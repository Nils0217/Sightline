// labels: testing, needs-review
// v9.1 (2026-10-31): the check trigger is object-centred, distances follow the user's body, and the
// record-only spot evidence classifies what LiDAR sees where the target was.
import Foundation
import simd
import Testing
@testable import SightlineCore

@Suite struct PickupTriggerTests {
    let object = ObjectModel(points: [SIMD3(0, 0.01, -0.5), SIMD3(0.05, 0.01, -0.5), SIMD3(0, 0.01, -0.55)],
                             supportHeight: 0, isFlat: true)

    func hand(_ tip: SIMD3<Float>) -> HandKeypoints {
        HandKeypoints(joints: [.indexTip: tip, .thumbTip: tip + SIMD3(-0.03, 0, 0.03),
                               .wrist: tip + SIMD3(0, 0.08, 0.12), .middleMCP: tip + SIMD3(0, 0.08, 0.05)])
    }

    func run(_ s: inout GuidanceSession, _ tips: [SIMD3<Float>?], t: inout Double) -> [String] {
        var reasons: [String] = []
        for p in tips {
            t += 1.0 / 30
            let out = s.update(time: t, hand: p.map(hand), cameraTransform: downCamera, targetDepthDelta: 0.2, speaking: false)
            if out.requestCheck { reasons.append(out.checkReason ?? "?") }
        }
        return reasons
    }

    /// Nils, 2026-10-31: a hand put down on the table and lifted again, without reaching the object,
    /// must not count as picking something up (v9 LiftDetector fired on palm height alone).
    @Test func handOnTheTableAwayFromTheObjectDoesNotTrigger() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let onTable = object.centre + SIMD3(0.25, 0.01, 0.05)
        let lifted = onTable + SIMD3(0, 0.25, 0)
        let path = Array(repeating: lifted, count: 30) + Array(repeating: onTable, count: 40) + Array(repeating: lifted, count: 40)
        var t = 0.0
        #expect(run(&s, path, t: &t).isEmpty)
    }

    /// A fingertip stays at the object, then the hand leaves: one check, then none until it comes back.
    @Test func contactThenLeavingChecksOnce() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        let near = object.centre + SIMD3(0, 0.015, 0)
        var t = 0.0
        #expect(run(&s, Array(repeating: far, count: 40) + Array(repeating: near, count: 15) + Array(repeating: far, count: 20), t: &t).count == 1)
        _ = s.resolveCheck(nil, time: t)
        #expect(run(&s, Array(repeating: far, count: 60), t: &t).isEmpty)
    }

    /// Contact candidate, then the hand vanishes (hidden by what it holds): check after 1.5 s.
    @Test func contactThenHandHiddenChecks() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        let near = object.centre + SIMD3(0, 0.015, 0)
        var t = 0.0
        let reasons = run(&s, Array(repeating: far, count: 40) + Array(repeating: near, count: 15)
                          + Array(repeating: nil, count: 60), t: &t)
        #expect(reasons.contains("near_then_lost") || reasons.contains("left_object"))
    }

    /// A tall object lifted straight up keeps the fingertips inside its old outline: contact, then a rise.
    @Test func contactThenRiseChecks() {
        let bottle = ObjectModel(points: (0..<10).map { SIMD3(0, Float($0) * 0.025, -0.5) }, supportHeight: 0, isFlat: false)
        var s = GuidanceSession(targetName: "bottle", target: bottle.centre, object: bottle, cameraTransform: downCamera, time: 0)
        let far = bottle.centre + SIMD3(0.25, 0.1, 0.2)
        let side = SIMD3<Float>(0.015, 0.06, -0.5)
        var t = 0.0
        let path: [SIMD3<Float>?] = Array(repeating: far, count: 40) + Array(repeating: side, count: 15)
            + (1...20).map { side + SIMD3(0, Float($0) * 0.006, 0) } + Array(repeating: side + SIMD3(0, 0.12, 0), count: 15)
        #expect(run(&s, path, t: &t).contains("near_then_rose"))
    }

    /// The hand stays put while "Keep going" repeats: they may already hold it (hidden while gripping).
    /// v9.2 (Nils): look again with one check photo, which also sees whether it is still at its spot.
    @Test func stalledHandIsCheckedOnce() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let stuck = object.centre + SIMD3(0.2, 0.05, 0)
        var t = 0.0
        var reasons: [String] = []
        for i in 0..<1200 {  // 40 s, the hand creeping 1 mm per frame for 0.2 s after each cue, then stopping
            t += 1.0 / 30
            let p = stuck + SIMD3(Float(i % 90 < 6 ? -0.001 * Double(i % 90) : 0), 0, 0)
            let out = s.update(time: t, hand: hand(p), cameraTransform: downCamera, targetDepthDelta: 0, speaking: false)
            if out.requestCheck { reasons.append(out.checkReason ?? "") }
        }
        #expect(reasons == ["stalled"])
    }

    /// The spot going empty (LiDAR now sees the table where a 10 cm box stood) checks, with no hand seen.
    @Test func emptySpotChecks() {
        let box = ObjectModel(points: (0..<10).map { SIMD3(0, Float($0) * 0.01, -0.5) }, supportHeight: 0, isFlat: false)
        var s = GuidanceSession(targetName: "box", target: box.centre, object: box, cameraTransform: downCamera, time: 0)
        var t = 0.0
        var reasons: [String] = []
        let far = box.centre + SIMD3(0.25, 0.1, 0.2)
        for i in 0..<120 {
            t += 1.0 / 30
            let delta: Float = i < 60 ? 0 : 0.09  // full, then the table behind it
            let out = s.update(time: t, hand: i < 40 ? hand(far) : nil, cameraTransform: downCamera, targetDepthDelta: delta, speaking: false)
            if out.requestCheck { reasons.append(out.checkReason ?? "") }
        }
        #expect(reasons == ["spot_empty"])
    }

    /// Never seen full (the lock centre's pixel shows the table behind): no "gone" check from the start.
    @Test func spotNeverSeenFullDoesNotCheck() {
        let box = ObjectModel(points: (0..<10).map { SIMD3(0, Float($0) * 0.01, -0.5) }, supportHeight: 0, isFlat: false)
        var s = GuidanceSession(targetName: "box", target: box.centre, object: box, cameraTransform: downCamera, time: 0)
        var t = 0.0
        for _ in 0..<90 {
            t += 1.0 / 30
            let out = s.update(time: t, hand: hand(box.centre + SIMD3(0.25, 0.1, 0.2)), cameraTransform: downCamera,
                               targetDepthDelta: 0.09, speaking: false)
            #expect(!out.requestCheck)
        }
    }

    /// Hand gone a while: the second time it asks for help talking (the app listens and Spark answers).
    @Test func handGoneAsksOnce() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        var t = 0.0
        var asks = 0
        var lines: [String] = []
        for i in 0..<1500 {
            t += 1.0 / 30
            let out = s.update(time: t, hand: i < 60 ? hand(far) : nil, cameraTransform: downCamera, targetDepthDelta: nil, speaking: false)
            if out.askAboutHand { asks += 1 }
            lines += out.lines.map(\.text)
        }
        #expect(asks == 1)
        #expect(lines.first { $0.contains("see your hand") && !$0.hasPrefix("I see") } == "I can't see your hand.")
        #expect(lines.contains("I need to see your hand to guide you."))
    }

    /// Hand lost without ever reaching the object: no check.
    @Test func handHiddenWithoutContactDoesNotTrigger() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        var t = 0.0
        #expect(run(&s, Array(repeating: far, count: 40) + Array(repeating: nil, count: 90), t: &t).isEmpty)
    }
}

