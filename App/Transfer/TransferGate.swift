import Foundation

/// A computer asking for access, shown as a prompt on the phone.
struct TransferAccessRequest: Identifiable, Equatable {
    let id: UUID
    let ip: String
    /// "Windows · Chrome", or "" when the browser is not recognized.
    let client: String

    /// "192.168.1.5（Windows · Chrome）"
    var label: String {
        client.isEmpty ? ip : "\(ip)（\(client)）"
    }
}

/// Decides which browsers may use the transfer server. A browser is known by a random session
/// cookie; the first time it asks, the phone shows a prompt, and only an allowed session reaches the
/// files. Approvals survive a brief server restart (the app inactive for a moment) but are all
/// revoked when the user leaves the transfer screen or the app locks; no computer is remembered.
/// Safe to use from any queue.
final class TransferGate: @unchecked Sendable {
    enum State: String {
        case pending, allowed, denied
    }

    /// What a browser's status poll gets back.
    struct Poll {
        let state: State
        /// A new session the response must set as a cookie.
        var newSession: String?
        /// Always nil: computers are never remembered (old device cookies are ignored).
        var device: String?
        /// A new prompt for the phone.
        var request: TransferAccessRequest?
    }

    private struct Session {
        var state: State
        let ip: String
        let client: String
        /// The open prompt this session waits for.
        var request: UUID?
    }

    private struct Pending {
        let request: TransferAccessRequest
        var sessions: [String]
    }

    static let shared = TransferGate()
    static let sessionCookie = "filebox_session"
    static let deviceCookie = "filebox_device"

    /// Sessions kept per prompt; a browser that drops cookies cannot pile them up.
    private static let maxSessionsPerRequest = 8

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var pending: [UUID: Pending] = [:]

    private init() {}

    /// The browser with these cookies may see and change files.
    func isAllowed(session: String?, device: String?) -> Bool {
        locked { isAllowedLocked(session: session, device: device) }
    }

    /// A status poll from the waiting page. An unknown browser gets a new session and, unless the
    /// same computer already waits for an answer, a new prompt. `retry` asks again after a denial.
    func poll(session: String?, device: String?, ip: String, client: String, retry: Bool) -> Poll {
        locked {
            guard let id = session, var current = sessions[id] else {
                let newID = Self.makeToken()
                sessions[newID] = Session(state: .pending, ip: ip, client: client)
                return Poll(state: .pending, newSession: newID, request: enqueue(newID))
            }
            switch current.state {
            case .allowed:
                return Poll(state: .allowed)
            case .denied:
                guard retry else { return Poll(state: .denied) }
                current.state = .pending
                sessions[id] = current
                return Poll(state: .pending, request: enqueue(id))
            case .pending:
                return Poll(state: .pending, request: current.request == nil ? enqueue(id) : nil)
            }
        }
    }

    /// The user's answer to a prompt. Applies to every session waiting on it.
    func decide(_ requestID: UUID, allow: Bool) {
        locked {
            guard let answered = pending.removeValue(forKey: requestID) else { return }
            for id in answered.sessions {
                guard var session = sessions[id] else { continue }
                session.state = allow ? .allowed : .denied
                session.request = nil
                sessions[id] = session
            }
        }
    }

    /// Ends every approval: the next visit from any computer has to be allowed on the phone again.
    func revokeAll() {
        locked {
            sessions.removeAll()
            pending.removeAll()
        }
    }

    /// Drops unanswered prompts when the server stops; waiting browsers ask again once it is back.
    func dropPending() {
        locked {
            for item in pending.values {
                item.sessions.forEach { sessions[$0] = nil }
            }
            pending.removeAll()
        }
    }

    // MARK: - Private

    private func isAllowedLocked(session: String?, device: String?) -> Bool {
        guard let session else { return false }
        return sessions[session]?.state == .allowed
    }

    /// Adds a pending session to the open prompt for its computer, or opens a new prompt (returned).
    private func enqueue(_ id: String) -> TransferAccessRequest? {
        guard var session = sessions[id] else { return nil }
        if let key = pending.first(where: { $0.value.request.ip == session.ip })?.key, var item = pending[key] {
            item.sessions.append(id)
            if item.sessions.count > Self.maxSessionsPerRequest {
                sessions[item.sessions.removeFirst()] = nil
            }
            pending[key] = item
            session.request = key
            sessions[id] = session
            return nil
        }
        let request = TransferAccessRequest(id: UUID(), ip: session.ip, client: session.client)
        pending[request.id] = Pending(request: request, sessions: [id])
        session.request = request.id
        sessions[id] = session
        return request
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// 128 random bits as hex.
    private static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
