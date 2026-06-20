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

    @Test("RIFF carving sizes from the header, types AVI/WAV, and drops bogus forms")
    func carveRIFFContainers() async throws {
        let size = 300_000
        var bytes = [UInt8](repeating: 0, count: size)

        func writeRIFF(at offset: Int, form: String, payload: UInt32) {
            bytes.replaceSubrange(offset..<offset + 4, with: Array("RIFF".utf8))
            bytes[offset + 4] = UInt8(payload & 0xFF)
            bytes[offset + 5] = UInt8((payload >> 8) & 0xFF)
            bytes[offset + 6] = UInt8((payload >> 16) & 0xFF)
            bytes[offset + 7] = UInt8((payload >> 24) & 0xFF)
            bytes.replaceSubrange(offset + 8..<offset + 12, with: Array(form.utf8))
        }

        let aviOffset = 10_000, aviPayload: UInt32 = 40_000           // file = payload + 8
        let wavOffset = 60_000, wavPayload: UInt32 = 5_000
        let bogusOffset = 80_000                                       // unrecognized form → dropped
        writeRIFF(at: aviOffset, form: "AVI ", payload: aviPayload)
        writeRIFF(at: wavOffset, form: "WAVE", payload: wavPayload)
        writeRIFF(at: bogusOffset, form: "XXXX", payload: 1_000)

        let reader = InMemoryBlockReader(bytes)
        let device = DeviceInfo(
            id: DeviceID("t"), displayName: "t", bsdName: "x", devicePath: "/x", rawPath: "/x",
            totalSize: Int64(size), blockSize: 512, isRemovable: true, isExternal: true
        )

        let engine = ScanEngine()
        await engine.startScan(device: device, mode: .deep, reader: reader)
        let stream = await engine.subscribeProgress()
        for await update in stream where update.phase == .complete { break }
        let files = await engine.snapshot().files

        let avi = try #require(files.first { $0.byteOffset == Int64(aviOffset) })
        #expect(avi.fileType == .video)
        #expect(avi.size == Int64(aviPayload) + 8)

        let wav = try #require(files.first { $0.byteOffset == Int64(wavOffset) })
        #expect(wav.fileType == .audio)
        #expect(wav.size == Int64(wavPayload) + 8)

        // The unrecognized RIFF form is not carved at all.
        #expect(!files.contains { $0.byteOffset == Int64(bogusOffset) })
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
