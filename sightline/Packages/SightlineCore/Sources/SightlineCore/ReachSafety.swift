// labels: production, needs-review, important
// Conservative reach limits and staged approach; no walking or claim of collision-free motion.
import simd

public struct ReachProfile: Sendable {
    /// Measured from the worn camera to the user's comfortably extended fingertip, metres.
    public var maximumDistance: Float
    public init(maximumDistance: Float) { self.maximumDistance = maximumDistance }

    public func permits(target: SIMD3<Float>, cameraTransform: simd_float4x4) -> Bool {
        let camera = SIMD3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        let offset = BodyOffset(from: camera, to: target, cameraTransform: cameraTransform)
        return maximumDistance.isFinite && maximumDistance >= 0.15 && maximumDistance <= 0.85
            && target.x.isFinite && target.y.isFinite && target.z.isFinite
            && offset.forward >= 0.05 && simd_distance(camera, target) <= maximumDistance
    }
}

/// A calibration succeeds only on a steady, fully observed fingertip. Repeat after moving the phone.
public struct ReachCalibration: Sendable {
    private var samples: [(Double, SIMD3<Float>, SIMD3<Float>)] = []
    public init() {}
    public mutating func update(time: Double, fingertip: SIMD3<Float>?, camera: SIMD3<Float>) -> Float? {
        guard let fingertip else { samples.removeAll(); return nil }
        samples.append((time, fingertip, camera))
        samples.removeAll { time - $0.0 > 1.0 }
        guard let first = samples.first, time - first.0 >= 0.8, samples.count >= 8 else { return nil }
        guard samples.allSatisfy({ simd_distance($0.1, fingertip) < 0.025 && simd_distance($0.2, camera) < 0.02 }) else { return nil }
        let distance = samples.map { simd_distance($0.1, $0.2) }.sorted()[samples.count / 2] - 0.03
        return (0.15...0.85).contains(distance) ? distance : nil
    }
}

/// Fixed in world space for a reach. Phone/body turns require a new lock before moving again.
public enum ReachFrame {
    public static func rotationDifference(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let dot = abs(simd_dot(simd_quatf(a).vector, simd_quatf(b).vector))
        return dot.isFinite ? 2 * acos(min(1, max(0, dot))) : .pi
    }

    public static func yawDifference(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        func forward(_ t: simd_float4x4) -> SIMD3<Float> {
            var f = -SIMD3(t.columns.2.x, 0, t.columns.2.z)
            if simd_length(f) < 0.001 { f = SIMD3(t.columns.1.x, 0, t.columns.1.z) }
            return simd_normalize(f)
        }
        let dot = simd_dot(forward(a), forward(b))
        return dot.isFinite ? acos(min(1, max(-1, dot))) : .pi
    }
}

/// Tabletop approach: lift clear, move over a reachable edge, then descend to exploration height.
/// Obstacles can veto each actual axis segment; this is not an autonomous detour planner.
public struct ReachApproach: Sendable {
    public enum Stage: String, Sendable { case lift, traverse, advance, approach }
    public private(set) var stage = Stage.lift
    public let contact: SIMD3<Float>
    private let transitY: Float
    private let flat: Bool
    private let advancePoint: SIMD3<Float>

    public init(object: ObjectModel, from point: SIMD3<Float>, cameraTransform t: simd_float4x4 = matrix_identity_float4x4) {
        flat = object.isFlat
        contact = object.nearestSurfacePoint(to: point)
        transitY = max(point.y, contact.y + 0.10)
        var forward = -SIMD3(t.columns.2.x, 0, t.columns.2.z)
        if simd_length(forward) < 0.001 { forward = SIMD3(t.columns.1.x, 0, t.columns.1.z) }
        forward = simd_normalize(forward)
        advancePoint = point + forward * simd_dot(contact - point, forward)
        if !flat { stage = simd_distance(point, advancePoint) > 0.04 ? .advance : .approach }
    }

    public mutating func waypoint(from point: SIMD3<Float>) -> SIMD3<Float> {
        if stage == .lift && point.y >= transitY - 0.04 { stage = .traverse }
        if stage == .advance && simd_distance(point, advancePoint) <= 0.04 { stage = .approach }
        let sideways = simd_length(SIMD2(point.x - contact.x, point.z - contact.z))
        if stage == .traverse && sideways <= 0.04 { stage = .approach }
        switch stage {
        case .lift: return SIMD3(point.x, transitY, point.z)
        case .traverse: return SIMD3(contact.x, transitY, contact.z)
        case .advance: return advancePoint
        case .approach: return contact + SIMD3(0, flat ? 0.03 : 0, 0)
        }
    }
}

/// Two observations must show hand/object moving together. A single image cannot prove a hold.
public enum HoldMotion {
    public static func verified(firstObject: SIMD3<Float>, firstHand: SIMD3<Float>, firstTime: Double,
                                object: SIMD3<Float>, hand: SIMD3<Float>, time: Double) -> Bool {
        let dt = time - firstTime
        let movement = simd_distance(hand, firstHand)
        let objectMovement = simd_distance(object, firstObject)
        let drift = simd_distance(object - hand, firstObject - firstHand)
        return dt >= 0.35 && dt <= 30 && movement >= 0.03 && objectMovement >= 0.03 && drift <= 0.025
    }
}

/// An empty obstacle set is meaningful only when enough scene depth was actually observed.
public enum SceneCoverage {
    public static func isUsable(valid: Int, sampled: Int) -> Bool {
        sampled >= 16 && valid >= 16 && Float(valid) / Float(sampled) >= 0.25
    }
}

/// Shared self-return exclusion and arm envelope; a coarse model, not a full tracked skeleton.
public enum HandEnvelope {
    public static func centres(hand: HandKeypoints, camera: SIMD3<Float>) -> [SIMD3<Float>] {
        var points = Array(hand.joints.values)
        if let wrist = hand.joints[.wrist] {
            let back = camera - wrist
            if simd_length(back) > 0.01 {
                for distance: Float in [0.05, 0.10, 0.15, 0.20] { points.append(wrist + simd_normalize(back) * distance) }
            }
        }
        return points
    }
}
