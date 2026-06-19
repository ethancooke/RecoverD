import Foundation
import RecoverDCore

/// A recognizable file signature (magic bytes) used for carving.
public struct FileSignature: Sendable, Hashable {
    public let magic: [UInt8]
    public let fileExtension: String
    public let fileType: RecoverableFileType
    public let maxExpectedSize: Int64
    public let footer: [UInt8]?
    public let displayName: String

    public init(magic: [UInt8],
                fileExtension: String,
                fileType: RecoverableFileType,
                maxExpectedSize: Int64,
                footer: [UInt8]? = nil,
                displayName: String) {
        self.magic = magic
        self.fileExtension = fileExtension
        self.fileType = fileType
        self.maxExpectedSize = maxExpectedSize
        self.footer = footer
        self.displayName = displayName
    }
}

/// Carves files out of raw blocks by signature. Implementations provide the signature table and
/// a factory that turns a match into a `RecoverableFile`. The actual block-by-block scan is
/// driven by `ScanEngine` so progress/cancellation stay in one place.
public protocol FileCarver: Sendable {
    var signatures: [FileSignature] { get }
    func makeFile(signature: FileSignature,
                  offset: Int64,
                  availableSize: Int64,
                  deviceID: DeviceID) -> RecoverableFile
}

/// A signature carver covering common media/document/archive types found on thumb drives.
public struct SignatureFileCarver: FileCarver {
    public let signatures: [FileSignature]

    public init() {
        self.signatures = [
            FileSignature(magic: [0xFF, 0xD8, 0xFF],
                          fileExtension: "jpg", fileType: .image,
                          maxExpectedSize: 64 * 1024 * 1024, displayName: "JPEG image"),
            FileSignature(magic: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                          fileExtension: "png", fileType: .image,
                          maxExpectedSize: 64 * 1024 * 1024,
                          footer: [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82],
                          displayName: "PNG image"),
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
            FileSignature(magic: [0x52, 0x49, 0x46, 0x46],
                          fileExtension: "avi", fileType: .video,
                          maxExpectedSize: 4 * 1024 * 1024 * 1024, displayName: "RIFF (AVI/WAV)"),
            FileSignature(magic: [0x49, 0x44, 0x33],
                          fileExtension: "mp3", fileType: .audio,
                          maxExpectedSize: 256 * 1024 * 1024, displayName: "MP3 audio")
        ]
    }

    public func makeFile(signature: FileSignature,
                         offset: Int64,
                         availableSize: Int64,
                         deviceID: DeviceID) -> RecoverableFile {
        let size = min(signature.maxExpectedSize, max(0, availableSize))
        return RecoverableFile(
            id: FileID("carved:\(offset):\(signature.fileExtension)"),
            displayName: "recovered_\(offset).\(signature.fileExtension)",
            originalPath: nil,
            fileType: signature.fileType,
            size: size,
            byteOffset: offset,
            allocationStatus: .orphaned,
            sourceDeviceID: deviceID,
            confidence: 0.6,
            signatureMatch: signature.displayName
        )
    }
}
