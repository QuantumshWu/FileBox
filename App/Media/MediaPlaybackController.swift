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

/// The speeds of the viewer's speed menu. The choice is stored in UserDefaults under `storageKey`
/// and applies to every file until it is changed.
enum PlayerSpeed {
    static let storageKey = "mediaPlaybackSpeed"
    static let options: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// The stored speed, snapped to one of the options (1 when unset).
    static var stored: Float {
        let value = UserDefaults.standard.object(forKey: storageKey) as? Double ?? 1
        guard value.isFinite, value > 0 else { return 1 }
        return options.min { abs(Double($0) - value) < abs(Double($1) - value) } ?? 1
    }

    /// "1.5×"
    static func label(_ speed: Float) -> String {
        String(format: "%g×", Double(speed))
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
    /// From `beginScrub` until the picture has landed where the finger let go.
    @Published private(set) var isScrubbing = false
    /// Where the picture is heading, in seconds; nil when no seek is pending. Shown instead of the
    /// player's time, so the scrubber never jumps back while a seek runs.
    @Published private(set) var seekTarget: Double?
    /// Equals `currentURL` once that file's first frame is on screen (at once for audio).
    @Published private(set) var displayReadyURL: URL?
    /// Pressed and held: playing at double speed until the finger lifts.
    @Published private(set) var isBoosted = false
    /// The player has been waiting for data for a moment.
    @Published private(set) var isBuffering = false
    /// Size of the video picture; `.zero` until known, and for audio.
    @Published private(set) var presentationSize: CGSize = .zero
    /// Playback speed of every file, kept across launches (see `PlayerSpeed`).
    @Published var speed: Float {
        didSet { speedChanged(from: oldValue) }
    }

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
    private var remoteCommandsEnabled = false
    /// The viewer moved on to an image: Control Center must not start the video behind it.
    private var offPlayablePage = false
    private var artwork: UIImage?
    private var artist: String?
    private var album: String?
    private let audioOverlay = MediaAudioOverlayView()
    private var observers: Set<AnyCancellable> = []
    private var itemObservers: Set<AnyCancellable> = []
    private var positionObserver: Any?

    // Seeking: one seek at a time, the next one to the latest target (see `chase`).
    private enum SeekPurpose {
        case move, scrubEnd, resume
    }

    private struct SeekRequest {
        let seconds: Double
        let tolerance: CMTime
        let purpose: SeekPurpose
    }

    private var pendingSeek: SeekRequest?
    private var inFlightSeek: SeekRequest?
    /// Bumped whenever the item changes, so completions of seeks on an earlier item are ignored.
    private var seekGeneration = 0
    private var lastTargetPublish: CFTimeInterval = 0
    private var scrubFingerDown = false
    private var wasPlayingBeforeScrub = false

    // First frame
    /// The item `load` put in the player.
    private weak var loadedItem: AVPlayerItem?
    private var displayToken = UUID()

    // Resume position
    /// This session's positions: paging A → B → A continues A.
    private var sessionPositions: [URL: Double] = [:]
    /// The file waits for its saved position before it may play or show its first frame.
    private var awaitsResume = false
    private var resumeAutoplay = false
    /// The saved position comes from an earlier visit (设置 → 记住播放位置), not from paging back
    /// to the file in this session: only then does a message say where it continues.
    private var announcesResume = false

    // Buffering and interruptions
    private var waitingToken: UUID?
    private var lastPausedAt: Date?
    private var lastPauseWasOurs = false
    private var ownPauseAt: Date?

    private static let lockScreenButtonsKey = "mediaLockScreenButtons"

    private override init() {
        _speed = Published(initialValue: PlayerSpeed.stored)
        super.init()
        player.actionAtItemEnd = .none
        player.defaultRate = speed
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
        offPlayablePage = false
        if currentURL == items[index].url {
            // Already in the player, e.g. the viewer reopened from PiP or paged back to it.
            if currentIndex != index { currentIndex = index }
            applyRemoteCommandState()
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
        endBoost()
        guard !isPictureInPictureActive, !isPictureInPictureStarting else { return }
        saveResumePosition()
        let waitedToPlay = awaitsResume && resumeAutoplay
        if player.timeControlStatus != .paused || waitedToPlay {
            resumeOnReturn = true
        }
        resumeAutoplay = false
        offPlayablePage = true
        applyRemoteCommandState()
        pauseForUs()
        if waitedToPlay { playbackStatusChanged() }
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
        guard let item = player.currentItem else { return }
        if awaitsResume {
            // It plays once the saved position is reached.
            resumeAutoplay = true
            playbackStatusChanged()
            return
        }
        MediaViewerHub.shared.activateAudioSession(for: .video)
        if item.status == .readyToPlay {
            let duration = Self.duration(of: item)
            let position = seekTarget ?? player.currentTime().seconds
            if duration > 0, position >= duration - 0.25 {
                // Parked at the very end: play starts over instead of ending again at once.
                seekToStart()
            }
        }
        player.play()
    }

    func pause() {
        resumeOnReturn = false
        let waitedToPlay = awaitsResume && resumeAutoplay
        resumeAutoplay = false
        saveResumePosition()
        pauseForUs()
        // Already paused while it waited for its saved position: nothing else reports it.
        if waitedToPlay { playbackStatusChanged() }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
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
        saveResumePosition()
        resumeOnReturn = false
        endBoost()
        pauseForUs()
        player.replaceCurrentItem(with: nil)
        releasePictureInPictureController()
        itemObservers.removeAll()
        resetSeeking()
        sessionItems = []
        currentURL = nil
        currentIndex = nil
        loadedItem = nil
        awaitsResume = false
        resumeAutoplay = false
        displayToken = UUID()
        if displayReadyURL != nil { displayReadyURL = nil }
        if presentationSize != .zero { presentationSize = .zero }
        waitingToken = nil
        if isBuffering { isBuffering = false }
        artwork = nil
        artist = nil
        album = nil
        failedURLs = []
        sessionPositions = [:]
        automaticAdvance = false
        holdsForBackground = false
        offPlayablePage = false
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

    /// Pauses for a reason of our own (not the system), which an audio interruption must not undo.
    private func pauseForUs() {
        ownPauseAt = Date()
        player.pause()
    }

    // MARK: - Seeking

    /// The finger went down on the scrubber: playback pauses (without forgetting it played) until
    /// the picture has landed where the finger lets go.
    func beginScrub() {
        guard let item = player.currentItem, item.status == .readyToPlay, Self.duration(of: item) > 0 else { return }
        if !isScrubbing {
            // First, so the pause below is known to be the scrubber's.
            isScrubbing = true
            wasPlayingBeforeScrub = player.timeControlStatus != .paused || (awaitsResume && resumeAutoplay)
        }
        scrubFingerDown = true
        endBoost()
        pauseForUs()
    }

    /// The finger moved along the scrubber; the picture follows it.
    func scrub(to seconds: Double) {
        guard isScrubbing, scrubFingerDown, let item = player.currentItem else { return }
        // Exact frames on clips up to 3 minutes; on longer ones the nearest second is fast enough.
        let tolerance = Self.duration(of: item) <= 180 ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
        chase(to: seconds, tolerance: tolerance, purpose: .move)
    }

    /// The finger let go: an exact seek there, then playback goes on if it played before.
    func endScrub(at seconds: Double) {
        guard isScrubbing, scrubFingerDown else { return }
        scrubFingerDown = false
        chase(to: seconds, tolerance: .zero, purpose: .scrubEnd)
    }

    /// Skips `seconds` forward (or back, when negative) from where the picture is heading, so
    /// quick repeated taps add up. Playing or paused stays as it was. False when nothing can seek.
    @discardableResult
    func seek(by seconds: Double) -> Bool {
        guard !isScrubbing, let item = player.currentItem, item.status == .readyToPlay else { return false }
        let duration = Self.duration(of: item)
        guard duration > 0 else { return false }
        let now = player.currentTime().seconds
        let base = seekTarget ?? (now.isFinite ? now : 0)
        let target = min(max(0, base + seconds), max(0, duration - 0.1))
        chase(to: target, tolerance: CMTime(seconds: 0.1, preferredTimescale: 600), purpose: .move)
        return true
    }

    /// Seeks the way the trim editor does (Apple QA1820): one seek at a time, and when it lands the
    /// next one goes to the latest target. Issuing a seek per finger move would cancel every one
    /// still running, and the picture would freeze until the finger stops.
    private func chase(to seconds: Double, tolerance: CMTime, purpose: SeekPurpose) {
        guard let item = player.currentItem else { return }
        if pendingSeek?.purpose == .resume && purpose != .resume {
            // A newer target replaces the saved position before it was reached.
            pendingSeek = nil
            settleResume(at: nil)
        }
        let target = Self.clamped(seconds, in: item)
        pendingSeek = SeekRequest(seconds: target, tolerance: tolerance, purpose: purpose)
        // While a finger drags, at most 20 updates a second reach the views watching this object.
        publishSeekTarget(target, force: !(purpose == .move && scrubFingerDown))
        issuePendingSeek()
    }

    /// Seeking with a completion handler before the item is ready raises an exception, so until
    /// then the target waits here (see `itemStatusChanged`).
    private func issuePendingSeek() {
        guard inFlightSeek == nil, let request = pendingSeek, let item = player.currentItem,
              item.status == .readyToPlay
        else { return }
        pendingSeek = nil
        let target = Self.clamped(request.seconds, in: item)
        inFlightSeek = SeekRequest(seconds: target, tolerance: request.tolerance, purpose: request.purpose)
        publishSeekTarget(target, force: false)
        let generation = seekGeneration
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: request.tolerance, toleranceAfter: request.tolerance) { finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    MediaPlaybackController.shared.seekLanded(finished: finished, generation: generation)
                }
            }
        }
    }

