import Foundation
import RecoverDCore

// Shared helpers for file-system parsers (exFAT, FAT12/16/32, future HFS+/APFS).
// Internal to RecoverDEngine — not part of the public API.

func readU16LE(_ b: [UInt8], at off: Int) -> UInt16 {
    guard off + 2 <= b.count else { return 0 }
    return UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
}

func readU32LE(_ b: [UInt8], at off: Int) -> UInt32 {
    guard off + 4 <= b.count else { return 0 }
    return UInt32(b[off])
        | (UInt32(b[off + 1]) << 8)
        | (UInt32(b[off + 2]) << 16)
        | (UInt32(b[off + 3]) << 24)
}

func readU64LE(_ b: [UInt8], at off: Int) -> UInt64 {
    guard off + 8 <= b.count else { return 0 }
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[off + i]) << (8 * i) }
    return v
}

/// FAT timestamp: high 16 bits = date, low 16 bits = time. Same encoding for exFAT (single
/// uint32) and FAT12/16/32 (separate uint16 date/time fields — combine before calling).
func fatTimestampToDate(_ raw: UInt32) -> Date? {
    guard raw != 0 else { return nil }
    let date = (raw >> 16) & 0xFFFF
    let time = raw & 0xFFFF
    let year = Int(date >> 9) + 1980
    let month = Int((date >> 5) & 0x0F)
    let day = Int(date & 0x1F)
    let hour = Int(time >> 11)
    let minute = Int((time >> 5) & 0x3F)
    let second = Int(time & 0x1F) * 2
    guard (1980...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else {
        return nil
    }
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = min(hour, 23)
    comps.minute = min(minute, 59)
    comps.second = min(second, 59)
    comps.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: comps)
}

/// Convenience for FAT12/16/32 separate date/time fields.
func fatDateTimeToDate(date: UInt16, time: UInt16) -> Date? {
    fatTimestampToDate((UInt32(date) << 16) | UInt32(time))
}

/// Decodes a UTF-16LE string from code units, truncating to `maxLength` and stripping
/// trailing null/0xFFFF padding. Used by exFAT File Name entries and FAT LFN entries.
func decodeUTF16String(_ units: [UInt16], maxLength: Int) -> String {
    let limit = maxLength > 0 ? min(maxLength, units.count) : units.count
    guard limit > 0 else { return "" }
    var utf16 = Array(units.prefix(limit))
    while let last = utf16.last, last == 0 || last == 0xFFFF { utf16.removeLast() }
    return String(decoding: utf16, as: UTF16.self)
}

/// Infers a coarse file type from the file extension. Shared by all parsers.
func inferFileTypeFromName(_ name: String) -> RecoverableFileType {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "jpg", "jpeg", "png", "gif", "bmp", "heic", "heif", "webp", "tiff", "tif",
         "cr2", "cr3", "nef", "nrw", "arw", "sr2", "srf", "dng", "orf", "rw2", "raf",
         "x3f", "pef", "3fr", "raw": return .image
    case "mp4", "mov", "avi", "mkv", "m4v", "webm",
         "mpeg", "mpg", "ts", "m2ts", "vob", "wmv", "flv": return .video
    case "mp3", "wav", "aac", "flac", "m4a", "m4b", "ogg", "oga", "opus", "aiff", "aif": return .audio
    case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "rtf": return .document
    case "zip", "rar", "7z", "gz", "tar": return .archive
    case "txt", "log", "md", "csv", "json", "xml", "swift", "c", "h", "py": return .text
    case "db", "sqlite", "sqlitedb": return .database
    case "app", "exe", "sh", "command": return .executable
    default: return .other
    }
}
