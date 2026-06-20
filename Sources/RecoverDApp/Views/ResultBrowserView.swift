import SwiftUI
import RecoverDCore
import RecoverDEngine

/// In-memory result browser: metadata + lazy thumbnails, multi-select, and the gateway to the
/// (only) content-writing path — Export. Double-click a file to open a full preview.
struct ResultBrowserView: View {
    @Bindable var session: RecoverySessionViewModel
    let result: ScanResult

    @State private var selection: Set<FileID> = []
    @State private var typeFilter: RecoverableFileType?
    @State private var presentingExport = false

    private var filteredFiles: [RecoverableFile] {
        result.files.filter { typeFilter == nil || $0.fileType == typeFilter }
    }

    private var selectedFiles: [RecoverableFile] {
        result.files.filter { selection.contains($0.id) }
    }

    private var allFilteredSelected: Bool {
        !filteredFiles.isEmpty && filteredFiles.allSatisfy { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            List {
                ForEach(filteredFiles) { file in
                    rowView(file)
                }
            }
            Divider()
            bottomBar
        }
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

    /// A result row with an explicit selection checkbox and preview button. We drive selection
    /// ourselves rather than relying on `List(selection:)`, whose single-click selection is
    /// swallowed by the row's tap gesture on macOS.
    @ViewBuilder
    private func rowView(_ file: RecoverableFile) -> some View {
        let isSelected = selection.contains(file.id)
        HStack(spacing: 12) {
            Button {
                if isSelected { selection.remove(file.id) } else { selection.insert(file.id) }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help("Select this file for recovery")

            ResultRow(file: file, session: session)

            Button {
                session.openPreview(for: file)
            } label: {
                Image(systemName: "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Preview this file (photo, video, PDF, text)")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.openPreview(for: file) }
    }

    private var filterBar: some View {
        HStack {
            Picker("Type", selection: $typeFilter) {
                Text("All").tag(RecoverableFileType?.none)
                ForEach(RecoverableFileType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(RecoverableFileType?.some(type))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .help("Filter recovered files by type (images, videos, documents, etc.)")

            Spacer()
            Text("\(filteredFiles.count) shown · \(result.count) total · \(selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack {
            Label("\(selection.count) selected", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Number of files you've selected for recovery")

            Button(allFilteredSelected ? "Deselect All" : "Select All") {
                if allFilteredSelected {
                    filteredFiles.forEach { selection.remove($0.id) }
                } else {
                    selection.formUnion(filteredFiles.map(\.id))
                }
            }
            .buttonStyle(.link)
            .disabled(filteredFiles.isEmpty)
            .help("Select or deselect every file currently shown")

            Spacer()
            Button("Recover Selected…") {
                presentingExport = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
            .help("Choose a destination folder and write the selected files to your Mac — this is the only action that writes recovered content to disk")
        }
        .padding()
    }
}

private struct ResultRow: View {
    let file: RecoverableFile
    let session: RecoverySessionViewModel

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName).font(.body)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    Text(file.fileType.displayName)
                    statusBadge
                    if file.isCarved, let match = file.signatureMatch {
                        Label(match, systemImage: "wand.and.stars")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = session.thumbnail(for: file) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if session.thumbnailLoading.contains(file.id) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay(ProgressView().controlSize(.small))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 48, height: 48)
                .overlay(Image(systemName: iconForType(file.fileType)).foregroundStyle(.secondary))
        }
    }

    private var statusBadge: some View {
        switch file.allocationStatus {
        case .live:
            Label("live", systemImage: "leaf").foregroundStyle(.green)
        case .deleted:
            Label("deleted", systemImage: "trash").foregroundStyle(.orange)
        case .orphaned:
            Label("carved", systemImage: "wand.and.stars").foregroundStyle(.blue)
        }
    }

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
}
