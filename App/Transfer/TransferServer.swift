import Foundation
import Network

/// What the transfer server reports to the screen. Delivered on the main queue.
enum TransferServerEvent {
    /// Listening on `port`.
    case ready(port: UInt16)
    /// The listener is waiting for a usable network.
    case waiting(String)
    /// The listener could not start.
    case failed(String)
    /// `isUpload` is from the phone's point of view: a file the computer sends to the vault.
    case transferStarted(id: UUID, name: String, isUpload: Bool, total: Int64)
    case transferProgress(id: UUID, done: Int64)
    /// `folder` is the vault-relative folder the file was saved to or sent from ("" for the root).
    case transferFinished(id: UUID, name: String, isUpload: Bool, folder: String)
    case transferFailed(id: UUID, name: String, isUpload: Bool, reason: String)
    case folderCreated(name: String, folder: String)
}

/// A small HTTP/1.1 server on Network.framework for the Wi-Fi transfer page. Every path must start
/// with `/<token>/`; anything else gets a 404. Requests are handled on background queues (one
/// serial queue per connection), never on the main thread; `onEvent` is called on the main queue.
final class TransferServer: @unchecked Sendable {
    static let preferredPort: UInt16 = 8080
    private static let maxConnections = 48

    let token: String
    /// Set on the main thread before `start`.
    var onEvent: ((TransferServerEvent) -> Void)?

