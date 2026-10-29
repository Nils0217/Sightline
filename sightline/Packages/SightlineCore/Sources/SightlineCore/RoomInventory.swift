// labels: production, needs-review, important
// Room object map (Nils, 2026-10-29: "scan the room once, build a 3D map, then use it to guess where
// the object is and guide the scan"). The app saves an ARWorldMap plus this inventory: object names
// with world positions (ARKit world of that map), from a one-time room scan (Muse Spark lists the
// objects in each view, LiDAR places them) and from every successful find ("last seen").
// Positions are only meaningful after ARKit relocalizes against the saved map.

import Foundation
import simd

public struct RoomItem: Codable, Sendable, Equatable {
    public var name: String
    public var position: [Float]
    public var seen: Date
    /// "room_scan" or "found".
    public var source: String

    public init(name: String, position: SIMD3<Float>, seen: Date, source: String) {
        self.name = name
        self.position = [position.x, position.y, position.z]
        self.seen = seen
        self.source = source
    }

    public var world: SIMD3<Float> { SIMD3(position[0], position[1], position[2]) }
}

public struct RoomInventory: Codable, Sendable, Equatable {
    public var items: [RoomItem] = []
    public var created: Date

    public init(created: Date) { self.created = created }

    /// Best item for a spoken noun: same word after singular/lowercase ("keys" = "key", "my water
    /// bottle" ~ "bottle"); a "found" entry beats a room-scan one; newest first.
    public func match(_ noun: String) -> RoomItem? {
        let want = Self.words(noun)
        guard !want.isEmpty else { return nil }
        let hits = items.filter { !Self.words($0.name).isDisjoint(with: want) }
        return hits.max { a, b in
            let sa = Self.words(a.name) == want ? 1 : 0, sb = Self.words(b.name) == want ? 1 : 0
            if sa != sb { return sa < sb }
            if (a.source == "found") != (b.source == "found") { return b.source == "found" }
            return a.seen < b.seen
        }
    }

    /// Adds or moves an item. Same name within 50 cm = the same thing seen again.
    public mutating func remember(_ name: String, at p: SIMD3<Float>, date: Date, source: String) {
        let key = Self.words(name)
        if let i = items.firstIndex(where: { Self.words($0.name) == key && simd_distance($0.world, p) < 0.5 }) {
            items[i] = RoomItem(name: name, position: p, seen: date, source: source)
        } else if source == "found", let i = items.firstIndex(where: { Self.words($0.name) == key && $0.source == "found" }) {
            items[i] = RoomItem(name: name, position: p, seen: date, source: source)  // it moved
        } else {
            items.append(RoomItem(name: name, position: p, seen: date, source: source))
        }
    }

    /// "Your keys were last seen to your right, about 1 metre away."
    public static func hint(_ item: RoomItem, noun: String, cameraTransform t: simd_float4x4) -> String {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let o = BodyOffset(from: camera, to: item.world, cameraTransform: t)
        let dist = (o.right * o.right + o.forward * o.forward).squareRoot()
        let place: String
        if o.forward < -0.2 { place = o.right >= 0 ? "behind you, on your right" : "behind you, on your left" }
        else if abs(o.right) < 0.15 { place = "ahead of you" }
        else { place = o.right > 0 ? "to your right" : "to your left" }
        let howFar = dist < 1 ? "about \(max(1, Int((dist * 10).rounded())) * 10) centimetres" : String(format: "about %.0f metre%@", dist.rounded(), dist.rounded() == 1 ? "" : "s")
        let verb = noun.hasSuffix("s") && !noun.hasSuffix("ss") ? "were" : "was"
        return "Your \(noun) \(verb) last seen \(place), \(howFar) away."
    }

