import UIKit

/// Turns the app sideways for a landscape video even with the iPhone's rotation lock on (the 横屏
/// button), and back upright when the video, the viewer or the app goes away.
@MainActor
enum ViewerOrientation {
    /// What the app allows, answered by `ViewerAppDelegate`.
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    static private(set) var isForcedLandscape = false

    static func forceLandscape() {
        guard let scene = activeScene else { return }
        mask = .landscape
        isForcedLandscape = true
        topController(in: scene)?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
            let message = error.localizedDescription
            Task { @MainActor in MediaDiagnostics.log("横屏失败：\(message)") }
        }
    }

    /// Back to upright; does nothing unless the app was turned sideways by `forceLandscape`.
    static func restorePortrait() {
        guard isForcedLandscape else { return }
        isForcedLandscape = false
        mask = .allButUpsideDown
        guard let scene = activeScene else { return }
        topController(in: scene)?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in
            let message = error.localizedDescription
            Task { @MainActor in MediaDiagnostics.log("恢复竖屏失败：\(message)") }
        }
    }

    private static var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// The controller on top (the viewer's cover), which decides the orientations on screen.
    private static func topController(in scene: UIWindowScene) -> UIViewController? {
        let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            controller = presented
        }
        return controller
    }
}

/// The app delegate FileBoxApp adopts with `@UIApplicationDelegateAdaptor`, so the viewer can lock
/// the orientation to landscape for a video.
@MainActor
final class ViewerAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ViewerOrientation.mask
    }
}
