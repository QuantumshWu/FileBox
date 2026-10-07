import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// One image of the viewer. The list's thumbnail (or an earlier decode) shows at once and the
/// decoded picture takes its place without moving. Swiped up or down, it follows the finger,
/// shrinks and closes the viewer.
struct MediaImagePage: View {
    let item: FileItem
    let transition: ViewerTransition
    let onTap: () -> Void
    /// Swiped far or fast enough: the viewer starts closing while the page flies off.
    let onDismiss: () -> Void
    let onQuickLook: (URL) -> Void

    @State private var image: UIImage?
    @State private var failed = false
    @State private var showsSpinner = false
    @State private var drag = ViewerDrag()

    var body: some View {
        // Read on every render, so a decoded (or prefetched) picture shows on the first frame.
        let shown = image
            ?? MediaImageLoader.cachedImage(for: item, maxPixel: MediaImageLoader.displayMaxPixel)
            ?? Thumbnails.cachedPlaceholder(for: item)
        ZStack {
            Color.clear.contentShape(Rectangle())
            if let shown {
                // One branch for the placeholder and the full picture: the same zoom view stays.
                MediaZoomableImage(
                    image: shown,
                    sourceURL: item.url,
                    onSingleTap: onTap,
                    onDismissEvent: dismissEvent
                )
            } else if failed {
                ViewerDismissDragArea(onTap: onTap, onEvent: dismissEvent)
                MediaUnsupportedView(message: "无法显示这张图片", url: item.url, onQuickLook: onQuickLook)
            } else {
                ViewerDismissDragArea(onTap: onTap, onEvent: dismissEvent)
                if showsSpinner {
                    ProgressView()
                        .tint(.white)
                        .allowsHitTesting(false)
                }
            }
        }
        .scaleEffect(drag.scale, anchor: drag.anchor)
        .offset(drag.offset)
        .task(id: item.url) {
            failed = false
            let loaded = await MediaImageLoader.load(item, maxPixel: MediaImageLoader.displayMaxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
        .task(id: item.url) {
            // Only a slow picture gets a spinner.
            showsSpinner = false
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            showsSpinner = true
        }
        .onDisappear {
            // Pages the viewer has moved past keep no full-size picture; it comes from the cache again.
            image = nil
            failed = false
            showsSpinner = false
            drag = ViewerDrag()
        }
    }

    private func dismissEvent(_ event: ViewerDismissEvent) {
        ViewerDrag.handle(event, drag: $drag, transition: transition, onCommit: onDismiss)
    }
}

/// One video or audio file. Only the page of the file in the player hosts the shared player view;
/// the others show the first frame (or the audio layout) until the viewer moves to them. On the
/// video, a double tap on the left or right skips back or forward, in the middle plays or pauses,
/// and pressing and holding plays at 2×.
struct MediaPlayablePage: View {
    let item: FileItem
    let transition: ViewerTransition
    let onTap: () -> Void
    /// A double tap or a long press: the viewer's bars restart their auto-hide.
    let onInteraction: () -> Void
    /// Swiped far or fast enough: the viewer starts closing while the page flies off.
    let onDismiss: () -> Void
    let onQuickLook: (URL) -> Void

    @ObservedObject private var playback = MediaPlaybackController.shared
    @AppStorage(ViewerSkipStep.storageKey) private var storedStep = ViewerSkipStep.defaultSeconds
    @State private var isPlayable: Bool?
    @State private var poster: UIImage?
    @State private var drag = ViewerDrag()
    /// The player has shown this file's first frame since it became the playing one, so the poster
    /// never comes back over it (PiP returning, the app coming back).
    @State private var revealed = false
    @State private var skipShown: ViewerSkipFeedback?
    /// The last skip, so double taps in a row on the same side add up.
    @State private var lastSkip: ViewerSkipFeedback?
    @State private var toggleShown: ViewerToggleFeedback?

    private var isCurrent: Bool { playback.currentURL == item.url }

    private var shownPoster: UIImage? {
        poster ?? ViewerPosterCache.cached(for: item) ?? Thumbnails.cachedPlaceholder(for: item)
    }

    /// The first frame covers the player until the player has a picture of its own.
    private var showsPoster: Bool {
        item.kind == .video && !revealed && playback.displayReadyURL != item.url
            && !playback.isPictureInPictureEngaged
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            content
        }
        .scaleEffect(drag.scale, anchor: drag.anchor)
        .offset(drag.offset)
        .task(id: item.url) { await load() }
        .onAppear {
            if playback.displayReadyURL == item.url { revealed = true }
        }
        .onChange(of: playback.displayReadyURL) { _, url in
            if url == item.url { revealed = true }
        }
        .onChange(of: playback.currentURL) { _, url in
            if url != item.url { revealed = false }
        }
        .onDisappear {
            poster = nil
            drag = ViewerDrag()
            skipShown = nil
            toggleShown = nil
            if isCurrent && playback.isBoosted { playback.endBoost() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isPlayable == false || playback.failedURLs.contains(item.url) {
            ViewerDismissDragArea(onTap: onTap, onEvent: dismissEvent)
            MediaUnsupportedView(
                message: item.kind == .audio ? "不支持这种音频格式" : "不支持这种视频格式",
                url: item.url,
                onQuickLook: onQuickLook
            )
        } else if isCurrent {
            MediaPlayerHost(
                onTap: onTap,
                onDoubleTap: doubleTapped(at:),
                onLongPress: longPressChanged(_:),
                onDismissEvent: dismissEvent
            )
            ZStack {
                if showsPoster, let poster = shownPoster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showsPoster)
            .allowsHitTesting(false)
            if playback.isBuffering && item.kind == .video {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                    .allowsHitTesting(false)
            }
            feedback
        } else {
            ViewerDismissDragArea(onTap: onTap, onEvent: dismissEvent)
            placeholder
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if item.kind == .audio {
            ViewerAudioPlaceholder(title: (item.name as NSString).deletingPathExtension)
        } else if let poster = shownPoster {
            Image(uiImage: poster)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "film")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// The skip ripple and the play / pause glyph of the double tap.
    private var feedback: some View {
        ZStack {
            if let skipShown {
                ViewerSkipRipple(feedback: skipShown)
                    .transition(.opacity)
            }
            if let toggleShown {
                Image(systemName: toggleShown.symbol)
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .id(toggleShown.id)
            }
        }
        .allowsHitTesting(false)
    }

    private func load() async {
        let asset = PlayerAssetCache.asset(for: item)
        async let playable = Self.loadPlayable(asset)
        async let frame = posterFrame()
        let isOK = await playable
        guard !Task.isCancelled else { return }
        isPlayable = isOK
        let image = await frame
        guard !Task.isCancelled, isOK, let image else { return }
        poster = image
    }

    private static func loadPlayable(_ asset: AVURLAsset) async -> Bool {
        (try? await asset.load(.isPlayable)) ?? false
    }

    private func posterFrame() async -> UIImage? {
        guard item.kind == .video else { return nil }
        return await ViewerPosterCache.poster(for: item)
    }

    private func dismissEvent(_ event: ViewerDismissEvent) {
        ViewerDrag.handle(event, drag: $drag, transition: transition, onCommit: onDismiss)
    }

    /// `x` is where the second tap landed, as a share of the page's width.
    private func doubleTapped(at x: CGFloat) {
        guard isCurrent, !playback.failedURLs.contains(item.url) else { return }
        if x < 0.35 || x > 0.65 {
            let forward = x > 0.65
            let step = ViewerSkipStep.seconds(storedStep)
            guard playback.seek(by: Double(forward ? step : -step)) else { return }
            let now = Date()
            var total = step
            if let lastSkip, lastSkip.forward == forward, now < lastSkip.continuesUntil {
                total += lastSkip.seconds
            }
            let skip = ViewerSkipFeedback(forward: forward, seconds: total, continuesUntil: now.addingTimeInterval(0.7))
            lastSkip = skip
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { skipShown = skip }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard skipShown?.id == skip.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { skipShown = nil }
            }
        } else {
            let wasPlaying = playback.isPlaying
            playback.togglePlayPause()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let toggle = ViewerToggleFeedback(symbol: wasPlaying ? "pause.fill" : "play.fill")
            withAnimation(.easeOut(duration: 0.12)) { toggleShown = toggle }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard toggleShown?.id == toggle.id else { return }
                withAnimation(.easeOut(duration: 0.25)) { toggleShown = nil }
            }
        }
        onInteraction()
    }

    private func longPressChanged(_ began: Bool) {
        if began {
            guard isCurrent, !playback.failedURLs.contains(item.url) else { return }
            if playback.beginBoost() {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } else {
            playback.endBoost()
            onInteraction()
        }
    }
}

/// A double tap's skip: which side, and how far the taps in a row have gone together.
struct ViewerSkipFeedback: Equatable {
    let id = UUID()
    let forward: Bool
    let seconds: Int
    /// Another double tap on the same side before this adds to `seconds`.
    let continuesUntil: Date
}

struct ViewerToggleFeedback: Equatable {
    let id = UUID()
    let symbol: String
}

/// The seconds a double tap (or the skip buttons) jumps, set in 设置.
enum ViewerSkipStep {
    static let storageKey = "mediaDoubleTapStep"
    static let defaultSeconds = 10

    /// The stored value made usable (unset or 0 means 10; the symbols exist for 5, 10, 15, 30).
    static func seconds(_ stored: Int) -> Int {
        [5, 10, 15, 30].contains(stored) ? stored : defaultSeconds
    }
}

/// A half oval on the side that was double-tapped, with how far the video skipped.
struct ViewerSkipRipple: View {
    let feedback: ViewerSkipFeedback

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Ellipse()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: size.width * 0.75, height: size.height * 1.3)
                    .position(x: feedback.forward ? size.width : 0, y: size.height / 2)
                Text(feedback.forward ? "\(feedback.seconds) 秒 »" : "« \(feedback.seconds) 秒")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .position(x: feedback.forward ? size.width * 0.82 : size.width * 0.18, y: size.height / 2)
            }
        }
        .clipped()
    }
}

