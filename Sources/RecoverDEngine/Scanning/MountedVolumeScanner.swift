import Foundation
import RecoverDCore

/// Scans a mounted volume's filesystem for live files via FileManager.
///
/// This is the no-privilege path: when a volume is already mounted (e.g. `/Volumes/CANON_DC`),
/// we can enumerate all files through the normal filesystem API. This finds live (non-deleted)
/// files — useful when the user wants to recover files from a working but failing drive, or
/// browse what's on a volume before attempting deleted-file recovery.
///
/// For deleted files and carving, the engine needs raw device access (an authorized `RawFDReader`
/// over `/dev/rdiskN`, or an image file). The `ScanEngine` uses both: filesystem scan for live
/// files + raw scan for deleted/carved files when available.
///
/// SECURITY: reads only file metadata (name, size, dates) through the filesystem. File *content*
/// is never read during scanning — it's fetched on demand at preview/export time.
public struct MountedVolumeScanner {
    private let mountPoint: URL
    private let deviceID: DeviceID

    public init(mountPoint: URL, deviceID: DeviceID) {
        self.mountPoint = mountPoint
        self.deviceID = deviceID
    }

    public func scan() async -> [RecoverableFile] {
        var results: [RecoverableFile] = []
        let fm = FileManager.default

        func enumerate(directory: URL, parentPath: String) {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for entry in entries {
                let name = entry.lastPathComponent
                let relativePath = parentPath.isEmpty ? name : "\(parentPath)/\(name)"

                let values = try? entry.resourceValues(forKeys: [
                    .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey
                ])

                let isDir = values?.isDirectory ?? false
                let size = Int64(values?.fileSize ?? 0)

                if isDir {
                    // Skip system directories that aren't user content
                    let skip = ["System Volume Information", ".fseventsd", ".Trashes", "LOST.DIR"]
                    if !skip.contains(name) {
                        enumerate(directory: entry, parentPath: relativePath)
                    }
                } else if size > 0 {
                    // Get the device-relative byte offset if possible (for live files we use
                    // the file path for content reading, not byte offsets)
                    let file = RecoverableFile(
                        id: FileID("mounted:\(relativePath)"),
                        displayName: relativePath,
                        originalPath: relativePath,
                        fileType: inferFileTypeFromName(name),
                        size: size,
                        byteOffset: 0, // Mounted files are read by path, not offset
                        allocationStatus: .live,
                        creationDate: values?.creationDate,
                        modificationDate: values?.contentModificationDate,
                        deletionDate: nil,
                        sourceDeviceID: deviceID,
                        confidence: 1.0,
                        signatureMatch: nil,
                        extents: nil
                    )
                    results.append(file)
                }
            }
        }

        enumerate(directory: mountPoint, parentPath: "")
        return results
    }
}
