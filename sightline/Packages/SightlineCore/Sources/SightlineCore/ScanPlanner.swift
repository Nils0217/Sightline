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
        let yaw = atan2(d.x, -d.z)  // 0 = initial forward (−z)
        return (Int(floor((yaw + .pi) / (.pi / 6))) % 12 + 12) % 12
    }
}
