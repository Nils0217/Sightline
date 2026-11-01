// labels: production, needs-review
// One spoken command, recognised on the device (no audio leaves the phone). Stops on a final
// result, after 1.2 s without new words, or after 6 s.
// Branch muse-voice (2026-11-01): with `engine == .muse` the same microphone tap also streams to Muse Voice
// Transcribe (MuseStream), which decides when the user has finished and what they said; the on-device
// result runs alongside as the fallback (no network, handshake failure) and both are kept for the log.

import AVFoundation
import Speech

final class SpeechInput {
    enum Failure: Error { case notAuthorized, unavailable }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript: TranscriptBox?
    private var tapInstalled = false

    enum Engine: String { case muse, apple }
    /// Which result is used. Saved, so the A/B choice survives launches (button on the find screen).
    static var engine: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: "stt_engine") ?? "") ?? .muse }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "stt_engine") }
    }
    /// Words to bias Muse toward (room inventory names, the current target). Set before listening.
    var keywords: [String] = []
    /// For the find log: both transcripts, which one was used, and Muse's timing.
    private(set) var lastReport = ""
    private var muse: MuseStream?

    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    /// Returns the best transcript ("" if nothing was heard).
    func listenOnce() async throws -> String {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.notAuthorized }
        guard let recognizer, recognizer.isAvailable else { throw Failure.unavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = ["find", "Sightline", "where is my"]
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let stream: MuseStream? = Self.engine == .muse ? APIKey.value.map { key in
            let m = MuseStream()
            m.start(key: key, keywords: keywords)
            return m
        } : nil
        muse = stream
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            stream?.feed(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        defer { finish() }
        let listenStart = Date()

        lastError = nil
        var boxRef: TranscriptBox?
        let heard = await withCheckedContinuation { continuation in
            let box = TranscriptBox(continuation)
            boxRef = box
            transcript = box
            task = recognizer.recognitionTask(with: request) { result, error in
                // While Muse is streaming it decides when to stop; the on-device result is only kept.
                let museLeads = stream?.isHealthy ?? false
                if let result {
                    box.update(result.bestTranscription.formattedString, final: result.isFinal && !museLeads)
                } else if let error {
                    if museLeads { box.note(error.localizedDescription) } else { box.fail(error.localizedDescription) }
                }
            }
            Task {
                // Silence / overall timeout watchdog.
                let start = Date()
                while !box.done {
                    try? await Task.sleep(for: .milliseconds(200))
                    // v5 test: "the green key" was never transcribed within 6 s; allow a slower start.
                    let elapsed = Date().timeIntervalSince(start)
                    if let stream, stream.isHealthy {
                        // Muse decides (it waits through a mid-sentence pause; docs/STT_EXPERIMENT.md).
                        if stream.finished() || elapsed > 15 || (elapsed > 8 && stream.lastChange == nil) { box.finish() }
                    } else if elapsed > 8 || box.silentFor > 1.5 {
                        box.finish()
                    }
                }
            }
        }
        lastError = boxRef?.error
        guard let stream else {
            lastReport = "engine apple"
            return heard
        }
        let museText = stream.text
        let useMuse = stream.isHealthy && !museText.isEmpty
        let state: String
        switch stream.state {
        case .failed(let why): state = "failed " + why
        default: state = "ok"
        }
        lastReport = "engine \(useMuse ? "muse" : "apple_fallback") muse \"\(museText)\" apple \"\(heard)\" "
            + "muse_state \(state) connect_ms \(stream.connectMS.map { String(Int($0)) } ?? "-") "
            + "listen_s \(String(format: "%.2f", Date().timeIntervalSince(listenStart)))"
        stream.close(label: "listen")
        muse = nil
        return useMuse ? Self.clean(museText) : heard
    }

    /// Muse punctuates ("Where's my mug?") and may write a number in Chinese with an accent (experiment:
    /// "五十五"); the command parser expects plain words.
    static func clean(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".?!".contains(last) { t.removeLast() }
        return t
    }

    /// Why the last listen returned nothing, if the recogniser said (for the find log).
    private(set) var lastError: String?

    func cancel() {
        muse?.close(label: "listen_cancelled")
        muse = nil
        transcript?.finish()
        transcript = nil
        finish()
    }

    private func finish() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}

/// Resumes the continuation exactly once.
private nonisolated final class TranscriptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var text = ""
    private var lastChange: Date?

    init(_ c: CheckedContinuation<String, Never>) { continuation = c }

    var done: Bool { lock.withLock { continuation == nil } }
    /// Seconds since the last new word; 0 until something was heard.
    var silentFor: Double { lock.withLock { lastChange.map { Date().timeIntervalSince($0) } ?? 0 } }

    func update(_ newText: String, final: Bool) {
        lock.withLock {
            if newText != text { text = newText; lastChange = Date() }
        }
        if final { finish() }
    }

    private(set) var error: String? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }
    private var _error: String?

    /// An on-device error while Muse leads: remembered for the log, the listen goes on.
    func note(_ message: String) { error = message }

    func fail(_ message: String) {
        error = message
        finish()
    }

    func finish() {
        let (c, t) = lock.withLock { () -> (CheckedContinuation<String, Never>?, String) in
            defer { continuation = nil }
            return (continuation, text)
        }
        c?.resume(returning: t)
    }
}
