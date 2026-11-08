import XCTest
@testable import HomeRollTVCore

final class TimelineTests: XCTestCase {
    func testGroupsByYearMonthDay() {
        let list = [asset("1", "2024-05-01T10:00:00"), asset("2", "2024-05-01T23:59:00"), asset("3", "2024-06-02T08:00:00"),
                    asset("4", "2025-01-01T00:00:00", fav: true)]
        let years = TimelineGrouping.groups(list, level: .year)
        XCTAssertEqual(years.map(\.id), ["2025", "2024"])
        XCTAssertEqual(years[1].assets.count, 3)
        XCTAssertEqual(TimelineGrouping.groups(list, level: .month).map(\.id), ["2025-01", "2024-06", "2024-05"])
        let days = TimelineGrouping.groups(list, level: .day)
        XCTAssertEqual(days.map(\.id), ["2025-01-01", "2024-06-02", "2024-05-01"])
        XCTAssertEqual(days[2].assets.map(\.id), ["2", "1"])
        XCTAssertEqual(years[0].key?.id, "4")
        XCTAssertEqual(years[0].title, "2025")
    }

    func testKeyPhotoPrefersFavoriteImages() {
        let list = [asset("v", "2024-01-01T10:00:00", image: false, fav: true), asset("a", "2024-01-01T11:00:00"),
                    asset("b", "2024-01-01T12:00:00", fav: true)]
        XCTAssertEqual(TimelineGrouping.keyPhoto(list)?.id, "b")
        XCTAssertEqual(TimelineGrouping.mainPlace([asset("x", "2024-01-01T10:00:00", city: "Rom"), asset("y", "2024-01-01T10:00:00", city: "Rom"),
                                                    asset("z", "2024-01-01T10:00:00", city: "Bern")]), "Rom")
    }

    func testRelativeDay() {
        let now = DateParsing.wallClock("2026-11-08T12:00:00")!.addingTimeInterval(-TimeInterval(TimeZone.current.secondsFromGMT()))
        XCTAssertEqual(Fmt.relativeDay(DateParsing.wallClock("2026-11-08T08:00:00")!, now: now), "Heute")
        XCTAssertEqual(Fmt.relativeDay(DateParsing.wallClock("2026-11-07T08:00:00")!, now: now), "Gestern")
    }

