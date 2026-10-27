// labels: production, needs-review, important
// Image point -> LiDAR depth -> ARKit world space. Pure math, no ARKit types, so it is
// unit-testable on the Mac. See docs/G1_PLAN.md for the pipeline and conventions.
//
// Conventions
// - Raw image: ARKit `capturedImage`, landscape sensor orientation, pixels, origin top-left, y down.
// - Vision: normalized [0, 1], origin bottom-left, in the space of the orientation passed to Vision.
// - Camera space (ARKit): x right, y up, z backward (toward the viewer), metres, sensor orientation.
// - World space (ARKit): x right, y up, z toward the user, metres.

import simd

/// Pinhole intrinsics in pixels for an image of `imageSize`.
public struct CameraIntrinsics: Sendable, Equatable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var imageSize: SIMD2<Float>

    public init(fx: Float, fy: Float, cx: Float, cy: Float, imageSize: SIMD2<Float>) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.imageSize = imageSize
    }

    /// From `ARCamera.intrinsics` (column-major: fx = [0][0], fy = [1][1], cx = [2][0], cy = [2][1]).
    public init(matrix m: simd_float3x3, imageSize: SIMD2<Float>) {
        self.init(fx: m[0][0], fy: m[1][1], cx: m[2][0], cy: m[2][1], imageSize: imageSize)
    }

    /// Intrinsics for the same camera at another resolution (e.g. 1920x1440 -> 256x192 depth map).
    /// Uses pixel-centre alignment: (c + 0.5) * s - 0.5.
    public func scaled(to newSize: SIMD2<Float>) -> CameraIntrinsics {
        let s = newSize / imageSize
        return CameraIntrinsics(
            fx: fx * s.x,
            fy: fy * s.y,
            cx: (cx + 0.5) * s.x - 0.5,
            cy: (cy + 0.5) * s.y - 0.5,
            imageSize: newSize
        )
    }
}

/// Orientation passed to Vision for the raw landscape `capturedImage`.
public enum VisionOrientation: Sendable {
    /// Raw image as-is (`CGImagePropertyOrientation.up`).
    case up
    /// Portrait phone (`CGImagePropertyOrientation.right`): raw image rotated 90° clockwise.
    case right
}

public enum DepthProjector {

    /// Vision normalized point -> raw `capturedImage` pixel (origin top-left).
    public static func rawPixel(fromVision p: SIMD2<Float>,
                                orientation: VisionOrientation,
                                rawSize: SIMD2<Float>) -> SIMD2<Float> {
        switch orientation {
        case .up:
            return SIMD2(p.x * rawSize.x, (1 - p.y) * rawSize.y)
        case .right:
            // Oriented image is the raw image rotated 90° CW: x_o = H - y_r, y_o = x_r.
            return SIMD2((1 - p.y) * rawSize.x, (1 - p.x) * rawSize.y)
        }
    }

    /// Raw `capturedImage` pixel -> Vision normalized point (inverse of `rawPixel`).
    public static func visionPoint(fromRawPixel q: SIMD2<Float>,
                                   orientation: VisionOrientation,
                                   rawSize: SIMD2<Float>) -> SIMD2<Float> {
        switch orientation {
        case .up:
            return SIMD2(q.x / rawSize.x, 1 - q.y / rawSize.y)
        case .right:
            return SIMD2(1 - q.y / rawSize.y, 1 - q.x / rawSize.x)
        }
    }

    /// Pixel + depth (metres along the optical axis) -> ARKit camera space.
    public static func unproject(pixel: SIMD2<Float>, depth: Float,
                                 intrinsics k: CameraIntrinsics) -> SIMD3<Float> {
        let x = (pixel.x - k.cx) / k.fx * depth
        let y = (pixel.y - k.cy) / k.fy * depth
        // Image y points down and the camera looks along -z in ARKit camera space.
        return SIMD3(x, -y, -depth)
    }

    /// ARKit camera space -> pixel; nil when the point is behind the camera.
    public static func project(cameraPoint c: SIMD3<Float>,
                               intrinsics k: CameraIntrinsics) -> SIMD2<Float>? {
        let depth = -c.z
        guard depth > 0 else { return nil }
        return SIMD2(c.x / depth * k.fx + k.cx, -c.y / depth * k.fy + k.cy)
    }

    /// Camera space -> world space using `ARCamera.transform`.
    public static func world(fromCamera c: SIMD3<Float>, cameraTransform t: simd_float4x4) -> SIMD3<Float> {
        let w = t * SIMD4(c, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    /// World space -> camera space.
    public static func camera(fromWorld w: SIMD3<Float>, cameraTransform t: simd_float4x4) -> SIMD3<Float> {
        let c = t.inverse * SIMD4(w, 1)
        return SIMD3(c.x, c.y, c.z)
    }

    /// World point -> raw image pixel; for drawing the reference centre as a visual check.
    public static func rawPixel(fromWorld w: SIMD3<Float>, cameraTransform t: simd_float4x4,
                                intrinsics k: CameraIntrinsics) -> SIMD2<Float>? {
        project(cameraPoint: camera(fromWorld: w, cameraTransform: t), intrinsics: k)
    }
}
