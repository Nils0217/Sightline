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
    /// "room_scan", "found" or "seen" (listed by Spark in a later view, 2026-11-02).
    public var source: String
    /// What it stands on, as Spark named it in the room scan ("desk", "shelf"); nil when unknown.
    public var on: String?
    /// Furniture or a big thing that does not move (desk, shelf, lamp): a landmark for aligning the map.
    public var fixed: Bool?
    /// Other words the user might say for it, from the room scan ("vitamin bottle": "vitamins", "supplements");
    /// matched on the phone, so no model call is needed at search time (2026-11-02).
    public var aliases: [String]?
    /// How it looks, from the room scan, as a phrase with its name ("black metal water bottle with an AMD logo"), so
    /// the which-one question can describe it (Nils, 2026-11-04: "I want it to describe, not just say where"). nil on
    /// maps saved before.
    public var look: String?

    public init(name: String, position: SIMD3<Float>, seen: Date, source: String, on: String? = nil, fixed: Bool? = nil,
                aliases: [String]? = nil, look: String? = nil) {
        self.name = name
        self.position = [position.x, position.y, position.z]
        self.seen = seen
        self.source = source
        self.on = on
        self.fixed = fixed
        self.aliases = aliases
        self.look = look
    }

    public var world: SIMD3<Float> { SIMD3(position[0], position[1], position[2]) }
}

public struct RoomInventory: Codable, Sendable, Equatable {
    public var items: [RoomItem] = []
    public var created: Date

    public init(created: Date) { self.created = created }

    /// Best item for a spoken noun: same word after singular/lowercase ("keys" = "key", "my water
    /// bottle" ~ "bottle"); with `near` (the camera), the nearest of two things more than 25 cm apart (T21: two
    /// saved water bottles, the newer one 1.9 m away was guided to, the one in reach skipped); then a "found" entry
    /// beats a room-scan one; newest first.
    public func match(_ noun: String, near: SIMD3<Float>? = nil) -> RoomItem? {
        let want = Self.words(noun)
        guard !want.isEmpty else { return nil }
        // Same name first, then an alias said exactly ("supplements"), then a shared word.
        func score(_ i: RoomItem) -> Int { Self.words(i.name) == want ? 2 : Self.aliasHit(i, want) ? 1 : 0 }
        let hits = items.filter { !Self.words($0.name).isDisjoint(with: want) || Self.aliasHit($0, want) }
        return hits.max { a, b in
            let sa = score(a), sb = score(b)
            if sa != sb { return sa < sb }
            if let c = near, simd_distance(a.world, b.world) > Self.sameThing {
                return simd_distance(a.world, c) > simd_distance(b.world, c)
            }
            if (a.source == "found") != (b.source == "found") { return b.source == "found" }
            return a.seen < b.seen
        }
    }

    /// Two saved entries closer than this are the same thing seen twice, not two things.
    public static let sameThing: Float = 0.25

    /// The name to ask SAM for (device test 2026-11-02: "vitamin" found nothing in 17 views, with the Nature Made
    /// jar in plain sight; the room scan had it as "vitamin bottle"). The saved name when it is the user's word plus
    /// more ("vitamin" -> "vitamin bottle"); otherwise the user's word.
    /// When the word fits several saved things ("bottle": a water bottle and a vitamin bottle), it stays as said.
    public func searchName(for noun: String) -> String {
        guard let item = target(for: noun), Self.words(item.name) != Self.words(noun) else { return noun }
        return item.name
    }

    /// The one saved thing the word means: same name, else the only saved name that is the word plus more or has it
    /// as an alias. nil when unknown or when it fits several different things (review 2026-11-02).
    public func target(for noun: String, near: SIMD3<Float>? = nil) -> RoomItem? {
        let want = Self.words(noun)
        guard !want.isEmpty else { return nil }
        if items.contains(where: { Self.words($0.name) == want }) { return match(noun, near: near) }
        let fits = items.filter { Self.words($0.name).isStrictSuperset(of: want) || Self.aliasHit($0, want) }
        guard Set(fits.map { Self.words($0.name) }).count == 1 else { return nil }
        return fits.max { a, b in
            if let c = near, simd_distance(a.world, b.world) > Self.sameThing {
                return simd_distance(a.world, c) > simd_distance(b.world, c)
            }
            if (a.source == "found") != (b.source == "found") { return b.source == "found" }
            return a.seen < b.seen
        }
    }