    private func seekLanded(finished: Bool, generation: Int) {
        guard generation == seekGeneration, let request = inFlightSeek else { return }
        inFlightSeek = nil
        if request.purpose == .resume {
            settleResume(at: finished ? request.seconds : nil)
        }
        if pendingSeek != nil {
            issuePendingSeek()
            return
        }
        if seekTarget != nil { seekTarget = nil }
        // While a finger drags, Now Playing waits for the end of the drag.
        if !scrubFingerDown { updateNowPlaying() }
        guard isScrubbing, !scrubFingerDown else { return }
        // The finger has let go and the picture is where it was released.
        isScrubbing = false
        let playOn = wasPlayingBeforeScrub
        wasPlayingBeforeScrub = false
        guard finished, request.purpose == .scrubEnd, playOn, !isPictureInPictureEngaged,
              let item = player.currentItem, request.seconds < Self.duration(of: item) - 0.25
        else { return }
        play()
    }

    private func publishSeekTarget(_ target: Double, force: Bool) {
        let now = CACurrentMediaTime()
        guard force || seekTarget == nil || now - lastTargetPublish >= 0.05 else { return }
        lastTargetPublish = now
        if seekTarget != target { seekTarget = target }
    }

    /// A seek outside the chase (restart, end of file, previous): it overrides whatever the chase
    /// still had to do.
    private func seekToStart() {
        if pendingSeek?.purpose == .resume {
            pendingSeek = nil
            settleResume(at: nil)
        }
        pendingSeek = nil
        if seekTarget != nil { seekTarget = nil }
        player.seek(to: .zero)
    }

