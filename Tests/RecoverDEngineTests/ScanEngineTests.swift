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

    @Test("TIFF carve: sizes a valid IFD, rejects noise + embedded EXIF")
    func carveTIFFValidatesAndSizes() async throws {
        let size = 200_000
        var bytes = [UInt8](repeating: 0, count: size)

        // A minimal but valid little-endian TIFF: header → IFD at +8 with one entry, next=0.
        func writeValidTIFF(at o: Int) {
            bytes.replaceSubrange(o..<o + 4, with: [0x49, 0x49, 0x2A, 0x00]) // II*\0
            bytes.replaceSubrange(o + 4..<o + 8, with: [0x08, 0x00, 0x00, 0x00]) // IFD0 @ 8
            bytes.replaceSubrange(o + 8..<o + 10, with: [0x01, 0x00]) // 1 entry
            // tag 0x0100 (ImageWidth), type 3 (SHORT), count 1, value 100
            bytes.replaceSubrange(o + 10..<o + 22,
                with: [0x00, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00])
            bytes.replaceSubrange(o + 22..<o + 26, with: [0x00, 0x00, 0x00, 0x00]) // next IFD = 0
        }

        let valid = 20_000
        writeValidTIFF(at: valid) // 26-byte TIFF

        // Bare II*\0 with a zero IFD pointer — noise, must be rejected by IFD validation.
        let noise = 50_000
        bytes.replaceSubrange(noise..<noise + 4, with: [0x49, 0x49, 0x2A, 0x00])

        // TIFF header embedded in JPEG EXIF (preceded by "Exif\0\0") — skipped before validation.
        let exifTiff = 80_000
        bytes.replaceSubrange(exifTiff - 6..<exifTiff, with: Array("Exif".utf8) + [0x00, 0x00])
        bytes.replaceSubrange(exifTiff..<exifTiff + 4, with: [0x49, 0x49, 0x2A, 0x00])

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

        let carved = try #require(files.first { $0.byteOffset == Int64(valid) })
        #expect(carved.fileType == .image)
        #expect(carved.size == 26) // sized from the IFD, not the 128 MB cap
        #expect(!files.contains { $0.byteOffset == Int64(noise) })   // invalid IFD rejected
        #expect(!files.contains { $0.byteOffset == Int64(exifTiff) }) // EXIF skipped
        await engine.clear()
    }

    @Test("Deep scan carves Matroska (EBML) and MPEG-PS signatures as video")
    func carveMatroskaAndMPEG() async throws {
        let size = 200_000
        var bytes = [UInt8](repeating: 0, count: size)
        let mkvOffset = 20_000
        bytes.replaceSubrange(mkvOffset..<mkvOffset + 4, with: [0x1A, 0x45, 0xDF, 0xA3])
        let mpegOffset = 60_000
        // pack-header start code + a valid MPEG-2 pack-id byte (0x44).
        bytes.replaceSubrange(mpegOffset..<mpegOffset + 5, with: [0x00, 0x00, 0x01, 0xBA, 0x44])

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

        #expect(files.first { $0.byteOffset == Int64(mkvOffset) }?.fileType == .video)
        #expect(files.first { $0.byteOffset == Int64(mpegOffset) }?.fileType == .video)
        await engine.clear()
    }

    @Test("Deep scan carves ISO-BMFF: backs up to box start, walks boxes for size, types by brand")
    func carveISOBMFF() async throws {
        let size = 200_000
        var bytes = [UInt8](repeating: 0, count: size)

        func writeBE32(_ offset: Int, _ value: UInt32) {
            bytes[offset] = UInt8((value >> 24) & 0xFF)
            bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 3] = UInt8(value & 0xFF)
        }
        func writeASCII(_ offset: Int, _ s: String) {
            bytes.replaceSubrange(offset..<offset + s.utf8.count, with: Array(s.utf8))
        }
        // An ISO-BMFF file: ftyp(24) + free(16) + mdat(100) = 140 bytes total.
        func writeISO(at o: Int, brand: String) -> Int {
            writeBE32(o, 24);       writeASCII(o + 4, "ftyp"); writeASCII(o + 8, brand)
            writeBE32(o + 24, 16);  writeASCII(o + 28, "free")
            writeBE32(o + 40, 100); writeASCII(o + 44, "mdat")
            return 140
        }
        let mp4Offset = 20_000, mp4Len = writeISO(at: mp4Offset, brand: "isom")
        let m4aOffset = 60_000, m4aLen = writeISO(at: m4aOffset, brand: "M4A ")

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

        // The carve starts at the box (4 bytes before `ftyp`), is sized by the box walk, and the
        // brand picks the type: isom → video, M4A → audio.
        let mp4 = try #require(files.first { $0.byteOffset == Int64(mp4Offset) })
        #expect(mp4.fileType == .video)
        #expect(mp4.size == Int64(mp4Len))

        let m4a = try #require(files.first { $0.byteOffset == Int64(m4aOffset) })
        #expect(m4a.fileType == .audio)
        #expect(m4a.size == Int64(m4aLen))
        await engine.clear()
    }

    @Test("ISO-BMFF carve confidence reflects whether a moov atom is present")
    func carveISOBMFFConfidence() async throws {
        let size = 200_000
        var bytes = [UInt8](repeating: 0, count: size)
        func be32(_ o: Int, _ v: UInt32) {
            bytes[o] = UInt8(v >> 24); bytes[o + 1] = UInt8((v >> 16) & 0xFF)
            bytes[o + 2] = UInt8((v >> 8) & 0xFF); bytes[o + 3] = UInt8(v & 0xFF)
        }
        func ascii(_ o: Int, _ s: String) { bytes.replaceSubrange(o..<o + s.utf8.count, with: Array(s.utf8)) }

        // With moov: ftyp(24) + moov(40) + mdat(100).
        let withMoov = 20_000
        be32(withMoov, 24);       ascii(withMoov + 4, "ftyp"); ascii(withMoov + 8, "isom")
        be32(withMoov + 24, 40);  ascii(withMoov + 28, "moov")
        be32(withMoov + 64, 100); ascii(withMoov + 68, "mdat")
        // Without moov: ftyp(24) + mdat(100) — a fragment.
        let noMoov = 60_000
        be32(noMoov, 24);      ascii(noMoov + 4, "ftyp"); ascii(noMoov + 8, "isom")
        be32(noMoov + 24, 100); ascii(noMoov + 28, "mdat")

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

        #expect(try #require(files.first { $0.byteOffset == Int64(withMoov) }).isLowConfidence == false)
        #expect(try #require(files.first { $0.byteOffset == Int64(noMoov) }).isLowConfidence == true)
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
