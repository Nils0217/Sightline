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
        #expect(said.contains { $0.contains("contact is not confirmed") })
        #expect(said.last == "Checking.")
        #expect(s.phase == .checking)
        #expect(s.resolveCheck(true, time: t).first?.text == "Confirmed. You have the phone.")
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
        #expect(reply.first?.text.hasPrefix("I cannot confirm") == true)
        #expect(s.phase == .grabbing)
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
        #expect(said.contains { $0.hasPrefix("Move your hand up") })
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
}
