// labels: production, needs-review
// Spoken output. Short phrases only; `interrupt` cuts the current phrase (used for "Now grab").

import AVFoundation

final class Speaker {
    private let synth = AVSpeechSynthesizer()

    var isSpeaking: Bool { synth.isSpeaking }

    func say(_ text: String, interrupt: Bool = false) {
        if interrupt { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Slightly slower than default: the first device test found 1.1x too fast.
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }
}
