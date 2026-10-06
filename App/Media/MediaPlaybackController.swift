import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

/// What happens when a video or audio file ends. Stored in UserDefaults under `storageKey`.
enum MediaPlaybackMode: String, CaseIterable, Identifiable {
    case repeatOne, sequential, loopAll, stopAfter

    static let storageKey = "mediaPlaybackMode"
    static let defaultMode = MediaPlaybackMode.sequential

    static var current: MediaPlaybackMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MediaPlaybackMode.init(rawValue:)) ?? defaultMode
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .repeatOne: return "单个循环"
        case .sequential: return "顺序播放"
        case .loopAll: return "列表循环"
        case .stopAfter: return "播完停止"
        }
    }

    var symbol: String {
        switch self {
        case .repeatOne: return "repeat.1"
        case .sequential: return "arrow.right.to.line"
        case .loopAll: return "repeat"
        case .stopAfter: return "stop.circle"
        }
    }
}

/// Owns the app's one AVPlayer and its video surface, so Picture in Picture and background
/// playback survive SwiftUI rebuilding (or closing) the viewer. Plays through the files of one folder
/// according to `MediaPlaybackMode`, also while in PiP or in the background.
@MainActor
final class MediaPlaybackController: NSObject, ObservableObject {
    static let shared = MediaPlaybackController()

    let player = AVPlayer()
    /// The video surface the viewer's pages borrow. A plain AVPlayerLayer with our own controls:
    /// AVPlayerViewController's Picture in Picture stops working once its controls are turned off.
    let playerViewController = MediaPlayerSurfaceController()
    /// Made once the picture is on screen (see `preparePictureInPicture`).
    private var pictureInPicture: AVPictureInPictureController?
    /// Whether the page on screen wants PiP to start by itself when the app leaves the screen.
    private var wantsAutomaticPictureInPicture = true
    /// A new file was loaded: the next time the picture is on screen it gets a fresh PiP controller,
    /// so nothing left over from an earlier PiP session can keep it from starting.
    private var pictureInPictureNeedsRefresh = false
    private var possibleObservation: NSKeyValueObservation?
    /// When the app resigned: a video played and PiP was set to start by itself.
    private var pictureInPictureExpected = false
    /// Paging to an image paused a playing video; coming back to it plays on.
    private var resumeOnReturn = false

    /// Index (in `sessionItems`) of the file in the player.
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isPictureInPictureActive = false
    /// The file in the player.
    @Published private(set) var currentURL: URL?
    /// Files AVFoundation could not open.
    @Published private(set) var failedURLs: Set<URL> = []

    /// The folder being played through: the items of the viewer that started playback.
    private(set) var sessionItems: [FileItem] = []

    /// PiP is showing the video or about to.
    var isPictureInPictureEngaged: Bool { isPictureInPictureActive || isPictureInPictureStarting }

    private var isPictureInPictureStarting = false
    private var automaticAdvance = false
    private var failuresInARow = 0
    private var wasPlayingWhenResigning = false
    /// Set when the app leaves the screen mid-playback, so the viewer survives iOS pausing the video.
    private var holdsForBackground = false
    private var wasPlayingBeforeInterruption = false
    private var detachedForBackground = false
    private var pendingRestore: ((Bool) -> Void)?
    /// PiP asked to go back to the viewer, so its stop is not the user closing it with the X.
    private var isRestoringFromPictureInPicture = false
    private var restoreID = UUID()
    private var remoteCommandsReady = false
    private var artwork: UIImage?
    private let audioOverlay = MediaAudioOverlayView()
    private var observers: Set<AnyCancellable> = []
    private var itemObservers: Set<AnyCancellable> = []

    private override init() {
        super.init()
        player.actionAtItemEnd = .none
        playerViewController.loadViewIfNeeded()
        playerViewController.player = player
        audioOverlay.frame = playerViewController.view.bounds
        audioOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        audioOverlay.isHidden = true
        playerViewController.view.addSubview(audioOverlay)
        observeAppAndPlayer()
    }

    // MARK: - Viewer

    /// The viewer moved to `items[index]`, a video or audio file.
    func show(_ items: [FileItem], at index: Int, autoplay: Bool) {
        guard items.indices.contains(index) else { return }
        sessionItems = items
        if currentURL == items[index].url {
            // Already in the player, e.g. the viewer reopened from PiP or paged back to it.
            if currentIndex != index { currentIndex = index }
            if autoplay && resumeOnReturn && !isPictureInPictureEngaged { play() }
            resumeOnReturn = false
            return
        }
        failuresInARow = 0
        automaticAdvance = false
        load(index, autoplay: autoplay && !failedURLs.contains(items[index].url))
    }

