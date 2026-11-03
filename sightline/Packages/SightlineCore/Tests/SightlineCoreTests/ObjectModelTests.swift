// labels: testing, needs-review
import simd
import Testing
@testable import SightlineCore

/// Camera 0.8 m above a table, looking straight down (camera −z = world −y, image up = world −z).
let downCamera = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))

/// Landscape 40x30 depth: table at 0.8 m; object in raw i 10..<20, j 5..<15 at `objectDepth`.
/// Portrait source 30x40, object mask at x 15..<25, y 10..<20 (same layout as MaskTargetTests).
func tableScene(objectDepth: Float, glossyNoise: Bool = false) -> (DepthImage, SourceMask, CameraIntrinsics) {
    var d = [Float](repeating: 0.8, count: 40 * 30)
    for j in 5..<15 {
        for i in 10..<20 {
            // A glossy phone: LiDAR reads ±3 cm around the true surface.
            d[j * 40 + i] = objectDepth + (glossyNoise ? Float((i * 7 + j * 3) % 7 - 3) / 100 : 0)
        }
    }
    let record = SAMRecord(id: "0", left: 15, top: 10, right: 25, bottom: 20, sourceWidth: 30, sourceHeight: 40,
                           confidence: 0.9, maskWidth: 10, maskHeight: 10, payload: "")
    let mask = SourceMask(record: record, raster: [UInt8](repeating: 1, count: 100))
    let k = CameraIntrinsics(fx: 30, fy: 30, cx: 19.5, cy: 14.5, imageSize: SIMD2(40, 30))
    return (DepthImage(width: 40, height: 30, depth: d, confidence: [UInt8](repeating: 2, count: 1200)), mask, k)
}

@Suite struct ObjectModelTests {
    @Test func flatObjectSitsOnTheTable() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79, glossyNoise: true)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        #expect(m.isFlat)
        #expect(abs(try #require(m.supportHeight) - -0.8) < 0.005)
        // Glossy noise gone: every point is on the plane 1 cm above the table.
        #expect(m.points.allSatisfy { abs($0.y - -0.79) < 1e-4 })
        #expect(m.size.x > 0.15 && m.size.x < 0.3)
    }

    @Test func tallObjectKeepsItsOwnDepth() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.6)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        #expect(!m.isFlat)
        #expect(abs(m.centre.y - -0.6) < 1e-4)
    }

    @Test func nearestSurfacePointIsOnTheSideFacingTheHand() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        let hand = m.centre + SIMD3(0.5, 0, 0)
        let p = m.nearestSurfacePoint(to: hand)
        #expect(p.x > m.centre.x + 0.05)
    }
}

@Suite struct GraspTests {
    func phone() throws -> ObjectModel {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        return try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
    }

    @Test func thumbAndFingersOnOppositeEdgesIsAGrip() throws {
        let m = try phone()
        let c = m.centre, hx = m.size.x / 2
        let hand = HandKeypoints(joints: [
            .thumbTip: c + SIMD3(-hx - 0.01, 0, 0),
            .indexTip: c + SIMD3(hx + 0.01, 0, -0.02), .middleTip: c + SIMD3(hx + 0.01, 0, 0.01),
            .wrist: c + SIMD3(0, 0.05, 0.1), .middleMCP: c + SIMD3(0, 0.05, 0.03),
        ])
        let g = GraspAssessment.assess(hand, object: m)
        #expect(g.tipsNear >= 2)
        #expect(g.touching)
        #expect(g.opposed)
    }

    @Test func handHoveringAboveIsNotTouching() throws {
        let m = try phone()
        let up = SIMD3<Float>(0, 0.12, 0)
        let hand = HandKeypoints(joints: [.thumbTip: m.centre + up, .indexTip: m.centre + up, .wrist: m.centre + up * 1.2,
                                          .middleMCP: m.centre + up])
        #expect(!GraspAssessment.assess(hand, object: m).touching)
    }

    @Test func obstacleOnThePathIsFound() {
        let map = ObstacleMap(points: [SIMD3(0.2, 0.05, 0), SIMD3(0.9, 0.05, 0.5)])
        #expect(map.blocking(from: SIMD3(0, 0.05, 0), to: SIMD3(0.4, 0.05, 0)) == SIMD3(0.2, 0.05, 0))
        #expect(map.blocking(from: SIMD3(0, 0.05, 0), to: SIMD3(0, 0.05, -0.4)) == nil)
    }
}

