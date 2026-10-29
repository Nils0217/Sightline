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

    public private(set) var scanned: [SIMD3<Float>] = []
    public private(set) var used = 0
    private var lastDirection: SIMD3<Float>?
    private var lastTime: Double?
    private var steadySince: Double?
    private var lastScan: Double = -.infinity
    private var lastPrompt: Double

    public init(time: Double) { lastPrompt = time }

    public var exhausted: Bool { used >= budget }

    /// Viewing directions covered, in 30° compass sectors (12 = all round).
    public var sectorsCovered: Int { Set(scanned.map { Self.sector($0) }).count }

    /// The view at lock time already failed: count it as searched without spending budget.
    public mutating func markSearched(cameraTransform t: simd_float4x4) { scanned.append(Self.direction(t)) }

    public enum Step: Equatable, Sendable { case wait, scan, prompt, giveUp }

    public mutating func update(time: Double, cameraTransform t: simd_float4x4, busy: Bool, speaking: Bool) -> Step {
        let dir = Self.direction(t)
        defer { lastDirection = dir; lastTime = time }
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
            scanned.append(dir)
            return .scan
        }
        if !speaking, time - lastPrompt >= promptEvery {
            lastPrompt = time
            return .prompt
        }
        return .wait
    }

    /// Note that speech just happened (resets the prompt timer).
    public mutating func spoke(at time: Double) { lastPrompt = time }

    // Shared spoken lines (app and simulator).
    public static func startLine(_ noun: String) -> String {
        "I don't see the \(noun) here. Turn slowly to your left and right. I'll keep looking."
    }
    public static let promptLine = "Still looking. Keep turning slowly."

    /// Points to look at first (e.g. where the room map last saw the object), world space.
    public var hint: SIMD3<Float>?

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
                return d > 0 ? "Turn right slowly, toward where I last saw it." : "Turn left slowly, toward where I last saw it."
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
