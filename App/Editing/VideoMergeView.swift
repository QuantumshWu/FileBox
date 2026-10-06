import AVFoundation
import SwiftUI

/// Asks for confirmation, then appends `second` after `first` into a new video next to `first`.
/// Both originals are kept.
struct VideoMergeView: View {
    let first: FileItem
    let second: FileItem

    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: VideoEditMergeModel

    init(first: FileItem, second: FileItem) {
        self.first = first
        self.second = second
        _model = StateObject(wrappedValue: VideoEditMergeModel(first: first, second: second))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    clipRow(model.order[0], badge: "A")
                    Label("然后", systemImage: "arrow.down")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    clipRow(model.order[1], badge: "B")
                    Button {
                        withAnimation { model.swapOrder() }
                    } label: {
                        Label("交换顺序", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(model.isMerging)
                } header: {
                    Text("A 然后 B")
                } footer: {
                    Text("新视频先播放 A，紧接着播放 B。两个原视频都会保留。")
                }

                Section {
                    LabeledContent("文件名") {
                        Text(model.outputName)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("保存到", value: folderName)
                } footer: {
                    Text(model.methodNote)
                }
            }
            .navigationTitle("合并视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if model.isMerging {
                            model.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("合并") {
                        model.merge(store: store, lock: lock) { dismiss() }
                    }
                    .bold()
                    .disabled(!model.canMerge)
                }
            }
            .overlay {
                if let progress = model.progress {
                    VideoEditProgressOverlay(title: model.status, progress: progress) {
                        model.cancel()
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isMerging)
        .task { await model.load() }
        .onDisappear { model.leftScreen() }
        .alert("无法合并", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var folderName: String {
        store.isRoot(model.destination) ? "FileBox" : model.destination.lastPathComponent
    }

    private func clipRow(_ item: FileItem, badge: String) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item, side: 56)
                .overlay(alignment: .topLeading) {
                    Text(badge)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: -4, y: -4)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(2)
                Text(model.detail(for: item))
                    .font(.caption)
                    .foregroundStyle(model.failures[item.url] == nil ? Color.secondary : Color.red)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Loading, ordering and exporting for `VideoMergeView`.
@MainActor
final class VideoEditMergeModel: ObservableObject {
    /// The clips in playback order: A, then B.
    @Published private(set) var order: [FileItem]
    @Published private(set) var clips: [URL: VideoEditClip] = [:]
    @Published private(set) var failures: [URL: String] = [:]
    /// Set while merging.
    @Published private(set) var progress: Double?
    @Published private(set) var status = ""
    @Published var errorMessage: String?

    /// Folder of the first video, where the result goes.
    let destination: URL

    private var task: Task<Void, Never>?
    /// False once the sheet has gone, e.g. because the app locked itself in the background while
    /// the export kept running; results are then reported with a banner instead of an alert.
    private var isOnScreen = false

    init(first: FileItem, second: FileItem) {
        order = [first, second]
        destination = first.url.deletingLastPathComponent()
    }

    var isMerging: Bool { progress != nil }
    var canMerge: Bool { !isMerging && loadedClips != nil }

    var outputName: String {
        order.map { VideoEditExport.baseName(of: $0, maxBytes: 110) }.joined(separator: " + ") + ".mov"
    }

    var methodNote: String {
        if !failures.isEmpty { return "有视频无法读取，不能合并。" }
        guard let clips = loadedClips else { return "正在读取视频信息…" }
        if VideoEditMerger.canPassthrough(clips) {
            return "两个视频的尺寸、方向和编码相同，会直接无损拼接，速度快，画质不变。"
        }
        return "两个视频的尺寸、方向或编码不同，需要重新编码（较慢）。画面统一成 A 的尺寸，比例不同的地方加黑边。"
    }

    /// Both clips in order, once they are loaded.
    private var loadedClips: [VideoEditClip]? {
        let loaded = order.compactMap { clips[$0.url] }
        return loaded.count == order.count ? loaded : nil
    }

    func detail(for item: FileItem) -> String {
        if let failure = failures[item.url] { return failure }
        guard let clip = clips[item.url] else { return "正在读取…" }
        let size = clip.orientedSize
        let length = VideoEditExport.timeText(clip.duration.seconds, tenths: false)
        return "\(length) · \(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }

    func load() async {
        isOnScreen = true
        for item in order where clips[item.url] == nil && failures[item.url] == nil {
            do {
                let clip = try await VideoEditClip.load(item.url)
                clips[item.url] = clip
            } catch {
                if Task.isCancelled { return }
                failures[item.url] = VideoEditExport.loadMessage(for: error)
            }
        }
    }

    func swapOrder() {
        guard !isMerging else { return }
        order.reverse()
    }

    /// Exports A followed by B and saves it as "<A> + <B>.mov" in `destination`. Lossless when the
    /// clips allow it; if that fails, it automatically tries again with re-encoding.
    /// `onSaved` closes the sheet; it is skipped when the sheet has already gone.
    func merge(store: FileStore, lock: LockManager, onSaved: @escaping () -> Void) {
        guard canMerge, let sources = loadedClips else { return }
        let name = outputName
        let folder = destination
        let bytes = order.reduce(Int64(0)) { $0 + $1.size }
        progress = 0
        task = Task {
            var output: URL?
            do {
                try VideoEditExport.ensureFreeSpace(bytes)
                let url = try VideoEditExport.makeTemporaryURL()
                output = url
                if VideoEditMerger.canPassthrough(sources) {
                    status = "正在无损合并…"
                    do {
                        try await export(sources, reencode: false, keepsHDR: false, to: url)
                    } catch {
                        guard !Task.isCancelled, VideoEditExport.shouldRetryWithReencode(error) else { throw error }
                        try? FileManager.default.removeItem(at: url)
                        status = "无损合并没有成功，正在重新编码…"
                        try await exportReencoded(sources, to: url)
                    }
                } else {
                    status = "正在重新编码合并…"
                    try await exportReencoded(sources, to: url)
                }
                try Task.checkCancellation()
                guard let saved = store.add(fileAt: url, named: name, into: folder, moving: true) else {
                    throw VideoEditError.saveFailed
                }
                VideoEditExport.discard(url)
                task = nil
                progress = nil
                let done = "已合并为「\(saved.lastPathComponent)」"
                if isOnScreen {
                    store.show(done)
                    onSaved()
                } else {
                    VideoEditExport.announce(done, store: store, lock: lock)
                }
            } catch {
                if let output { VideoEditExport.discard(output) }
                task = nil
                progress = nil
                if Task.isCancelled { return }
                let message = VideoEditExport.message(for: error)
                if isOnScreen {
                    errorMessage = message
                } else {
                    VideoEditExport.announce("视频合并没有完成：\(message)", store: store, lock: lock)
                }
            }
        }
    }

    /// Re-encodes, keeping HDR when a clip has it. If the HDR export fails, tries once more in SDR,
    /// which every device can encode.
    private func exportReencoded(_ sources: [VideoEditClip], to url: URL) async throws {
        let hasHDR = sources.contains { $0.hdrTransferFunction != nil }
        do {
            try await export(sources, reencode: true, keepsHDR: hasHDR, to: url)
        } catch {
            guard hasHDR, !Task.isCancelled, VideoEditExport.shouldRetryWithReencode(error) else { throw error }
            try? FileManager.default.removeItem(at: url)
            status = "HDR 导出没有成功，正在改用 SDR 重新编码…"
            try await export(sources, reencode: true, keepsHDR: false, to: url)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The sheet went away; a running export continues.
    func leftScreen() {
        isOnScreen = false
    }

    private func export(_ sources: [VideoEditClip], reencode: Bool, keepsHDR: Bool, to url: URL) async throws {
        let (composition, track) = try VideoEditMerger.composition(of: sources, passthrough: !reencode)
        let preset: String
        if reencode {
            preset = await VideoEditExport.reencodePreset(for: composition)
        } else {
            preset = AVAssetExportPresetPassthrough
            let compatible = await AVAssetExportSession.compatibility(
                ofExportPreset: preset, with: composition, outputFileType: .mov
            )
            guard compatible else { throw VideoEditError.passthroughUnsupported }
        }
        try Task.checkCancellation()
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw VideoEditError.exportFailed
        }
        if reencode {
            session.videoComposition = VideoEditMerger.videoComposition(
                for: sources,
                in: composition,
                track: track,
                keepsHDR: keepsHDR && preset == AVAssetExportPresetHEVCHighestQuality
            )
        }
        progress = 0
        try await VideoEditExport.run(session, to: url) { [weak self] value in
            guard let self, self.task != nil else { return }
            self.progress = value
        }
    }
}
