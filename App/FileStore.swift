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
        collectIncoming()
    }

    func isRoot(_ folder: URL) -> Bool {
        normalizedPath(folder) == normalizedPath(rootURL)
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

    /// Reloads open folders, e.g. after files were changed from the Files app.
    func refresh() {
        changed()
    }

    // MARK: - Editing

    func createFolder(named name: String, in folder: URL) {
        let clean = allowedName(sanitizedFileName(name), in: folder)
        let url = fm.uniqueURL(for: clean.isEmpty ? "新建文件夹" : clean, in: folder)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            changed()
        } catch {
            report(error)
        }
    }

    func rename(_ item: FileItem, to newName: String) {
        let folder = item.url.deletingLastPathComponent()
        let clean = allowedName(sanitizedFileName(newName), in: folder)
        guard !clean.isEmpty, clean != item.name else { return }
        let dest = fm.uniqueURL(for: clean, in: folder)
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
    func importFiles(_ urls: [URL], into folder: URL, moving: Bool = false) async {
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = fm.uniqueURL(for: safeName(url.lastPathComponent), in: folder)
            do {
                if moving {
                    try fm.moveItem(at: url, to: dest)
                } else {
                    try await coordinatedCopy(url, to: dest)
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
    func importIncoming(_ url: URL) async {
        guard url.isFileURL else { return }
        // Files copied from another app's sandbox arrive in Documents/Inbox, which collectIncoming()
        // empties; it may already have done so while the app was launching.
        if normalizedPath(url.deletingLastPathComponent()) == normalizedPath(systemInboxURL) {
            collectIncoming()
            return
        }
        // Opening one of our own files from the Files app: nothing to import.
        if normalizedPath(url).hasPrefix(normalizedPath(rootURL) + "/") { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        ensureReceivedFolder()
        let dest = fm.uniqueURL(for: safeName(url.lastPathComponent), in: receivedURL)
        do {
            try await coordinatedCopy(url, to: dest)
            changed()
            show("已收到「\(dest.lastPathComponent)」")
        } catch {
            report(error)
        }
    }

    /// Moves files dropped off by the share extension (and the system Inbox) into 收件箱.
    func collectIncoming() {
        ensureReceivedFolder()
        var count = 0
        if let shared = SharedConfig.sharedInboxURL { count += drain(shared) }
        count += drain(systemInboxURL)
        if count > 0 {
            changed()
            show("收到 \(count) 个文件，已放进「收件箱」")
        }
    }

    private func drain(_ folder: URL) -> Int {
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for url in urls {
            // Files the share extension is still writing; delete leftovers from a killed extension.
            if url.lastPathComponent.hasPrefix(".partial-") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < Date().addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
                continue
            }
            let dest = fm.uniqueURL(for: safeName(url.lastPathComponent), in: receivedURL)
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

    /// Copy that also works for iCloud files that are not downloaded yet, off the main thread
    /// because the download can take a while.
    private func coordinatedCopy(_ source: URL, to dest: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
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
        }.value
    }

    /// 收件箱 can be deleted by the user (here or in the Files app); bring it back when needed.
    private func ensureReceivedFolder() {
        try? fm.createDirectory(at: receivedURL, withIntermediateDirectories: true)
    }

    /// "Inbox" at the root belongs to the system.
    private func allowedName(_ name: String, in folder: URL) -> String {
        isRoot(folder) && name == "Inbox" ? "Inbox 2" : name
    }

    private func safeName(_ name: String) -> String {
        let clean = sanitizedFileName(name)
        return clean.isEmpty ? "文件" : clean
    }

    /// Path without the /private prefix, which iOS adds to some URLs but not others.
    private func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
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
