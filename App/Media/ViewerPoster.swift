import AVFoundation
import UIKit

/// The frame a video starts on, at screen size, shown until the player has a picture, so opening or
/// swiping to a video never flashes black or shows another frame first. That is the first frame,
/// or the saved position when the video continues where it was left. Kept in a small cost-limited
/// cache.
@MainActor
enum ViewerPosterCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()

    /// `seconds` nil: the first frame.
    static func cached(for item: FileItem, at seconds: Double? = nil) -> UIImage? {
        cache.object(forKey: key(for: item, at: seconds))
    }

    /// The frame at `seconds` (nil: the first frame, the same as the folder's thumbnail; see
    /// `VideoFrameReader`), upright, at most the screen's pixel size.
    static func poster(for item: FileItem, at seconds: Double? = nil) async -> UIImage? {
        if let hit = cached(for: item, at: seconds) { return hit }
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
        cache.setObject(image, forKey: key(for: item, at: seconds), cost: frame.bytesPerRow * frame.height)
        return image
    }

    /// Reads the frame at `seconds` ahead of time: the video was just left there, so opening it
    /// again shows that frame at once.
    static func prepare(_ item: FileItem, at seconds: Double) {
        guard item.kind == .video, cached(for: item, at: seconds) == nil else { return }
        Task { _ = await poster(for: item, at: seconds) }
    }

    private static func key(for item: FileItem, at seconds: Double?) -> NSString {
        let file = "\(item.url.path)|\(item.modified.timeIntervalSince1970)"
        guard let seconds else { return file as NSString }
        return "\(file)|\(seconds)" as NSString
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