    /// The viewer moved away from the playing file (to an image). PiP keeps playing.
    func leavePlayablePage() {
        guard !isPictureInPictureActive, !isPictureInPictureStarting else { return }
        resumeOnReturn = player.timeControlStatus != .paused
        player.pause()
    }

    /// The viewer closed: stop, unless the video is floating in PiP.
    func viewerClosed() {
        guard !isPictureInPictureActive, !isPictureInPictureStarting else { return }
        stop()
    }

    func setAutomaticPictureInPicture(_ enabled: Bool) {
        wantsAutomaticPictureInPicture = enabled
        pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    /// Creates the PiP controller the first time the video layer is in a window. One created before
    /// that (at launch) never becomes "possible", so swiping home only kept the sound playing.
    private func preparePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              playerViewController.viewIfLoaded?.window != nil,
              !isPictureInPictureActive, !isPictureInPictureStarting,
              pictureInPicture == nil || pictureInPictureNeedsRefresh
        else { return }
        // Never two controllers on one layer: the old one goes before the new one is made.
        releasePictureInPictureController()
        guard let controller = AVPictureInPictureController(playerLayer: playerViewController.playerLayer) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = wantsAutomaticPictureInPicture
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in MediaDiagnostics.log(possible ? "小窗可以开启" : "小窗暂不可用") }
        }
        pictureInPicture = controller
        pictureInPictureNeedsRefresh = false
        MediaDiagnostics.log("准备好视频小窗")
    }

    /// Forgets the PiP controller (not while it floats or starts); the next time the picture is on
    /// screen a fresh one is made. A long-lived one stops being eligible after its layer has left
    /// the window and the audio session was switched off and on again.
    private func releasePictureInPictureController() {
        guard !isPictureInPictureActive, !isPictureInPictureStarting else { return }
        pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPicture?.delegate = nil
        pictureInPicture = nil
        possibleObservation = nil
        pictureInPictureNeedsRefresh = true
    }

    /// The video surface moved to another page host (a new viewer).
    func surfaceMoved() {
        guard !isPictureInPictureActive, !isPictureInPictureStarting else { return }
        pictureInPictureNeedsRefresh = true
    }

    func play() {
        guard player.currentItem != nil else { return }
        MediaViewerHub.shared.activateAudioSession(for: .video)
        player.play()
    }

    func pause() {
        resumeOnReturn = false
        player.pause()
    }

    /// FileBox is back on screen while the video floats: it goes back into the viewer and keeps
    /// playing there, so there is never a floating window and a full one at the same time.
    func endPictureInPictureForReturn() {
        // A restore the user tapped is already bringing it back.
        guard !isRestoringFromPictureInPicture, pendingRestore == nil,
              let controller = pictureInPicture, controller.isPictureInPictureActive
        else { return }
        MediaDiagnostics.log("回到 App，收起视频小窗")
        isRestoringFromPictureInPicture = true
        controller.stopPictureInPicture()
    }

    /// The manual PiP button.
    func togglePictureInPicture() {
        guard player.currentItem != nil else { return }
        guard let controller = pictureInPicture else {
            MediaViewerHub.shared.show("这台设备不支持小窗")
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        } else {
            MediaViewerHub.shared.show("小窗暂时无法开启")
        }
    }

    /// Stops playback and forgets the folder.
    func stop() {
        resumeOnReturn = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        releasePictureInPictureController()
        itemObservers.removeAll()
        sessionItems = []
        currentURL = nil
        currentIndex = nil
        artwork = nil
        failedURLs = []
        automaticAdvance = false
        holdsForBackground = false
        finishRestore(false)
        if detachedForBackground {
            playerViewController.player = player
            detachedForBackground = false
        }
        setRemoteCommandsEnabled(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if isPlaying { isPlaying = false }
        publishState()
        MediaViewerHub.shared.releaseAudioSession(for: .video)
    }

    // MARK: - Loading and advancing

    private func load(_ index: Int, autoplay: Bool) {
        let file = sessionItems[index]
        if !MediaViewerHub.shared.activateAudioSession(for: .video) {
            MediaViewerHub.shared.show("声音暂时无法播放")
        }
        let item = AVPlayerItem(url: file.url)
        observe(item)
        pictureInPictureNeedsRefresh = true
        currentURL = file.url
        artwork = nil
        audioOverlay.configure(title: file.name, artwork: nil)
        audioOverlay.isHidden = file.kind != .audio
        player.replaceCurrentItem(with: item)
        currentIndex = index
        configureRemoteCommands()
        updateNowPlaying()
        if autoplay { player.play() }
        if file.kind == .audio { loadArtwork(of: item, url: file.url) }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservers.removeAll()
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.itemDidEnd() }
            .store(in: &itemObservers)
        NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNowPlaying() }
            .store(in: &itemObservers)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.player.currentItem else { return }
                self.itemStatusChanged(status)
            }
            .store(in: &itemObservers)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            failuresInARow = 0
            updateNowPlaying()
        case .failed:
            if let url = currentURL { failedURLs.insert(url) }
            // A failed item can leave the player "waiting" forever, which would count as playing.
            if !(automaticAdvance && skipFailedItem()) {
                player.pause()
                playbackStatusChanged()
            }
        default:
            break
        }
    }

    /// Called when the file in the player ends; continues per the playback mode.
    private func itemDidEnd() {
        switch MediaPlaybackMode.current {
        case .repeatOne:
            restartCurrent()
        case .sequential:
            if !advance(by: 1, wrap: false, automatic: true) { finish() }
        case .loopAll:
            if !advance(by: 1, wrap: true, automatic: true) { restartCurrent() }
        case .stopAfter:
            finish()
        }
    }

    private func restartCurrent() {
        player.seek(to: .zero)
        player.play()
    }

    private func finish() {
        player.pause()
        player.seek(to: .zero)
        updateNowPlaying()
    }

    /// A file that failed while playing through the folder is skipped like one that ended.
    /// Returns false when playback stops there.
    private func skipFailedItem() -> Bool {
        failuresInARow += 1
        guard failuresInARow < sessionItems.count else { return false }
        switch MediaPlaybackMode.current {
        case .sequential: return advance(by: 1, wrap: false, automatic: true)
        case .loopAll: return advance(by: 1, wrap: true, automatic: true)
        case .repeatOne, .stopAfter: return false
        }
    }

    /// Loads the next (or previous) playable file. Returns false when there is none.
    @discardableResult
    private func advance(by step: Int, wrap: Bool, automatic: Bool) -> Bool {
        guard let index = playableIndex(after: currentIndex, step: step, wrap: wrap) else { return false }
        automaticAdvance = automatic
        load(index, autoplay: true)
        return true
    }

    private func playableIndex(after start: Int?, step: Int, wrap: Bool) -> Int? {
        guard let start, !sessionItems.isEmpty else { return nil }
        let count = sessionItems.count
        var index = start
        for _ in 0..<count {
            index += step
            if index < 0 || index >= count {
                guard wrap else { return nil }
                index = (index % count + count) % count
            }
            if index == start { return nil }
            let file = sessionItems[index]
            if (file.kind == .video || file.kind == .audio) && !failedURLs.contains(file.url) { return index }
        }
        return nil
    }

    /// Next / previous from the lock screen or headphones.
    private func skip(by step: Int) {
        if step < 0, player.currentTime().seconds > 3 {
            player.seek(to: .zero)
            return
        }
        failuresInARow = 0
        advance(by: step, wrap: MediaPlaybackMode.current == .loopAll, automatic: false)
    }

    private func loadArtwork(of item: AVPlayerItem, url: URL) {
        let asset = item.asset
        Task { [weak self] in
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            let candidates = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
            guard let first = candidates.first,
                  let data = try? await first.load(.dataValue),
                  let image = UIImage(data: data),
                  let self, self.currentURL == url
            else { return }
            self.artwork = image
            self.audioOverlay.configure(title: url.lastPathComponent, artwork: image)
            self.updateNowPlaying()
        }
    }

    // MARK: - State

    private func observeAppAndPlayer() {
        player.publisher(for: \.timeControlStatus, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.playbackStatusChanged() }
            .store(in: &observers)
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.willResignActive() }
            .store(in: &observers)
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.didEnterBackground() }
            .store(in: &observers)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.willEnterForeground() }
            .store(in: &observers)
        center.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.didBecomeActive() }
            .store(in: &observers)
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in self?.audioSessionInterrupted(note) }
            .store(in: &observers)
    }

    private func playbackStatusChanged() {
        let playing = player.currentItem.map { $0.status != .failed } == true && player.timeControlStatus != .paused
        if isPlaying != playing { isPlaying = playing }
        updateNowPlaying()
        publishState()
    }

    private func publishState() {
        let pip = isPictureInPictureActive || isPictureInPictureStarting
        MediaViewerHub.shared.setVideoState(
            keepsAlive: isPlaying || pip || holdsForBackground,
            pictureInPicture: isPictureInPictureActive
        )
    }

    private func willResignActive() {
        wasPlayingWhenResigning = isPlaying
        let controller = pictureInPicture
        let possible = controller?.isPictureInPicturePossible ?? false
        pictureInPictureExpected = isPlaying && wantsAutomaticPictureInPicture && controller != nil
        if isPlaying {
            holdsForBackground = true
            if wantsAutomaticPictureInPicture {
                // Automatic PiP needs the (non-mixing) video audio session to be active.
                MediaViewerHub.shared.ensureVideoAudioSession()
                controller?.canStartPictureInPictureAutomaticallyFromInline = true
            }
            publishState()
        }
        guard player.currentItem != nil else { return }
        MediaDiagnostics.log(
            "离开 App：播放\(isPlaying ? "中" : "已停") 小窗\(possible ? "可开" : "不可开") "
                + "自动\(wantsAutomaticPictureInPicture ? "开" : "关") 声音 \(MediaViewerHub.shared.audioDescription) "
                + "画面\(playerViewController.viewIfLoaded?.window != nil ? "在屏幕上" : "不在屏幕上")"
                + "\(playerViewController.player == nil ? " 未连接播放器" : "")"
        )
    }

    private func didBecomeActive() {
        guard holdsForBackground else { return }
        holdsForBackground = false
        publishState()
    }

    private func didEnterBackground() {
        guard wasPlayingWhenResigning, player.currentItem != nil else { return }
        let waitsForPictureInPicture = pictureInPictureExpected
        Task { [weak self] in
            // Expected PiP gets plenty of time to begin; the sound goes on alone only without it,
            // so the fallback can no longer cut a slow PiP start short.
            try? await Task.sleep(nanoseconds: waitsForPictureInPicture ? 3_000_000_000 : 300_000_000)
            guard let self else { return }
            if waitsForPictureInPicture && !self.isPictureInPictureActive && !self.isPictureInPictureStarting {
                MediaDiagnostics.log("小窗没有启动")
            }
            self.keepPlayingInBackgroundIfNeeded()
        }
    }

    /// Without PiP, iOS pauses a video whose picture is attached to a view when the app leaves the
    /// screen. Detaching the player keeps its sound playing.
    private func keepPlayingInBackgroundIfNeeded() {
        guard UIApplication.shared.applicationState == .background,
              !isPictureInPictureActive, !isPictureInPictureStarting,
              pictureInPicture?.isPictureInPictureActive != true,
              player.currentItem != nil, !detachedForBackground
        else { return }
        playerViewController.player = nil
        detachedForBackground = true
        player.play()
        MediaDiagnostics.log("后台只播放声音")
    }

    private func willEnterForeground() {
        guard detachedForBackground else { return }
        playerViewController.player = player
        detachedForBackground = false
    }

    private func audioSessionInterrupted(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if wasPlayingBeforeInterruption, AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                play()
            }
            // The session was switched off and on: the PiP controller is made again.
            surfaceMoved()
            preparePictureInPicture()
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    // MARK: - Lock screen and Control Center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        if !remoteCommandsReady {
            remoteCommandsReady = true
            center.playCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.play() }
                return .success
            }
            center.pauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.pause() }
                return .success
            }
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in
                    if self.isPlaying { self.pause() } else { self.play() }
                }
                return .success
            }
            center.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.skip(by: 1) }
                return .success
            }
            center.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.skip(by: -1) }
                return .success
            }
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let seconds = event.positionTime
                Task { @MainActor in
                    self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                    self.updateNowPlaying()
                }
                return .success
            }
        }
        setRemoteCommandsEnabled(true)
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        guard remoteCommandsReady else { return }
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand, center.changePlaybackPositionCommand] {
            command.isEnabled = enabled
        }
    }

    private func updateNowPlaying() {
        guard let item = player.currentItem, let index = currentIndex, sessionItems.indices.contains(index) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let file = sessionItems[index]
        let mediaType: MPNowPlayingInfoMediaType = file.kind == .audio ? .audio : .video
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: (file.name as NSString).deletingPathExtension,
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: mediaType.rawValue),
        ]
        let elapsed = player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer asks for the image on its own queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Picture in Picture

    private func pictureInPictureWillStart() {
        MediaDiagnostics.log("视频小窗开始开启")
        isPictureInPictureStarting = true
        publishState()
    }

    private func pictureInPictureDidStart() {
        MediaDiagnostics.log("视频小窗已开启")
        isPictureInPictureStarting = false
        isPictureInPictureActive = true
        publishState()
    }

    private func pictureInPictureFailed() {
        isPictureInPictureStarting = false
        isPictureInPictureActive = false
        publishState()
        MediaViewerHub.shared.show("小窗暂时无法开启")
        // Nothing would be left to show or stop the video.
        guard MediaViewerHub.shared.isViewerPresented else {
            stop()
            return
        }
        // Keep the sound going if the app already left the screen.
        if wasPlayingWhenResigning, UIApplication.shared.applicationState == .background {
            keepPlayingInBackgroundIfNeeded()
        }
    }

    private func pictureInPictureDidStop() {
        let restoring = isRestoringFromPictureInPicture
        MediaDiagnostics.log(restoring ? "视频小窗回到全屏" : "视频小窗已关闭")
        isRestoringFromPictureInPicture = false
        isPictureInPictureStarting = false
        isPictureInPictureActive = false
        finishRestore(false)
        publishState()
        let hub = MediaViewerHub.shared
        if !restoring && !LockManager.shared.isUnlocked {
            // Closed with its X while locked: nothing of it may be left on return.
            stop()
            hub.closeViewerAfterPictureInPicture()
            return
        }
        if !hub.isViewerPresented || hub.presentedURLs != sessionItems.map(\.url) {
            // Closed with its X after the viewer had closed or moved on to another folder: the
            // session is over.
            stop()
        } else {
            hub.checkInBackground(after: 0.6)
        }
    }

    /// Brings the viewer back on the playing file (reopening it if it was closed) before PiP
    /// animates into it.
    private func restoreUserInterface(_ completion: @escaping (Bool) -> Void) {
        isRestoringFromPictureInPicture = true
        guard let index = currentIndex, sessionItems.indices.contains(index) else {
            completion(false)
            return
        }
        finishRestore(false)
        pendingRestore = completion
        let id = UUID()
        restoreID = id
        let hub = MediaViewerHub.shared
        hub.reveal(sessionItems, at: index, reopen: true)
        if hub.presentedURLs == sessionItems.map(\.url), playerViewController.viewIfLoaded?.window != nil {
            playerViewDidAppear()
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.restoreID == id else { return }
            self.finishRestore(self.playerViewController.viewIfLoaded?.window != nil)
        }
    }

    /// The player's view is on screen again (called by its host page).
    func playerViewDidAppear() {
        preparePictureInPicture()
        guard pendingRestore != nil else { return }
        let id = restoreID
        Task { [weak self] in
            // Let the viewer settle on the page first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.restoreID == id else { return }
            self.finishRestore(true)
        }
    }

    private func finishRestore(_ restored: Bool) {
        let completion = pendingRestore
        pendingRestore = nil
        restoreID = UUID()
        completion?(restored)
    }
}

