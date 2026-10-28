// labels: testing, needs-review, important
// Recording mode for diagnosing the device "dots are biased left" problem offline (Nils, 2026-10-28).
// On every SAM call and on hand events it writes what the pipeline saw and computed:
//
//   Documents/diagnostics/<launch time>/
//     NN_<kind>_photo.jpg    the exact 512 px image (what SAM saw)
//     NN_<kind>_overlay.jpg  photo + SAM masks/boxes + target reprojected (red cross) + hand joints
//                            (Vision 2D = blue dots, our 3D reprojected = orange rings)
//     NN_<kind>_screen.jpg   the AR view as shown on screen, with the green/red dots
//     NN_<kind>_meta.json    intrinsics, camera pose, candidates, hand points, reprojection check
//     NN_<kind>_sam.txt      raw SAM output (SAM events only)
//     NN_<kind>_depth.f32 / _conf.u8   LiDAR depth (Float32, 256x192 landscape) and confidence
//
// One folder per app launch; files accumulate within a launch and are never overwritten or deleted.
// Get them with the Files app (On My iPhone > Sightline > diagnostics) or the Export button.
// About 0.3 MB per event.

import Foundation
import SightlineCore
import simd
import UIKit

nonisolated struct RecordedCandidate: Sendable {
    var id: String
    var confidence: Float
    var world: SIMD3<Float>
    var cameraPoint: SIMD3<Float>
    var samples: Int
    var depthSpread: Float
    var box: CGRect
    var mask: SourceMask
    var reprojected: SIMD2<Float>?
    var reprojectsInsideMask: Bool?
    var chosen = false
}

nonisolated struct RecordedHand: Sendable {
    var vision: [HandJoint: SIMD2<Float>]
    var world: [HandJoint: SIMD3<Float>]
    var depths: [HandJoint: Float]
}

@MainActor
final class DiagnosticRecorder {
    let folder: URL
    private var count = 0
    private let queue = DispatchQueue(label: "sightline.diagnostics", qos: .utility)

    init() {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics").appendingPathComponent(f.string(from: Date()))
    }

