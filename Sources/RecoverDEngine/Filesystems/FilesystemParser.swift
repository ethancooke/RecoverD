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
    // Routes off the OS-reported content hint (normalized). A boot-sector probe (below) is the
    // authoritative router for FAT/exFAT/NTFS; this covers APFS/HFS+, which we can't open to probe.
    switch device.filesystemLabel {
    case "exFAT":
        return EXFATParser(reader: reader, deviceID: device.id)
    case "FAT32", "FAT16", "FAT12", "FAT":
        return FAT32Parser(reader: reader, deviceID: device.id)
    case "NTFS":
        return NTFSParser(reader: reader, deviceID: device.id)
    case "APFS":
        return APFSParser(reader: reader, deviceID: device.id)
    case "HFS+":
        return HFSPlusParser(reader: reader, deviceID: device.id)
    default:
        return nil
    }
}

/// Authoritative content probe: reads the volume's first sector and matches the on-disk boot
/// signature. This is more reliable than the OS content hint — macOS often can't label an NTFS or
/// Linux drive, and MBR type 0x07 is shared by NTFS/exFAT — so the scan prefers this. Recognizes
/// the filesystems we can actually recover (FAT12/16/32, exFAT, NTFS); returns nil otherwise.
public func probeFilesystemParser(for device: DeviceInfo, reader: any RawBlockReader) async -> (any FilesystemParser)? {
    guard let sector = try? await reader.read(at: 0, count: 512) else { return nil }
    defer { sector.wipe() }
    let b = sector.withUnsafeBytes { Array($0) }
    guard b.count >= 90 else { return nil }

    // NTFS / exFAT: OEM id at offset 3 of the boot sector.
    if let oem = String(bytes: b[3..<11], encoding: .ascii) {
        if oem == "NTFS    " { return NTFSParser(reader: reader, deviceID: device.id) }
        if oem.hasPrefix("EXFAT") { return EXFATParser(reader: reader, deviceID: device.id) }
    }
    // FAT12/16/32: a jump instruction at byte 0, then the BS_FilSysType string — "FAT32   " at
    // offset 0x52 (FAT32) or "FAT12/16/  " at offset 0x36 (FAT12/16). FAT32Parser handles all three.
    if b[0] == 0xEB || b[0] == 0xE9 {
        let fat32 = String(bytes: b[0x52..<0x57], encoding: .ascii) ?? ""
        let fat1x = String(bytes: b[0x36..<0x3B], encoding: .ascii) ?? ""
        if fat32.hasPrefix("FAT") || fat1x.hasPrefix("FAT") {
            return FAT32Parser(reader: reader, deviceID: device.id)
        }
    }
    return nil
}
