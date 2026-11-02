// labels: production, needs-review, important
// Room object map (Nils, 2026-10-29: "scan the room once, build a 3D map, then use it to guess where
// the object is and guide the scan"). The app saves an ARWorldMap plus this inventory: object names
// with world positions (ARKit world of that map), from a one-time room scan (Muse Spark lists the
// objects in each view, LiDAR places them) and from every successful find ("last seen").
// Positions are only meaningful in the saved map's frame: after ARKit relocalizes against it, or after a
// landmark alignment (`alignment(to:)`, 2026-11-01). Relations (`relation`) need neither.

import Foundation
import simd

public struct RoomItem: Codable, Sendable, Equatable {
    public var name: String
    public var position: [Float]
    public var seen: Date
    /// "room_scan" or "found".
    public var source: String
    /// What it stands on, as Spark named it in the room scan ("desk", "shelf"); nil when unknown.
    public var on: String?
    /// Furniture or a big thing that does not move (desk, shelf, lamp): a landmark for aligning the map.
    public var fixed: Bool?

    public init(name: String, position: SIMD3<Float>, seen: Date, source: String, on: String? = nil, fixed: Bool? = nil) {
        self.name = name
        self.position = [position.x, position.y, position.z]
        self.seen = seen
        self.source = source
        self.on = on
        self.fixed = fixed
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

    /// Adds or moves an item. Same name within 50 cm = the same thing seen again (keeps what it stands on and
    /// whether it is fixed when the new sighting does not say).
    public mutating func remember(_ name: String, at p: SIMD3<Float>, date: Date, source: String,
                                  on: String? = nil, fixed: Bool? = nil) {
        let key = Self.words(name)
        if let i = items.firstIndex(where: { Self.words($0.name) == key && simd_distance($0.world, p) < 0.5 }) {
            items[i] = RoomItem(name: name, position: p, seen: date, source: source, on: on ?? items[i].on, fixed: fixed ?? items[i].fixed)
        } else if source == "found", let i = items.firstIndex(where: { Self.words($0.name) == key && $0.source == "found" }) {
            items[i] = RoomItem(name: name, position: p, seen: date, source: source, on: on, fixed: fixed)  // it moved
        } else {
            items.append(RoomItem(name: name, position: p, seen: date, source: source, on: on, fixed: fixed))
        }
    }

    // MARK: Relations (Nils, 2026-11-01: let the LLM read the map and infer from related things)
    //
    // Positions need the map's frame; relations do not. "On the desk, next to the laptop" still holds after a
    // relaunch with no ARKit match, and a blind user knows their own furniture.

    /// Up to `limit` other things within 80 cm, nearest first (different names only).
    public func neighbours(of item: RoomItem, limit: Int = 2) -> [(item: RoomItem, distance: Float)] {
        let key = Self.words(item.name)
        // The surface it stands on is said as "on the desk", not again as a neighbour.
        var seen: Set<Set<String>> = [key]
        if let on = item.on { seen.insert(Self.words(on)) }
        var out: [(item: RoomItem, distance: Float)] = []
        for other in items.sorted(by: { simd_distance($0.world, item.world) < simd_distance($1.world, item.world) }) {
            let d = simd_distance(other.world, item.world)
            guard d <= 0.8, out.count < limit else { break }
            let k = Self.words(other.name)
            if seen.contains(k) { continue }
            seen.insert(k)
            out.append((other, d))
        }
        return out
    }

    /// "on the desk, next to the laptop and the kettle"; "" when nothing is known.
    public func relation(_ item: RoomItem) -> String {
        var parts: [String] = []
        if let on = item.on, !on.isEmpty { parts.append("on the \(on)") }
        let near = neighbours(of: item).map { "the \($0.item.name)" }
        if !near.isEmpty { parts.append("next to " + near.joined(separator: " and ")) }
        return parts.joined(separator: ", ")
    }

    /// One line per item for Spark when no direction is known: "3. tumbler: on the desk, next to the laptop
    /// (seen 2 h ago)". Numbered like `describe`.
    public func describeRelations(now: Date, limit: Int = 40) -> String {
        items.prefix(limit).enumerated().map { i, item in
            let rel = relation(item)
            return "\(i). \(item.name)" + (rel.isEmpty ? "" : ": \(rel)") + (item.fixed == true ? " [fixed]" : "")
                + " (seen \(Self.age(item.seen, now: now)))"
        }.joined(separator: "\n")
    }

    /// "Your tumbler was on the desk, next to the laptop." nil when there is no relation to say.
    public func relationHint(_ item: RoomItem, noun: String) -> String? {
        let rel = relation(item)
        guard !rel.isEmpty else { return nil }
        let verb = noun.hasSuffix("s") && !noun.hasSuffix("ss") ? "were" : "was"
        return "Your \(noun) \(verb) \(rel)."
    }

    static func age(_ d: Date, now: Date) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 60 { return "\(max(1, m)) min ago" }
        if m < 48 * 60 { return "\(m / 60) h ago" }
        return "\(m / 1440) days ago"
    }

