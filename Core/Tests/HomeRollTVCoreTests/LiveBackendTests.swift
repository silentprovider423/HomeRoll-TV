import XCTest
@testable import HomeRollTVCore

/// Gegen ein echtes Immich-Testkonto (nur lesend). Läuft nur mit
/// FOTOS_SERVER + FOTOS_TOKEN_FILE in der Umgebung (siehe tools/test.sh), sonst übersprungen.
final class LiveBackendTests: XCTestCase {
    private func client() throws -> ImmichClient {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["FOTOS_SERVER"], let f = env["FOTOS_TOKEN_FILE"],
              let t = try? String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8) else {
            throw XCTSkip("kein Testkonto in der Umgebung")
        }
        return ImmichClient(configuration: .ephemeral, store: MemoryAccountStore(),
                            environment: ["FOTOS_SERVER": s, "FOTOS_TOKEN": t.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    func testServerAndTimeline() async throws {
        let c = try client()
        let base = try XCTUnwrap(c.baseURL)
        let found = try await c.findServer(base.absoluteString)
        XCTAssertEqual(found.host(), base.host())
        let me = try await c.me()
        XCTAssertFalse(me.id.isEmpty)
        let buckets = try await c.buckets()
        XCTAssertFalse(buckets.isEmpty)
        let assets = try await c.bucket(buckets[0].timeBucket)
        XCTAssertEqual(assets.count, buckets[0].count)
        let first = try XCTUnwrap(assets.first)
        let dto = try await c.asset(first.id)
        XCTAssertEqual(dto.id, first.id)
        let img = try await c.data(try XCTUnwrap(c.thumbnailURL(first.id, .preview)))
        XCTAssertNotNil(ImageLoader.decode(img, maxPixel: 800))
    }

    func testAlbumsPeopleSearchRandom() async throws {
        let c = try client()
        let albums = try await c.albums()
        if let a = albums.first(where: { $0.assetCount > 0 }) {
            let list = try await c.albumAssets(a.id)
            XCTAssertEqual(list.count, a.assetCount)
        }
        _ = try await c.sharedAlbums()
        _ = try await c.people()
        _ = try await c.memories()
        let random = try await c.random(size: 5)
        XCTAssertLessThanOrEqual(random.count, 5)
        let cities = try await c.suggestions("city")
        if let city = cities.first {
            let hits = try await c.search(filter: ["city": ["eq": .string(city)]], size: 50)
            XCTAssertTrue(hits.allSatisfy { $0.exifInfo?.city == city })
        }
        let smart = try await c.smartSearch("photo", size: 5)
        XCTAssertLessThanOrEqual(smart.count, 5)
    }

    @MainActor func testTimelineAndMemoriesEndToEnd() async throws {
        let c = try client()
        let tl = TimelineStore(client: c, cacheFile: nil)
        await tl.load()
        XCTAssertNil(tl.error)
        XCTAssertEqual(tl.assets.count, tl.buckets.reduce(0) { $0 + $1.count })
        let center = MemoryCenter(defaults: UserDefaults(suiteName: "live-\(UUID())")!)
        await center.rebuild(timeline: tl, client: c)
        XCTAssertFalse(center.items.isEmpty, "Testkonto sollte Rückblicke ergeben")
        // Top-Shelf-Schnappschuss mit echten Vorschauen
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-ts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let pick = TopShelfFeeder.pick(memories: center.items, favorites: tl.favorites, random: try await c.random(size: 10).map(\.asset))
        let snap = try await TopShelfFeeder.write(memories: pick.memories, photos: pick.photos, style: .carousel, folder: folder) { id in
            guard let u = c.thumbnailURL(id, .preview) else { return nil }
            return try? await c.data(u)
        }
        XCTAssertFalse(snap.memories.isEmpty && snap.photos.isEmpty)
    }
}
