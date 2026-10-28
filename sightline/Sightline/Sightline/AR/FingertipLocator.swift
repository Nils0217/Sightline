// labels: production, needs-review, important
// Index fingertip in ARKit world space from one ARFrame: Vision hand pose -> LiDAR depth ->
// unproject -> world. Shared by the G1 test (FrameProcessor) and the find-and-grab loop.
// Call on one serial queue only (holds Vision request state).

import ARKit
import SightlineCore

nonisolated struct FingertipResult: Sendable {
    var handConfidence: Float?
    /// Vision index tip, normalized portrait coordinates (origin bottom-left).
    var visionTip: SIMD2<Float>?
    var tip: SIMD3<Float>?
    var depth: Float?
    var validSamples = 0
    var depthRelaxed = false
    /// nil = valid tip. Values match docs/G1_PLAN.md `fail_reason`.
    var failReason: String?
}

nonisolated struct FingertipLocator {
    static let minHandConfidence: Float = 0.5

    private let hand = HandPoseDetector()
    private let sampler = DepthSampler()

    func locate(in frame: ARFrame) -> FingertipResult {
        var r = FingertipResult()
        guard let tip = hand.indexTip(in: frame.capturedImage, orientation: .right) else {
            r.failReason = "no_hand"
            return r
        }
        r.handConfidence = tip.confidence
        r.visionTip = tip.point
        guard tip.confidence >= Self.minHandConfidence else {
            r.failReason = "low_hand_conf"
            return r
        }
        guard case .normal = frame.camera.trackingState else {
            r.failReason = "tracking_limited"
            return r
        }
        guard let depthData = frame.sceneDepth, let depth = DepthImageReader.read(depthData) else {
            r.failReason = "depth_invalid"
            return r
        }
        let rawSize = SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height))
        let depthSize = SIMD2(Float(depth.width), Float(depth.height))
        let raw = DepthProjector.rawPixel(fromVision: tip.point, orientation: .right, rawSize: rawSize)
        let depthPixel = (raw + 0.5) * (depthSize / rawSize) - 0.5
        switch sampler.sample(depth, at: depthPixel) {
        case .failure(let failure):
            r.failReason = failure.rawValue
        case .success(let sample):
            let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: rawSize).scaled(to: depthSize)
            let cameraPoint = DepthProjector.unproject(pixel: depthPixel, depth: sample.depth, intrinsics: k)
            r.tip = DepthProjector.world(fromCamera: cameraPoint, cameraTransform: frame.camera.transform)
            r.depth = sample.depth
            r.validSamples = sample.validSamples
            r.depthRelaxed = sample.relaxed
        }
        return r
    }
}
