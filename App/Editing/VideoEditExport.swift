import AVFoundation
import SwiftUI
import UIKit

/// Why a video edit could not be finished, worded for the user.
enum VideoEditError: LocalizedError, Equatable {
    case unplayable
    case noVideoTrack
    case unreadableDuration
    case passthroughUnsupported
    case notEnoughSpace(needed: Int64, available: Int64)
    case interrupted
    case exportFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unplayable:
            return "iOS 无法播放这种视频格式，不能编辑"
        case .noVideoTrack:
            return "这个文件里没有视频画面"
        case .unreadableDuration:
            return "无法读取视频时长"
        case .passthroughUnsupported:
            return "这个视频不支持快速（无损）剪辑，请改用「精确」模式"
        case .notEnoughSpace(let needed, let available):
            let need = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "存储空间不足：大约需要 \(need)，只剩 \(free)。请清理一些空间后再试"
        case .interrupted:
            return "导出被中断了：App 进入后台后系统停止了导出。导出时请不要离开 App"
        case .exportFailed:
            return "导出失败，请再试一次"
        case .saveFailed:
            return "导出完成，但没能保存到文件夹里"
        }
    }

    /// Errors that a second attempt with another method would hit again.
    var isFinal: Bool {
        switch self {
        case .notEnoughSpace, .interrupted, .saveFailed: return true
        default: return false
        }
    }
}

