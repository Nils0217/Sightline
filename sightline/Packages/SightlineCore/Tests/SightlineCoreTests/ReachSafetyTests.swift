// labels: testing, needs-review
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
    @Test func trackingFailureStopsAndDoesNotAutomaticallyResume() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.4], cameraTransform: camera, time: 0)
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false, trackingNormal: false)
        #expect(out.lines.first?.interrupt == true)
        #expect(out.toneDistance == nil && !out.requestCheck)
        let recovered = s.update(time: 2, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        #expect(recovered.lines.isEmpty && s.pauseReason != nil)
    }
    @Test func turnedCameraCannotChangeInstructionFrame() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.4], cameraTransform: camera, time: 0)
        let turned = simd_float4x4(simd_quatf(angle: .pi / 4, axis: [0, 1, 0]))
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: turned, targetDepthDelta: nil, speaking: false)
        #expect(s.pauseReason != nil && out.lines.first?.interrupt == true)
    }
    @Test func obstacleVetoesAllMovementInstructions() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        let h = hand([0, 0, -0.4])
        _ = s.update(time: 0, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let map = ObstacleMap(points: [[0.15, 0, -0.4]])
        let out = s.update(time: 0.5, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false, liveObstacles: map)
        #expect(s.pauseReason != nil)
        #expect(out.lines.count == 1 && out.lines[0].interrupt)
        #expect(out.toneDistance == nil)
    }
    @Test func obstacleBesideWristAlsoVetoesMovement() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        let h = hand([0, 0, -0.4])
        _ = s.update(time: 0, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.5, hand: h, cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                     liveObstacles: ObstacleMap(points: [[0.15, 0.06, -0.28]]))
        #expect(s.pauseReason != nil)
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
        #expect(lines.contains { $0.contains("contact is not confirmed") })
        #expect(!lines.contains { $0.contains("Grab it") || $0.contains("at your hand") })
    }
    @Test func handLossInterruptsSpeechAndSilencesTones() {
        var s = GuidanceSession(targetName: "phone", target: [0.3, 0, -0.4], cameraTransform: camera, time: 0)
        _ = s.update(time: 0, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        _ = s.update(time: 0.4, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        let out = s.update(time: 1, hand: nil, cameraTransform: camera, targetDepthDelta: nil, speaking: true)
        #expect(out.lines.first?.interrupt == true && out.toneDistance == nil)
    }
    @Test func noAutomaticSuccessFromSingleImageOrModelAlone() {
        #expect(HoldDecision.decide(held: true, atSpot: false, spark: true).result == nil)
        #expect(HoldDecision.decide(held: false, atSpot: false, spark: true).result == nil)
        #expect(HoldDecision.decide(held: false, atSpot: nil, spark: true).result == nil)
        #expect(HoldDecision.decide(held: true, atSpot: false, spark: false, motionVerified: true).result == nil)
        #expect(HoldDecision.decide(held: true, atSpot: false, spark: true, motionVerified: true).result == true)
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
        var moving = false
        for i in 0..<50 {
            let out = s.update(time: Double(i) / 30, hand: hand([0, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
            moving = moving || out.lines.contains { $0.text.hasPrefix("Move your hand right") }
        }
        #expect(moving)
        let out = s.update(time: 1.7, hand: hand([0.02, 0, -0.3]), cameraTransform: camera, targetDepthDelta: nil, speaking: false,
                           liveObstacles: ObstacleMap(points: [[0.13, 0, -0.3]]))
        #expect(s.pauseReason != nil && out.lines.first?.interrupt == true)
    }
    @Test func missingSceneDepthIsNotAnEmptyClearScene() {
        #expect(!SceneCoverage.isUsable(valid: 0, sampled: 100))
        #expect(!SceneCoverage.isUsable(valid: 10, sampled: 100))
        #expect(SceneCoverage.isUsable(valid: 30, sampled: 100))
    }
    @Test func explicitCheckFailureCannotResumeOldGuidance() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.5], cameraTransform: camera, time: 0)
        s.beginManualCheck()
        _ = s.resolveCheck(false, time: 1)
        #expect(s.phase == .grabbing)
        let out = s.update(time: 1.1, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        #expect(!out.lines.contains { $0.text.hasPrefix("Move your hand") })
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
        #expect(s.pauseReason?.contains("comfortable reach") == true)
        #expect(out.lines.first?.interrupt == true)
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
        #expect(lines.contains { $0.hasPrefix("Move your hand right") })
    }
    @Test func solidApproachAlignsDepthBeforeLargeSidewaysReach() {
        let o = ObjectModel(points: [[0.2, 0, -0.5]], supportHeight: nil, isFlat: false)
        var p = ReachApproach(object: o, from: [0, 0, -0.25])
        let first = p.waypoint(from: [0, 0, -0.25])
        #expect(p.stage == .advance && first.x == 0 && first.z == -0.5)
        let second = p.waypoint(from: first)
        #expect(p.stage == .approach && second == o.centre)
    }

    @Test func edgeOfViewRequiresReorientationBeforeAnyReach() {
        let o = ObjectModel(points: [[0.2, 0, -0.5]], supportHeight: nil, isFlat: false)
        var s = GuidanceSession(targetName: "bottle", target: o.centre, object: o, cameraTransform: camera, time: 0,
                                reachProfile: ReachProfile(maximumDistance: 0.8))
        #expect(s.pauseReason?.contains("hand lowered") == true)
        let out = s.update(time: 1, hand: hand([0, 0, -0.2]), cameraTransform: camera, targetDepthDelta: nil, speaking: false)
        #expect(!out.lines.contains { $0.text.hasPrefix("Move your hand") })
    }

}
