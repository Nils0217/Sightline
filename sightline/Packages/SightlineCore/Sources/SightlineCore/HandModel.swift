// labels: production, needs-review, important
// Six hand keypoints from Vision's 21 joints (Nils, 2026-10-28: one point is not enough to grasp):
// five fingertips + palm centre. Guidance steers the palm centre (stable, rarely hidden while
// grasping); the fingertips tell whether the object is between them.

import simd

/// Vision `VNHumanHandPoseObservation.JointName` raw names, so the app can map 1:1.
public enum HandJoint: String, CaseIterable, Sendable {
    case wrist = "VNHLKWRI"
    case thumbCMC = "VNHLKTCMC", thumbMP = "VNHLKTMP", thumbIP = "VNHLKTIP", thumbTip = "VNHLKTTIP"
    case indexMCP = "VNHLKIMCP", indexPIP = "VNHLKIPIP", indexDIP = "VNHLKIDIP", indexTip = "VNHLKITIP"
    case middleMCP = "VNHLKMMCP", middlePIP = "VNHLKMPIP", middleDIP = "VNHLKMDIP", middleTip = "VNHLKMTIP"
    case ringMCP = "VNHLKRMCP", ringPIP = "VNHLKRPIP", ringDIP = "VNHLKRDIP", ringTip = "VNHLKRTIP"
    case littleMCP = "VNHLKPMCP", littlePIP = "VNHLKPPIP", littleDIP = "VNHLKPDIP", littleTip = "VNHLKPTIP"

    public static let tips: [HandJoint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
    /// Wrist + the four finger bases: their mean is the palm centre.
    public static let palm: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
}

public struct HandKeypoints: Sendable, Equatable {
    /// World positions (m) of the joints that were seen and had valid depth.
    public var joints: [HandJoint: SIMD3<Float>]

    public init(joints: [HandJoint: SIMD3<Float>]) { self.joints = joints }

    /// Mean of the visible palm joints (needs ≥ 2), else nil.
    public var palmCentre: SIMD3<Float>? {
        let seen = HandJoint.palm.compactMap { joints[$0] }
        guard seen.count >= 2 else { return nil }
        return seen.reduce(.zero, +) / Float(seen.count)
    }

    public var tips: [HandJoint: SIMD3<Float>] { joints.filter { HandJoint.tips.contains($0.key) } }

    /// The point guidance steers: palm centre, else the mean of visible fingertips (≥ 2), else any joint.
    public var reference: SIMD3<Float>? {
        if let p = palmCentre { return p }
        let t = Array(tips.values)
        if t.count >= 2 { return t.reduce(.zero, +) / Float(t.count) }
        return joints.values.first
    }

    /// Number of the six keypoints (5 tips + palm centre) available.
    public var keypointCount: Int { tips.count + (palmCentre == nil ? 0 : 1) }
}
