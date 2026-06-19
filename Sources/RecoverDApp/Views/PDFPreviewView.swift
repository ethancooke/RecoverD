import SwiftUI
import AppKit
import PDFKit
import RecoverDEngine

/// PDF preview using PDFKit. Reads the full PDF from the source into RAM, renders it in a
/// scrollable `PDFView`, and wipes the source `SecureData` after the `PDFDocument` is created.
struct PDFPreviewView: View {
    let contentReader: FileContentReader
    @State private var pdfDocument: PDFDocument?
    @State private var isLoading = true
    @State private var loadError: String?

    private let maxPreviewBytes: Int64 = 128 * 1024 * 1024 // 128 MB cap

    var body: some View {
        ZStack {
            if let pdfDocument {
                PDFContainerView(pdfDocument: pdfDocument)
            } else if isLoading {
                loadingView
            } else if let loadError {
                errorView(loadError)
            }
        }
        .task { await loadPDF() }
    }

    private func loadPDF() async {
        isLoading = true
        loadError = nil
        do {
            let content = try await contentReader.readAll(maxLength: maxPreviewBytes)
            defer { content.wipe() }
            let doc = content.withUnsafeBytes { buf in PDFDocument(data: Data(buf)) }
            if let doc, doc.pageCount > 0 {
                await MainActor.run {
                    self.pdfDocument = doc
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.loadError = "Could not open this PDF. The file may be corrupted."
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
            Text("Loading PDF…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFContainerView: NSViewRepresentable {
    let pdfDocument: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = pdfDocument
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = pdfDocument
    }
}
