import Foundation
import RecoverDCore

/// Reads recovered file *content* from the source. This is the single routine both preview
/// (`ScanEngine.readContent`) and export (`ExportManager`) use, so extent-following lives in
/// exactly one place.
///
/// - If `file.extents` is non-empty, content is the concatenation of those runs (a fragmented
///   file recovered from a file system). Runs are assembled directly into a single
///   `SecureData`-owned buffer (zero-initialized, so short reads at EOF leave zeros, not
///   garbage); each per-run `SecureData` chunk is wiped immediately after copying.
/// - Otherwise, content is a single read at `file.byteOffset` (a carved file or a contiguous
///   deleted-file heuristic).
///
/// `maxLength` caps the total bytes (used for thumbnail/preview generation).
func readContent(of file: RecoverableFile,
                 from reader: any RawBlockReader,
                 maxLength: Int64? = nil) async throws -> SecureData {
    let limit = min(max(0, file.size), maxLength ?? file.size)
    guard limit > 0 else { return SecureData(data: Data()) }

    if let extents = file.extents, !extents.isEmpty {
        let total = Int(limit)
        let combined = UnsafeMutableRawBufferPointer.allocate(byteCount: total, alignment: 16)
        if let base = combined.baseAddress { memset(base, 0, total) }

        var pos = 0
        var remaining = limit
        for ext in extents {
            if remaining <= 0 { break }
            let take = Int(min(ext.length, remaining))
            let chunk = try await reader.read(at: ext.offset, count: take)
            let actual = min(take, chunk.count)
            if actual > 0 {
                chunk.withUnsafeBytes { src in
                    if let dst = combined.baseAddress?.advanced(by: pos), let srcBase = src.baseAddress {
                        dst.copyMemory(from: srcBase, byteCount: actual)
                    }
                }
            }
            chunk.wipe()
            pos += actual
            remaining -= Int64(actual)
        }
        return SecureData(owning: combined)
    }

    return try await reader.read(at: file.byteOffset, count: Int(limit))
}
