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

        // Self-heal: older builds imaged the device to a temporary `.dmg` and didn't always clean
        // up. Sweep any such leftovers so they can't silently fill the disk. (This build never
        // writes them — reads go straight to RAM.)
        sweepStaleDeviceImages()
    }

    /// Removes stale `recoverd_*.dmg` files left by previous (imaging-based) builds in the temp dir.
    private func sweepStaleDeviceImages() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) else { return }
        for url in items where url.lastPathComponent.hasPrefix("recoverd_") && url.pathExtension == "dmg" {
            try? FileManager.default.removeItem(at: url)
        }
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
