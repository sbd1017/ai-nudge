import AppKit
import Network

extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
}

/// The settings page and its small JSON API. Listens on 127.0.0.1 only, unless "other devices"
/// is switched on; every request needs the token that's in the link from the menu bar.
@MainActor
final class WebServer {
    static let shared = WebServer()
    private var listener: NWListener?
    private var store: Store { .shared }

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: UInt16(store.config.port))!
        do {
            if store.config.allowLAN {
                listener = try NWListener(using: params, on: port)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
                listener = try NWListener(using: params)
            }
        } catch {
            store.record("settings page couldn't start on port \(port): \(error.localizedDescription)")
            return
        }
        listener?.newConnectionHandler = { conn in
            MainActor.assumeIsolated { WebServer.shared.accept(conn) }
        }
        listener?.start(queue: .main)
    }

    func restart() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { WebServer.shared.start() } }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, Data())
    }

    private func receive(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                guard error == nil, buffer.count < 1_000_000 else { conn.cancel(); return }
                if let request = Request(buffer) {
                    WebServer.shared.respond(to: request, on: conn)
                } else if done {
                    conn.cancel()
                } else {
                    WebServer.shared.receive(conn, buffer)
                }
            }
        }
    }

    private func respond(to r: Request, on conn: NWConnection) {
        let (status, type, body) = route(r)
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        head += "Content-Security-Policy: default-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n"
        head += "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func route(_ r: Request) -> (String, String, Data) {
        // The stylesheet and script hold no settings, so they load without the token.
        switch (r.method, r.path) {
        case ("GET", "/app.css"): return ("200 OK", "text/css; charset=utf-8", Data(settingsCSS.utf8))
        case ("GET", "/app.js"): return ("200 OK", "text/javascript; charset=utf-8", Data(settingsJS.utf8))
        default: break
        }
        guard r.token == store.config.token else {
            return ("403 Forbidden", "text/plain; charset=utf-8", Data("This page needs AI Nudge's secret link. On the Mac, copy the link from AI Nudge's Settings › General.\n".utf8))
        }
        switch (r.method, r.path) {
        case ("GET", "/"):
            return ("200 OK", "text/html; charset=utf-8", Data(settingsPage.utf8))
        case ("GET", "/api/state"):
            return json(snapshot())
        case ("PUT", "/api/config"):
            guard let new = try? JSONDecoder.iso.decode(Config.self, from: r.body) else {
                return ("400 Bad Request", "text/plain", Data("bad settings".utf8))
            }
            store.update(new)
            return json(snapshot())
        case ("POST", "/api/send"):
            store.sendNow(r.query["id"] ?? "")
            return json(snapshot())
        case ("POST", "/api/awake"):
            let m = r.query["minutes"] ?? ""
            store.keepAwake(minutes: m == "forever" ? nil : Int(m) ?? 0)
            return json(snapshot())
        case ("POST", "/api/accessibility"):
            Sender.requestTrust()
            return json(snapshot())
        default:
            return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private struct Snapshot: Encodable {
        struct Option: Encodable { let id: String, label: String, chat: String?, note: String? }
        let config: Config
        let targets: [Option]
        let browsers: [Option]
        let defaultBrowser: String
        let status: [String: [String: String]]
        let trusted: Bool
        let sending: String?
        let lanURL: String?
        let siteURL: String?
        let awake: String?
        let codexStatus: String
        let codexThreads: [Option]
        let today: String
        let nextNudge: String?
        let log: [String]
    }

    private func snapshot() -> Snapshot {
        store.refreshCodexThreads()
        var config = store.config
        config.token = ""
        let defaultID = Sender.defaultBrowser
        let defaultName = Sender.knownBrowsers.first { $0.0 == defaultID }?.1 ?? "default"
        return Snapshot(
            config: config,
            targets: Target.allCases.map { .init(id: $0.rawValue, label: $0.label, chat: $0.chatPrompt, note: $0.note) },
            browsers: Sender.installedBrowsers.map { .init(id: $0.id, label: $0.name, chat: nil, note: nil) },
            defaultBrowser: defaultName,
            // Formatted here: browsers can report a different time zone (Firefox's fingerprinting protection uses UTC).
            status: Dictionary(uniqueKeysWithValues: store.config.nudges.map { n in
                (n.id, ["next": store.nextText(n), "last": store.lastText(n), "failed": store.lastFailed(n) ? "1" : ""])
            }),
            trusted: Sender.trusted,
            sending: store.sending,
            lanURL: store.lanURL?.absoluteString,
            siteURL: store.siteURL?.absoluteString,
            awake: store.awakeText,
            codexStatus: store.codexStatusText,
            codexThreads: store.codexThreads.map { .init(id: $0.id, label: "\($0.name) · \(Store.short($0.updated))", chat: nil, note: nil) },
            today: Schedule.dayString(Date()),
            nextNudge: store.nextUp.map { Store.short($0.date) },
            log: store.log.reversed()
        )
    }

    private func json<T: Encodable>(_ value: T) -> (String, String, Data) {
        ("200 OK", "application/json", (try? JSONEncoder.iso.encode(value)) ?? Data())
    }
}

/// A complete HTTP/1.1 request, or nil until all of it has arrived.
struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let token: String?
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - end.upperBound >= length else { return nil }
        let parts = URLComponents(string: String(first[1]))
        method = String(first[0])
        path = parts?.path ?? "/"
        query = Dictionary((parts?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        token = headers["x-token"] ?? query["t"]
        body = data[end.upperBound..<end.upperBound + length]
    }
}
