import Foundation
import RecoverDCore

public struct ExportProgress: Sendable, Hashable {
    public var exported: Int
    public var total: Int
    public var currentFileName: String
    public var bytesWritten: Int64
    public init(exported: Int, total: Int, currentFileName: String, bytesWritten: Int64 = 0) {
        self.exported = exported
        self.total = total
        self.currentFileName = currentFileName
        self.bytesWritten = bytesWritten
    }
}

/// THE explicit-save path. This is the only component that writes recovered *content* to the
/// Mac, and only when the user selects files and chooses a destination.
///
/// Workflow per file:
///   1. Read the file's bytes from the source into a transient `SecureData`.
///   2. Write them to a unique file inside the user-chosen destination directory.
///   3. Wipe the `SecureData` immediately (no content is retained after writing).
///
/// Progress is delivered through an `AsyncStream` continuation so the caller can observe it
/// safely on its own actor (e.g. `@MainActor`), rather than via a closure that would have to
/// touch isolated state from off-actor. The destination directory should be resolved through a
/// security-scoped bookmark by the App layer before calling here.
public struct ExportManager: Sendable {
    public init() {}

    public func export(files: [RecoverableFile],
                       from reader: any RawBlockReader,
                       to directory: URL,
                       progress continuation: AsyncStream<ExportProgress>.Continuation? = nil) async throws -> [URL] {
        var written: [URL] = []
        written.reserveCapacity(files.count)

        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let content = try await readContent(of: file, from: reader)
            defer { content.wipe() }

            let destination = uniqueURL(in: directory, for: file)
            try content.withUnsafeBytes { buf in
                try Data(buf).write(to: destination, options: [.atomic])
            }

            written.append(destination)
            continuation?.yield(ExportProgress(
                exported: index + 1,
                total: files.count,
                currentFileName: file.displayName,
                bytesWritten: file.size
            ))
        }
        return written
    }

    private func uniqueURL(in directory: URL, for file: RecoverableFile) -> URL {
        let baseName = file.displayName
        let proposed = directory.appendingPathComponent(baseName)
        if FileManager.default.fileExists(atPath: proposed.path) {
            let ext = (baseName as NSString).pathExtension
            let stem = (baseName as NSString).deletingPathExtension
            let suffix = String(Int.random(in: 1000...9999))
            let unique = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
            return directory.appendingPathComponent(unique)
        }
        return proposed
    }
}
