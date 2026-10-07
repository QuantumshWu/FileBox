import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import UIKit

/// Shows the viewer's current image in a Picture in Picture window, like a paused video: the image
/// is drawn into a pixel buffer and fed to an `AVSampleBufferDisplayLayer` that sits (covered) behind
/// the viewer's pages. PiP starts by itself when the app leaves the screen on an image page; its skip
/// buttons go to the previous / next image and play runs a slideshow.
@MainActor
final class MediaImagePiPController: NSObject, ObservableObject {
    static let shared = MediaImagePiPController()

    /// Seconds per image in the slideshow (and per image on the PiP time line).
    static let slideInterval: Double = 3

    @Published private(set) var isActive = false
    @Published private(set) var isSlideshowRunning = false

    /// The layer PiP takes its picture from. The viewer hosts it; while PiP floats with the viewer
    /// closed it is parked at the back of the app's window.
    let layerView = MediaSampleBufferView()

    private(set) var sessionItems: [FileItem] = []

    /// PiP is showing an image or about to.
    var isEngaged: Bool { isActive || isStarting }

    private var currentIndex: Int?
    /// The image the PiP picture is (being) made of.
    private var renderedURL: URL?
    /// Set while the picture of `renderedURL` is still being made.
    private var renderingURL: URL?
    private var onImagePage = false
    private var isStarting = false
    private var isPossible = false
    private var startWhenPossible = false
    private var startToken = UUID()
    private var holdsAudio = false
    private var controller: AVPictureInPictureController?
    private var frame: MediaPiPFrame?
    private var timebase: CMTimebase?
    private var renderTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var slideshowTimer: Timer?
    private var pendingRestore: ((Bool) -> Void)?
    /// The coming stop is not the user closing PiP with its X: PiP goes back into the viewer (its
    /// restore button, the app coming back) or the viewer ends it (its button, a video page).
    private var stopKeepsViewer = false
    private var restoreID = UUID()
    private var reportedPaused: Bool?
    private var reportedCount = 0
    private var observers: Set<AnyCancellable> = []
    private var possibleCancellable: AnyCancellable?
    nonisolated private let snapshot = MediaPiPSnapshot()

