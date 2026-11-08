import AVFoundation
import Foundation

enum APIError: LocalizedError, Equatable {
    case notLoggedIn, http(Int, String), badURL, emailAsServer, notImmich
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: String(localized: "Nicht angemeldet")
        case .http(401, _): String(localized: "E-Mail, Passwort oder Schlüssel stimmen nicht.")
        case .http(let c, let m): String(localized: "Server-Fehler \(c): \(m)")
        case .badURL: String(localized: "Ungültige Server-Adresse")
        case .emailAsServer: String(localized: "Das ist eine E-Mail-Adresse. Ins erste Feld gehört die Adresse deines Immich-Servers, z. B. http://192.168.1.20:2283")
        case .notImmich: String(localized: "Unter dieser Adresse antwortet kein Immich-Server. Stimmen Adresse und Port (meist 2283)?")
        }
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}

/// Spricht mit dem eigenen Immich-Server (getestet mit v3.3.x). Kopie aus HomeRoll (App/API/ImmichClient.swift),
/// für tvOS gekürzt: nur Ansehen (keine Uploads, kein Bearbeiten, kein Löschen von Fotos), Zugang als Sitzung
/// oder API-Schlüssel, Speicher austauschbar (Tests). Wer eine eigene Heimnetz-CA nutzt, legt deren Zertifikat als
/// `Resources/HeimnetzCA.der` ins Projekt – dann vertraut die App ihr zusätzlich.
final class ImmichClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = ImmichClient()

    private let lock = NSLock()
    private var _account: Account?
    private let store: AccountStore
    private var session: URLSession!
    private let anchor: SecCertificate? = {
        guard let url = Bundle.main.url(forResource: "HeimnetzCA", withExtension: "der"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }()
    let decoder = JSONDecoder()

    /// `configuration` austauschbar für Tests (URLProtocol-Attrappe), `store` für den Zugang.
    init(configuration: URLSessionConfiguration? = nil, store: AccountStore = KeychainAccountStore(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.store = store
        super.init()
        let cfg = configuration ?? {
            let c = URLSessionConfiguration.default
            // tvOS darf Caches jederzeit leeren – für Vorschaubilder genau richtig
            c.urlCache = URLCache(memoryCapacity: 96 << 20, diskCapacity: 512 << 20)
            c.requestCachePolicy = .useProtocolCachePolicy
            return c
        }()
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        _account = store.load()
        #if DEBUG
        // Simulator-Tests: Server + Token per Startumgebung (SIMCTL_CHILD_FOTOS_*), kein Passwort-Tippen.
        if let s = environment["FOTOS_SERVER"], let u = Self.validBase(s), let t = environment["FOTOS_TOKEN"], !t.isEmpty {
            _account = Account(server: u, credential: environment["FOTOS_TOKEN_KIND"] == "apikey" ? .apiKey(t) : .session(t))
        }
        // Anmeldebildschirm testen, ohne den gespeicherten Zugang anzufassen
        if environment["FOTOS_LOGIN_SCREEN"] == "1" { _account = nil }
        #endif
    }

    var account: Account? { lock.withLock { _account } }
    var baseURL: URL? { account?.server }
    var isLoggedIn: Bool { account != nil }
    var authHeaders: [String: String] { account?.credential.headers ?? [:] }

    // MARK: Anmeldung

    /// E-Mail + Passwort → Sitzungs-Token. Gespeichert wird erst nach Erfolg.
    @discardableResult
    func login(server: String, email: String, password: String) async throws -> Account {
        let url = try await findServer(server)
        let body = JSON.object(["email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), "password": .string(password)])
        let data = try await raw("auth/login", method: "POST", body: body.data, base: url, auth: .anonymous)
        let r = try decoder.decode(LoginResponse.self, from: data)
        let acc = Account(server: url, credential: .session(r.accessToken), name: r.name, email: r.userEmail)
        activate(acc)
        return acc
    }

    /// API-Schlüssel (oder Sitzungs-Token) prüfen und übernehmen.
    @discardableResult
    func login(server: String, key: String) async throws -> Account {
        let url = try await findServer(server)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Immich-API-Schlüssel sind lang und ohne Punkte; Sitzungs-Token ebenso – also beide Wege versuchen.
        var lastError: Error = APIError.http(401, "")
        for cred in [Credential.apiKey(k), .session(k)] {
            do {
                let data = try await raw("users/me", base: url, auth: .with(cred))
                let me = try decoder.decode(UserDTO.self, from: data)
                let acc = Account(server: url, credential: cred, name: me.name, email: me.email)
                activate(acc)
                return acc
            } catch { lastError = error }
        }
        throw lastError
    }

    func activate(_ acc: Account) {
        lock.withLock { _account = acc; videoFallback = [:]; realtimeHLS = nil }
        store.save(acc)
    }

    func logout() {
        lock.withLock { _account = nil; videoFallback = [:]; realtimeHLS = nil }
        store.save(nil)
        HashStore.shared.reset()
    }

    /// http(s)-Adresse mit Rechnername und ohne Benutzerteil („test@email.com“ wäre sonst Benutzer test auf email.com).
    static func validBase(_ s: String) -> URL? {
        guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              let h = u.host(), !h.isEmpty, u.user == nil else { return nil }
        return u
    }

    /// Eingabe → Kandidaten-Adressen. Ohne http(s):// erst https, dann http (Heimnetz).
    static func candidates(_ input: String) throws -> [URL] {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/api") { s.removeLast(4) }
        let hasScheme = s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")
        let tries = (hasScheme ? [s] : ["https://" + s, "http://" + s]).compactMap(validBase)
        guard !tries.isEmpty else { throw s.contains("@") && !s.contains("/") ? APIError.emailAsServer : APIError.badURL }
        return tries
    }

    /// Adresse, unter der wirklich Immich antwortet.
    func findServer(_ input: String) async throws -> URL {
        var reached = false, lastError: Error?
        for u in try Self.candidates(input) {
            var req = URLRequest(url: u.appendingPathComponent("api/server/ping"))
            req.timeoutInterval = 10
            do {
                let (data, resp) = try await session.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200,
                   (try? JSONDecoder().decode([String: String].self, from: data))?["res"] == "pong" { return u }
                reached = true
            } catch { lastError = error }
        }
        throw reached ? APIError.notImmich : (lastError ?? APIError.notImmich)
    }

    // MARK: Basis

    func url(_ path: String, query: [String: String] = [:], base: URL? = nil) throws -> URL {
        guard let b = base ?? baseURL else { throw APIError.notLoggedIn }
        var c = URLComponents(url: b.appendingPathComponent("api/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    func authorized(_ url: URL) throws -> URLRequest {
        guard let cred = account?.credential else { throw APIError.notLoggedIn }
        var r = URLRequest(url: url)
        for (k, v) in cred.headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// Video vom Server für AVFoundation: Kopfzeilen + (bei Sitzungen) Immichs Sitzungs-Cookie (siehe HomeRoll Issue #1).
    func avAsset(_ url: URL) -> AVURLAsset {
        var opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": authHeaders]
        if case .session(let token)? = account?.credential, let host = url.host(), let c = HTTPCookie(properties: [
            .domain: host, .path: "/", .name: "immich_access_token", .value: token]) {
            opts[AVURLAssetHTTPCookiesKey] = [c]
        }
        return AVURLAsset(url: url, options: opts)
    }

    func request<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET",
                               body: Data? = nil) async throws -> T {
        try decoder.decode(T.self, from: try await raw(path, query: query, method: method, body: body))
    }

    /// Womit eine Anfrage sich ausweist.
    enum Auth: Sendable { case account, anonymous, with(Credential) }

    /// `.anonymous` mit eigener `base` = ohne Anmeldung (Login); `.with` = Zugang prüfen, bevor er gespeichert wird.
    @discardableResult
    func raw(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil,
             base: URL? = nil, auth: Auth = .account) async throws -> Data {
        var req = URLRequest(url: try url(path, query: query, base: base))
        let cred: Credential?
        switch auth {
        case .account:
            guard let c = account?.credential else { throw APIError.notLoggedIn }
            cred = c
        case .anonymous: cred = nil
        case .with(let c): cred = c
        }
        for (k, v) in cred?.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401, case .account = auth {
                await MainActor.run { NotificationCenter.default.post(name: .sessionExpired, object: nil) }
            }
            throw APIError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return data
    }

    // MARK: Zeitleiste

    func buckets() async throws -> [TimeBucket] {
        try await request("timeline/buckets", query: ["visibility": "timeline", "withStacked": "true", "withPartners": "true"])
    }
    func bucket(_ b: String) async throws -> [Asset] {
        let d = try await raw("timeline/bucket", query: ["timeBucket": b, "visibility": "timeline", "withStacked": "true", "withPartners": "true"])
        return try decoder.decode(BucketColumns.self, from: d).assets().sorted { $0.date > $1.date }
    }

    func asset(_ id: String) async throws -> AssetDTO { try await request("assets/\(id)") }
    func me() async throws -> UserDTO { try await request("users/me") }

    // MARK: Rückblicke

    func memories(for day: Date = Date()) async throws -> [MemoryDTO] {
        try await request("memories", query: ["for": DateParsing.dayString(day)])
    }
    /// Rückblick als Favorit merken (Immich: isSaved).
    func setMemorySaved(_ id: String, _ saved: Bool) async throws {
        try await raw("memories/\(id)", method: "PUT", body: JSON.object(["isSaved": .bool(saved)]).data)
    }

    // MARK: Alben, Personen, Orte

    func albums() async throws -> [AlbumDTO] { try await request("albums") }
    func sharedAlbums() async throws -> [AlbumDTO] { try await request("albums", query: ["shared": "true"]) }
    func albums(containing id: String) async throws -> [AlbumDTO] { try await request("albums", query: ["assetId": id]) }
    func albumAssets(_ id: String) async throws -> [Asset] {
        try await search(filter: ["albumIds": ["any": [.string(id)]]], size: 20000, order: "asc").map(\.asset)
    }
    func people() async throws -> [PersonDTO] {
        let p: PeopleDTO = try await request("people", query: ["withHidden": "false", "size": "500"])
        return p.people.filter { !($0.isHidden ?? false) }
    }
    func personAssets(_ id: String) async throws -> [Asset] {
        try await search(filter: ["personIds": ["all": [.string(id)]]], size: 5000).map(\.asset)
    }
    /// Werte für Suchvorschläge (type: country | state | city | camera-make | camera-model)
    func suggestions(_ type: String) async throws -> [String] { try await request("search/suggestions", query: ["type": type]) }
    func activities(album: String, asset: String? = nil) async throws -> [ActivityDTO] {
        var q = ["albumId": album]; if let asset { q["assetId"] = asset }
        return try await request("activities", query: q)
    }

    // MARK: Suche

    /// Anfrage-Rumpf der Metadaten-Suche (v3.2+ mit Filter-Objekt) – eigene Funktion, damit Tests ihn prüfen können.
    static func searchBody(filter: JSON, size: Int, cursor: String?, order: String) -> JSON {
        var body: JSON = ["filter": visible(filter), "size": .int(min(1000, size)), "withExif": true,
                          "orderBy": ["field": "fileCreatedAt", "direction": .string(order)]]
        if let cursor { body["cursor"] = .string(cursor) }
        return body
    }

    /// Metadaten-Suche, blättert über `nextCursor` bis `size`.
    func search(filter: JSON, size: Int = 250, order: String = "desc") async throws -> [AssetDTO] {
        var out: [AssetDTO] = []
        var cursor: String?
        repeat {
            let body = Self.searchBody(filter: filter, size: size - out.count, cursor: cursor, order: order)
            let r: SearchResponseDTO = try await request("search/metadata", method: "POST", body: body.data)
            out += r.assets.items
            cursor = r.assets.nextCursor
        } while cursor != nil && out.count < size
        return out
    }

    /// Ohne eigene Sichtbarkeit nur die Mediathek (sonst kommen die Videoteile der Live Photos mit).
    static func visible(_ f: JSON) -> JSON {
        guard case .object(var o) = f else { return ["visibility": ["eq": "timeline"]] }
        if o["visibility"] == nil { o["visibility"] = ["eq": "timeline"] }
        return .object(o)
    }

    /// KI-Suche (Bild-Text-Modell auf dem Server); optional mit zusätzlichem Filter.
    func smartSearch(_ query: String, filter: JSON = [:], size: Int = 120) async throws -> [AssetDTO] {
        let body: JSON = ["query": .string(query), "size": .int(size), "withExif": true, "filter": Self.visible(filter)]
        let r: SearchResponseDTO = try await request("search/smart", method: "POST", body: body.data)
        return r.assets.items
    }

    func random(size: Int = 12) async throws -> [AssetDTO] {
        try await request("search/random", method: "POST", body: JSON.object(["size": .int(size), "withExif": true]).data)
    }

    func setFavorite(_ id: String, _ fav: Bool) async throws {
        try await raw("assets/\(id)", method: "PUT", body: JSON.object(["isFavorite": .bool(fav)]).data)
    }

    // MARK: Medien-URLs

    enum Size: String, Sendable { case thumbnail, preview, fullsize }

    /// Immer die bearbeitete Fassung; `v` (aus dem ThumbHash) umgeht den Cache, wenn der Server neu gerechnet hat.
    func thumbnailURL(_ id: String, _ size: Size = .thumbnail) -> URL? {
        var q = ["size": size.rawValue, "edited": "true"]
        if let v = HashStore.shared.version(id) { q["v"] = v }
        return try? url("assets/\(id)/thumbnail", query: q)
    }
    func videoURL(_ id: String) -> URL? {
        lock.withLock { videoFallback[id] } ?? (try? url("assets/\(id)/video/playback"))
    }
    func originalURL(_ id: String) -> URL? { try? url("assets/\(id)/original", query: ["edited": "true"]) }
    func personThumbURL(_ id: String) -> URL? { try? url("people/\(id)/thumbnail") }

    private var videoFallback: [String: URL] = [:]
    private var realtimeHLS: Bool?

    /// Ausweg, wenn die Wiedergabedatei nicht abspielbar ist (hev1, VP9, AV1, MKV): erst das Original, dann Immichs
    /// Echtzeit-Umwandlung (HLS, wenn auf dem Server eingeschaltet). nil = beides nicht.
    func playableFallback(for id: String) async -> AVURLAsset? {
        var tries = [originalURL(id)].compactMap { $0 }
        if await realtimeTranscoding(), let u = try? url("assets/\(id)/video/stream/main.m3u8") { tries.append(u) }
        for u in tries {
            let a = avAsset(u)
            if (try? await a.load(.isPlayable)) == true {
                lock.withLock { videoFallback[id] = u }
                return a
            }
        }
        return nil
    }

    private func realtimeTranscoding() async -> Bool {
        if let v = lock.withLock({ realtimeHLS }) { return v }
        struct Features: Decodable { let realtimeTranscoding: Bool? }
        let v = ((try? await request("server/features")) as Features?)?.realtimeTranscoding ?? false
        lock.withLock { realtimeHLS = v }
        return v
    }

    /// Bild/Datei mit Zugang laden.
    func data(_ url: URL) async throws -> Data {
        let (d, resp) = try await session.data(for: try authorized(url))
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "Medien")
        }
        return d
    }

    // MARK: TLS – Heimnetz-CA als zusätzlicher Anker

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.useCredential, URLCredential(trust: trust)) }
        if let anchor {
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            if SecTrustEvaluateWithError(trust, nil) { return (.useCredential, URLCredential(trust: trust)) }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
