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
    /// Tells apart the timers of messages shown one after another.
    private var bannerID = 0
    private var vaultObserver: NSObjectProtocol?

    /// The trash is cleaned up at most once an hour; this remembers when it last was.
    private static let trashPurgedKey = "trashPurgedAt"

    init() {
        Vault.prepare()
        rootURL = Vault.root
        receivedURL = Vault.folder(Vault.receivedName)
        systemInboxURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        collectIncoming()
        // Shortcuts actions run in this process and post this after saving into the vault, so an
        // open folder shows a new screenshot right away.
        vaultObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("FileBoxVaultChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changed()
            }
        }
    }

    func isRoot(_ folder: URL) -> Bool {
        normalizedPath(folder) == normalizedPath(rootURL)
    }

    /// A top-level vault folder such as `Vault.downloadsName`, created if needed.
    func folder(named name: String) -> URL {
        Vault.folder(name)
    }

    func items(in folder: URL, sort: SortOrder) -> [FileItem] {
        Self.listItems(in: folder, sort: sort)
    }

    /// The visible contents of `folder`, folders first. Safe on any thread, so big folders can be
    /// listed in the background.
    nonisolated static func listItems(in folder: URL, sort: SortOrder) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var result = urls.map { url -> FileItem in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            var childCount: Int?
            if isDirectory, let names = try? fm.contentsOfDirectory(atPath: url.path) {
                childCount = names.filter { !$0.hasPrefix(".") }.count
            }
            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                childCount: childCount
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

    /// Every folder in the vault (root first, depth-first), e.g. for a "move to" picker.
    func allFolders() -> [(url: URL, depth: Int)] {
        Self.allFolderURLs(root: rootURL)
    }

    /// Every folder under `root` (root first at depth 0, then depth-first, by name). Only folders
    /// are looked at, and it is safe on any thread.
    nonisolated static func allFolderURLs(root: URL) -> [(url: URL, depth: Int)] {
        let fm = FileManager.default
        var result: [(url: URL, depth: Int)] = [(root, 0)]
        func walk(_ folder: URL, depth: Int) {
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            else { return }
            let folders = urls
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for subfolder in folders {
                result.append((subfolder, depth))
                walk(subfolder, depth: depth + 1)
            }
        }
        walk(root, depth: 1)
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

    /// Renames in place. A file keeps its extension when the new name leaves it out, and a name
    /// that is already taken is refused instead of being numbered.
    func rename(_ item: FileItem, to newName: String) {
        var clean = sanitizedFileName(newName)
        guard !clean.isEmpty else { return }
        let ext = item.url.pathExtension
        if !item.isDirectory, !ext.isEmpty, !clean.lowercased().hasSuffix("." + ext.lowercased()) {
            clean += "." + ext
        }
        guard clean != item.name else { return }
        let folder = item.url.deletingLastPathComponent()
        let dest = folder.appendingPathComponent(clean, isDirectory: item.isDirectory)
        // Only the case changes: the "existing" item is this one.
        let caseOnly = dest.path.lowercased() == item.url.path.lowercased()
        if !caseOnly, fm.fileExists(atPath: dest.path) {
            show("已有同名项目「\(clean)」", duration: 5)
            return
        }
        do {
            if caseOnly {
                // Through a hidden temporary name, which also works where names ignore case.
                let temp = folder.appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: item.url, to: temp)
                do {
                    try fm.moveItem(at: temp, to: dest)
                } catch {
                    try? fm.moveItem(at: temp, to: item.url)
                    throw error
                }
            } else {
                try fm.moveItem(at: item.url, to: dest)
            }
            changed()
        } catch {
            report(error)
        }
    }

    /// Copies an item next to itself as 「名字 2.ext」.
    func duplicate(_ item: FileItem) {
        let source = item.url
        let folder = source.deletingLastPathComponent()
        Task {
            do {
                let copy = try await Task.detached(priority: .userInitiated) {
                    try Vault.place(source, in: folder, move: false)
                }.value
                changed()
                show("已创建副本「\(copy.lastPathComponent)」")
            } catch {
                report(error)
            }
        }
    }

    /// Moves items to the trash; they are removed for good after `Vault.trashDays` days.
    func delete(_ items: [FileItem]) {
        var count = 0
        var failures: [Error] = []
        for item in items {
            do {
                try Vault.moveToTrash(item.url)
                count += 1
            } catch {
                failures.append(error)
            }
        }
        changed()
        if let failure = failures.first {
            let reason = failure.localizedDescription
            show(count > 0 ? "已移到回收站 \(count) 项，\(failures.count) 项失败：\(reason)" : "删除失败：\(reason)", duration: 5)
        } else if count > 0 {
            show("已移到回收站，\(Vault.trashDays) 天后自动删除")
        }
    }

    func trashEntries() -> [Vault.TrashEntry] {
        Vault.trashEntries()
    }

    func restore(_ entries: [Vault.TrashEntry]) {
        var restored: [Vault.TrashEntry] = []
        var failures: [Error] = []
        for entry in entries {
            do {
                try Vault.restoreFromTrash(entry)
                restored.append(entry)
            } catch {
                failures.append(error)
            }
        }
        changed()
        var message: String
        if restored.count == 1, let entry = restored.first {
            message = "已恢复到「\(entry.originalFolder.isEmpty ? "FileBox" : entry.originalFolder)」"
        } else if !restored.isEmpty {
            message = "已恢复 \(restored.count) 项"
        } else if let failure = failures.first {
            show("恢复失败：\(failure.localizedDescription)", duration: 5)
            return
        } else {
            return
        }
        if let failure = failures.first {
            message += "，\(failures.count) 项失败：\(failure.localizedDescription)"
            show(message, duration: 5)
        } else {
            show(message)
        }
    }

    /// Removes items from the trash for good. They leave the list at once; deleting the files
    /// themselves (maybe whole folders) happens in the background.
    func deleteForever(_ entries: [Vault.TrashEntry]) {
        guard !entries.isEmpty else { return }
        entries.forEach(Vault.removeTrashRecord)
        changed()
        show("已彻底删除 \(entries.count) 项")
        Task.detached(priority: .utility) {
            entries.forEach(Vault.removeTrashBox)
        }
    }

    /// Moves items into `folder` (nesting them), skipping a folder moved into itself or its own
    /// subfolder. A folder whose name is already taken there is merged with the existing one.
    func move(_ items: [FileItem], into folder: URL) {
        let target = normalizedPath(folder)
        var count = 0
        var failures: [Error] = []
        for item in items {
            let source = normalizedPath(item.url)
            if target == source || target.hasPrefix(source + "/") { continue }
            if normalizedPath(item.url.deletingLastPathComponent()) == target { continue }
            do {
                try Vault.merge(item.url, into: folder, move: true)
                count += 1
            } catch {
                failures.append(error)
            }
        }
        guard count > 0 || !failures.isEmpty else { return }
        changed()
        let moved = "已移动 \(count) 项到「\(displayName(of: folder))」"
        if let failure = failures.first {
            let reason = failure.localizedDescription
            show(count > 0 ? "\(moved)，\(failures.count) 项失败：\(reason)" : "移动失败：\(reason)", duration: 5)
        } else {
            show(moved)
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
    /// merged with the existing one. `progress` gets (files done, files in total) on the way;
    /// cancelling the calling task stops before the next file.
    func importFiles(
        _ urls: [URL],
        into folder: URL,
        moving: Bool = false,
        progress: (@MainActor (Int, Int) -> Void)? = nil
    ) async {
        let outcome: VaultImportOutcome
        if moving {
            outcome = moveIn(urls, into: folder, progress: progress)
        } else {
            let worker = Task.detached(priority: .userInitiated) {
                await FileStore.copyIn(urls, into: folder, progress: progress)
            }
            outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        if outcome.imported > 0 || outcome.cancelled || !outcome.failures.isEmpty { changed() }
        if outcome.cancelled {
            show("已取消导入，已导入 \(outcome.imported) 项")
        } else if let failure = outcome.failures.first {
            let reason = failure.localizedDescription
            show(outcome.imported > 0
                 ? "导入了 \(outcome.imported) 项，\(outcome.failures.count) 项失败：\(reason)"
                 : "导入失败：\(reason)", duration: 5)
        } else if outcome.imported > 0 {
            show("导入了 \(outcome.imported) 项")
        }
    }

    /// Moves files that are already ours (e.g. Photos exports in the temporary folder).
    private func moveIn(_ urls: [URL], into folder: URL, progress: (@MainActor (Int, Int) -> Void)?) -> VaultImportOutcome {
        var outcome = VaultImportOutcome()
        progress?(0, urls.count)
        for (index, url) in urls.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                try Vault.merge(url, into: folder, move: true)
                outcome.imported += 1
            } catch {
                outcome.failures.append(error)
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            progress?(index + 1, urls.count)
        }
        return outcome
    }

    /// Copies picked files and folders in the background: counts the files first, then copies
    /// them one by one, reporting each one.
    nonisolated private static func copyIn(
        _ urls: [URL],
        into folder: URL,
        progress: (@MainActor (Int, Int) -> Void)?
    ) async -> VaultImportOutcome {
        let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (url, isScoped) in zip(urls, scoped) where isScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let counter = VaultImportCounter(total: urls.reduce(0) { $0 + fileCount(of: $1) }, report: progress)
        await counter.start()
        var outcome = VaultImportOutcome()
        for url in urls {
            do {
                try await importTree(url, into: folder, counter: counter)
                outcome.imported += 1
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                outcome.failures.append(error)
            }
        }
        return outcome
    }

    /// 1 for a file, the files inside (at any depth, hidden ones left out) for a folder.
    nonisolated private static func fileCount(of url: URL) -> Int {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return 1 }
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let child as URL in enumerator
        where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
            count += 1
        }
        return count
    }

    /// Copies a picked file, or a picked folder with everything in it, into `folder`. Each file is
    /// read through a file coordinator, so iCloud and other providers (Readdle Documents) deliver
    /// files that are not downloaded yet.
    nonisolated private static func importTree(_ source: URL, into folder: URL, counter: VaultImportCounter) async throws {
        try Task.checkCancellation()
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
                try await importTree(child, into: target, counter: counter)
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
        await counter.fileDone()
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
        purgeTrashIfDue()
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

    /// Expired items need not go the moment they expire (the trash list already hides them), so
    /// the cleanup runs at most once an hour instead of on every return to the app.
    private func purgeTrashIfDue() {
        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: Self.trashPurgedKey) as? Date, last <= now, now.timeIntervalSince(last) < 3600 {
            return
        }
        Vault.purgeTrash()
        defaults.set(now, forKey: Self.trashPurgedKey)
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
        Self.normalize(url)
    }

    /// `normalizedPath` for any thread.
    nonisolated static func normalize(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Feedback

    private func changed() {
        revision += 1
    }

    /// Shows `message` for `duration` seconds (unless another one replaces it first).
    func show(_ message: String, duration: TimeInterval = 2.5) {
        banner = message
        bannerID += 1
        let id = bannerID
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            if bannerID == id { banner = nil }
        }
    }

    func report(_ error: Error) {
        show("出错了：\(error.localizedDescription)", duration: 5)
    }
}

/// What an import achieved: picked items brought in, failures, and whether it was cancelled.
private struct VaultImportOutcome {
    var imported = 0
    var failures: [Error] = []
    var cancelled = false
}

/// Counts the files an import has copied and passes the count on to its progress callback.
private final class VaultImportCounter {
    let total: Int
    private(set) var done = 0
    private let report: (@MainActor (Int, Int) -> Void)?

    init(total: Int, report: (@MainActor (Int, Int) -> Void)?) {
        self.total = total
        self.report = report
    }

    func start() async {
        await report?(0, total)
    }

    func fileDone() async {
        done += 1
        // A folder can turn out to hold more than counted (files added while copying).
        await report?(done, max(total, done))
    }
}
