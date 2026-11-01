// labels: testing, needs-review
// Tests for the gaps the Muse review of 2026-10-30 listed: the hold decision matrix, re-arming and
// capping automatic checks, the timeout path, agent text rules, room-map naming and turn sizes.
import Foundation
import simd
import Testing
@testable import SightlineCore

@Suite struct HoldDecisionTests {
    /// Every (held, atSpot, spark) combination.
    @Test(arguments: [true, false])
    func matrix(held: Bool) {
        for atSpot: Bool? in [true, false, nil] {
            for spark: Bool? in [true, false, nil] {
                let (result, reason) = HoldDecision.decide(held: held, atSpot: atSpot, spark: spark)
                if held {
                    // SAM sees it in the hand; Spark can only veto (layers disagree: not sure).
                    #expect(reason == .held)
                    #expect(result == (spark == false ? nil : true))
                    continue
                }
                switch atSpot {
                case true?:
                    // Spark yes disagrees with SAM: not sure (v7 key bunch). Otherwise "still there".
                    #expect(reason == .stillAtSpot)
                    #expect(result == (spark == true ? nil : false))
                case false?:
                    #expect(reason == .goneFromSpot)
                    #expect(result == (spark == true ? true : nil))
                case nil:
                    #expect(reason == .sparkOnly)
                    #expect(result == (spark == true ? true : nil))
                }
            }
        }
    }
}

@Suite struct AutoCheckTests {
    let object = ObjectModel(points: [SIMD3(0, 0.01, -0.5), SIMD3(0.05, 0.01, -0.5), SIMD3(0, 0.01, -0.55)],
                             supportHeight: 0, isFlat: true)

    func hand(_ tip: SIMD3<Float>) -> HandKeypoints {
        HandKeypoints(joints: [.indexTip: tip, .thumbTip: tip + SIMD3(-0.03, 0, 0.03),
                               .wrist: tip + SIMD3(0, 0.08, 0.12), .middleMCP: tip + SIMD3(0, 0.08, 0.05)])
    }

    /// Drives the session along `tips` (one per frame) and returns the number of check requests.
    func run(_ s: inout GuidanceSession, _ tips: [SIMD3<Float>], t: inout Double) -> Int {
        var checks = 0
        for p in tips {
            t += 1.0 / 30
            let out = s.update(time: t, hand: hand(p), cameraTransform: downCamera, targetDepthDelta: 0, speaking: false)
            if out.requestCheck { checks += 1 }
        }
        return checks
    }

