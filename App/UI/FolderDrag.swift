import Foundation
import SwiftUI

/// Rows are dragged as an opaque "filebox-item:<UUID>" string instead of a file URL, so a file can
/// only be dropped inside FileBox: other apps just see a meaningless string, and only this process
/// can turn the token back into a file.
final class FolderDragRegistry: @unchecked Sendable {
    static let shared = FolderDragRegistry()

    private static let prefix = "filebox-item:"

    private let lock = NSLock()
    private var urlsByToken: [String: URL] = [:]
    private var tokensByURL: [URL: String] = [:]

    /// The drag payload for a file, the same token every time for the same URL.
    func token(for url: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let token = tokensByURL[url] { return token }
        let token = Self.prefix + UUID().uuidString
        tokensByURL[url] = token
        urlsByToken[token] = url
        return token
    }

    /// The file behind a dropped string, or nil if it is not one of our tokens.
    func url(for token: String) -> URL? {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix(Self.prefix) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return urlsByToken[clean]
    }
}

/// What follows the finger while a row is dragged.
struct FolderDragPreview: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 8) {
            FolderThumbnail(item: item, side: 36)
            Text(item.name)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
