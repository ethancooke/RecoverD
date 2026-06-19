import SwiftUI
import AppKit
import RecoverDEngine

/// Full-size photo preview with zoom and scroll. Reads the image from the source on demand,
/// renders it into an `NSImage`, and wipes the source `SecureData` immediately after.
struct PhotoPreviewView: View {
    let contentReader: FileContentReader
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var zoom: CGFloat = 1.0

    private let maxPreviewBytes: Int64 = 64 * 1024 * 1024 // 64 MB cap for preview

    var body: some View {
        ZStack {
            if let image {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .bottomTrailing) { zoomControls }
            } else if isLoading {
                loadingView
            } else if let loadError {
                errorView(loadError)
            }
        }
        .task { await loadImage() }
    }

    private func loadImage() async {
        isLoading = true
        loadError = nil
        do {
            let content = try await contentReader.readAll(maxLength: maxPreviewBytes)
            let byteCount = content.count
            defer { content.wipe() }
            let img = content.withUnsafeBytes { buf in NSImage(data: Data(buf)) }
            if let img {
                self.image = img
                self.isLoading = false
            } else {
                self.loadError = "Could not decode image (\(byteCount) bytes read). The file may be corrupted or an unsupported format."
                self.isLoading = false
            }
        } catch {
            self.loadError = "Failed to read file: \(error.localizedDescription)"
            self.isLoading = false
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading image…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { withAnimation { zoom = max(0.25, zoom - 0.25) } } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Text("\(Int(zoom * 100))%")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 44)
            Button { withAnimation { zoom = min(4.0, zoom + 0.25) } } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
            Button { withAnimation { zoom = 1.0 } } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .help("Reset zoom")
        }
        .padding(8)
        .background(.thinMaterial)
        .cornerRadius(8)
        .padding(12)
    }
}