    /// The different saved names the word fits (same name, the word plus more, or an alias), sorted. More than one:
    /// say them instead of picking one ("bottle": "vitamin bottle", "water bottle").
    public func fits(_ noun: String) -> [String] {
        let want = Self.words(noun)
        guard !want.isEmpty else { return [] }
        var seen: Set<Set<String>> = [], out: [String] = []
        for item in items where Self.words(item.name) == want || Self.words(item.name).isStrictSuperset(of: want)
            || Self.aliasHit(item, want) {
            if seen.insert(Self.words(item.name)).inserted { out.append(item.name) }
        }
        return out.sorted()
    }

    /// T21 (Nils, 2026-11-04: "no matter what, ask what exactly the user wants"): the different saved things the word
    /// fits (same name, the word plus more, or an alias), as indices into `items`. Entries of one name closer than
    /// `sameThing` are one thing (the found, else the newest, entry is kept). Order: found first, then newest.
    public func options(for noun: String) -> [Int] {
        let want = Self.words(noun)
        guard !want.isEmpty else { return [] }
        let fit = items.indices.filter { i in
            let w = Self.words(items[i].name)
            return w == want || w.isStrictSuperset(of: want) || Self.aliasHit(items[i], want)
        }.sorted { a, b in
            if (items[a].source == "found") != (items[b].source == "found") { return items[a].source == "found" }
            return items[a].seen > items[b].seen
        }
        var kept: [Int] = []
        // Another name closer than 8 cm is the same thing too (T21: "bottle", alias "water bottle", 4 cm from the
        // floor's water bottle); the vitamin bottle 13 cm from the black bottle is not.
        for i in fit where !kept.contains(where: { k in
            let d = simd_distance(items[k].world, items[i].world)
            return d < 0.08 || (Self.words(items[k].name) == Self.words(items[i].name) && d < Self.sameThing)
        }) {
            kept.append(i)
        }
        return kept
    }

    /// How one option is said in the which-one question: how it looks, then what it stands on ("a black metal water
    /// bottle with an AMD logo, on the desk"); T22: neighbours too made the question 13-19 s long, so they are said
    /// only when nothing else places it. The name when the map has no look (saved before 2026-11-04); with no place,
    /// the distance when known ("about 2 metres away").
    public func optionLabel(_ i: Int, distance: Float? = nil) -> String {
        let item = items[i], rel = relation(item)
        let what = "a " + (item.look ?? item.name)
        if let on = item.on, !on.isEmpty { return what + ", on the " + on }
        if !rel.isEmpty { return what + ", " + rel }
        guard let d = distance else { return what }
        return d < 1 ? what + ", about \(Int((d * 10).rounded()) * 10) centimetres away"
            : what + ", about \(Int(d.rounded())) metre\(d.rounded() == 1 ? "" : "s") away"
    }

    /// One thing in a listing of a view, placed by LiDAR (same frame as `items`).
    public struct Sighting: Sendable {
        public var name: String
        public var world: SIMD3<Float>
        public var on: String?
        public var aliases: [String]?
        public var look: String?
        public init(name: String, world: SIMD3<Float>, on: String? = nil, aliases: [String]? = nil, look: String? = nil) {
            self.name = name; self.world = world; self.on = on; self.aliases = aliases; self.look = look
        }
    }

    /// Rolling update from one listed view (Nils, 2026-11-02): a saved thing whose spot is in this view
    /// (`isVisible`: in the photo, nothing in front of it) but was not seen there, while a thing of that name was
    /// seen elsewhere, has moved: the old entry goes. Saved things out of view stay (a second cup in another room
    /// corner). Then every sighting is remembered (same name within 50 cm = the same thing).
    @discardableResult
    public mutating func refresh(with sightings: [Sighting], date: Date, source: String,
                                 isVisible: (SIMD3<Float>) -> Bool) -> (added: [String], removed: [String]) {
        let keys = Set(sightings.map { Self.words($0.name) })
        var removed: [String] = []
        items.removeAll { item in
            let k = Self.words(item.name)
            guard keys.contains(k), item.fixed != true else { return false }
            let stillThere = sightings.contains { Self.words($0.name) == k && simd_distance($0.world, item.world) < 0.5 }
            guard !stillThere, isVisible(item.world) else { return false }
            removed.append(item.name)
            return true
        }
        var added: [String] = []
        for s in sightings {
            let k = Self.words(s.name)
            if !items.contains(where: { Self.words($0.name) == k && simd_distance($0.world, s.world) < 0.5 }) { added.append(s.name) }
            remember(s.name, at: s.world, date: date, source: source, on: s.on, aliases: s.aliases, look: s.look)
        }
        return (added, removed)
    }

