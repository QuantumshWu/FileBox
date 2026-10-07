import CryptoKit
import Foundation

/// Where longer videos and audio files were left, kept across launches while 设置 → 记住播放位置
/// is on (the default). Entries are keyed by a hash of the file's place in the vault and its size,
/// so no file names are stored; the newest 300 are kept, in a small file excluded from backups.
@MainActor
final class PlayerResumeStore {
    static let shared = PlayerResumeStore()

    /// UserDefaults key of the 设置 switch; unset means on.
    static let settingKey = "mediaResumePosition"
    private static let capacity = 300

    private struct Entry: Codable {
        var seconds: Double
        var duration: Double
        var date: Date
    }

    private var entries: [String: Entry]?
    private var writeToken = UUID()
    private var hasUnsavedChanges = false
    private let queue = DispatchQueue(label: "FileBox.PlayerResumeStore", qos: .utility)
    private lazy var rootPath = Self.normalizedPath(Vault.root)

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlayerPositions.json")
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
    }

    private init() {}

    /// Worth remembering: a file of at least a minute, not at its very start or end.
    nonisolated static func isEligible(seconds: Double, duration: Double) -> Bool {
        duration >= 60 && seconds > 5 && seconds < duration - 10
    }

    func position(for item: FileItem) -> Double? {
        guard isEnabled, let entry = load()[key(for: item)],
              Self.isEligible(seconds: entry.seconds, duration: entry.duration)
        else { return nil }
        return entry.seconds
    }

    /// Remembers `seconds`, or forgets the file when that position is not worth keeping.
    func save(_ seconds: Double, duration: Double, for item: FileItem) {
        guard isEnabled else { return }
        let itemKey = key(for: item)
        var all = load()
        if Self.isEligible(seconds: seconds, duration: duration) {
            if let old = all[itemKey], abs(old.seconds - seconds) < 0.5 { return }
            all[itemKey] = Entry(seconds: seconds, duration: duration, date: Date())
            if all.count > Self.capacity {
                let oldest = all.sorted { $0.value.date > $1.value.date }.dropFirst(Self.capacity).map(\.key)
                for stale in oldest { all[stale] = nil }
            }
        } else {
            guard all[itemKey] != nil else { return }
            all[itemKey] = nil
        }
        entries = all
        scheduleWrite()
    }

    func remove(_ item: FileItem) {
        var all = load()
        guard all.removeValue(forKey: key(for: item)) != nil else { return }
        entries = all
        scheduleWrite()
    }

    /// Writes what is still pending now (the app is leaving the screen).
    func flush() {
        guard hasUnsavedChanges else { return }
        write()
    }

    // MARK: - Storage

    private func load() -> [String: Entry] {
        if let entries { return entries }
        let data = try? Data(contentsOf: Self.fileURL)
        let loaded = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = loaded
        return loaded
    }

    /// At most one write a second while playing.
    private func scheduleWrite() {
        hasUnsavedChanges = true
        let token = UUID()
        writeToken = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.writeToken == token else { return }
            self.write()
        }
    }

    private func write() {
        hasUnsavedChanges = false
        writeToken = UUID()
        guard let entries, let data = try? JSONEncoder().encode(entries) else { return }
        let url = Self.fileURL
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            // An atomic write replaces the file, so the flag is set again each time.
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
        }
    }

    /// The file's path inside the vault and its size, hashed.
    private func key(for item: FileItem) -> String {
        var path = Self.normalizedPath(item.url)
        if path.hasPrefix(rootPath + "/") { path.removeFirst(rootPath.count) }
        let digest = SHA256.hash(data: Data("\(path)|\(item.size)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The same spelling for every route to a file (`/private/var` and `/var`, trailing slashes).
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
