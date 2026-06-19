import Foundation
import RecoverDCore

/// Parses a file system on a source into recoverable *metadata*. Parsers never return file
/// content — only `RecoverableFile` records pointing at offsets on the source. Content stays in
/// RAM and is only materialized on explicit preview/export.
public protocol FilesystemParser: Sendable {
    var displayName: String { get }
    func parse() async throws -> [RecoverableFile]
}

/// Chooses a parser for a device based on its detected file-system content strings. Returns
/// `nil` when the file system is unknown (the engine will fall back to carving in deep mode).
public func makeFilesystemParser(for device: DeviceInfo, reader: any RawBlockReader) -> (any FilesystemParser)? {
    let content = device.detectedFileSystems.joined(separator: " ").lowercased()

    if content.contains("exfat") {
        return EXFATParser(reader: reader, deviceID: device.id)
    }
    if content.contains("fat32") || content.contains("ms-dos") || content.contains("fat16") {
        return FAT32Parser(reader: reader, deviceID: device.id)
    }
    if content.contains("apfs") {
        return APFSParser(reader: reader, deviceID: device.id)
    }
    if content.contains("hfs") || content.contains("jhsf") || content.contains("hfs+") {
        return HFSPlusParser(reader: reader, deviceID: device.id)
    }
    return nil
}
