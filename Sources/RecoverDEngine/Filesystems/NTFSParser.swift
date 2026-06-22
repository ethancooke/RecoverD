import Foundation
import RecoverDCore

/// NTFS file-system parser (read-only recovery).
///
/// NTFS stores everything — including its own metadata — as files described by the **Master File
/// Table** ($MFT), an array of fixed-size records (almost always 1024 bytes). Each record begins
/// with a "FILE" signature and a sequence of *attributes*: `$STANDARD_INFORMATION` (0x10,
/// timestamps), `$FILE_NAME` (0x30, name + parent reference), and `$DATA` (0x80, the content).
///
/// On-disk layout we use:
///   - **Boot sector** (sector 0): OEM "NTFS    " at offset 3, bytes/sector, sectors/cluster,
///     the $MFT's starting cluster (LCN) at 0x30, and the clusters-per-MFT-record code at 0x40.
///   - **$MFT**: located at `mftLCN * bytesPerCluster`. Record 0 *is* the $MFT; its non-resident
///     `$DATA` data runs tell us where every MFT record lives (the table can be fragmented).
///
/// Recovery:
///   - **Live** files: the unnamed `$DATA` attribute's data runs map directly to `extents`
///     (one `ByteRange` per run, final run trimmed to the real data size). Tiny files whose data
///     is *resident* inside the MFT record get a single extent pointing into that record.
///   - **Deleted** files: an MFT record's in-use bit (record flags bit 0) is cleared on delete,
///     but the record — including its data runs — usually survives until the slot is reused, so
///     name, size, timestamps, and `extents` are recovered. Content may be partially overwritten;
///     that is inherent to recovery.
///   - **Compressed / sparse** `$DATA` is flagged low-confidence and left without `extents`
///     (decompression/hole-filling isn't attempted), so we never hand back garbage as if exact.
///
/// SECURITY: this parser reads only *metadata* (boot sector, $MFT records) into ordinary `[UInt8]`
/// held transiently in the actor. File *content* is never read here — it is fetched on demand via
/// `extents` into `SecureData` at preview/export time.
public struct NTFSParser: FilesystemParser {
    public let displayName = "NTFS"
    private let reader: any RawBlockReader
    private let deviceID: DeviceID

    // Guardrails: cap how much of the MFT we'll walk so a hostile/huge volume can't exhaust RAM.
    private let maxRecords = 4_000_000
    private let maxMFTBytes: Int64 = 1 << 30 // 1 GiB of MFT (~1M records at 1 KiB)

    public init(reader: any RawBlockReader, deviceID: DeviceID) {
        self.reader = reader
        self.deviceID = deviceID
    }

    public func parse() async throws -> [RecoverableFile] {
        let boot = try await readBootSector()
        let mftRuns = try await readMFTRuns(boot: boot)
        guard mftRuns.totalLength > 0 else { return [] }

        // Pass 1: parse every MFT record into a lightweight node (no content bytes).
        var nodes: [UInt32: Node] = [:]
        let recordSize = boot.mftRecordSize
        let mftBytes = min(mftRuns.totalLength, maxMFTBytes)
        let recordCount = min(Int(mftBytes / Int64(recordSize)), maxRecords)

        var index = 0
        while index < recordCount {
            try Task.checkCancellation()
            let logicalOffset = Int64(index) * Int64(recordSize)
            guard let raw = try await readMFT(runs: mftRuns, logicalOffset: logicalOffset,
                                              count: recordSize) else { break }
            if let node = parseRecord(raw, index: UInt32(index),
                                      deviceOffset: mftRuns.deviceOffset(forLogical: logicalOffset),
                                      boot: boot) {
                nodes[UInt32(index)] = node
            }
            index += 1
        }

        // Pass 2: resolve full paths and emit files (skip directories + NTFS metafiles).
        var results: [RecoverableFile] = []
        for (_, node) in nodes where !node.isDirectory {
            guard node.index >= 16 else { continue }              // 0..15 are $MFT, $LogFile, …
            guard !node.name.isEmpty, !node.name.hasPrefix("$") else { continue }
            let path = resolvePath(of: node, in: nodes)
            results.append(makeFile(node: node, path: path))
        }
        return results
    }

