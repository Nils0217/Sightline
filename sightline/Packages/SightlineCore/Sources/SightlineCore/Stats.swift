// labels: production, needs-review
// Summary statistics for G1 error reports.

/// One distance per meaning (2026-11-03 alignment: every judge used its own radius for the same
/// "touching / same thing / already seen", so the hold check, guidance and the map disagreed).
/// Same level, same value; BodyScale derives the per-user value from these.
public enum Geometry {
    /// Contact level: a fingertip on the surface (grasp, touch, near).
    public static let touch: Float = 0.03
    /// Contact level: a fingertip at the object, arming the leave/rise checks.
    public static let near: Float = 0.04
    /// Object level: two detections / spots are the same thing (tile dedup, agent merge,
    /// still-at-spot, mark-other).
    public static let same: Float = 0.05
    /// Skip level: an already-rejected lock, or a same-named cluster that is the target's own
    /// edge, is not locked or named again within this of it.
    public static let skip: Float = 0.10
    /// Room level: two sightings are the same saved thing.
    public static let roomSame: Float = 0.50
    /// Room level: landmark alignment agreement.
    public static let align: Float = 0.25
}

public enum Stats {
    public static func median(_ values: [Float]) -> Float? {
        percentile(values, 0.5)
    }

    public static func mean(_ values: [Float]) -> Float? {
        values.isEmpty ? nil : values.reduce(0, +) / Float(values.count)
    }

    /// Linear-interpolated percentile, p in [0, 1].
    public static func percentile(_ values: [Float], _ p: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(max(p, 0), 1) * Float(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        let frac = rank - Float(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

/// G1 report: touch errors plus a localisation rate.
/// Auto-capture only fires on valid estimates, so the rate is measured per frame:
/// frames with a valid 3D fingertip / frames where Vision saw a hand.
public struct AccuracyReport: Sendable, Equatable {
    public let attempts: Int
    public let valid: Int
    public let touches: Int
    public let median: Float?
    public let mean: Float?
    public let p90: Float?

    public var validRate: Float { attempts == 0 ? 0 : Float(valid) / Float(attempts) }

    /// Gate from docs/G1_PLAN.md: median <= 3 cm and valid rate >= 80%.
    public var passesGate: Bool {
        guard let median else { return false }
        return median <= 0.03 && validRate >= 0.8
    }

    public init(errors: [Float], validEstimates: Int, attempts: Int) {
        self.attempts = attempts
        valid = validEstimates
        touches = errors.count
        median = Stats.median(errors)
        mean = Stats.mean(errors)
        p90 = Stats.percentile(errors, 0.9)
    }
}
