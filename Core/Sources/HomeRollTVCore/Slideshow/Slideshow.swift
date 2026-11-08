import Foundation

/// Diashow-Themen. Apples Apple-TV-Vorlagen (`com.apple.TBD@atv` in OpusKit) kennen nur „Überblenden“ (3,0 s Übergang)
/// und „Magazin“; Ken Burns kommt vom iPhone dazu.
enum SlideshowTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case dissolve, magazine, kenBurns
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dissolve: String(localized: "Überblenden")
        case .magazine: String(localized: "Magazin")
        case .kenBurns: String(localized: "Ken Burns")
        }
    }
    /// Dauer des Übergangs in Sekunden
    var transition: Double {
        switch self { case .dissolve: 3.0; case .magazine: 1.2; case .kenBurns: 2.0 }
    }
}

/// „Diashow-Optionen“ (Apples PUSlideshowSettingsViewController): Thema, Musik, Wiederholen, Dauer je Foto.
struct SlideshowOptions: Codable, Equatable, Sendable {
    var theme: SlideshowTheme = .dissolve
    var mood: MemoryMood = .none
    var repeats = true
    var shuffle = false
    var secondsPerSlide: Double = 5

    private static let key = "slideshowOptions"
    static func load(_ d: UserDefaults = .standard) -> SlideshowOptions {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SlideshowOptions.self, from: $0) } ?? SlideshowOptions()
    }
    func save(_ d: UserDefaults = .standard) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
}

/// Eine Seite der Diashow: ein Foto oder (Magazin) mehrere Fotos in einem Layout.
struct SlidePage: Identifiable, Hashable, Sendable {
    enum Layout: Hashable, Sendable {
        case single           // ein Foto, bildschirmfüllend
        case pair             // zwei Hochformate nebeneinander
        case trio             // groß links, zwei klein rechts
        case strip            // drei Hochformate nebeneinander
    }
    let id: Int
    let layout: Layout
    let assets: [Asset]
}

enum SlideshowPlanner {
    /// Seiten bauen. Videos werden übersprungen (Apple zeigt in der Diashow nur Standbilder),
    /// beim Magazin teilen sich Hochformate eine Seite.
    static func pages(_ input: [Asset], theme: SlideshowTheme, shuffle: Bool = false, seed: UInt64 = 1) -> [SlidePage] {
        var list = input.filter(\.isImage)
        if shuffle {
            var rng = SeededRandom(seed: seed)
            list.shuffle(using: &rng)
        }
        guard theme == .magazine else {
            return list.enumerated().map { SlidePage(id: $0.offset, layout: .single, assets: [$0.element]) }
        }
        var out: [SlidePage] = []
        var i = 0
        let portrait: (Asset) -> Bool = { $0.ratio < 0.9 }
        while i < list.count {
            let a = list[i], n = out.count
            if i + 2 < list.count, portrait(a), portrait(list[i + 1]), portrait(list[i + 2]), n % 3 == 2 {
                out.append(SlidePage(id: n, layout: .strip, assets: Array(list[i...i + 2]))); i += 3
            } else if i + 1 < list.count, portrait(a), portrait(list[i + 1]) {
                out.append(SlidePage(id: n, layout: .pair, assets: [a, list[i + 1]])); i += 2
            } else if i + 2 < list.count, !portrait(a), n % 4 == 3 {
                out.append(SlidePage(id: n, layout: .trio, assets: Array(list[i...i + 2]))); i += 3
            } else {
                out.append(SlidePage(id: n, layout: .single, assets: [a])); i += 1
            }
        }
        return out
    }

    /// Nächste Seite (nil = Ende ohne Wiederholen).
    static func next(_ i: Int, count: Int, repeats: Bool) -> Int? {
        guard count > 0 else { return nil }
        if i + 1 < count { return i + 1 }
        return repeats ? 0 : nil
    }
    static func previous(_ i: Int, count: Int) -> Int { count == 0 ? 0 : (i - 1 + count) % count }

    /// Start-Seite für ein bestimmtes Foto („Diashow ab hier“).
    static func index(of assetID: String?, in pages: [SlidePage]) -> Int {
        guard let assetID else { return 0 }
        return pages.firstIndex { $0.assets.contains { $0.id == assetID } } ?? 0
    }
}

/// Reproduzierbarer Zufall (Tests, gleiche Reihenfolge nach Pause).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
