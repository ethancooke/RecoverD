import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RecoverDCore
import RecoverDEngine

/// The export sheet: choose a destination folder, then write *only the selected* recovered
/// files there. This is the single content-writing path in the app.
struct ExportView: View {
    @Bindable var session: RecoverySessionViewModel
    let files: [RecoverableFile]

    @State private var destination: URL?
    @State private var isExporting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover selected files")
                .font(.headline)

            Text("These \(files.count) file(s) will be written to the folder you choose. " +
                 "Everything else stays in memory.")
                .font(.callout)
                .foregroundStyle(.secondary)

            destinationPicker

            if let progress = session.exportProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.exported), total: Double(max(progress.total, 1)))
                    Text("\(progress.exported)/\(progress.total) — \(progress.currentFileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !session.lastExportedFiles.isEmpty {
                Label("Exported \(session.lastExportedFiles.count) file(s) to disk.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            buttonBar
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    private var destinationPicker: some View {
        HStack {
            Image(systemName: "folder")
            Text(destination?.path ?? "No destination chosen")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(destination == nil ? .secondary : .primary)
            Spacer()
            Button("Choose…") { chooseFolder() }
                .help("Select a folder on your Mac where the recovered files will be saved")
        }
        .padding(8)
        .background(.thinMaterial)
        .cornerRadius(8)
    }

    private var buttonBar: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .help("Close this sheet without writing anything to disk")
            Button("Recover to Disk") {
                guard let destination else { return }
                isExporting = true
                Task {
                    await session.exportSelected(files, to: destination)
                    isExporting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(destination == nil || files.isEmpty || isExporting)
            .help("Write the selected files to the chosen destination folder. This is the only action that persists recovered content to your Mac.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a recovery destination"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }
}