@Suite struct ScanPlannerTests {
    func camera(yawDegrees: Float) -> simd_float4x4 {
        let a = yawDegrees * .pi / 180
        return simd_float4x4(simd_quatf(angle: a, axis: SIMD3(0, 1, 0)))
    }

    @Test func scansOnlyNewSteadyViews() {
        var p = ScanPlanner(time: 0)
        p.markSearched(cameraTransform: camera(yawDegrees: 0))
        var scans: [Double] = []
        var t = 0.0
        // Hold still at 0°, then turn to 40° quickly, hold, then back to 5°.
        for (yaw, until) in [(Float(0), 2.0), (40, 4.0), (5, 6.0)] {
            while t < until {
                t += 1.0 / 30
                if p.update(time: t, cameraTransform: camera(yawDegrees: yaw), busy: false, speaking: true) == .scan { scans.append(t) }
            }
        }
        #expect(scans.count == 1)
        #expect(scans[0] > 2.4 && scans[0] < 3)
        #expect(p.sectorsCovered == 2)
    }

    @Test func givesUpWhenBudgetIsSpent() {
        var p = ScanPlanner(time: 0)
        p.budget = 1
        var steps: [ScanPlanner.Step] = []
        var t = 0.0
        for yaw in [Float(0), 60, 120] {
            for _ in 0..<60 {
                t += 1.0 / 30
                steps.append(p.update(time: t, cameraTransform: camera(yawDegrees: yaw), busy: false, speaking: true))
            }
        }
        #expect(steps.filter { $0 == .scan }.count == 1)
        #expect(steps.last == .giveUp)
    }

    /// Nils, 2026-11-01: the room scan stops by itself after a full circle with enough views; no tap.
    func steadyScans(_ p: inout ScanPlanner, _ t: inout Double, _ pose: simd_float4x4) -> Int {
        var n = 0
        for _ in 0..<60 {
            t += 1.0 / 30
            if p.update(time: t, cameraTransform: pose, busy: false, speaking: true) == .scan { n += 1 }
        }
        return n
    }

    @Test func aDirectionIsNewAgainAfterWalking() {
        // Nils, 2026-11-02: a thing hidden behind a bigger one shows up from somewhere else.
        var p = ScanPlanner(time: 0)
        var t = 0.0
        var pose = camera(yawDegrees: 0)
        #expect(steadyScans(&p, &t, pose) == 1)
        #expect(steadyScans(&p, &t, pose) == 0)          // same place, same direction
        pose.columns.3 = SIMD4(0.4, 0, 0, 1)
        #expect(steadyScans(&p, &t, pose) == 0)          // 40 cm: still the same view
        pose.columns.3 = SIMD4(1.2, 0, 0, 1)
        #expect(steadyScans(&p, &t, pose) == 1)          // 1.2 m away: look again
        #expect(p.directionPrompt(cameraTransform: pose).contains("haven't looked"))
    }

    /// v9.4 device run (2026-11-03): the water bottle and the sunglasses were saved on a mantel above the chest
    /// phone. Facing it, the view was already searched, so no SAM call was made, and "Hold still. Looking there
    /// now." was said 3 times before giving up (24 s, nothing looked at).
    @Test func aSavedSpotAboveTheViewIsNotAWait() {
        func pose(pitchDegrees: Float) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: pitchDegrees * .pi / 180, axis: SIMD3(1, 0, 0)))
        }
        // Chest phone tilted down 20°; the saved spot 1 m ahead, 45° up: out of view.
        var p = ScanPlanner(time: 0)
        p.markSearched(cameraTransform: pose(pitchDegrees: -20))
        p.hint = SIMD3(0, 1, -1)
        #expect(p.directionPrompt(cameraTransform: pose(pitchDegrees: -20)) == "Point the phone a little higher.")
        // 15° below the spot (in view), 20° from a searched view: look at it now.
        var q = ScanPlanner(time: 0)
        q.markSearched(cameraTransform: pose(pitchDegrees: 10))
        q.hint = SIMD3(0, 1, -1)
        var t = 0.0
        #expect(steadyScans(&q, &t, pose(pitchDegrees: 30)) == 1)
        #expect(steadyScans(&q, &t, pose(pitchDegrees: 30)) == 0)  // the spot counts as looked at
    }

    @Test func roomScanEndsAfterAFullCircle() {
        var p = ScanPlanner(time: 0)
        p.budget = 12
        p.minNewAngle = 30 * .pi / 180
        var t = 0.0
        var yaw: Float = 0
        // Turn right in 15° steps, holding each view 1 s.
        while yaw < 360, !p.mappingDone {
            for _ in 0..<30 {
                t += 1.0 / 30
                _ = p.update(time: t, cameraTransform: camera(yawDegrees: -yaw), busy: false, speaking: true)
            }
            yaw += 15
        }
        #expect(p.mappingDone)
        #expect(p.swept.count == 12)
        #expect(!p.mappingPrompt(cameraTransform: camera(yawDegrees: 0)).lowercased().contains("tap"))
    }

    @Test func halfACircleIsNotDone() {
        var p = ScanPlanner(time: 0)
        p.budget = 12
        var t = 0.0
        for yaw in stride(from: Float(0), through: 180, by: 30) {
            for _ in 0..<60 {
                t += 1.0 / 30
                _ = p.update(time: t, cameraTransform: camera(yawDegrees: -yaw), busy: false, speaking: true)
            }
        }
        #expect(!p.mappingDone)
    }
}

