import Foundation
import Security

/// Wie die App sich beim Server ausweist: Sitzungs-Token (nach Anmeldung mit E-Mail/Passwort) oder
/// API-Schlüssel (in Immich unter Kontoeinstellungen › API-Schlüssel erstellt, gern nur mit Leserechten).
enum Credential: Codable, Equatable, Sendable {
    case session(String)
    case apiKey(String)

    var secret: String { switch self { case .session(let s), .apiKey(let s): s } }

    /// Kopfzeilen für jede Anfrage. Immich liest Sitzungen aus „Authorization: Bearer“, Schlüssel aus „x-api-key“.
    var headers: [String: String] {
        switch self {
        case .session(let t): ["Authorization": "Bearer \(t)"]
        case .apiKey(let k): ["x-api-key": k]
        }
    }
}

/// Server + Zugang, gemeinsam gespeichert.
struct Account: Codable, Equatable, Sendable {
    let server: URL
    let credential: Credential
    var name: String? = nil
    var email: String? = nil
}

protocol AccountStore: Sendable {
    func load() -> Account?
    func save(_ account: Account?)
}

/// Schlüsselbund (tvOS behält ihn auch, wenn das System die Caches der App leert). Mit Zugriffsgruppe teilt die
/// App den Zugang mit der Top-Shelf-Erweiterung.
struct KeychainAccountStore: AccountStore {
    var service = "org.homeroll.tv"
    var account = "konto"
    var accessGroup: String? = nil

    private var base: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    func load() -> Account? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }

    func save(_ value: Account?) {
        SecItemDelete(base as CFDictionary)
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Für Tests und Debug-Starts (nichts wird dauerhaft gespeichert).
final class MemoryAccountStore: AccountStore, @unchecked Sendable {
    private var value: Account?
    private let lock = NSLock()
    init(_ value: Account? = nil) { self.value = value }
    func load() -> Account? { lock.withLock { value } }
    func save(_ account: Account?) { lock.withLock { value = account } }
}
