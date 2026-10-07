import SwiftUI

@main
struct FileBoxApp: App {
    /// Answers the allowed orientations, so the viewer's 横屏 button can hold a video sideways.
    @UIApplicationDelegateAdaptor(ViewerAppDelegate.self) private var appDelegate
    @StateObject private var store = FileStore()
    @StateObject private var lock = LockManager.shared
    @StateObject private var viewer = ViewerCoordinator()
    @StateObject private var tabs = TabCoordinator()
    @StateObject private var nav = FolderUINavigation()
    @StateObject private var browser = BrowserSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(tabs)
                .environmentObject(nav)
                .environmentObject(browser)
                .environmentObject(PlaybackState.shared)
                .onOpenURL { url in
                    Task { await store.importIncoming(url) }
                }
        }
        // Locking is manual (锁定) or a fresh launch; leaving the app only puts up the privacy
        // shield, so coming back finds the same tab, folder and open file.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if PlaybackState.shared.isPictureInPictureActive {
                    // Back in FileBox: the floating window goes back into the viewer.
                    MediaViewerHub.shared.endPictureInPictureForReturn()
                }
                PrivacyShield.shared.hide()
                // No blanket reload: files the extensions left while the app was away are collected
                // here, which reloads the open folders when it brings anything in.
                store.collectIncoming()
            case .inactive:
                // Not behind a Photos prompt of our own, which makes the app inactive too.
                if !PrivacyShield.shared.suppressWhileInactive {
                    PrivacyShield.shared.show()
                }
            case .background:
                PrivacyShield.shared.show()
            @unknown default:
                break
            }
        }
    }
}
