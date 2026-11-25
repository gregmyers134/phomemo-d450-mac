import Foundation
#if canImport(Glibc)
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
private let sendFlags = Int32(MSG_NOSIGNAL)
#else
import Darwin
private let streamSocket = SOCK_STREAM
private let sendFlags: Int32 = 0
#endif

public struct HttpRequest {
    public var method: String
    public var path: String
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: [UInt8]
}

public struct HttpResponse {
    public var status: Int
    public var contentType: String
    public var body: [UInt8]

    public init(status: Int, contentType: String = "text/plain; charset=utf-8", body: [UInt8] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func text(_ status: Int, _ message: String) -> HttpResponse {
        HttpResponse(status: status, body: Array((message + "\n").utf8))
    }
}

public enum HttpError: Error, Equatable {
    case cannotListen(String)
}

/// A small HTTP/1.1 server on the loopback interface only, built on BSD
/// sockets so it needs nothing beyond the system libraries. It handles
/// "Expect: 100-continue", chunked request bodies and keep-alive, which is
/// what IPP clients use.
public final class HttpServer {
    /// Looks at the request line and headers before the body is read. Return a
    /// response to refuse the request; the connection is then closed.
    public typealias Precheck = (_ method: String, _ path: String, _ headers: [String: String]) -> HttpResponse?
    public typealias Handler = (HttpRequest) -> HttpResponse

    private let port: UInt16
    private let maxBody: Int
    private let precheck: Precheck
    private let handler: Handler
    private let log: (String) -> Void
    private static let maxHead = 32 * 1024
    private static let timeoutSeconds = 60

    public init(port: UInt16, maxBody: Int = 256 << 20, log: @escaping (String) -> Void,
                precheck: @escaping Precheck, handler: @escaping Handler) {
        self.port = port
        self.maxBody = maxBody
        self.precheck = precheck
        self.handler = handler
        self.log = log
    }