@Suite struct SeeThroughTests {
    /// v9.2 log: the clear glass's LiDAR shape was the table behind it, 35 x 64 cm, for a box about 10 cm wide.
    @Test func shapeMuchWiderThanThePhotoBoxIsRejected() {
        let table = ObjectModel(points: [SIMD3(0, 0, 0), SIMD3(0.35, 0, 0), SIMD3(0, 0, 0.64), SIMD3(0.35, 0, 0.64)],
                                supportHeight: 0, isFlat: true)
        #expect(!table.fitsBox(0.10))
    }

    @Test func aNapkinOrABookFits() {
        let napkin = ObjectModel(points: [SIMD3(0, 0, 0), SIMD3(0.20, 0, 0), SIMD3(0, 0, 0.21), SIMD3(0.20, 0, 0.21)],
                                 supportHeight: 0, isFlat: true)
        #expect(napkin.fitsBox(0.12))
        #expect(napkin.fitsBox(0.22))
    }
}

@Suite struct HiddenBackTests {
    /// v9.4 device run (2026-11-03, Nils: "it doesn't identify the object entirely"): the lock saw only the front of
    /// a 6.5 cm vitamin bottle; the rolling scan saw its side and back from where the hand was, more than 4 cm from that
    /// front, and said "Something is ahead / on your right" about the bottle itself.
    @Test func theBackOfTheTargetIsNotAnObstacle() {
        // Front face 40 cm ahead of the lock camera, 6 cm wide, 10 cm tall, on a table at y = -0.06.
        var front: [SIMD3<Float>] = []
        for x in stride(from: Float(-0.03), through: 0.03, by: 0.01) {
            for y in stride(from: Float(-0.05), through: 0.04, by: 0.01) { front.append(SIMD3(x, y, -0.40)) }
        }
        var bottle = ObjectModel(points: front, supportHeight: -0.06, isFlat: false)
        bottle.viewFrom = .zero
        bottle.hiddenDepth = 0.065
        func blob(_ p: SIMD3<Float>) -> [SIMD3<Float>] {
            [-0.03, 0, 0.03].flatMap { dx in [0, 0.03].map { dy in p + SIMD3(dx, dy, 0) } }
        }
        let back = blob(SIMD3(0, 0, -0.455))          // its back, 5.5 cm behind the front
        let beside = blob(SIMD3(0.12, 0, -0.42))      // another bottle 6 cm to its right
        let camera = SIMD3<Float>(0.05, 0.1, 0)        // the user moved a little
        let map = ObstacleMap.scene(back + beside, object: bottle, camera: camera)!
        #expect(!map.points.contains { $0.z < -0.44 && abs($0.x) < 0.04 })
        #expect(map.points.contains { $0.x > 0.08 })
    }
}

