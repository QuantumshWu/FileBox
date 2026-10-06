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
    @EnvironmentObject private var lock: LockManager
    @ObservedObject private var hub = MediaViewerHub.shared
    @ObservedObject private var playback = MediaPlaybackController.shared
    @ObservedObject private var imagePiP = MediaImagePiPController.shared
    @AppStorage("mediaPlaybackMode") private var mode: MediaPlaybackMode = MediaPlaybackMode.defaultMode

    @State private var selection: Int
    /// Like Photos: only the picture at first; a tap shows the bar (with the player's own controls
    /// on video pages).
    @State private var chromeVisible = false
    /// Hides the bar of a playing video again after a few seconds, along with the player's controls.
    @State private var chromeHideID = UUID()
    @State private var token = UUID()
    @State private var editingImage: FileItem?
    @State private var trimmingVideo: FileItem?
    @State private var quickLookURL: URL?

    private let urls: [URL]

    /// Black between pages while swiping, as in Photos.
    private static let pageGap: CGFloat = 20

    init(items: [FileItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        urls = items.map(\.url)
        let start = items.indices.contains(startIndex) ? startIndex : 0
        _selection = State(initialValue: start)
    }

    private var currentItem: FileItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Covered by the pages, but on screen: image PiP takes its picture from here.
            MediaImagePiPLayerHost().ignoresSafeArea()
            // Keeps that picture out of the gaps between pages.
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(items.indices, id: \.self) { index in
                    page(for: items[index])
                        .padding(.horizontal, Self.pageGap / 2)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Pages one gap wider than the screen: a page still fills it, the gap shows while swiping.
            .padding(.horizontal, -Self.pageGap / 2)
            .ignoresSafeArea()

            if chromeVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if let kind = currentItem?.kind, kind == .video || kind == .audio {
                        MediaVideoControls(onInteraction: { scheduleChromeHide() })
                            .padding(.bottom, 8)
                    }
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
        .onChange(of: selection) { oldIndex, index in
            pageChanged(to: index)
            updateChrome(from: oldIndex, to: index)
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
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(PlaybackState.shared)
        }
        .fullScreenCover(item: $trimmingVideo) { item in
            VideoTrimView(item: item)
                .environmentObject(store)
                .environmentObject(lock)
                .environmentObject(viewer)
                .environmentObject(PlaybackState.shared)
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Pages

    @ViewBuilder
    private func page(for item: FileItem) -> some View {
        switch item.kind {
        case .image:
            MediaImagePage(
                item: item,
                onTap: { toggleChrome() },
                onClose: { viewer.close() },
                onQuickLook: { openInQuickLook($0) }
            )
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

    /// On video and audio pages the same tap also shows or hides the player's own controls, so
    /// the bar follows them, including hiding again a few seconds into playback.
    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        let id = UUID()
        chromeHideID = id
        guard chromeVisible, let kind = currentItem?.kind, kind == .video || kind == .audio else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard chromeHideID == id, chromeVisible, playback.isPlaying,
                  let kind = currentItem?.kind, kind == .video || kind == .audio
            else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible = false
            }
        }
    }

    /// A new video or audio page starts with just the picture; moving between images keeps what
    /// the last tap chose.
    private func updateChrome(from oldIndex: Int, to index: Int) {
        guard items.indices.contains(index) else { return }
        switch items[index].kind {
        case .image:
            if items.indices.contains(oldIndex), items[oldIndex].kind == .image { return }
        case .video, .audio:
            break
        case .folder, .other:
            return
        }
        chromeHideID = UUID()
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible = false
        }
    }

    private func openInQuickLook(_ url: URL) {
        playback.pause()
        quickLookURL = url
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { viewer.close() } label: { barIcon("xmark") }
                .accessibilityLabel("关闭")
            titleCapsule
                .frame(maxWidth: .infinity)
            if let item = currentItem {
                actions(for: item)
            }
        }
        .foregroundStyle(.white)
        .frame(height: 44)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var titleCapsule: some View {
        VStack(spacing: 0) {
            Text(currentItem?.name ?? "")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if items.count > 1 {
                Text("\(selection + 1) / \(items.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .mediaBarGlass(Capsule())
    }

    @ViewBuilder
    private func actions(for item: FileItem) -> some View {
        ShareLink(item: item.url) {
            barIcon("square.and.arrow.up")
        }
        .accessibilityLabel("分享")
        switch item.kind {
        case .image:
            Button {
                // The editor covers the viewer, and with it the layer the floating image comes from.
                if imagePiP.isEngaged { imagePiP.toggle() }
                editingImage = item
            } label: { barIcon("crop.rotate") }
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
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .mediaBarGlass(Circle())
            .contentShape(Circle())
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

private extension View {
    /// Dark glass behind the bar's controls, so white symbols stay readable over bright pictures.
    func mediaBarGlass<S: Shape>(_ shape: S) -> some View {
        background {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(Color.black.opacity(0.3)) }
        }
    }
}
