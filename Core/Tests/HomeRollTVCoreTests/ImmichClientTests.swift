import XCTest
@testable import HomeRollTVCore

final class ImmichClientTests: XCTestCase {
    let server = URL(string: "http://photos.test:2283")!

    func testCandidatesAddSchemeAndStripAPI() throws {
        XCTAssertEqual(try ImmichClient.candidates("photos.test:2283/api/").map(\.absoluteString),
                       ["https://photos.test:2283", "http://photos.test:2283"])
        XCTAssertEqual(try ImmichClient.candidates(" http://10.0.0.5:2283 ").map(\.absoluteString), ["http://10.0.0.5:2283"])
        XCTAssertThrowsError(try ImmichClient.candidates("me@example.com")) { XCTAssertEqual($0 as? APIError, .emailAsServer) }
        XCTAssertThrowsError(try ImmichClient.candidates("")) { XCTAssertEqual($0 as? APIError, .badURL) }
    }

    func testLoginFallsBackToHTTPAndStoresSession() async throws {
        MockURLProtocol.reset { req in
            let u = req.url!
            if u.scheme == "https" { return nil }                       // https nicht erreichbar → http
            switch u.path {
            case "/api/server/ping": return json(#"{"res":"pong"}"#)
            case "/api/auth/login":
                XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
                return json(#"{"accessToken":"tok123","name":"Test","userId":"u1","userEmail":"t@example.com"}"#)
            default: return .init(status: 404)
            }
        }
        let store = MemoryAccountStore()
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [MockURLProtocol.self]
        let c = ImmichClient(configuration: cfg, store: store, environment: [:])
        let acc = try await c.login(server: "photos.test:2283", email: " t@example.com ", password: "pw")
        XCTAssertEqual(acc.server.absoluteString, "http://photos.test:2283")
        XCTAssertEqual(acc.credential, .session("tok123"))
        XCTAssertEqual(store.load(), acc)
        XCTAssertTrue(c.isLoggedIn)
        let login = MockURLProtocol.requests.first { $0.url?.path == "/api/auth/login" }
        XCTAssertEqual(login?.bodyJSON?["email"] as? String, "t@example.com")
        XCTAssertEqual(c.authHeaders, ["Authorization": "Bearer tok123"])
    }

    func testLoginNotImmich() async {
        MockURLProtocol.reset { _ in .init(status: 200, body: Data("<html>".utf8)) }
        let c = MockURLProtocol.makeClient()
        do { _ = try await c.login(server: "http://photos.test", email: "a@b.c", password: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .notImmich) }
        XCTAssertFalse(c.isLoggedIn)
    }

    func testAPIKeyLoginUsesHeader() async throws {
        MockURLProtocol.reset { req in
            switch req.url!.path {
            case "/api/server/ping": return json(#"{"res":"pong"}"#)
            case "/api/users/me":
                guard req.value(forHTTPHeaderField: "x-api-key") == "KEY" else { return .init(status: 401) }
                return json(#"{"id":"u1","name":"Leser","email":"r@example.com"}"#)
            default: return .init(status: 404)
            }
        }
        let c = MockURLProtocol.makeClient()
        let acc = try await c.login(server: "http://photos.test:2283", key: " KEY ")
        XCTAssertEqual(acc.credential, .apiKey("KEY"))
        XCTAssertEqual(acc.name, "Leser")
        XCTAssertEqual(c.authHeaders, ["x-api-key": "KEY"])
    }

    func testWrongPasswordMessage() async {
        MockURLProtocol.reset { req in
            req.url!.path == "/api/server/ping" ? json(#"{"res":"pong"}"#) : .init(status: 401, body: Data(#"{"message":"Incorrect"}"#.utf8))
        }
        let c = MockURLProtocol.makeClient()
        do { _ = try await c.login(server: "http://photos.test", email: "a@b.c", password: "x"); XCTFail() }
        catch {
            guard case .http(401, _)? = error as? APIError else { return XCTFail("\(error)") }
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testBucketDecodingAppliesLocalOffsetAndHashes() async throws {
        MockURLProtocol.reset { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer T")
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(q.contains(URLQueryItem(name: "timeBucket", value: "2026-09-01")))
            return json("""
            {"id":["a","b"],"isImage":[true,false],"isFavorite":[false,true],"fileCreatedAt":["2026-09-01T22:30:00","2026-09-02T10:00:00"],
             "localOffsetHours":[2,null],"ratio":[1.5,null],"duration":[null,12000],"livePhotoVideoId":[null,null],
             "city":["Bodrum",null],"country":["Turkey",null],"thumbhash":["3OcRJYB4d3h/iIeHeEh3eIhw+j2w",null],"ownerId":["u","u"]}
            """)
        }
        let c = MockURLProtocol.makeClient(account: Account(server: server, credential: .session("T")))
        let list = try await c.bucket("2026-09-01")
        XCTAssertEqual(list.map(\.id), ["b", "a"])                     // neueste zuerst
        let a = list[1]
        XCTAssertEqual(Calendar.wall.component(.day, from: a.date), 2)  // 22:30 UTC + 2 h = nächster Tag
        XCTAssertEqual(a.city, "Bodrum")
        XCTAssertTrue(list[0].isVideo)
        XCTAssertEqual(list[0].durationMs, 12000)
        XCTAssertNotNil(HashStore.shared.hash("a"))
        XCTAssertNotNil(c.thumbnailURL("a", .preview)?.query?.contains("v="))
    }

    func testSearchBodyAddsTimelineVisibility() {
        let body = ImmichClient.searchBody(filter: ["city": ["eq": "Bodrum"]], size: 5000, cursor: "c1", order: "asc")
        let d = try! JSONSerialization.jsonObject(with: body.data) as! [String: Any]
        let f = d["filter"] as! [String: Any]
        XCTAssertEqual((f["visibility"] as? [String: String])?["eq"], "timeline")
        XCTAssertEqual((f["city"] as? [String: String])?["eq"], "Bodrum")
        XCTAssertEqual(d["size"] as? Int, 1000)
        XCTAssertEqual(d["cursor"] as? String, "c1")
        XCTAssertEqual((d["orderBy"] as? [String: String])?["direction"], "asc")
        // eigene Sichtbarkeit bleibt
        let v = ImmichClient.visible(["visibility": ["eq": "archive"]])
        XCTAssertEqual(v["visibility"], ["eq": "archive"])
    }

    func testSearchPagesWithCursor() async throws {
        MockURLProtocol.reset { req in
            let cursor = req.bodyJSON?["cursor"] as? String
            func item(_ id: String) -> String {
                #"{"id":"\#(id)","type":"IMAGE","isFavorite":false,"fileCreatedAt":"2026-01-01T10:00:00.000Z","localDateTime":"2026-01-01T11:00:00.000Z"}"#
            }
            return cursor == nil
                ? json(#"{"assets":{"items":[\#(item("1")),\#(item("2"))],"nextCursor":"p2"}}"#)
                : json(#"{"assets":{"items":[\#(item("3"))],"nextCursor":null}}"#)
        }
        let c = MockURLProtocol.makeClient(account: Account(server: server, credential: .apiKey("K")))
        let r = try await c.search(filter: [:], size: 10)
        XCTAssertEqual(r.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
        XCTAssertEqual(MockURLProtocol.requests[0].value(forHTTPHeaderField: "x-api-key"), "K")
        XCTAssertEqual(Calendar.wall.component(.hour, from: r[0].asset.date), 11)   // Ortszeit
    }

    func test401PostsSessionExpired() async {
        MockURLProtocol.reset { _ in .init(status: 401) }
        let c = MockURLProtocol.makeClient(account: Account(server: server, credential: .session("old")))
        let exp = expectation(forNotification: .sessionExpired, object: nil)
        _ = try? await c.me()
        await fulfillment(of: [exp], timeout: 2)
    }

    func testNotLoggedIn() async {
        let c = MockURLProtocol.makeClient()
        do { _ = try await c.albums(); XCTFail() } catch { XCTAssertEqual(error as? APIError, .notLoggedIn) }
    }

    func testLogoutClearsStore() {
        let store = MemoryAccountStore(Account(server: server, credential: .session("x")))
        let c = ImmichClient(configuration: .ephemeral, store: store, environment: [:])
        XCTAssertTrue(c.isLoggedIn)
        c.logout()
        XCTAssertFalse(c.isLoggedIn)
        XCTAssertNil(store.load())
    }

    func testDebugEnvironmentLogin() {
        let c = ImmichClient(configuration: .ephemeral, store: MemoryAccountStore(),
                             environment: ["FOTOS_SERVER": "http://photos.test:2283", "FOTOS_TOKEN": "abc"])
        XCTAssertEqual(c.account?.credential, .session("abc"))
    }

    func testDeepLinks() {
        XCTAssertEqual(DeepLink(URL(string: "homeroll-tv://memory/today-2024")!), .memory("today-2024"))
        XCTAssertEqual(DeepLink(URL(string: "homeroll-tv://asset/abc-1")!), .asset("abc-1"))
        XCTAssertEqual(DeepLink(URL(string: "homeroll-tv://slideshow")!), .slideshow)
        XCTAssertNil(DeepLink(URL(string: "https://memory/x")!))
        XCTAssertNil(DeepLink(URL(string: "homeroll-tv://memory")!))
        for l in [DeepLink.memory("city-Bad Boll"), .asset("x"), .album("y"), .library, .search, .slideshow] {
            XCTAssertEqual(DeepLink(l.url), l)
        }
    }
}