    // MARK: Boot sector

    private struct Boot {
        let bytesPerSector: Int
        let bytesPerCluster: Int
        let mftRecordSize: Int
        let mftLCN: Int64
    }

    private func readBootSector() async throws -> Boot {
        let sec = try await reader.read(at: 0, count: 512)
        defer { sec.wipe() }
        let b = sec.withUnsafeBytes { Array($0) }
        guard b.count >= 0x54 else {
            throw RecoverDError.unsupportedFilesystem("NTFS boot too small")
        }
        guard let oem = String(bytes: b[3..<11], encoding: .ascii), oem == "NTFS    " else {
            throw RecoverDError.unsupportedFilesystem("not NTFS (OEM id)")
        }
        let bytesPerSector = Int(readU16LE(b, at: 0x0B))
        let sectorsPerCluster = decodeClusterFactor(b[0x0D])
        guard [256, 512, 1024, 2048, 4096].contains(bytesPerSector), sectorsPerCluster > 0 else {
            throw RecoverDError.unsupportedFilesystem("NTFS implausible geometry")
        }
        let bytesPerCluster = bytesPerSector * sectorsPerCluster
        let mftLCN = Int64(bitPattern: readU64LE(b, at: 0x30))
        let recordSize = decodeSizeFactor(b[0x40], bytesPerCluster: bytesPerCluster)
        guard recordSize >= 256, recordSize <= 65536, mftLCN > 0 else {
            throw RecoverDError.unsupportedFilesystem("NTFS bad MFT record size / LCN")
        }
        return Boot(bytesPerSector: bytesPerSector, bytesPerCluster: bytesPerCluster,
                    mftRecordSize: recordSize, mftLCN: mftLCN)
    }

    /// Sectors-per-cluster / index size fields are a power-of-two count, but a value > 0x80 is
    /// a negative log2 byte size (e.g. 0xF6 => 2^10 = 1024). NTFS uses this for both fields.
    private func decodeClusterFactor(_ v: UInt8) -> Int {
        v <= 0x80 ? Int(v) : 1 << (256 - Int(v))
    }
    private func decodeSizeFactor(_ v: UInt8, bytesPerCluster: Int) -> Int {
        let s = Int8(bitPattern: v)
        return s >= 0 ? Int(s) * bytesPerCluster : 1 << (-Int(s))
    }

    // MARK: $MFT location

    /// The runs (in device bytes) holding the MFT, plus a logical→device mapping.
    private struct MFTRuns {
        let runs: [ByteRange]       // device-byte ranges, in logical order
        let cumulative: [Int64]     // cumulative logical start of each run
        let totalLength: Int64

        func deviceOffset(forLogical offset: Int64) -> Int64 {
            for (i, run) in runs.enumerated() {
                let start = cumulative[i]
                if offset >= start, offset < start + run.length {
                    return run.offset + (offset - start)
                }
            }
            return runs.first?.offset ?? 0
        }
    }

    private func readMFTRuns(boot: Boot) async throws -> MFTRuns {
        let mftByteOffset = boot.mftLCN * Int64(boot.bytesPerCluster)
        let rec = try await reader.read(at: mftByteOffset, count: boot.mftRecordSize)
        defer { rec.wipe() }
        var bytes = rec.withUnsafeBytes { Array($0) }
        guard applyFixups(&bytes, boot: boot) else {
            throw RecoverDError.unsupportedFilesystem("NTFS $MFT record 0 unreadable")
        }
        guard let data = unnamedDataAttribute(bytes, boot: boot), let runs = data.extents,
              !runs.isEmpty else {
            throw RecoverDError.unsupportedFilesystem("NTFS $MFT has no data runs")
        }
        var cumulative: [Int64] = []
        var acc: Int64 = 0
        for run in runs { cumulative.append(acc); acc += run.length }
        return MFTRuns(runs: runs, cumulative: cumulative, totalLength: acc)
    }

