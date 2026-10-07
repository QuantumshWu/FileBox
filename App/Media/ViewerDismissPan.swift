import SwiftUI
import UIKit

/// One step of the swipe up or down that closes the viewer.
enum ViewerDismissEvent {
    /// The page follows the finger; `anchor` is where it was touched, `height` the page's height.
    case changed(offset: CGSize, anchor: UnitPoint, height: CGFloat)
    /// Let go without closing; `velocity` is the finger's vertical speed (points per second).
    case cancelled(velocity: CGFloat)
    /// Let go far or fast enough: the page flies off and the viewer closes.
    case committed(velocity: CGSize)
}

/// The vertical pan that closes the viewer, shared by images, videos and pages that show nothing.
/// It starts only for a mostly vertical drag (never on a zoomed image or during 2× playback), and
/// the scroll views' own pans (paging, panning a zoomed image) wait until it gives up.
@MainActor
final class ViewerDismissPan: NSObject, UIGestureRecognizerDelegate {
    let pan = UIPanGestureRecognizer()
    /// A zoomable image: zoomed in, a drag pans the picture instead.
    weak var zoomView: UIScrollView?
    /// While this long press runs (2× playback) the finger neither pages nor closes.
    weak var blockingPress: UILongPressGestureRecognizer?
    var onEvent: ((ViewerDismissEvent) -> Void)?

    private var anchor: UnitPoint = .center
    private var height: CGFloat = 1

    override init() {
        super.init()
        pan.addTarget(self, action: #selector(handle(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
    }

    func install(on view: UIView) {
        view.addGestureRecognizer(pan)
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        // In window coordinates: SwiftUI moves the view itself along with the finger.
        let translation = pan.translation(in: nil)
        let offset = CGSize(width: translation.x, height: translation.y)
        #if DEBUG
        if pan.state == .began { ViewerProbe.shared.event("dismiss drag began") }
        if pan.state == .ended || pan.state == .cancelled { ViewerProbe.shared.event("dismiss drag ended") }
        #endif
        switch pan.state {
        case .began:
            if let view = pan.view, view.bounds.width > 0, view.bounds.height > 0 {
                let location = pan.location(in: view)
                let bounds = view.bounds
                anchor = UnitPoint(
                    x: min(1, max(0, (location.x - bounds.minX) / bounds.width)),
                    y: min(1, max(0, (location.y - bounds.minY) / bounds.height))
                )
                height = bounds.height
            } else {
                anchor = .center
                height = max(1, pan.view?.window?.bounds.height ?? 1)
            }
            onEvent?(.changed(offset: offset, anchor: anchor, height: height))
        case .changed:
            onEvent?(.changed(offset: offset, anchor: anchor, height: height))
        case .ended:
            let velocity = pan.velocity(in: nil)
            // Positive while the finger moves away from where it started.
            let outward = velocity.y * (translation.y < 0 ? -1 : 1)
            if (abs(translation.y) > 100 && outward > -150) || outward > 700 {
                onEvent?(.committed(velocity: CGSize(width: velocity.x, height: velocity.y)))
            } else {
                onEvent?(.cancelled(velocity: velocity.y))
            }
        default:
            onEvent?(.cancelled(velocity: 0))
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        if pan.numberOfTouches > 1 { return false }
        if let press = blockingPress, press.state == .began || press.state == .changed { return false }
        if let zoomView, zoomView.zoomScale > zoomView.minimumZoomScale + 0.01 { return false }
        let translation = pan.translation(in: pan.view?.superview)
        return abs(translation.y) > abs(translation.x) * 1.2
    }

    /// Paging sideways (and panning a zoomed image) waits until a drag turns out not to be a swipe
    /// to close.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === pan && otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }

    /// Buttons and sliders only work themselves.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let candidate = current, candidate !== gestureRecognizer.view {
            if candidate is UIControl { return false }
            current = candidate.superview
        }
        return true
    }
}

/// A page's position while it is dragged to close: pinned under the finger, shrinking toward 0.65.
struct ViewerDrag: Equatable {
    var offset: CGSize = .zero
    var anchor: UnitPoint = .center
    var height: CGFloat = 1

    var scale: CGFloat {
        1 - 0.35 * min(1, abs(offset.height) / (0.5 * max(1, height)))
    }

    /// Applies one event of the swipe to a page's `drag` state. `onCommit` starts the viewer's
    /// exit (backdrop, pausing); the page then flies off in the direction it was thrown.
    @MainActor
    static func handle(
        _ event: ViewerDismissEvent,
        drag: Binding<ViewerDrag>,
        transition: ViewerTransition,
        onCommit: () -> Void
    ) {
        switch event {
        case let .changed(offset, anchor, height):
            guard !transition.isExiting else { return }
            drag.wrappedValue = ViewerDrag(offset: offset, anchor: anchor, height: height)
            transition.dragChanged(offset.height, height: height)
        case let .cancelled(velocity):
            guard !transition.isExiting else { return }
            let distance = drag.wrappedValue.offset.height
            // The spring starts at the speed the finger let go with (as a share of the way back).
            let relative = abs(distance) < 1 ? 0 : min(30, max(-30, -velocity / distance))
            let spring = Animation.interpolatingSpring(stiffness: 320, damping: 32, initialVelocity: Double(relative))
            withAnimation(spring) {
                drag.wrappedValue.offset = .zero
            }
            transition.dragCancelled(spring)
        case let .committed(velocity):
            guard !transition.isExiting else { return }
            onCommit()
            let current = drag.wrappedValue
            let direction: CGFloat = current.offset.height < 0 ? -1 : 1
            let target = CGSize(
                width: current.offset.width + velocity.width * 0.08,
                height: direction * (max(1, current.height) + 80)
            )
            withAnimation(.easeOut(duration: 0.22)) {
                drag.wrappedValue.offset = target
            }
        }
    }
}

/// A clear area that toggles the bars on a tap and closes the viewer on a swipe up or down, for
/// pages without a picture to drag (loading, failed, unsupported). UIKit, so it cooperates with
/// the pager's pan instead of fighting it.
struct ViewerDismissDragArea: UIViewRepresentable {
    let onTap: () -> Void
    let onEvent: (ViewerDismissEvent) -> Void

    func makeUIView(context: Context) -> ViewerDismissDragView {
        let view = ViewerDismissDragView()
        configure(view)
        return view
    }

    func updateUIView(_ view: ViewerDismissDragView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ViewerDismissDragView) {
        view.onTap = onTap
        view.dismiss.onEvent = onEvent
    }
}

final class ViewerDismissDragView: UIView {
    var onTap: (() -> Void)?
    let dismiss = ViewerDismissPan()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = dismiss
        addGestureRecognizer(tap)
        dismiss.install(on: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        onTap?()
    }
}
