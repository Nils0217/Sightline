// labels: production, needs-review
// Copies ARKit's LiDAR depth + confidence pixel buffers into SightlineCore.DepthImage.

import ARKit
import SightlineCore

nonisolated enum DepthImageReader {
    static func read(_ data: ARDepthData) -> DepthImage? {
        let depthMap = data.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              let depth: [Float] = copyRows(depthMap, width: width, height: height) else { return nil }

        var confidence: [UInt8]?
        if let confMap = data.confidenceMap,
           CVPixelBufferGetWidth(confMap) == width, CVPixelBufferGetHeight(confMap) == height {
            confidence = copyRows(confMap, width: width, height: height)
        }
        return DepthImage(width: width, height: height, depth: depth, confidence: confidence)
    }

    /// Row-by-row copy that respects bytesPerRow padding.
    private static func copyRows<T>(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [T]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        return [T](unsafeUninitializedCapacity: width * height) { out, count in
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: T.self)
                for x in 0..<width { (out.baseAddress! + y * width + x).initialize(to: row[x]) }
            }
            count = width * height
        }
    }
}