    private func readMFT(runs: MFTRuns, logicalOffset: Int64, count: Int) async throws -> [UInt8]? {
        guard logicalOffset + Int64(count) <= runs.totalLength else { return nil }
        // A record almost always sits inside one run; handle the rare straddle by stitching.
        var out = [UInt8]()
        out.reserveCapacity(count)
        var remaining = count
        var logical = logicalOffset
        while remaining > 0 {
            let devOff = runs.deviceOffset(forLogical: logical)
            // How many bytes are left in the run that contains `logical`.
            var inRun = remaining
            for (i, run) in runs.runs.enumerated() {
                let start = runs.cumulative[i]
                if logical >= start, logical < start + run.length {
                    inRun = min(remaining, Int(start + run.length - logical)); break
                }
            }
            let chunk = try await reader.read(at: devOff, count: inRun)
            defer { chunk.wipe() }
            out.append(contentsOf: chunk.withUnsafeBytes { Array($0) })
            remaining -= inRun
            logical += Int64(inRun)
        }
        return out
    }

    // MARK: Record parsing

    private struct Node {
        let index: UInt32
        var name: String
        var parentIndex: UInt32
        var isDirectory: Bool
        var deleted: Bool
        var size: Int64
        var extents: [ByteRange]?
        var reliable: Bool          // false for compressed/sparse $DATA
        var created: Date?
        var modified: Date?
        var accessed: Date?
    }

    private func parseRecord(_ raw: [UInt8], index: UInt32, deviceOffset: Int64,
                             boot: Boot) -> Node? {
        var bytes = raw
        guard bytes.count >= 0x30,
              bytes[0] == 0x46, bytes[1] == 0x49, bytes[2] == 0x4C, bytes[3] == 0x45, // "FILE"
              applyFixups(&bytes, boot: boot) else { return nil }

        let flags = readU16LE(bytes, at: 0x16)
        let inUse = (flags & 0x01) != 0
        let isDir = (flags & 0x02) != 0
        let baseRef = readU64LE(bytes, at: 0x20) & 0x0000_FFFF_FFFF_FFFF
        guard baseRef == 0 else { return nil } // extension record; attrs belong to its base

        var node = Node(index: index, name: "", parentIndex: 5, isDirectory: isDir,
                        deleted: !inUse, size: 0, extents: nil, reliable: true,
                        created: nil, modified: nil, accessed: nil)
        var bestNameRank = -1

        var off = Int(readU16LE(bytes, at: 0x14))
        while off >= 0, off + 16 <= bytes.count {
            let type = readU32LE(bytes, at: off)
            if type == 0xFFFF_FFFF { break }
            let len = Int(readU32LE(bytes, at: off + 4))
            if len <= 0 || off + len > bytes.count { break }
            let nonResident = bytes[off + 8] != 0
            let nameLen = Int(bytes[off + 9])
            let contentOffset = Int(readU16LE(bytes, at: off + 0x14))

            switch type {
            case 0x10 where !nonResident: // $STANDARD_INFORMATION
                let c = off + contentOffset
                if c + 0x20 <= bytes.count {
                    node.created = filetimeToDate(readU64LE(bytes, at: c + 0x00))
                    node.modified = filetimeToDate(readU64LE(bytes, at: c + 0x08))
                    node.accessed = filetimeToDate(readU64LE(bytes, at: c + 0x18))
                }
            case 0x30 where !nonResident: // $FILE_NAME
                let c = off + contentOffset
                if c + 0x42 <= bytes.count {
                    let parent = UInt32(readU64LE(bytes, at: c) & 0x0000_FFFF_FFFF)
                    let fnameLen = Int(bytes[c + 0x40])
                    let namespace = bytes[c + 0x41]
                    let rank = nameRank(namespace)
                    if rank > bestNameRank, c + 0x42 + fnameLen * 2 <= bytes.count {
                        var units = [UInt16]()
                        for i in 0..<fnameLen { units.append(readU16LE(bytes, at: c + 0x42 + i * 2)) }
                        node.name = String(decoding: units, as: UTF16.self)
                        node.parentIndex = parent
                        bestNameRank = rank
                    }
                }
            case 0x80 where nameLen == 0: // unnamed $DATA
                let attrFlags = readU16LE(bytes, at: off + 0x0C)
                let compressedOrSparse = (attrFlags & 0xC0FF) != 0 // compressed | sparse | encrypted
                if nonResident {
                    let realSize = Int64(bitPattern: readU64LE(bytes, at: off + 0x30))
                    let runsOffset = Int(readU16LE(bytes, at: off + 0x20))
                    node.size = realSize
                    if compressedOrSparse {
                        node.reliable = false
                    } else {
                        node.extents = trim(decodeDataRuns(bytes, start: off + runsOffset,
                                                           bytesPerCluster: boot.bytesPerCluster),
                                            to: realSize)
                    }
                } else {
                    let contentLen = Int64(readU32LE(bytes, at: off + 0x10))
                    node.size = contentLen
                    if contentLen > 0 {
                        node.extents = [ByteRange(offset: deviceOffset + Int64(off + contentOffset),
                                                  length: contentLen)]
                    }
                }
            default:
                break
            }
            off += len
        }
        return node
    }

