import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Tests for `JPEGSegmentWalker`: exact carve bounds for JPEGs whose APP-segment payloads
/// contain marker-lookalike bytes (a stray, unbalanced `FF D8`). The depth-counting fallback
/// never terminates on such files and the carve falls back to the size cap — gluing trailing
/// on-disk junk onto the photo. The segment walk must bound the carve exactly at the EOI.
@Suite("JPEG segment walker")
struct JPEGWalkerTests {

    /// Hand-crafted minimal JPEG (same payload as the quick-format integration test):
    /// SOI + DQT + SOF0 8x8 grayscale + DHT x2 + SOS + minimal entropy data + EOI.
    private static let baseJPEG: [UInt8] = [
        0xFF,0xD8,0xFF,0xDB,0x00,0x43,0x00,0x08,0x06,0x06,0x07,0x06,0x05,0x08,0x07,0x07,
        0x07,0x09,0x09,0x08,0x0A,0x0C,0x14,0x0D,0x0C,0x0B,0x0B,0x0C,0x19,0x12,0x13,0x0F,
        0x14,0x1D,0x1A,0x1F,0x1E,0x1D,0x1A,0x1C,0x20,0x24,0x2E,0x27,0x20,0x22,0x2C,0x23,
        0x1C,0x1C,0x28,0x37,0x29,0x2C,0x30,0x31,0x34,0x34,0x34,0x1F,0x27,0x39,0x3D,0x38,
        0x32,0x3C,0x2E,0x33,0x34,0x32,0x32,
        0xFF,0xC0,0x00,0x0B,0x08,0x00,0x08,0x00,0x08,0x01,0x01,0x11,0x00,
        0xFF,0xC4,0x00,0x1F,0x00,0x00,0x01,0x05,0x01,0x01,0x01,0x01,0x01,0x01,0x00,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,
        0x0B,
        0xFF,0xC4,0x00,0xB5,0x10,0x00,0x02,0x01,0x03,0x03,0x02,0x04,0x03,0x05,0x05,0x04,
        0x04,0x00,0x00,0x01,0x7D,0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,
        0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xA1,0x08,0x23,0x42,0xB1,
        0xC1,0x15,0x52,0xD1,0xF0,0x24,0x33,0x62,0x72,0x82,0x09,0x0A,0x16,0x17,0x18,0x19,
        0x1A,0x25,0x26,0x27,0x28,0x29,0x2A,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,
        0x45,0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0x63,0x64,
        0x65,0x66,0x67,0x68,0x69,0x6A,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x83,0x84,
        0x85,0x86,0x87,0x88,0x89,0x8A,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,
        0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,
        0xBA,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,
        0xD8,0xD9,0xDA,0xE1,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,
        0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA,
        0xFF,0xDA,0x00,0x08,0x01,0x01,0x00,0x00,0x3F,0x00,0xFB,0xFA,0x28,0xA2,0x8A,
        0xFF,0xD9
    ]

    /// The base JPEG with an APP1 "Exif" segment spliced in after the SOI whose payload contains
    /// a stray, unbalanced `FF D8` — the maker-note lookalike that breaks depth counting.
    private static var craftedJPEG: [UInt8] {
        let payload: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00,        // "Exif\0\0"
                                0xDE, 0xAD, 0xFF, 0xD8, 0xBE, 0xEF]        // stray SOI, no EOI
        let len = 2 + payload.count
        let app1: [UInt8] = [0xFF, 0xE1, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
        var bytes = baseJPEG
        bytes.insert(contentsOf: app1, at: 2)
        return bytes
    }

    /// Writes the crafted JPEG followed by 4 KB of on-disk junk (no markers) to a temp file.
    private static func writeFixture() throws -> (url: URL, craftedCount: Int, total: Int) {
        let crafted = craftedJPEG
        let junk = [UInt8](repeating: 0xAB, count: 4096)
        let all = crafted + junk
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walker-\(UUID().uuidString).jpg")
        try Data(all).write(to: url)
        return (url, crafted.count, all.count)
    }

