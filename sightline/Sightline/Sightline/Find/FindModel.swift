// labels: production, needs-review, important
// Find-and-explore app orchestration: calibrated reach, current-frame local geometry,
// explicit Stop/Status/Check controls and token-isolated event-driven cloud calls.
// Automatic confirmation requires two frame-aligned hand/object observations and affirmative
// reference-image checks, never Spark or disappearance alone. See docs/HUMAN_FACTORS.md.

import ARKit
import AVFoundation
import Foundation
import Observation
import RealityKit
import SightlineCore
import UIKit

@Observable
final class FindModel {
    enum Phase: String {
        case idle, listening, locating, searching, guiding, grabbing, verifying, done, mapping
    }

    /// SAM calls per search outside the scan (lock, re-lock, agent find_object). Was 5 (v5 test: the
    /// agent needs several finds to see which options are here).
    static let maxSAMCalls = 12
    /// SAM hold-check calls per search; an exhausted budget retains uncertainty.
    /// The session asks for at most `GuidanceSession.maxAutoChecks` automatic checks.
    static let maxHoldSAMCalls = 12

    private(set) var phase = Phase.idle
    private(set) var targetName: String?
    private(set) var target: SIMD3<Float>?
    /// Palm-centre reference point (red dot) and visible fingertips (small dots), world space.
    private(set) var palm: SIMD3<Float>?
    private(set) var fingertips: [SIMD3<Float>] = []
    private(set) var handDistance: Float?
    /// "6/6" etc.: how many of the six keypoints are visible, or the reason none are.
    private(set) var handStatus = "-"
    private(set) var guidePhase = "-"
    private(set) var recordings = 0
    private(set) var lastHeard = ""
    private(set) var lastCue = ""
    private(set) var tracking = "-"
    private(set) var samCalls = 0
    @ObservationIgnored private var holdSAMCalls = 0
    /// One per hold check: a timer or result of an older check must not end a newer one (v6 run 2: the
    /// 25 s timer of a previous check fired 0.2 s into a new one, three times).
    @ObservationIgnored private var holdCheckID = 0
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    private(set) var logURL: URL?

    let session = ARSession()
    @ObservationIgnored private let processor = FindFrameProcessor()
    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let tones = TonePlayer()
    @ObservationIgnored private let input = SpeechInput()
    @ObservationIgnored private let audio = AudioSessionKeeper()
    @ObservationIgnored private let room = RoomMapStore()
    /// Waiting for ARKit to relocalize against the saved room map (since this date).
    @ObservationIgnored private var relocalizingSince: Date?
    /// The target as seen at lock (crop of the SAM box), for the strict hold check.
    @ObservationIgnored private var referenceCrop: Data?
    /// Room scan in progress ("scan the room").
    @ObservationIgnored private var mapPlanner: ScanPlanner?
    @ObservationIgnored private var mapInventory = RoomInventory(created: Date())
    @ObservationIgnored private var mapInFlight = 0
    @ObservationIgnored private var mapViews = 0
    @ObservationIgnored private var guide: GuidanceSession?
    /// Keep-scanning state while the object is not in view (ScanPlanner decides when to call SAM).
    @ObservationIgnored private var scan: ScanPlanner?
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanCalls = 0
    /// The current hold check came from GuidanceSession (hand left the object), not from a tap.
    @ObservationIgnored private var checkFromSession = false
    /// Where each object was last locked during this app launch (world space; not across launches:
    /// loading the G3 world map at start would block tracking in any other room).
    @ObservationIgnored private var lastSeen: [String: SIMD3<Float>] = [:]
    @ObservationIgnored private var lastFrameTime: Double = 0
    @ObservationIgnored private let recorder = DiagnosticRecorder()
    @ObservationIgnored weak var arView: ARView?
    @ObservationIgnored private var lastCamera = matrix_identity_float4x4
    @ObservationIgnored private var sessionStart: Date?
    @ObservationIgnored private var logRows: [String] = []
    @ObservationIgnored private var sessionID = 0
    @ObservationIgnored private var candidates: [Candidate] = []
    /// Agent: phrases find_object looked for with nothing found in this search, and finds so far.
    @ObservationIgnored private var notFound: [String] = []
    @ObservationIgnored private var agentFinds = 0
    @ObservationIgnored private var lastJPEG: Data?

    private(set) var reachDistance: Float?
    private(set) var calibrating = false
    private(set) var selectedHand = "right"
    private(set) var safetyMessage: String?
    @ObservationIgnored private var calibration = ReachCalibration()
    @ObservationIgnored private var calibrationDeadline: Double?
    @ObservationIgnored private var calibrationStarted: Double?
    private(set) var needsUserDecision = false
    @ObservationIgnored private var holdVerification = HoldVerification()
    @ObservationIgnored private var holdCycleStarted = false
    @ObservationIgnored private var holdMovementIssued = false
    @ObservationIgnored private var activeHoldMovement: (context: HoldMovementContext, intrinsics: CameraIntrinsics)?
    @ObservationIgnored private var holdMovementCapture: HoldMovementCapture?
    @ObservationIgnored private var holdCaptureSerial = 0
    @ObservationIgnored private var holdCapturePending = false
    @ObservationIgnored private var holdObservationInFlight = false
    @ObservationIgnored private var handTrace = HandTrace()
    @ObservationIgnored private var holdScene: (time: Double, map: ObstacleMap)?
    @ObservationIgnored private var reachFrame: simd_float4x4?
    @ObservationIgnored private var lastInputFrame: Double = 0
    @ObservationIgnored private var frameWatchdog: Task<Void, Never>?

    private func clearHoldCollection() {
        holdMovementCapture = nil
        activeHoldMovement = nil
        holdCapturePending = false
        holdObservationInFlight = false
    }

    private func resetHoldCycle() {
        clearHoldCollection()
        holdVerification = HoldVerification()
        holdCaptureSerial = 0
        holdCycleStarted = false
        holdMovementIssued = false
        needsUserDecision = false
        handTrace = HandTrace()
        holdScene = nil
    }

    func newSearch() {
        stop()
        guard reachDistance != nil else { explainSetup(); return }
        listen()
    }

    func beginReachCalibration(hand: String) {
        stop()
        selectedHand = hand
        reachDistance = nil
        calibration = ReachCalibration()
        calibrating = true
        calibrationStarted = nil
        calibrationDeadline = ProcessInfo.processInfo.systemUptime + 45
        speaker.say("Keep the phone secured on your chest. Keep your body still. Show only your \(hand) hand, with your index finger at a comfortable reach. Hold still without stretching. Measuring in three seconds.", interrupt: true)
    }

    func closeReachSetup() {
        stop()
        speaker.say(reachDistance == nil
            ? "Setup closed. Reach guidance is unavailable until measured. Tap anywhere to reopen setup."
            : "Setup closed. Tap anywhere to say what to find.", interrupt: true)
    }

    func chooseReachHand(_ hand: String) {
        guard !calibrating, ["left", "right"].contains(hand) else { return }
        selectedHand = hand
        Haptics.tap()
        speaker.say("Using your \(hand) hand. Tap the main area to measure. With VoiceOver, double tap with two fingers.", interrupt: true)
    }

    func explainSetup() {
        speaker.say("Secure the phone on your chest and keep your body still. Using your \(selectedHand) hand. Tap the main area to measure; with VoiceOver, double tap with two fingers. Then hold your index finger at a comfortable reach without stretching. Setup closes automatically when measured. Swipe left or right to choose that hand, or use the hand controls with VoiceOver. To exit setup, hold the screen, or use the VoiceOver escape gesture.", interrupt: true)
    }

    /// A fixed action in every phase. Invalidate all delayed model, capture and microphone results.
    func stop() {
        sessionID += 1
        holdCheckID += 1
        input.cancel()
        tones.stop()
        speaker.stop()
        guide = nil
        reachFrame = nil
        scan = nil
        mapPlanner = nil
        clearHoldCollection()
        processor.target = nil
        processor.object = nil
        candidates = []
        safetyMessage = nil
        handDistance = nil
        calibrating = false
        resetHoldCycle()
        phase = .idle
        log("stop", "explicit cancellation")
        speaker.say("Stopped. Keep your hand still. Tap to speak a new command.", interrupt: true)
    }

    func finishRoomScan() {
        guard phase == .mapping else { return }
        finishMapping(early: true)
    }

