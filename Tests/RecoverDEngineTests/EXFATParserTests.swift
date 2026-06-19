import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Hermetic exFAT parser tests against a hand-built in-memory image (no hdiutil, no mounting).
/// The fixture encodes a real exFAT layout: boot sector, FAT, root directory with bitmap +
/// up-case-table entries, one live file ("hello.txt") and one deleted file ("gone.txt") whose
/// FAT chain is freed. Validates boot parsing, directory walk, live/deleted recovery, extents,
/// and the extent-following content reader / export path.
@Suite("EXFATParser (hermetic fixture)")
struct EXFATParserHermeticTests {

    private let liveContent = "Hello, exFAT!\n"           // 14 bytes
    private let deletedContent = "gone!"                  // 5 bytes (still on disk)

    @Test("Recovers live and deleted files with correct metadata")
    func recoversFiles() async throws {
        let image = makeExFATImage()
        let reader = InMemoryBlockReader(image)
        let parser = EXFATParser(reader: reader, deviceID: DeviceID("hermetic"))

        let files = try await parser.parse()

        // exactly two regular files: hello.txt (live), gone.txt (deleted)
        #expect(files.count == 2)

        let hello = try #require(files.first { $0.displayName == "hello.txt" })
        let gone = try #require(files.first { $0.displayName == "gone.txt" })

        #expect(hello.allocationStatus == .live)
        #expect(hello.size == 14)
        #expect(hello.byteOffset == 2048) // cluster 3 = heap(1536) + (3-2)*512
        #expect(hello.extents == [ByteRange(offset: 2048, length: 14)])
        #expect(hello.fileType == .text)
        #expect(hello.confidence == 0.95)

        #expect(gone.allocationStatus == .deleted)
        #expect(gone.size == 5)
        #expect(gone.byteOffset == 3584) // cluster 6 = heap(1536) + (6-2)*512
        #expect(gone.extents == nil)     // deleted: chain freed -> contiguous heuristic
        #expect(gone.deletionDate != nil)
        #expect(gone.confidence == 0.5)
    }

    @Test("Live file content reads correctly through extents")
    func readsLiveContent() async throws {
        let image = makeExFATImage()
        let reader = InMemoryBlockReader(image)
        let parser = EXFATParser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let hello = try #require(files.first { $0.displayName == "hello.txt" })

        let content = try await readContent(of: hello, from: reader)
        defer { content.wipe() }
        let str = content.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        #expect(str == liveContent)
    }

    @Test("Deleted file content is recoverable via contiguous heuristic")
    func readsDeletedContent() async throws {
        let image = makeExFATImage()
        let reader = InMemoryBlockReader(image)
        let parser = EXFATParser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let gone = try #require(files.first { $0.displayName == "gone.txt" })

        let content = try await readContent(of: gone, from: reader)
        defer { content.wipe() }
        let str = content.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        #expect(str == deletedContent)
    }

    @Test("Export writes extent-assembled content to disk")
    func exportsExtentContent() async throws {
        let image = makeExFATImage()
        let reader = InMemoryBlockReader(image)
        let parser = EXFATParser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()
        let hello = try #require(files.first { $0.displayName == "hello.txt" })

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverd-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let manager = ExportManager()
        let written = try await manager.export(files: [hello], from: reader, to: outDir)
        #expect(written.count == 1)

        let data = try Data(contentsOf: written[0])
        #expect(String(data: data, encoding: .utf8) == liveContent)
    }