    /// A "not sure" verdict must not loop straight into another check while the hand stays away.
    @Test func notSureNeedsTheHandBackBeforeTheNextCheck() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        let near = object.centre + SIMD3(0, 0.015, 0)
        var t = 0.0
        #expect(run(&s, Array(repeating: far, count: 40) + Array(repeating: near, count: 10) + Array(repeating: far, count: 20), t: &t) == 1)
        #expect(s.phase == .checking)
        _ = s.resolveCheck(nil, time: t)
        #expect(s.phase == .grabbing)
        // Hand still away: no new check, however long.
        #expect(run(&s, Array(repeating: far, count: 90), t: &t) == 0)
    }

    /// The app's timeout resolves the session like "not sure", so cues are not silenced in .checking.
    @Test func timeoutLeavesChecking() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        var t = 0.0
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        let near = object.centre + SIMD3(0, 0.015, 0)
        _ = run(&s, Array(repeating: far, count: 40) + Array(repeating: near, count: 10) + Array(repeating: far, count: 20), t: &t)
        #expect(s.phase == .checking)
        let lines = s.checkTimedOut(time: t)
        #expect(s.phase == .grabbing)
        #expect(lines.first?.text == "I can't tell. Hold it up to the camera.")
    }

    /// After `maxAutoChecks` the session only says once how to ask for a check.
    @Test func automaticChecksAreCapped() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        s.maxAutoChecks = 2
        let far = object.centre + SIMD3(0.25, 0.15, 0.2)
        let near = object.centre + SIMD3(0, 0.015, 0)
        let pass = Array(repeating: far, count: 40) + Array(repeating: near, count: 10) + Array(repeating: far, count: 20)
        var t = 0.0
        var checks = 0
        var said: [String] = []
        for _ in 0..<5 {
            for p in pass {
                t += 1.0 / 30
                let out = s.update(time: t, hand: hand(p), cameraTransform: downCamera, targetDepthDelta: 0, speaking: false)
                said += out.lines.map(\.text)
                if out.requestCheck { checks += 1; _ = s.resolveCheck(false, time: t) }
            }
        }
        #expect(checks == 2)
        #expect(said.filter { $0 == "Double tap to check it." }.count == 1)
    }

    /// v6 run 2: the hand hovered ~7 cm over the phone and single-frame fingertip depth jumps (±6 cm)
    /// started four checks. Jumps that do not last must not arm or fire a check.
    @Test func fingertipDepthJumpsDoNotStartChecks() {
        var s = GuidanceSession(targetName: "phone", target: object.centre, object: object, cameraTransform: downCamera, time: 0)
        s.keepGoingLimit = 1000  // the hand never moves; only the jumps are under test
        let hover = object.centre + SIMD3(0, 0.07, 0.03)
        var tips: [SIMD3<Float>] = []
        for i in 0..<600 {  // 20 s
            switch i % 9 {
            case 3: tips.append(hover + SIMD3(0, -0.055, 0))  // one frame near the surface
            case 7: tips.append(hover + SIMD3(0, 0.06, 0))    // one frame far
            default: tips.append(hover)
            }
        }
        var t = 0.0
        #expect(run(&s, tips, t: &t) == 0)
    }

    /// "Keep going" counting uses the cue's flag, not its wording.
    @Test func repeatedFlagMarksTheSameInstruction() {
        var g = StepGuide()
        var cues: [GuidanceCue] = []
        var t = 0.0
        for _ in 0..<200 {
            t += 1.0 / 30
            if let c = g.update(time: t, offset: BodyOffset(right: 0.3, up: 0, forward: 0)), c.kind == .move { cues.append(c) }
        }
        #expect(cues.count >= 2)
        #expect(cues.first?.repeated == false)
        #expect(cues.dropFirst().allSatisfy { $0.repeated })
    }
}

@Suite struct AgentTextTests {
    @Test func directionsAreCutNotTheWholeSentence() {
        #expect(AgentText.withoutDirections("Got it, the blue cup, on your right.") == "Got it, the blue cup.")
        #expect(AgentText.withoutDirections("It's to the left of the bottle.") == nil)
        #expect(AgentText.withoutDirections("Okay, the right cup it is.") == "Okay, the right cup it is.")
        #expect(AgentText.withoutDirections("Yes, that's right.") == "Yes, that's right.")
        #expect(AgentText.withoutDirections("The mug is in front of you") == nil)
        #expect(AgentText.withoutDirections("I'll guide you to the water bottle.") == "I'll guide you to the water bottle.")
    }

    @Test func guessReadsTheFirstNumberAnywhere() {
        #expect(AgentText.firstInteger("3") == 3)
        #expect(AgentText.firstInteger("Item 3.") == 3)
        #expect(AgentText.firstInteger("I think 12, the desk") == 12)
        #expect(AgentText.firstInteger("none") == nil)
    }

    @Test func scanTheRoomForSomethingIsASearch() {
        #expect(CommandParser.parse("scan the room for my keys") == .find("keys"))
        #expect(CommandParser.parse("scan the room") == .mapRoom)
    }
}

@Suite struct RoomNamingTests {
    @Test func summaryRanksWholeWordsOnly() {
        var inv = RoomInventory(created: Date())
        for (i, n) in ["garbage can", "basket", "keys", "headphones", "lamp", "zebra plush"].enumerated() {
            inv.remember(n, at: SIMD3(Float(i), 0, 0), date: Date(), source: "map")
        }
        let names = inv.summaryNames()
        #expect(names.prefix(2) == ["keys", "headphones"])
        // "garbage" holds "bag", but is not one: ranked with the other unknown things, alphabetically.
        #expect(Array(names.dropFirst(2)) == ["basket", "garbage can", "lamp"])
    }

