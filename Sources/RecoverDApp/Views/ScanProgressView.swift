import SwiftUI
import RecoverDCore
import RecoverDEngine

/// Live scan progress with pause/resume/cancel and an in-RAM indicator.
/// Shows an imaging step when creating a .dmg of a physical device.
/// During scanning, shows files found so far in real time — with selection and recovery
/// available even while the scan is running.
/// Ordering options for the live "files found so far" list. Default keeps discovery order so the
/// feed reads like a live stream; the others sort a copy on demand (cheap — the list is capped at
/// `displayLimit` rows and the array is only a few thousand items).
enum FileSortKey: String, CaseIterable {
    case found = "Found order"
    case largest = "Largest first"
    case smallest = "Smallest first"
    case name = "Name"
    case type = "Type"
}

struct ScanProgressView: View {
    @Bindable var session: RecoverySessionViewModel
    @State private var selection: Set<FileID> = []
    @State private var presentingExport = false
    @State private var sortKey: FileSortKey = .found

    private let displayLimit = 100

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    if session.isImaging {
                        imagingView
                    } else {
                        scanningView
                    }

                    if !currentFiles.isEmpty {
                        liveResultsView
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            }

            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $presentingExport) {
            ExportView(session: session, files: selectedFiles)
        }
        .sheet(item: $session.previewFile) { file in
            if let reader = session.contentReader(for: file) {
                PreviewView(file: file, contentReader: reader)
            } else {
                Text("No source loaded").padding()
            }
        }
    }

    private var currentFiles: [RecoverableFile] {
        session.result?.files ?? []
    }

    private var selectedFiles: [RecoverableFile] {
        currentFiles.filter { selection.contains($0.id) }
    }

    /// The (sorted) slice actually rendered. Capped at `displayLimit` rows so sorting and SwiftUI
    /// diffing stay cheap no matter how many files the scan has found.
    private var displayedFiles: [RecoverableFile] {
        switch sortKey {
        case .found:
            // Discovery order — show the most recent finds, like a live feed.
            return Array(currentFiles.suffix(displayLimit))
        case .largest:
            return Array(currentFiles.sorted { $0.size > $1.size }.prefix(displayLimit))
        case .smallest:
            return Array(currentFiles.sorted { $0.size < $1.size }.prefix(displayLimit))
        case .name:
            return Array(currentFiles
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .prefix(displayLimit))
        case .type:
            return Array(currentFiles
                .sorted { $0.fileType.displayName < $1.fileType.displayName }
                .prefix(displayLimit))
        }
    }

    // MARK: Imaging

    private var imagingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Creating disk image…")
                .font(.headline)
            Text("Reading \(session.selectedDevice?.displayName ?? "device")")
                .foregroundStyle(.secondary)
                .font(.caption)

            VStack(spacing: 8) {
                ProgressView(value: imagingFraction)
                    .progressViewStyle(.linear)
                    .labelsHidden()
                HStack {
                    Text("\(ByteCountFormatter.string(fromByteCount: session.imagingBytesDone, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: session.imagingBytesTotal, countStyle: .file))")
                        .monospacedDigit()
                    Spacer()
                    Text("\(Int(imagingFraction * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 120)

            Text("Temporary copy in /tmp — deleted when the scan ends")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button("Cancel", role: .destructive) {
                Task { await session.cancelImaging() }
            }
            .help("Cancel the imaging and return to the device picker")
        }
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(session.progress.phase.rawValue.capitalized)
                .font(.headline)
            Text("\(session.progress.filesFound) files found")
                .foregroundStyle(.secondary)
            Text(session.scanStrategy.displayName)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)

            VStack(spacing: 8) {
                ProgressView(value: session.progress.fraction)
                    .progressViewStyle(.linear)
                    .labelsHidden()
                HStack {
                    Text(percentText(session.progress.fraction))
                        .monospacedDigit()
                    Spacer()
                    if let region = session.progress.currentRegion {
                        Text(region).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 120)

            HStack {
                if session.progress.isPaused {
                    Button("Resume") { Task { await session.resume() } }
                        .buttonStyle(.borderedProminent)
                        .help("Continue the paused scan from where it stopped")
                } else {
                    Button("Pause") { Task { await session.pause() } }
                        .disabled(!session.isScanning)
                        .help("Temporarily halt the scan without discarding results found so far")
                }
                Button("Cancel", role: .destructive) { Task { await session.cancel() } }
                    .help("Stop the scan and discard all in-memory results")
                if session.progress.phase == .complete {
                    Button("Done") { /* phase is complete, ContentView will switch */ }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Live results (interactive)

    private var liveResultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Files found so far")
                    .font(.headline)

                Picker("Sort", selection: $sortKey) {
                    ForEach(FileSortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Sort the files found so far")

                Spacer()
                Text("\(currentFiles.count) total · \(selection.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)

            VStack(spacing: 0) {
                ForEach(displayedFiles) { file in
                    fileRow(file)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: RecoverableFile) -> some View {
        let isSelected = selection.contains(file.id)
        HStack(spacing: 10) {
            Button {
                if isSelected { selection.remove(file.id) }
                else { selection.insert(file.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("Click to select/deselect this file for recovery")

            Image(systemName: iconForType(file.fileType))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(file.displayName)
                .lineLimit(1)
                .font(.caption)

            Spacer()

            Button {
                session.openPreview(for: file)
            } label: {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Preview this file (photo, video, PDF, text)")

            if file.isLowConfidence {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Low confidence — likely a fragment or false positive; may not open.")
            }

            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            statusDot(file.allocationStatus)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            Label("\(selection.count) selected", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !selection.isEmpty {
                Button("Recover Selected…") { presentingExport = true }
                    .buttonStyle(.borderedProminent)
                    .help("Choose a destination folder and write the selected files to your Mac")
            }
            Label("All results in RAM — nothing on disk", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: Helpers

    private func iconForType(_ type: RecoverableFileType) -> String {
        switch type {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.richtext"
        case .archive: "archivebox"
        case .executable: "app"
        case .text: "doc.plaintext"
        case .database: "cylinder.split.1x2"
        case .other: "doc"
        case .unknown: "questionmark.folder"
        }
    }

    private func statusDot(_ status: AllocationStatus) -> some View {
        Circle()
            .fill(colorForStatus(status))
            .frame(width: 6, height: 6)
            .help(status.rawValue.capitalized)
    }

    private func colorForStatus(_ status: AllocationStatus) -> Color {
        switch status {
        case .live: .green
        case .deleted: .orange
        case .orphaned: .blue
        }
    }

    private var imagingFraction: Double {
        guard session.imagingBytesTotal > 0 else { return 0 }
        return min(1, Double(session.imagingBytesDone) / Double(session.imagingBytesTotal))
    }

    private func percentText(_ fraction: Double) -> String {
        String(format: "%.1f%% — in memory only", fraction * 100)
    }
}
