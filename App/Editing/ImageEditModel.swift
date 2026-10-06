import SwiftUI
import UIKit

/// The tools in the image editor's bottom bar.
enum ImageEditTool: Hashable {
    case crop, rotate, adjust
}

/// Crop shape presets. Ratios are width / height of the image as currently rotated.
enum ImageEditAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeFour, sixteenNine, nineSixteen

    var id: Self { self }

    var title: String {
        switch self {
        case .free: return "自由"
        case .original: return "原始"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    /// nil for a free crop. `imageSize` is the size of the rotated image.
    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.width > 0 && imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }

    /// The same shape turned by 90°, for when the image rotates under the crop.
    var rotated: ImageEditAspect {
        switch self {
        case .fourThree: return .threeFour
        case .threeFour: return .fourThree
        case .sixteenNine: return .nineSixteen
        case .nineSixteen: return .sixteenNine
        case .free, .original, .square: return self
        }
    }
}

/// Everything the user changed. Applied in this order: colours, rotation and flip, crop.
struct ImageEditState: Equatable {
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Crop in unit coordinates (top-left origin) of the rotated and flipped image.
    var crop = ImageEditState.fullCrop
    var aspect: ImageEditAspect = .free
    /// Clockwise quarter turns (0...3), applied before the flip.
    var quarterTurns = 0
    /// Mirrored left to right after rotating.
    var flipped = false
    /// Slider positions in -1...1; 0 leaves the image unchanged.
    var brightness: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var autoEnhance = false

    var isCropped: Bool { crop != Self.fullCrop }
    var hasAdjustments: Bool { brightness != 0 || contrast != 0 || saturation != 0 || autoEnhance }
    var hasEdits: Bool { isCropped || quarterTurns != 0 || flipped || hasAdjustments }

    /// True if both give the same uncropped pixels, so the preview needs no new render.
    func rendersSame(as other: ImageEditState) -> Bool {
        quarterTurns == other.quarterTurns && flipped == other.flipped
            && brightness == other.brightness && contrast == other.contrast
            && saturation == other.saturation && autoEnhance == other.autoEnhance
    }

    /// `rect` limited to the unit square.
    static func clampedUnit(_ rect: CGRect) -> CGRect {
        let x = min(max(rect.minX, 0), 1)
        let y = min(max(rect.minY, 0), 1)
        return CGRect(x: x, y: y, width: min(max(rect.width, 0), 1 - x), height: min(max(rect.height, 0), 1 - y))
    }
}

/// One image editor session: the downsampled preview, the edits and saving the result.
@MainActor
final class ImageEditModel: ObservableObject {
    let item: FileItem

    @Published var state = ImageEditState() {
        didSet {
            trackPreviewCrop(from: oldValue)
            if !state.rendersSame(as: oldValue) { scheduleRender() }
        }
    }
    @Published var tool: ImageEditTool = .crop
    /// The downsampled image with colours, rotation and flip applied, not cropped.
    @Published private(set) var preview: CGImage?
    @Published private(set) var loadError: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isAnalyzing = false
    @Published var saveError: String?
    /// Short hint shown over the image.
    @Published private(set) var notice: String?

    /// Upright downsampled original that every preview is rendered from.
    private var base: CGImage?
    /// Upright pixel size of the full image.
    private var fullSize: CGSize = .zero
    /// Auto-enhance analysis of `base`, computed the first time it is switched on.
    private var autoFilters: [ImageEditAutoFilter]?
    private var needsRender = false
    private var isRendering = false
    /// Orientation `preview` was rendered with and the crop in that orientation, so the cropped
    /// preview stays right while a rotated or flipped one is still rendering.
    private var previewTurns = 0
    private var previewFlipped = false
    private var previewCrop = ImageEditState.fullCrop

    init(item: FileItem) {
        self.item = item
    }

    /// Size of the full image as currently rotated.
    var displaySize: CGSize {
        state.quarterTurns % 2 == 0 ? fullSize : CGSize(width: fullSize.height, height: fullSize.width)
    }

