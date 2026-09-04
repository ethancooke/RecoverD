import Foundation
import RecoverDCore

/// Walks a JPEG's segment structure marker by marker to find its true end.
///
/// `ScanEngine.findJPEGEnd` depth-counts `FF D8`/`FF D9` pairs over the whole file, which fixes
/// the classic EXIF-thumbnail truncation. But APP-segment payloads (maker notes, XMP, Photoshop
/// IRB) can legitimately contain *unbalanced* `FF D8` bytes as ordinary data — the depth counter
/// then never returns to zero and the carve falls back to the size cap, gluing the photo to
/// whatever follows it on disk.
///
/// The segment walker instead reads each marker's declared length and strides over its payload
/// without inspecting it, so bytes inside APPn/COM/DQT/DHT/SOFn segments cannot confuse the
/// walk. Only the entropy-coded scan (whose length is undeclared) is scanned for markers, where
/// a real `FF` is always byte-stuffed (`FF 00`) or a marker itself. Multi-picture files (MPF —
/// iPhone portrait/HDR) are continued through each `SOI…EOI` picture.
///
/// Returns the absolute offset just past the outer `EOI`, or nil when the structure doesn't
/// validate (truncated or corrupt header, implausible length). Callers fall back to the
/// depth-counting path, then the size cap — never losing a recovery to a failed walk.
public enum JPEGSegmentWalker {

    /// Bytes fetched per read: enough to stride most segments in one hop, small enough to stay
    /// cache-friendly when skipping between rare markers.
    private static let window = 1 << 16

    /// Validates the MP Index IFD in an APP2 segment and returns its declared picture count.
    /// Requiring the mandatory version, NumberOfImages, and MPEntry tags prevents an arbitrary
    /// `MPF\0` payload from licensing the merge of an unrelated adjacent JPEG.
    private static func mpfPictureCount(
        in buf: UnsafeRawBufferPointer, markerAt marker: Int, segmentLength len: Int
    ) -> Int? {
        // len includes its own two length bytes. The payload is "MPF\0" followed by a TIFF
        // header and an IFD. Three 12-byte mandatory entries plus the MP entries need >= 82 bytes.
        let segmentEnd = marker + 2 + len
        guard len >= 88, segmentEnd > marker, marker + 16 <= buf.count,
              buf[marker + 4] == 0x4D, buf[marker + 5] == 0x50,
              buf[marker + 6] == 0x46, buf[marker + 7] == 0x00 else { return nil }

        let tiff = marker + 8
        let little: Bool
        if buf[tiff] == 0x49, buf[tiff + 1] == 0x49 { little = true }
        else if buf[tiff] == 0x4D, buf[tiff + 1] == 0x4D { little = false }
        else { return nil }

        func u16(_ at: Int) -> UInt16 {
            if little { return UInt16(buf[at]) | UInt16(buf[at + 1]) << 8 }
            return UInt16(buf[at]) << 8 | UInt16(buf[at + 1])
        }
        func u32(_ at: Int) -> UInt32 {
            if little {
                return UInt32(buf[at]) | UInt32(buf[at + 1]) << 8
                    | UInt32(buf[at + 2]) << 16 | UInt32(buf[at + 3]) << 24
            }
            return UInt32(buf[at]) << 24 | UInt32(buf[at + 1]) << 16
                | UInt32(buf[at + 2]) << 8 | UInt32(buf[at + 3])
        }

        guard u16(tiff + 2) == 42 else { return nil }
        let ifdOffset = Int(u32(tiff + 4))
        guard ifdOffset >= 8, ifdOffset <= len else { return nil }
        let ifd = tiff + ifdOffset
        guard ifd >= tiff, ifd + 2 <= segmentEnd, ifd + 2 <= buf.count else { return nil }
        let entryCount = Int(u16(ifd))
        // MP Index IFDs are tiny. This cap also bounds work on adversarial metadata.
        guard entryCount <= 64 else { return nil }
        let entriesEnd = ifd + 2 + entryCount * 12
        guard entriesEnd + 4 <= segmentEnd, entriesEnd + 4 <= buf.count else { return nil }

        var hasVersion = false
        var pictures: Int?
        var mpEntryCount: UInt32?
        var mpEntryOffset: UInt32?
        for entry in 0..<entryCount {
            let p = ifd + 2 + entry * 12
            switch u16(p) {
            case 0xB000: // MPFVersion: UNDEFINED[4] == "0100"
                if u16(p + 2) == 7, u32(p + 4) == 4,
                   buf[p + 8] == 0x30, buf[p + 9] == 0x31,
                   buf[p + 10] == 0x30, buf[p + 11] == 0x30 { hasVersion = true }
            case 0xB001: // NumberOfImages: LONG[1]
                if u16(p + 2) == 4, u32(p + 4) == 1 {
                    let n = Int(u32(p + 8))
                    if (2...4).contains(n) { pictures = n }
                }
            case 0xB002: // MPEntry: UNDEFINED[16 * NumberOfImages]
                if u16(p + 2) == 7 {
                    mpEntryCount = u32(p + 4)
                    mpEntryOffset = u32(p + 8)
                }
            default: break
            }
        }
        guard hasVersion, let pictures, let mpEntryCount, let mpEntryOffset,
              mpEntryCount == UInt32(pictures * 16) else { return nil }
        let tiffBytes = UInt64(segmentEnd - tiff)
        let minimumMPEntryOffset = UInt64(entriesEnd + 4 - tiff)
        guard UInt64(mpEntryOffset) >= minimumMPEntryOffset,
              UInt64(mpEntryOffset) + UInt64(mpEntryCount) <= tiffBytes else { return nil }
        return pictures
    }