    @MainActor func testTimelineStoreLoadsAllBucketsAndCaches() async throws {
        let server = URL(string: "http://photos.test:2283")!
        MockURLProtocol.reset { req in
            if req.url!.path == "/api/timeline/buckets" { return json(#"[{"timeBucket":"2026-09-01","count":1},{"timeBucket":"2025-01-01","count":1}]"#) }
            let b = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "timeBucket" }!.value!
            let id = b.prefix(4)
            return json(#"{"id":["\#(id)"],"isImage":[true],"isFavorite":[\#(id == "2026")],"fileCreatedAt":["\#(b.prefix(10))T10:00:00"],"ratio":[1.5],"livePhotoVideoId":[null],"thumbhash":["3OcRJYB4d3h/iIeHeEh3eIhw+j2w"]}"#)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID()).json")
        let c = MockURLProtocol.makeClient(account: Account(server: server, credential: .session("T")))
        let store = TimelineStore(client: c, cacheFile: file)
        await store.load()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.assets.map(\.id), ["2026", "2025"])
        XCTAssertEqual(store.favorites.map(\.id), ["2026"])
        XCTAssertEqual(store.generation, 1)
        store.setFavorite("2025", true)
        XCTAssertEqual(store.favorites.count, 2)
        // Cache wird im Hintergrund geschrieben
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { try await Task.sleep(for: .milliseconds(20)) }
        let again = TimelineStore(client: c, cacheFile: file)
        again.restore()
        XCTAssertEqual(again.assets.count, 2)
        try? FileManager.default.removeItem(at: file)
    }
}

final class MemoryTests: XCTestCase {
    /// Fotos alle 2 Minuten ab `start`.
    func series(_ prefix: String, _ start: String, _ n: Int, city: String? = nil, country: String? = nil, ratio: Double = 1.5) -> [Asset] {
        let d = DateParsing.wallClock(start)!
        return (0..<n).map { i in
            Asset(id: "\(prefix)\(i)", isImage: true, isFavorite: false, date: d.addingTimeInterval(Double(i) * 120), ratio: ratio,
                  durationMs: nil, livePhotoVideoId: nil, city: city, country: country)
        }
    }

    func testOnThisDayTripsAndBestOfYear() {
        let now = DateParsing.wallClock("2026-11-08T12:00:00")!
        var all = series("home", "2025-03-01T10:00:00", 30, city: "Stuttgart", country: "Germany")
        all += series("otd", "2024-11-07T10:00:00", 6, city: "Stuttgart", country: "Germany")
        all += series("trip", "2025-07-10T10:00:00", 10, city: "Bodrum", country: "Turkey")
        let ms = MemoryEngine.build(all: all, server: [], prefs: MemoryPrefs(), now: now)
        let ids = ms.map(\.id)
        XCTAssertEqual(ids.first, "today-2024")
        XCTAssertEqual(ms.first?.title, "Heute vor 2 Jahren")
        XCTAssertTrue(ids.contains { $0.hasPrefix("trip-") })
        XCTAssertTrue(ids.contains("best-2025"))
        let trip = ms.first { $0.id.hasPrefix("trip-") }!
        XCTAssertTrue(trip.title.hasSuffix("2025"))
        XCTAssertEqual(trip.place, trip.title.replacingOccurrences(of: " 2025", with: ""))
        // gelöscht und „weniger solche“
        var p = MemoryPrefs(); p.deleted = ["today-2024"]; p.lessPlaces = [trip.place!]
        let ms2 = MemoryEngine.build(all: all, server: [], prefs: p, now: now)
        XCTAssertFalse(ms2.contains { $0.id == "today-2024" || $0.id.hasPrefix("trip-") })
    }

    func testServerMemoriesWin() {
        let now = DateParsing.wallClock("2026-11-08T12:00:00")!
        let srv = series("s", "2023-11-08T09:00:00", 5)
        let ms = MemoryEngine.build(all: srv, server: [(id: "srv1", year: 2023, saved: true, assets: srv)], prefs: MemoryPrefs(), now: now)
        XCTAssertEqual(ms.first?.id, "today-2023")
        XCTAssertEqual(ms.first?.serverID, "srv1")
        XCTAssertEqual(ms.first?.title, "Heute vor 3 Jahren")
    }

    func testCurateThinsBurstsAndLimits() {
        let d = DateParsing.wallClock("2024-01-01T10:00:00")!
        let burst = (0..<10).map { i in Asset(id: "b\(i)", isImage: true, isFavorite: false, date: d.addingTimeInterval(Double(i)), ratio: 1.5,
                                              durationMs: nil, livePhotoVideoId: nil, city: nil, country: nil) }
        XCTAssertEqual(MemoryEngine.curate(burst, max: 50).count, 1)
        let many = series("m", "2024-01-01T10:00:00", 100)
        let c = MemoryEngine.curate(many, max: 20)
        XCTAssertEqual(c.count, 20)
        XCTAssertEqual(c, c.sorted { $0.date < $1.date })
        // Bildschirmfotos raus
        XCTAssertTrue(MemoryEngine.looksLikeScreenshot(asset("s", "2024-01-01T10:00:00", ratio: 1179.0 / 2556.0)))
    }

    func testKeyPhotoPrefersLandscape() {
        let list = series("p", "2024-01-01T10:00:00", 5, ratio: 0.75) + series("l", "2024-01-02T10:00:00", 2, ratio: 1.78)
        XCTAssertTrue(MemoryEngine.keyPhoto(list)!.id.hasPrefix("l"))
    }

    func testAdhocAndRange() {
        let list = series("a", "2024-09-01T10:00:00", 5)
        let m = MemoryEngine.adhoc(id: "x", title: "Album", assets: list.reversed())
        XCTAssertEqual(m?.assets.first?.id, "a0")
        XCTAssertEqual(MemoryEngine.range(list), Fmt.dayMonthYear.string(from: list[0].date).uppercased())
        XCTAssertNil(MemoryEngine.adhoc(id: "y", title: "leer", assets: []))
    }

    func testStoryTimelineUsesBarsAndGroupsPortraits() {
        let p = series("p", "2024-01-01T10:00:00", 3, ratio: 0.75)
        let l = series("l", "2024-01-01T12:00:00", 2, ratio: 1.5)
        let v = [asset("v", "2024-01-01T13:00:00", image: false, durationMs: 20000)]
        let scenes = StoryTimeline.build(p + l + v, mood: .gentle)
        let bar = 60 / MemoryMood.gentle.bpm * 4
        if case .title = scenes[0].kind {} else { XCTFail("Titelkarte fehlt") }
        guard case .three = scenes[1].kind else { return XCTFail("drei Hochformate gehören zusammen") }
        if case .video = scenes.last!.kind {} else { XCTFail("Video am Ende") }
        for s in scenes {
            XCTAssertEqual((s.duration / bar).rounded(), s.duration / bar, accuracy: 1e-9)   // ganze Takte
        }
        for (a, b) in zip(scenes, scenes.dropFirst()) { XCTAssertEqual(a.end, b.start, accuracy: 1e-9) }
        XCTAssertLessThanOrEqual(scenes.last!.duration, 9 + bar)
        XCTAssertEqual(StoryTimeline.index(at: scenes[2].start + 0.1, in: scenes), 2)
    }

    func testClockPausesAndSeeks() {
        let t0 = Date()
        var c = StoryClock()
        c.play(t0)
        XCTAssertEqual(c.time(t0.addingTimeInterval(2)), 2, accuracy: 1e-6)
        c.pause(t0.addingTimeInterval(2))
        XCTAssertEqual(c.time(t0.addingTimeInterval(10)), 2, accuracy: 1e-6)
        c.seek(5, t0.addingTimeInterval(10))
        c.play(t0.addingTimeInterval(10))
        XCTAssertEqual(c.time(t0.addingTimeInterval(11)), 6, accuracy: 1e-6)  // ab der Sprungstelle weiter
    }

    func testKenBurnsStaysInBounds() {
        for seed in 0..<8 {
            let a = KenBurns.at(seed: seed, progress: 0), b = KenBurns.at(seed: seed, progress: 1)
            XCTAssertGreaterThanOrEqual(min(a.scale, b.scale), 1.04 - 1e-9)
            // Schwenk kleiner als der Zoom-Überstand → kein schwarzer Rand
            XCTAssertLessThan(abs(b.dx), (b.scale - 1) / 2 + 0.001)
        }
    }

    @MainActor func testMemoryCenterPrefs() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        let c = MemoryCenter(defaults: d)
        c.update { $0.favorites.insert("x") }
        XCTAssertEqual(MemoryPrefs.load(d).favorites, ["x"])
    }
}

final class SlideshowTests: XCTestCase {
    func testDissolveOnePhotoPerPageWithoutVideos() {
        let list = [asset("a", "2024-01-01T10:00:00"), asset("v", "2024-01-01T10:01:00", image: false), asset("b", "2024-01-01T10:02:00")]
        let pages = SlideshowPlanner.pages(list, theme: .dissolve)
        XCTAssertEqual(pages.map { $0.assets.map(\.id) }, [["a"], ["b"]])
        XCTAssertTrue(pages.allSatisfy { $0.layout == .single })
        XCTAssertEqual(SlideshowTheme.dissolve.transition, 3.0)   // Apple-TV-Vorlage
    }

