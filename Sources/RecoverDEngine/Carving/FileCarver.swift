import Foundation
import RecoverDCore

/// A container format whose header is self-describing — the carver parses it to bound the file
/// and refine its type rather than relying on a footer/size cap.
public enum ContainerKind: Sendable, Hashable {
    /// RIFF (`RIFF` magic): bytes 4–7 are the little-endian payload size; bytes 8–11 are the form
    /// type (`AVI `, `WAVE`, `WEBP`, …).
    case riff
    /// ISO base media (MP4/MOV/M4A/HEIC): the `ftyp` magic sits 4 bytes into the file; the size
    /// comes from walking the top-level box chain. The brand (bytes 8–11) gives the real type.
    case isoBMFF
    /// TIFF and TIFF-based camera RAW (`II*\0` / `MM\0*`): the engine skips the copy embedded in
    /// JPEG EXIF and labels Canon CR2 (which has `CR` at offset 8) specifically.
    case tiff
    /// Matroska/WebM (EBML): the size comes from the Segment element's size field, a variable-
    /// length integer right after the Segment ID.
    case ebml
    /// Fujifilm RAF: a header directory at fixed offsets points to the embedded JPEG and the raw
    /// (CFA) data; the file end is the furthest of those offset+length pairs.
    case raf
}

/// Which scan tier a signature belongs to, so the UI can trade recall for precision/speed.
public enum SignatureCategory: Sendable, Hashable {
    /// Sized exactly and high-yield — always scanned.
    case core
    /// Can't be sized exactly (no length field / end marker), so recovery is a best guess —
    /// scanned only with "Try harder".
    case bestGuess
    /// Camera RAW (and TIFF, which shares the magic) — scanned only when RAW is included.
    case raw
}

/// Carve options chosen in the UI before a deep scan.
public struct CarveOptions: Sendable, Hashable {
    /// Include `.bestGuess` formats (GIF/ZIP/MP3/FLAC/Ogg/MPEG) we can't size exactly.
    public var tryHarder: Bool
    /// Include camera RAW + TIFF.
    public var includeRAW: Bool
    public init(tryHarder: Bool = false, includeRAW: Bool = false) {
        self.tryHarder = tryHarder
        self.includeRAW = includeRAW
    }
}

