import Foundation
import SwiftUI

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: URL { url }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case date, name, size

    var id: Self { self }

    var title: String {
        switch self {
        case .date: return "按日期"
        case .name: return "按名称"
        case .size: return "按大小"
        }
    }
}

/// All file operations. Files live in the app's Documents folder, which the Files app also shows
/// under "On My iPhone › FileBox".
@MainActor
final class FileStore: ObservableObject {
    /// Bumped after every change so open folders reload.
    @Published private(set) var revision = 0
    @Published var banner: String?

    let rootURL: URL
    /// Where everything shared from other apps lands.
    let receivedURL: URL

    private let fm = FileManager.default
    /// Folder the system itself drops "Copy to FileBox" files into; the app may only read and delete there.
    private var systemInboxURL: URL { rootURL.appendingPathComponent("Inbox", isDirectory: true) }

    init() {
        rootURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        receivedURL = rootURL.appendingPathComponent("收件箱", isDirectory: true)
        try? fm.createDirectory(at: receivedURL, withIntermediateDirectories: true)
        collectIncoming()
    }

    func isRoot(_ folder: URL) -> Bool {
        folder.standardizedFileURL.path == rootURL.standardizedFileURL.path
    }

    func items(in folder: URL, sort: SortOrder) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        let hideSystemInbox = isRoot(folder)
        var result = urls.compactMap { url -> FileItem? in
            if hideSystemInbox && url.lastPathComponent == "Inbox" { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
        result.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sort {
            case .date: return a.modified > b.modified
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return a.size > b.size
            }
        }
        return result
    }

    // MARK: - Editing

    func createFolder(named name: String, in folder: URL) {
        let clean = sanitizedFileName(name)
        let url = fm.uniqueURL(for: clean.isEmpty ? "新建文件夹" : clean, in: folder)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            changed()
        } catch {
            report(error)
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let clean = sanitizedFileName(newName)
        guard !clean.isEmpty, clean != item.name else { return }
        let dest = fm.uniqueURL(for: clean, in: item.url.deletingLastPathComponent())
        do {
            try fm.moveItem(at: item.url, to: dest)
            changed()
        } catch {
            report(error)
        }
    }

    func delete(_ items: [FileItem]) {
        for item in items {
            do { try fm.removeItem(at: item.url) } catch { report(error) }
        }
        changed()
    }

    // MARK: - Importing

    /// Files picked in the app (Photos or the Files picker).
    func importFiles(_ urls: [URL], into folder: URL, moving: Bool = false) {
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = fm.uniqueURL(for: url.lastPathComponent, in: folder)
            do {
                if moving {
                    try fm.moveItem(at: url, to: dest)
                } else {
                    try coordinatedCopy(url, to: dest)
                }
                count += 1
            } catch {
                report(error)
            }
        }
        if count > 0 {
            changed()
            show("导入了 \(count) 个文件")
        }
    }

    /// A file handed over with "Open in / Copy to FileBox".
    func importIncoming(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.resolvingSymlinksInPath().path
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let systemInboxPath = systemInboxURL.resolvingSymlinksInPath().path
        // Opening one of our own files from the Files app: nothing to import.
        if path.hasPrefix(rootPath + "/") && !path.hasPrefix(systemInboxPath + "/") { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = fm.uniqueURL(for: url.lastPathComponent, in: receivedURL)
        do {
            if path.hasPrefix(systemInboxPath + "/") {
                try fm.moveItem(at: url, to: dest)
            } else {
                try coordinatedCopy(url, to: dest)
            }
            changed()
            show("已收到「\(dest.lastPathComponent)」")
        } catch {
            report(error)
        }
    }

    /// Moves files dropped off by the share extension (and the system Inbox) into 收件箱.
    func collectIncoming() {
        var count = 0
        if let shared = SharedConfig.sharedInboxURL { count += drain(shared) }
        count += drain(systemInboxURL)
        if count > 0 {
            changed()
            show("收到 \(count) 个文件，已放进「收件箱」")
        }
    }

    private func drain(_ folder: URL) -> Int {
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var count = 0
        for url in urls {
            let dest = fm.uniqueURL(for: url.lastPathComponent, in: receivedURL)
            do {
                try fm.moveItem(at: url, to: dest)
                count += 1
            } catch {
                // A move between containers can be refused; copy and delete instead.
                if (try? fm.copyItem(at: url, to: dest)) != nil {
                    try? fm.removeItem(at: url)
                    count += 1
                }
            }
        }
        return count
    }

    /// Copy that also works for iCloud files that are not downloaded yet.
    private func coordinatedCopy(_ source: URL, to dest: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: dest)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    // MARK: - Feedback

    private func changed() {
        revision += 1
    }

    func show(_ message: String) {
        banner = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if banner == message { banner = nil }
        }
    }

    private func report(_ error: Error) {
        show("出错了：\(error.localizedDescription)")
    }
}
