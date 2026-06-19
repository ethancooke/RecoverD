import Foundation
import RecoverDCore

/// exFAT file-system parser (read-only recovery).
///
/// On-disk layout:
///   - Boot Region: 12 sectors at sector 0. The Main Boot Sector (sector 0) holds volume
///     parameters at fixed byte offsets (see `readBootSector`). A backup boot region follows.
///   - FAT Region: at `FatOffset` (sectors); `FatLength` per FAT; `NumberOfFats` (usually 1).
///     The FAT is an array of uint32 cluster entries — cluster N's entry is at byte offset
///     `N * 4` from the FAT start. EOC = 0xFFFFFFF8..0xFFFFFFFF.
///   - Cluster Heap (data region): at `ClusterHeapOffset` (sectors). Cluster N's bytes are at
///     `(ClusterHeapOffset + (N - 2) * SectorsPerCluster) * BytesPerSector`. Clusters are
///     numbered from 2.
///   - Root directory: a cluster chain starting at `FirstClusterOfRootDir`.
///
/// Directory entries are 32 bytes. A file is an "entry set": one File entry (type 0x85, or 0x05
/// when deleted — the InUse bit 0x80 is cleared) followed by `SecondaryCount` secondary
/// entries: exactly one Stream Extension (0x86 / 0x06 deleted) and one or more File Name
/// entries (0x81 / 0x01 deleted, 15 UTF-16 chars each). The name is the concatenation of the
/// File Name entries' characters, truncated to the stream's `NameLength`.
///
/// Recovery:
///   - **Live** files: the FAT chain from `FirstCluster` is walked to build accurate `extents`
///     (one `ByteRange` per cluster, with the final run trimmed to `DataLength`).
///   - **Deleted** files (InUse bit cleared): the stream/name secondaries often survive
///     contiguously, so we recover name, size, and `FirstCluster`. The FAT chain is typically
///     zeroed (freed), so `extents` is nil and we fall back to a contiguous heuristic at the
///     first cluster — content may be partially overwritten; that is inherent to recovery.
///
/// SECURITY: this parser reads only *metadata* (boot sector, FAT, directory entries) into
/// ordinary `Data`/`[UInt8]` held transiently in the actor. File *content* is never read here —
/// it is fetched on demand via `readContent(of:from:)` into `SecureData` at preview/export time.
public struct EXFATParser: FilesystemParser {
    public let displayName = "exFAT"
    private let reader: any RawBlockReader
    private let deviceID: DeviceID

    public init(reader: any RawBlockReader, deviceID: DeviceID) {
        self.reader = reader
        self.deviceID = deviceID
    }

    public func parse() async throws -> [RecoverableFile] {
        let volume = try await readBootSector()
        let fat = try await readFAT(volume: volume)
        var visited: Set<UInt32> = []
        return try await walkDirectory(
            firstCluster: volume.rootCluster,
            parentPath: "",
            volume: volume,
            fat: fat,
            visited: &visited
        )
    }

    // MARK: Boot sector

    private struct Volume {
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        let bytesPerCluster: Int
        let clusterHeapOffsetBytes: Int64
        let fatOffsetBytes: Int64
        let fatLengthBytes: Int
        let rootCluster: UInt32
        let clusterCount: UInt32
    }

