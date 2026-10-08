import SwiftUI
import UIKit

/// Keeps the folder still when a screen over it hides the status bar.
///
/// On an iPhone with a Home button the status bar is the top of the safe area, so hiding it took
/// 20 pt off the top of the safe area of everything in the window, the folder under the viewer
/// too: the folder moved up while it still showed through the viewer fading in, and back down
/// after the viewer had gone. The tab bar, the navigation bar and the lists lay out against the
/// root controller's safe area, so the root controller gets back, as an additional inset, what the
/// hidden status bar took off its top: its top inset never drops below the one it had with the
/// status bar in that shape of the screen. iPhones with a notch or a Dynamic Island keep their top
/// inset with the status bar hidden, so there nothing is ever added. Screens presented over the
/// folder (the viewer) are not under the root controller's view and keep their own safe area.
struct StatusBarInsetKeeper: UIViewRepresentable {
    func makeUIView(context: Context) -> StatusBarInsetKeeperView {
        let view = StatusBarInsetKeeperView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: StatusBarInsetKeeperView, context: Context) {}
}

final class StatusBarInsetKeeperView: UIView {
    private struct Shape: Hashable {
        let width: CGFloat
        let height: CGFloat
    }

    /// For each size of the window, the largest top inset the window gave the root controller:
    /// the one with the status bar showing.
    private var fullTop: [Shape: CGFloat] = [:]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        update()
    }

    // Called while UIKit hands a new safe area down, before anything under the root is laid out
    // with it, so the folder never draws a frame with the smaller inset.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        update()
    }

    private func update() {
        guard let window, let root = window.rootViewController, root.isViewLoaded,
              isDescendant(of: root.view)
        else { return }
        let added = root.additionalSafeAreaInsets.top
        // What the window gives the root, without what is added here.
        let given = max(0, root.view.safeAreaInsets.top - added)
        let shape = Shape(width: window.bounds.width, height: window.bounds.height)
        let full = max(fullTop[shape] ?? 0, given)
        fullTop[shape] = full
        let wanted = full - given
        guard abs(wanted - added) > 0.01 else { return }
        #if DEBUG
        ViewerProbe.shared.event("keeper top given=\(given) full=\(full) add=\(wanted)")
        #endif
        root.additionalSafeAreaInsets.top = wanted
    }
}
