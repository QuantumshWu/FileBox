import AVFoundation
import Combine
import ImageIO
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

    private var videoKeepsAlive = false
    private var videoPiPActive = false
    private var imageKeepsAlive = false
    private var imagePiPActive = false
    private var audioHolders: Set<AudioUse> = []
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundCheckID = UUID()
    private var appObservers: Set<AnyCancellable> = []

    var isViewerPresented: Bool { presentedToken != nil }
    var isVideoPictureInPictureActive: Bool { videoPiPActive }
    var isImagePictureInPictureActive: Bool { imagePiPActive }

    private init() {
        let center = NotificationCenter.default
        center.publisher(for: UIApplication.didEnterBackgroundNotification)
            // After the video's own sound-only fallback (3 s) has decided.
            .sink { [weak self] _ in self?.checkInBackground(after: 3.5) }
            .store(in: &appObservers)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.backgroundCheckID = UUID()
                self?.endBackgroundTime()
            }
            .store(in: &appObservers)
    }

    // MARK: - Viewer

    func viewerAppeared(token: UUID, items: [FileItem], coordinator: ViewerCoordinator) {
        presentedToken = token
        presentedURLs = items.map(\.url)
        if self.coordinator !== coordinator {
            self.coordinator = coordinator
            // Closing the viewer (button, or the app going to the background) clears the request.
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
        if let request = coordinator?.request, request.items.map(\.url) == presentedURLs { return }
        closePresentedViewer()
    }

    private func requestChanged(_ request: ViewerRequest?) {
        guard presentedToken != nil, request?.items.map(\.url) != presentedURLs else { return }
        closePresentedViewer()
    }

    private func closePresentedViewer() {
        presentedToken = nil
        presentedURLs = nil
        publish()
        MediaPlaybackController.shared.viewerClosed()
        MediaImagePiPController.shared.viewerClosed()
    }

    /// Moves the viewer to `items[index]`. If another folder (or nothing) is on screen, `reopen`
    /// presents the viewer again.
    func reveal(_ items: [FileItem], at index: Int, reopen: Bool) {
        guard items.indices.contains(index) else { return }
        let urls = items.map(\.url)
        if presentedURLs == urls {
            pageRequest = PageRequest(urls: urls, index: index)
        } else if reopen {
            coordinator?.open(items, at: index)
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

    /// While the viewer is open and something plays or PiP is active or armed, backgrounding must
    /// neither close the viewer nor cover it with the privacy shield (which would stop PiP from
    /// starting). A closed viewer leaves nothing to keep: PiP floats on by itself.
    private func publish() {
        let state = PlaybackState.shared
        let pip = videoPiPActive || imagePiPActive
        let keeps = isViewerPresented && (pip || videoKeepsAlive || imageKeepsAlive)
        if state.keepsViewerInBackground != keeps { state.keepsViewerInBackground = keeps }
        if state.isPictureInPictureActive != pip { state.isPictureInPictureActive = pip }
    }

    /// The viewer stayed open when the app left the screen because PiP was armed or something
    /// played. If after `seconds` nothing plays or floats any more (PiP did not start, or its window
    /// was closed), the viewer closes and the privacy shield goes up, as for any other screen.
    func checkInBackground(after seconds: Double) {
        guard UIApplication.shared.applicationState == .background, isViewerPresented else { return }
        beginBackgroundTime()
        let id = UUID()
        backgroundCheckID = id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.backgroundCheckID == id else { return }
            self.closeIfIdleInBackground()
            self.endBackgroundTime()
        }
    }

    /// FileBox came back to the screen while something floats: end the floating window and show
    /// it in the viewer again.
    func endPictureInPictureForReturn() {
        MediaPlaybackController.shared.endPictureInPictureForReturn()
        MediaImagePiPController.shared.endPictureInPictureForReturn()
    }

    /// PiP was closed with its X while the app is locked (it locks whenever it leaves the screen;
    /// iOS may deliver this only once the user is back): close the viewer at once, without the
    /// closing animation, so only the locked screen is ever seen.
    func closeViewerAfterPictureInPicture() {
        guard isViewerPresented else { return }
        backgroundCheckID = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { coordinator?.close() }
        if UIApplication.shared.applicationState != .active { PrivacyShield.shared.show() }
    }

    private func closeIfIdleInBackground() {
        let playback = MediaPlaybackController.shared
        let image = MediaImagePiPController.shared
        guard UIApplication.shared.applicationState == .background, isViewerPresented,
              !playback.isPlaying, !playback.isPictureInPictureEngaged, !image.isEngaged
        else { return }
        coordinator?.close()
        PrivacyShield.shared.show()
    }

    /// Keeps the app running for the check above; without sound playing it would be suspended.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaViewerCheck") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Audio session

    /// Video takes over the audio; an image in PiP plays along with other apps' music.
    @discardableResult
    func activateAudioSession(for use: AudioUse) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let alreadyActive = !audioHolders.isEmpty
        let needsVideoCategory = use == .video && !audioHolders.contains(.video)
        audioHolders.insert(use)
        do {
            if needsVideoCategory {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
            } else if !alreadyActive {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            if needsVideoCategory || !alreadyActive {
                try session.setActive(true)
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
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback || session.mode != .moviePlayback || session.categoryOptions.contains(.mixWithOthers) {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        }
        try? session.setActive(true)
    }

    /// For the PiP log, e.g. "Playback/MoviePlayback".
    var audioDescription: String {
        let session = AVAudioSession.sharedInstance()
        let category = session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")
        let mode = session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")
        return category + "/" + mode + (session.categoryOptions.contains(.mixWithOthers) ? "+混音" : "")
    }

    func releaseAudioSession(for use: AudioUse) {
        guard audioHolders.remove(use) != nil else { return }
        let session = AVAudioSession.sharedInstance()
        if audioHolders.isEmpty {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        } else if use == .video {
            // Only the image is left; it plays along with other apps' music again.
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }
}

/// Decodes images at a bounded size, off the main thread, so huge photos don't exhaust memory.
enum MediaImageLoader {
    /// The last few decoded pages, so swiping back does not decode again.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    private static let gate = MediaDecodeGate()

    static func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(Int(maxPixel))|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image: UIImage? = await limited {
            MediaImageLoader.decode(url, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
        }
        if let image, let cgImage = image.cgImage {
            cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        }
        return image
    }

    /// Runs `work` off the main thread, at most two at a time: decoding a big HEIC can take a few
    /// hundred MB, and flicking through a folder must not start one per page. Returns nil without
    /// running `work` if the calling task was cancelled while it waited (its page went away).
    static func limited<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        await gate.enter()
        let result: T?
        if Task.isCancelled {
            result = nil
        } else {
            result = await Task.detached(priority: .userInitiated) { work() }.value
        }
        await gate.leave()
        return result
    }

    /// The image (orientation applied) with its longer side at most `maxPixel` pixels.
    static func decode(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A two-slot queue (first come, first served) for `MediaImageLoader.limited`.
private actor MediaDecodeGate {
    private let slots = 2
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if running < slots {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// Hands the slot straight to the next waiter, if any.
    func leave() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
