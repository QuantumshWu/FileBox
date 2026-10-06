import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One folder of the vault as a Photos-like grid or a plain list. Items can be dragged onto a
/// folder (move) or onto another video (merge), have a context menu, and can be multi-selected.
/// The root folder also carries the app's navigation (lock, capture, Wi-Fi transfer, settings).
struct FolderView: View {
    let folder: URL

    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var viewer: ViewerCoordinator
    @AppStorage("sortOrder") private var sort: SortOrder = .date
    /// List by default (the user prefers it); the grid is opt-in from the toolbar.
    @AppStorage("folderLayoutV2") private var layout: ItemLayout = .list
    /// Grid columns, changed by pinching (3...6).
    @AppStorage("folderGridColumns") private var gridColumns = 4
    /// Magnification at the last column change of the current pinch.
    @State private var pinchBase: CGFloat = 1

    @State private var items: [FileItem] = []
    @State private var loaded = false
    @State private var videoCount = 0
    @State private var query = ""
    @State private var quickLookURL: URL?
    /// Screens opened from the root toolbar; a NavigationLink inside a Menu is unreliable.
    @State private var menuRoute: Route?

    @State private var selecting = false
    @State private var selection: Set<URL> = []
    @State private var dropTarget: URL?

    @State private var sheet: FolderSheet?
    /// Shown as soon as the current sheet has gone, since two sheets cannot be up at once.
    @State private var pendingSheet: FolderSheet?
    @State private var cover: FolderCover?

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: FileItem?
    @State private var renameText = ""
    @State private var pendingDelete: [FileItem]?

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Photos library identifiers of just-imported items, while asking whether to delete them there.
    @State private var pendingPhotoDeletion: [String]?
    @State private var progress: String?

    private enum ItemLayout: String {
        case grid, list
    }

    private enum FolderSheet: Identifiable {
        case move([FileItem])
        case mergePicker(FileItem)
        case merge(first: FileItem, second: FileItem)
        /// `directory` is resolved once when the sheet opens; resolving a bookmark can be slow.
        case documents(showsHint: Bool, directory: URL?)

        var id: String {
            switch self {
            case .move(let items): return "move:" + items.map(\.url.path).joined(separator: "|")
            case .mergePicker(let item): return "pick:" + item.url.path
            case .merge(let first, let second): return "merge:" + first.url.path + "|" + second.url.path
            case .documents: return "documents"
            }
        }
    }

    private enum FolderCover: Identifiable {
        case editImage(FileItem)
        case trimVideo(FileItem)

        var id: String {
            switch self {
            case .editImage(let item): return "image:" + item.url.path
            case .trimVideo(let item): return "trim:" + item.url.path
            }
        }
    }

    private var isRoot: Bool { store.isRoot(folder) }
    private var title: String { isRoot ? "FileBox" : folder.lastPathComponent }

    private var visibleItems: [FileItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        dialogs(presentations(content))
    }

    // MARK: - Grid and list

    private var content: some View {
        ScrollView {
            switch layout {
            case .grid: grid
            case .list: list
            }
        }
        .simultaneousGesture(pinch, including: layout == .grid ? .all : .subviews)
        .overlay { overlayContent }
        .navigationTitle(selecting ? "已选择 \(selection.count) 项" : title)
        .navigationBarBackButtonHidden(selecting)
        .searchable(text: $query, prompt: "搜索文件名")
        .toolbar { toolbarContent }
        .refreshable {
            store.collectIncoming()
            reload()
        }
        .quickLookPreview($quickLookURL, in: previewURLs)
        .navigationDestination(item: $menuRoute) { route in
            routeDestination(route)
        }
        .onAppear(perform: reload)
        .onChange(of: store.revision) { reload() }
        .onChange(of: sort) { reload() }
    }

