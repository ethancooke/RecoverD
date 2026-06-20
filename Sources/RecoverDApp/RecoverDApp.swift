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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When run as a bare executable (not inside a .app bundle), macOS doesn't give the
        // process a regular activation policy, so the window can launch hidden behind other apps
        // with no Dock icon. Force a regular, foreground app and bring the window forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // AppKit calls this on the main thread; run the synchronous wipe of all in-RAM recovered
        // content + the device fd before the process exits.
        MainActor.assumeIsolated {
            RecoverySessionViewModel.shared?.wipeAllOnQuit()
        }
    }
}