    /// Binds 127.0.0.1 (required) and ::1 (when available) and starts accepting.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        guard let v4 = HttpServer.listen4(port) else {
            throw HttpError.cannotListen("cannot listen on 127.0.0.1:\(port): \(String(cString: strerror(errno)))")
        }
        acceptLoop(v4)
        if let v6 = HttpServer.listen6(port) { acceptLoop(v6) } else { log("not listening on [::1]:\(port) (IPv6 loopback unavailable)") }
    }

    private static func prepare(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func listen4(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, streamSocket, 0)
        guard fd >= 0 else { return nil }
        prepare(fd)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian      // 127.0.0.1
        #if !canImport(Glibc)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { let e = errno; close(fd); errno = e; return nil }
        return fd
    }

    private static func listen6(_ port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, streamSocket, 0)
        guard fd >= 0 else { return nil }
        prepare(fd)
        var yes: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback                          // ::1
        #if !canImport(Glibc)
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); return nil }
        return fd
    }

    private func acceptLoop(_ listener: Int32) {
        Thread.detachNewThread { [self] in
            while true {
                let fd = accept(listener, nil, nil)
                if fd < 0 {
                    if errno != EINTR { usleep(100_000) }
                    continue
                }
                var tv = timeval(tv_sec: HttpServer.timeoutSeconds, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                #if !canImport(Glibc)
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                #endif
                Thread.detachNewThread { [self] in
                    serve(fd)
                    close(fd)
                }
            }
        }
    }

    // MARK: One connection

    private struct Reader {
        let fd: Int32
        var buffer = [UInt8]()
        var start = 0

        /// Drops bytes that have been consumed. Only called between reads, so no
        /// caller holds an index into the buffer across it.
        private mutating func compact() {
            if start == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                start = 0
            } else if start > 1 << 20 {
                buffer.removeSubrange(0 ..< start)
                start = 0
            }
        }

        /// Reads more bytes into the buffer. False at end of stream, on error or on timeout.
        mutating func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n > 0 { buffer.append(contentsOf: chunk[0 ..< n]); return true }
                if n < 0 && errno == EINTR { continue }
                return false
            }
        }

        /// Bytes up to and including `terminator`, or nil if it does not arrive within `limit` bytes.
        mutating func through(_ terminator: [UInt8], limit: Int) -> [UInt8]? {
            compact()
            var searchFrom = start
            while true {
                while searchFrom + terminator.count <= buffer.count {
                    var match = true
                    for k in 0 ..< terminator.count where buffer[searchFrom + k] != terminator[k] { match = false; break }
                    if match {
                        let out = Array(buffer[start ..< searchFrom + terminator.count])
                        start = searchFrom + terminator.count
                        return out
                    }
                    searchFrom += 1
                }
                if buffer.count - start > limit || !fill() { return nil }
            }
        }

        mutating func exactly(_ n: Int) -> [UInt8]? {
            compact()
            while buffer.count - start < n { if !fill() { return nil } }
            defer { start += n }
            return Array(buffer[start ..< start + n])
        }

        var isEmpty: Bool { start == buffer.count }
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, sendFlags) }
            if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    private static let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                                  405: "Method Not Allowed", 413: "Payload Too Large",
                                  415: "Unsupported Media Type", 500: "Internal Server Error"]

    private func sendResponse(_ fd: Int32, _ r: HttpResponse, close: Bool, headOnly: Bool = false) -> Bool {
        var head = "HTTP/1.1 \(r.status) \(HttpServer.reasons[r.status] ?? "Status")\r\n"
        head += "Server: d450d\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: \(close ? "close" : "keep-alive")\r\n\r\n"
        return sendAll(fd, Array(head.utf8) + (headOnly ? [] : r.body))
    }

    private func serve(_ fd: Int32) {
        var reader = Reader(fd: fd)
        while true {
            // Request line and headers.
            if reader.isEmpty && !reader.fill() { return }
            guard let headBytes = reader.through([13, 10, 13, 10], limit: HttpServer.maxHead) else {
                _ = sendResponse(fd, .text(400, "Bad request"), close: true)
                return
            }
            let lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
                _ = sendResponse(fd, .text(400, "Bad request"), close: true)
                return
            }
            let method = String(parts[0])
            let path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            var headers = [String: String]()
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if let refusal = precheck(method, path, headers) {
                _ = sendResponse(fd, refusal, close: true)
                return
            }

            // Body.
            let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
            let declared = Int(headers["content-length"] ?? "0") ?? -1
            guard declared >= 0, declared <= maxBody else {
                _ = sendResponse(fd, .text(declared < 0 ? 400 : 413, "Bad content length"), close: true)
                return
            }
            if headers["expect"]?.lowercased() == "100-continue" && (chunked || declared > 0) {
                guard sendAll(fd, Array("HTTP/1.1 100 Continue\r\n\r\n".utf8)) else { return }
            }
            var body = [UInt8]()
            if chunked {
                while true {
                    guard let sizeLine = reader.through([13, 10], limit: 256) else { log("connection lost while reading a chunked request"); return }
                    let hex = String(decoding: sizeLine.dropLast(2), as: UTF8.self)
                        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                        .trimmingCharacters(in: .whitespaces)
                    guard let size = Int(hex, radix: 16), size >= 0, body.count + size <= maxBody else {
                        _ = sendResponse(fd, .text(400, "Bad chunk"), close: true)
                        return
                    }
                    if size == 0 {
                        // Trailer lines, if any, end with an empty line.
                        while let trailer = reader.through([13, 10], limit: 8192), trailer.count > 2 {}
                        break
                    }
                    guard let piece = reader.exactly(size), reader.exactly(2) != nil else { log("connection lost while reading a chunked request"); return }
                    body.append(contentsOf: piece)
                }
            } else if declared > 0 {
                guard let b = reader.exactly(declared) else { log("connection lost while reading a request body"); return }
                body = b
            }

            let response = handler(HttpRequest(method: method, path: path, headers: headers, body: body))
            let closing = parts[2] == "HTTP/1.0" || (headers["connection"]?.lowercased().contains("close") ?? false)
            guard sendResponse(fd, response, close: closing, headOnly: method == "HEAD"), !closing else { return }
        }
    }
}
