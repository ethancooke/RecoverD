import Foundation
import IOKit
import DiskArbitration
import RecoverDCore

/// Discovers connected block devices using IOKit + DiskArbitration.
///
/// Discovery reads only registry metadata and DiskArbitration descriptions — it does **not**
/// open `/dev/disk*`, so it needs no privilege and is safe to run from the sandboxed GUI. Raw
/// reads of a chosen device still go through the privileged helper.
///
/// What it finds:
///   - **Whole disks** that are external/removable (USB thumb drives, SD cards, external
///     HDDs/SSDs). Non-removable-but-external devices (e.g. a USB enclosure reporting itself as
///     fixed) are included too, with `isInternal` false. The Mac's internal boot disk and APFS
///     container are excluded from the external list but available via `discoverAllDevices()`.
///   - Each whole disk carries a recursive `partitions` tree built from the actual IORegistry
///     parent chain — not string matching. APFS volumes inside a container partition nest
///     correctly (e.g. disk3s1 → disk3s1s1).
///   - Connection type (USB / SD / Thunderbolt / FireWire / internal) is detected by walking
///     the IOService parent chain and matching the provider class name.
public enum DeviceDiscovery {

    // IOKit IOMedia registry key values (C macros not imported into Swift; use literals).
    private static let kMediaClass = "IOMedia"
    private static let kBSDName = "BSD Name"
    private static let kSize = "Size"
    private static let kPreferredBlockSize = "Preferred Block Size"
    private static let kWhole = "Whole"
    private static let kLeaf = "Leaf"
    private static let kRemovable = "Removable"
    private static let kEjectable = "Ejectable"
    private static let kContent = "Content"
    private static let kServicePlane = "IOService"

    /// Discovers external/removable devices suitable as recovery targets. Excludes the internal
    /// boot disk and internal APFS container.
    public static func discoverExternalDevices() async -> [DeviceInfo] {
        await discoverAllDevices().filter { $0.isLikelyExternalRecoveryTarget }
    }

    /// Discovers all whole-disk block devices (external + internal). Use this for diagnostics or
    /// when the user opts into scanning a non-removable device.
    public static func discoverAllDevices() async -> [DeviceInfo] {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching(kMediaClass) else { return [] }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        // First pass: collect every IOMedia entry with its properties and service handle.
        var allMedia: [(service: io_registry_entry_t, props: [String: Any])] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = cfProperties(for: service) {
                allMedia.append((service: service, props: props))
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        defer { for entry in allMedia { IOObjectRelease(entry.service) } }

        // For each non-whole IOMedia, find its immediate IOMedia parent by walking up the
        // IORegistry. This gives us the real tree, not a string-matching guess.
        var parentMap: [String: String] = [:] // childBSDName -> parentBSDName
        for entry in allMedia {
            let isWhole = (entry.props[kWhole] as? Bool) == true
            guard !isWhole else { continue }
            let childBSD = entry.props[kBSDName] as? String ?? ""
            guard !childBSD.isEmpty else { continue }
            if let parentBSD = findImmediateIOMediaParent(for: entry.service) {
                parentMap[childBSD] = parentBSD
            }
        }

        // DiskArbitration descriptions for volume/mount info.
        let session = DASessionCreate(kCFAllocatorDefault)
        let diskDescriptions = readDiskArbitrationDescriptions(
            session: session, allMedia: allMedia
        )

        // Build DeviceInfo for each whole disk, recursively attaching its partition tree.
        var results: [DeviceInfo] = []
        for entry in allMedia {
            let isWhole = (entry.props[kWhole] as? Bool) == true
            guard isWhole else { continue }
            guard let info = buildWholeDisk(
                props: entry.props,
                service: entry.service,
                allMedia: allMedia,
                parentMap: parentMap,
                diskDescriptions: diskDescriptions
            ) else { continue }
            results.append(info)
        }

        return results.sorted { sortKey($0) < sortKey($1) }
    }

    private static func sortKey(_ d: DeviceInfo) -> String {
        let prefix = d.isExternal ? "0" : "1"
        return "\(prefix)-\(d.bsdName)"
    }

    // MARK: IORegistry parent walking

    /// Walks up the IOService plane from `entry` and returns the BSD name of the first ancestor
    /// that is itself an IOMedia (i.e. the immediate partition parent). Returns nil if the entry
    /// is a direct child of the whole disk with no intermediate IOMedia (the common case), or if
    /// no IOMedia ancestor is found.
    private static func findImmediateIOMediaParent(for entry: io_registry_entry_t) -> String? {
        var current = entry
        var depth = 0
        while depth < 20 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            if current != entry { IOObjectRelease(current) }
            defer { IOObjectRelease(parent) }

            // Check if this parent is an IOMedia (has a BSD Name and is the IOMedia class).
            if let props = cfProperties(for: parent) {
                if let bsdName = props[kBSDName] as? String, !bsdName.isEmpty {
                    // Confirm it's IOMedia by checking for IOMedia-specific keys.
                    let hasWhole = props[kWhole] != nil
                    let hasLeaf = props[kLeaf] != nil
                    if hasWhole || hasLeaf {
                        return bsdName
                    }
                }
            }
            current = parent
            depth += 1
        }
        return nil
    }

