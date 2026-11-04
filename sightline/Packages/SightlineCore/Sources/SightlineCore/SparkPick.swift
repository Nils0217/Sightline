// labels: production, needs-review
// Spark picks the target (Nils, 2026-11-03, after T13-T17: SAM chose and Spark only vetoed, so a category
// detector decided "which one" and a yes/no on one box could not tell two phones apart). Spark points at
// the thing the user means; SAM only draws its outline; LiDAR places it.

import Foundation

public struct SparkPick: Sendable, Equatable {
    /// What the user wants, short ("phone", "pill bottle").
    public var want: String
    public var visible: Bool
    /// Centre of its visible part, 0-1 on the photo (x left to right, y top to bottom).
    public var x: Float
    public var y: Float
    /// What it looks like, one or two words SAM can find ("pill bottle").
    public var sam: String
    /// How it differs from look-alikes in the photo (log, which-one question).
    public var how: String
    /// How many other things in the photo look like it (T18: vitamin and melatonin, same yellow caps): more than 0
    /// sends a closer look that reads labels.
    public var similar: Int

    public init(want: String, visible: Bool, x: Float = 0, y: Float = 0, sam: String = "", how: String = "", similar: Int = 0) {
        self.similar = similar
        self.want = want
        self.visible = visible
        self.x = x
        self.y = y
        self.sam = sam
        self.how = how
    }

    /// `{"want":"phone","visible":true,"x":0.42,"y":0.61,"sam":"phone","how":"grey, on the left"}`; nil when
    /// unreadable. A visible pick without a point in the photo counts as not visible.
    public static func parse(_ text: String) -> SparkPick? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func clean(_ key: String) -> String {
            (json[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let want = clean("want")
        let x = (json["x"] as? NSNumber)?.floatValue, y = (json["y"] as? NSNumber)?.floatValue
        guard json["visible"] as? Bool == true, let x, let y, (0...1).contains(x), (0...1).contains(y) else {
            return SparkPick(want: want, visible: false)
        }
        let sam = clean("sam")
        return SparkPick(want: want, visible: true, x: x, y: y, sam: sam.isEmpty ? want : sam, how: clean("how"),
                         similar: (json["similar"] as? NSNumber)?.intValue ?? 0)
    }

    /// A pick made on a crop at `origin`, `size` of a photo `full`: the same point on the whole photo (0-1).
    public func onPhoto(cropOrigin origin: SIMD2<Int>, cropSize size: SIMD2<Int>, full: SIMD2<Int>) -> SparkPick {
        var p = self
        p.x = (Float(origin.x) + x * Float(size.x)) / Float(full.x)
        p.y = (Float(origin.y) + y * Float(size.y)) / Float(full.y)
        return p
    }

    /// The pick in pixels of an image `size` wide and high.
    public func pixel(in size: SIMD2<Int>) -> SIMD2<Int> {
        SIMD2(min(size.x - 1, max(0, Int(x * Float(size.x)))), min(size.y - 1, max(0, Int(y * Float(size.y)))))
    }

    /// The SAM outline Spark pointed at: the smallest mask holding the point, else the smallest box holding it,
    /// else the box nearest the point within `near` pixels (Spark's point is approximate: just beside a thin phone),
    /// else nil (SAM did not outline it).
    public static func choose(_ masks: [SourceMask], at p: SIMD2<Int>, near: Int = 0) -> Int? {
        func area(_ m: SourceMask) -> Int { (m.record.right - m.record.left) * (m.record.bottom - m.record.top) }
        let inMask = masks.indices.filter { masks[$0].contains(p.x, p.y) }
        if let i = inMask.min(by: { area(masks[$0]) < area(masks[$1]) }) { return i }
        let inBox = masks.indices.filter { i in
            let r = masks[i].record
            return p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom
        }
        if let i = inBox.min(by: { area(masks[$0]) < area(masks[$1]) }) { return i }
        func gap(_ m: SourceMask) -> Int {
            let r = m.record
            return max(r.left - p.x, 0, p.x - (r.right - 1)) + max(r.top - p.y, 0, p.y - (r.bottom - 1))
        }
        return masks.indices.filter { gap(masks[$0]) <= near }.min(by: { gap(masks[$0]) < gap(masks[$1]) })
    }

    /// No outline: a filled square of `side` pixels around the point, so LiDAR can still place and shape it.
    public static func pointMask(at p: SIMD2<Int>, side: Int, imageSize: SIMD2<Int>) -> SourceMask {
        let left = max(0, p.x - side / 2), top = max(0, p.y - side / 2)
        let right = min(imageSize.x, left + side), bottom = min(imageSize.y, top + side)
        let record = SAMRecord(id: "spark", left: left, top: top, right: right, bottom: bottom,
                               sourceWidth: imageSize.x, sourceHeight: imageSize.y, confidence: nil,
                               maskWidth: right - left, maskHeight: bottom - top, payload: "")
        return SourceMask(record: record, raster: [UInt8](repeating: 1, count: (right - left) * (bottom - top)))
    }
}
