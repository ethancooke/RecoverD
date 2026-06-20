import SwiftUI
import AppKit
import AVKit
import AVFoundation
import RecoverDEngine

/// Video/audio preview using AVKit. Plays directly from the source device via
/// `InMemoryAssetLoader` (AVAssetResourceLoaderDelegate) — no temp file, no disk writes.
/// Byte ranges are read on demand as AVPlayer requests them.
struct VideoPreviewView: View {
    let contentReader: FileContentReader
    let fileSize: Int64
    var audioOnly: Bool = false
    /// Lowercased container extension (e.g. "avi"), used to short-circuit formats AVFoundation
    /// can't open so we show an honest message instead of a cryptic decode error.
    var fileExtension: String = ""

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var assetLoader: InMemoryAssetLoader?

    /// Containers macOS' AVFoundation cannot open. AVI is the one the signature carver produces
    /// (from the RIFF magic); the rest are here so any future signatures fail gracefully too.
    private static let unsupportedContainers: Set<String> = [
        "avi", "mkv", "wmv", "flv", "webm", "ogv", "vob", "asf", "rm", "rmvb"
    ]

    var body: some View {
        ZStack {
            if let player {
                PlayerContainerView(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                loadingView
            } else if let loadError {
                errorView(loadError)
            }
        }
        .task { await setupPlayer() }
        .onDisappear { cleanup() }
    }

    private func setupPlayer() async {
        isLoading = true
        loadError = nil

        if Self.unsupportedContainers.contains(fileExtension.lowercased()) {
            let fmt = fileExtension.uppercased()
            loadError = "\(fmt) files can't be previewed here — macOS media playback doesn't "
                + "support this format. You can still recover the file and open it in another "
                + "player such as VLC."
            isLoading = false
            return
        }

        let loader = InMemoryAssetLoader(contentReader: contentReader)
        assetLoader = loader
        let asset = loader.makeAsset()

        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            if tracks.isEmpty {
                await MainActor.run {
                    self.loadError = "No playable tracks found. The file may be corrupted or in an unsupported format."
                    self.isLoading = false
                }
                return
            }

            let item = AVPlayerItem(asset: asset)
            await MainActor.run {
                self.player = AVPlayer(playerItem: item)
                self.player?.play()
                self.isLoading = false
            }
            _ = duration
        } catch {
            await MainActor.run {
                self.loadError = "Couldn't play this file — it may be corrupted, incomplete, or "
                    + "in a format macOS can't open. You can still recover it to disk."
                self.isLoading = false
            }
        }
    }

    private func cleanup() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        assetLoader = nil
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(audioOnly ? "Loading audio…" : "Loading video…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: audioOnly ? "waveform.badge.exclamationmark" : "play.slash")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// NSViewRepresentable wrapper for AVKit's AVPlayerView (macOS).
private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
