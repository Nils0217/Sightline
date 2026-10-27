// labels: production, needs-review, important
// Robust depth at a fingertip from the low-res LiDAR map (256x192 on iPhone 15 Pro).
// Fails instead of guessing when too few trustworthy samples exist (docs/G1_PLAN.md).

/// A copy of `ARDepthData.depthMap` (+ `confidenceMap`) as plain arrays, row-major.
public struct DepthImage: Sendable {
    public let width: Int
    public let height: Int
    /// Metres. Non-finite or <= 0 means no reading.
    public let depth: [Float]
    /// `ARConfidenceLevel` raw values (0 low, 1 medium, 2 high); nil = treat all as high.
    public let confidence: [UInt8]?

    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]? = nil) {
        precondition(depth.count == width * height, "depth size mismatch")
        precondition(confidence == nil || confidence!.count == width * height, "confidence size mismatch")
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
    }
}

public enum DepthSampleFailure: String, Sendable, Error {
    case outOfBounds = "out_of_bounds"
    case depthInvalid = "depth_invalid"
}

public struct DepthSample: Sendable, Equatable {
    /// Metres along the optical axis.
    public let depth: Float
    /// Samples that passed validity and confidence checks (before clustering).
    public let validSamples: Int
}

public struct DepthSampler: Sendable {
    /// Window half-size in depth pixels: 1 -> 3x3.
    public var radius = 1
    /// Minimum `ARConfidenceLevel` raw value accepted (2 = high).
    public var minConfidence: UInt8 = 2
    /// Fewer valid samples than this -> failure.
    public var minValidSamples = 3
    /// Samples farther than this behind the nearest one belong to the background (e.g. table).
    public var clusterWindow: Float = 0.02

    public init() {}

    /// Median depth of the nearest cluster around `pixel` (depth-map pixels, origin top-left).
    public func sample(_ image: DepthImage, at pixel: SIMD2<Float>) -> Result<DepthSample, DepthSampleFailure> {
        let cx = Int(pixel.x.rounded())
        let cy = Int(pixel.y.rounded())
        guard (0..<image.width).contains(cx), (0..<image.height).contains(cy) else {
            return .failure(.outOfBounds)
        }

        var values: [Float] = []
        for y in max(0, cy - radius)...min(image.height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(image.width - 1, cx + radius) {
                let i = y * image.width + x
                let d = image.depth[i]
                guard d.isFinite, d > 0 else { continue }
                if let conf = image.confidence, conf[i] < minConfidence { continue }
                values.append(d)
            }
        }
        guard values.count >= minValidSamples else { return .failure(.depthInvalid) }

        values.sort()
        let nearest = values.filter { $0 <= values[0] + clusterWindow }
        return .success(DepthSample(depth: Stats.median(nearest)!, validSamples: values.count))
    }
}
