import SwiftUI

/// Locked: an empty decoy file manager. Unlocked: the real vault.
struct RootView: View {
    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var viewer: ViewerCoordinator
    @EnvironmentObject private var playback: PlaybackState
    @EnvironmentObject private var tabs: TabCoordinator
    @EnvironmentObject private var nav: FolderUINavigation

    var body: some View {
        // A ZStack, not a Group: modifiers on a Group attach to each branch, so locking would
        // dismiss and re-present the viewer (and break a Picture in Picture that is starting).
        ZStack {
            if lock.isUnlocked {
                // Both tabs stay alive while switching, so the browser keeps its pages; locking
                // removes the whole TabView and with it the private browsing session. The files
                // path outlives the lock, so unlocking lands in the folder that was open.
                TabView(selection: $tabs.selected) {
                    NavigationStack(path: $nav.path) {
                        FolderView(folder: store.rootURL)
                            .navigationDestination(for: Route.self) { route in
                                destination(route)
                            }
                    }
                    .tabItem { Label("文件", systemImage: "folder") }
                    .tag(MainTab.files)

                    NavigationStack {
                        BrowserView()
                    }
                    .tabItem { Label("浏览器", systemImage: "globe") }
                    .tag(MainTab.browser)
                }
            } else {
                DecoyView()
            }
        }
        // Only the banner animates, so list changes that come with a message keep their own
        // animation; it never takes the taps meant for the rows under it.
        .overlay(alignment: .bottom) {
            ZStack {
                if lock.isUnlocked, let banner = store.banner {
                    Text(banner)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 96)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring, value: store.banner)
            .allowsHitTesting(false)
        }
        .fullScreenCover(item: $viewer.request) { request in
            MediaViewer(items: request.items, startIndex: request.startIndex)
                .environmentObject(store)
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(playback)
                .environmentObject(tabs)
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .folder(let url): FolderView(folder: url)
        case .browser: BrowserView()
        case .capture: CaptureView()
        case .transfer: TransferView()
        case .settings: SettingsView()
        case .trash: TrashView()
        }
    }
}

/// What anyone else sees: an ordinary, empty file manager. Typing the passcode into the search
/// field unlocks the vault.
struct DecoyView: View {
    @EnvironmentObject private var lock: LockManager
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    ContentUnavailableView(
                        "这里还没有文件",
                        systemImage: "tray",
                        description: Text("在其他 App 里点「分享」→ FileBox 保存文件")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("FileBox")
            .searchable(text: $query, prompt: "搜索文件名")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: query) { _, newValue in
                if lock.tryUnlock(with: newValue) {
                    query = ""
                }
            }
        }
    }
}
