// labels: testing, needs-review, important
// `swift run SightlineSim replay <diagnostics folder>`: re-runs the object model and the grasp check
// on a device recording (DiagnosticRecorder output). Reads only; writes nothing.
// For each SAM event: support height, flat or not, size, centre vs the old single-point target.
// For each hand event after it: fingertips near the surface, thumb opposition, palm distances.

import Foundation
import simd
import SightlineCore

enum Replay {
    struct Event {
        var prefix: String
        var kind: String
        var meta: [String: Any]
    }

    static func run(folder: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { print("Cannot read \(folder)"); return }
        let metas = names.filter { $0.hasSuffix("_meta.json") }.sorted()
        var object: ObjectModel?
        var objectName = ""
        for name in metas {
            let prefix = String(name.dropLast("_meta.json".count))
            guard let data = fm.contents(atPath: "\(folder)/\(name)"),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let kind = meta["kind"] as? String ?? "?"
            print("== \(prefix)")
            if kind == "sam" || kind == "scan" {
                printLocate(folder: folder, prefix: prefix, meta: meta)
                guard let built = buildObject(folder: folder, prefix: prefix, meta: meta) else { print("   no object model"); continue }
                object = built
                objectName = meta["noun"] as? String ?? ""
                let old = (meta["candidates"] as? [[String: Any]])?.first?["world"] as? [Double]
                print(String(format: "   %@: %@, support y %@, size %.1f x %.1f x %.1f cm, %d points",
                             objectName, built.isFlat ? "flat" : "not flat",
                             built.supportHeight.map { String(format: "%.3f", $0) } ?? "none",
                             built.size.x * 100, built.size.y * 100, built.size.z * 100, built.points.count))
                if let sup = built.supportHeight {
                    let ys = built.points.map(\.y)
                    print(String(format: "   height above support: median %.1f cm, p10 %.1f, p90 %.1f",
                                 ((Stats.median(ys) ?? 0) - sup) * 100, ((Stats.percentile(ys, 0.1) ?? 0) - sup) * 100,
                                 ((Stats.percentile(ys, 0.9) ?? 0) - sup) * 100))
                }
                if let old {
                    let o = SIMD3(Float(old[0]), Float(old[1]), Float(old[2]))
                    print(String(format: "   centre moved %.1f cm from the old single-point target (dy %.1f cm)",
                                 simd_distance(o, built.centre) * 100, (built.centre.y - o.y) * 100))
                }
            } else if let object, let hand = meta["hand"] as? [String: [String: Any]] {
                var joints: [HandJoint: SIMD3<Float>] = [:]
                for (key, e) in hand {
                    guard let j = HandJoint.allCases.first(where: { "\($0)" == key }), let w = e["world"] as? [Double] else { continue }
                    joints[j] = SIMD3(Float(w[0]), Float(w[1]), Float(w[2]))
                }
                let h = HandKeypoints(joints: joints)
                let g = GraspAssessment.assess(h, object: object)
                let tips = h.tips.map { "\($0.key)".replacingOccurrences(of: "Tip", with: "") + String(format: " %.1f", object.distanceToSurface($0.value) * 100) }
                    .sorted().joined(separator: ", ")
                print(String(format: "   %@ vs %@: palm→surface %@, palm→centre %@, old hand→target %@ cm",
                             kind, objectName,
                             g.palmToSurface.map { String(format: "%.1f cm", $0 * 100) } ?? "-",
                             h.reference.map { String(format: "%.1f cm", simd_distance($0, object.centre) * 100) } ?? "-",
                             String(format: "%.1f", (meta["hand_to_target_cm"] as? Double) ?? -1)))
                print("   fingertips to surface (cm): \(tips.isEmpty ? "none with depth" : tips)")
                print("   -> tipsNear \(g.tipsNear), touching \(g.touching), opposed \(g.opposed)")
            }
        }
    }

