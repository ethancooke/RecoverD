import Foundation

/// Coarse file classification used for grouping, icons, and preview routing.
public enum RecoverableFileType: String, Sendable, Hashable, CaseIterable {
    case image
    case video
    case audio
    case document
    case archive
    case executable
    case text
    case database
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .archive: "Archive"
        case .executable: "Executable"
        case .text: "Text"
        case .database: "Database"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }
}

/// How a file entry came to be known to the engine.
public enum AllocationStatus: String, Sendable, Hashable {
    case live       // present in the file system tree
    case deleted    // unlinked but referenced by metadata/indirect structures
    case orphaned   // recovered purely by carving, no FS metadata
}

/// In-memory metadata for a recoverable file.
///
/// SECURITY INVARIANT: this type holds *metadata only*. It never stores file *content* bytes.
/// Content is fetched on demand from the source via `RawBlockReader` and held transiently in
/// `SecureData`, which is zeroed when no longer needed. Nothing here is written to disk by the
/// engine; only `ExportManager` writes content, and only on explicit user action.
public struct RecoverableFile: Identifiable, Hashable, Sendable {
    public let id: FileID
    public var displayName: String
    public var originalPath: String?
    public var fileType: RecoverableFileType
    public var size: Int64
    public var byteOffset: Int64
    public var allocationStatus: AllocationStatus
    public var creationDate: Date?
    public var modificationDate: Date?
    public var deletionDate: Date?
    public var sourceDeviceID: DeviceID
    public var confidence: Double
    public var signatureMatch: String?
    public var extents: [ByteRange]?

    public init(
        id: FileID,
        displayName: String,
        originalPath: String? = nil,
        fileType: RecoverableFileType = .unknown,
        size: Int64,
        byteOffset: Int64,
        allocationStatus: AllocationStatus = .orphaned,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        deletionDate: Date? = nil,
        sourceDeviceID: DeviceID,
        confidence: Double = 0,
        signatureMatch: String? = nil,
        extents: [ByteRange]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.fileType = fileType
        self.size = size
        self.byteOffset = byteOffset
        self.allocationStatus = allocationStatus
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.deletionDate = deletionDate
        self.sourceDeviceID = sourceDeviceID
        self.confidence = confidence
        self.signatureMatch = signatureMatch
        self.extents = extents
    }

    public var isCarved: Bool { allocationStatus == .orphaned }

    /// Flagged uncertain in the UI (e.g. an MP4 carve with no `moov` atom — a fragment or false
    /// positive). The threshold keeps footer-bounded/known-form carves and live files unflagged.
    public var isLowConfidence: Bool { confidence < 0.5 }
    public var canPreview: Bool {
        switch fileType {
        case .image, .video, .audio, .text, .document: true
        default: false
        }
    }
}
