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
            let chunkCount = chunk.count
            if chunkCount == 0 { break }
            bytesRead += Int64(chunkCount)

            // First pass (synchronous, inside the secure buffer): collect confirmed magic hits.
            // We can't resolve footer-bounded sizes here because that needs async reads, so we
            // gather the validated offsets and size them after the buffer access closes.
            let base = offset
            let hits: [(signature: FileSignature, offset: Int64)] = chunk.withUnsafeBytes { buf in
                var found: [(FileSignature, Int64)] = []
                for signature in carver.signatures {
                    var cursor = 0
                    while cursor < buf.count {
                        guard let rel = findMagic(in: buf, magic: signature.magic, from: cursor) else {
                            break
                        }
                        cursor = rel + 1
                        // Validate the byte after the magic when the signature demands it. If the
                        // magic lands at the very end of the chunk the follow byte isn't available
                        // yet — skip without recording it so the next (overlapping) chunk retries.
                        if let followSet = signature.headerFollowSet {
                            let followIdx = rel + signature.magic.count
                            guard followIdx < buf.count else { continue }
                            guard followSet.contains(buf[followIdx]) else { continue }
                        }
                        let absolute = base + Int64(rel)
                        if seenOffsets.insert(absolute).inserted {
                            found.append((signature, absolute))
                        }
                    }
                }
                return found
            }
            chunk.wipe()

            // Second pass: resolve each hit's real size by locating its footer, then record it.
            for hit in hits {
                let (size, footerFound) = try await resolveCarvedSize(
                    signature: hit.signature, start: hit.offset, total: total, reader: reader
                )
                files.append(carver.makeFile(
                    signature: hit.signature,
                    offset: hit.offset,
                    size: size,
                    footerFound: footerFound,
                    deviceID: device.id
                ))
                progress.filesFound = files.count
            }

            progress.bytesScanned = min(total, offset + Int64(chunkCount))
            broadcast()

            offset += Int64(chunkCount)
            if offset < total {
                offset -= Int64(overlap)
            }
        }
    }

    /// Resolves the on-disk length of a carved file starting at `start`.
    ///
    /// When the signature has an end marker we scan forward (bounded by `maxExpectedSize`) for it
    /// and size the file up to and including it. The scan reads through the source's `SecureData`
    /// and wipes each window, so no recovered content lingers. If no marker is found within the
    /// bound — or the signature has none — we fall back to the capped maximum so a real but
    /// unterminated file is still recoverable (ImageIO and friends stop at the real end anyway).
    ///
    /// Returns `(size, footerFound)`.
    private func resolveCarvedSize(
        signature: FileSignature, start: Int64, total: Int64, reader: any RawBlockReader
    ) async throws -> (Int64, Bool) {
        let available = total - start
        let capped = min(signature.maxExpectedSize, max(0, available))
        guard capped > Int64(signature.magic.count) else { return (capped, false) }
        let limit = start + capped

        // JPEG: the trailer `FF D9` also terminates the embedded EXIF thumbnail, so the *first*
        // one would truncate the photo. Depth-count nested SOI/EOI pairs and stop at the outer EOI.
        if signature.footer == [0xFF, 0xD9] {
            if let end = try await findJPEGEnd(start: start, limit: limit, reader: reader) {
                return (min(end - start, capped), true)
            }
            return (capped, false)
        }

        guard let footer = signature.footer else { return (capped, false) }
        if let end = try await findFirstFooter(
            footer: footer, from: start + Int64(signature.magic.count), limit: limit, reader: reader
        ) {
            return (min(end - start, capped), true)
        }
        return (capped, false)
    }

    /// Scans for the outer JPEG `FF D9`, counting nested `FF D8 … FF D9` pairs (EXIF thumbnails)
    /// so the carve isn't cut short at the thumbnail's end. Returns the absolute offset just past
    /// the outer EOI, or nil if the image doesn't terminate within `limit`.
    private func findJPEGEnd(start: Int64, limit: Int64, reader: any RawBlockReader) async throws -> Int64? {
        let window = 1 << 20
        var pos = start + 2 // skip the leading SOI (`FF D8`); the outer image counts as depth 1
        var depth = 1
        while pos < limit {
            let toRead = Int(min(Int64(window), limit - pos))
            if toRead < 2 { break }
            let block = try await reader.read(at: pos, count: toRead)
            let n = block.count
            if n < 2 { block.wipe(); break }
            let end: Int64? = block.withUnsafeBytes { buf in
                var i = 0
                while i + 1 < buf.count {
                    guard buf[i] == 0xFF else { i += 1; continue }
                    switch buf[i + 1] {
                    case 0xD8: depth += 1
                    case 0xD9:
                        depth -= 1
                        if depth == 0 { return pos + Int64(i) + 2 }
                    default: break
                    }
                    i += 2
                }
                return nil
            }
            block.wipe()
            if let end { return end }
            // Re-read the final byte next iteration in case a marker straddles the boundary.
            pos += Int64(max(1, n - 1))
        }
        return nil
    }

    /// Scans forward for the first occurrence of `footer`, returning the absolute offset just past
    /// it, or nil if not found within `limit`. Used for unique terminal markers (PNG IEND, %%EOF).
    private func findFirstFooter(
        footer: [UInt8], from searchStart: Int64, limit: Int64, reader: any RawBlockReader
    ) async throws -> Int64? {
        let window = 1 << 20
        var pos = searchStart
        while pos < limit {
            let toRead = Int(min(Int64(window), limit - pos))
            if toRead < footer.count { break }
            let block = try await reader.read(at: pos, count: toRead)
            let n = block.count
            if n < footer.count { block.wipe(); break }
            let rel = block.withUnsafeBytes { findMagic(in: $0, magic: footer, from: 0) }
            block.wipe()
            if let rel { return pos + Int64(rel) + Int64(footer.count) }
            pos += Int64(max(1, n - (footer.count - 1)))
        }
        return nil
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