    /// Forgets every seek of the item that is leaving the player.
    private func resetSeeking() {
        seekGeneration += 1
        pendingSeek = nil
        inFlightSeek = nil
        scrubFingerDown = false
        wasPlayingBeforeScrub = false
        if seekTarget != nil { seekTarget = nil }
        if isScrubbing { isScrubbing = false }
    }

    private static func duration(of item: AVPlayerItem) -> Double {
        let seconds = item.duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Within the file, a hair before its end (so a seek never lands on "ended").
    private static func clamped(_ seconds: Double, in item: AVPlayerItem) -> Double {
        let target = seconds.isFinite ? max(0, seconds) : 0
        let length = Self.duration(of: item)
        return length > 0 ? min(target, max(0, length - 0.05)) : target
    }

    // MARK: - Speed and boost

    private func speedChanged(from oldValue: Float) {
        guard speed != oldValue else { return }
        UserDefaults.standard.set(Double(speed), forKey: PlayerSpeed.storageKey)
        // Every `player.play()` (modes, PiP, lock screen, background) starts at the default rate.
        player.defaultRate = speed
        if player.rate != 0 && !isBoosted { player.rate = speed }
        updateNowPlaying()
        MediaViewerHub.shared.show("播放速度 \(PlayerSpeed.label(speed))")
    }

    /// Press and hold: double speed (at least 2×, at most 3×) while the finger stays down.
    @discardableResult
    func beginBoost() -> Bool {
        if isBoosted { return true }
        guard isPlaying, !isScrubbing, !awaitsResume, !isPictureInPictureEngaged else { return false }
        isBoosted = true
        player.rate = min(3, max(2, speed * 2))
        updateNowPlaying()
        return true
    }

    /// Back to the chosen speed (if still playing).
    func endBoost() {
        guard isBoosted else { return }
        isBoosted = false
        if player.rate != 0 { player.rate = player.defaultRate }
        updateNowPlaying()
    }

    // MARK: - Loading and advancing

    private func load(_ index: Int, autoplay: Bool) {
        let file = sessionItems[index]
        // Where the outgoing file stands, before it leaves the player.
        saveResumePosition()
        if !MediaViewerHub.shared.activateAudioSession(for: .video) {
            MediaViewerHub.shared.show("声音暂时无法播放")
        }
        endBoost()
        resetSeeking()
        resumeOnReturn = false
        let resumeAt = resumePosition(for: file)
        if resumeAt != nil || !autoplay {
            // The rate of the outgoing file would carry over and start this one from 0.
            pauseForUs()
        }
        let item = AVPlayerItem(asset: PlayerAssetCache.asset(for: file))
        // Natural voices at other speeds.
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item)
        pictureInPictureNeedsRefresh = true
        currentURL = file.url
        loadedItem = item
        awaitsResume = resumeAt != nil
        resumeAutoplay = autoplay && resumeAt != nil
        announcesResume = resumeAt != nil && sessionPositions[file.url] == nil
        if presentationSize != .zero { presentationSize = .zero }
        artwork = nil
        artist = nil
        album = nil
        audioOverlay.configure(title: Self.title(of: file.name), artist: nil, artwork: nil)
        audioOverlay.isHidden = file.kind != .audio
        prepareDisplay(for: file)
        player.replaceCurrentItem(with: item)
        currentIndex = index
        configureRemoteCommands()
        updateNowPlaying()
        waitingToken = nil
        if isBuffering { isBuffering = false }
        if let resumeAt {
            // Applied once the item is ready (see `issuePendingSeek`); it plays after that.
            chase(to: resumeAt, tolerance: .zero, purpose: .resume)
            playbackStatusChanged()
        } else if autoplay {
            player.play()
        }
        updateBuffering()
        if file.kind == .audio { loadMetadata(of: item, url: file.url) }
        warmNeighbours(of: index)
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservers.removeAll()
        let center = NotificationCenter.default
        center.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.itemDidEnd() }
            .store(in: &itemObservers)
        center.publisher(for: AVPlayerItem.timeJumpedNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // While seeks are chased, Now Playing is updated once the picture has landed.
                guard let self, !self.isScrubbing, self.seekTarget == nil else { return }
                self.updateNowPlaying()
            }
            .store(in: &itemObservers)
        center.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self, let item, item === self.player.currentItem else { return }
                self.currentItemFailed()
            }
            .store(in: &itemObservers)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item, item === self.player.currentItem else { return }
                self.itemStatusChanged(status)
            }
            .store(in: &itemObservers)
        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] size in
                guard let self, let item, item === self.player.currentItem, self.presentationSize != size else { return }
                self.presentationSize = size
            }
            .store(in: &itemObservers)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            failuresInARow = 0
            issuePendingSeek()
            updateNowPlaying()
            if playerViewController.playerLayer.isReadyForDisplay {
                // The layer may have reported its frame before the item reported ready.
                Task { [weak self] in self?.markDisplayReady() }
            }
            if player.timeControlStatus == .paused && !awaitsResume {
                // Not playing: the paused first frame is up in a moment.
                let token = displayToken
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self, self.displayToken == token else { return }
                    self.markDisplayReady()
                }
            }
        case .failed:
            currentItemFailed()
        default:
            break
        }
    }

    /// The file could not be opened, or broke off while playing.
    private func currentItemFailed() {
        if let url = currentURL, !failedURLs.contains(url) { failedURLs.insert(url) }
        awaitsResume = false
        resumeAutoplay = false
        // A failed item can leave the player "waiting" forever, which would count as playing.
        if !(automaticAdvance && skipFailedItem()) {
            pauseForUs()
            playbackStatusChanged()
        }
    }

    /// Called when the file in the player ends; continues per the playback mode.
    private func itemDidEnd() {
        endBoost()
        if let index = currentIndex, sessionItems.indices.contains(index) {
            // Played to the end: next time it starts from the beginning.
            let file = sessionItems[index]
            sessionPositions[file.url] = nil
            PlayerResumeStore.shared.remove(file)
        }
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
        seekToStart()
        player.play()
    }

    private func finish() {
        pauseForUs()
        seekToStart()
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

    /// Previous (-1) or next (+1) playable file of the folder, from the lock screen, headphones or
    /// the viewer's buttons. Previous more than 3 s into a file starts that file over instead.
    func skipTrack(_ step: Int) {
        if step < 0, (seekTarget ?? player.currentTime().seconds) > 3 {
            seekToStart()
            updateNowPlaying()
            return
        }
        failuresInARow = 0
        advance(by: step, wrap: MediaPlaybackMode.current == .loopAll, automatic: false)
    }

    /// Opens the files on either side ahead of time, so the next one starts quickly.
    private func warmNeighbours(of index: Int) {
        let neighbours = [index + 1, index - 1]
            .filter { sessionItems.indices.contains($0) }
            .map { sessionItems[$0] }
        PlayerAssetCache.warm(neighbours)
    }

    /// Artwork, artist and album of an audio file, for the overlay and the lock screen.
    private func loadMetadata(of item: AVPlayerItem, url: URL) {
        let asset = item.asset
        Task { [weak self] in
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var image: UIImage?
            if let first = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await first.load(.dataValue) {
                image = UIImage(data: data)
            }
            let artist = await MediaPlaybackController.metadataString(.commonIdentifierArtist, in: metadata)
            let album = await MediaPlaybackController.metadataString(.commonIdentifierAlbumName, in: metadata)
            guard let self, self.currentURL == url else { return }
            self.artwork = image
            self.artist = artist
            self.album = album
            self.audioOverlay.configure(title: Self.title(of: url.lastPathComponent), artist: artist, artwork: image)
            self.updateNowPlaying()
        }
    }

    private static func metadataString(_ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The file name without its extension.
    private static func title(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    // MARK: - First frame

    /// Until the new file's first frame is up, the viewer keeps its still picture over the player,
    /// so paging and opening never flash black.
    private func prepareDisplay(for file: FileItem) {
        let token = UUID()
        displayToken = token
        guard file.kind != .audio else {
            // Nothing to wait for: audio shows its own overlay.
            displayReadyURL = file.url
            return
        }
        if displayReadyURL != nil { displayReadyURL = nil }
        let url = file.url
        Task { [weak self] in
            // Never leave the picture covered for long, whatever the signals did.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.displayToken == token, self.currentURL == url else { return }
            self.markDisplayReady(fallback: true)
        }
    }

    /// The first frame of the loaded file is on screen. Before the saved position is reached only
    /// the fallback may say so, or frame 0 would flash first.
    private func markDisplayReady(fallback: Bool = false) {
        guard let url = currentURL, displayReadyURL != url,
              let item = player.currentItem, item === loadedItem
        else { return }
        if !fallback {
            guard !awaitsResume, item.status == .readyToPlay else { return }
        }
        displayReadyURL = url
    }

    // MARK: - Resume position

    /// Remembers where the file in the player stands: for this session (paging back continues
    /// there) and, with 设置 → 记住播放位置 on, across launches.
    private func saveResumePosition() {
        guard let item = player.currentItem, item.status == .readyToPlay, !awaitsResume,
              let index = currentIndex, sessionItems.indices.contains(index)
        else { return }
        let file = sessionItems[index]
        guard file.url == currentURL else { return }
        let duration = Self.duration(of: item)
        let seconds = seekTarget ?? player.currentTime().seconds
        guard duration > 0, seconds.isFinite else { return }
        if PlayerResumeStore.isEligible(seconds: seconds, duration: duration) {
            sessionPositions[file.url] = seconds
        } else {
            sessionPositions[file.url] = nil
        }
        PlayerResumeStore.shared.save(seconds, duration: duration, for: file)
    }

    private func resumePosition(for file: FileItem) -> Double? {
        sessionPositions[file.url] ?? PlayerResumeStore.shared.position(for: file)
    }

    /// The seek to the saved position landed (`seconds`), or was given up (nil).
    private func settleResume(at seconds: Double?) {
        guard awaitsResume else { return }
        awaitsResume = false
        let autoplay = resumeAutoplay
        resumeAutoplay = false
        if autoplay && !isScrubbing {
            play()
        } else {
            // No longer waiting to play; playing itself reports through timeControlStatus.
            playbackStatusChanged()
        }
        if let seconds, announcesResume {
            MediaViewerHub.shared.show("从 \(MediaVideoControls.format(seconds)) 继续播放")
        }
        announcesResume = false
        if player.timeControlStatus == .playing || playerViewController.playerLayer.isReadyForDisplay {
            let token = displayToken
            Task { [weak self] in
                // A moment for the frame at the new position to reach the layer.
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.displayToken == token else { return }
                self.markDisplayReady()
            }
        }
    }

    // MARK: - State

    private func observeAppAndPlayer() {
        player.publisher(for: \.timeControlStatus, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.playbackStatusChanged() }
            .store(in: &observers)
        // A speed change while playing does not change timeControlStatus.
        player.publisher(for: \.rate, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isScrubbing else { return }
                self.updateNowPlaying()
            }
            .store(in: &observers)
        playerViewController.playerLayer.publisher(for: \.isReadyForDisplay, options: [.new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                if ready { self?.markDisplayReady() }
            }
            .store(in: &observers)
        positionObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 5, timescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicSave() }
        }
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

    private func periodicSave() {
        guard isPlaying else { return }
        saveResumePosition()
    }

    private func playbackStatusChanged() {
        // Waiting for the saved position before playing counts as playing, like waiting for data.
        let waitsToPlay = awaitsResume && resumeAutoplay
        let playing = player.currentItem.map { $0.status != .failed } == true
            && (player.timeControlStatus != .paused || waitsToPlay)
        if isPlaying != playing {
            if !playing {
                // An audio interruption may be reported after the pause it caused.
                let now = Date()
                lastPausedAt = now
                lastPauseWasOurs = ownPauseAt.map { now.timeIntervalSince($0) < 1 } ?? false
            }
            isPlaying = playing
        }
        if !playing { endBoost() }
        if player.timeControlStatus == .playing { markDisplayReady() }
        updateBuffering()
        updateNowPlaying()
        publishState()
    }

    /// Waiting for data for more than 0.4 s counts as buffering (a spinner may show).
    private func updateBuffering() {
        guard player.currentItem != nil, player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            waitingToken = nil
            if isBuffering { isBuffering = false }
            return
        }
        guard waitingToken == nil else { return }
        let token = UUID()
        waitingToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.waitingToken == token,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            else { return }
            self.isBuffering = true
        }
    }

    private func publishState() {
        let pip = isPictureInPictureActive || isPictureInPictureStarting
        MediaViewerHub.shared.setVideoState(
            keepsAlive: isPlaying || pip || holdsForBackground,
            pictureInPicture: isPictureInPictureActive
        )
    }

    private func willResignActive() {
        endBoost()
        saveResumePosition()
        PlayerResumeStore.shared.flush()
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
        // A file still seeking to its saved position plays once it is there.
        if !awaitsResume { player.play() }
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
            // 1 = AVAudioSessionInterruptionReasonAppWasSuspended: the app was suspended earlier;
            // nothing is interrupting playback now.
            if let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt, reason == 1 { return }
            // The system's pause may have been reported first, so "playing" can already read false.
            let pausedJustNow = lastPausedAt.map { Date().timeIntervalSince($0) < 1 } ?? false
            wasPlayingBeforeInterruption = isPlaying || (pausedJustNow && !lastPauseWasOurs)
        case .ended:
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if wasPlayingBeforeInterruption, player.currentItem != nil,
               AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
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
                Task { @MainActor in self.togglePlayPause() }
                return .success
            }
            center.nextTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.skipTrack(1) }
                return .success
            }
            center.previousTrackCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                Task { @MainActor in self.skipTrack(-1) }
                return .success
            }
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let seconds = event.positionTime
                // Exact, and Now Playing is updated once it has landed, so the thumb never jumps back.
                Task { @MainActor in self.chase(to: seconds, tolerance: .zero, purpose: .move) }
                return .success
            }
            center.skipForwardCommand.preferredIntervals = [NSNumber(value: 15)]
            center.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
            center.skipForwardCommand.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
                Task { @MainActor in self.seek(by: interval) }
                return .success
            }
            center.skipBackwardCommand.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
                Task { @MainActor in self.seek(by: -interval) }
                return .success
            }
        }
        setRemoteCommandsEnabled(true)
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        remoteCommandsEnabled = enabled
        applyRemoteCommandState()
    }

    /// 设置 → 锁屏按钮 picks previous / next file or skipping 15 seconds; on an image page nothing
    /// may start the video behind it.
    private func applyRemoteCommandState() {
        guard remoteCommandsReady else { return }
        let center = MPRemoteCommandCenter.shared()
        let enabled = remoteCommandsEnabled
        let skips = UserDefaults.standard.string(forKey: Self.lockScreenButtonsKey) == "skip"
        center.playCommand.isEnabled = enabled && !offPlayablePage
        center.togglePlayPauseCommand.isEnabled = enabled && !offPlayablePage
        center.pauseCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        center.nextTrackCommand.isEnabled = enabled && !skips
        center.previousTrackCommand.isEnabled = enabled && !skips
        center.skipForwardCommand.isEnabled = enabled && skips
        center.skipBackwardCommand.isEnabled = enabled && skips
    }

    /// 设置 → 锁屏按钮 changed.
    func lockScreenButtonsChanged() {
        applyRemoteCommandState()
    }

    private func updateNowPlaying() {
        guard let item = player.currentItem, let index = currentIndex, sessionItems.indices.contains(index) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let file = sessionItems[index]
        let mediaType: MPNowPlayingInfoMediaType = file.kind == .audio ? .audio : .video
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: Self.title(of: file.name),
            MPNowPlayingInfoPropertyPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: mediaType.rawValue),
        ]
        let elapsed = seekTarget ?? player.currentTime().seconds
        if elapsed.isFinite { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
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
        endBoost()
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

/// The video picture: a view backed by an AVPlayerLayer, clear around the video (the viewer
/// draws the black backdrop, so swiping to close can reveal the list underneath).
final class MediaPlayerSurfaceController: UIViewController {
    var playerLayer: AVPlayerLayer { surface.playerLayer }

    var player: AVPlayer? {
        get { surface.playerLayer.player }
        set { surface.playerLayer.player = newValue }
    }

    private let surface = MediaPlayerLayerView()

    override func loadView() {
        surface.backgroundColor = .clear
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

/// Artwork (or a note symbol), the title and the artist over the empty picture of an audio file.
final class MediaAudioOverlayView: UIView {
    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()

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
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        artistLabel.font = .preferredFont(forTextStyle: .subheadline)
        artistLabel.textAlignment = .center
        artistLabel.numberOfLines = 1
        let stack = UIStackView(arrangedSubviews: [artworkView, titleLabel, artistLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.setCustomSpacing(4, after: titleLabel)
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
        configure(title: "", artist: nil, artwork: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, artist: String?, artwork: UIImage?) {
        titleLabel.text = title
        artistLabel.text = artist
        artistLabel.isHidden = artist?.isEmpty ?? true
        artworkView.image = artwork ?? UIImage(systemName: "music.note")
    }
}
