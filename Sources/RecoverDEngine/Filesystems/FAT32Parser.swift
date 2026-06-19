import Foundation
import RecoverDCore

/// FAT12/16/32 file-system parser (read-only recovery).
///
/// Despite the name, this parser handles all three FAT variants. They share the same directory
/// entry format (8.3 + LFN) and differ only in: FAT entry width (12/16/32 bits), root directory
/// location (fixed region for FAT12/16 vs cluster chain for FAT32), and EOC threshold.
///
/// On-disk layout:
///   - Boot Sector (sector 0): BIOS Parameter Block (BPB) with volume parameters.
///   - Reserved Region: `reservedSectorCount` sectors starting at sector 0.
///   - FAT Region: `numFATs` copies, each `fatSize` sectors, starting at sector `reservedSectorCount`.
///   - Root Directory Region (FAT12/16 only): `rootEntryCount * 32` bytes immediately after the
///     FAT region. For FAT32, the root directory is a cluster chain starting at `rootCluster`.
///   - Data Region (cluster heap): starts after the root dir region (FAT12/16) or after the FAT
///     region (FAT32). Cluster N's bytes are at `dataRegionOffset + (N - 2) * bytesPerCluster`.
///
/// Directory entries are 32 bytes:
///   - 8.3 entry: name (8) + ext (3) + attr (1) + NTCaseInfo (1) + createdTimeTenth (1) +
///     createdTime (2) + createdDate (2) + accessedDate (2) + firstClusterHigh (2) +
///     writeTime (2) + writeDate (2) + firstClusterLow (2) + fileSize (4).
///   - LFN entry (attr == 0x0F): ordinal (1) + nameChars1-5 (10) + attr (1) + type (1) +
///     checksum (1) + nameChars6-11 (10) + firstClusterZero (2) + nameChars12-13 (4).
///
/// LFN entries precede their 8.3 entry in reverse ordinal order. The entry with the highest
/// ordinal has bit 0x40 set. The name is the concatenation of chars from ordinal 1 → N.
///
/// Recovery:
///   - **Live** files: the FAT chain from `firstCluster` is walked to build accurate `extents`.
///   - **Deleted** files (first byte 0xE5): the first character of the 8.3 name is lost. The
///     first cluster and size usually survive in the 8.3 entry, but the FAT chain is freed
///     (entry = 0), so `extents` is nil and we fall back to a contiguous heuristic.
///
/// SECURITY: reads only metadata (boot sector, FAT, directory entries) into transient buffers.
/// File *content* is never read here — it is fetched on demand at preview/export via
/// `readContent(of:from:)` into `SecureData`.
public struct FAT32Parser: FilesystemParser {
    public let displayName = "FAT32"
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
        return try await walkRootDirectory(volume: volume, fat: fat, visited: &visited)
    }

    // MARK: FAT type

    private enum FATType {
        case fat12, fat16, fat32

        var eocThreshold: UInt32 {
            switch self {
            case .fat12: 0x0FF8
            case .fat16: 0xFFF8
            case .fat32: 0x0FFFFFF8
            }
        }

        var entryMask: UInt32 {
            switch self {
            case .fat12: 0x0FFF
            case .fat16: 0xFFFF
            case .fat32: 0x0FFFFFFF
            }
        }
    }

    // MARK: Volume (BPB)

    private struct Volume {
        let fatType: FATType
        let bytesPerSector: Int
        let sectorsPerCluster: Int
        let bytesPerCluster: Int
        let reservedSectors: Int
        let numFATs: Int
        let fatSizeSectors: Int
        let rootEntryCount: Int
        let rootDirByteOffset: Int64
        let rootDirByteSize: Int
        let dataRegionByteOffset: Int64
        let rootFirstCluster: UInt32
        let isFAT32: Bool
    }

    private func readBootSector() async throws -> Volume {
        let sec = try await reader.read(at: 0, count: 512)
        defer { sec.wipe() }
        let b = sec.withUnsafeBytes { Array($0) }
        guard b.count >= 512 else {
            throw RecoverDError.unsupportedFilesystem("FAT boot too small")
        }
        guard b[0] == 0xEB || b[0] == 0xE9 else {
            throw RecoverDError.unsupportedFilesystem("not FAT (jump boot)")
        }

        let bytesPerSector = Int(readU16LE(b, at: 0x0B))
        let sectorsPerCluster = Int(b[0x0D])
        let reservedSectors = Int(readU16LE(b, at: 0x0E))
        let numFATs = Int(b[0x10])
        let rootEntryCount = Int(readU16LE(b, at: 0x11))
        let totalSectors16 = Int(readU16LE(b, at: 0x13))
        let fatSize16 = Int(readU16LE(b, at: 0x16))
        let totalSectors32 = Int(readU32LE(b, at: 0x20))

        guard bytesPerSector > 0, sectorsPerCluster > 0, reservedSectors > 0, numFATs > 0 else {
            throw RecoverDError.unsupportedFilesystem("FAT invalid BPB")
        }

        let totalSectors = totalSectors16 > 0 ? totalSectors16 : totalSectors32
        let isFAT32 = fatSize16 == 0

        let fatSizeSectors: Int
        let rootFirstCluster: UInt32
        if isFAT32 {
            fatSizeSectors = Int(readU32LE(b, at: 0x24))
            rootFirstCluster = readU32LE(b, at: 0x2C)
        } else {
            fatSizeSectors = fatSize16
            rootFirstCluster = 0
        }
        guard fatSizeSectors > 0 else {
            throw RecoverDError.unsupportedFilesystem("FAT invalid FAT size")
        }

        let bytesPerCluster = bytesPerSector * sectorsPerCluster
        let fatRegionSectors = reservedSectors + numFATs * fatSizeSectors
        let rootDirSectors = isFAT32 ? 0 : (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector
        let dataRegionSectors = fatRegionSectors + rootDirSectors
        let dataSectors = totalSectors - dataRegionSectors
        let clusterCount = dataSectors / sectorsPerCluster

        let rootDirByteOffset: Int64
        let rootDirByteSize: Int
        if isFAT32 {
            rootDirByteOffset = 0
            rootDirByteSize = 0
        } else {
            rootDirByteOffset = Int64(fatRegionSectors) * Int64(bytesPerSector)
            rootDirByteSize = rootEntryCount * 32
        }

        let dataRegionByteOffset = Int64(dataRegionSectors) * Int64(bytesPerSector)

        let fatType = determineFATType(b: b, isFAT32: isFAT32, clusterCount: clusterCount)

        return Volume(
            fatType: fatType,
            bytesPerSector: bytesPerSector,
            sectorsPerCluster: sectorsPerCluster,
            bytesPerCluster: bytesPerCluster,
            reservedSectors: reservedSectors,
            numFATs: numFATs,
            fatSizeSectors: fatSizeSectors,
            rootEntryCount: rootEntryCount,
            rootDirByteOffset: rootDirByteOffset,
            rootDirByteSize: rootDirByteSize,
            dataRegionByteOffset: dataRegionByteOffset,
            rootFirstCluster: rootFirstCluster,
            isFAT32: isFAT32
        )
    }

    private func determineFATType(b: [UInt8], isFAT32: Bool, clusterCount: Int) -> FATType {
        let labelOffset = isFAT32 ? 0x52 : 0x36
        if labelOffset + 8 <= b.count {
            let label = String(bytes: b[labelOffset..<labelOffset + 8], encoding: .ascii) ?? ""
            if label.hasPrefix("FAT32") { return .fat32 }
            if label.hasPrefix("FAT16") { return .fat16 }
            if label.hasPrefix("FAT12") { return .fat12 }
        }
        if clusterCount < 4085 { return .fat12 }
        if clusterCount < 65525 { return .fat16 }
        return .fat32
    }

    // MARK: FAT

    private func readFAT(volume: Volume) async throws -> [UInt8] {
        let fatBytes = volume.fatSizeSectors * volume.bytesPerSector
        let fatOffset = Int64(volume.reservedSectors) * Int64(volume.bytesPerSector)
        let fat = try await reader.read(at: fatOffset, count: fatBytes)
        defer { fat.wipe() }
        return fat.withUnsafeBytes { Array($0) }
    }

    private func fatEntry(_ fat: [UInt8], cluster: UInt32, type: FATType) -> UInt32 {
        switch type {
        case .fat12:
            let off = Int(cluster) * 3 / 2
            guard off + 1 < fat.count else { return 0 }
            let lo = UInt32(fat[off])
            let hi = UInt32(fat[off + 1])
            return (cluster & 1 == 0) ? (lo | ((hi & 0x0F) << 8)) : ((lo >> 4) | (hi << 4))
        case .fat16:
            let off = Int(cluster) * 2
            guard off + 2 <= fat.count else { return 0 }
            return UInt32(readU16LE(fat, at: off))
        case .fat32:
            let off = Int(cluster) * 4
            guard off + 4 <= fat.count else { return 0 }
            return readU32LE(fat, at: off) & type.entryMask
        }
    }

    private func isEOC(_ entry: UInt32, type: FATType) -> Bool { entry >= type.eocThreshold }

    private func clusterChain(first: UInt32, fat: [UInt8], type: FATType) -> [UInt32] {
        guard first >= 2, first < type.eocThreshold else { return [] }
        var chain: [UInt32] = []
        var seen: Set<UInt32> = []
        var cur = first
        while cur >= 2, cur < type.eocThreshold, !isEOC(cur, type: type), !seen.contains(cur) {
            chain.append(cur)
            seen.insert(cur)
            cur = fatEntry(fat, cluster: cur, type: type) & type.entryMask
        }
        return chain
    }

    private func clusterByteOffset(_ cluster: UInt32, volume: Volume) -> Int64 {
        volume.dataRegionByteOffset + Int64(cluster - 2) * Int64(volume.bytesPerCluster)
    }

    // MARK: Directory walk

    private func walkRootDirectory(volume: Volume, fat: [UInt8],
                                   visited: inout Set<UInt32>) async throws -> [RecoverableFile] {
        if volume.isFAT32 {
            guard volume.rootFirstCluster >= 2 else { return [] }
            let chain = clusterChain(first: volume.rootFirstCluster, fat: fat, type: volume.fatType)
            let bytes = try await readClusters(chain: chain, volume: volume)
            return try await walkDirectoryEntries(
                bytes: bytes, firstCluster: volume.rootFirstCluster,
                parentPath: "", volume: volume, fat: fat, visited: &visited
            )
        } else {
            guard volume.rootDirByteSize > 0 else { return [] }
            let chunk = try await reader.read(at: volume.rootDirByteOffset, count: volume.rootDirByteSize)
            defer { chunk.wipe() }
            let bytes = chunk.withUnsafeBytes { Array($0) }
            return try await walkDirectoryEntries(
                bytes: bytes, firstCluster: 0,
                parentPath: "", volume: volume, fat: fat, visited: &visited
            )
        }
    }

    private func walkDirectoryEntries(
        bytes: [UInt8],
        firstCluster: UInt32,
        parentPath: String,
        volume: Volume,
        fat: [UInt8],
        visited: inout Set<UInt32>
    ) async throws -> [RecoverableFile] {
        if firstCluster >= 2 {
            guard !visited.contains(firstCluster) else { return [] }
            visited.insert(firstCluster)
        }

        let entryCount = bytes.count / 32
        var results: [RecoverableFile] = []
        var pendingLFNs: [LFNEntry] = []

        var i = 0
        while i < entryCount {
            let base = i * 32
            let firstByte = bytes[base]
            if firstByte == 0x00 { break }

            let attr = bytes[base + 0x0B]
            if attr == 0x0F {
                let lfn = parseLFNEntry(bytes, at: base)
                if firstByte != 0xE5 { pendingLFNs.append(lfn) }
                else { pendingLFNs.append(lfn) }
                i += 1
                continue
            }

            if firstByte == 0xE5 {
                let result = try await processDeletedEntry(
                    bytes: bytes, at: base, pendingLFNs: pendingLFNs,
                    parentPath: parentPath, volume: volume, fat: fat
                )
                if let result { results.append(result) }
                pendingLFNs.removeAll()
                i += 1
                continue
            }

            let nameBytes = Array(bytes[base..<base + 11])
            if isDotOrDotDot(nameBytes) || isVolumeLabel(attr) {
                pendingLFNs.removeAll()
                i += 1
                continue
            }

            let attrFlags = bytes[base + 0x0B]
            let isDirectory = (attrFlags & 0x10) != 0
            let firstCluster = (UInt32(readU16LE(bytes, at: base + 0x14)) << 16)
                | UInt32(readU16LE(bytes, at: base + 0x1A))

            if isDirectory {
                let shortName = formatShortName(bytes: nameBytes, deleted: false,
                                                ntCaseInfo: bytes[base + 0x0C])
                var dirName = shortName
                if !pendingLFNs.isEmpty {
                    let checksum = lfnChecksum(bytes: nameBytes)
                    if pendingLFNs.allSatisfy({ $0.checksum == checksum }) {
                        dirName = reconstructLFN(pendingLFNs)
                    }
                }
                let dirPath = parentPath.isEmpty ? dirName : "\(parentPath)/\(dirName)"
                if firstCluster >= 2 {
                    let chain = clusterChain(first: firstCluster, fat: fat, type: volume.fatType)
                    if !chain.isEmpty {
                        let subBytes = try await readClusters(chain: chain, volume: volume)
                        let sub = try await walkDirectoryEntries(
                            bytes: subBytes, firstCluster: firstCluster,
                            parentPath: dirPath, volume: volume, fat: fat, visited: &visited
                        )
                        results.append(contentsOf: sub)
                    }
                }
                pendingLFNs.removeAll()
                i += 1
                continue
            }

            let result = try await processLiveFileEntry(
                bytes: bytes, at: base, pendingLFNs: pendingLFNs,
                parentPath: parentPath, volume: volume, fat: fat
            )
            if let result { results.append(result) }
            pendingLFNs.removeAll()
            i += 1
        }
        return results
    }

    private func processLiveFileEntry(
        bytes: [UInt8], at base: Int, pendingLFNs: [LFNEntry],
        parentPath: String, volume: Volume, fat: [UInt8]
    ) async throws -> RecoverableFile? {
        let firstCluster = (UInt32(readU16LE(bytes, at: base + 0x14)) << 16)
            | UInt32(readU16LE(bytes, at: base + 0x1A))
        let size = Int64(readU32LE(bytes, at: base + 0x1C))
        let ntCaseInfo = bytes[base + 0x0C]
        let writeTime = readU16LE(bytes, at: base + 0x16)
        let writeDate = readU16LE(bytes, at: base + 0x18)
        let createdTime = readU16LE(bytes, at: base + 0x0E)
        let createdDate = readU16LE(bytes, at: base + 0x10)
        let accessedDate = readU16LE(bytes, at: base + 0x12)

        let shortName = formatShortName(bytes: Array(bytes[base..<base + 11]),
                                        deleted: false, ntCaseInfo: ntCaseInfo)
        var name = shortName
        if !pendingLFNs.isEmpty {
            let checksum = lfnChecksum(bytes: Array(bytes[base..<base + 11]))
            if pendingLFNs.allSatisfy({ $0.checksum == checksum }) {
                name = reconstructLFN(pendingLFNs)
            }
        }

        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"
        guard size > 0, firstCluster >= 2 else { return nil }

        return makeFile(
            name: path, size: size, firstCluster: firstCluster,
            volume: volume, fat: fat, deleted: false,
            created: fatDateTimeToDate(date: createdDate, time: createdTime),
            modified: fatDateTimeToDate(date: writeDate, time: writeTime),
            accessed: fatDateTimeToDate(date: accessedDate, time: 0)
        )
    }

    private func processDeletedEntry(
        bytes: [UInt8], at base: Int, pendingLFNs: [LFNEntry],
        parentPath: String, volume: Volume, fat: [UInt8]
    ) async throws -> RecoverableFile? {
        let attr = bytes[base + 0x0B]
        let isDirectory = (attr & 0x10) != 0
        let firstCluster = (UInt32(readU16LE(bytes, at: base + 0x14)) << 16)
            | UInt32(readU16LE(bytes, at: base + 0x1A))
        let size = Int64(readU32LE(bytes, at: base + 0x1C))
        let writeTime = readU16LE(bytes, at: base + 0x16)
        let writeDate = readU16LE(bytes, at: base + 0x18)

        let shortName = formatShortName(bytes: Array(bytes[base..<base + 11]),
                                        deleted: true, ntCaseInfo: 0)
        var name = shortName
        if !pendingLFNs.isEmpty {
            let bestEffort = reconstructLFN(pendingLFNs)
            if !bestEffort.isEmpty { name = bestEffort }
        }

        let path = parentPath.isEmpty ? name : "\(parentPath)/\(name)"

        if isDirectory { return nil }

        guard size > 0, firstCluster >= 2 else { return nil }

        return makeFile(
            name: path, size: size, firstCluster: firstCluster,
            volume: volume, fat: fat, deleted: true,
            created: nil,
            modified: fatDateTimeToDate(date: writeDate, time: writeTime),
            accessed: nil
        )
    }

    private func makeFile(name: String, size: Int64, firstCluster: UInt32,
                          volume: Volume, fat: [UInt8], deleted: Bool,
                          created: Date?, modified: Date?, accessed: Date?) -> RecoverableFile {
        let baseOffset = firstCluster >= 2 ? clusterByteOffset(firstCluster, volume: volume) : 0
        var extents: [ByteRange]? = nil

        if !deleted, firstCluster >= 2, size > 0 {
            let chain = clusterChain(first: firstCluster, fat: fat, type: volume.fatType)
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

        return RecoverableFile(
            id: FileID("fat:\(firstCluster):\(name)"),
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

    // MARK: 8.3 name formatting

    private func formatShortName(bytes: [UInt8], deleted: Bool, ntCaseInfo: UInt8) -> String {
        guard bytes.count >= 11 else { return "" }
        var nameBytes = Array(bytes[0..<8])
        let extBytes = Array(bytes[8..<11])

        if deleted {
            nameBytes[0] = 0x5F // '_' — first char lost
        } else if nameBytes[0] == 0x05 {
            nameBytes[0] = 0xE5 // Kanji 0xE5 escape
        }

        let lowerName = (ntCaseInfo & 0x08) != 0
        let lowerExt = (ntCaseInfo & 0x10) != 0

        var name = trimTrailingSpaces(nameBytes)
        let ext = trimTrailingSpaces(extBytes)

        if lowerName { name = name.lowercased() }
        var extStr = ext
        if lowerExt { extStr = extStr.lowercased() }

        return extStr.isEmpty ? name : "\(name).\(extStr)"
    }

    private func trimTrailingSpaces(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0x20 { end -= 1 }
        guard end > 0 else { return "" }
        return String(bytes: bytes[0..<end], encoding: .ascii) ?? ""
    }

    // MARK: LFN

    private struct LFNEntry {
        let ordinal: UInt8
        let checksum: UInt8
        let nameChars: [UInt16]
    }

    private func parseLFNEntry(_ b: [UInt8], at base: Int) -> LFNEntry {
        let ordinal = b[base]
        let checksum = b[base + 0x0D]
        var chars: [UInt16] = []
        for c in 0..<5 { chars.append(readU16LE(b, at: base + 0x01 + c * 2)) }
        for c in 0..<6 { chars.append(readU16LE(b, at: base + 0x0E + c * 2)) }
        for c in 0..<2 { chars.append(readU16LE(b, at: base + 0x1C + c * 2)) }
        return LFNEntry(ordinal: ordinal, checksum: checksum, nameChars: chars)
    }

    private func reconstructLFN(_ entries: [LFNEntry]) -> String {
        let sorted = entries.sorted { ($0.ordinal & 0x3F) < ($1.ordinal & 0x3F) }
        var allChars: [UInt16] = []
        for entry in sorted {
            allChars.append(contentsOf: entry.nameChars)
        }
        return decodeUTF16String(allChars, maxLength: allChars.count)
    }

    private func lfnChecksum(bytes: [UInt8]) -> UInt8 {
        guard bytes.count >= 11 else { return 0 }
        var sum: UInt8 = 0
        for i in 0..<11 {
            sum = UInt8((((Int(sum) & 1) << 7) + (Int(sum) >> 1) + Int(bytes[i])) & 0xFF)
        }
        return sum
    }

    // MARK: Entry classification

    private func isDotOrDotDot(_ nameBytes: [UInt8]) -> Bool {
        guard nameBytes.count >= 11 else { return false }
        if nameBytes[0] == 0x2E {
            let rest = Array(nameBytes[1..<11])
            if rest.allSatisfy({ $0 == 0x20 }) { return true }
            if nameBytes[1] == 0x2E {
                let rest2 = Array(nameBytes[2..<11])
                if rest2.allSatisfy({ $0 == 0x20 }) { return true }
            }
        }
        return false
    }

    private func isVolumeLabel(_ attr: UInt8) -> Bool {
        (attr & 0x08) != 0 && attr != 0x0F
    }
}
