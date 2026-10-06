import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Shortcuts action "保存截图到 FileBox". Together with the "截屏" action and Back Tap it puts
/// screenshots straight into the vault, so they never reach Photos. It runs in the background app
/// process and only uses `Vault`; open folders refresh the next time the app becomes active.
struct CaptureSaveScreenshotIntent: AppIntent {
    static var title: LocalizedStringResource = "保存截图到 FileBox"
    static var description: IntentDescription? = IntentDescription("把截图存进 FileBox 的「截图」文件夹，不会进入「照片」。")
    static var openAppWhenRun: Bool = false

    // `supportedContentTypes:` needs iOS 18; the type identifier form works from iOS 16.
    @Parameter(title: "截图", supportedTypeIdentifiers: ["public.image"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var screenshot: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("保存\(\.$screenshot)到 FileBox")
    }

    /// Silent on success: a confirmation would show up in the next screenshot.
    func perform() async throws -> some IntentResult {
        let ext = CaptureIntentFiles.fileExtension(of: screenshot, fallback: "png")
        let name = "截图 \(CaptureIntentFiles.timestamp()).\(ext)"
        try CaptureIntentFiles.save(screenshot, named: name, in: Vault.folder(Vault.screenshotsName))
        return .result()
    }
}

/// Shortcuts action "保存文件到 FileBox": any files into 收件箱.
struct CaptureSaveFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "保存文件到 FileBox"
    static var description: IntentDescription? = IntentDescription("把文件存进 FileBox 的「收件箱」。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "文件", supportedTypeIdentifiers: ["public.data"], inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("保存\(\.$files)到 FileBox")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !files.isEmpty else { throw CaptureIntentError.emptyFile }
        let folder = Vault.folder(Vault.receivedName)
        for file in files {
            try CaptureIntentFiles.save(file, named: CaptureIntentFiles.name(of: file), in: folder)
        }
        let count = files.count
        let dialog: IntentDialog = count == 1 ? "已保存到「收件箱」" : "已保存 \(count) 个文件到「收件箱」"
        return .result(dialog: dialog)
    }
}

/// Lists both actions in Shortcuts and Spotlight right after installation.
struct CaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureSaveScreenshotIntent(),
            phrases: ["用\(.applicationName)保存截图", "保存截图到\(.applicationName)"],
            shortTitle: "保存截图",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: CaptureSaveFilesIntent(),
            phrases: ["用\(.applicationName)保存文件", "保存文件到\(.applicationName)"],
            shortTitle: "保存文件",
            systemImageName: "tray.and.arrow.down"
        )
    }
}

/// Failures Shortcuts shows to the user.
private enum CaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyFile
    case saveFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyFile: return "没有收到文件内容"
        case .saveFailed(let reason): return "保存到 FileBox 失败：\(reason)"
        }
    }
}

/// Puts files handed over by Shortcuts into the vault.
private enum CaptureIntentFiles {
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }

    /// The file's own extension, else the one for its type, else `fallback`.
    static func fileExtension(of file: IntentFile, fallback: String) -> String {
        let own = (file.filename as NSString).pathExtension
        if !own.isEmpty { return own.lowercased() }
        return file.type?.preferredFilenameExtension ?? fallback
    }

    /// The name Shortcuts gave the file, with an extension added when it has none.
    static func name(of file: IntentFile) -> String {
        let clean = sanitizedFileName(file.filename)
        let base = clean.isEmpty ? "文件" : clean
        guard (base as NSString).pathExtension.isEmpty, let ext = file.type?.preferredFilenameExtension
        else { return base }
        return base + "." + ext
    }

    /// Copies the file into `folder` under a free name, or writes its data when there is no
    /// readable file behind it (a screenshot usually arrives only as data).
    @discardableResult
    static func save(_ file: IntentFile, named name: String, in folder: URL) throws -> URL {
        if let source = file.fileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            if let placed = try? Vault.place(source, named: name, in: folder, move: false) { return placed }
        }
        let data = file.data
        guard !data.isEmpty else { throw CaptureIntentError.emptyFile }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            return try Vault.place(temp, named: name, in: folder, move: true)
        } catch {
            try? fm.removeItem(at: temp)
            throw CaptureIntentError.saveFailed(error.localizedDescription)
        }
    }
}
