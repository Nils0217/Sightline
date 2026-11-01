// labels: production, needs-review, important
// Find-and-grab app orchestration. v9 (2026-10-31, Nils: "the whole process is a piece of shit user
// experience, and the voice instruction is crumbled"): reach measured once and saved; one screen with
// tap (start/stop), double tap ("Is this it?"), long press (measure reach); short spoken lines; any
// pick-up starts a one-photo hold check (SAM + Spark, HoldDecision). Nothing latches: only "out of
// reach" or a lasting obstacle ends a search. Cloud calls stay event-triggered.

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
    /// The hand-help conversation is running (`startHandHelp`).
    @ObservationIgnored private var handHelpRunning = false
    /// Locks Spark said were not the object, this search.
    @ObservationIgnored private var rejected: [Candidate] = []
    /// "Which one?" was asked this search (a re-lock must not ask again about the first one).
    @ObservationIgnored private var whichAsked = false

    /// Comfortable reach (camera to index fingertip), measured once and saved across launches.
    private(set) var reachDistance: Float? = FindModel.savedReach
    private(set) var calibrating = false
    @ObservationIgnored private var calibration = ReachCalibration()
    @ObservationIgnored private var calibrationStarted: Double?
    /// The last hold check could not tell (status line only since 2026-11-01).
    private(set) var lastCheckUnsure = false
    @ObservationIgnored private var lastInputFrame: Double = 0
    @ObservationIgnored private var frameWatchdog: Task<Void, Never>?

    /// Wrist to index tip, measured with the reach (v9.1); scales hand-size thresholds.
    private(set) var handLength: Float? = {
        let v = UserDefaults.standard.float(forKey: FindModel.handKey)
        return v > 0.05 ? v : nil
    }()
    static let handKey = "sightline.handLength"
    /// Every arm and hand distance threshold, for this user (Nils, 2026-10-31).
    var bodyScale: BodyScale { BodyScale(reach: reachDistance, hand: handLength) }
    /// OBSOLETE (2026-11-01): a double tap no longer claims; always false.
    @ObservationIgnored private var userClaimed = false
    /// The last hold-check photo, for `describeHeld`.
    @ObservationIgnored private var lastCheckPhoto: Data?
    /// Descriptions this search. After `maxDescribes` the camera has had its chance (Nils, 2026-11-01: the
    /// "Is this it?" loop must end): unsure checks and double taps get `cameraCantTell`, with no API call.
    @ObservationIgnored private var describes = 0
    static let maxDescribes = 2
    static let cameraCantTell = "The camera can't tell. Feel it, or close the app if it's right."
    /// Burst recordings (BurstRecorder.swift): per search and per launch caps.
    @ObservationIgnored private var burstsThisSearch = 0
    @ObservationIgnored private var burstsThisLaunch = 0
    @ObservationIgnored private var burstMeta: [String: [String: Any]] = [:]
    static let maxBurstsPerSearch = 5
    static let maxBurstsPerLaunch = 30
    static let reachKey = "sightline.reachDistance"
    static var savedReach: Float? {
        let v = UserDefaults.standard.float(forKey: reachKey)
        return v > 0.2 ? v : nil
    }

    /// Long press: measure the comfortable reach (index fingertip held out, body still).
    func beginReachCalibration() {
        cancel()
        Haptics.tap()
        calibration = ReachCalibration()
        calibrating = true
        calibrationStarted = nil
        log("reach_measure", "start")
        speaker.say("Hold your hand out comfortably. Hold still.", interrupt: true)
    }

    /// Cancel everything silently (internal: new task, background, re-measure). Invalidates late results.
    private func cancel() {
        sessionID += 1
        holdCheckID += 1
        input.cancel()
        tones.stop()
        guide = nil
        scan = nil
        mapPlanner = nil
        processor.target = nil
        processor.object = nil
        candidates = []
        handDistance = nil
        calibrating = false
        lastCheckUnsure = false
        describes = 0
        phase = .idle
    }

    /// The user stopped (tap during a task, "stop", VoiceOver action).
    func stop() {
        cancel()
        speaker.stop()
        log("stop", "user")
        speaker.say("Stopped.", interrupt: true)
    }

    func finishRoomScan() {
        guard phase == .mapping else { return }
        finishMapping(early: true)
    }

    /// Double tap = "Is this it?" (case 2, Nils 2026-11-01: holding something and not sure). Idle: same as
    /// a tap (start listening). A user who is sure just closes the app (case 1), so nothing claims "I have it".
    func doubleTap() {
        Haptics.tap()
        log("double_tap", phase.rawValue)
        switch phase {
        case .idle, .done:
            tap()
        case .mapping:
            finishRoomScan()
        case .guiding, .grabbing:
            // The answer is "Yes. That's the X." / "No. The X is still there." / "I can't tell. Hold it up to the camera."
            if lastCheckUnsure, describes >= Self.maxDescribes {
                log("check_skipped", "describes used")
                say(SpokenLine(text: Self.cameraCantTell, interrupt: true))
                return
            }
            guide?.beginManualCheck()
            startHoldCheck(fromSession: false, reason: "asked")
        case .listening, .locating, .searching, .verifying:
            break
        }
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
                    // Leaving the app ends the task silently; the saved reach stays.
                    if event == "app_background" {
                        self?.cancel()
                        self?.speaker.stop()
                    }
                }
            })
        }
        audio.onReset = { [weak self] in self?.speaker.rebuild(reason: "audio reset") }
        processor.bursts.onBurst = { [weak self] label, frames in
            guard let model = self else { return }
            Task { @MainActor in model.saveBurst(label, frames: frames) }
        }
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
                // No camera frames: no tones pretending to guide (the session resumes when frames return).
                if ProcessInfo.processInfo.systemUptime - lastInputFrame > 0.75 { tones.stop() }
            }
        }
        Task {
            if await SpeechInput.requestAuthorization() {
                speaker.say(reachDistance == nil ? "Welcome. Hold your hand out comfortably, then press and hold the screen."
                                                 : "Ready. Tap and say what to find.")
            } else {
                speaker.say("Sightline needs microphone and speech permission. Please allow them in Settings.")
            }
        }
    }

    func pause() {
        cancel()
        frameWatchdog?.cancel()
        frameWatchdog = nil
        session.pause()
        tones.stop()
        speaker.stop()
    }


    /// Tap: idle -> listen; room scan -> finish and save; any other task -> stop.
    /// Every tap is answered at once (haptic, then a sound or words), 2026-10-29 blindfold test.
    func tap() {
        Haptics.tap()
        log("tap", phase.rawValue)
        if calibrating { stop(); return }
        switch phase {
        case .idle, .done:
            guard reachDistance != nil else {
                speaker.say("First, hold your hand out comfortably, then press and hold the screen.", interrupt: true)
                return
            }
            listen()
        case .mapping:
            finishRoomScan()
        default:
            stop()
        }
    }

    /// VoiceOver "Status" action and the Status button.
    func speakStatus() {
        Haptics.tap()
        let line = statusLine()
        log("status", line)
        speaker.say(line, interrupt: true)
    }

    func statusLine() -> String {
        let name = targetName ?? "object"
        if calibrating { return "Measuring your reach. Hold still." }
        if reachDistance == nil { return "Hold your hand out comfortably, then press and hold the screen." }
        switch phase {
        case .idle: return "Ready. Tap and say what to find."
        case .listening: return "Listening."
        case .locating: return "Looking for the \(name)."
        case .searching: return "Looking for the \(name). Turn slowly."
        case .guiding:
            guard let d = handDistance else { return "Going to the \(name). Hold your hand out." }
            return "The \(name) is \(max(1, Int((d * 10).rounded())) * 10) centimetres from your hand."
        case .grabbing: return lastCheckUnsure ? "Double tap to check the \(name)." : "The \(name) is at your fingers."
        case .verifying: return "Checking."
        case .done: return "You have the \(name). Tap to find something else."
        case .mapping: return "Scanning the room. \(mapInventory.items.count) things so far. Tap when done."
        }
    }

    // MARK: Hold check (one photo: SAM where it is + Spark is the hand holding it)

    /// OBSOLETE since the case-2 flow (2026-11-01): nothing calls it; a check that cannot tell no longer
    /// takes the user's word. Kept for the record.
    private func acceptUserClaim(reason: String) {
        lastCheckUnsure = false
        userClaimed = false
        holdCheckID += 1
        log("user_claim", reason)
        finish(spoken: "Okay. You have the \(targetName ?? "object").", event: "user_confirmed")
    }

    /// Saves the last 2 s and the next 2 s around a check (capped per search and per launch).
    private func startBurst(_ label: String, meta: [String: Any]) {
        guard burstsThisSearch < Self.maxBurstsPerSearch, burstsThisLaunch < Self.maxBurstsPerLaunch,
              processor.bursts.start(label) else { return }
        burstsThisSearch += 1
        burstsThisLaunch += 1
        burstMeta[label] = meta
    }

    private func saveBurst(_ label: String, frames: [BurstFrame]) {
        let meta = burstMeta.removeValue(forKey: label) ?? [:]
        let folder = recorder.folder.appendingPathComponent("burst_\(label)")
        log("recorded_burst", "\(label) \(frames.count) frames")
        DispatchQueue.global(qos: .utility).async { BurstRing.write(frames, to: folder, meta: meta) }
    }

    /// Any pick-up (GuidanceSession) or a double tap. The photo is the next processed frame.
    private func startHoldCheck(fromSession: Bool, reason: String?, claimed: Bool = false) {
        guard phase == .guiding || phase == .grabbing, targetName != nil else { return }
        userClaimed = claimed
        checkFromSession = guide != nil
        phase = .verifying
        tones.stop()
        holdCheckID += 1
        let id = sessionID, check = holdCheckID
        if !fromSession { say(SpokenLine(text: "Checking.", interrupt: true)) }
        log("hold_check", reason ?? (fromSession ? "session" : "double_tap"))
        processor.requestCapture("hold_check:\(id):\(check)")
        let scale = bodyScale
        startBurst("\(id)_\(check)_\(reason ?? "check")", meta: [
            "target": targetName ?? "", "reason": reason ?? "", "session": id, "check": check,
            "target_world": target.map { [$0.x, $0.y, $0.z] } ?? [],
            "object_points": (guide?.object?.points ?? []).prefix(400).map { [$0.x, $0.y, $0.z] },
            "support_y": guide?.object?.supportHeight ?? NSNull(),
            "reach_m": scale.reach, "hand_m": scale.hand])
        Task {
            try? await Task.sleep(for: .seconds(25))
            guard id == sessionID, check == holdCheckID, phase == .verifying else { return }
            log("hold_check_timeout", "")
            completeHoldCheck(nil, reason: "timeout")
        }
    }

    /// SAM and Spark in parallel on the check photo; HoldDecision combines them.
    private func runHoldCheck(_ s: FrameSnapshot, hand: HandKeypoints?, spot evidence: SpotEvidence?) {
        guard let noun = targetName, let original = target else { return }
        // Layer 2, record only (v9.1): what LiDAR sees where the target was. Never used to decide.
        log("spot_evidence", evidence?.summary ?? "none")
        let id = sessionID, check = holdCheckID
        let reference = referenceCrop
        lastCheckPhoto = s.jpeg
        let supported = guide?.object?.supportHeight != nil
        Task {
            async let seen = holdCandidates(noun, snapshot: s, expectedSession: id, expectedCheck: check)
            async let spark = try? MuseAgent.verifyHolding(noun: noun, jpeg: s.jpeg, reference: reference,
                                                           label: "hold_\(id)_\(check)")
            let (list, sparkSays) = await (seen, spark)
            guard id == sessionID, check == holdCheckID, phase == .verifying else { return }
            // The candidate nearest the hand (else the original spot) is the one that could be in it.
            let point = hand?.reference ?? original
            let candidate = list?.min { simd_distance($0.world, point) < simd_distance($1.world, point) }
            let near = candidate.map { HoldContact.near(hand: hand, points: $0.object?.points ?? [], centre: $0.world) } ?? false
            let (held, atSpot) = HoldGeometry.classify(candidate: candidate?.world, original: original,
                                                       supported: supported, nearHand: near)
            let spot: Bool? = list == nil ? nil : (atSpot ?? false) || (list ?? []).contains {
                simd_distance($0.world, original) < HoldGeometry.spotRadius }
            let (result, why) = HoldDecision.decide(held: held, atSpot: spot, spark: sparkSays ?? nil)
            log("hold_evidence", "sam \(list.map { "\($0.count)" } ?? "error") near \(near) held \(held) "
                + "at_spot \(spot.map(String.init) ?? "nil") spark \((sparkSays ?? nil).map(String.init) ?? "nil")")
            if result == true, let c = candidate, held { target = c.world }
            completeHoldCheck(result, reason: why.rawValue)
        }
    }

    private func completeHoldCheck(_ result: Bool?, reason: String) {
        log("hold_check_result", "\(result.map { $0 ? "yes" : "no" } ?? "unsure") (\(reason))")
        userClaimed = false
        holdCheckID += 1
        lastCheckUnsure = result == nil
        var session = guide
        let lines = session?.resolveCheck(result, time: lastFrameTime) ?? []
        let describe = session?.takeDescribeRequest() ?? false
        guide = session
        checkFromSession = false
        lines.forEach(say)
        if describe { describeHeld() }
        switch result {
        case true?: finish(spoken: nil, event: "hold_yes")
        case false?: phase = .guiding
        case nil: phase = .grabbing
        }
    }

    /// The held-up look still cannot tell (Nils, 2026-11-01: never leave the user with "it may be"): Spark tells
    /// the user how to bring it into view, or what it sees in their hand, so they can judge. 1 Spark call.
    private func describeHeld() {
        guard let noun = targetName, let photo = lastCheckPhoto else { return }
        guard describes < Self.maxDescribes else {
            log("describe_skipped", "\(describes) used")
            say(SpokenLine(text: Self.cameraCantTell, interrupt: true))
            return
        }
        describes += 1
        let id = sessionID, reference = referenceCrop
        log("describe_held", "")
        Task {
            let text = (try? await MuseAgent.describeHeld(noun: noun, jpeg: photo, reference: reference,
                                                         label: "describe_\(id)")) ?? ""
            guard id == sessionID, phase == .grabbing || phase == .guiding else { return }
            let line = text.isEmpty ? "I can't see it well. Hold it in front of the phone." : text
            log("describe_held_result", line)
            say(SpokenLine(text: line + " Double tap to check again.", interrupt: true))
        }
    }

    /// One SAM call on the hold-check photo (every check since v6). nil = the call failed.
    private func holdCandidates(_ noun: String, snapshot s: FrameSnapshot, expectedSession: Int, expectedCheck: Int) async -> [Candidate]? {
        guard expectedSession == sessionID, expectedCheck == holdCheckID, phase == .verifying else { return nil }
        guard holdSAMCalls < Self.maxHoldSAMCalls else {
            log("hold_sam_budget", "\(holdSAMCalls) used; cannot automatically confirm")
            return nil
        }
        holdSAMCalls += 1
        guard let response = try? await MetaAPI.segment(noun: noun, jpeg: s.jpeg,
                                                        imageLabel: "still_\(sessionID)_\(holdSAMCalls)") else { return nil }
        guard expectedSession == sessionID, expectedCheck == holdCheckID, phase == .verifying else { return nil }
        return Self.candidates(from: SAMParser.parse(response.text), snapshot: s, scale: bodyScale)
    }

    /// Bounding box of the Vision hand joints on the uploaded image, nil without joints.
    nonisolated static func handRegion(_ joints: [HandJoint: SIMD2<Float>], snapshot s: FrameSnapshot) -> CGRect? {
        let px = joints.values.map { DiagnosticRecorder.portraitPixel(vision: $0, snapshot: s) }
        guard px.count >= 3, let minX = px.map(\.x).min(), let maxX = px.map(\.x).max(),
              let minY = px.map(\.y).min(), let maxY = px.map(\.y).max() else { return nil }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // MARK: Command

    /// Every listen (branch muse-voice): Muse is biased to the room's things and the target, and the
    /// find log gets both transcripts (`stt`).
    private func listenOnce() async throws -> String {
        var words = Set((room.inventory?.items ?? []).map(\.name) + mapInventory.items.map(\.name))
        if let targetName { words.insert(targetName) }
        words.formUnion(["find", "scan the room", "stop", "is this it"])
        input.keywords = words.sorted()
        let heard = try await input.listenOnce()
        log("stt", input.lastReport)
        return heard
    }

    /// A/B for the device test: which transcript is used (Muse, or Apple on the device). Saved.
    var sttEngine: String { SpeechInput.engine.rawValue }
    func toggleSTTEngine() {
        SpeechInput.engine = SpeechInput.engine == .muse ? .apple : .muse
        log("stt_engine", SpeechInput.engine.rawValue)
        speaker.say(SpeechInput.engine == .muse ? "Listening with Muse." : "Listening on the phone.", interrupt: true)
    }

    private func listen() {
        speaker.stop()
        tones.stop()
        tones.earcon(.listening)
        phase = .listening
        let id = sessionID
        Task {
            try? await Task.sleep(for: .milliseconds(180))  // let the earcon end before the mic opens
            guard id == sessionID, phase == .listening else { return }
            let heard = (try? await listenOnce()) ?? ""
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
        rejected = []
        whichAsked = false
        samCalls = 0
        holdSAMCalls = 0
        scanCalls = 0
        scan = nil
        scanInFlight = false
        checkFromSession = false
        referenceCrop = nil
        lastCheckUnsure = false
        userClaimed = false
        burstsThisSearch = 0
        mapPlanner = nil
        guide = nil
        guidePhase = "-"
        // A limited-tracking moment before this search must not trigger a re-lock (2026-10-28 log:
        // an extra SAM call 2 s into the search with tracking normal).
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

    /// OBSOLETE since v9.2: Spark now checks every single lock (T11: a utensil holder locked as "mug" at
    /// SAM 0.84 was never checked and ended in "Got it. You have the mug."). Kept for the record.
    static let verifyBelow: Float = 0.75
    /// Spark said "not a <noun>" this many times in a search: stop instead of scanning again.
    static let maxRejected = 3

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
            let list = Self.candidates(from: records, snapshot: s, scale: bodyScale).map { c -> Candidate in
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
    nonisolated static func candidates(from records: [SAMRecord], snapshot s: FrameSnapshot,
                                       scale: BodyScale = BodyScale()) -> [Candidate] {
        let t = s.cameraTransform
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        // SAM returns every instance, unsorted.
        let sorted = records.filter { ($0.confidence ?? 1) >= 0.3 }.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        var out: [Candidate] = []
        for r in sorted where out.count < 4 {
            guard let c = candidate(r, chosen: out.isEmpty, snapshot: s, camera: camera, scale: scale),
                  !out.contains(where: { simd_distance($0.world, c.world) < 0.04 }) else { continue }
            out.append(c)
        }
        return out
    }

    nonisolated private static func candidate(_ r: SAMRecord, chosen: Bool, snapshot s: FrameSnapshot,
                                              camera: SIMD3<Float>, scale: BodyScale) -> Candidate? {
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
            ObstacleMap.build(mask: mask, depth: s.depth, intrinsics: s.intrinsics, cameraTransform: t, object: $0, scale: scale)
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
        } else {
            // Every lock is checked by Spark (v9.2, Nils after T11). Things it already rejected are skipped,
            // so the scan cannot lock the same wrong thing again and again.
            guard let first = list.first(where: { c in !rejected.contains { simd_distance($0.world, c.world) < 0.10 } }) else {
                log("verify", "only rejected candidates")
                startScan(noun)
                return
            }
            let ok = await verify(noun: noun, candidate: first)
            guard id == sessionID, phase == .locating else { return }
            log("verify", "c \(first.info.confidence) -> \(ok.map { $0 ? "yes" : "no" } ?? "error")")
            switch ok {
            case false?:
                rejected.append(first)
                if rejected.count >= Self.maxRejected {
                    // Spark can be wrong too (Muse review): not "it isn't here", but the likeliest one, said as unsure.
                    selectBestRejected(noun)
                } else {
                    startScan(noun)
                }
            default:
                // Yes, or Spark could not answer (network): SAM's lock stands; no answer must not block a search.
                select(first)
            }
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
            if !rejected.isEmpty {
                // Nothing else found: Spark's "no" may have been wrong; go to the likeliest one, said as unsure.
                selectBestRejected(noun)
                return
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

    /// Spark rejected every lock (or the scan found nothing else): guide to the most confident rejected one and
    /// say so; the user decides by touch.
    private func selectBestRejected(_ noun: String) {
        guard let best = rejected.max(by: { $0.info.confidence < $1.info.confidence }) else { return }
        log("verify", "fallback to rejected c \(best.info.confidence)")
        scan = nil
        phase = .locating
        select(best, intro: "I'm not sure this is the \(noun).")
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
                                      reachProfile: ReachProfile(maximumDistance: reachDistance ?? 0), scale: bodyScale)
        guide = session
        processor.scale = bodyScale
        guidePhase = session.phase.rawValue
        lookAround(session.obstacleClusters)
        if let intro { say(SpokenLine(text: intro, interrupt: true)) }
        for (i, line) in session.opening.enumerated() {
            say(SpokenLine(text: line.text, interrupt: line.interrupt && i == 0 && intro == nil))
        }
    }

    /// One Spark look at the photo around the target (v9.2): names the things in the map (numbered marks),
    /// says which are dangerous, finds dangerous things too low for the map (a knife lying flat), and which marks
    /// look like the target itself. Always made, even with nothing in the map (Nils: safety is a KPI; dangerous
    /// things must go through the LLM); tried twice. Guidance does not wait for it.
    private func lookAround(_ clusters: [ObstacleMap.Cluster]) {
        let marks = Array(clusters.prefix(6))
        let id = sessionID
        let noun = targetName ?? "object"
        Task {
            guard let s = await snapshot() else { return }
            let pixels: [CGPoint?] = marks.map { c in Self.photoPoint(SIMD3(c.centre.x, (c.centre.y + c.top) / 2, c.centre.z), s) }
            let box = guide?.object.flatMap { Self.photoBox($0.points, s) }
            guard let marked = Self.drawMarks(s.jpeg, at: pixels, labels: marks.indices.map { "\($0 + 1)" }, box: box) else { return }
            var look: MuseAgent.LookAround?
            for attempt in 0..<2 where look == nil {
                look = try? await MuseAgent.lookAround(jpeg: marked, count: marks.count, noun: noun, label: "look_\(id)_\(attempt)")
            }
            guard id == sessionID, guide != nil else { return }
            guard let look else {
                log("look_around", "failed")
                say(SpokenLine(text: "I couldn't check for danger. Go slowly.", interrupt: false))
                return
            }
            let named = marks.indices.compactMap { i -> (centre: SIMD3<Float>, name: String)? in
                guard pixels[i] != nil, let name = look.names[i + 1] else { return nil }
                return (marks[i].centre, name)
            }
            guide?.nameObstacles(named, dangerous: Set(look.dangerous.compactMap { look.names[$0] }))
            var hazards: [String] = []
            for h in look.hazards {
                guard let p = Self.worldPoint(photoX: h.x, photoY: h.y, s), let target,
                      simd_distance(SIMD2(p.x, p.z), SIMD2(target.x, target.z)) < 0.6 else { continue }
                guide?.addHazard(at: p, name: h.name)
                hazards.append(String(format: "%@ at %.2f,%.2f,%.2f", h.name, p.x, p.y, p.z))
            }
            log("look_around", marks.indices.map { i in
                String(format: "%d %@%@ %.0f cm tall", i + 1, look.names[i + 1] ?? "?", look.dangerous.contains(i + 1) ? " (danger)" : "",
                       (marks[i].top - (guide?.object?.supportHeight ?? marks[i].top)) * 100)
            }.joined(separator: "; ") + " | hazards: " + (hazards.isEmpty ? "none" : hazards.joined(separator: "; ")))
            // Another one like the target (two books): ask which one (Nils, v9.2), once per search.
            let same = marks.indices.filter { i in
                pixels[i] != nil && (look.sameKind.contains(i + 1) || look.names[i + 1].map { Self.sameKind($0, noun) } == true)
            }
            if !same.isEmpty, !whichAsked {
                whichAsked = true
                let options = same.enumerated().map { (label: $0.offset + 1, centre: marks[$0.element].centre) }
                if let photo = Self.drawMarks(s.jpeg, at: same.map { pixels[$0] }, labels: options.map { "\($0.label)" },
                                              box: box, boxLabel: "A") {
                    await chooseWhich(noun, options: options, photo: photo)
                }
            }
        }
    }

    /// "Books" / "book", "key" / "green key".
    nonisolated static func sameKind(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasSuffix("es"), t.count > 4 { t.removeLast(2) } else if t.hasSuffix("s"), t.count > 3 { t.removeLast() }
            return t
        }
        let x = norm(a), y = norm(b)
        return !x.isEmpty && !y.isEmpty && (x == y || x.hasSuffix(" " + y) || y.hasSuffix(" " + x))
    }

    /// Talk with the user to find out which of several like things they mean; the chosen one is guided to.
    /// Guidance is paused meanwhile. Silence keeps the one already locked.
    private func chooseWhich(_ noun: String, options: [(label: Int, centre: SIMD3<Float>)], photo: Data) async {
        let id = sessionID
        guide?.conversing = true
        defer { if id == sessionID { guide?.conversing = false } }
        var transcript: [String] = []
        for turn in 0..<4 {
            let r = try? await MuseAgent.whichOne(noun: noun, jpeg: photo, others: options.count, transcript: transcript,
                                                  label: "which_\(id)_\(turn)")
            guard id == sessionID, let r else { return }
            log("which_one", "\(r.say) -> \(r.choice ?? "?")")
            if let choice = r.choice {
                if !r.say.isEmpty { say(SpokenLine(text: r.say, interrupt: true)) }
                if choice == "A" {
                    for o in options { guide?.markOther(at: o.centre, name: noun) }
                } else if let n = Int(choice), let o = options.first(where: { $0.label == n }) {
                    await retarget(noun, near: o.centre)
                }
                return
            }
            guard !r.say.isEmpty else { return }
            say(SpokenLine(text: r.say, interrupt: true))
            try? await Task.sleep(for: .milliseconds(150))
            while speaker.isSpeaking {
                guard id == sessionID else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            tones.earcon(.listening)
            try? await Task.sleep(for: .milliseconds(180))
            let heard = (try? await listenOnce()) ?? ""
            audio.apply()
            guard id == sessionID else { return }
            log("which_heard", heard.isEmpty ? "(nothing)" : heard)
            if heard.isEmpty { return }
            if CommandParser.parse(heard) == .stop {
                finish(spoken: "Stopped. Tap to speak a command.", event: "stop")
                return
            }
            tones.earcon(.heard)
            transcript += ["App: \(r.say)", "User: \(heard)"]
        }
    }

    /// The user meant another one: lock it with SAM (nearest find to where it was seen) and guide there.
    private func retarget(_ noun: String, near centre: SIMD3<Float>) async {
        let id = sessionID
        let old = guide?.object?.centre ?? target
        guard case .success(let list) = await segment(noun), id == sessionID,
              let c = list.min(by: { simd_distance($0.world, centre) < simd_distance($1.world, centre) }),
              simd_distance(c.world, centre) < 0.12 else {
            log("which_one", "retarget failed")
            return
        }
        log("which_one", "retarget \(c.info.id)")
        select(c)
        if let old { guide?.markOther(at: old, name: noun) }
    }

    /// World point -> pixel on the snapshot photo (portrait), nil when off the photo.
    nonisolated static func photoPoint(_ w: SIMD3<Float>, _ s: FrameSnapshot) -> CGPoint? {
        let size = SIMD2(Float(s.imageSize.x), Float(s.imageSize.y))
        let cam = DepthProjector.camera(fromWorld: w, cameraTransform: s.cameraTransform)
        guard let raw = DepthProjector.project(cameraPoint: cam, intrinsics: s.intrinsics) else { return nil }
        let p = MaskTarget.portraitPixel(fromRawPixel: raw, rawSize: s.intrinsics.imageSize, imageSize: size)
        guard p.x >= 0, p.y >= 0, p.x < size.x, p.y < size.y else { return nil }
        return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }

    nonisolated static func photoBox(_ points: [SIMD3<Float>], _ s: FrameSnapshot) -> CGRect? {
        let px = points.compactMap { photoPoint($0, s) }
        guard let x0 = px.map(\.x).min(), let x1 = px.map(\.x).max(), let y0 = px.map(\.y).min(), let y1 = px.map(\.y).max() else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -6, dy: -6)
    }

    /// Photo position (0–1, portrait) -> world point from the snapshot's LiDAR (median of a 5x5 window).
    nonisolated static func worldPoint(photoX x: Float, photoY y: Float, _ s: FrameSnapshot) -> SIMD3<Float>? {
        let d = s.depth
        // Inverse of MaskTarget.portraitNormalized: raw = (portrait.y, 1 - portrait.x).
        let cx = Int(y * Float(d.width)), cy = Int((1 - x) * Float(d.height))
        var values: [Float] = []
        for j in (cy - 2)...(cy + 2) where j >= 0 && j < d.height {
            for i in (cx - 2)...(cx + 2) where i >= 0 && i < d.width {
                let v = d.depth[j * d.width + i]
                if v.isFinite, v > 0.1 { values.append(v) }
            }
        }
        guard values.count >= 5, let z = Stats.median(values) else { return nil }
        let k = s.intrinsics.scaled(to: SIMD2(Float(d.width), Float(d.height)))
        let cam = DepthProjector.unproject(pixel: SIMD2(Float(cx), Float(cy)), depth: z, intrinsics: k)
        return DepthProjector.world(fromCamera: cam, cameraTransform: s.cameraTransform)
    }

    nonisolated static func drawMarks(_ jpeg: Data, at points: [CGPoint?], labels: [String], box: CGRect? = nil,
                                      boxLabel: String? = nil) -> Data? {
        guard let image = UIImage(data: jpeg) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).jpegData(withCompressionQuality: 0.85) { ctx in
            image.draw(at: .zero)
            ctx.cgContext.setLineWidth(3)
            if let box {
                UIColor.green.setStroke()
                ctx.cgContext.stroke(box)
                if let boxLabel {
                    (boxLabel as NSString).draw(at: CGPoint(x: box.minX, y: box.minY - 26),
                                                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.green])
                }
            }
            for (i, p) in points.enumerated() {
                guard let p else { continue }
                UIColor.red.setStroke()
                ctx.cgContext.strokeEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
                (labels[i] as NSString).draw(at: CGPoint(x: p.x + 16, y: p.y - 22),
                                             withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.red])
            }
        }
    }

    /// The hand has been out of view a while (the session said "I need to see your hand to guide you."):
    /// listen, let Spark answer, up to 3 turns; ends when the hand is back or the user says nothing.
    private func startHandHelp() {
        guard !handHelpRunning else { return }
        handHelpRunning = true
        guide?.conversing = true
        let id = sessionID
        let noun = targetName ?? "object"
        Task {
            defer {
                if id == sessionID {
                    handHelpRunning = false
                    guide?.conversing = false
                }
            }
            var transcript: [String] = []
            for turn in 0..<3 {
                try? await Task.sleep(for: .milliseconds(150))
                while speaker.isSpeaking {
                    guard id == sessionID else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // The hand came back: guidance speaks again, no need to talk.
                guard id == sessionID, phase == .guiding, palm == nil else { return }
                tones.earcon(.listening)
                try? await Task.sleep(for: .milliseconds(180))
                let heard = (try? await listenOnce()) ?? ""
                audio.apply()
                guard id == sessionID else { return }
                log("hand_help_heard", heard.isEmpty ? "(nothing)" : heard)
                if heard.isEmpty { return }
                if CommandParser.parse(heard) == .stop {
                    finish(spoken: "Stopped. Tap to speak a command.", event: "stop")
                    return
                }
                tones.earcon(.heard)
                let answer = (try? await MuseAgent.handHelp(noun: noun, said: heard, transcript: transcript,
                                                            label: "hand_help_\(id)_\(turn)")) ?? ""
                guard id == sessionID else { return }
                log("hand_help_answer", answer)
                let spoken = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                if spoken.isEmpty { return }
                transcript += ["User: \(heard)", "App: \(spoken)"]
                speaker.say(spoken, interrupt: false)
            }
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
            // Every lock is checked, the agent's choice too (Muse review of v9.2: the agent path skipped it).
            let noun = targetName ?? c.info.name
            let ok = await verify(noun: noun, candidate: c)
            guard id == sessionID, phase == .locating else { return .ended }
            log("verify", "agent \(c.info.id) -> \(ok.map { $0 ? "yes" : "no" } ?? "error")")
            if ok == false {
                rejected.append(c)
                return .output(#"{"error":"A second look says this is not a "# + noun
                               + #". Choose another candidate, find_object again, or ask the user."}"#)
            }
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
            let answer = (try? await listenOnce()) ?? ""
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
            if elapsed > 10 {
                calibrating = false
                log("reach_measure", "failed")
                speaker.say("I can't see your finger. Press and hold to try again.", interrupt: true)
            } else if f.tracking == "normal",
                      let distance = calibration.update(time: f.time, fingertip: f.hand?.joints[.indexTip],
                          camera: SIMD3(f.cameraTransform.columns.3.x, f.cameraTransform.columns.3.y, f.cameraTransform.columns.3.z),
                          wrist: f.hand?.joints[.wrist]) {
                reachDistance = distance
                UserDefaults.standard.set(distance, forKey: Self.reachKey)
                // Hand length only when the wrist was seen; otherwise keep the earlier one (or the reference).
                if let hand = calibration.handLength {
                    handLength = hand
                    UserDefaults.standard.set(hand, forKey: Self.handKey)
                }
                calibrating = false
                log("reach_measure", String(format: "reach %.2f m hand %@", distance,
                                            calibration.handLength.map { String(format: "%.3f m", $0) } ?? "not seen"))
                Haptics.success()
                speaker.say("Reach \(Int((distance * 100).rounded())) centimetres. Tap and say what to find.", interrupt: true)
            }
            return
        }
        if let capture = f.capture {
            record(kind: capture.kind, snapshot: capture.snapshot, samText: nil, candidates: [],
                   hand: RecordedHand(vision: f.handVision, world: f.hand?.joints ?? [:], depths: f.handDepths),
                   extra: ["hand_to_target_cm": handDistance.map { $0 * 100 } ?? -1,
                           "target_world": target.map { [$0.x, $0.y, $0.z] } ?? []])
            if phase == .verifying, capture.kind == "hold_check:\(sessionID):\(holdCheckID)" {
                runHoldCheck(capture.snapshot, hand: f.hand, spot: f.spot)
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
        guard phase == .guiding || phase == .grabbing, var session = guide else {
            handDistance = nil
            return
        }
        if let scan = f.rollingScan {
            let before = session.obstaclePointCount
            session.addScan(scan, hand: f.hand, cameraTransform: f.cameraTransform)
            // Things, not just points (Muse review): a cluttered desk seen from a new angle adds points by design.
            if session.obstaclePointCount != before {
                log("rolling_scan", "points \(before) -> \(session.obstaclePointCount), things \(session.obstacleClusters.count)")
            }
        }
        let out = session.update(time: f.time, hand: f.hand, cameraTransform: f.cameraTransform,
                                 targetDepthDelta: f.targetDepthDelta, speaking: speaker.isSpeaking,
                                 trackingNormal: f.tracking == "normal", liveObstacles: f.obstacles)
        guide = session
        if session.endReason != nil {
            // The session said why (path blocked too long); end the search, next tap listens again.
            out.lines.forEach(say)
            finish(spoken: nil, event: "ended")
            return
        }
        guidePhase = out.phase.rawValue
        handDistance = out.handDistance
        tones.update(distance: out.toneDistance)
        for line in out.lines {
            say(line)
            // Snapshot the hand at the moments that tell us most about the hand-point bias.
            if line.text == "I see your hand." { processor.requestCapture("hand_seen") }
            if line.text.hasPrefix("Stop. The ") { processor.requestCapture("grab") }
        }
        if out.askAboutHand { startHandHelp() }
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
        say(SpokenLine(text: "Scanning the room. Turn slowly in a full circle. Tap when done.", interrupt: true))
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
                    self.say(SpokenLine(text: "I couldn't save the room. Turn around once more, then tap.",
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
    /// Rolling scan (v9.2): the current frame's map (`ObstacleMap.scene`), about once a second while an
    /// object is locked; the session adds cells seen twice in a row.
    var rollingScan: ObstacleMap?
    /// Layer 2 (record only): LiDAR at the target's locked surface points, on hold-check frames.
    var spot: SpotEvidence?
}

/// Runs the six-point hand pipeline on every second frame (≤ 30 Hz) off the main thread; drops frames
/// while busy (FrameGate) so ARKit never waits on us.
nonisolated final class FindFrameProcessor: NSObject, ARSessionDelegate, @unchecked Sendable {
    private let gate = FrameGate(label: "sightline.find.frames")
    var queue: DispatchQueue { gate.delegateQueue }
    var onFrame: (@Sendable (FindFrame) -> Void)?
    private let locator = HandKeypointLocator()
    /// Last 2 s at 10 Hz for burst recordings around hold checks.
    let bursts = BurstRing()
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
    private var _scale = BodyScale()
    var scale: BodyScale {
        get { lock.withLock { _scale } }
        set { lock.withLock { _scale = newValue } }
    }
    private var lastRolling: Double = 0

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
            if bursts.wants(frame.timestamp),
               let b = BurstRing.frame(from: frame, tracking: tracking, joints: r.keypoints?.joints ?? [:]) {
                bursts.add(b)
            }
            let spot = capture?.kind.hasPrefix("hold_check") == true ? object.flatMap { spotEvidence(frame: frame, object: $0) } : nil
            var rolling: ObstacleMap?
            if let object, frame.timestamp - lastRolling >= 1 {
                lastRolling = frame.timestamp
                rolling = rollingScan(frame: frame, object: object)
            }
            onFrame?(FindFrame(time: frame.timestamp, tracking: tracking, cameraTransform: frame.camera.transform,
                               hand: r.keypoints, handVision: r.vision, handDepths: r.depths, handFail: r.failReason,
                               capture: capture,
                               targetDepthDelta: target.flatMap { depthDelta(at: $0, frame: frame) },
                               // v9.1: no live per-frame map (it held the user's own arm and flying pixels and
                               // stopped every search); the session uses the lock-frame map. See ObstacleMap.
                               obstacles: nil,
                               rollingScan: rolling,
                               spot: spot))
        }
    }

    /// Layer 2 (record only): LiDAR now along the rays to up to 200 of the target's locked surface points.
    private func spotEvidence(frame: ARFrame, object: ObjectModel) -> SpotEvidence? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data), !object.points.isEmpty else { return nil }
        let res = frame.camera.imageResolution
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: SIMD2(Float(res.width), Float(res.height)))
            .scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        let step = max(1, object.points.count / 200)
        let samples = stride(from: 0, to: object.points.count, by: step).map { i -> SpotEvidence.Sample in
            let p = object.points[i]
            let c = DepthProjector.camera(fromWorld: p, cameraTransform: frame.camera.transform)
            var measured: Float?
            var confidence: UInt8 = 0
            if let px = DepthProjector.project(cameraPoint: c, intrinsics: k) {
                let x = Int(px.x.rounded()), y = Int(px.y.rounded())
                if x >= 0, y >= 0, x < depth.width, y < depth.height {
                    measured = depth.depth[y * depth.width + x]
                    confidence = depth.confidence?[y * depth.width + x] ?? 2
                }
            }
            return SpotEvidence.Sample(expected: -c.z, measured: measured, confidence: confidence,
                                       thickness: object.supportHeight.map { p.y - $0 })
        }
        return SpotEvidence.classify(samples)
    }

    /// Rolling scan (v9.2, Nils: "live scan? rolling scanning"): every 4th depth pixel with high confidence,
    /// through the same `ObstacleMap.scene` filters as the lock map (support, near the target, away from the
    /// body and the object). The arm and hand are removed in `GuidanceSession.addScan`, and one scan alone
    /// never adds anything (the v9 live map held the user's own arm).
    private func rollingScan(frame: ARFrame, object: ObjectModel) -> ObstacleMap? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else { return nil }
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics,
            imageSize: SIMD2(Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height)))
            .scaled(to: SIMD2(Float(depth.width), Float(depth.height)))
        let t = frame.camera.transform
        var world: [SIMD3<Float>] = []
        for y in stride(from: 0, to: depth.height, by: 4) {
            for x in stride(from: 0, to: depth.width, by: 4) {
                let i = y * depth.width + x, d = depth.depth[i]
                guard d.isFinite, d > 0.1, d < 2, (depth.confidence?[i] ?? 0) >= 2 else { continue }
                world.append(DepthProjector.world(fromCamera: DepthProjector.unproject(pixel: SIMD2(Float(x), Float(y)), depth: d, intrinsics: k),
                                                  cameraTransform: t))
            }
        }
        return ObstacleMap.scene(world, object: object, camera: SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), scale: scale)
    }

    /// Current-frame conservative point cloud. Hand/target returns are excluded; occluded or
    /// transparent obstacles remain unknown, so this cannot certify a collision-free route.
    /// OBSOLETE since v9.1 (unused): the per-frame map stopped every device search with nothing in the way.
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
