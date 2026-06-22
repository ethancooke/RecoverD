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
    if content.contains("ntfs") {
        return NTFSParser(reader: reader, deviceID: device.id)
    }
    if content.contains("apfs") {
        return APFSParser(reader: reader, deviceID: device.id)
    }
    if content.contains("hfs") || content.contains("jhsf") || content.contains("hfs+") {
        return HFSPlusParser(reader: reader, deviceID: device.id)
    }
    return nil
}

/// Content-probe fallback when the OS didn't label the volume (common for NTFS Windows drives and
/// any filesystem macOS can't mount). Reads the first sector and matches an on-disk magic, so we
/// route to the right parser even with no `detectedFileSystems` hint. Returns nil if unrecognized.
public func probeFilesystemParser(for device: DeviceInfo, reader: any RawBlockReader) async -> (any FilesystemParser)? {
    guard let sector = try? await reader.read(at: 0, count: 512) else { return nil }
    defer { sector.wipe() }
    let b = sector.withUnsafeBytes { Array($0) }
    guard b.count >= 11 else { return nil }

    // NTFS: OEM id "NTFS    " at offset 3 of the boot sector.
    if let oem = String(bytes: b[3..<11], encoding: .ascii), oem == "NTFS    " {
        return NTFSParser(reader: reader, deviceID: device.id)
    }
    // exFAT: "EXFAT   " at the same offset.
    if let oem = String(bytes: b[3..<11], encoding: .ascii), oem.hasPrefix("EXFAT") {
        return EXFATParser(reader: reader, deviceID: device.id)
    }
    return nil
}
