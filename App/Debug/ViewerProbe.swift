#if DEBUG
import AVFoundation
import QuartzCore
import UIKit

/// Debug builds only, and only under the UI test (`UITestSeed`): on every display frame, writes
/// down where the viewer's views are in the window (model and on-screen presentation values), the
/// safe areas and the status bar, and where the folder underneath is (the root controller's safe
/// area, the navigation bar and the list's content), whenever any of it changed since the frame
/// before. The log goes to Library/Caches/viewer-probe.log, which the repro workflow copies out of
/// the simulator.
@MainActor
final class ViewerProbe: NSObject {
    static let shared = ViewerProbe()

    private struct Entry {
        let name: String
        weak var view: UIView?
    }

    private var entries: [Entry] = []
    private var link: CADisplayLink?
    private var lastState = ""
    private var handle: FileHandle?
    private var frameCount = 0
    /// The folder's list and navigation bar, looked up again every few frames.
    private weak var folderList: UIScrollView?
    private weak var folderBar: UINavigationBar?
    private var lookedUp = -100

    static var logURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("viewer-probe.log")
    }

    func start() {
        guard link == nil else { return }
        // Appended to: the test launches the app more than once.
        let url = Self.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        write("start screen=\(UIScreen.main.bounds.size) scale=\(UIScreen.main.scale) model=\(UIDevice.current.model) os=\(UIDevice.current.systemVersion)")
    }

    /// Keeps an eye on `view` for as long as it lives.
    func register(_ view: UIView, as name: String) {
        guard link != nil else { return }
        entries.removeAll { $0.view == nil || $0.view === view }
        entries.append(Entry(name: name, view: view))
    }

    func event(_ text: String) {
        guard link != nil else { return }
        write("EVENT \(text)")
    }

    private func write(_ line: String) {
        let stamp = String(format: "%.4f %.4f", Date().timeIntervalSince1970, CACurrentMediaTime())
        handle?.write(Data("\(stamp) \(line)\n".utf8))
    }

    @objc private func tick(_ link: CADisplayLink) {
        frameCount += 1
        guard let window = keyWindow else { return }
        var parts: [String] = []
        let scene = window.windowScene
        let bar = scene?.statusBarManager
        parts.append("sb=\(bar?.isStatusBarHidden == true ? "hidden" : "shown") sbH=\(f(bar?.statusBarFrame.height ?? -1))")
        parts.append("win=\(r(window.bounds)) winSafe=\(e(window.safeAreaInsets))")
        parts.append(folderState(window))
        if let presented = topPresented(window) {
            let view = presented.view!
            parts.append("presented=\(type(of: presented)) pv=\(r(view.convert(view.bounds, to: window))) pvSafe=\(e(view.safeAreaInsets)) captures=\(presented.modalPresentationCapturesStatusBarAppearance) prefHidden=\(presented.prefersStatusBarHidden)")
        }
        entries.removeAll { $0.view == nil }
        for entry in entries {
            guard let view = entry.view, view.window === window else { continue }
            let model = view.convert(view.bounds, to: window)
            guard model.intersects(window.bounds.insetBy(dx: -2, dy: -2)) else { continue }
            var line = "\(entry.name)@\(short(view)) m=\(r(model))"
            if let shown = presentationFrame(view.layer, in: window) { line += " p=\(r(shown))" }
            line += " safe=\(e(view.safeAreaInsets)) a=\(f(alpha(of: view)))"
            if let controller = view.next as? UIViewController, controller.additionalSafeAreaInsets != .zero {
                line += " add=\(e(controller.additionalSafeAreaInsets))"
            }
            if let scroll = view as? UIScrollView {
                line += " off=\(pt(scroll.contentOffset)) inset=\(e(scroll.adjustedContentInset)) zoom=\(f(scroll.zoomScale))"
                if let image = scroll.subviews.first(where: { $0 is UIImageView }) as? UIImageView {
                    line += " img=\(r(image.convert(image.bounds, to: window)))"
                    if let shown = presentationFrame(image.layer, in: window) { line += " imgP=\(r(shown))" }
                    if let picture = image.image { line += " imgSize=\(sz(picture.size))" }
                }
            }
            if let layer = view.layer as? AVPlayerLayer {
                let rect = layer.videoRect
                if rect.width > 0 {
                    line += " video=\(r(view.convert(rect, to: window))) ready=\(layer.isReadyForDisplay)"
                }
            }
            if entry.name == "edgeHost" {
                if let pager = firstPagingScrollView(in: view) {
                    line += " pager=\(r(pager.convert(pager.bounds, to: window))) pagerOff=\(pt(pager.contentOffset)) pagerInset=\(e(pager.adjustedContentInset)) pagerSafe=\(e(pager.safeAreaInsets))"
                    // The page on screen: its cell and the cell's first view (the page's host).
                    let visible = pager.subviews.filter {
                        !$0.isHidden && $0.frame.width > 50 && $0.convert($0.bounds, to: window).intersects(window.bounds.insetBy(dx: 40, dy: 40))
                    }
                    for (index, cell) in visible.prefix(2).enumerated() {
                        line += " cell\(index)=\(r(cell.convert(cell.bounds, to: window))) cellSafe=\(e(cell.safeAreaInsets))"
                        if let host = cell.subviews.first(where: { $0.frame.width > 50 }) {
                            line += " host\(index)=\(r(host.convert(host.bounds, to: window))) hostSafe=\(e(host.safeAreaInsets))"
                        }
                    }
                }
            }
            parts.append(line)
        }
        let state = parts.joined(separator: " | ")
        if state != lastState {
            lastState = state
            write("F\(frameCount) ts=\(String(format: "%.4f", link.timestamp)) \(state)")
        }
    }

    /// The root controller's safe area (with the additional insets it was given), the folder's
    /// navigation bar, and the list's content origin in the window (laid out c0, drawn c0p): the
    /// list's rows move exactly with it.
    private func folderState(_ window: UIWindow) -> String {
        guard let root = window.rootViewController, root.isViewLoaded else { return "root=-" }
        var text = "root safe=\(e(root.view.safeAreaInsets)) add=\(e(root.additionalSafeAreaInsets))"
        let stale = folderList.map { $0.window !== window || !isShown($0) } ?? true
        if stale || frameCount - lookedUp > 30 {
            lookedUp = frameCount
            var lists: [UIScrollView] = []
            var bars: [UINavigationBar] = []
            collect(root.view, window: window, lists: &lists, bars: &bars)
            let area = window.bounds.width * window.bounds.height
            folderList = lists.last { scroll in
                let frame = scroll.convert(scroll.bounds, to: window)
                return !scroll.isPagingEnabled && frame.width * frame.height > area * 0.4
            }
            folderBar = bars.last
        }
        if let bar = folderBar, bar.window === window {
            text += " nav=\(r(bar.convert(bar.bounds, to: window)))"
            if let shown = presentationFrame(bar.layer, in: window) { text += " navP=\(r(shown))" }
        }
        if let list = folderList, list.window === window {
            let origin = list.convert(CGPoint.zero, to: window)
            text += " list@\(short(list)) lm=\(r(list.convert(list.bounds, to: window))) loff=\(pt(list.contentOffset)) linset=\(e(list.adjustedContentInset)) c0=\(f(origin.y))"
            if let shown = list.layer.presentation(), let windowLayer = window.layer.presentation() {
                text += " c0p=\(f(shown.convert(CGPoint.zero, to: windowLayer).y))"
            }
        }
        return text
    }

    private func collect(_ view: UIView, window: UIWindow, lists: inout [UIScrollView], bars: inout [UINavigationBar]) {
        if view.isHidden || view.alpha < 0.01 { return }
        if let bar = view as? UINavigationBar {
            bars.append(bar)
            return
        }
        if let scroll = view as? UIScrollView, scroll.window === window { lists.append(scroll) }
        for sub in view.subviews { collect(sub, window: window, lists: &lists, bars: &bars) }
    }

    private func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return false }
            current = v.superview
        }
        return true
    }

    // MARK: - Helpers

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }

    private func topPresented(_ window: UIWindow) -> UIViewController? {
        var controller = window.rootViewController?.presentedViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }

    private func presentationFrame(_ layer: CALayer, in window: UIWindow) -> CGRect? {
        guard let shown = layer.presentation(), let windowLayer = window.layer.presentation() else { return nil }
        return shown.convert(shown.bounds, to: windowLayer)
    }

    private func alpha(of view: UIView) -> CGFloat {
        var value: CGFloat = 1
        var current: UIView? = view
        while let v = current {
            value *= CGFloat(v.layer.presentation()?.opacity ?? v.layer.opacity)
            if v.isHidden { return 0 }
            current = v.superview
        }
        return value
    }

    private func firstPagingScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView, scroll.isPagingEnabled { return scroll }
            if let found = firstPagingScrollView(in: sub) { return found }
        }
        return nil
    }

    private func short(_ view: UIView) -> String {
        String(UInt(bitPattern: ObjectIdentifier(view).hashValue) & 0xFFFF, radix: 16)
    }

    private func f(_ value: CGFloat) -> String { String(format: "%.2f", value) }
    private func pt(_ p: CGPoint) -> String { "(\(f(p.x)),\(f(p.y)))" }
    private func sz(_ s: CGSize) -> String { "\(f(s.width))x\(f(s.height))" }
    private func r(_ rect: CGRect) -> String { "[\(f(rect.minX)),\(f(rect.minY)),\(f(rect.width)),\(f(rect.height))]" }
    private func e(_ i: UIEdgeInsets) -> String { "{\(f(i.top)),\(f(i.left)),\(f(i.bottom)),\(f(i.right))}" }
}
#endif
