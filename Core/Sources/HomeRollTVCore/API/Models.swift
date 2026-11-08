import Foundation

// Server-Antworten (Immich v3.3.x). Übernommen aus HomeRoll (App/API/Models.swift) und für tvOS gekürzt:
// keine Bearbeitungs-, Backup- oder Duplikat-Typen, dafür Rückblick-Felder (isSaved) und JSON-Filter.

struct LoginResponse: Decodable, Sendable {
    let accessToken: String
    let name: String
    let userId: String
    let userEmail: String
}

struct TimeBucket: Decodable, Hashable, Identifiable, Sendable {
    let timeBucket: String          // "2024-12-01" (Monatsanfang)
    let count: Int
    var id: String { timeBucket }

    /// Monatsanfang als Datum (Kalender in UTC = „Wanduhrzeit“, siehe Asset.date).
    var monthDate: Date { DateParsing.day(timeBucket) ?? .distantPast }
}

/// Spaltenformat von GET /timeline/bucket: jedes Feld ist ein Array, Index i = Asset i.
struct BucketColumns: Decodable, Sendable {
    let id: [String]
    let isImage: [Bool]
    let isFavorite: [Bool]
    let fileCreatedAt: [String]          // UTC, ohne "Z"
    let localOffsetHours: [Double?]?     // + Offset = Ortszeit der Aufnahme
    let ratio: [Double?]
    let duration: [Int?]?                // Millisekunden, nur Videos
    let livePhotoVideoId: [String?]
    let city: [String?]?
    let country: [String?]?
    let thumbhash: [String?]?
    let createdAt: [String]?
    let ownerId: [String]?

    func assets() -> [Asset] {
        id.indices.map { i in
            HashStore.shared.set(id[i], thumbhash?[i] ?? nil)
            let utc = DateParsing.wallClock(fileCreatedAt[i]) ?? .distantPast
            let offset = (localOffsetHours?[i] ?? nil) ?? 0
            return Asset(id: id[i],
                         isImage: isImage[i],
                         isFavorite: isFavorite[i],
                         date: utc.addingTimeInterval(offset * 3600),
                         ratio: ratio[i] ?? 1,
                         durationMs: duration?[i] ?? nil,
                         livePhotoVideoId: livePhotoVideoId[i],
                         city: city?[i] ?? nil,
                         country: country?[i] ?? nil,
                         ownerId: ownerId?[i])
        }
    }
}

/// Ein Foto/Video. `date` ist die lokale Aufnahme-Uhrzeit („Wanduhr“), als UTC gespeichert
/// und immer mit `Calendar.wall` / UTC-Formattern angezeigt → Tage kippen nie um Mitternacht.
struct Asset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let isImage: Bool
    var isFavorite: Bool
    let date: Date
    let ratio: Double
    let durationMs: Int?
    let livePhotoVideoId: String?
    let city: String?
    let country: String?
    var ownerId: String? = nil

    var isVideo: Bool { !isImage }
    var isLivePhoto: Bool { livePhotoVideoId != nil }
}

/// Vollständiges Asset (GET /assets/{id}, Suche, Rückblicke, Alben).
struct AssetDTO: Decodable, Sendable {
    let id: String
    let type: String                 // IMAGE | VIDEO
    let isFavorite: Bool
    let localDateTime: String?       // Ortszeit der Aufnahme (mit falschem "Z")
    let fileCreatedAt: String
    let duration: Int?               // Millisekunden (v3), null bei Fotos
    let livePhotoVideoId: String?
    let originalFileName: String?
    let exifInfo: ExifDTO?
    let ownerId: String?
    let description: String?
    let thumbhash: String?
    let width: Double?
    let height: Double?
    let people: [PersonDTO]?

    struct ExifDTO: Decodable, Sendable {
        let city: String?
        let country: String?
        let state: String?
        let make: String?
        let model: String?
        let exifImageWidth: Double?
        let exifImageHeight: Double?
        let fileSizeInByte: Int?
        let latitude: Double?
        let longitude: Double?
        let fNumber: Double?
        let focalLength: Double?
        let iso: Double?
        let exposureTime: String?
        let lensModel: String?
        let description: String?
    }

    var asset: Asset {
        HashStore.shared.set(id, thumbhash)
        let w = width ?? exifInfo?.exifImageWidth ?? 0, h = height ?? exifInfo?.exifImageHeight ?? 0
        return Asset(id: id, isImage: type == "IMAGE", isFavorite: isFavorite,
                     date: DateParsing.wallClock(localDateTime ?? fileCreatedAt) ?? .distantPast,
                     ratio: (w > 0 && h > 0) ? w / h : 1,
                     durationMs: (duration ?? 0) > 0 ? duration : nil,
                     livePhotoVideoId: livePhotoVideoId,
                     city: exifInfo?.city, country: exifInfo?.country, ownerId: ownerId)
    }
}