@Suite struct GraspSessionTests {
    /// v6 (2026-10-29): a grip then lift no longer ends on geometry alone; it asks the app to check.
    @Test func gripThenLiftAsksForACheck() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        var s = GuidanceSession(targetName: "phone", target: m.centre, object: m, cameraTransform: downCamera, time: 0)
        let c = m.centre, hx = m.size.x / 2
        func grip(_ lift: Float) -> HandKeypoints {
            let up = SIMD3<Float>(0, lift, 0)
            return HandKeypoints(joints: [
                .thumbTip: c + up + SIMD3(-hx - 0.01, 0, 0), .indexTip: c + up + SIMD3(hx + 0.01, 0, 0),
                .middleTip: c + up + SIMD3(hx + 0.01, 0, 0.02), .wrist: c + up + SIMD3(0, 0.05, 0.08),
                .middleMCP: c + up + SIMD3(0, 0.05, 0.02),
            ])
        }
        var said: [String] = []
        var t = 0.0
        for lift: Float in Array(repeating: 0, count: 40) + stride(from: 0, through: 0.2, by: 0.01).map({ $0 })
            + Array(repeating: 0.2, count: 15) {
            t += 1.0 / 30
            let out = s.update(time: t, hand: grip(lift), cameraTransform: downCamera, targetDepthDelta: 0.005, speaking: false)
            said += out.lines.map(\.text)
        }
        #expect(said.contains { $0.hasSuffix("is at your fingers.") })
        #expect(said.last == "Checking.")
        #expect(s.phase == .checking)
        #expect(s.resolveCheck(true, time: t).first?.text == "Got it. You have the phone.")
        #expect(s.phase == .done)
    }

    @Test func touchWithoutGripAsksForACheck() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        var s = GuidanceSession(targetName: "phone", target: m.centre, object: m, cameraTransform: downCamera, time: 0)
        let c = m.centre
        func touch(_ lift: Float) -> HandKeypoints {
            let up = SIMD3<Float>(0, lift + 0.01, 0)
            return HandKeypoints(joints: [.indexTip: c + up, .middleTip: c + up + SIMD3(0.02, 0, 0),
                                          .wrist: c + up + SIMD3(0, 0.05, 0.1), .middleMCP: c + up + SIMD3(0, 0.04, 0.04)])
        }
        var asked = false
        var t = 0.0
        for lift: Float in Array(repeating: 0, count: 40) + stride(from: 0, through: 0.2, by: 0.01).map({ $0 })
            + Array(repeating: 0.2, count: 15) {
            t += 1.0 / 30
            asked = asked || s.update(time: t, hand: touch(lift), cameraTransform: downCamera,
                                      targetDepthDelta: 0.005, speaking: false).requestCheck
        }
        #expect(asked)
        #expect(s.phase == .checking)
        let reply = s.resolveCheck(false, time: t)
        // false = SAM still sees it at its spot: say so and guide again.
        #expect(reply.first?.text == "The phone is still there.")
        #expect(s.phase == .guiding)
    }

    /// Nils, 2026-10-30: the palm gives left/right only, the leading fingertip up/down and forward/back.
    @Test func guidePointTakesHeightAndForwardFromTheFingertip() {
        // Camera looking along -z (forward), level.
        let t = matrix_identity_float4x4
        let hand = HandKeypoints(joints: [
            .wrist: SIMD3(0.1, -0.2, -0.3), .middleMCP: SIMD3(0.1, -0.2, -0.4),
            .middleTip: SIMD3(0.12, -0.25, -0.5), .thumbTip: SIMD3(0.05, -0.22, -0.42),
        ])
        let p = GuidanceSession.guidePoint(hand, cameraTransform: t)!
        #expect(abs(p.x - 0.12) < 1e-5)
        #expect(abs(p.y - -0.25) < 1e-5)
        #expect(abs(p.z - -0.5) < 1e-5)
    }

    /// Nils, 2026-10-30 (v6 run): left/right first, then forward/back, then up/down.
    @Test func axisOrderIsSidewaysThenForwardThenDown() {
        #expect(StepGuide.dominantAxis(BodyOffset(right: 0.10, up: -0.30, forward: 0.20), tolerance: 0.03).0 == .right)
        #expect(StepGuide.dominantAxis(BodyOffset(right: 0.01, up: -0.30, forward: 0.20), tolerance: 0.03).0 == .forward)
        #expect(StepGuide.dominantAxis(BodyOffset(right: 0.01, up: -0.30, forward: 0.01), tolerance: 0.03).0 == .up)
    }

    /// v6 run: "Keep going down" with the fingers already on the table. At the support's height, never "down".
    @Test func noDownWhenFingersAreOnTheTable() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        var s = GuidanceSession(targetName: "phone", target: m.centre, object: m, cameraTransform: downCamera, time: 0)
        let support = try #require(m.supportHeight)
        // Fingertips on the table, left of and behind the phone; the palm 8 cm higher.
        let base = SIMD3<Float>(m.centre.x - m.size.x / 2 - 0.12, support, m.centre.z + m.size.z / 2 + 0.10)
        let hand = HandKeypoints(joints: [
            .indexTip: base, .middleTip: base + SIMD3(0.01, 0, 0.01), .thumbTip: base + SIMD3(-0.03, 0, 0.03),
            .wrist: base + SIMD3(0, 0.08, 0.12), .middleMCP: base + SIMD3(0, 0.08, 0.05),
        ])
        var said: [String] = []
        var t = 0.0
        for _ in 0..<150 {
            t += 1.0 / 30
            said += s.update(time: t, hand: hand, cameraTransform: downCamera, targetDepthDelta: 0, speaking: false).lines.map(\.text)
        }
        #expect(!said.contains { $0.lowercased().contains("down") })
        #expect(said.contains { $0.hasPrefix("Up") || $0 == "A little up." })
    }

    /// v6 run: the user grabbed the phone without "Grab it" and no check started. A fingertip that came
    /// near the object and then left asks for a check, even while guiding.
    @Test func nearThenLeftWhileGuidingAsksForACheck() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        var s = GuidanceSession(targetName: "phone", target: m.centre, object: m, cameraTransform: downCamera, time: 0)
        func hand(at tip: SIMD3<Float>) -> HandKeypoints {
            HandKeypoints(joints: [.indexTip: tip, .thumbTip: tip + SIMD3(-0.03, 0, 0.03),
                                   .wrist: tip + SIMD3(0, 0.08, 0.12), .middleMCP: tip + SIMD3(0, 0.08, 0.05)])
        }
        let far = m.centre + SIMD3(-0.3, 0.15, 0.2)
        let edge = m.nearestSurfacePoint(to: far) + SIMD3(0, 0.02, 0)
        var said: [String] = []
        var t = 0.0
        for p in Array(repeating: far, count: 60) + Array(repeating: edge, count: 10) + Array(repeating: far, count: 20) {
            t += 1.0 / 30
            said += s.update(time: t, hand: hand(at: p), cameraTransform: downCamera, targetDepthDelta: 0, speaking: false).lines.map(\.text)
            if s.phase == .checking { break }
        }
        #expect(said.last == "Checking.")
        #expect(s.phase == .checking)
    }

    /// A single fingertip on the surface counts; the palm alone (fingers curled up) does not.
    @Test func fingertipNotPalmDecidesTouch() throws {
        let (depth, mask, k) = tableScene(objectDepth: 0.79)
        let m = try #require(ObjectModel.build(mask: mask, depth: depth, intrinsics: k, cameraTransform: downCamera))
        let c = m.centre
        let tipOnly = HandKeypoints(joints: [.indexTip: c + SIMD3(0, 0.01, 0), .wrist: c + SIMD3(0, 0.08, 0.12),
                                             .middleMCP: c + SIMD3(0, 0.08, 0.05)])
        #expect(GraspAssessment.assess(tipOnly, object: m).touching)
        let palmOnly = HandKeypoints(joints: [.indexTip: c + SIMD3(0, 0.09, 0), .wrist: c + SIMD3(0, 0.02, 0.02),
                                              .middleMCP: c + SIMD3(0, 0.02, 0)])
        #expect(!GraspAssessment.assess(palmOnly, object: m).touching)
    }
}

