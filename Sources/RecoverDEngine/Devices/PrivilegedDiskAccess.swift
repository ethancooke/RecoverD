import Foundation

/// Outline of the privileged helper daemon that performs raw `/dev/rdisk*` reads.
///
/// App Sandbox forbids the GUI from opening `/dev/disk*`. The helper is registered via
/// `SMAppService` (macOS 13+) and runs with elevated privileges, hardened but **not** sandboxed.
/// The GUI talks to it over XPC using the `@objc` protocol below; XPC requires Objective-C
/// bridging, so messages use `NSData`/`NSNumber` rather than Swift-only types.
///
/// SCAFFOLD: wiring `SMAppService.daemon(plistName:)` registration, the helper's
/// `NSXPCListener`, and code-signing constraints (helper and app must share a Team ID and
/// `com.apple.developer.smapp-service` configuration) is a tracked next step. The engine runs
/// against `URLBlockReader` (image files) until the helper is in place.
@objc public protocol PrivilegedBlockReaderProtocol {
    func readDevice(_ bsdName: NSString,
                    atOffset offset: NSNumber,
                    count: NSNumber,
                    withReply reply: @escaping (NSData, NSError?) -> Void)

    func deviceSize(_ bsdName: NSString,
                    withReply reply: @escaping (NSNumber, NSError?) -> Void)
}

/// Helpers for the names/plists the GUI and helper must agree on.
public enum PrivilegedHelper {
    public static let helperBundleIdentifier = "app.recoverd.helper"
    public static let serviceInterfaceName = "app.recoverd.helper.blockreader"
    public static let launchdPlistName = "app.recoverd.helper.plist"
}
