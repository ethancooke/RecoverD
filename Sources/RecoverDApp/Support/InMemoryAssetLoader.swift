import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import RecoverDCore
import RecoverDEngine

/// Bridges an in-memory recovered file to AVFoundation without writing a temp file.
///
/// `AVPlayer` normally loads media from a URL. We register a custom URL scheme
/// (`recoverd-inmemory://`) on an `AVURLAsset`, and AVFoundation calls our
/// `AVAssetResourceLoaderDelegate` to request byte ranges on demand. Each request reads
/// the needed bytes from the source device via `FileContentReader` into a transient
/// `Data` (copied from `SecureData`, which is immediately wiped), hands it to AVFoundation,
/// and the `Data` is released when AVFoundation is done. No content is written to disk.
///
/// SECURITY: the `Data` copies handed to AVFoundation are not in `SecureData` (AVFoundation
/// needs standard `Data`), but they are short-lived — AVFoundation releases them after
/// decoding. When the preview closes, the `AVPlayer` is cancelled and the asset is released,
/// freeing all remaining buffers.
final class InMemoryAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    static let scheme = "recoverd-inmemory"

    private let contentReader: FileContentReader
    /// The UTI AVFoundation uses to pick a demuxer. Derived from the file's (real) extension — a
    /// generic `public.data` leaves AVFoundation unable to recognize MP4/MOV/etc. and it won't play.
    private let contentTypeUTI: String
    private let fileExtension: String
    private let lock = NSLock()
    private var _pendingRequests: Set<ObjectIdentifier> = []

    private var pendingRequests: Set<ObjectIdentifier> {
        get { lock.lock(); defer { lock.unlock() }; return _pendingRequests }
    }

    func addPending(_ request: AVAssetResourceLoadingRequest) {
        lock.lock(); _pendingRequests.insert(ObjectIdentifier(request)); lock.unlock()
    }

    func removePending(_ request: AVAssetResourceLoadingRequest) {
        lock.lock(); _pendingRequests.remove(ObjectIdentifier(request)); lock.unlock()
    }

    init(contentReader: FileContentReader, fileExtension: String = "") {
        self.contentReader = contentReader
        self.fileExtension = fileExtension.lowercased()
        // Resolve the extension to a concrete UTI so AVFoundation knows the format. Fall back to
        // generic data if the extension is unknown/empty.
        self.contentTypeUTI = UTType(filenameExtension: fileExtension.lowercased())?.identifier
            ?? UTType.data.identifier
        super.init()
    }

    /// Creates an `AVURLAsset` backed by this loader. The URL is synthetic — the scheme triggers
    /// the resource loader delegate — but we keep the real extension on the path as an extra format
    /// hint for AVFoundation.
    func makeAsset() -> AVURLAsset {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let url = URL(string: "\(InMemoryAssetLoader.scheme)://preview/\(UUID().uuidString)\(suffix)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .global(qos: .userInitiated))
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // 1. Content information request (size, range support, content type).
        if let info = loadingRequest.contentInformationRequest {
            info.contentLength = contentReader.totalSize
            info.isByteRangeAccessSupported = true
            info.contentType = contentTypeUTI
            loadingRequest.finishLoading()
            return true
        }

        // 2. Data request — stream the requested byte range from the source in small chunks.
        //    Reading the whole `requestedLength` at once stalls playback, because AVPlayer's
        //    "all data to end" request would pull the entire (possibly huge) file from a slow
        //    source device before a single byte is delivered. Chunked responses start feeding
        //    immediately and keep peak memory bounded.
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(with: NSError(domain: InMemoryAssetLoader.scheme, code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "No data request"]))
            return true
        }

        addPending(loadingRequest)
        let contentReader = self.contentReader
        let request = loadingRequest

        Task { [weak self] in
            let chunkSize = 256 * 1024
            let end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
            while !request.isCancelled {
                let pos = dataRequest.currentOffset
                guard pos < end else { break }
                let want = Int(min(Int64(chunkSize), end - pos))
                do {
                    let data = try await contentReader.read(at: pos, count: want)
                    if data.count == 0 { data.wipe(); break } // EOF
                    data.withUnsafeBytes { dataRequest.respond(with: Data($0)) }
                    let got = data.count
                    data.wipe()
                    if got < want { break } // short read → end of file
                } catch {
                    self?.removePending(request)
                    if !request.isCancelled { request.finishLoading(with: error as NSError) }
                    return
                }
            }
            self?.removePending(request)
            if !request.isCancelled { request.finishLoading() }
        }

        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        removePending(loadingRequest)
    }
}
