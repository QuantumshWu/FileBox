import Foundation

/// A short log of Picture in Picture events (start, failure reasons, stop), shown under 设置 → 关于
/// so a problem on the phone can be reported with a screenshot. Kept across launches.
@MainActor
enum MediaDiagnostics {
    private static let key = "mediaPiPLog"
    private static let maxLines = 40
    private static var lines: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    static func log(_ event: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(time) \(event)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static var text: String {
        lines.isEmpty ? "（还没有记录）" : lines.reversed().joined(separator: "\n")
    }
}
