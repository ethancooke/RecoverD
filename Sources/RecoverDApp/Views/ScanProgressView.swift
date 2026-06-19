import SwiftUI
import RecoverDCore
import RecoverDEngine

/// Live scan progress with pause/resume/cancel and an in-RAM indicator.
struct ScanProgressView: View {
    @Bindable var session: RecoverySessionViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(session.progress.phase.rawValue.capitalized)
                    .font(.headline)
                Text("\(session.progress.filesFound) files found")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ProgressView(value: session.progress.fraction)
                    .progressViewStyle(.linear)
                    .labelsHidden()
                HStack {
                    Text(percentText(session.progress.fraction))
                        .monospacedDigit()
                    Spacer()
                    if let region = session.progress.currentRegion {
                        Text(region).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 120)

            HStack {
                if session.progress.isPaused {
                    Button("Resume") { Task { await session.resume() } }
                        .buttonStyle(.borderedProminent)
                        .help("Continue the paused scan from where it stopped")
                } else {
                    Button("Pause") { Task { await session.pause() } }
                        .disabled(!session.isScanning)
                        .help("Temporarily halt the scan without discarding results found so far")
                }
                Button("Cancel") { Task { await session.cancel() } }
                    .help("Stop the scan and discard all in-memory results")
            }

            Spacer()
            inMemoryBadge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func percentText(_ fraction: Double) -> String {
        String(format: "%.1f%% — in memory only", fraction * 100)
    }

    private var inMemoryBadge: some View {
        Label("All results are in RAM — nothing written to disk", systemImage: "lock.shield.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .padding(.bottom, 20)
    }
}
