// labels: production, needs-review, important
// SAM mask (on the uploaded portrait image) + LiDAR depth -> one 3D target point in camera space.
// Pure math so it runs under `swift test`. Used by G2 (docs/G2_PLAN.md).
//
// The uploaded image is the raw landscape `capturedImage` rotated 90° clockwise (portrait,
// Vision orientation `.right`), then scaled. We walk the depth map, map each depth pixel to the
// uploaded image, keep pixels well inside the mask, unproject them and take the per-axis median.

import simd

/// A decoded mask placed on the uploaded (source) image.
public struct SourceMask: Sendable {
    public let record: SAMRecord
    public let raster: [UInt8]

    public init(record: SAMRecord, raster: [UInt8]) {
        precondition(raster.count == record.maskWidth * record.maskHeight, "raster size mismatch")
        self.record = record
        self.raster = raster
    }

    /// True when source pixel (x, y) is inside the mask.
    public func contains(_ x: Int, _ y: Int) -> Bool {
        let mx = x - record.left, my = y - record.top
        guard mx >= 0, my >= 0, mx < record.maskWidth, my < record.maskHeight else { return false }
        return raster[my * record.maskWidth + mx] != 0
    }

    /// Mask centroid in source pixels (pixel centres), nil for an empty mask.
    public var centroid: SIMD2<Float>? {
        var sum = SIMD2<Float>.zero, n: Float = 0
        for my in 0..<record.maskHeight {
            for mx in 0..<record.maskWidth where raster[my * record.maskWidth + mx] != 0 {
                sum += SIMD2(Float(record.left + mx) + 0.5, Float(record.top + my) + 0.5)
                n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }
}

public struct MaskTargetResult: Sendable, Equatable {
    /// ARKit camera space, metres.
    public let cameraPoint: SIMD3<Float>
    /// Depth pixels that contributed.
    public let samples: Int
    /// Spread of the contributing depths (P90 − P10), metres; large = mask mixed several surfaces.
    public let depthSpread: Float
}

public enum MaskTargetFailure: String, Error, Sendable {
    case emptyMask = "empty_mask"
    case tooFewDepthSamples = "too_few_depth_samples"
}

public enum MaskTarget {
    /// Portrait-normalized (origin top-left) position of a raw-normalized point, for the `.right` rotation.
    /// Inverse of raw = (b * W, (1 − a) * H) for portrait (a, b).
    public static func portraitNormalized(fromRawNormalized r: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(1 - r.y, r.x)
    }

    /// Raw `capturedImage` pixel -> pixel on the uploaded portrait image (`imageSize`, origin top-left).
    /// Used to draw a 3D point back onto the photo SAM saw (recording / reprojection check).
    public static func portraitPixel(fromRawPixel q: SIMD2<Float>, rawSize: SIMD2<Float>,
                                     imageSize: SIMD2<Float>) -> SIMD2<Float> {
        portraitNormalized(fromRawNormalized: q / rawSize) * imageSize
    }

    /// Does the target point, projected back onto the uploaded image, land inside the mask?
    /// A no means the mask -> 3D step put the target somewhere other than on the object.
    public static func reprojectsInside(cameraPoint: SIMD3<Float>, mask: SourceMask,
                                        intrinsics: CameraIntrinsics) -> (pixel: SIMD2<Float>, inside: Bool)? {
        guard let raw = DepthProjector.project(cameraPoint: cameraPoint, intrinsics: intrinsics) else { return nil }
        let size = SIMD2(Float(mask.record.sourceWidth), Float(mask.record.sourceHeight))
        let p = portraitPixel(fromRawPixel: raw, rawSize: intrinsics.imageSize, imageSize: size)
        return (p, mask.contains(Int(p.x), Int(p.y)))
    }

    /// - Parameters:
    ///   - erosion: a depth pixel counts only if source pixels this far away (in 4 directions) are also
    ///     in the mask; keeps samples off the object edge where depth mixes with the background.
    ///   - minConfidence: lowest `ARConfidenceLevel` raw value accepted.
    public static func locate(mask: SourceMask, depth: DepthImage, intrinsics: CameraIntrinsics,
                              erosion: Int = 3, minConfidence: UInt8 = 1,
                              minSamples: Int = 8) -> Result<MaskTargetResult, MaskTargetFailure> {
        let r = mask.record
        let sw = Float(r.sourceWidth), sh = Float(r.sourceHeight)
        let k = intrinsics.scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        var points: [SIMD3<Float>] = []
        var maskHit = false
        for j in 0..<depth.height {
            for i in 0..<depth.width {
                let rawN = SIMD2((Float(i) + 0.5) / Float(depth.width), (Float(j) + 0.5) / Float(depth.height))
                let p = portraitNormalized(fromRawNormalized: rawN)
                let sx = Int(p.x * sw), sy = Int(p.y * sh)
                guard mask.contains(sx, sy) else { continue }
                maskHit = true
                guard mask.contains(sx - erosion, sy), mask.contains(sx + erosion, sy),
                      mask.contains(sx, sy - erosion), mask.contains(sx, sy + erosion) else { continue }
                let idx = j * depth.width + i
                let d = depth.depth[idx]
                guard d.isFinite, d > 0 else { continue }
                if let c = depth.confidence, c[idx] < minConfidence { continue }
                points.append(DepthProjector.unproject(pixel: SIMD2(Float(i), Float(j)), depth: d, intrinsics: k))
            }
        }
        guard maskHit else { return .failure(.emptyMask) }
        guard points.count >= minSamples else { return .failure(.tooFewDepthSamples) }
        let xs = points.map(\.x), ys = points.map(\.y), zs = points.map(\.z)
        let depths = zs.map { -$0 }
        let spread = (Stats.percentile(depths, 0.9) ?? 0) - (Stats.percentile(depths, 0.1) ?? 0)
        let centre = SIMD3(Stats.median(xs)!, Stats.median(ys)!, Stats.median(zs)!)
        return .success(MaskTargetResult(cameraPoint: centre, samples: points.count, depthSpread: spread))
    }
}
