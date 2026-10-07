import SwiftUI
import UIKit

/// Drag and drop onto the rows of a SwiftUI List. The List is a UICollectionView whose own drop
/// handling takes every drop that starts inside it, so drop destinations on its rows never fire.
/// This finds that collection view, swaps its drop interaction for one of ours, maps the finger to
/// a row and scrolls while the finger rests near the top or bottom edge. It sits behind the List;
/// if no collection view turns up it does nothing.
struct FolderUIDropBridge: UIViewRepresentable {
    /// Off while selecting.
    var isEnabled: Bool
    /// The id of the row at this index if a drop there means something (a folder or a video).
    var target: (Int) -> URL?
    /// The row under the finger that would take the drop, or nil.
    var onTargetChange: (URL?) -> Void
    /// The dragged tokens were dropped on the row with this id.
    var onDrop: ([String], URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: self)
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.bridge = self
        context.coordinator.attach(near: view)
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Looks for the collection view once it is on screen, and again a moment later in case the
    /// List was not laid out yet.
    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            for delay in [0.0, 0.6] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let coordinator = self.coordinator else { return }
                        coordinator.attach(near: self)
                    }
                }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var bridge: FolderUIDropBridge

        private lazy var interaction = UIDropInteraction(delegate: self)
        private weak var collectionView: UICollectionView?
        private weak var session: UIDropSession?
        private var currentTarget: URL?
        private var displayLink: CADisplayLink?

        init(bridge: FolderUIDropBridge) {
            self.bridge = bridge
        }

        /// Takes over the drops of the List's collection view. Safe to call any time: SwiftUI may
        /// put its own drop interaction back, and a new List brings a new collection view.
        func attach(near anchor: UIView) {
            guard anchor.window != nil else { return }
            if let view = collectionView, view.window != nil, interaction.view === view {
                removeOtherDropInteractions(from: view)
                return
            }
            guard let found = Self.collectionView(covering: anchor) else { return }
            interaction.view?.removeInteraction(interaction)
            removeOtherDropInteractions(from: found)
            found.addInteraction(interaction)
            collectionView = found
        }

        /// The List is going away: no highlight to clear, its state goes with it.
        func detach() {
            displayLink?.invalidate()
            displayLink = nil
            session = nil
            currentTarget = nil
            interaction.view?.removeInteraction(interaction)
            collectionView = nil
        }

        private func removeOtherDropInteractions(from view: UICollectionView) {
            for other in view.interactions where other is UIDropInteraction && other !== interaction {
                view.removeInteraction(other)
            }
        }

        /// The collection view lying under `anchor`, searched among its relatives, nearest first.
        private static func collectionView(covering anchor: UIView) -> UICollectionView? {
            guard let window = anchor.window else { return nil }
            let frame = anchor.convert(anchor.bounds, to: window)
            guard frame.width > 1, frame.height > 1 else { return nil }
            var ancestor = anchor.superview
            var level = 0
            while let current = ancestor, level < 8 {
                if let found = bestCover(of: frame, under: current, in: window) { return found }
                ancestor = current.superview
                level += 1
            }
            return nil
        }

        /// The collection view under `root` that overlaps `frame` the most, if it covers at least half.
        private static func bestCover(of frame: CGRect, under root: UIView, in window: UIWindow) -> UICollectionView? {
            var best: UICollectionView?
            var bestArea: CGFloat = 0
            var queue: [UIView] = [root]
            var index = 0
            while index < queue.count {
                let view = queue[index]
                index += 1
                if let candidate = view as? UICollectionView {
                    let overlap = candidate.convert(candidate.bounds, to: window).intersection(frame)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > bestArea {
                        best = candidate
                        bestArea = area
                    }
                    // Its cells are not where another List would be.
                    continue
                }
                if !view.isHidden { queue.append(contentsOf: view.subviews) }
            }
            return bestArea >= frame.width * frame.height * 0.5 ? best : nil
        }

        // MARK: - Dropping

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            bridge.isEnabled && session.localDragSession != nil && session.canLoadObjects(ofClass: NSString.self)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            self.session = session
            startAutoScroll()
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            self.session = session
            guard updateTarget(for: session) != nil else { return UIDropProposal(operation: .cancel) }
            return UIDropProposal(operation: session.allowsMoveOperation ? .move : .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            finish()
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            let target = updateTarget(for: session)
            finish()
            guard let target else { return }
            _ = session.loadObjects(ofClass: NSString.self) { [weak self] objects in
                let tokens = objects.compactMap { ($0 as? NSString).map { $0 as String } }
                Task { @MainActor in
                    self?.bridge.onDrop(tokens, target)
                }
            }
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            finish()
        }

        /// Highlights the row under the finger if it takes the drop; returns its id.
        @discardableResult
        private func updateTarget(for session: UIDropSession) -> URL? {
            var target: URL?
            if let view = collectionView,
               let path = view.indexPathForItem(at: session.location(in: view)),
               path.section == 0 {
                target = bridge.target(path.item)
            }
            if target != currentTarget {
                currentTarget = target
                bridge.onTargetChange(target)
            }
            return target
        }

        private func finish() {
            displayLink?.invalidate()
            displayLink = nil
            session = nil
            if currentTarget != nil {
                currentTarget = nil
                bridge.onTargetChange(nil)
            }
        }

        // MARK: - Scrolling at the edges

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(autoScroll(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        /// Scrolls while the finger is within 60 points of the visible top or bottom, faster the
        /// closer it gets to the edge.
        @objc private func autoScroll(_ link: CADisplayLink) {
            guard let view = collectionView, let session else { return }
            let point = session.location(in: view)
            let zone: CGFloat = 60
            let top = view.contentOffset.y + view.adjustedContentInset.top
            let bottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
            let push: CGFloat
            if point.y < top + zone {
                push = -min(1, (top + zone - point.y) / zone)
            } else if point.y > bottom - zone {
                push = min(1, (point.y - (bottom - zone)) / zone)
            } else {
                return
            }
            // Up to 900 points a second, whatever the display's frame rate.
            let seconds = CGFloat(max(link.targetTimestamp - link.timestamp, 1.0 / 120))
            let minY = -view.adjustedContentInset.top
            let maxY = max(minY, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
            let y = min(max(view.contentOffset.y + push * 900 * seconds, minY), maxY)
            guard abs(y - view.contentOffset.y) > 0.1 else { return }
            view.contentOffset.y = y
            updateTarget(for: session)
        }
    }
}
