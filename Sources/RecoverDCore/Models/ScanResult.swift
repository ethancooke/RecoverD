import Foundation

/// Scan mode selected by the user.
public enum ScanMode: String, Sendable, Hashable, CaseIterable {
    case quick   // parse file-system metadata only
    case deep    // carve raw blocks (slower; works on reformatted/corrupted media)

    public var displayName: String {
        switch self {
        case .quick: "Quick Scan"
        case .deep: "Deep / Carving Scan"
        }
    }
}

/// Live scan progress, surfaced to the UI. Contains no file content.
public struct ScanProgress: Sendable, Hashable {
    public var bytesScanned: Int64
    public var totalBytes: Int64
    public var filesFound: Int
    public var currentRegion: String?
    public var phase: ScanPhase
    public var isPaused: Bool

    public init(
        bytesScanned: Int64 = 0,
        totalBytes: Int64 = 0,
        filesFound: Int = 0,
        currentRegion: String? = nil,
        phase: ScanPhase = .idle,
        isPaused: Bool = false
    ) {
        self.bytesScanned = bytesScanned
        self.totalBytes = totalBytes
        self.filesFound = filesFound
        self.currentRegion = currentRegion
        self.phase = phase
        self.isPaused = isPaused
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesScanned) / Double(totalBytes))
    }
}

public enum ScanPhase: String, Sendable, Hashable {
    case idle
    case discovering
    case imaging
    case parsing
    case carving
    case finalizing
    case complete
    case cancelled
    case failed
}

/// A non-fatal problem encountered during scanning.
public struct ScanError: Sendable, Hashable {
    public var code: String
    public var message: String
    public var byteOffset: Int64?

    public init(code: String, message: String, byteOffset: Int64? = nil) {
        self.code = code
        self.message = message
        self.byteOffset = byteOffset
    }
}

/// An immutable snapshot of scan results. The live, mutable result set is owned by `ScanEngine`
/// (an actor); this struct is what gets handed to the UI for rendering so the UI never touches
/// mutable engine state directly.
public struct ScanResult: Sendable {
    public let deviceID: DeviceID
    public let mode: ScanMode
    public let startedAt: Date
    public var finishedAt: Date?
    public var files: [RecoverableFile]
    public var bytesScanned: Int64
    public var bytesRead: Int64
    public var errors: [ScanError]

    public init(
        deviceID: DeviceID,
        mode: ScanMode,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        files: [RecoverableFile] = [],
        bytesScanned: Int64 = 0,
        bytesRead: Int64 = 0,
        errors: [ScanError] = []
    ) {
        self.deviceID = deviceID
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.files = files
        self.bytesScanned = bytesScanned
        self.bytesRead = bytesRead
        self.errors = errors
    }

    public var count: Int { files.count }
    public func files(of type: RecoverableFileType) -> [RecoverableFile] {
        files.filter { $0.fileType == type }
    }
}