    private override init() {
        super.init()
        layerView.isUserInteractionEnabled = false
        layerView.backgroundColor = .black
        let layer = layerView.displayLayer
        layer.videoGravity = .resizeAspect
        var newTimebase: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &newTimebase) == noErr,
           let newTimebase {
            CMTimebaseSetTime(newTimebase, time: .zero)
            CMTimebaseSetRate(newTimebase, rate: 0)
            layer.controlTimebase = newTimebase
            timebase = newTimebase
        }
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.enqueueFrame() }
                .store(in: &observers)
        }
        center.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.willResignActive() }
            .store(in: &observers)
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.catchUpOnClosedPictureInPicture() }
            .store(in: &observers)
    }

    // MARK: - Viewer

    /// The viewer shows `items[index]`, an image.
    func show(_ items: [FileItem], at index: Int) {
        guard items.indices.contains(index), items[index].kind == .image else { return }
        sessionItems = items
        onImagePage = true
        setCurrent(index)
        updateArming()
    }

    /// The viewer moved to a video, audio or other file: a floating image gives way to it.
    func leaveImagePage() {
        onImagePage = false
        startWhenPossible = false
        if isActive || isStarting { stopKeepingViewer() }
        updateArming()
    }

    /// The viewer closed: a floating image stays, otherwise everything is released.
    func viewerClosed() {
        onImagePage = false
        if isActive || isStarting {
            parkLayer()
            updateArming()
        } else {
            teardown()
        }
    }

    /// Video PiP started or stopped; only one of the two may be armed.
    func videoPictureInPictureChanged() {
        updateArming()
    }

    /// FileBox is back on screen while the image floats: it goes back into the viewer.
    func endPictureInPictureForReturn() {
        catchUpOnClosedPictureInPicture()
        guard isActive, !stopKeepsViewer, let controller, controller.isPictureInPictureActive else { return }
        stopKeepsViewer = true
        controller.stopPictureInPicture()
    }

    /// The window was closed with its X while the app was away, and iOS may tell only some time
    /// after the app is back: as soon as AVKit's own state shows it, the viewer closes, before it
    /// is seen again. The late report then finds nothing left to do.
    private func catchUpOnClosedPictureInPicture() {
        guard isActive, !stopKeepsViewer, pendingRestore == nil, let controller,
              !controller.isPictureInPictureActive
        else { return }
        MediaDiagnostics.log("图片小窗已在 App 外关闭")
        pictureInPictureDidStop()
    }

    /// The manual PiP button.
    func toggle() {
        if isActive || isStarting {
            stopKeepingViewer()
            return
        }
        let hub = MediaViewerHub.shared
        if hub.isVideoPictureInPictureActive {
            hub.show("请先关闭视频小窗")
            return
        }
        let current = frame != nil && frame?.url == renderedURL
        if !current, let index = currentIndex, sessionItems.indices.contains(index) {
            // The picture of this page is not made yet (it waits for paging to settle): make it now.
            renderedURL = sessionItems[index].url
            render(sessionItems[index], immediate: true)
        }
        guard let pip = makeControllerIfNeeded() else {
            hub.show("小窗暂时无法开启")
            return
        }
        holdAudio()
        if current && pip.isPictureInPicturePossible {
            pip.startPictureInPicture()
            return
        }
        // The picture is still being made, or the layer has just entered the window: start as
        // soon as both are ready.
        startWhenPossible = true
        let token = UUID()
        startToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.startToken == token, self.startWhenPossible else { return }
            self.startWhenPossible = false
            self.updateArming()
            MediaViewerHub.shared.show("小窗暂时无法开启")
        }
    }

    /// The viewer's backdrop took the layer (see `MediaImagePiPLayerHost`).
    func attachLayer(to host: UIView) {
        if layerView.superview !== host {
            layerView.removeFromSuperview()
            layerView.frame = host.bounds
            layerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(layerView)
        }
        enqueueFrame()
        guard pendingRestore != nil else { return }
        let id = restoreID
        Task { [weak self] in
            // Let the viewer settle on the page first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.restoreID == id else { return }
            self.finishRestore(true)
        }
    }

    // MARK: - Pictures

    /// `immediate` skips the settle delay: PiP skip buttons and the slideshow, or PiP showing.
    private func setCurrent(_ index: Int, immediate: Bool = false) {
        currentIndex = index
        updateTimebase()
        let item = sessionItems[index]
        guard item.url != renderedURL else { return }
        renderedURL = item.url
        render(item, immediate: immediate || isEngaged)
    }

    /// Makes the PiP picture of `item`. While paging it waits for the page to settle and then
    /// reuses the page's own decode. The previous picture stays armed until the new one lands, so
    /// paging never releases the PiP controller and its audio session.
    private func render(_ item: FileItem, immediate: Bool) {
        let url = item.url
        renderTask?.cancel()
        renderingURL = url
        renderTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            let made = await MediaImagePiPController.makeFrame(for: item)
            guard let self, !Task.isCancelled, self.renderedURL == url else { return }
            self.renderingURL = nil
            guard let made else {
                // Never float the previous picture under this one's name.
                self.frame = nil
                self.layerView.displayLayer.flushAndRemoveImage()
                if self.isActive || self.startWhenPossible {
                    self.startWhenPossible = false
                    MediaViewerHub.shared.show("这张图片无法在小窗里显示")
                }
                self.updateArming()
                return
            }
            self.frame = made
            self.enqueueFrame()
            self.updateArming()
            self.startIfWaiting()
        }
    }

    /// From the decode the viewer's page uses (joining it while it runs), so a photo is read from
    /// disk once; decoded on its own only when the viewer is closed (slideshow in PiP).
    private static func makeFrame(for item: FileItem) async -> MediaPiPFrame? {
        let url = item.url
        if MediaViewerHub.shared.isViewerPresented {
            let image = await MediaImageLoader.load(item, maxPixel: MediaImageLoader.displayMaxPixel, priority: .background)
            if Task.isCancelled { return nil }
            if let cgImage = image?.cgImage {
                let made = await Task.detached(priority: .utility) { MediaPiPFrame.make(from: cgImage, url: url) }.value
                if made != nil || Task.isCancelled { return made }
            }
        }
        if Task.isCancelled { return nil }
        return await MediaImageLoader.limited(priority: .background) { MediaPiPFrame.make(from: url) }
    }

    /// Leaving the app right after paging: the new picture is made at once, so automatic PiP
    /// does not show the previous one for long.
    private func willResignActive() {
        guard let url = renderingURL, frame?.url != url, let index = currentIndex,
              sessionItems.indices.contains(index), sessionItems[index].url == url
        else { return }
        render(sessionItems[index], immediate: true)
    }

    /// The manual button asked for PiP before the picture or the controller was ready.
    private func startIfWaiting() {
        guard startWhenPossible, isPossible, let frame, frame.url == renderedURL, let controller else { return }
        startWhenPossible = false
        controller.startPictureInPicture()
    }

    /// Hands the current picture to the layer again. Called periodically, because the layer may
    /// drop its picture (for example when the app goes to the background) and PiP would turn black.
    private func enqueueFrame() {
        guard let frame else { return }
        let layer = layerView.displayLayer
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        let now = timebase.map { CMTimebaseGetTime($0) } ?? .zero
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: frame.format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample
        else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        layer.enqueue(sample)
    }

    /// Next (`direction` 1) or previous (-1) image of the folder, wrapping around.
    private func step(_ direction: Int) {
        guard let start = currentIndex, !sessionItems.isEmpty else { return }
        let count = sessionItems.count
        var index = start
        for _ in 0..<count {
            index = ((index + direction) % count + count) % count
            if index == start { return }
            if sessionItems[index].kind == .image { break }
        }
        guard index != start, sessionItems[index].kind == .image else { return }
        setCurrent(index, immediate: true)
        MediaViewerHub.shared.reveal(sessionItems, at: index, reopen: false)
    }

    private func setSlideshow(_ running: Bool) {
        if running != isSlideshowRunning {
            isSlideshowRunning = running
            slideshowTimer?.invalidate()
            slideshowTimer = nil
            if running {
                let timer = Timer(timeInterval: Self.slideInterval, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in self.step(1) }
                }
                RunLoop.main.add(timer, forMode: .common)
                slideshowTimer = timer
            }
            updateTimebase()
        }
        updatePlaybackState()
    }

    /// The PiP time line shows where the image is in the folder.
    private func updateTimebase() {
        guard let timebase else { return }
        let position = Double(currentIndex ?? 0) * Self.slideInterval
        CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 600))
        CMTimebaseSetRate(timebase, rate: isSlideshowRunning ? 1 : 0)
    }

    /// Inline the content counts as playing, so that PiP may start automatically; in the window
    /// play / pause is the slideshow.
    private func updatePlaybackState() {
        let paused = (isActive || isStarting) ? !isSlideshowRunning : !onImagePage
        let count = max(1, sessionItems.count)
        guard paused != reportedPaused || count != reportedCount else { return }
        reportedPaused = paused
        reportedCount = count
        let duration = CMTime(seconds: Double(count) * Self.slideInterval, preferredTimescale: 600)
        snapshot.set(paused: paused, range: CMTimeRange(start: .zero, duration: duration))
        controller?.invalidatePlaybackState()
    }

    // MARK: - Arming

    @discardableResult
    private func makeControllerIfNeeded() -> AVPictureInPictureController? {
        if let controller { return controller }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        updatePlaybackState()
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layerView.displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.delegate = self
        possibleCancellable = pip.publisher(for: \.isPictureInPicturePossible, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in self?.possibleChanged(possible) }
        controller = pip
        return pip
    }

    private func possibleChanged(_ possible: Bool) {
        isPossible = possible
        startIfWaiting()
        updateArming()
    }

    /// Arms automatic PiP while the viewer shows an image (and no video floats), and tells the app
    /// shell whether the viewer must survive going to the background.
    private func updateArming() {
        let hub = MediaViewerHub.shared
        let floating = isActive || isStarting
        let armed = onImagePage && hub.isViewerPresented && !hub.isVideoPictureInPictureActive && frame != nil
        if armed {
            holdAudio()
            makeControllerIfNeeded()
        }
        if let controller, controller.canStartPictureInPictureAutomaticallyFromInline != armed {
            controller.canStartPictureInPictureAutomaticallyFromInline = armed
        }
        if !armed && !floating && !startWhenPossible {
            // Off image pages there is only the video's PiP controller; this one is made again on
            // the next image page.
            releaseController()
        }
        updatePlaybackState()
        setRefreshing(armed || floating)
        hub.setImageState(keepsAlive: (armed && isPossible) || floating, pictureInPicture: isActive)
    }

    private func releaseController() {
        guard let controller else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.delegate = nil
        self.controller = nil
        possibleCancellable = nil
        isPossible = false
        if holdsAudio {
            holdsAudio = false
            MediaViewerHub.shared.releaseAudioSession(for: .image)
        }
    }

    private func setRefreshing(_ on: Bool) {
        guard on != (refreshTimer != nil) else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.enqueueFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// PiP needs a playback audio session; mixing keeps other apps' music playing.
    private func holdAudio() {
        guard !holdsAudio else { return }
        holdsAudio = MediaViewerHub.shared.activateAudioSession(for: .image)
    }

    /// Keeps the layer in the window while PiP floats without the viewer.
    private func parkLayer() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { $0.windowLevel == .normal }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        layerView.removeFromSuperview()
        layerView.frame = window.bounds
        layerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.insertSubview(layerView, at: 0)
        enqueueFrame()
    }

    private func teardown() {
        startWhenPossible = false
        setSlideshow(false)
        renderTask?.cancel()
        renderTask = nil
        frame = nil
        renderedURL = nil
        renderingURL = nil
        currentIndex = nil
        sessionItems = []
        onImagePage = false
        finishRestore(false)
        layerView.displayLayer.flushAndRemoveImage()
        if !(layerView.superview is MediaImagePiPHostView) {
            layerView.removeFromSuperview()
        }
        holdsAudio = false
        MediaViewerHub.shared.releaseAudioSession(for: .image)
        updateArming()
    }

    /// Ends PiP for a reason of the viewer's own; the viewer stays.
    private func stopKeepingViewer() {
        guard let controller else { return }
        stopKeepsViewer = true
        controller.stopPictureInPicture()
    }

    // MARK: - Picture in Picture events

    private func pictureInPictureWillStart() {
        // A new window: no stop of an earlier one is still on its way.
        stopKeepsViewer = false
        isStarting = true
        startWhenPossible = false
        updateArming()
    }

    private func pictureInPictureDidStart() {
        MediaDiagnostics.log("图片小窗已开启")
        if frame?.url != renderedURL { MediaDiagnostics.log("小窗显示的是上一张图片") }
        isStarting = false
        isActive = true
        updateArming()
        enqueueFrame()
    }

    private func pictureInPictureFailed() {
        MediaDiagnostics.log("图片小窗开启失败")
        stopKeepsViewer = false
        isStarting = false
        isActive = false
        MediaViewerHub.shared.show("小窗暂时无法开启")
        if MediaViewerHub.shared.isViewerPresented { updateArming() } else { teardown() }
    }

    private func pictureInPictureDidStop() {
        // Already handled (see `catchUpOnClosedPictureInPicture`).
        guard isActive || isStarting || stopKeepsViewer else { return }
        let keepsViewer = stopKeepsViewer
        MediaDiagnostics.log(keepsViewer ? "图片小窗回到全屏" : "图片小窗已关闭")
        stopKeepsViewer = false
        isStarting = false
        isActive = false
        setSlideshow(false)
        finishRestore(false)
        let hub = MediaViewerHub.shared
        let urls = sessionItems.map(\.url)
        if !keepsViewer {
            // Closed with its X: the viewer it floated from closes at once, so coming back shows
            // the page the viewer was opened from.
            teardown()
            hub.closeViewerAfterPictureInPicture(of: urls)
            return
        }
        if hub.isViewerPresented {
            updateArming()
        } else {
            // Back from PiP, but the viewer could not take it: nothing is left to show.
            teardown()
        }
    }

    /// Brings the viewer back on the floating image (reopening it if it was closed) before PiP
    /// animates into it.
    private func restoreUserInterface(_ completion: @escaping (Bool) -> Void) {
        stopKeepsViewer = true
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
        if hub.presentedURLs == sessionItems.map(\.url), let host = layerView.superview as? MediaImagePiPHostView {
            attachLayer(to: host)
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.restoreID == id else { return }
            self.finishRestore(self.layerView.superview is MediaImagePiPHostView)
        }
    }

    private func finishRestore(_ restored: Bool) {
        let completion = pendingRestore
        pendingRestore = nil
        restoreID = UUID()
        completion?(restored)
    }
}

