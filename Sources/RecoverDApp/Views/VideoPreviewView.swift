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

    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var assetLoader: InMemoryAssetLoader?

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
                self.loadError = "Could not open media: \(error.localizedDescription)"
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
