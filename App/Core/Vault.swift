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
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
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
