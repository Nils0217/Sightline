// labels: testing, needs-review
import Testing
@testable import SightlineCore

struct SparkPickTests {
    @Test func readsAPick() {
        let p = SparkPick.parse(#"Sure: {"want":"Phone","visible":true,"x":0.25,"y":0.5,"sam":"cell phone","how":"grey, left"}"#)
        #expect(p == SparkPick(want: "phone", visible: true, x: 0.25, y: 0.5, sam: "cell phone", how: "grey, left"))
        #expect(p?.pixel(in: SIMD2(400, 800)) == SIMD2(100, 400))
    }

    @Test func notVisibleOrNoPointIsNotAPick() {
        #expect(SparkPick.parse(#"{"want":"pill bottle","visible":false}"#)?.visible == false)
        #expect(SparkPick.parse(#"{"want":"pill bottle","visible":true,"x":1.4,"y":0.2}"#)?.visible == false)
        #expect(SparkPick.parse("no json") == nil)
    }

    @Test func samNameFallsBackToWhatTheyWant() {
        #expect(SparkPick.parse(#"{"want":"phone","visible":true,"x":0.5,"y":0.5}"#)?.sam == "phone")
    }

    /// T17: two phones outlined; Spark's point picks the one it means, not SAM's most confident.
    @Test func thePointChoosesTheOutline() {
        let size = SIMD2(400, 400)
        let a = SparkPick.pointMask(at: SIMD2(100, 100), side: 40, imageSize: size)
        let b = SparkPick.pointMask(at: SIMD2(300, 300), side: 40, imageSize: size)
        #expect(SparkPick.choose([a, b], at: SIMD2(305, 295)) == 1)
        #expect(SparkPick.choose([a, b], at: SIMD2(200, 200)) == nil)
    }

    /// Spark's point just beside a thin outline still takes it, within `near` only.
    @Test func aPointJustBesideTakesTheNearestOutline() {
        let size = SIMD2(400, 400)
        let phone = SparkPick.pointMask(at: SIMD2(100, 100), side: 20, imageSize: size)  // 90..<110
        #expect(SparkPick.choose([phone], at: SIMD2(115, 100), near: 10) == 0)
        #expect(SparkPick.choose([phone], at: SIMD2(140, 100), near: 10) == nil)
    }

    /// The crop around the pick takes the pick in 0-1 (T17 follow-up: pixels put every crop in the corner).
    @Test func theCropIsCentredOnThePick() {
        let pick = SparkPick(want: "phone", visible: true, x: 0.3, y: 0.4)
        let size = SIMD2(698, 930)
        let tile = SmallObjects.tile(around: SIMD2(pick.x, pick.y), in: size)
        let p = pick.pixel(in: size)
        #expect(p.x >= tile.origin.x && p.x < tile.origin.x + tile.size.x)
        #expect(p.y >= tile.origin.y && p.y < tile.origin.y + tile.size.y)
        #expect(tile.origin.x > 0 && tile.origin.x + tile.size.x < size.x)
    }

    /// T18: look-alikes are counted, and a closer look on a crop maps back onto the whole photo.
    @Test func aCloserLookMapsBackToThePhoto() {
        let p = SparkPick.parse(#"{"want":"vitamin","visible":true,"x":0.5,"y":0.5,"similar":1}"#)
        #expect(p?.similar == 1)
        let close = SparkPick(want: "vitamin", visible: true, x: 0.5, y: 0.25)
        let full = close.onPhoto(cropOrigin: SIMD2(100, 200), cropSize: SIMD2(400, 400), full: SIMD2(800, 1000))
        #expect(abs(full.x - 0.375) < 0.001 && abs(full.y - 0.3) < 0.001)
    }

    @Test func aPointMaskStaysInsideThePhoto() {
        let m = SparkPick.pointMask(at: SIMD2(2, 398), side: 30, imageSize: SIMD2(400, 400))
        #expect(m.record.left == 0 && m.record.bottom == 400 && m.raster.allSatisfy { $0 == 1 })
        #expect(m.contains(5, 395))
    }
}