    /// Locked crop shape (width / height), nil for a free crop.
    var cropRatio: CGFloat? {
        state.aspect.ratio(imageSize: displaySize)
    }

    func load() async {
        guard base == nil, loadError == nil else { return }
        let url = item.url
        let loaded = await Task.detached(priority: .userInitiated) {
            ImageEditRenderer.loadPreview(url)
        }.value
        guard let loaded else {
            loadError = "文件可能已损坏，或者不是能编辑的图片格式。"
            return
        }
        base = loaded.image
        fullSize = loaded.fullSize
        preview = loaded.image
        if state.hasEdits { scheduleRender() }
    }

    /// The preview cut down to the crop, for the tools that show the result.
    func croppedPreview(_ image: CGImage) -> CGImage {
        guard previewCrop != ImageEditState.fullCrop else { return image }
        let rect = ImageEditRenderer.pixelRect(previewCrop, width: CGFloat(image.width), height: CGFloat(image.height))
        return image.cropping(to: rect) ?? image
    }

    private func matchesPreview(_ other: ImageEditState) -> Bool {
        other.quarterTurns == previewTurns && other.flipped == previewFlipped
    }

    /// Keeps `previewCrop` in the preview's orientation: the current crop while they match,
    /// otherwise the last crop that was made in it.
    private func trackPreviewCrop(from old: ImageEditState) {
        if matchesPreview(state) {
            previewCrop = state.crop
        } else if matchesPreview(old) {
            previewCrop = old.crop
        }
    }

    // MARK: - Editing

    func rotate(clockwise: Bool) {
        var next = state
        // The image is turned first and mirrored second, so turning a mirrored image runs the other way.
        next.quarterTurns = (next.quarterTurns + (clockwise == next.flipped ? 3 : 1)) % 4
        let crop = next.crop
        next.crop = ImageEditState.clampedUnit(clockwise
            ? CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
            : CGRect(x: crop.minY, y: 1 - crop.maxX, width: crop.height, height: crop.width))
        next.aspect = next.aspect.rotated
        state = next
    }

    func flip() {
        var next = state
        next.flipped.toggle()
        next.crop.origin.x = 1 - next.crop.maxX
        next.crop = ImageEditState.clampedUnit(next.crop)
        state = next
    }

    /// Selects a crop shape; a fixed one takes the largest crop of that shape around the current centre.
    func setAspect(_ aspect: ImageEditAspect) {
        var next = state
        next.aspect = aspect
        let size = displaySize
        if let ratio = aspect.ratio(imageSize: size), size.width > 0, size.height > 0 {
            let width = min(size.width, size.height * ratio)
            let height = width / ratio
            let x = min(max(next.crop.midX * size.width - width / 2, 0), size.width - width)
            let y = min(max(next.crop.midY * size.height - height / 2, 0), size.height - height)
            next.crop = ImageEditState.clampedUnit(CGRect(
                x: x / size.width,
                y: y / size.height,
                width: width / size.width,
                height: height / size.height
            ))
        }
        state = next
    }

    func resetCrop() {
        var next = state
        next.crop = ImageEditState.fullCrop
        next.aspect = .free
        state = next
    }

    func resetAdjustments() {
        var next = state
        next.brightness = 0
        next.contrast = 0
        next.saturation = 0
        next.autoEnhance = false
        state = next
    }

    func resetAll() {
        state = ImageEditState()
    }

    func toggleAutoEnhance() async {
        if state.autoEnhance {
            state.autoEnhance = false
            return
        }
        guard !isAnalyzing, let base else { return }
        if autoFilters == nil {
            isAnalyzing = true
            let filters = await Task.detached(priority: .userInitiated) {
                ImageEditRenderer.autoFilters(for: base)
            }.value
            isAnalyzing = false
            autoFilters = filters
        }
        if autoFilters?.isEmpty ?? true {
            flash("这张图片不需要自动增强")
        } else {
            state.autoEnhance = true
        }
    }

    // MARK: - Preview

    /// Renders the preview off the main thread; changes made meanwhile are coalesced into one more render.
    private func scheduleRender() {
        needsRender = true
        guard !isRendering, base != nil else { return }
        isRendering = true
        Task { await renderLoop() }
    }

