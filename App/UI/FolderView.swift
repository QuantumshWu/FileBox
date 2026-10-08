import AVFoundation
import Combine
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
    /// Worked out once; resolving paths on every render is not free.
    private let isRoot: Bool

    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var viewer: ViewerCoordinator
    @EnvironmentObject private var nav: FolderUINavigation
    @AppStorage("sortOrder") private var sort: SortOrder = .date
    /// List by default (the user prefers it); the grid is opt-in from the toolbar.
    @AppStorage("folderLayoutV2") private var layout: ItemLayout = .list
    /// Grid columns, changed by pinching (3...6).
    @AppStorage("folderGridColumns") private var gridColumns = 4
    /// Magnification at the last column change of the current pinch.
    @State private var pinchBase: CGFloat = 1
    /// The file at the top of the grid, kept up to date by the scroll view. Only handed on as a
    /// binding, never read while rendering, so scrolling does not re-render the folder.
    @State private var gridAnchor: URL?

    @State private var items: [FileItem] = []
    /// Derived from `items` whenever they load, so rendering never works them out again.
    @State private var mediaItems: [FileItem] = []
    @State private var previewURLs: [URL] = []
    @State private var videoCount = 0
    @State private var loaded = false
    /// Bookkeeping that must not re-render the folder when it changes.
    @State private var tracking = Tracking()
    @State private var query = ""
    @State private var quickLookURL: URL?

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
    /// A delete asked for one row (swipe or context menu); its question appears at that row.
    @State private var pendingDelete: [FileItem]?
    /// A delete asked from the selection bar; its question appears at the bar's button.
    @State private var pendingBulkDelete: [FileItem]?

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Photos library identifiers of just-imported items, while asking whether to delete them there.
    @State private var pendingPhotoDeletion: [String]?
    @State private var importStatus: ImportStatus?
    @State private var importTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        isRoot = Self.plainPath(folder) == Self.rootPath
    }

    private static let rootPath = plainPath(Vault.root)
    private static let viewerPageChanged = Notification.Name("FileBoxViewerPageChanged")

    /// A path to compare without touching the disk.
    private static func plainPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private enum ItemLayout: String {
        case grid, list
    }

    private final class Tracking {
        /// Counts reloads, so only the newest result is applied.
        var generation = 0
        var revision = -1
        var sort: SortOrder?
        /// The file the viewer shows (or showed last).
        var lastViewed: URL?
    }

    private struct ImportStatus {
        var text: String
        /// nil while the total is not known.
        var fraction: Double?
        /// Imports from 「文件」 and Documents can be stopped between files.
        var cancellable = false
    }

    private enum FolderSheet: Identifiable {
        case move([FileItem])
        case mergeFolder(FileItem)
        case mergePicker(FileItem)
        case merge(first: FileItem, second: FileItem)
        /// `directory` is resolved once when the sheet opens; resolving a bookmark can be slow.
        case documents(showsHint: Bool, directory: URL?)

        var id: String {
            switch self {
            case .move(let items): return "move:" + items.map(\.url.path).joined(separator: "|")
            case .mergeFolder(let item): return "mergeFolder:" + item.url.path
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

    private var title: String { isRoot ? "FileBox" : folder.lastPathComponent }

    private var visibleItems: [FileItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        dialogs(presentations(content))
    }

    // MARK: - Grid and list

    private var content: some View {
        ScrollViewReader { proxy in
            decorated(layoutView(proxy), proxy: proxy)
        }
    }

    /// The list is a real List so rows keep the system swipe actions; the grid scrolls itself.
    @ViewBuilder
    private func layoutView(_ proxy: ScrollViewProxy) -> some View {
        switch layout {
        case .grid:
            ScrollView { grid }
                .scrollPosition(id: $gridAnchor, anchor: .top)
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(pinch(proxy))
        case .list:
            List { listRows }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
                .background { dropBridge }
        }
    }

    private func decorated<Content: View>(_ content: Content, proxy: ScrollViewProxy) -> some View {
        content
            .overlay { overlayContent }
            .navigationTitle(selecting ? "已选择 \(selection.count) 项" : title)
            .navigationBarBackButtonHidden(selecting)
            .searchable(text: $query, prompt: "搜索文件名")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar { toolbarContent }
            // In selection mode its bar takes the tab bar's place.
            .toolbar(selecting ? .hidden : .visible, for: .tabBar)
            .refreshable {
                store.collectIncoming()
                await reload()
            }
            .quickLookPreview($quickLookURL, in: previewURLs)
            .onAppear(perform: appeared)
            .onChange(of: store.revision) { Task { await reload() } }
            .onChange(of: sort) { Task { await reload() } }
            .onReceive(NotificationCenter.default.publisher(for: Self.viewerPageChanged)) { note in
                followViewer(note, proxy: proxy)
            }
            .onChange(of: viewer.request == nil) { _, closed in
                guard closed else { return }
                reveal(tracking.lastViewed, proxy: proxy)
                tracking.lastViewed = nil
            }
    }

    /// Import progress, or an empty state that lets touches through so pull-to-refresh still works.
    @ViewBuilder
    private var overlayContent: some View {
        if let importStatus {
            importCard(importStatus)
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

    /// Only its 取消 button takes touches; the folder stays usable around it.
    private func importCard(_ status: ImportStatus) -> some View {
        VStack(spacing: 12) {
            Group {
                if let fraction = status.fraction {
                    ProgressView(value: fraction) {
                        Text(status.text)
                    }
                } else {
                    ProgressView(status.text)
                }
            }
            .allowsHitTesting(false)
            if status.cancellable {
                Button("取消") { cancelImport() }
            }
        }
        .padding()
        .frame(width: 240)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
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
                deleteDialog(cell(item), for: [item], isPresented: rowDeleteBinding(item))
            }
        }
        .scrollTargetLayout()
    }

    private var listRows: some View {
        ForEach(visibleItems) { item in
            deleteDialog(row(item), for: [item], isPresented: rowDeleteBinding(item))
                .listRowInsets(EdgeInsets())
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !selecting {
                        swipeButtons(item)
                    }
                }
        }
    }

    /// Drops onto list rows go through UIKit (see FolderUIDropBridge); the List keeps them otherwise.
    private var dropBridge: some View {
        FolderUIDropBridge(
            isEnabled: !selecting,
            target: { index in
                let shown = visibleItems
                guard shown.indices.contains(index) else { return nil }
                let item = shown[index]
                return item.isDirectory || item.kind == .video ? item.url : nil
            },
            onTargetChange: { url in
                if dropTarget != url { dropTarget = url }
            },
            onDrop: { tokens, url in
                guard let item = visibleItems.first(where: { $0.url == url }) else { return }
                _ = drop(tokens, on: item)
            }
        )
    }

    /// Swipe a row left for 删除 / 重命名 / 移动. Delete still asks first, so no destructive role
    /// (that would animate the row away before the answer).
    @ViewBuilder
    private func swipeButtons(_ item: FileItem) -> some View {
        Button { pendingDelete = [item] } label: {
            Label("删除", systemImage: "trash")
        }
        .tint(.red)
        Button { startRename(item) } label: {
            Label("重命名", systemImage: "pencil")
        }
        .tint(.orange)
        Button { sheet = .move([item]) } label: {
            Label("移动", systemImage: "folder")
        }
        .tint(.blue)
    }

    /// Pinching out shows fewer, bigger squares; pinching in shows more, like in Photos. The file
    /// at the top stays at the top, so the place in the folder is not lost.
    private func pinch(_ proxy: ScrollViewProxy) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / pinchBase
                let columns: Int
                if ratio > 1.25, columnCount > 3 {
                    columns = columnCount - 1
                } else if ratio < 0.8, columnCount < 6 {
                    columns = columnCount + 1
                } else {
                    return
                }
                pinchBase = value.magnification
                let anchor = gridAnchor
                withAnimation(.snappy) {
                    gridColumns = columns
                }
                guard let anchor else { return }
                // Once the new columns are laid out, the same file goes back to the top.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        withAnimation(.snappy) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
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

    /// Every list row is a plain button, folders included: one chevron (the row's own) and the same
    /// highlight for all. Drops onto rows arrive through the List's drop bridge.
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
            Button {
                activate(item)
            } label: {
                rowLabel(item, isSelected: nil)
            }
            .buttonStyle(FolderRowButtonStyle())
            .accessibilityIdentifier("row-" + item.name)
            .background(rowBackground(item))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
            .contextMenu { menu(for: item) }
            .draggable(FolderDragRegistry.shared.token(for: item.url)) {
                FolderDragPreview(item: item)
            }
        }
    }

    private func rowLabel(_ item: FileItem, isSelected: Bool?) -> some View {
        FileRow(item: item, isSelected: isSelected)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// Grid cells: folders push their own view; files open in the media viewer or Quick Look.
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
            .accessibilityIdentifier("cell-" + item.name)
        } else {
            Button {
                open(item)
            } label: {
                face
            }
            .buttonStyle(style)
            .accessibilityIdentifier("cell-" + item.name)
        }
    }

    /// Grid cells of folders take any dragged item, video cells take another video.
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

    /// A tap on a list row: folders push their own view, files open.
    private func activate(_ item: FileItem) {
        if item.isDirectory {
            dismissKeyboard()
            nav.path.append(.folder(item.url))
        } else {
            open(item)
        }
    }

    private func open(_ item: FileItem) {
        dismissKeyboard()
        if item.isMedia {
            let media = query.isEmpty ? mediaItems : visibleItems.filter(\.isMedia)
            if let index = media.firstIndex(where: { $0.url == item.url }) {
                viewer.open(media, at: index)
            }
        } else {
            quickLookURL = item.url
        }
    }

    /// Closes the search keyboard, so UIKit does not bring it back once the viewer or Quick Look closes.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The viewer moved on to another file: bring it into view behind the viewer (only as far as
    /// needed), so closing the viewer lands on it. Not the file it opened on: that one was tapped
    /// here, so it is in view already, and showing all of it (a row half under the tab bar) would
    /// scroll the folder while it still shows through the viewer fading in.
    private func followViewer(_ note: Notification, proxy: ScrollViewProxy) {
        guard let request = viewer.request,
              let url = note.userInfo?["url"] as? URL ?? note.object as? URL
        else { return }
        if tracking.lastViewed == nil, request.animated, request.items.indices.contains(request.startIndex),
           request.items[request.startIndex].url == url {
            return
        }
        tracking.lastViewed = url
        reveal(url, proxy: proxy)
    }

    private func reveal(_ url: URL?, proxy: ScrollViewProxy) {
        guard let url, visibleItems.contains(where: { $0.url == url }) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(url, anchor: nil)
        }
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
        if item.isDirectory {
            Button { sheet = .mergeFolder(item) } label: {
                Label("合并到…", systemImage: "arrow.triangle.merge")
            }
        }
        Button { startRename(item) } label: {
            Label("重命名", systemImage: "pencil")
        }
        if !item.isDirectory {
            Button { store.duplicate(item) } label: {
                Label("创建副本", systemImage: "plus.square.on.square")
            }
        }
        if Self.savesToPhotos(item) {
            Button { saveToPhotos([item]) } label: {
                Label("存到「照片」", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) { pendingDelete = [item] } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private static func savesToPhotos(_ item: FileItem) -> Bool {
        item.kind == .image || item.kind == .video
    }

    private func saveToPhotos(_ targets: [FileItem]) {
        let media = targets.filter { Self.savesToPhotos($0) }
        guard !media.isEmpty else { return }
        // Videos and bigger batches take a moment; the result replaces this.
        if media.count > 3 || media.contains(where: { $0.kind == .video }) {
            store.show("正在存到「照片」…")
        }
        Task {
            let message = await FolderUIPhotoSaver.save(media)
            store.show(message)
        }
    }

    /// Files keep their extension: only the name before it is offered for editing.
    private func startRename(_ item: FileItem) {
        renameText = keptExtension(of: item) == nil ? item.name : (item.name as NSString).deletingPathExtension
        renaming = item
    }

    private func commitRename(_ item: FileItem) {
        var name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let ext = keptExtension(of: item), !name.lowercased().hasSuffix("." + ext.lowercased()) {
            name += "." + ext
        }
        store.rename(item, to: name)
    }

    private func keptExtension(of item: FileItem) -> String? {
        guard !item.isDirectory else { return nil }
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    // MARK: - Loading

    /// The first load is synchronous, so a pushed folder never slides in empty. Coming back to an
    /// unchanged folder (popping back to it, closing the viewer) does not list it again.
    private func appeared() {
        if !loaded {
            let listing = FolderUIListing(items: FileStore.listItems(in: folder, sort: sort))
            apply(listing, revision: store.revision, sort: sort, animated: false)
        } else if tracking.revision != store.revision || tracking.sort != sort {
            Task { await reload() }
        }
    }

    /// Lists the folder off the main thread; of overlapping reloads only the newest is applied.
    private func reload() async {
        tracking.generation += 1
        let generation = tracking.generation
        let url = folder
        let order = sort
        let revision = store.revision
        let listing = await Task.detached(priority: .userInitiated) {
            FolderUIListing(items: FileStore.listItems(in: url, sort: order))
        }.value
        guard generation == tracking.generation else { return }
        apply(listing, revision: revision, sort: order, animated: loaded)
    }

    /// Rows slide in and out for ordinary changes; a first load or a huge import just appears.
    private func apply(_ listing: FolderUIListing, revision: Int, sort: SortOrder, animated: Bool) {
        tracking.revision = revision
        tracking.sort = sort
        if listing.items != items {
            // The grid keeps its top file in place when the content changes; at the very top,
            // files sorted in front of it should come into view instead of staying above it.
            let keepsTop = layout == .grid && gridAnchor != nil && gridAnchor == visibleItems.first?.url
            let change = {
                items = listing.items
                if keepsTop, let top = visibleItems.first?.url, top != gridAnchor { gridAnchor = top }
            }
            if animated && abs(listing.items.count - items.count) < 150 {
                withAnimation(.snappy, change)
            } else {
                change()
            }
            mediaItems = listing.media
            previewURLs = listing.previews
            videoCount = listing.videoCount
        }
        if !loaded { loaded = true }
        if !selection.isEmpty {
            let kept = selection.intersection(items.map(\.url))
            if kept != selection { selection = kept }
        }
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

    private func startSelecting() {
        withAnimation {
            selecting = true
        }
    }

    private func endSelecting() {
        withAnimation {
            selecting = false
            selection = []
        }
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
                Button { saveToPhotos(selectedItems) } label: {
                    Label("存到「照片」", systemImage: "square.and.arrow.down")
                }
                .disabled(!selectedItems.contains(where: { Self.savesToPhotos($0) }))
                Spacer()
                deleteDialog(
                    Button(role: .destructive) { pendingBulkDelete = selectedItems } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty),
                    for: pendingBulkDelete ?? [],
                    isPresented: Binding(get: { pendingBulkDelete != nil }, set: { if !$0 { pendingBulkDelete = nil } })
                )
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
                Button("选择") { startSelecting() }
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
                    Label("从「文件」导入（可选文件夹）", systemImage: "doc.badge.plus")
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
            .disabled(importStatus != nil)
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    /// Sub-folders get 锁定 here too, so locking never means backing out to the top first.
    private var moreMenu: some View {
        Menu {
            if !isRoot {
                Button { lock.lock() } label: {
                    Label("锁定", systemImage: "lock")
                }
                Divider()
            }
            Picker("排序", selection: $sort) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            if isRoot {
                Divider()
                Button { nav.path.append(.capture) } label: {
                    Label("截图与录屏", systemImage: "record.circle")
                }
                Button { nav.path.append(.transfer) } label: {
                    Label("Wi-Fi 传输", systemImage: "wifi")
                }
                Button { nav.path.append(.trash) } label: {
                    Label("回收站", systemImage: "trash")
                }
                Button { nav.path.append(.settings) } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
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
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder, .item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    importPicked(urls)
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
        case .mergeFolder(let source):
            FolderMovePicker(items: [source], merging: true) { destination in
                store.mergeFolder(source, into: destination)
                sheet = nil
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
                TextField("新建文件夹", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") { store.createFolder(named: newFolderName, in: folder) }
            }
            .alert("重命名", isPresented: renameBinding, presenting: renaming) { item in
                TextField("名称", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("确定") { commitRename(item) }
            } message: { item in
                if let ext = keptExtension(of: item) {
                    Text("扩展名 .\(ext) 会保留")
                }
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

    /// The delete question, attached to whatever asked for it so iOS shows it right there.
    private func deleteDialog<Content: View>(_ content: Content, for targets: [FileItem], isPresented: Binding<Bool>) -> some View {
        content.confirmationDialog(deleteTitle(targets), isPresented: isPresented, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.delete(targets)
                if selecting { endSelecting() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(targets.contains(where: \.isDirectory) ? "连同文件夹里的文件一起移到回收站，\(Vault.trashDays) 天内可以恢复。" : "会移到回收站，\(Vault.trashDays) 天内可以恢复。")
        }
    }

    private func rowDeleteBinding(_ item: FileItem) -> Binding<Bool> {
        Binding(
            get: { pendingDelete?.first?.url == item.url },
            set: { if !$0, pendingDelete?.first?.url == item.url { pendingDelete = nil } }
        )
    }

    private func deleteTitle(_ targets: [FileItem]) -> String {
        guard let first = targets.first else { return "" }
        return targets.count == 1 ? "删除「\(first.name)」？" : "删除这 \(targets.count) 项？"
    }

    private var photoDeletionBinding: Binding<Bool> {
        Binding(get: { pendingPhotoDeletion != nil }, set: { if !$0 { pendingPhotoDeletion = nil } })
    }

    private var photoDeletionTitle: String {
        "要从「照片」删除这 \(pendingPhotoDeletion?.count ?? 0) 个原件吗？"
    }

    // MARK: - Importing

    /// Files from the 「文件」 or Documents picker; FileStore handles their security scope. It counts
    /// the files as they are copied and can be stopped between files.
    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty, importStatus == nil else { return }
        importStatus = ImportStatus(text: "正在导入…", cancellable: true)
        importTask = Task {
            let activity = FolderImportActivity()
            defer { activity.end() }
            await store.importFiles(urls, into: folder, moving: false, progress: { done, total in
                guard importStatus?.cancellable == true else { return }
                importStatus = ImportStatus(
                    text: "正在导入 \(done)/\(total)…",
                    fraction: total > 0 ? Double(done) / Double(total) : nil,
                    cancellable: true
                )
            })
            importStatus = nil
            importTask = nil
        }
    }

    private func cancelImport() {
        importTask?.cancel()
        importStatus = ImportStatus(text: "正在停止…", fraction: importStatus?.fraction)
    }

    private func importFromDocuments(_ urls: [URL]) {
        guard let last = urls.last else { return }
        FolderDocumentsLocation.remember(folderOf: last)
        importPicked(urls)
    }

    /// Copies the picked photos and videos in, then offers to delete the originals from Photos.
    private func importPhotos(_ picked: [PhotosPickerItem]) async {
        let activity = FolderImportActivity()
        defer { activity.end() }
        var files: [URL] = []
        var identifiers: [URL: String] = [:]
        var failed = 0
        for (index, item) in picked.enumerated() {
            importStatus = ImportStatus(
                text: "正在导入 \(index + 1)/\(picked.count)…",
                fraction: Double(index) / Double(picked.count)
            )
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
        importStatus = nil
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

/// A folder's contents with what the folder view derives from them, built off the main thread.
private struct FolderUIListing {
    let items: [FileItem]
    /// Images, videos and audio in display order: what the viewer pages through.
    let media: [FileItem]
    /// The other files: what Quick Look pages through.
    let previews: [URL]
    let videoCount: Int

    init(items: [FileItem]) {
        self.items = items
        var media: [FileItem] = []
        var previews: [URL] = []
        var videos = 0
        for item in items {
            switch item.kind {
            case .image, .audio:
                media.append(item)
            case .video:
                media.append(item)
                videos += 1
            case .other:
                previews.append(item.url)
            case .folder:
                break
            }
        }
        self.media = media
        self.previews = previews
        videoCount = videos
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

/// One file or folder: an optional selection mark, thumbnail, name and details (item count for
/// folders, length for videos, size and date).
struct FileRow: View {
    let item: FileItem
    /// nil outside selection mode.
    var isSelected: Bool?

    @State private var duration: String?

    init(item: FileItem, isSelected: Bool? = nil) {
        self.item = item
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(spacing: 12) {
            if let isSelected {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                    .transition(.opacity)
            }
            FolderThumbnail(item: item, side: 56)
            VStack(alignment: .leading, spacing: 2) {
                // Cut in the middle, so the extension stays visible.
                Text(item.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
        .task(id: item) {
            guard item.kind == .video else { return }
            let loaded = await FolderVideoDurations.text(for: item)
            guard !Task.isCancelled else { return }
            duration = loaded
        }
    }

    private var detail: String {
        let date = item.modified.formatted(date: .abbreviated, time: .shortened)
        if item.isDirectory {
            guard let count = item.childCount else { return date }
            return "\(count) 项 · \(date)"
        }
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        // A length the grid or an earlier row already read shows in the first frame.
        if let duration = duration ?? (item.kind == .video ? FolderVideoDurations.cachedText(for: item) : nil) {
            return "\(size) · \(duration) · \(date)"
        }
        return "\(size) · \(date)"
    }
}
