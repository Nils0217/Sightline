// labels: production, needs-review
// Index fingertip from Apple Vision hand pose. Runs off the main thread.

import CoreVideo
import ImageIO
import Vision

/// Vision result in normalized coordinates (origin bottom-left) of the oriented image.
nonisolated struct HandTip: Sendable {
    let point: SIMD2<Float>
    let confidence: Float
}

nonisolated final class HandPoseDetector {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// nil when no hand is found or Vision fails.
    func indexTip(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> HandTip? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let hand = request.results?.first,
              let tip = try? hand.recognizedPoint(.indexTip) else { return nil }
        return HandTip(point: SIMD2(Float(tip.location.x), Float(tip.location.y)),
                       confidence: Float(tip.confidence))
    }
}
