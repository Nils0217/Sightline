// labels: production, needs-review
// Everything a cloud call needs from one ARFrame, copied out so the frame can be released
// right away (holding ARFrames starves ARKit's buffer pool): upright 512 px JPEG + depth +
// camera pose and intrinsics at that instant.

import ARKit
import CoreImage
import SightlineCore

nonisolated struct FrameSnapshot: Sendable {
    var jpeg: Data
    /// Uploaded image size (portrait), e.g. 384x512.
    var imageSize: SIMD2<Int>
    var depth: DepthImage
    var intrinsics: CameraIntrinsics
    var cameraTransform: simd_float4x4
    var tracking: String
    var timestamp: TimeInterval

    static let longEdge: CGFloat = 512
    private static let context = CIContext()

    enum Failure: String, Error {
        case noDepth = "no_depth"
        case encodeFailed = "encode_failed"
    }

    static func make(from frame: ARFrame, tracking: String) throws(Failure) -> FrameSnapshot {
        guard let depthData = frame.sceneDepth, let depth = DepthImageReader.read(depthData) else { throw .noDepth }
        // Portrait upright = raw rotated 90° CW (`.right`), same as the Vision/G1 pipeline.
        var image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = longEdge / max(image.extent.width, image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = SIMD2(Int(image.extent.width.rounded()), Int(image.extent.height.rounded()))
        guard let jpeg = context.jpegRepresentation(
            of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) else { throw .encodeFailed }
        let res = frame.camera.imageResolution
        return FrameSnapshot(
            jpeg: jpeg, imageSize: size, depth: depth,
            intrinsics: CameraIntrinsics(matrix: frame.camera.intrinsics,
                                         imageSize: SIMD2(Float(res.width), Float(res.height))),
            cameraTransform: frame.camera.transform, tracking: tracking, timestamp: frame.timestamp)
    }
}