struct MemoryDTO: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let memoryAt: String
    let data: MemoryData
    let assets: [AssetDTO]
    var isSaved: Bool? = nil
    struct MemoryData: Decodable, Sendable { let year: Int? }
}

struct AlbumDTO: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let albumName: String
    let albumThumbnailAssetId: String?
    let assetCount: Int
    var order: String? = nil          // asc | desc
    var createdAt: String? = nil
    var updatedAt: String? = nil
    var startDate: String? = nil
    var endDate: String? = nil
    var shared: Bool? = nil
    var ownerId: String? = nil
}

/// Kommentar oder „Gefällt mir“ in einem geteilten Album (Immich: /activities).
struct ActivityDTO: Decodable, Identifiable, Hashable, Sendable {
    struct User: Decodable, Hashable, Sendable { let id: String; let name: String }
    let id: String
    let createdAt: String
    let type: String                  // comment | like
    let assetId: String?
    let comment: String?
    let user: User
}

struct PersonDTO: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isHidden: Bool?
    var isFavorite: Bool? = nil
}

struct PeopleDTO: Decodable, Sendable {
    let people: [PersonDTO]
    let total: Int
}

struct SearchResponseDTO: Decodable, Sendable {
    let assets: Page
    struct Page: Decodable, Sendable {
        let items: [AssetDTO]
        let nextPage: String?
        let nextCursor: String?
    }
}

struct UserDTO: Decodable, Sendable {
    let id: String
    let name: String
    let email: String
}

// MARK: - JSON für Anfragen (Sendable statt [String: Any])

/// Kleiner JSON-Baum für Suchfilter und Anfrage-Rümpfe – über Aktor-Grenzen hinweg sicher.
enum JSON: Sendable, Equatable, Encodable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
           ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSON]), object([String: JSON])

    init(stringLiteral v: String) { self = .string(v) }
    init(integerLiteral v: Int) { self = .int(v) }
    init(booleanLiteral v: Bool) { self = .bool(v) }
    init(arrayLiteral v: JSON...) { self = .array(v) }
    init(dictionaryLiteral v: (String, JSON)...) { self = .object(Dictionary(v, uniquingKeysWith: { _, b in b })) }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSON? {
        get { if case .object(let o) = self { o[key] } else { nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    var data: Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

// MARK: - Datum

enum DateParsing {
    static let utc = TimeZone(identifier: "UTC")!

    /// "2024-12-17T10:10:00" oder "...000Z" → Datum, als Wanduhrzeit in UTC interpretiert.
    static func wallClock(_ s: String) -> Date? {
        var str = s
        if let z = str.firstIndex(where: { $0 == "Z" || $0 == "+" }) { str = String(str[..<z]) }
        if let dot = str.firstIndex(of: ".") { str = String(str[..<dot]) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: str)
    }

    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// Datum → "2026-11-08" (für Rückblicke „für heute“).
    static func dayString(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Jetzt als Wanduhr-Datum (gleiche Darstellung wie Asset.date).
    static func wallNow(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT(for: now)))
    }
}

extension Calendar {
    /// Kalender für Wanduhr-Daten (siehe Asset.date).
    static let wall: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = DateParsing.utc
        c.locale = .autoupdatingCurrent
        return c
    }()
}

enum Fmt {
    private static func make(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = DateParsing.utc
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    nonisolated(unsafe) static let dayMonthYear = make("d MMM yyyy")
    nonisolated(unsafe) static let dayMonth = make("d MMM")
    nonisolated(unsafe) static let monthYear = make("MMMM yyyy")
    nonisolated(unsafe) static let month = make("MMMM")
    nonisolated(unsafe) static let time = make("HH:mm")
    nonisolated(unsafe) static let weekday = make("EEEE")
    nonisolated(unsafe) static let dayLongMonthYear = make("d MMMM yyyy")
    nonisolated(unsafe) static let fullDate = make("EEEE d MMMM yyyy")

    /// Wie Fotos: „Heute“, „Gestern“, innerhalb einer Woche der Wochentag, sonst das lange Datum.
    static func relativeDay(_ d: Date, now: Date = Date()) -> String {
        let today = Calendar.wall.startOfDay(for: DateParsing.wallNow(now))
        let diff = Calendar.wall.dateComponents([.day], from: Calendar.wall.startOfDay(for: d), to: today).day ?? 99
        switch diff {
        case 0: return String(localized: "Heute")
        case 1: return String(localized: "Gestern")
        case 2..<7: return weekday.string(from: d)
        default: return fullDate.string(from: d)
        }
    }

    static func duration(_ ms: Int?) -> String {
        guard let ms else { return "" }
        let s = ms / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