    private func renderLoop() async {
        while needsRender, let base {
            needsRender = false
            let state = self.state
            let filters = state.autoEnhance ? (autoFilters ?? []) : []
            let image = await Task.detached(priority: .userInitiated) {
                ImageEditRenderer.renderPreview(base, state: state, auto: filters)
            }.value
            if let image {
                previewTurns = state.quarterTurns
                previewFlipped = state.flipped
                previewCrop = matchesPreview(self.state) ? self.state.crop : state.crop
                preview = image
            }
        }
        isRendering = false
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if notice == text { notice = nil }
        }
    }

    // MARK: - Saving

    /// Renders the full-size result and adds it next to the original. Returns true on success;
    /// otherwise `saveError` says what went wrong.
    func save(into store: FileStore) async -> Bool {
        guard !isSaving, let base else { return false }
        isSaving = true
        // Leaving the app locks it and closes the editor, but the save carries on.
        let background = ImageEditBackgroundWatch()
        defer {
            background.end()
            isSaving = false
        }
        let source = item.url
        let state = self.state
        let filters = state.autoEnhance ? (autoFilters ?? []) : []
        let previewWidth = CGFloat(base.width)
        var output: ImageEditRenderer.Output
        do {
            let software = background.enteredBackground
            output = try await Self.export(source, state: state, auto: filters, previewWidth: previewWidth,
                                           software: software)
            if background.enteredBackground && !software {
                // iOS refuses GPU work in the background, so that render may be broken: redo it on the CPU.
                try? FileManager.default.removeItem(at: output.url)
                output = try await Self.export(source, state: state, auto: filters, previewWidth: previewWidth,
                                               software: true)
            }
        } catch {
            let reason = (error as? ImageEditError)?.errorDescription ?? "生成图片时出错：\(error.localizedDescription)"
            saveError = reason
            if background.enteredBackground { store.show("图片没有保存。\(reason)") }
            return false
        }
        let name = Self.editedName(for: item.name, pathExtension: output.pathExtension)
        guard let dest = store.add(fileAt: output.url, named: name, into: source.deletingLastPathComponent(), moving: true)
        else {
            // add() has already shown the reason in the banner.
            try? FileManager.default.removeItem(at: output.url)
            saveError = "无法把编辑后的图片存进文件夹。"
            return false
        }
        if let size = output.reducedSize {
            store.show("已另存为「\(dest.lastPathComponent)」（原图太大，已缩小为 \(Int(size.width))×\(Int(size.height))）")
        } else {
            store.show("已另存为「\(dest.lastPathComponent)」")
        }
        return true
    }

    /// One export off the main thread.
    private static func export(_ source: URL, state: ImageEditState, auto: [ImageEditAutoFilter],
                               previewWidth: CGFloat, software: Bool) async throws -> ImageEditRenderer.Output {
        try await Task.detached(priority: .userInitiated) {
            try ImageEditRenderer.export(source, state: state, auto: auto, previewWidth: previewWidth, software: software)
        }.value
    }

    /// "<原名> 编辑.<ext>"; editing an edited copy again gets a number instead of a second suffix.
    private static func editedName(for original: String, pathExtension: String) -> String {
        var base = (original as NSString).deletingPathExtension
        let suffix = " 编辑"
        if base.hasSuffix(suffix) { base.removeLast(suffix.count) }
        if base.isEmpty { base = "图片" }
        return "\(base)\(suffix).\(pathExtension)"
    }
}

/// Keeps a save running for a while after the app leaves the foreground, and notes whether it did,
/// because iOS refuses GPU work from apps in the background.
@MainActor
private final class ImageEditBackgroundWatch {
    private(set) var enteredBackground: Bool
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observer: NSObjectProtocol?

    init() {
        enteredBackground = UIApplication.shared.applicationState == .background
        task = UIApplication.shared.beginBackgroundTask(withName: "ImageEditSave") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endTask()
            }
        }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.enteredBackground = true
            }
        }
    }

    /// Call once the save is over.
    func end() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        endTask()
    }

    private func endTask() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
