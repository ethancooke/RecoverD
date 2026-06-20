import Foundation
import RecoverDCore

/// A content-based type identification for a file whose name/extension is missing or misleading
/// (e.g. `123.avi` renamed to `123.qwerty` before deletion). The filesystem path types files by
/// extension; this looks at the actual bytes instead.
public struct DetectedFileType: Sendable, Hashable {
    public let fileExtension: String
    public let fileType: RecoverableFileType
    public let displayName: String

    public init(fileExtension: String, fileType: RecoverableFileType, displayName: String) {
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.displayName = displayName
    }
}

/// Identifies a file from its leading bytes. Reuses the carver's signature table (so it stays in
/// sync), then adds ISO-BMFF (MP4/MOV/HEIC) and a plain-text fallback.
public enum FileTypeSniffer {

    /// Inspects the first bytes of a file and returns the best content match, or nil if unknown.
    /// Pass at least a few KB so the text heuristic and `ftyp` brand have something to work with.
    public static func detect(_ bytes: [UInt8]) -> DetectedFileType? {
        guard !bytes.isEmpty else { return nil }

        // 1. Carver magic signatures, matched at offset 0.
        for sig in SignatureFileCarver().signatures {
            guard bytes.count >= sig.magic.count,
                  Array(bytes.prefix(sig.magic.count)) == sig.magic else { continue }

            if let followSet = sig.headerFollowSet {
                let idx = sig.magic.count
                guard idx < bytes.count, followSet.contains(bytes[idx]) else { continue }
            }

            if sig.container == .riff {
                guard bytes.count >= 12,
                      let form = String(bytes: bytes[8..<12], encoding: .ascii),
                      let riff = SignatureFileCarver.riffForm(form) else { continue }
                return DetectedFileType(fileExtension: riff.fileExtension,
                                        fileType: riff.fileType, displayName: riff.displayName)
            }
            if sig.container == .tiff {
                // Canon CR2: a generic little-endian TIFF with "CR" at offset 8.
                if sig.fileExtension == "tiff", bytes[0] == 0x49,
                   bytes.count >= 10, bytes[8] == 0x43, bytes[9] == 0x52 {
                    return DetectedFileType(fileExtension: "cr2", fileType: .image, displayName: "Canon RAW")
                }
                return DetectedFileType(fileExtension: sig.fileExtension,
                                        fileType: .image, displayName: sig.displayName)
            }
            return DetectedFileType(fileExtension: sig.fileExtension,
                                    fileType: sig.fileType, displayName: sig.displayName)
        }

        // 2. MPEG elementary stream (sequence header start code) — `.mpeg`. (The program-stream
        //    pack header `00 00 01 BA` is already covered by the carver signature above.)
        if bytes.count >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01, bytes[3] == 0xB3 {
            return DetectedFileType(fileExtension: "mpeg", fileType: .video, displayName: "MPEG video")
        }

        // 3. MPEG transport stream — the 0x47 sync byte repeats every 188 bytes. A single 0x47 is
        //    far too common, so require it to line up across several packets.
        if bytes.count >= 188 * 3 + 1,
           bytes[0] == 0x47, bytes[188] == 0x47, bytes[376] == 0x47, bytes[564] == 0x47 {
            return DetectedFileType(fileExtension: "ts", fileType: .video, displayName: "MPEG-TS video")
        }

        // 4. ISO base media (MP4 / MOV / M4A / HEIC): the `ftyp` box at offset 4, brand at 8.
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
            let form = SignatureFileCarver.isoBMFFType(brand: brand)
            return DetectedFileType(fileExtension: form.fileExtension,
                                    fileType: form.fileType, displayName: form.displayName)
        }

        // 5. Raw MPEG audio (an MP3 with no ID3 tag): a valid frame header at the start. Validating
        //    the version/layer/bitrate/sample-rate fields keeps the 11-bit sync from false-matching.
        if isMPEGAudioFrameHeader(bytes) {
            return DetectedFileType(fileExtension: "mp3", fileType: .audio, displayName: "MP3 audio")
        }

        // 6. Plain-text fallback: valid UTF-8 with very few control bytes.
        if looksLikeText(bytes) {
            return DetectedFileType(fileExtension: "txt", fileType: .text, displayName: "Plain text")
        }

        return nil
    }

    /// True if `bytes` begins with a structurally valid MPEG-1/2 Audio (Layer I–III) frame header.
    /// Rejects the reserved/invalid field encodings so a bare `FF Ex` sync isn't enough.
    private static func isMPEGAudioFrameHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        guard bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 else { return false } // 11-bit frame sync
        let version = (bytes[1] >> 3) & 0x03   // 01 = reserved
        let layer = (bytes[1] >> 1) & 0x03     // 00 = reserved
        let bitrate = (bytes[2] >> 4) & 0x0F   // 1111 = bad
        let sampleRate = (bytes[2] >> 2) & 0x03 // 11 = reserved
        return version != 0b01 && layer != 0b00 && bitrate != 0b1111 && sampleRate != 0b11
    }

    private static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        let sample = Array(bytes.prefix(2048))
        guard !sample.isEmpty, String(bytes: sample, encoding: .utf8) != nil else { return false }
        // Allow tab/newline/carriage-return; bail if too many other control bytes (i.e. binary).
        let control = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return Double(control) / Double(sample.count) < 0.05
    }
}
