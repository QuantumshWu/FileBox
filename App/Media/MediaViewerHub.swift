import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Connects the viewer on screen with the two playback engines (`MediaPlaybackController` for
/// video and audio, `MediaImagePiPController` for images) and mirrors them into `PlaybackState`.
@MainActor
final class MediaViewerHub: ObservableObject {
    static let shared = MediaViewerHub()

    /// A page the viewer showing `urls` should move to (PiP skip buttons, restoring from PiP).
    struct PageRequest: Equatable {
        let id = UUID()
        let urls: [URL]
        let index: Int
    }

    enum AudioUse: Hashable {
        case video, image
    }

    @Published private(set) var pageRequest: PageRequest?
    @Published private(set) var toast: String?

    /// The app's viewer coordinator, used to reopen the viewer when PiP is restored after it closed.
    private weak var coordinator: ViewerCoordinator?
    private var requestObserver: AnyCancellable?
    /// Files of the viewer on screen, nil while it is closed.
    private(set) var presentedURLs: [URL]?
    private var presentedToken: UUID?
    /// The `ViewerRequest` the viewer on screen shows. A request with the same id is the same
    /// viewer with a file taken out; any other request (or none) means it closed.
    private var presentedRequestID: UUID?

    private var videoKeepsAlive = false
    private var videoPiPActive = false
    private var imageKeepsAlive = false
    private var imagePiPActive = false
    private var audioHolders: Set<AudioUse> = []
    /// Whether this app last switched the audio session on (an interruption switches it off).
    private var sessionActive = false
    /// Bumped by every activation, so a deferred switch-off that is no longer wanted does nothing.
    private var deactivationGeneration = 0
    private var appObservers: Set<AnyCancellable> = []

    var isViewerPresented: Bool { presentedToken != nil }
    var isVideoPictureInPictureActive: Bool { videoPiPActive }
    var isImagePictureInPictureActive: Bool { imagePiPActive }

    private init() {
        let center = NotificationCenter.default
        // The viewer itself stays open in the background, on the same file and turned the same way.
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                // A suspended app would never run a deferred switch-off.
                if self.audioHolders.isEmpty && self.sessionActive { self.deactivateAudioSession() }
            }
            .store(in: &appObservers)
        center.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .began
                else { return }
                // The system switched the session off; the next activation switches it on again.
                self?.sessionActive = false
            }
            .store(in: &appObservers)
        center.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sessionActive = false }
            .store(in: &appObservers)
    }

    // MARK: - Viewer

    func viewerAppeared(token: UUID, requestID: UUID?, items: [FileItem], coordinator: ViewerCoordinator) {
        presentedToken = token
        presentedRequestID = requestID
        presentedURLs = items.map(\.url)
        if self.coordinator !== coordinator {
            self.coordinator = coordinator
            // Closing the viewer (its button, a swipe, PiP's X) clears the request.
            requestObserver = coordinator.$request.sink { [weak self] request in
                self?.requestChanged(request)
            }
        }
        publish()
    }

    /// Fallback for a viewer that went away while its request stayed; a cover presented from the
    /// viewer (an editor, Quick Look) also makes it disappear, and that must not end playback.
    func viewerDisappeared(token: UUID) {
        guard presentedToken == token else { return }
        if let request = coordinator?.request, request.id == presentedRequestID { return }
        closePresentedViewer()
    }

    private func requestChanged(_ request: ViewerRequest?) {
        guard presentedToken != nil else { return }
        if let request, request.id == presentedRequestID {
            // The same viewer with a deleted file taken out.
            presentedURLs = request.items.map(\.url)
            publish()
            return
        }
        closePresentedViewer()
    }

    private func closePresentedViewer() {
        presentedToken = nil
        presentedRequestID = nil
        presentedURLs = nil
        publish()
        ViewerOrientation.restorePortrait()
        MediaPlaybackController.shared.viewerClosed()
        MediaImagePiPController.shared.viewerClosed()
    }

    /// Moves the viewer to `items[index]`. If another folder (or nothing) is on screen, `reopen`
    /// presents the viewer again, already settled, so Picture in Picture can animate into it.
    func reveal(_ items: [FileItem], at index: Int, reopen: Bool) {
        guard items.indices.contains(index) else { return }
        let urls = items.map(\.url)
        if presentedURLs == urls {
            pageRequest = PageRequest(urls: urls, index: index)
        } else if reopen {
            coordinator?.open(items, at: index, animated: false)
        }
    }

    func show(_ message: String) {
        toast = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: - App shell

    func setVideoState(keepsAlive: Bool, pictureInPicture: Bool) {
        let pipChanged = videoPiPActive != pictureInPicture
        videoKeepsAlive = keepsAlive
        videoPiPActive = pictureInPicture
        publish()
        if pipChanged { MediaImagePiPController.shared.videoPictureInPictureChanged() }
    }

    func setImageState(keepsAlive: Bool, pictureInPicture: Bool) {
        imageKeepsAlive = keepsAlive
        imagePiPActive = pictureInPicture
        publish()
    }

    /// While the viewer is open and something plays or PiP is active or armed, going to the
    /// background must not cover it with the privacy shield, which would keep PiP from starting.
    /// A closed viewer leaves nothing to keep: PiP floats on by itself.
    private func publish() {
        let state = PlaybackState.shared
        let pip = videoPiPActive || imagePiPActive
        let keeps = isViewerPresented && (pip || videoKeepsAlive || imageKeepsAlive)
        if state.keepsViewerInBackground != keeps { state.keepsViewerInBackground = keeps }
        if state.isPictureInPictureActive != pip { state.isPictureInPictureActive = pip }
    }

    /// FileBox came back to the screen while something floats: end the floating window and show
    /// it in the viewer again.
    func endPictureInPictureForReturn() {
        MediaPlaybackController.shared.endPictureInPictureForReturn()
        MediaImagePiPController.shared.endPictureInPictureForReturn()
    }

    /// PiP was closed with its X, whenever iOS delivers that (often only once the user is back in
    /// the app): the viewer showing `urls`, the one PiP floated from, closes at once and without its
    /// closing animation, so the page it was opened from is all that shows.
    func closeViewerAfterPictureInPicture(of urls: [URL]) {
        guard isViewerPresented, presentedURLs == urls else { return }
        coordinator?.closeImmediately()
        // In the background the shield stayed away for PiP; now it covers the app switcher.
        if UIApplication.shared.applicationState == .background { PrivacyShield.shared.show() }
    }

    /// 锁定: nothing of the vault may stay floating over the decoy or come back onto it. Picture in
    /// Picture closes as if with its X, which ends its playback, and a viewer still open closes at
    /// once. Leaving the app never locks, so this is only the 锁定 buttons.
    func closeForLock() {
        MediaPlaybackController.shared.closePictureInPictureForLock()
        MediaImagePiPController.shared.closePictureInPictureForLock()
        if isViewerPresented { coordinator?.closeImmediately() }
    }

    // MARK: - Audio session

    /// Video takes over the audio; an image in PiP plays along with other apps' music. Every call
    /// stays on the main thread, and the session is only touched when something must change.
    @discardableResult
    func activateAudioSession(for use: AudioUse) -> Bool {
        deactivationGeneration += 1
        audioHolders.insert(use)
        do {
            let changed = try applyCategory(video: audioHolders.contains(.video))
            if !sessionActive || changed {
                try AVAudioSession.sharedInstance().setActive(true)
                sessionActive = true
            }
            return true
        } catch {
            return false
        }
    }

    /// Right before the app leaves the screen with a video playing: the session must be the video
    /// one (not mixing with other apps) and active, or iOS will not start PiP by itself.
    func ensureVideoAudioSession() {
        guard audioHolders.contains(.video) else { return }
        deactivationGeneration += 1
        _ = try? applyCategory(video: true)
        // Always re-asserted here: it runs once per leaving the app, and PiP depends on it.
        if (try? AVAudioSession.sharedInstance().setActive(true)) != nil {
            sessionActive = true
        }
    }

    /// Sets the video (non-mixing) or the image (mixing) category unless it is already set.
    /// Returns whether it changed.
    @discardableResult
    private func applyCategory(video: Bool) throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = video ? .moviePlayback : .default
        let mixes = session.categoryOptions.contains(.mixWithOthers)
        guard session.category != .playback || session.mode != mode || mixes == video else { return false }
        try session.setCategory(.playback, mode: mode, options: video ? [] : [.mixWithOthers])
        return true
    }

    /// Switches the session off and lets other apps' music resume.
    private func deactivateAudioSession() {
        deactivationGeneration += 1
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    /// For the PiP log, e.g. "Playback/MoviePlayback".
    var audioDescription: String {
        let session = AVAudioSession.sharedInstance()
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        return category + "/" + mode + (session.categoryOptions.contains(.mixWithOthers) ? "+混音" : "")
    }

    /// With no holder left the session goes off a second later, so moving between an image and a
    /// video, or closing and reopening the viewer, doesn't switch it off and on again. In the
    /// background it goes off at once: a suspended app would never get to it.
    func releaseAudioSession(for use: AudioUse) {
        guard audioHolders.remove(use) != nil else { return }
        if audioHolders.isEmpty {
            guard UIApplication.shared.applicationState == .active, !videoPiPActive, !imagePiPActive else {
                deactivateAudioSession()
                return
            }
            deactivationGeneration += 1
            let generation = deactivationGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.deactivationGeneration == generation, self.audioHolders.isEmpty,
                      self.sessionActive, !self.videoPiPActive, !self.imagePiPActive
                else { return }
                self.deactivateAudioSession()
            }
        } else if use == .video {
            // Only the image is left; it plays along with other apps' music again.
            _ = try? applyCategory(video: false)
        }
    }
}