    func testMagazinePairsPortraits() {
        let p = (0..<4).map { asset("p\($0)", "2024-01-01T10:0\($0):00", ratio: 0.75) }
        let pages = SlideshowPlanner.pages(p + [asset("l", "2024-01-01T11:00:00")], theme: .magazine)
        XCTAssertEqual(pages[0].layout, .pair)
        XCTAssertEqual(pages.flatMap(\.assets).count, 5)          // nichts geht verloren
        XCTAssertEqual(pages.last?.layout, .single)
    }

    func testNextPreviousRepeatAndStart() {
        XCTAssertEqual(SlideshowPlanner.next(0, count: 3, repeats: false), 1)
        XCTAssertNil(SlideshowPlanner.next(2, count: 3, repeats: false))
        XCTAssertEqual(SlideshowPlanner.next(2, count: 3, repeats: true), 0)
        XCTAssertEqual(SlideshowPlanner.previous(0, count: 3), 2)
        let pages = SlideshowPlanner.pages((0..<5).map { asset("x\($0)", "2024-01-01T10:0\($0):00") }, theme: .dissolve)
        XCTAssertEqual(SlideshowPlanner.index(of: "x3", in: pages), 3)
        XCTAssertEqual(SlideshowPlanner.index(of: "nope", in: pages), 0)
    }

