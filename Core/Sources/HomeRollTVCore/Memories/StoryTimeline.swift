import Foundation

/// Selbst erzeugte Hintergrundmusik (keine Musikdateien, keine Lizenzen) – aus HomeRoll.
enum MemoryMood: Int, CaseIterable, Identifiable, Codable, Sendable {
    case none, gentle, happy, thoughtful, epic
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: String(localized: "Ohne Musik")
        case .gentle: String(localized: "Sanft")
        case .happy: String(localized: "Fröhlich")
        case .thoughtful: String(localized: "Nachdenklich")
        case .epic: String(localized: "Episch")
        }
    }
    var icon: String {
        switch self {
        case .none: "speaker.slash"; case .gentle: "leaf"; case .happy: "sun.max"
        case .thoughtful: "cloud.drizzle"; case .epic: "mountain.2"
        }
    }
    /// Tempo der Musik (gleiche Werte wie der Synthesizer)
    var bpm: Double {
        switch self { case .gentle: 72; case .happy: 112; case .thoughtful: 64; case .epic: 80; case .none: 76 }
    }
}

/// Farbstil eines Rückblicks.
enum MemoryStyle: Int, CaseIterable, Identifiable, Codable, Sendable {
    case natural, warm, cool, vivid, contrast, mono
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .natural: String(localized: "Natürlich"); case .warm: String(localized: "Warm"); case .cool: String(localized: "Kühl")
        case .vivid: String(localized: "Lebendig"); case .contrast: String(localized: "Kontrastreich"); case .mono: String(localized: "Schwarzweiß")
        }
    }
}

/// Rückblick-Mix: Musik + Farbstil, wie Apples „Memory Mixes“.
struct MemoryMix: Hashable, Sendable {
    let mood: MemoryMood
    let style: MemoryStyle
    static let all: [MemoryMix] = [
        .init(mood: .gentle, style: .natural), .init(mood: .happy, style: .vivid), .init(mood: .thoughtful, style: .cool),
        .init(mood: .epic, style: .contrast), .init(mood: .gentle, style: .warm), .init(mood: .thoughtful, style: .mono),
    ]
    var title: String { "\(mood.title) · \(style.title)" }
}

/// Eine Szene der Rückblick-Zeitleiste (Fernseher: 16:9 quer).
struct StoryScene: Identifiable, Sendable {
    enum Kind: Sendable { case title, one(Asset), two(Asset, Asset), three(Asset, Asset, Asset), video(Asset) }
    enum Transition: Sendable { case fade, push, zoom }
    let id: Int
    let kind: Kind
    let start: Double
    let duration: Double
    let transition: Transition
    var end: Double { start + duration }
    var assets: [Asset] {
        switch kind {
        case .title: []
        case .one(let a), .video(let a): [a]
        case .two(let a, let b): [a, b]
        case .three(let a, let b, let c): [a, b, c]
        }
    }
}

/// Zeitleiste aus Szenen, Längen auf ganze Takte der Musik (Vorlage HomeRoll StoryTimeline, hier für Querformat:
/// Hochformate kommen zu zweit oder dritt nebeneinander, Querformate allein).
enum StoryTimeline {
    static let fade = 0.8

    static func build(_ assets: [Asset], mood: MemoryMood) -> [StoryScene] {
        let bar = 60 / mood.bpm * 4
        func bars(_ seconds: Double) -> Double { max(1, (seconds / bar).rounded()) * bar }
        var out = [StoryScene(id: 0, kind: .title, start: 0, duration: bars(5.0), transition: .fade)]
        var t = out[0].duration
        var i = 0, n = 1
        let portrait: (Asset) -> Bool = { $0.isImage && $0.ratio < 0.9 }
        func near(_ a: Asset, _ b: Asset) -> Bool { abs(a.date.timeIntervalSince(b.date)) < 6 * 3600 }
        while i < assets.count {
            let a = assets[i]
            let kind: StoryScene.Kind, len: Double
            if a.isVideo {
                kind = .video(a); len = bars(min(Double(a.durationMs ?? 4000) / 1000, 9)); i += 1
            } else if i + 2 < assets.count, portrait(a), portrait(assets[i + 1]), portrait(assets[i + 2]),
                      near(a, assets[i + 2]), n % 3 == 1 {
                kind = .three(a, assets[i + 1], assets[i + 2]); len = bars(5.0); i += 3
            } else if i + 1 < assets.count, portrait(a), portrait(assets[i + 1]), near(a, assets[i + 1]) {
                kind = .two(a, assets[i + 1]); len = bars(4.2); i += 2
            } else {
                kind = .one(a); len = bars(3.6); i += 1
            }
            let tr: StoryScene.Transition = n % 7 == 0 ? .zoom : n % 4 == 0 ? .push : .fade
            out.append(StoryScene(id: n, kind: kind, start: t, duration: len, transition: tr))
            t += len; n += 1
        }
        return out
    }

    static func total(_ scenes: [StoryScene]) -> Double { scenes.last?.end ?? 0 }
    static func index(at t: Double, in scenes: [StoryScene]) -> Int { scenes.lastIndex { $0.start <= t } ?? 0 }
}

/// Uhr des Players: läuft nur beim Abspielen, Sprünge setzen sie neu (Apples PXStoryPacingClock).
struct StoryClock: Sendable {
    private(set) var playing = false
    private var base: Double = 0
    private var started = Date()
    func time(_ now: Date = Date()) -> Double { playing ? base + now.timeIntervalSince(started) : base }
    mutating func play(_ now: Date = Date()) { guard !playing else { return }; started = now; playing = true }
    mutating func pause(_ now: Date = Date()) { guard playing else { return }; base = time(now); playing = false }
    mutating func seek(_ t: Double, _ now: Date = Date()) { base = max(0, t); started = now }
}

/// Langsamer Zoom und Schwenk (Ken Burns), aus dem Fortschritt 0…1 berechnet – friert bei Pause ein.
struct KenBurns: Equatable, Sendable {
    let scale: Double
    let dx: Double     // Anteil der Breite
    let dy: Double     // Anteil der Höhe

    static func at(seed: Int, progress p: Double) -> KenBurns {
        let dirs: [(Double, Double)] = [(-0.018, -0.012), (0.016, 0.014), (-0.012, 0.016), (0.014, -0.014)]
        let d = dirs[abs(seed) % dirs.count]
        let q = min(1, max(0, p))
        let zoomIn = seed % 2 == 0
        return KenBurns(scale: zoomIn ? 1.04 + 0.12 * q : 1.16 - 0.12 * q, dx: d.0 * q, dy: d.1 * q)
    }
}
