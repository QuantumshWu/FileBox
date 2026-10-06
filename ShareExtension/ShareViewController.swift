import UIKit
import UniformTypeIdentifiers

/// Shown when the user picks FileBox in another app's share sheet. Copies every shared item into
/// the App Group drop box; the app moves them into 收件箱 the next time it opens.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Don't let a swipe dismiss the sheet halfway through a copy.
        isModalInPresentation = true

        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "正在保存到 FileBox…"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)

        view.addSubview(card)
        card.addSubview(spinner)
        card.addSubview(label)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
            spinner.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await saveAll() }
    }

    private func saveAll() async {
        guard let inbox = SharedConfig.sharedInboxURL else {
            finish("保存失败：共享文件夹不可用。\n可以在分享菜单里改用「拷贝到 FileBox」。", success: false)
            return
        }
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        var saved = 0
        var failed = 0
        for (index, provider) in providers.enumerated() {
            if providers.count > 1 {
                label.text = "正在保存 \(index + 1)/\(providers.count)…"
            }
            do {
                try await IncomingSaver.save(provider, into: inbox)
                saved += 1
            } catch {
                failed += 1
            }
        }
        if saved == 0 {
            finish("没有可以保存的内容", success: false)
        } else if failed == 0 {
            finish("已保存 \(saved) 个文件 ✓\n打开 FileBox 的「收件箱」查看", success: true)
        } else {
            finish("已保存 \(saved) 个，\(failed) 个失败", success: true)
        }
    }

    private func finish(_ message: String, success: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = message
        let delay: TimeInterval = success ? 1.2 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}

/// Turns one shared item into a file. Large videos are copied file-to-file, never loaded into
/// memory, because share extensions are killed at a low memory limit.
enum IncomingSaver {
    static func save(_ provider: NSItemProvider, into folder: URL) async throws {
        let types = provider.registeredTypeIdentifiers
        let suggestedName = provider.suggestedName

        // 1. Real file content: photos, videos, PDFs, documents...
        if let type = types.first(where: isBinaryFileType) {
            try await copyFileRepresentation(provider, type: type, suggestedName: suggestedName, into: folder)
            return
        }
        // 2. Some apps hand over a URL pointing at the file instead.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await loadURL(provider, type: UTType.fileURL.identifier)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
            try place(url, named: fileName(suggestedName, fallback: url.lastPathComponent, ext: ext), in: folder)
            return
        }
        // 3. A web link: keep it as a small text file.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let url = try await loadURL(provider, type: UTType.url.identifier)
            try placeText(url.absoluteString, named: "\(url.host ?? "链接").txt", in: folder)
            return
        }
        // 4. Text: either a text *file* (.txt, .csv, .json, .vcf...) or a plain string.
        if let type = types.first(where: { UTType($0)?.conforms(to: .text) == true }) {
            try await saveText(provider, type: type, suggestedName: suggestedName, into: folder)
            return
        }
        throw CocoaError(.fileReadUnknown)
    }

    private static func isBinaryFileType(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text)
    }

    private static func copyFileRepresentation(_ provider: NSItemProvider, type: String, suggestedName: String?, into folder: URL) async throws {
        let ext = UTType(type)?.preferredFilenameExtension
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // The temporary file is deleted when this handler returns, so copy it right here.
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try place(url, named: fileName(suggestedName, fallback: url.lastPathComponent, ext: ext), in: folder)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func loadURL(_ provider: NSItemProvider, type: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let string = item as? String, let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    /// Text files arrive as file URLs and are copied byte for byte (so GBK etc. survive);
    /// only a bare string becomes a new 文本.txt.
    private static func saveText(_ provider: NSItemProvider, type: String, suggestedName: String?, into folder: URL) async throws {
        let ext = UTType(type)?.preferredFilenameExtension ?? "txt"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                do {
                    if let url = item as? URL, url.isFileURL {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        try place(url, named: fileName(suggestedName, fallback: url.lastPathComponent, ext: ext), in: folder)
                    } else if let data = item as? Data {
                        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        try data.write(to: temp)
                        defer { try? FileManager.default.removeItem(at: temp) }
                        try place(temp, named: fileName(suggestedName, fallback: "文本.\(ext)", ext: ext), in: folder)
                    } else if let string = item as? String {
                        try placeText(string, named: fileName(suggestedName, fallback: "文本.txt", ext: "txt"), in: folder)
                    } else if let attributed = item as? NSAttributedString {
                        try placeText(attributed.string, named: fileName(suggestedName, fallback: "文本.txt", ext: "txt"), in: folder)
                    } else {
                        throw error ?? CocoaError(.fileReadUnknown)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func fileName(_ suggested: String?, fallback: String, ext: String?) -> String {
        // Data-backed items get a temporary name like ".com.apple.Foundation.NSItemProvider.ab12.png".
        let usableFallback = fallback.contains("NSItemProvider") ? "文件" : fallback
        var name = sanitizedFileName(suggested ?? "")
        if name.isEmpty { name = sanitizedFileName(usableFallback) }
        if name.isEmpty { name = "文件" }
        // Names like "Report v1.2" have a dot but no real extension; add the type's one.
        if let ext, !ext.isEmpty {
            let current = (name as NSString).pathExtension
            let known = !current.isEmpty && UTType(filenameExtension: current)?.isDeclared == true
            if !known && current.lowercased() != ext.lowercased() {
                name += ".\(ext)"
            }
        }
        return name
    }

    /// Copies under a hidden name first so the app never picks up a half-written file.
    private static func place(_ source: URL, named name: String, in folder: URL) throws {
        let fm = FileManager.default
        let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: partial)
        try fm.moveItem(at: partial, to: fm.uniqueURL(for: name, in: folder))
    }

    private static func placeText(_ text: String, named name: String, in folder: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        try place(temp, named: name, in: folder)
    }
}
