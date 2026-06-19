import SwiftUI
import AppKit
import AVFoundation
import RecoverDCore
import RecoverDEngine

/// How the current scan is accessing the source device.
enum ScanStrategy: String {
    case unknown
    case mountedFilesystem       // scanning via mount point (live files only)
    case mountedFilesystemWithRaw // mounted filesystem + authorized raw reads (live + deleted + carved)
    case authorizedRaw           // raw device read via admin auth dialog (no mount)
    case imageFile               // .dmg/.img file (no privilege needed)

    var displayName: String {
        switch self {
        case .unknown: "—"
        case .mountedFilesystem: "Filesystem scan (mounted volume)"
        case .mountedFilesystemWithRaw: "Full scan (filesystem + raw device)"
        case .authorizedRaw: "Raw device scan (admin authorized)"
        case .imageFile: "Image file scan"
        }
    }
}

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
    var thumbnailLoading: Set<FileID> = []
    var previewFile: RecoverableFile?
    var exportProgress: ExportProgress?
    var lastExportedFiles: [URL] = []
    var imagingProgress: ImagingProgress?
    var showInternalDevices: Bool = false
    var scanStrategy: ScanStrategy = .unknown
    var isImaging: Bool = false
    var imagingBytesDone: Int64 = 0
    var imagingBytesTotal: Int64 = 0
    private var lastShowInternal: Bool = false

    // MARK: Engine + transient state

    let engine = ScanEngine()
    private var reader: (any RawBlockReader)?
    private var rawReader: RawFDReader?
    private var imageReader: DeviceImageReader?
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

    /// Returns the best BSD name + size to image. Prefers a partition with a known file system
    /// (so the parser sees the FS boot sector, not the partition table). Falls back to the whole disk.
    private func bestPartitionToScan(_ device: DeviceInfo) -> (String, Int64) {
        // Find the first partition with a recognizable file system
        let fsKeywords = ["fat", "exfat", "hfs", "apfs", "ms-dos", "ntfs"]
        if let part = device.partitions.first(where: { p in
            p.detectedFileSystems.contains { fs in
                fsKeywords.contains { fs.lowercased().contains($0) }
            }
        }) {
            return (part.bsdName, part.size)
        }
        // Fall back to the first partition that isn't a system type
        if let part = device.partitions.first(where: { !$0.detectedFileSystems.isEmpty }) {
            return (part.bsdName, part.size)
        }
        // No partitions — scan the whole disk
        return (device.bsdName, device.totalSize)
    }

    // MARK: Scanning

    /// Scans a real external device by reading its raw partition directly.
    ///   1. If the volume is mounted, enumerate live files via the filesystem (no privilege)
    ///      AND read the raw partition for deleted files + carving.
    ///   2. If not mounted, read the raw partition directly.
    ///
    /// Raw reads go through `authopen` (one admin prompt) into wiped `SecureData` — the device is
    /// never copied to the Mac's storage or fully buffered in memory.
    func startScanOnSelectedDevice() async {
        guard let device = selectedDevice else { lastError = "Select a device first."; return }

        // Strategy 1: if a partition with a mount point exists, scan the mounted filesystem
        if let mountPoint = device.partitions.first(where: { $0.mountPoint != nil })?.mountPoint {
            await startMountedScan(device: device, mountPoint: mountPoint)
            return
        }

        // Strategy 2: read the raw partition (the one carrying a file system, so the parser sees
        // the FS boot sector rather than the MBR/GPT) directly via an authorized fd.
        let (bsd, size) = bestPartitionToScan(device)
        do {
            let reader = try await openRawReader(bsdName: bsd, size: size, blockSize: device.blockSize)
            scanStrategy = .authorizedRaw
            await startScan(device: device, reader: reader)
        } catch {
            lastError = "Cannot read \(device.rawPath) directly. \(error.localizedDescription)"
        }
    }

    /// Opens an authorized, read-only fd to `/dev/r{bsdName}` and wraps it in a `RawFDReader`.
    /// Closes any previously opened raw reader first.
    private func openRawReader(bsdName: String, size: Int64, blockSize: Int) async throws -> RawFDReader {
        await rawReader?.close()
        let fd = try await PrivilegedRawDevice.openReadOnly(rawPath: "/dev/r\(bsdName)")
        let reader = RawFDReader(fd: fd, totalSize: size, blockSize: blockSize)
        rawReader = reader
        return reader
    }

    /// Scans a mounted volume: enumerates live files via the filesystem, then reads the raw
    /// partition (with admin auth) for deleted-file recovery and carving.
    private func startMountedScan(device: DeviceInfo, mountPoint: URL) async {
        scanStrategy = .mountedFilesystem
        lastError = nil
        result = nil
        thumbnails.removeAll()
        thumbnailLoading.removeAll()

        // 1. Scan the mounted filesystem for live files (no privilege needed)
        let scanner = MountedVolumeScanner(mountPoint: mountPoint, deviceID: device.id)
        let liveFiles = await scanner.scan()

        // 2. Read the raw partition directly for deleted-file recovery + carving.
        let partition = device.partitions.first(where: { $0.mountPoint?.path == mountPoint.path })
        let partitionBSD = partition?.bsdName ?? device.bsdName
        let partitionSize = partition?.size ?? device.totalSize

        do {
            let reader = try await openRawReader(
                bsdName: partitionBSD, size: partitionSize, blockSize: device.blockSize
            )
            scanStrategy = .mountedFilesystemWithRaw
            await startScanWithMergedFiles(device: device, reader: reader, liveFiles: liveFiles)
        } catch {
            // Auth declined or the device is unavailable — still show the live files we found.
            scanStrategy = .mountedFilesystem
            self.reader = nil
            let scanResult = ScanResult(
                deviceID: device.id,
                mode: scanMode,
                startedAt: Date(),
                finishedAt: Date(),
                files: liveFiles,
                bytesScanned: device.totalSize,
                bytesRead: 0,
                errors: [ScanError(code: "raw", message: error.localizedDescription)]
            )
            result = scanResult
            progress = ScanProgress(totalBytes: device.totalSize, phase: .complete)
        }
    }

    /// Starts a raw-device scan, then merges the filesystem-scan live files into the result.
    private func startScanWithMergedFiles(device: DeviceInfo, reader: any RawBlockReader, liveFiles: [RecoverableFile]) async {
        self.reader = reader
        result = nil
        lastError = nil
        thumbnails.removeAll()
        thumbnailLoading.removeAll()
        beginProgressSubscription()
        await engine.startScan(device: device, mode: scanMode, reader: reader)

        // After the scan completes, merge in the live files from the filesystem scan
        // (the engine's snapshot will have deleted/carved files from the raw scan)
        // We'll append them when the scan finishes in the progress subscription
        self.pendingLiveFiles = liveFiles
    }

    private var pendingLiveFiles: [RecoverableFile]?

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
            var lastSnapshotCount = 0
            for await update in stream {
                guard let self else { return }
                self.progress = update

                // Take a snapshot during scanning so the UI can show files found so far.
                // Only snapshot when the file count changed (avoids excessive actor calls).
                if update.filesFound != lastSnapshotCount {
                    lastSnapshotCount = update.filesFound
                    self.result = await engine.snapshot()
                }

                switch update.phase {
                case .complete, .cancelled, .failed:
                    self.result = await self.engine.snapshot()
                    // Merge in pending live files from a mounted-filesystem scan.
                    // This happens even if the raw scan failed/cancelled — the live files
                    // from the filesystem scan are still valid.
                    if let liveFiles = self.pendingLiveFiles {
                        self.result?.files.insert(contentsOf: liveFiles, at: 0)
                        self.pendingLiveFiles = nil
                    }
                    // If the raw scan failed but we have live files, show them as a success
                    if update.phase == .failed, let result = self.result, !result.files.isEmpty {
                        self.progress = ScanProgress(
                            totalBytes: self.progress.totalBytes,
                            phase: .complete
                        )
                    }
                default:
                    break
                }
            }
        }
    }

    func pause() async { await engine.pause() }
    func resume() async { await engine.resume() }
    func cancel() async { await engine.cancel() }

    func cancelImaging() async {
        await imageReader?.cancelImaging()
        imageReader = nil
        isImaging = false
        progress = ScanProgress()
    }

    func clear() async {
        progressTask?.cancel()
        progressTask = nil
        thumbnails.removeAll()
        thumbnailLoading.removeAll()
        previewFile = nil
        result = nil
        progress = ScanProgress()
        lastError = nil
        await engine.clear()
        await rawReader?.close()
        rawReader = nil
        reader = nil
    }

    func snapshot() async {
        result = await engine.snapshot()
    }

    // MARK: Thumbnails (in-memory, on-demand)

    private let thumbnailSize = 128
    private let maxThumbnailSourceBytes: Int64 = 16 * 1024 * 1024

    func thumbnail(for file: RecoverableFile) -> NSImage? {
        if let existing = thumbnails[file.id] { return existing }
        guard thumbnailLoading.contains(file.id) == false else { return nil }
        guard canThumbnail(file) else { return nil }
        thumbnailLoading.insert(file.id)
        Task { await generateThumbnail(for: file) }
        return nil
    }

    private func canThumbnail(_ file: RecoverableFile) -> Bool {
        file.fileType == .image || file.fileType == .video
    }

    private func generateThumbnail(for file: RecoverableFile) async {
        defer { thumbnailLoading.remove(file.id) }

        switch file.fileType {
        case .image:
            await generateImageThumbnail(for: file)
        case .video:
            await generateVideoThumbnail(for: file)
        default:
            break
        }
    }

    private func generateImageThumbnail(for file: RecoverableFile) async {
        do {
            let content: SecureData
            if file.id.rawValue.hasPrefix("mounted:"),
               let contentReader = contentReader(for: file) {
                content = try await contentReader.readAll(maxLength: maxThumbnailSourceBytes)
            } else {
                content = try await engine.readContent(for: file, maxLength: maxThumbnailSourceBytes)
            }
            defer { content.wipe() }
            guard let fullImage = content.withUnsafeBytes({ buf in NSImage(data: Data(buf)) }) else { return }
            let thumb = downscale(fullImage, to: thumbnailSize)
            thumbnails[file.id] = thumb
        } catch {
            // Best-effort.
        }
    }

    private func generateVideoThumbnail(for file: RecoverableFile) async {
        guard let contentReader = contentReader(for: file) else { return }
        let loader = InMemoryAssetLoader(contentReader: contentReader)
        let asset = loader.makeAsset()

        do {
            let duration = try await asset.load(.duration)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = NSSize(width: thumbnailSize, height: thumbnailSize)
            generator.appliesPreferredTrackTransform = true

            let time = CMTime(seconds: min(1.0, CMTimeGetSeconds(duration) / 2), preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image
            thumbnails[file.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            // Best-effort — video may be corrupted.
        }
    }

    private func downscale(_ image: NSImage, to maxPx: Int) -> NSImage {
        let size = image.size
        guard size.width > CGFloat(maxPx) || size.height > CGFloat(maxPx) else { return image }
        let scale = min(CGFloat(maxPx) / size.width, CGFloat(maxPx) / size.height)
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    // MARK: Preview

    func openPreview(for file: RecoverableFile) {
        previewFile = file
    }

    func closePreview() {
        previewFile = nil
    }

    /// Returns a `FileContentReader` for the file. For mounted-filesystem files (ID starts with
    /// "mounted:"), creates a `MountedFileReader` from the file's path. For raw/image files,
    /// uses the existing raw reader.
    func contentReader(for file: RecoverableFile) -> FileContentReader? {
        if file.id.rawValue.hasPrefix("mounted:"), let path = file.originalPath {
            // Find the mount point from the device info
            if let device = devices.first(where: { $0.id == file.sourceDeviceID }),
               let mountPoint = device.partitions.first(where: { $0.mountPoint != nil })?.mountPoint {
                let url = mountPoint.appendingPathComponent(path)
                // Create a synchronous wrapper for the async MountedFileReader
                let source = SyncFileReader(url: url)
                return FileContentReader(file: file, source: source)
            }
        }
        guard let reader else { return nil }
        return FileContentReader(file: file, source: reader)
    }

    // MARK: Export (the only content-writing path)

    func exportSelected(_ files: [RecoverableFile], to directory: URL) async {
        lastError = nil
        exportProgress = nil
        lastExportedFiles = []

        let (stream, cont) = AsyncStream<ExportProgress>.makeStream()
        let manager = ExportManager()

        // Split files by source: mounted (read by path) vs raw/image (read by offset)
        let mountedFiles = files.filter { $0.id.rawValue.hasPrefix("mounted:") }
        let rawFiles = files.filter { !$0.id.rawValue.hasPrefix("mounted:") }

        let work = Task<[URL], Error> {
            defer { cont.finish() }
            var written: [URL] = []

            // Export mounted files via their filesystem path
            for file in mountedFiles {
                guard let path = file.originalPath,
                      let device = devices.first(where: { $0.id == file.sourceDeviceID }),
                      let mountPoint = device.partitions.first(where: { $0.mountPoint != nil })?.mountPoint else { continue }
                let url = mountPoint.appendingPathComponent(path)
                let source = SyncFileReader(url: url)
                let result = try await manager.export(files: [file], from: source, to: directory, progress: cont)
                written.append(contentsOf: result)
            }

            // Export raw/image files via the existing reader
            if !rawFiles.isEmpty, let reader {
                let result = try await manager.export(files: rawFiles, from: reader, to: directory, progress: cont)
                written.append(contentsOf: result)
            }

            return written
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