    private func readBootSector() async throws -> Volume {
        let sec = try await reader.read(at: 0, count: 512)
        defer { sec.wipe() }
        let bytes = sec.withUnsafeBytes { Array($0) }
        guard bytes.count >= 0x6E + 2 else {
            throw RecoverDError.unsupportedFilesystem("exFAT boot too small")
        }
        guard bytes[0] == 0xEB, bytes[1] == 0x76, bytes[2] == 0x90 else {
            throw RecoverDError.unsupportedFilesystem("not exFAT (jump boot)")
        }
        let fsName = String(bytes: bytes[3..<11], encoding: .ascii) ?? ""
        guard fsName.hasPrefix("EXFAT") else {
            throw RecoverDError.unsupportedFilesystem("not exFAT (fs name)")
        }
        let zeroRegion = Array(bytes[0x0B..<0x40])
        guard zeroRegion.allSatisfy({ $0 == 0 }) else {
            throw RecoverDError.unsupportedFilesystem("exFAT must-be-zero region not zero")
        }
        let fatOffset = readU32LE(bytes, at: 0x50)
        let fatLength = readU32LE(bytes, at: 0x54)
        let clusterHeapOffset = readU32LE(bytes, at: 0x58)
        let clusterCount = readU32LE(bytes, at: 0x5C)
        let rootCluster = readU32LE(bytes, at: 0x60)
        let bytesPerSectorShift = bytes[0x6C]
        let sectorsPerClusterShift = bytes[0x6D]
        guard bytesPerSectorShift <= 12, sectorsPerClusterShift <= 25 else {
            throw RecoverDError.unsupportedFilesystem("exFAT invalid shift field")
        }
        let bytesPerSector = 1 << bytesPerSectorShift
        let sectorsPerCluster = 1 << sectorsPerClusterShift
        return Volume(
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            bytesPerCluster: bytesPerSector * sectorsPerCluster,
            clusterHeapOffsetBytes: Int64(clusterHeapOffset) * Int64(bytesPerSector),
            fatOffsetBytes: Int64(fatOffset) * Int64(bytesPerSector),
            fatLengthBytes: Int(fatLength) * bytesPerSector,
            rootCluster: rootCluster,
            clusterCount: clusterCount
        )
    }

    // MARK: FAT

    private func readFAT(volume: Volume) async throws -> [UInt8] {
        guard volume.fatLengthBytes > 0 else { return [] }
        let fat = try await reader.read(at: volume.fatOffsetBytes, count: volume.fatLengthBytes)
        defer { fat.wipe() }
        return fat.withUnsafeBytes { Array($0) }
    }

    private func fatEntry(_ fat: [UInt8], cluster: UInt32) -> UInt32 {
        let off = Int(cluster) * 4
        guard off >= 0, off + 4 <= fat.count else { return 0 }
        return readU32LE(fat, at: off)
    }

    private func isEOC(_ entry: UInt32) -> Bool { entry >= 0xFFFFFFF8 }

    private func clusterChain(first: UInt32, fat: [UInt8]) -> [UInt32] {
        guard first >= 2, first < 0xFFFFFFF7 else { return [] }
        var chain: [UInt32] = []
        var seen: Set<UInt32> = []
        var cur = first
        while cur >= 2, cur < 0xFFFFFFF7, !isEOC(cur), !seen.contains(cur) {
            chain.append(cur)
            seen.insert(cur)
            cur = fatEntry(fat, cluster: cur)
        }
        return chain
    }

    private func clusterByteOffset(_ cluster: UInt32, volume: Volume) -> Int64 {
        volume.clusterHeapOffsetBytes + Int64(cluster - 2) * Int64(volume.bytesPerCluster)
    }

    // MARK: Directory walk

