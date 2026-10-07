import SwiftUI
import UIKit

/// Whether the viewer's bars show, and when they hide again by themselves. The viewer keeps it as a
/// plain reference; only `ViewerChrome` observes it, so a tap never rebuilds the pages.
@MainActor
final class ViewerChromeModel: ObservableObject {
    /// Like Photos: only the picture at first; a tap shows the bars.
    @Published private(set) var visible = false
    /// The page on screen, set by the viewer when it changes.
    var currentKind: FileKind?
    var currentURL: URL?
    /// An editor or Quick Look covers the viewer.
    var coverUp = false

    private var hideID = UUID()
    /// A menu, dialog or sheet of the bar is open: no auto-hide until the next interaction.
    private var held = false

    func toggle() {
        setVisible(!visible)
        scheduleHide()
    }

    /// Shows the bars and leaves them up (paused playback, audio).
    func show() {
        hideID = UUID()
        setVisible(true)
    }

    func hide() {
        hideID = UUID()
        setVisible(false)
    }

    /// Something on the page was used (a double tap, 2× ended): the countdown starts again.
    func interacted() {
        if visible { scheduleHide() }
    }

    func hold() {
        held = true
        hideID = UUID()
    }

    /// A playing video's bars hide 3 s after the last interaction, but never while a finger is on
    /// the scrubber, 2× runs or a menu is open.
    func scheduleHide() {
        held = false
        let id = UUID()
        hideID = id
        guard visible, currentKind == .video else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.hideID == id, self.visible, !self.held, self.currentKind == .video else { return }
            let playback = MediaPlaybackController.shared
            guard playback.isPlaying, !playback.isScrubbing, !playback.isBoosted else { return }
            self.setVisible(false)
        }
    }

    private func setVisible(_ value: Bool) {
        guard visible != value else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            visible = value
        }
    }
}

/// The viewer's one set of controls: the top bar, the transport buttons, the scrubber and the
/// messages. Always in place (so an open menu survives the bars fading), and only touchable while
/// shown.
struct ViewerChrome: View {
    let items: [FileItem]
    let selection: Int
    @ObservedObject var model: ViewerChromeModel
    /// Read, not observed: `ViewerChromeFade` follows the drag.
    let transition: ViewerTransition
    let onClose: () -> Void
    let onEditImage: (FileItem) -> Void
    let onTrimVideo: (FileItem) -> Void
    let onDelete: (FileItem) -> Void

    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var viewer: ViewerCoordinator
    @ObservedObject private var hub = MediaViewerHub.shared
    @ObservedObject private var playback = MediaPlaybackController.shared
    @ObservedObject private var imagePiP = MediaImagePiPController.shared
    @AppStorage(MediaPlaybackMode.storageKey) private var mode: MediaPlaybackMode = MediaPlaybackMode.defaultMode
    @AppStorage(ViewerSkipStep.storageKey) private var storedStep = ViewerSkipStep.defaultSeconds
    @State private var pendingDelete: FileItem?
    /// Bumped when the 横屏 button turns the screen, so the button follows.
    @State private var orientationRevision = 0

    private var currentItem: FileItem? {
        items.indices.contains(selection) ? items[selection] : nil
    }

    private var step: Int { ViewerSkipStep.seconds(storedStep) }

    var body: some View {
        ZStack {
            ViewerChromeFade(transition: transition, visible: model.visible) {
                controls
            }
            boostPill
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeInOut(duration: 0.2), value: hub.toast)
        .animation(.easeInOut(duration: 0.2), value: playback.isBoosted)
        .statusBarHidden(!model.visible)
        .persistentSystemOverlays(model.visible ? .automatic : .hidden)
        .sensoryFeedback(.selection, trigger: mode)
        .onChange(of: mode) { _, newMode in
            hub.show("播放方式：\(newMode.title)")
            model.scheduleHide()
        }
        .onChange(of: playback.speed) { _, _ in
            model.scheduleHide()
        }
        .onChange(of: playback.isPlaying) { _, playing in
            if playing {
                model.interacted()
            } else {
                showIfPausedByItself()
            }
        }
        .onChange(of: playback.presentationSize) { _, size in
            followVideoShape(size)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // A phone call or Siri paused it while the app was inactive.
            showIfPausedByItself()
        }
    }

