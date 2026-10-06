import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「移动到…」: every vault folder, indented by depth. Folders that cannot take the items (where they
/// already are, or inside a folder that is being moved) are disabled. With `merging`, it is
/// 「合并到…」 for one folder: its contents go into the chosen folder and it disappears.
struct FolderMovePicker: View {
    let items: [FileItem]
    var merging = false
    let onMove: (URL) -> Void

    @EnvironmentObject private var store: FileStore
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [Target] = []

    private struct Target: Identifiable {
        let url: URL
        let depth: Int
        let name: String
        let isAllowed: Bool

        var id: URL { url }
    }

    private var title: String {
        if merging, let item = items.first { return "合并「\(item.name)」到…" }
        return items.count == 1 ? "移动「\(items[0].name)」" : "移动 \(items.count) 项"
    }

    var body: some View {
        NavigationStack {
            List(targets) { target in
                Button {
                    onMove(target.url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: target.depth == 0 ? "archivebox.fill" : "folder.fill")
                            .foregroundStyle(target.isAllowed ? Color.blue : Color.secondary)
                        Text(target.name)
                            .foregroundStyle(target.isAllowed ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(target.depth) * 18)
                    .contentShape(Rectangle())
                }
                .disabled(!target.isAllowed)
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                if merging, let item = items.first {
                    Text("「\(item.name)」里的所有内容会放进你选的文件夹：同名文件夹会合并，同名文件会自动改名，不会覆盖。之后「\(item.name)」会被删除。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let moving = items.map { item in
            (path: store.normalizedPath(item.url),
             isFolder: item.isDirectory,
             parent: store.normalizedPath(item.url.deletingLastPathComponent()))
        }
        targets = store.allFolders().map { entry in
            let path = store.normalizedPath(entry.url)
            let insideMoved = moving.contains { $0.isFolder && (path == $0.path || path.hasPrefix($0.path + "/")) }
            let alreadyThere = moving.allSatisfy { $0.parent == path }
            return Target(
                url: entry.url,
                depth: entry.depth,
                name: store.isRoot(entry.url) ? "FileBox" : entry.url.lastPathComponent,
                isAllowed: !insideMoved && (merging || !alreadyThere)
            )
        }
    }
}

/// 「拼接到…」: pick the video of the same folder that `video` will be appended to.
struct FolderMergePicker: View {
    let video: FileItem
    let candidates: [FileItem]
    let onPick: (FileItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "没有其他视频",
                        systemImage: "film",
                        description: Text("这个文件夹里没有可以拼接的视频")
                    )
                } else {
                    List {
                        Section {
                            ForEach(candidates) { candidate in
                                Button {
                                    onPick(candidate)
                                } label: {
                                    FileRow(item: candidate)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("「\(video.name)」会接在所选视频的后面")
                                .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("拼接到…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 「从 Documents 导入」: a document picker that starts in the folder of the last file imported this
/// way, with a one-line hint until something has been imported.
struct FolderDocumentsSheet: View {
    let showsHint: Bool
    /// Where the picker starts (`FolderDocumentsLocation.directory`), nil for the system default.
    let directory: URL?
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsHint {
                Text("在「浏览」里选择 Documents（需先在「文件」App 的浏览页面把 Documents 打开）")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            FolderDocumentPicker(directory: directory, onPick: onPick, onCancel: onCancel)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// UIDocumentPickerViewController that opens any files in place (multi-select), so FileStore can
/// copy them in with their security scope. `directory` is where it starts browsing.
struct FolderDocumentPicker: UIViewControllerRepresentable {
    let directory: URL?
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .folder makes whole folders selectable, not just the files inside them.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .item])
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.directoryURL = directory
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// Remembers the folder of the last file imported with 「从 Documents 导入」 (as bookmark data, with
/// the plain path as a fallback) so the picker reopens there next time.
enum FolderDocumentsLocation {
    private static let bookmarkKey = "documentsImportBookmark"
    private static let bookmarkIsFileKey = "documentsImportBookmarkIsFile"
    private static let pathKey = "documentsImportPath"

    static var isRemembered: Bool {
        let defaults = UserDefaults.standard
        return defaults.data(forKey: bookmarkKey) != nil || defaults.string(forKey: pathKey) != nil
    }

    /// The remembered folder, or nil before the first import.
    static var directory: URL? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if isStale {
                    let scoped = url.startAccessingSecurityScopedResource()
                    if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        defaults.set(fresh, forKey: bookmarkKey)
                    }
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                return defaults.bool(forKey: bookmarkIsFileKey) ? url.deletingLastPathComponent() : url
            }
        }
        if let path = defaults.string(forKey: pathKey) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    /// Stores the folder containing `file`, a URL straight from the document picker. A bookmark of
    /// the folder itself can be refused (the picker only granted access to the file), so a bookmark
    /// of the file is the second choice.
    static func remember(folderOf file: URL) {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let folder = file.deletingLastPathComponent()
        let defaults = UserDefaults.standard
        if let data = try? folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
            defaults.set(false, forKey: bookmarkIsFileKey)
        } else if let data = try? file.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
            defaults.set(true, forKey: bookmarkIsFileKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
        }
        defaults.set(folder.path, forKey: pathKey)
    }
}