    /// Old fixed-erosion target vs the adaptive one, per SAM record (was a detection dropped?).
    static func printLocate(folder: String, prefix: String, meta: [String: Any]) {
        guard let (records, depth, k, _) = load(folder: folder, prefix: prefix, meta: meta) else { return }
        for r in records {
            guard let raster = try? r.decodeMask() else { continue }
            let mask = SourceMask(record: r, raster: raster)
            func show(_ x: Result<MaskTargetResult, MaskTargetFailure>) -> String {
                switch x {
                case .success(let h): "ok (\(h.samples) samples)"
                case .failure(let f): f.rawValue
                }
            }
            print(String(format: "   SAM %@ c %.2f box %dx%d px: fixed %@, adaptive %@", r.id, r.confidence ?? 0,
                         r.right - r.left, r.bottom - r.top,
                         show(MaskTarget.locate(mask: mask, depth: depth, intrinsics: k)),
                         show(MaskTarget.locateAdaptive(mask: mask, depth: depth, intrinsics: k))))
        }
    }

    static func load(folder: String, prefix: String, meta: [String: Any])
        -> ([SAMRecord], DepthImage, CameraIntrinsics, simd_float4x4)? {
        let fm = FileManager.default
        guard let samText = try? String(contentsOfFile: "\(folder)/\(prefix)_sam.txt", encoding: .utf8),
              let depthData = fm.contents(atPath: "\(folder)/\(prefix)_depth.f32"),
              let size = meta["depth_size"] as? [Int], let k = meta["intrinsics_raw"] as? [String: Double],
              let cols = meta["camera_transform"] as? [[Double]], cols.count == 4 else { return nil }
        let depth = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let conf = fm.contents(atPath: "\(folder)/\(prefix)_conf.u8").map { [UInt8]($0) }
        let image = DepthImage(width: size[0], height: size[1], depth: depth, confidence: conf)
        let intr = CameraIntrinsics(fx: Float(k["fx"]!), fy: Float(k["fy"]!), cx: Float(k["cx"]!), cy: Float(k["cy"]!),
                                    imageSize: SIMD2(Float(k["width"]!), Float(k["height"]!)))
        let c = cols.map { SIMD4(Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
        return (records(samText, meta: meta), image, intr, simd_float4x4(columns: (c[0], c[1], c[2], c[3])))
    }

    /// SAM records of a recording; tiled small-object calls (meta `tile_origins`) are placed back on the full image.
    static func records(_ samText: String, meta: [String: Any]) -> [SAMRecord] {
        guard let origins = meta["tile_origins"] as? [[Int]], let full = meta["image_size"] as? [Int], full.count == 2 else {
            return SAMParser.parse(samText)
        }
        return SmallObjects.parseTiled(samText, origins: origins.map { SIMD2($0[0], $0[1]) }, fullSize: SIMD2(full[0], full[1]))
    }

    static func buildObject(folder: String, prefix: String, meta: [String: Any]) -> ObjectModel? {
        let fm = FileManager.default
        guard let samText = try? String(contentsOfFile: "\(folder)/\(prefix)_sam.txt", encoding: .utf8),
              let depthData = fm.contents(atPath: "\(folder)/\(prefix)_depth.f32"),
              let size = meta["depth_size"] as? [Int], let k = meta["intrinsics_raw"] as? [String: Double],
              let cols = meta["camera_transform"] as? [[Double]], cols.count == 4 else { return nil }
        let depth = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let conf = fm.contents(atPath: "\(folder)/\(prefix)_conf.u8").map { [UInt8]($0) }
        let image = DepthImage(width: size[0], height: size[1], depth: depth, confidence: conf)
        let intr = CameraIntrinsics(fx: Float(k["fx"]!), fy: Float(k["fy"]!), cx: Float(k["cx"]!), cy: Float(k["cy"]!),
                                    imageSize: SIMD2(Float(k["width"]!), Float(k["height"]!)))
        let c = cols.map { SIMD4(Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
        let t = simd_float4x4(columns: (c[0], c[1], c[2], c[3]))
        // Same choice as the app: most confident record.
        guard let record = records(samText, meta: meta).max(by: { ($0.confidence ?? 0) < ($1.confidence ?? 0) }),
              let raster = try? record.decodeMask() else { return nil }
        return ObjectModel.build(mask: SourceMask(record: record, raster: raster), depth: image, intrinsics: intr, cameraTransform: t)
    }
}
