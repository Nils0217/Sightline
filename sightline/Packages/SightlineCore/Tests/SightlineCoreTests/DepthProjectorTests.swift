// labels: testing, needs-review
import Testing
import simd
@testable import SightlineCore

/// Roughly iPhone 15 Pro wide camera at ARKit's 1920x1440 capture size.
let rawSize = SIMD2<Float>(1920, 1440)
let depthSize = SIMD2<Float>(256, 192)
let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 959.5, cy: 719.5, imageSize: rawSize)

func close(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tol: Float = 1e-3) -> Bool { simd_distance(a, b) <= tol }
func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 1e-4) -> Bool { simd_distance(a, b) <= tol }

@Suite struct ProjectionTests {
    static let pixels: [SIMD2<Float>] = [
        SIMD2(959.5, 719.5),               // centre
        SIMD2(0, 0), SIMD2(1919, 0),       // corners
        SIMD2(0, 1439), SIMD2(1919, 1439),
        SIMD2(959.5, 0), SIMD2(0, 719.5),  // edges
    ]

    @Test(arguments: pixels, [Float(0.3), 0.5, 1.0])
    func unprojectThenProjectRoundTrips(pixel: SIMD2<Float>, depth: Float) throws {
        let c = DepthProjector.unproject(pixel: pixel, depth: depth, intrinsics: k)
        #expect(abs(-c.z - depth) < 1e-6)
        let back = try #require(DepthProjector.project(cameraPoint: c, intrinsics: k))
        #expect(close(back, pixel))
    }

    @Test func centrePixelLiesOnOpticalAxis() {
        let c = DepthProjector.unproject(pixel: SIMD2(959.5, 719.5), depth: 0.5, intrinsics: k)
        #expect(close(c, SIMD3(0, 0, -0.5)))
    }

    @Test func imageAxesMapToCameraAxes() {
        // Right of centre -> +x; below centre (image y down) -> -y.
        let right = DepthProjector.unproject(pixel: SIMD2(1259.5, 719.5), depth: 1, intrinsics: k)
        #expect(close(right, SIMD3(0.2, 0, -1)))
        let below = DepthProjector.unproject(pixel: SIMD2(959.5, 1019.5), depth: 1, intrinsics: k)
        #expect(close(below, SIMD3(0, -0.2, -1)))
    }

    @Test func pointBehindCameraDoesNotProject() {
        #expect(DepthProjector.project(cameraPoint: SIMD3(0, 0, 0.5), intrinsics: k) == nil)
    }
}

@Suite struct IntrinsicsTests {
    @Test func scalesToDepthResolution() {
        let d = k.scaled(to: depthSize)
        #expect(abs(d.fx - 200) < 1e-3)
        #expect(abs(d.fy - 200) < 1e-3)
        // (959.5 + 0.5) * 256/1920 - 0.5 = 127.5 : still the centre of a 256-wide image.
        #expect(abs(d.cx - 127.5) < 1e-3)
        #expect(abs(d.cy - 95.5) < 1e-3)
    }

    @Test(arguments: [SIMD3<Float>(0.05, -0.1, -0.4), SIMD3(-0.2, 0.15, -0.8)])
    func samePointLandsOnMatchingPixelAtBothResolutions(point: SIMD3<Float>) throws {
        let d = k.scaled(to: depthSize)
        let hi = try #require(DepthProjector.project(cameraPoint: point, intrinsics: k))
        let lo = try #require(DepthProjector.project(cameraPoint: point, intrinsics: d))
        let s = depthSize / rawSize
        #expect(close(lo, (hi + 0.5) * s - 0.5))
    }

    @Test func readsARKitColumnMajorMatrix() {
        let m = simd_float3x3(columns: (SIMD3(1500, 0, 0), SIMD3(0, 1490, 0), SIMD3(950, 715, 1)))
        let parsed = CameraIntrinsics(matrix: m, imageSize: rawSize)
        #expect(parsed == CameraIntrinsics(fx: 1500, fy: 1490, cx: 950, cy: 715, imageSize: rawSize))
    }
}