    /// Walks from `start` (a confirmed `FF D8` SOI) to the outer EOI, bounded by `limit`.
    public static func walkEnd(
        start: Int64, limit: Int64, reader: any RawBlockReader
    ) async throws -> Int64? {
        // Validate the public API's arithmetic before adding to `start`. ScanEngine supplies
        // non-negative in-device offsets, but rejecting hostile direct callers keeps overflow
        // from becoming a process trap.
        guard start >= 0, limit >= start, limit - start >= 2 else { return nil }
        var pos = start + 2                       // past the opening SOI
        var inScan = false                        // between SOS entropy and the next real marker
        var picturesWalked = 1                    // global cap survives hostile re-declarations
        var remainingMPFPictures = 0              // validated primary MP Index count

        while pos < limit {
            try Task.checkCancellation()
            let remaining = limit - pos
            let toRead = Int(min(Int64(window), remaining))
            guard toRead >= 2 else { return nil }
            let block = try await reader.read(at: pos, count: toRead)
            let n = block.count
            // Internal readers never return more than requested. Enforce that contract here
            // because RawBlockReader is public and the parser indexes its unsafe buffer directly.
            if n < 2 || n > toRead { block.wipe(); return nil }

            // Outcome of walking this window:
            var doneAbs: Int64?                   // EOI found; absolute offset just past it
            var jumpAbs: Int64?                   // segment crossed the window — re-read there
            var consumed: Int64 = 0               // bytes consumed linearly (scan mode / straddle)
            var failed = false

            block.withUnsafeBytes { buf in
                var i = 0
                while i + 1 < buf.count {
                    let b0 = buf[i], b1 = buf[i + 1]

                    if inScan {
                        // Entropy-coded data: only FF-prefixed sequences matter. FF 00 is a
                        // stuffed literal FF and FF D0–D7 are restart markers. For FF FF fill,
                        // advance by one so the second FF remains available as the prefix of a
                        // following marker (for example FF FF D9).
                        guard b0 == 0xFF else { i += 1; continue }
                        switch b1 {
                        case 0x00, 0xD0...0xD7: i += 2
                        case 0xFF: i += 1
                        default: inScan = false      // a real marker ends the scan
                        }
                        continue
                    }

                    // Header mode: a marker must start here. Walk fill bytes with a separate
                    // cursor so `i + 1` is never evaluated past the unsafe buffer's end.
                    guard b0 == 0xFF else { failed = true; return }
                    var codeIndex = i + 1
                    while codeIndex < buf.count && buf[codeIndex] == 0xFF { codeIndex += 1 }
                    if codeIndex == buf.count {
                        // Preserve the final FF for the next window while discarding preceding
                        // fill. This always advances because every accepted block has >= 2 bytes.
                        jumpAbs = pos + Int64(buf.count - 1)
                        return
                    }
                    let code = buf[codeIndex]
                    if code == 0x00 { failed = true; return }
                    i = codeIndex - 1               // normalize so the code remains at i + 1
                    switch code {
                    case 0x01, 0xD0...0xD7:          // standalone markers (TEM, RST)
                        i += 2
                    case 0xD8:                       // SOI: a further MPF picture begins
                        i += 2
                    case 0xD9:                       // EOI: done (MPF peek happens below)
                        doneAbs = pos + Int64(i) + 2
                    case 0xDA:                       // SOS: length, then undeclared entropy data
                        guard i + 3 < buf.count else { jumpAbs = pos + Int64(i); return }
                        let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
                        guard len >= 2 else { failed = true; return }
                        let after = Int64(i) + 2 + Int64(len)
                        guard after <= remaining else { failed = true; return }
                        if after <= Int64(buf.count) {
                            i = Int(after); inScan = true
                        } else {
                            inScan = true            // payload crosses the window
                            jumpAbs = pos + after
                            return                   // re-read at the far side; do not rescan this marker
                        }
                    default:                         // APPn/COM/DQT/DHT/SOFn/DRI/…: length-bound
                        guard i + 3 < buf.count else { jumpAbs = pos + Int64(i); return }
                        let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
                        guard len >= 2 else { failed = true; return }
                        let after = Int64(i) + 2 + Int64(len)
                        guard after <= remaining else { failed = true; return }
                        // MPF declaration: re-read a straddling APP2 from its marker so the MP
                        // Index IFD can be validated. A bare "MPF\0" prefix is not sufficient.
                        if code == 0xE2, len >= 6 {
                            // Re-read a boundary-straddling APP2 once from its marker. At i == 0
                            // the front of even a maximum-sized segment is available to validate.
                            if after > Int64(buf.count), i > 0 {
                                jumpAbs = pos + Int64(i)
                                return
                            }
                            guard i + 8 <= buf.count else { jumpAbs = pos + Int64(i); return }
                            if picturesWalked == 1, remainingMPFPictures == 0,
                               let count = Self.mpfPictureCount(in: buf, markerAt: i, segmentLength: len) {
                                remainingMPFPictures = min(count - 1, 4 - picturesWalked)
                            }
                        }
                        if after <= Int64(buf.count) {
                            i = Int(after)
                        } else {
                            jumpAbs = pos + after    // payload crosses the window
                            return                   // re-read at the far side; do not rescan this marker
                        }
                    }
                    if doneAbs != nil { return }
                }
                // Keep the final byte so a marker straddling the window edge is re-examined.
                consumed = Int64(buf.count - 1)
            }
            block.wipe()

            if failed { return nil }
            if let done = doneAbs {
                // Multi-picture (MPF): a validated MP Index licenses its declared number of
                // directly following SOI pictures (at most four total). Undeclared adjacency is
                // just two files stored back-to-back, so stop at the first EOI.
                if remainingMPFPictures > 0 && done <= limit - 2 {
                    let peek = try await reader.read(at: done, count: 2)
                    let continues = peek.withUnsafeBytes {
                        $0.count >= 2 && $0[0] == 0xFF && $0[1] == 0xD8
                    }
                    peek.wipe()
                    if continues {
                        pos = done + 2
                        inScan = false
                        remainingMPFPictures -= 1
                        picturesWalked += 1
                        continue
                    }
                }
                return done
            }
            if let jump = jumpAbs {
                // A truncated marker header at the current position used to set jump == pos and
                // spin forever. Every continuation must make forward progress and stay in bounds.
                guard jump > pos, jump <= limit else { return nil }
                pos = jump
                continue
            }
            guard consumed > 0, consumed <= limit - pos else { return nil }
            pos += consumed
        }
        return nil
    }
}
