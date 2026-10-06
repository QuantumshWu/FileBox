import AVFoundation
import SwiftUI
import UIKit

/// Player, selection and export state of the trim editor (`VideoTrimView`).
@MainActor
final class VideoEditTrimModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    /// Length of the video in seconds.
    @Published private(set) var duration: Double = 0
    /// Selected range in seconds.
    @Published private(set) var start: Double = 0
    @Published private(set) var end: Double = 0
    /// Playhead position in seconds.
    @Published private(set) var current: Double = 0
    @Published private(set) var isPlaying = false
    /// Filmstrip thumbnails, filled in as they are generated.
    @Published private(set) var frames: [UIImage?] = []
    /// Set while exporting.
    @Published private(set) var exportProgress: Double?
    @Published var errorMessage: String?

    let item: FileItem
    let player = AVPlayer()

    static let frameCount = 10

    private var asset: AVURLAsset?
    private var assetDuration = CMTime.zero
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// False once the editor has gone, e.g. because the app locked itself in the background while
    /// an export kept running; results are then reported with a banner instead of an alert.
    private var isOnScreen = false
    private var isAdjusting = false
    private var isSeeking = false
    private var pendingSeek: Double?
    private var exportTask: Task<Void, Never>?

    init(item: FileItem) {
        self.item = item
    }

    /// Shortest selection the handles allow.
    var minimumLength: Double { min(0.3, duration / 2) }
    var selectedLength: Double { max(0, end - start) }
    var isExporting: Bool { exportProgress != nil }
    var canSave: Bool { phase == .ready && !isExporting && selectedLength >= 0.05 }

    // MARK: - Loading

    func load() async {
        isOnScreen = true
        if let asset {
            attach(asset)
            if frames.contains(where: { $0 == nil }) { await loadFrames(from: asset) }
            return
        }
        let asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let (time, playable) = try await asset.load(.duration, .isPlayable)
            guard playable else { throw VideoEditError.unplayable }
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw VideoEditError.noVideoTrack }
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 0 else { throw VideoEditError.unreadableDuration }
            self.asset = asset
            assetDuration = time
            duration = seconds
            start = 0
            end = seconds
            current = 0
            frames = Array(repeating: nil, count: Self.frameCount)
            attach(asset)
            phase = .ready
        } catch {
            if Task.isCancelled { return }
            phase = .failed(VideoEditExport.loadMessage(for: error))
            return
        }
        await loadFrames(from: asset)
    }

    private func loadFrames(from asset: AVURLAsset) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let step = duration / Double(Self.frameCount)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        for index in 0..<Self.frameCount {
            if Task.isCancelled { return }
            guard frames.indices.contains(index), frames[index] == nil else { continue }
            let time = CMTime(seconds: step * (Double(index) + 0.5), preferredTimescale: 600)
            if let result = try? await generator.image(at: time), frames.indices.contains(index) {
                frames[index] = UIImage(cgImage: result.image)
            }
        }
    }

    /// Connects the player; also used when the editor appears again after `stop()`.
    private func attach(_ asset: AVURLAsset) {
        guard player.currentItem == nil else { return }
        let playerItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: playerItem)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reachedEnd()
            }
        }
        // A phone call or another app's audio pauses the player; keep the play button in step.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated {
                self?.pause()
            }
        }
        if current > 0 { seek(to: current) }
    }

    /// Pauses and releases the player when the editor goes away. A running export continues.
    func stop() {
        isOnScreen = false
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - Playback

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Plays the selected range in a loop.
    func play() {
        guard phase == .ready, !isExporting else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if current < start || current >= end - 0.05 { seek(to: start) }
        isPlaying = true
        player.play()
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    private func tick(_ seconds: Double) {
        guard !isAdjusting, !isSeeking, seconds.isFinite else { return }
        current = seconds
        if isPlaying, seconds >= end - 0.01 { loop() }
    }

    private func reachedEnd() {
        if isPlaying { loop() }
    }

    private func loop() {
        seek(to: start)
        player.play()
    }

    /// Shows the frame at `seconds`. Seeks are coalesced so dragging stays smooth.
    private func seek(to seconds: Double) {
        current = seconds
        pendingSeek = seconds
        guard !isSeeking else { return }
        isSeeking = true
        Task { await drainSeeks() }
    }

    private func drainSeeks() async {
        while let target = pendingSeek {
            pendingSeek = nil
            _ = await player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        isSeeking = false
    }

    // MARK: - Selection

    /// Called when a handle or the filmstrip starts being dragged.
    func beginAdjusting() {
        guard !isAdjusting else { return }
        pause()
        isAdjusting = true
    }

    func endAdjusting() {
        isAdjusting = false
    }

    func setStart(_ value: Double) {
        start = max(0, min(value, end - minimumLength))
        seek(to: start)
    }

    func setEnd(_ value: Double) {
        end = min(duration, max(value, start + minimumLength))
        seek(to: end)
    }

    func scrub(to value: Double) {
        seek(to: min(max(0, value), duration))
    }

    private var selectedRange: CMTimeRange {
        let startTime = start <= 0 ? CMTime.zero : CMTime(seconds: start, preferredTimescale: 600)
        let endTime = end >= duration - 0.001 ? assetDuration : CMTime(seconds: end, preferredTimescale: 600)
        return CMTimeRange(start: startTime, end: endTime)
    }

    // MARK: - Export

    /// Exports the selection and saves it as "<name> 剪辑.mov" next to the original.
    /// `precise` re-encodes for frame-exact cuts; otherwise samples are copied (cuts snap to keyframes).
    func save(precise: Bool, to store: FileStore, onSaved: @escaping () -> Void) {
        guard canSave, let asset else { return }
        pause()
        let range = selectedRange
        let fraction = duration > 0 ? selectedLength / duration : 1
        let source = item
        exportProgress = 0
        exportTask = Task {
            var output: URL?
            do {
                let preset: String
                if precise {
                    preset = await VideoEditExport.reencodePreset(for: asset)
                } else {
                    preset = AVAssetExportPresetPassthrough
                    let compatible = await AVAssetExportSession.compatibility(
                        ofExportPreset: preset, with: asset, outputFileType: .mov
                    )
                    guard compatible else { throw VideoEditError.passthroughUnsupported }
                }
                try Task.checkCancellation()
                guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                    throw VideoEditError.exportFailed
                }
                session.timeRange = range
                try VideoEditExport.ensureFreeSpace(Int64(Double(source.size) * fraction))
                let url = try VideoEditExport.makeTemporaryURL()
                output = url
                try await VideoEditExport.run(session, to: url) { [weak self] value in
                    guard let self, self.exportTask != nil else { return }
                    self.exportProgress = value
                }
                try Task.checkCancellation()
                let name = VideoEditExport.baseName(of: source, maxBytes: 200) + " 剪辑.mov"
                let folder = source.url.deletingLastPathComponent()
                guard let saved = store.add(fileAt: url, named: name, into: folder, moving: true) else {
                    throw VideoEditError.saveFailed
                }
                VideoEditExport.discard(url)
                exportTask = nil
                exportProgress = nil
                store.show("已保存「\(saved.lastPathComponent)」")
                onSaved()
            } catch {
                if let output { VideoEditExport.discard(output) }
                exportTask = nil
                exportProgress = nil
                if Task.isCancelled { return }
                var message = VideoEditExport.message(for: error)
                // The "unsupported" message already says to use 精确.
                let alreadySaid = (error as? VideoEditError) == .passthroughUnsupported
                if !precise, !alreadySaid, VideoEditExport.shouldRetryWithReencode(error) {
                    message += "\n可以改用「精确」模式再试一次。"
                }
                if isOnScreen {
                    errorMessage = message
                } else {
                    store.show("「\(source.name)」的剪辑没有保存：\(message)")
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}
