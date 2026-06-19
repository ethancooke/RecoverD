import Foundation
import RecoverDCore

/// A `RawBlockReader` that reads from a specific file path on a mounted volume.
///
/// Used when `MountedVolumeScanner` finds live files — those files are accessible through the
/// filesystem, so we read their content by path rather than by raw byte offset on the device.
/// The `FileContentReader` treats this as a regular source; the file's `byteOffset` is ignored
/// and `extents` are nil, so reads go through `read(at:count:)` which maps to the file path.
///
/// SECURITY: opens the file with `O_RDONLY` via `FileHandle`. Content is read into `SecureData`
/// and wiped after use.
public actor MountedFileReader: RawBlockReader {
    private let fileURL: URL
    private let fileSize: Int64
    public let blockSize: Int

    public init(url: URL) async throws {
        self.fileURL = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        self.fileSize = Int64((attrs[.size] as? UInt64) ?? 0)
        self.blockSize = 512
    }

    public var totalSize: Int64 { get async { fileSize } }
    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard count > 0, offset >= 0 else { return SecureData(data: Data()) }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = (try handle.read(upToCount: count)) ?? Data()
        return SecureData(data: data)
    }
}
