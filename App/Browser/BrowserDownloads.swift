import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One entry of the browser's downloads panel.
final class BrowserDownload: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case saved
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let source: URL?
    @Published var name: String
    @Published var state: State = .running
    @Published var received: Int64 = 0
    /// Total size, or 0 while unknown.
    @Published var expected: Int64 = 0

    fileprivate var webDownload: WKDownload?
    fileprivate var task: URLSessionDownloadTask?
    /// Where the data is being written, inside its own temporary folder.
    fileprivate var tempFile: URL?

    init(name: String, source: URL?) {
        self.name = name
        self.source = source
    }

    var isRunning: Bool { state == .running }

    var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }
}

/// What a download outside WebKit needs to look like the page's own request: the web view's cookies,
/// the page as Referer (many image hosts block hotlinking) and the same User-Agent.
struct BrowserFetchContext {
    let cookies: [HTTPCookie]
    let referer: URL?
    let userAgent: String?

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer, ["http", "https"].contains(referer.scheme?.lowercased() ?? "") {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let matching = cookies.filter { Self.cookie($0, matches: url) }
        if !matching.isEmpty {
            for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    /// An in-memory session that applies these headers again after redirects. Invalidate it when done.
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: BrowserRedirectDelegate(context: self), delegateQueue: nil)
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        let path = url.path.isEmpty ? "/" : url.path
        return cookiePath == "/" || path == cookiePath
            || path.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/")
    }
}

/// Recomputes cookies for the new host when a download is redirected (often to a CDN).
private final class BrowserRedirectDelegate: NSObject, URLSessionTaskDelegate {
    let context: BrowserFetchContext

    init(context: BrowserFetchContext) {
        self.context = context
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(request)
            return
        }
        var redirected = context.request(for: url)
        redirected.httpMethod = request.httpMethod
        completionHandler(redirected)
    }
}

