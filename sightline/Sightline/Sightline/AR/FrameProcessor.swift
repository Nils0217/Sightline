// labels: production, needs-review, important
// Per-frame pipeline on a background queue: reference anchor -> Vision fingertip ->
// LiDAR depth -> world position -> dwell capture. Never touches the main thread directly;
// results go to the main actor as `FrameMeasurement`.

import ARKit
import SightlineCore

nonisolated struct FrameMeasurement: Sendable {
    var time: Double
    var tracking: String
    var reference: SIMD3<Float>?
    /// Image-plane normal (anchor +y) in world space.
    var referenceNormal: SIMD3<Float>?
    /// Max deviation of the anchor centre from its mean over the last `jitterWindow` s; nil until the window is full.
    var referenceJitterMM: Float?
    var handConfidence: Float?
    var tip: SIMD3<Float>?
    var tipDepth: Float?
    var validSamples = 0
    /// Depth came from the wider medium-confidence fallback pass.
    var depthRelaxed = false
    /// Vision index tip, normalized portrait coordinates (origin bottom-left), for offset analysis.
    var visionTip: SIMD2<Float>?
    /// nil = valid fingertip estimate. Values match docs/G1_PLAN.md `fail_reason`.
    var failReason: String?
    /// Set on the frame a dwell touch is captured (averaged fingertip position).
    var capturedTouch: SIMD3<Float>?
}

nonisolated final class FrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    static let minHandConfidence = FingertipLocator.minHandConfidence
    static let jitterWindow: Double = 5

    let queue = DispatchQueue(label: "sightline.frames", qos: .userInteractive)
    private let onMeasurement: @Sendable (FrameMeasurement) -> Void
    private let locator = FingertipLocator()

    // Accessed only on `queue`.
    private var dwell = DwellDetector()
    private var anchorHistory: [(time: Double, centre: SIMD3<Float>)] = []
    private var frameCount = 0

    // Written from the main actor, read on `queue`.
    private let lock = NSLock()
    private var _captureArmed = false
    var captureArmed: Bool {
        get { lock.withLock { _captureArmed } }
        set { lock.withLock { _captureArmed = newValue } }
    }

    init(onMeasurement: @escaping @Sendable (FrameMeasurement) -> Void) {
        self.onMeasurement = onMeasurement
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }  // ~30 Hz is enough and keeps Vision cheap
        onMeasurement(measure(frame))
    }

    private func measure(_ frame: ARFrame) -> FrameMeasurement {
        var m = FrameMeasurement(time: frame.timestamp, tracking: Self.describe(frame.camera.trackingState))

        if let anchor = frame.anchors.lazy.compactMap({ $0 as? ARImageAnchor }).first(where: { $0.isTracked }) {
            let t = anchor.transform
            let centre = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            m.reference = centre
            m.referenceNormal = SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
            m.referenceJitterMM = jitter(adding: centre, at: frame.timestamp)
        } else {
            anchorHistory.removeAll()
        }

        let r = locator.locate(in: frame)
        m.handConfidence = r.handConfidence
        m.visionTip = r.visionTip
        m.tip = r.tip
        m.tipDepth = r.depth
        m.validSamples = r.validSamples
        m.depthRelaxed = r.depthRelaxed
        m.failReason = r.failReason
        return finish(m)
    }

    /// Runs dwell detection; a reference is required to capture.
    private func finish(_ m: FrameMeasurement) -> FrameMeasurement {
        var m = m
        if m.reference == nil, m.failReason == nil { m.failReason = "no_anchor" }
        if captureArmed, let reference = m.reference {
            m.capturedTouch = dwell.update(time: m.time, fingertip: m.tip, reference: reference)
        } else {
            dwell = DwellDetector()
        }
        return m
    }

    private func jitter(adding centre: SIMD3<Float>, at time: Double) -> Float? {
        anchorHistory.append((time, centre))
        anchorHistory.removeAll { time - $0.time > Self.jitterWindow }
        guard let first = anchorHistory.first, time - first.time >= Self.jitterWindow * 0.95 else { return nil }
        let mean = anchorHistory.reduce(SIMD3<Float>.zero) { $0 + $1.centre } / Float(anchorHistory.count)
        let maxDev = anchorHistory.map { simd_distance($0.centre, mean) }.max() ?? 0
        return maxDev * 1000
    }

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: "normal"
        case .notAvailable: "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: "limited_initializing"
            case .excessiveMotion: "limited_motion"
            case .insufficientFeatures: "limited_features"
            case .relocalizing: "limited_relocalizing"
            @unknown default: "limited"
            }
        }
    }
}
