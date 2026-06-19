import Foundation

/// Uniquely identifies a discovered block device across the run.
public struct DeviceID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// Uniquely identifies a recoverable file within a scan. Stable across the run, not persisted.
public struct FileID: Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// How a device is physically connected to the Mac. Drives the icon shown in the picker.
public enum DeviceConnection: String, Sendable, Hashable, CaseIterable {
    case usb
    case sdCard
    case thunderbolt
    case fireWire
    case internalDisk
    case imageFile
    case network
    case unknown

    public var displayName: String {
        switch self {
        case .usb: "USB"
        case .sdCard: "SD Card"
        case .thunderbolt: "Thunderbolt"
        case .fireWire: "FireWire"
        case .internalDisk: "Internal"
        case .imageFile: "Image File"
        case .network: "Network"
        case .unknown: "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .usb: "externaldrive.connected.to.line.below"
        case .sdCard: "sdcard"
        case .thunderbolt: "bolt.fill"
        case .fireWire: "externaldrive"
        case .internalDisk: "internaldrive"
        case .imageFile: "doc.richtext"
        case .network: "externaldrive.badge.wifi"
        case .unknown: "externaldrive"
        }
    }
}

/// A partition/slice on a whole disk. Read-only metadata; the engine scans whole disks or
/// specific partitions depending on the user's selection. Supports recursive nesting for
/// container schemes like APFS (e.g. disk3s1 contains disk3s1s1).
public struct PartitionInfo: Identifiable, Hashable, Sendable {
    public let id: DeviceID
    public var bsdName: String
    public var rawPath: String
    public var size: Int64
    public var offset: Int64
    public var volumeName: String?
    public var mountPoint: URL?
    public var detectedFileSystems: [String]
    public var subpartitions: [PartitionInfo]

    public init(
        id: DeviceID,
        bsdName: String,
        rawPath: String,
        size: Int64,
        offset: Int64,
        volumeName: String? = nil,
        mountPoint: URL? = nil,
        detectedFileSystems: [String] = [],
        subpartitions: [PartitionInfo] = []
    ) {
        self.id = id
        self.bsdName = bsdName
        self.rawPath = rawPath
        self.size = size
        self.offset = offset
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.detectedFileSystems = detectedFileSystems
        self.subpartitions = subpartitions
    }

    public var formattedSize: String {
        DeviceInfo.formatBytes(size)
    }

    public var hasSubpartitions: Bool {
        !subpartitions.isEmpty
    }
}

/// Metadata describing a connected block device. No content, no path on the host beyond the
/// BSD device node (which the privileged helper is responsible for opening).
public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public let id: DeviceID
    public var displayName: String
    public var bsdName: String
    public var devicePath: String
    public var rawPath: String
    public var totalSize: Int64
    public var blockSize: Int
    public var isRemovable: Bool
    public var isExternal: Bool
    public var isWhole: Bool
    public var detectedFileSystems: [String]
    public var vendorName: String?
    public var modelName: String?
    public var serialNumber: String?
    public var connection: DeviceConnection
    public var busProtocol: String?
    public var volumeName: String?
    public var mountPoint: URL?
    public var partitions: [PartitionInfo]

    public init(
        id: DeviceID,
        displayName: String,
        bsdName: String,
        devicePath: String,
        rawPath: String,
        totalSize: Int64,
        blockSize: Int,
        isRemovable: Bool,
        isExternal: Bool,
        isWhole: Bool = true,
        detectedFileSystems: [String] = [],
        vendorName: String? = nil,
        modelName: String? = nil,
        serialNumber: String? = nil,
        connection: DeviceConnection = .unknown,
        busProtocol: String? = nil,
        volumeName: String? = nil,
        mountPoint: URL? = nil,
        partitions: [PartitionInfo] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bsdName = bsdName
        self.devicePath = devicePath
        self.rawPath = rawPath
        self.totalSize = totalSize
        self.blockSize = blockSize
        self.isRemovable = isRemovable
        self.isExternal = isExternal
        self.isWhole = isWhole
        self.detectedFileSystems = detectedFileSystems
        self.vendorName = vendorName
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.connection = connection
        self.busProtocol = busProtocol
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.partitions = partitions
    }

    public var isLikelyExternalRecoveryTarget: Bool {
        isExternal || isRemovable
    }

    /// A human-readable size string.
    public var formattedSize: String {
        DeviceInfo.formatBytes(totalSize)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useTB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
