import SwiftUI
import RecoverDCore
import RecoverDEngine

/// Routes a double-clicked file to the right preview view based on its type.
/// All previews read content from the source on demand into RAM — nothing is written to disk.
struct PreviewView: View {
    let file: RecoverableFile
    let contentReader: FileContentReader
    @Environment(\.dismiss) private var dismiss

    /// Set when the user runs content-based identification on an unknown file; once set, the
    /// preview routes by the detected type instead of the (missing/misleading) extension.
    @State private var detected: DetectedFileType?
    @State private var identifying = false
    @State private var identifyMessage: String?

    private var fileExtension: String {
        detected?.fileExtension ?? (file.displayName as NSString).pathExtension
    }

    private var effectiveType: RecoverableFileType {
        detected?.fileType ?? file.fileType
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    if let detected {
                        Text("identified as \(detected.displayName)").foregroundStyle(.blue)
                    } else {
                        Text(file.fileType.displayName)
                    }
                    statusBadge
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var contentArea: some View {
        switch effectiveType {
        case .image:
            PhotoPreviewView(contentReader: contentReader)
        case .video:
            VideoPreviewView(contentReader: contentReader, fileSize: file.size,
                             fileExtension: fileExtension)
        case .audio:
            VideoPreviewView(contentReader: contentReader, fileSize: file.size, audioOnly: true,
                             fileExtension: fileExtension)
        case .document:
            PDFPreviewView(contentReader: contentReader)
        case .text:
            TextPreviewView(contentReader: contentReader)
        default:
            unsupportedView
        }
    }

    private var statusBadge: some View {
        switch file.allocationStatus {
        case .live: Label("live", systemImage: "leaf.fill").foregroundStyle(.green)
        case .deleted: Label("deleted", systemImage: "trash.fill").foregroundStyle(.orange)
        case .orphaned: Label("carved", systemImage: "wand.and.stars").foregroundStyle(.blue)
        }
    }

    private var unsupportedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No preview available for this file type.")
                .foregroundStyle(.secondary)

            // For unknown/other files (e.g. a renamed extension), offer to identify by content.
            Button {
                Task { await identify() }
            } label: {
                Label("Identify file type", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(identifying)
            .help("Inspect the file's actual contents to detect its real format, ignoring its name")

            if identifying {
                ProgressView().controlSize(.small)
            }
            if let identifyMessage {
                Text(identifyMessage)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Text("You can still recover it to disk using the Recover button.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reads the file's leading bytes and runs content-based type detection. On a previewable
    /// match, `detected` is set and `contentArea` re-routes to the right viewer; otherwise we show
    /// what it looks like (or that it couldn't be identified).
    private func identify() async {
        identifying = true
        identifyMessage = nil
        defer { identifying = false }
        do {
            let head = try await contentReader.readAll(maxLength: 16 * 1024)
            let bytes = head.withUnsafeBytes { Array($0) }
            head.wipe()
            guard let match = FileTypeSniffer.detect(bytes) else {
                identifyMessage = "Couldn't identify this file from its contents — it doesn't match a known format."
                return
            }
            switch match.fileType {
            case .image, .video, .audio, .document, .text:
                detected = match // triggers a re-render into the matching preview
            default:
                identifyMessage = "Looks like \(match.displayName). It can't be previewed here, "
                    + "but you can recover it and open it in the right app."
            }
        } catch {
            identifyMessage = "Couldn't read the file: \(error.localizedDescription)"
        }
    }
}
