import SwiftUI
import AppKit
import RecoverDCore
import RecoverDEngine

struct ContentView: View {
    @State private var session = RecoverySessionViewModel()

    var body: some View {
        NavigationStack {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("RecoverD")
                .toolbar { toolbarContent }
        }
        .task {
            await session.refreshDevices()
            session.startDevicePolling()
        }
        .onChange(of: session.showInternalDevices) { _, _ in
            Task { await session.refreshDevices() }
        }
        .onDisappear {
            session.stopDevicePolling()
            Task { await session.clear() }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if let error = session.lastError {
                errorBanner(error)
            }
            switch session.progress.phase {
            case .discovering, .parsing, .carving, .finalizing:
                ScanProgressView(session: session)
            case .complete, .cancelled, .failed:
                if let result = session.result, !result.files.isEmpty {
                    ResultBrowserView(session: session, result: result)
                } else {
                    emptyState(message: phaseMessage(session.progress.phase))
                }
            default:
                DevicePickerView(session: session)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 0) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.red.opacity(0.08))
            Divider()
        }
    }

    private func phaseMessage(_ phase: ScanPhase) -> String {
        switch phase {
        case .complete: "Scan complete — no recoverable files found."
        case .cancelled: "Scan cancelled."
        case .failed: "Scan failed."
        default: "No results yet."
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
            Button("Back to devices") {
                Task { await session.clear() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await session.refreshDevices() }
            } label: {
                Label("Refresh devices", systemImage: "arrow.clockwise")
            }
            .help("Re-scan for connected external drives and SD cards")

            Button {
                openImageFile()
            } label: {
                Label("Open image…", systemImage: "doc")
            }
            .help("Open a .dmg or raw disk image file to scan without needing a physical device")

            Toggle("Show internal drives", isOn: $session.showInternalDevices)
                .toggleStyle(.checkbox)
                .help("Show the Mac's internal boot disk and APFS container (not recommended scan targets)")

            if session.isScanning || session.result != nil {
                Button {
                    Task { await session.clear() }
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .help("Discard all in-memory results and return to the device picker (securely wipes RAM)")
            }
        }
    }

    private func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage, .data, .item]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose a disk image or raw file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.startScanOnImageFile(url) }
    }
}
