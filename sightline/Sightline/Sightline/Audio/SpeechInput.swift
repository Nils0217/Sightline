// labels: production, needs-review
// One spoken command, recognised on the device (no audio leaves the phone). Stops on a final
// result, after 1.2 s without new words, or after 6 s.

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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        defer { finish() }

        lastError = nil
        var boxRef: TranscriptBox?
        let heard = await withCheckedContinuation { continuation in
            let box = TranscriptBox(continuation)
            boxRef = box
            transcript = box
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    box.update(result.bestTranscription.formattedString, final: result.isFinal)
                } else if let error {
                    box.fail(error.localizedDescription)
                }
            }
            Task {
                // Silence / overall timeout watchdog.
                let start = Date()
                while !box.done {
                    try? await Task.sleep(for: .milliseconds(200))
                    // v5 test: "the green key" was never transcribed within 6 s; allow a slower start.
                    if Date().timeIntervalSince(start) > 8 || box.silentFor > 1.5 { box.finish() }
                }
            }
        }
        lastError = boxRef?.error
        return heard
    }

    /// Why the last listen returned nothing, if the recogniser said (for the find log).
    private(set) var lastError: String?

    func cancel() {
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
