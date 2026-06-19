import Foundation
import RecoverDCore

/// Wraps a `RawBlockReader` + `RecoverableFile` to provide reads at **file-relative** offsets.
/// Offset 0 = start of the file, regardless of where the file lives on the device or how
/// fragmented it is. This is what the preview system (and `AVAssetResourceLoaderDelegate`)
/// needs: "give me bytes 1000–2000 of this file" without knowing the extent layout.
///
/// For contiguous files (carved or single-extent), reads are forwarded directly to the source
/// at `file.byteOffset + fileOffset`. For fragmented files, the requested range is mapped to
/// the correct extent(s) and assembled.
public struct FileContentReader: Sendable {
    public let file: RecoverableFile
    private let source: any RawBlockReader

    public init(file: RecoverableFile, source: any RawBlockReader) {
        self.file = file
        self.source = source
    }

    public var totalSize: Int64 { file.size }

    /// Reads `count` bytes starting at `fileOffset` from the beginning of the file.
    /// Returns a `SecureData` whose memory is zeroed when the caller is done.
    public func read(at fileOffset: Int64, count: Int) async throws -> SecureData {
        guard count > 0, fileOffset >= 0, fileOffset < file.size else {
            return SecureData(data: Data())
        }
        let available = file.size - fileOffset
        let toRead = Int(min(Int64(count), available))

        if let extents = file.extents, !extents.isEmpty {
            return try await readFromExtents(fileOffset: fileOffset, count: toRead, extents: extents)
        }
        return try await source.read(at: file.byteOffset + fileOffset, count: toRead)
    }

    /// Reads the entire file content into a single `SecureData`. Use only for small files
    /// (images, PDFs, text). For video, use `read(at:count:)` via `InMemoryAssetLoader`.
    public func readAll(maxLength: Int64? = nil) async throws -> SecureData {
        let limit = min(file.size, maxLength ?? file.size)
        guard limit > 0 else { return SecureData(data: Data()) }
        return try await read(at: 0, count: Int(limit))
    }

    private func readFromExtents(fileOffset: Int64, count: Int, extents: [ByteRange]) async throws -> SecureData {
        let combined = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 16)
        if let base = combined.baseAddress { memset(base, 0, count) }

        var pos = 0
        var remaining = fileOffset
        for ext in extents {
            if remaining >= ext.length {
                remaining -= ext.length
                continue
            }
            let skip = remaining
            remaining = 0
            let availableInExt = ext.length - skip
            let toReadFromExt = Int(min(Int64(count - pos), availableInExt))
            if toReadFromExt <= 0 { break }

            let chunk = try await source.read(at: ext.offset + skip, count: toReadFromExt)
            let actual = min(toReadFromExt, chunk.count)
            if actual > 0 {
                chunk.withUnsafeBytes { src in
                    if let dst = combined.baseAddress?.advanced(by: pos),
                       let srcBase = src.baseAddress {
                        dst.copyMemory(from: srcBase, byteCount: actual)
                    }
                }
            }
            chunk.wipe()
            pos += actual
            if pos >= count { break }
        }
        return SecureData(owning: combined)
    }
}
