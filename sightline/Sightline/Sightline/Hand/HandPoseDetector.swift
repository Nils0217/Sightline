// labels: production, needs-review
// Index fingertip (and a whole-hand fallback point) from Apple Vision hand pose. Off the main thread.

import CoreVideo
import ImageIO
import SightlineCore
import Vision

/// Vision result in normalized coordinates (origin bottom-left) of the oriented image.
nonisolated struct HandTip: Sendable {
    let point: SIMD2<Float>
    let confidence: Float
}

/// Index tip plus the mean of all confidently seen joints (used when the index tip is hidden,
/// e.g. behind the palm or other fingers while grasping).
nonisolated struct HandPoints: Sendable {
    var indexTip: HandTip?
    var centre: HandTip?
}

nonisolated final class HandPoseDetector {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    /// nil when no hand is found or Vision fails.
    func indexTip(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> HandTip? {
        hand(in: pixelBuffer, orientation: orientation)?.indexTip
    }

    /// Vision joint name -> SightlineCore joint (the six-keypoint model needs palm + tips).
    static let jointMap: [VNHumanHandPoseObservation.JointName: HandJoint] = [
        .wrist: .wrist,
        .thumbCMC: .thumbCMC, .thumbMP: .thumbMP, .thumbIP: .thumbIP, .thumbTip: .thumbTip,
        .indexMCP: .indexMCP, .indexPIP: .indexPIP, .indexDIP: .indexDIP, .indexTip: .indexTip,
        .middleMCP: .middleMCP, .middlePIP: .middlePIP, .middleDIP: .middleDIP, .middleTip: .middleTip,
        .ringMCP: .ringMCP, .ringPIP: .ringPIP, .ringDIP: .ringDIP, .ringTip: .ringTip,
        .littleMCP: .littleMCP, .littlePIP: .littlePIP, .littleDIP: .littleDIP, .littleTip: .littleTip,
    ]

    /// All joints Vision reports with confidence ≥ `minConfidence`; empty when no hand.
    func joints(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                minConfidence: Float = 0.3) -> [HandJoint: HandTip] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil, let hand = request.results?.first,
              let points = try? hand.recognizedPoints(.all) else { return [:] }
        var out: [HandJoint: HandTip] = [:]
        for (name, p) in points where Float(p.confidence) >= minConfidence {
            guard let j = Self.jointMap[name] else { continue }
            out[j] = HandTip(point: SIMD2(Float(p.location.x), Float(p.location.y)), confidence: Float(p.confidence))
        }
        return out
    }

    /// nil when no hand is found or Vision fails.
    func hand(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> HandPoints? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let hand = request.results?.first else { return nil }
        var result = HandPoints()
        if let tip = try? hand.recognizedPoint(.indexTip) {
            result.indexTip = HandTip(point: SIMD2(Float(tip.location.x), Float(tip.location.y)), confidence: Float(tip.confidence))
        }
        let seen = ((try? hand.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence >= 0.3 }
        if seen.count >= 4 {
            let n = Float(seen.count)
            let x = seen.reduce(Float(0)) { $0 + Float($1.location.x) } / n
            let y = seen.reduce(Float(0)) { $0 + Float($1.location.y) } / n
            let c = seen.reduce(Float(0)) { $0 + Float($1.confidence) } / n
            result.centre = HandTip(point: SIMD2(x, y), confidence: c)
        }
        return result.indexTip == nil && result.centre == nil ? nil : result
    }
}
