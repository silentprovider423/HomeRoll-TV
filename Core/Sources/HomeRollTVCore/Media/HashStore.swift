import Foundation

/// Merkt sich je Objekt den ThumbHash der Server-Vorschau (kommt mit jeder Zeitleisten-Antwort).
/// Er dient als unscharfer Platzhalter und als Version in der Vorschau-Adresse: rechnet der Server neue
/// Vorschauen, ändert sich der Hash → neue Adresse → der Bild-Cache wird umgangen (wie in HomeRoll).
final class HashStore: @unchecked Sendable {
    static let shared = HashStore()
    private var hashes: [String: String] = [:]
    private let lock = NSLock()

    func set(_ id: String, _ hash: String?) {
        guard let hash, !hash.isEmpty else { return }
        lock.withLock { hashes[id] = hash }
    }
    func hash(_ id: String) -> String? { lock.withLock { hashes[id] } }
    /// Kurze, URL-taugliche Fassung des Hashes (nil = unbekannt).
    func version(_ id: String) -> String? {
        hash(id).map { String($0.prefix(10)).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") }
    }
    func reset() { lock.withLock { hashes = [:] } }
}