/// A recognizable file signature (magic bytes) used for carving.
public struct FileSignature: Sendable, Hashable {
    public let magic: [UInt8]
    public let fileExtension: String
    public let fileType: RecoverableFileType
    public let maxExpectedSize: Int64
    public let footer: [UInt8]?
    public let displayName: String
    public let category: SignatureCategory

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
                category: SignatureCategory = .core,
                displayName: String) {
        self.magic = magic
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.maxExpectedSize = maxExpectedSize
        self.footer = footer
        self.headerFollowSet = headerFollowSet
        self.container = container
        self.category = category
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
                          maxExpectedSize: 64 * 1024 * 1024,
                          category: .bestGuess, displayName: "GIF image"),
            // TIFF (and most camera RAW: NEF/ARW/DNG/CR2/3FR/…), both byte orders. Size-capped —
            // TIFF readers use the IFD offsets, so trailing bytes are ignored when opened.
            FileSignature(magic: [0x49, 0x49, 0x2A, 0x00],
                          fileExtension: "tiff", fileType: .image,
                          maxExpectedSize: 128 * 1024 * 1024,
                          container: .tiff, category: .raw, displayName: "TIFF/RAW image"),
            FileSignature(magic: [0x4D, 0x4D, 0x00, 0x2A],
                          fileExtension: "tiff", fileType: .image,
                          maxExpectedSize: 128 * 1024 * 1024,
                          container: .tiff, category: .raw, displayName: "TIFF/RAW image"),
            // Camera RAW with distinctive magics (no EXIF-collision risk). ORF/RW2 are TIFF-based,
            // so they go through the IFD sizer too (their "magic number" just isn't 42).
            FileSignature(magic: [0x49, 0x49, 0x52, 0x4F],            // "IIRO"
                          fileExtension: "orf", fileType: .image,
                          maxExpectedSize: 128 * 1024 * 1024,
                          container: .tiff, category: .raw, displayName: "Olympus RAW"),
            FileSignature(magic: [0x49, 0x49, 0x55, 0x00],            // "IIU\0"
                          fileExtension: "rw2", fileType: .image,
                          maxExpectedSize: 128 * 1024 * 1024,
                          container: .tiff, category: .raw, displayName: "Panasonic RAW"),
            FileSignature(magic: [0x46, 0x55, 0x4A, 0x49, 0x46, 0x49, 0x4C, 0x4D], // "FUJIFILM"
                          fileExtension: "raf", fileType: .image,
                          maxExpectedSize: 256 * 1024 * 1024,
                          container: .raf, category: .raw, displayName: "Fujifilm RAW"),
            FileSignature(magic: [0x46, 0x4F, 0x56, 0x62],           // "FOVb"
                          fileExtension: "x3f", fileType: .image,
                          maxExpectedSize: 128 * 1024 * 1024,
                          category: .raw, displayName: "Sigma RAW"),
            FileSignature(magic: [0x25, 0x50, 0x44, 0x46, 0x2D],
                          fileExtension: "pdf", fileType: .document,
                          maxExpectedSize: 256 * 1024 * 1024,
                          footer: [0x25, 0x25, 0x45, 0x4F, 0x46],
                          displayName: "PDF document"),
            FileSignature(magic: [0x50, 0x4B, 0x03, 0x04],
                          fileExtension: "zip", fileType: .archive,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024,
                          category: .bestGuess, displayName: "ZIP archive"),
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
                          category: .bestGuess, displayName: "MP3 audio"),
            // FLAC: the "fLaC" stream marker. No simple total-size field, so size-capped.
            FileSignature(magic: [0x66, 0x4C, 0x61, 0x43],
                          fileExtension: "flac", fileType: .audio,
                          maxExpectedSize: 1024 * 1024 * 1024,
                          category: .bestGuess, displayName: "FLAC audio"),
            // Ogg (Vorbis/Opus/FLAC): the "OggS" page marker. Usually audio.
            FileSignature(magic: [0x4F, 0x67, 0x67, 0x53],
                          fileExtension: "ogg", fileType: .audio,
                          maxExpectedSize: 1024 * 1024 * 1024,
                          category: .bestGuess, displayName: "Ogg audio"),
            // ISO base media (MP4/MOV/M4A/HEIC): the `ftyp` box type, which is 4 bytes into the
            // file. The engine backs up to the box start and walks the box chain to size it.
            FileSignature(magic: [0x66, 0x74, 0x79, 0x70],
                          fileExtension: "mp4", fileType: .video,
                          maxExpectedSize: 16 * 1024 * 1024 * 1024,
                          container: .isoBMFF, displayName: "MP4/MOV/M4A"),
            // Matroska / WebM: the EBML header magic. (Both use it; WebM is just a Matroska
            // profile.) The engine parses the EBML Segment size for the real length.
            FileSignature(magic: [0x1A, 0x45, 0xDF, 0xA3],
                          fileExtension: "mkv", fileType: .video,
                          maxExpectedSize: 8 * 1024 * 1024 * 1024,
                          container: .ebml, displayName: "Matroska/WebM video"),
            // MPEG program stream (.mpg/.vob): pack-header start code, validated by the pack
            // identifier bits in the next byte (MPEG-1 `0010xxxx`, MPEG-2 `01xxxxxx`) so the
            // common `00 00 01` prefix doesn't carve garbage. Bounded by the program end code.
            FileSignature(magic: [0x00, 0x00, 0x01, 0xBA],
                          fileExtension: "mpg", fileType: .video,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024,
                          footer: [0x00, 0x00, 0x01, 0xB9],
                          headerFollowSet: SignatureFileCarver.mpegPackBytes,
                          category: .bestGuess, displayName: "MPEG video")
        ]
    }

    /// The signatures to scan for under the given options. `.core` is always included; `.bestGuess`
    /// and `.raw` are opt-in.
    public func signatures(for options: CarveOptions) -> [FileSignature] {
        signatures.filter { sig in
            switch sig.category {
            case .core: return true
            case .bestGuess: return options.tryHarder
            case .raw: return options.includeRAW
            }
        }
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

    /// Maps an ISO-BMFF major brand (the `ftyp` box's bytes 8–11) to a media type. Shared by the
    /// carver and `FileTypeSniffer`. Unknown-but-plausible brands fall back to MP4 video.
    public static func isoBMFFType(brand: String) -> RIFFForm {
        let b = brand.trimmingCharacters(in: .whitespaces).lowercased()
        if b.hasPrefix("m4a") || b.hasPrefix("m4b") || b.hasPrefix("m4p") {
            return RIFFForm(fileExtension: "m4a", fileType: .audio, displayName: "MPEG-4 audio")
        }
        if b.hasPrefix("hei") || b == "mif1" || b == "msf1" || b == "avif" {
            return RIFFForm(fileExtension: "heic", fileType: .image, displayName: "HEIF image")
        }
        if b.hasPrefix("crx") {
            return RIFFForm(fileExtension: "cr3", fileType: .image, displayName: "Canon RAW")
        }
        if b.hasPrefix("qt") {
            return RIFFForm(fileExtension: "mov", fileType: .video, displayName: "QuickTime video")
        }
        return RIFFForm(fileExtension: "mp4", fileType: .video, displayName: "MP4 video")
    }

    /// Builds a `RecoverableFile` for a parsed container (RIFF/ISO-BMFF) hit, using the resolved
    /// extension/type and the header-derived size.
    public func makeContainerFile(fileExtension: String,
                                  fileType: RecoverableFileType,
                                  displayName: String,
                                  offset: Int64,
                                  size: Int64,
                                  confidence: Double = 0.85,
                                  deviceID: DeviceID) -> RecoverableFile {
        RecoverableFile(
            id: FileID("carved:\(offset):\(fileExtension)"),
            displayName: "recovered_\(offset).\(fileExtension)",
            originalPath: nil,
            fileType: fileType,
            size: max(0, size),
            byteOffset: offset,
            allocationStatus: .orphaned,
            sourceDeviceID: deviceID,
            confidence: confidence,
            signatureMatch: displayName
        )
    }
}
