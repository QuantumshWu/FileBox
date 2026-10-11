import AVFoundation

/// Reads a video's first frame, upright and at most `maximumSize`: the frame playback starts on.
/// List and grid thumbnails and the viewer's poster all come from here, so opening a video never
/// swaps one picture for another.
///
/// The frame at 0 is read exactly, even between keyframes: a copy trimmed without re-encoding
/// starts there, and a quicker read could land on a keyframe that was cut away. Should a file have
/// no frame at exactly 0 (its first one stamped a little later), the nearest frame is read instead.
final class VideoFirstFrame: @unchecked Sendable {
    private let exact: AVAssetImageGenerator
    private let nearest: AVAssetImageGenerator
    private let lock = NSLock()
    private var cancelled = false

    init(asset: AVAsset, maximumSize: CGSize) {
        exact = Self.generator(for: asset, maximumSize: maximumSize)
        exact.requestedTimeToleranceBefore = .zero
        exact.requestedTimeToleranceAfter = .zero
        nearest = Self.generator(for: asset, maximumSize: maximumSize)
    }

    /// Calls `completion` exactly once, on any thread; nil when there is no frame or after `cancel`.
    /// The reader stays alive until then.
    func start(_ completion: @escaping (CGImage?) -> Void) {
        exact.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            if let image { return completion(image) }
            if self.isCancelled { return completion(nil) }
            self.nearest.generateCGImageAsynchronously(for: .zero) { image, _, _ in
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
