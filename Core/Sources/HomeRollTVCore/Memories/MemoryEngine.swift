import Foundation
import Observation

/// Ein Rückblick wie in Fotos: Titel, Untertitel, ausgewählte Fotos, Schlüsselfoto.
struct Memory: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    let subtitle: String
    let assets: [Asset]          // kuratiert, chronologisch
    let key: Asset
    let date: Date
    var place: String? = nil
    /// ID des Server-Rückblicks (Immich /memories) – nur dann lässt sich „Favorit“ am Server speichern
    var serverID: String? = nil
}

/// Was der Nutzer an Rückblicken geändert hat (UserDefaults; tvOS behält kleine Einstellungen).
struct MemoryPrefs: Codable, Equatable, Sendable {
    var favorites: Set<String> = []
    var deleted: Set<String> = []
    var lessPlaces: Set<String> = []
    var mix: [String: Int] = [:]

    private static let key = "memoryPrefs"
    static func load(_ d: UserDefaults = .standard) -> MemoryPrefs {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(MemoryPrefs.self, from: $0) } ?? MemoryPrefs()
    }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Reise = zusammenhängende Tage außerhalb des Heimatlandes (häufigstes Land der Mediathek). Wie HomeRoll.
struct Trip: Hashable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let assets: [Asset]
}

/// Baut Rückblicke aus der Zeitleiste (Vorlage: HomeRoll MemoryEngine, ohne Vision/Sensibel-Filter).
enum MemoryEngine {
    static func build(all: [Asset], server: [(id: String, year: Int?, saved: Bool, assets: [Asset])], prefs: MemoryPrefs,
                      now: Date = Date()) -> [Memory] {
        let photos = all.filter { $0.isImage || ($0.durationMs ?? 0) >= 2000 }.sorted { $0.date < $1.date }
        let cal = Calendar.wall
        let wallNow = DateParsing.wallNow(now)
        let thisYear = cal.component(.year, from: wallNow)
        var out: [Memory] = []
        func add(_ id: String, _ title: String, _ list: [Asset], min: Int, max: Int = 50, date: Date? = nil,
                 place: String? = nil, serverID: String? = nil) {
            guard list.count >= min, !prefs.deleted.contains(id) else { return }
            if let place, prefs.lessPlaces.contains(place) { return }
            let picked = curate(list, max: max)
            guard picked.count >= Swift.max(3, min / 2), let key = keyPhoto(picked) else { return }
            out.append(Memory(id: id, title: title, subtitle: range(picked), assets: picked, key: key,
                              date: date ?? picked.last!.date, place: place, serverID: serverID))
        }
        func yearsAgo(_ n: Int) -> String {
            n == 1 ? String(localized: "Heute vor 1 Jahr") : String(localized: "Heute vor \(n) Jahren")
        }

        // 1. Heute vor X Jahren (Server-Vorschlag, sonst selbst: ±3 Tage um heute in früheren Jahren)
        if !server.isEmpty {
            for m in server {
                let n = m.year.map { thisYear - $0 } ?? 0
                add("today-\(m.year ?? 0)", n > 0 ? yearsAgo(n) : String(localized: "Erinnerungen"),
                    m.assets.sorted { $0.date < $1.date }, min: 3, date: wallNow, serverID: m.id)
            }
        } else {
            let doy = cal.ordinality(of: .day, in: .year, for: wallNow) ?? 0
            let byYear = Dictionary(grouping: photos.filter { a in
                let y = cal.component(.year, from: a.date), d = cal.ordinality(of: .day, in: .year, for: a.date) ?? 0
                return y < thisYear && abs(d - doy) <= 3
            }) { cal.component(.year, from: $0.date) }
            for (y, list) in byYear.sorted(by: { $0.key > $1.key }) {
                add("today-\(y)", yearsAgo(thisYear - y), list, min: 4, date: wallNow)
            }
        }

        // 2. Reisen, größte zuerst
        for t in trips(from: all).sorted(by: { $0.assets.count > $1.assets.count }).prefix(8) {
            let y = cal.component(.year, from: t.start)
            add("trip-\(Int(t.start.timeIntervalSince1970))", "\(t.title) \(y)", t.assets, min: 6, date: t.start, place: t.title)
        }

        // 3. Das Beste aus <Jahr>
        let byYear = Dictionary(grouping: photos) { cal.component(.year, from: $0.date) }
        for (y, list) in byYear.sorted(by: { $0.key > $1.key }).prefix(4) where y < thisYear || cal.component(.month, from: wallNow) >= 11 {
            add("best-\(y)", String(localized: "Das Beste aus \(String(y))"), list, min: 20, max: 45)
        }

        // 4. Monate mit vielen Fotos („September 2026“)
        let byMonth = Dictionary(grouping: photos) { cal.dateComponents([.year, .month], from: $0.date) }
        for (c, list) in byMonth.sorted(by: { $0.value.count > $1.value.count }).prefix(4) where list.count >= 25 {
            let d = cal.date(from: c) ?? list[0].date
            add("month-\(c.year ?? 0)-\(c.month ?? 0)", Fmt.monthYear.string(from: d), list, min: 25, max: 40, date: d)
        }

        // 5. Orte im Laufe der Jahre (mindestens 3 verschiedene Jahre)
        let byCity = Dictionary(grouping: photos.filter { $0.city != nil }) { $0.city! }
        for (city, list) in byCity.sorted(by: { $0.value.count > $1.value.count }).prefix(6) {
            let years = Set(list.map { cal.component(.year, from: $0.date) })
            if years.count >= 3 { add("city-\(city)", String(localized: "\(city) im Laufe der Jahre"), list, min: 15, max: 45, place: city) }
        }

        // „Heute“ zuerst, dann nach Datum
        let today = out.filter { $0.id.hasPrefix("today-") }
        let rest = out.filter { !$0.id.hasPrefix("today-") }.sorted { $0.date > $1.date }
        var seen = Set<String>()
        return (today + rest).filter { seen.insert($0.id).inserted }
    }

