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

    /// Walks from `start` (a confirmed `FF D8` SOI) to the outer EOI, bounded by `limit`.
    public static func walkEnd(
        start: Int64, limit: Int64, reader: any RawBlockReader
    ) async throws -> Int64? {
        var pos = start + 2                       // past the opening SOI
        var inScan = false                        // between SOS entropy and the next real marker
        var sawMPF = false                        // an APP2 "MPF\0" segment declares multi-picture
        var pictures = 1                          // MPF pictures walked so far (continuation cap)

        while pos < limit {
            let toRead = Int(min(Int64(window), limit - pos))
            guard toRead >= 2 else { return nil }
            let block = try await reader.read(at: pos, count: toRead)
            let n = block.count
            if n < 2 { block.wipe(); return nil }

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
                        // stuffed literal FF, FF D0–D7 are restart markers, FF FF is fill.
                        guard b0 == 0xFF else { i += 1; continue }
                        switch b1 {
                        case 0x00, 0xFF, 0xD0...0xD7: i += 2
                        default: inScan = false      // a real marker ends the scan
                        }
                        continue
                    }

                    // Header mode: a marker must start here.
                    guard b0 == 0xFF else { failed = true; return }
                    var code = b1
                    if code == 0xFF {               // fill bytes may precede the marker code
                        var fill = 0
                        while code == 0xFF && i + 1 < buf.count && fill < 64 {
                            i += 1; code = buf[i + 1]; fill += 1
                        }
                        if code == 0xFF || code == 0x00 { failed = true; return }
                    }
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
                        guard len >= 2, len <= 0xFFFF else { failed = true; return }
                        let after = Int64(i) + 2 + Int64(len)
                        if pos + after > limit { failed = true; return }
                        if after <= buf.count {
                            i = Int(after); inScan = true
                        } else {
                            inScan = true            // payload crosses the window
                            jumpAbs = pos + after
                            return                   // re-read at the far side; do not rescan this marker
                        }
                    default:                         // APPn/COM/DQT/DHT/SOFn/DRI/…: length-bound
                        guard i + 3 < buf.count else { jumpAbs = pos + Int64(i); return }
                        let len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
                        guard len >= 2, len <= 0xFFFF else { failed = true; return }
                        // MPF declaration: APP2 payload begins with "MPF\0". Only a declared
                        // multi-picture file may continue past an EOI into a following SOI —
                        // otherwise two independent JPEGs stored back-to-back would merge.
                        if code == 0xE2, i + 8 <= buf.count,
                           buf[i + 4] == 0x4D, buf[i + 5] == 0x50, buf[i + 6] == 0x46, buf[i + 7] == 0x00 {
                            sawMPF = true
                        }
                        let after = Int64(i) + 2 + Int64(len)
                        if pos + after > limit { failed = true; return }
                        if after <= buf.count {
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
                // Multi-picture (MPF): an APP2 "MPF\0" declaration licenses continuation
                // through a directly following SOI (iPhone portrait/HDR). Undeclared adjacency
                // is just two files stored back-to-back — stop at the first EOI.
                if sawMPF && pictures < 4 {
                    let peek = try await reader.read(at: done, count: 2)
                    let continues = peek.withUnsafeBytes {
                        $0.count >= 2 && $0[0] == 0xFF && $0[1] == 0xD8
                    }
                    peek.wipe()
                    if continues {
                        pos = done + 2
                        inScan = false
                        sawMPF = false          // the continuation picture must re-declare if it continues further
                        pictures += 1
                        continue
                    }
                }
                return done
            }
            if let jump = jumpAbs { pos = jump; continue }
            pos += consumed
        }
        return nil
    }
}
