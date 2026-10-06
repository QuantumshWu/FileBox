import AVFoundation
import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Cached thumbnails. Photos are decoded directly with ImageIO (Quick Look's thumbnailer gives up on
/// some JPEGs and returns only a file icon); videos fall back to a frame from AVFoundation; anything
/// else gets Quick Look's thumbnail or file-type icon.
enum Thumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for item: FileItem, side: CGFloat = 44, scale: CGFloat) async -> UIImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(side)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let maxPixel = side * scale
        var image: UIImage?
        if item.kind == .image {
            let url = item.url
            image = await Task.detached(priority: .utility) { downsampledImage(at: url, maxPixel: maxPixel) }.value
        }
        if image == nil, item.kind == .video {
            image = await quickLookThumbnail(for: item.url, side: side, scale: scale, types: .thumbnail)
            if image == nil { image = await videoFrame(of: item.url, maxPixel: maxPixel) }
        }
        if image == nil {
            image = await quickLookThumbnail(for: item.url, side: side, scale: scale, types: .all)
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    /// A small, upright version of the photo, read without decoding the whole picture.
    static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up))),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func quickLookThumbnail(
        for url: URL,
        side: CGFloat,
        scale: CGFloat,
        types: QLThumbnailGenerator.Request.RepresentationTypes
    ) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: types
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }

    private static func videoFrame(of url: URL, maxPixel: CGFloat) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        guard let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: frame.image)
    }
}

/// Square thumbnail for a file or folder.
struct ThumbnailView: View {
    let item: FileItem
    var side: CGFloat = 44

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
                    .padding(side * 0.1)
            } else if let image {
                Image(uiImage: image)
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
        .task(id: item) {
            guard !item.isDirectory else { return }
            image = await Thumbnails.image(for: item, side: side, scale: displayScale)
        }
    }
}
