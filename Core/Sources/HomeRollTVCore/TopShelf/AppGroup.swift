import Foundation

/// Gemeinsamer Ordner von App und Top-Shelf-Erweiterung (Vorlage: HomeRoll Shared/AppGroup.swift).
/// SideStore/AltStore hängen beim Installieren die Team-ID an die Gruppe an und schreiben die echte ID in die
/// Info.plist (Schlüssel „ALTAppGroups“) – im Simulator gilt der Name aus den Berechtigungen.
enum AppGroup {
    static let base = "group.org.homeroll.tv"

    static let id: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        var candidates: [String] = []
        for case let list as [String] in [info["ALTAppGroups"]] + info.values.map({ Optional($0) }) {
            candidates += list.filter { $0.hasPrefix(base) }
        }
        candidates.append(base)
        return candidates.first { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil } ?? base
    }()

    /// Beschreibbarer Teil des Gruppen-Ordners. tvOS erlaubt Apps nur Caches (auch im Gruppen-Ordner nur
    /// `Library/Caches`); ohne Berechtigung (macOS-Tests) ein Ordner unter den eigenen Caches.
    static var container: URL {
        let fm = FileManager.default
        #if os(tvOS)
        let group = fm.containerURL(forSecurityApplicationGroupIdentifier: id)
        #else
        let group: URL? = nil
        #endif
        let u = group?.appendingPathComponent("Library/Caches", isDirectory: true)
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("homeroll-tv-group", isDirectory: true)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
