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
        Task.detached {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playAndRecord, mode: .default,
                                   options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            try? audio.setActive(true)
            if audio.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
                try? audio.overrideOutputAudioPort(.speaker)
            }
        }
    }
}
