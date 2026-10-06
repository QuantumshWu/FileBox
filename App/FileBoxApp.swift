import SwiftUI

@main
struct FileBoxApp: App {
    @StateObject private var store = FileStore()
    @StateObject private var lock = LockManager.shared
    @StateObject private var viewer = ViewerCoordinator()
    @StateObject private var tabs = TabCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(tabs)
                .environmentObject(PlaybackState.shared)
                .onOpenURL { url in
                    Task { await store.importIncoming(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
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
                store.collectIncoming()
                store.refresh()
            case .inactive:
                PrivacyShield.shared.show()
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
