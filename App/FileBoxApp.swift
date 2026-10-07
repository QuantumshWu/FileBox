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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(tabs)
                .environmentObject(nav)
                .environmentObject(PlaybackState.shared)
                .onOpenURL { url in
                    Task { await store.importIncoming(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if PlaybackState.shared.isPictureInPictureActive {
                    // Back in FileBox: the floating window goes back into the viewer.
                    MediaViewerHub.shared.endPictureInPictureForReturn()
                }
                if !lock.isUnlocked && viewer.request != nil && !PlaybackState.shared.isPictureInPictureActive {
                    // The viewer outlived a Picture in Picture that has since been closed: come
                    // back to the locked screen at once, with no closing animation to see.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { viewer.close() }
                    Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        PrivacyShield.shared.hide()
                    }
                } else {
                    PrivacyShield.shared.hide()
                }
                // No blanket reload: no folder survives the lock that leaving the app sets, and
                // collecting reloads them when it brings anything in.
                store.collectIncoming()
            case .inactive:
                // Not behind a Photos prompt of our own, which makes the app inactive too.
                if !PrivacyShield.shared.suppressWhileInactive {
                    PrivacyShield.shared.show()
                }
            case .background:
                PrivacyShield.shared.show()
                lock.lock()
                tabs.selected = .files
                if !PlaybackState.shared.keepsViewerInBackground {
                    viewer.close()
                }
            @unknown default:
                break
            }
        }
    }
}
