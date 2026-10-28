// labels: testing, needs-review
import simd
import Testing
@testable import SightlineCore

@Suite struct MaskTargetTests {
    @Test func portraitMappingMatchesVisionRightOrientation() {
        let rawSize = SIMD2<Float>(1920, 1440)
        for a: Float in [0.1, 0.5, 0.8] {
            for b: Float in [0.2, 0.6, 0.9] {
                let raw = DepthProjector.rawPixel(fromVision: SIMD2(a, 1 - b), orientation: .right, rawSize: rawSize)
                let p = MaskTarget.portraitNormalized(fromRawNormalized: raw / rawSize)
                #expect(abs(p.x - a) < 1e-5 && abs(p.y - b) < 1e-5)
            }
        }
    }

    /// Landscape 40x30 depth map: table at 1.0 m, object at 0.8 m in raw i 10..<20, j 5..<15.
    /// Portrait source image is 30x40, so the object is at source x 15...24, y 10...19.
    func scene(objectConfidence: UInt8 = 2) -> (DepthImage, SourceMask, CameraIntrinsics) {
        var d = [Float](repeating: 1.0, count: 40 * 30)
        var c = [UInt8](repeating: 2, count: 40 * 30)
        for j in 5..<15 { for i in 10..<20 { d[j * 40 + i] = 0.8; c[j * 40 + i] = objectConfidence } }
        let record = SAMRecord(id: "0", left: 15, top: 10, right: 25, bottom: 20, sourceWidth: 30, sourceHeight: 40,
                               confidence: 0.9, maskWidth: 10, maskHeight: 10, payload: "")
        let mask = SourceMask(record: record, raster: [UInt8](repeating: 1, count: 100))
        let k = CameraIntrinsics(fx: 30, fy: 30, cx: 19.5, cy: 14.5, imageSize: SIMD2(40, 30))
        return (DepthImage(width: 40, height: 30, depth: d, confidence: c), mask, k)
    }

    @Test func targetReprojectsInsideItsMask() throws {
        let (depth, mask, k) = scene()
        let r = try MaskTarget.locate(mask: mask, depth: depth, intrinsics: k, erosion: 1).get()
        let check = try #require(MaskTarget.reprojectsInside(cameraPoint: r.cameraPoint, mask: mask, intrinsics: k))
        #expect(check.inside)
        #expect(abs(check.pixel.x - 20) < 1 && abs(check.pixel.y - 15) < 1)
        // A point 20 cm to the camera's right lands outside.
        let off = try #require(MaskTarget.reprojectsInside(cameraPoint: r.cameraPoint + SIMD3(0.2, 0, 0), mask: mask, intrinsics: k))
        #expect(!off.inside)
    }

    @Test func locatesObjectCentreAtObjectDepth() throws {
        let (depth, mask, k) = scene()
        let r = try MaskTarget.locate(mask: mask, depth: depth, intrinsics: k, erosion: 1).get()
        // Eroded mask keeps raw i 11...18, j 6...13 -> median pixel (14.5, 9.5).
        let want = DepthProjector.unproject(pixel: SIMD2(14.5, 9.5), depth: 0.8, intrinsics: k)
        #expect(simd_distance(r.cameraPoint, want) < 1e-5)
        #expect(r.samples == 64)
        #expect(r.depthSpread < 1e-6)
    }

    @Test func erosionKeepsTableDepthOut() throws {
        // Without erosion the mask still only covers object pixels here, so spread stays 0;
        // with a mask one pixel too big the edge would pull in table depth.
        let (depth, mask, k) = scene()
        let bigger = SourceMask(record: SAMRecord(id: "0", left: 14, top: 9, right: 26, bottom: 21, sourceWidth: 30,
                                                  sourceHeight: 40, confidence: nil, maskWidth: 12, maskHeight: 12,
                                                  payload: ""), raster: [UInt8](repeating: 1, count: 144))
        let loose = try MaskTarget.locate(mask: bigger, depth: depth, intrinsics: k, erosion: 0).get()
        let tight = try MaskTarget.locate(mask: bigger, depth: depth, intrinsics: k, erosion: 2).get()
        #expect(loose.depthSpread > 0.1)
        #expect(tight.depthSpread < 1e-6)
        _ = mask
    }

    @Test func lowConfidenceDepthFails() {
        let (depth, mask, k) = scene(objectConfidence: 0)
        #expect(MaskTarget.locate(mask: mask, depth: depth, intrinsics: k, erosion: 1) == .failure(.tooFewDepthSamples))
    }

    @Test func maskOutsideViewFails() {
        let (depth, _, k) = scene()
        let record = SAMRecord(id: "0", left: 0, top: 0, right: 1, bottom: 1, sourceWidth: 3000, sourceHeight: 4000,
                               confidence: nil, maskWidth: 1, maskHeight: 1, payload: "")
        let tiny = SourceMask(record: record, raster: [1])
        #expect(MaskTarget.locate(mask: tiny, depth: depth, intrinsics: k) == .failure(.emptyMask))
    }

    @Test func centroidOfSquare() {
        let (_, mask, _) = scene()
        #expect(mask.centroid == SIMD2(20, 15))
    }
}
