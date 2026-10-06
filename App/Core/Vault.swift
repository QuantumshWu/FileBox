import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case folder, image, video, audio, other
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date

    var id: URL { url }

    var kind: FileKind {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        // JPEG spellings the system does not always map to an image type.
        if ["jfif", "jpe", "pjpeg", "pjp"].contains(ext) { return .image }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    /// Images, videos and audio open in the media viewer; everything else in Quick Look.
    var isMedia: Bool {
        switch kind {
        case .image, .video, .audio: return true
        case .folder, .other: return false
        }
    }

    init(url: URL, name: String, isDirectory: Bool, size: Int64, modified: Date) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// Reads the file's current attributes from disk.
    init(url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.init(
            url: url,
            name: url.lastPathComponent,
            isDirectory: values?.isDirectory ?? false,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .distantPast
        )
    }
}

/// The private library. It lives in Library/Application Support, which the Files app never shows,
/// and is excluded from iCloud and computer backups. All helpers here are safe on any thread.
enum Vault {
    static let receivedName = "收件箱"
    static let downloadsName = "下载"
    static let screenshotsName = "截图"
    static let recordingsName = "录屏"

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vault", isDirectory: true)
    }

    /// A top-level folder of the vault (e.g. `Vault.folder(Vault.downloadsName)`), created if needed.
    static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Creates the vault, keeps it out of backups and moves over files from the old Documents
    /// location (which the Files app used to show).
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
        migrateFromDocuments()
    }

    /// Copies or moves a file into `folder` under a free name and returns where it ended up.
    @discardableResult
    static func place(_ source: URL, named name: String? = nil, in folder: URL, move: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var clean = sanitizedFileName(name ?? source.lastPathComponent)
        if clean.isEmpty { clean = "文件" }
        let dest = fm.uniqueURL(for: clean, in: folder)
        if move {
            try fm.moveItem(at: source, to: dest)
        } else {
            try fm.copyItem(at: source, to: dest)
        }
        return dest
    }

    /// Moves or copies `source` into `folder`. A folder whose name is already taken there by another
    /// folder is merged into it, recursively; a clashing file gets a numbered name, so nothing is
    /// ever overwritten. `folder` must not be `source` or inside it.
    static func merge(_ source: URL, into folder: URL, move: Bool) throws {
        let fm = FileManager.default
        var clean = sanitizedFileName(source.lastPathComponent)
        if clean.isEmpty { clean = "文件" }
        let target = folder.appendingPathComponent(clean, isDirectory: true)
        let sourceIsFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        var targetIsFolder: ObjCBool = false
        if sourceIsFolder, fm.fileExists(atPath: target.path, isDirectory: &targetIsFolder), targetIsFolder.boolValue {
            for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
                try merge(child, into: target, move: move)
            }
            if move { try fm.removeItem(at: source) }
        } else {
            let dest = fm.uniqueURL(for: clean, in: folder)
            if move {
                try fm.moveItem(at: source, to: dest)
            } else {
                try fm.copyItem(at: source, to: dest)
            }
        }
    }

    /// Bytes used by everything in the vault.
    static func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Trash

    /// Deleted files wait this many days in the trash before they are removed for good.
    static let trashDays = 7

    /// Outside the vault, so no folder listing or Wi-Fi transfer ever shows it. Each deleted item
    /// sits in Trash/<id>/<its name>, described by Trash/<id>.json.
    static var trashRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Trash", isDirectory: true)
    }

    struct TrashEntry: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        /// The folder it was deleted from, relative to the vault root ("" for the root).
        let originalFolder: String
        let deletedAt: Date
        let isDirectory: Bool
        let size: Int64

        var url: URL {
            Vault.trashRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent(name)
        }

        var expiresAt: Date {
            deletedAt.addingTimeInterval(TimeInterval(Vault.trashDays * 86_400))
        }
    }

    static func moveToTrash(_ url: URL) throws {
        let fm = FileManager.default
        prepareTrash()
        let id = UUID().uuidString
        let box = trashRoot.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: box, withIntermediateDirectories: true)
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let entry = TrashEntry(
            id: id,
            name: url.lastPathComponent,
            originalFolder: relativePath(of: url.deletingLastPathComponent()),
            deletedAt: Date(),
            isDirectory: isFolder,
            size: isFolder ? size(of: url) : Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        )
        do {
            try fm.moveItem(at: url, to: entry.url)
        } catch {
            try? fm.removeItem(at: box)
            throw error
        }
        try JSONEncoder().encode(entry).write(to: trashRoot.appendingPathComponent(id + ".json"))
    }

    /// Everything in the trash, most recently deleted first.
    static func trashEntries() -> [TrashEntry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(TrashEntry.self, from: data)
            }
            .filter { fm.fileExists(atPath: $0.url.path) }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Puts an item back where it was deleted from (recreating that folder if needed; a name
    /// taken in the meantime is merged or numbered). Returns that folder.
    @discardableResult
    static func restoreFromTrash(_ entry: TrashEntry) throws -> URL {
        let folder = entry.originalFolder.isEmpty ? root : root.appendingPathComponent(entry.originalFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try merge(entry.url, into: folder, move: true)
        removeFromTrash(entry)
        return folder
    }

    static func removeFromTrash(_ entry: TrashEntry) {
        let fm = FileManager.default
        try? fm.removeItem(at: trashRoot.appendingPathComponent(entry.id, isDirectory: true))
        try? fm.removeItem(at: trashRoot.appendingPathComponent(entry.id + ".json"))
    }

    /// Removes for good what has been in the trash longer than `trashDays`, and leftovers.
    static func purgeTrash() {
        let fm = FileManager.default
        let now = Date()
        let entries = trashEntries()
        for entry in entries where entry.expiresAt < now {
            removeFromTrash(entry)
        }
        // Boxes without a description (or the other way round) can never be restored.
        let known = Set(entries.filter { $0.expiresAt >= now }.map(\.id))
        for url in (try? fm.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)) ?? [] {
            let id = url.pathExtension == "json" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            if !known.contains(id) { try? fm.removeItem(at: url) }
        }
    }

    private static func prepareTrash() {
        try? FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        var url = trashRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// `url`'s folder path relative to the vault root, "" for the root itself.
    private static func relativePath(of url: URL) -> String {
        func clean(_ url: URL) -> String {
            var path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let rootPath = clean(root)
        let path = clean(url)
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static func migrateFromDocuments() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let urls = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }
        // Documents/Inbox belongs to the system ("Copy to FileBox"); FileStore drains it separately.
        for url in urls where url.lastPathComponent != "Inbox" {
            let dest = root.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            var destIsFolder: ObjCBool = false
            if isFolder, fm.fileExists(atPath: dest.path, isDirectory: &destIsFolder), destIsFolder.boolValue {
                // Merge folders that exist on both sides, such as 收件箱.
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for child in children {
                    try? fm.moveItem(at: child, to: fm.uniqueURL(for: child.lastPathComponent, in: dest))
                }
                try? fm.removeItem(at: url)
            } else {
                try? fm.moveItem(at: url, to: fm.uniqueURL(for: url.lastPathComponent, in: root))
            }
        }
    }
}
