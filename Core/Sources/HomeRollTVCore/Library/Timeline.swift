import Foundation
import Observation

/// Eine Gruppe der Mediathek (Jahr, Monat oder Tag) – Apples „Jahre · Monate · Tage“.
struct TimeGroup: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable { case year, month, day }
    let id: String               // "2024", "2024-05", "2024-05-12"
    let level: Level
    let date: Date               // Beginn (Wanduhr)
    let assets: [Asset]          // neueste zuerst
    var key: Asset? { TimelineGrouping.keyPhoto(assets) }
    /// Häufigster Ort der Gruppe (für „Göppingen“ unter dem Tag/Monat)
    var place: String? { TimelineGrouping.mainPlace(assets) }

    var title: String {
        switch level {
        case .year: String(Calendar.wall.component(.year, from: date))
        case .month: Fmt.monthYear.string(from: date)
        case .day: Fmt.relativeDay(date)
        }
    }
}

enum TimelineGrouping {
    static func groups(_ assets: [Asset], level: TimeGroup.Level) -> [TimeGroup] {
        let cal = Calendar.wall
        func id(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: d)
            switch level {
            case .year: return String(format: "%04d", c.year ?? 0)
            case .month: return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            case .day: return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
        }
        var order: [String] = []
        var bucket: [String: [Asset]] = [:]
        for a in assets.sorted(by: { $0.date > $1.date }) {
            let k = id(a.date)
            if bucket[k] == nil { order.append(k) }
            bucket[k, default: []].append(a)
        }
        return order.map { k in
            let list = bucket[k]!
            let comps: Set<Calendar.Component> = level == .year ? [.year] : level == .month ? [.year, .month] : [.year, .month, .day]
            let start = cal.date(from: cal.dateComponents(comps, from: list[0].date)) ?? list[0].date
            return TimeGroup(id: k, level: level, date: start, assets: list)
        }
    }

    /// Titelbild wie bei Apple: ein Favorit, sonst ein Foto aus dem ersten Drittel (keine Videos, wenn es geht).
    static func keyPhoto(_ list: [Asset]) -> Asset? {
        let photos = list.filter(\.isImage)
        let pool = photos.isEmpty ? list : photos
        return pool.first(where: \.isFavorite) ?? (pool.isEmpty ? nil : pool[pool.count / 3])
    }

    static func mainPlace(_ list: [Asset]) -> String? {
        Dictionary(grouping: list.compactMap(\.city), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }
}

/// Zeitleiste vom Server: Monatsliste, dann alle Monate (4 gleichzeitig), neueste zuerst. tvOS hat keinen dauerhaften
/// Speicher – die geladene Liste liegt nur als Cache in „Caches“ und macht den nächsten Start sofort sichtbar.
@MainActor @Observable
final class TimelineStore {
    private(set) var assets: [Asset] = []
    private(set) var buckets: [TimeBucket] = []
    private(set) var loading = false
    private(set) var loadedBuckets = 0
    private(set) var error: String?
    /// Zählt bei jedem fertigen Laden hoch (Rückblicke/Top Shelf hängen sich daran).
    private(set) var generation = 0

    @ObservationIgnored private var byID: [String: Int] = [:]
    @ObservationIgnored let client: ImmichClient
    @ObservationIgnored private let cacheFile: URL?

    init(client: ImmichClient = .shared, cacheFile: URL? = TimelineStore.defaultCacheFile) {
        self.client = client
        self.cacheFile = cacheFile
    }

    nonisolated static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("zeitleiste.json")
    }

    func asset(_ id: String) -> Asset? { byID[id].map { assets[$0] } }
    var favorites: [Asset] { assets.filter(\.isFavorite) }

    private struct Cache: Codable { let server: String; let assets: [Asset]; let hashes: [String: String] }

    /// Cache von der Platte (nur wenn er zum selben Server gehört).
    func restore() {
        guard assets.isEmpty, let f = cacheFile, let d = try? Data(contentsOf: f),
              let c = try? JSONDecoder().decode(Cache.self, from: d), c.server == client.baseURL?.absoluteString else { return }
        for (id, h) in c.hashes { HashStore.shared.set(id, h) }
        set(c.assets)
    }

    func load() async {
        guard !loading else { return }
        loading = true; error = nil; loadedBuckets = 0
        defer { loading = false }
        do {
            let list = try await client.buckets()
            buckets = list
            var collected: [String: [Asset]] = [:]
            let client = self.client
            try await withThrowingTaskGroup(of: (String, [Asset]).self) { group in
                var it = list.makeIterator()
                func next() -> Bool {
                    guard let b = it.next() else { return false }
                    group.addTask { (b.timeBucket, try await client.bucket(b.timeBucket)) }
                    return true
                }
                for _ in 0..<4 { _ = next() }
                while let (k, a) = try await group.next() {
                    collected[k] = a
                    loadedBuckets += 1
                    // Zwischenstand zeigen, solange noch nichts da ist (erster Start)
                    if assets.isEmpty || loadedBuckets % 12 == 0 {
                        set(list.compactMap { collected[$0.timeBucket] }.flatMap { $0 })
                    }
                    _ = next()
                }
            }
            set(list.compactMap { collected[$0.timeBucket] }.flatMap { $0 })
            generation += 1
            save()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func set(_ list: [Asset]) {
        assets = list.sorted { $0.date > $1.date }
        byID = Dictionary(assets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        guard let f = cacheFile, let server = client.baseURL?.absoluteString else { return }
        let hashes = Dictionary(assets.compactMap { a in HashStore.shared.hash(a.id).map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let c = Cache(server: server, assets: assets, hashes: hashes)
        Task.detached(priority: .utility) { try? JSONEncoder().encode(c).write(to: f, options: .atomic) }
    }

    /// Favorit lokal sofort umschalten (Server-Aufruf macht der Aufrufer).
    func setFavorite(_ id: String, _ fav: Bool) {
        guard let i = byID[id] else { return }
        assets[i].isFavorite = fav
    }

    func reset() {
        assets = []; buckets = []; byID = [:]; generation = 0
        if let f = cacheFile { try? FileManager.default.removeItem(at: f) }
    }
}
