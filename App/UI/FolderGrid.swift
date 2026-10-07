import AVFoundation
import SwiftUI
import UIKit

/// One square of the folder grid. Photos and videos fill it edge to edge like in Photos (videos with
/// their duration); folders and other files sit on a light rounded tile with their name below.
struct FolderGridCell: View {
    let item: FileItem
    /// nil outside selection mode.
    var isSelected: Bool? = nil
    var isDropTarget = false

    /// Photos and videos fill the whole square.
    static func fillsCell(_ item: FileItem) -> Bool {
        item.kind == .image || item.kind == .video
    }

    static func shape(for item: FileItem) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: fillsCell(item) ? 0 : 8)
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let side = proxy.size.width
                    if Self.fillsCell(item) {
                        media(side: side)
                    } else {
                        tile(side: side)
                    }
                }
            }
            .overlay {
                if isSelected == true {
                    Color.white.opacity(0.25)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let isSelected {
                    FolderSelectionMark(isSelected: isSelected)
                }
            }
            .overlay {
                if isDropTarget {
                    Self.shape(for: item)
                        .fill(Color.accentColor.opacity(0.2))
                        .overlay {
                            Self.shape(for: item).strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                }
            }
            .clipShape(Self.shape(for: item))
            .contentShape(Self.shape(for: item))
    }

    private func media(side: CGFloat) -> some View {
        FolderThumbnail(item: item, side: side, cornerRadius: 0)
            .overlay(alignment: .bottomTrailing) {
                if item.kind == .video {
                    FolderVideoDurationLabel(item: item)
                }
            }
    }

    private func tile(side: CGFloat) -> some View {
        let compact = side < 80
        return VStack(spacing: 4) {
            FolderThumbnail(item: item, side: (side * 0.42).rounded())
                .frame(maxHeight: .infinity)
            Text(item.name)
                .font(compact ? .caption2 : .caption)
                .lineLimit(compact ? 1 : 2, reservesSpace: true)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
        .padding(6)
        .frame(width: side, height: side)
        .background(Color(uiColor: .secondarySystemBackground))
    }
}

/// A file's thumbnail cropped to a square, or the folder symbol for a folder.
struct FolderThumbnail: View {
    let item: FileItem
    let side: CGFloat
    /// Defaults to the rounded look of a list row.
    var cornerRadius: CGFloat? = nil

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        // Whatever is already in memory (this size or another) shows in the very first frame.
        let shown: UIImage? = item.isDirectory ? nil : (image ?? Thumbnails.cached(for: item, side: side, scale: displayScale))
        ZStack {
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
            } else if FolderGridCell.fillsCell(item) {
                Color(uiColor: .secondarySystemBackground)
                Image(systemName: item.kind == .video ? "video" : "photo")
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(side * 0.18)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? side * 0.14))
        .task(id: Thumbnails.key(for: item, side: side, scale: displayScale)) {
            guard !item.isDirectory, side >= 1 else { return }
            if let hit = Thumbnails.exactCached(for: item, side: side, scale: displayScale) {
                image = hit
                return
            }
            // Cells flung past in a fast scroll are gone before this ends and never start work.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let loaded = await Thumbnails.image(for: item, side: side, scale: displayScale)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// A video's length in the bottom-right corner, white with a soft shadow like in Photos.
private struct FolderVideoDurationLabel: View {
    let item: FileItem

    @State private var text: String?

    var body: some View {
        Text(text ?? FolderVideoDurations.cachedText(for: item) ?? "")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
            .padding(.trailing, 5)
            .padding(.bottom, 4)
            .task(id: item) {
                let loaded = await FolderVideoDurations.text(for: item)
                guard !Task.isCancelled else { return }
                text = loaded
            }
    }
}

/// Video durations as display text, loaded once per file version. Files without a readable
/// duration are remembered too, so they are not opened again on every appearance.
@MainActor
enum FolderVideoDurations {
    private static var texts: [String: String] = [:]
    private static var failures: Set<String> = []

    /// The text if it is already known.
    static func cachedText(for item: FileItem) -> String? {
        texts[cacheKey(item)]
    }

    static func text(for item: FileItem) async -> String? {
        let fileKey = cacheKey(item)
        if let hit = texts[fileKey] { return hit }
        if failures.contains(fileKey) { return nil }
        let duration = try? await AVURLAsset(url: item.url).load(.duration)
        guard let seconds = duration?.seconds, seconds.isFinite, seconds >= 0 else {
            // A cancelled load says nothing about the file.
            if !Task.isCancelled { failures.insert(fileKey) }
            return nil
        }
        let total = Int(seconds.rounded())
        let text = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        texts[fileKey] = text
        return text
    }

    private static func cacheKey(_ item: FileItem) -> String {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)"
    }
}

/// The round checkmark of selection mode.
private struct FolderSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.black.opacity(0.2))
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.25), radius: 1)
        .padding(5)
    }
}

/// Grid cells dim a little while pressed.
struct FolderGridButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
