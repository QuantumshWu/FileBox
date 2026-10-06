import Foundation

/// Settings shared by the app and its extensions.
enum SharedConfig {
    /// App Group declared in the entitlements. Free-account sideloading tools re-sign the app and
    /// usually rename the group (for example by appending the team ID), so the real ID is looked up
    /// at runtime instead of being trusted.
    static let declaredAppGroup = "group.io.github.quantumshwu.filebox"

    /// Group IDs this build may use, most trustworthy first.
    static var appGroupCandidates: [String] {
        var ids = provisionedAppGroups(in: Bundle.main.bundleURL)
        ids += altAppGroups(Bundle.main.infoDictionary)
        if let host = hostAppBundleURL {
            ids += provisionedAppGroups(in: host)
            ids += altAppGroups(NSDictionary(contentsOf: host.appendingPathComponent("Info.plist")) as? [String: Any])
        }
        // Re-signers turn "group.<bundle ID>" into "group.<re-signed bundle ID>", e.g. with ".TEAMID".
        if let appBundleID = runtimeAppBundleID {
            ids.append("group." + appBundleID)
        }
        ids.append(declaredAppGroup)
        var seen = Set<String>()
        return ids.filter { !$0.contains("*") && seen.insert($0).inserted }
    }

    /// Container shared by the app and its extensions.
    static var groupContainerURL: URL? {
        let fm = FileManager.default
        for id in appGroupCandidates {
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: id) { return container }
        }
        return nil
    }

    /// A drop-box folder in the shared container, created if needed.
    static func sharedFolder(_ name: String) -> URL? {
        guard let container = groupContainerURL else { return nil }
        let folder = container.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// Where the share extension drops shared files; the app empties it on launch.
    static var sharedInboxURL: URL? { sharedFolder("Inbox") }

    /// Where the screen-recording extension writes finished recordings; the app empties it on launch.
    static var sharedRecordingsURL: URL? { sharedFolder("Recordings") }

    /// The installed main app's bundle ID as re-signed (extensions drop their last component).
    static var runtimeAppBundleID: String? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        guard hostAppBundleURL != nil else { return id }
        var parts = id.split(separator: ".")
        guard parts.count > 1 else { return nil }
        parts.removeLast()
        return parts.joined(separator: ".")
    }

    /// Human-readable summary for the settings screen, to debug sideloading issues on the phone.
    static var diagnostics: String {
        let resolved = sharedInboxURL != nil ? "可用" : "不可用"
        return "共享文件夹：\(resolved)\n候选 App Group：\n" + appGroupCandidates.joined(separator: "\n")
    }

    /// Inside an extension (FileBox.app/PlugIns/X.appex) this is the containing app bundle.
    private static var hostAppBundleURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// AltStore and SideStore record the renamed groups under this Info.plist key.
    private static func altAppGroups(_ info: [String: Any]?) -> [String] {
        info?["ALTAppGroups"] as? [String] ?? []
    }

    /// The groups the installed provisioning profile actually grants.
    private static func provisionedAppGroups(in bundle: URL) -> [String] {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return [] }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}

extension FileManager {
    /// `name` inside `folder`, numbered ("photo 2.jpg") if that name is already taken.
    func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        guard fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            index += 1
        } while fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Makes a user- or app-supplied name safe to use as a single, visible path component.
func sanitizedFileName(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    // A leading dot would make the file hidden, and the app lists only visible files.
    while name.hasPrefix(".") { name.removeFirst() }
    return name.trimmingCharacters(in: .whitespaces)
}
