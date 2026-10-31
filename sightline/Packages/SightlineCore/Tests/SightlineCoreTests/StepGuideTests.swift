// labels: testing, needs-review
import Testing
@testable import SightlineCore

@Suite struct StepGuideTests {
    /// Feeds the same offset every 1/30 s from `from` to `to`; returns the cues spoken.
    func hold(_ g: inout StepGuide, _ o: BodyOffset?, from: Double, to: Double) -> [String] {
        var cues: [String] = []
        var t = from
        while t < to {
            if let c = g.update(time: t, offset: o) { cues.append(c.phrase) }
            t += 1.0 / 30
        }
        return cues
    }

    @Test func instructsOnlyWhenStill() {
        var g = StepGuide()
        let o = BodyOffset(right: 0.2, up: 0, forward: 0.1)
        #expect(hold(&g, o, from: 0, to: 0.5).isEmpty)
        #expect(hold(&g, o, from: 0.5, to: 1.0) == ["Move your hand right, about 20 centimetres."])
    }

    @Test func silentWhileMovingThenStop() {
        var g = StepGuide()
        _ = hold(&g, BodyOffset(right: 0.2, up: 0, forward: 0.1), from: 0, to: 1)
        var cues: [String] = []
        // Hand moves right at 25 cm/s.
        var t = 1.0, r: Float = 0.2
        while r > -0.05 {
            if let c = g.update(time: t, offset: BodyOffset(right: r, up: 0, forward: 0.1)) { cues.append(c.phrase) }
            t += 1.0 / 30
            r -= 0.25 / 30
        }
        #expect(cues == ["Stop."])
    }

    @Test func nextInstructionAfterSettling() {
        var g = StepGuide()
        _ = hold(&g, BodyOffset(right: 0.2, up: 0, forward: 0.15), from: 0, to: 1)
        _ = g.update(time: 1.0, offset: BodyOffset(right: 0.02, up: 0, forward: 0.15))  // jump -> Stop
        let cues = hold(&g, BodyOffset(right: 0.02, up: 0, forward: 0.15), from: 1.05, to: 2.0)
        #expect(cues == ["Move your hand forward, about 15 centimetres."])
    }

    @Test func stalledHandIsReinstructed() {
        var g = StepGuide()
        _ = hold(&g, BodyOffset(right: 0.3, up: 0, forward: 0), from: 0, to: 1)
        let cues = hold(&g, BodyOffset(right: 0.18, up: 0, forward: 0), from: 1, to: 3)
        // Same direction again: no new number, just keep going (2026-10-28 recording).
        #expect(cues == ["Move your hand right, slowly."])
    }

    @Test func grabWhenClose() {
        var g = StepGuide()
        let c = g.update(time: 0, offset: BodyOffset(right: 0.01, up: 0.01, forward: 0.02))
        #expect(c?.kind == .grab)
        #expect(g.state == .grabbing)
        let after = g.update(time: 0.1, offset: BodyOffset(right: 0.3, up: 0, forward: 0))
        #expect(after == nil)
    }

    @Test func noHandIsRareAndDelayed() {
        var g = StepGuide()
        _ = hold(&g, BodyOffset(right: 0.2, up: 0, forward: 0), from: 0, to: 1)
        let cues = hold(&g, nil, from: 1, to: 25)
        // Grace 2.5 s, then at most every 10 s: t≈3.5, 13.5, 23.5.
        #expect(cues.count == 3)
        #expect(hold(&g, nil, from: 25, to: 26).isEmpty)
    }

    @Test func noHandAtStartWaitsToo() {
        var g = StepGuide()
        #expect(hold(&g, nil, from: 0, to: 9).isEmpty)
        #expect(hold(&g, nil, from: 9, to: 11).count == 1)
    }

    @Test func pickupNeedsNearHandAndFartherDepth() {
        var p = PickupDetector()
        var t = 0.0
        // Depth farther but the hand was never near: no pick-up (e.g. object occluded oddly).
        var early = false
        for _ in 0..<30 { early = p.update(time: t, depthDelta: 0.1, handDistance: 0.5) || early; t += 1.0 / 30 }
        #expect(!early)
        // Hand comes near, then the object is lifted away.
        _ = p.update(time: t, depthDelta: -0.05, handDistance: 0.05); t += 1.0 / 30
        var fired = false
        for _ in 0..<30 { fired = p.update(time: t, depthDelta: 0.12, handDistance: nil) || fired; t += 1.0 / 30 }
        #expect(fired)
    }
}