    func testShuffleIsReproducible() {
        let list = (0..<20).map { asset("s\($0)", "2024-01-01T10:00:\(String(format: "%02d", $0))") }
        let a = SlideshowPlanner.pages(list, theme: .dissolve, shuffle: true, seed: 42).map(\.assets.first!.id)
        let b = SlideshowPlanner.pages(list, theme: .dissolve, shuffle: true, seed: 42).map(\.assets.first!.id)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, list.map(\.id))
    }

    func testOptionsPersist() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        var o = SlideshowOptions(); o.theme = .magazine; o.mood = .happy; o.repeats = false
        o.save(d)
        XCTAssertEqual(SlideshowOptions.load(d), o)
    }
}

final class SearchPlanTests: XCTestCase {
    func testParsesCityYearPersonAndFreeText() {
        let people = [PersonDTO(id: "p1", name: "Anna", isHidden: false)]
        let p = SearchPlan.make("Strand Anna Bad Boll Juli 2024", cities: ["Boll", "Bad Boll"], people: people)
        XCTAssertEqual(p.filter["city"], ["eq": "Bad Boll"])
        XCTAssertEqual(p.filter["personIds"], ["all": ["p1"]])
        XCTAssertEqual(p.filter["takenAt"], ["gte": "2024-07-01T00:00:00Z", "lt": "2024-08-01T00:00:00Z"])
        XCTAssertEqual(p.freeText, "Strand")
        XCTAssertEqual(p.labels, ["Bad Boll", "Anna", "Juli 2024"])
    }

    func testMediaKeywords() {
        let p = SearchPlan.make("Videos 2023", cities: [], people: [])
        XCTAssertEqual(p.filter["type"], ["eq": "VIDEO"])
        XCTAssertTrue(p.freeText.isEmpty)
        XCTAssertEqual(SearchPlan.make("favoriten", cities: [], people: []).filter["isFavorite"], ["eq": true])
        XCTAssertTrue(SearchPlan.make("", cities: [], people: []).isEmpty)
    }
}

final class ThumbHashTests: XCTestCase {
    func testDecodesUnpaddedHash() {
        // Beispiel aus Evan Wallaces ThumbHash-Demo, ohne „=“ wie bei Immich
        let img = ThumbHash.cgImage(base64: "1QcSHQRnh493V4dIh4eXh1h4kJUI")
        XCTAssertNotNil(img)
        XCTAssertLessThanOrEqual(max(img!.width, img!.height), 32)
        XCTAssertNil(ThumbHash.cgImage(base64: "AA"))
    }
}
