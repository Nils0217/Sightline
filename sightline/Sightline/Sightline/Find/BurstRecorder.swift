// labels: testing, needs-review, important
// Short burst recording around each hold check (v9.1, 2026-10-31), to set the pick-up thresholds from
// real data instead of guesses. The frame processor keeps the last 2 s in memory at 10 Hz; a check
// saves those plus the next 2 s: depth (half resolution, Float16), confidence, camera pose and
// intrinsics, hand joints and a small photo per frame.
//
// Files: Documents/diagnostics/<launch>/NN_burst_<label>/ with frames.json, depth_XX.f16, conf_XX.u8,
// photo_XX.jpg. About 40 frames x ~45 KB = ~2 MB per burst. At most `maxPerSearch` bursts per search
// and `maxPerLaunch` per launch, so a long session cannot fill the phone. Exported with the
// diagnostics folder; contains home photos, never commit it.

import ARKit
import CoreImage
import Foundation
import SightlineCore

nonisolated struct BurstFrame: Sendable {
    var time: Double
    var tracking: String
    var cameraTransform: simd_float4x4
    /// For the stored depth size (half of the 256x192 LiDAR map).
    var intrinsics: CameraIntrinsics
    var width: Int
    var height: Int
    var depth: [Float16]
    var confidence: [UInt8]
    var joints: [HandJoint: SIMD3<Float>]
    var jpeg: Data?
}

/// Thread-safe ring of recent frames plus at most one burst being collected.
nonisolated final class BurstRing: @unchecked Sendable {
    static let rate: Double = 10
    static let before: Double = 2
    static let after: Double = 2

    private let lock = NSLock()
    private var ring: [BurstFrame] = []
    private var pending: (label: String, frames: [BurstFrame], until: Double)?
    private var lastAdded: Double = -.infinity
    /// Called once per finished burst, on the frame queue.
    var onBurst: (@Sendable (String, [BurstFrame]) -> Void)?

    /// Whether a frame at `time` should be sampled (10 Hz).
    func wants(_ time: Double) -> Bool { lock.withLock { time - lastAdded >= 1 / Self.rate - 0.005 } }

    func add(_ frame: BurstFrame) {
        let done: (String, [BurstFrame])? = lock.withLock {
            lastAdded = frame.time
            ring.append(frame)
            ring.removeAll { frame.time - $0.time > Self.before }
            guard var p = pending else { return nil }
            p.frames.append(frame)
            if frame.time >= p.until {
                pending = nil
                return (p.label, p.frames)
            }
            pending = p
            return nil
        }
        if let done { onBurst?(done.0, done.1) }
    }

    /// Keeps the last `before` seconds and collects `after` more. Ignored while another burst runs.
    func start(_ label: String) -> Bool {
        lock.withLock {
            guard pending == nil else { return false }
            let now = ring.last?.time ?? 0
            pending = (label, ring, now + Self.after)
            return true
        }
    }

    func cancel() { lock.withLock { pending = nil } }

    /// One frame for the ring: half-resolution depth and confidence, joints, a 192 px photo.
    static func frame(from frame: ARFrame, tracking: String, joints: [HandJoint: SIMD3<Float>]) -> BurstFrame? {
        guard let data = frame.sceneDepth, let depth = DepthImageReader.read(data) else { return nil }
        let w = depth.width / 2, h = depth.height / 2
        var d = [Float16](repeating: 0, count: w * h)
        var c = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * 2) * depth.width + x * 2
                d[y * w + x] = Float16(depth.depth[i])
                c[y * w + x] = depth.confidence?[i] ?? 2
            }
        }
        let res = frame.camera.imageResolution
        let k = CameraIntrinsics(matrix: frame.camera.intrinsics, imageSize: SIMD2(Float(res.width), Float(res.height)))
            .scaled(to: SIMD2(Float(w), Float(h)))
        return BurstFrame(time: frame.timestamp, tracking: tracking, cameraTransform: frame.camera.transform,
                          intrinsics: k, width: w, height: h, depth: d, confidence: c, joints: joints,
                          jpeg: FrameSnapshot.smallJPEG(frame, longEdge: 192))
    }

    /// Writes one burst folder; `meta` goes into frames.json next to the per-frame records.
    static func write(_ frames: [BurstFrame], to folder: URL, meta: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        for (i, f) in frames.enumerated() {
            let name = String(format: "%02d", i)
            f.depth.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: folder.appendingPathComponent("depth_\(name).f16")) }
            try? Data(f.confidence).write(to: folder.appendingPathComponent("conf_\(name).u8"))
            if let jpeg = f.jpeg { try? jpeg.write(to: folder.appendingPathComponent("photo_\(name).jpg")) }
            let t = f.cameraTransform
            records.append([
                "index": i, "time": f.time, "tracking": f.tracking, "depth_size": [f.width, f.height],
                "intrinsics": ["fx": f.intrinsics.fx, "fy": f.intrinsics.fy, "cx": f.intrinsics.cx, "cy": f.intrinsics.cy],
                "camera_transform": [t.columns.0, t.columns.1, t.columns.2, t.columns.3].map { [$0.x, $0.y, $0.z, $0.w] },
                "joints": Dictionary(uniqueKeysWithValues: f.joints.map { ($0.key.rawValue, [$0.value.x, $0.value.y, $0.value.z]) }),
            ])
        }
        var all = meta
        all["frames"] = records
        all["format"] = "depth_XX.f16: Float16 metres, row-major, depth_size; conf_XX.u8: 0 low 1 medium 2 high"
        if let json = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: folder.appendingPathComponent("frames.json"))
        }
    }
}
