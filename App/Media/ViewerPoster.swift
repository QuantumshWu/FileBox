import AVFoundation
import UIKit

/// The frame a video starts on, at screen size, shown until the player has a picture, so opening or
/// swiping to a video never flashes black or shows another frame first. That is the first frame,
/// or the saved position when the video continues where it was left. Kept in a small cost-limited
/// cache.
@MainActor
enum ViewerPosterCache {
    private static let firstFrames: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()

    /// One frame per file: where it was last left. A newer position replaces the older one. Room
    /// for the page in the player, the file just left and both neighbours, at up to 12 MB each.
    private static let resumeFrames: NSCache<NSString, ResumeFrame> = {
        let cache = NSCache<NSString, ResumeFrame>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    /// Frames being read ahead (`prepare`), so the page waits for that read instead of making its own.
    private static var preparing: [NSString: Task<UIImage?, Never>] = [:]

    private final class ResumeFrame {
        let seconds: Double
        let image: UIImage

        init(seconds: Double, image: UIImage) {
            self.seconds = seconds
            self.image = image
        }
    }

    /// `seconds` nil: the first frame.
    static func cached(for item: FileItem, at seconds: Double? = nil) -> UIImage? {
        let file = fileKey(for: item)
        guard let seconds else { return firstFrames.object(forKey: file) }
        guard let frame = resumeFrames.object(forKey: file), frame.seconds == seconds else { return nil }
        return frame.image
    }

    /// The frame at `seconds` (nil: the first frame, the same as the folder's thumbnail; see
    /// `VideoFrameReader`), upright, at most the screen's pixel size.
    static func poster(for item: FileItem, at seconds: Double? = nil) async -> UIImage? {
        if let hit = cached(for: item, at: seconds) { return hit }
        if let pending = preparing[readKey(for: item, at: seconds)] { return await pending.value }
        return await read(item, at: seconds)
    }

    /// Reads the frame at `seconds` ahead of time: the video was just left there, so opening it
    /// again shows that frame at once.
    static func prepare(_ item: FileItem, at seconds: Double) {
        let key = readKey(for: item, at: seconds)
        guard item.kind == .video, cached(for: item, at: seconds) == nil, preparing[key] == nil else { return }
        preparing[key] = Task {
            let image = await read(item, at: seconds)
            preparing[key] = nil
            return image
        }
    }

    private static func read(_ item: FileItem, at seconds: Double?) async -> UIImage? {
        let reader = VideoFrameReader(asset: PlayerAssetCache.asset(for: item), at: seconds, maximumSize: screenPixelSize)
        let frame: CGImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                reader.start { continuation.resume(returning: $0) }
            }
        } onCancel: {
            reader.cancel()
        }
        guard let frame, !Task.isCancelled else { return nil }
        let image = UIImage(cgImage: frame)
        let cost = frame.bytesPerRow * frame.height
        if let seconds {
            resumeFrames.setObject(ResumeFrame(seconds: seconds, image: image), forKey: fileKey(for: item), cost: cost)
        } else {
            firstFrames.setObject(image, forKey: fileKey(for: item), cost: cost)
        }
        // Pages showing black while it was read ahead show it now.
        ViewerPosterUpdates.shared.revision &+= 1
        return image
    }

    private static func fileKey(for item: FileItem) -> NSString {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
    }

    private static func readKey(for item: FileItem, at seconds: Double?) -> NSString {
        let file = fileKey(for: item) as String
        return (seconds.map { "\(file)|\($0)" } ?? file) as NSString
    }

    /// The screen in pixels, upright: a landscape video fits its width, a portrait one its height.
    private static var screenPixelSize: CGSize {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        guard let screen else { return CGSize(width: 1290, height: 2796) }
        let bounds = screen.nativeBounds.size
        return CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height))
    }
}

/// Changes whenever `ViewerPosterCache` gets a new frame, so the viewer's pages redraw with it.
@MainActor
final class ViewerPosterUpdates: ObservableObject {
    static let shared = ViewerPosterUpdates()

    @Published var revision = 0

    private init() {}
}
