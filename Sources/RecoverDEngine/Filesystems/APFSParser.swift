import Foundation
import RecoverDCore

/// APFS (read-only) parser.
///
/// APFS is complex (container superblock, NX block map, volumes, file-system trees, and the
/// " omap" for persistent objects). Rather than reimplement it, RecoverD bridges to
/// **libfsapfs** (https://github.com/libyal/libfsapfs) for correct, maintained parsing. The
/// bridge is abstracted behind `APFSParser` so the rest of the engine is unaware of the C
/// dependency.
///
/// Integration plan:
///   1. Ship `libfsapfs.dylib` as a SwiftPM `.binaryTarget` (or build from source in a
///      separate package) signed by the project.
///   2. Add a thin C module map + Swift wrapper (`libfsapfs` handle -> open / iterate files /
///      read extent bytes).
///   3. Map libfsapfs file entries to `RecoverableFile` (offset = physical block on the
///      container; size from the inode; deleted entries via the NX block map's unlinked extents).
///
/// TODO(scaffold): once the bridge lands, `parse()` enumerates files and returns metadata only;
/// libfsapfs reads content on demand, which the engine funnels through `SecureData`.
public struct APFSParser: FilesystemParser {
    public let displayName = "APFS"
    private let reader: any RawBlockReader
    private let deviceID: DeviceID

    public init(reader: any RawBlockReader, deviceID: DeviceID) {
        self.reader = reader
        self.deviceID = deviceID
    }

    public func parse() async throws -> [RecoverableFile] {
        return []
    }
}
