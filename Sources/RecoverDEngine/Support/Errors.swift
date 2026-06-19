import Foundation

public enum RecoverDError: Error, Sendable, Equatable {
    case notImplemented(String)
    case deviceUnavailable
    case readFailed(offset: Int64, cause: String)
    case unsupportedFilesystem(String)
    case carvingFailed(String)
    case exportFailed(String)
    case imagingFailed(String)
    case invalidRange
    case cancelled

    public var localizedDescription: String {
        switch self {
        case .notImplemented(let what): "\(what) is not implemented yet"
        case .deviceUnavailable: "The source device is no longer available"
        case .readFailed(let offset, let cause): "Read failed at \(offset): \(cause)"
        case .unsupportedFilesystem(let fs): "Unsupported file system: \(fs)"
        case .carvingFailed(let why): "Carving failed: \(why)"
        case .exportFailed(let why): "Export failed: \(why)"
        case .imagingFailed(let why): "Imaging failed: \(why)"
        case .invalidRange: "Invalid byte range"
        case .cancelled: "Operation cancelled"
        }
    }
}
