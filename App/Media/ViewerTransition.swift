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
            // Only under the PiP layer; otherwise it would double the black above while fading.
            Color.black.opacity(hidesPictureInPictureLayer ? 0 : transition.backdrop)
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
        #if DEBUG
        ViewerProbe.shared.event("presentation probe in window")
        #endif
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
///
/// It must be given the whole screen: the safe area is ignored around it, not by the pages inside.
/// While a view is scaled below full size, SwiftUI does not extend it into the safe area, so pages
/// that ignored the safe area themselves were laid out inside it while the viewer grew in (14 pt
/// lower and smaller on a Dynamic Island iPhone), and moved up and grew to the whole screen at the
/// first layout after the animation ended; closing with the button moved them back down. Laid out
/// edge to edge outside the scale, they are only drawn smaller and never move.
///
/// The fade and the scale are worked out by SwiftUI on every frame (`ViewerPagerFade`). Left to
/// SwiftUI's own animation of the hosted pager, it handed them to Core Animation in pieces, and as
/// one piece gave way to the next the closing picture came back for a frame at three quarters of
/// its opacity and almost full size.
struct ViewerPagerFrame<Content: View>: View {
    @ObservedObject var transition: ViewerTransition
    @ViewBuilder let content: Content

    var body: some View {
        content
            .modifier(ViewerPagerFade(opacity: transition.contentOpacity, scale: transition.contentScale))
    }
}

/// Opacity and scale as one animatable value: SwiftUI interpolates it and sets the result on each
/// frame, so what is drawn is always exactly the animation's current value.
private struct ViewerPagerFade: ViewModifier, Animatable {
    var opacity: Double
    var scale: CGFloat

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(opacity, scale) }
        set {
            opacity = newValue.first
            scale = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
    }
}

/// Hosts the pager without a SwiftUI safe area, so no page's layout depends on it: the bars and the
/// status bar showing or hiding (which changes the safe area on iPhones without a notch) never move
/// a page. It fills whatever frame it is given; the viewer gives it the whole screen (see
/// ViewerPagerFrame).
struct ViewerEdgeToEdge<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIViewController {
        #if DEBUG
        switch ViewerEdgeExperiment.variant {
        case 1: return ViewerEdgeContainer(rootView: content, zeroView: false)
        case 2: return ViewerEdgeContainer(rootView: content, zeroView: true)
        case 3:
            let controller = ViewerEdgeToEdgeController(rootView: content)
            controller.neverAdjustsPager = true
            return controller
        default: break
        }
        #endif
        return ViewerEdgeToEdgeController(rootView: content)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let controller = controller as? ViewerEdgeToEdgeController<Content> {
            controller.rootView = content
        }
        #if DEBUG
        if let container = controller as? ViewerEdgeContainer<Content> {
            container.host.rootView = content
        }
        #endif
    }

    /// Always the whole space offered, never the pager's own idea of its size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

#if DEBUG
/// Debug builds only, for the repro workflow's experiment: which way of hosting the pager keeps
/// the window's safe area away from the pager's UIKit views (`-ViewerEdgeVariant N`).
enum ViewerEdgeExperiment {
    static let variant: Int = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ViewerEdgeVariant"), index + 1 < arguments.count else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }()
}

/// Variant 1: a plain container cancelling the safe area with negative additional insets; variant
/// 2: a container whose view reports no safe area. The hosting controller is its child.
final class ViewerEdgeContainer<Content: View>: UIViewController {
    let host: UIHostingController<Content>
    private let zeroView: Bool

    init(rootView: Content, zeroView: Bool) {
        host = UIHostingController(rootView: rootView)
        self.zeroView = zeroView
        super.init(nibName: nil, bundle: nil)
        host.safeAreaRegions = []
        host.overrideUserInterfaceStyle = .dark
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = zeroView ? ViewerZeroSafeAreaView() : UIView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        ViewerProbe.shared.register(host.view, as: "edgeHost")
        ViewerProbe.shared.register(view, as: "edgeBox")
        ViewerProbe.shared.event("edge variant \(ViewerEdgeExperiment.variant)")
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard !zeroView else { return }
        let added = additionalSafeAreaInsets
        let insets = view.safeAreaInsets
        let cancelling = UIEdgeInsets(
            top: added.top - insets.top,
            left: added.left - insets.left,
            bottom: added.bottom - insets.bottom,
            right: added.right - insets.right
        )
        if cancelling != added { additionalSafeAreaInsets = cancelling }
    }
}

final class ViewerZeroSafeAreaView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}
#endif

final class ViewerEdgeToEdgeController<Content: View>: UIHostingController<Content> {
    #if DEBUG
    /// Variant 3 of the experiment: the pager's scroll view never adjusts its insets.
    var neverAdjustsPager = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard neverAdjustsPager, let pager = Self.pagingScrollView(in: view),
              pager.contentInsetAdjustmentBehavior != .never
        else { return }
        pager.contentInsetAdjustmentBehavior = .never
        ViewerProbe.shared.event("edge variant 3: pager never adjusts")
    }

    private static func pagingScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView, scroll.isPagingEnabled { return scroll }
            if let found = pagingScrollView(in: sub) { return found }
        }
        return nil
    }
    #endif

    override init(rootView: Content) {
        super.init(rootView: rootView)
        // SwiftUI inside gets no safe area.
        safeAreaRegions = []
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The viewer's backdrop supplies the black; the folder shows through a page dragged away.
        view.backgroundColor = .clear
        #if DEBUG
        ViewerProbe.shared.register(view, as: "edgeHost")
        #endif
    }

    /// Cancels the safe area the viewer around passes down, so the UIKit views inside (the
    /// pager's scroll view and its pages) get none either.
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let added = additionalSafeAreaInsets
        let insets = view.safeAreaInsets
        let cancelling = UIEdgeInsets(
            top: added.top - insets.top,
            left: added.left - insets.left,
            bottom: added.bottom - insets.bottom,
            right: added.right - insets.right
        )
        if cancelling != added { additionalSafeAreaInsets = cancelling }
    }
}
