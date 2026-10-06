import Foundation
import UniformTypeIdentifiers

/// A parsed HTTP/1.1 request head (request line and headers, without the body).
struct TransferRequest {
    let method: String
    /// The raw request path, without the query.
    let path: String
    /// Percent-decoded path components (UTF-8), empty components dropped.
    let segments: [String]
    /// Percent-decoded query parameters.
    let query: [String: String]
    /// Header values by lowercased name.
    let headers: [String: String]

    /// Returns nil for anything that is not a well-formed origin-form HTTP/1.x request.
    init?(head: Data) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        // Clients may send empty lines before the request line.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])

        let pathPart: String
        let queryPart: String
        if let mark = target.firstIndex(of: "?") {
            pathPart = String(target[..<mark])
            queryPart = String(target[target.index(after: mark)...])
        } else {
            pathPart = target
            queryPart = ""
        }
        guard pathPart.hasPrefix("/") else { return nil }

        var segments: [String] = []
        for raw in pathPart.split(separator: "/") {
            guard let decoded = String(raw).removingPercentEncoding else { return nil }
            segments.append(decoded)
        }

        var query: [String: String] = [:]
        for pair in queryPart.split(separator: "&") {
            let field = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = Self.decodeQueryPart(field[0]),
                  let value = field.count > 1 ? Self.decodeQueryPart(field[1]) : ""
            else { return nil }
            query[key] = value
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        self.method = parts[0].uppercased()
        self.path = pathPart
        self.segments = segments
        self.query = query
        self.headers = headers
    }

    /// Query strings may encode spaces as "+"; the page itself always sends %20.
    private static func decodeQueryPart(_ part: Substring) -> String? {
        String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

/// Building blocks for the transfer server's responses.
enum TransferHTTP {
    enum ByteRange: Equatable {
        case whole
        /// First and last byte, inclusive.
        case partial(Int64, Int64)
        case unsatisfiable
    }

    /// Status line and headers, including the headers every response carries.
    static func head(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers + commonHeaders {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }

    private static let commonHeaders: [(String, String)] = [
        ("Connection", "close"),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 201: return "Created"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        default: return status < 500 ? "Bad Request" : "Internal Server Error"
        }
    }

    /// Interprets a Range header for a file of `size` bytes. Only a single range is honored; several
    /// ranges or a malformed header get the whole file, which HTTP allows.
    static func byteRange(_ header: String?, size: Int64) -> ByteRange {
        guard let header, header.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return .whole }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return .whole }
        if bounds[0].isEmpty {
            // "bytes=-500": the last 500 bytes.
            guard let suffix = Int64(bounds[1]) else { return .whole }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix), size - 1)
        }
        guard let first = Int64(bounds[0]), first >= 0 else { return .whole }
        guard first < size else { return .unsatisfiable }
        if bounds[1].isEmpty { return .partial(first, size - 1) }
        guard let last = Int64(bounds[1]), last >= first else { return .whole }
        return .partial(first, min(last, size - 1))
    }

    static func mimeType(for url: URL) -> String {
        let mime = UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
        return mime.hasPrefix("text/") ? mime + "; charset=utf-8" : mime
    }

    /// Types a browser can show in a tab without running anything on the page's origin. Everything
    /// else (HTML, SVG, ...) is always sent as a download, so a file from the vault can never script
    /// the transfer page.
    static func allowsInline(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), !type.conforms(to: .svg)
        else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .pdf) || type.conforms(to: .plainText)
    }

    /// Content-Disposition with an ASCII fallback and the RFC 5987 UTF-8 name, so Chinese file names
    /// survive in every browser.
    static func contentDisposition(_ name: String, attachment: Bool) -> String {
        let unsafe: Set<Unicode.Scalar> = ["\"", "\\", "%"]
        var fallback = ""
        for scalar in name.unicodeScalars {
            let plain = (0x20..<0x7F).contains(scalar.value) && !unsafe.contains(scalar)
            fallback.unicodeScalars.append(plain ? scalar : Unicode.Scalar(UInt8(ascii: "_")))
        }
        let kind = attachment ? "attachment" : "inline"
        return "\(kind); filename=\"\(fallback)\"; filename*=UTF-8''\(rfc5987(name))"
    }

    /// Longest name, in UTF-8 bytes, given to an uploaded file or a new folder. The file system
    /// allows 255; the rest leaves room for the " 2" that makes a name unique.
    private static let maxNameBytes = 240

    /// `sanitizedFileName(raw)` (or `fallback` when nothing is left), shortened to fit the file
    /// system's name limit while keeping the extension. Checked before an upload starts, so a long
    /// name never fails a multi-GB upload at the very end.
    static func fileName(_ raw: String, fallback: String) -> String {
        // Control characters (NUL, line breaks, ...) are never part of a real file name.
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: raw.unicodeScalars.lazy.filter { $0.properties.generalCategory != .control })
        let clean = sanitizedFileName(String(visible))
        guard !clean.isEmpty else { return fallback }
        guard clean.utf8.count > maxNameBytes else { return clean }
        let ext = (clean as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.utf8.count <= 16
        let suffix = keepsExtension ? "." + ext : ""
        let stem = keepsExtension ? (clean as NSString).deletingPathExtension : clean
        var short = ""
        var bytes = suffix.utf8.count
        for character in stem {
            let size = String(character).utf8.count
            if bytes + size > maxNameBytes { break }
            short.append(character)
            bytes += size
        }
        short = short.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? fallback : short + suffix
    }

    private static let attributeChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)

    /// Percent-encodes everything outside RFC 5987's attr-char set.
    static func rfc5987(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if attributeChars.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    /// An IMF-fixdate such as "Sun, 06 Nov 1994 08:49:37 GMT".
    static func httpDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// Path with symlinks resolved and without the /private prefix iOS adds to some URLs.
    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