    // MARK: Landmark alignment (C): the saved map's frame from things seen now, without ARKit relocalization

    /// Transform taking saved-map positions into the current ARKit world: a turn about the vertical axis plus a
    /// shift (both frames have gravity as y). Needs 3 things that agree within `tolerance`, or 2 fixed ones;
    /// a moved cup does not agree and is left out. nil = not enough agreement.
    public static let alignTolerance: Float = 0.25

    public func alignment(to seen: [(name: String, world: SIMD3<Float>)]) -> (transform: simd_float4x4, inliers: [String])? {
        // Every saved item with the same name as something seen now (duplicates allowed; RANSAC sorts them out).
        var pairs: [(saved: RoomItem, now: SIMD3<Float>)] = []
        for o in seen {
            let k = Self.words(o.name)
            for item in items where Self.words(item.name) == k { pairs.append((item, o.world)) }
        }
        guard pairs.count >= 2 else { return nil }
        func xz(_ v: SIMD3<Float>) -> SIMD2<Float> { SIMD2(v.x, v.z) }
        var best: (inliers: [Int], error: Float)?
        for i in pairs.indices {
            for j in pairs.indices where j > i && Self.words(pairs[i].saved.name) != Self.words(pairs[j].saved.name) {
                let s = xz(pairs[j].saved.world) - xz(pairs[i].saved.world), n = xz(pairs[j].now) - xz(pairs[i].now)
                // A rigid move keeps the distance between two things; two near each other give no direction.
                guard simd_length(s) >= 0.3, abs(simd_length(s) - simd_length(n)) < 0.15 else { continue }
                let t = Self.transform(from: [pairs[i].saved.world, pairs[j].saved.world], to: [pairs[i].now, pairs[j].now])
                var inl: [Int] = [], err: Float = 0
                var used: Set<Set<String>> = []
                for (k, p) in pairs.enumerated() {
                    let d = simd_distance(Self.apply(t, p.saved.world), p.now)
                    let key = Self.words(p.saved.name)
                    if d <= Self.alignTolerance, !used.contains(key) { inl.append(k); err += d; used.insert(key) }
                }
                if best == nil || inl.count > best!.inliers.count || (inl.count == best!.inliers.count && err < best!.error) {
                    best = (inl, err)
                }
            }
        }
        guard let b = best else { return nil }
        let fixedCount = b.inliers.filter { pairs[$0].saved.fixed == true }.count
        guard b.inliers.count >= 3 || (b.inliers.count == 2 && fixedCount == 2) else { return nil }
        let t = Self.transform(from: b.inliers.map { pairs[$0].saved.world }, to: b.inliers.map { pairs[$0].now })
        return (t, b.inliers.map { pairs[$0].saved.name })
    }

    /// Least-squares turn about y + shift (2D Kabsch on x, z; mean y offset).
    static func transform(from a: [SIMD3<Float>], to b: [SIMD3<Float>]) -> simd_float4x4 {
        let n = Float(a.count)
        let ca = a.reduce(SIMD3<Float>(repeating: 0), +) / n, cb = b.reduce(SIMD3<Float>(repeating: 0), +) / n
        var dot: Float = 0, cross: Float = 0
        for (p, q) in zip(a, b) {
            let u = p - ca, v = q - cb
            dot += u.x * v.x + u.z * v.z
            cross += u.x * v.z - u.z * v.x
        }
        let angle = atan2(cross, dot), c = cos(angle), s = sin(angle)
        // (x, z) -> (c x - s z, s x + c z)
        let rx = c * ca.x - s * ca.z, rz = s * ca.x + c * ca.z
        return simd_float4x4(columns: (SIMD4(c, 0, s, 0), SIMD4(0, 1, 0, 0), SIMD4(-s, 0, c, 0),
                                       SIMD4(cb.x - rx, cb.y - ca.y, cb.z - rz, 1)))
    }