@Suite struct VerticalSupportTests {
    @Test func doorRingIsVerticalTableRingIsNot() {
        // Door: a 14 cm x 14 cm patch in the x-y plane at z = -0.6.
        var door: [SIMD3<Float>] = []
        var table: [SIMD3<Float>] = []
        for i in 0..<15 {
            for j in 0..<15 {
                let a = Float(i) / 100 - 0.07, b = Float(j) / 100 - 0.07
                door.append(SIMD3(a, 0.9 + b, -0.6))
                table.append(SIMD3(a, 0.75 + Float((i * 7 + j) % 3) * 0.002, -0.6 + b))
            }
        }
        #expect(ObjectModel.isVertical(door))
        #expect(!ObjectModel.isVertical(table))
    }
}

/// Nils, 2026-10-29: "next to the hand" is not held; thumb + another fingertip on it, or on the palm, is.
@Suite struct HoldsTests {
    let phone: [SIMD3<Float>] = (0..<20).map { i in SIMD3(Float(i % 5) * 0.015, 0, Float(i / 5) * 0.03) }
    var centre: SIMD3<Float> { SIMD3(0.03, 0, 0.045) }

    @Test func thumbAndFingerOnItIsHeld() {
        let hand = HandKeypoints(joints: [.thumbTip: SIMD3(-0.01, 0, 0.04), .indexTip: SIMD3(0.07, 0, 0.05),
                                          .wrist: SIMD3(0.03, 0.05, 0.2), .middleMCP: SIMD3(0.03, 0.04, 0.12)])
        #expect(GraspAssessment.holds(hand, points: phone, centre: centre))
    }