/// Runs the browser's downloads (WebKit downloads, and URLSession fetches of page media) and moves
/// finished files into the vault's 下载 folder. Everything stops when the browser closes.
@MainActor
final class BrowserDownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [BrowserDownload] = []
    @Published private(set) var activeCount = 0

    weak var store: FileStore?
    private var ticker: Task<Void, Never>?

    var hasFinished: Bool { items.contains { !$0.isRunning } }

    override init() {
        super.init()
        // Leftovers of a browser session that ended while downloading.
        Self.removeTemporaryFiles()
    }

    /// Follows a download WebKit started (a link, a file response, or our own startDownload).
    func track(_ download: WKDownload, source: URL?) {
        let item = BrowserDownload(name: Self.provisionalName(for: source), source: source)
        item.webDownload = download
        download.delegate = self
        items.insert(item, at: 0)
        didStart(count: 1, first: item)
    }

    /// Downloads page media with URLSession, carrying the page's cookies, Referer and User-Agent.
    func fetch(_ urls: [URL], context: BrowserFetchContext) {
        guard !urls.isEmpty else { return }
        let session = context.makeSession()
        var first: BrowserDownload?
        for url in urls {
            let item = BrowserDownload(name: Self.provisionalName(for: url), source: url)
            let id = item.id
            let task = session.downloadTask(with: context.request(for: url)) { [weak self] location, response, error in
                // The system deletes `location` as soon as this returns.
                let file = location.flatMap { Self.keepDownloadedFile($0) }
                Task { @MainActor in
                    guard let self else {
                        if let file { Self.removeFolder(of: file) }
                        return
                    }
                    self.sessionTaskEnded(id, file: file, response: response, error: error)
                }
            }
            item.task = task
            items.insert(item, at: 0)
            if first == nil { first = item }
            task.resume()
        }
        session.finishTasksAndInvalidate()
        didStart(count: urls.count, first: first)
    }

    func cancel(_ item: BrowserDownload) {
        guard item.isRunning else { return }
        item.state = .cancelled
        item.webDownload?.cancel(nil)
        item.task?.cancel()
        discardFile(of: item)
        refreshCount()
    }

    func cancelAll() {
        for item in items where item.isRunning {
            cancel(item)
        }
        ticker?.cancel()
        ticker = nil
    }

    func clearFinished() {
        items.removeAll { !$0.isRunning }
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        guard let item = item(for: download), item.isRunning else {
            completionHandler(nil)
            return
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            fail(item, "服务器返回 \(status)")
            completionHandler(nil)
            return
        }
        item.name = Self.fileName(suggested: suggestedFilename, response: response, url: response.url ?? item.source)
        if response.expectedContentLength > 0 {
            item.expected = response.expectedContentLength
        }
        do {
            let file = try Self.makeTemporaryFile()
            item.tempFile = file
            completionHandler(file)
        } catch {
            fail(item, error.localizedDescription)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), item.isRunning else { return }
        guard let file = item.tempFile else {
            fail(item, "找不到下载的文件")
            return
        }
        save(item, from: file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.isRunning else { return }
        fail(item, error.localizedDescription)
    }

    // MARK: - Progress and results

    private func item(for download: WKDownload) -> BrowserDownload? {
        items.first { $0.webDownload === download }
    }

    private func didStart(count: Int, first: BrowserDownload?) {
        refreshCount()
        startTicking()
        if count == 1, let first {
            store?.show("开始下载「\(first.name)」")
        } else {
            store?.show("开始下载 \(count) 个文件")
        }
    }

    private func sessionTaskEnded(_ id: UUID, file: URL?, response: URLResponse?, error: Error?) {
        guard let item = items.first(where: { $0.id == id }), item.isRunning else {
            if let file { Self.removeFolder(of: file) }
            return
        }
        if let error {
            if let file { Self.removeFolder(of: file) }
            if (error as? URLError)?.code == .cancelled {
                item.state = .cancelled
                refreshCount()
            } else {
                fail(item, error.localizedDescription)
            }
            return
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            if let file { Self.removeFolder(of: file) }
            fail(item, "服务器返回 \(status)")
            return
        }
        guard let file else {
            fail(item, "无法保存下载的文件")
            return
        }
        item.name = Self.fileName(suggested: response?.suggestedFilename, response: response, url: response?.url ?? item.source)
        save(item, from: file)
    }

    /// Moves a finished file into 下载 under its suggested name.
    private func save(_ item: BrowserDownload, from file: URL) {
        item.tempFile = nil
        defer {
            Self.removeFolder(of: file)
            refreshCount()
        }
        guard let store else {
            item.state = .failed("无法保存到「下载」")
            return
        }
        guard let saved = store.add(fileAt: file, named: item.name, into: Vault.folder(Vault.downloadsName), moving: true) else {
            item.state = .failed("无法保存到「下载」")
            return
        }
        let size = Int64((try? saved.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        item.name = saved.lastPathComponent
        item.received = size
        item.expected = size
        item.state = .saved
        store.show("已下载「\(saved.lastPathComponent)」，在「下载」里")
    }

    private func fail(_ item: BrowserDownload, _ message: String) {
        item.state = .failed(message)
        discardFile(of: item)
        refreshCount()
    }

    private func discardFile(of item: BrowserDownload) {
        if let file = item.tempFile { Self.removeFolder(of: file) }
        item.tempFile = nil
    }

    private func refreshCount() {
        let count = items.filter(\.isRunning).count
        if count != activeCount { activeCount = count }
    }

    /// Polls progress while anything runs; cheaper and simpler than observing every task.
    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, self.tick() else { break }
            }
            self?.ticker = nil
        }
    }

    /// Updates byte counts and returns whether any download is still running.
    private func tick() -> Bool {
        var running = false
        for item in items where item.isRunning {
            running = true
            var received: Int64 = 0
            var expected: Int64 = 0
            if let download = item.webDownload {
                received = download.progress.completedUnitCount
                expected = download.progress.totalUnitCount
            } else if let task = item.task {
                received = task.countOfBytesReceived
                expected = task.countOfBytesExpectedToReceive
            }
            if received != item.received { item.received = received }
            if expected > 0 && expected != item.expected { item.expected = expected }
        }
        return running
    }

    // MARK: - Files

    nonisolated private static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDownloads", isDirectory: true)
    }

    /// A not yet existing file in a fresh temporary folder (WebKit refuses existing destinations).
    nonisolated private static func makeTemporaryFile() throws -> URL {
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("download")
    }

    nonisolated private static func keepDownloadedFile(_ location: URL) -> URL? {
        guard let file = try? makeTemporaryFile() else { return nil }
        do {
            try FileManager.default.moveItem(at: location, to: file)
            return file
        } catch {
            return nil
        }
    }

    nonisolated private static func removeFolder(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    nonisolated private static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    nonisolated private static func provisionalName(for url: URL?) -> String {
        guard let url else { return "下载" }
        let last = url.lastPathComponent
        if last != "/" {
            let clean = sanitizedFileName(last)
            if !clean.isEmpty { return clean }
        }
        return url.host ?? "下载"
    }

    /// The server's file name (or the URL's), with an extension from the MIME type when it lacks a
    /// fitting one, so the vault recognizes images and videos.
    nonisolated static func fileName(suggested: String?, response: URLResponse?, url: URL?) -> String {
        var name = sanitizedFileName(suggested ?? "")
        if name.isEmpty || name.lowercased() == "unknown" {
            name = provisionalName(for: url)
        }
        if let mime = response?.mimeType, let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            let isMedia: (UTType) -> Bool = { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }
            let current = (name as NSString).pathExtension
            let needsExtension: Bool
            if !current.isEmpty, let currentType = UTType(filenameExtension: current.lowercased()) {
                needsExtension = currentType.isDynamic || (isMedia(type) && !isMedia(currentType))
            } else {
                needsExtension = true
            }
            if needsExtension { name += "." + ext }
        }
        return name
    }
}