    @Test("Rejects a non-exFAT image")
    func rejectsNonExFAT() async throws {
        let reader = InMemoryBlockReader([UInt8](repeating: 0, count: 1024))
        let parser = EXFATParser(reader: reader, deviceID: DeviceID("blank"))
        await #expect(throws: RecoverDError.self) {
            _ = try await parser.parse()
        }
    }

    // MARK: Fixture builder

    /// Builds a minimal valid exFAT image:
    ///   bytesPerSector = 512, sectorsPerCluster = 1 (cluster = 512 bytes)
    ///   FatOffset = sector 2, FatLength = 1 sector, ClusterHeapOffset = sector 3
    ///   cluster 2 = root dir, cluster 3 = hello.txt (live), cluster 6 = gone.txt (deleted,
    ///   FAT entry freed). Bitmap/upcase entries included so the parser skips them like real exFAT.
    private func makeExFATImage() -> [UInt8] {
        let bytesPerSector = 512
        let sectorsPerCluster = 1
        let bytesPerCluster = bytesPerSector * sectorsPerCluster
        let fatOffset = 2
        let fatLength = 1
        let clusterHeapOffset = 3
        let clusterCount = 10
        let rootCluster: UInt32 = 2
        let volumeSectors = 16
        var img = [UInt8](repeating: 0, count: volumeSectors * bytesPerSector)

        // --- Boot sector (sector 0) ---
        img[0] = 0xEB; img[1] = 0x76; img[2] = 0x90
        let fsName = Array("EXFAT   ".utf8)
        for i in 0..<8 { img[3 + i] = fsName[i] }
        // 0x0B..0x3F: must-be-zero (already zero)
        writeU32LE(&img, 0x40, 0)
        writeU64LE(&img, 0x48, UInt64(volumeSectors))
        writeU32LE(&img, 0x50, UInt32(fatOffset))
        writeU32LE(&img, 0x54, UInt32(fatLength))
        writeU32LE(&img, 0x58, UInt32(clusterHeapOffset))
        writeU32LE(&img, 0x5C, UInt32(clusterCount))
        writeU32LE(&img, 0x60, rootCluster)
        writeU32LE(&img, 0x64, 0x12345678)
        writeU16LE(&img, 0x68, 0x0100)
        writeU16LE(&img, 0x6A, 0)
        img[0x6C] = 9  // bytesPerSectorShift (512)
        img[0x6D] = 0  // sectorsPerClusterShift (1)
        img[0x6E] = 1  // numberOfFats
        img[0x6F] = 0x80
        img[0x70] = 0xFF
        img[0x1FE] = 0x55; img[0x1FF] = 0xAA

        // --- FAT (sector 2 = byte 1024) ---
        let fatBase = fatOffset * bytesPerSector
        writeU32LE(&img, fatBase + 0, 0xFFFFFFF8) // entry 0 (media)
        writeU32LE(&img, fatBase + 4, 0xFFFFFFFF) // entry 1 (reserved)
        writeU32LE(&img, fatBase + 8, 0xFFFFFFFF) // entry 2 (root) EOC
        writeU32LE(&img, fatBase + 12, 0xFFFFFFFF) // entry 3 (hello.txt) EOC
        writeU32LE(&img, fatBase + 16, 0xFFFFFFFF) // entry 4 (bitmap) EOC
        writeU32LE(&img, fatBase + 20, 0xFFFFFFFF) // entry 5 (upcase) EOC
        // entry 6 (gone.txt) = 0 (freed/deleted)

        // --- Root directory (cluster 2 = byte 1536) ---
        let rootBase = clusterHeapOffset * bytesPerSector + Int(rootCluster - 2) * bytesPerCluster
        var p = rootBase

        func writeEntry(_ build: (inout [UInt8]) -> Void) {
            var entry = [UInt8](repeating: 0, count: 32)
            build(&entry)
            for i in 0..<32 { img[p + i] = entry[i] }
            p += 32
        }

        // Allocation Bitmap (0x82): FirstCluster=4, DataLength=2 (covers 10 clusters)
        writeEntry { e in
            e[0] = 0x82
            writeU32LE(&e, 0x14, 4)
            writeU64LE(&e, 0x18, 2)
        }
        // Up-case Table (0x83): FirstCluster=5, DataLength=128
        writeEntry { e in
            e[0] = 0x83
            writeU32LE(&e, 0x14, 5)
            writeU64LE(&e, 0x18, 128)
        }

        // File entry set: hello.txt (live)
        appendFileEntry(at: &p, into: &img, name: "hello.txt", firstCluster: 3,
                        dataLength: UInt64(liveContent.count), deleted: false,
                        fatTimestamp: makeFATTimestamp())

        // File entry set: gone.txt (deleted)
        appendFileEntry(at: &p, into: &img, name: "gone.txt", firstCluster: 6,
                        dataLength: UInt64(deletedContent.count), deleted: true,
                        fatTimestamp: makeFATTimestamp())

        // End-of-directory marker (0x00) — already zeroed.

        // --- File contents ---
        let helloOff = clusterHeapOffset * bytesPerSector + Int(3 - 2) * bytesPerCluster
        let helloBytes = Array(liveContent.utf8)
        for i in 0..<helloBytes.count { img[helloOff + i] = helloBytes[i] }

        let goneOff = clusterHeapOffset * bytesPerSector + Int(6 - 2) * bytesPerCluster
        let goneBytes = Array(deletedContent.utf8)
        for i in 0..<goneBytes.count { img[goneOff + i] = goneBytes[i] }

        return img
    }

    // Encodes a File + Stream Extension + File Name entry set (3 entries, 96 bytes).
    private func appendFileEntry(at p: inout Int, into img: inout [UInt8],
                                 name: String, firstCluster: UInt32,
                                 dataLength: UInt64, deleted: Bool, fatTimestamp: UInt32) {
        let nameUnits = Array(name.utf16)
        let fileEntryType: UInt8 = deleted ? 0x05 : 0x85
        let streamEntryType: UInt8 = deleted ? 0x06 : 0x86
        let nameEntryType: UInt8 = deleted ? 0x01 : 0x81

        // File entry
        var file = [UInt8](repeating: 0, count: 32)
        file[0] = fileEntryType
        file[1] = 2 // SecondaryCount: stream + 1 name
        writeU16LE(&file, 0x04, 0x20) // FileAttributes: archive
        writeU32LE(&file, 0x08, fatTimestamp)
        writeU32LE(&file, 0x0C, fatTimestamp)
        writeU32LE(&file, 0x10, fatTimestamp)
        for i in 0..<32 { img[p + i] = file[i] }; p += 32

        // Stream Extension
        var stream = [UInt8](repeating: 0, count: 32)
        stream[0] = streamEntryType
        stream[1] = 0x01 // AllocationPossible, NoFatChain=0
        stream[3] = UInt8(nameUnits.count) // NameLength
        writeU64LE(&stream, 0x08, dataLength) // ValidDataLength
        writeU32LE(&stream, 0x14, firstCluster)
        writeU64LE(&stream, 0x18, dataLength) // DataLength
        for i in 0..<32 { img[p + i] = stream[i] }; p += 32

        // File Name (15 UTF-16 chars)
        var nameEntry = [UInt8](repeating: 0, count: 32)
        nameEntry[0] = nameEntryType
        for (i, unit) in nameUnits.prefix(15).enumerated() {
            writeU16LE(&nameEntry, 2 + i * 2, unit)
        }
        for i in 0..<32 { img[p + i] = nameEntry[i] }; p += 32
    }

    // 2025-06-15 12:30:42 UTC as a FAT timestamp.
    private func makeFATTimestamp() -> UInt32 {
        // year=2025 -> 45, month=6, day=15, hour=12, minute=30, second=42
        let value: UInt32 =
            (UInt32(2025 - 1980) << 25) |
            (UInt32(6) << 21) |
            (UInt32(15) << 16) |
            (UInt32(12) << 11) |
            (UInt32(30) << 5) |
            UInt32(42 / 2)
        return value
    }

    private func writeU16LE(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
        b[off] = UInt8(v & 0xFF)
        b[off + 1] = UInt8((v >> 8) & 0xFF)
    }

    private func writeU32LE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }

    private func writeU64LE(_ b: inout [UInt8], _ off: Int, _ v: UInt64) {
        for i in 0..<8 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
}
