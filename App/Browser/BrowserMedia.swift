import ImageIO
import SwiftUI
import UIKit

/// An image, video or audio file found on the current page.
struct BrowserMediaItem: Identifiable, Hashable {
    enum Kind: String {
        case image, video, audio

        var title: String {
            switch self {
            case .image: return "图片"
            case .video: return "视频"
            case .audio: return "音频"
            }
        }

        var symbol: String {
            switch self {
            case .image: return "photo"
            case .video: return "film"
            case .audio: return "waveform"
            }
        }
    }

    let url: URL
    let kind: Kind
    let width: Int?
    let height: Int?
    let poster: URL?

    var id: URL { url }

    /// blob:/MediaSource players and HLS/DASH playlists have no single file to download.
    var isStream: Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "blob" || scheme == "mediasource" { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "mpd"
    }

    var canDownload: Bool {
        let scheme = url.scheme?.lowercased()
        return !isStream && (scheme == "http" || scheme == "https")
    }

    var thumbnailURL: URL? {
        kind == .image ? url : poster
    }

    var summary: String {
        var parts = [kind.title]
        if let width, let height { parts.append("\(width)×\(height)") }
        if isStream { parts.append("流媒体") }
        return parts.joined(separator: " · ")
    }

    /// Parses the page script's JSON; videos and audio come first since they are usually wanted.
    static func items(fromJSON json: String) -> [BrowserMediaItem] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([BrowserRawMedia].self, from: data)
        else { return [] }
        var seen = Set<URL>()
        let items = raw.compactMap { entry -> BrowserMediaItem? in
            guard let url = URL(string: entry.url), let kind = Kind(rawValue: entry.type), seen.insert(url).inserted
            else { return nil }
            let width = entry.w.flatMap(pixels)
            let height = entry.h.flatMap(pixels)
            let poster = entry.poster.flatMap { URL(string: $0) }
            return BrowserMediaItem(url: url, kind: kind, width: width, height: height, poster: poster)
        }
        return [Kind.video, .audio, .image].flatMap { kind in items.filter { $0.kind == kind } }
    }

    private static func pixels(_ value: Double) -> Int? {
        value.isFinite && value >= 1 && value < 1_000_000 ? Int(value) : nil
    }
}

/// One entry as the page script reports it.
private struct BrowserRawMedia: Decodable {
    let url: String
    let type: String
    let w: Double?
    let h: Double?
    let poster: String?
}

/// What the 「本页媒体」 sheet shows: the page's media plus what is needed to fetch it like the page.
struct BrowserMediaRequest: Identifiable {
    let id = UUID()
    let items: [BrowserMediaItem]
    let context: BrowserFetchContext
    let thumbnails: BrowserThumbnailLoader

    init(items: [BrowserMediaItem], context: BrowserFetchContext) {
        self.items = items
        self.context = context
        thumbnails = BrowserThumbnailLoader(context: context)
    }
}

/// Loads small previews of page images through an in-memory session with the page's cookies and
/// Referer, so nothing reaches the shared disk cache and hotlink-protected images still show.
final class BrowserThumbnailLoader {
    private let context: BrowserFetchContext
    private let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()

    init(context: BrowserFetchContext) {
        self.context = context
        session = context.makeSession()
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// A preview whose shorter side is at least `side` pixels, so it can fill a square.
    func image(for url: URL, side: CGFloat) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let result = try? await session.data(for: context.request(for: url)) else { return nil }
        if let status = (result.1 as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { return nil }
        guard let preview = Self.downsampled(result.0, side: side) else { return nil }
        cache.setObject(preview, forKey: url as NSURL)
        return preview
    }

    /// Decodes only a small version of the image, so large photos do not fill the memory.
    private static func downsampled(_ data: Data, side: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var maxPixels = side
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            maxPixels = side * CGFloat(min(4, max(width, height) / min(width, height)))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels)),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

private enum BrowserMediaFilter: CaseIterable, Identifiable {
    case all, video, image, audio

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "全部"
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        }
    }

    func includes(_ item: BrowserMediaItem) -> Bool {
        switch self {
        case .all: return true
        case .video: return item.kind == .video
        case .image: return item.kind == .image
        case .audio: return item.kind == .audio
        }
    }
}

/// 「本页媒体」: everything the page shows or links to, with multi-select download.
struct BrowserMediaSheet: View {
    let request: BrowserMediaRequest
    let onDownload: ([BrowserMediaItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<URL> = []
    @State private var filter: BrowserMediaFilter = .all

    private var visible: [BrowserMediaItem] { request.items.filter { filter.includes($0) } }
    private var selectable: [BrowserMediaItem] { visible.filter(\.canDownload) }
    private var chosen: [BrowserMediaItem] { request.items.filter { selection.contains($0.url) } }
    private var allSelected: Bool {
        !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.url) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visible) { item in
                    Button { toggle(item) } label: {
                        BrowserMediaRow(item: item, isSelected: selection.contains(item.url), loader: request.thumbnails)
                    }
                    .disabled(!item.canDownload)
                }
            }
            .listStyle(.plain)
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(
                        "没有找到媒体",
                        systemImage: "photo.on.rectangle",
                        description: Text("这个页面里没有能识别的图片、视频或音频")
                    )
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("类型", selection: $filter) {
                    ForEach(BrowserMediaFilter.allCases) { filter in
                        Text(title(for: filter)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                downloadBar
            }
            .navigationTitle("本页媒体")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(allSelected ? "全不选" : "全选", action: toggleAll)
                        .disabled(selectable.isEmpty)
                }
            }
        }
    }

    private var downloadBar: some View {
        VStack(spacing: 6) {
            Button {
                onDownload(chosen)
            } label: {
                Text(chosen.isEmpty ? "下载" : "下载 \(chosen.count) 项")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(chosen.isEmpty)
            if request.items.contains(where: \.isStream) {
                Text("流媒体（blob、HLS 播放列表）无法直接下载")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func title(for filter: BrowserMediaFilter) -> String {
        let count = request.items.filter { filter.includes($0) }.count
        return count > 0 ? "\(filter.title) \(count)" : filter.title
    }

    private func toggle(_ item: BrowserMediaItem) {
        guard item.canDownload else { return }
        if selection.contains(item.url) {
            selection.remove(item.url)
        } else {
            selection.insert(item.url)
        }
    }

    private func toggleAll() {
        if allSelected {
            selection.subtract(selectable.map(\.url))
        } else {
            selection.formUnion(selectable.map(\.url))
        }
    }
}

private struct BrowserMediaRow: View {
    let item: BrowserMediaItem
    let isSelected: Bool
    let loader: BrowserThumbnailLoader

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .opacity(item.canDownload ? 1 : 0.3)
            BrowserMediaThumbnail(item: item, loader: loader)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.summary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                Text(item.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !item.canDownload {
                    Text(item.isStream ? "无法直接下载（流媒体）" : "无法直接下载")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private struct BrowserMediaThumbnail: View {
    let item: BrowserMediaItem
    let loader: BrowserThumbnailLoader

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private let side: CGFloat = 56

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if item.kind == .video && image != nil {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .shadow(radius: 2)
            }
        }
        .task(id: item.thumbnailURL) {
            guard let source = item.thumbnailURL, ["http", "https"].contains(source.scheme?.lowercased() ?? "") else { return }
            image = await loader.image(for: source, side: side * displayScale)
        }
    }
}
