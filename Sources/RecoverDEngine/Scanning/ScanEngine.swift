import Foundation
import RecoverDCore

/// Owns the mutable recovery session state: the live `RecoverableFile` list, scan progress, and
/// the transient source reader. All recovered *metadata* lives here in RAM; recovered *content*
/// is fetched on demand via `readContent(for:)` into `SecureData` that the caller wipes.
///
/// This is an `actor` to keep mutable state off the main thread and to satisfy Swift 6 strict
/// concurrency. The UI never touches this state directly — it reads `ScanResult` snapshots and
/// an `AsyncStream<ScanProgress>`.
public actor ScanEngine {

    // MARK: State

    private var device: DeviceInfo?
    private var reader: (any RawBlockReader)?
    private var mode: ScanMode = .quick
    private var files: [RecoverableFile] = []
    private var errors: [ScanError] = []
    private var progress = ScanProgress()
    private var startedAt: Date?
    private var finishedAt: Date?
    private var bytesRead: Int64 = 0

    private var scanTask: Task<Void, Never>?
    private var paused = false

    private var subscribers: [UUID: AsyncStream<ScanProgress>.Continuation] = [:]

    public init() {}

    // MARK: Scanning

    public func startScan(device: DeviceInfo, mode: ScanMode, reader: any RawBlockReader) {
        cancel()
        self.device = device
        self.reader = reader
        self.mode = mode
        self.files = []
        self.errors = []
        self.bytesRead = 0
        self.startedAt = Date()
        self.finishedAt = nil
        self.paused = false
        self.progress = ScanProgress(totalBytes: device.totalSize, phase: .discovering)
        broadcast()

        let capture = ScanCapture(engine: self)
        scanTask = Task { [weak self] in
            await self?.runScan(capture: capture)
        }
    }

    public func pause() {
        paused = true
        progress.isPaused = true
        broadcast()
    }

    public func resume() {
        paused = false
        progress.isPaused = false
        broadcast()
    }

    public func cancel() {
        scanTask?.cancel()
        scanTask = nil
        if progress.phase == .discovering || progress.phase == .parsing
            || progress.phase == .carving || progress.phase == .finalizing {
            progress.phase = .cancelled
            broadcast()
        }
    }

    /// Wipes all in-memory recovery data (metadata + any transient content) and resets state.
    /// Call on "Clear results" and on app quit.
    public func clear() {
        cancel()
        device = nil
        reader = nil
        files = []
        errors = []
        bytesRead = 0
        startedAt = nil
        finishedAt = nil
        paused = false
        progress = ScanProgress()
        broadcast()
    }

    // MARK: Read-on-demand (previews / export)

    public func readContent(for file: RecoverableFile, maxLength: Int64? = nil) async throws -> SecureData {
        guard let reader else { throw RecoverDError.deviceUnavailable }
        return try await RecoverDEngine.readContent(of: file, from: reader, maxLength: maxLength)
    }

    // MARK: Snapshots for the UI

    public func snapshot() -> ScanResult {
        ScanResult(
            deviceID: device?.id ?? DeviceID(""),
            mode: mode,
            startedAt: startedAt ?? Date(),
            finishedAt: finishedAt,
            files: files,
            bytesScanned: progress.bytesScanned,
            bytesRead: bytesRead,
            errors: errors
        )
    }

    public func currentProgress() -> ScanProgress { progress }

    public func subscribeProgress() -> AsyncStream<ScanProgress> {
        let id = UUID()
        let (stream, cont) = AsyncStream<ScanProgress>.makeStream()
        cont.yield(progress)
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = cont
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast() {
        for cont in subscribers.values {
            cont.yield(progress)
        }
    }

    // MARK: Scan driver

    private func runScan(capture: ScanCapture) async {
        guard let device, let reader else { return }
        do {
            try Task.checkCancellation()

            progress.phase = .parsing
            broadcast()
            if let parser = makeFilesystemParser(for: device, reader: reader) {
                let parsed = try await parser.parse()
                files.append(contentsOf: parsed)
                progress.filesFound = files.count
                broadcast()
            }

            if mode == .deep {
                progress.phase = .carving
                broadcast()
                try await carve(device: device, reader: reader)
            }

            progress.phase = .finalizing
            progress.bytesScanned = device.totalSize
            progress.phase = .complete
            finishedAt = Date()
            broadcast()
        } catch is CancellationError {
            progress.phase = .cancelled
            broadcast()
        } catch {
            errors.append(ScanError(code: "scan", message: String(describing: error)))
            progress.phase = .failed
            broadcast()
        }
        scanTask = nil
    }

    private func carve(device: DeviceInfo, reader: any RawBlockReader) async throws {
        let carver = SignatureFileCarver()
        let total = await reader.totalSize
        let chunkSize = 4 * 1024 * 1024
        let overlap = 64
        var offset: Int64 = 0
        var seenOffsets: Set<Int64> = []

        while offset < total {
            try Task.checkCancellation()
            while paused {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 150_000_000)
            }

            let readCount = Int(min(Int64(chunkSize), total - offset))
            let chunk = try await reader.read(at: offset, count: readCount)
            if chunk.count == 0 { break }
            bytesRead += Int64(chunk.count)

            let base = offset
            chunk.withUnsafeBytes { buf in
                for signature in carver.signatures {
                    var cursor = 0
                    while cursor < buf.count {
                        guard let rel = findMagic(in: buf, magic: signature.magic, from: cursor) else {
                            break
                        }
                        let absolute = base + Int64(rel)
                        if !seenOffsets.contains(absolute) {
                            seenOffsets.insert(absolute)
                            let available = total - absolute
                            let file = carver.makeFile(
                                signature: signature,
                                offset: absolute,
                                availableSize: available,
                                deviceID: device.id
                            )
                            files.append(file)
                            progress.filesFound = files.count
                        }
                        cursor = rel + 1
                    }
                }
            }
            chunk.wipe()

            progress.bytesScanned = min(total, offset + Int64(chunk.count))
            broadcast()

            offset += Int64(chunk.count)
            if offset < total {
                offset -= Int64(overlap)
            }
        }
    }
}

private func findMagic(in buf: UnsafeRawBufferPointer, magic: [UInt8], from start: Int) -> Int? {
    guard !magic.isEmpty, magic.count <= buf.count, start >= 0 else { return nil }
    var i = start
    while i + magic.count <= buf.count {
        var matched = true
        for j in 0..<magic.count {
            if buf[i + j] != magic[j] {
                matched = false
                break
            }
        }
        if matched { return i }
        i += 1
    }
    return nil
}

/// A lightweight, Sendable reference back into the engine used to keep `runScan` decoupled from
/// isolated state during suspension points. Currently a placeholder for future checkpointing of
/// *scan position only* (never content) to support resume across launches.
private struct ScanCapture: Sendable {
    weak var engine: ScanEngine?
    init(engine: ScanEngine) { self.engine = engine }
}
