import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

@Suite("FileTypeSniffer")
struct FileTypeSnifferTests {

    @Test func detectsImageByMagicNotName() {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 32)
        let d = FileTypeSniffer.detect(jpeg)
        #expect(d?.fileType == .image)
        #expect(d?.fileExtension == "jpg")
    }

    @Test func detectsRIFFForms() {
        func riff(_ form: String) -> [UInt8] {
            Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array(form.utf8) + [UInt8](repeating: 0, count: 16)
        }
        #expect(FileTypeSniffer.detect(riff("AVI "))?.fileType == .video)
        #expect(FileTypeSniffer.detect(riff("WAVE"))?.fileType == .audio)
        #expect(FileTypeSniffer.detect(riff("WEBP"))?.fileType == .image)
        // Unrecognized RIFF form isn't claimed as a known type.
        #expect(FileTypeSniffer.detect(riff("ZZZZ")) == nil)
    }

    @Test func detectsMP4ByFtypBox() {
        let mp4: [UInt8] = [0, 0, 0, 0x18] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 16)
        let d = FileTypeSniffer.detect(mp4)
        #expect(d?.fileType == .video)
        #expect(d?.fileExtension == "mp4")
    }

    @Test func detectsPlainText() {
        let text = Array("hello, this is just some recovered text.\nLine two.".utf8)
        #expect(FileTypeSniffer.detect(text)?.fileType == .text)
    }

    @Test func returnsNilForUnknownBinary() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<512).map { _ in UInt8.random(in: 0...255, using: &rng) }
        // Random binary won't reliably match anything; just assert it isn't misreported as text.
        if let d = FileTypeSniffer.detect(noise) {
            #expect(d.fileType != .text)
        }
    }
}