    @Test func carriedForgetsSingularAndPlural() {
        var inv = RoomInventory(created: Date())
        inv.remember("key", at: SIMD3(1, 0, 0), date: Date(), source: "map")
        inv.carried("keys", from: SIMD3(1.1, 0, 0))
        #expect(inv.items.isEmpty)
    }

    @Test func turnSizesAgreeAtTheBoundaries() {
        func offset(_ deg: Float) -> BodyOffset {
            let r = deg * .pi / 180
            return BodyOffset(right: sin(r), up: 0, forward: cos(r))
        }
        #expect(RoomInventory.place(offset(49)).contains("a little"))
        #expect(ScanPlanner.turn(49 * .pi / 180).contains("a little"))
        #expect(RoomInventory.place(offset(51)).contains("quarter turn"))
        #expect(ScanPlanner.turn(51 * .pi / 180).contains("quarter turn"))
        #expect(RoomInventory.place(offset(124)).contains("quarter turn"))
        #expect(ScanPlanner.turn(124 * .pi / 180).contains("quarter turn"))
        #expect(RoomInventory.place(offset(126)).contains("half a turn"))
        #expect(ScanPlanner.turn(126 * .pi / 180).contains("half a turn"))
    }
}

/// Nils, 2026-10-30 (v7): "用戶一抓起任何東西要馬上啟動判定".
@Suite struct LiftDetectorTests {
    /// Feeds palm heights (nil = no hand) at 30 Hz; returns the reasons fired.
    func feed(_ ys: [Float?], table: Float = 0) -> [String] {
        var d = LiftDetector()
        var t = 0.0
        return ys.compactMap { y in
            t += 1.0 / 30
            return d.update(time: t, palmY: y, tableY: table)
        }
    }

    @Test func restThenLiftFires() {
        let rest = [Float?](repeating: 0.06, count: 20)
        let up: [Float?] = stride(from: Float(0.06), through: 0.2, by: 0.01).map { $0 }
        #expect(feed(rest + up) == ["lift"])
    }

    @Test func handVanishingAtTheTableFires() {
        #expect(feed([Float?](repeating: 0.06, count: 20) + [Float?](repeating: nil, count: 30)) == ["hand_lost_low"])
    }

    @Test func passingThroughOrBelowTheTableDoesNot() {
        // Up from the lap through the table band without stopping.
        let pass: [Float?] = stride(from: Float(-0.3), through: 0.3, by: 0.01).map { $0 }
        #expect(feed(pass) == [])
        // Resting in the lap, then rising.
        let lap = [Float?](repeating: -0.25, count: 30) + stride(from: Float(-0.25), through: 0.0, by: 0.01).map { $0 }
        #expect(feed(lap) == [])
        // Hovering high over the table, then rising.
        let high = [Float?](repeating: 0.15, count: 30) + stride(from: Float(0.15), through: 0.3, by: 0.01).map { $0 }
        #expect(feed(high) == [])
    }

    @Test func firesOnceUntilLowAgain() {
        let rest = [Float?](repeating: 0.06, count: 20)
        let up: [Float?] = stride(from: Float(0.06), through: 0.25, by: 0.01).map { $0 }
        let held = [Float?](repeating: 0.25, count: 30)
        #expect(feed(rest + up + held + rest + up) == ["lift", "lift"])
    }
}

@Suite struct ScanStallTests {
    /// v7 book: the user never turned, no SAM call was made, and "Still looking" repeated forever.
    @Test func noNewViewGivesUpAfterThreePrompts() {
        var p = ScanPlanner(time: 0)
        p.markSearched(cameraTransform: matrix_identity_float4x4)
        var steps: [ScanPlanner.Step] = []
        var t = 0.0
        while t < 60, steps.last != .giveUp {
            t += 1.0 / 30
            let s = p.update(time: t, cameraTransform: matrix_identity_float4x4, busy: false, speaking: false)
            if s != .wait { steps.append(s) }
        }
        #expect(steps == [.prompt, .prompt, .prompt, .giveUp])
        #expect(t < 40)
    }
}
