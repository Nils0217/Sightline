// labels: production, needs-review
// One place that owns the shared AVAudioSession (2026-10-29: speech dropped out after the
// microphone was used and around phone calls / route changes). Sets playAndRecord with the
// loudspeaker, re-applies it after every listen, reactivates after an interruption, and moves
// output back to the loudspeaker if a route change sent it to the earpiece. Every event is logged.

import AVFoundation

final class AudioSessionKeeper {
    /// (event, detail) for the find log: audio_interruption, audio_route, audio_reset.
    var onEvent: ((String, String) -> Void)?
    /// Called after the media server reset: the synthesizer and engines must be rebuilt.
    var onReset: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEvent?("audio_interruption", type == .began ? "began" : "ended")
                if type == .ended { self.apply() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEvent?("audio_route", "\(reason.map { "\($0.rawValue)" } ?? "?") -> \(outputs)")
                if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) { self.apply() }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEvent?("audio_reset", "media services reset")
                self.apply()
                self.onReset?()
            }
        })
        apply()
    }

    /// (Re)apply category, activate, and force the loudspeaker. Off the main thread: setActive can block.
    func apply() {
        Task.detached { Self.configure() }
    }

    /// After a listen (T22, Nils: "the voice is easily cut by the beep"): every listen was followed by a route change
    /// to the earpiece for about 0.7 s (reason 3, category change: re-setting the category drops the loudspeaker
    /// override), while the next line had already started, so it began on the loudspeaker and went on in the
    /// earpiece. Configures, then waits until the output is the loudspeaker (at least 0.2 s for a late route change,
    /// at most 1 s) before anything is said. Returns the wait in ms (logged).
    func settle() async -> Int {
        let start = Date()
        await Task.detached { Self.configure() }.value
        try? await Task.sleep(for: .milliseconds(200))
        while Self.onEarpiece, Date().timeIntervalSince(start) < 1 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    nonisolated static var onEarpiece: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }

    /// The category is set only when it differs (setting it again moved the output to the earpiece, T22).
    nonisolated static func configure() {
        let audio = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP]
        if audio.category != .playAndRecord || audio.mode != .default || !audio.categoryOptions.isSuperset(of: options) {
            try? audio.setCategory(.playAndRecord, mode: .default, options: options)
        }
        try? audio.setActive(true)
        if onEarpiece { try? audio.overrideOutputAudioPort(.speaker) }
    }
}
