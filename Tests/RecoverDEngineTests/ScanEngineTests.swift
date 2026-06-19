import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// In-memory `RawBlockReader` for tests — no files, no privileges required.
actor InMemoryBlockReader: RawBlockReader {
    private let bytes: [UInt8]
    private let totalSizeBytes: Int64
    private let blockSizeBytes: Int

    init(_ bytes: [UInt8], blockSize: Int = 512) {
        self.bytes = bytes
        self.totalSizeBytes = Int64(bytes.count)
        self.blockSizeBytes = blockSize
    }

    var totalSize: Int64 { get async { totalSizeBytes } }
    var blockSize: Int { get async { blockSizeBytes } }

    func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard count > 0, offset >= 0, offset < Int64(bytes.count) else {
            return SecureData(data: Data())
        }
        let start = Int(offset)
        let end = min(start + count, bytes.count)
        return SecureData(bytes: Array(bytes[start..<end]))
    }
}

@Suite("ScanEngine")
struct ScanEngineTests {

    @Test("Deep scan carves a planted JPEG signature")
    func carveFindsJPEG() async throws {
        let size = 1_000_000
        var bytes = [UInt8](repeating: 0, count: size)
        let offset = 100_000
        // A minimally valid header: SOI + APP0 marker (`FF D8 FF E0`) so it passes follow-byte
        // validation, then an EOI (`FF D9`) 5_000 bytes later to bound the carve.
        bytes[offset] = 0xFF
        bytes[offset + 1] = 0xD8
        bytes[offset + 2] = 0xFF
        bytes[offset + 3] = 0xE0
        let jpegLength = 5_000
        bytes[offset + jpegLength - 2] = 0xFF
        bytes[offset + jpegLength - 1] = 0xD9

        let reader = InMemoryBlockReader(bytes)
        let device = DeviceInfo(
            id: DeviceID("test"),
            displayName: "test",
            bsdName: "x",
            devicePath: "/x",
            rawPath: "/x",
            totalSize: Int64(size),
            blockSize: 512,
            isRemovable: true,
            isExternal: true
        )

        let engine = ScanEngine()
        await engine.startScan(device: device, mode: .deep, reader: reader)

        let stream = await engine.subscribeProgress()
        for await update in stream where update.phase == .complete { break }

        let snapshot = await engine.snapshot()
        #expect(snapshot.files.count >= 1)
        let carved = try #require(snapshot.files.first { $0.byteOffset == Int64(offset) })
        #expect(carved.fileType == .image)
        // The carve is bounded by the planted EOI, not the 64 MB max.
        #expect(carved.size == Int64(jpegLength))
        await engine.clear()
    }

    @Test("Carved JPEG extends past an embedded thumbnail's EOI to the outer EOI")
    func carveJPEGSkipsThumbnailEOI() async throws {
        let size = 200_000
        var bytes = [UInt8](repeating: 0, count: size)
        let offset = 10_000

        // Outer image header: SOI + APP1 (EXIF).
        bytes.replaceSubrange(offset..<offset + 4, with: [0xFF, 0xD8, 0xFF, 0xE1])
        // Nested EXIF thumbnail: a complete `FF D8 … FF D9` 2_000 bytes in.
        let thumbStart = offset + 2_000
        bytes.replaceSubrange(thumbStart..<thumbStart + 4, with: [0xFF, 0xD8, 0xFF, 0xE0])
        let thumbEOI = thumbStart + 500
        bytes.replaceSubrange(thumbEOI..<thumbEOI + 2, with: [0xFF, 0xD9])
        // Outer EOI much later — this is the real end of the file.
        let outerEOI = offset + 50_000
        bytes.replaceSubrange(outerEOI..<outerEOI + 2, with: [0xFF, 0xD9])

        let reader = InMemoryBlockReader(bytes)
        let device = DeviceInfo(
            id: DeviceID("t"), displayName: "t", bsdName: "x", devicePath: "/x", rawPath: "/x",
            totalSize: Int64(size), blockSize: 512, isRemovable: true, isExternal: true
        )

        let engine = ScanEngine()
        await engine.startScan(device: device, mode: .deep, reader: reader)
        let stream = await engine.subscribeProgress()
        for await update in stream where update.phase == .complete { break }

        let snapshot = await engine.snapshot()
        let carved = try #require(snapshot.files.first { $0.byteOffset == Int64(offset) })
        // Size must reach the outer EOI, not stop at the thumbnail's EOI.
        #expect(carved.size == Int64(outerEOI + 2 - offset))
        await engine.clear()
    }

    @Test("Quick scan with unknown FS yields no files and still completes")
    func quickScanUnknownFS() async throws {
        let reader = InMemoryBlockReader([UInt8](repeating: 0, count: 4096))
        let device = DeviceInfo(
            id: DeviceID("blank"),
            displayName: "blank",
            bsdName: "x",
            devicePath: "/x",
            rawPath: "/x",
            totalSize: 4096,
            blockSize: 512,
            isRemovable: true,
            isExternal: true,
            detectedFileSystems: ["unknown"]
        )

        let engine = ScanEngine()
        await engine.startScan(device: device, mode: .quick, reader: reader)

        let stream = await engine.subscribeProgress()
        for await update in stream where update.phase == .complete { break }

        let snapshot = await engine.snapshot()
        #expect(snapshot.files.isEmpty)
        await engine.clear()
    }
}
