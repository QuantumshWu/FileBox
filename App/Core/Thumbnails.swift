import AVFoundation
import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Cached thumbnails. Photos are decoded directly with ImageIO (Quick Look's thumbnailer gives up on
/// some JPEGs and returns only a file icon); videos fall back to a frame from AVFoundation; anything
/// else gets Quick Look's thumbnail or file-type icon.
///
/// Thumbnails come in a few pixel sizes ("buckets", measured on the short side), so list rows,
/// every grid size and previews share them and a pinch does not decode anything again. They stay in
/// `VaultThumbCache` and are made by `VaultThumbScheduler`, newest request first.
enum Thumbnails {
    private static let cache = VaultThumbCache.shared
    private static let scheduler = VaultThumbScheduler.shared

    /// The pixel size made for a square of `side` points: 256 for list rows, previews and small
    /// grid cells, 512 for big cells, anything larger (the viewer) in steps of 256.
    static func bucket(side: CGFloat, scale: CGFloat) -> Int {
        let pixels = side * scale
        guard pixels.isFinite else { return 512 }
        if pixels <= 256 { return 256 }
        if pixels <= 512 { return 512 }
        return Int((pixels / 256).rounded(.up)) * 256
    }

    /// Names a file version and bucket, e.g. for `.task(id:)`.
    static func key(for item: FileItem, side: CGFloat, scale: CGFloat) -> String {
        key(fileKey(item), bucket(side: side, scale: scale))
    }

    static func image(for item: FileItem, side: CGFloat = 44, scale: CGFloat) async -> UIImage? {
        let size = bucket(side: side, scale: scale)
        let file = fileKey(item)
        let cacheKey = key(file, size)
        if let hit = cache.image(forKey: cacheKey) { return hit }
        if cache.hasFailed(cacheKey) { return nil }
        let result = await scheduler.run { job in
            Thumbnails.make(item, bucket: size, scale: scale, job: job)
        }
        if let result {
            cache.insert(result, forKey: cacheKey, file: file, bucket: size)
            return result.image
        }
        // A cancelled request says nothing about the file.
        if !Task.isCancelled { cache.markFailed(cacheKey) }
        return nil
    }

    /// The thumbnail for this size if it is in memory, else another size of the same file version,
    /// else nil. Instant, so the first frame of a cell can already show it.
    static func cached(for item: FileItem, side: CGFloat, scale: CGFloat) -> UIImage? {
        guard !item.isDirectory else { return nil }
        let file = fileKey(item)
        let size = bucket(side: side, scale: scale)
        return cache.image(forKey: key(file, size)) ?? cache.closestVariant(file: file, bucket: size)
    }

    /// Only the thumbnail for exactly this size, if it is in memory.
    static func exactCached(for item: FileItem, side: CGFloat, scale: CGFloat) -> UIImage? {
        guard !item.isDirectory else { return nil }
        return cache.image(forKey: key(for: item, side: side, scale: scale))
    }

    /// The biggest real thumbnail of this file version in memory (a photo, or a frame of a video;
    /// never a file-type icon), else nil. Instant and safe on any thread, so the viewer can show it
    /// while the full picture is still loading.
    static func cachedPlaceholder(for item: FileItem) -> UIImage? {
        guard !item.isDirectory else { return nil }
        return cache.largestReal(file: fileKey(item))
    }

    /// A small, upright version of the photo, read without decoding the whole picture.
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func fileKey(_ item: FileItem) -> String {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)"
    }

    private static func key(_ file: String, _ bucket: Int) -> String {
        "\(file)|\(bucket)"
    }

    // MARK: - Making thumbnails

    /// Runs on the scheduler's queue and finishes `job` exactly once.
    private static func make(_ item: FileItem, bucket: Int, scale: CGFloat, job: VaultThumbJob) {
        let url = item.url
        // Quick Look and AVFoundation fit the picture inside a square. Twice the bucket keeps the
        // short side of a cropped video big enough up to 2:1.
        let box = CGFloat(bucket <= 512 ? bucket * 2 : bucket)
        let isMedia = item.kind == .image || item.kind == .video
        func quickLookAll() {
            Thumbnails.quickLook(url, box: box, scale: scale, types: .all, job: job) { image, type in
                job.finish(image.map { VaultThumbResult(image: $0, isReal: isMedia && type == .thumbnail) })
            }
        }
        switch item.kind {
        case .image:
            if job.isCancelled { return job.finish(nil) }
            if let image = photoThumbnail(at: url, bucket: bucket) {
                return job.finish(VaultThumbResult(image: image, isReal: true))
            }
            quickLookAll()
        case .video:
            Thumbnails.quickLook(url, box: box, scale: scale, types: .thumbnail, job: job) { image, _ in
                if let image { return job.finish(VaultThumbResult(image: image, isReal: true)) }
                if job.isCancelled { return job.finish(nil) }
                Thumbnails.videoFrame(of: url, maxPixel: box, job: job) { frame in
                    if let frame { return job.finish(VaultThumbResult(image: frame, isReal: true)) }
                    if job.isCancelled { return job.finish(nil) }
                    quickLookAll()
                }
            }
        case .folder, .audio, .other:
            quickLookAll()
        }
    }

    /// A photo's thumbnail whose short side reaches `bucket` pixels (a panorama's long side stops
    /// at three times that), read without decoding the whole picture.
    private static func photoThumbnail(at url: URL, bucket: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        var maxPixel = CGFloat(bucket * 2)
        // Only the ratio of the sides matters here, so the EXIF orientation can be ignored.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            let long = CGFloat(max(width, height))
            let short = CGFloat(min(width, height))
            maxPixel = min(CGFloat(bucket) * min(long / short, 3), long)
        }
        return thumbnail(from: source, maxPixel: maxPixel)
    }

    private static func thumbnail(from source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up))),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Quick Look's thumbnail (or, with `.all`, possibly the file-type icon) inside a square of
    /// `box` pixels.
    private static func quickLook(
        _ url: URL,
        box: CGFloat,
        scale: CGFloat,
        types: QLThumbnailGenerator.Request.RepresentationTypes,
        job: VaultThumbJob,
        completion: @escaping (UIImage?, QLThumbnailRepresentation.RepresentationType?) -> Void
    ) {
        let scale = max(scale, 1)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: box / scale, height: box / scale),
            scale: scale,
            representationTypes: types
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.uiImage, representation?.type)
        }
        job.onCancel { QLThumbnailGenerator.shared.cancel(request) }
    }

    /// The frame at one second, inside a square of `maxPixel` pixels.
    private static func videoFrame(of url: URL, maxPixel: CGFloat, job: VaultThumbJob, completion: @escaping (UIImage?) -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: 1, preferredTimescale: 600)) { image, _, _ in
            // Keeps the generator alive until it is done.
            withExtendedLifetime(generator) {}
            completion(image.map { UIImage(cgImage: $0) })
        }
        job.onCancel { generator.cancelAllCGImageGeneration() }
    }
}

/// Square thumbnail for a file or folder.
struct ThumbnailView: View {
    let item: FileItem
    var side: CGFloat = 44

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        // Whatever is already in memory shows in the very first frame.
        let shown: UIImage? = item.isDirectory ? nil : (image ?? Thumbnails.cached(for: item, side: side, scale: displayScale))
        Group {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
                    .padding(side * 0.1)
            } else if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(side * 0.18)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.14))
        .task(id: Thumbnails.key(for: item, side: side, scale: displayScale)) {
            guard !item.isDirectory else { return }
            if let hit = Thumbnails.exactCached(for: item, side: side, scale: displayScale) {
                image = hit
                return
            }
            let loaded = await Thumbnails.image(for: item, side: side, scale: displayScale)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