/// The downloads panel: progress, cancel, and where finished files went.
struct BrowserDownloadsSheet: View {
    @ObservedObject var downloads: BrowserDownloadManager
    @Environment(\.dismiss) private var dismiss

    private static let footnote = "下载的文件保存在 FileBox 的「下载」文件夹。下载只在浏览器开着时进行：离开浏览器或 FileBox 切到后台时，没下载完的文件会停止下载。"

    var body: some View {
        NavigationStack {
            Group {
                if downloads.items.isEmpty {
                    ContentUnavailableView(
                        "还没有下载",
                        systemImage: "arrow.down.circle",
                        description: Text("长按链接或图片选「下载」，或者用「本页媒体」一次下载多个文件。\n\n" + Self.footnote)
                    )
                } else {
                    List {
                        Section {
                            ForEach(downloads.items) { item in
                                BrowserDownloadRow(item: item) { downloads.cancel(item) }
                            }
                        } footer: {
                            Text(Self.footnote)
                        }
                    }
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除已结束") { downloads.clearFinished() }
                        .disabled(!downloads.hasFinished)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct BrowserDownloadRow: View {
    @ObservedObject var item: BrowserDownload
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.isRunning, let fraction = item.fraction {
                    ProgressView(value: fraction)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if item.isRunning {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("取消下载")
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch item.state {
        case .running: return "arrow.down.circle"
        case .saved: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .running: return .accentColor
        case .saved: return .green
        case .failed: return .orange
        case .cancelled: return .secondary
        }
    }

    private var status: String {
        switch item.state {
        case .running:
            if item.expected > 0 {
                return "\(Self.bytes(item.received)) / \(Self.bytes(item.expected))"
            }
            return item.received > 0 ? "已下载 \(Self.bytes(item.received))" : "正在连接…"
        case .saved:
            return item.received > 0 ? "已保存到「下载」 · \(Self.bytes(item.received))" : "已保存到「下载」"
        case .failed(let message):
            return "下载失败：\(message)"
        case .cancelled:
            return "已取消"
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
