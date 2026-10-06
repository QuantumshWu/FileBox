import QuickLook
import SwiftUI

/// Full-screen viewer for the images, videos and audio of one folder: swipe between the files,
/// zoom images, play videos and audio with the system controls, and keep either one floating in
/// Picture in Picture after leaving the app.
struct MediaViewer: View {
    let items: [FileItem]
    let startIndex: Int

    @EnvironmentObject private var viewer: ViewerCoordinator
    @EnvironmentObject private var store: FileStore
    @ObservedObject private var hub = MediaViewerHub.shared
    @ObservedObject private var playback = MediaPlaybackController.shared
    @ObservedObject private var imagePiP = MediaImagePiPController.shared
    @AppStorage("mediaPlaybackMode") private var mode: MediaPlaybackMode = MediaPlaybackMode.defaultMode

    @State private var selection: Int
    @State private var chromeVisible = true
    @State private var token = UUID()
    @State private var editingImage: FileItem?
    @State private var trimmingVideo: FileItem?
    @State private var quickLookURL: URL?

    private let urls: [URL]

    init(items: [FileItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        urls = items.map(\.url)
        _selection = State(initialValue: items.indices.contains(startIndex) ? startIndex : 0)
    }

    private var currentItem: FileItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Covered by the pages, but on screen: image PiP takes its picture from here.
            MediaImagePiPLayerHost().ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(items.indices, id: \.self) { index in
                    page(for: items[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: hub.toast)
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .onAppear {
            hub.viewerAppeared(token: token, items: items, coordinator: viewer)
            pageChanged(to: selection)
        }
        .onDisappear {
            hub.viewerDisappeared(token: token)
        }
        .onChange(of: selection) { _, index in
            pageChanged(to: index)
        }
        .onChange(of: hub.pageRequest) { _, request in
            guard let request, request.urls == urls, items.indices.contains(request.index) else { return }
            selection = request.index
        }
        .onChange(of: playback.currentIndex) { _, index in
            followPlayback(to: index)
        }
        .onChange(of: mode) { _, newMode in
            hub.show("播放方式：\(newMode.title)")
        }
        .fullScreenCover(item: $editingImage) { item in
            ImageEditorView(item: item)
                .environmentObject(store)
                .environmentObject(viewer)
        }
        .fullScreenCover(item: $trimmingVideo) { item in
            VideoTrimView(item: item)
                .environmentObject(store)
                .environmentObject(viewer)
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for item: FileItem) -> some View {
        switch item.kind {
        case .image:
            MediaImagePage(item: item, onTap: { toggleChrome() }, onQuickLook: { openInQuickLook($0) })
        case .video, .audio:
            MediaPlayablePage(item: item, onTap: { toggleChrome() }, onQuickLook: { openInQuickLook($0) })
        case .folder, .other:
            ZStack {
                Color.black
                MediaUnsupportedView(message: "无法预览这个文件", url: item.url, onQuickLook: { openInQuickLook($0) })
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleChrome() }
        }
    }

    /// Hands the new page to the engine that plays it.
    private func pageChanged(to index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        switch item.kind {
        case .video, .audio:
            imagePiP.leaveImagePage()
            playback.setAutomaticPictureInPicture(true)
            playback.show(items, at: index, autoplay: true)
        case .image:
            playback.leavePlayablePage()
            playback.setAutomaticPictureInPicture(false)
            imagePiP.show(items, at: index)
        case .folder, .other:
            playback.leavePlayablePage()
            playback.setAutomaticPictureInPicture(false)
            imagePiP.leaveImagePage()
        }
    }

    /// The player moved on to another file of this folder (playback mode, lock screen); follow it
    /// while a video or audio page is showing.
    private func followPlayback(to index: Int?) {
        guard let index, index != selection, items.indices.contains(index),
              let item = currentItem, item.kind == .video || item.kind == .audio,
              playback.sessionItems.map(\.url) == urls
        else { return }
        selection = index
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    private func openInQuickLook(_ url: URL) {
        playback.pause()
        quickLookURL = url
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 2) {
            Button("关闭") { viewer.close() }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 44)
            VStack(spacing: 1) {
                Text(currentItem?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if items.count > 1 {
                    Text("\(selection + 1) / \(items.count)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            if let item = currentItem {
                actions(for: item)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .background {
            LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder
    private func actions(for item: FileItem) -> some View {
        ShareLink(item: item.url) {
            barIcon("square.and.arrow.up")
        }
        .accessibilityLabel("分享")
        switch item.kind {
        case .image:
            Button { editingImage = item } label: { barIcon("crop.rotate") }
                .accessibilityLabel("编辑")
            Button { imagePiP.toggle() } label: {
                barIcon(imagePiP.isActive ? "pip.exit" : "pip.enter")
            }
            .accessibilityLabel("小窗")
        case .video:
            Button {
                playback.pause()
                trimmingVideo = item
            } label: { barIcon("scissors") }
                .accessibilityLabel("编辑")
            modeMenu
            Button { playback.togglePictureInPicture() } label: {
                barIcon(playback.isPictureInPictureActive ? "pip.exit" : "pip.enter")
            }
            .accessibilityLabel("小窗")
        case .audio:
            modeMenu
        case .folder, .other:
            EmptyView()
        }
    }

    private var modeMenu: some View {
        Menu {
            Picker("播放方式", selection: $mode) {
                ForEach(MediaPlaybackMode.allCases) { option in
                    Label(option.title, systemImage: option.symbol)
                        .tag(option)
                }
            }
        } label: {
            barIcon(mode.symbol)
        }
        .accessibilityLabel("播放方式")
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var toast: some View {
        if let message = hub.toast ?? store.banner {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 96)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}