    /// Prefer Win32 / Win32+DOS names over POSIX over DOS-only (8.3).
    private func nameRank(_ namespace: UInt8) -> Int {
        switch namespace {
        case 1, 3: return 3   // Win32, Win32&DOS
        case 0:    return 2   // POSIX
        case 2:    return 1   // DOS (8.3)
        default:   return 0
        }
    }

    // MARK: Fixups (update sequence array)

    /// NTFS stores the last two bytes of every 512-byte stride as a copy of the record's update
    /// sequence number; the originals live in the update sequence array. Restore them before
    /// reading attribute data that spans a stride boundary. Returns false if the record is torn.
    private func applyFixups(_ bytes: inout [UInt8], boot: Boot) -> Bool {
        guard bytes.count >= 8 else { return false }
        let usaOffset = Int(readU16LE(bytes, at: 0x04))
        let usaCount = Int(readU16LE(bytes, at: 0x06))
        guard usaCount >= 1, usaOffset + usaCount * 2 <= bytes.count else { return false }
        let usn0 = readU16LE(bytes, at: usaOffset)
        let stride = 512
        for i in 1..<usaCount {
            let pos = i * stride - 2
            guard pos + 2 <= bytes.count else { break }
            guard readU16LE(bytes, at: pos) == usn0 else { return false } // torn write
            let orig = readU16LE(bytes, at: usaOffset + i * 2)
            bytes[pos] = UInt8(orig & 0xFF)
            bytes[pos + 1] = UInt8(orig >> 8)
        }
        return true
    }

    // MARK: Attributes / data runs

    private struct DataAttr { let size: Int64; let extents: [ByteRange]? }

    /// Walks a (fixed-up) record for its unnamed non-resident $DATA — used only for $MFT itself.
    private func unnamedDataAttribute(_ bytes: [UInt8], boot: Boot) -> DataAttr? {
        var off = Int(readU16LE(bytes, at: 0x14))
        while off >= 0, off + 16 <= bytes.count {
            let type = readU32LE(bytes, at: off)
            if type == 0xFFFF_FFFF { break }
            let len = Int(readU32LE(bytes, at: off + 4))
            if len <= 0 || off + len > bytes.count { break }
            if type == 0x80, bytes[off + 9] == 0, bytes[off + 8] != 0 {
                let realSize = Int64(bitPattern: readU64LE(bytes, at: off + 0x30))
                let runsOffset = Int(readU16LE(bytes, at: off + 0x20))
                let runs = decodeDataRuns(bytes, start: off + runsOffset,
                                          bytesPerCluster: boot.bytesPerCluster)
                return DataAttr(size: realSize, extents: runs)
            }
            off += len
        }
        return nil
    }