@Suite struct VisionOrientationTests {
    @Test func upFlipsYOnly() {
        // Vision bottom-left -> raw bottom-left pixel.
        #expect(close(DepthProjector.rawPixel(fromVision: SIMD2(0, 0), orientation: .up, rawSize: rawSize), SIMD2(0, 1440)))
        #expect(close(DepthProjector.rawPixel(fromVision: SIMD2(1, 1), orientation: .up, rawSize: rawSize), SIMD2(1920, 0)))
    }

    @Test func rightRotatesPortraitCorners() {
        // Portrait image = raw rotated 90° CW, so portrait top-left is raw bottom-left,
        // portrait top-right is raw top-left, portrait bottom-left is raw bottom-right.
        let r = { (p: SIMD2<Float>) in DepthProjector.rawPixel(fromVision: p, orientation: .right, rawSize: rawSize) }
        #expect(close(r(SIMD2(0, 1)), SIMD2(0, 1440)))     // top-left
        #expect(close(r(SIMD2(1, 1)), SIMD2(0, 0)))        // top-right
        #expect(close(r(SIMD2(0, 0)), SIMD2(1920, 1440)))  // bottom-left
        #expect(close(r(SIMD2(1, 0)), SIMD2(1920, 0)))     // bottom-right
        #expect(close(r(SIMD2(0.5, 0.5)), SIMD2(960, 720)))
    }

    @Test(arguments: [VisionOrientation.up, .right],
          [SIMD2<Float>(0.1, 0.2), SIMD2(0.5, 0.5), SIMD2(0.93, 0.07)])
    func visionToRawRoundTrips(orientation: VisionOrientation, p: SIMD2<Float>) {
        let raw = DepthProjector.rawPixel(fromVision: p, orientation: orientation, rawSize: rawSize)
        let back = DepthProjector.visionPoint(fromRawPixel: raw, orientation: orientation, rawSize: rawSize)
        #expect(close(back, p, 1e-6))
    }
}

@Suite struct WorldTransformTests {
    /// Camera at (1, 2, 3), rotated 90° about world y (camera -z looks along world -x).
    static let transform: simd_float4x4 = {
        var t = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        t.columns.3 = SIMD4(1, 2, 3, 1)
        return t
    }()

    @Test func identityKeepsCameraPoint() {
        let w = DepthProjector.world(fromCamera: SIMD3(0.1, 0.2, -0.5), cameraTransform: matrix_identity_float4x4)
        #expect(close(w, SIMD3(0.1, 0.2, -0.5)))
    }

    @Test func rotatedAndTranslatedCamera() {
        // 0.5 m in front of a camera looking along world -x.
        let w = DepthProjector.world(fromCamera: SIMD3(0, 0, -0.5), cameraTransform: Self.transform)
        #expect(close(w, SIMD3(0.5, 2, 3)))
    }

    @Test(arguments: [SIMD3<Float>(0.3, -0.1, -0.6), SIMD3(-0.05, 0.4, -1.2)])
    func worldRoundTrips(c: SIMD3<Float>) {
        let w = DepthProjector.world(fromCamera: c, cameraTransform: Self.transform)
        #expect(close(DepthProjector.camera(fromWorld: w, cameraTransform: Self.transform), c))
    }

    @Test func fullPipelineRoundTrip() throws {
        // Vision point -> raw pixel -> depth pixel -> camera -> world -> back to raw pixel.
        let raw = DepthProjector.rawPixel(fromVision: SIMD2(0.3, 0.6), orientation: .right, rawSize: rawSize)
        let dk = k.scaled(to: depthSize)
        let depthPixel = (raw + 0.5) * (depthSize / rawSize) - 0.5
        let world = DepthProjector.world(
            fromCamera: DepthProjector.unproject(pixel: depthPixel, depth: 0.45, intrinsics: dk),
            cameraTransform: Self.transform)
        let back = try #require(DepthProjector.rawPixel(fromWorld: world, cameraTransform: Self.transform, intrinsics: k))
        #expect(close(back, raw, 1e-2))
    }
}
