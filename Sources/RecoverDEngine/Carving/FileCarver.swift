import Foundation
import RecoverDCore

/// A container format whose header is self-describing — the carver parses it to bound the file
/// and refine its type rather than relying on a footer/size cap.
public enum ContainerKind: Sendable, Hashable {
    /// RIFF (`RIFF` magic): bytes 4–7 are the little-endian payload size; bytes 8–11 are the form
    /// type (`AVI `, `WAVE`, `WEBP`, …).
    case riff
}

/// A recognizable file signature (magic bytes) used for carving.
public struct FileSignature: Sendable, Hashable {
    public let magic: [UInt8]
    public let fileExtension: String
    public let fileType: RecoverableFileType
    public let maxExpectedSize: Int64
    public let footer: [UInt8]?
    public let displayName: String

    /// Optional allow-list for the single byte immediately following `magic`. When non-nil, a
    /// magic match is only accepted if that next byte is in this set. This cheaply rejects the
    /// flood of false positives that short magics (e.g. JPEG's 3-byte `FF D8 FF`) produce on
    /// random/compressed data: a real JPEG's 4th byte is always a valid segment marker.
    public let headerFollowSet: Set<UInt8>?

    /// When set, the engine parses the container header to size the file and refine its type,
    /// instead of using `footer`/`maxExpectedSize`.
    public let container: ContainerKind?

    public init(magic: [UInt8],
                fileExtension: String,
                fileType: RecoverableFileType,
                maxExpectedSize: Int64,
                footer: [UInt8]? = nil,
                headerFollowSet: Set<UInt8>? = nil,
                container: ContainerKind? = nil,
                displayName: String) {
        self.magic = magic
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.maxExpectedSize = maxExpectedSize
        self.footer = footer
        self.headerFollowSet = headerFollowSet
        self.container = container
        self.displayName = displayName
    }
}

/// Carves files out of raw blocks by signature. Implementations provide the signature table and
/// a factory that turns a match into a `RecoverableFile`. The actual block-by-block scan is
/// driven by `ScanEngine` so progress/cancellation stay in one place.
public protocol FileCarver: Sendable {
    var signatures: [FileSignature] { get }
    /// Builds a `RecoverableFile` for a confirmed signature hit. `size` is the resolved on-disk
    /// length the engine computed (footer-bounded when a footer was found, otherwise capped),
    /// so callers don't re-derive it.
    func makeFile(signature: FileSignature,
                  offset: Int64,
                  size: Int64,
                  footerFound: Bool,
                  deviceID: DeviceID) -> RecoverableFile
}

/// A signature carver covering common media/document/archive types found on thumb drives.
public struct SignatureFileCarver: FileCarver {
    public let signatures: [FileSignature]

