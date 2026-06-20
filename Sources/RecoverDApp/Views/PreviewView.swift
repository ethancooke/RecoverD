import SwiftUI
import RecoverDCore
import RecoverDEngine

/// Routes a double-clicked file to the right preview view based on its type.
/// All previews read content from the source on demand into RAM — nothing is written to disk.
struct PreviewView: View {
    let file: RecoverableFile
    let contentReader: FileContentReader
    @Environment(\.dismiss) private var dismiss

    private var fileExtension: String {
        (file.displayName as NSString).pathExtension
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
                    Text(file.fileType.displayName)
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
        switch file.fileType {
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
            Text("You can still recover it to disk using the Recover button.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
