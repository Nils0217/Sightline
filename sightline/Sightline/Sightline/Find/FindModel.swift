// labels: production, needs-review, important
// Find-and-grab session (PRD "Find and grab"):
//   tap -> listen -> parse noun locally -> say "Looking for the cup" at once -> SAM on the
//   current frame -> mask + LiDAR -> world target -> 30 Hz hand guidance (speech + tones)
//   -> "Now grab".
// Cloud is called only on events (lock, re-lock after tracking recovers); ≤ 5 SAM calls per
// find session. The guidance loop never waits on the network.

import ARKit
import AVFoundation
import Foundation
import Observation
import SightlineCore

@Observable
final class FindModel {
    enum Phase: String {
        case idle, listening, locating, guiding, done
    }

    static let maxSAMCalls = 5

    private(set) var phase = Phase.idle
    private(set) var targetName: String?
    private(set) var target: SIMD3<Float>?
    private(set) var tip: SIMD3<Float>?
    private(set) var handDistance: Float?
    private(set) var lastHeard = ""
    private(set) var lastCue = ""
    private(set) var tracking = "-"
    private(set) var samCalls = 0
    private(set) var logURL: URL?

    let session = ARSession()
    @ObservationIgnored private let processor = FindFrameProcessor()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let tones = TonePlayer()
    @ObservationIgnored private let input = SpeechInput()
    @ObservationIgnored private var guidance = GuidanceController()
    @ObservationIgnored private var throttle = SpeechThrottle()
    @ObservationIgnored private var lastCamera = matrix_identity_float4x4
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var wasTrackingLimited = false
    @ObservationIgnored private var logRows: [String] = []
    @ObservationIgnored private var sessionID = 0

    init() {
        processor.onFrame = { [weak self] f in
            guard let model = self else { return }
            Task { @MainActor in model.ingest(f) }
        }
        session.delegate = processor
        session.delegateQueue = processor.queue
    }

    func start() {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        session.run(config)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                         options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task {
            if await SpeechInput.requestAuthorization() {
                speaker.say("Sightline ready. Tap the screen and say what to find.")
            } else {
                speaker.say("Sightline needs microphone and speech permission. Please allow them in Settings.")
            }
        }
    }

    func pause() {
        session.pause()
        tones.stop()
        speaker.stop()
    }

    /// The one big button: listen when idle, stop when busy.
    func tap() {
        switch phase {
        case .idle, .done:
            listen()
        case .guiding, .locating:
            finish(spoken: "Stopped.", event: "stop")
        case .listening:
            break
        }
    }

    // MARK: Command

    private func listen() {
        speaker.stop()
        tones.stop()
        phase = .listening
        Task {
            let heard = (try? await input.listenOnce()) ?? ""
            lastHeard = heard
            switch CommandParser.parse(heard) {
            case .find(let noun):
                startFind(noun)
            case .stop:
                finish(spoken: "Stopped.", event: "stop")
            case nil:
                phase = .idle
                speaker.say(heard.isEmpty ? "I didn't hear anything. Tap and try again."
                                          : "Sorry. Say for example: find the cup.")
                log("unparsed", heard)
            }
        }
    }

    private func startFind(_ noun: String) {
        sessionID += 1
        targetName = noun
        target = nil
        samCalls = 0
        guidance = GuidanceController()
        throttle = SpeechThrottle()
        sessionStart = Date()
        log("command", noun)
        // Instant local cue (G4): the user hears something before any network call.
        speaker.say("Looking for the \(noun).")
        locate(reason: "lock")
    }

    // MARK: Cloud (event-triggered)

    private func locate(reason: String) {
        guard let noun = targetName else { return }
        guard samCalls < Self.maxSAMCalls else {
            finish(spoken: "I couldn't find the \(noun). Let's stop here.", event: "budget")
            return
        }
        guard let frame = session.currentFrame,
              let snapshot = try? FrameSnapshot.make(from: frame, tracking: tracking) else {
            Task { try? await Task.sleep(for: .milliseconds(300)); locate(reason: reason) }
            return
        }
        if reason == "lock" { phase = .locating }
        samCalls += 1
        let id = sessionID
        Task {
            let result = await Self.findTarget(noun: noun, snapshot: snapshot, label: "find_\(id)_\(samCalls)")
            guard id == sessionID, phase == .locating || phase == .guiding else { return }  // stale
            switch result {
            case .success(let world):
                let moved = target.map { simd_distance($0, world) }
                target = world
                log("sam_\(reason)", "ok" + (moved.map { String(format: " moved %.1f cm", $0 * 100) } ?? ""))
                if phase == .locating {
                    phase = .guiding
                    speaker.say(GuidanceController.describe(target: world, cameraTransform: snapshot.cameraTransform, name: noun)
                                + " Reach out slowly.", interrupt: true)
                }
            case .failure(let error):
                log("sam_\(reason)_fail", error.reason)
                if phase == .locating {
                    phase = .idle
                    speaker.say("I can't see the \(noun). Turn slowly, then tap and ask again.", interrupt: true)
                }
            }
        }
    }

