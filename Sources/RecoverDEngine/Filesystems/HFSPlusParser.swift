import Foundation
import RecoverDCore

/// HFS+ / HFS file-system parser (basic).
///
/// HFS+ uses a catalog B-tree keyed by (parent CNID, name). Deleted files leave catalog nodes
/// marked free until reused; the extent overflow file maps file extents. A basic parser walks
/// the catalog B-tree for live files and recovers deleted nodes where their extents still
/// resolve. The volume header lives at offset 1024; the alternate volume header near the end.
///
/// TODO(scaffold): parse the volume header, locate the catalog file, traverse the catalog
/// B-tree, and recover deleted catalog records whose extent runs still resolve to allocated
/// blocks. Full HFS+ is large; this is the lowest-priority parser.
public struct HFSPlusParser: FilesystemParser {
    public let displayName = "HFS+"
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
