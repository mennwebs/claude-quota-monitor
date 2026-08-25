import Foundation
import Network

/// A deliberately tiny HTTP/1.1 server bound to 127.0.0.1 only.
///
/// The browser extension cannot write files, and installing a native-messaging host
/// into five Chromium data directories is more moving parts than this. One loopback
/// port serves every browser profile with a single manifest change on the extension side.
///
/// Scope is kept as small as it can be: two routes, a request-size ceiling, a shared
/// token, and no reachability beyond the loopback interface.
final class LoopbackServer {
    enum ServerState: Equatable {
        case stopped
        case listening(UInt16)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.mennwebs.cqm.server")
    private var listener: NWListener?
    private var live: [ObjectIdentifier: NWConnection] = [:]
    private var liveOrder: [ObjectIdentifier] = []
    private var token: String = ""

    /// 256 KB is far beyond any real report; anything larger is dropped unread.
    private let maxRequestBytes = 256 * 1024
    /// Every local process can reach this port. A request that never completes must not
    /// be able to hold a file descriptor open indefinitely, or enough of them to stop
    /// the listener accepting the one request that matters.
    private let maxLiveConnections = 32
    private let requestDeadline: TimeInterval = 10

    private let onReport: @Sendable (Data) -> ReportAck
    private let onState: @Sendable (ServerState) -> Void

    /// What the sender learns from a successful post. `refresh` is the only way this
    /// machine can ask the browser to go fetch fresh numbers — see `RefreshFlag`.
    struct ReportAck: Sendable {
        var refresh: Bool = false
    }

    init(onReport: @escaping @Sendable (Data) -> ReportAck,
         onState: @escaping @Sendable (ServerState) -> Void) {
        self.onReport = onReport
        self.onState = onState
    }

    func start(port: UInt16, token: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.token = token

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.onState(.failed("พอร์ต \(port) ไม่ถูกต้อง"))
                return
            }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = false
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

            do {
                let l = try NWListener(using: params)
                l.stateUpdateHandler = { [weak self, weak l] st in
                    // A cancelled listener still delivers `.cancelled` — and possibly a
                    // late `.waiting` naming the *old* port — after its replacement is
                    // already live. Without this check the loser of that race is what
                    // the user sees: "server stopped" over a server that is running.
                    guard let self, let l, self.listener === l else { return }
                    switch st {
                    case .ready:  self.onState(.listening(port))
                    case .failed(let e), .waiting(let e):
                        self.onState(.failed(Self.describe(e, port: port)))
                    case .cancelled: self.onState(.stopped)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                l.start(queue: self.queue)
                self.listener = l
            } catch {
                self.onState(.failed(Self.describe(error, port: port)))
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
            // stopLocked() clears `listener`, so the identity guard above will swallow
            // the listener's own `.cancelled`. Announce the stop here instead.
            self?.onState(.stopped)
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        live.values.forEach { $0.cancel() }
        live.removeAll()
        liveOrder.removeAll()
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if let e = error as? NWError, case .posix(let code) = e, code == .EADDRINUSE {
            return "พอร์ต \(port) ถูกใช้อยู่แล้ว — เปลี่ยนพอร์ตในหน้าตั้งค่า"
        }
        return "\(error.localizedDescription) (พอร์ต \(port))"
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        // At capacity, drop the oldest rather than refuse the newest. A real exchange is
        // over in milliseconds, so the oldest connection is the one stalling — turning
        // away the new arrival would let a flood lock out the request that matters.
        while liveOrder.count >= maxLiveConnections, let oldest = liveOrder.first {
            liveOrder.removeFirst()
            live.removeValue(forKey: oldest)?.cancel()
        }

        let id = ObjectIdentifier(conn)
        live[id] = conn
        liveOrder.append(id)
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled:
                self?.queue.async { self?.release(id) }
            default: break
            }
        }
        // Unconditional, and safe as a blanket rule: every reply sends `Connection: close`
        // and cancels in its completion handler, so a well-behaved exchange is long over
        // by now and cancelling twice is a no-op.
        queue.asyncAfter(deadline: .now() + requestDeadline) { conn.cancel() }
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func release(_ id: ObjectIdentifier) {
        live.removeValue(forKey: id)
        liveOrder.removeAll { $0 == id }
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let chunk, !chunk.isEmpty { buf.append(chunk) }

            if buf.count > self.maxRequestBytes {
                self.respond(conn, 413, ["error": "too large"], origin: nil)
                return
            }
            if error != nil { conn.cancel(); return }

            if let request = HTTPRequest(buf) {
                self.handle(request, on: conn)
                return
            }
            if done { conn.cancel(); return }
            self.read(conn, buffer: buf)
        }
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        // Only an extension page should ever be talking to this port. A same-origin
        // web page cannot read our replies anyway (no permissive CORS below), but
        // echoing the origin back keeps the preflight honest about who is allowed.
        let origin = req.header("origin").flatMap { $0.hasPrefix("chrome-extension://") ? $0 : nil }

        switch (req.method, req.path) {
        case ("OPTIONS", _):
            respond(conn, 204, nil, origin: origin)

        case ("GET", "/v1/health"):
            // Unauthenticated on purpose: the extension needs a way to tell
            // "app is not running" from "token is wrong" without leaking anything.
            respond(conn, 200, ["ok": true, "app": "claude-quota-mac", "v": 1], origin: origin)

        case ("POST", "/v1/usage"):
            guard !token.isEmpty, let got = req.header("x-cqm-token"), constantTimeEqual(got, token) else {
                respond(conn, 401, ["error": "bad token"], origin: origin)
                return
            }
            guard !req.body.isEmpty else {
                respond(conn, 400, ["error": "empty body"], origin: origin)
                return
            }
            let ack = onReport(req.body)
            respond(conn, 200, ["ok": true, "refresh": ack.refresh], origin: origin)

        default:
            respond(conn, 404, ["error": "no route"], origin: origin)
        }
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ json: [String: Any]?, origin: String?) {
        let body: Data = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Access-Control-Allow-Headers: content-type, x-cqm-token\r\n"
            head += "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n"
            head += "Vary: Origin\r\n"
        }
        head += "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        default:  return "Error"
        }
    }
}

/// Compare without an early exit on the first differing byte.
private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<x.count { diff |= x[i] ^ y[i] }
    return diff == 0
}

/// Just enough parsing for the two routes above: request line, headers, and a
/// Content-Length body. Chunked encoding is not accepted — nothing we talk to uses it.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased names
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Returns nil while the request is still incomplete, so the caller keeps reading.
    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headText = String(data: headData, encoding: .utf8) else { return nil }

        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }

        method = String(requestLine[0]).uppercased()
        path = String(requestLine[1].split(separator: "?").first ?? "")

        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[name] = value
        }
        headers = h

        let declared = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= declared else { return nil }   // body still arriving
        body = declared > 0 ? Data(data[bodyStart..<data.index(bodyStart, offsetBy: declared)]) : Data()
    }
}
