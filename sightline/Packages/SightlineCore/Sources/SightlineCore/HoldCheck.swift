// labels: production, needs-review, important
// One-photo hold check (v9, back to the v7 design): one SAM call says where the object is now,
// one Spark call (the photo with the reference crop) says whether the hand holds it. Any pick-up
// starts it at once; GuidanceSession caps the automatic ones. HoldDecision (ObjectModel.swift)
// combines the two. See docs/TEST_LOG.md T10.

import simd

public enum HoldContact {
    /// Proximity candidate, not grip proof. Two visible tips suffice; a thumb is not mandatory.
    public static func near(hand: HandKeypoints?, points: [SIMD3<Float>], centre: SIMD3<Float>) -> Bool {
        guard let hand else { return false }
        let surface = points.isEmpty ? [centre] : points
        return hand.tips.values.filter { tip in surface.contains { simd_distance($0, tip) <= 0.04 } }.count >= 2
    }
}

public enum HoldGeometry {
    /// Where it was found: within this of the original spot counts as "still there".
    public static let spotRadius: Float = 0.05
    /// A supported object must rise this much; sliding it on the table is not a pick-up.
    public static let minRise: Float = 0.03

    /// SAM candidate (world centre) on the check photo relative to the original spot, for HoldDecision.
    /// No candidate: atSpot nil (cannot tell).
    public static func classify(candidate: SIMD3<Float>?, original: SIMD3<Float>, supported: Bool,
                                nearHand: Bool) -> (held: Bool, atSpot: Bool?) {
        guard let c = candidate else { return (false, nil) }
        let atSpot = simd_distance(c, original) < spotRadius
        let rose = !supported || c.y - original.y >= minRise
        return (!atSpot && rose && nearHand, atSpot)
    }
}

/// Layer 2 (v9.1, 2026-10-31): RECORD ONLY. What LiDAR sees now along the rays to the target's surface
/// points as locked: the object (same depth), the background behind it (farther: the spot is empty),
/// something nearer (a hand or arm in the way), or nothing usable. Depth cannot say *what* is there,
/// so this never blocks or decides a check; the logs decide later whether it is reliable enough.
/// Tolerances are sensor/object values (not BodyScale) and untested on the device.
public struct SpotEvidence: Sendable, Equatable {
    public enum State: String, Sendable { case present, vacated, unknown }

    public struct Sample: Sendable {
        /// Depth (metres along the optical axis) of the locked surface point from the current camera.
        public var expected: Float
        /// LiDAR depth at that pixel now; nil when off-screen or no reading.
        public var measured: Float?
        /// ARConfidenceLevel raw value (0 low, 1 medium, 2 high).
        public var confidence: UInt8
        /// Height of the point above the object's support surface; nil without a support plane.
        public var thickness: Float?
        public init(expected: Float, measured: Float?, confidence: UInt8, thickness: Float?) {
            self.expected = expected; self.measured = measured; self.confidence = confidence; self.thickness = thickness
        }
    }

    public var state: State
    public var object = 0, background = 0, occluded = 0, invalid = 0

    /// Same depth as the object within this (metres).
    public static let tolerance: Float = 0.015
    /// Share of the usable samples needed for "present" or "vacated".
    public static let majority: Float = 0.7
    public static let minUsable = 12

    public static func classify(_ samples: [Sample]) -> SpotEvidence {
        var e = SpotEvidence(state: .unknown)
        for s in samples {
            guard let d = s.measured, d.isFinite, d > 0, s.confidence >= 1 else { e.invalid += 1; continue }
            // Thinner than the noise band: object and table cannot be told apart (keys, a phone lying flat).
            if let t = s.thickness, t < tolerance { e.invalid += 1; continue }
            let gap = max(tolerance, (s.thickness ?? 0.03) * 0.5)
            if d < s.expected - tolerance { e.occluded += 1 }
            else if abs(d - s.expected) <= tolerance { e.object += 1 }
            else if d >= s.expected + gap { e.background += 1 }
            else { e.invalid += 1 }
        }
        let usable = e.object + e.background
        guard usable >= minUsable, Float(usable) >= 0.3 * Float(max(1, samples.count)) else { return e }
        if Float(e.object) >= majority * Float(usable) { e.state = .present }
        else if Float(e.background) >= majority * Float(usable) { e.state = .vacated }
        return e
    }

    public var summary: String { "\(state.rawValue) object \(object) background \(background) occluded \(occluded) invalid \(invalid)" }
}
