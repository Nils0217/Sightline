// labels: testing, obsolete, needs-review
// Tests HoldVerification.swift, obsolete since v9 (kept as a record; the app no longer uses it).
import Testing
import simd
@testable import SightlineCore

@Suite struct HoldVerificationTests {
    func hand(_ p: SIMD3<Float>, thumb: Bool = false) -> HandKeypoints {
        var joints: [HandJoint: SIMD3<Float>] = [.indexTip: p + [0.015, 0, 0], .middleTip: p + [-0.015, 0, 0], .ringTip: p + [0, 0, 0.015]]
        if thumb { joints[.thumbTip] = p + [-0.025, 0, 0] }
        return HandKeypoints(joints: joints)
    }
    func observation(_ time: Double, _ p: SIMD3<Float>?, identity: Bool? = true, h: HandKeypoints? = nil, away: Bool = true) -> HoldObservation {
        let h = h ?? p.map { hand($0) }
        return HoldObservation(time: time, object: p, hand: h, identity: identity,
                               nearHand: p.map { HoldContact.near(hand: h, points: [$0], centre: $0) } ?? false,
                               awayFromOriginal: away)
    }

    @Test func missingThumbDoesNotDiscardValidSharedMotion() {
        var v = HoldVerification()
        #expect(v.add(observation(0, [0, 0.1, -0.4])) == .collect)
        #expect(v.add(observation(1, [0.04, 0.1, -0.4])) == .confirmed([0.04, 0.1, -0.4]))
    }
    @Test func missedMiddleImagePreservesEarlierMotionEvidence() {
        var v = HoldVerification()
        _ = v.add(observation(0, [0, 0.1, -0.4]))
        #expect(v.add(observation(1, nil, identity: nil)) == .collect)
        #expect(v.add(observation(2, [0.04, 0.1, -0.4])) == .confirmed([0.04, 0.1, -0.4]))
    }
    @Test func droppedIndexCanUseTwoOtherCommonPhysicalTips() {
        var v = HoldVerification()
        _ = v.add(observation(0, [0, 0.1, -0.4]))
        var second = hand([0.04, 0.1, -0.4]); second.joints[.indexTip] = nil
        #expect(v.add(observation(1, [0.04, 0.1, -0.4], h: second)) == .confirmed([0.04, 0.1, -0.4]))
    }
    @Test func threeMissingImagesEndWithoutAnAutomaticRetry() {
        var v = HoldVerification()
        _ = v.add(observation(0, nil, identity: nil)); _ = v.add(observation(1, nil, identity: nil))
        #expect(v.add(observation(2, nil, identity: nil)) == .uncertain(.insufficientEvidence))
        #expect(v.add(observation(3, [0.04, 0.1, -0.4])) == .uncertain(.insufficientEvidence))
        #expect(v.attempts == 3)
    }
    @Test func wrongIdentityEndsTheCycleEvenWithMotion() {
        var v = HoldVerification(); _ = v.add(observation(0, [0, 0.1, -0.4]))
        #expect(v.add(observation(1, [0.04, 0.1, -0.4], identity: false)) == .uncertain(.identityMismatch))
    }
    @Test func stationaryObjectCannotBeConfirmedByMovingFingers() {
        var v = HoldVerification(); let p = SIMD3<Float>(0, 0.1, -0.4)
        _ = v.add(observation(0, p)); _ = v.add(observation(1, p, h: hand(p + [0.03, 0, 0])))
        #expect(v.add(observation(2, p)) == .uncertain(.insufficientEvidence))
    }
    @Test func movingObjectWithoutHandMotionCannotBeConfirmed() {
        var v = HoldVerification(); let p = SIMD3<Float>(0, 0.1, -0.4), h = hand(p)
        _ = v.add(observation(0, p, h: h)); _ = v.add(observation(1, p + [0.04, 0, 0], h: h))
        #expect(v.add(observation(2, p + [0.04, 0, 0], h: h)) == .uncertain(.insufficientEvidence))
    }
    @Test func nearbyWrongHandOrObjectCannotPassRelativeMotionCheck() {
        var v = HoldVerification(); let p = SIMD3<Float>(0, 0.1, -0.4)
        _ = v.add(observation(0, p))
        _ = v.add(observation(1, p + [0.04, 0, 0], h: hand(p + [-0.04, 0, 0])))
        #expect(v.add(observation(2, p + [0.04, 0, 0], h: hand(p + [-0.04, 0, 0]))) == .uncertain(.insufficientEvidence))
    }
    @Test func noRiseFromKnownSupportCannotBecomePossession() {
        var v = HoldVerification()
        _ = v.add(observation(0, [0, 0, -0.4], away: false)); _ = v.add(observation(1, [0.04, 0, -0.4], away: false))
        #expect(v.add(observation(2, [0.08, 0, -0.4], away: false)) == .uncertain(.insufficientEvidence))
    }
    @Test func oneAffirmativeIdentityIsNotEnough() {
        var v = HoldVerification(); _ = v.add(observation(0, [0, 0.1, -0.4]))
        _ = v.add(observation(1, [0.04, 0.1, -0.4], identity: nil))
        #expect(v.add(observation(2, [0.04, 0.1, -0.4], identity: nil)) == .uncertain(.insufficientEvidence))
    }
    @Test func expiredAndDuplicateEvidenceCannotConfirm() {
        var v = HoldVerification(); _ = v.add(observation(1, [0, 0.1, -0.4]))
        _ = v.add(observation(1, [0.04, 0.1, -0.4])); #expect(v.attempts == 1)
        #expect(v.add(observation(32, [0.04, 0.1, -0.4])) == .uncertain(.timeout))
    }
    @Test func oneCommonFingerIsInsufficient() {
        var v = HoldVerification(); _ = v.add(observation(0, [0, 0.1, -0.4]))
        let h = HandKeypoints(joints: [.indexTip: [0.055, 0.1, -0.4], .littleTip: [0.04, 0.1, -0.4]])
        _ = v.add(observation(1, [0.04, 0.1, -0.4], h: h))
        #expect(v.add(observation(2, [0.04, 0.1, -0.4], h: h)) == .uncertain(.insufficientEvidence))
    }
    @Test func shortJointDropoutIsRetainedButStaleJointExpires() {
        var trace = HandTrace(); trace.append(time: 1, hand: hand([0, 0, -0.4]))
        var partial = hand([0, 0, -0.4]); partial.joints[.indexTip] = nil
        trace.append(time: 1.1, hand: partial)
        #expect(trace.hand(at: 1.1)?.joints[.indexTip] != nil)
        #expect(trace.hand(at: 1.2)?.joints[.indexTip] == nil)
        #expect(trace.hand(at: 0.9) == nil)
    }
    @Test func movementPlanUsesOnlyOneSmallHorizontalStep() throws {
        let h = hand([0, 0, -0.4])
        let plan = try #require(HoldMovementPlan.make(object: [0, 0, -0.4], hand: h, camera: matrix_identity_float4x4,
            profile: ReachProfile(maximumDistance: 0.7), obstacles: ObstacleMap(points: []), canSee: { _ in true }))
        #expect(abs(simd_length(plan.delta) - 0.04) < 0.0001 && plan.delta.y == 0)
        let capture = HoldMovementCapture(baseline: h, delta: plan.delta, started: 1)
        #expect(!capture.ready(time: 1.2, hand: h))
        #expect(capture.ready(time: 1.5, hand: hand([0, 0, -0.4] + plan.delta)))
        #expect(capture.ready(time: 5, hand: nil))
    }
    @Test func unavailableOrBlockedSpaceDoesNotRequestMovement() {
        let h = hand([0, 0, -0.4]), profile = ReachProfile(maximumDistance: 0.7)
        #expect(HoldMovementPlan.make(object: [0, 0, -0.4], hand: h, camera: matrix_identity_float4x4,
            profile: profile, obstacles: nil, canSee: { _ in true }) == nil)
        #expect(HoldMovementPlan.make(object: [0, 0, -0.4], hand: h, camera: matrix_identity_float4x4,
            profile: profile, obstacles: ObstacleMap(points: [[0, 0, -0.4]]), canSee: { _ in true }) == nil)
        #expect(HoldMovementPlan.make(object: [0, 0, -0.4], hand: h, camera: matrix_identity_float4x4,
            profile: profile, obstacles: ObstacleMap(points: []), canSee: { _ in false }) == nil)
    }
    @Test func negativeVerdictWaitsForUserInsteadOfRestartingChecks() {
        var s = GuidanceSession(targetName: "phone", target: [0, 0, -0.4], cameraTransform: matrix_identity_float4x4, time: 0)
        // v9: "not sure" goes back to grabbing and asks for a double tap; the hand resting at the
        // spot does not start another check by itself.
        s.beginManualCheck()
        #expect(s.resolveCheck(nil, time: 1).map(\.text) == ["Not sure. Double tap if you have it."])
        for i in 2..<100 {
            let out = s.update(time: Double(i), hand: hand([0, 0, -0.4]), cameraTransform: matrix_identity_float4x4,
                               targetDepthDelta: nil, speaking: false)
            #expect(!out.requestCheck)
            // After 12 s without a pick-up it guides again (v9.1: no dead end; v9.2: 20 -> 12 s), so tones may return.
            if i < 13 { #expect(out.toneDistance == nil) }
        }
    }
    @Test func overshootIsDetectedWithoutRequestingMoreMovement() {
        let h = hand([0, 0, -0.4])
        let capture = HoldMovementCapture(baseline: h, delta: [0.04, 0, 0], started: 0)
        #expect(!capture.overLimit(hand: hand([0.04, 0, -0.4])))
        #expect(capture.overLimit(hand: hand([0.08, 0, -0.4])))
    }

    @Test func naturalMovementIsObservedInsteadOfAddingAnotherMovementRequest() {
        var steady = HandTrace(), moving = HandTrace()
        for i in 0..<12 {
            let t = Double(i) / 30
            steady.append(time: t, hand: hand([0, 0, -0.4]))
            moving.append(time: t, hand: hand([Float(t) * 0.13, 0, -0.4]))
        }
        #expect(steady.isSteady(at: 11.0 / 30))
        #expect(!moving.isSteady(at: 11.0 / 30))
    }

    @Test func returningToStartDoesNotMakeAnOscillatingHandSteady() {
        var trace = HandTrace()
        for i in 0..<12 {
            let excursion: Float = (3...8).contains(i) ? 0.1 : 0
            trace.append(time: Double(i) / 30, hand: hand([excursion, 0, -0.4]))
        }
        #expect(!trace.isSteady(at: 11.0 / 30))
    }
    @Test func movementVetoUsesFreshDepthAndTracksTwoCommonTips() {
        let h = hand([0, 0, -0.4])
        let context = HoldMovementContext(baseline: h, object: [0, 0, -0.4], surface: [], delta: [0.04, 0, 0])
        let profile = ReachProfile(maximumDistance: 0.7), camera = matrix_identity_float4x4
        #expect(context.failure(hand: h, camera: camera, profile: profile, obstacles: ObstacleMap(points: []), canSee: { _ in true }) == nil)
        #expect(context.failure(hand: h, camera: camera, profile: profile, obstacles: nil, canSee: { _ in true }) == .depth)
        #expect(context.failure(hand: h, camera: camera, profile: profile, obstacles: ObstacleMap(points: [[0.07, 0, -0.4]]), canSee: { _ in true }) == .blocked)
        let onlyOne = HandKeypoints(joints: [.indexTip: [0.015, 0, -0.4], .wrist: [0, 0, -0.3]])
        #expect(context.failure(hand: onlyOne, camera: camera, profile: profile, obstacles: ObstacleMap(points: []), canSee: { _ in true }) == .tracking)
    }
    @Test func wideObjectEdgeCanVetoAClearCentrePath() {
        let h = hand([0, 0, -0.4])
        let context = HoldMovementContext(baseline: h, object: [0, 0, -0.4],
            surface: [[-0.12, 0, -0.4], [0.12, 0, -0.4]], delta: [0.04, 0, 0])
        let obstacle = ObstacleMap(points: [[0.2, 0, -0.4]])
        #expect(obstacle.blocking(from: [0, 0, -0.4], to: [0.04, 0, -0.4]) == nil)
        #expect(context.failure(hand: h, camera: matrix_identity_float4x4,
            profile: ReachProfile(maximumDistance: 0.7), obstacles: obstacle, canSee: { _ in true }) == .blocked)
    }
    @Test func retainedAnchorKeepsItsOwnShapeAcrossAMissingObservation() {
        var v = HoldVerification()
        var first = observation(0, [0, 0.1, -0.4]); first.surface = [[0.1, 0.1, -0.4]]
        _ = v.add(first); _ = v.add(observation(1, nil, identity: nil))
        #expect(v.latestAnchor?.surface == first.surface)
        #expect(v.add(observation(2, [0.04, 0.1, -0.4])) == .confirmed([0.04, 0.1, -0.4]))
    }

    @Test func movementInTheOppositeDirectionIsRejected() {
        let h = hand([0, 0, -0.4])
        let context = HoldMovementContext(baseline: h, object: [0, 0, -0.4], surface: [], delta: [0.04, 0, 0])
        #expect(context.failure(hand: hand([-0.05, 0, -0.4]), camera: matrix_identity_float4x4,
            profile: ReachProfile(maximumDistance: 0.7), obstacles: ObstacleMap(points: []), canSee: { _ in true }) == .direction)
    }
    @Test func limitsRemainEnforcedAfterCaptureWhileCloudIsPending() {
        let h = hand([0, 0, -0.4])
        let context = HoldMovementContext(baseline: h, object: [0, 0, -0.4], surface: [], delta: [0.04, 0, 0])
        let trigger = HoldMovementCapture(baseline: h, delta: [0.04, 0, 0], started: 0)
        #expect(trigger.ready(time: 1, hand: hand([0.04, 0, -0.4])))
        #expect(context.failure(hand: hand([0.08, 0, -0.4]), camera: matrix_identity_float4x4,
            profile: ReachProfile(maximumDistance: 0.7), obstacles: ObstacleMap(points: []), canSee: { _ in true }) == .overshoot)
    }

}