    // MARK: Whole-disk builder

    private static func buildWholeDisk(
        props: [String: Any],
        service: io_registry_entry_t,
        allMedia: [(service: io_registry_entry_t, props: [String: Any])],
        parentMap: [String: String],
        diskDescriptions: [String: [String: Any]]
    ) -> DeviceInfo? {
        let bsdName = props[kBSDName] as? String ?? ""
        guard !bsdName.isEmpty else { return nil }

        let size = (props[kSize] as? UInt64).map(Int64.init) ?? 0
        let blockSize = (props[kPreferredBlockSize] as? UInt64).map(Int.init) ?? 512
        let removable = (props[kRemovable] as? Bool) == true
        let ejectable = (props[kEjectable] as? Bool) == true

        let (connection, busProtocol, isInternal) = detectConnection(for: service)
        // A device is external if:
        //   - It's not internal, AND
        //   - It's removable/ejectable, OR has a known external bus type (USB/SD/TB/FW),
        //     OR has an unknown bus type (default to showing it — better to show than hide).
        let isExternal: Bool
        if isInternal {
            isExternal = false
        } else {
            switch connection {
            case .usb, .sdCard, .thunderbolt, .fireWire, .imageFile, .network:
                isExternal = true
            case .unknown:
                isExternal = removable || ejectable || true
            case .internalDisk:
                isExternal = false
            }
        }

        let parentProps = parentProperties(for: service)
        let vendor = (props["Vendor Name"] as? String)
            ?? (parentProps?["Vendor Name"] as? String)
            ?? (props["USB Vendor Name"] as? String)
        let model = (props["Product Name"] as? String)
            ?? (parentProps?["Product Name"] as? String)
            ?? (props["USB Product Name"] as? String)
        let serial = (props["USB Serial Number"] as? String)
            ?? (parentProps?["USB Serial Number"] as? String)
            ?? (props["Serial Number"] as? String)

        let daDesc = diskDescriptions[bsdName] ?? [:]
        let volumeName = (daDesc["DAVolumeName"] as? String)
            ?? (props["Volume Name"] as? String)
        let mountPath = (daDesc["DAMountPath"] as? String).map { URL(fileURLWithPath: $0) }
        let detectedFS = detectedFileSystems(media: props, daDesc: daDesc)

        // Build the recursive partition tree: only direct children (parent is this whole disk)
        // are top-level; their subpartitions nest recursively.
        let partitions = buildPartitionTree(
            parentBSDName: bsdName,
            allMedia: allMedia,
            parentMap: parentMap,
            diskDescriptions: diskDescriptions
        )

        let displayName = makeDisplayName(
            bsdName: bsdName, volumeName: volumeName,
            vendor: vendor, model: model, size: size, connection: connection
        )

        return DeviceInfo(
            id: DeviceID("iokit:\(bsdName)"),
            displayName: displayName,
            bsdName: bsdName,
            devicePath: "/dev/\(bsdName)",
            rawPath: "/dev/r\(bsdName)",
            totalSize: size,
            blockSize: blockSize,
            isRemovable: removable,
            isExternal: isExternal,
            isWhole: true,
            detectedFileSystems: detectedFS,
            vendorName: vendor,
            modelName: model,
            serialNumber: serial,
            connection: connection,
            busProtocol: busProtocol,
            volumeName: volumeName,
            mountPoint: mountPath,
            partitions: partitions
        )
    }

    // MARK: Recursive partition tree builder

