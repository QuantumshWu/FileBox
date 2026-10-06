import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {
    let folder: URL

    @EnvironmentObject private var store: FileStore
    @AppStorage("sortOrder") private var sort: SortOrder = .date

    @State private var items: [FileItem] = []
    @State private var query = ""
    @State private var previewURL: URL?

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: FileItem?
    @State private var renameText = ""

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    @State private var showAbout = false

    private var title: String { store.isRoot(folder) ? "FileBox" : folder.lastPathComponent }

    private var visibleItems: [FileItem] {
        query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Swiping in the preview moves through the files of this folder.
    private var previewableURLs: [URL] {
        visibleItems.filter { !$0.isDirectory }.map(\.url)
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
            if items.isEmpty {
                ContentUnavailableView(
                    "这里还没有文件",
                    systemImage: "tray",
                    description: Text("在其他 App 里点「分享」→ FileBox，\n或者点右上角的 + 导入")
                )
            } else if importingPhotos {
                ProgressView("正在导入…")
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "搜索文件名")
        .toolbar { toolbarContent }
        .refreshable {
            store.collectIncoming()
            reload()
        }
        .quickLookPreview($previewURL, in: previewableURLs)
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
                store.importFiles(urls, into: folder)
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
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    @ViewBuilder
    private func row(_ item: FileItem) -> some View {
        if item.isDirectory {
            NavigationLink(value: item.url) { FileRow(item: item) }
        } else {
            Button { previewURL = item.url } label: { FileRow(item: item) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if !item.isDirectory {
            ShareLink(item: item.url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        Button { startRename(item) } label: { Label("重命名", systemImage: "pencil") }
        Button(role: .destructive) { store.delete([item]) } label: { Label("删除", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                if store.isRoot(folder) {
                    Divider()
                    Button { showAbout = true } label: { Label("关于", systemImage: "info.circle") }
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
        store.importFiles(urls, into: folder, moving: true)
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

struct ThumbnailView: View {
    let item: FileItem

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Group {
            if item.isDirectory {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.blue)
                    .padding(4)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item) {
            guard !item.isDirectory else { return }
            image = await Thumbnails.image(for: item, scale: displayScale)
        }
    }
}

enum Thumbnails {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for item: FileItem, scale: CGFloat) async -> UIImage? {
        let key = "\(item.url.path)|\(item.modified.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: 44, height: 44),
            scale: scale,
            representationTypes: .all
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        cache.setObject(representation.uiImage, forKey: key)
        return representation.uiImage
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("版本") {
                    Text(version)
                    Text(Bundle.main.bundleIdentifier ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("诊断") {
                    Text(SharedConfig.diagnostics)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("关于 FileBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
