import Foundation
import RecoverDCore

/// A synchronous `RawBlockReader` backed by a file URL. Used for reading live files found by
/// `MountedVolumeScanner` — those files are accessible through the filesystem, so we open them
/// directly with `FileHandle` and serve reads without needing raw device access.
///
/// This is NOT an actor (unlike `URLBlockReader`) so it can be used directly in
/// `FileContentReader` without async ceremony. Thread-safe via a `DispatchQueue`.
public final class SyncFileReader: RawBlockReader, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "recoverd.syncreader")
    private var handle: FileHandle?
    private let fileSize: Int64
    private let _blockSize: Int

    public init(url: URL) {
        self.url = url
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        self.fileSize = Int64((attrs[.size] as? UInt64) ?? 0)
        self._blockSize = 512
        self.handle = try? FileHandle(forReadingFrom: url)
    }

    public var totalSize: Int64 { get async { fileSize } }
    public var blockSize: Int { get async { _blockSize } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        try queue.sync {
            guard let handle else { throw RecoverDError.deviceUnavailable }
            guard count > 0, offset >= 0 else { return SecureData(data: Data()) }
            try handle.seek(toOffset: UInt64(offset))
            let data = (try handle.read(upToCount: count)) ?? Data()
            return SecureData(data: data)
        }
    }
}

/// Alias for clarity — same class, used in export paths for mounted files.
public typealias MountedFileReaderSync = SyncFileReader
