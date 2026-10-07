import QuickLook
import SwiftUI

/// Full-screen viewer for the images, videos and audio of one folder: swipe between the files,
/// zoom images, play videos and audio with the viewer's own controls, and keep either one floating
/// in Picture in Picture after leaving the app. It fades in over the folder, and a page swiped up
/// or down carries on in that direction while the folder shows through.
struct MediaViewer: View {
    let items: [FileItem]
    let startIndex: Int

    @EnvironmentObject private var viewer: ViewerCoordinator
    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager

    @State private var selection: Int
    // Plain references, observed only by the small views that draw them, so that taps, drags and
    // playback never rebuild the pages.
    @State private var transition: ViewerTransition
    @State private var chrome: ViewerChromeModel
    @State private var paging: PagingState
    @State private var token = UUID()
    @State private var editingImage: FileItem?
    @State private var trimmingVideo: FileItem?
    @State private var quickLookURL: URL?

    private let urls: [URL]
    /// Each file's page. Pages are identified by file, so after a delete each keeps its own state.
    private let tags: [URL: Int]

    /// Black between pages while swiping, as in Photos.
    private static let pageGap: CGFloat = 20

    init(items: [FileItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        let urls = items.map(\.url)
        self.urls = urls
        var tags: [URL: Int] = [:]
        tags.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() { tags[url] = index }
        self.tags = tags
        let start = items.indices.contains(startIndex) ? startIndex : 0
        _selection = State(initialValue: start)
        _transition = State(initialValue: ViewerTransition())
        _chrome = State(initialValue: ViewerChromeModel())
        _paging = State(initialValue: PagingState(settled: start))
    }

    private var currentItem: FileItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    private var hub: MediaViewerHub { .shared }
    private var playback: MediaPlaybackController { .shared }
    private var imagePiP: MediaImagePiPController { .shared }

    private var coverIsUp: Bool {
        editingImage != nil || trimmingVideo != nil || quickLookURL != nil
    }

    var body: some View {
        ZStack {
            ViewerBackdrop(transition: transition)
            ViewerPagerFrame(transition: transition) {
                ViewerEdgeToEdge(content: pager)
            }
            // Edge to edge, whatever the bars and the notch take; only the bars keep clear. Outside
            // the opening and closing scale, never inside it (see ViewerPagerFrame).
            .ignoresSafeArea()
            ViewerChrome(
                items: items,
                selection: selection,
                model: chrome,
                transition: transition,
                onClose: { fadeExit() },
                onEditImage: { editImage($0) },
                onTrimVideo: { trimVideo($0) },
                onDelete: { delete($0) }
            )
            ViewerFollower(selection: $selection, items: items, urls: urls)
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.size.width) { oldWidth, newWidth in
                        if oldWidth > 0, abs(oldWidth - newWidth) > 1 { rotationStarted() }
                    }
            }
            .ignoresSafeArea()
        }
        .background(ViewerPresentationProbe().frame(width: 0, height: 0))
        .environment(\.colorScheme, .dark)
        // Light status bar and dark menus over the black viewer, also in light mode.
        .preferredColorScheme(.dark)
        // The folder stays underneath and shows through while a page is dragged away.
        .presentationBackground(Color.clear)
        .onAppear { appeared() }
        .onDisappear {
            #if DEBUG
            ViewerProbe.shared.event("viewer disappeared")
            #endif
            MediaDiagnostics.log("关闭查看页面")
            hub.viewerDisappeared(token: token)
        }
        .onChange(of: selection) { oldIndex, index in
            selectionChanged(from: oldIndex, to: index)
        }
        .onChange(of: urls) { _, _ in
            itemsChanged()
        }
        .onChange(of: coverIsUp) { _, up in
            chrome.coverUp = up
            if !up { chrome.interacted() }
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

    /// Hosted by `ViewerEdgeToEdge`, outside this view's environment, so the dark appearance is
    /// set again here.
    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                page(for: item)
                    // There is no safe area in there; should one ever get through, it is ignored.
                    .ignoresSafeArea()
                    .padding(.horizontal, Self.pageGap / 2)
                    .tag(tags[item.url] ?? 0)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Pages one gap wider than the screen: a page still fills it, the gap shows while swiping.
        .padding(.horizontal, -Self.pageGap / 2)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func page(for item: FileItem) -> some View {
        let bars = chrome
        switch item.kind {
        case .image:
            MediaImagePage(
                item: item,
                transition: transition,
                onTap: { bars.toggle() },
                onDismiss: { flingExit() },
                onQuickLook: { openInQuickLook($0) }
            )
        case .video, .audio:
            MediaPlayablePage(
                item: item,
                transition: transition,
                onTap: { bars.toggle() },
                onInteraction: { bars.interacted() },
                onDismiss: { flingExit() },
                onQuickLook: { openInQuickLook($0) }
            )
        case .folder, .other:
            ViewerUnsupportedPage(
                item: item,
                transition: transition,
                onTap: { bars.toggle() },
                onDismiss: { flingExit() },
                onQuickLook: { openInQuickLook($0) }
            )
        }
    }

    private func appeared() {
        #if DEBUG
        ViewerProbe.shared.event("viewer appeared")
        #endif
        MediaDiagnostics.log("打开查看页面")
        let request = viewer.request
        hub.viewerAppeared(token: token, requestID: request?.id, items: items, coordinator: viewer)
        // Once: closing an editor or Quick Look over the viewer makes it appear again.
        if !paging.appeared {
            paging.appeared = true
            transition.appear(animated: request?.animated ?? true)
        }
        pageChanged(to: selection, from: nil)
        if currentItem?.kind == .audio { chrome.show() }
    }

    private func selectionChanged(from oldIndex: Int, to index: Int) {
        #if DEBUG
        ViewerProbe.shared.event("selection \(oldIndex) -> \(index)")
        #endif
        if Date() < paging.rotationUntil {
            // Turning the phone can make the pager jump; stay on the page that was showing.
            if index != paging.settled {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = paging.settled }
            }
            return
        }
        pageChanged(to: index, from: oldIndex)
        // After a delete, `itemsChanged` decides about the bars.
        guard paging.deletedKind == nil else { return }
        arrive(at: index, fromKind: items.indices.contains(oldIndex) ? items[oldIndex].kind : nil)
    }