    public static func apply(_ t: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = t * SIMD4(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    /// The inventory with every position moved by `t` (saved frame -> current world).
    public func transformed(by t: simd_float4x4) -> RoomInventory {
        var out = self
        out.items = items.map { item in
            var i = item
            let p = Self.apply(t, item.world)
            i.position = [p.x, p.y, p.z]
            return i
        }
        return out
    }

    /// The things a user is likely to ask for first (v5: the summary read "backpack, bag, basket, beige cloth").
    public func summaryNames() -> [String] {
        let useful = ["key", "phone", "wallet", "glasses", "remote", "bottle", "cup", "mug", "book", "laptop", "headphone",
                      "charger", "bag", "backpack", "toothbrush", "medicine", "watch", "earbud"]
        let names = Array(Set(items.map(\.name)))
        // Whole words: "garbage" is not a "bag" (Muse review 2026-10-30); "keys" counts as "key".
        func rank(_ n: String) -> Int {
            let words = Self.words(n)
            return useful.firstIndex { words.contains($0) } ?? useful.count
        }
        return Array(names.sorted { (rank($0), $0) < (rank($1), $1) }.prefix(5))
    }

    /// The user picked the object up (v5 test: the hint then pointed at the empty spot where the keys had
    /// been lifted). It is with the user now: forget where it was, both found and room-scan entries.
    public mutating func carried(_ name: String, from p: SIMD3<Float>?) {
        let key = Self.words(name)
        items.removeAll { item in
            Self.words(item.name) == key && (item.source == "found" || p.map { simd_distance(item.world, $0) < 0.5 } ?? false)
        }
    }

    /// "Your keys were last seen a quarter turn to your right, about 1 metre away."
    public static func hint(_ item: RoomItem, noun: String, cameraTransform t: simd_float4x4) -> String {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let o = BodyOffset(from: camera, to: item.world, cameraTransform: t)
        let dist = (o.right * o.right + o.forward * o.forward).squareRoot()
        let place = Self.place(o)
        let howFar = dist < 1 ? "about \(max(1, Int((dist * 10).rounded())) * 10) centimetres" : String(format: "about %.0f metre%@", dist.rounded(), dist.rounded() == 1 ? "" : "s")
        let verb = noun.hasSuffix("s") && !noun.hasSuffix("ss") ? "were" : "was"
        return "Your \(noun) \(verb) last seen \(place), \(howFar) away."
    }

    /// Where an offset is, with how far to turn: "ahead of you", "a quarter turn to your left",
    /// "behind you, half a turn to your right".
    public static func place(_ o: BodyOffset) -> String {
        let yaw = atan2(o.right, o.forward)  // + = right
        let deg = abs(yaw) * 180 / .pi
        let side = yaw > 0 ? "right" : "left"
        if deg < 20 { return "ahead of you" }
        if deg < TurnSize.littleBelow { return "ahead, a little to your \(side)" }
        if deg < TurnSize.quarterBelow { return "a quarter turn to your \(side)" }
        return "behind you, half a turn to your \(side)"
    }

    /// Items as Spark sees them for a guess: number, name, metres right / forward / up of the user.
    public func describe(from t: simd_float4x4, now: Date, limit: Int = 40) -> String {
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return items.prefix(limit).enumerated().map { i, item in
            let o = BodyOffset(from: camera, to: item.world, cameraTransform: t)
            let rel = relation(item)
            return String(format: "%d. %@: %.1f m right, %.1f m forward, %.1f m up", i, item.name, o.right, o.forward, o.up)
                + (rel.isEmpty ? "" : ", " + rel)
        }.joined(separator: "\n")
    }

    public struct SparkObject: Sendable, Equatable {
        public var name: String
        public var point: SIMD2<Float>
        /// What it stands on ("desk"), when Spark said.
        public var on: String?
        public var fixed: Bool
    }

    /// Objects from a Muse Spark room-scan reply:
    /// `{"objects":[{"name":"keys","x":0.4,"y":0.6,"on":"desk","fixed":false}]}` (x, y normalized on the photo,
    /// origin top-left; `on` and `fixed` optional). Tolerates text around the JSON.
    public static func parseSparkObjects(_ text: String) -> [SparkObject] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["objects"] as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            guard let name = o["name"] as? String, !name.isEmpty,
                  let x = (o["x"] as? NSNumber)?.floatValue, let y = (o["y"] as? NSNumber)?.floatValue,
                  (0...1).contains(x), (0...1).contains(y) else { return nil }
            let on = (o["on"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
            return SparkObject(name: name.lowercased(), point: SIMD2(x, y), on: on?.isEmpty == false && on != "null" ? on : nil,
                               fixed: (o["fixed"] as? Bool) ?? false)
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

/// Turn sizes in spoken directions (degrees from straight ahead), shared by RoomInventory.place and
/// ScanPlanner.turn so both say the same thing for the same angle.
public enum TurnSize {
    /// Below this: "a little".
    public static let littleBelow: Float = 50
    /// Below this: "a quarter turn"; above: "half a turn".
    public static let quarterBelow: Float = 125
}
