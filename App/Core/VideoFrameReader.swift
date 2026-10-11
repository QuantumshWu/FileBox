import AVFoundation

/// Reads one frame of a video, upright and at most `maximumSize`. List and grid thumbnails and the
/// viewer's poster all come from here, so opening a video never swaps one picture for another:
/// thumbnails show the first frame; the viewer shows the frame playback starts on, which is the
/// saved position when the video continues where it was left.
///
/// The frame is read exactly, even between keyframes: playback seeks there exactly, and a copy
/// trimmed without re-encoding starts there, where a quicker read could land on a keyframe that was
/// cut away. Should a file have no frame at exactly that time (a first frame stamped a little after
/// 0), the nearest frame is read instead.
final class VideoFrameReader: @unchecked Sendable {
    private let exact: AVAssetImageGenerator
    private let nearest: AVAssetImageGenerator
    private let time: CMTime
    private let lock = NSLock()
    private var cancelled = false

    /// `seconds` nil: the first frame. Otherwise the same time the player seeks to.
    init(asset: AVAsset, at seconds: Double? = nil, maximumSize: CGSize) {
        time = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .zero
        exact = Self.generator(for: asset, maximumSize: maximumSize)
        exact.requestedTimeToleranceBefore = .zero
        exact.requestedTimeToleranceAfter = .zero
        nearest = Self.generator(for: asset, maximumSize: maximumSize)
    }

    /// Calls `completion` exactly once, on any thread; nil when there is no frame or after `cancel`.
    /// The reader stays alive until then.
    func start(_ completion: @escaping (CGImage?) -> Void) {
        // Already given up on (a page swiped past at once): nothing is decoded.
        if isCancelled { return completion(nil) }
        let time = time
        exact.generateCGImageAsynchronously(for: time) { image, _, _ in
            if let image { return completion(image) }
            if self.isCancelled { return completion(nil) }
            self.nearest.generateCGImageAsynchronously(for: time) { image, _, _ in
                completion(self.isCancelled ? nil : image)
            }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        exact.cancelAllCGImageGeneration()
        nearest.cancelAllCGImageGeneration()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func generator(for asset: AVAsset, maximumSize: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        return generator
    }
}
