import Foundation
import Network
import UIKit

/// A finished or failed transfer in the screen's log.
struct TransferLogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let symbol: String
    let title: String
    let detail: String?
    let isError: Bool
}

/// A transfer in progress. `isUpload` is from the phone's point of view (received from the computer).
struct TransferProgress: Identifiable {
    let id: UUID
    let name: String
    let isUpload: Bool
    let total: Int64
    var done: Int64 = 0

    var fraction: Double {
        total > 0 ? min(1, Double(done) / Double(total)) : 0
    }
}

/// The phone's address on the local network.
struct TransferHost: Equatable {
    let ip: String
    /// The address belongs to the phone's Personal Hotspot rather than to a Wi-Fi network.
    let isHotspot: Bool

    /// The Wi-Fi (en0) IPv4 address, else the Personal Hotspot's (bridge*) one.
    static func current() -> TransferHost? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var wifi: String?
        var hotspot: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = entry.pointee.ifa_flags
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let ip = numericHost(address),
                  !ip.hasPrefix("169.254.")
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name == "en0" {
                wifi = wifi ?? ip
            } else if name.hasPrefix("bridge") {
                hotspot = hotspot ?? ip
            }
        }
        if let wifi { return TransferHost(ip: wifi, isHotspot: false) }
        if let hotspot { return TransferHost(ip: hotspot, isHotspot: true) }
        return nil
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) }
        }
    }
}

/// Drives TransferServer for TransferView: the server runs only while the screen is visible, its
/// switch is on and the app is active, and its events become progress rows and a log.
@MainActor
final class TransferController: ObservableObject {
    enum Status: Equatable {
        case off
        case starting
        case running
        case waiting(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var isEnabled = true
    @Published private(set) var port: UInt16?
    @Published private(set) var host: TransferHost?
    @Published private(set) var token = ""
    @Published private(set) var transfers: [TransferProgress] = []
    @Published private(set) var log: [TransferLogEntry] = []
    /// iOS reports that FileBox's local network access is turned off, so no computer can connect.
    @Published private(set) var isLocalNetworkDenied = false

    private var server: TransferServer?
    private weak var store: FileStore?
    private var isVisible = false
    private var isSceneActive = false
    /// A fresh token for every start the user asks for; an automatic restart after the app was
    /// briefly inactive keeps the address, so an open browser tab keeps working.
    private var needsNewToken = true
    private var lastPort: UInt16?
    private var pathMonitor: NWPathMonitor?
    /// Only the latest local network probe may update `isLocalNetworkDenied`.
    private var probeGeneration = 0
    private var isRefreshPending = false

    /// What the computer's browser opens, e.g. "http://192.168.1.5:8080/k3mx9q/".
    var address: String? {
        guard status == .running, let host, let port else { return nil }
        return "http://\(host.ip):\(port)/\(token)/"
    }

    // MARK: - Lifecycle

    func appear(store: FileStore, sceneActive: Bool) {
        self.store = store
        isVisible = true
        isSceneActive = sceneActive
        startMonitoringNetwork()
        refreshHost()
        update()
    }

    func disappear() {
        isVisible = false
        pathMonitor?.cancel()
        pathMonitor = nil
        update()
    }

    func sceneChanged(active: Bool) {
        isSceneActive = active
        if active { refreshHost() }
        update()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            needsNewToken = true
            if case .failed = status { status = .off }
        }
        update()
    }

    private func update() {
        let shouldRun = isEnabled && isVisible && isSceneActive
        if shouldRun && server == nil {
            startServer()
        } else if !shouldRun && server != nil {
            stopServer()
        }
    }