/// An audio file that isn't in the player yet, laid out like the player's own audio overlay so
/// nothing moves when it starts.
struct ViewerAudioPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .foregroundStyle(.white.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 24)
        .offset(y: -30)
    }
}

/// A page the viewer can't show (a folder or another kind of file), which still closes with a
/// swipe up or down.
struct ViewerUnsupportedPage: View {
    let item: FileItem
    let transition: ViewerTransition
    let onTap: () -> Void
    let onDismiss: () -> Void
    let onQuickLook: (URL) -> Void

    @State private var drag = ViewerDrag()

    var body: some View {
        ZStack {
            ViewerDismissDragArea(onTap: onTap) { event in
                ViewerDrag.handle(event, drag: $drag, transition: transition, onCommit: onDismiss)
            }
            MediaUnsupportedView(message: "无法预览这个文件", url: item.url, onQuickLook: onQuickLook)
        }
        .scaleEffect(drag.scale, anchor: drag.anchor)
        .offset(drag.offset)
        .onDisappear { drag = ViewerDrag() }
    }
}

/// A file AVFoundation (or ImageIO) cannot show, with Quick Look as a fallback.
struct MediaUnsupportedView: View {
    let message: String
    let url: URL
    let onQuickLook: (URL) -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.6))
            Text(message)
                .font(.headline)
            Text(url.lastPathComponent)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button {
                onQuickLook(url)
            } label: {
                Label("用「快速查看」打开", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

/// Hosts `MediaPlaybackController.shared.playerViewController`. The player controller outlives the
/// page, so the page only borrows it: whichever host comes on screen last takes it.
struct MediaPlayerHost: UIViewControllerRepresentable {
    let onTap: () -> Void
    let onDoubleTap: (CGFloat) -> Void
    let onLongPress: (Bool) -> Void
    let onDismissEvent: (ViewerDismissEvent) -> Void

    func makeUIViewController(context: Context) -> MediaPlayerHostController {
        let controller = MediaPlayerHostController()
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: MediaPlayerHostController, context: Context) {
        configure(controller)
        controller.attachPlayer(force: false)
    }

    private func configure(_ controller: MediaPlayerHostController) {
        controller.onTap = onTap
        controller.onDoubleTap = onDoubleTap
        controller.onLongPress = onLongPress
        controller.dismiss.onEvent = onDismissEvent
    }

    static func dismantleUIViewController(_ controller: MediaPlayerHostController, coordinator: Coordinator) {
        controller.detachPlayer()
    }
}

final class MediaPlayerHostController: UIViewController, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    /// Where the second tap landed, as a share of the width.
    var onDoubleTap: ((CGFloat) -> Void)?
    /// True when a press is held long enough, false when it lets go.
    var onLongPress: ((Bool) -> Void)?
    let dismiss = ViewerDismissPan()

    private let doubleTap = UITapGestureRecognizer()
    private let longPress = UILongPressGestureRecognizer()

    override func loadView() {
        let host = MediaWindowObservingView()
        host.backgroundColor = .clear
        host.onWindowChange = { [weak self] inWindow in
            if inWindow { self?.attachPlayer(force: true) }
        }
        view = host
        #if DEBUG
        ViewerProbe.shared.register(host, as: "playerHost")
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Double tap: skip back or forward on the sides, play or pause in the middle.
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)
        // Press and hold: 2× until the finger lifts.
        longPress.addTarget(self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.allowableMovement = 12
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        view.addGestureRecognizer(longPress)
        // A tap shows or hides the viewer's bars, once it can't be a double tap or a hold.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.require(toFail: doubleTap)
        tap.require(toFail: longPress)
        view.addGestureRecognizer(tap)
        // Swipe up or down to close, like an image page.
        dismiss.blockingPress = longPress
        dismiss.install(on: view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for child in children { child.view.frame = view.bounds }
    }

    /// Takes the shared player view. `force` is for a host that just came on screen; otherwise it
    /// only takes a player no other on-screen host holds, so a viewer that is being dismissed
    /// while the next one appears doesn't pull the player back on every update.
    func attachPlayer(force: Bool) {
        let playerController = MediaPlaybackController.shared.playerViewController
        let heldElsewhere = playerController.parent.map { $0 !== self && $0.viewIfLoaded?.window != nil } ?? false
        if heldElsewhere && !force { return }
        if playerController.parent !== self {
            if playerController.parent != nil {
                playerController.willMove(toParent: nil)
                playerController.view.removeFromSuperview()
                playerController.removeFromParent()
            }
            MediaPlaybackController.shared.surfaceMoved()
            addChild(playerController)
            playerController.view.frame = view.bounds
            playerController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(playerController.view)
            playerController.didMove(toParent: self)
        }
        if view.window != nil { MediaPlaybackController.shared.playerViewDidAppear() }
    }

    func detachPlayer() {
        let playerController = MediaPlaybackController.shared.playerViewController
        guard playerController.parent === self else { return }
        playerController.willMove(toParent: nil)
        playerController.view.removeFromSuperview()
        playerController.removeFromParent()
    }

    @objc private func tapped() {
        onTap?()
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        let width = max(1, view.bounds.width)
        onDoubleTap?(gesture.location(in: view).x / width)
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            onLongPress?(true)
        case .ended, .cancelled, .failed:
            onLongPress?(false)
        default:
            break
        }
    }

    /// 2× only for a playing video; on a paused one a held finger can still swipe to close or page.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === longPress { return MediaPlaybackController.shared.isPlaying }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dismiss.pan || otherGestureRecognizer === dismiss.pan { return false }
        // Held for 2×, the finger neither pages nor closes.
        if gestureRecognizer === longPress, otherGestureRecognizer is UIPanGestureRecognizer,
           otherGestureRecognizer.view is UIScrollView {
            return false
        }
        return true
    }

    /// Touches on buttons and sliders only work those.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let candidate = current, candidate !== view {
            if candidate is UIControl { return false }
            current = candidate.superview
        }
        return true
    }
}

/// Reports when it enters or leaves a window.
final class MediaWindowObservingView: UIView {
    var onWindowChange: ((Bool) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
    }
}

/// The viewer's backdrop, which holds the image PiP layer behind the pages.
struct MediaImagePiPLayerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> MediaImagePiPHostView {
        let view = MediaImagePiPHostView()
        // The viewer's backdrop supplies the black.
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MediaImagePiPHostView, context: Context) {}
}