    /// Decodes NTFS data runs into device-byte ranges. Each run: a header byte whose low nibble
    /// is the run-length field width and high nibble is the LCN-offset field width; the LCN offset
    /// is signed and relative to the previous run. A zero offset width = a sparse hole (skipped).
    private func decodeDataRuns(_ b: [UInt8], start: Int, bytesPerCluster: Int) -> [ByteRange] {
        var runs: [ByteRange] = []
        var i = start
        var lcn: Int64 = 0
        while i < b.count {
            let header = b[i]; i += 1
            if header == 0 { break }
            let lenW = Int(header & 0x0F)
            let offW = Int(header >> 4)
            guard lenW > 0, i + lenW + offW <= b.count else { break }
            let runLen = Int64(bitPattern: readUIntLE(b, i, lenW)); i += lenW
            if offW == 0 {
                // Sparse run (hole): no LCN. We can't represent a zero-fill range, so skip it.
            } else {
                lcn += readSIntLE(b, i, offW)
                if lcn > 0, runLen > 0 {
                    runs.append(ByteRange(offset: lcn * Int64(bytesPerCluster),
                                          length: runLen * Int64(bytesPerCluster)))
                }
            }
            i += offW
        }
        return runs
    }

    private func trim(_ extents: [ByteRange], to size: Int64) -> [ByteRange]? {
        guard size > 0, !extents.isEmpty else { return extents.isEmpty ? nil : extents }
        var out: [ByteRange] = []
        var remaining = size
        for run in extents {
            if remaining <= 0 { break }
            let take = min(run.length, remaining)
            out.append(ByteRange(offset: run.offset, length: take))
            remaining -= take
        }
        return out.isEmpty ? nil : out
    }

    private func readUIntLE(_ b: [UInt8], _ off: Int, _ width: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<width where off + i < b.count { v |= UInt64(b[off + i]) << (8 * i) }
        return v
    }
    private func readSIntLE(_ b: [UInt8], _ off: Int, _ width: Int) -> Int64 {
        let u = readUIntLE(b, off, width)
        let signBit: UInt64 = 1 << (8 * width - 1)
        if width < 8, (u & signBit) != 0 {
            return Int64(bitPattern: u | ~((1 << (8 * width)) - 1))
        }
        return Int64(bitPattern: u)
    }

    // MARK: Path + file assembly

    private func resolvePath(of node: Node, in nodes: [UInt32: Node]) -> String {
        var components = [node.name]
        var parent = node.parentIndex
        var guardSet: Set<UInt32> = [node.index]
        var depth = 0
        while parent != 5, depth < 128, !guardSet.contains(parent), let p = nodes[parent] {
            guardSet.insert(parent)
            if !p.name.isEmpty, !p.name.hasPrefix("$") { components.insert(p.name, at: 0) }
            parent = p.parentIndex
            depth += 1
        }
        return components.joined(separator: "/")
    }

    private func makeFile(node: Node, path: String) -> RecoverableFile {
        let confidence: Double
        if !node.reliable { confidence = 0.3 }
        else if node.deleted { confidence = 0.5 }
        else { confidence = 0.9 }
        return RecoverableFile(
            id: FileID("ntfs:\(node.index):\(path)"),
            displayName: path.isEmpty ? node.name : path,
            originalPath: path,
            fileType: inferFileTypeFromName(node.name),
            size: node.size,
            byteOffset: node.extents?.first?.offset ?? 0,
            allocationStatus: node.deleted ? .deleted : .live,
            creationDate: node.created,
            modificationDate: node.modified,
            deletionDate: node.deleted ? node.modified : nil,
            sourceDeviceID: deviceID,
            confidence: confidence,
            signatureMatch: nil,
            extents: node.extents
        )
    }
}
