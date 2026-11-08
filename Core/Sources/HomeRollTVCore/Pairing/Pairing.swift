import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network

// Anmelden ohne Fernbedienungs-Tipperei: Das Apple TV startet im Heimnetz eine kleine Webseite und zeigt dazu einen
// QR-Code (Adresse + Code). Auf dem iPhone/Computer öffnen, Server und Zugang eintragen – das TV meldet sich an.
// Ohne Kamera geht es auch: Adresse im Browser eintippen und den sechsstelligen Code vom Fernseher eingeben.

/// Was die Webseite schickt.
struct PairingSubmission: Equatable, Sendable {
    var server: String
    var email: String = ""
    var password: String = ""
    var key: String = ""
    var usesKey: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum PairingCode {
    static func make() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }
    /// Vergleich in konstanter Zeit (kein Erraten über Antwortzeiten).
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Minimale HTTP/1.1-Anfrage (nur was die Kopplungsseite braucht).
struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]     // Schlüssel klein geschrieben
    let body: Data

    enum Parse: Equatable { case incomplete, invalid, done(HTTPRequest) }

    static let maxSize = 32 * 1024

    static func parse(_ data: Data) -> Parse {
        guard data.count <= maxSize else { return .invalid }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 8192 ? .invalid : .incomplete }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxSize else { return .invalid }
        let body = data[end.upperBound...]
        guard body.count >= length else { return .incomplete }
        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        return .done(HTTPRequest(method: String(first[0]).uppercased(), path: comps?.path ?? target, query: query,
                                 headers: headers, body: Data(body.prefix(length))))
    }

    /// application/x-www-form-urlencoded → Felder
    var form: [String: String] {
        guard let s = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            if let k = kv.first { out[k] = kv.count > 1 ? kv[1] : "" }
        }
        return out
    }
}