    public init() {
        self.signatures = [
            // JPEG: SOI + start of the first marker is `FF D8 FF`; the 4th byte is the marker
            // code, always one of a small known set (APPn/DQT/DHT/SOFn/DRI/COM). Requiring it
            // turns the 3-byte magic from a false-positive magnet into a usable signature.
            // Footer is the EOI marker `FF D9`, which bounds the carve to the real image length.
            FileSignature(magic: [0xFF, 0xD8, 0xFF],
                          fileExtension: "jpg", fileType: .image,
                          maxExpectedSize: 64 * 1024 * 1024,
                          footer: [0xFF, 0xD9],
                          headerFollowSet: SignatureFileCarver.jpegMarkerBytes,
                          displayName: "JPEG image"),
            FileSignature(magic: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                          fileExtension: "png", fileType: .image,
                          maxExpectedSize: 64 * 1024 * 1024,
                          footer: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82],
                          displayName: "PNG image"),
            // GIF's trailer is a single `0x3B` byte — far too common to use as a reliable end
            // marker — so this stays size-capped rather than footer-bounded.
            FileSignature(magic: [0x47, 0x49, 0x46, 0x38],
                          fileExtension: "gif", fileType: .image,
                          maxExpectedSize: 64 * 1024 * 1024, displayName: "GIF image"),
            FileSignature(magic: [0x25, 0x50, 0x44, 0x46, 0x2D],
                          fileExtension: "pdf", fileType: .document,
                          maxExpectedSize: 256 * 1024 * 1024,
                          footer: [0x25, 0x25, 0x45, 0x4F, 0x46],
                          displayName: "PDF document"),
            FileSignature(magic: [0x50, 0x4B, 0x03, 0x04],
                          fileExtension: "zip", fileType: .archive,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024, displayName: "ZIP archive"),
            // RIFF container (AVI / WAV / WebP). The engine parses the header to size it and pick
            // the real type; a hit with no recognized form type is rejected as a false positive.
            FileSignature(magic: [0x52, 0x49, 0x46, 0x46],
                          fileExtension: "avi", fileType: .video,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024,
                          container: .riff, displayName: "RIFF (AVI/WAV)"),
            // ID3v2 tag: "ID3" followed by a major-version byte (2, 3, or 4). Validating it keeps
            // this 3-byte magic from matching arbitrary "ID3" runs in binary data.
            FileSignature(magic: [0x49, 0x44, 0x33],
                          fileExtension: "mp3", fileType: .audio,
                          maxExpectedSize: 256 * 1024 * 1024,
                          headerFollowSet: [0x02, 0x03, 0x04],
                          displayName: "MP3 audio"),
            // Matroska / WebM: the EBML header magic. (Both use it; WebM is just a Matroska
            // profile.) No simple total-size field, so it's size-capped.
            FileSignature(magic: [0x1A, 0x45, 0xDF, 0xA3],
                          fileExtension: "mkv", fileType: .video,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024,
                          displayName: "Matroska/WebM video"),
            // MPEG program stream (.mpg/.vob): pack-header start code, validated by the pack
            // identifier bits in the next byte (MPEG-1 `0010xxxx`, MPEG-2 `01xxxxxx`) so the
            // common `00 00 01` prefix doesn't carve garbage.
            FileSignature(magic: [0x00, 0x00, 0x01, 0xBA],
                          fileExtension: "mpg", fileType: .video,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024,
                          headerFollowSet: SignatureFileCarver.mpegPackBytes,
                          displayName: "MPEG video")
        ]
    }

    /// Valid bytes immediately after an MPEG-PS pack-header start code: MPEG-2 packs are
    /// `01xxxxxx` (0x40–0x7F), MPEG-1 packs are `0010xxxx` (0x20–0x2F).
    static let mpegPackBytes: Set<UInt8> = {
        var set = Set<UInt8>(0x40...0x7F)
        set.formUnion(0x20...0x2F)
        return set
    }()

    /// The set of valid JPEG marker codes that may immediately follow `FF D8 FF`: APP0–APP15
    /// (`E0`–`EF`), DQT (`DB`), DHT (`C4`), DRI (`DD`), COM (`FE`), and the SOF variants
    /// (`C0`–`C3`, `C5`–`C7`, `C9`–`CB`, `CD`–`CF`).
    static let jpegMarkerBytes: Set<UInt8> = {
        var set = Set<UInt8>(0xE0...0xEF)          // APPn
        set.formUnion(0xC0...0xCF)                 // SOFn / DHT / DAC (covers C4)
        set.remove(0xC8)                           // JPG (reserved, not used)
        set.insert(0xDB)                           // DQT
        set.insert(0xDD)                           // DRI
        set.insert(0xFE)                           // COM
        return set
    }()

    public func makeFile(signature: FileSignature,
                         offset: Int64,
                         size: Int64,
                         footerFound: Bool,
                         deviceID: DeviceID) -> RecoverableFile {
        return RecoverableFile(
            id: FileID("carved:\(offset):\(signature.fileExtension)"),
            displayName: "recovered_\(offset).\(signature.fileExtension)",
            originalPath: nil,
            fileType: signature.fileType,
            size: max(0, size),
            byteOffset: offset,
            allocationStatus: .orphaned,
            sourceDeviceID: deviceID,
            // A hit whose end marker we actually found is far more likely to be a real file than
            // a bare magic match capped at the maximum size.
            confidence: footerFound ? 0.85 : 0.5,
            signatureMatch: signature.displayName
        )
    }

    /// A recognized RIFF form: the real extension, type, and human label for a form-type code.
    public struct RIFFForm: Sendable, Hashable {
        public let fileExtension: String
        public let fileType: RecoverableFileType
        public let displayName: String
    }

    /// Maps a 4-character RIFF form type (bytes 8–11) to a known media type, or nil if it isn't
    /// one we recognize — which lets the carver drop random `RIFF` false positives.
    public static func riffForm(_ formType: String) -> RIFFForm? {
        switch formType {
        case "AVI ": return RIFFForm(fileExtension: "avi", fileType: .video, displayName: "AVI video")
        case "WAVE": return RIFFForm(fileExtension: "wav", fileType: .audio, displayName: "WAV audio")
        case "WEBP": return RIFFForm(fileExtension: "webp", fileType: .image, displayName: "WebP image")
        default: return nil
        }
    }

    /// Builds a `RecoverableFile` for a parsed container (RIFF) hit, using the form's real
    /// extension/type and the header-derived size.
    public func makeContainerFile(form: RIFFForm,
                                  offset: Int64,
                                  size: Int64,
                                  deviceID: DeviceID) -> RecoverableFile {
        RecoverableFile(
            id: FileID("carved:\(offset):\(form.fileExtension)"),
            displayName: "recovered_\(offset).\(form.fileExtension)",
            originalPath: nil,
            fileType: form.fileType,
            size: max(0, size),
            byteOffset: offset,
            allocationStatus: .orphaned,
            sourceDeviceID: deviceID,
            // Valid form type + self-describing size ⇒ high confidence it's a real file.
            confidence: 0.85,
            signatureMatch: form.displayName
        )
    }
}
