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
        // Size cap for the ISO-BMFF box walk (falls back if the signature is ever removed).
        let isoMaxSize = carver.signatures.first { $0.container == .isoBMFF }?.maxExpectedSize
            ?? (16 * 1024 * 1024 * 1024)
        let tiffMaxSize = carver.signatures.first { $0.container == .tiff }?.maxExpectedSize
            ?? (128 * 1024 * 1024)

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
            let (hits, riffFiles, isoHits, tiffHits):
                ([(signature: FileSignature, offset: Int64)], [RecoverableFile],
                 [(start: Int64, brand: String)], [(start: Int64, ext: String, name: String)]) =
            chunk.withUnsafeBytes { buf in
                var found: [(FileSignature, Int64)] = []
                var riff: [RecoverableFile] = []
                var iso: [(start: Int64, brand: String)] = []
                var tiff: [(start: Int64, ext: String, name: String)] = []
                for signature in carver.signatures {
                    var cursor = 0
                    while cursor < buf.count {
                        guard let rel = findMagic(in: buf, magic: signature.magic, from: cursor) else {
                            break
                        }
                        cursor = rel + 1
                        let absolute = base + Int64(rel)

                        // Self-describing container (RIFF): parse the header here to size + type it,
                        // and drop hits whose form type we don't recognize (false positives).
                        if signature.container == .riff {
                            // Need the 12-byte header; if it spills past the chunk, the overlap retries.
                            guard rel + 12 <= buf.count else { continue }
                            guard seenOffsets.insert(absolute).inserted else { continue }
                            if let file = parseRIFFFile(in: buf, at: rel, absolute: absolute,
                                                        total: total, signature: signature,
                                                        carver: carver, deviceID: device.id) {
                                riff.append(file)
                            }
                            continue
                        }

                        // ISO-BMFF (MP4/MOV/M4A/HEIC): `ftyp` is 4 bytes into the file, so back up to
                        // the box start. Validate the box size + a printable brand to reject random
                        // "ftyp" bytes; the box chain is walked for the size in the async pass below.
                        if signature.container == .isoBMFF {
                            guard rel >= 4, rel + 8 <= buf.count else { continue }
                            let start = absolute - 4
                            guard seenOffsets.insert(start).inserted else { continue }
                            let boxSize = (UInt32(buf[rel - 4]) << 24) | (UInt32(buf[rel - 3]) << 16)
                                | (UInt32(buf[rel - 2]) << 8) | UInt32(buf[rel - 1])
                            guard boxSize >= 12, boxSize <= 4096 else { continue }
                            let brandBytes = [buf[rel + 4], buf[rel + 5], buf[rel + 6], buf[rel + 7]]
                            guard brandBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
                                  let brand = String(bytes: brandBytes, encoding: .ascii) else { continue }
                            iso.append((start, brand))
                            continue
                        }

                        // TIFF / TIFF-based RAW. Skip the copy embedded in JPEG EXIF (preceded by
                        // "Exif\0\0"), otherwise every photo would yield a bogus image. Label Canon
                        // CR2 (little-endian TIFF with "CR" at offset 8). The IFDs are parsed in the
                        // async pass below to size it and confirm it's a real TIFF (not noise).
                        if signature.container == .tiff {
                            if rel >= 6,
                               buf[rel - 6] == 0x45, buf[rel - 5] == 0x78, buf[rel - 4] == 0x69,
                               buf[rel - 3] == 0x66, buf[rel - 2] == 0x00, buf[rel - 1] == 0x00 {
                                continue // embedded EXIF block, not a standalone file
                            }
                            guard seenOffsets.insert(absolute).inserted else { continue }
                            var ext = signature.fileExtension, name = signature.displayName
                            if signature.magic[0] == 0x49, rel + 10 <= buf.count,
                               buf[rel + 8] == 0x43, buf[rel + 9] == 0x52 { // "CR" ⇒ Canon CR2
                                ext = "cr2"; name = "Canon RAW"
                            }
                            tiff.append((absolute, ext, name))
                            continue
                        }

                        // Validate the byte after the magic when the signature demands it. If the
                        // magic lands at the very end of the chunk the follow byte isn't available
                        // yet — skip without recording it so the next (overlapping) chunk retries.
                        if let followSet = signature.headerFollowSet {
                            let followIdx = rel + signature.magic.count
                            guard followIdx < buf.count else { continue }
                            guard followSet.contains(buf[followIdx]) else { continue }
                        }
                        if seenOffsets.insert(absolute).inserted {
                            found.append((signature, absolute))
                        }
                    }
                }
                return (found, riff, iso, tiff)
            }
            chunk.wipe()

            for file in riffFiles {
                files.append(file)
                progress.filesFound = files.count
            }

            // TIFF/RAW: parse the IFDs to size it and confirm validity; drop noise hits.
            for hit in tiffHits {
                let cap = min(tiffMaxSize, total - hit.start)
                let (size, valid) = try await resolveTIFFSize(start: hit.start, cap: cap, reader: reader)
                guard valid else { continue }
                files.append(carver.makeContainerFile(
                    fileExtension: hit.ext, fileType: .image, displayName: hit.name,
                    offset: hit.start, size: size, confidence: 0.75, deviceID: device.id
                ))
                progress.filesFound = files.count
            }

            // ISO-BMFF: walk the box chain to size each hit, then record it.
            for hit in isoHits {
                let cap = min(isoMaxSize, total - hit.start)
                let (size, hasMoov) = try await walkISOBMFFSize(start: hit.start, cap: cap, reader: reader)
                let form = SignatureFileCarver.isoBMFFType(brand: hit.brand)
                files.append(carver.makeContainerFile(
                    fileExtension: form.fileExtension, fileType: form.fileType,
                    displayName: form.displayName, offset: hit.start, size: size,
                    // No moov ⇒ a fragment or false positive that can't play — flag it low.
                    confidence: hasMoov ? 0.85 : 0.4, deviceID: device.id
                ))
                progress.filesFound = files.count
            }

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

    /// Walks the top-level ISO-BMFF box chain from `start`, summing box sizes until it meets a
    /// 4-byte type that isn't a known box (the end of the file) or hits the size `cap`. Each step
    /// reads only a 16-byte box header and jumps over the (possibly huge) payload, so it's a few
    /// small reads per file. Returns the file length.
    /// Returns the file length and whether a `moov` box was seen. A playable MP4/MOV must have a
    /// `moov` (its sample tables); its absence means an `mdat`-only fragment or a false positive —
    /// useful as a confidence signal.
    private func walkISOBMFFSize(start: Int64, cap: Int64, reader: any RawBlockReader) async throws
        -> (size: Int64, hasMoov: Bool) {
        let known: Set<String> = ["ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "meta",
                                  "mfra", "moof", "sidx", "styp", "pdin", "pnot", "udta"]
        let limit = start + cap
        var pos = start
        var hasMoov = false
        while pos < limit {
            let header = try await reader.read(at: pos, count: 16)
            if header.count < 8 { header.wipe(); break }
            let parsed: (size: Int64, type: String)? = header.withUnsafeBytes { buf in
                let size32 = (UInt32(buf[0]) << 24) | (UInt32(buf[1]) << 16)
                    | (UInt32(buf[2]) << 8) | UInt32(buf[3])
                let type = String(bytes: [buf[4], buf[5], buf[6], buf[7]], encoding: .ascii) ?? ""
                guard known.contains(type) else { return nil } // not a box → end of file
                let boxSize: Int64
                if size32 == 1 {
                    guard buf.count >= 16 else { return nil }
                    var large: UInt64 = 0
                    for i in 8..<16 { large = (large << 8) | UInt64(buf[i]) }
                    boxSize = Int64(bitPattern: large)
                } else if size32 == 0 {
                    boxSize = limit - pos // box runs to EOF
                } else {
                    boxSize = Int64(size32)
                }
                return (boxSize, type)
            }
            header.wipe()
            guard let parsed, parsed.size >= 8 else { break }
            if parsed.type == "moov" { hasMoov = true }
            pos += parsed.size
        }
        return (min(max(pos - start, 0), cap), hasMoov)
    }

    /// Parses the TIFF IFD chain (and SubIFDs) from `start` to find the file's real end and confirm
    /// it's a genuine TIFF — a random `II*\0`/`MM\0*` match yields an implausible IFD and is
    /// rejected (`valid == false`). Sizing follows the strip/tile offset+bytecount tags. Bounded by
    /// `cap`; on anything unparseable it returns `(cap, valid)` so a real-but-odd file isn't lost.
    private func resolveTIFFSize(start: Int64, cap: Int64, reader: any RawBlockReader) async throws
        -> (size: Int64, valid: Bool) {
        func bytes(_ at: Int64, _ n: Int) async throws -> [UInt8] {
            guard n > 0, at >= start, at < start + cap else { return [] }
            let d = try await reader.read(at: at, count: n)
            defer { d.wipe() }
            return d.withUnsafeBytes { Array($0) }
        }
        let header = try await bytes(start, 8)
        guard header.count >= 8 else { return (cap, false) }
        let be: Bool
        if header[0] == 0x4D, header[1] == 0x4D { be = true }
        else if header[0] == 0x49, header[1] == 0x49 { be = false }
        else { return (cap, false) }
        func u16(_ a: [UInt8], _ i: Int) -> Int {
            guard i + 2 <= a.count else { return -1 }
            return be ? (Int(a[i]) << 8 | Int(a[i + 1])) : (Int(a[i + 1]) << 8 | Int(a[i]))
        }
        func u32(_ a: [UInt8], _ i: Int) -> Int64 {
            guard i + 4 <= a.count else { return -1 }
            return be ? (Int64(a[i]) << 24 | Int64(a[i + 1]) << 16 | Int64(a[i + 2]) << 8 | Int64(a[i + 3]))
                      : (Int64(a[i + 3]) << 24 | Int64(a[i + 2]) << 16 | Int64(a[i + 1]) << 8 | Int64(a[i]))
        }
        guard u16(header, 2) == 42 else { return (cap, false) }

        var maxEnd: Int64 = 8
        var queue: [Int64] = [u32(header, 4)]
        var visited = Set<Int64>()
        var validIFD = false
        var guardCount = 0

        while let ifdOff = queue.popLast(), guardCount < 64 {
            guardCount += 1
            guard ifdOff >= 8, ifdOff + 2 <= cap, visited.insert(ifdOff).inserted else { continue }
            let cnt = try await bytes(start + ifdOff, 2)
            let n = u16(cnt, 0)
            guard n >= 1, n <= 4096 else { continue } // implausible entry count ⇒ not a real IFD
            let body = try await bytes(start + ifdOff + 2, n * 12 + 4)
            guard body.count >= n * 12 else { continue }
            validIFD = true
            maxEnd = max(maxEnd, ifdOff + 2 + Int64(n) * 12 + 4)

            var stripOffsets: [Int64] = []
            var stripCounts: [Int64] = []
            var pending: [(tag: Int, type: Int, count: Int, at: Int64)] = []

            func decode(tag: Int, values: [Int64]) {
                switch tag {
                case 273, 324: stripOffsets = values            // Strip/TileOffsets
                case 279, 325: stripCounts = values             // Strip/TileByteCounts
                case 330: queue.append(contentsOf: values)      // SubIFDs
                default: break
                }
            }

            for e in 0..<n {
                let o = e * 12
                let type = u16(body, o + 2), count = Int(u32(body, o + 4))
                let ts = tiffTypeSize(type)
                guard ts > 0, count > 0, count <= 1 << 24 else { continue }
                let dataBytes = Int64(count) * Int64(ts)
                // Any field whose value doesn't fit in the 4-byte entry is stored out-of-line and
                // occupies file space — count it toward the end (covers the strip arrays, ColorMap,
                // ASCII tags, etc., which sips and cameras place after the image data).
                if dataBytes > 4 { maxEnd = max(maxEnd, u32(body, o + 8) + dataBytes) }

                let tag = u16(body, o)
                guard tag == 273 || tag == 324 || tag == 279 || tag == 325 || tag == 330 else { continue }
                if dataBytes <= 4 {
                    let values = (0..<count).map { k -> Int64 in
                        ts == 2 ? Int64(u16(body, o + 8 + k * 2)) : u32(body, o + 8 + k * 4)
                    }
                    decode(tag: tag, values: values)
                } else {
                    pending.append((tag, type, count, start + u32(body, o + 8)))
                }
            }
            if u32(body, n * 12) != 0 { queue.append(u32(body, n * 12)) } // next IFD

            for p in pending {
                let arr = try await bytes(p.at, min(p.count * tiffTypeSize(p.type), 1 << 20))
                let have = arr.count / tiffTypeSize(p.type)
                let values = (0..<min(p.count, have)).map { k -> Int64 in
                    tiffTypeSize(p.type) == 2 ? Int64(u16(arr, k * 2)) : u32(arr, k * 4)
                }
                decode(tag: p.tag, values: values)
            }
            for i in 0..<min(stripOffsets.count, stripCounts.count) {
                maxEnd = max(maxEnd, stripOffsets[i] + stripCounts[i])
            }
        }
        guard validIFD else { return (cap, false) }
        return (min(max(maxEnd, 8), cap), true)
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

/// Parses a RIFF header at `rel` within `buf` (which must hold at least `rel + 12` bytes) into a
/// `RecoverableFile`, or returns nil if the form type isn't recognized (a false positive). The
/// file is sized from the RIFF payload-size field when that value is sane, otherwise capped.
private func parseRIFFFile(in buf: UnsafeRawBufferPointer, at rel: Int, absolute: Int64,
                           total: Int64, signature: FileSignature,
                           carver: SignatureFileCarver, deviceID: DeviceID) -> RecoverableFile? {
    let formBytes = [buf[rel + 8], buf[rel + 9], buf[rel + 10], buf[rel + 11]]
    guard let formString = String(bytes: formBytes, encoding: .ascii),
          let form = SignatureFileCarver.riffForm(formString) else { return nil }

    // Payload size is a little-endian UInt32 at offset 4; the whole file is that + 8 (RIFF header).
    let payload = UInt32(buf[rel + 4]) | (UInt32(buf[rel + 5]) << 8)
        | (UInt32(buf[rel + 6]) << 16) | (UInt32(buf[rel + 7]) << 24)
    let declared = Int64(payload) + 8
    let cap = min(signature.maxExpectedSize, total - absolute)
    let size = (declared >= 16 && declared <= cap) ? declared : cap

    return carver.makeContainerFile(fileExtension: form.fileExtension, fileType: form.fileType,
                                    displayName: form.displayName, offset: absolute, size: size,
                                    deviceID: deviceID)
}

/// Byte size of a TIFF field type (BYTE/ASCII=1, SHORT=2, LONG/IFD=4, RATIONAL/LONG8=8). 0 if
/// unknown. Used to read strip/tile offset & byte-count arrays during TIFF sizing.
private func tiffTypeSize(_ type: Int) -> Int {
    switch type {
    case 1, 2, 6, 7: return 1
    case 3, 8: return 2
    case 4, 9, 11, 13: return 4
    case 5, 10, 12, 16, 17, 18: return 8
    default: return 0
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