    /// Writes one event. `screen` is the ARView snapshot (may be nil). Returns the file prefix.
    @discardableResult
    func record(kind: String, snapshot s: FrameSnapshot, noun: String?, samText: String?,
                candidates: [RecordedCandidate], hand: RecordedHand?, screen: UIImage?, extra: [String: Any] = [:]) -> String {
        count += 1
        let prefix = String(format: "%02d_%@", count, kind)
        let folder = folder
        let meta = Self.meta(kind: kind, snapshot: s, noun: noun, candidates: candidates, hand: hand, extra: extra)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            func url(_ name: String) -> URL { folder.appendingPathComponent("\(prefix)_\(name)") }
            try? s.jpeg.write(to: url("photo.jpg"))
            if let overlay = Self.overlay(snapshot: s, candidates: candidates, hand: hand) { try? overlay.write(to: url("overlay.jpg")) }
            if let screen, let data = screen.jpegData(compressionQuality: 0.7) { try? data.write(to: url("screen.jpg")) }
            if let samText { try? samText.write(to: url("sam.txt"), atomically: true, encoding: .utf8) }
            if let json = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? json.write(to: url("meta.json"))
            }
            s.depth.depth.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: url("depth.f32")) }
            if let c = s.depth.confidence { try? Data(c).write(to: url("conf.u8")) }
        }
        return prefix
    }

    // MARK: Pure helpers

    nonisolated static func portraitPixel(world: SIMD3<Float>, snapshot s: FrameSnapshot) -> SIMD2<Float>? {
        guard let raw = DepthProjector.rawPixel(fromWorld: world, cameraTransform: s.cameraTransform,
                                                intrinsics: s.intrinsics) else { return nil }
        return MaskTarget.portraitPixel(fromRawPixel: raw, rawSize: s.intrinsics.imageSize,
                                        imageSize: SIMD2(Float(s.imageSize.x), Float(s.imageSize.y)))
    }

    /// Vision normalized (origin bottom-left) -> uploaded image pixel (origin top-left).
    nonisolated static func portraitPixel(vision p: SIMD2<Float>, snapshot s: FrameSnapshot) -> SIMD2<Float> {
        SIMD2(p.x * Float(s.imageSize.x), (1 - p.y) * Float(s.imageSize.y))
    }

    nonisolated private static func meta(kind: String, snapshot s: FrameSnapshot, noun: String?,
                                         candidates: [RecordedCandidate], hand: RecordedHand?,
                                         extra: [String: Any]) -> [String: Any] {
        func v2(_ v: SIMD2<Float>?) -> Any { v.map { [$0.x, $0.y] } ?? NSNull() }
        func v3(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }
        let t = s.cameraTransform
        var m: [String: Any] = [
            "kind": kind, "noun": noun ?? "", "timestamp": s.timestamp, "tracking": s.tracking,
            "image_size": [s.imageSize.x, s.imageSize.y],
            "intrinsics_raw": ["fx": s.intrinsics.fx, "fy": s.intrinsics.fy, "cx": s.intrinsics.cx, "cy": s.intrinsics.cy,
                               "width": s.intrinsics.imageSize.x, "height": s.intrinsics.imageSize.y],
            "depth_size": [s.depth.width, s.depth.height],
            // Column-major, as simd stores it: columns 0..3.
            "camera_transform": [t.columns.0, t.columns.1, t.columns.2, t.columns.3].map { [$0.x, $0.y, $0.z, $0.w] },
            "candidates": candidates.map { c -> [String: Any] in
                [
                    "id": c.id, "confidence": c.confidence, "chosen": c.chosen,
                    "world": v3(c.world), "camera": v3(c.cameraPoint), "depth_samples": c.samples,
                    "depth_spread_m": c.depthSpread,
                    "box_px": [c.box.minX, c.box.minY, c.box.maxX, c.box.maxY],
                    "mask_centroid_px": v2(c.mask.centroid),
                    "target_reprojected_px": v2(c.reprojected),
                    "target_reprojects_inside_mask": c.reprojectsInsideMask.map { $0 as Any } ?? NSNull(),
                ]
            },
        ]
        if let hand {
            var joints: [String: Any] = [:]
            for (j, p) in hand.vision {
                var e: [String: Any] = ["vision_px": v2(portraitPixel(vision: p, snapshot: s))]
                if let w = hand.world[j] {
                    e["world"] = v3(w)
                    e["reprojected_px"] = v2(portraitPixel(world: w, snapshot: s))
                }
                if let d = hand.depths[j] { e["depth_m"] = d }
                joints["\(j)"] = e
            }
            m["hand"] = joints
        }
        for (k, v) in extra { m[k] = v }
        return m
    }

    nonisolated private static func overlay(snapshot s: FrameSnapshot, candidates: [RecordedCandidate],
                                            hand: RecordedHand?) -> Data? {
        guard let photo = UIImage(data: s.jpeg) else { return nil }
        let size = CGSize(width: s.imageSize.x, height: s.imageSize.y)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            photo.draw(in: CGRect(origin: .zero, size: size))
            for c in candidates {
                let colour = c.chosen ? UIColor.systemGreen : UIColor.systemYellow
                // Mask: one translucent rect per row run.
                g.setFillColor(colour.withAlphaComponent(0.35).cgColor)
                let r = c.mask.record
                for my in 0..<r.maskHeight {
                    var mx = 0
                    while mx < r.maskWidth {
                        guard c.mask.raster[my * r.maskWidth + mx] != 0 else { mx += 1; continue }
                        let start = mx
                        while mx < r.maskWidth && c.mask.raster[my * r.maskWidth + mx] != 0 { mx += 1 }
                        g.fill(CGRect(x: r.left + start, y: r.top + my, width: mx - start, height: 1))
                    }
                }
                g.setStrokeColor(colour.cgColor)
                g.setLineWidth(1.5)
                g.stroke(c.box)
                let label = "\(c.id) \(String(format: "%.2f", c.confidence))" as NSString
                label.draw(at: CGPoint(x: c.box.minX + 2, y: c.box.minY + 2),
                           withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: colour])
                if let m = c.mask.centroid { dot(g, m, 3, .white) }
                if let p = c.reprojected { cross(g, p, 9, .systemRed) }
            }
            if let hand {
                for p in hand.vision.values { dot(g, portraitPixel(vision: p, snapshot: s), 3, .systemBlue) }
                for (_, w) in hand.world {
                    if let p = portraitPixel(world: w, snapshot: s) { ring(g, p, 5, .systemOrange) }
                }
                if let palm = HandKeypoints(joints: hand.world).reference, let p = portraitPixel(world: palm, snapshot: s) {
                    cross(g, p, 7, .systemOrange)
                }
            }
        }
        return image.jpegData(compressionQuality: 0.85)
    }

    nonisolated private static func dot(_ g: CGContext, _ p: SIMD2<Float>, _ r: CGFloat, _ c: UIColor) {
        g.setFillColor(c.cgColor)
        g.fillEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: 2 * r, height: 2 * r))
    }

    nonisolated private static func ring(_ g: CGContext, _ p: SIMD2<Float>, _ r: CGFloat, _ c: UIColor) {
        g.setStrokeColor(c.cgColor)
        g.setLineWidth(1.5)
        g.strokeEllipse(in: CGRect(x: CGFloat(p.x) - r, y: CGFloat(p.y) - r, width: 2 * r, height: 2 * r))
    }

    nonisolated private static func cross(_ g: CGContext, _ p: SIMD2<Float>, _ r: CGFloat, _ c: UIColor) {
        g.setStrokeColor(c.cgColor)
        g.setLineWidth(2)
        let x = CGFloat(p.x), y = CGFloat(p.y)
        g.strokeLineSegments(between: [CGPoint(x: x - r, y: y), CGPoint(x: x + r, y: y),
                                       CGPoint(x: x, y: y - r), CGPoint(x: x, y: y + r)])
    }
}