    /// Rückblick aus einem beliebigen Fotosatz (Album, Person) – „Rückblick-Video wiedergeben“.
    static func adhoc(id: String, title: String, assets: [Asset]) -> Memory? {
        let picked = curate(assets.sorted { $0.date < $1.date }, max: 60)
        guard let key = keyPhoto(picked) else { return nil }
        return Memory(id: id, title: title, subtitle: range(picked), assets: picked, key: key, date: picked.last?.date ?? Date())
    }

    /// Auswahl wie bei Apple: Serienbilder ausdünnen, Favoriten bevorzugen, gleichmäßig über die Zeit verteilen.
    static func curate(_ list: [Asset], max: Int) -> [Asset] {
        var kept: [Asset] = []
        let usable = list.filter { !looksLikeScreenshot($0) && ($0.isImage || ($0.durationMs ?? 0) >= 2000) }
        var videos = 0
        for a in usable.sorted(by: { $0.date < $1.date }) {
            if a.isVideo { if videos >= Swift.max(1, max / 5) { continue }; videos += 1 }
            if let last = kept.last, a.date.timeIntervalSince(last.date) < 45, !a.isFavorite { continue }
            kept.append(a)
        }
        guard kept.count > max else { return kept }
        let favs = kept.filter(\.isFavorite).prefix(max / 2)
        let others = kept.filter { !$0.isFavorite }
        guard !others.isEmpty else { return Array(kept.prefix(max)) }
        let need = max - favs.count
        let step = Double(others.count) / Double(Swift.max(1, need))
        let sampled = (0..<need).map { others[Swift.min(others.count - 1, Int(Double($0) * step))] }
        return (Array(favs) + sampled).sorted { $0.date < $1.date }
    }

    /// Titelbild: Favorit im Querformat (Fernseher!), sonst Querformat, sonst irgendein Foto.
    static func keyPhoto(_ list: [Asset]) -> Asset? {
        let photos = list.filter(\.isImage).isEmpty ? list : list.filter(\.isImage)
        let wide = photos.filter { $0.ratio >= 1.2 }
        let pool = wide.isEmpty ? photos : wide
        return pool.first(where: \.isFavorite) ?? (pool.isEmpty ? nil : pool[pool.count / 3])
    }

    /// iPhone-Bildschirmfotos haben das Seitenverhältnis des Bildschirms (~0,46).
    static func looksLikeScreenshot(_ a: Asset) -> Bool {
        let r = a.ratio < 1 ? a.ratio : 1 / a.ratio
        return a.livePhotoVideoId == nil && (0.455...0.470).contains(r)
    }

