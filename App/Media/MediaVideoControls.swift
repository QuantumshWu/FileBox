import AVFoundation
import Combine
import SwiftUI

/// The scrubber, the times and the playback speed of the file in `MediaPlaybackController`. It is
/// part of the viewer's bar (the system player's own controls are off), so everything shows and
/// hides together; play / pause lives in the viewer's own buttons.
struct MediaVideoControls: View {
    /// Whether the bar is on screen. It stays mounted while hidden; its clock only runs when shown.
    let isVisible: Bool
    /// Any use of the bar, so the 3 s auto-hide starts again from the last one.
    let onInteraction: () -> Void
    /// A menu of the bar opened: the bar must stay up until something is chosen.
    let onHoldChrome: () -> Void

    @ObservedObject private var playback = MediaPlaybackController.shared
    @StateObject private var clock = MediaPlayerClock()
    /// Where the finger is while it drags the scrubber.
    @State private var dragTime: Double?

    init(isVisible: Bool = true, onInteraction: @escaping () -> Void, onHoldChrome: @escaping () -> Void = {}) {
        self.isVisible = isVisible
        self.onInteraction = onInteraction
        self.onHoldChrome = onHoldChrome
    }

    var body: some View {
        ZStack {
            if let url = playback.currentURL, !playback.failedURLs.contains(url) {
                bar
            }
        }
        .onAppear {
            if isVisible { clock.start() }
        }
        .onDisappear { clock.stop() }
        .onChange(of: isVisible) { _, visible in
            if visible { clock.start() } else { clock.stop() }
        }
    }

    /// The finger while dragging; otherwise where a seek is heading, so nothing jumps back while it
    /// runs; otherwise the player's time.
    private var shownTime: Double {
        dragTime ?? playback.seekTarget ?? clock.time
    }

    private var bar: some View {
        let duration = clock.duration
        let template = Self.template(for: duration)
        return HStack(spacing: 10) {
            timeLabel(Self.format(shownTime, fieldOf: duration), template: template)
            PlayerScrubber(
                time: playback.seekTarget ?? clock.time,
                duration: duration,
                isEnabled: duration > 0,
                dragTime: $dragTime,
                onEnd: onInteraction
            )
            timeLabel(Self.format(duration, fieldOf: duration), template: template)
            speedMenu
        }
        .foregroundStyle(.white)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background {
            Capsule().fill(.ultraThinMaterial)
                .overlay { Capsule().fill(Color.black.opacity(0.3)) }
        }
        .padding(.horizontal, 12)
    }

    /// Both times are as wide as the longest the duration needs, so the bar never shifts.
    private func timeLabel(_ text: String, template: String) -> some View {
        Text(template)
            .hidden()
            .overlay { Text(text) }
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }

    private var speedMenu: some View {
        Menu {
            Picker("播放速度", selection: $playback.speed) {
                ForEach(PlayerSpeed.options, id: \.self) { option in
                    Text(PlayerSpeed.label(option)).tag(option)
                }
            }
        } label: {
            Text(PlayerSpeed.label(playback.speed))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture().onEnded { onHoldChrome() })
        .onChange(of: playback.speed) { onInteraction() }
        .accessibilityLabel("播放速度")
    }

    /// "1:05", or "1:02:05" for an hour or more.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `seconds` with as many fields as `duration` needs: "0:05" under 10 minutes, "00:05" from
    /// 10 minutes, "0:00:05" from an hour.
    static func format(_ seconds: Double, fieldOf duration: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded(.down)) : 0
        let length = duration.isFinite && duration > 0 ? Int(duration.rounded(.down)) : 0
        if length >= 3600 || total >= 3600 {
            let hours = length >= 36000 ? "%02d" : "%d"
            return String(format: hours + ":%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
        }
        if length >= 600 {
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The widest time for `duration` (every digit is equally wide in monospaced digits).
    private static func template(for duration: Double) -> String {
        String(format(duration, fieldOf: duration).map { $0.isNumber ? "0" : $0 })
    }
}

/// The player's position and length, refreshed 30 times a second while the controls show.
@MainActor
final class MediaPlayerClock: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0

    private var observer: Any?
    private var subscriptions: Set<AnyCancellable> = []
    private var playback: MediaPlaybackController { MediaPlaybackController.shared }
    private var player: AVPlayer { playback.player }

    func start() {
        guard observer == nil else { return }
        refresh(force: true)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The length is known as soon as the item is, without waiting for a tick.
        player.publisher(for: \.currentItem?.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDuration() }
            .store(in: &subscriptions)
        playback.$currentURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(force: true) }
            .store(in: &subscriptions)
        // A seek landed: take its time at once (ticks were ignored while it ran, and a paused
        // player sends none), before the views fall back from the target to this clock.
        playback.$seekTarget
            .sink { [weak self] target in
                if target == nil { self?.refresh(force: true) }
            }
            .store(in: &subscriptions)
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        subscriptions.removeAll()
    }

    /// Ticks are ignored while a seek is pending or the scrubber is dragged: they would still
    /// report where the picture was.
    func refresh(force: Bool = false) {
        refreshDuration()
        guard force || (playback.seekTarget == nil && !playback.isScrubbing) else { return }
        let now = player.currentTime().seconds
        let value = now.isFinite ? max(0, now) : 0
        if value != time { time = value }
    }

    private func refreshDuration() {
        let length = player.currentItem?.duration.seconds ?? 0
        let value = length.isFinite ? max(0, length) : 0
        if value != duration { duration = value }
    }
}
