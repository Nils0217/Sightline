// labels: production, needs-review
// G1 auto-capture: log a touch when the fingertip dwells near the reference,
// because a chest-mounted phone leaves no hand free to press a button.

import simd

public struct DwellDetector: Sendable {
    /// Fingertip must be within this distance of the reference to capture (metres).
    public var nearRadius: Float = 0.10
    /// Max movement during the dwell window (metres).
    public var stillTolerance: Float = 0.005
    /// Dwell time (seconds).
    public var dwell: Double = 0.5

    private var window: [(time: Double, position: SIMD3<Float>)] = []
    private var armed = true

    public init() {}

    /// Feed one fingertip estimate (nil = no valid estimate this frame).
    /// Returns the averaged fingertip position when a touch is captured.
    public mutating func update(time: Double, fingertip: SIMD3<Float>?, reference: SIMD3<Float>) -> SIMD3<Float>? {
        guard let tip = fingertip else {
            window.removeAll()
            return nil
        }
        let distance = simd_distance(tip, reference)
        if !armed {
            // Re-arm only after the hand leaves the zone, so one touch logs once.
            if distance > nearRadius { armed = true }
            window.removeAll()
            return nil
        }
        guard distance <= nearRadius else {
            window.removeAll()
            return nil
        }

        window.append((time, tip))
        window.removeAll { time - $0.time > dwell }
        guard let first = window.first, time - first.time >= dwell * 0.9 else { return nil }

        let mean = window.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(window.count)
        let still = window.allSatisfy { simd_distance($0.position, mean) <= stillTolerance }
        guard still else { return nil }

        armed = false
        window.removeAll()
        return mean
    }
}

/// Error of one touch, split relative to the reference plane.
public struct TouchError: Sendable, Equatable {
    public let total: Float
    /// Signed distance along the plane normal (positive = above the plane).
    public let normal: Float
    public let inPlane: Float

    public init(tip: SIMD3<Float>, reference: SIMD3<Float>, planeNormal: SIMD3<Float>) {
        let d = tip - reference
        let n = simd_normalize(planeNormal)
        let along = simd_dot(d, n)
        total = simd_length(d)
        normal = along
        inPlane = simd_length(d - along * n)
    }
}
