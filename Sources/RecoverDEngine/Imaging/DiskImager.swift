import Foundation
import RecoverDCore

public struct ImagingProgress: Sendable, Hashable {
    public var bytesWritten: Int64
    public var totalBytes: Int64
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }
    public init(bytesWritten: Int64, totalBytes: Int64) {
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
    }
}

/// Byte-for-byte copy of a source device/image to a `.dmg`/raw image on the Mac.
///
/// This is an **explicit, user-initiated write** (the recommended pre-recovery safety step),
/// so it is permitted to write to disk — unlike scanning/previewing. Source bytes are read into
/// `SecureData`, written to the destination, and immediately wiped per chunk so only the
/// destination file (chosen by the user) ever persists content. Progress is delivered via an
/// `AsyncStream` continuation for actor-safe observation.
public struct DiskImager: Sendable {
    public init() {}

    public func image(from reader: any RawBlockReader,
                      to destination: URL,
                      chunkSize: Int = 4 * 1024 * 1024,
                      progress continuation: AsyncStream<ImagingProgress>.Continuation? = nil) async throws {
        let total = await reader.totalSize

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer {
            try? handle.synchronize()
            try? handle.close()
        }

        var written: Int64 = 0
        while written < total {
            try Task.checkCancellation()
            let toRead = Int(min(Int64(chunkSize), total - written))
            let chunk = try await reader.read(at: written, count: toRead)
            if chunk.count == 0 { break }
            try chunk.withUnsafeBytes { buf in
                try handle.write(contentsOf: Data(buf))
            }
            written += Int64(chunk.count)
            chunk.wipe()
            continuation?.yield(ImagingProgress(bytesWritten: written, totalBytes: total))
        }
    }
}