    private func startServer() {
        if needsNewToken || token.isEmpty {
            token = Self.makeToken()
            needsNewToken = false
        }
        let server = TransferServer(token: token, root: Vault.root)
        server.onEvent = { [weak self, weak server] event in
            guard let self, let server, server === self.server else { return }
            self.handle(event)
        }
        self.server = server
        status = .starting
        port = nil
        server.start(port: lastPort ?? TransferServer.preferredPort)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func stopServer() {
        server?.onEvent = nil
        server?.stop()
        server = nil
        for transfer in transfers {
            appendLog(
                symbol: "exclamationmark.triangle.fill",
                title: "「\(transfer.name)」\(transfer.isUpload ? "接收" : "发送")中断",
                detail: "传输已停止",
                isError: true
            )
        }
        transfers.removeAll()
        port = nil
        if case .failed = status {} else { status = .off }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Events

    private func handle(_ event: TransferServerEvent) {
        switch event {
        case .ready(let port):
            self.port = port
            lastPort = port
            status = .running
            host = TransferHost.current()
            probeLocalNetwork()
        case .waiting(let message):
            status = .waiting(message)
        case .failed(let message):
            status = .failed(message)
            isEnabled = false
            update()
        case .transferStarted(let id, let name, let isUpload, let total):
            transfers.append(TransferProgress(id: id, name: name, isUpload: isUpload, total: total))
        case .transferProgress(let id, let done):
            if let index = transfers.firstIndex(where: { $0.id == id }) {
                transfers[index].done = done
            }
        case .transferFinished(let id, let name, let isUpload, let folder):
            transfers.removeAll { $0.id == id }
            if isUpload {
                appendLog(symbol: "arrow.down.circle.fill", title: "收到「\(name)」", detail: "保存在「\(folderLabel(folder))」", isError: false)
                scheduleRefresh()
            } else {
                appendLog(symbol: "arrow.up.circle.fill", title: "发送「\(name)」", detail: "来自「\(folderLabel(folder))」", isError: false)
            }
        case .transferFailed(let id, let name, let isUpload, let reason):
            transfers.removeAll { $0.id == id }
            appendLog(
                symbol: "exclamationmark.triangle.fill",
                title: "「\(name)」\(isUpload ? "接收" : "发送")失败",
                detail: reason,
                isError: true
            )
        case .folderCreated(let name, let folder):
            appendLog(symbol: "folder.fill.badge.plus", title: "新建文件夹「\(name)」", detail: "在「\(folderLabel(folder))」里", isError: false)
            scheduleRefresh()
        }
    }

    /// A folder upload can finish hundreds of files a minute; the open folders reload at most
    /// twice a second instead of once per file.
    private func scheduleRefresh() {
        guard !isRefreshPending, let store else { return }
        isRefreshPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self?.isRefreshPending = false
            store.refresh()
        }
    }

    private func folderLabel(_ folder: String) -> String {
        folder.isEmpty ? "FileBox" : folder
    }

    private func appendLog(symbol: String, title: String, detail: String?, isError: Bool) {
        log.insert(TransferLogEntry(symbol: symbol, title: title, detail: detail, isError: isError), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    // MARK: - Network

    private func refreshHost() {
        let current = TransferHost.current()
        guard current != host else { return }
        host = current
        probeLocalNetwork()
    }

    /// Asks for local network access (the first time) and finds out whether it is turned off.
    private func probeLocalNetwork() {
        guard status == .running, let host else { return }
        probeGeneration += 1
        let generation = probeGeneration
        TransferLocalNetwork.probe(near: host.ip) { [weak self] denied in
            guard let self, generation == self.probeGeneration else { return }
            self.isLocalNetworkDenied = denied
        }
    }

    /// Keeps the shown address right when Wi-Fi connects, drops or changes.
    private func startMonitoringNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refreshHost() }
        }
        monitor.start(queue: DispatchQueue(label: "FileBox.Transfer.path"))
        pathMonitor = monitor
    }

    /// Six characters that are easy to read and type (no 0/o, 1/l/i).
    private static func makeToken() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// One UDP datagram to a neighbor address (discard port). The first one makes iOS ask for local
/// network access as soon as the server runs, instead of silently dropping the computer's first
/// connection; later ones tell whether the user turned that access off.
private enum TransferLocalNetwork {
    /// Calls `result` on the main queue with true when local network access is denied, false once
    /// the datagram can be sent. It may not be called at all (no answer within five seconds).
    static func probe(near ip: String, result: @escaping (Bool) -> Void) {
        var octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return }
        octets[3] = octets[3] == 1 ? 2 : 1
        let neighbor = octets.map(String.init).joined(separator: ".")
        let queue = DispatchQueue(label: "FileBox.Transfer.probe")
        let connection = NWConnection(host: NWEndpoint.Host(neighbor), port: 9, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data([0]), completion: .idempotent)
                DispatchQueue.main.async { result(false) }
            case .waiting:
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    DispatchQueue.main.async { result(true) }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}