    /// Builds the partition tree for a given parent (a whole disk or a container partition).
    /// A partition belongs to this parent if:
    ///   - Its immediate IOMedia parent (from `parentMap`) is this parent's BSD name, OR
    ///   - It has no intermediate IOMedia parent (parentMap entry is nil) and its BSD name
    ///     starts with the parent's BSD name + "s" (the standard slice naming: disk3 → disk3s1).
    ///
    /// This correctly handles:
    ///   - Direct slices: disk3s1 is a child of disk3 (no intermediate IOMedia parent, BSD prefix match).
    ///   - APFS volumes: disk3s1s1 has parentMap["disk3s1s1"] = "disk3s1", so it nests under disk3s1.
    private static func buildPartitionTree(
        parentBSDName: String,
        allMedia: [(service: io_registry_entry_t, props: [String: Any])],
        parentMap: [String: String],
        diskDescriptions: [String: [String: Any]]
    ) -> [PartitionInfo] {
        var parts: [PartitionInfo] = []

        for entry in allMedia {
            let isWhole = (entry.props[kWhole] as? Bool) == true
            guard !isWhole else { continue }

            let childBSD = entry.props[kBSDName] as? String ?? ""
            guard !childBSD.isEmpty else { continue }

            // Determine if this entry is a direct child of parentBSDName.
            let isChild: Bool
            if let intermediateParent = parentMap[childBSD] {
                // Has an intermediate IOMedia parent — it's a direct child only if that
                // intermediate parent IS this parent.
                isChild = (intermediateParent == parentBSDName)
            } else {
                // No intermediate IOMedia parent — use BSD naming convention as fallback.
                // disk3s1 is a child of disk3, disk3s1s1 is NOT (it would have an intermediate).
                isChild = childBSD.hasPrefix("\(parentBSDName)s")
                    && !childBSD.dropFirst(parentBSDName.count + 1).contains("s")
            }
            guard isChild else { continue }

            let size = (entry.props[kSize] as? UInt64).map(Int64.init) ?? 0
            let daDesc = diskDescriptions[childBSD] ?? [:]
            let volumeName = (daDesc["DAVolumeName"] as? String)
                ?? (entry.props["Volume Name"] as? String)
            let mountPath = (daDesc["DAMountPath"] as? String).map { URL(fileURLWithPath: $0) }
            let fs = detectedFileSystems(media: entry.props, daDesc: daDesc)
            let offset = (entry.props["Base Offset"] as? UInt64).map(Int64.init) ?? 0

            // Recursively build subpartitions (e.g. APFS volumes inside this container partition).
            let subparts = buildPartitionTree(
                parentBSDName: childBSD,
                allMedia: allMedia,
                parentMap: parentMap,
                diskDescriptions: diskDescriptions
            )

            parts.append(PartitionInfo(
                id: DeviceID("iokit:\(childBSD)"),
                bsdName: childBSD,
                rawPath: "/dev/r\(childBSD)",
                size: size,
                offset: offset,
                volumeName: volumeName,
                mountPoint: mountPath,
                detectedFileSystems: fs,
                subpartitions: subparts
            ))
        }

        return parts.sorted { $0.bsdName < $1.bsdName }
    }

    // MARK: Connection-type detection

    /// Determines the connection type and whether the device is internal.
    ///
    /// Primary signal: the `IOMediaIcon.IOBundleResourceFile` property on the IOMedia entry
    /// itself — IOKit sets this to `"Internal.icns"` for built-in storage and `"Removable.icns"`
    /// for external/removable media. This is more reliable on Apple Silicon than walking the
    /// parent chain (the internal NVMe controller sits behind `RTBuddyService`/`AppleANS3`,
    /// which doesn't match the old SATA/NVMe class-name heuristics).
    ///
    /// Secondary signals:
    ///   - APFS container/synthetic whole disks (content = `EF57347C-...`, the APFS UUID) with
    ///     no icon and `parentClass = IOMedia` are internal virtual disks.
    ///   - The IOService parent chain identifies the bus type (USB, SD, Thunderbolt, FireWire).
    private static func detectConnection(for entry: io_registry_entry_t) -> (DeviceConnection, String?, Bool) {
        guard let ownProps = cfProperties(for: entry) else {
            return detectBusType(for: entry)
        }

        // 1. Check the IOMedia's own icon property for the internal/removable marker.
        if let iconDict = ownProps["IOMediaIcon"] as? [String: Any],
           let resourceFile = iconDict["IOBundleResourceFile"] as? String {
            if resourceFile.lowercased().contains("internal") {
                let (_, busProtocol, _) = detectBusType(for: entry)
                return (.internalDisk, busProtocol, true)
            }
            if resourceFile.lowercased().contains("removable") {
                let (busConnection, busProtocol, _) = detectBusType(for: entry)
                return (busConnection, busProtocol, false)
            }
        }

        // 2. Check for APFS container / synthetic virtual disks. These are whole disks whose
        //    content is the APFS container UUID (EF57347C-0000-11AA-AA11-00306543ECAC) and whose
        //    IOProviderClass is "IOMedia" (a virtual layer, not a physical device). They have no
        //    IOMediaIcon and aren't flagged removable, but they're internal.
        let content = (ownProps["Content"] as? String ?? "").uppercased()
        let isAPFSContainer = content.contains("EF57347C-0000-11AA-AA11-00306543ECAC")
            || content.contains("41504653-0000-11AA-AA11-00306543ECAC")
        let removable = (ownProps["Removable"] as? Bool) == true
        if isAPFSContainer && !removable {
            return (.internalDisk, "APFS", true)
        }

        // 3. Fall back to parent-chain walking for bus type + internal detection.
        return detectBusType(for: entry)
    }