    private func walkDirectory(
        firstCluster: UInt32,
        parentPath: String,
        volume: Volume,
        fat: [UInt8],
        visited: inout Set<UInt32>
    ) async throws -> [RecoverableFile] {
        guard firstCluster >= 2, firstCluster < 0xFFFFFFF7 else { return [] }
        guard !visited.contains(firstCluster) else { return [] }
        visited.insert(firstCluster)

        let chain = clusterChain(first: firstCluster, fat: fat)
        guard !chain.isEmpty else { return [] }
        let dirBytes = try await readClusters(chain: chain, volume: volume)
        let entryCount = dirBytes.count / 32

        var results: [RecoverableFile] = []
        var i = 0
        while i < entryCount {
            let base = i * 32
            let type = dirBytes[base]
            if type == 0x00 { break } // end-of-directory
            let typeCode = type & 0x7F
            let inUse = (type & 0x80) != 0

            if typeCode == 0x05 { // File entry (0x85 live / 0x05 deleted)
                let secondaryCount = Int(dirBytes[base + 1])
                let fileAttributes = readU16LE(dirBytes, at: base + 0x04)
                let isDirectory = (fileAttributes & 0x10) != 0
                let created = fatTimestampToDate(readU32LE(dirBytes, at: base + 0x08))
                let modified = fatTimestampToDate(readU32LE(dirBytes, at: base + 0x0C))
                let accessed = fatTimestampToDate(readU32LE(dirBytes, at: base + 0x10))

                var streamFirstCluster: UInt32 = 0
                var streamDataLength: Int64 = 0
                var streamNameLength: Int = 0
                var streamNoFatChain = false
                var nameChars: [UInt16] = []
                var consumed = 0

                for s in 0..<secondaryCount {
                    let sIdx = i + 1 + s
                    guard sIdx < entryCount else { break }
                    let sBase = sIdx * 32
                    let secTypeCode = dirBytes[sBase] & 0x7F
                    consumed += 1
                    if secTypeCode == 0x06 { // Stream Extension
                        streamNoFatChain = (dirBytes[sBase + 1] & 0x02) != 0
                        streamNameLength = Int(dirBytes[sBase + 3])
                        streamFirstCluster = readU32LE(dirBytes, at: sBase + 0x14)
                        streamDataLength = Int64(bitPattern: readU64LE(dirBytes, at: sBase + 0x18))
                    } else if secTypeCode == 0x01 { // File Name
                        for c in 0..<15 {
                            let v = readU16LE(dirBytes, at: sBase + 2 + c * 2)
                            if v == 0 { break }
                            nameChars.append(v)
                        }
                    }
                }
                i += 1 + consumed

                let name = decodeUTF16String(nameChars, maxLength: streamNameLength)
                guard !name.isEmpty else { continue }
                let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"

                if isDirectory {
                    if inUse {
                        let sub = try await walkDirectory(
                            firstCluster: streamFirstCluster,
                            parentPath: path,
                            volume: volume,
                            fat: fat,
                            visited: &visited
                        )
                        results.append(contentsOf: sub)
                    }
                    // Deleted directories: not recursed (chain freed); not reported as files.
                } else {
                    results.append(makeFile(
                        name: path,
                        size: streamDataLength,
                        firstCluster: streamFirstCluster,
                        volume: volume,
                        fat: fat,
                        noFatChain: streamNoFatChain,
                        deleted: !inUse,
                        created: created,
                        modified: modified,
                        accessed: accessed
                    ))
                }
            } else {
                // Allocation Bitmap (0x82), Up-case Table (0x83), Volume Label (0x84),
                // Volume GUID (0x87), or unknown — skip a single 32-byte entry.
                i += 1
            }
        }
        return results
    }

    private func makeFile(name: String,
                          size: Int64,
                          firstCluster: UInt32,
                          volume: Volume,
                          fat: [UInt8],
                          noFatChain: Bool,
                          deleted: Bool,
                          created: Date?,
                          modified: Date?,
                          accessed: Date?) -> RecoverableFile {
        let baseOffset = firstCluster >= 2 ? clusterByteOffset(firstCluster, volume: volume) : 0
        var extents: [ByteRange]? = nil

        if !deleted, firstCluster >= 2, size > 0 {
            if noFatChain {
                extents = [ByteRange(offset: baseOffset, length: size)]
            } else {
                let chain = clusterChain(first: firstCluster, fat: fat)
                if !chain.isEmpty {
                    var runs = chain.map {
                        ByteRange(offset: clusterByteOffset($0, volume: volume),
                                  length: Int64(volume.bytesPerCluster))
                    }
                    let total = runs.reduce(Int64(0)) { $0 + $1.length }
                    let overrun = total - size
                    if overrun > 0, let last = runs.last {
                        runs[runs.count - 1] = ByteRange(offset: last.offset,
                                                         length: last.length - overrun)
                    }
                    extents = runs
                }
            }
        }

        return RecoverableFile(
            id: FileID("exfat:\(firstCluster):\(name)"),
            displayName: name,
            originalPath: name,
            fileType: inferFileTypeFromName(name),
            size: size,
            byteOffset: baseOffset,
            allocationStatus: deleted ? .deleted : .live,
            creationDate: created,
            modificationDate: modified,
            deletionDate: deleted ? modified : nil,
            sourceDeviceID: deviceID,
            confidence: deleted ? 0.5 : 0.95,
            signatureMatch: nil,
            extents: extents
        )
    }

    // MARK: Cluster I/O

    private func readClusters(chain: [UInt32], volume: Volume) async throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(chain.count * volume.bytesPerCluster)
        for cluster in chain {
            let off = clusterByteOffset(cluster, volume: volume)
            let chunk = try await reader.read(at: off, count: volume.bytesPerCluster)
            defer { chunk.wipe() }
            out.append(contentsOf: chunk.withUnsafeBytes { Array($0) })
        }
        return out
    }
}
