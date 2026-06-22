import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// Covers filesystem detection: the content-string normalizer behind the device-picker label, and
/// the boot-sector probe that routes a scan to the right parser. Regression guard for FAT32 quick
/// scans finding nothing because "DOS_FAT_32" didn't match the old "fat32"/"ms-dos" string check.
@Suite("Filesystem detection")
struct FilesystemDetectionTests {

    @Test("Normalizes OS content hints into clean filesystem labels")
    func normalizesLabels() {
        #expect(DeviceInfo.filesystemLabel(from: ["DOS_FAT_32"]) == "FAT32")
        #expect(DeviceInfo.filesystemLabel(from: ["Windows_FAT_32"]) == "FAT32")
        #expect(DeviceInfo.filesystemLabel(from: ["msdos"]) == "FAT")
        #expect(DeviceInfo.filesystemLabel(from: ["DOS_FAT_16"]) == "FAT16")
        #expect(DeviceInfo.filesystemLabel(from: ["ExFAT"]) == "exFAT")
        #expect(DeviceInfo.filesystemLabel(from: ["Windows_NTFS"]) == "NTFS")
        #expect(DeviceInfo.filesystemLabel(from: ["Apple_APFS"]) == "APFS")
        #expect(DeviceInfo.filesystemLabel(from: ["Apple_HFS"]) == "HFS+")
        #expect(DeviceInfo.filesystemLabel(from: ["FDisk_partition_scheme"]) == nil)
        #expect(DeviceInfo.filesystemLabel(from: []) == nil)
    }

    @Test("Whole-disk label falls back to a partition's filesystem")
    func labelFallsBackToPartition() {
        let part = PartitionInfo(
            id: DeviceID("d1s1"), bsdName: "disk1s1", rawPath: "/dev/rdisk1s1",
            size: 1000, offset: 0, detectedFileSystems: ["DOS_FAT_32"]
        )
        let device = DeviceInfo(
            id: DeviceID("d1"), displayName: "USB", bsdName: "disk1", devicePath: "/dev/disk1",
            rawPath: "/dev/rdisk1", totalSize: 1000, blockSize: 512, isRemovable: true,
            isExternal: true, detectedFileSystems: ["FDisk_partition_scheme"], partitions: [part]
        )
        #expect(device.filesystemLabel == "FAT32")
    }

    @Test("Boot-sector probe routes FAT, exFAT, and NTFS by on-disk signature")
    func probeRoutesByBootSignature() async {
        let device = DeviceInfo(
            id: DeviceID("x"), displayName: "x", bsdName: "x", devicePath: "/x", rawPath: "/x",
            totalSize: 512, blockSize: 512, isRemovable: true, isExternal: true
        )

        // FAT32: jump byte + "FAT32   " at offset 0x52 (the case the old string check missed).
        var fat = [UInt8](repeating: 0, count: 512)
        fat[0] = 0xEB
        for (i, c) in Array("FAT32   ".utf8).enumerated() { fat[0x52 + i] = c }
        let fatParser = await probeFilesystemParser(for: device, reader: InMemoryBlockReader(fat))
        #expect(fatParser?.displayName == "FAT32")

        // exFAT / NTFS: OEM id at offset 3.
        var exfat = [UInt8](repeating: 0, count: 512)
        for (i, c) in Array("EXFAT   ".utf8).enumerated() { exfat[3 + i] = c }
        let exfatParser = await probeFilesystemParser(for: device, reader: InMemoryBlockReader(exfat))
        #expect(exfatParser?.displayName == "exFAT")

        var ntfs = [UInt8](repeating: 0, count: 512)
        for (i, c) in Array("NTFS    ".utf8).enumerated() { ntfs[3 + i] = c }
        let ntfsParser = await probeFilesystemParser(for: device, reader: InMemoryBlockReader(ntfs))
        #expect(ntfsParser?.displayName == "NTFS")

        // Unformatted noise routes nowhere.
        let none = await probeFilesystemParser(for: device,
                                               reader: InMemoryBlockReader([UInt8](repeating: 0, count: 512)))
        #expect(none == nil)
    }
}
