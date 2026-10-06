import SwiftUI

@main
struct FileBoxApp: App {
    @StateObject private var store = FileStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onOpenURL { url in
                    Task { await store.importIncoming(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.collectIncoming()
                store.refresh()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: FileStore

    var body: some View {
        NavigationStack {
            FolderView(folder: store.rootURL)
                .navigationDestination(for: URL.self) { FolderView(folder: $0) }
        }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                Text(banner)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring, value: store.banner)
    }
}