enum HTTPResponse {
    static func make(_ status: Int, _ html: String, contentType: String = "text/html; charset=utf-8") -> Data {
        let reason = [200: "OK", 303: "See Other", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 429: "Too Many Requests"][status] ?? "OK"
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Die Kopplungsseite (schlicht, funktioniert auf jedem Handy-Browser, ohne JavaScript).
enum PairingPage {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func form(code: String?, server: String = "", message: String? = nil, error: Bool = false) -> String {
        let codeField = code.map { "<input type=\"hidden\" name=\"code\" value=\"\(escape($0))\">" }
            ?? """
            <label>\(escape(String(localized: "Code vom Fernseher")))<input name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" required></label>
            """
        let note = message.map { "<p class=\"\(error ? "err" : "ok")\">\(escape($0))</p>" } ?? ""
        return page(String(localized: "HomeRoll TV anmelden"), """
        <h1>\(escape(String(localized: "HomeRoll TV anmelden")))</h1>
        <p>\(escape(String(localized: "Trage deinen Immich-Server ein. Die Daten gehen nur an deinen Fernseher im Heimnetz.")))</p>
        \(note)
        <form method="post" action="/pair">
        \(codeField)
        <label>\(escape(String(localized: "Server-Adresse")))<input name="server" type="url" inputmode="url" placeholder="https://photos.example.com" value="\(escape(server))" autocapitalize="off" required></label>
        <fieldset><legend>\(escape(String(localized: "Mit Immich-Konto")))</legend>
        <label>\(escape(String(localized: "E-Mail")))<input name="email" type="email" autocomplete="username" autocapitalize="off"></label>
        <label>\(escape(String(localized: "Passwort")))<input name="password" type="password" autocomplete="current-password"></label>
        </fieldset>
        <fieldset><legend>\(escape(String(localized: "Oder mit API-Schlüssel")))</legend>
        <label>\(escape(String(localized: "API-Schlüssel")))<input name="key" autocapitalize="off" autocomplete="off"></label>
        <small>\(escape(String(localized: "Immich › Kontoeinstellungen › API-Schlüssel. Für den Fernseher reichen Leserechte.")))</small>
        </fieldset>
        <button type="submit">\(escape(String(localized: "Anmelden")))</button>
        </form>
        """)
    }

    static func done(_ text: String) -> String {
        page(String(localized: "HomeRoll TV anmelden"), "<h1>✓</h1><p class=\"ok\">\(escape(text))</p>")
    }

    static func page(_ title: String, _ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title))</title><style>
        :root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif}
        body{max-width:30rem;margin:0 auto;padding:1.5rem 1rem;line-height:1.4}
        label{display:block;margin:.8rem 0;font-weight:600}
        input{display:block;width:100%;box-sizing:border-box;margin-top:.3rem;padding:.7rem;font-size:1rem;border-radius:.6rem;border:1px solid #8886}
        fieldset{border:1px solid #8884;border-radius:.8rem;margin:1rem 0;padding:.4rem .9rem}
        button{width:100%;padding:.9rem;font-size:1.05rem;font-weight:600;border:0;border-radius:.8rem;background:#0a84ff;color:#fff}
        .err{color:#ff453a;font-weight:600}.ok{color:#30d158;font-weight:600}small{opacity:.7}
        </style></head><body>\(body)</body></html>
        """
    }
}

/// Heimnetz-Adresse des Geräts (IPv4 von WLAN/Ethernet).
enum LocalAddress {
    static func ipv4() -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0, let first = ptr else { return nil }
        defer { freeifaddrs(ptr) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0, (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.hasPrefix("169.254.") { found.append((name, ip)) }
        }
        // Ethernet/WLAN (en*) vor allem anderen (VPN, Brücken)
        return found.first { $0.0.hasPrefix("en") }?.1 ?? found.first?.1
    }
}

enum QRCode {
    /// QR-Code als scharfes Bitmap (jedes Modul `scale` Pixel).
    static func image(_ text: String, scale: CGFloat = 12) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(out, from: out.extent)
    }
}

/// Kleiner Webserver für die Kopplung. Läuft nur, solange der Anmeldebildschirm offen ist; nach 5 falschen Codes
/// gibt es einen neuen Code.
final class PairingServer: @unchecked Sendable {
    typealias Handler = @Sendable (PairingSubmission) async -> Result<String, Error>

    private(set) var code = PairingCode.make()
    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var failures = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "pairing")
    private let handler: Handler
    /// Neuer Code (z. B. nach zu vielen Fehlversuchen) → Anzeige aktualisieren
    var onCodeChange: (@Sendable (String) -> Void)?

    init(handler: @escaping Handler) { self.handler = handler }

    var currentCode: String { lock.withLock { code } }

    /// Startet auf `preferredPort` (sonst einem freien Port) und meldet den Port zurück.
    func start(preferredPort: UInt16 = 8765) async throws -> UInt16 {
        for candidate in [preferredPort, 0] {
            do { return try await listen(candidate) } catch { if candidate == 0 { throw error } }
        }
        throw NWError.posix(.EADDRINUSE)
    }

    private func listen(_ p: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: p == 0 ? .any : NWEndpoint.Port(rawValue: p)!)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = l.port?.rawValue ?? 0
                    self?.lock.withLock { self?.port = port }
                    if once.claim() { cont.resume(returning: port) }
                case .failed(let e):
                    l.cancel()
                    if once.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            lock.withLock { listener = l }
            l.start(queue: queue)
        }
    }

    func stop() {
        lock.withLock { listener?.cancel(); listener = nil }
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
        // hängende Verbindungen nach 30 s schließen
        queue.asyncAfter(deadline: .now() + 30) { c.cancel() }
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            switch HTTPRequest.parse(buf) {
            case .incomplete where !complete && error == nil: self.receive(c, buffer: buf)
            case .done(let req):
                Task { [self] in
                    let resp = await self.respond(req)
                    c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                }
            default:
                c.send(content: HTTPResponse.make(400, PairingPage.page("400", "<p>Bad request</p>")),
                       completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// Antwort auf eine Anfrage (eigene Funktion → ohne Netz testbar).
    func respond(_ req: HTTPRequest) async -> Data {
        let code = currentCode
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/pair"):
            // Code aus dem QR-Link nur übernehmen, wenn er stimmt (sonst muss er eingetippt werden)
            let given = req.query["c"].flatMap { PairingCode.matches($0, code) ? $0 : nil }
            return HTTPResponse.make(200, PairingPage.form(code: given))
        case ("POST", "/pair"):
            let f = req.form
            guard PairingCode.matches(f["code"] ?? "", code) else {
                let blocked = lock.withLock { () -> Bool in
                    failures += 1
                    guard failures >= 5 else { return false }
                    failures = 0; self.code = PairingCode.make()
                    return true
                }
                if blocked { onCodeChange?(currentCode) }
                return HTTPResponse.make(403, PairingPage.form(code: nil, server: f["server"] ?? "",
                                                               message: String(localized: "Der Code stimmt nicht. Schau auf den Fernseher."), error: true))
            }
            let sub = PairingSubmission(server: f["server"] ?? "", email: f["email"] ?? "", password: f["password"] ?? "", key: f["key"] ?? "")
            guard !sub.server.isEmpty, sub.usesKey || (!sub.email.isEmpty && !sub.password.isEmpty) else {
                return HTTPResponse.make(400, PairingPage.form(code: code, server: sub.server,
                                                               message: String(localized: "Bitte Server und E-Mail + Passwort oder einen API-Schlüssel eintragen."), error: true))
            }
            switch await handler(sub) {
            case .success(let name):
                return HTTPResponse.make(200, PairingPage.done(String(localized: "Angemeldet als \(name). Du kannst diese Seite schließen.")))
            case .failure(let e):
                return HTTPResponse.make(200, PairingPage.form(code: code, server: sub.server, message: e.localizedDescription, error: true))
            }
        case ("GET", "/favicon.ico"):
            return HTTPResponse.make(404, "")
        default:
            return HTTPResponse.make(404, PairingPage.page("404", "<p>404</p>"))
        }
    }

    /// Adresse für QR-Code und Anzeige.
    static func link(host: String, port: UInt16, code: String?) -> String {
        "http://\(host):\(port)/" + (code.map { "?c=\($0)" } ?? "")
    }
}

/// Einmal-Schalter für Fortsetzungen (Netzwerk-Rückrufe können mehrfach kommen).
final class OnceFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
