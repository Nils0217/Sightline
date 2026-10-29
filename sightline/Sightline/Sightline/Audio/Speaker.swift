// labels: production, needs-review
// Spoken output. Short phrases only; `interrupt` cuts the current phrase (used for "Now grab").
// 2026-10-29 (speech dropped out for up to 17 s in the 9d77d1e device test): we track what is
// queued ourselves through the delegate instead of trusting `synth.isSpeaking`, interrupt only
// when something is actually playing, and a watchdog rebuilds the synthesizer when an utterance
// never starts or never finishes. Every start / finish / cancel / stuck goes to the find log.

import AVFoundation

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private var synth = AVSpeechSynthesizer()
    /// Utterances handed to the synthesizer and not yet finished or cancelled, oldest first.
    private var queue: [(utterance: AVSpeechUtterance, queuedAt: Date, startedAt: Date?)] = []
    private var watchdog: Timer?
    /// (event, detail) for the find log: speech_start, speech_finish, speech_cancel, speech_stuck.
    var onEvent: ((String, String) -> Void)?

    /// Never started this long after being queued (and nothing ahead of it) = stuck.
    static let startTimeout: TimeInterval = 3
    /// Spoken longer than words x 0.6 s + this = stuck.
    static let finishSlack: TimeInterval = 4

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { !queue.isEmpty }

    func say(_ text: String, interrupt: Bool = false) {
        if interrupt && !queue.isEmpty { cancelAll() }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Slightly slower than default: the first device test found 1.1x too fast.
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        queue.append((u, Date(), nil))
        synth.speak(u)
        startWatchdog()
    }

    func stop() { if !queue.isEmpty { cancelAll() } }

    private func cancelAll() {
        // Queued utterances behind the current one get no callback: forget them all here.
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
    }

    /// Audio session reset or a stuck synthesizer: start over with a fresh one, re-saying the newest line.
    func rebuild(reason: String) {
        let last = queue.last?.utterance.speechString
        onEvent?("speech_stuck", reason + (last.map { ": " + $0 } ?? ""))
        synth.delegate = nil
        synth.stopSpeaking(at: .immediate)
        queue.removeAll()
        synth = AVSpeechSynthesizer()
        synth.delegate = self
        if let last { say(last) }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let head = queue.first else {
            watchdog?.invalidate()
            watchdog = nil
            return
        }
        let now = Date()
        if let started = head.startedAt {
            let words = Double(head.utterance.speechString.split(separator: " ").count)
            if now.timeIntervalSince(started) > words * 0.6 + Self.finishSlack { rebuild(reason: "never finished") }
        } else if now.timeIntervalSince(head.queuedAt) > Self.startTimeout {
            rebuild(reason: "never started")
        }
    }

    // MARK: AVSpeechSynthesizerDelegate (any thread -> main actor)

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u), text = u.speechString
        Task { @MainActor in
            guard let i = self.queue.firstIndex(where: { ObjectIdentifier($0.utterance) == id }) else { return }
            self.queue[i].startedAt = Date()
            // Anything queued before it is done even if its callback was lost.
            self.queue.removeFirst(i)
            self.onEvent?("speech_start", text)
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u), text = u.speechString
        Task { @MainActor in self.done(id, event: "speech_finish", text: text) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u), text = u.speechString
        Task { @MainActor in self.done(id, event: "speech_cancel", text: text) }
    }

    private func done(_ id: ObjectIdentifier, event: String, text: String) {
        queue.removeAll { ObjectIdentifier($0.utterance) == id }
        onEvent?(event, text)
    }
}
