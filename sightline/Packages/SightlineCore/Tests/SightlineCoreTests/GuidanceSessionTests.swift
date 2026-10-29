// labels: testing, needs-review
import Testing
import simd
@testable import SightlineCore

@Suite struct HandModelTests {
    @Test func palmCentreIsMeanOfPalmJoints() {
        let h = HandKeypoints(joints: [.wrist: [0, 0, 0], .middleMCP: [0, 0, -0.1], .indexTip: [1, 1, 1]])
        #expect(h.palmCentre == SIMD3<Float>(0, 0, -0.05))
        #expect(h.reference == SIMD3<Float>(0, 0, -0.05))
        #expect(h.keypointCount == 2)
    }

    @Test func fallsBackToFingertipsWithoutPalm() {
        let h = HandKeypoints(joints: [.indexTip: [0, 0, 0], .thumbTip: [0.02, 0, 0], .wrist: [5, 5, 5]])
        #expect(h.palmCentre == nil)
        #expect(h.reference == SIMD3<Float>(0.01, 0, 0))
    }
}

@Suite struct GuidanceSessionTests {
    static let camera = matrix_identity_float4x4

    @Test func openingSaysWhereAndAsksForHand() {
        let s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.5], cameraTransform: Self.camera, time: 0)
        // 31° to the right: turn to face it before reaching (2026-10-29).
        #expect(s.opening.map(\.text) == ["Found the phone. It's to your right, about 60 centimetres.",
                                          "Turn a little to your right, to face it.",
                                          "Hold your hand out in front of you, toward it."])
    }

    @Test func noTurnWhenAhead() {
        let s = GuidanceSession(targetName: "phone", target: [0.1, 0, -0.5], cameraTransform: Self.camera, time: 0)
        #expect(s.opening.count == 2)
        #expect(GuidanceSession.faceLine(goal: [-0.5, 0, -0.5], cameraTransform: Self.camera) == "Turn a little to your left, to face it.")
    }

    @Test func handPromptRepeatsOnlyAfterSpeechEnds() {
        var s = GuidanceSession(targetName: "cup", target: [0, 0, -0.5], cameraTransform: Self.camera, time: 0)
        var said = 0
        for i in 1...300 {  // 10 s, speaking for the first 5 s
            let t = Double(i) / 30
            said += s.update(time: t, hand: nil, cameraTransform: Self.camera, targetDepthDelta: nil, speaking: t < 5).lines.count
        }
        #expect(said == 0)  // 7 s gap counts from t = 5
        for i in 301...400 {
            said += s.update(time: Double(i) / 30, hand: nil, cameraTransform: Self.camera, targetDepthDelta: nil, speaking: false).lines.count
        }
        #expect(said == 1)
    }

    @Test func jitteryStillHandGetsAnInstruction() {
        var s = GuidanceSession(targetName: "cup", target: [0.3, 0, -0.5], cameraTransform: Self.camera, time: 0)
        var lines: [String] = []
        for i in 1...120 {
            let jitter: Float = i % 2 == 0 ? 0.005 : -0.005
            let hand = HandKeypoints(joints: [.wrist: [jitter, 0, -0.3], .middleMCP: [0, jitter, -0.38]])
            lines += s.update(time: Double(i) / 30, hand: hand, cameraTransform: Self.camera,
                              targetDepthDelta: 0, speaking: false).lines.map(\.text)
        }
        #expect(lines.contains("I see your hand."))
        #expect(lines.contains { $0.hasPrefix("Right, about") })
    }
}
