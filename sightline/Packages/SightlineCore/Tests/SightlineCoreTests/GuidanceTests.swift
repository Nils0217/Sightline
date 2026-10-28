// labels: testing, needs-review
import simd
import Testing
@testable import SightlineCore

@Suite struct GuidanceTests {
    /// Camera at origin looking along world −z (portrait on the chest, level).
    let level = matrix_identity_float4x4

    @Test func bodyFrameFromLevelCamera() {
        let o = BodyOffset(from: .zero, to: SIMD3(0.1, 0.2, -0.3), cameraTransform: level)
        #expect(abs(o.right - 0.1) < 1e-6 && abs(o.up - 0.2) < 1e-6 && abs(o.forward - 0.3) < 1e-6)
    }

    @Test func bodyFrameIgnoresCameraPitch() {
        // Pitched 30° down: forward stays horizontal.
        let pitched = simd_float4x4(simd_quatf(angle: -.pi / 6, axis: SIMD3(1, 0, 0)))
        let o = BodyOffset(from: .zero, to: SIMD3(0, 0, -0.5), cameraTransform: pitched)
        #expect(abs(o.forward - 0.5) < 1e-5 && abs(o.up) < 1e-5 && abs(o.right) < 1e-5)
    }

    @Test func bodyFrameTurnedLeft() {
        // Turned 90° left: world −x is forward, world −z is right.
        let turned = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        let o = BodyOffset(from: .zero, to: SIMD3(-0.4, 0, -0.1), cameraTransform: turned)
        #expect(abs(o.forward - 0.4) < 1e-5 && abs(o.right - 0.1) < 1e-5)
    }

    @Test func largestLateralFirst() {
        let cue = GuidanceController.moveCue(BodyOffset(right: -0.12, up: 0.05, forward: 0.2), tolerance: 0.03)
        #expect(cue.phrase == "Left, 10 centimetres.")
    }

    @Test func forwardOnlyWhenAligned() {
        let cue = GuidanceController.moveCue(BodyOffset(right: 0.02, up: -0.01, forward: 0.27), tolerance: 0.03)
        #expect(cue.phrase == "Forward, 25 centimetres.")
    }

    @Test func smallCorrectionsAreVague() {
        let cue = GuidanceController.moveCue(BodyOffset(right: 0, up: -0.05, forward: 0.06), tolerance: 0.03)
        #expect(cue.phrase == "A little lower.")
    }

    @Test func grabAfterHold() {
        var g = GuidanceController()
        let near = BodyOffset(right: 0.01, up: 0.01, forward: 0.02)
        let r1 = g.update(time: 0, offset: near, targetName: "cup")

        #expect(r1 == nil)
        let r2 = g.update(time: 0.2, offset: near, targetName: "cup")

        #expect(r2 == nil)
        let r3 = g.update(time: 0.35, offset: near, targetName: "cup")

        #expect(r3?.kind == .grab)
    }

    @Test func leavingResetsGrabTimer() {
        var g = GuidanceController()
        let near = BodyOffset(right: 0.01, up: 0, forward: 0)
        _ = g.update(time: 0, offset: near, targetName: "cup")
        let r4 = g.update(time: 0.2, offset: BodyOffset(right: 0.2, up: 0, forward: 0), targetName: "cup")
        #expect(r4?.kind == .move)
        let r5 = g.update(time: 0.4, offset: near, targetName: "cup")

        #expect(r5 == nil)
    }

    @Test func noHandAfterGrace() {
        var g = GuidanceController()
        _ = g.update(time: 0, offset: BodyOffset(right: 0.2, up: 0, forward: 0), targetName: "cup")
        let r6 = g.update(time: 0.5, offset: nil, targetName: "cup")

        #expect(r6 == nil)
        let r7 = g.update(time: 1.1, offset: nil, targetName: "cup")

        #expect(r7?.kind == .noHand)
    }

    @Test func throttle() {
        var t = SpeechThrottle()
        let a = GuidanceCue(kind: .move, phrase: "Right, 10 centimetres.", key: "Right-10")
        let b = GuidanceCue(kind: .move, phrase: "Higher, 5 centimetres.", key: "Higher-5")
        let grab = GuidanceCue(kind: .grab, phrase: "Now grab.", key: "grab")
        let r8 = t.shouldSpeak(a, time: 0, speaking: false)

        #expect(r8)
        let r9 = t.shouldSpeak(b, time: 0.5, speaking: false)

        #expect(!r9)   // too soon
        let r10 = t.shouldSpeak(b, time: 1.5, speaking: true)

        #expect(!r10)    // still talking
        let r11 = t.shouldSpeak(b, time: 1.5, speaking: false)

        #expect(r11)
        let r12 = t.shouldSpeak(b, time: 3.0, speaking: false)

        #expect(!r12)   // same cue, not yet repeated
        let r13 = t.shouldSpeak(b, time: 4.6, speaking: false)

        #expect(r13)
        let r14 = t.shouldSpeak(grab, time: 4.7, speaking: true)

        #expect(r14)  // grab interrupts
        let r15 = t.shouldSpeak(grab, time: 6, speaking: false)

        #expect(!r15)  // said once
    }

    @Test func describeTarget() {
        let s = GuidanceController.describe(target: SIMD3(0.15, -0.3, -0.42), cameraTransform: level, name: "cup")
        #expect(s == "Found the cup, about 40 centimetres ahead, to your right.")
    }

    @Test func tones() {
        #expect(ProximityTone.interval(distance: 0.7) == nil)
        #expect(ProximityTone.interval(distance: 0.04)! < ProximityTone.interval(distance: 0.3)!)
        #expect(abs(ProximityTone.frequency(distance: 0.04) - 880) < 0.01)
        #expect(abs(ProximityTone.frequency(distance: 0.6) - 440) < 0.01)
    }
}
