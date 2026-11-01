// labels: production, needs-review, important
// Keep looking while the user turns (Nils, 2026-10-28: "move around while keep scanning; otherwise
// the blind user still can't know where the item is"). Decides *when* a new SAM call is worth it:
// only for a view that is new (≥ 25° from every view already searched) and steady (not blurred).
// Cost stays event-triggered: one SAM call per new view, capped by `budget`.

import Foundation
import simd

public struct ScanPlanner: Sendable {
    public var minNewAngle: Float = 25 * .pi / 180
    /// Camera must turn slower than this (rad/s) for `steadyFor` seconds: blurred frames waste a call.
    public var maxTurnSpeed: Float = 35 * .pi / 180
    public var steadyFor: Double = 0.4
    public var minGap: Double = 1.5
    /// SAM calls allowed for scanning one search.
    public var budget = 8
    /// Repeat "keep turning" after this long without speech.
    public var promptEvery: Double = 8
    /// "Keep turning" this many times with no new view in between -> give up (v7: the user did not turn,
    /// no SAM call was ever made, and "Still looking. Keep turning slowly." repeated until he stopped it).
    public var maxIdlePrompts = 3
    private var idlePrompts = 0

    public private(set) var scanned: [SIMD3<Float>] = []
    public private(set) var used = 0
    private var lastDirection: SIMD3<Float>?
    private var lastTime: Double?
    private var steadySince: Double?
    private var lastScan: Double = -.infinity
    private var lastPrompt: Double
    /// Compass sectors the camera has pointed at (every frame, not only views sent to Spark/SAM).
    public private(set) var swept: Set<Int> = []

    public init(time: Double) { lastPrompt = time }

    /// Room scan finished without a tap (Nils, 2026-11-01: "shouldn't ask user tap to stop, it should stop
    /// automatically"): the camera went all round and at least `minMapViews` views were listed, or the
    /// view budget is used up.
    public static let minMapViews = 6
    public var mappingDone: Bool { exhausted || (swept.count >= 12 && used >= Self.minMapViews) }

    public var exhausted: Bool { used >= budget }

    /// Viewing directions covered, in 30° compass sectors (12 = all round).
    public var sectorsCovered: Int { Set(scanned.map { Self.sector($0) }).count }

    /// The view at lock time already failed: count it as searched without spending budget.
    public mutating func markSearched(cameraTransform t: simd_float4x4) { scanned.append(Self.direction(t)) }

    public enum Step: Equatable, Sendable { case wait, scan, prompt, giveUp }

    public mutating func update(time: Double, cameraTransform t: simd_float4x4, busy: Bool, speaking: Bool) -> Step {
        let dir = Self.direction(t)
        defer { lastDirection = dir; lastTime = time }
        // Level-ish views only: pointing at the floor or ceiling does not cover a compass direction.
        if abs(dir.y) < 0.8 { swept.insert(Self.sector(dir)) }
        if let prev = lastDirection, let t0 = lastTime, time > t0 {
            let speed = Self.angle(prev, dir) / Float(time - t0)
            if speed < maxTurnSpeed { steadySince = steadySince ?? time } else { steadySince = nil }
        }
        if exhausted && !busy { return .giveUp }
        let steady = steadySince.map { time - $0 >= steadyFor } ?? false
        let isNew = scanned.allSatisfy { Self.angle($0, dir) >= minNewAngle }
        if !busy, steady, isNew, time - lastScan >= minGap {
            lastScan = time
            used += 1
            idlePrompts = 0
            scanned.append(dir)
            return .scan
        }
        if !speaking, !busy, time - lastPrompt >= promptEvery {
            lastPrompt = time
            if idlePrompts >= maxIdlePrompts { return .giveUp }
            idlePrompts += 1
            return .prompt
        }
        return .wait
    }

    /// Note that speech just happened (resets the prompt timer).
    public mutating func spoke(at time: Double) { lastPrompt = time }

    // Shared spoken lines (app and simulator).
    public static func startLine(_ noun: String) -> String {
        "I don't see the \(noun) here. Turn slowly."
    }
    public static let promptLine = "Still looking. Keep turning slowly."

    /// Points to look at first (e.g. where the room map last saw the object), world space.
    public var hint: SIMD3<Float>?
    /// The hint is Spark's guess from nearby things, not a sighting of the object.
    public var hintIsGuess = false

    /// "left a little", "right, about a quarter turn", "left, about half a turn" for a yaw
    /// difference `d` (radians, + = right).
    public static func turn(_ d: Float) -> String {
        let side = d > 0 ? "right" : "left"
        let deg = abs(d) * 180 / .pi
        if deg < TurnSize.littleBelow { return "\(side) a little" }
        if deg < TurnSize.quarterBelow { return "\(side), about a quarter turn" }
        return "\(side), about half a turn"
    }

    /// Room scan ("scan the room"): always one way round, so the user is never sent back and forth
    /// (v5 test: the search prompts flipped left/right and said "I haven't looked there yet").
    public func mappingPrompt(cameraTransform t: simd_float4x4) -> String {
        // The scan ends by itself (mappingDone), so no line asks for a tap.
        if swept.count >= 12 { return "Keep turning right, slowly. Almost done." }
        return sectorsCovered <= 1 ? "Turn slowly to your right." : "Keep turning right, slowly."
    }

    /// Which way to turn next (2026-10-29: "keep turning" alone gave no direction): toward the hint
    /// while it is not yet searched, else the nearest compass sector not searched yet, else lower.
    public func directionPrompt(cameraTransform t: simd_float4x4) -> String {
        let dir = Self.direction(t)
        let yaw = Self.yaw(dir)
        let searched = Set(scanned.map { Self.sector($0) })
        if let hint {
            let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            let toHint = simd_normalize(hint - camera)
            if scanned.allSatisfy({ Self.angle($0, toHint) >= minNewAngle }) {
                let d = Self.wrap(Self.yaw(toHint) - yaw)
                if abs(d) < minNewAngle { return toHint.y < dir.y - 0.3 ? "Point the phone a little lower." : "Hold still. Looking there now." }
                // v5 test: "turn left" alone gave no idea how far; "behind you" needs half a turn.
                return "Turn \(Self.turn(d)), toward \(hintIsGuess ? "where it might be" : "where I last saw it")."
            }
        }
        // Nearest unsearched sector centre.
        var best: Float?
        for s in 0..<12 where !searched.contains(s) {
            let centre = Float(s) * .pi / 6 - .pi + .pi / 12
            let d = Self.wrap(centre - yaw)
            if best == nil || abs(d) < abs(best!) { best = d }
        }
        if let d = best, abs(d) >= .pi / 12 {
            return d > 0 ? "Turn right slowly. I haven't looked there yet." : "Turn left slowly. I haven't looked there yet."
        }
        // All round at this height: look lower (floors, low shelves) if not done yet.
        if !scanned.contains(where: { $0.y < -0.6 }) { return "Point the phone lower, toward the floor, and turn slowly." }
        return Self.promptLine
    }

    static func yaw(_ d: SIMD3<Float>) -> Float { atan2(d.x, -d.z) }
    static func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }
    public static func giveUpLine(_ noun: String) -> String {
        "I looked around and couldn't find the \(noun). Tap to try again."
    }

    static func direction(_ t: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(-SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
    }

    static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(max(-1, min(1, simd_dot(a, b))))
    }

    static func sector(_ d: SIMD3<Float>) -> Int {
        let yaw = Self.yaw(d)  // 0 = initial forward (−z), + = right
        return (Int(floor((yaw + .pi) / (.pi / 6))) % 12 + 12) % 12
    }
}
