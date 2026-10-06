import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {
    let folder: URL

    @EnvironmentObject private var store: FileStore
    @EnvironmentObject private var lock: LockManager
    @EnvironmentObject private var viewer: ViewerCoordinator
    @AppStorage("sortOrder") private var sort: SortOrder = .date

    @State private var items: [FileItem] = []
    @State private var query = ""
    @State private var quickLookURL: URL?

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: FileItem?
    @State private var renameText = ""

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingPhotos = false

    @State private var editingImage: FileItem?
    @State private var trimmingVideo: FileItem?

    private var isRoot: Bool { store.isRoot(folder) }
    private var title: String { isRoot ? "FileBox" : folder.lastPathComponent }

    private var visibleItems: [FileItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(visibleItems) { item in
                row(item)
                    .contextMenu { menu(for: item) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.delete([item]) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { startRename(item) } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if importingPhotos {
                ProgressView("正在导入…")
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else if items.isEmpty {
                ContentUnavailableView(
                    "这里还没有文件",
                    systemImage: "tray",
                    description: Text("在其他 App 里点「分享」→ FileBox，\n或者点右上角的 + 导入")
                )
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜索文件名")
        .toolbar { toolbarContent }
        .refreshable {
            store.collectIncoming()
            reload()
        }
        .quickLookPreview($quickLookURL, in: visibleItems.filter { !$0.isDirectory && !$0.isMedia }.map(\.url))
        .onAppear(perform: reload)
        .onChange(of: store.revision) { reload() }
        .onChange(of: sort) { reload() }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") { store.createFolder(named: newFolderName, in: folder) }
        }
        .alert("重命名", isPresented: renameBinding) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let item = renaming { store.rename(item, to: renameText) }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await store.importFiles(urls, into: folder) }
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        .onChange(of: photoItems) {
            Task { await importPhotos() }
        }
        .fullScreenCover(item: $editingImage) { item in
            ImageEditorView(item: item)
        }
        .fullScreenCover(item: $trimmingVideo) { item in
            VideoTrimView(item: item)
        }
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        if item.isDirectory {
            NavigationLink(value: Route.folder(item.url)) { FileRow(item: item) }
        } else {
            Button { open(item) } label: { FileRow(item: item) }
                .buttonStyle(.plain)
        }
    }

    private func open(_ item: FileItem) {
        if item.isMedia {
            let media = visibleItems.filter(\.isMedia)
            viewer.open(media, at: media.firstIndex(of: item) ?? 0)
        } else {
            quickLookURL = item.url
        }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if !item.isDirectory {
            ShareLink(item: item.url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        if item.kind == .image {
            Button { editingImage = item } label: { Label("编辑图片", systemImage: "crop.rotate") }
        }
        if item.kind == .video {
            Button { trimmingVideo = item } label: { Label("剪辑视频", systemImage: "scissors") }
        }
        Button { startRename(item) } label: { Label("重命名", systemImage: "pencil") }
        Button(role: .destructive) { store.delete([item]) } label: { Label("删除", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isRoot {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { lock.lock() } label: { Image(systemName: "lock") }
                NavigationLink(value: Route.browser) { Image(systemName: "globe") }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Button { showPhotoPicker = true } label: {
                    Label("从相册导入", systemImage: "photo.on.rectangle")
                }
                Button { showFileImporter = true } label: {
                    Label("从「文件」导入", systemImage: "doc.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("排序", selection: $sort) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                if isRoot {
                    Divider()
                    NavigationLink(value: Route.capture) { Label("截图与录屏", systemImage: "record.circle") }
                    NavigationLink(value: Route.transfer) { Label("Wi-Fi 传输", systemImage: "wifi") }
                    NavigationLink(value: Route.settings) { Label("设置", systemImage: "gearshape") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func startRename(_ item: FileItem) {
        renameText = item.name
        renaming = item
    }

    private func reload() {
        items = store.items(in: folder, sort: sort)
    }

    private func importPhotos() async {
        let picked = photoItems
        guard !picked.isEmpty else { return }
        photoItems = []
        importingPhotos = true
        var urls: [URL] = []
        for item in picked {
            if let file = try? await item.loadTransferable(type: PickedFile.self) {
                urls.append(file.url)
            }
        }
        await store.importFiles(urls, into: folder, moving: true)
        importingPhotos = false
    }
}

/// A photo or video from the picker, copied out to a temporary file.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile(copying: received.file)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile(copying: received.file)
        }
    }

    init(copying source: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        url = dest
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let date = item.modified.formatted(date: .abbreviated, time: .shortened)
        if item.isDirectory { return date }
        return "\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(date)"
    }
}
