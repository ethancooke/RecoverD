import Foundation
import AVFoundation
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

    init(contentReader: FileContentReader) {
        self.contentReader = contentReader
        super.init()
    }

    /// Creates an `AVURLAsset` backed by this loader. The URL is synthetic — the scheme triggers
    /// the resource loader delegate, so the host/path are just identifiers.
    func makeAsset() -> AVURLAsset {
        let url = URL(string: "\(InMemoryAssetLoader.scheme)://preview/\(UUID().uuidString)")!
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
            info.contentType = "public.data"
            loadingRequest.finishLoading()
            return true
        }

        // 2. Data request — read the requested byte range from the source.
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading(with: NSError(domain: InMemoryAssetLoader.scheme, code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "No data request"]))
            return true
        }

        let offset = dataRequest.requestedOffset
        let length = dataRequest.requestedLength

        addPending(loadingRequest)

        let contentReader = self.contentReader
        let loadingRequestRef = loadingRequest

        Task {
            let result = try? await contentReader.read(at: offset, count: length)
            DispatchQueue.global(qos: .userInitiated).async {
                self.removePending(loadingRequestRef)
                guard !loadingRequestRef.isCancelled else { return }

                if let result {
                    result.withUnsafeBytes { buf in
                        loadingRequestRef.dataRequest?.respond(with: Data(buf))
                    }
                    result.wipe()
                    loadingRequestRef.finishLoading()
                } else {
                    loadingRequestRef.finishLoading(with: NSError(domain: InMemoryAssetLoader.scheme, code: -3,
                                                               userInfo: [NSLocalizedDescriptionKey: "Read failed"]))
                }
            }
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
