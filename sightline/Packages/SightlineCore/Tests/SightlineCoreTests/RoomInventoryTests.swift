// labels: testing, needs-review
import Foundation
import simd
import Testing
@testable import SightlineCore

@Suite struct RoomInventoryTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func matchesPluralsAndPartialNames() {
        var inv = RoomInventory(created: t0)
        inv.remember("keys", at: [1, 0, 0], date: t0, source: "room_scan")
        inv.remember("water bottle", at: [0, 0, -1], date: t0, source: "room_scan")
        #expect(inv.match("key")?.name == "keys")
        #expect(inv.match("my keys")?.name == "keys")
        #expect(inv.match("bottle")?.name == "water bottle")
        #expect(inv.match("phone") == nil)
    }

    @Test func foundBeatsRoomScanAndMovesWithTheObject() {
        var inv = RoomInventory(created: t0)
        inv.remember("phone", at: [1, 0, 0], date: t0, source: "room_scan")
        inv.remember("phone", at: [0, 0, -2], date: t0.addingTimeInterval(10), source: "found")
        inv.remember("phone", at: [2, 0, -2], date: t0.addingTimeInterval(20), source: "found")
        #expect(inv.items.count == 2)
        #expect(inv.match("phone")?.world == SIMD3(2, 0, -2))
    }

    @Test func hintSaysSideAndDistance() {
        var inv = RoomInventory(created: t0)
        inv.remember("keys", at: [1.0, 0, -0.3], date: t0, source: "found")
        let text = RoomInventory.hint(inv.match("keys")!, noun: "keys", cameraTransform: matrix_identity_float4x4)
        #expect(text == "Your keys were last seen a quarter turn to your right, about 1 metre away.")
        let behind = RoomItem(name: "cup", position: [-0.5, 0, 1.5], seen: t0, source: "found")
        #expect(RoomInventory.hint(behind, noun: "cup", cameraTransform: matrix_identity_float4x4)
                == "Your cup was last seen behind you, half a turn to your left, about 2 metres away.")
    }

    @Test func parsesSparkObjectList() {
        let reply = #"Here: {"objects":[{"name":"Keys","x":0.42,"y":0.61},{"name":"mug","x":1.4,"y":0.2},{"name":"book","x":0.1,"y":0.9}]}"#
        let objects = RoomInventory.parseSparkObjects(reply)
        #expect(objects.map(\.name) == ["keys", "book"])
        #expect(objects[0].point == SIMD2(0.42, 0.61))
        #expect(RoomInventory.parseSparkObjects("no json").isEmpty)
    }

    @Test func tileRecordMovesIntoFullImage() {
        let r = SAMRecord(id: "0", left: 10, top: 20, right: 30, bottom: 40, sourceWidth: 384, sourceHeight: 512,
                          confidence: 0.7, maskWidth: 20, maskHeight: 20, payload: "")
        let tiles = SmallObjects.tiles(for: SIMD2(698, 930))
        #expect(tiles.count == 4)
        #expect(tiles[3].origin == SIMD2(698 - 384, 930 - 512))
        let placed = r.placed(atTileOrigin: tiles[3].origin, fullSize: SIMD2(698, 930))
        #expect(placed.left == 10 + 314 && placed.top == 20 + 418)
        #expect(placed.sourceWidth == 698 && placed.maskWidth == 20)
        #expect(SmallObjects.isSmall("my keys") && !SmallObjects.isSmall("water bottle"))
    }

    /// v5 test: after the keys were picked up, the hint still pointed at the spot they were lifted from.
    @Test func carriedObjectIsForgotten() {
        var inv = RoomInventory(created: t0)
        inv.remember("keys", at: [1, 0, 0], date: t0, source: "room_scan")
        inv.remember("key", at: [1.1, 0, 0], date: t0, source: "found")
        inv.remember("keys", at: [-2, 0, 0], date: t0, source: "room_scan")
        inv.remember("cup", at: [1, 0, 0], date: t0, source: "room_scan")
        inv.carried("key", from: [1.1, 0, 0])
        #expect(inv.items.map(\.name).sorted() == ["cup", "keys"])
        #expect(inv.match("key")?.world == SIMD3<Float>(-2, 0, 0))
    }
}

@Suite struct RoomPlacementTests {
    @Test func sparkPointLandsOnTheObjectDepth() throws {
        let (depth, _, k) = tableScene(objectDepth: 0.6)
        // Object centre in raw depth pixels (15, 10) of 40x30 -> portrait normalized (1 - ry, rx).
        let raw = SIMD2<Float>(15.5 / 40, 10.5 / 30)
        let p = try #require(RoomInventory.place(portrait: SIMD2(1 - raw.y, raw.x), depth: depth, intrinsics: k,
                                                 cameraTransform: downCamera))
        #expect(abs(p.y - -0.6) < 0.01)
    }

    @Test func mapCommand() {
        #expect(CommandParser.parse("scan the room") == .mapRoom)
        #expect(CommandParser.parse("Sightline, map my room please") == .mapRoom)
        #expect(CommandParser.parse("Scanner room") == .mapRoom)  // v5 mishearing
        #expect(CommandParser.parse("find the room key") == .find("room key"))
        #expect(CommandParser.parse("find the room key") == .find("room key"))
    }
}

