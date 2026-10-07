import AVFoundation
import UIKit

/// The first frame of a video at screen size, shown until the player has a picture, so opening or
/// swiping to a video never flashes black. Kept in a small cost-limited cache.
@MainActor
enum ViewerPosterCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()

    static func cached(for item: FileItem) -> UIImage? {
        cache.object(forKey: key(for: item))
    }

    /// The frame at 0 s (the one playback starts on), upright, at most the screen's pixel size.
    static func poster(for item: FileItem) async -> UIImage? {
        if let hit = cached(for: item) { return hit }
        let generator = AVAssetImageGenerator(asset: PlayerAssetCache.asset(for: item))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = screenPixelSize
        let frame: CGImage? = await withTaskCancellationHandler {
            try? await generator.image(at: .zero).image
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        guard let frame, !Task.isCancelled else { return nil }
        let image = UIImage(cgImage: frame)
        cache.setObject(image, forKey: key(for: item), cost: frame.bytesPerRow * frame.height)
        return image
    }

    private static func key(for item: FileItem) -> NSString {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
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