    static func aliasHit(_ item: RoomItem, _ want: Set<String>) -> Bool {
        (item.aliases ?? []).contains { Self.words($0) == want }
    }

    /// Adds or moves an item. Same name within 50 cm = the same thing seen again (keeps what it stands on and
    /// whether it is fixed when the new sighting does not say).
    public mutating func remember(_ name: String, at p: SIMD3<Float>, date: Date, source: String,
                                  on: String? = nil, fixed: Bool? = nil, aliases: [String]? = nil, look: String? = nil) {
        let key = Self.words(name)
        if let i = items.firstIndex(where: { Self.words($0.name) == key && simd_distance($0.world, p) < 0.5 }) {
            let old = items[i]
            let merged = Array(Set((old.aliases ?? []) + (aliases ?? []))).sorted()
            items[i] = RoomItem(name: name, position: p, seen: date, source: source, on: on ?? old.on, fixed: fixed ?? old.fixed,
                                aliases: merged.isEmpty ? nil : merged, look: look ?? old.look)
        } else if source == "found", let i = items.firstIndex(where: { Self.words($0.name) == key && $0.source == "found" }) {
            // It moved.
            items[i] = RoomItem(name: name, position: p, seen: date, source: source, on: on, fixed: fixed,
                                aliases: aliases ?? items[i].aliases, look: look ?? items[i].look)
        } else {
            items.append(RoomItem(name: name, position: p, seen: date, source: source, on: on, fixed: fixed, aliases: aliases,
                                  look: look))
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
        // Every saved item sharing a word with something seen now ("desk lamp" pairs with "lamp" and "desk";
        // duplicates allowed): RANSAC sorts them out. `seen` = index of the sighting, used once per hypothesis.
        var pairs: [(saved: RoomItem, now: SIMD3<Float>, seen: Int)] = []
        for (n, o) in seen.enumerated() {
            let k = Self.words(o.name)
            guard !k.isEmpty else { continue }
            for item in items where !Self.words(item.name).isDisjoint(with: k) { pairs.append((item, o.world, n)) }
        }
        guard pairs.count >= 2 else { return nil }
        func xz(_ v: SIMD3<Float>) -> SIMD2<Float> { SIMD2(v.x, v.z) }
        // Only hypotheses that would be accepted compete (review 2026-11-01: a movable pair with a smaller error
        // used to beat 2 fixed ones and then be rejected). More inliers, then more fixed ones, then less error.
        var best: (inliers: [Int], fixed: Int, error: Float)?
        for i in pairs.indices {
            for j in pairs.indices where j > i && pairs[i].seen != pairs[j].seen
                && Self.words(pairs[i].saved.name) != Self.words(pairs[j].saved.name) {
                let s = xz(pairs[j].saved.world) - xz(pairs[i].saved.world), n = xz(pairs[j].now) - xz(pairs[i].now)
                // A rigid move keeps the distance between two things; two near each other give no direction.
                guard simd_length(s) >= 0.3, abs(simd_length(s) - simd_length(n)) < 0.15 else { continue }
                let t = Self.transform(from: [pairs[i].saved.world, pairs[j].saved.world], to: [pairs[i].now, pairs[j].now])
                var inl: [Int] = [], err: Float = 0
                var used: Set<Set<String>> = [], usedSeen: Set<Int> = []
                for (k, p) in pairs.enumerated() {
                    let d = simd_distance(Self.apply(t, p.saved.world), p.now)
                    let key = Self.words(p.saved.name)
                    guard d <= Self.alignTolerance, !used.contains(key), !usedSeen.contains(p.seen) else { continue }
                    inl.append(k); err += d; used.insert(key); usedSeen.insert(p.seen)
                }
                let fixed = inl.filter { pairs[$0].saved.fixed == true }.count
                guard inl.count >= 3 || (inl.count == 2 && fixed == 2) else { continue }
                if let b = best, (b.inliers.count, b.fixed) > (inl.count, fixed)
                    || ((b.inliers.count, b.fixed) == (inl.count, fixed) && b.error <= err) { continue }
                best = (inl, fixed, err)
            }
        }
        guard let b = best else { return nil }
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

    /// Looked for at its own spot, in clear view, twice, and not there (v9.4: the room scan called a shaker a
    /// "water bottle" and every search steered there). Only that entry goes; others with the name stay.
    public mutating func forget(_ name: String, near p: SIMD3<Float>) {
        items.removeAll { $0.name == name && simd_distance($0.world, p) < 0.3 }
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
        /// Other words the user might say for it (up to 4).
        public var aliases: [String] = []
        /// How it looks, with its name ("black metal water bottle with an AMD logo").
        public var look: String?
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
            let aliases = ((o["aliases"] as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
                .filter { !$0.isEmpty && $0 != name.lowercased() }
            let look = (o["look"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            return SparkObject(name: name.lowercased(), point: SIMD2(x, y), on: on?.isEmpty == false && on != "null" ? on : nil,
                               fixed: (o["fixed"] as? Bool) ?? false, aliases: Array(aliases.prefix(4)),
                               look: look?.isEmpty == false && look != "null" ? look : nil)
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

    /// A world point on the portrait photo (0...1, origin top-left; inverse of `place`), nil when behind the
    /// camera or outside the photo. For cutting the photo around where the map says the object is (2026-11-02).
    public static func portraitPoint(world w: SIMD3<Float>, intrinsics k: CameraIntrinsics,
                                     cameraTransform t: simd_float4x4) -> SIMD2<Float>? {
        guard let q = DepthProjector.rawPixel(fromWorld: w, cameraTransform: t, intrinsics: k) else { return nil }
        let raw = q / k.imageSize
        let p = SIMD2(1 - raw.y, raw.x)
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        return p
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

/// One search's names for the target (2026-11-03 alignment: SAM was asked one name, Spark was
/// asked another, the map stored a third, so a found object failed verification or polluted the map).
/// Built once per search in FindModel; every judge reads from it instead of re-deriving a name.
public struct TargetVocabulary: Sendable, Equatable {
    /// What the user said ("vitamin"): spoken lines and log keys only.
    public var userPhrase: String
    /// What SAM is asked for ("vitamin bottle"): the visible name.
    public var samQuery: String
    /// The identity ("vitamin bottle"): Spark verification, hold checks, room storage.
    public var canonical: String
    /// Other words for it from the room scan ("vitamins", "supplements").
    public var aliases: [String]

    public init(userPhrase: String, samQuery: String, canonical: String, aliases: [String] = []) {
        self.userPhrase = userPhrase
        self.samQuery = samQuery
        self.canonical = canonical
        self.aliases = aliases
    }

    /// For Spark identity prompts: "vitamin (vitamin bottle)". The user phrase alone when unknown.
    public var verifyPhrase: String {
        RoomInventory.words(canonical) == RoomInventory.words(userPhrase) || canonical.isEmpty
            ? userPhrase : "\(userPhrase) (\(canonical))"
    }

    /// Does a Spark-given name mean this target (obstacle `sameKind`, room matches)?
    public func matches(_ name: String) -> Bool {
        Self.sameWords(name, canonical) || Self.sameWords(name, userPhrase)
            || aliases.contains { Self.sameWords($0, name) }
    }

    /// "Books" / "book", "key" / "green key": equal after a light singularise, or one ends with the other.
    public static func sameWords(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        return !x.isEmpty && !y.isEmpty && (x == y || x.hasSuffix(" " + y) || y.hasSuffix(" " + x))
    }

    private static func norm(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("es"), t.count > 4 { t.removeLast(2) } else if t.hasSuffix("s"), t.count > 3 { t.removeLast() }
        return t
    }
}

/// Spark's names SAM can look for (`{"names":["pill bottle","supplement jar"]}`), lowercased, at most 3.
public enum VisualNames {
    public static func parse(_ text: String) -> [String] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let names = json["names"] as? [Any] else { return [] }
        let clean = names.compactMap { ($0 as? String)?.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Array(clean.prefix(3))
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

    /// One tile the size of `tiles` centred on `p` (portrait, 0...1), kept inside the image: SAM looks only
    /// where the room map says the object is (one call instead of 4 tiles for a small thing, 2026-11-02).
    public static func tile(around p: SIMD2<Float>, in size: SIMD2<Int>) -> (origin: SIMD2<Int>, size: SIMD2<Int>) {
        let w = Int((Float(size.x) * 0.55).rounded()), h = Int((Float(size.y) * 0.55).rounded())
        let x = Int((p.x * Float(size.x)).rounded()) - w / 2, y = Int((p.y * Float(size.y)).rounded()) - h / 2
        return (SIMD2(min(max(0, x), size.x - w), min(max(0, y), size.y - h)), SIMD2(w, h))
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
