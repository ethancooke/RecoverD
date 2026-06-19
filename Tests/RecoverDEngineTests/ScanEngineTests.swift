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
        bytes[offset] = 0xFF
        bytes[offset + 1] = 0xD8
        bytes[offset + 2] = 0xFF

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
        #expect(snapshot.files.contains { $0.byteOffset == Int64(offset) })
        #expect(snapshot.files.contains { $0.fileType == .image })
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
