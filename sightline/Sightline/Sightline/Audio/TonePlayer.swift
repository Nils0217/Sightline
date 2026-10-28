// labels: production, needs-review
// Parking-sensor beeps: interval and pitch from SightlineCore.ProximityTone. Generated on the
// audio thread; the main thread only writes the target distance.

import AVFoundation
import SightlineCore

final class TonePlayer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let state = ToneState()

    /// nil = silent.
    func update(distance: Float?) {
        state.set(distance: distance)
        if distance != nil, !engine.isRunning { start() }
    }

    func stop() {
        state.set(distance: nil)
        engine.pause()
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

    static let beepLength = 0.05

    func set(distance: Float?) { lock.withLock { self.distance = distance } }

    func render(frameCount: Int, sampleRate: Double, buffers: UnsafeMutableAudioBufferListPointer) {
        let d = lock.withLock { distance }
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
                    sample = Float(sin(phase)) * 0.3
                }
            }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[i] = sample
            }
        }
    }
}