    private static func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("walker-\(UUID().uuidString).jpg")
        try Data(bytes).write(to: url)
        return url
    }

    /// A finite read budget turns a no-progress regression into a fast thrown-test failure rather
    /// than hanging CI indefinitely.
    private enum FixtureError: Error { case readBudgetExceeded }
    private actor ReadBudgetReader: RawBlockReader {
        let bytes: [UInt8]
        let maxReads: Int
        var reads = 0

        init(bytes: [UInt8], maxReads: Int) {
            self.bytes = bytes
            self.maxReads = maxReads
        }

        var totalSize: Int64 { get async { Int64(bytes.count) } }
        var blockSize: Int { get async { 512 } }

        func read(at offset: Int64, count: Int) async throws -> SecureData {
            reads += 1
            guard reads <= maxReads else { throw FixtureError.readBudgetExceeded }
            guard count > 0, offset >= 0, offset < Int64(bytes.count) else {
                return SecureData(bytes: [])
            }
            let first = Int(offset)
            let last = min(first + count, bytes.count)
            return SecureData(bytes: Array(bytes[first..<last]))
        }
    }

    /// A structurally complete MP Index with the three mandatory tags. MPEntry data is zeroed
    /// because the walker only needs its declared extent and the adjacent SOIs.
    private static func mpfAPP2(pictures: Int = 2, littleEndian: Bool = true) -> [UInt8] {
        precondition((2...4).contains(pictures))
        func e16(_ value: Int) -> [UInt8] {
            let lo = UInt8(value & 0xFF), hi = UInt8((value >> 8) & 0xFF)
            return littleEndian ? [lo, hi] : [hi, lo]
        }
        func e32(_ value: Int) -> [UInt8] {
            let bytes = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
            return littleEndian ? bytes : Array(bytes.reversed())
        }
        let mpEntryBytes = pictures * 16
        let mpEntryOffset = 50                    // relative to TIFF header
        var entries = e16(0xB000) + e16(7)             // B000 "0100"
        entries += e32(4)
        entries += [0x30, 0x31, 0x30, 0x30]
        entries += e16(0xB001) + e16(4)                // B001 count
        entries += e32(1)
        entries += e32(pictures)
        entries += e16(0xB002) + e16(7)                // B002 MPEntry
        entries += e32(mpEntryBytes)
        entries += e32(mpEntryOffset)
        var tiff = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + e16(42) + e32(8)
        tiff += e16(3)
        tiff += entries
        tiff += e32(0)
        tiff += [UInt8](repeating: 0, count: mpEntryBytes)
        let payload = [0x4D, 0x50, 0x46, 0x00] + tiff                    // "MPF\0" + TIFF
        let len = 2 + payload.count
        return [0xFF, 0xE2, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    /// baseJPEG with a validated two-picture MP Index spliced in after the SOI.
    private static var mpfDeclaredJPEG: [UInt8] {
        var bytes = baseJPEG
        bytes.insert(contentsOf: mpfAPP2(), at: 2)
        return bytes
    }

    @Test("Segment walk bounds the carve exactly despite a stray SOI inside APP1")
    func walkEndFindsExactEnd() async throws {
        let (url, craftedCount, total) = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(
            start: 0, limit: Int64(total), reader: reader
        )
        // The walk must stop exactly at the EOI — not at the file end (the cap fallback would
        // glue the trailing junk on), and not before it.
        #expect(end == Int64(craftedCount))
    }

    @Test("Deep scan sizes the carved JPEG from the segment walk, not the cap")
    func deepScanSizesExactly() async throws {
        let (url, craftedCount, _) = try Self.writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let total = await reader.totalSize
        let device = DeviceInfo(
            id: DeviceID("dmg:walker-fixture"),
            displayName: "walker-fixture.jpg",
            bsdName: "(image)",
            devicePath: url.path,
            rawPath: url.path,
            totalSize: total,
            blockSize: 512,
            isRemovable: true,
            isExternal: true,
            detectedFileSystems: []
        )
        let engine = ScanEngine()
        await engine.startScan(device: device, mode: .deep, reader: reader,
                                options: CarveOptions())
        let stream = await engine.subscribeProgress()
        for await update in stream where update.phase == .complete { break }
        let result = await engine.snapshot()
        let images = result.files(of: .image)
        #expect(images.count == 1, "exactly one image should be carved")
        // The carved size must be the real JPEG length, excluding the trailing junk.
        #expect(images.first?.size == Int64(craftedCount))
    }

    // MARK: - Adjacent independent JPEGs must not merge

    @Test("Two JPEGs stored back-to-back stay two files (no undeclared MPF merge)")
    func adjacentJPEGsStaySeparate() async throws {
        var second = Self.baseJPEG
        second[10] ^= 0xFF                       // make the payloads distinct
        let all = Self.baseJPEG + second
        let url = try Self.writeTemp(all)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(all.count), reader: reader)
        #expect(end == Int64(Self.baseJPEG.count), "walk must stop at the FIRST EOI")
    }

    @Test("Declared MPF multi-picture continues past the first EOI")
    func mpfDeclarationMergesPictures() async throws {
        let first = Self.mpfDeclaredJPEG
        let all = first + Self.baseJPEG              // second picture follows the first EOI
        let url = try Self.writeTemp(all)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(all.count), reader: reader)
        #expect(end == Int64(all.count), "declared MPF must walk through both pictures")
    }

    @Test("Big-endian MP Index is validated and continued")
    func bigEndianMPFContinues() async throws {
        var first = Self.baseJPEG
        first.insert(contentsOf: Self.mpfAPP2(littleEndian: false), at: 2)
        let bytes = first + Self.baseJPEG
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(bytes.count))
    }

    @Test("MP Index count, not a fixed heuristic, bounds multi-picture continuation")
    func mpfCountBoundsContinuation() async throws {
        var first = Self.baseJPEG
        first.insert(contentsOf: Self.mpfAPP2(pictures: 3), at: 2)
        let declaredThree = first + Self.baseJPEG + Self.baseJPEG
        let bytes = declaredThree + Self.baseJPEG     // undeclared fourth adjacent JPEG
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(declaredThree.count), "walk exactly the MP Index image count")
    }

    @Test("A secondary picture cannot reset the primary MP Index continuation cap")
    func secondaryMPFDoesNotResetCount() async throws {
        var first = Self.baseJPEG
        first.insert(contentsOf: Self.mpfAPP2(pictures: 2), at: 2)
        var second = Self.baseJPEG
        second.insert(contentsOf: Self.mpfAPP2(pictures: 4), at: 2)
        let declaredTwo = first + second
        let bytes = declaredTwo + Self.baseJPEG
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(declaredTwo.count))
    }

    @Test("A bare MPF identifier without a valid MP Index cannot merge an adjacent JPEG")
    func bareMPFPrefixDoesNotMerge() async throws {
        let payload = [0x4D, 0x50, 0x46, 0x00] + [UInt8](repeating: 0, count: 82)
        let len = payload.count + 2
        let bogusAPP2 = [0xFF, 0xE2, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
        var first = Self.baseJPEG
        first.insert(contentsOf: bogusAPP2, at: 2)
        let bytes = first + Self.baseJPEG
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(first.count))
    }

    // MARK: - Damage falls back gracefully

    @Test("Corrupt segment length returns nil so the depth-count fallback engages")
    func corruptLengthReturnsNil() async throws {
        var corrupt = Self.baseJPEG
        corrupt[4] = 0x00                        // DQT declared length 0x0001 < 2
        corrupt[5] = 0x01
        let url = try Self.writeTemp(corrupt)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(corrupt.count), reader: reader)
        #expect(end == nil, "structural failure must return nil, not a guess")
    }

    @Test("Truncated segment header returns nil without a no-progress loop")
    func truncatedSegmentHeaderReturnsNil() async throws {
        // This is accepted by the scanner's JPEG follow-byte filter but ends before the APP1
        // length field. The read budget ensures a regression fails instead of hanging the suite.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1]
        let reader = ReadBudgetReader(bytes: bytes, maxReads: 4)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == nil)
    }

    @Test("Hostile public bounds return nil instead of overflowing")
    func hostileBoundsReturnNil() async throws {
        let reader = ReadBudgetReader(bytes: [], maxReads: 0)
        #expect(try await JPEGSegmentWalker.walkEnd(start: -1, limit: 10, reader: reader) == nil)
        #expect(try await JPEGSegmentWalker.walkEnd(start: 10, limit: 5, reader: reader) == nil)
        #expect(try await JPEGSegmentWalker.walkEnd(
            start: Int64.max - 1, limit: Int64.max, reader: reader
        ) == nil)
    }

    @Test("A cancelled walk exits before reading more media")
    func cancellationIsObserved() async {
        let reader = ReadBudgetReader(bytes: Self.baseJPEG, maxReads: 0)
        let task = Task<Int64?, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await JPEGSegmentWalker.walkEnd(
                start: 0, limit: Int64(Self.baseJPEG.count), reader: reader
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Window straddle

    @Test("A 64 KiB-crossing APP payload is skipped intact via the jump path")
    func longAPPStraddlesWindow() async throws {
        // Two maximum-size APP1 segments: the second's payload crosses the
        // 64 KiB read window, forcing the jump re-read path.
        func bigAPP1(_ filler: UInt8) -> [UInt8] {
            let payload = [UInt8](repeating: filler, count: 0xFFFD)  // len 0xFFFF total
            return [0xFF, 0xE1, 0xFF, 0xFF] + payload
        }
        var bytes = [UInt8](Self.baseJPEG.prefix(2)) + bigAPP1(0x11) + bigAPP1(0x22)
        bytes += Array(Self.baseJPEG.dropFirst(2))
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(bytes.count), "both long APPs skipped; EOI found exactly")
    }

    @Test("Marker fill at the 64 KiB edge cannot index beyond the read window")
    func markerFillAtWindowEdgeIsSafe() async throws {
        // APP0 makes this a scanner-accepted JPEG. TEM pairs place FF FF in the final two bytes
        // of the first read, the exact boundary that previously indexed buf[buf.count].
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02]
        for _ in 0..<32_765 { bytes += [0xFF, 0x01] }
        bytes += [0xFF, 0xFF]
        #expect(bytes.count == 65_538)
        let reader = ReadBudgetReader(bytes: bytes, maxReads: 4)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == nil)
    }

    @Test("An MPF identifier crossing the read edge is re-read, not skipped")
    func mpfIdentifierStraddleContinues() async throws {
        // The APP1 ends at relative byte 65,530, leaving only "FF E2 len MP" in the first
        // window. The remaining "F\0" must be seen after re-reading from the APP2 marker.
        let bridgeLength = 65_528
        let bridge = [0xFF, 0xE1, UInt8(bridgeLength >> 8), UInt8(bridgeLength & 0xFF)]
            + [UInt8](repeating: 0x11, count: bridgeLength - 2)
        let first = [UInt8](Self.baseJPEG.prefix(2)) + bridge + Self.mpfAPP2()
            + Array(Self.baseJPEG.dropFirst(2))
        let bytes = first + Self.baseJPEG
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(bytes.count))
    }

    // MARK: - Entropy discipline

    @Test("Byte-stuffed FF and restart markers in scan data do not terminate the walk")
    func entropyStuffingIgnored() async throws {
        // Replace the 5-byte entropy run with stuffing + restart markers + fill,
        // all of which are legal scan data that must NOT end the scan early.
        var bytes = Self.baseJPEG
        let stuffed: [UInt8] = [0xFF, 0x00, 0xFF, 0xD2, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xD5]
        let entropyStart = bytes.count - 7       // 5 entropy bytes + EOI (2)
        bytes.replaceSubrange(entropyStart..<(entropyStart + 5), with: stuffed)
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(bytes.count), "stuffed FF/RST/Fill must be consumed as scan data")
    }

    @Test("Entropy fill preserves the following EOI marker prefix")
    func entropyFillBeforeEOIIsRecognized() async throws {
        let jpeg: [UInt8] = [
            0xFF, 0xD8,
            0xFF, 0xE0, 0x00, 0x02,
            0xFF, 0xDA, 0x00, 0x02,
            0xFF, 0xFF, 0xD9,
        ]
        let bytes = jpeg + [UInt8](repeating: 0xAB, count: 4096)
        let url = try Self.writeTemp(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try await URLBlockReader(url: url)
        let end = try await JPEGSegmentWalker.walkEnd(start: 0, limit: Int64(bytes.count), reader: reader)
        #expect(end == Int64(jpeg.count), "fill must not hide EOI and glue trailing bytes")
    }
}
