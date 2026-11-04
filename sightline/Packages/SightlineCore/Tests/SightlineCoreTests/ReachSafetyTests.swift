// labels: testing, needs-review
// v9 (2026-10-31): nothing latches. Tracking loss holds and resumes, a turned body re-bases the frame,
// an obstacle stops the hand and resumes when clear; only out of reach or a lasting obstacle ends.
import Testing
import simd
@testable import SightlineCore

@Suite struct ReachSafetyTests {
    let camera = matrix_identity_float4x4
    func hand(_ p: SIMD3<Float>) -> HandKeypoints {
        HandKeypoints(joints: [.indexTip: p, .thumbTip: p + SIMD3(-0.03, 0, 0),
                              .wrist: p + SIMD3(0, 0.06, 0.12), .middleMCP: p + SIMD3(0, 0.06, 0.04)])
    }
    @Test func distantAndBehindTargetsDoNotPermitReaching() {
        let profile = ReachProfile(maximumDistance: 0.45)
        #expect(profile.permits(target: [0, -0.1, -0.35], cameraTransform: camera))
        #expect(!profile.permits(target: [0, 0, -0.8], cameraTransform: camera))
        #expect(!profile.permits(target: [0, 0, 0.3], cameraTransform: camera))
        #expect(!ReachProfile(maximumDistance: .nan).permits(target: [0, 0, -0.2], cameraTransform: camera))
    }
    /// Device, 2026-10-31: a book on the table 45 cm ahead and 50 cm below the chest camera was called
    /// out of reach with a 50 cm reach (straight line 67 cm). Reach is horizontal; the drop is allowed.
    @Test func tableObjectBelowTheChestIsWithinReach() {
        let profile = ReachProfile(maximumDistance: 0.50)
        #expect(profile.permits(target: [0.1, -0.5, -0.45], cameraTransform: camera))
        #expect(!profile.permits(target: [0, -0.5, -0.6], cameraTransform: camera))   // too far ahead
        #expect(!profile.permits(target: [0, -1.2, -0.3], cameraTransform: camera))   // the floor
        #expect(!profile.permits(target: [0, 0.4, -0.3], cameraTransform: camera))    // a high shelf
    }
    @Test func calibrationRejectsUnstableOrMissingFingers() {
        var c = ReachCalibration()
        var result: Float?
        for i in 0..<40 { result = c.update(time: Double(i) / 30, fingertip: [Float(i % 2) * 0.1, 0, -0.4], camera: .zero) }
        #expect(result == nil)
        #expect(c.update(time: 2, fingertip: nil, camera: .zero) == nil)
        for i in 0..<40 { result = c.update(time: 3 + Double(i) / 30, fingertip: [0, 0, -0.4], camera: .zero) }
        #expect(abs((result ?? 0) - 0.37) < 0.001)
    }
    @Test func flatApproachLiftsBeforeTraversingAndThenDescends() {
        let o = ObjectModel(points: [[0, -0.3, -0.4], [0.1, -0.3, -0.4], [0, -0.3, -0.5]], supportHeight: -0.31, isFlat: true)
        var p = ReachApproach(object: o, from: [-0.2, -0.3, -0.2])
        let lift = p.waypoint(from: [-0.2, -0.3, -0.2])
        #expect(lift.x == -0.2 && lift.z == -0.2 && lift.y > -0.25)
        let across = p.waypoint(from: lift)
        #expect(p.stage == .traverse && across.y == lift.y)
        let down = p.waypoint(from: across)
        #expect(p.stage == .approach && down.y < across.y)
    }
    @Test func trackingLossHoldsThenResumes() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.4], cameraTransform: camera, time: 0)
        _ = s.update(time: 0, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false, trackingNormal: false)
        #expect(out.lines.map(\.text) == ["Hold still."] && out.lines[0].interrupt)
        #expect(out.toneDistance == nil && !out.requestCheck)
        let still = s.update(time: 1.5, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false, trackingNormal: false)
        #expect(still.lines.isEmpty)
        var back: [String] = []
        for i in 0..<30 {
            back += s.update(time: 2 + Double(i) / 30, hand: hand([0, 0, -0.2]), cameraTransform: camera,
                             targetDepthDelta: nil, speaking: false).lines.map(\.text)
        }
        #expect(s.endReason == nil && back.contains { $0.hasPrefix("Forward") })
    }
    @Test func turnedBodyRebasesTheDirectionFrame() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.4], cameraTransform: camera, time: 0)
        let turned = simd_float4x4(simd_quatf(angle: .pi / 4, axis: [0, 1, 0]))
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: turned, targetDepthDelta: nil, speaking: false)
        #expect(s.endReason == nil && !out.lines.contains { $0.interrupt })
    }
    /// T20: the fingers stop against a thermos 25 cm short of the bottle, which is ahead and to the left; the
    /// thermos is not in the map (carved as hand). "Something is in the way. Go around it on your left." before any check.
    @Test func handStoppedShortIsToldToGoAround() {
        var s = GuidanceSession(targetName: "pill bottle", target: [-0.08, 0, -0.45], cameraTransform: camera, time: 0)
        let stuck = SIMD3<Float>(0, 0, -0.2)
        var said: [String] = []
        var checks = 0
        for i in 0..<1200 {
            let p = stuck + SIMD3(0, 0, Float(i % 90 < 6 ? -0.001 * Double(i % 90) : 0))
            let out = s.update(time: Double(i) / 30, hand: hand(p), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
            said += out.lines.map(\.text)
            if out.requestCheck, checks == 0 { checks = said.count }
        }
        let blocked = said.firstIndex(of: "Something is in the way. Go around it on your left.")
        #expect(blocked != nil && (checks == 0 || blocked! < checks), "\(said)")
    }

    /// A small cluster (3 cm cells), like a real thing standing there; one point is noise.
    func cluster(_ p: SIMD3<Float>) -> ObstacleMap {
        ObstacleMap(points: [p, p + [0.01, 0, 0], p + [0, 0.015, 0], p + [0, 0, 0.01]])
    }
    /// v9.1 with planned detours (off by default since v9.2): an obstacle on the next move at rest is planned
    /// around; the hand is never sent into it and the search never ends (v9 ended it after 8 s).
    @Test func obstacleAtRestIsGoneAroundNotInto() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        s.maxDetours = 6
        let h = hand([0, 0, -0.4])
        var lines: [String] = []
        for i in 0..<240 {
            lines += s.update(time: Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                              liveObstacles: cluster([0.15, 0, -0.4])).lines.map(\.text)
        }
        #expect(s.endReason == nil)
        #expect(!lines.contains { $0.hasPrefix("Right") || $0.hasSuffix("right.") && !$0.hasPrefix("Careful") && !$0.contains("ahead") })
        #expect(lines.contains { $0.hasPrefix("Up") || $0.hasPrefix("Forward") || $0.hasPrefix("Back") || $0.hasPrefix("Careful")
            || $0.contains("ahead") })
    }
    /// v9.2 default (Nils: touching things is normal, time is the KPI): no stop, no detour; the thing is
    /// named once with where it is, and guidance goes on.
    @Test func obstacleIsNamedAndGuidanceGoesOn() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        s.nameObstacles([(centre: [0.15, 0, -0.4], name: "bottle")])
        let h = hand([0, 0, -0.4])
        var lines: [String] = []
        for i in 0..<240 {
            lines += s.update(time: Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                              liveObstacles: cluster([0.15, 0, -0.4])).lines.map(\.text)
        }
        #expect(s.endReason == nil)
        #expect(lines.contains("Careful. A bottle is on your right."), "\(lines)")
        #expect(!lines.contains { $0.hasPrefix("Stop. ") })
        #expect(lines.contains { $0.hasPrefix("Right") || $0.hasPrefix("Keep going right") })
    }
    /// T15: the bottle 2.5 m away on a shelf, things beside it: nothing is in front of the hand, so no
    /// "Something is ahead. Go around it." until the hand comes within an arm-sized 30 cm of them.
    @Test func thingsBesideAFarTargetAreNotAhead() {
        var s = GuidanceSession(targetName: "bottle", target: [0, 0, -2.5], cameraTransform: camera, time: 0)
        var lines: [String] = []
        for i in 0..<240 {
            lines += s.update(time: Double(i) / 30, hand: hand([0, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil,
                              speaking: false, liveObstacles: cluster([0.03, 0, -2.3])).lines.map(\.text)
        }
        #expect(!lines.contains { $0.contains("ahead") || $0.hasPrefix("Careful") || $0.hasPrefix("Stop") }, "\(lines)")
    }
    /// Ahead: pass it on the side the object is on, so the next direction agrees.
    @Test func obstacleAheadIsPassedOnTheObjectSide() {
        var s = GuidanceSession(targetName: "phone", target: [0.02, 0, -0.6], cameraTransform: camera, time: 0)
        s.nameObstacles([(centre: [-0.04, 0, -0.45], name: "cup")])
        var lines: [String] = []
        for i in 0..<120 {
            lines += s.update(time: Double(i) / 30, hand: hand([0, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil,
                              speaking: false, liveObstacles: cluster([-0.04, 0, -0.45])).lines.map(\.text)
        }
        #expect(lines.contains("A cup is ahead. Go around it on your right."), "\(lines)")
    }
    @Test func clearedPathResumesGuidance() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        let h = hand([0, 0, -0.4])
        _ = s.update(time: 0, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.5, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                     liveObstacles: cluster([0.15, 0, -0.4]))
        var lines: [String] = []
        for i in 0..<120 {
            lines += s.update(time: 0.6 + Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                              liveObstacles: ObstacleMap(points: [])).lines.map(\.text)
        }
        #expect(s.endReason == nil && lines.contains { $0.hasPrefix("Right") })
    }
    /// Device, 2026-10-31: "Stop. Something's in the way." with nothing there. One stray point (a flying
    /// pixel) and the user's own arm in a live map must not stop the hand.
    @Test func strayPointAndOwnArmDoNotStop() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        let h = hand([0, 0, -0.4])
        let wrist = h.joints[.wrist]!
        // The arm: points from the wrist back toward the chest camera, plus one stray point on the path.
        var points = (0...12).map { wrist + (SIMD3<Float>(0.1, 0.05, 0) - wrist) * Float($0) / 12 }
        points.append([0.15, 0, -0.4])
        var lines: [String] = []
        for i in 0..<60 {
            lines += s.update(time: Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                              liveObstacles: ObstacleMap(points: points)).lines.map(\.text)
        }
        #expect(!lines.contains { $0.contains("in the way") || $0.hasPrefix("Go slowly") })
        #expect(lines.contains { $0.hasPrefix("Right") })
    }
    /// Lock-frame scene: the table, a single stray cell, the user's body near the chest camera and the
    /// target's own edge are not obstacles; a bottle beside the target is.
    @Test func sceneKeepsRealThingsOnly() {
        let phone = ObjectModel(points: [[0, 0.81, -0.5], [0.04, 0.81, -0.5], [0, 0.81, -0.56]], supportHeight: 0.8, isFlat: true)
        var world: [SIMD3<Float>] = []
        for x in stride(from: Float(-0.3), through: 0.3, by: 0.02) { for z in stride(from: Float(-0.8), through: -0.2, by: 0.02) {
            world.append([x, 0.8 + (x * 37).truncatingRemainder(dividingBy: 0.008), z])  // table, < 1 cm noise
        } }
        world.append([0.2, 1.0, -0.6])                                              // one stray point
        world += (0..<20).map { SIMD3<Float>(0.02, 0.9 + Float($0) * 0.01, -0.1) }  // the user's body/arm
        world += (0..<5).map { SIMD3<Float>(0.02, 0.84, -0.5 + Float($0) * 0.003) } // target edge
        let bottle = (0..<8).flatMap { i in (0..<3).map { k in SIMD3<Float>(-0.15 + Float(k) * 0.03, 0.83 + Float(i) * 0.03, -0.5) } }
        world += bottle
        let map = ObstacleMap.scene(world, object: phone, camera: [0, 1.3, 0])!
        #expect(!map.points.isEmpty)
        #expect(map.points.allSatisfy { $0.x < -0.05 })  // only the bottle
    }
    /// A hand already beside something may move along it or away; only moving closer is blocked.
    @Test func besideAnObstacleTheHandCanMoveAway() {
        let map = cluster([0.03, 0, -0.4])
        #expect(map.blocking(from: [0, 0, -0.4], to: [-0.2, 0, -0.4], clearance: 0.05, minCount: 3, approaching: true) == nil)
        #expect(map.blocking(from: [0, 0, -0.4], to: [0, 0.2, -0.4], clearance: 0.05, minCount: 3, approaching: true) == nil)
        #expect(map.blocking(from: [-0.1, 0, -0.4], to: [0.2, 0, -0.4], clearance: 0.05, minCount: 3, approaching: true) != nil)
    }
    @Test func coherentReferenceUsesOnePhysicalFingertip() throws {
        let h = hand([0.03, 0.1, -0.3])
        #expect(GuidanceSession.guidePoint(h, cameraTransform: camera) == h.joints[.indexTip])
        let palmOnly = HandKeypoints(joints: [.wrist: .zero, .middleMCP: [0, 0, -0.1]])
        #expect(GuidanceSession.guidePoint(palmOnly, cameraTransform: camera) == nil)
    }
    @Test func proximityDoesNotClaimContactOrGrip() {
        var s = GuidanceSession(targetName: "book", target: [0, 0, -0.4], cameraTransform: camera, time: 0)
        var lines: [String] = []
        for i in 0..<50 {
            lines += s.update(time: Double(i) / 30, hand: hand([0, 0.025, -0.38]), cameraTransform: camera,
                              targetDepthDelta: nil, speaking: false).lines.map(\.text)
        }
        #expect(lines.contains { $0 == "Stop. The book is at your fingers." })
        #expect(!lines.contains { $0.contains("Grab it") || $0.contains("You have") })
    }
    @Test func handLossInterruptsSpeechAndSilencesTones() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        _ = s.update(time: 0, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let out = s.update(time: 1.5, hand: nil, cameraTransform: camera, targetDepthDelta: nil, speaking: true)
        #expect(out.lines.map(\.text) == ["I can't see your hand."] && out.lines[0].interrupt && out.toneDistance == nil)
        // Said once: a flickering hand does not repeat it.
        _ = s.update(time: 1.6, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let again = s.update(time: 3, hand: nil, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        #expect(again.lines.isEmpty)
    }
    @Test func slidingOrAStillObjectIsNotHeld() {
        let spot = SIMD3<Float>(0, 0, -0.4)
        #expect(HoldGeometry.classify(candidate: spot + [0.08, 0, 0], original: spot, supported: true, nearHand: true).held == false)
        #expect(HoldGeometry.classify(candidate: spot + [0, 0.06, 0.02], original: spot, supported: true, nearHand: true).held == true)
        #expect(HoldGeometry.classify(candidate: spot + [0, 0.06, 0.02], original: spot, supported: true, nearHand: false).held == false)
        #expect(HoldGeometry.classify(candidate: spot + [0.01, 0, 0], original: spot, supported: true, nearHand: true) == (false, true))
        #expect(HoldGeometry.classify(candidate: nil, original: spot, supported: true, nearHand: true).atSpot == nil)
    }
    @Test func motionRequiresJointMovementNotNearbyOrStationaryObject() {
        let p = SIMD3<Float>(0, 0, -0.3), h = SIMD3<Float>(0, -0.02, -0.3), d = SIMD3<Float>(0, 0.05, 0)
        #expect(HoldMotion.verified(firstObject: p, firstHand: h, firstTime: 0, object: p + d, hand: h + d, time: 1))
        #expect(!HoldMotion.verified(firstObject: p, firstHand: h, firstTime: 0, object: p, hand: h + d, time: 1))
        #expect(!HoldMotion.verified(firstObject: p, firstHand: h, firstTime: 0, object: p, hand: h, time: 1))
        #expect(!HoldMotion.verified(firstObject: p, firstHand: h, firstTime: 0, object: p + d, hand: h + d, time: 0.1))
    }
    @Test func obstacleCheckFollowsTheInstructionStillInProgress() {
        var s = GuidanceSession(targetName: "phone", target: [0.06, 0, -0.5], cameraTransform: camera, time: 0)
        s.maxDetours = 6  // the stop comes only when a way around will be planned
        var moving = false
        for i in 0..<50 {
            let out = s.update(time: Double(i) / 30, hand: hand([0, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
            moving = moving || out.lines.contains { $0.text.hasSuffix("right.") || $0.text.hasPrefix("Right") }
        }
        #expect(moving)
        let out = s.update(time: 1.7, hand: hand([0.02, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                           liveObstacles: cluster([0.07, 0, -0.3]))  // on the rest of the move to the right
        #expect(out.lines.first?.text == "Stop. Something's in the way." && out.lines.first?.interrupt == true,
                "\(out.lines.map(\.text)) \(out.phase)")
    }
    @Test func missingSceneDepthIsNotAnEmptyClearScene() {
        #expect(!SceneCoverage.isUsable(valid: 0, sampled: 100))
        #expect(!SceneCoverage.isUsable(valid: 10, sampled: 100))
        #expect(SceneCoverage.isUsable(valid: 30, sampled: 100))
    }
    @Test func stillThereGuidesAgain() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.5], cameraTransform: camera, time: 0)
        s.beginManualCheck()
        let lines = s.resolveCheck(false, time: 1)
        #expect(lines.map(\.text) == ["No. The phone is still there."])  // asked (double tap): worded as a reply
        #expect(s.phase == .guiding)
    }

    @Test func intermediateAxisEndpointCannotLeaveComfortableSphere() {
        // Both endpoints fit a 60 cm sphere; a sideways-first corner does not.
        let o = ObjectModel(points: [[0.18, 0, -0.53]], supportHeight: -0.01, isFlat: true)
        var s = GuidanceSession(targetName: "bottle", target: o.centre, object: o, cameraTransform: camera, time: 0,
                                reachProfile: ReachProfile(maximumDistance: 0.6))
        let h = hand([-0.1, 0.1, -0.57])
        _ = s.update(time: 0, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let out = s.update(time: 0.5, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        // The staged corner would leave the reach sphere: go straight for the object instead of stopping.
        #expect(s.endReason == nil)
        #expect(out.lines.first?.interrupt != true)
    }
    /// Nils, 2026-10-31: "I don't care how far the object is, it must guide." Beyond the measured reach the
    /// search goes on with directions; nothing says "out of reach".
    @Test func objectBeyondReachIsStillGuided() {
        let o = ObjectModel(points: [[0, -0.4, -0.9]], supportHeight: -0.41, isFlat: true)
        var s = GuidanceSession(targetName: "book", target: o.centre, object: o, cameraTransform: camera, time: 0,
                                reachProfile: ReachProfile(maximumDistance: 0.45))
        var lines = s.opening.map(\.text)
        var t = 0.0
        for _ in 0..<60 {
            t += 1.0 / 30
            lines += s.update(time: t, hand: hand([0, -0.1, -0.4]), cameraTransform: camera, targetDepthDelta: nil, speaking: false).lines.map(\.text)
        }
        #expect(s.endReason == nil)
        #expect(!lines.contains { $0.contains("out of reach") })
        #expect(s.phase == .guiding)
    }
    @Test func selfArmReturnsUseTheSameEnvelopeAsCollisionScreening() {
        let h = hand([0, 0, -0.4])
        let points = HandEnvelope.centres(hand: h, camera: .zero)
        #expect(points.count >= h.joints.count + 4)
        let wrist = h.joints[.wrist]!
        #expect(points.contains { simd_distance($0, wrist) > 0.19 && simd_distance($0, wrist) < 0.21 })
    }

    @Test func intermittentIndexDoesNotResetEveryInstruction() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        var lines: [String] = []
        for i in 0..<180 {
            var h = hand([0, 0, -0.3])
            h.joints[.middleTip] = [0.01, 0, -0.31]
            if i % 3 != 0 { h.joints[.indexTip] = nil }
            lines += s.update(time: Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false).lines.map(\.text)
        }
        #expect(lines.contains { $0.hasPrefix("Right") || $0.hasSuffix("right.") })
    }
    @Test func solidApproachAlignsDepthBeforeLargeSidewaysReach() {
        let o = ObjectModel(points: [[0.2, 0, -0.5]], supportHeight: nil, isFlat: false)
        var p = ReachApproach(object: o, from: [0, 0, -0.25])
        let first = p.waypoint(from: [0, 0, -0.25])
        #expect(p.stage == .advance && first.x == 0 && first.z == -0.5)
        let second = p.waypoint(from: first)
        #expect(p.stage == .approach && second == o.centre)
    }

    @Test func edgeOfViewAsksToTurnThenGuides() {
        let o = ObjectModel(points: [[0.2, 0, -0.5]], supportHeight: nil, isFlat: false)
        var s = GuidanceSession(targetName: "bottle", target: o.centre, object: o, cameraTransform: camera, time: 0,
                                reachProfile: ReachProfile(maximumDistance: 0.8))
        #expect(s.opening.last?.text.hasPrefix("Turn a little to your right") == true)
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        #expect(out.lines.isEmpty)
        // Turned to face it: "Good. Hold your hand out." and guidance can start.
        let facing = simd_float4x4(simd_quatf(angle: -atan2(0.2, 0.5), axis: [0, 1, 0]))
        let turned = s.update(time: 2, hand: hand([0, 0, -0.2]), cameraTransform: facing, targetDepthDelta: nil, speaking: false)
        #expect(turned.lines.map(\.text) == ["Good. Hold your hand out."] && s.endReason == nil)
    }


    /// v9.2: something dangerous is never just "Careful": the hand is stopped and sent around it.
    @Test func dangerousThingIsGoneAround() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        s.addHazard(at: [0.15, 0, -0.4], name: "knife")
        let h = hand([0, 0, -0.4])
        var lines: [String] = []
        for i in 0..<240 {
            lines += s.update(time: Double(i) / 30, hand: h, cameraTransform: camera, targetDepthDelta: nil,
                              speaking: false).lines.map(\.text)
        }
        #expect(!lines.contains { $0.hasPrefix("Right") || $0.hasPrefix("Keep going right") }, "\(lines)")
        #expect(lines.contains { $0.contains("knife") })
    }
}
