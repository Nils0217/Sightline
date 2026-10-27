// labels: testing, needs-review
import Testing
import simd
@testable import SightlineCore

@Suite struct DwellDetectorTests {
    let ref = SIMD3<Float>(0, 0, 0)

    /// Feed `seconds` of frames at 30 Hz; returns all captures.
    func run(_ d: inout DwellDetector, from t0: Double, seconds: Double,
             at position: (Double) -> SIMD3<Float>?) -> [SIMD3<Float>] {
        var captures: [SIMD3<Float>] = []
        var t = t0
        while t < t0 + seconds {
            if let c = d.update(time: t, fingertip: position(t), reference: ref) { captures.append(c) }
            t += 1.0 / 30
        }
        return captures
    }

    @Test func stillNearReferenceCapturesOnce() throws {
        var d = DwellDetector()
        let captures = run(&d, from: 0, seconds: 2) { _ in SIMD3(0.01, 0, 0) }
        #expect(captures.count == 1)
        #expect(simd_distance(try #require(captures.first), SIMD3(0.01, 0, 0)) < 1e-6)
    }

    @Test func rearmsOnlyAfterLeaving() {
        var d = DwellDetector()
        #expect(run(&d, from: 0, seconds: 1) { _ in SIMD3(0.01, 0, 0) }.count == 1)
        #expect(run(&d, from: 1, seconds: 0.2) { _ in SIMD3(0.2, 0, 0) }.isEmpty)     // leave
        #expect(run(&d, from: 1.2, seconds: 1) { _ in SIMD3(0.02, 0, 0) }.count == 1)  // second touch
    }

    @Test func movingHandDoesNotCapture() {
        var d = DwellDetector()
        // 2 cm/s drift: more than 5 mm over the 0.5 s window.
        #expect(run(&d, from: 0, seconds: 2) { t in SIMD3(Float(t) * 0.04 - 0.04, 0, 0) }.isEmpty)
    }

    @Test func farFromReferenceDoesNotCapture() {
        var d = DwellDetector()
        #expect(run(&d, from: 0, seconds: 2) { _ in SIMD3(0.15, 0, 0) }.isEmpty)
    }

    @Test func lostTrackingResetsDwell() {
        var d = DwellDetector()
        // Valid for 0.4 s, lost for one frame, valid 0.4 s: never a full 0.5 s window.
        let caps = run(&d, from: 0, seconds: 0.85) { t in (0.4..<0.45).contains(t) ? nil : SIMD3(0.01, 0, 0) }
        #expect(caps.isEmpty)
    }
}

@Suite struct TouchErrorTests {
    @Test func splitsNormalAndInPlane() {
        // Table plane normal = +y. Tip 1 cm above and 2 cm sideways.
        let e = TouchError(tip: SIMD3(0.02, 0.01, 0), reference: .zero, planeNormal: SIMD3(0, 2, 0))
        #expect(abs(e.normal - 0.01) < 1e-6)
        #expect(abs(e.inPlane - 0.02) < 1e-6)
        #expect(abs(e.total - sqrtf(0.0005)) < 1e-6)
    }
}

@Suite struct StatsTests {
    @Test func medianMeanPercentile() {
        let v: [Float] = [5, 1, 3, 2, 4]
        #expect(Stats.median(v) == 3)
        #expect(Stats.mean(v) == 3)
        #expect(Stats.percentile(v, 0.9) == 4.6)
        #expect(Stats.median([1, 2]) == 1.5)
        #expect(Stats.median([]) == nil)
    }

    @Test func gateNeedsMedianAndValidRate() {
        let good = [Float](repeating: 0.02, count: 9)
        #expect(AccuracyReport(errors: good, validEstimates: 90, attempts: 100).passesGate)
        #expect(!AccuracyReport(errors: good, validEstimates: 75, attempts: 100).passesGate)
        #expect(!AccuracyReport(errors: [0.04, 0.05], validEstimates: 100, attempts: 100).passesGate)
        #expect(!AccuracyReport(errors: [], validEstimates: 0, attempts: 0).passesGate)
    }
}
