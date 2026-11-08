import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sprungziele aus dem Top Shelf (und für Tests/Kurzbefehle): homeroll-tv://memory/<id>, …/asset/<id>, …/slideshow
enum DeepLink: Equatable, Sendable {
    case memory(String), asset(String), album(String), slideshow, library, search

    static let scheme = "homeroll-tv"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let id = url.pathComponents.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        switch (host, id) {
        case ("memory", let id?): self = .memory(id)
        case ("asset", let id?): self = .asset(id)
        case ("album", let id?): self = .album(id)
        case ("slideshow", _): self = .slideshow
        case ("library", _): self = .library
        case ("search", _): self = .search
        default: return nil
        }
    }

    var url: URL {
        let s: String = switch self {
        case .memory(let id): "memory/\(Self.encode(id))"
        case .asset(let id): "asset/\(Self.encode(id))"
        case .album(let id): "album/\(Self.encode(id))"
        case .slideshow: "slideshow"
        case .library: "library"
        case .search: "search"
        }
        return URL(string: "\(Self.scheme)://\(s)")!
    }

    private static func encode(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id }
}

/// Was der Top Shelf zeigt. Die App schreibt es samt Bildern in den Gruppen-Ordner, die Erweiterung liest es –
/// das System lädt Top-Shelf-Bilder selbst und kennt unseren Zugang nicht, darum `file://`-Bilder statt Server-Adressen.
struct TopShelfSnapshot: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable { case carousel, sections }
    struct Item: Codable, Hashable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let file: String          // Dateiname im Top-Shelf-Ordner
        let link: String          // DeepLink-Adresse
        var date: Date? = nil
        var isMemory = false
    }
    var style: Style = .carousel
    /// Server, von dem die Bilder stammen (anderes Konto → neu laden)
    var server: String? = nil
    var memories: [Item] = []
    var photos: [Item] = []
    var updated = Date()

    static var folder: URL { AppGroup.container.appendingPathComponent("topshelf", isDirectory: true) }
    static var file: URL { folder.appendingPathComponent("snapshot.json") }

    static func load(from folder: URL = folder) -> TopShelfSnapshot? {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("snapshot.json")) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TopShelfSnapshot.self, from: d)
    }
    func save(to folder: URL = folder) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: folder.appendingPathComponent("snapshot.json"), options: .atomic)
    }

    /// Bilder, die zu keinem Eintrag mehr gehören, löschen.
    func pruneFiles(in folder: URL = folder) {
        let keep = Set((memories + photos).map(\.file) + ["snapshot.json"])
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(f) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(f))
        }
    }

    static func clear(_ folder: URL = folder) { try? FileManager.default.removeItem(at: folder) }
}

/// Wählt aus, was in den Top Shelf kommt, und lädt die Vorschauen (mit Zugang) in den Gruppen-Ordner.
enum TopShelfFeeder {
    /// Auswahl: bis zu 6 Rückblicke (Querformat-Titelbild) und 10 empfohlene Fotos (Favoriten im Querformat
    /// zuerst, dann Zufall vom Server). Reine Funktion → testbar.
    static func pick(memories: [Memory], favorites: [Asset], random: [Asset], limit: (Int, Int) = (6, 10)) -> (memories: [Memory], photos: [Asset]) {
        let mems = Array(memories.prefix(limit.0))
        let used = Set(mems.map(\.key.id))
        var photos: [Asset] = []
        var seen = used
        let wide: (Asset) -> Bool = { $0.isImage && $0.ratio >= 1.2 }
        for a in favorites.filter(wide) + random.filter(wide) + random.filter(\.isImage) where photos.count < limit.1 {
            if seen.insert(a.id).inserted { photos.append(a) }
        }
        return (mems, photos)
    }

    /// Schreibt den Schnappschuss. `fetch` lädt ein Vorschaubild (JPEG/WebP) – austauschbar für Tests.
    static func write(memories: [Memory], photos: [Asset], style: TopShelfSnapshot.Style, server: String? = nil,
                      folder: URL = TopShelfSnapshot.folder, fetch: @Sendable (String) async -> Data?) async throws -> TopShelfSnapshot {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var snap = TopShelfSnapshot(style: style, server: server)
        func store(_ assetID: String) async -> String? {
            let name = "\(assetID).jpg"
            let dest = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { return name }
            guard let data = await fetch(assetID), let jpeg = JPEG.recode(data, maxPixel: 1920) else { return nil }
            return (try? jpeg.write(to: dest, options: .atomic)) != nil ? name : nil
        }
        for m in memories {
            guard let f = await store(m.key.id) else { continue }
            snap.memories.append(.init(id: m.id, title: m.title, subtitle: m.subtitle, file: f,
                                       link: DeepLink.memory(m.id).url.absoluteString, date: m.date, isMemory: true))
        }
        for a in photos {
            guard let f = await store(a.id) else { continue }
            snap.photos.append(.init(id: a.id, title: Fmt.dayLongMonthYear.string(from: a.date), subtitle: a.city ?? "",
                                     file: f, link: DeepLink.asset(a.id).url.absoluteString, date: a.date))
        }
        try snap.save(to: folder)
        snap.pruneFiles(in: folder)
        return snap
    }
}


/// Vorschauen vom Server sind WebP; das System lädt Top-Shelf-Bilder selbst → sicherheitshalber als JPEG ablegen.
enum JPEG {
    static func recode(_ data: Data, maxPixel: Int) -> Data? {
        guard let img = ImageLoader.decode(data, maxPixel: maxPixel) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
