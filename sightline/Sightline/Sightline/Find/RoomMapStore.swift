// labels: production, needs-review, important
// The saved room map (Nils, 2026-10-29: scan the room once, then use it to say where things
// probably are). Two files in Documents/room_map/, both **overwritten** by each new room scan:
//   world.arworldmap  ARKit world map (relocalization: positions only make sense after it matched)
//   inventory.json    RoomInventory: object names + world positions, updated after every find
// At launch the app tries to relocalize against the map for `relocalizeTimeout` seconds and falls
// back to a fresh session (FindModel); `active` is true only after a match.

import ARKit
import Foundation
import SightlineCore

final class RoomMapStore {
    static let relocalizeTimeout: TimeInterval = 8

    private(set) var inventory: RoomInventory?
    /// ARKit relocalized against the saved map in this launch, or a new map was just saved.
    private(set) var active = false

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
        saveInventory()
    }

    /// A successful find while the map is active: remember where the object is now.
    func remember(_ name: String, at p: SIMD3<Float>) {
        guard active, var inv = inventory else { return }
        inv.remember(name, at: p, date: Date(), source: "found")
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

    /// Hint for a noun when the map is active: the item and where it is.
    func item(for noun: String) -> RoomItem? { active ? inventory?.match(noun) : nil }
}
