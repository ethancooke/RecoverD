import SwiftUI
import AppKit
import RecoverDEngine

/// Text file preview. Reads the content, decodes as UTF-8 (with fallback), and displays in a
/// scrollable monospaced text view. Source `SecureData` is wiped after decoding.
struct TextPreviewView: View {
    let contentReader: FileContentReader
    @State private var text: String?
    @State private var isLoading = true
    @State private var loadError: String?

    private let maxPreviewBytes: Int64 = 4 * 1024 * 1024 // 4 MB cap for text

    var body: some View {
        ZStack {
            if let text {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else if isLoading {
                loadingView
            } else if let loadError {
                errorView(loadError)
            }
        }
        .task { await loadText() }
    }

    private func loadText() async {
        isLoading = true
        loadError = nil
        do {
            let content = try await contentReader.readAll(maxLength: maxPreviewBytes)
            defer { content.wipe() }
            let decoded = content.withUnsafeBytes { buf -> String? in
                let data = Data(buf)
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .isoLatin1)
            }
            if let decoded {
                await MainActor.run {
                    self.text = decoded
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.loadError = "Could not decode this file as text. It may be a binary file."
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.loadError = "Failed to read file: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading text…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
