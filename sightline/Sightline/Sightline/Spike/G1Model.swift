// labels: production, needs-review
// G1 hand-accuracy test state: scenarios, jitter check, touch log, CSV export (docs/G1_PLAN.md).

import ARKit
import AudioToolbox
import Foundation
import Observation
import SightlineCore

struct G1Row {
    var timestamp: Date
    var scenario: String
    var distanceCM: Int
    var angleDeg: Int
    var reference: SIMD3<Float>?
    var referenceJitterMM: Float?
    var tip: SIMD3<Float>?
    var error: TouchError?
    var handConfidence: Float?
    var validSamples: Int
    var depth: Float?
    var tracking: String
    var failReason: String

    static let header = "timestamp,scenario,distance_cm,angle_deg,ref_x,ref_y,ref_z,ref_jitter_mm,tip_x,tip_y,tip_z,err_3d_cm,err_normal_cm,err_plane_cm,hand_conf,depth_valid_samples,depth_m,tracking_state,fail_reason"

    var csv: String {
        func f(_ v: Float?, _ digits: Int = 4) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        let r = reference, t = tip
        return [
            ISO8601DateFormatter().string(from: timestamp), scenario, "\(distanceCM)", "\(angleDeg)",
            f(r?.x), f(r?.y), f(r?.z), f(referenceJitterMM, 1),
            f(t?.x), f(t?.y), f(t?.z),
            f(error.map { $0.total * 100 }, 2), f(error.map { $0.normal * 100 }, 2), f(error.map { $0.inPlane * 100 }, 2),
            f(handConfidence, 2), "\(validSamples)", f(depth), tracking, failReason,
        ].joined(separator: ",")
    }
}

@Observable
final class G1Model {
    enum Phase: Equatable {
        case idle
        case checkingJitter
        case capturing
        case done
    }

    static let touchesPerScenario = 10
    static let maxJitterMM: Float = 5

    // Settings
    var distanceCM = 50
    var angleDeg = 0
    var markerWidthMM: Double = 100 { didSet { configureSession() } }

    // Live state
    private(set) var phase = Phase.idle
    private(set) var latest: FrameMeasurement?
    private(set) var rows: [G1Row] = []
    private(set) var statusLine = "Point the camera at the printed marker"
    private(set) var csvURL: URL?

    // Frame-level localisation rate for the running scenario, per scenario name.
    private var handFrames: [String: Int] = [:]
    private var validFrames: [String: Int] = [:]
    private var lastFailureLog = Date.distantPast

    let session = ARSession()
    @ObservationIgnored private var processor: FrameProcessor!

    var scenario: String { "d\(distanceCM)_a\(angleDeg)" }
    var touchesInScenario: Int { rows.filter { $0.scenario == scenario && $0.failReason.isEmpty }.count }

    init() {
        processor = FrameProcessor { [weak self] m in
            guard let model = self else { return }
            Task { @MainActor in model.ingest(m) }
        }
        session.delegate = processor
        session.delegateQueue = processor.queue
    }

    func configureSession() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            statusLine = "This device has no LiDAR scene depth"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        if let cg = UIImage(named: "g1_marker")?.cgImage {
            let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(markerWidthMM / 1000))
            ref.name = "g1_marker"
            config.detectionImages = [ref]
            config.maximumNumberOfTrackedImages = 1
        } else {
            statusLine = "g1_marker.png missing from the app bundle"
        }
        session.run(config, options: [.removeExistingAnchors])
    }

    func pause() { session.pause() }

    func startScenario() {
        phase = .checkingJitter
        processor.captureArmed = false
        statusLine = "Hold the phone still for 5 s"
    }

    func stopScenario() {
        phase = .idle
        processor.captureArmed = false
    }

    func report(for name: String?) -> AccuracyReport {
        let errors = rows.filter { name == nil || $0.scenario == name }.compactMap { $0.error?.total }
        let attempts = name.map { handFrames[$0, default: 0] } ?? handFrames.values.reduce(0, +)
        let valid = name.map { validFrames[$0, default: 0] } ?? validFrames.values.reduce(0, +)
        return AccuracyReport(errors: errors, validEstimates: valid, attempts: attempts)
    }

    private func ingest(_ m: FrameMeasurement) {
        latest = m
        switch phase {
        case .idle, .done:
            break
        case .checkingJitter:
            guard let jitter = m.referenceJitterMM else { return }
            if jitter <= Self.maxJitterMM {
                phase = .capturing
                processor.captureArmed = true
                statusLine = "Touch the crosshair and hold still"
                AudioServicesPlaySystemSound(1113)
            } else {
                statusLine = String(format: "Anchor jitter %.1f mm > 5 mm. Hold still.", jitter)
            }
        case .capturing:
            countFrame(m)
            if let touch = m.capturedTouch { record(touch: touch, m) }
            else if let reason = m.failReason, m.handConfidence != nil, Date().timeIntervalSince(lastFailureLog) >= 1 {
                // Hand visible but no valid estimate: sample the reason at most once a second.
                lastFailureLog = Date()
                append(G1Row(timestamp: Date(), scenario: scenario, distanceCM: distanceCM, angleDeg: angleDeg,
                             reference: m.reference, referenceJitterMM: m.referenceJitterMM, tip: nil, error: nil,
                             handConfidence: m.handConfidence, validSamples: m.validSamples, depth: m.tipDepth,
                             tracking: m.tracking, failReason: reason))
            }
        }
    }

    private func countFrame(_ m: FrameMeasurement) {
        guard let conf = m.handConfidence, conf >= FrameProcessor.minHandConfidence else { return }
        handFrames[scenario, default: 0] += 1
        if m.tip != nil, m.reference != nil { validFrames[scenario, default: 0] += 1 }
    }

    private func record(touch: SIMD3<Float>, _ m: FrameMeasurement) {
        guard let reference = m.reference, let normal = m.referenceNormal else { return }
        append(G1Row(timestamp: Date(), scenario: scenario, distanceCM: distanceCM, angleDeg: angleDeg,
                     reference: reference, referenceJitterMM: m.referenceJitterMM, tip: touch,
                     error: TouchError(tip: touch, reference: reference, planeNormal: normal),
                     handConfidence: m.handConfidence, validSamples: m.validSamples, depth: m.tipDepth,
                     tracking: m.tracking, failReason: ""))
        AudioServicesPlaySystemSound(1104)
        if touchesInScenario >= Self.touchesPerScenario {
            phase = .done
            processor.captureArmed = false
            statusLine = "Scenario \(scenario) done. Change distance/angle and start the next one."
            AudioServicesPlaySystemSound(1025)
        } else {
            statusLine = "Touch \(touchesInScenario)/\(Self.touchesPerScenario) logged. Lift the finger, touch again."
        }
    }

    private func append(_ row: G1Row) {
        rows.append(row)
        writeCSV()
    }

    private func writeCSV() {
        let url = csvURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("g1_touches_\(Int(Date().timeIntervalSince1970)).csv")
        let text = ([G1Row.header] + rows.map(\.csv)).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        csvURL = url
    }
}
