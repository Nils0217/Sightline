// labels: production, needs-review, important
// Six-point hand (5 fingertips + palm joints) in ARKit world space from one ARFrame:
// Vision 21 joints -> LiDAR depth per joint -> unproject -> world. Replaces the single index tip
// for the find flow (Nils, 2026-10-28). Call on one serial queue only (holds Vision state).

import ARKit
import SightlineCore

nonisolated struct HandObservation: Sendable {
    /// Joints with valid depth, world space. nil when fewer than `minJoints` survived.
    var keypoints: HandKeypoints?
    /// Every joint Vision saw (normalized portrait, origin bottom-left), for overlays and recordings.
    var vision: [HandJoint: SIMD2<Float>] = [:]
    /// Depth (m) per joint that got one.
    var depths: [HandJoint: Float] = [:]
    var failReason: String?
}

nonisolated struct HandKeypointLocator {
    /// Joints used for guidance: palm (wrist + 4 MCP) and the 5 tips.
    static let used: [HandJoint] = HandJoint.palm + HandJoint.tips
    /// A joint whose depth is this far from the hand's median depth hit the background (or the object).
    static let maxDepthOutlier: Float = 0.08
    static let minJoints = 2

    private let detector = HandPoseDetector()
    private let sampler = DepthSampler()

    func locate(in frame: ARFrame) -> HandObservation {
        var r = HandObservation()
        let joints = detector.joints(in: frame.capturedImage, orientation: .right)
        r.vision = joints.mapValues(\.point)
        guard !joints.isEmpty else { r.failReason = "no_hand"; return r }
        guard case .normal = frame.camera.trackingState else { r.failReason = "tracking_limited"; return r }
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else {
            r.failReason = "depth_invalid"
            return r
        }
        let rawSize = SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height))
        let depthSize = SIMD2(Float(depth.width), Float(depth.height))
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: rawSize).scaled(to: depthSize)

        var camera: [HandJoint: SIMD3<Float>] = [:]
        for j in Self.used {
            guard let tip = joints[j] else { continue }
            let raw = DepthProjector.rawPixel(fromVision: tip.point, orientation: .right, rawSize: rawSize)
            let pixel = (raw + 0.5) * (depthSize / rawSize) - 0.5
            guard case .success(let s) = sampler.sample(depth, at: pixel) else { continue }
            r.depths[j] = s.depth
            camera[j] = DepthProjector.unproject(pixel: pixel, depth: s.depth, intrinsics: k)
        }
        // Drop joints whose depth disagrees with the rest of the hand (fingertip over the table edge).
        if let median = Stats.median(Array(r.depths.values)) {
            for (j, d) in r.depths where abs(d - median) > Self.maxDepthOutlier { camera[j] = nil }
        }
        guard camera.count >= Self.minJoints else { r.failReason = "too_few_joints"; return r }
        let t = frame.camera.transform
        let hand = HandKeypoints(joints: camera.mapValues { DepthProjector.world(fromCamera: $0, cameraTransform: t) })
        guard hand.reference != nil else { r.failReason = "too_few_joints"; return r }
        r.keypoints = hand
        return r
    }
}
