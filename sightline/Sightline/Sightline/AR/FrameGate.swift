// labels: production, needs-review, important
// Keeps ARSession delegates from holding ARFrames. The delegate callback returns at once; a frame
// is processed on `workQueue` only when the previous one is finished, otherwise it is dropped.
// Without this, slow per-frame work (Vision + depth) queued up frames until ARKit warned
// "delegate is retaining 11 ARFrames" and could stop delivering camera images (2026-10-28).

import ARKit

nonisolated final class FrameGate: @unchecked Sendable {
    /// ARSession delegate queue: only does the busy check.
    let delegateQueue: DispatchQueue
    /// Serial queue where the real work runs.
    let workQueue: DispatchQueue
    private let lock = NSLock()
    private var busy = false
    private(set) var dropped = 0

    init(label: String) {
        delegateQueue = DispatchQueue(label: "\(label).delegate", qos: .userInteractive)
        workQueue = DispatchQueue(label: "\(label).work", qos: .userInteractive)
    }

    /// Runs `work` with the frame on `workQueue` unless the previous frame is still being processed.
    func submit(_ frame: ARFrame, _ work: @escaping @Sendable (ARFrame) -> Void) {
        let accepted = lock.withLock { () -> Bool in
            if busy { dropped += 1; return false }
            busy = true
            return true
        }
        guard accepted else { return }
        let box = FrameBox(frame)
        workQueue.async { [self] in
            work(box.frame)
            lock.withLock { busy = false }
        }
    }
}

/// ARFrame is not Sendable; it is only read on the work queue while the gate is busy.
private nonisolated final class FrameBox: @unchecked Sendable {
    let frame: ARFrame
    init(_ frame: ARFrame) { self.frame = frame }
}