    // MARK: - Layout

    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomControls
            }
            if let item = currentItem, item.kind == .video, !isFailed(item), !playback.isScrubbing {
                centreButtons
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        if let item = currentItem, item.kind == .video || item.kind == .audio, !isFailed(item) {
            VStack(spacing: 14) {
                if item.kind == .video, showsLandscapeButton(for: item) {
                    landscapeButton
                }
                if item.kind == .audio {
                    audioButtons
                }
                MediaVideoControls(
                    isVisible: model.visible,
                    onInteraction: { model.scheduleHide() },
                    onHoldChrome: { model.hold() }
                )
            }
            .padding(.bottom, 8)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) { barIcon("xmark") }
                .accessibilityLabel("关闭")
            titleCapsule
                .frame(maxWidth: .infinity)
            if let item = currentItem {
                actions(for: item)
            }
            deleteButton
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
        .simultaneousGesture(TapGesture().onEnded { model.hold() })
        switch item.kind {
        case .image:
            Button {
                model.hold()
                onEditImage(item)
            } label: { barIcon("crop.rotate") }
                .accessibilityLabel("编辑")
            Button {
                imagePiP.toggle()
                model.scheduleHide()
            } label: {
                barIcon(imagePiP.isActive ? "pip.exit" : "pip.enter")
            }
            .accessibilityLabel("小窗")
        case .video:
            Button {
                model.hold()
                onTrimVideo(item)
            } label: { barIcon("scissors") }
                .accessibilityLabel("编辑")
            modeMenu
            Button {
                playback.togglePictureInPicture()
                model.scheduleHide()
            } label: {
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
        // Opening the menu keeps the bars up; picking a mode starts the countdown again.
        .simultaneousGesture(TapGesture().onEnded { model.hold() })
    }

    /// The file goes to the trash after a question asked right at the button, as in the folder list.
    private var deleteButton: some View {
        Button {
            guard let item = currentItem else { return }
            model.hold()
            pendingDelete = item
        } label: { barIcon("trash") }
            .accessibilityLabel("删除")
            .confirmationDialog(
                pendingDelete.map { "删除「\($0.name)」？" } ?? "",
                isPresented: deleteBinding,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { target in
                Button("删除", role: .destructive) { onDelete(target) }
                Button("取消", role: .cancel) {}
            } message: { _ in
                Text("会移到回收站，\(Vault.trashDays) 天内可以恢复。")
            }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { open in
                if !open {
                    pendingDelete = nil
                    model.scheduleHide()
                }
            }
        )
    }

    /// Big play / pause between skip back and skip forward, in the middle of a video. Only the
    /// buttons take touches; a tap anywhere else still hides the bars.
    private var centreButtons: some View {
        HStack(spacing: 36) {
            roundButton("gobackward.\(step)", size: 44, label: "后退 \(step) 秒") { skip(-step) }
            playPauseButton
            roundButton("goforward.\(step)", size: 44, label: "前进 \(step) 秒") { skip(step) }
        }
    }

    /// An audio file's transport, above the scrubber.
    private var audioButtons: some View {
        HStack(spacing: 16) {
            roundButton("backward.end.fill", size: 44, label: "上一个") {
                playback.skipTrack(-1)
                model.scheduleHide()
            }
            roundButton("gobackward.\(step)", size: 44, label: "后退 \(step) 秒") { skip(-step) }
            playPauseButton
            roundButton("goforward.\(step)", size: 44, label: "前进 \(step) 秒") { skip(step) }
            roundButton("forward.end.fill", size: 44, label: "下一个") {
                playback.skipTrack(1)
                model.scheduleHide()
            }
        }
    }

    private var playPauseButton: some View {
        roundButton(playback.isPlaying ? "pause.fill" : "play.fill", size: 64, label: playback.isPlaying ? "暂停" : "播放") {
            playback.togglePlayPause()
            model.scheduleHide()
        }
    }

    private func skip(_ seconds: Int) {
        _ = playback.seek(by: Double(seconds))
        model.scheduleHide()
    }

    // MARK: - Landscape

    private func showsLandscapeButton(for item: FileItem) -> Bool {
        let size = playback.presentationSize
        return playback.currentURL == item.url && size.width > size.height
    }

    private var landscapeButton: some View {
        let forced = ViewerOrientation.isForcedLandscape
        return HStack {
            Spacer(minLength: 0)
            Button {
                if ViewerOrientation.isForcedLandscape {
                    ViewerOrientation.restorePortrait()
                } else {
                    ViewerOrientation.forceLandscape()
                }
                orientationRevision += 1
                model.scheduleHide()
            } label: {
                barIcon(forced ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel(forced ? "竖屏" : "横屏")
            .id(orientationRevision)
        }
        .padding(.horizontal, 12)
    }

    /// Turned sideways for a landscape video, the next video turns out upright: back to portrait.
    private func followVideoShape(_ size: CGSize) {
        guard ViewerOrientation.isForcedLandscape, size.width > 0, size.height > 0, size.width <= size.height,
              let item = currentItem, playback.currentURL == item.url
        else { return }
        ViewerOrientation.restorePortrait()
        orientationRevision += 1
    }

    // MARK: - Playback stopping by itself

    /// The end of a file, a phone call or headphones coming out paused the video while the bars were
    /// hidden: show them, so the picture isn't left frozen without a play button.
    private func showIfPausedByItself() {
        guard !model.visible, let item = currentItem, item.kind == .video || item.kind == .audio,
              playback.currentURL == item.url, !playback.isPlaying
        else { return }
        let url = item.url
        let chrome = model
        let coordinator = viewer
        let viewerTransition = transition
        Task { @MainActor in
            // Ignores a pause that only lasts while the next file loads.
            try? await Task.sleep(nanoseconds: 300_000_000)
            let player = MediaPlaybackController.shared
            guard UIApplication.shared.applicationState == .active,
                  coordinator.request != nil, MediaViewerHub.shared.isViewerPresented,
                  !viewerTransition.isExiting, !chrome.coverUp, !chrome.visible,
                  chrome.currentURL == url, player.currentURL == url,
                  !player.isPlaying, !player.isScrubbing, !player.isPictureInPictureEngaged
            else { return }
            chrome.show()
        }
    }

    private func isFailed(_ item: FileItem) -> Bool {
        playback.failedURLs.contains(item.url)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var boostPill: some View {
        if playback.isBoosted, currentItem?.kind == .video {
            let rate = Double(playback.player.rate)
            Text(String(format: "%g× 快进中", rate > 1.01 ? rate : 2))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .mediaBarGlass(Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 56)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .mediaBarGlass(Circle())
            .contentShape(Circle())
    }

    private func roundButton(_ symbol: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .mediaBarGlass(Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(label)
    }
}

/// Fades the bars with the drag that closes the viewer, without rebuilding them on every touch.
struct ViewerChromeFade<Content: View>: View {
    @ObservedObject var transition: ViewerTransition
    let visible: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shown = visible && !transition.isExiting
        content
            .opacity(shown ? 1 - min(1, transition.dragProgress * 3) : 0)
            .allowsHitTesting(shown && !transition.isDragging)
            .accessibilityHidden(!visible)
            .animation(.easeOut(duration: 0.15), value: transition.isExiting)
    }
}

/// Moves the viewer when something else picks the file: the player going on to the next one
/// (playback mode, lock screen) or Picture in Picture skipping and returning. Observes the
/// engines so the viewer itself doesn't.
struct ViewerFollower: View {
    @Binding var selection: Int
    let items: [FileItem]
    let urls: [URL]

    @ObservedObject private var hub = MediaViewerHub.shared
    @ObservedObject private var playback = MediaPlaybackController.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: hub.pageRequest) { _, request in
                guard let request, request.urls == urls, items.indices.contains(request.index) else { return }
                selection = request.index
            }
            .onChange(of: playback.currentIndex) { _, index in
                follow(index)
            }
    }

    /// The player moved on to another file of this folder; follow it while a video or audio page
    /// is showing.
    private func follow(_ index: Int?) {
        guard let index, index != selection, items.indices.contains(index), items.indices.contains(selection) else { return }
        let kind = items[selection].kind
        guard kind == .video || kind == .audio, playback.sessionItems.map(\.url) == urls else { return }
        selection = index
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
