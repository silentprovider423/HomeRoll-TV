import XCTest
@testable import HomeRollTVCore

final class PairingTests: XCTestCase {
    func testParsesRequestInPieces() {
        let body = "code=123456&server=http%3A%2F%2Fphotos.test%3A2283&email=a%40b.c&password=p+w%26"
        let raw = "POST /pair HTTP/1.1\r\nHost: tv\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let data = Data(raw.utf8)
        XCTAssertEqual(HTTPRequest.parse(data.prefix(30)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(data.dropLast(3)), .incomplete)
        guard case .done(let req) = HTTPRequest.parse(data) else { return XCTFail() }
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/pair")
        XCTAssertEqual(req.form["server"], "http://photos.test:2283")
        XCTAssertEqual(req.form["email"], "a@b.c")
        XCTAssertEqual(req.form["password"], "p w&")
        guard case .done(let get) = HTTPRequest.parse(Data("GET /?c=042000 HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(get.query["c"], "042000")
        XCTAssertEqual(HTTPRequest.parse(Data(repeating: 65, count: 40_000)), .invalid)
    }

    func testCodeCompare() {
        XCTAssertTrue(PairingCode.matches("012345", "012345"))
        XCTAssertFalse(PairingCode.matches("012345", "012346"))
        XCTAssertFalse(PairingCode.matches("01234", "012345"))
        XCTAssertEqual(PairingCode.make().count, 6)
    }

    func testEscapesHTML() {
        XCTAssertFalse(PairingPage.form(code: nil, server: "\"><script>").contains("<script>"))
    }

    private func post(_ fields: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/pair", query: [:], headers: [:], body: Data(fields.utf8))
    }

    func testRespondFlow() async {
        let got = Locked<PairingSubmission?>(nil)
        let s = PairingServer { sub in got.set(sub); return sub.password == "ok" ? .success("Test") : .failure(APIError.http(401, "")) }
        let code = s.currentCode
        // QR-Link mit richtigem Code: kein Codefeld nötig
        let page = String(decoding: await s.respond(HTTPRequest(method: "GET", path: "/", query: ["c": code], headers: [:], body: Data())), as: UTF8.self)
        XCTAssertTrue(page.contains("type=\"hidden\" name=\"code\" value=\"\(code)\""))
        // falscher Code
        let bad = String(decoding: await s.respond(post("code=000000x&server=s&email=e&password=ok")), as: UTF8.self)
        XCTAssertTrue(bad.hasPrefix("HTTP/1.1 403"))
        XCTAssertNil(got.get())
        // fehlende Felder
        let missing = String(decoding: await s.respond(post("code=\(code)&server=s")), as: UTF8.self)
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 400"))
        // Erfolg
        let ok = String(decoding: await s.respond(post("code=\(code)&server=http%3A%2F%2Fx&email=e&password=ok")), as: UTF8.self)
        XCTAssertTrue(ok.contains("Test"))
        XCTAssertEqual(got.get()?.server, "http://x")
        // API-Schlüssel genügt
        let key = String(decoding: await s.respond(post("code=\(code)&server=x&key=K")), as: UTF8.self)
        XCTAssertTrue(key.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(got.get()?.usesKey, true)
    }

    func testCodeRotatesAfterFiveFailures() async {
        let s = PairingServer { _ in .success("") }
        let first = s.currentCode
        for _ in 0..<5 { _ = await s.respond(post("code=x&server=s&key=k")) }
        XCTAssertNotEqual(s.currentCode, first)
    }

    /// Echter Server auf localhost: Seite holen, Formular schicken.
    func testLiveServerRoundTrip() async throws {
        let s = PairingServer { sub in .success(sub.email) }
        let port = try await s.start(preferredPort: 0)
        defer { s.stop() }
        XCTAssertGreaterThan(port, 0)
        let base = URL(string: PairingServer.link(host: "127.0.0.1", port: port, code: s.currentCode))!
        let (page, r1) = try await URLSession.shared.data(from: base)
        XCTAssertEqual((r1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("<form"))
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("code=\(s.currentCode)&server=x&email=me%40example.com&password=pw".utf8)
        let (done, r2) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((r2 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: done, as: UTF8.self).contains("me@example.com"))
    }

    func testQRCodeRenders() {
        let img = QRCode.image("http://10.0.0.2:8765/?c=123456", scale: 4)
        XCTAssertNotNil(img)
        XCTAssertGreaterThan(img!.width, 80)
    }

    func testLocalAddressIsIPv4() {
        if let ip = LocalAddress.ipv4() { XCTAssertEqual(ip.split(separator: ".").count, 4) }
    }
}

final class TopShelfTests: XCTestCase {
    func testPickPrefersWideFavoritesWithoutDuplicates() {
        let key = asset("k", "2024-01-01T10:00:00", ratio: 1.5)
        let m = Memory(id: "m1", title: "T", subtitle: "S", assets: [key], key: key, date: key.date)
        let favs = [asset("f1", "2024-01-01T10:00:00", fav: true, ratio: 1.5), asset("f2", "2024-01-01T10:00:00", fav: true, ratio: 0.7), key]
        let random = [asset("r1", "2024-01-01T10:00:00", ratio: 1.6), asset("r2", "2024-01-01T10:00:00", ratio: 0.7),
                      asset("rv", "2024-01-01T10:00:00", image: false, ratio: 1.7)]
        let pick = TopShelfFeeder.pick(memories: [m], favorites: favs, random: random, limit: (6, 3))
        XCTAssertEqual(pick.memories.map(\.id), ["m1"])
        XCTAssertEqual(pick.photos.map(\.id), ["f1", "r1", "r2"])
    }

    func testWriteStoresJPEGsAndSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        // kleines PNG als „Server-Vorschau“
        let png = try XCTUnwrap(QRCode.image("x", scale: 4)).pngData()
        let key = asset("k", "2024-01-01T10:00:00", city: "Rom")
        let m = Memory(id: "m1", title: "Rom 2024", subtitle: "1. JAN. 2024", assets: [key], key: key, date: key.date)
        try "alt".write(to: { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder.appendingPathComponent("old.jpg") }(), atomically: true, encoding: .utf8)
        let snap = try await TopShelfFeeder.write(memories: [m], photos: [key, asset("missing", "2024-01-02T10:00:00")],
                                                  style: .sections, folder: folder) { id in id == "missing" ? nil : png }
        XCTAssertEqual(snap.memories.first?.link, "homeroll-tv://memory/m1")
        XCTAssertEqual(snap.photos.map(\.id), ["k"])                 // Foto ohne Bild fällt weg
        XCTAssertEqual(snap.photos.first?.subtitle, "Rom")
        let loaded = try XCTUnwrap(TopShelfSnapshot.load(from: folder))
        XCTAssertEqual(loaded.style, .sections)
        XCTAssertEqual(loaded.memories.count, 1)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["k.jpg", "snapshot.json"])            // alte Bilder aufgeräumt
        let jpeg = try Data(contentsOf: folder.appendingPathComponent("k.jpg"))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }
}

/// Kleiner Thread-sicherer Behälter für Testwerte.
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { l.withLock { v } }
    func set(_ n: T) { l.withLock { v = n } }
}

import ImageIO
import UniformTypeIdentifiers
extension CGImage {
    func pngData() -> Data {
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, self, nil); CGImageDestinationFinalize(d)
        return out as Data
    }
}
