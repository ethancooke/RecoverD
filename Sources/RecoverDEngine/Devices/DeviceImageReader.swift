import Foundation
import RecoverDCore

/// Reads raw blocks from a physical device by creating a temporary `.dmg` image using `hdiutil`,
/// then reading from that image. This works because `hdiutil` has Apple-granted entitlements to
/// read raw device nodes, even under SIP where `dd`/`open()` are blocked.
///
/// Usage: call `prepare()` (async) to create the image, then use as a `RawBlockReader`.
/// `imagingProgress` can be subscribed to BEFORE calling `prepare()` to get live progress.
///
/// SECURITY: the `.dmg` is in `/tmp` and deleted on `cleanup()`.
public actor DeviceImageReader: RawBlockReader {
    private let bsdName: String
    private let totalSizeBytes: Int64
    private let blockSizeBytes: Int
    private var imageReader: URLBlockReader?
    private var imageURL: URL?
    private var hdiutilProcess: Process?

    private let progressContinuation: AsyncStream<ImagingProgress>.Continuation
    public let imagingProgress: AsyncStream<ImagingProgress>

    public init(bsdName: String, totalSize: Int64, blockSize: Int) {
        self.bsdName = bsdName
        self.totalSizeBytes = totalSize
        self.blockSizeBytes = blockSize
        let (stream, cont) = AsyncStream<ImagingProgress>.makeStream()
        self.imagingProgress = stream
        self.progressContinuation = cont
    }

    /// Creates the .dmg image via hdiutil. Call this before using as a RawBlockReader.
    /// Subscribe to `imagingProgress` before calling this to get live progress updates.
    public func prepare() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let dmgPath = tmpDir.appendingPathComponent("recoverd_\(UUID().uuidString).dmg")
        self.imageURL = dmgPath

        progressContinuation.yield(ImagingProgress(bytesWritten: 0, totalBytes: totalSizeBytes))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["create", "-srcdevice", "/dev/\(bsdName)",
                          "-format", "UDRW", "-quiet", dmgPath.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        self.hdiutilProcess = proc

        // Monitor file size in a detached task (doesn't block the actor).
        let dmgPathStr = dmgPath.path
        let total = totalSizeBytes
        let monitorTask = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let attrs = try? FileManager.default.attributesOfItem(atPath: dmgPathStr)
                let currentSize = Int64((attrs?[.size] as? UInt64) ?? 0)
                await self.reportProgress(bytesWritten: currentSize, total: total)
                if proc.isRunning == false { break }
            }
        }

        // Wait for hdiutil to finish. Use a continuation so we don't block the actor.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                cont.resume()
            }
        }

        monitorTask.cancel()
        progressContinuation.yield(ImagingProgress(bytesWritten: totalSizeBytes, totalBytes: totalSizeBytes))

        if proc.terminationStatus != 0 {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            try? FileManager.default.removeItem(at: dmgPath)
            progressContinuation.finish()
            throw RecoverDError.readFailed(offset: 0, cause: "hdiutil failed: \(errMsg)")
        }

        self.imageReader = try await URLBlockReader(url: dmgPath, blockSize: blockSizeBytes)
        progressContinuation.finish()
    }

    private func reportProgress(bytesWritten: Int64, total: Int64) {
        progressContinuation.yield(ImagingProgress(bytesWritten: bytesWritten, totalBytes: total))
    }

    public var totalSize: Int64 { get async { await imageReader?.totalSize ?? totalSizeBytes } }
    public var blockSize: Int { get async { await imageReader?.blockSize ?? blockSizeBytes } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard let reader = imageReader else { throw RecoverDError.deviceUnavailable }
        return try await reader.read(at: offset, count: count)
    }

    public func cleanup() {
        if let url = imageURL { try? FileManager.default.removeItem(at: url); imageURL = nil }
    }

    /// Cancels an in-progress imaging operation by terminating the hdiutil process.
    public func cancelImaging() {
        hdiutilProcess?.terminate()
        progressContinuation.finish()
    }
}
