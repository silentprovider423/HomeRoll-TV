import Foundation
@testable import HomeRollTVCore

/// URLProtocol-Attrappe: Antworten je Pfad, Anfragen werden mitgeschrieben.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var body = Data(); var headers: [String: String] = ["Content-Type": "application/json"] }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply?)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        // URLSession gibt den Rumpf als Stream weiter
        if req.httpBody == nil, let s = req.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            s.close(); req.httpBody = d
        }
        Self.lock.withLock { Self.requests.append(req) }
        guard let r = Self.handler?(req) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let resp = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset(_ h: @escaping @Sendable (URLRequest) -> Reply?) {
        lock.withLock { requests = [] }
        handler = h
    }

    static func makeClient(account: Account? = nil) -> ImmichClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return ImmichClient(configuration: cfg, store: MemoryAccountStore(account), environment: [:])
    }
}

func json(_ s: String) -> MockURLProtocol.Reply { .init(body: Data(s.utf8)) }

func asset(_ id: String, _ date: String, image: Bool = true, fav: Bool = false, ratio: Double = 1.5,
           city: String? = nil, country: String? = nil, live: String? = nil, durationMs: Int? = nil) -> Asset {
    Asset(id: id, isImage: image, isFavorite: fav, date: DateParsing.wallClock(date)!, ratio: ratio,
          durationMs: durationMs, livePhotoVideoId: live, city: city, country: country)
}

extension URLRequest {
    var bodyJSON: [String: Any]? { httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
}
