import Foundation
import Testing
@testable import RecoverDEngine
@testable import RecoverDCore

/// TEMP diagnostic — prints how real devices on this machine get classified.
@Test func diagnosticPrintDiscovery() async {
    let all = await DeviceDiscovery.discoverAllDevices()
    print("=== discoverAllDevices (\(all.count)) ===")
    for d in all {
        print("\(d.bsdName)\tconn=\(d.connection.rawValue)\tisExternal=\(d.isExternal)\tisRemovable=\(d.isRemovable)\trecoveryTarget=\(d.isLikelyExternalRecoveryTarget)\tname=\(d.displayName)")
    }
    let ext = await DeviceDiscovery.discoverExternalDevices()
    print("=== discoverExternalDevices (\(ext.count)) ===")
    for d in ext {
        print("\(d.bsdName)\tconn=\(d.connection.rawValue)\tname=\(d.displayName)")
    }
}