    /// Objects from a Muse Spark room-scan reply: `{"objects":[{"name":"keys","x":0.4,"y":0.6}]}`
    /// (x, y normalized on the photo, origin top-left). Tolerates text around the JSON.
    public static func parseSparkObjects(_ text: String) -> [(name: String, point: SIMD2<Float>)] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["objects"] as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty,
                  let x = (o["x"] as? NSNumber)?.floatValue, let y = (o["y"] as? NSNumber)?.floatValue,
                  (0...1).contains(x), (0...1).contains(y) else { return nil }
            return (name.lowercased(), SIMD2(x, y))
        }
    }

    /// World position of a point Spark named on a portrait photo (x, y in 0...1, origin top-left):
    /// nearest LiDAR cluster in a 5x5 window (medium confidence), unprojected. nil without depth.
    public static func place(portrait p: SIMD2<Float>, depth: DepthImage, intrinsics: CameraIntrinsics,
                             cameraTransform t: simd_float4x4) -> SIMD3<Float>? {
        // Portrait = raw rotated 90° clockwise: raw.x = portrait.y, raw.y = 1 - portrait.x.
        let raw = SIMD2(p.y, 1 - p.x)
        let size = SIMD2(Float(depth.width), Float(depth.height))
        let pixel = raw * size - 0.5
        var sampler = DepthSampler()
        sampler.radius = 2
        sampler.minConfidence = 1
        sampler.fallback = (radius: 4, minConfidence: 0)
        guard case .success(let d) = sampler.sample(depth, at: pixel) else { return nil }
        let k = intrinsics.scaled(to: size)
        return DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: pixel, depth: d.depth, intrinsics: k),
                                    cameraTransform: t)
    }

    static let stopWords: Set<String> = ["my", "the", "a", "an", "of", "some", "pair"]

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { !stopWords.contains($0) }
            .map { w in w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : w })
    }
}

extension SAMRecord {
    /// A record from SAM on a tile, moved into the coordinates of the full image the tile was cut
    /// from (same scale). The mask raster is unchanged; only its placement moves.
    public func placed(atTileOrigin o: SIMD2<Int>, fullSize: SIMD2<Int>) -> SAMRecord {
        var r = self
        r.left += o.x; r.right += o.x
        r.top += o.y; r.bottom += o.y
        r.sourceWidth = fullSize.x
        r.sourceHeight = fullSize.y
        return r
    }
}

/// Small things SAM misses at 512 px across a room (2026-10-29: keys were 12x16 px).
public enum SmallObjects {
    static let nouns: Set<String> = ["key", "ring", "earring", "coin", "pill", "battery", "airpod", "earbud",
                                     "pen", "pencil", "card", "lipstick", "usb", "charger", "remote", "watch",
                                     "glasses", "sunglasses", "lighter", "keychain", "hairpin", "button"]

    public static func isSmall(_ noun: String) -> Bool { !RoomInventory.words(noun).isDisjoint(with: nouns) }

    /// 2x2 tiles with 10 % overlap: origins and size in pixels of an image `size`.
    public static func tiles(for size: SIMD2<Int>) -> [(origin: SIMD2<Int>, size: SIMD2<Int>)] {
        let w = Int((Float(size.x) * 0.55).rounded()), h = Int((Float(size.y) * 0.55).rounded())
        let xs = [0, size.x - w], ys = [0, size.y - h]
        return ys.flatMap { y in xs.map { x in (SIMD2(x, y), SIMD2(w, h)) } }
    }

    /// Recorded `sam.txt` of a tiled call: the tiles' SAM outputs joined by this line.
    public static let separator = "\n#tile\n"

    /// Records of all tiles, moved into full-image coordinates (`origins` in tile order).
    public static func parseTiled(_ text: String, origins: [SIMD2<Int>], fullSize: SIMD2<Int>) -> [SAMRecord] {
        let parts = text.components(separatedBy: separator)
        return zip(parts, origins).flatMap { part, o in SAMParser.parse(part).map { $0.placed(atTileOrigin: o, fullSize: fullSize) } }
    }
}