@Suite struct BodyScaleTests {
    @Test func referenceUserKeepsTheWrittenValues() {
        let s = BodyScale()
        #expect(s.arm(0.10) == 0.10 && s.handSized(0.04) == 0.04)
    }

    @Test func longerReachAndBiggerHandScaleUp() {
        let s = BodyScale(reach: 0.65, hand: 0.20)
        #expect(abs(s.arm(0.10) - 0.125) < 0.0001)
        #expect(abs(s.handSized(0.04) - 0.0444) < 0.0001)
    }

    @Test func absurdMeasurementsAreBounded() {
        let s = BodyScale(reach: 2, hand: 0.01)
        #expect(abs(s.arm(0.10) - 0.15) < 0.0001)
        #expect(abs(s.handSized(0.04) - 0.024) < 0.0001)
    }

    @Test func sessionUsesTheScale() {
        let small = GuidanceSession(targetName: "cup", target: [0, 0, -0.4], cameraTransform: matrix_identity_float4x4, time: 0,
                                    scale: BodyScale(reach: 0.39, hand: 0.15))
        #expect(abs(small.leaveDistance - 0.075) < 0.0001)
        #expect(abs(small.nearDistance - 0.0333) < 0.0001)
    }

    @Test func calibrationMeasuresTheHand() {
        var c = ReachCalibration()
        var reach: Float?
        for i in 0..<40 {
            reach = c.update(time: Double(i) / 30, fingertip: [0, 0, -0.55], camera: .zero, wrist: [0, 0.02, -0.37])
        }
        #expect(abs((reach ?? 0) - 0.52) < 0.001)
        #expect(abs((c.handLength ?? 0) - 0.1811) < 0.001)
    }
}

@Suite struct SpotEvidenceTests {
    func samples(_ measured: Float?, n: Int = 40, thickness: Float? = 0.03, confidence: UInt8 = 2) -> [SpotEvidence.Sample] {
        (0..<n).map { _ in SpotEvidence.Sample(expected: 0.5, measured: measured, confidence: confidence, thickness: thickness) }
    }

    @Test func sameDepthIsPresent() { #expect(SpotEvidence.classify(samples(0.505)).state == .present) }
    @Test func tableBehindIsVacated() { #expect(SpotEvidence.classify(samples(0.53)).state == .vacated) }
    @Test func handInFrontIsUnknown() {
        let e = SpotEvidence.classify(samples(0.40))
        #expect(e.state == .unknown && e.occluded == 40)
    }
    @Test func thinObjectsCannotBeTold() {
        let e = SpotEvidence.classify(samples(0.53, thickness: 0.008))
        #expect(e.state == .unknown && e.invalid == 40)
    }
    @Test func lowConfidenceIsNotUsed() { #expect(SpotEvidence.classify(samples(0.53, confidence: 0)).state == .unknown) }
    @Test func mixedIsUnknown() {
        #expect(SpotEvidence.classify(samples(0.505, n: 20) + samples(0.53, n: 20)).state == .unknown)
    }
}