    /// Hands the new page to the engine that plays it, and gets the neighbours ready.
    private func pageChanged(to index: Int, from oldIndex: Int?) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        paging.settled = index
        if playback.isBoosted { playback.endBoost() }
        switch item.kind {
        case .video, .audio:
            // Only a video floats when the app leaves the screen; audio just plays on.
            playback.setAutomaticPictureInPicture(item.kind == .video)
            playback.show(items, at: index, autoplay: true)
            // After the player took the audio session, so it never goes off in between.
            imagePiP.leaveImagePage()
        case .image:
            playback.leavePlayablePage()
            playback.setAutomaticPictureInPicture(false)
            imagePiP.show(items, at: index)
        case .folder, .other:
            playback.leavePlayablePage()
            playback.setAutomaticPictureInPicture(false)
            imagePiP.leaveImagePage()
        }
        // A video's own shape decides once it is known (see ViewerChrome).
        if item.kind != .video { ViewerOrientation.restorePortrait() }
        chrome.currentKind = item.kind
        chrome.currentURL = item.url
        prefetchImages(around: index, from: oldIndex)
        warmPlayers(around: index)
        // The folder list scrolls to this file, so closing lands on it.
        NotificationCenter.default.post(
            name: Notification.Name("FileBoxViewerPageChanged"),
            object: nil,
            userInfo: ["url": item.url]
        )
    }

    /// Decodes the images next to the page, the way the user is swiping first.
    private func prefetchImages(around index: Int, from oldIndex: Int?) {
        let forward = oldIndex.map { index >= $0 } ?? true
        let order = forward ? [index + 1, index - 1, index + 2] : [index - 1, index + 1, index - 2]
        let images = order.compactMap { i -> FileItem? in
            items.indices.contains(i) && items[i].kind == .image ? items[i] : nil
        }
        MediaImageLoader.prefetch(images, maxPixel: MediaImageLoader.displayMaxPixel)
    }

    /// Opens the videos and audio next to the page ahead of time, so they start quickly.
    private func warmPlayers(around index: Int) {
        let playable = [index - 1, index + 1].compactMap { i -> FileItem? in
            guard items.indices.contains(i) else { return nil }
            let kind = items[i].kind
            return kind == .video || kind == .audio ? items[i] : nil
        }
        if !playable.isEmpty { PlayerAssetCache.warm(playable) }
    }

    /// A new video page starts with just the picture; moving between images keeps what the last
    /// tap chose; audio shows its controls.
    private func arrive(at index: Int, fromKind: FileKind?) {
        guard items.indices.contains(index) else { return }
        switch items[index].kind {
        case .image:
            if fromKind == .image { return }
            chrome.hide()
        case .video:
            chrome.hide()
        case .audio:
            chrome.show()
        case .folder, .other:
            return
        }
    }

    private func rotationStarted() {
        paging.rotationUntil = Date().addingTimeInterval(0.5)
    }

    // MARK: - Closing

    /// A page was swiped away: it flies off by itself while the backdrop fades.
    private func flingExit() {
        exitViewer(duration: 0.22, fadeContent: false)
    }

    /// The close button (or deleting the last file): everything fades out together.
    private func fadeExit() {
        exitViewer(duration: 0.2, fadeContent: true)
    }

    private func exitViewer(duration: Double, fadeContent: Bool) {
        guard !transition.isExiting else { return }
        #if DEBUG
        ViewerProbe.shared.event("exit fade=\(fadeContent)")
        #endif
        // First, so the pause below doesn't bring the bars back.
        transition.isExiting = true
        if !playback.isPictureInPictureEngaged { playback.pause() }
        let coordinator = viewer
        let requestID = coordinator.request?.id
        transition.exit(duration: duration, fadeContent: fadeContent) {
            // Nothing is left on screen; playback stops as the request goes.
            guard requestID != nil, coordinator.request?.id == requestID else { return }
            coordinator.closeImmediately()
        }
    }

    // MARK: - Actions

    private func editImage(_ item: FileItem) {
        // The editor covers the viewer, and with it the layer the floating image comes from.
        if imagePiP.isEngaged { imagePiP.toggle() }
        ViewerOrientation.restorePortrait()
        chrome.coverUp = true
        editingImage = item
    }

    private func trimVideo(_ item: FileItem) {
        // Like the image editor: a floating video goes back first, so closing that window can never
        // take the editor away with the viewer.
        playback.endPictureInPictureForViewer()
        playback.pause()
        ViewerOrientation.restorePortrait()
        chrome.coverUp = true
        trimmingVideo = item
    }

    private func openInQuickLook(_ url: URL) {
        chrome.coverUp = true
        playback.pause()
        quickLookURL = url
    }

    /// Moves the file to the trash and shows the next one (the one before, if it was the last).
    private func delete(_ item: FileItem) {
        if playback.currentURL == item.url { playback.stop() }
        if item.kind == .image, imagePiP.isEngaged { imagePiP.leaveImagePage() }
        store.delete([item])
        guard items.count > 1, let index = items.firstIndex(where: { $0.url == item.url }) else {
            fadeExit()
            return
        }
        paging.deletedKind = item.kind
        if index == items.count - 1, selection == index {
            selection = index - 1
        }
        viewer.remove(item.url)
    }

    /// The request now has a file fewer (see `delete`): the viewer stays, with the pages it has.
    private func itemsChanged() {
        guard !items.isEmpty else { return }
        if !items.indices.contains(selection) { selection = items.count - 1 }
        let deletedKind = paging.deletedKind
        paging.deletedKind = nil
        hub.viewerAppeared(token: token, requestID: viewer.request?.id, items: items, coordinator: viewer)
        pageChanged(to: selection, from: nil)
        arrive(at: selection, fromKind: deletedKind)
    }

    /// Bookkeeping that must not re-render the viewer.
    private final class PagingState {
        /// The page last handed to the engines.
        var settled: Int
        /// Until then the pager may jump because the phone turned; such jumps are undone.
        var rotationUntil = Date.distantPast
        /// Set between deleting a file and the viewer getting its new list.
        var deletedKind: FileKind?
        var appeared = false

        init(settled: Int) {
            self.settled = settled
        }
    }
}
