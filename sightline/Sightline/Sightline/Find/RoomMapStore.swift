// labels: production, needs-review, important
// The saved room map (Nils, 2026-10-29: scan the room once, then use it to say where things
// probably are). Two files in Documents/room_map/, both **overwritten** by each new room scan:
//   world.arworldmap  ARKit world map (relocalization: positions only make sense after it matched)
//   inventory.json    RoomInventory: object names + world positions, updated after every find
// At launch the app tries to relocalize against the map for `relocalizeTimeout` seconds (a tap to search
// ends it early) and falls back to a fresh session (FindModel); `active` is true only after a match.
// Without a match, things seen later can align the map (`alignment`, 2026-11-01), and relations
// ("on the desk, next to the laptop") work with no frame at all.

import ARKit
import Foundation
import SightlineCore

final class RoomMapStore {
    /// Was 8 s: in 6 launches (V5 to v9.2) the map never matched in time; the G3 plan allowed 30 s.
    static let relocalizeTimeout: TimeInterval = 30

    private(set) var inventory: RoomInventory?
    /// ARKit relocalized against the saved map in this launch, or a new map was just saved.
    private(set) var active = false
    /// Saved frame -> this launch's world, from things seen now (landmark alignment, 2026-11-01), when ARKit
    /// did not relocalize. The file keeps saved-frame positions; this only maps them in and out.
    private(set) var alignment: simd_float4x4?

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("room_map")
    }
    private static var mapURL: URL { folder.appendingPathComponent("world.arworldmap") }
    private static var inventoryURL: URL { folder.appendingPathComponent("inventory.json") }

    /// The saved world map, if any (and its inventory into `inventory`).
    func load() -> ARWorldMap? {
        guard let data = try? Data(contentsOf: Self.mapURL),
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else { return nil }
        if let json = try? Data(contentsOf: Self.inventoryURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            inventory = try? decoder.decode(RoomInventory.self, from: json)
        }
        return map
    }

    func relocalized() { active = inventory != nil }

    /// A new room scan: replaces both files.
    func save(map: ARWorldMap, inventory: RoomInventory) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try data.write(to: Self.mapURL, options: .atomic)
        self.inventory = inventory
        active = true
        alignment = nil
        saveInventory()
    }

    /// The saved map has items but no frame yet: worth trying a landmark alignment.
    var needsAlignment: Bool { !active && alignment == nil && !(inventory?.items.isEmpty ?? true) }

    func align(_ t: simd_float4x4) { alignment = t }

    /// This launch's world position -> the saved frame (nil when there is no frame).
    private func toSaved(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        if active { return p }
        return alignment.map { RoomInventory.apply($0.inverse, p) }
    }

    /// A successful find while the map has a frame: remember where the object is now. `source` "seen": Spark listed
    /// it in a later view (2026-11-02: things hidden at scan time get into the map when they show up).
    func remember(_ name: String, at p: SIMD3<Float>, source: String = "found", on: String? = nil, aliases: [String]? = nil) {
        guard let saved = toSaved(p), var inv = inventory else { return }
        inv.remember(name, at: saved, date: Date(), source: source, on: on, aliases: aliases)
        inventory = inv
        saveInventory()
    }

    private func saveInventory() {
        guard let inventory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(inventory).write(to: Self.inventoryURL, options: .atomic)
    }

    /// Not at its saved spot (`FindModel.checkSavedSpot`): drop that entry. `p` is in this launch's frame.
    func forget(_ name: String, near p: SIMD3<Float>) {
        guard let saved = toSaved(p), var inv = inventory else { return }
        inv.forget(name, near: saved)
        inventory = inv
        saveInventory()
    }

    /// Picked up (pick-up confirmed): it is with the user now, not where it was found.
    func carried(_ name: String, from p: SIMD3<Float>?) {
        guard active || alignment != nil, var inv = inventory else { return }
        inv.carried(name, from: p.flatMap(toSaved))
        inventory = inv
        saveInventory()
    }

    /// Everything the map knows, in this launch's world, when it has a frame (ARKit match or landmark alignment).
    var activeInventory: RoomInventory? {
        if active { return inventory }
        if let t = alignment { return inventory?.transformed(by: t) }
        return nil
    }

    /// Hint for a noun when the map has a frame: the one thing it means and where it is now (nil when the word fits
    /// several saved things, review 2026-11-02: "bottle" pointed at one of two bottles).
    func item(for noun: String) -> RoomItem? { activeInventory?.target(for: noun) }

    /// The saved item without a frame (relations only: "on the desk, next to the laptop"); same rule.
    func savedItem(for noun: String) -> RoomItem? { inventory?.target(for: noun) }

    /// Rolling update from one listed view with a frame (positions and `isVisible` in this launch's world).
    func refresh(_ seen: [RoomInventory.Sighting], source: String,
                 isVisible: (SIMD3<Float>) -> Bool) -> (added: [String], removed: [String])? {
        guard var inv = inventory, active || alignment != nil else { return nil }
        let toWorld: (SIMD3<Float>) -> SIMD3<Float> = { [alignment] p in alignment.map { RoomInventory.apply($0, p) } ?? p }
        let saved = seen.compactMap { s -> RoomInventory.Sighting? in
            toSaved(s.world).map { RoomInventory.Sighting(name: s.name, world: $0, on: s.on, aliases: s.aliases) }
        }
        let r = inv.refresh(with: saved, date: Date(), source: source, isVisible: { isVisible(toWorld($0)) })
        inventory = inv
        saveInventory()
        return r
    }
}
