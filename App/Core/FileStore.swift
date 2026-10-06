import Foundation
import SwiftUI

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

/// All file operations on the vault (see `Vault`). Views observe `revision` to reload.
@MainActor
final class FileStore: ObservableObject {
    /// Bumped after every change so open folders reload.
    @Published private(set) var revision = 0
    /// Short message shown at the bottom of the screen (only while unlocked).
    @Published var banner: String?

    /// Root of the private library.
    let rootURL: URL
    /// Where everything shared from other apps lands.
    let receivedURL: URL

    private let fm = FileManager.default
    /// Folder the system drops "Copy to FileBox" files into; the app may only read and delete there.
    private let systemInboxURL: URL

    init() {
        Vault.prepare()
        rootURL = Vault.root
        receivedURL = Vault.folder(Vault.receivedName)
        systemInboxURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        collectIncoming()
    }

    func isRoot(_ folder: URL) -> Bool {
        normalizedPath(folder) == normalizedPath(rootURL)
    }

    /// A top-level vault folder such as `Vault.downloadsName`, created if needed.
    func folder(named name: String) -> URL {
        Vault.folder(name)
    }

    func items(in folder: URL, sort: SortOrder) -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var result = urls.map { FileItem(url: $0) }
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

    /// Every folder in the vault (root first, depth-first), e.g. for a "move to" picker.
    func allFolders() -> [(url: URL, depth: Int)] {
        var result: [(url: URL, depth: Int)] = [(rootURL, 0)]
        func walk(_ folder: URL, depth: Int) {
            for item in items(in: folder, sort: .name) where item.isDirectory {
                result.append((item.url, depth))
                walk(item.url, depth: depth + 1)
            }
        }
        walk(rootURL, depth: 1)
        return result
    }

    /// Reloads open folders, e.g. after returning to the app.
    func refresh() {
        changed()
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

    /// Moves items to the trash; they are removed for good after `Vault.trashDays` days.
    func delete(_ items: [FileItem]) {
        var count = 0
        for item in items {
            do {
                try Vault.moveToTrash(item.url)
                count += 1
            } catch {
                report(error)
            }
        }
        changed()
        if count > 0 { show("已移到回收站，\(Vault.trashDays) 天后自动删除") }
    }

    func trashEntries() -> [Vault.TrashEntry] {
        Vault.trashEntries()
    }

    func restore(_ entries: [Vault.TrashEntry]) {
        var count = 0
        for entry in entries {
            do {
                try Vault.restoreFromTrash(entry)
                count += 1
            } catch {
                report(error)
            }
        }
        changed()
        if count > 0 { show("已恢复 \(count) 项") }
    }

    /// Removes items from the trash for good.
    func deleteForever(_ entries: [Vault.TrashEntry]) {
        entries.forEach(Vault.removeFromTrash)
        changed()
    }

    /// Moves items into `folder` (nesting them), skipping a folder moved into itself or its own
    /// subfolder. A folder whose name is already taken there is merged with the existing one.
    func move(_ items: [FileItem], into folder: URL) {
        let target = normalizedPath(folder)
        var count = 0
        for item in items {
            let source = normalizedPath(item.url)
            if target == source || target.hasPrefix(source + "/") { continue }
            if normalizedPath(item.url.deletingLastPathComponent()) == target { continue }
            do {
                try Vault.merge(item.url, into: folder, move: true)
                count += 1
            } catch {
                report(error)
            }
        }
        if count > 0 {
            changed()
            show("已移动 \(count) 项到「\(displayName(of: folder))」")
        }
    }

    /// Moves everything inside `source` into `target` (merging same-named subfolders, renaming
    /// clashing files) and then removes the emptied `source`.
    func mergeFolder(_ source: FileItem, into target: URL) {
        let sourcePath = normalizedPath(source.url)
        let targetPath = normalizedPath(target)
        guard source.isDirectory, targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else { return }
        do {
            for child in try fm.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil) {
                try Vault.merge(child, into: target, move: true)
            }
            try fm.removeItem(at: source.url)
            changed()
            show("已把「\(source.name)」合并到「\(displayName(of: target))」")
        } catch {
            changed()
            report(error)
        }
    }

    private func displayName(of folder: URL) -> String {
        isRoot(folder) ? "FileBox" : folder.lastPathComponent
    }