    /// Import progress, or an empty state that lets touches through so pull-to-refresh still works.
    @ViewBuilder
    private var overlayContent: some View {
        if let progress {
            ProgressView(progress)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if loaded && items.isEmpty {
            ContentUnavailableView(
                "这里还没有文件",
                systemImage: "tray",
                description: Text(isRoot
                    ? "在其他 App 里点「分享」→ FileBox，\n或者点右上角的 + 导入"
                    : "点右上角的 + 导入，\n或者在上一层把文件拖到这个文件夹上")
            )
            .allowsHitTesting(false)
        } else if !query.isEmpty && visibleItems.isEmpty {
            ContentUnavailableView.search(text: query)
                .allowsHitTesting(false)
        }
    }

    private var columnCount: Int { min(max(gridColumns, 3), 6) }

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount),
            spacing: 2
        ) {
            ForEach(visibleItems) { item in
                cell(item)
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(visibleItems) { item in
                VStack(spacing: 0) {
                    row(item)
                    Divider()
                        .padding(.leading, selecting ? 120 : 84)
                }
            }
        }
    }

    /// Pinching out shows fewer, bigger squares; pinching in shows more, like in Photos.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / pinchBase
                if ratio > 1.25, columnCount > 3 {
                    pinchBase = value.magnification
                    withAnimation(.snappy) { gridColumns = columnCount - 1 }
                } else if ratio < 0.8, columnCount < 6 {
                    pinchBase = value.magnification
                    withAnimation(.snappy) { gridColumns = columnCount + 1 }
                }
            }
            .onEnded { _ in
                pinchBase = 1
            }
    }

    @ViewBuilder
    private func cell(_ item: FileItem) -> some View {
        if selecting {
            Button {
                toggle(item)
            } label: {
                FolderGridCell(item: item, isSelected: selection.contains(item.url))
            }
            .buttonStyle(FolderGridButtonStyle())
        } else {
            acceptingDrops(
                link(item, style: FolderGridButtonStyle()) {
                    FolderGridCell(item: item, isDropTarget: dropTarget == item.url)
                }
                .contentShape(.contextMenuPreview, FolderGridCell.shape(for: item))
                .contextMenu { menu(for: item) }
                .draggable(FolderDragRegistry.shared.token(for: item.url)) {
                    FolderDragPreview(item: item)
                },
                on: item
            )
        }
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        if selecting {
            let isSelected = selection.contains(item.url)
            Button {
                toggle(item)
            } label: {
                rowLabel(item, isSelected: isSelected)
            }
            .buttonStyle(FolderRowButtonStyle())
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        } else {
            acceptingDrops(
                link(item, style: FolderRowButtonStyle()) {
                    rowLabel(item, isSelected: nil)
                }
                .background(rowBackground(item))
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
                .contextMenu { menu(for: item) }
                .draggable(FolderDragRegistry.shared.token(for: item.url)) {
                    FolderDragPreview(item: item)
                },
                on: item
            )
        }
    }

    private func rowLabel(_ item: FileItem, isSelected: Bool?) -> some View {
        FileRow(item: item, isSelected: isSelected)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// Folders push their own view; files open in the media viewer or Quick Look.
    @ViewBuilder
    private func link<Content: View, Style: ButtonStyle>(
        _ item: FileItem,
        style: Style,
        @ViewBuilder label: () -> Content
    ) -> some View {
        let face = label()
        if item.isDirectory {
            NavigationLink(value: Route.folder(item.url)) {
                face
            }
            .buttonStyle(style)
        } else {
            Button {
                open(item)
            } label: {
                face
            }
            .buttonStyle(style)
        }
    }

    /// Folder rows take any dragged item, video rows take another video; other rows take nothing.
    @ViewBuilder
    private func acceptingDrops<Content: View>(_ content: Content, on item: FileItem) -> some View {
        if item.isDirectory || item.kind == .video {
            content.dropDestination(for: String.self) { tokens, _ in
                drop(tokens, on: item)
            } isTargeted: { targeted in
                if targeted {
                    dropTarget = item.url
                } else if dropTarget == item.url {
                    dropTarget = nil
                }
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func rowBackground(_ item: FileItem) -> some View {
        if dropTarget == item.url {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.15))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2))
                .padding(.horizontal, 6)
        } else {
            Color(uiColor: .systemBackground)
        }
    }

    // MARK: - Actions

    private func open(_ item: FileItem) {
        if item.isMedia {
            let media = visibleItems.filter(\.isMedia)
            if let index = media.firstIndex(where: { $0.url == item.url }) {
                viewer.open(media, at: index)
            }
        } else {
            quickLookURL = item.url
        }
    }

    private var previewURLs: [URL] {
        items.filter { !$0.isDirectory && !$0.isMedia }.map(\.url)
    }

    private func drop(_ tokens: [String], on target: FileItem) -> Bool {
        dropTarget = nil
        let targetPath = store.normalizedPath(target.url)
        let dragged = tokens
            .compactMap { FolderDragRegistry.shared.url(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && store.normalizedPath($0) != targetPath }
            .map { FileItem(url: $0) }
        guard !dragged.isEmpty else { return false }
        if target.isDirectory {
            store.move(dragged, into: target.url)
            return true
        }
        guard let video = dragged.first(where: { $0.kind == .video }) else {
            store.show("把视频拖到另一个视频上可以拼接")
            return false
        }
        // Let the drop animation finish before the sheet slides up.
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            sheet = .merge(first: target, second: video)
        }
        return true
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if !item.isDirectory {
            ShareLink(item: item.url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }
        if item.kind == .image {
            Button { cover = .editImage(item) } label: {
                Label("编辑图片", systemImage: "slider.horizontal.3")
            }
        }
        if item.kind == .video {
            Button { cover = .trimVideo(item) } label: {
                Label("剪辑视频", systemImage: "scissors")
            }
            if videoCount > 1 {
                Button { sheet = .mergePicker(item) } label: {
                    Label("拼接到…", systemImage: "film.stack")
                }
            }
        }
        Button { sheet = .move([item]) } label: {
            Label("移动到…", systemImage: "folder")
        }
        Button { startRename(item) } label: {
            Label("重命名", systemImage: "pencil")
        }
        Divider()
        Button(role: .destructive) { pendingDelete = [item] } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func startRename(_ item: FileItem) {
        renameText = item.name
        renaming = item
    }

    private func reload() {
        items = store.items(in: folder, sort: sort)
        videoCount = items.filter { $0.kind == .video }.count
        loaded = true
        selection.formIntersection(items.map(\.url))
        if selecting && items.isEmpty { endSelecting() }
    }

    // MARK: - Selection

    private var selectedItems: [FileItem] {
        items.filter { selection.contains($0.url) }
    }

    private var selectedFileURLs: [URL] {
        selectedItems.filter { !$0.isDirectory }.map(\.url)
    }

    private var allVisibleSelected: Bool {
        !visibleItems.isEmpty && visibleItems.allSatisfy { selection.contains($0.url) }
    }

    private func toggle(_ item: FileItem) {
        if selection.contains(item.url) {
            selection.remove(item.url)
        } else {
            selection.insert(item.url)
        }
    }

    private func toggleAll() {
        let urls = visibleItems.map(\.url)
        if allVisibleSelected {
            selection.subtract(urls)
        } else {
            selection.formUnion(urls)
        }
    }

    private func endSelecting() {
        selecting = false
        selection = []
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "取消全选" : "全选", action: toggleAll)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { endSelecting() }
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { sheet = .move(selectedItems) } label: {
                    Label("移动到…", systemImage: "folder")
                }
                .disabled(selection.isEmpty)
                Spacer()
                ShareLink(items: selectedFileURLs) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedFileURLs.isEmpty)
                Spacer()
                Button(role: .destructive) { pendingDelete = selectedItems } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        } else {
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button { lock.lock() } label: {
                        Label("锁定", systemImage: "lock")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("选择") { selecting = true }
                    .disabled(items.isEmpty)
                layoutButton
                addMenu
                moreMenu
            }
        }
    }

    /// Switches between the grid and the list; the icon shows what a tap switches to.
    private var layoutButton: some View {
        Button {
            layout = layout == .grid ? .list : .grid
        } label: {
            if layout == .grid {
                Label("列表", systemImage: "list.bullet")
            } else {
                Label("网格", systemImage: "square.grid.2x2")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            // One import at a time, so the progress overlay always belongs to the running one.
            Group {
                Button { showPhotoPicker = true } label: {
                    Label("从相册导入", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: {
                    Label("从「文件」导入", systemImage: "doc.badge.plus")
                }
                Button {
                    sheet = .documents(
                        showsHint: !FolderDocumentsLocation.isRemembered,
                        directory: FolderDocumentsLocation.directory
                    )
                } label: {
                    Label("从 Documents 导入", systemImage: "tray.and.arrow.down")
                }
            }
            .disabled(progress != nil)
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    private var moreMenu: some View {
        Menu {
            Picker("排序", selection: $sort) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            if isRoot {
                Divider()
                Button { menuRoute = .capture } label: {
                    Label("截图与录屏", systemImage: "record.circle")
                }
                Button { menuRoute = .transfer } label: {
                    Label("Wi-Fi 传输", systemImage: "wifi")
                }
                Button { menuRoute = .settings } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .folder(let url): FolderView(folder: url)
        case .capture: CaptureView()
        case .transfer: TransferView()
        case .settings: SettingsView()
        default: EmptyView()
        }
    }

    // MARK: - Sheets and covers

    private func presentations<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $sheet, onDismiss: showPendingSheet) { sheet in
                sheetContent(sheet)
                    .environmentObject(store)
                    .environmentObject(lock)
                    .environmentObject(viewer)
                    .environmentObject(PlaybackState.shared)
            }
            .fullScreenCover(item: $cover) { cover in
                coverContent(cover)
                    .environmentObject(store)
                    .environmentObject(lock)
                    .environmentObject(viewer)
                    .environmentObject(PlaybackState.shared)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task { await importPicked(urls) }
                case .failure(let error):
                    store.report(error)
                }
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoItems,
                maxSelectionCount: nil,
                selectionBehavior: .ordered,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            )
            .onChange(of: photoItems) {
                let picked = photoItems
                guard !picked.isEmpty else { return }
                photoItems = []
                Task { await importPhotos(picked) }
            }
    }

    @ViewBuilder
    private func sheetContent(_ shown: FolderSheet) -> some View {
        switch shown {
        case .move(let targets):
            FolderMovePicker(items: targets) { destination in
                store.move(targets, into: destination)
                sheet = nil
                if selecting { endSelecting() }
            }
        case .mergePicker(let video):
            FolderMergePicker(video: video, candidates: items.filter { $0.kind == .video && $0.url != video.url }) { picked in
                pendingSheet = .merge(first: picked, second: video)
                sheet = nil
            }
        case .merge(let first, let second):
            VideoMergeView(first: first, second: second)
        case .documents(let showsHint, let directory):
            FolderDocumentsSheet(showsHint: showsHint, directory: directory) { urls in
                sheet = nil
                importFromDocuments(urls)
            } onCancel: {
                sheet = nil
            }
        }
    }

    @ViewBuilder
    private func coverContent(_ shown: FolderCover) -> some View {
        switch shown {
        case .editImage(let item): ImageEditorView(item: item)
        case .trimVideo(let item): VideoTrimView(item: item)
        }
    }

    private func showPendingSheet() {
        guard let next = pendingSheet else { return }
        pendingSheet = nil
        sheet = next
    }

    // MARK: - Dialogs

    private func dialogs<Content: View>(_ content: Content) -> some View {
        content
            .alert("新建文件夹", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") { store.createFolder(named: newFolderName, in: folder) }
            }
            .alert("重命名", isPresented: renameBinding, presenting: renaming) { item in
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("确定") { store.rename(item, to: renameText) }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible, presenting: pendingDelete) { targets in
                Button("删除", role: .destructive) {
                    store.delete(targets)
                    if selecting { endSelecting() }
                }
                Button("取消", role: .cancel) {}
            } message: { targets in
                Text(targets.contains(where: \.isDirectory) ? "文件夹里的文件也会一起删除，删除后无法恢复。" : "删除后无法恢复。")
            }
            .confirmationDialog(photoDeletionTitle, isPresented: photoDeletionBinding, titleVisibility: .visible, presenting: pendingPhotoDeletion) { identifiers in
                Button("删除原件", role: .destructive) {
                    Task {
                        let message = await FolderPhotoOriginals.delete(identifiers)
                        store.show(message)
                    }
                }
                Button("保留", role: .cancel) {}
            } message: { _ in
                Text("文件已经保存在 FileBox 里。")
            }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let targets = pendingDelete else { return "" }
        return targets.count == 1 ? "删除「\(targets[0].name)」？" : "删除这 \(targets.count) 项？"
    }

    private var photoDeletionBinding: Binding<Bool> {
        Binding(get: { pendingPhotoDeletion != nil }, set: { if !$0 { pendingPhotoDeletion = nil } })
    }

    private var photoDeletionTitle: String {
        "要从「照片」删除这 \(pendingPhotoDeletion?.count ?? 0) 个原件吗？"
    }

    // MARK: - Importing

    /// Files from the 「文件」 or Documents picker; FileStore handles their security scope.
    private func importPicked(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let activity = FolderImportActivity()
        defer { activity.end() }
        progress = "正在导入…"
        await store.importFiles(urls, into: folder)
        progress = nil
    }

    private func importFromDocuments(_ urls: [URL]) {
        guard let last = urls.last else { return }
        FolderDocumentsLocation.remember(folderOf: last)
        Task { await importPicked(urls) }
    }

    /// Copies the picked photos and videos in, then offers to delete the originals from Photos.
    private func importPhotos(_ picked: [PhotosPickerItem]) async {
        let activity = FolderImportActivity()
        defer { activity.end() }
        var files: [URL] = []
        var identifiers: [URL: String] = [:]
        var failed = 0
        for (index, item) in picked.enumerated() {
            progress = "正在导入 \(index + 1)/\(picked.count)…"
            do {
                if let file = try await item.loadTransferable(type: PickedFile.self) {
                    files.append(file.url)
                    if let identifier = item.itemIdentifier { identifiers[file.url] = identifier }
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }
        }
        await store.importFiles(files, into: folder, moving: true)
        let fm = FileManager.default
        // A moved file is no longer in its temporary folder; anything still there failed.
        let imported = files.filter { !fm.fileExists(atPath: $0.path) }
        for file in files {
            try? fm.removeItem(at: file.deletingLastPathComponent())
        }
        progress = nil
        if failed > 0 {
            // Replaces FileStore's "导入了 N 个文件" banner, so it carries both counts.
            store.show(imported.isEmpty
                ? "所选的 \(failed) 个项目没能导入"
                : "导入了 \(imported.count) 个，另有 \(failed) 个没能导入")
        }
        let originals = imported.compactMap { identifiers[$0] }
        if !originals.isEmpty {
            // A quick import can finish while the picker is still sliding away.
            try? await Task.sleep(nanoseconds: 500_000_000)
            pendingPhotoDeletion = originals
        }
    }
}

/// Asks iOS for extra time when the app goes to the background in the middle of an import, so a
/// long video from Photos or a file provider can finish instead of being cut off.
@MainActor
private final class FolderImportActivity {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        // iOS calls this on the main thread when the extra time runs out.
        id = UIApplication.shared.beginBackgroundTask(withName: "FileBox import") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Plain list-row look with a gray highlight while pressed.
private struct FolderRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color(uiColor: .systemGray5) : Color.clear)
    }
}

/// One file or folder: an optional selection mark, thumbnail, name and size/date.
struct FileRow: View {
    let item: FileItem
    /// nil outside selection mode.
    var isSelected: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
            }
            FolderThumbnail(item: item, side: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isDirectory && isSelected == nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        let date = item.modified.formatted(date: .abbreviated, time: .shortened)
        if item.isDirectory { return date }
        return "\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(date)"
    }
}