    private let root: URL
    private let rootPath: String
    private let queue = DispatchQueue(label: "FileBox.Transfer.server")
    /// Serializes naming and creating items so parallel uploads never pick the same free name.
    private let fileLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: TransferConnection] = [:]
    private var isStopped = false

    init(token: String, root: URL) {
        self.token = token
        self.root = root
        rootPath = TransferHTTP.normalizedPath(root)
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    /// Listens on `port`, or on any free port if that one stays taken.
    func start(port: UInt16) {
        queue.async {
            TransferConnection.removeStaleUploads()
            self.listen(on: NWEndpoint.Port(rawValue: port) ?? .any, retries: 3)
        }
    }

    /// Stops listening and drops every connection; unfinished uploads are deleted.
    func stop() {
        queue.async {
            self.isStopped = true
            if let listener = self.listener { self.discard(listener) }
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func listen(on port: NWEndpoint.Port, retries: Int) {
        guard !isStopped else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            retry(port: port, retries: retries, after: error)
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.emit(.ready(port: listener.port?.rawValue ?? port.rawValue))
            case .waiting(let error):
                if Self.isAddressInUse(error) {
                    self.discard(listener)
                    self.retry(port: port, retries: retries, after: error)
                } else {
                    self.emit(.waiting(error.localizedDescription))
                }
            case .failed(let error):
                self.discard(listener)
                self.retry(port: port, retries: retries, after: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// The preferred port can still be held by a listener that is shutting down, so it is retried a
    /// few times before falling back to any free port.
    private func retry(port: NWEndpoint.Port, retries: Int, after error: Error) {
        guard !isStopped else { return }
        if port == .any {
            emit(.failed(error.localizedDescription))
        } else if retries > 0, let error = error as? NWError, Self.isAddressInUse(error) {
            queue.asyncAfter(deadline: .now() + 0.4) {
                self.listen(on: port, retries: retries - 1)
            }
        } else {
            listen(on: .any, retries: 0)
        }
    }

    private func discard(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        if self.listener === listener { self.listener = nil }
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    private func accept(_ nwConnection: NWConnection) {
        guard !isStopped, connections.count < Self.maxConnections else {
            nwConnection.cancel()
            return
        }
        let context = TransferConnection.Context(
            token: token,
            root: root,
            rootPath: rootPath,
            fileLock: fileLock,
            emit: { [weak self] event in self?.emit(event) }
        )
        let connection = TransferConnection(nwConnection, context: context)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.onClose = { [weak self] in
            guard let self else { return }
            self.queue.async { self.connections[key] = nil }
        }
        connection.start()
    }

    private func emit(_ event: TransferServerEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}

/// One client connection: reads one request, answers it, then closes (`Connection: close`).
/// Everything runs on the connection's own serial queue.
private final class TransferConnection: @unchecked Sendable {
    struct Context {
        let token: String
        let root: URL
        /// `root` normalized with TransferHTTP.normalizedPath.
        let rootPath: String
        let fileLock: NSLock
        let emit: (TransferServerEvent) -> Void
    }

    private struct Upload {
        let id: UUID
        let name: String
        let folder: URL
        let temp: URL
        let handle: FileHandle
        let expected: Int64
        var received: Int64 = 0
    }

    private struct Download {
        let id: UUID
        let name: String
        let folder: String
        let handle: FileHandle
        let total: Int64
        /// Whole-file GETs show up in the app; range requests (video seeking) do not.
        let isTracked: Bool
        var sent: Int64 = 0
    }

    private struct Listing: Encodable {
        struct Entry: Encodable {
            let name: String
            let dir: Bool
            let size: Int64
            /// Milliseconds since 1970, as JavaScript dates use.
            let mtime: Int64
        }

        let path: String
        let free: Int64?
        let items: [Entry]
    }

    private static let maxHeaderSize = 64 * 1024
    private static let chunkSize = 1 << 20
    /// Upload bytes read and thrown away after an early error response (see `lingers`).
    private static let maxDiscard: Int64 = 64 << 20
    private static let headerTimeout: TimeInterval = 30
    private static let idleTimeout: TimeInterval = 120
    /// Space left free on the phone when accepting an upload.
    private static let reservedSpace: Int64 = 100 * 1024 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)

    /// Where uploads are written while they arrive; on the same volume as the vault, so the final
    /// move is a rename.
    static var uploadsFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FileBoxTransfer", isDirectory: true)
    }

    /// Deletes partial uploads left behind by a crash (untouched for ten minutes).
    static func removeStaleUploads() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: uploadsFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? fm.removeItem(at: url) }
        }
    }

    /// Called once on the connection's queue after it closed.
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let context: Context
    private let queue = DispatchQueue(label: "FileBox.Transfer.connection")
    private let fm = FileManager.default
    private var buffer = Data()
    private var isClosed = false
    private var hasRequest = false
    /// The client is still sending a body the server will not read. After the response the
    /// connection keeps reading (and discarding) for a while: closing it with unread data would
    /// reset it, and the browser would show a network error instead of the server's message.
    private var lingers = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var lastProgressReport: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var upload: Upload?
    private var download: Download?

    init(_ connection: NWConnection, context: Context) {
        self.connection = connection
        self.context = context
    }

    func start() {
        queue.async { self.begin() }
    }

    func cancel() {
        queue.async { self.close(reason: "传输已停止") }
    }

    private func begin() {
        guard !isClosed else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(reason: "连接中断")
            default:
                break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5.0)
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        self.timer = timer
        connection.start(queue: queue)
        receiveHead()
    }

    // MARK: - Lifecycle

    private func touch() {
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    /// Drops clients that connect and never send a request, or stall in the middle of a transfer.
    private func checkIdle() {
        let limit = hasRequest ? Self.idleTimeout : Self.headerTimeout
        if ProcessInfo.processInfo.systemUptime - lastActivity > limit {
            close(reason: "连接超时")
        }
    }

    /// Ends the connection. An unfinished upload is deleted and reported. Safe to call repeatedly.
    private func close(reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        if let upload {
            self.upload = nil
            try? upload.handle.close()
            try? fm.removeItem(at: upload.temp)
            context.emit(.transferFailed(id: upload.id, name: upload.name, isUpload: true, reason: reason ?? "连接中断"))
        }
        if let download {
            self.download = nil
            try? download.handle.close()
            if download.isTracked {
                context.emit(.transferFailed(id: download.id, name: download.name, isUpload: false, reason: reason ?? "连接中断"))
            }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?()
        onClose = nil
    }

    // MARK: - Requests

    /// Reads until the blank line that ends the request head, which may span several packets.
    private func receiveHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.touch()
            }
            if let end = self.buffer.range(of: Self.headerEnd) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<end.lowerBound)
                let body = self.buffer.subdata(in: end.upperBound..<self.buffer.endIndex)
                self.buffer = Data()
                self.hasRequest = true
                self.handle(head: head, body: body)
            } else if self.buffer.count > Self.maxHeaderSize {
                self.hasRequest = true
                self.respondError(431, "请求头太大")
            } else if isComplete || error != nil {
                self.close(reason: nil)
            } else {
                self.receiveHead()
            }
        }
    }

    /// `body` holds whatever arrived after the head in the same packets.
    private func handle(head: Data, body: Data) {
        guard let request = TransferRequest(head: head) else {
            respondError(400, "请求格式不对")
            return
        }
        guard request.segments.first == context.token else {
            respond(404, type: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
            return
        }
        let route = Array(request.segments.dropFirst())
        let headOnly = request.method == "HEAD"
        switch (request.method, route.first ?? "") {
        case ("GET", ""), ("HEAD", ""):
            if request.path.hasSuffix("/") {
                respond(
                    200,
                    type: "text/html; charset=utf-8",
                    body: TransferWebPage.data,
                    headers: [("Content-Security-Policy", TransferWebPage.contentSecurityPolicy)],
                    headOnly: headOnly
                )
            } else {
                respond(301, type: "text/plain; charset=utf-8", body: Data(), headers: [("Location", "/\(context.token)/")])
            }
        case ("GET", "api") where route.count == 2 && route[1] == "list":
            list(request)
        case ("GET", "file"), ("HEAD", "file"):
            serveFile(Array(route.dropFirst()), request: request, headOnly: headOnly)
        case ("PUT", "upload"), ("POST", "upload"):
            beginUpload(request, body: body)
        case ("POST", "mkdir"):
            makeFolder(request)
        default:
            respondError(404, "找不到这个地址")
        }
    }

    // MARK: - Paths

    /// The vault item at these decoded path components. Hidden names, "." and "..", and anything that
    /// resolves (through symlinks) outside the vault are rejected. Returns the resolved URL.
    private func resolve(_ components: [String]) -> URL? {
        var url = context.root
        for component in components {
            guard !component.isEmpty, !component.hasPrefix("."), !component.contains("/"), !component.contains("\0")
            else { return nil }
            url.appendPathComponent(component)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideVault(resolved) else { return nil }
        return resolved
    }

    private func isInsideVault(_ url: URL) -> Bool {
        let path = TransferHTTP.normalizedPath(url)
        return path == context.rootPath || path.hasPrefix(context.rootPath + "/")
    }

    /// An existing folder of the vault from a relative path such as "收件箱/照片".
    private func existingFolder(at relativePath: String) -> URL? {
        guard let url = resolve(relativePath.split(separator: "/").map(String.init)) else { return nil }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    /// "收件箱/照片" for a folder of the vault, "" for the vault itself.
    private func relativePath(of url: URL) -> String {
        let path = TransferHTTP.normalizedPath(url)
        guard path.count > context.rootPath.count + 1, path.hasPrefix(context.rootPath + "/") else { return "" }
        return String(path.dropFirst(context.rootPath.count + 1))
    }

    private func freeSpace() -> Int64? {
        (try? context.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        context.fileLock.lock()
        defer { context.fileLock.unlock() }
        return try body()
    }

    // MARK: - Listing and folders

    private func list(_ request: TransferRequest) {
        guard let folder = existingFolder(at: request.query["dir"] ?? "") else {
            respondError(404, "这个文件夹已经不存在了，请回到「全部文件」")
            return
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            respondError(500, "读取文件夹失败：\(error.localizedDescription)")
            return
        }
        let items = urls.map { url -> Listing.Entry in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            return Listing.Entry(
                name: url.lastPathComponent,
                dir: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                mtime: Int64(modified.timeIntervalSince1970 * 1000)
            )
        }
        respondJSON(200, Listing(path: relativePath(of: folder), free: freeSpace(), items: items))
    }

    private func makeFolder(_ request: TransferRequest) {
        guard let parent = existingFolder(at: request.query["dir"] ?? "") else {
            respondError(404, "所在的文件夹已经不存在了，请刷新页面")
            return
        }
        var name = sanitizedFileName(request.query["name"] ?? "")
        if name.isEmpty { name = "新建文件夹" }
        do {
            let created = try locked { () throws -> URL in
                let url = fm.uniqueURL(for: name, in: parent)
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            }
            context.emit(.folderCreated(name: created.lastPathComponent, folder: relativePath(of: parent)))
            respondJSON(201, ["name": created.lastPathComponent])
        } catch {
            respondError(500, "新建文件夹失败：\(error.localizedDescription)")
        }
    }

    /// Creates (or reuses) the folders of an uploaded folder's relative path, e.g. "旅行/第一天".
    private func subfolder(_ relativePath: String, in folder: URL) throws -> URL {
        var current = folder
        try locked {
            for raw in relativePath.split(separator: "/") {
                let name = sanitizedFileName(String(raw))
                guard !name.isEmpty else { continue }
                current.appendPathComponent(name, isDirectory: true)
                try fm.createDirectory(at: current, withIntermediateDirectories: true)
            }
        }
        guard isInsideVault(current) else { throw CocoaError(.fileWriteNoPermission) }
        return current
    }

    // MARK: - Downloads

    private func serveFile(_ components: [String], request: TransferRequest, headOnly: Bool) {
        guard !components.isEmpty, let url = resolve(components),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true
        else {
            respondError(404, "文件不存在，可能已经被删除")
            return
        }
        let name = url.lastPathComponent
        let size = Int64(values.fileSize ?? 0)
        let lastModified = TransferHTTP.httpDate(values.contentModificationDate ?? Date())
        let attachment = request.query["dl"] != nil || !TransferHTTP.allowsInline(url)
        var status = 200
        var start: Int64 = 0
        var length = size
        var headers: [(String, String)] = [
            ("Content-Type", TransferHTTP.mimeType(for: url)),
            ("Accept-Ranges", "bytes"),
            ("Last-Modified", lastModified),
            ("Content-Disposition", TransferHTTP.contentDisposition(name, attachment: attachment)),
        ]
        // A resumed download whose file changed in the meantime gets the whole new file.
        let rangeStillValid = request.headers["if-range"].map { $0 == lastModified } ?? true
        if rangeStillValid {
            switch TransferHTTP.byteRange(request.headers["range"], size: size) {
            case .whole:
                break
            case .partial(let first, let last):
                status = 206
                start = first
                length = last - first + 1
                headers.append(("Content-Range", "bytes \(first)-\(last)/\(size)"))
            case .unsatisfiable:
                respond(416, type: "text/plain; charset=utf-8", body: Data(), headers: [("Content-Range", "bytes */\(size)")])
                return
            }
        }
        headers.append(("Content-Length", String(length)))

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            if start > 0 { try handle.seek(toOffset: UInt64(start)) }
        } catch {
            respondError(500, "无法读取文件：\(error.localizedDescription)")
            return
        }
        let head = TransferHTTP.head(status: status, headers: headers)
        if headOnly || length == 0 {
            try? handle.close()
            send(head) { [weak self] in self?.endResponse() }
            return
        }
        let id = UUID()
        let tracked = status == 200
        download = Download(
            id: id,
            name: name,
            folder: relativePath(of: url.deletingLastPathComponent()),
            handle: handle,
            total: length,
            isTracked: tracked
        )
        if tracked {
            context.emit(.transferStarted(id: id, name: name, isUpload: false, total: length))
        }
        send(head) { [weak self] in self?.sendNextChunk() }
    }

    /// Streams the file in 1 MB chunks; the next chunk is read only after the previous one was handed
    /// to the network, so a slow client never makes the app buffer the file in memory.
    private func sendNextChunk() {
        guard let download, !isClosed else { return }
        let remaining = download.total - download.sent
        if remaining <= 0 {
            self.download = nil
            try? download.handle.close()
            if download.isTracked {
                context.emit(.transferFinished(id: download.id, name: download.name, isUpload: false, folder: download.folder))
            }
            endResponse()
            return
        }
        let chunk: Data
        do {
            chunk = try download.handle.read(upToCount: Int(min(remaining, Int64(Self.chunkSize)))) ?? Data()
        } catch {
            close(reason: "读取文件失败")
            return
        }
        guard !chunk.isEmpty else {
            close(reason: "文件在传输过程中被改动了")
            return
        }
        send(chunk) { [weak self] in
            guard let self, var current = self.download else { return }
            current.sent += Int64(chunk.count)
            self.download = current
            if current.isTracked { self.reportProgress(id: current.id, done: current.sent) }
            self.sendNextChunk()
        }
    }

    // MARK: - Uploads

    /// `PUT upload?dir=&name=[&sub=]` with the raw file as the body. The body is streamed to a
    /// temporary file as it arrives, then moved into the vault under a free name.
    private func beginUpload(_ request: TransferRequest, body: Data) {
        if let encoding = request.headers["transfer-encoding"], encoding.lowercased() != "identity" {
            respondError(411, "不支持这种上传方式，请换个浏览器再试")
            return
        }
        // A request without Content-Length has no body.
        var expected: Int64 = 0
        if let value = request.headers["content-length"] {
            guard let length = Int64(value), length >= 0 else {
                respondError(400, "文件大小无效")
                return
            }
            expected = length
        }
        lingers = expected > Int64(body.count)
        guard let target = existingFolder(at: request.query["dir"] ?? "") else {
            respondError(404, "目标文件夹已经不存在了，请刷新页面")
            return
        }
        var name = sanitizedFileName(request.query["name"] ?? "")
        if name.isEmpty { name = "文件" }
        if expected > 0, let free = freeSpace(), expected > free - Self.reservedSpace {
            let left = ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)
            respondError(507, "手机存储空间不足（只剩 \(left)）")
            return
        }
        let folder: URL
        do {
            folder = try subfolder(request.query["sub"] ?? "", in: target)
        } catch {
            respondError(409, "无法创建文件夹：\(error.localizedDescription)")
            return
        }
        let temp = Self.uploadsFolder.appendingPathComponent("upload-\(UUID().uuidString)")
        let handle: FileHandle
        do {
            try fm.createDirectory(at: Self.uploadsFolder, withIntermediateDirectories: true)
            guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: temp)
        } catch {
            try? fm.removeItem(at: temp)
            respondError(500, "无法创建临时文件：\(error.localizedDescription)")
            return
        }
        let id = UUID()
        upload = Upload(id: id, name: name, folder: folder, temp: temp, handle: handle, expected: expected)
        context.emit(.transferStarted(id: id, name: name, isUpload: true, total: expected))
        if request.headers["expect"]?.lowercased() == "100-continue" {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        if !body.isEmpty {
            guard write(body.prefix(Int(min(Int64(body.count), expected)))) else { return }
        }
        receiveBody()
    }

    private func receiveBody() {
        guard let upload, !isClosed else { return }
        let remaining = upload.expected - upload.received
        guard remaining > 0 else {
            finishUpload()
            return
        }
        let maximum = Int(min(remaining, Int64(Self.chunkSize)))
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                guard self.write(data) else { return }
            }
            if let upload = self.upload, upload.received >= upload.expected {
                self.finishUpload()
            } else if isComplete || error != nil {
                self.close(reason: "连接中断，文件没有传完")
            } else {
                self.receiveBody()
            }
        }
    }

    /// Appends body bytes to the temporary file. On failure it answers with an error and returns false.
    private func write(_ data: Data) -> Bool {
        guard var current = upload else { return false }
        do {
            try current.handle.write(contentsOf: data)
        } catch {
            let full = Self.isOutOfSpace(error)
            failUpload(status: full ? 507 : 500, message: full ? "手机存储空间不足" : "写入失败：\(error.localizedDescription)")
            return false
        }
        current.received += Int64(data.count)
        upload = current
        touch()
        reportProgress(id: current.id, done: current.received)
        return true
    }

    private func finishUpload() {
        guard let finished = upload else { return }
        upload = nil
        lingers = false
        do {
            try finished.handle.close()
            let saved = try locked {
                try Vault.place(finished.temp, named: finished.name, in: finished.folder, move: true)
            }
            context.emit(.transferFinished(
                id: finished.id,
                name: saved.lastPathComponent,
                isUpload: true,
                folder: relativePath(of: finished.folder)
            ))
            respondJSON(201, ["name": saved.lastPathComponent])
        } catch {
            try? fm.removeItem(at: finished.temp)
            context.emit(.transferFailed(id: finished.id, name: finished.name, isUpload: true, reason: "保存失败：\(error.localizedDescription)"))
            respondError(500, "保存失败：\(error.localizedDescription)")
        }
    }

    private func failUpload(status: Int, message: String) {
        guard let failed = upload else { return }
        upload = nil
        try? failed.handle.close()
        try? fm.removeItem(at: failed.temp)
        context.emit(.transferFailed(id: failed.id, name: failed.name, isUpload: true, reason: message))
        respondError(status, message)
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// At most a few progress events per second per transfer.
    private func reportProgress(id: UUID, done: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgressReport >= 0.3 else { return }
        lastProgressReport = now
        context.emit(.transferProgress(id: id, done: done))
    }

    // MARK: - Responses

    private func respond(_ status: Int, type: String, body: Data, headers: [(String, String)] = [], headOnly: Bool = false) {
        let all = [("Content-Type", type), ("Content-Length", String(body.count))] + headers
        var data = TransferHTTP.head(status: status, headers: all)
        if !headOnly { data.append(body) }
        send(data) { [weak self] in self?.endResponse() }
    }

    private func respondJSON<T: Encodable>(_ status: Int, _ value: T) {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        respond(status, type: "application/json; charset=utf-8", body: body)
    }

    /// A JSON `{"error": message}` the page shows to the user.
    private func respondError(_ status: Int, _ message: String) {
        respondJSON(status, ["error": message])
    }

    private func send(_ data: Data, then next: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isClosed else { return }
            if error != nil {
                self.close(reason: "连接中断")
                return
            }
            self.touch()
            next()
        })
    }

    /// Closes the sending side once everything is out, then releases the connection.
    private func endResponse() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self, !self.isClosed else { return }
            if self.lingers {
                self.discardBody(upTo: Self.maxDiscard)
            } else {
                self.close(reason: nil)
            }
        })
    }

    /// Reads and drops the rest of a rejected upload until the client hangs up, `limit` bytes were
    /// dropped or the idle timeout hits.
    private func discardBody(upTo limit: Int64) {
        guard limit > 0 else {
            close(reason: nil)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            self.touch()
            if isComplete || error != nil {
                self.close(reason: nil)
            } else {
                self.discardBody(upTo: limit - Int64(data?.count ?? 0))
            }
        }
    }
}