/// Shared export plumbing of the video editors: temporary files, a free-space check, progress,
/// cancellation, and a background task so a short trip out of the app does not kill the export.
enum VideoEditExport {
    /// A fresh temporary file for one export, in its own folder so nothing else is ever overwritten.
    static func makeTemporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoEdit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("video.mov")
    }

    /// Deletes a temporary export file together with its folder.
    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Refuses to start when `bytes` (plus some headroom) clearly do not fit on the phone.
    static func ensureFreeSpace(_ bytes: Int64) throws {
        let needed = max(0, bytes) + 50 * 1024 * 1024
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        if available < needed {
            throw VideoEditError.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// HEVC when this asset can be encoded with it, otherwise the best H.264 preset.
    static func reencodePreset(for asset: AVAsset) async -> String {
        let hevc = AVAssetExportPresetHEVCHighestQuality
        if await AVAssetExportSession.compatibility(ofExportPreset: hevc, with: asset, outputFileType: .mov) {
            return hevc
        }
        return AVAssetExportPresetHighestQuality
    }

    /// Exports `session` to `url` as a QuickTime movie. Cancelling the calling task cancels the export.
    /// The screen stays on meanwhile, and if the app is sent to the background the export keeps
    /// running for as long as iOS allows, then fails with `VideoEditError.interrupted`.
    @MainActor
    static func run(
        _ session: AVAssetExportSession,
        to url: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let background = VideoEditBackgroundGuard()
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled
            background.end()
        }
        try Task.checkCancellation()
        let work = Task { @MainActor in
            try await VideoEditExport.perform(session, to: url, progress: progress)
        }
        background.begin {
            work.cancel()
            session.cancelExport()
        }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            if background.expired { throw VideoEditError.interrupted }
            throw error
        }
    }

    @MainActor
    private static func perform(
        _ session: AVAssetExportSession,
        to url: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        progress(0)
        if #available(iOS 18.0, *) {
            let monitor = Task { @MainActor in
                for await state in session.states(updateInterval: 0.1) {
                    // A value buffered before the export ended must not bring the progress back.
                    if Task.isCancelled { break }
                    if case .exporting(let current) = state {
                        progress(current.fractionCompleted)
                    }
                }
            }
            defer { monitor.cancel() }
            try await withTaskCancellationHandler {
                try await session.export(to: url, as: .mov)
            } onCancel: {
                session.cancelExport()
            }
        } else {
            session.outputURL = url
            session.outputFileType = .mov
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            defer { monitor.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.exportAsynchronously {
                        switch session.status {
                        case .completed:
                            continuation.resume()
                        case .cancelled:
                            continuation.resume(throwing: CancellationError())
                        default:
                            continuation.resume(throwing: session.error ?? VideoEditError.exportFailed)
                        }
                    }
                }
            } onCancel: {
                session.cancelExport()
            }
        }
        progress(1)
    }

    /// Whether a failed lossless attempt is worth retrying with re-encoding.
    static func shouldRetryWithReencode(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? VideoEditError { return !error.isFinal }
        let ns = error as NSError
        if isDiskFull(ns) { return false }
        if ns.domain == AVFoundationErrorDomain, AVError.Code(rawValue: ns.code) == .operationInterrupted {
            return false
        }
        return true
    }

    /// A Chinese explanation of an export error.
    static func message(for error: Error) -> String {
        if let error = error as? VideoEditError, let text = error.errorDescription { return text }
        let ns = error as NSError
        if isDiskFull(ns) { return "存储空间不足，导出没有完成。请清理一些空间后再试" }
        if ns.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: ns.code) {
            case .operationInterrupted?:
                return VideoEditError.interrupted.errorDescription ?? "导出被中断了"
            case .operationNotSupportedForAsset?:
                return "这个视频不支持这种处理方式"
            case .fileFormatNotRecognized?, .decoderNotFound?:
                return "无法解码这个视频"
            default:
                break
            }
        }
        return "导出失败：\(error.localizedDescription)"
    }

    /// A Chinese explanation of why a video could not be opened.
    static func loadMessage(for error: Error) -> String {
        if let error = error as? VideoEditError, let text = error.errorDescription { return text }
        return "无法读取这个视频：\(error.localizedDescription)"
    }

    /// File name without its extension, cut to at most `maxBytes` of UTF-8 so names built from it
    /// stay within the file system's 255-byte limit (a Chinese character takes 3 bytes).
    static func baseName(of item: FileItem, maxBytes: Int) -> String {
        var base = sanitizedFileName((item.name as NSString).deletingPathExtension)
        while base.utf8.count > maxBytes { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "视频" : base
    }

    /// "1:05.3" (or "1:02:05.3"); without tenths for durations in lists.
    static func timeText(_ seconds: Double, tenths: Bool = true) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let totalTenths = Int((value * 10).rounded(.down))
        let whole = totalTenths / 10
        let hours = whole / 3600
        let minutes = (whole / 60) % 60
        let secs = whole % 60
        var text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
        if tenths { text += ".\(totalTenths % 10)" }
        return text
    }

    /// Length of a selection: "12.6 秒" below a minute, "1:02.3" above.
    static func lengthText(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.1f 秒", max(0, seconds)) : timeText(seconds)
    }

    private static func isDiskFull(_ error: NSError) -> Bool {
        if error.domain == AVFoundationErrorDomain, error.code == AVError.Code.diskFull.rawValue { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(underlying) }
        return false
    }
}

/// Keeps the app alive for a while if it goes to the background mid-export, and stops the export
/// cleanly when that time runs out.
@MainActor
private final class VideoEditBackgroundGuard {
    private(set) var expired = false
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var onExpire: (() -> Void)?

    func begin(onExpire: @escaping () -> Void) {
        self.onExpire = onExpire
        identifier = UIApplication.shared.beginBackgroundTask(withName: "FileBox 视频导出") { [weak self] in
            MainActor.assumeIsolated {
                self?.expire()
            }
        }
    }

    func end() {
        onExpire = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    private func expire() {
        expired = true
        onExpire?()
        end()
    }
}

/// Dimmed card with export progress, the "stay in the app" warning and a cancel button.
struct VideoEditProgressOverlay: View {
    let title: String
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                ProgressView(value: min(max(progress, 0), 1))
                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Label("导出时请不要离开 App", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("取消", role: .cancel) { onCancel() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(32)
        }
    }
}
