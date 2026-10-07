import AVFoundation

/// The last few opened video and audio assets, so a file is parsed once: the page's playability
/// check, the player item and the warm-up of the neighbouring files all share one `AVURLAsset`.
enum PlayerAssetCache {
    private static let cache: NSCache<NSString, AVURLAsset> = {
        let cache = NSCache<NSString, AVURLAsset>()
        cache.countLimit = 8
        return cache
    }()

    static func asset(for item: FileItem) -> AVURLAsset {
        let itemKey = key(for: item)
        if let hit = cache.object(forKey: itemKey) { return hit }
        let made = AVURLAsset(url: item.url)
        cache.setObject(made, forKey: itemKey)
        return made
    }

    /// Loads what playback needs of `items` (videos and audio only) in the background, so the
    /// next file starts quickly.
    static func warm(_ items: [FileItem]) {
        for item in items where item.kind == .video || item.kind == .audio {
            guard cache.object(forKey: key(for: item)) == nil else { continue }
            let warming = asset(for: item)
            Task(priority: .utility) {
                _ = try? await warming.load(.isPlayable, .duration, .tracks)
            }
        }
    }

    /// A file replaced at the same path gets a new asset.
    private static func key(for item: FileItem) -> NSString {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
    }
}
