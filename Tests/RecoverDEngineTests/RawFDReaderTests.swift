import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

@Suite("RawFDReader + fd passing")
struct RawFDReaderTests {

    /// Reads via a plain fd: covers block-aligned widening + slicing for arbitrary offsets/lengths.
    @Test func preadAlignmentAndSlicing() async throws {
        let bytes = (0..<10_000).map { UInt8($0 & 0xFF) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rawfd_\(UUID()).bin")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = open(url.path, O_RDONLY)
        #expect(fd >= 0)
        let reader = RawFDReader(fd: fd, totalSize: Int64(bytes.count), blockSize: 512)

        // Unaligned offset + length, a whole-block read, and a read clamped at EOF.
        for (off, len) in [(0, 100), (100, 50), (511, 3), (512, 1024), (9_900, 500)] {
            let data = try await reader.read(at: Int64(off), count: len)
            let got = data.withUnsafeBytes { Array($0) }
            data.wipe()
            let expectedLen = min(len, bytes.count - off)
            #expect(got.count == expectedLen)
            #expect(got == Array(bytes[off..<off + expectedLen]))
        }
        await reader.close()
    }

    /// Sends a real fd across a socketpair and reads through it on the other end — exercises the
    /// SCM_RIGHTS receive path used for authopen, minus the authopen call.
    @Test func fileDescriptorPassingRoundTrip() async throws {
        let bytes = (0..<2048).map { UInt8(($0 * 7) & 0xFF) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rawfd_\(UUID()).bin")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var sv: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)

        let sourceFD = open(url.path, O_RDONLY)
        #expect(sourceFD >= 0)
        #expect(PrivilegedRawDevice.sendFileDescriptor(sourceFD, over: sv[1]) == true)
        close(sourceFD) // the received dup stays valid independently

        let receivedFD = PrivilegedRawDevice.receiveFileDescriptor(over: sv[0])
        #expect(receivedFD >= 0)
        close(sv[0]); close(sv[1])

        let reader = RawFDReader(fd: receivedFD, totalSize: Int64(bytes.count), blockSize: 512)
        let data = try await reader.read(at: 1000, count: 300)
        let got = data.withUnsafeBytes { Array($0) }
        data.wipe()
        #expect(got == Array(bytes[1000..<1300]))
        await reader.close()
    }
}
