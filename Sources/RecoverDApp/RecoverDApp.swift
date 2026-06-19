import SwiftUI
import AppKit

@main
struct RecoverDApp: App {
    @NSApplicationDelegateAdaptor(RecoverDAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("RecoverD") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Handles app termination so in-memory recovery data is wiped on quit.
///
/// NOTE(scaffold): this is a best-effort nudge. A deterministic, app-wide wipe service that
/// guarantees zeroing of all `SecureData` buffers and thumbnail caches before exit is a tracked
/// hardening item (e.g. a shared `MemoryHygiene` actor that every holder registers with).
final class RecoverDAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // No-op for now; ContentView clears its session on disappear. See note above.
    }
}