    @Test func nextToTheHandIsNotHeld() {
        // Fingers 6 cm to the side, palm far: near, but not touching.
        let hand = HandKeypoints(joints: [.thumbTip: SIMD3(0.13, 0, 0.04), .indexTip: SIMD3(0.14, 0, 0.08),
                                          .wrist: SIMD3(0.2, 0.05, 0.2), .middleMCP: SIMD3(0.18, 0.04, 0.12)])
        #expect(!GraspAssessment.holds(hand, points: phone, centre: centre))
    }

    @Test func oneFingerOnlyIsNotHeld() {
        let hand = HandKeypoints(joints: [.indexTip: SIMD3(0.03, 0.01, 0.04),
                                          .wrist: SIMD3(0.03, 0.12, 0.25), .middleMCP: SIMD3(0.03, 0.1, 0.15)])
        #expect(!GraspAssessment.holds(hand, points: phone, centre: centre))
    }

    @Test func restingOnThePalmIsHeld() {
        let palmUnder = HandKeypoints(joints: [.wrist: SIMD3(0.03, -0.03, 0.08), .middleMCP: SIMD3(0.03, -0.03, 0.01)])
        #expect(GraspAssessment.holds(palmUnder, points: phone, centre: centre))
    }

    /// Rolling scan (v9.2): one scan alone (arm, flying pixels) adds nothing; the same cells twice in a row do.
    @Test func rollingScanNeedsTwoScansInARow() {
        var map = ObstacleMap(points: [])
        let bottle = (0..<5).map { SIMD3<Float>(0.1, 0.03 * Float($0), -0.4) }
        var last = map.merge(scan: ObstacleMap(points: bottle), previous: nil)
        #expect(map.points.isEmpty)
        last = map.merge(scan: ObstacleMap(points: bottle.map { $0 + [0.005, 0, 0] }), previous: last)
        #expect(map.points.count == 5)
        _ = map.merge(scan: ObstacleMap(points: [[0.5, 0.1, -0.4]]), previous: last)
        #expect(map.points.count == 5)
    }
    @Test func clustersSplitSeparateThings() {
        let a = (0..<5).map { SIMD3<Float>(0, 0.03 * Float($0), -0.4) }
        let b = (0..<4).map { SIMD3<Float>(0.3, 0.03 * Float($0), -0.4) }
        let c = ObstacleMap(points: a + b + [[0.6, 0, -0.4]]).clusters()
        #expect(c.count == 2 && c[0].count == 5 && abs(c[0].top - 0.12) < 0.001)
    }

    /// v9.2: no support height still gives a map; the table counts, except where the hand lands.
    @Test func noSupportKeepsTheTableExceptTheLandingPatch() {
        let obj = ObjectModel(points: (0..<5).map { SIMD3<Float>(0.01 * Float($0), 0.005, -0.5) }, supportHeight: nil, isFlat: true)
        let table: [SIMD3<Float>] = stride(from: Float(-0.4), through: 0.4, by: 0.03).flatMap { x in
            stride(from: Float(-0.8), through: -0.3, by: 0.03).map { z in SIMD3(x, 0, z) } }
        let map = ObstacleMap.scene(table, object: obj, camera: [0, 0.6, 0])
        #expect(map != nil)
        #expect(map!.points.contains { simd_distance($0, [0.3, 0, -0.5]) < 0.03 })
        #expect(!map!.points.contains { obj.horizontalDistance($0) < 0.08 })
    }
    /// The hand's own points go, a bottle 8 cm beside the fingertip stays (a 9 cm ball took it).
    @Test func carveHandKeepsThingsBesideTheHand() {
        let tip = SIMD3<Float>(0, 0.1, -0.5)
        // Along the hand toward the chest camera (where the arm comes from), 1 cm above the bones.
        let back = simd_normalize(SIMD3<Float>(0, 0.5, 0) - tip)
        let handSurface = (0..<10).map { tip + back * 0.015 * Float($0) + SIMD3<Float>(0, 0.01, 0) }
        let bottle = SIMD3<Float>(0.08, 0.1, -0.5)
        var map = ObstacleMap(points: handSurface + [bottle])
        map.carveHand([.indexTip: tip], camera: [0, 0.5, 0])
        #expect(map.points == [bottle])
    }
}
