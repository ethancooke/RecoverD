import SwiftUI
import AppKit
import RecoverDCore
import RecoverDEngine

/// Main, UI-driving model. `@Observable` (macOS 14+) for SwiftUI, `@MainActor` so all mutations
/// happen on the main thread. Holds the `ScanEngine` actor and bridges its async updates into
/// observable properties.
///
/// SECURITY: thumbnails and previews live in `thumbnails` (RAM only). `clear()`/quit wipes them.
/// No recovered *content* is stored here — only rendered `NSImage` thumbnails and metadata.
@MainActor
@Observable
final class RecoverySessionViewModel {

    // MARK: Observable UI state

    var devices: [DeviceInfo] = []
    var selectedDevice: DeviceInfo?
    var scanMode: ScanMode = .quick
    var progress: ScanProgress = ScanProgress()
    var result: ScanResult?
    var lastError: String?
    var thumbnails: [FileID: NSImage] = [:]
    var exportProgress: ExportProgress?
    var lastExportedFiles: [URL] = []
    var imagingProgress: ImagingProgress?
    var showInternalDevices: Bool = false
    private var lastShowInternal: Bool = false

    // MARK: Engine + transient state

    let engine = ScanEngine()
    private var reader: (any RawBlockReader)?
    private var progressTask: Task<Void, Never>?
    private var devicePollTask: Task<Void, Never>?

    var isScanning: Bool {
        switch progress.phase {
        case .discovering, .parsing, .carving, .finalizing: true
        default: false
        }
    }

    init() {}

    // Cancellation is handled by stopDevicePolling()/clear(); tasks also self-cancel via
    // Task.isCancelled checks. No deinit body is needed (and @MainActor deinits can't touch
    // isolated state in Swift 6).

    // MARK: Device discovery

    /// Refreshes the device list once. Discovery is read-only (IOKit registry + DiskArbitration
    /// description) and never opens `/dev/disk*`.
    func refreshDevices() async {
        let discovered = showInternalDevices
            ? await DeviceDiscovery.discoverAllDevices()
            : await DeviceDiscovery.discoverExternalDevices()
        // Always update when the visibility toggle changed since the last refresh, even if the
        // resulting list happens to be equal (e.g. no internal drives exist).
        if discovered != devices || lastShowInternal != showInternalDevices {
            devices = discovered
            lastShowInternal = showInternalDevices
            if !devices.contains(where: { $0.id == selectedDevice?.id }) {
                selectedDevice = devices.first(where: { $0.isLikelyExternalRecoveryTarget }) ?? devices.first
            }
        }
    }

    /// Starts periodic device polling so newly connected drives appear automatically without
    /// the user clicking Refresh. Stops when the view disappears or a scan starts.
    func startDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = Task { [weak self] in
            while !Task.isCancelled {
                if Task.isCancelled { break }
                await self?.refreshDevices()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopDevicePolling() {
        devicePollTask?.cancel()
        devicePollTask = nil
    }

    // MARK: Scanning

    /// Attempts to scan a real external device. Raw `/dev/rdisk*` access needs the privileged
    /// helper (not yet wired up); until then this will surface a helpful error and point the
    /// user at File ▸ Open Image… to exercise the engine against a `.dmg`/`.img`.
    func startScanOnSelectedDevice() async {
        guard let device = selectedDevice else { lastError = "Select a device first."; return }
        do {
            let url = URL(fileURLWithPath: device.rawPath)
            let r = try await URLBlockReader(url: url, blockSize: device.blockSize)
            await startScan(device: device, reader: r)
        } catch {
            lastError = "Cannot open \(device.rawPath) directly — raw device access needs the privileged helper (not wired up yet). To try the engine now, use File ▸ Open Image… and pick a .dmg/.img. (\(error.localizedDescription))"
        }
    }

    /// Scans a user-chosen image file — the no-privilege, test-friendly path.
    func startScanOnImageFile(_ url: URL) async {
        do {
            let r = try await URLBlockReader(url: url)
            let device = DeviceInfo(
                id: DeviceID("image:\(url.lastPathComponent)"),
                displayName: url.lastPathComponent,
                bsdName: "(image)",
                devicePath: url.path,
                rawPath: url.path,
                totalSize: await r.totalSize,
                blockSize: await r.blockSize,
                isRemovable: true,
                isExternal: true,
                isWhole: true,
                detectedFileSystems: [],
                connection: .imageFile
            )
            await startScan(device: device, reader: r)
        } catch {
            lastError = "Could not open image: \(error.localizedDescription)"
        }
    }

    private func startScan(device: DeviceInfo, reader: any RawBlockReader) async {
        self.reader = reader
        result = nil
        lastError = nil
        thumbnails.removeAll()
        beginProgressSubscription()
        await engine.startScan(device: device, mode: scanMode, reader: reader)
    }

    private func beginProgressSubscription() {
        progressTask?.cancel()
        let engine = self.engine
        progressTask = Task { [weak self] in
            let stream = await engine.subscribeProgress()
            for await update in stream {
                guard let self else { return }
                self.progress = update
                switch update.phase {
                case .complete, .cancelled, .failed:
                    self.result = await self.engine.snapshot()
                default:
                    break
                }
            }
        }
    }

    func pause() async { await engine.pause() }
    func resume() async { await engine.resume() }
    func cancel() async { await engine.cancel() }

    func clear() async {
        progressTask?.cancel()
        progressTask = nil
        thumbnails.removeAll()
        result = nil
        progress = ScanProgress()
        lastError = nil
        await engine.clear()
    }

    func snapshot() async {
        result = await engine.snapshot()
    }

    // MARK: Thumbnails (in-memory, on-demand)

    func thumbnail(for file: RecoverableFile) -> NSImage? {
        guard thumbnails[file.id] == nil, file.fileType == .image else {
            return thumbnails[file.id]
        }
        Task { await generateThumbnail(for: file) }
        return thumbnails[file.id]
    }

    private func generateThumbnail(for file: RecoverableFile) async {
        do {
            let content = try await engine.readContent(for: file, maxLength: 8 * 1024 * 1024)
            defer { content.wipe() }
            if let image = content.withUnsafeBytes({ buf in NSImage(data: Data(buf)) }) {
                thumbnails[file.id] = image
            }
        } catch {
            // Best-effort; ignore.
        }
    }

    // MARK: Export (the only content-writing path)

    func exportSelected(_ files: [RecoverableFile], to directory: URL) async {
        guard let reader else { lastError = "No source is loaded."; return }
        lastError = nil
        exportProgress = nil
        lastExportedFiles = []
        let (stream, cont) = AsyncStream<ExportProgress>.makeStream()
        let manager = ExportManager()

        let work = Task<[URL], Error> {
            defer { cont.finish() }
            return try await manager.export(files: files, from: reader, to: directory, progress: cont)
        }

        for await p in stream {
            exportProgress = p
        }

        do {
            lastExportedFiles = try await work.value
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Quit / wipe

    func wipeAllOnQuit() {
        // Best-effort on quit; deterministic secure-on-quit is a tracked item.
        progressTask?.cancel()
        Task { [weak self] in await self?.clear() }
    }
}
