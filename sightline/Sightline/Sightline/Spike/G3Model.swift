// labels: production, needs-review
// G3 test (docs/G3_PLAN.md): scan a room, drop a marker on a surface, save the ARWorldMap;
// relaunch the app, load the map and time how long ARKit takes to relocalize. The marker
// is saved inside the map, so after relocalizing it should reappear on the same physical spot.

import ARKit
import AudioToolbox
import Foundation
import Observation

@Observable
final class G3Model {
    nonisolated static let markerName = "g3_marker"
    static let timeout: TimeInterval = 30

    private(set) var tracking = "-"
    private(set) var mapping = "-"
    private(set) var marker: SIMD3<Float>?
    private(set) var status = "Walk around the room slowly until mapping says mapped."
    private(set) var loading = false
    private(set) var csvURL: URL?
    private var rows: [String] = []
    private var loadStart: Date?
    private var wasRelocalizing = false

    let session = ARSession()
    @ObservationIgnored private let observer = G3Observer()

    static var mapURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("g3_worldmap.arworldmap")
    }
    var hasSavedMap: Bool { FileManager.default.fileExists(atPath: Self.mapURL.path) }

    init() {
        observer.onUpdate = { [weak self] update in
            guard let model = self else { return }
            Task { @MainActor in model.apply(update) }
        }
        session.delegate = observer
        session.delegateQueue = observer.queue
    }

    func startFresh() {
        loading = false
        loadStart = nil
        marker = nil
        session.run(ARWorldTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        status = "Walk around the room slowly until mapping says mapped."
    }

    func pause() { session.pause() }

    /// Raycasts from the screen centre onto any surface and adds the marker anchor there.
    func placeMarker() {
        guard let frame = session.currentFrame else { return }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any)
        guard let hit = session.raycast(query).first else {
            status = "No surface at the centre. Aim at a table or the floor."
            return
        }
        for anchor in frame.anchors where anchor.name == Self.markerName { session.remove(anchor: anchor) }
        session.add(anchor: ARAnchor(name: Self.markerName, transform: hit.worldTransform))
        status = "Marker placed. Remember the exact spot, then Save map when mapped."
    }

    func saveMap() {
        session.getCurrentWorldMap { [weak self] map, error in
            guard let model = self else { return }
            let result: Result<Int, Error>
            if let map {
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    try data.write(to: G3Model.mapURL, options: .atomic)
                    result = .success(data.count)
                } catch { result = .failure(error) }
            } else {
                result = .failure(error ?? CocoaError(.fileWriteUnknown))
            }
            let anchors = map?.anchors.count ?? 0
            Task { @MainActor in model.didSave(result, anchors: anchors) }
        }
    }

    func loadMap() {
        do {
            let data = try Data(contentsOf: Self.mapURL)
            guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
                status = "Saved map is unreadable."
                return
            }
            let config = ARWorldTrackingConfiguration()
            config.initialWorldMap = map
            marker = nil
            wasRelocalizing = false
            loading = true
            loadStart = Date()
            session.run(config, options: [.resetTracking, .removeExistingAnchors])
            log("load_start", detail: "\(data.count) bytes, \(map.anchors.count) anchors")
            status = "Point the phone at the scanned area from roughly where you saved."
        } catch {
            status = "Could not load the map: \(error.localizedDescription)"
        }
    }

    private func didSave(_ result: Result<Int, Error>, anchors: Int) {
        switch result {
        case .success(let bytes):
            log("saved", detail: "\(bytes) bytes, \(anchors) anchors, mapping \(mapping)")
            status = "Map saved (\(bytes / 1024) KB). Now force-quit the app, reopen it, open G3, tap Load map."
            AudioServicesPlaySystemSound(1104)
        case .failure(let error):
            status = "Save failed: \(error.localizedDescription). Keep scanning and retry."
        }
    }

    private func apply(_ u: G3Observer.Update) {
        if let t = u.tracking { tracking = t }
        if let m = u.mapping { mapping = m }
        if let markerUpdate = u.marker { marker = markerUpdate }
        guard loading, let start = loadStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        if tracking == "limited_relocalizing" { wasRelocalizing = true }
        if tracking == "normal" && wasRelocalizing {
            loading = false
            log("relocalized", detail: String(format: "%.1f s", elapsed), elapsed: elapsed)
            status = String(format: "Relocalized in %.1f s. Is the green dot on the same spot as before?", elapsed)
            AudioServicesPlaySystemSound(1025)
        } else if elapsed > Self.timeout {
            loading = false
            log("timeout", detail: "no relocalization in \(Int(Self.timeout)) s", elapsed: elapsed)
            status = "No relocalization in \(Int(Self.timeout)) s."
        }
    }

    private func log(_ event: String, detail: String, elapsed: TimeInterval? = nil) {
        let row = [ISO8601DateFormatter().string(from: Date()), event, elapsed.map { String(format: "%.2f", $0) } ?? "",
                   tracking, mapping, detail.replacingOccurrences(of: ",", with: ";")].joined(separator: ",")
        rows.append(row)
        let url = csvURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("g3_relocalize_\(Int(Date().timeIntervalSince1970)).csv")
        let text = (["timestamp,event,elapsed_s,tracking_state,mapping_status,detail"] + rows).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        csvURL = url
    }
}

/// Forwards tracking/mapping changes and the marker position; per-frame values only when they change.
private nonisolated final class G3Observer: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Update: Sendable {
        var tracking: String?
        var mapping: String?
        var marker: SIMD3<Float>?
    }

    let queue = DispatchQueue(label: "sightline.g3.session")
    var onUpdate: (@Sendable (Update) -> Void)?
    private var lastMapping = ""
    private var lastMarker: SIMD3<Float>?

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onUpdate?(Update(tracking: FrameProcessor.describe(camera.trackingState)))
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        var update = Update()
        let mapping = Self.describe(frame.worldMappingStatus)
        if mapping != lastMapping { lastMapping = mapping; update.mapping = mapping }
        if let anchor = frame.anchors.first(where: { $0.name == G3Model.markerName }) {
            let p = SIMD3(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            if lastMarker.map({ simd_distance($0, p) > 0.001 }) ?? true { lastMarker = p; update.marker = p }
        }
        if update.mapping != nil || update.marker != nil { onUpdate?(update) }
    }

    private static func describe(_ s: ARFrame.WorldMappingStatus) -> String {
        switch s {
        case .notAvailable: "not_available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
    }
}