extension MediaImagePiPController: AVPictureInPictureControllerDelegate {
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
        Task { @MainActor in self.pictureInPictureFailed() }
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

extension MediaImagePiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.setSlideshow(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        snapshot.timeRange
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        snapshot.isPaused
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        let direction = CMTimeGetSeconds(skipInterval) < 0 ? -1 : 1
        Task { @MainActor in self.step(direction) }
        completionHandler()
    }
}

/// A view whose backing layer is an `AVSampleBufferDisplayLayer`.
final class MediaSampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // layerClass guarantees the type.
        layer as! AVSampleBufferDisplayLayer
    }
}

/// Full-screen backdrop of the viewer that holds the image PiP layer, covered by the pages.
final class MediaImagePiPHostView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { MediaImagePiPController.shared.attachLayer(to: self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews { subview.frame = bounds }
    }
}

/// Answers for the PiP playback delegate, which AVKit may ask on any thread.
private final class MediaPiPSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var range = CMTimeRange(start: .zero, duration: CMTime(value: 3, timescale: 1))

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    var timeRange: CMTimeRange {
        lock.lock()
        defer { lock.unlock() }
        return range
    }

    func set(paused: Bool, range: CMTimeRange) {
        lock.lock()
        self.paused = paused
        self.range = range
        lock.unlock()
    }
}

/// One image drawn into a pixel buffer for the display layer.
private struct MediaPiPFrame: @unchecked Sendable {
    /// The file the picture shows.
    let url: URL
    let pixelBuffer: CVPixelBuffer
    let format: CMVideoFormatDescription

    /// The image at `url`, decoded on its own.
    static func make(from url: URL) -> MediaPiPFrame? {
        guard let image = MediaImageLoader.decode(url, maxPixel: 1920) else { return nil }
        return make(from: image, url: url)
    }

    /// `image` scaled to fit 1920×1080 (either way round), keeping its aspect ratio.
    static func make(from image: CGImage, url: URL) -> MediaPiPFrame? {
        guard image.width > 0, image.height > 0 else { return nil }
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let scale = min(1, 1920 / max(sourceWidth, sourceHeight), 1080 / min(sourceWidth, sourceHeight))
        let width = max(16, Int((sourceWidth * scale).rounded()) / 2 * 2)
        let height = max(16, Int((sourceHeight * scale).rounded()) / 2 * 2)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr, let format
        else { return nil }
        return MediaPiPFrame(url: url, pixelBuffer: buffer, format: format)
    }
}
