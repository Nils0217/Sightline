// labels: production, needs-review, important
// SAM 3.1 image output: record parser and mask decoder.
// Swift port of Meta's meta-sam-parser 0.1.0 (_segmentation.py, _mask_codec.py) for the
// image case. Verified against the Python parser on real outputs (Tests/.../Fixtures,
// built by tools/make_sam_fixtures.py). Format: docs/api-notes.md.

import Foundation

/// One segmented instance. Box bounds are source pixels; `right`/`bottom` are exclusive.
public struct SAMRecord: Sendable, Equatable {
    public var id: String
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int
    /// Size of the image SAM saw.
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var confidence: Float?
    /// Mask raster size; the raster is box-local, placed at (`left`, `top`).
    public var maskWidth: Int
    public var maskHeight: Int
    /// `~` lossless or `!` one_bit payload.
    public var payload: String

    /// Row-major 0/1 raster of `maskWidth` x `maskHeight`.
    public func decodeMask() throws -> [UInt8] {
        try SAMMaskDecoder.decode(payload, width: maskWidth, height: maskHeight)
    }
}

public enum SAMError: Error, Equatable {
    case invalidMask(String)
}

public enum SAMParser {
    /// Parses every well-formed record in the SAM text output. Malformed records are skipped.
    public static func parse(_ text: String) -> [SAMRecord] {
        var records: [SAMRecord] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("<"), let close = line.firstIndex(of: ">") else { continue }
            // Frame header `<0f>` or `<0f;k=v>`; images only use frame 0.
            let header = line[line.index(after: line.startIndex)..<close]
            guard header.split(separator: ";").first == "0f" else { continue }
            records += parseBody(String(line[line.index(after: close)...]))
        }
        return records
    }

    private static func parseBody(_ body: String) -> [SAMRecord] {
        var records: [SAMRecord] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            if rest.first == "," { rest = rest.dropFirst() }
            let id = rest.prefix { $0.isASCII && $0.isNumber }
            guard !id.isEmpty else { break }
            rest = rest.dropFirst(id.count)
            var tokens: [String: [String: String]] = [:]
            while rest.hasPrefix("<|"), let end = rest.range(of: "|>") {
                let inner = rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound]
                let parts = inner.split(separator: ";", omittingEmptySubsequences: true)
                if let name = parts.first {
                    var fields: [String: String] = [:]
                    for part in parts.dropFirst() {
                        let kv = part.split(separator: "=", maxSplits: 1)
                        let key = kv[0].trimmingCharacters(in: .whitespaces)
                        if fields[key] == nil { fields[key] = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : "" }
                    }
                    tokens[String(name)] = fields
                }
                rest = rest[end.upperBound...]
            }
            if let record = makeRecord(id: String(id), box: tokens["box"], mask: tokens["mask"]) {
                records.append(record)
            }
        }
        return records
    }

    private static func makeRecord(id: String, box: [String: String]?, mask: [String: String]?) -> SAMRecord? {
        guard let box, let mask,
              let x1 = box["x1"].flatMap(Int.init), let y1 = box["y1"].flatMap(Int.init),
              let x2 = box["x2"].flatMap(Int.init), let y2 = box["y2"].flatMap(Int.init),
              let w = box["w"].flatMap(Int.init), let h = box["h"].flatMap(Int.init),
              mask["x"] == "0", mask["y"] == "0", let data = mask["data"] else { return nil }
        guard w > 0, h > 0, x1 >= 0, y1 >= 0, x2 >= x1, y2 >= y1, x2 < w, y2 < h else { return nil }
        // data = <height>,<width>,<payload>
        let parts = data.split(separator: ",", maxSplits: 2)
        guard parts.count == 3, let mh = Int(parts[0]), let mw = Int(parts[1]), mw > 0, mh > 0,
              let tag = parts[2].first, tag == "~" || tag == "!" else { return nil }
        return SAMRecord(id: id, left: x1, top: y1, right: x2 + 1, bottom: y2 + 1,
                         sourceWidth: w, sourceHeight: h, confidence: box["c"].flatMap(Float.init),
                         maskWidth: mw, maskHeight: mh, payload: String(parts[2]))
    }
}

