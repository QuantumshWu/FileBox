import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Cached Quick Look thumbnails (photos, video frames, PDF pages, file-type icons).
enum Thumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for item: FileItem, side: CGFloat = 44, scale: CGFloat) async -> UIImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(side)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .all
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        cache.setObject(representation.uiImage, forKey: key)
        return representation.uiImage
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