    static func range(_ list: [Asset]) -> String {
        guard let f = list.first?.date, let l = list.last?.date else { return "" }
        let cal = Calendar.wall
        if cal.isDate(f, inSameDayAs: l) { return Fmt.dayMonthYear.string(from: f).uppercased() }
        let fy = cal.component(.year, from: f), ly = cal.component(.year, from: l)
        if fy != ly { return "\(fy) – \(ly)" }
        return (Fmt.dayMonth.string(from: f) + " – " + Fmt.dayMonth.string(from: l) + " \(ly)").uppercased()
    }

    static func trips(from input: [Asset]) -> [Trip] {
        let all = input.filter { $0.country != nil }
        guard !all.isEmpty else { return [] }
        let home = Dictionary(grouping: all, by: { $0.country! }).max { $0.value.count < $1.value.count }?.key
        var out: [Trip] = []
        var cur: [Asset] = []
        func flush() {
            guard cur.count >= 3, let f = cur.first, let l = cur.last else { cur = []; return }
            let place = Dictionary(grouping: cur.compactMap(\.city), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            let country = Dictionary(grouping: cur.compactMap(\.country), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            out.append(Trip(title: country.map(CountryName.localized) ?? place ?? String(localized: "Reise"), start: f.date, end: l.date, assets: cur))
            cur = []
        }
        for a in all.sorted(by: { $0.date < $1.date }) {
            if a.country == home { flush(); continue }
            if let last = cur.last, a.date.timeIntervalSince(last.date) > 4 * 86400 || a.country != last.country { flush() }
            cur.append(a)
        }
        flush()
        return out.reversed()
    }
}

/// Ländernamen vom Server (englisch) in der Sprache des Geräts.
enum CountryName {
    static func localized(_ c: String) -> String {
        let english = Locale(identifier: "en_US")
        for code in Locale.Region.isoRegions.map(\.identifier) where english.localizedString(forRegionCode: code) == c {
            return Locale.autoupdatingCurrent.localizedString(forRegionCode: code) ?? c
        }
        return c
    }
}

/// Alle Rückblicke der App: Server-Rückblicke + selbst gebaute, mit den Vorlieben des Nutzers.
@MainActor @Observable
final class MemoryCenter {
    private(set) var items: [Memory] = []
    private(set) var prefs: MemoryPrefs
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var builtGeneration = -1

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefs = MemoryPrefs.load(defaults)
    }

    func memory(_ id: String) -> Memory? { items.first { $0.id == id } }
    func isFavorite(_ m: Memory) -> Bool { prefs.favorites.contains(m.id) }
    var favorites: [Memory] { items.filter(isFavorite) }

    func rebuild(timeline: TimelineStore, client: ImmichClient, force: Bool = false) async {
        guard force || timeline.generation != builtGeneration, !timeline.assets.isEmpty else { return }
        builtGeneration = timeline.generation
        let server = ((try? await client.memories()) ?? []).map { m in
            (id: m.id, year: m.data.year, saved: m.isSaved ?? false, assets: m.assets.map(\.asset))
        }
        // Server-Favoriten übernehmen
        for m in server where m.saved { prefs.favorites.insert("today-\(m.year ?? 0)") }
        let all = timeline.assets, p = prefs
        items = await Task.detached(priority: .userInitiated) { MemoryEngine.build(all: all, server: server, prefs: p) }.value
    }

    func update(_ change: (inout MemoryPrefs) -> Void) {
        change(&prefs)
        prefs.save(defaults)
        items.removeAll { prefs.deleted.contains($0.id) || ($0.place.map { prefs.lessPlaces.contains($0) } ?? false) }
    }

    func toggleFavorite(_ m: Memory, client: ImmichClient) {
        let fav = !isFavorite(m)
        update { if fav { $0.favorites.insert(m.id) } else { $0.favorites.remove(m.id) } }
        if let sid = m.serverID { Task { try? await client.setMemorySaved(sid, fav) } }
    }

    /// Nächster Rückblick für „Als Nächstes ansehen“.
    func next(after m: Memory) -> Memory? {
        guard let i = items.firstIndex(where: { $0.id == m.id }) else { return items.first { $0.id != m.id } }
        return items.count > 1 ? items[(i + 1) % items.count] : nil
    }

    func reset() { items = []; builtGeneration = -1 }
}
