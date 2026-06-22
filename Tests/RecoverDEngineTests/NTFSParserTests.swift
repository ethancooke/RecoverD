import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Hermetic NTFS parser tests against a hand-built in-memory image (no mounting, no ntfs tooling —
/// macOS can't even create an NTFS volume). The fixture encodes a real NTFS layout: a boot sector,
/// a 20-record $MFT whose record 0 ($MFT) has a non-resident $DATA describing the table's own
/// extent, a "photos" directory, a live file in it, a deleted file, and a file with resident data.
/// Validates boot parsing, MFT self-location, fixups, attribute walking, data-run decoding,
/// resident data, deleted recovery, parent-chain path resolution, and the content reader.
@Suite("NTFSParser (hermetic fixture)")
struct NTFSParserHermeticTests {

    private let helloContent = "Hello, NTFS!\n"          // 13 bytes (live, non-resident)
    private let goneContent  = "deleted-but-here"        // 16 bytes (deleted, runs survive)
    private let tinyContent  = "tiny"                    // 4 bytes (resident in the MFT record)

    @Test("Recovers live, deleted, and resident files with paths and extents")
    func recoversFiles() async throws {
        let reader = InMemoryBlockReader(makeNTFSImage())
        let parser = NTFSParser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()

        // Three regular files; the "photos" directory and the <16 metafiles are excluded.
        #expect(files.count == 3)

        let hello = try #require(files.first { $0.displayName.hasSuffix("hello.txt") })
        #expect(hello.allocationStatus == .live)
        #expect(hello.size == 13)
        #expect(hello.originalPath == "photos/hello.txt")     // parent-chain resolved
        #expect(hello.extents == [ByteRange(offset: 25600, length: 13)]) // LCN 50 * 512
        #expect(hello.byteOffset == 25600)
        #expect(hello.fileType == .text)
        #expect(hello.confidence == 0.9)
        #expect(hello.modificationDate != nil)

        let gone = try #require(files.first { $0.displayName.hasSuffix("gone.txt") })
        #expect(gone.allocationStatus == .deleted)
        #expect(gone.size == 16)
        #expect(gone.extents == [ByteRange(offset: 26112, length: 16)]) // LCN 51 * 512
        #expect(gone.deletionDate != nil)
        #expect(gone.confidence == 0.5)

        let tiny = try #require(files.first { $0.displayName.hasSuffix("tiny.txt") })
        #expect(tiny.size == 4)
        #expect(tiny.allocationStatus == .live)
    }

    @Test("Content reads back through extents (non-resident, deleted, and resident)")
    func readsContent() async throws {
        let reader = InMemoryBlockReader(makeNTFSImage())
        let parser = NTFSParser(reader: reader, deviceID: DeviceID("hermetic"))
        let files = try await parser.parse()

        func text(_ f: RecoverableFile) async throws -> String? {
            let c = try await readContent(of: f, from: reader)
            defer { c.wipe() }
            return c.withUnsafeBytes { String(data: Data($0), encoding: .utf8) }
        }

        let hello = try #require(files.first { $0.displayName.hasSuffix("hello.txt") })
        let gone = try #require(files.first { $0.displayName.hasSuffix("gone.txt") })
        let tiny = try #require(files.first { $0.displayName.hasSuffix("tiny.txt") })

        #expect(try await text(hello) == helloContent)
        #expect(try await text(gone) == goneContent)
        #expect(try await text(tiny) == tinyContent)
    }

    @Test("Probe routes an unlabeled NTFS volume by its boot magic")
    func probeRoutesNTFS() async throws {
        let reader = InMemoryBlockReader(makeNTFSImage())
        let device = DeviceInfo(
            id: DeviceID("test"), displayName: "ntfs", bsdName: "x", devicePath: "/x",
            rawPath: "/x", totalSize: 32768, blockSize: 512, isRemovable: true, isExternal: true
        )
        let parser = await probeFilesystemParser(for: device, reader: reader)
        #expect(parser?.displayName == "NTFS")
    }

    @Test("Rejects a non-NTFS image")
    func rejectsNonNTFS() async throws {
        let reader = InMemoryBlockReader([UInt8](repeating: 0, count: 1024))
        let parser = NTFSParser(reader: reader, deviceID: DeviceID("blank"))
        await #expect(throws: RecoverDError.self) {
            _ = try await parser.parse()
        }
    }

    // MARK: Fixture builder

    /// bytesPerSector = 512, sectorsPerCluster = 1 (cluster = 512), MFT record = 1024 (2 sectors,
    /// so fixups matter). $MFT at LCN 4. 20 records; data clusters at LCN 50/51.
    private func makeNTFSImage() -> [UInt8] {
        let clusterSize = 512
        let recordSize = 1024
        let mftLCN = 4
        let recordCount = 20
        var img = [UInt8](repeating: 0, count: 64 * clusterSize) // 32 KiB

        // --- Boot sector ---
        for (i, b) in Array("NTFS    ".utf8).enumerated() { img[3 + i] = b }
        writeU16LE(&img, 0x0B, 512)            // bytes per sector
        img[0x0D] = 1                          // sectors per cluster
        writeU64LE(&img, 0x28, 64)             // total sectors (unused by parser)
        writeU64LE(&img, 0x30, UInt64(mftLCN)) // $MFT LCN
        img[0x40] = 0xF6                       // clusters-per-record = -10 => 2^10 = 1024
        img[0x1FE] = 0x55; img[0x1FF] = 0xAA

        let ft = makeFiletime() // 2025-06-15 12:30:42 UTC

        // --- Build the 20-record MFT ---
        var mft = [UInt8](repeating: 0, count: recordCount * recordSize)
        func place(_ index: Int, _ record: [UInt8]) {
            for (i, b) in record.enumerated() { mft[index * recordSize + i] = b }
        }

        // Record 0: $MFT — non-resident $DATA covering the whole table (40 clusters at LCN 4).
        let mftClusters = recordCount * recordSize / clusterSize // 40
        place(0, buildRecord(flags: 0x01, attrs: [
            stdInfoAttr(ft),
            dataNonResidentAttr(realSize: UInt64(recordCount * recordSize),
                                lenClusters: UInt64(mftClusters), lcn: Int64(mftLCN))
        ]))

        // Record 16: "photos" directory (parent = root index 5).
        place(16, buildRecord(flags: 0x03, attrs: [
            stdInfoAttr(ft),
            fileNameAttr(parent: 5, name: "photos", filetime: ft)
        ]))

        // Record 17: live "hello.txt" inside photos, non-resident data at LCN 50.
        place(17, buildRecord(flags: 0x01, attrs: [
            stdInfoAttr(ft),
            fileNameAttr(parent: 16, name: "hello.txt", filetime: ft),
            dataNonResidentAttr(realSize: UInt64(helloContent.count), lenClusters: 1, lcn: 50)
        ]))

        // Record 18: deleted "gone.txt" (in-use bit cleared), data run still present at LCN 51.
        place(18, buildRecord(flags: 0x00, attrs: [
            stdInfoAttr(ft),
            fileNameAttr(parent: 5, name: "gone.txt", filetime: ft),
            dataNonResidentAttr(realSize: UInt64(goneContent.count), lenClusters: 1, lcn: 51)
        ]))

        // Record 19: live "tiny.txt" with resident data (content inline in the record).
        place(19, buildRecord(flags: 0x01, attrs: [
            stdInfoAttr(ft),
            fileNameAttr(parent: 5, name: "tiny.txt", filetime: ft),
            dataResidentAttr(Array(tinyContent.utf8))
        ]))

        // Copy the MFT into the image at LCN 4, then lay down the non-resident file contents.
        for (i, b) in mft.enumerated() { img[mftLCN * clusterSize + i] = b }
        for (i, b) in Array(helloContent.utf8).enumerated() { img[50 * clusterSize + i] = b }
        for (i, b) in Array(goneContent.utf8).enumerated() { img[51 * clusterSize + i] = b }
        return img
    }

    // MARK: Attribute + record encoders

    private func align8(_ n: Int) -> Int { (n + 7) & ~7 }

    private func stdInfoAttr(_ filetime: UInt64) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 0x18 + 0x30)
        writeU32LE(&a, 0x00, 0x10)
        writeU32LE(&a, 0x04, UInt32(a.count))
        writeU16LE(&a, 0x14, 0x18)
        writeU32LE(&a, 0x10, 0x30)
        writeU64LE(&a, 0x18 + 0x00, filetime) // created
        writeU64LE(&a, 0x18 + 0x08, filetime) // modified
        writeU64LE(&a, 0x18 + 0x10, filetime) // MFT changed
        writeU64LE(&a, 0x18 + 0x18, filetime) // accessed
        return a
    }

    private func fileNameAttr(parent: UInt32, name: String, filetime: UInt64) -> [UInt8] {
        let units = Array(name.utf16)
        let contentLen = 0x42 + units.count * 2
        var a = [UInt8](repeating: 0, count: align8(0x18 + contentLen))
        writeU32LE(&a, 0x00, 0x30)
        writeU32LE(&a, 0x04, UInt32(a.count))
        writeU16LE(&a, 0x14, 0x18)
        writeU32LE(&a, 0x10, UInt32(contentLen))
        let c = 0x18
        writeU64LE(&a, c + 0x00, UInt64(parent)) // parent ref (low 48 bits = index)
        writeU64LE(&a, c + 0x08, filetime)
        writeU64LE(&a, c + 0x10, filetime)
        writeU64LE(&a, c + 0x18, filetime)
        writeU64LE(&a, c + 0x20, filetime)
        a[c + 0x40] = UInt8(units.count)
        a[c + 0x41] = 1 // Win32 namespace
        for (i, u) in units.enumerated() { writeU16LE(&a, c + 0x42 + i * 2, u) }
        return a
    }

    private func dataNonResidentAttr(realSize: UInt64, lenClusters: UInt64, lcn: Int64) -> [UInt8] {
        let runsOffset = 0x40
        let runs: [UInt8] = [0x11, UInt8(lenClusters), UInt8(bitPattern: Int8(lcn)), 0x00]
        var a = [UInt8](repeating: 0, count: align8(runsOffset + runs.count))
        writeU32LE(&a, 0x00, 0x80)
        writeU32LE(&a, 0x04, UInt32(a.count))
        a[0x08] = 1 // non-resident
        writeU64LE(&a, 0x10, 0)                    // start VCN
        writeU64LE(&a, 0x18, lenClusters - 1)      // last VCN
        writeU16LE(&a, 0x20, UInt16(runsOffset))
        writeU64LE(&a, 0x28, lenClusters * 512)    // allocated size
        writeU64LE(&a, 0x30, realSize)             // real size
        writeU64LE(&a, 0x38, realSize)             // initialized size
        for (i, b) in runs.enumerated() { a[runsOffset + i] = b }
        return a
    }

    private func dataResidentAttr(_ content: [UInt8]) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: align8(0x18 + content.count))
        writeU32LE(&a, 0x00, 0x80)
        writeU32LE(&a, 0x04, UInt32(a.count))
        writeU16LE(&a, 0x14, 0x18)
        writeU32LE(&a, 0x10, UInt32(content.count))
        for (i, b) in content.enumerated() { a[0x18 + i] = b }
        return a
    }

    /// Builds a 1024-byte FILE record, then applies the update-sequence-array "write" (overwriting
    /// the last 2 bytes of each 512-byte stride with the USN) so the parser must reverse the fixup.
    private func buildRecord(flags: UInt16, attrs: [[UInt8]]) -> [UInt8] {
        let recordSize = 1024
        var r = [UInt8](repeating: 0, count: recordSize)
        r[0] = 0x46; r[1] = 0x49; r[2] = 0x4C; r[3] = 0x45 // "FILE"
        let usaOffset = 0x30
        let usaCount = 3 // USN + one fixup per 512-byte stride (2 strides)
        writeU16LE(&r, 0x04, UInt16(usaOffset))
        writeU16LE(&r, 0x06, UInt16(usaCount))
        writeU16LE(&r, 0x14, 0x38) // first attribute offset
        writeU16LE(&r, 0x16, flags)

        var off = 0x38
        for attr in attrs { for (i, b) in attr.enumerated() { r[off + i] = b }; off += attr.count }
        writeU32LE(&r, off, 0xFFFF_FFFF) // attribute terminator
        off += 4
        writeU32LE(&r, 0x18, UInt32(off))         // used size
        writeU32LE(&r, 0x1C, UInt32(recordSize))  // allocated size

        // Apply fixups: stride ends are 510 and 1022. Attrs end well before 510, so originals are 0.
        let usn: UInt16 = 0x0001
        let s1 = 510, s2 = 1022
        writeU16LE(&r, usaOffset + 2, UInt16(r[s1]) | (UInt16(r[s1 + 1]) << 8))
        writeU16LE(&r, usaOffset + 4, UInt16(r[s2]) | (UInt16(r[s2 + 1]) << 8))
        writeU16LE(&r, usaOffset, usn)
        writeU16LE(&r, s1, usn)
        writeU16LE(&r, s2, usn)
        return r
    }

    /// 2025-06-15 12:30:42 UTC as a Windows FILETIME (100 ns ticks since 1601).
    private func makeFiletime() -> UInt64 {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 15
        comps.hour = 12; comps.minute = 30; comps.second = 42
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let seconds = date.timeIntervalSince1970 + 11_644_473_600
        return UInt64(seconds * 10_000_000)
    }

    private func writeU16LE(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
        b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8((v >> 8) & 0xFF)
    }
    private func writeU32LE(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
    private func writeU64LE(_ b: inout [UInt8], _ off: Int, _ v: UInt64) {
        for i in 0..<8 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
}
