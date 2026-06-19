import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Hermetic FAT16 parser tests against a hand-built in-memory image (no hdiutil, no mounting,
/// no desktop/GUI). The fixture encodes a real FAT16 layout: boot sector with BPB, FAT, fixed
/// root directory region, and three files — an 8.3 live file, an LFN live file, and a deleted
/// (0xE5) file whose FAT entry is freed. Validates BPB parsing, FAT16 type detection, 8.3 + LFN
/// decoding, deleted-entry recovery, extents, content reading, and export.
@Suite("FAT32Parser (hermetic FAT16 fixture)")
struct FAT32ParserHermeticTests {

    private let helloContent = "Hello, FAT16!\n"    // 14 bytes
    private let lfnContent = "LFN body!"            // 9 bytes
    private let deletedContent = "deleted!"         // 8 bytes (still on disk)

    @Test("Recovers 8.3 live, LFN live, and deleted files with correct metadata")
    func recoversFiles() async throws {
        let image = makeFAT16Image()
        let reader = InMemoryBlockReader(image)
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("hermetic"))

        let files = try await parser.parse()

        #expect(files.count == 3)

        let hello = try #require(files.first { $0.displayName == "HELLO.TXT" })
        let lfn = try #require(files.first { $0.displayName == "Long File Name.txt" })
        let deleted = try #require(files.first { $0.displayName.hasPrefix("_") && $0.displayName.hasSuffix(".TXT") })

        #expect(hello.allocationStatus == .live)
        #expect(hello.size == 14)
        #expect(hello.byteOffset == 1536) // cluster 2 = dataRegion(1536) + (2-2)*512
        #expect(hello.extents == [ByteRange(offset: 1536, length: 14)])
        #expect(hello.fileType == .text)

        #expect(lfn.allocationStatus == .live)
        #expect(lfn.size == 9)
        #expect(lfn.byteOffset == 2048) // cluster 3
        #expect(lfn.extents == [ByteRange(offset: 2048, length: 9)])

        #expect(deleted.allocationStatus == .deleted)
        #expect(deleted.size == 8)
        #expect(deleted.byteOffset == 2560) // cluster 4
        #expect(deleted.extents == nil)     // deleted: FAT freed -> contiguous heuristic
        #expect(deleted.deletionDate != nil)
    }

    @Test("Live file content reads correctly through extents")
    func readsLiveContent() async throws {
        let image = makeFAT16Image()
        let reader = InMemoryBlockReader(image)
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let hello = try #require(files.first { $0.displayName == "HELLO.TXT" })

        let content = try await readContent(of: hello, from: reader)
        defer { content.wipe() }
        let str = content.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        #expect(str == helloContent)
    }

    @Test("LFN file content reads correctly")
    func readsLFNContent() async throws {
        let image = makeFAT16Image()
        let reader = InMemoryBlockReader(image)
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let lfn = try #require(files.first { $0.displayName == "Long File Name.txt" })

        let content = try await readContent(of: lfn, from: reader)
        defer { content.wipe() }
        let str = content.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        #expect(str == lfnContent)
    }

    @Test("Deleted file content is recoverable via contiguous heuristic")
    func readsDeletedContent() async throws {
        let image = makeFAT16Image()
        let reader = InMemoryBlockReader(image)
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let deleted = try #require(files.first { $0.allocationStatus == .deleted })

        let content = try await readContent(of: deleted, from: reader)
        defer { content.wipe() }
        let str = content.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        #expect(str == deletedContent)
    }

    @Test("Export writes extent-assembled content to disk")
    func exportsContent() async throws {
        let image = makeFAT16Image()
        let reader = InMemoryBlockReader(image)
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let hello = try #require(files.first { $0.displayName == "HELLO.TXT" })

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverd-fat-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let manager = ExportManager()
        let written = try await manager.export(files: [hello], from: reader, to: outDir)
        #expect(written.count == 1)

        let data = try Data(contentsOf: written[0])
        #expect(String(data: data, encoding: .utf8) == helloContent)
    }

    @Test("Rejects a non-FAT image")
    func rejectsNonFAT() async throws {
        let reader = InMemoryBlockReader([UInt8](repeating: 0, count: 1024))
        let parser = FAT32Parser(reader: reader, deviceID: DeviceID("blank"))
        await #expect(throws: RecoverDError.self) {
            _ = try await parser.parse()
        }
    }

    // MARK: Fixture builder

    /// Builds a minimal valid FAT16 image:
    ///   bytesPerSector = 512, sectorsPerCluster = 1 (cluster = 512 bytes)
    ///   reservedSectors = 1, numFATs = 1, fatSize = 1 sector, rootEntryCount = 16
    ///   Layout: [boot(512)] [FAT(512)] [rootDir(512)] [data...]
    ///   cluster 2 = HELLO.TXT, cluster 3 = Long File Name.txt (LFN), cluster 4 = deleted file
    private func makeFAT16Image() -> [UInt8] {
        let bytesPerSector = 512
        let sectorsPerCluster = 1
        let reservedSectors = 1
        let numFATs = 1
        let rootEntryCount = 16
        let fatSizeSectors = 1
        let totalSectors = 20
        var img = [UInt8](repeating: 0, count: totalSectors * bytesPerSector)

        // --- Boot sector (BPB) ---
        img[0] = 0xEB; img[1] = 0x3C; img[2] = 0x90 // jump
        let oem = Array("MSDOS5.0".utf8)
        for i in 0..<8 { img[3 + i] = oem[i] }
        writeU16LE(&img, 0x0B, UInt16(bytesPerSector))
        img[0x0D] = UInt8(sectorsPerCluster)
        writeU16LE(&img, 0x0E, UInt16(reservedSectors))
        img[0x10] = UInt8(numFATs)
        writeU16LE(&img, 0x11, UInt16(rootEntryCount))
        writeU16LE(&img, 0x13, UInt16(totalSectors))
        img[0x15] = 0xF8 // media descriptor
        writeU16LE(&img, 0x16, UInt16(fatSizeSectors))
        writeU16LE(&img, 0x18, 63)  // sectors per track
        writeU16LE(&img, 0x1A, 255) // heads
        // FAT16 label at offset 0x36
        let label = Array("FAT16   ".utf8)
        for i in 0..<8 { img[0x36 + i] = label[i] }
        img[0x1FE] = 0x55; img[0x1FF] = 0xAA // boot signature

        // --- FAT (sector 1 = byte 512) ---
        let fatBase = reservedSectors * bytesPerSector
        writeU16LE(&img, fatBase + 0, 0xFFF8) // entry 0 (media)
        writeU16LE(&img, fatBase + 2, 0xFFFF) // entry 1 (reserved)
        writeU16LE(&img, fatBase + 4, 0xFFFF) // entry 2 (HELLO.TXT) EOC
        writeU16LE(&img, fatBase + 6, 0xFFFF) // entry 3 (LFN file) EOC
        // entry 4 (deleted file) = 0 (freed)

        // --- Root directory (sector 2 = byte 1024) ---
        let rootBase = (reservedSectors + numFATs * fatSizeSectors) * bytesPerSector
        var p = rootBase

        // Volume label entry (to test it's skipped)
        var volLabel = [UInt8](repeating: 0x20, count: 32)
        let volName = Array("RECOVERD".utf8)
        for i in 0..<volName.count { volLabel[i] = volName[i] }
        volLabel[0x0B] = 0x08 // volume label attribute
        for i in 0..<32 { img[p + i] = volLabel[i] }; p += 32

        // 8.3 file: HELLO.TXT → cluster 2, 14 bytes
        appendShortEntry(at: &p, into: &img, name: "HELLO", ext: "TXT",
                         attr: 0x20, firstCluster: 2, fileSize: UInt32(helloContent.count),
                         deleted: false, timestamp: makeFATDate(), time: makeFATTime())

        // LFN entries + 8.3 for "Long File Name.txt" → cluster 3, 9 bytes
        let shortNameBytes = makeShortNameBytes(name: "LONGFI~1", ext: "TXT")
        let checksum = lfnChecksum(shortNameBytes)
        appendLFNEntries(at: &p, into: &img, longName: "Long File Name.txt", checksum: checksum)
        appendShortEntry(at: &p, into: &img, name: "LONGFI~1", ext: "TXT",
                         attr: 0x20, firstCluster: 3, fileSize: UInt32(lfnContent.count),
                         deleted: false, timestamp: makeFATDate(), time: makeFATTime())

        // Deleted 8.3 file: DELETED.TXT → cluster 4, 9 bytes (first byte = 0xE5)
        appendShortEntry(at: &p, into: &img, name: "DELETED", ext: "TXT",
                         attr: 0x20, firstCluster: 4, fileSize: UInt32(deletedContent.count),
                         deleted: true, timestamp: makeFATDate(), time: makeFATTime())

        // End-of-directory (0x00) — already zeroed.

        // --- File contents ---
        let dataRegionBase = (reservedSectors + numFATs * fatSizeSectors +
                              (rootEntryCount * 32 + bytesPerSector - 1) / bytesPerSector) * bytesPerSector
        let helloOff = dataRegionBase + Int(2 - 2) * bytesPerSector
        let helloBytes = Array(helloContent.utf8)
        for i in 0..<helloBytes.count { img[helloOff + i] = helloBytes[i] }

        let lfnOff = dataRegionBase + Int(3 - 2) * bytesPerSector
        let lfnBytes = Array(lfnContent.utf8)
        for i in 0..<lfnBytes.count { img[lfnOff + i] = lfnBytes[i] }

        let deletedOff = dataRegionBase + Int(4 - 2) * bytesPerSector
        let deletedBytes = Array(deletedContent.utf8)
        for i in 0..<deletedBytes.count { img[deletedOff + i] = deletedBytes[i] }

        return img
    }

    private func appendShortEntry(at p: inout Int, into img: inout [UInt8],
                                  name: String, ext: String, attr: UInt8,
                                  firstCluster: UInt32, fileSize: UInt32,
                                  deleted: Bool, timestamp: UInt16, time: UInt16) {
        var entry = [UInt8](repeating: 0x20, count: 32)
        let nameBytes = Array(name.utf8)
        for i in 0..<min(nameBytes.count, 8) { entry[i] = nameBytes[i] }
        let extBytes = Array(ext.utf8)
        for i in 0..<min(extBytes.count, 3) { entry[8 + i] = extBytes[i] }
        if deleted { entry[0] = 0xE5 }
        entry[0x0B] = attr
        writeU16LE(&entry, 0x0E, time)   // createdTime
        writeU16LE(&entry, 0x10, timestamp) // createdDate
        writeU16LE(&entry, 0x12, timestamp) // accessedDate
        writeU16LE(&entry, 0x14, UInt16(firstCluster >> 16)) // firstClusterHigh
        writeU16LE(&entry, 0x16, time)      // writeTime
        writeU16LE(&entry, 0x18, timestamp) // writeDate
        writeU16LE(&entry, 0x1A, UInt16(firstCluster & 0xFFFF)) // firstClusterLow
        writeU32LE(&entry, 0x1C, fileSize)
        for i in 0..<32 { img[p + i] = entry[i] }; p += 32
    }

    private func appendLFNEntries(at p: inout Int, into img: inout [UInt8],
                                  longName: String, checksum: UInt8) {
        let units = Array(longName.utf16)
        let entryCount = (units.count + 12) / 13 // ceil(units.count / 13)
        for idx in 0..<entryCount {
            let ordinal = UInt8(idx + 1)
            let isLast = idx == entryCount - 1
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = isLast ? (ordinal | 0x40) : ordinal
            entry[0x0B] = 0x0F // LFN attribute
            entry[0x0D] = checksum

            let chunkStart = idx * 13
            for c in 0..<5 {
                let ui = chunkStart + c
                let v: UInt16 = ui < units.count ? units[ui] : (ui == units.count ? 0 : 0xFFFF)
                writeU16LE(&entry, 0x01 + c * 2, v)
            }
            for c in 0..<6 {
                let ui = chunkStart + 5 + c
                let v: UInt16 = ui < units.count ? units[ui] : (ui == units.count ? 0 : 0xFFFF)
                writeU16LE(&entry, 0x0E + c * 2, v)
            }
            for c in 0..<2 {
                let ui = chunkStart + 11 + c
                let v: UInt16 = ui < units.count ? units[ui] : (ui == units.count ? 0 : 0xFFFF)
                writeU16LE(&entry, 0x1C + c * 2, v)
            }
            // Write in reverse order (highest ordinal first)
            let writeIdx = p + (entryCount - 1 - idx) * 32
            for i in 0..<32 { img[writeIdx + i] = entry[i] }
        }
        p += entryCount * 32
    }

    private func makeShortNameBytes(name: String, ext: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0x20, count: 11)
        let n = Array(name.utf8)
        for i in 0..<min(n.count, 8) { bytes[i] = n[i] }
        let e = Array(ext.utf8)
        for i in 0..<min(e.count, 3) { bytes[8 + i] = e[i] }
        return bytes
    }

    private func lfnChecksum(_ nameBytes: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<11 {
            sum = UInt8((((Int(sum) & 1) << 7) + (Int(sum) >> 1) + Int(nameBytes[i])) & 0xFF)
        }
        return sum
    }

    // 2025-06-15 as FAT date: year=2025(45), month=6, day=15 → (45 << 9) | (6 << 5) | 15
    private func makeFATDate() -> UInt16 {
        UInt16((2025 - 1980) << 9) | (6 << 5) | 15
    }

    // 12:30:00 as FAT time: hour=12, minute=30, second=0 → (12 << 11) | (30 << 5) | 0
    private func makeFATTime() -> UInt16 {
        (12 << 11) | (30 << 5) | 0
    }

    private func writeU16LE(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
    }

    private func writeU32LE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
}
