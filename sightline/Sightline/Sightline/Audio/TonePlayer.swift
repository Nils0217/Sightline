// labels: production, needs-review
// Parking-sensor beeps: interval and pitch from SightlineCore.ProximityTone. Generated on the
// audio thread; the main thread only writes the target distance. `click()` = one short low tick
// ("I'm looking at this view") while scanning for an object that is not in view. `earcon` = short
// fixed cues for the blind user (listening, found, not found, reset).
// 2026-10-29: the engine is no longer paused on `stop()` (pause/start next to the speech
// synthesizer was one suspect for speech dropping out); it keeps running silent, and restarts
// after an audio configuration change.

import AVFoundation
import SightlineCore

final class TonePlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let state = ToneState()
    private var configObserver: NSObjectProtocol?

    enum Earcon {
        /// Microphone is on: rising two notes.
        case listening
        /// Found / got it: bright rising third.
        case success
        /// Not found / not that object: falling two notes.
        case failure
        /// Long-press reset: two low notes.
        case reset

        var notes: [(hz: Double, seconds: Double)] {
            switch self {
            case .listening: [(660, 0.07), (990, 0.09)]
            case .success: [(784, 0.08), (988, 0.08), (1175, 0.12)]
            case .failure: [(440, 0.1), (330, 0.14)]
            case .reset: [(330, 0.08), (0, 0.05), (330, 0.08)]
            }
        }
    }

    func earcon(_ e: Earcon) {
        state.play(e.notes)
        if !engine.isRunning { start() }
    }

    /// nil = silent.
    func update(distance: Float?) {
        state.set(distance: distance)
        if distance != nil, !engine.isRunning { start() }
    }

    /// One 30 ms 300 Hz tick.
    func click() {
        state.play([(300, 0.03)])
        if !engine.isRunning { start() }
    }

    /// Silence (the engine keeps running).
    func stop() {
        state.set(distance: nil)
    }

    private func start() {
        if source == nil {
            let format = engine.outputNode.inputFormat(forBus: 0)
            let sampleRate = format.sampleRate
            let state = self.state
            let node = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
                state.render(frameCount: Int(frameCount), sampleRate: sampleRate,
                             buffers: UnsafeMutableAudioBufferListPointer(bufferList))
                return noErr
            }
            let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: mono)
            source = node
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { try? self?.engine.start() }
            }
        }
        try? engine.start()
    }
}

/// Shared between the main thread (writes) and the render thread (reads).
private nonisolated final class ToneState: @unchecked Sendable {
    private let lock = NSLock()
    private var distance: Float?
    private var phase: Double = 0
    private var sinceBeep: Double = 1
    /// Fixed notes to play (clicks, earcons), each (Hz, seconds left); 0 Hz = pause.
    private var notes: [(hz: Double, seconds: Double)] = []
    private var generation = 0

    static let beepLength = 0.05

    func set(distance: Float?) { lock.withLock { self.distance = distance } }
    func play(_ n: [(hz: Double, seconds: Double)]) { lock.withLock { notes = n; generation += 1 } }

    func render(frameCount: Int, sampleRate: Double, buffers: UnsafeMutableAudioBufferListPointer) {
        // Notes span several buffers: copy them, render, and keep what is left.
        let (d, queued, gen) = lock.withLock { (distance, notes, generation) }
        var pending = queued
        let interval = d.flatMap { ProximityTone.interval(distance: $0) }
        let freq = d.map { ProximityTone.frequency(distance: $0) } ?? 0
        let dt = 1 / sampleRate
        for i in 0..<frameCount {
            var sample: Float = 0
            if let interval {
                sinceBeep += dt
                if sinceBeep >= interval { sinceBeep = 0 }
                if sinceBeep < Self.beepLength {
                    phase += 2 * .pi * freq * dt
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    sample = Float(sin(phase)) * 0.12
                }
            }
            if !pending.isEmpty {
                let hz = pending[0].hz
                pending[0].seconds -= dt
                if pending[0].seconds <= 0 { pending.removeFirst() }
                if hz > 0 {
                    phase += 2 * .pi * hz * dt
                    if phase > 2 * .pi { phase -= 2 * .pi }
                    sample = Float(sin(phase)) * 0.15
                } else {
                    sample = 0
                }
            }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[i] = sample
            }
        }
        // A new earcon queued meanwhile wins over what was left of the old one.
        lock.withLock { if generation == gen { notes = pending } }
    }
}