    func checkHeldObject() {
        guard targetName != nil, [.guiding, .grabbing].contains(phase), safetyMessage == nil, !holdCycleStarted else {
            speaker.say(needsUserDecision ? "I cannot confirm it. Confirm it yourself, start a new search, or stop." : "No object check is available. Start a new search.", interrupt: true)
            return
        }
        startHoldCheck()
    }

    func confirmHeldObject() {
        guard targetName != nil, [.guiding, .grabbing, .verifying].contains(phase), safetyMessage == nil else { return }
        holdCheckID += 1
        clearHoldCollection()
        needsUserDecision = false
        finish(spoken: "You confirmed the \(targetName ?? "object").", event: "user_confirmed")
    }

    private func pauseForSafety(_ message: String) {
        guard safetyMessage == nil else { return }
        safetyMessage = message
        holdCheckID += 1
        clearHoldCollection()
        tones.stop()
        handDistance = nil
        speaker.say(message, interrupt: true)
        log("safety_pause", message)
    }

    init() {
        processor.onFrame = { [weak self] f in
            guard let model = self else { return }
            Task { @MainActor in model.ingest(f) }
        }
        session.delegate = processor
        session.delegateQueue = processor.queue
        speaker.onEvent = { [weak self] event, text in self?.log(event, text) }
        audio.onEvent = { [weak self] event, detail in
            guard let self else { return }
            log(event, detail)
            // v5 launch: an interruption began and the first line never finished.
            if event == "audio_interruption", detail == "ended", speaker.isSpeaking { speaker.rebuild(reason: "interruption ended") }
        }
        // v5 launch: 4.5 min with the first line stuck and tracking initializing. Log app state so the
        // next log shows whether the app was in the background.
        for (name, event) in [(UIApplication.didBecomeActiveNotification, "app_active"),
                              (UIApplication.willResignActiveNotification, "app_inactive"),
                              (UIApplication.didEnterBackgroundNotification, "app_background")] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log(event, "")
                    if event != "app_active" {
                        self?.stop()
                        self?.speaker.stop()
                        self?.reachDistance = nil
                    }
                }
            })
        }
        audio.onReset = { [weak self] in self?.speaker.rebuild(reason: "audio reset") }
    }

    private static func trackingConfig() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        return config
    }

    func start() {
        let config = Self.trackingConfig()
        if let map = room.load() {
            // Saved room map: relocalize against it; ingest() falls back after RoomMapStore.relocalizeTimeout.
            config.initialWorldMap = map
            relocalizingSince = Date()
            log("room_map_load", "\(room.inventory?.items.count ?? 0) items")
        }
        session.run(config)
        audio.start()
        frameWatchdog?.cancel()
        frameWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if calibrating, let deadline = calibrationDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
                    calibrating = false
                    speaker.say("Measurement timed out. Check the camera and try Reach setup again.", interrupt: true)
                }
                if [.guiding, .grabbing, .verifying].contains(phase),
                   ProcessInfo.processInfo.systemUptime - lastInputFrame > 0.75 {
                    pauseForSafety("Stop your hand. Camera updates stopped. Start a new search after the camera recovers.")
                }
            }
        }
        Task {
            if await SpeechInput.requestAuthorization() {
                explainSetup()
            } else {
                speaker.say("Sightline needs microphone and speech permission. Please allow them in Settings.")
            }
        }
    }

    func pause() {
        stop()
        frameWatchdog?.cancel()
        frameWatchdog = nil
        session.pause()
        tones.stop()
        speaker.stop()
    }


    /// The one big button: listen when idle, check the object when the hand is at it, stop otherwise.
    /// Every tap is answered at once (haptic, then a sound or words), 2026-10-29 blindfold test.
    func tap() {
        Haptics.tap()
        if calibrating { stop(); return }
        log("tap", phase.rawValue)
        if phase == .idle || phase == .done {
            guard reachDistance != nil else { explainSetup(); return }
            listen()
        } else { stop() }
    }

    /// Double tap: say where we are and what to do next.
    func speakStatus() {
        Haptics.tap()
        let line = statusLine()
        log("status", line)
        speaker.say(line, interrupt: true)
    }

    /// Long press: cancel everything and go back to idle.
    func reset() { stop() }

    func statusLine() -> String {
        let name = targetName ?? "object"
        if calibrating { return "Measuring your comfortable reach. Keep still. Tap to stop measurement." }
        if reachDistance == nil { return "Reach not measured. Tap the main area to open spoken setup." }
        if let safetyMessage { return safetyMessage }
        if needsUserDecision { return "I cannot confirm it. Confirm it yourself, start a new search, or stop." }
        switch phase {
        case .idle:
            return "Ready. Tap and say what to find." + (room.active ? " Room map is on." : "")
        case .listening:
            return "Listening."
        case .locating:
            return "Looking for the \(name)."
        case .searching:
            return "Searching for the \(name). \(scanCalls) views checked. Turn slowly. Tap to stop."
        case .guiding:
            guard let d = handDistance else { return "Guiding you to the \(name). I cannot see your hand. Keep it still. Tap to stop." }
            return "Guiding you to the \(name). Your hand is about \(max(1, Int((d * 10).rounded())) * 10) centimetres away."
        case .grabbing:
            return "The \(name) is nearby. Contact is not confirmed. Explore by touch. Choose Check after picking it up, or tap the main area to stop."
        case .verifying:
            return "Checking what you are holding."
        case .done:
            return "Search finished for the \(name). Tap to find something else."
        case .mapping:
            return "Scanning the room. \(mapViews) views, \(mapInventory.items.count) things so far. Turn slowly. Use Finish scan to save, or Stop to discard."
        }
    }

    // MARK: Bounded hold evidence collection

    private func startHoldCheck(fromSession: Bool = false, reason: String? = nil) {
        guard tracking == "normal", safetyMessage == nil, !holdCycleStarted else { return }
        clearHoldCollection()
        holdVerification = HoldVerification()
        holdCaptureSerial = 0
        holdMovementIssued = false
        needsUserDecision = false
        holdCycleStarted = true
        checkFromSession = guide != nil
        if !fromSession { guide?.beginManualCheck() }
        phase = .verifying
        tones.stop()
        holdCheckID += 1
        let id = sessionID, check = holdCheckID
        if !fromSession { speaker.say("Checking the object.", interrupt: true) }
        log("hold_check", fromSession ? (reason ?? "session") : "button")
        requestHoldObservation(session: id, check: check)
        Task {
            try? await Task.sleep(for: .seconds(35))
            guard id == sessionID, check == holdCheckID, phase == .verifying else { return }
            completeHoldCheck(nil, reason: HoldFailure.timeout.rawValue, moved: nil)
        }
    }

    private func requestHoldObservation(session id: Int, check: Int) {
        guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil,
              !holdCapturePending, !holdObservationInFlight, holdVerification.result == .collect else { return }
        guard holdCaptureSerial < HoldVerification.maxObservations else {
            completeHoldCheck(nil, reason: "insufficientEvidence", moved: nil)
            return
        }
        holdCaptureSerial += 1
        holdCapturePending = true
        processor.requestCapture("hold_evidence:\(id):\(check):\(holdCaptureSerial)")
    }

    private func runHoldObservation(_ s: FrameSnapshot, hand: HandKeypoints?) {
        guard let noun = targetName, holdCapturePending, !holdObservationInFlight else { return }
        holdCapturePending = false
        holdObservationInFlight = true
        let id = sessionID, check = holdCheckID, serial = holdCaptureSerial
        let reference = referenceCrop
        let original = target
        let support = guide?.object?.supportHeight
        Task {
            guard id == sessionID, check == holdCheckID, serial == holdCaptureSerial,
                  phase == .verifying, safetyMessage == nil else { return }
            guard let reference else { completeHoldCheck(nil, reason: "missing_reference", moved: nil); return }
            guard holdSAMCalls < Self.maxHoldSAMCalls else { completeHoldCheck(nil, reason: "budget", moved: nil); return }
            let seen = await holdCandidates(noun, snapshot: s, expectedSession: id, expectedCheck: check)
            guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil else { return }
            // Pick the candidate nearest the observed hand, then verify that exact candidate's identity.
            let point = hand?.reference ?? original ?? .zero
            let candidate = seen?.min { simd_distance($0.world, point) < simd_distance($1.world, point) }
            var identity: Bool?
            if let candidate, let boxed = Self.drawBox(s.jpeg, box: candidate.box) {
                identity = try? await MuseAgent.verifyObjectIdentity(noun: noun, jpeg: boxed, reference: reference,
                                                                    label: "hold_identity_\(id)_\(serial)")
            }
            guard id == sessionID, check == holdCheckID, serial == holdCaptureSerial,
                  phase == .verifying, safetyMessage == nil else { return }
            let near = candidate.map { HoldContact.near(hand: hand, points: $0.object?.points ?? [], centre: $0.world) } ?? false
            // A supported object must actually rise; sliding it with a hand is not possession.
            let away = candidate.flatMap { c in original.map { p in
                simd_distance(c.world, p) >= 0.05 && (support == nil || c.world.y - p.y >= 0.03)
            } } ?? false
            let observation = HoldObservation(time: s.timestamp, object: candidate?.world, hand: hand,
                                              identity: identity, nearHand: near, awayFromOriginal: away, surface: candidate?.object?.points ?? [])
            let result = holdVerification.add(observation)
            holdObservationInFlight = false
            log("hold_evidence", "n \(holdVerification.attempts) identity \(identity.map(String.init) ?? "unknown") near \(near) away \(away) result \(result)")
            switch result {
            case .confirmed(let position): completeHoldCheck(true, reason: "identity_and_shared_motion", moved: position)
            case .uncertain(let reason): completeHoldCheck(nil, reason: reason.rawValue, moved: nil)
            case .collect: await collectNextHoldEvidence(source: s, session: id, check: check)
            }
        }
    }

    private func collectNextHoldEvidence(source: FrameSnapshot, session id: Int, check: Int) async {
        guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil else { return }
        if !holdMovementIssued, handTrace.isSteady(at: lastFrameTime), let anchor = holdVerification.latestAnchor, let object = anchor.object,
           let oldHand = anchor.hand, let current = handTrace.hand(at: lastFrameTime) {
            let shifts = HandJoint.tips.compactMap { joint -> SIMD3<Float>? in
                guard let a = oldHand.joints[joint], let b = current.joints[joint] else { return nil }
                return b - a
            }
            guard shifts.count >= 2, let scene = holdScene, lastFrameTime - scene.time <= 0.4,
                  let reachDistance else { completeHoldCheck(nil, reason: "no_clear_movement", moved: nil); return }
            let shift = shifts.reduce(.zero, +) / Float(shifts.count)
            let currentObject = object + shift
            // Remove only the observed held-object surface from the self/obstacle screen.
            let shape = anchor.surface.map { $0 + shift }
            let obstacles = scene.map
            let camera = lastCamera
            let plan = HoldMovementPlan.make(object: currentObject, hand: current, camera: camera,
                profile: ReachProfile(maximumDistance: reachDistance), obstacles: obstacles, surface: shape) { point in
                    let p = DepthProjector.camera(fromWorld: point, cameraTransform: camera)
                    guard let pixel = DepthProjector.project(cameraPoint: p, intrinsics: source.intrinsics) else { return false }
                    let size = source.intrinsics.imageSize
                    return pixel.x > size.x * 0.05 && pixel.x < size.x * 0.95 && pixel.y > size.y * 0.05 && pixel.y < size.y * 0.95
                }
            guard let plan else { completeHoldCheck(nil, reason: "no_clear_movement", moved: nil); return }
            holdMovementIssued = true
            activeHoldMovement = (HoldMovementContext(baseline: current, object: currentObject, surface: shape, delta: plan.delta), source.intrinsics)
            speaker.say(plan.phrase, interrupt: true)
            while speaker.isSpeaking {
                try? await Task.sleep(for: .milliseconds(100))
                guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil else { return }
            }
            guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil else { return }
            holdMovementCapture = HoldMovementCapture(baseline: current, delta: plan.delta, started: lastFrameTime)
            // Capture will be triggered by local movement, or once after a four-second deadline.
            return
        }
        speaker.say("Keep your hand still. Taking one more look.", interrupt: true)
        try? await Task.sleep(for: .milliseconds(400))
        guard id == sessionID, check == holdCheckID, phase == .verifying, safetyMessage == nil else { return }
        requestHoldObservation(session: id, check: check)
    }

    private func completeHoldCheck(_ result: Bool?, reason: String, moved: SIMD3<Float>?) {
        clearHoldCollection()
        if result != true { holdVerification.finish(HoldFailure(rawValue: reason) ?? .insufficientEvidence) }
        holdCheckID += 1
        needsUserDecision = result != true
        if let moved { target = moved; processor.target = moved }
        log("hold_check_result", "\(result == true ? "yes" : "unclear") (\(reason)) observations \(holdVerification.attempts) captures \(holdCaptureSerial) movement_prompt \(holdMovementIssued)")
        if checkFromSession, var session = guide {
            checkFromSession = false
            session.resolveCheck(result, time: lastFrameTime).forEach(say)
            guide = session
        }
        if result == true { finish(spoken: "Confirmed. You have the \(targetName ?? "object").", event: "hold_yes") }
        else {
            phase = .grabbing
            speaker.say("I cannot confirm it. Keep your hand still. Confirm it yourself, start a new search, or stop.", interrupt: true)
        }
    }

    /// One SAM call on the hold-check photo (every check since v6). nil = the call failed.
    private func holdCandidates(_ noun: String, snapshot s: FrameSnapshot, expectedSession: Int, expectedCheck: Int) async -> [Candidate]? {
        guard expectedSession == sessionID, expectedCheck == holdCheckID, phase == .verifying, safetyMessage == nil else { return nil }
        guard holdSAMCalls < Self.maxHoldSAMCalls else {
            log("hold_sam_budget", "\(holdSAMCalls) used; cannot automatically confirm")
            return nil
        }
        holdSAMCalls += 1
        guard let response = try? await MetaAPI.segment(noun: noun, jpeg: s.jpeg,
                                                        imageLabel: "still_\(sessionID)_\(holdSAMCalls)") else { return nil }
        guard expectedSession == sessionID, expectedCheck == holdCheckID, phase == .verifying, safetyMessage == nil else { return nil }
        return Self.candidates(from: SAMParser.parse(response.text), snapshot: s)
    }

    /// Bounding box of the Vision hand joints on the uploaded image, nil without joints.
    nonisolated static func handRegion(_ joints: [HandJoint: SIMD2<Float>], snapshot s: FrameSnapshot) -> CGRect? {
        let px = joints.values.map { DiagnosticRecorder.portraitPixel(vision: $0, snapshot: s) }
        guard px.count >= 3, let minX = px.map(\.x).min(), let maxX = px.map(\.x).max(),
              let minY = px.map(\.y).min(), let maxY = px.map(\.y).max() else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // MARK: Command

    private func listen() {
        speaker.stop()
        tones.stop()
        tones.earcon(.listening)
        phase = .listening
        let id = sessionID
        Task {
            try? await Task.sleep(for: .milliseconds(180))  // let the earcon end before the mic opens
            guard id == sessionID, phase == .listening else { return }
            let heard = (try? await input.listenOnce()) ?? ""
            // The input engine may have changed the route: back to the loudspeaker before speaking.
            audio.apply()
            guard id == sessionID else { return }  // long-press reset while listening
            tones.earcon(.heard)
            log("heard", heard.isEmpty ? "(nothing)" + (input.lastError.map { " " + $0 } ?? "") : heard)
            lastHeard = heard
            switch CommandParser.parse(heard) {
            case .find(let noun):
                startFind(noun)
            case .mapRoom:
                startMapping()
            case .stop:
                finish(spoken: "Stopped. Tap to speak a command.", event: "stop")
            case nil where heard.isEmpty:
                phase = .idle
                speaker.say("I didn't catch that. Tap and say it again.")
            case nil:
                startAgent(heard: heard)
            }
        }
    }

    private func beginSession(name: String?) {
        sessionID += 1
        targetName = name
        target = nil
        candidates = []
        notFound = []
        agentFinds = 0
        samCalls = 0
        holdSAMCalls = 0
        scanCalls = 0
        scan = nil
        scanInFlight = false
        checkFromSession = false
        referenceCrop = nil
        safetyMessage = nil
        resetHoldCycle()
        mapPlanner = nil
        guide = nil
        guidePhase = "-"
        // A limited-tracking moment before this search must not trigger a re-lock (2026-10-28 log:
        // an extra SAM call 2 s into the search with tracking normal).
        reachFrame = nil
        processor.target = nil
        processor.object = nil
        sessionStart = Date()
        phase = .locating
    }

    private func startFind(_ noun: String) {
        beginSession(name: noun)
        log("command", noun)
        // Instant local cue (G4): the user hears something before any network call.
        speaker.say("Looking for the \(noun).")
        let id = sessionID
        Task {
            guard id == sessionID, phase == .locating else { return }
            await lock(noun: noun)
        }
    }

    /// The local parser could not read the command ("I'm thirsty", "the green key"): Muse Spark decides.
    /// Effort medium since v6 (understanding first; v5: "only very simple language works").
    private func startAgent(heard: String) {
        beginSession(name: nil)
        log("command_agent", heard)
        speaker.say("One moment.")
        let id = sessionID
        Task {
            let image = await snapshot()?.jpeg
            guard id == sessionID, phase == .locating else { return }
            await runAgent(prompt: "The user said: \"\(heard)\". Work out what they want and help them get it. "
                           + "If it is not about finding an object or scanning the room, say so briefly and stop.",
                           jpeg: image, effort: .medium)
        }
    }

    // MARK: Cloud (event-triggered)

    struct Candidate: Sendable {
        var info: AgentCandidate
        var world: SIMD3<Float>
        /// SAM box on the uploaded image (pixels), for the verification crop.
        var box: CGRect
        var recorded: RecordedCandidate
        /// 3D shape + support plane (guidance to the nearest surface, fingertip grasp check).
        var object: ObjectModel?
        var obstacles: ObstacleMap?
        var referenceCrop: Data?
        var sourceJPEG: Data
    }

    /// Below this SAM confidence, Spark checks the crop before we trust it (the first device test
    /// locked a power bank for "phone" in a room with no phone).
    static let verifyBelow: Float = 0.75

    /// The current frame as a snapshot (retries while depth is missing).
    private func snapshot(longEdge: CGFloat = FrameSnapshot.longEdge) async -> FrameSnapshot? {
        for _ in 0..<10 {
            if let frame = session.currentFrame,
               let s = try? FrameSnapshot.make(from: frame, tracking: tracking, longEdge: longEdge) { return s }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// One SAM event on the current frame -> up to 4 candidates in 3D, most confident first.
    /// `scanning`: counted against the scan budget (ScanPlanner) instead of `maxSAMCalls`.
    /// Small objects (SmallObjects, e.g. keys): a 930 px photo cut into 2x2 tiles of ~512 px, one SAM
    /// call per tile in parallel (2026-10-29: the keys were 13x17 px at 512 px and SAM missed them).
    private func segment(_ noun: String, scanning: Bool = false) async -> Result<[Candidate], FindError> {
        let id = sessionID
        guard scanning || samCalls < Self.maxSAMCalls else { return .failure(FindError("budget")) }
        let tiled = SmallObjects.isSmall(noun)
        guard let s = await snapshot(longEdge: tiled ? FrameSnapshot.tiledLongEdge : FrameSnapshot.longEdge) else {
            return .failure(FindError("no_frame"))
        }
        guard id == sessionID else { return .failure(FindError("cancelled")) }
        if scanning { scanCalls += 1 } else { samCalls += 1 }
        lastJPEG = s.jpeg
        do {
            let label = "find_\(sessionID)_\(samCalls + scanCalls)"
            var records: [SAMRecord]
            var samText: String
            var extra: [String: Any] = ["scanning": scanning]
            if tiled {
                let tiles = SmallObjects.tiles(for: s.imageSize)
                let texts = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                    for (i, tile) in tiles.enumerated() {
                        let rect = CGRect(x: tile.origin.x, y: tile.origin.y, width: tile.size.x, height: tile.size.y)
                        guard let jpeg = Self.crop(s.jpeg, to: rect, margin: 0) else { continue }
                        group.addTask { (i, try await MetaAPI.segment(noun: noun, jpeg: jpeg, imageLabel: "\(label)_tile\(i)").text) }
                    }
                    var out = [String](repeating: "", count: tiles.count)
                    for try await (i, text) in group { out[i] = text }
                    return out
                }
                samText = texts.joined(separator: SmallObjects.separator)
                records = SmallObjects.parseTiled(samText, origins: tiles.map(\.origin), fullSize: s.imageSize)
                extra["tile_origins"] = tiles.map { [$0.origin.x, $0.origin.y] }
                extra["tile_size"] = [tiles[0].size.x, tiles[0].size.y]
            } else {
                samText = try await MetaAPI.segment(noun: noun, jpeg: s.jpeg, imageLabel: label).text
                records = SAMParser.parse(samText)
            }
            guard id == sessionID else { return .failure(FindError("cancelled")) }
            if samText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#tile", with: "").isEmpty {
                log("sam_empty", tiled ? "4 tiles, nothing found" : "nothing found")
            }
            let list = Self.candidates(from: records, snapshot: s).map { c -> Candidate in
                var c = c
                c.info.name = noun
                return c
            }
            for c in list where c.recorded.reprojectsInsideMask == false {
                log("target_outside_mask", "id \(c.info.id)")
            }
            if let o = list.first?.object {
                extra["object_flat"] = o.isFlat
                extra["object_support_y"] = o.supportHeight ?? NSNull()
                extra["object_size_m"] = [o.size.x, o.size.y, o.size.z]
                extra["object_centre"] = [o.centre.x, o.centre.y, o.centre.z]
                extra["obstacle_points"] = list.first?.obstacles?.points.count ?? 0
            }
            record(kind: scanning ? "scan" : "sam", snapshot: s, samText: samText, candidates: list.map(\.recorded),
                   hand: nil, extra: extra)
            return list.isEmpty ? .failure(FindError("no_object")) : .success(list)
        } catch {
            // A real failure (HTTP, network); an empty SAM answer is not an error any more.
            log("api_error", error.localizedDescription)
            return .failure(FindError("api_error"))
        }
    }

    /// SAM records -> up to 4 candidates in 3D, most confident first; duplicates from overlapping
    /// tiles (same place within 4 cm) are dropped.
    nonisolated static func candidates(from records: [SAMRecord], snapshot s: FrameSnapshot) -> [Candidate] {
        let t = s.cameraTransform
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // SAM returns every instance, unsorted.
        let sorted = records.filter { ($0.confidence ?? 1) >= 0.3 }.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        var out: [Candidate] = []
        for r in sorted where out.count < 4 {
            guard let c = candidate(r, chosen: out.isEmpty, snapshot: s, camera: camera),
                  !out.contains(where: { simd_distance($0.world, c.world) < 0.04 }) else { continue }
            out.append(c)
        }
        return out
    }

    nonisolated private static func candidate(_ r: SAMRecord, chosen: Bool, snapshot s: FrameSnapshot,
                                              camera: SIMD3<Float>) -> Candidate? {
        let t = s.cameraTransform
        guard let raster = try? r.decodeMask() else { return nil }
        let mask = SourceMask(record: r, raster: raster)
        // Adaptive: small masks (keys, 13x17 px) lose every pixel to the default erosion.
        guard case .success(let hit) = MaskTarget.locateAdaptive(mask: mask, depth: s.depth, intrinsics: s.intrinsics) else { return nil }
        let check = MaskTarget.reprojectsInside(cameraPoint: hit.cameraPoint, mask: mask, intrinsics: s.intrinsics)
        let world = DepthProjector.world(fromCamera: hit.cameraPoint, cameraTransform: t)
        let info = AgentCandidate(id: r.id, confidence: r.confidence ?? 0,
                                  offset: BodyOffset(from: camera, to: world, cameraTransform: t),
                                  widthFraction: Float(r.right - r.left) / Float(r.sourceWidth),
                                  heightFraction: Float(r.bottom - r.top) / Float(r.sourceHeight))
        let box = CGRect(x: r.left, y: r.top, width: r.right - r.left, height: r.bottom - r.top)
        let recorded = RecordedCandidate(id: r.id, confidence: r.confidence ?? 0, world: world, cameraPoint: hit.cameraPoint,
                                         samples: hit.samples, depthSpread: hit.depthSpread, box: box, mask: mask,
                                         reprojected: check?.pixel, reprojectsInsideMask: check?.inside, chosen: chosen)
        let object = ObjectModel.build(mask: mask, depth: s.depth, intrinsics: s.intrinsics, cameraTransform: t)
        let obstacles = object.flatMap {
            ObstacleMap.build(mask: mask, depth: s.depth, intrinsics: s.intrinsics, cameraTransform: t, object: $0)
        }
        return Candidate(info: info, world: object?.centre ?? world, box: box, recorded: recorded,
                         object: object, obstacles: obstacles, referenceCrop: Self.crop(s.jpeg, to: box, margin: 0.3), sourceJPEG: s.jpeg)
    }

    private func lock(noun: String) async {
        let id = sessionID
        let result = await segment(noun)
        guard id == sessionID, phase == .locating else { return }  // stopped meanwhile
        switch result {
        case .failure(let error):
            log("sam_lock_fail", error.reason)
            startScan(noun)
        case .success(let list):
            log("sam_lock", "\(list.count) candidates")
            await decide(list, noun: noun)
        }
    }

    /// SAM found something: pick it (fast path), ask Spark to choose (several), or check it (unsure).
    /// A "no" from the check goes back to scanning.
    private func decide(_ list: [Candidate], noun: String) async {
        let id = sessionID
        candidates = list
        if AgentTools.isAmbiguous(list.map(\.info.confidence)) {
            speaker.say("I see more than one \(noun). Checking.")
            await runAgent(prompt: "The user said: \"\(lastHeard)\". SAM found several \(noun) candidates "
                           + "(call get_state; the photo is what the chest camera sees). Select the one they mean, or ask them.",
                           jpeg: lastJPEG, effort: .medium)
        } else if list[0].info.confidence < Self.verifyBelow {
            speaker.say("Checking.")
            let ok = await verify(noun: noun, candidate: list[0])
            guard id == sessionID, phase == .locating else { return }
            log("verify", "c \(list[0].info.confidence) -> \(ok.map { $0 ? "yes" : "no" } ?? "error")")
            if ok == true { select(list[0]) }
            else { startScan(noun) }
        } else {
            select(list[0])
        }
    }

    // MARK: Keep scanning (object not in view)

    /// Not found in this view: keep looking while the user turns, one SAM call per new steady view.
    private func startScan(_ noun: String) {
        var planner = ScanPlanner(time: lastFrameTime)
        planner.markSearched(cameraTransform: lastCamera)
        var text = ScanPlanner.startLine(noun)
        // Room map: say where it was last seen and turn the scan toward it first.
        if let item = room.item(for: noun) {
            planner.hint = item.world
            text = RoomInventory.hint(item, noun: noun, cameraTransform: lastCamera) + " " + text
            log("room_hint", "\(item.name) \(item.source) \(item.seen)")
        } else if let inventory = room.activeInventory, !inventory.items.isEmpty {
            guessFromRoom(noun, inventory: inventory)
        }
        scan = planner
        scanInFlight = false
        phase = .searching
        log("scan_start", "")
        say(SpokenLine(text: text, interrupt: true))
    }

    /// The room map does not know the object (Nils, v5: "infer from nearby things, then send the user that
    /// way"): Spark picks the mapped thing it is most likely near; the scan turns there first.
    private func guessFromRoom(_ noun: String, inventory: RoomInventory) {
        let id = sessionID, camera = lastCamera
        let items = Array(inventory.items.prefix(40))
        Task {
            let pick = try? await MuseAgent.guessNear(noun: noun, items: inventory.describe(from: camera, now: Date()),
                                                     label: "guess_\(id)")
            guard id == sessionID, phase == .searching, let i = pick ?? nil, items.indices.contains(i) else {
                log("room_guess", "none")
                return
            }
            let item = items[i]
            scan?.hint = item.world
            scan?.hintIsGuess = true
            let o = BodyOffset(from: SIMD3(lastCamera.columns.3.x, lastCamera.columns.3.y, lastCamera.columns.3.z),
                               to: item.world, cameraTransform: lastCamera)
            log("room_guess", item.name)
            say(SpokenLine(text: "It might be near the \(item.name), \(RoomInventory.place(o)). I'll look there first.",
                           interrupt: false))
        }
    }

    private func stepScan(_ f: FindFrame) {
        guard var planner = scan, let noun = targetName else { return }
        let step = planner.update(time: f.time, cameraTransform: f.cameraTransform, busy: scanInFlight, speaking: speaker.isSpeaking)
        scan = planner
        switch step {
        case .wait:
            break
        case .prompt:
            say(SpokenLine(text: planner.directionPrompt(cameraTransform: f.cameraTransform), interrupt: false))
        case .giveUp:
            var text = ScanPlanner.giveUpLine(noun)
            if let item = room.item(for: noun) {
                text = RoomInventory.hint(item, noun: noun, cameraTransform: f.cameraTransform) + " " + text
            } else if let p = lastSeen[noun] {
                text = Self.earlierLine(p, cameraTransform: f.cameraTransform) + " " + text
            }
            finish(spoken: text, event: "scan_give_up")
            suggestAfterGiveUp(noun)
        case .scan:
            scanInFlight = true
            tones.click()
            let id = sessionID
            Task {
                let result = await segment(noun, scanning: true)
                guard id == sessionID, phase == .searching else { return }
                scanInFlight = false
                switch result {
                case .success(let list):
                    log("scan_found", "\(list.count) candidates, sectors \(scan?.sectorsCovered ?? 0)")
                    scan = nil
                    phase = .locating
                    await decide(list, noun: noun)
                case .failure(let error):
                    log("scan_nothing", error.reason)
                }
            }
        }
    }

    /// After giving up: one Spark (minimal) guess from a wide photo, spoken if nothing else started.
    private func suggestAfterGiveUp(_ noun: String) {
        let id = sessionID
        Task {
            guard let s = await snapshot(), id == sessionID, phase == .idle else { return }
            guard let guess = try? await MuseAgent.suggest(noun: noun, jpeg: s.jpeg, label: "suggest_\(id)") else {
                log("spark_suggest", "none")
                return
            }
            log("spark_suggest", guess)
            guard id == sessionID, phase == .idle else { return }
            say(SpokenLine(text: "A guess: " + guess, interrupt: false))
        }
    }

    /// "Earlier, it was to your right, about 60 centimetres."
    nonisolated static func earlierLine(_ p: SIMD3<Float>, cameraTransform t: simd_float4x4) -> String {
        let found = GuidanceSession.whereIs(target: p, cameraTransform: t, name: "x")
        return "Earlier, " + found.replacingOccurrences(of: "Found the x. It's", with: "it was")
    }

    /// Muse Spark (minimal) yes/no on the whole photo with the SAM box drawn. nil = could not check.
    /// v7: a crop of the ~512 px photo was ~200 px wide and showed a green book as a thin strip under a
    /// white tube; Spark said no to both prompts. With the box on the full photo it said yes, and no for
    /// the cup's and the tube's boxes (2026-10-30, logged as verify_box_* in api_calls.csv).
    private func verify(noun: String, candidate c: Candidate) async -> Bool? {
        guard let boxed = Self.drawBox(c.sourceJPEG, box: c.box) else { return nil }
        return try? await MuseAgent.verify(noun: noun, jpeg: boxed, label: "verify_\(sessionID)")
    }

    nonisolated static func drawBox(_ jpeg: Data, box: CGRect) -> Data? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).jpegData(withCompressionQuality: 0.85) { ctx in
            image.draw(at: .zero)
            UIColor.green.setStroke()
            ctx.cgContext.setLineWidth(3)
            ctx.cgContext.stroke(box)
        }
    }

    nonisolated static func crop(_ jpeg: Data, to box: CGRect, margin: CGFloat) -> Data? {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = box.insetBy(dx: -box.width * margin, dy: -box.height * margin).intersection(bounds).integral
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
    }

    private func select(_ c: Candidate, intro: String? = nil) {
        target = c.world
        processor.target = c.world
        phase = .guiding
        reachFrame = lastCamera
        processor.object = c.object
        Haptics.success()
        tones.earcon(.success)
        log("target", "id \(c.info.id) c \(c.info.confidence)")
        // What the object looked like here, for the strict hold check later.
        referenceCrop = c.referenceCrop
        if let name = targetName {
            lastSeen[name] = c.world
            room.remember(name, at: c.world)
        }
        log("object", c.object.map { o in
            String(format: "%@ size %.0fx%.0fx%.0f cm support %@ obstacles %d", o.isFlat ? "flat" : "solid",
                   o.size.x * 100, o.size.y * 100, o.size.z * 100,
                   o.supportHeight.map { String(format: "%.2f", $0) } ?? "none", c.obstacles?.points.count ?? 0)
        } ?? "no model (centre only)")
        let session = GuidanceSession(targetName: targetName ?? "object", target: c.world, object: c.object,
                                      obstacles: c.obstacles, cameraTransform: lastCamera, time: lastFrameTime,
                                      reachProfile: ReachProfile(maximumDistance: reachDistance ?? 0))
        guide = session
        guidePhase = session.phase.rawValue
        safetyMessage = session.pauseReason
        if let intro { say(SpokenLine(text: intro, interrupt: true)) }
        for (i, line) in session.opening.enumerated() {
            say(SpokenLine(text: line.text, interrupt: line.interrupt && i == 0 && intro == nil))
        }
    }

    private func say(_ line: SpokenLine) {
        lastCue = line.text
        log("say", line.text + (line.interrupt ? " [interrupts]" : ""), distance: handDistance)
        speaker.say(line.text, interrupt: line.interrupt)
    }

    // MARK: Muse Spark commander (tool calling)

    private enum ToolResult {
        case output(String)
        case ended
    }

    private func runAgent(prompt: String, jpeg: Data?, effort: MuseAgent.Effort) async {
        let id = sessionID
        // State goes into the first message so Spark does not spend a turn on get_state.
        var history = MuseAgent.userMessage(AgentTools.instructions + "\n\n" + prompt
                                            + "\n\nCurrent state (same as get_state): " + agentState().json(), jpeg: jpeg)
        // v6 run 2: "I'm thirsty" -> two questions -> the answer hit the 6-turn limit. Nils: the agent is not limited.
        for turnIndex in 0..<16 {
            let turn: SparkTurn
            do {
                turn = try await MuseAgent.respond(history: history, effort: effort, label: "agent_\(id)_\(turnIndex)")
            } catch {
                log("agent_error", error.localizedDescription)
                guard id == sessionID else { return }
                phase = .idle
                speaker.say("Sorry, I'm not sure. Tap and try again.", interrupt: true)
                return
            }
            guard id == sessionID, phase == .locating else { return }
            if turn.calls.isEmpty {
                // tool_choice is always auto: a plain text reply ends the turn.
                log("agent_text", turn.text)
                phase = .idle
                speaker.say(turn.text.isEmpty ? "Sorry, I'm not sure. Tap and try again." : turn.text)
                return
            }
            var outputs: [[String: Any]] = []
            for call in turn.calls {
                log("agent_tool", "\(call.name) \(call.arguments)")
                guard let action = AgentAction.parse(name: call.name, arguments: call.arguments) else {
                    outputs.append(MuseAgent.toolOutput(callID: call.callID, output: #"{"error":"unknown tool or bad arguments"}"#))
                    continue
                }
                switch await perform(action) {
                case .output(let text):
                    outputs.append(MuseAgent.toolOutput(callID: call.callID, output: text))
                case .ended:
                    return
                }
                guard id == sessionID, phase == .locating else { return }
            }
            history += turn.calls.map(MuseAgent.callItem) + outputs
        }
        log("agent_turn_limit", "")
        phase = .idle
        speaker.say("Sorry, I'm not sure. Tap and try again.")
    }

    private func perform(_ action: AgentAction) async -> ToolResult {
        let id = sessionID
        guard phase == .locating else { return .ended }
        switch action {
        case .getState:
            return .output(agentState().json())
        case .findObject(let noun):
            // 2026-10-29: Spark called find_object five times on the same view: a phrase that already
            // found nothing goes straight to the scan.
            if notFound.contains(noun) {
                log("agent_scan", "repeat \(noun)")
                targetName = noun
                startScan(noun)
                return .ended
            }
            speaker.say("Looking for the \(noun).")
            agentFinds += 1
            let result = await segment(noun)
            guard id == sessionID, phase == .locating else { return .ended }
            switch result {
            case .success(let list):
                // Keep earlier finds selectable ("water bottle" and "cup" for "I'm thirsty").
                let k = agentFinds
                let fresh = list.map { c -> Candidate in
                    var c = c
                    c.info.id = "\(k)-\(c.info.id)"
                    return c
                }
                candidates = Self.merged(candidates, fresh)
                return .output(agentState().json())
            case .failure(let error):
                notFound.append(noun)
                log("agent_not_found", "\(noun) \(error.reason)")
                return .output(agentState().json())
            }
        case .scanFor(let noun):
            log("agent_scan", noun)
            targetName = noun
            startScan(noun)
            return .ended
        case .mapRoom:
            log("agent_map_room", "")
            startMapping()
            return .ended
        case .selectTarget(let candidateID, let sentence):
            guard let c = candidates.first(where: { $0.info.id == candidateID }) else {
                return .output(#"{"error":"unknown candidate_id"}"#)
            }
            if !c.info.name.isEmpty { targetName = c.info.name }
            let intro = sentence.flatMap(Self.withoutDirections)
            if let sentence, intro != sentence { log("agent_say_trimmed", "\(sentence) -> \(intro ?? "(nothing)")") }
            select(c, intro: intro)
            return .ended
        case .say(let text):
            speaker.say(text)
            return .output("ok")
        case .askUser(let question):
            speaker.say(question, interrupt: true)
            try? await Task.sleep(for: .milliseconds(150))
            while speaker.isSpeaking {
                guard id == sessionID, phase == .locating else { return .ended }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard id == sessionID, phase == .locating else { return .ended }
            let answer = (try? await input.listenOnce()) ?? ""
            guard id == sessionID, phase == .locating else { return .ended }
            audio.apply()
            log("agent_answer", answer)
            return .output(answer.isEmpty ? "(no answer)" : answer)
        case .stop:
            log("agent_stop", "")
            phase = .idle
            tones.stop()
            return .ended
        }
    }

    private func agentState() -> AgentState {
        let rooms = room.activeInventory.map { inv in
            inv.describe(from: lastCamera, now: Date()).split(separator: "\n").map(String.init)
        } ?? []
        return AgentState(phase: phase.rawValue, userSaid: lastHeard, targetName: targetName,
                          candidates: candidates.map(\.info), samCallsLeft: Self.maxSAMCalls - samCalls, tracking: tracking,
                          notFound: notFound, roomItems: rooms)
    }

    nonisolated static func withoutDirections(_ text: String) -> String? { AgentText.withoutDirections(text) }

    /// Agent finds: a new detection within 5 cm of an earlier one is the same thing ("bottle" and
    /// "water bottle"); keep the more confident one (Muse review 2026-10-30).
    nonisolated static func merged(_ old: [Candidate], _ fresh: [Candidate]) -> [Candidate] {
        var all = old
        for c in fresh {
            if let i = all.firstIndex(where: { simd_distance($0.world, c.world) < 0.05 }) {
                if c.info.confidence > all[i].info.confidence { all[i] = c }
            } else {
                all.append(c)
            }
        }
        return all
    }

    // MARK: Local loop (~30 Hz)

    private func ingest(_ f: FindFrame) {
        lastInputFrame = ProcessInfo.processInfo.systemUptime
        tracking = f.tracking
        lastCamera = f.cameraTransform
        lastFrameTime = f.time
        palm = f.hand?.reference
        fingertips = f.hand.map { Array($0.tips.values) } ?? []
        handStatus = f.hand.map { "\($0.keypointCount)/6" } ?? (f.handFail ?? "-")

        checkRelocalization(f)
        if calibrating {
            if speaker.isSpeaking { calibrationStarted = nil; return }
            calibrationStarted = calibrationStarted ?? f.time
            let elapsed = f.time - (calibrationStarted ?? f.time)
            if elapsed > 15 {
                calibrating = false
                speaker.say("Measurement failed. Keep the phone secured and your index finger visible, then try again.", interrupt: true)
            } else if elapsed > 3, f.tracking == "normal",
                      let distance = calibration.update(time: f.time, fingertip: f.hand?.joints[.indexTip],
                          camera: SIMD3(f.cameraTransform.columns.3.x, f.cameraTransform.columns.3.y, f.cameraTransform.columns.3.z)) {
                reachDistance = distance
                calibrating = false
                speaker.say("Comfortable reach measured: \(Int(distance * 100)) centimetres. Keep using your \(selectedHand) hand and keep your body still. Setup complete. Tap anywhere to say what to find. With VoiceOver, double tap with two fingers.", interrupt: true)
            }
            return
        }
        if [.guiding, .grabbing, .verifying].contains(phase), f.tracking != "normal" {
            pauseForSafety("Stop your hand. Tracking is unreliable. Start a new search after tracking recovers.")
        }
        if [.guiding, .grabbing, .verifying].contains(phase), let reachFrame {
            let p = f.cameraTransform.columns.3, q = reachFrame.columns.3
            if ReachFrame.rotationDifference(reachFrame, f.cameraTransform) > 15 * .pi / 180 || simd_distance(SIMD3(p.x, p.y, p.z), SIMD3(q.x, q.y, q.z)) > 0.06 {
                pauseForSafety("Stop your hand. The phone or your body moved. Start a new search to confirm the object again.")
            }
        }
        if [.guiding, .grabbing].contains(phase), f.obstacles == nil {
            pauseForSafety("Stop your hand. I cannot measure the nearby path reliably. Start a new search when the depth view is clear.")
        }
        if safetyMessage != nil { return }
        handTrace.append(time: f.time, hand: f.hand)
        holdScene = f.obstacles.map { (f.time, $0) }
        if phase == .verifying, let active = activeHoldMovement {
            let camera = f.cameraTransform
            let failure = active.context.failure(hand: handTrace.hand(at: f.time), camera: camera,
                profile: ReachProfile(maximumDistance: reachDistance ?? 0), obstacles: f.obstacles) { point in
                    let p = DepthProjector.camera(fromWorld: point, cameraTransform: camera)
                    guard let pixel = DepthProjector.project(cameraPoint: p, intrinsics: active.intrinsics) else { return false }
                    let size = active.intrinsics.imageSize
                    return pixel.x > size.x * 0.05 && pixel.x < size.x * 0.95 && pixel.y > size.y * 0.05 && pixel.y < size.y * 0.95
                }
            if let failure {
                log("hold_movement_veto", failure.rawValue)
                completeHoldCheck(nil, reason: "no_clear_movement", moved: nil)
                speaker.say("Stop your hand. I cannot continue this check. Confirm it yourself, start a new search, or stop.", interrupt: true)
            }
        }
        if phase == .verifying, let movement = holdMovementCapture,
           movement.ready(time: f.time, hand: handTrace.hand(at: f.time)) {
            holdMovementCapture = nil
            speaker.say("Stop your hand. Checking the evidence.", interrupt: true)
            requestHoldObservation(session: sessionID, check: holdCheckID)
        }
        if let capture = f.capture {
            record(kind: capture.kind, snapshot: capture.snapshot, samText: nil, candidates: [],
                   hand: RecordedHand(vision: f.handVision, world: f.hand?.joints ?? [:], depths: f.handDepths),
                   extra: ["hand_to_target_cm": handDistance.map { $0 * 100 } ?? -1,
                           "target_world": target.map { [$0.x, $0.y, $0.z] } ?? []])
            if phase == .verifying, capture.kind == "hold_evidence:\(sessionID):\(holdCheckID):\(holdCaptureSerial)" {
                runHoldObservation(capture.snapshot, hand: handTrace.hand(at: f.time))
            }
        }
        if phase == .searching {
            stepScan(f)
            return
        }
        if phase == .mapping {
            stepMapping(f)
            return
        }
        guard !needsUserDecision, phase == .guiding || phase == .grabbing, var session = guide else {
            handDistance = nil
            return
        }
        let out = session.update(time: f.time, hand: f.hand, cameraTransform: f.cameraTransform,
                                 targetDepthDelta: f.targetDepthDelta, speaking: speaker.isSpeaking,
                                 trackingNormal: f.tracking == "normal", liveObstacles: f.obstacles)
        guide = session
        if let reason = session.pauseReason { pauseForSafety(reason); return }
        guidePhase = out.phase.rawValue
        handDistance = out.handDistance
        tones.update(distance: out.toneDistance)
        for line in out.lines {
            say(line)
            // Snapshot the hand at the moments that tell us most about the hand-point bias.
            if line.text == "I see your hand." { processor.requestCapture("hand_seen") }
            if line.text.hasPrefix("Stop. The ") { processor.requestCapture("grab") }
        }
        if out.requestCheck {
            startHoldCheck(fromSession: true, reason: out.checkReason)
            return
        }
        switch out.phase {
        case .grabbing:
            phase = .grabbing
        case .checking:
            break
        case .done:
            finish(spoken: nil, event: "pickup")
        case .gaveUp:
            finish(spoken: "Stopping. Tap to start again.", event: "gave_up")
        case .waitingForHand, .guiding:
            break
        }
    }

    // MARK: Room map ("scan the room")

    /// Saved map: tracking "normal" = matched. Not matched within the timeout: fresh session, no map.
    private func checkRelocalization(_ f: FindFrame) {
        guard let since = relocalizingSince else { return }
        if f.tracking == "normal" {
            relocalizingSince = nil
            room.relocalized()
            log("room_map_relocalized", String(format: "%.1f s", Date().timeIntervalSince(since)))
        } else if Date().timeIntervalSince(since) > RoomMapStore.relocalizeTimeout {
            relocalizingSince = nil
            log("room_map_fallback", f.tracking)
            session.run(Self.trackingConfig(), options: [.resetTracking, .removeExistingAnchors])
        }
    }

    private func startMapping() {
        beginSession(name: nil)
        var planner = ScanPlanner(time: lastFrameTime)
        planner.budget = 12
        planner.minNewAngle = 30 * .pi / 180
        mapPlanner = planner
        mapInventory = RoomInventory(created: Date())
        mapInFlight = 0
        mapViews = 0
        phase = .mapping
        log("map_start", "")
        say(SpokenLine(text: "Scanning the room. Hold the phone at chest height and turn slowly in a full circle. "
                       + "Tap when you are done.", interrupt: true))
    }

    private func stepMapping(_ f: FindFrame) {
        guard var planner = mapPlanner else { return }
        let step = planner.update(time: f.time, cameraTransform: f.cameraTransform, busy: mapInFlight >= 2,
                                  speaking: speaker.isSpeaking)
        mapPlanner = planner
        switch step {
        case .wait:
            break
        case .prompt:
            say(SpokenLine(text: planner.mappingPrompt(cameraTransform: f.cameraTransform), interrupt: false))
        case .giveUp:
            if mapInFlight == 0 { finishMapping(early: false) }
        case .scan:
            tones.click()
            mapInFlight += 1
            mapViews += 1
            let id = sessionID, view = mapViews
            Task {
                defer { if id == sessionID { mapInFlight -= 1 } }
                guard let s = await snapshot(), id == sessionID, phase == .mapping else { return }
                guard let reply = try? await MuseAgent.listObjects(jpeg: s.jpeg, label: "room_\(id)_\(view)") else {
                    log("map_view_fail", "\(view)")
                    return
                }
                guard id == sessionID, phase == .mapping else { return }
                var names: [String] = []
                for o in RoomInventory.parseSparkObjects(reply) {
                    guard let p = RoomInventory.place(portrait: o.point, depth: s.depth, intrinsics: s.intrinsics,
                                                      cameraTransform: s.cameraTransform) else { continue }
                    mapInventory.remember(o.name, at: p, date: Date(), source: "room_scan")
                    names.append(o.name)
                }
                log("map_view", "\(view): " + names.joined(separator: " "))
                record(kind: "room", snapshot: s, samText: reply, candidates: [], hand: nil,
                       extra: ["room_objects": names])
            }
        }
    }

    /// Save the ARWorldMap and the inventory (overwrites the previous room map).
    private func finishMapping(early: Bool) {
        let id = sessionID
        let inventory = mapInventory
        mapPlanner = nil
        phase = .idle
        log("map_finish", "\(mapViews) views, \(inventory.items.count) items" + (early ? " (tap)" : ""))
        guard !inventory.items.isEmpty else {
            Haptics.warning()
            say(SpokenLine(text: "I didn't find anything to remember. Try again with more light.", interrupt: true))
            return
        }
        say(SpokenLine(text: "Saving the room.", interrupt: true))
        session.getCurrentWorldMap { map, error in
            nonisolated(unsafe) let map = map  // handed to the main actor once, never shared
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, id == self.sessionID else { return }
                guard let map else {
                    self.log("map_save_fail", message ?? "no map")
                    self.say(SpokenLine(text: "I couldn't save the room. Move the phone around a little more and try again.",
                                        interrupt: true))
                    return
                }
                do {
                    try self.room.save(map: map, inventory: inventory)
                    let names = Self.summaryNames(inventory)
                    self.log("map_saved", "\(inventory.items.count) items, \(map.anchors.count) anchors")
                    Haptics.success()
                    self.tones.earcon(.success)
                    self.say(SpokenLine(text: "Room saved. I remember \(inventory.items.count) things, including "
                                        + names.joined(separator: ", ") + ".", interrupt: true))
                } catch {
                    self.log("map_save_fail", error.localizedDescription)
                    self.say(SpokenLine(text: "I couldn't save the room.", interrupt: true))
                }
            }
        }
    }

    nonisolated static func summaryNames(_ inventory: RoomInventory) -> [String] { inventory.summaryNames() }

    private func record(kind: String, snapshot: FrameSnapshot, samText: String?, candidates: [RecordedCandidate],
                        hand: RecordedHand?, extra: [String: Any] = [:]) {
        let write: (UIImage?) -> Void = { [weak self] screen in
            guard let self else { return }
            let prefix = recorder.record(kind: kind, snapshot: snapshot, noun: targetName, samText: samText,
                                         candidates: candidates, hand: hand, screen: screen, extra: extra)
            recordings += 1
            log("recorded", prefix)
        }
        if let arView { arView.snapshot(saveToHDR: false) { write($0) } } else { write(nil) }
    }

    /// Log CSV and the diagnostics folder of this launch, for the Export button.
    var exportURLs: [URL] {
        let fm = FileManager.default
        return [logURL, fm.fileExists(atPath: recorder.folder.path) ? recorder.folder : nil,
                fm.fileExists(atPath: ApiCallLog.url.path) ? ApiCallLog.url : nil,
                fm.fileExists(atPath: RoomMapStore.folder.appendingPathComponent("inventory.json").path)
                    ? RoomMapStore.folder.appendingPathComponent("inventory.json") : nil].compactMap { $0 }
    }

    /// `spoken` nil: the line was already said (GuidanceSession's "Got it").
    private func finish(spoken: String?, event: String) {
        tones.stop()
        processor.target = nil
        processor.object = nil
        if ["pickup", "hold_yes", "user_confirmed"].contains(event) {
            Haptics.success()
            tones.earcon(.success)
            // It is in the user's hand now: not at the spot where it was found (v5: stale hints).
            if let name = targetName {
                room.carried(name, from: target)
                lastSeen[name] = nil
            }
        } else {
            Haptics.warning()
            tones.earcon(.failure)
        }
        if let spoken { speaker.say(spoken, interrupt: true) }
        log(event, spoken ?? "", distance: handDistance)
        phase = ["pickup", "done_tap", "hold_yes", "user_confirmed"].contains(event) ? .done : .idle
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
    /// Six-point hand in world space; nil when not usable this frame (see `handFail`).
    var hand: HandKeypoints?
    var handVision: [HandJoint: SIMD2<Float>]
    var handDepths: [HandJoint: Float]
    var handFail: String?
    /// Set on the frame after `requestCapture`: the photo of this exact frame, for the recorder.
    var capture: (kind: String, snapshot: FrameSnapshot)?
    /// LiDAR depth at the target's pixel minus the target's own depth; > 0 = something farther
    /// is visible there now (object lifted away). nil when the target is off-screen or unreadable.
    var targetDepthDelta: Float?
    var obstacles: ObstacleMap?
}

/// Runs the six-point hand pipeline on every second frame (≤ 30 Hz) off the main thread; drops frames
/// while busy (FrameGate) so ARKit never waits on us.
nonisolated final class FindFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let gate = FrameGate(label: "sightline.find.frames")
    var queue: DispatchQueue { gate.delegateQueue }
    var onFrame: (@Sendable (FindFrame) -> Void)?
    private let locator = HandKeypointLocator()
    private var frameCount = 0

    // Written from the main actor, read on `queue`.
    private let lock = NSLock()
    private var _target: SIMD3<Float>?
    var target: SIMD3<Float>? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }
    private var _object: ObjectModel?
    var object: ObjectModel? {
        get { lock.withLock { _object } }
        set { lock.withLock { _object = newValue } }
    }
    private var _capture: String?

    /// The next processed frame also carries its photo (FrameSnapshot) under this kind.
    func requestCapture(_ kind: String) { lock.withLock { _capture = kind } }
    private func takeCapture() -> String? { lock.withLock { defer { _capture = nil }; return _capture } }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }
        gate.submit(frame) { [self] frame in
            let r = locator.locate(in: frame)
            let tracking = FrameProcessor.describe(frame.camera.trackingState)
            let capture = takeCapture().flatMap { kind in
                (try? FrameSnapshot.make(from: frame, tracking: tracking)).map { (kind: kind, snapshot: $0) }
            }
            onFrame?(FindFrame(time: frame.timestamp, tracking: tracking, cameraTransform: frame.camera.transform,
                               hand: r.keypoints, handVision: r.vision, handDepths: r.depths, handFail: r.failReason,
                               capture: capture,
                               targetDepthDelta: target.flatMap { depthDelta(at: $0, frame: frame) },
                               obstacles: object.flatMap { liveObstacles(frame: frame, object: $0, hand: r.keypoints) }))
        }
    }

    /// Current-frame conservative point cloud. Hand/target returns are excluded; occluded or
    /// transparent obstacles remain unknown, so this cannot certify a collision-free route.
    private func liveObstacles(frame: ARFrame, object: ObjectModel, hand: HandKeypoints?) -> ObstacleMap? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else { return nil }
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics,
            imageSize: SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height)))
            .scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        let origin = frame.camera.transform.columns.3
        let joints = hand.map { HandEnvelope.centres(hand: $0, camera: SIMD3(origin.x, origin.y, origin.z)) } ?? []
        var points: [SIMD3<Float>] = []
        var usable = 0
        var total = 0
        for y in stride(from: 0, to: depth.height, by: 4) {
            for x in stride(from: 0, to: depth.width, by: 4) {
                total += 1
                let i = y * depth.width + x, d = depth.depth[i]
                guard d.isFinite, d > 0.1, d < 1.5, (depth.confidence?[i] ?? 0) >= 2 else { continue }
                usable += 1
                let p = DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: SIMD2(Float(x), Float(y)), depth: d, intrinsics: k), cameraTransform: frame.camera.transform)
                if let support = object.supportHeight, p.y <= support + 0.025 { continue }
                guard object.distanceToSurface(p) > 0.04,
                      !joints.contains(where: { simd_distance($0, p) < 0.065 }) else { continue }
                points.append(p)
            }
        }
        guard SceneCoverage.isUsable(valid: usable, sampled: total) else { return nil }
        return ObstacleMap(points: points)
    }

    /// Median LiDAR depth (medium+ confidence) in a 5x5 window at the target's pixel, minus the target's depth.
    private func depthDelta(at target: SIMD3<Float>, frame: ARFrame) -> Float? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else { return nil }
        let t = frame.camera.transform
        let c = DepthProjector.camera(fromWorld: target, cameraTransform: t)
        let rawSize = SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height))
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: rawSize)
            .scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        guard let p = DepthProjector.project(cameraPoint: c, intrinsics: k) else { return nil }
        let cx = Int(p.x.rounded()), cy = Int(p.y.rounded())
        var values: [Float] = []
        for y in (cy - 2)...(cy + 2) where y >= 0 && y < depth.height {
            for x in (cx - 2)...(cx + 2) where x >= 0 && x < depth.width {
                let i = y * depth.width + x
                let d = depth.depth[i]
                guard d.isFinite, d > 0, (depth.confidence?[i] ?? 2) >= 1 else { continue }
                values.append(d)
            }
        }
        guard values.count >= 8, let median = Stats.median(values) else { return nil }
        return median - (-c.z)
    }
}
