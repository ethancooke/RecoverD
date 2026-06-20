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
            return DetectedFileType(fileExtension: sig.fileExtension,
                                    fileType: sig.fileType, displayName: sig.displayName)
        }

        // 2. ISO base media (MP4 / MOV / HEIC): the `ftyp` box at offset 4, brand at 8.
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = (String(bytes: bytes[8..<12], encoding: .ascii) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if brand.hasPrefix("hei") || brand == "mif1" || brand == "heix" {
                return DetectedFileType(fileExtension: "heic", fileType: .image, displayName: "HEIF image")
            }
            if brand.hasPrefix("qt") {
                return DetectedFileType(fileExtension: "mov", fileType: .video, displayName: "QuickTime video")
            }
            return DetectedFileType(fileExtension: "mp4", fileType: .video, displayName: "MP4 video")
        }

        // 3. Plain-text fallback: valid UTF-8 with very few control bytes.
        if looksLikeText(bytes) {
            return DetectedFileType(fileExtension: "txt", fileType: .text, displayName: "Plain text")
        }

        return nil
    }

    private static func looksLikeText(_ bytes: [UInt8]) -> Bool {
        let sample = Array(bytes.prefix(2048))
        guard !sample.isEmpty, String(bytes: sample, encoding: .utf8) != nil else { return false }
        // Allow tab/newline/carriage-return; bail if too many other control bytes (i.e. binary).
        let control = sample.filter { $0 < 0x09 || ($0 > 0x0D && $0 < 0x20) }.count
        return Double(control) / Double(sample.count) < 0.05
    }
}
