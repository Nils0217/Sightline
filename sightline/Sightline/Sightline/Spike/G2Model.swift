// labels: production, needs-review
// G2 test state (docs/G2_PLAN.md): SAM mask -> LiDAR -> world-space target, then re-measure the
// same object from other viewpoints and log how far each estimate is from the first lock.
// Hard cap of 5 SAM calls per app launch (AGENTS.md cost rule).

import ARKit
import AudioToolbox
import Foundation
import Observation
import SightlineCore

struct G2Row {
    var timestamp: Date
    var index: Int
    var elapsed: Double?
    var noun: String
    var latencyMS: Double?
    var recordCount: Int
    var chosenID: String?
    var confidence: Float?
    var maskPixels: Int?
    var depthSamples: Int?
    var depthSpread: Float?
    var cameraToTarget: Float?
    var target: SIMD3<Float>?
    var distanceToFirst: Float?
    var camera: SIMD3<Float>
    var tracking: String
    var failReason: String

    static let header = "timestamp,measure_index,elapsed_s,noun,sam_latency_ms,sam_records,chosen_id,confidence,mask_pixels,depth_samples,depth_spread_cm,cam_to_target_m,target_x,target_y,target_z,dist_to_first_cm,camera_x,camera_y,camera_z,tracking_state,fail_reason"

    var csv: String {
        func f(_ v: Float?, _ d: Int = 4) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        func f(_ v: Double?, _ d: Int) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        return [
            ISO8601DateFormatter().string(from: timestamp), "\(index)", f(elapsed, 1), noun.replacingOccurrences(of: ",", with: " "),
            f(latencyMS, 0), "\(recordCount)", chosenID ?? "", f(confidence, 3), maskPixels.map(String.init) ?? "",
            depthSamples.map(String.init) ?? "", f(depthSpread.map { $0 * 100 }, 2), f(cameraToTarget, 3),
            f(target?.x), f(target?.y), f(target?.z), f(distanceToFirst.map { $0 * 100 }, 2),
            f(camera.x), f(camera.y), f(camera.z), tracking, failReason,
        ].joined(separator: ",")
    }
}

@Observable
final class G2Model {
    static let maxCalls = 5

    var noun = "book"
    private(set) var callsUsed = 0
    private(set) var busy = false
    private(set) var status = "Aim at the object, about 50 cm away, and tap Lock."
    private(set) var tracking = "-"
    private(set) var firstTarget: SIMD3<Float>?
    private(set) var latestTarget: SIMD3<Float>?
    private(set) var rows: [G2Row] = []
    private(set) var csvURL: URL?
    private var firstTime: Date?

    let session = ARSession()
    @ObservationIgnored private let observer = TrackingObserver()

    var hasKey: Bool { APIKey.value != nil }
    var callsLeft: Int { Self.maxCalls - callsUsed }
    var measurements: [G2Row] { rows.filter { $0.failReason.isEmpty } }

    init() {
        observer.onChange = { [weak self] state in
            guard let model = self else { return }
            Task { @MainActor in model.tracking = state }
        }
        session.delegate = observer
        session.delegateQueue = observer.queue
    }

    func configure() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            status = "This device has no LiDAR scene depth"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.run(config)
    }

    func pause() { session.pause() }

    func measure() {
        guard !busy, callsLeft > 0 else { return }
        guard let frame = session.currentFrame else { status = "Camera not ready"; return }
        let snapshot: FrameSnapshot
        do { snapshot = try FrameSnapshot.make(from: frame, tracking: tracking) } catch {
            status = "Could not read this frame (\(error.rawValue)). Try again."
            return
        }
        let index = rows.count
        callsUsed += 1
        busy = true
        status = "Asking SAM for \"\(noun)\"..."
        let noun = self.noun
        Task {
            let row = await locate(snapshot: snapshot, noun: noun, index: index)
            append(row)
            busy = false
        }
    }

    private func locate(snapshot s: FrameSnapshot, noun: String, index: Int) async -> G2Row {
        let camera = SIMD3(s.cameraTransform.columns.3.x, s.cameraTransform.columns.3.y, s.cameraTransform.columns.3.z)
        var row = G2Row(timestamp: Date(), index: index, elapsed: firstTime.map { Date().timeIntervalSince($0) },
                        noun: noun, recordCount: 0, camera: camera, tracking: s.tracking, failReason: "")
        let response: SAMResponse
        do {
            response = try await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: "g2_\(index)")
        } catch {
            row.failReason = "api_error"
            status = "SAM call failed: \(error.localizedDescription)"
            return row
        }
        row.latencyMS = response.latencyMS
        save(snapshot: s, samText: response.text, index: index)

        let records = SAMParser.parse(response.text)
        row.recordCount = records.count
        // SAM returns every instance of the noun, unsorted; take the most confident one.
        guard let best = records.max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }) else {
            row.failReason = "no_object"
            status = "SAM found no \"\(noun)\". Try another word or angle."
            return row
        }
        row.chosenID = best.id
        row.confidence = best.confidence
        guard let raster = try? best.decodeMask() else {
            row.failReason = "mask_decode"
            status = "Mask could not be decoded."
            return row
        }
        row.maskPixels = raster.reduce(0) { $0 + Int($1) }
        switch MaskTarget.locate(mask: SourceMask(record: best, raster: raster), depth: s.depth, intrinsics: s.intrinsics) {
        case .failure(let failure):
            row.failReason = failure.rawValue
            status = "No reliable depth on the object (\(failure.rawValue)). Move closer and retry."
        case .success(let result):
            let world = DepthProjector.world(fromCamera: result.cameraPoint, cameraTransform: s.cameraTransform)
            row.target = world
            row.depthSamples = result.samples
            row.depthSpread = result.depthSpread
            row.cameraToTarget = simd_distance(world, camera)
            latestTarget = world
            if let first = firstTarget {
                let d = simd_distance(world, first)
                row.distanceToFirst = d
                status = String(format: "Measure %d: %.1f cm from the first lock.", index, d * 100)
            } else {
                firstTarget = world
                firstTime = Date()
                row.elapsed = 0
                row.distanceToFirst = 0
                status = "Locked. Walk around the object, then re-measure from a new spot."
            }
            AudioServicesPlaySystemSound(1104)
        }
        return row
    }

    private func append(_ row: G2Row) {
        rows.append(row)
        let url = csvURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("g2_targets_\(Int(Date().timeIntervalSince1970)).csv")
        let text = ([G2Row.header] + rows.map(\.csv)).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        csvURL = url
    }

    /// Keeps the uploaded image and raw SAM text on the phone for debugging masks.
    private func save(snapshot: FrameSnapshot, samText: String, index: Int) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("g2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = "\(Int(Date().timeIntervalSince1970))_\(index)"
        try? snapshot.jpeg.write(to: dir.appendingPathComponent("\(stem).jpg"))
        try? samText.write(to: dir.appendingPathComponent("\(stem).sam.txt"), atomically: true, encoding: .utf8)
    }
}

/// Forwards tracking-state changes only (not every frame) to the model.
private nonisolated final class TrackingObserver: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "sightline.g2.session")
    var onChange: (@Sendable (String) -> Void)?

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onChange?(FrameProcessor.describe(camera.trackingState))
    }
}