    /// Adds a file produced inside the app (edited copy, download, recording...) to `folder`.
    /// Returns the final URL, or nil after showing the error.
    @discardableResult
    func add(fileAt source: URL, named name: String? = nil, into folder: URL, moving: Bool) -> URL? {
        do {
            let dest = try Vault.place(source, named: name, in: folder, move: moving)
            changed()
            return dest
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Importing

    /// Files and folders picked in the app (Photos or a document picker). Security-scoped URLs are
    /// handled here. Picked folders keep their subfolders; a folder whose name is already taken is
    /// merged with the existing one.
    func importFiles(_ urls: [URL], into folder: URL, moving: Bool = false) async {
        var count = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if moving {
                    try Vault.merge(url, into: folder, move: true)
                } else {
                    try await Task.detached(priority: .userInitiated) {
                        try FileStore.importTree(url, into: folder)
                    }.value
                }
                count += 1
            } catch {
                report(error)
            }
        }
        if count > 0 {
            changed()
            show("导入了 \(count) 项")
        }
    }

    /// Copies a picked file, or a picked folder with everything in it, into `folder`. Each file is
    /// read through a file coordinator, so iCloud and other providers (Readdle Documents) deliver
    /// files that are not downloaded yet.
    nonisolated private static func importTree(_ source: URL, into folder: URL) throws {
        let fm = FileManager.default
        var name = sanitizedFileName(source.lastPathComponent)
        if name.isEmpty { name = "文件" }
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder {
            var target = folder.appendingPathComponent(name, isDirectory: true)
            var existing: ObjCBool = false
            if !(fm.fileExists(atPath: target.path, isDirectory: &existing) && existing.boolValue) {
                if fm.fileExists(atPath: target.path) { target = fm.uniqueURL(for: name, in: folder) }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for child in children {
                try importTree(child, into: target)
            }
            return
        }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { readURL in
            do {
                try fm.copyItem(at: readURL, to: fm.uniqueURL(for: name, in: folder))
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    /// A file handed over with "Open in / Copy to FileBox".
    func importIncoming(_ url: URL) async {
        guard url.isFileURL else { return }
        // Files from another app arrive in Documents/Inbox, which collectIncoming() empties; it may
        // already have done so while the app was launching.
        if normalizedPath(url.deletingLastPathComponent()) == normalizedPath(systemInboxURL) {
            collectIncoming()
            return
        }
        // One of our own files: nothing to import.
        if normalizedPath(url).hasPrefix(normalizedPath(rootURL) + "/") { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let received = Vault.folder(Vault.receivedName)
        let dest = fm.uniqueURL(for: safeName(url.lastPathComponent), in: received)
        do {
            try await coordinatedCopy(url, to: dest)
            changed()
            show("已收到「\(dest.lastPathComponent)」")
        } catch {
            report(error)
        }
    }

    /// Moves files dropped off by the extensions (and the system Inbox) into the vault.
    func collectIncoming() {
        Vault.purgeTrash()
        var count = 0
        let received = Vault.folder(Vault.receivedName)
        if let shared = SharedConfig.sharedInboxURL { count += drain(shared, into: received) }
        count += drain(systemInboxURL, into: received)
        var recordings = 0
        if let shared = SharedConfig.sharedRecordingsURL {
            recordings = drain(shared, into: Vault.folder(Vault.recordingsName))
        }
        if count > 0 || recordings > 0 {
            changed()
            if recordings > 0 && count == 0 {
                show("新增 \(recordings) 个录屏，在「录屏」里")
            } else {
                show("收到 \(count + recordings) 个文件")
            }
        }
    }

    private func drain(_ folder: URL, into destination: URL) -> Int {
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for url in urls {
            // Files an extension is still writing; delete leftovers from a killed extension.
            if url.lastPathComponent.hasPrefix(".partial-") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < Date().addingTimeInterval(-3600) { try? fm.removeItem(at: url) }
                continue
            }
            let dest = fm.uniqueURL(for: safeName(url.lastPathComponent), in: destination)
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

    private func safeName(_ name: String) -> String {
        let clean = sanitizedFileName(name)
        return clean.isEmpty ? "文件" : clean
    }

    /// Path without the /private prefix, which iOS adds to some URLs but not others.
    func normalizedPath(_ url: URL) -> String {
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

    func report(_ error: Error) {
        show("出错了：\(error.localizedDescription)")
    }
}
