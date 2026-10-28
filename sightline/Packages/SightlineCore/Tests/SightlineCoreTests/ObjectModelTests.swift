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
    @Test func gripThenLiftIsGotIt() throws {
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
        for lift: Float in Array(repeating: 0, count: 40) + stride(from: 0, through: 0.2, by: 0.01).map({ $0 }) {
            t += 1.0 / 30
            let out = s.update(time: t, hand: grip(lift), cameraTransform: downCamera, targetDepthDelta: 0.005, speaking: false)
            said += out.lines.map(\.text)
        }
        #expect(said.contains("Stop. It's at your hand. Grab it."))
        #expect(said.last == "Got it. Well done.")
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
        for lift: Float in Array(repeating: 0, count: 40) + stride(from: 0, through: 0.2, by: 0.01).map({ $0 }) {
            t += 1.0 / 30
            asked = asked || s.update(time: t, hand: touch(lift), cameraTransform: downCamera,
                                      targetDepthDelta: 0.005, speaking: false).requestCheck
        }
        #expect(asked)
        #expect(s.phase == .checking)
        let reply = s.resolveCheck(false, time: t)
        #expect(reply.first?.text.hasPrefix("I don't think you have") == true)
        #expect(s.phase == .guiding)
    }
}
