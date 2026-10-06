import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// One image of the viewer, decoded at a bounded size.
struct MediaImagePage: View {
    let item: FileItem
    let onTap: () -> Void
    let onQuickLook: (URL) -> Void

    /// Longest side decoded for display: sharp when zoomed in a little, without decoding 50 MP.
    private static let maxPixel: CGFloat = 3000

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let image {
                MediaZoomableImage(image: image, onSingleTap: onTap)
            } else if failed {
                MediaUnsupportedView(message: "无法显示这张图片", url: item.url, onQuickLook: onQuickLook)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        .task(id: item.url) {
            let loaded = await MediaImageLoader.load(item.url, maxPixel: Self.maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
        .onDisappear {
            // Pages the viewer has moved past keep no full-size picture; it comes from the cache again.
            image = nil
            failed = false
        }
    }
}

/// One video or audio file. Only the page of the file in the player hosts the shared player view;
/// the others show a still frame until the viewer moves to them.
struct MediaPlayablePage: View {
    let item: FileItem
    let onTap: () -> Void
    let onQuickLook: (URL) -> Void

    @ObservedObject private var playback = MediaPlaybackController.shared
    @Environment(\.displayScale) private var displayScale
    @State private var isPlayable: Bool?
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if isPlayable == false || playback.failedURLs.contains(item.url) {
                MediaUnsupportedView(
                    message: item.kind == .audio ? "不支持这种音频格式" : "不支持这种视频格式",
                    url: item.url,
                    onQuickLook: onQuickLook
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            } else if playback.currentURL == item.url {
                MediaPlayerHost(onTap: onTap)
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
        }
        .task(id: item.url) {
            let asset = AVURLAsset(url: item.url)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard !Task.isCancelled else { return }
            isPlayable = playable
            if playable, item.kind == .video, poster == nil {
                poster = await Thumbnails.image(for: item, side: 600, scale: displayScale)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let poster {
            Image(uiImage: poster)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: item.kind == .audio ? "music.note" : "film")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.5))
        }
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

    func makeUIViewController(context: Context) -> MediaPlayerHostController {
        let controller = MediaPlayerHostController()
        controller.onTap = onTap
        return controller
    }

    func updateUIViewController(_ controller: MediaPlayerHostController, context: Context) {
        controller.onTap = onTap
        controller.attachPlayer(force: false)
    }

    static func dismantleUIViewController(_ controller: MediaPlayerHostController, coordinator: Coordinator) {
        controller.detachPlayer()
    }
}

final class MediaPlayerHostController: UIViewController, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?

    override func loadView() {
        let host = MediaWindowObservingView()
        host.backgroundColor = .black
        host.onWindowChange = { [weak self] inWindow in
            if inWindow { self?.attachPlayer(force: true) }
        }
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Keep the player's own top controls clear of the viewer's top bar.
        additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
        // Taps toggle the viewer's bar as well as the player's controls; double taps belong to the player.
        let doubleTap = UITapGestureRecognizer(target: nil, action: nil)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    /// Taps on the player's buttons and slider only work those.
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
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MediaImagePiPHostView, context: Context) {}
}