@Suite struct ScanDirectionTests {
    func camera(yaw: Float) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: -yaw * .pi / 180, axis: SIMD3(0, 1, 0))) }

    @Test func pointsToTheNearestUnsearchedSide() {
        var p = ScanPlanner(time: 0)
        for y: Float in [-15, 15, 45] { p.markSearched(cameraTransform: camera(yaw: y)) }
        // Facing 45° right, searched -15..45: nearest unsearched is further right.
        #expect(p.directionPrompt(cameraTransform: camera(yaw: 45)) == "Turn right slowly. I haven't looked there yet.")
    }

    @Test func turnsTowardTheRoomMapHint() {
        var p = ScanPlanner(time: 0)
        p.markSearched(cameraTransform: camera(yaw: 0))
        p.hint = SIMD3(-1, -0.3, 0)  // to the left
        #expect(p.directionPrompt(cameraTransform: camera(yaw: 0)) == "Turn left, about a quarter turn, toward where I last saw it.")
    }

    @Test func asksToLookLowerAfterAFullCircle() {
        var p = ScanPlanner(time: 0)
        for s in 0..<12 { p.markSearched(cameraTransform: camera(yaw: Float(s) * 30 - 165)) }
        #expect(p.directionPrompt(cameraTransform: camera(yaw: 0)).hasPrefix("Point the phone lower"))
    }
}

/// Nils, 2026-11-01: ARKit never matched the saved map at launch; use relations and things seen now instead.
@Suite struct RoomRelationTests {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    func room() -> RoomInventory {
        var inv = RoomInventory(created: t0)
        inv.remember("desk", at: [0, 0.75, -1], date: t0, source: "room_scan", fixed: true)
        inv.remember("laptop", at: [0.3, 0.8, -1], date: t0, source: "room_scan", on: "desk")
        inv.remember("tumbler", at: [0.1, 0.85, -1.1], date: t0, source: "room_scan", on: "desk")
        inv.remember("lamp", at: [-0.6, 1.1, -1.2], date: t0, source: "room_scan", fixed: true)
        inv.remember("shelf", at: [1.5, 1.0, 0.5], date: t0, source: "room_scan", fixed: true)
        inv.remember("cup", at: [1.4, 1.2, 0.4], date: t0, source: "room_scan", on: "shelf")
        return inv
    }

    @Test func relationNamesTheSurfaceAndNearestThings() {
        let inv = room()
        let tumbler = inv.match("tumbler")!
        #expect(inv.relation(tumbler) == "on the desk, next to the laptop and the lamp")
        #expect(inv.relationHint(tumbler, noun: "tumbler") == "Your tumbler was on the desk, next to the laptop and the lamp.")
        #expect(inv.describeRelations(now: t0.addingTimeInterval(7200)).contains("2. tumbler: on the desk"))
    }

    @Test func savedRelationsSurviveOldFiles() throws {
        // inventory.json written before 2026-11-01 has no "on" / "fixed".
        let json = #"{"created":"2026-11-01T23:00:25Z","items":[{"name":"laptop","position":[0.27,0.07,-0.05],"seen":"2026-11-01T23:00:55Z","source":"room_scan"}]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let inv = try d.decode(RoomInventory.self, from: Data(json.utf8))
        #expect(inv.items[0].on == nil && inv.items[0].fixed == nil)
    }

    func moved(_ inv: RoomInventory, degrees: Float, shift: SIMD3<Float>) -> [(name: String, world: SIMD3<Float>)] {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        return inv.items.map { i in
            let p = i.world
            return (i.name, SIMD3(c * p.x - s * p.z, p.y, s * p.x + c * p.z) + shift)
        }
    }

    @Test func recoversTheTurnAndShift() throws {
        let inv = room()
        var seen = moved(inv, degrees: 70, shift: [0.4, -0.1, 2])
        seen.removeAll { $0.name == "shelf" || $0.name == "cup" }
        let r = try #require(inv.alignment(to: seen))
        #expect(r.inliers.count == 4)
        let shelfNow = moved(inv, degrees: 70, shift: [0.4, -0.1, 2]).first { $0.name == "shelf" }!.world
        #expect(simd_distance(RoomInventory.apply(r.transform, inv.match("shelf")!.world), shelfNow) < 0.01)
    }

    @Test func aMovedCupIsLeftOut() throws {
        let inv = room()
        var seen = moved(inv, degrees: -30, shift: [1, 0, 0])
        if let i = seen.firstIndex(where: { $0.name == "tumbler" }) { seen[i].world += SIMD3(0.6, 0, 0.4) }
        let r = try #require(inv.alignment(to: seen))
        #expect(!r.inliers.contains("tumbler"))
        #expect(r.inliers.count >= 4)
    }

    @Test func twoMovableThingsAreNotEnough() {
        let inv = room()
        let seen = moved(inv, degrees: 20, shift: [0, 0, 0]).filter { $0.name == "laptop" || $0.name == "cup" }
        #expect(inv.alignment(to: seen) == nil)
    }

    @Test func twoFixedThingsAreEnough() {
        let inv = room()
        let seen = moved(inv, degrees: 20, shift: [0, 0, 1]).filter { $0.name == "lamp" || $0.name == "shelf" }
        #expect(inv.alignment(to: seen) != nil)
    }

    @Test func parsesSurfaceAndFixed() {
        let o = RoomInventory.parseSparkObjects(#"{"objects":[{"name":"Desk","x":0.5,"y":0.7,"fixed":true},{"name":"mug","x":0.4,"y":0.5,"on":"desk"}]}"#)
        #expect(o.map(\.fixed) == [true, false])
        #expect(o[1].on == "desk" && o[0].on == nil)
    }
}
