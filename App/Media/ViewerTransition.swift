import SwiftUI
import UIKit

/// How far the viewer is on screen: its black backdrop, the pages' fade and scale while it opens
/// or closes, and a page being dragged to close. The viewer keeps it as a plain reference; only
/// the small views below observe it, so a drag never rebuilds the pages.
@MainActor
final class ViewerTransition: ObservableObject {
    /// Opacity of the black behind the pages; below 1 the folder shows through.
    @Published var backdrop: Double = 0
    @Published var isDragging = false
    /// 0 at rest, 1 after 300 pt of drag; fades the bars out quickly.
    @Published var dragProgress: Double = 0
    @Published var isExiting = false
    /// Animating in; the image PiP layer behind the pages stays hidden until it's done.
    @Published private(set) var isAppearing = false
    @Published var contentOpacity: Double = 0
    @Published var contentScale: CGFloat = 0.94

    private var dragToken = 0

    /// Fades the backdrop in and grows the pages to full size (or shows them at once).
    func appear(animated: Bool) {
        isExiting = false
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                backdrop = 1
                contentOpacity = 1
                contentScale = 1
                isAppearing = false
            }
            return
        }
        isAppearing = true
        withAnimation(.spring(duration: 0.28, bounce: 0)) {
            backdrop = 1
            contentOpacity = 1
            contentScale = 1
        } completion: { [weak self] in
            MainActor.assumeIsolated { self?.isAppearing = false }
        }
    }

    /// Fades the backdrop out (and the pages, unless a page flies off by itself), then `completion`.
    func exit(duration: Double, fadeContent: Bool, completion: @escaping () -> Void) {
        isExiting = true
        withAnimation(.easeOut(duration: duration)) {
            backdrop = 0
            if fadeContent {
                contentOpacity = 0
                contentScale = 0.96
            }
        } completion: {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// A page follows the finger `dy` points up or down on a page `height` tall.
    func dragChanged(_ dy: CGFloat, height: CGFloat) {
        guard !isExiting else { return }
        dragToken += 1
        if !isDragging { isDragging = true }
        dragProgress = Double(abs(dy) / 300)
        backdrop = 1 - min(1, Double(abs(dy) / (0.35 * max(1, height))))
    }

    /// The drag let go without closing: everything goes back with the page's `animation`.
    func dragCancelled(_ animation: Animation) {
        guard !isExiting else { return }
        dragToken += 1
        let token = dragToken
        withAnimation(animation) {
            backdrop = 1
            dragProgress = 0
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragToken == token else { return }
                self.isDragging = false
            }
        }
    }
}

/// The black behind the pages, with the image PiP layer between two layers of it: on screen (PiP
/// takes its picture from there) but covered, and hidden while the folder shows through.
struct ViewerBackdrop: View {
    @ObservedObject var transition: ViewerTransition
    @ObservedObject private var imagePiP = MediaImagePiPController.shared

    private var hidesPictureInPictureLayer: Bool {
        (transition.isDragging || transition.isExiting || transition.isAppearing) && !imagePiP.isActive
    }

    var body: some View {
        ZStack {
            Color.black.opacity(transition.backdrop)
            MediaImagePiPLayerHost()
                .opacity(hidesPictureInPictureLayer ? 0 : 1)
            // Keeps that picture out of the gaps between pages.
            Color.black.opacity(transition.backdrop)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// With a clear background the cover is presented over the folder, and UIKit would let the folder
/// decide the status bar and home indicator. This hands that decision back to the viewer, so they
/// still hide with its bars.
struct ViewerPresentationProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ViewerPresentationProbeView {
        let view = ViewerPresentationProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ViewerPresentationProbeView, context: Context) {}
}

final class ViewerPresentationProbeView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                // The presented controller is the root of its own hierarchy.
                var presented = controller
                while let parent = presented.parent { presented = parent }
                guard presented.presentingViewController != nil else { return }
                if !presented.modalPresentationCapturesStatusBarAppearance {
                    presented.modalPresentationCapturesStatusBarAppearance = true
                }
                presented.setNeedsStatusBarAppearanceUpdate()
                presented.setNeedsUpdateOfHomeIndicatorAutoHidden()
                return
            }
            responder = current.next
        }
    }
}

/// Fades and scales the pages as the viewer opens or closes, without rebuilding them.
struct ViewerPagerFrame<Content: View>: View {
    @ObservedObject var transition: ViewerTransition
    @ViewBuilder let content: Content

    var body: some View {
        content
            .opacity(transition.contentOpacity)
            .scaleEffect(transition.contentScale)
    }
}