    private static func findTarget(noun: String, snapshot s: FrameSnapshot, label: String) async -> Result<SIMD3<Float>, FindError> {
        do {
            let response = try await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: label)
            // SAM returns every instance, unsorted; the most confident one wins for now.
            // TODO(agent): ask Muse Spark (medium) to choose when several instances are close.
            guard let best = SAMParser.parse(response.text).max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }),
                  let raster = try? best.decodeMask() else { return .failure(FindError("no_object")) }
            switch MaskTarget.locate(mask: SourceMask(record: best, raster: raster), depth: s.depth, intrinsics: s.intrinsics) {
            case .success(let r):
                return .success(DepthProjector.world(fromCamera: r.cameraPoint, cameraTransform: s.cameraTransform))
            case .failure(let f):
                return .failure(FindError(f.rawValue))
            }
        } catch {
            return .failure(FindError("api_error"))
        }
    }

    // MARK: Local loop (~30 Hz)

    private func ingest(_ f: FindFrame) {
        tracking = f.tracking
        lastCamera = f.cameraTransform
        tip = f.tip
        if f.tracking != "normal" { wasTrackingLimited = true }
        guard phase == .guiding, let target, let name = targetName else {
            handDistance = nil
            return
        }
        // Re-lock once tracking recovers (PRD: re-check when tracking confidence drops).
        if wasTrackingLimited && f.tracking == "normal" {
            wasTrackingLimited = false
            locate(reason: "relock")
        }
        let offset = f.tip.map { BodyOffset(from: $0, to: target, cameraTransform: f.cameraTransform) }
        handDistance = offset?.length
        tones.update(distance: offset?.length)
        guard let cue = guidance.update(time: f.time, offset: offset, targetName: name) else { return }
        if throttle.shouldSpeak(cue, time: f.time, speaking: speaker.isSpeaking) {
            lastCue = cue.phrase
            log("cue", cue.phrase, distance: offset?.length)
            if cue.kind == .grab {
                finish(spoken: cue.phrase, event: "grab")
            } else {
                speaker.say(cue.phrase)
            }
        }
    }

    private func finish(spoken: String, event: String) {
        tones.stop()
        speaker.say(spoken, interrupt: true)
        log(event, spoken, distance: handDistance)
        phase = event == "grab" ? .done : .idle
    }

    // MARK: Log

    /// One CSV per app launch, rewritten after every event (cumulative); export once at the end.
    private func log(_ event: String, _ detail: String, distance: Float? = nil) {
        let elapsed = sessionStart.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? ""
        let row = [ISO8601DateFormatter().string(from: Date()), "\(sessionID)", elapsed, event,
                   targetName ?? "", detail.replacingOccurrences(of: ",", with: ";"),
                   distance.map { String(format: "%.1f", $0 * 100) } ?? "", "\(samCalls)", tracking].joined(separator: ",")
        logRows.append(row)
        let url = logURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("find_log_\(Int(Date().timeIntervalSince1970)).csv")
        let header = "timestamp,session,elapsed_s,event,target,detail,hand_to_target_cm,sam_calls,tracking_state"
        try? (([header] + logRows).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        logURL = url
    }
}

nonisolated struct FindError: Error, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

nonisolated struct FindFrame: Sendable {
    var time: Double
    var tracking: String
    var cameraTransform: simd_float4x4
    var tip: SIMD3<Float>?
}

/// Runs the fingertip pipeline on every second frame (~30 Hz) off the main thread.
nonisolated final class FindFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "sightline.find.frames", qos: .userInteractive)
    var onFrame: (@Sendable (FindFrame) -> Void)?
    private let locator = FingertipLocator()
    private var frameCount = 0

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        let r = locator.locate(in: frame)
        onFrame?(FindFrame(time: frame.timestamp, tracking: FrameProcessor.describe(frame.camera.trackingState),
                           cameraTransform: frame.camera.transform, tip: r.tip))
    }
}