extension MediaPlaybackController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pictureInPictureWillStart() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pictureInPictureDidStart() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let reason = (error as NSError).localizedDescription + " (\((error as NSError).code))"
        Task { @MainActor in
            MediaDiagnostics.log("视频小窗开启失败：\(reason)")
            self.pictureInPictureFailed()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.pictureInPictureDidStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in self.restoreUserInterface(completionHandler) }
    }
}

/// The video picture: a view backed by an AVPlayerLayer, black around the video.
final class MediaPlayerSurfaceController: UIViewController {
    var playerLayer: AVPlayerLayer { surface.playerLayer }

    var player: AVPlayer? {
        get { surface.playerLayer.player }
        set { surface.playerLayer.player = newValue }
    }

    private let surface = MediaPlayerLayerView()

    override func loadView() {
        surface.backgroundColor = .black
        surface.playerLayer.videoGravity = .resizeAspect
        view = surface
    }
}

final class MediaPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass guarantees the type.
        layer as! AVPlayerLayer
    }
}

/// Artwork (or a note symbol) and the file name over the empty picture of an audio file.
final class MediaAudioOverlayView: UIView {
    private let artworkView = UIImageView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        artworkView.contentMode = .scaleAspectFit
        artworkView.tintColor = UIColor.white.withAlphaComponent(0.8)
        artworkView.layer.cornerRadius = 12
        artworkView.clipsToBounds = true
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [artworkView, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            artworkView.widthAnchor.constraint(equalToConstant: 160),
            artworkView.heightAnchor.constraint(equalToConstant: 160),
        ])
        configure(title: "", artwork: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, artwork: UIImage?) {
        titleLabel.text = title
        artworkView.image = artwork ?? UIImage(systemName: "music.note")
    }
}
