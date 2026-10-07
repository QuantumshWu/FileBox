import AVFoundation
import ImageIO
import SwiftUI
import UIKit

// CI-ONLY stand-ins for the media-engine and file-data contracts, so the media-viewer package can
// be compile-checked on its own. This file lives only on ci/v4-media-viewer-check; never merge it.

extension MediaPlaybackController {
    var isScrubbing: Bool { false }
    var seekTarget: Double? { nil }
    var displayReadyURL: URL? { currentURL }
    var isBoosted: Bool { false }
    var isBuffering: Bool { false }
    var presentationSize: CGSize { player.currentItem?.presentationSize ?? .zero }

    var speed: Float {
        get { player.defaultRate }
        set { player.defaultRate = newValue }
    }

    @discardableResult
    func seek(by seconds: Double) -> Bool {
        guard let item = player.currentItem, item.status == .readyToPlay else { return false }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return false }
        let target = min(max(0, player.currentTime().seconds + seconds), duration - 0.1)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        return true
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func skipTrack(_ step: Int) {}

    @discardableResult
    func beginBoost() -> Bool { false }

    func endBoost() {}
}

extension MediaVideoControls {
    init(isVisible: Bool, onInteraction: @escaping () -> Void, onHoldChrome: @escaping () -> Void) {
        self.init(onInteraction: onInteraction)
    }
}

enum MediaImageLoader {
    enum Priority { case visible, background }

    static let displayMaxPixel: CGFloat = 3000

    private static let cache = NSCache<NSString, UIImage>()

    private static func key(_ item: FileItem, _ maxPixel: CGFloat) -> NSString {
        "\(Int(maxPixel))|\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
    }

    static func cachedImage(for item: FileItem, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(item, maxPixel))
    }

    @MainActor
    static func load(_ item: FileItem, maxPixel: CGFloat, priority: Priority = .visible) async -> UIImage? {
        if let hit = cachedImage(for: item, maxPixel: maxPixel) { return hit }
        let url = item.url
        let image: UIImage? = await limited { decode(url, maxPixel: maxPixel).map { UIImage(cgImage: $0) } }
        if let image { cache.setObject(image, forKey: key(item, maxPixel)) }
        return image
    }

    @MainActor
    static func prefetch(_ items: [FileItem], maxPixel: CGFloat) {}

    static func limited<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

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

@MainActor
enum PlayerAssetCache {
    static func asset(for item: FileItem) -> AVURLAsset {
        AVURLAsset(url: item.url)
    }

    static func warm(_ items: [FileItem]) {}
}

extension Thumbnails {
    static func cachedPlaceholder(for item: FileItem) -> UIImage? { nil }
}
