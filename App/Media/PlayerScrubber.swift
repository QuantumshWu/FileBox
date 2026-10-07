import SwiftUI

/// The progress bar of the video controls. A touch anywhere on its 44 pt tall strip jumps there
/// and dragging scrubs with the picture following; the bar thickens while in use. Playback pauses
/// during the drag and goes on where the finger let go (see `MediaPlaybackController.beginScrub`).
struct PlayerScrubber: View {
    /// The position shown while not dragging.
    let time: Double
    let duration: Double
    let isEnabled: Bool
    /// Where the finger is; nil while not dragging.
    @Binding var dragTime: Double?
    /// The finger let go.
    let onEnd: () -> Void

    @GestureState private var touching = false

    /// Room for the knob at both ends of the track.
    private static let inset: CGFloat = 9

    var body: some View {
        GeometryReader { proxy in
            let trackWidth = max(1, proxy.size.width - 2 * Self.inset)
            let active = dragTime != nil
            let trackHeight: CGFloat = active ? 8 : 4
            let knob: CGFloat = active ? 18 : 12
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: trackWidth, height: trackHeight)
                Capsule()
                    .fill(Color.white)
                    .frame(width: trackWidth * progress, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                    .offset(x: trackWidth * progress - knob / 2)
            }
            .padding(.leading, Self.inset)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(drag(trackWidth: trackWidth))
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .frame(height: 44)
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
        .onChange(of: touching) { _, isTouching in
            // A drag the system cancelled ends without onEnded.
            if !isTouching { finish() }
        }
        .onDisappear { finish() }
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(MediaVideoControls.format(dragTime ?? time)) / \(MediaVideoControls.format(duration))")
        .accessibilityAdjustableAction { direction in
            let playback = MediaPlaybackController.shared
            switch direction {
            case .increment: playback.seek(by: 10)
            case .decrement: playback.seek(by: -10)
            @unknown default: break
            }
        }
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        let shown = dragTime ?? time
        return CGFloat(min(max(shown / duration, 0), 1))
    }

    private func drag(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { value in
                let playback = MediaPlaybackController.shared
                if dragTime == nil {
                    guard isEnabled else { return }
                    playback.beginScrub()
                    guard playback.isScrubbing else { return }
                }
                let fraction = min(max((value.location.x - Self.inset) / trackWidth, 0), 1)
                let target = Double(fraction) * duration
                dragTime = target
                playback.scrub(to: target)
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        guard let target = dragTime else { return }
        // The target is set before the finger's position goes, so the thumb stays put.
        dragTime = nil
        MediaPlaybackController.shared.endScrub(at: target)
        onEnd()
    }
}
