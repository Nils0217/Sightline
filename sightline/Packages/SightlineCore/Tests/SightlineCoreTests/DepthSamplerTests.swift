// labels: testing, needs-review
import Testing
@testable import SightlineCore

/// 5x5 depth image filled with `fill`, then overridden per (x, y).
func image(fill: Float, conf: UInt8 = 2, overrides: [(Int, Int, Float, UInt8)] = []) -> DepthImage {
    var d = [Float](repeating: fill, count: 25)
    var c = [UInt8](repeating: conf, count: 25)
    for (x, y, v, cv) in overrides {
        d[y * 5 + x] = v
        c[y * 5 + x] = cv
    }
    return DepthImage(width: 5, height: 5, depth: d, confidence: c)
}

@Suite struct DepthSamplerTests {
    let sampler = DepthSampler()

    @Test func uniformSurface() throws {
        let s = try sampler.sample(image(fill: 0.5), at: SIMD2(2, 2)).get()
        #expect(s.depth == 0.5)
        #expect(s.validSamples == 9)
    }

    @Test func allInvalidFails() {
        #expect(sampler.sample(image(fill: .nan), at: SIMD2(2, 2)) == .failure(.depthInvalid))
        #expect(sampler.sample(image(fill: 0), at: SIMD2(2, 2)) == .failure(.depthInvalid))
    }

    @Test func tooFewHighConfidenceFails() {
        let img = image(fill: 0.5, conf: 1, overrides: [(2, 2, 0.5, 2), (1, 2, 0.5, 2)])
        #expect(sampler.sample(img, at: SIMD2(2, 2)) == .failure(.depthInvalid))
    }

    @Test func lowConfidenceSamplesAreIgnored() throws {
        // Centre is a low-confidence outlier; the 8 high-confidence neighbours win.
        let img = image(fill: 0.5, overrides: [(2, 2, 0.1, 0)])
        let s = try sampler.sample(img, at: SIMD2(2, 2)).get()
        #expect(s.depth == 0.5)
        #expect(s.validSamples == 8)
    }

    @Test func fingerInFrontOfTablePicksNearestCluster() throws {
        // Finger at 0.45 m covers 4 of 9 pixels; the table behind is 0.50 m.
        let finger: [(Int, Int, Float, UInt8)] = [(2, 2, 0.45, 2), (2, 1, 0.452, 2), (1, 2, 0.448, 2), (1, 1, 0.451, 2)]
        let s = try sampler.sample(image(fill: 0.5, overrides: finger), at: SIMD2(2, 2)).get()
        #expect(abs(s.depth - 0.4505) < 1e-4)
        #expect(s.validSamples == 9)
    }

    @Test func outOfBoundsFails() {
        #expect(sampler.sample(image(fill: 0.5), at: SIMD2(-1, 2)) == .failure(.outOfBounds))
        #expect(sampler.sample(image(fill: 0.5), at: SIMD2(2, 5)) == .failure(.outOfBounds))
    }

    @Test func cornerUsesClippedWindow() throws {
        let s = try sampler.sample(image(fill: 0.6), at: SIMD2(0, 0)).get()
        #expect(s.validSamples == 4)
    }

    @Test func missingConfidenceMapTreatsAllAsHigh() throws {
        let img = DepthImage(width: 3, height: 3, depth: [Float](repeating: 0.7, count: 9))
        #expect(try sampler.sample(img, at: SIMD2(1, 1)).get().depth == 0.7)
    }
}
