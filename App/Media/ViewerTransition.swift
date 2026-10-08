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

/// Hosts the pager without a safe area, SwiftUI's or UIKit's, so no page's layout depends on it. It
/// fills whatever frame it is given; the viewer gives it the whole screen (see ViewerPagerFrame).
struct ViewerEdgeToEdge<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> UIViewController {
        #if DEBUG
        switch ViewerEdgeExperiment.variant {
        case 0:
            return ViewerEdgeToEdgeController(rootView: content, fixesPagerInsets: false)
        case 2:
            return ViewerEdgeToEdgeController(rootView: content, fixesPagerInsets: true)
        case 3:
            return ViewerEdgeToEdgeBox(rootView: content, fixesPagerInsets: true)
        case 4:
            return ViewerEdgeToEdgeBox(rootView: content, fixesPagerInsets: false, safeAreaFreeView: true)
        default:
            break
        }
        #endif
        return ViewerEdgeToEdgeBox(rootView: content, fixesPagerInsets: false)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        if let box = controller as? ViewerEdgeToEdgeBox<Content> {
            box.rootView = content
        } else if let host = controller as? ViewerEdgeToEdgeController<Content> {
            host.rootView = content
        }
    }

    /// Always the whole space offered, never the pager's own idea of its size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Holds the pager's hosting controller as its child and takes away, as a negative additional inset,
/// all of the safe area the viewer around passes down: the pager and its pages get none, in UIKit
/// either.
///
/// UIKit hands the safe area of the screen (the status bar and the notch, the home indicator, and
/// held sideways the sides) to every view under the viewer, the pager's own scroll view too, which
/// UIKit sets in from the sides by it when the phone is sideways. While the viewer grows in or
/// shrinks out, its scale changes how far it reaches into those edges, so that inset changed on
/// every frame and the page moved sideways with it while it faded in, then slid back the next time
/// the pager laid out. And after turning the phone, the pager centred its page between the top and
/// the home indicator instead of on the screen. With no safe area inside, none of that can happen.
final class ViewerEdgeToEdgeBox<Content: View>: UIViewController {
    private let host: ViewerPagerHostingController<Content>

    var rootView: Content {
        get { host.rootView }
        set { host.rootView = newValue }
    }

    private let safeAreaFreeView: Bool

    init(rootView: Content, fixesPagerInsets: Bool, safeAreaFreeView: Bool = false) {
        host = ViewerPagerHostingController(rootView: rootView, fixesPagerInsets: fixesPagerInsets)
        self.safeAreaFreeView = safeAreaFreeView
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = safeAreaFreeView ? ViewerSafeAreaFreeView() : UIView()
        // The viewer's backdrop supplies the black; the folder shows through a page dragged away.
        view.backgroundColor = .clear
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        cancelSafeArea()
        #if DEBUG
        ViewerProbe.shared.register(view, as: "edgeBox")
        #endif
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        cancelSafeArea()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        cancelSafeArea()
    }

    private func cancelSafeArea() {
        let outer = view.safeAreaInsets
        let cancelling = UIEdgeInsets(top: -outer.top, left: -outer.left, bottom: -outer.bottom, right: -outer.right)
        guard host.additionalSafeAreaInsets != cancelling else { return }
        #if DEBUG
        ViewerProbe.shared.event("edgeBox safe=\(outer) -> host added \(cancelling)")
        #endif
        host.additionalSafeAreaInsets = cancelling
    }
}

/// A view that reports no safe area (variant 4 of the Debug experiment).
final class ViewerSafeAreaFreeView: UIView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

/// The pager's hosting controller: SwiftUI inside gets no safe area either.
final class ViewerPagerHostingController<Content: View>: UIHostingController<Content> {
    private let fixesPagerInsets: Bool

    init(rootView: Content, fixesPagerInsets: Bool) {
        self.fixesPagerInsets = fixesPagerInsets
        super.init(rootView: rootView)
        safeAreaRegions = []
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        #if DEBUG
        ViewerProbe.shared.register(view, as: "edgeHost")
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if fixesPagerInsets { ViewerPagerInsets.neverAdjust(in: view) }
    }
}

/// The paging scroll view of the pager never sets itself in from the safe area.
@MainActor
enum ViewerPagerInsets {
    static func neverAdjust(in view: UIView) {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView, scroll.isPagingEnabled {
                if scroll.contentInsetAdjustmentBehavior != .never {
                    scroll.contentInsetAdjustmentBehavior = .never
                }
                continue
            }
            neverAdjust(in: sub)
        }
    }
}

/// The pager's host as released in build-78 (variants 0 and 2 of the Debug experiment).
final class ViewerEdgeToEdgeController<Content: View>: UIHostingController<Content> {
    private let fixesPagerInsets: Bool

    init(rootView: Content, fixesPagerInsets: Bool) {
        self.fixesPagerInsets = fixesPagerInsets
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if fixesPagerInsets { ViewerPagerInsets.neverAdjust(in: view) }
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
        #if DEBUG
        ViewerProbe.shared.event("edgeHost safe=\(insets) added=\(added) -> \(cancelling)")
        #endif
        if cancelling != added { additionalSafeAreaInsets = cancelling }
    }
}

#if DEBUG
/// Debug builds only: which way of hosting the pager the viewer uses (`-ViewerEdgeVariant N`, for
/// the repro workflow's experiment): 0 as released in build-78, 1 the safe-area-free box, 2 and 3
/// those two with the pager's scroll view kept from setting itself in from the safe area, 4 the box
/// with a root view that reports no safe area instead of the negative inset.
enum ViewerEdgeExperiment {
    static var variant: Int {
        UserDefaults.standard.object(forKey: "ViewerEdgeVariant") == nil ? 1 : UserDefaults.standard.integer(forKey: "ViewerEdgeVariant")
    }
}
#endif
