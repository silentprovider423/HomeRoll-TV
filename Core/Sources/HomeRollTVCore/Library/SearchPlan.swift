import Foundation

/// Suchtext → Server-Filter + Freitext (Vorlage: HomeRoll SearchPlan, gekürzt). „Strand Bodrum 2024“ wird zu
/// Ort = Bodrum, Jahr = 2024 und KI-Suche nach „Strand“. Ohne Freitext reicht die Metadaten-Suche.
struct SearchPlan: Equatable, Sendable {
    var filter: JSON = [:]
    var freeText = ""
    var labels: [String] = []

    var isEmpty: Bool { freeText.isEmpty && filter == [:] }

    private static let months: [String: Int] = [
        "januar": 1, "january": 1, "februar": 2, "february": 2, "märz": 3, "maerz": 3, "march": 3, "april": 4, "mai": 5, "may": 5,
        "juni": 6, "june": 6, "juli": 7, "july": 7, "august": 8, "september": 9, "oktober": 10, "october": 10,
        "november": 11, "dezember": 12, "december": 12]

    static func make(_ query: String, cities: [String], people: [PersonDTO]) -> SearchPlan {
        var p = SearchPlan()
        var rest = " " + query + " "
        func take(_ word: String) {
            rest = rest.replacingOccurrences(of: word, with: " ", options: [.caseInsensitive, .diacriticInsensitive])
        }
        func has(_ word: String) -> Bool {
            rest.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }

        // Medienart
        for w in ["videos", "video"] where has(w) { p.filter["type"] = ["eq": "VIDEO"]; p.labels.append(String(localized: "Videos")); take(w); break }
        for w in ["live photos", "live photo", "livephotos"] where has(w) { p.filter["isMotion"] = ["eq": true]; p.labels.append(String(localized: "Live Photos")); take(w); break }
        for w in ["favoriten", "favorites", "favorit", "favorite"] where has(w) { p.filter["isFavorite"] = ["eq": true]; p.labels.append(String(localized: "Favoriten")); take(w); break }

        // Ort (längster Treffer zuerst, damit „Bad Boll“ vor „Boll“ greift)
        if let city = cities.sorted(by: { $0.count > $1.count }).first(where: { has($0) }) {
            p.filter["city"] = ["eq": .string(city)]; p.labels.append(city); take(city)
        }
        // Personen
        let found = people.filter { !$0.name.isEmpty && has($0.name) }
        if !found.isEmpty {
            p.filter["personIds"] = ["all": .array(found.map { .string($0.id) })]
            p.labels += found.map(\.name); found.forEach { take($0.name) }
        }
        // Jahr (und Monat)
        let words = rest.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if let y = words.compactMap(Int.init).first(where: { (1900...2100).contains($0) }) {
            var from = DateComponents(year: y, month: 1, day: 1), to = DateComponents(year: y + 1, month: 1, day: 1)
            var label = "\(y)"
            if let mw = words.first(where: { months[$0] != nil }), let m = months[mw] {
                from.month = m
                to = DateComponents(year: m == 12 ? y + 1 : y, month: m == 12 ? 1 : m + 1, day: 1)
                label = "\(mw.capitalized) \(y)"; take(mw)
            }
            let iso = ISO8601DateFormatter()
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .gmt
            p.filter["takenAt"] = ["gte": .string(iso.string(from: cal.date(from: from)!)), "lt": .string(iso.string(from: cal.date(from: to)!))]
            p.labels.append(label); take(String(y))
        }
        p.freeText = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return p
    }
}
