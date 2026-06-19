import Testing
@testable import RecoverDCore

@Suite("SecureData")
struct SecureDataTests {

    @Test("Round-trips bytes and reports count")
    func roundTrip() {
        let data = SecureData(bytes: [0x01, 0x02, 0x03, 0x04])
        #expect(data.count == 4)
        #expect(!data.isEmpty)
        var read: [UInt8] = []
        data.withUnsafeBytes { buf in
            read = Array(buf)
        }
        #expect(read == [0x01, 0x02, 0x03, 0x04])
    }

    @Test("wipe() releases content so subsequent reads are empty")
    func wipe() {
        let data = SecureData(bytes: [0x09, 0x08, 0x07])
        #expect(data.count == 3)
        data.wipe()
        var read: [UInt8] = []
        data.withUnsafeBytes { buf in read = Array(buf) }
        #expect(read.isEmpty)
        data.wipe() // double-wipe is safe
    }

    @Test("Equality compares contents")
    func equality() {
        let a = SecureData(bytes: [1, 2, 3])
        let b = SecureData(bytes: [1, 2, 3])
        let c = SecureData(bytes: [1, 2, 4])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Empty data is empty")
    func empty() {
        let data = SecureData(bytes: [])
        #expect(data.isEmpty)
        #expect(data.count == 0)
    }
}