// MARK: - Mask codec (port of _mask_codec.py, decode side only)

enum SAMMaskDecoder {
    private static let alphabet: [UInt8] = {
        let excluded: Set<UInt8> = Set("\"\\,;<>|".utf8)
        return (UInt8(0x21)..<UInt8(0x7F)).filter { !excluded.contains($0) }
    }()
    private static let digitValues: [Int] = {
        var values = [Int](repeating: -1, count: 128)
        for (i, c) in alphabet.enumerated() { values[Int(c)] = i }
        return values
    }()
    private static let radix: UInt64 = 85
    private static let prefixLength = 5

    static func decode(_ payload: String, width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw SAMError.invalidMask("non-positive size") }
        let bytes = Array(payload.utf8)
        guard let tag = bytes.first else { throw SAMError.invalidMask("empty payload") }
        let packed = try unpack(bytes.dropFirst())
        switch tag {
        case UInt8(ascii: "~"):
            return try decodeLossless(packed, width: width, height: height).map { $0 >= 129 ? 1 : 0 }
        case UInt8(ascii: "!"):
            return try decodeOneBit(packed, width: width, height: height)
        default:
            throw SAMError.invalidMask("unknown encoding")
        }
    }

    private static func digit(_ c: UInt8) throws -> UInt64 {
        let v = c < 128 ? digitValues[Int(c)] : -1
        guard v >= 0 else { throw SAMError.invalidMask("invalid character") }
        return UInt64(v)
    }

    static func unpack(_ payload: ArraySlice<UInt8>) throws -> [UInt8] {
        let p = Array(payload)
        guard p.count >= prefixLength else { throw SAMError.invalidMask("missing length prefix") }
        var length: UInt64 = 0
        for c in p[0..<prefixLength] { length = length * radix + (try digit(c)) }
        let n = Int(length)
        let remainder = n % 4
        guard p.count == prefixLength + (n / 4) * 5 + (remainder == 0 ? 0 : remainder + 1) else {
            throw SAMError.invalidMask("length does not match prefix")
        }
        var out = [UInt8](repeating: 0, count: n)
        var src = prefixLength
        var dst = 0
        while dst < n - remainder {
            var value: UInt64 = 0
            for i in 0..<5 { value = value * radix + (try digit(p[src + i])) }
            guard value <= 0xFFFF_FFFF else { throw SAMError.invalidMask("group out of range") }
            out[dst] = UInt8(truncatingIfNeeded: value >> 24)
            out[dst + 1] = UInt8(truncatingIfNeeded: value >> 16)
            out[dst + 2] = UInt8(truncatingIfNeeded: value >> 8)
            out[dst + 3] = UInt8(truncatingIfNeeded: value)
            src += 5
            dst += 4
        }
        if remainder > 0 {
            var value: UInt64 = 0
            for i in 0..<5 { value = value * radix + (i < remainder + 1 ? try digit(p[src + i]) : radix - 1) }
            guard value <= 0xFFFF_FFFF else { throw SAMError.invalidMask("tail out of range") }
            for i in 0..<remainder { out[dst + i] = UInt8(truncatingIfNeeded: value >> UInt64(24 - i * 8)) }
        }
        return out
    }

    // MARK: Range decoder

    private struct RangeDecoder {
        static let top: UInt32 = 1 << 24
        static let bottom: UInt32 = 1 << 16
        let input: [UInt8]
        var position: Int
        var low: UInt32 = 0
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        var scaled: UInt32 = 0

        init(_ input: [UInt8], start: Int) throws {
            guard input.count - start >= 4 else { throw SAMError.invalidMask("missing finalization") }
            self.input = input
            position = start
            for _ in 0..<4 { code = (code << 8) | UInt32(try read()) }
        }

        mutating func read() throws -> UInt8 {
            guard position < input.count else { throw SAMError.invalidMask("payload ended early") }
            defer { position += 1 }
            return input[position]
        }

        mutating func frequency(_ total: UInt32) throws -> UInt32 {
            scaled = range / total
            guard scaled > 0 else { throw SAMError.invalidMask("invalid coding state") }
            let value = (code &- low) / scaled
            return value >= total ? total - 1 : value
        }

        mutating func decode(_ cumulative: UInt32, _ frequency: UInt32) throws {
            low = low &+ scaled &* cumulative
            range = scaled &* frequency
            while true {
                if (low ^ (low &+ range)) < Self.top {
                } else if range < Self.bottom {
                    range = (0 &- low) & (Self.bottom - 1)
                } else {
                    break
                }
                code = (code << 8) | UInt32(try read())
                low = low << 8
                range = range << 8
            }
        }
    }

    // MARK: one_bit

    private static func decodeOneBit(_ packed: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        var decoder = try RangeDecoder(packed, start: 0)
        let padding = 2
        var counts = [UInt16](repeating: 1, count: (1 << 12) * 2)
        let pw = width + 2 * padding
        var padded = [UInt8](repeating: 0, count: pw * (height + padding))
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (y + padding) * pw + padding
            for x in 0..<width {
                let pos = row + x
                let prior = pos - pw
                let earlier = pos - 2 * pw
                var context = Int(padded[pos - 1]) | Int(padded[pos - 2]) << 1
                context |= Int(padded[prior - 2]) << 2 | Int(padded[prior - 1]) << 3 | Int(padded[prior]) << 4
                context |= Int(padded[prior + 1]) << 5 | Int(padded[prior + 2]) << 6
                context |= Int(padded[earlier - 2]) << 7 | Int(padded[earlier - 1]) << 8 | Int(padded[earlier]) << 9
                context |= Int(padded[earlier + 1]) << 10 | Int(padded[earlier + 2]) << 11
                let offset = context << 1
                let zero = UInt32(counts[offset]), one = UInt32(counts[offset + 1])
                let bit = try decoder.frequency(zero + one) < zero ? 0 : 1
                if bit == 0 { try decoder.decode(0, zero) } else { try decoder.decode(zero, one) }
                padded[pos] = UInt8(bit)
                out[y * width + x] = UInt8(bit)
                counts[offset + bit] = counts[offset + bit] &+ 14
                if Int(counts[offset]) + Int(counts[offset + 1]) >= 4096 {
                    counts[offset] = max(counts[offset] >> 1, 1)
                    counts[offset + 1] = max(counts[offset + 1] >> 1, 1)
                }
            }
        }
        return out
    }

    // MARK: lossless

    private static func paeth(_ left: Int, _ up: Int, _ upperLeft: Int) -> Int {
        let estimate = left + up - upperLeft
        let l = abs(estimate - left), u = abs(estimate - up), ul = abs(estimate - upperLeft)
        if l <= u && l <= ul { return left }
        return u <= ul ? up : upperLeft
    }

    private static func decodeLossless(_ packed: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        guard packed.count >= 5 else { throw SAMError.invalidMask("lossless payload truncated") }
        let selector = Int(packed[0])
        guard selector < 5 else { throw SAMError.invalidMask("invalid predictor") }
        var decoder = try RangeDecoder(packed, start: 1)
        let symbols = 256
        let length = width * height
        var output = [UInt8](repeating: 0, count: length)
        var residuals = [UInt8](repeating: 0, count: length)
        var zeroCounts = [UInt32](repeating: 1, count: 32)
        var orderOne = [UInt16](repeating: 1, count: symbols * symbols)
        var orderOneTotals = [Int32](repeating: Int32(symbols), count: symbols)
        var orderZero = [UInt16](repeating: 2, count: symbols)
        var orderZeroTotal = symbols * 2
        var orderTwo: [Int: [UInt16]] = [:]
        var previous = 0

        for offset in 0..<length {
            let x = offset % width, y = offset / width
            // Zero-run context from neighbouring residuals.
            let l = x > 0 ? (residuals[offset - 1] == 0 ? 1 : 0) : 1
            let u = y > 0 ? (residuals[offset - width] == 0 ? 1 : 0) : 1
            let ul = x > 0 && y > 0 ? (residuals[offset - width - 1] == 0 ? 1 : 0) : 1
            let ur = y > 0 && x < width - 1 ? (residuals[offset - width + 1] == 0 ? 1 : 0) : 1
            let zeroOffset = (l | u << 1 | ul << 2 | ur << 3) << 1
            let zero = zeroCounts[zeroOffset], nonzero = zeroCounts[zeroOffset + 1]
            let bit = try decoder.frequency(zero + nonzero) < zero ? 0 : 1
            try decoder.decode(bit == 0 ? 0 : zero, bit == 0 ? zero : nonzero)
            zeroCounts[zeroOffset + bit] = zeroCounts[zeroOffset + bit] &+ 32
            if zeroCounts[zeroOffset] + zeroCounts[zeroOffset + 1] >= 16384 {
                zeroCounts[zeroOffset] = max(zeroCounts[zeroOffset] >> 1, 1)
                zeroCounts[zeroOffset + 1] = max(zeroCounts[zeroOffset + 1] >> 1, 1)
            }

            var symbol = 0
            if bit == 1 {
                let above = offset >= width ? Int(residuals[offset - width]) : 0
                let key = previous << 8 | above
                var second = orderTwo[key] ?? [UInt16](repeating: 0, count: symbols + 1)
                let firstOffset = previous << 8
                let excludedZero = Int(second[0]) + Int(orderOne[firstOffset]) + Int(orderZero[0])
                let total = Int(second[symbols]) + Int(orderOneTotals[previous]) + orderZeroTotal - excludedZero
                let target = Int(try decoder.frequency(UInt32(total)))
                var cumulative = 0
                symbol = 1
                var frequency = Int(second[1]) + Int(orderOne[firstOffset + 1]) + Int(orderZero[1])
                while cumulative + frequency <= target {
                    cumulative += frequency
                    symbol += 1
                    guard symbol < symbols else { throw SAMError.invalidMask("lossless payload malformed") }
                    frequency = Int(second[symbol]) + Int(orderOne[firstOffset + symbol]) + Int(orderZero[symbol])
                }
                try decoder.decode(UInt32(cumulative), UInt32(frequency))

                second[symbol] = second[symbol] &+ 14 * 44
                second[symbols] = second[symbols] &+ 14 * 44
                if second[symbols] >= 14 * 3584 {
                    var sum = 0
                    for v in 0..<symbols { second[v] >>= 1; sum += Int(second[v]) }
                    second[symbols] = UInt16(truncatingIfNeeded: sum)
                }
                orderTwo[key] = second

                orderOne[firstOffset + symbol] = orderOne[firstOffset + symbol] &+ 56
                orderOneTotals[previous] = orderOneTotals[previous] &+ 56
                if orderOneTotals[previous] >= 8192 {
                    var sum: Int32 = 0
                    for v in 0..<symbols {
                        let s = max(orderOne[firstOffset + v] >> 1, 1)
                        orderOne[firstOffset + v] = s
                        sum += Int32(s)
                    }
                    orderOneTotals[previous] = sum
                }

                orderZero[symbol] = orderZero[symbol] &+ 32
                orderZeroTotal += 32
                if orderZeroTotal >= 2 * 2048 {
                    var sum = 0
                    for v in 0..<symbols { orderZero[v] >>= 1; sum += Int(orderZero[v]) }
                    orderZeroTotal = sum
                }
            }
            residuals[offset] = UInt8(symbol)

            // Spatial prediction, then undo the zigzag residual.
            let left = x > 0 ? Int(output[offset - 1]) : 0
            let up = y > 0 ? Int(output[offset - width]) : 0
            let upperLeft = x > 0 && y > 0 ? Int(output[offset - width - 1]) : 0
            let prediction: Int
            switch selector {
            case 1: prediction = up
            case 2: prediction = left
            case 3: prediction = (left + up) >> 1
            case 0: prediction = paeth(left, up, upperLeft)
            default:
                if upperLeft >= max(left, up) { prediction = min(left, up) }
                else if upperLeft <= min(left, up) { prediction = max(left, up) }
                else { prediction = left + up - upperLeft }
            }
            let delta = symbol & 1 == 1 ? -((symbol + 1) >> 1) : symbol >> 1
            output[offset] = UInt8(truncatingIfNeeded: prediction + delta)
            previous = symbol
        }
        return output
    }
}