    /// Walks the IOService parent chain to identify the bus type (USB, SD, Thunderbolt,
    /// FireWire, or internal NVMe/SATA/APFS). Returns (connection, busProtocol, isInternal).
    private static func detectBusType(for entry: io_registry_entry_t) -> (DeviceConnection, String?, Bool) {
        var current: io_registry_entry_t = entry
        var depth = 0
        while depth < 16 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kServicePlane, &parent) == KERN_SUCCESS else {
                break
            }
            // Release the previous iteration's parent (if not the original entry) BEFORE
            // reassigning current. Do NOT release `parent` here — it becomes `current` for the
            // next iteration and is released at the top of the next iteration or after the loop.
            if current != entry { IOObjectRelease(current) }

            if let props = cfProperties(for: parent) {
                if let className = props["IOProviderClass"] as? String {
                    let lower = className.lowercased()
                    if lower.contains("usb") {
                        if let deviceProps = props["USB Product Name"] as? String,
                           deviceProps.lowercased().contains("sd") || deviceProps.lowercased().contains("card reader") {
                            IOObjectRelease(parent)
                            return (.sdCard, "USB", false)
                        }
                        IOObjectRelease(parent)
                        return (.usb, "USB", false)
                    }
                    if lower.contains("sdhost") || lower.contains("sdio") || lower.contains("sd ") {
                        IOObjectRelease(parent)
                        return (.sdCard, "SD", false)
                    }
                    if lower.contains("thunderbolt") || lower.contains("applethunderbolt") {
                        IOObjectRelease(parent)
                        return (.thunderbolt, "Thunderbolt", false)
                    }
                    if lower.contains("firewire") {
                        IOObjectRelease(parent)
                        return (.fireWire, "FireWire", false)
                    }
                }
                if let content = props["Content"] as? String, content.lowercased().contains("apfs") {
                    IOObjectRelease(parent)
                    return (.internalDisk, "APFS", true)
                }
                if let className = props["IOClassName"] as? String,
                   className.lowercased().contains("nvme") || className.lowercased().contains("sata") {
                    IOObjectRelease(parent)
                    return (.internalDisk, className, true)
                }
            }

            current = parent
            depth += 1
        }
        // Release the last `current` if it's not the original entry (don't release the caller's handle).
        if current != entry { IOObjectRelease(current) }
        return (.unknown, nil, false)
    }

    // MARK: DiskArbitration

    private static func readDiskArbitrationDescriptions(
        session: DASession?,
        allMedia: [(service: io_registry_entry_t, props: [String: Any])]
    ) -> [String: [String: Any]] {
        guard let session else { return [:] }
        var descriptions: [String: [String: Any]] = [:]
        for entry in allMedia {
            guard let bsdName = entry.props[kBSDName] as? String, !bsdName.isEmpty else { continue }
            let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(bsdName)")
            guard let disk else { continue }
            if let desc = DADiskCopyDescription(disk) as? [String: Any] {
                descriptions[bsdName] = desc
            }
        }
        return descriptions
    }

    // MARK: IOKit helpers

    private static func cfProperties(for entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func parentProperties(for entry: io_registry_entry_t) -> [String: Any]? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(parent) }
        return cfProperties(for: parent)
    }

    private static func detectedFileSystems(media: [String: Any], daDesc: [String: Any]) -> [String] {
        var fs: [String] = []
        if let content = media[kContent] as? String, !content.isEmpty {
            fs.append(content)
        }
        if let daContent = daDesc["DAVolumeKind"] as? String, !daContent.isEmpty, !fs.contains(daContent) {
            fs.append(daContent)
        }
        if let daContent = daDesc["DADiskContent"] as? String, !daContent.isEmpty, !fs.contains(daContent) {
            fs.append(daContent)
        }
        return fs
    }

    // MARK: Display

    private static func makeDisplayName(
        bsdName: String, volumeName: String?, vendor: String?, model: String?,
        size: Int64, connection: DeviceConnection
    ) -> String {
        let parts = [vendor, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let hardware = parts.isEmpty ? "Disk \(bsdName)" : parts.joined(separator: " ")
        let volPart = (volumeName?.trimmingCharacters(in: .whitespaces)).map { " — \($0)" } ?? ""
        return "\(hardware)\(volPart) — \(DeviceInfo.formatBytes(size))"
    }
}
