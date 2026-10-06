import AVFoundation
import SwiftUI

/// Play/pause, a scrubber and the times for the file in `MediaPlaybackController`. It is part of the
/// viewer's bar (the system player's own controls are off), so everything shows and hides together.
struct MediaVideoControls: View {
    /// Any touch here, so the bar stays up while it is being used.
    let onInteraction: () -> Void

    @ObservedObject private var playback = MediaPlaybackController.shared
    @StateObject private var clock = MediaPlayerClock()
    @State private var scrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if playback.isPlaying { playback.pause() } else { playback.play() }
                onInteraction()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
            Text(Self.format(shownTime))
                .font(.caption.monospacedDigit())
            Slider(value: sliderValue, in: 0...max(clock.duration, 0.1)) { editing in
                if editing { scrubTime = clock.time }
                scrubbing = editing
                if !editing { clock.seek(to: scrubTime, precise: true) }
                onInteraction()
            }
            .tint(.white)
            Text(Self.format(clock.duration))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(.ultraThinMaterial)
                .overlay { Capsule().fill(Color.black.opacity(0.3)) }
        }
        .padding(.horizontal, 12)
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
    }

    private var shownTime: Double { scrubbing ? scrubTime : clock.time }

    /// While dragging, the thumb follows the finger and the picture follows roughly.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { shownTime },
            set: { value in
                scrubTime = value
                clock.seek(to: value, precise: false)
            }
        )
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The player's position and length, refreshed a few times a second while the controls show.
@MainActor
final class MediaPlayerClock: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0

    private var observer: Any?
    private var player: AVPlayer { MediaPlaybackController.shared.player }

    func start() {
        guard observer == nil else { return }
        refresh()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    func seek(to seconds: Double, precise: Bool) {
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func refresh() {
        let now = player.currentTime().seconds
        time = now.isFinite ? now : 0
        let length = player.currentItem?.duration.seconds ?? 0
        duration = length.isFinite ? length : 0
    }
}
