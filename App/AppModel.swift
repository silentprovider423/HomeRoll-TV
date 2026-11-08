import SwiftUI
import TVServices

/// Was gerade im Vollbild läuft (Sprünge aus dem Top Shelf landen hier).
struct ViewerRequest: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let start: Int
}

struct SlideshowRequest: Identifiable {
    let id = UUID()
    let assets: [Asset]
    var startID: String? = nil
    var title: String = ""
}

enum MainTab: Hashable { case memories, library, albums, search, settings }

@MainActor @Observable
final class AppModel {
    let client: ImmichClient
    let timeline: TimelineStore
    let memories = MemoryCenter()
    private(set) var loggedIn: Bool
    private(set) var userName: String?
    var tab: MainTab = .memories

    // Vollbild-Ziele (aus Deep Links)
    var viewer: ViewerRequest?
    var slideshow: SlideshowRequest?
    var playingMemory: Memory?
    @ObservationIgnored private var pendingLink: DeepLink?
    @ObservationIgnored private var debugOpened = false

    var slideshowOptions = SlideshowOptions.load() { didSet { slideshowOptions.save() } }
    var topShelfStyle: TopShelfSnapshot.Style =
        TopShelfSnapshot.Style(rawValue: UserDefaults.standard.string(forKey: "topShelfStyle") ?? "") ?? .carousel {
        didSet { UserDefaults.standard.set(topShelfStyle.rawValue, forKey: "topShelfStyle"); refreshTopShelf(force: true) }
    }
    private(set) var topShelfUpdated: Date? = TopShelfSnapshot.load()?.updated

    init(client: ImmichClient = .shared) {
        self.client = client
        timeline = TimelineStore(client: client)
        loggedIn = client.isLoggedIn
        userName = client.account?.name
        NotificationCenter.default.addObserver(forName: .sessionExpired, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logout() }
        }
        if loggedIn { start() }
    }

    // MARK: Anmeldung

    func didLogin(_ acc: Account) {
        loggedIn = true
        userName = acc.name
        start()
    }

    func logout() {
        client.logout()
        timeline.reset()
        memories.reset()
        ImageLoader.shared.clear()
        TopShelfSnapshot.clear()
        TVTopShelfContentProvider.topShelfContentDidChange()
        viewer = nil; slideshow = nil; playingMemory = nil
        loggedIn = false
        userName = nil
    }

    private func start() {
        timeline.restore()
        Task {
            if userName == nil { userName = (try? await client.me())?.name }
            await reload()
        }
    }

    func reload() async {
        await timeline.load()
        await memories.rebuild(timeline: timeline, client: client)
        if let link = pendingLink { pendingLink = nil; open(link) }
        #if DEBUG
        // Simulator-Tests: direkt ein Ziel öffnen (z. B. FOTOS_OPEN=homeroll-tv://asset/<id>)
        if let s = ProcessInfo.processInfo.environment["FOTOS_OPEN"], let u = URL(string: s), !debugOpened {
            debugOpened = true; open(u)
        }
        #endif
        refreshTopShelf()
    }

    // MARK: Deep Links (Top Shelf)

    func open(_ url: URL) {
        guard let link = DeepLink(url) else { return }
        open(link)
    }

    func open(_ link: DeepLink) {
        guard loggedIn else { return }
        switch link {
        case .memory(let id):
            if let m = memories.memory(id) { viewer = nil; slideshow = nil; playingMemory = m }
            else if memories.items.isEmpty { pendingLink = link }
        case .asset(let id):
            if let a = timeline.asset(id) {
                let list = timeline.assets
                viewer = ViewerRequest(assets: list, start: list.firstIndex(of: a) ?? 0)
            } else if timeline.assets.isEmpty {
                pendingLink = link
            } else {
                Task {
                    if let a = try? await client.asset(id).asset { viewer = ViewerRequest(assets: [a], start: 0) }
                }
            }
        case .album: tab = .albums
        case .slideshow:
            let favs = timeline.favorites
            slideshow = SlideshowRequest(assets: favs.isEmpty ? timeline.assets : favs, title: String(localized: "Favoriten"))
        case .library: tab = .library
        case .search: tab = .search
        }
    }

    // MARK: Favoriten

    func toggleFavorite(_ a: Asset) async -> Bool {
        let new = !(timeline.asset(a.id)?.isFavorite ?? a.isFavorite)
        timeline.setFavorite(a.id, new)
        do { try await client.setFavorite(a.id, new) } catch { timeline.setFavorite(a.id, !new); return !new }
        return new
    }

    func isFavorite(_ a: Asset) -> Bool { timeline.asset(a.id)?.isFavorite ?? a.isFavorite }

    // MARK: Top Shelf

    @ObservationIgnored private var topShelfTask: Task<Void, Never>?

    /// Vorschauen für den Top Shelf mit unserem Zugang in den Gruppen-Ordner laden (höchstens alle 30 min).
    func refreshTopShelf(force: Bool = false) {
        guard loggedIn, topShelfTask == nil, !timeline.assets.isEmpty else { return }
        let server = client.baseURL?.absoluteString
        let sameServer = TopShelfSnapshot.load()?.server == server
        if !force, sameServer, let u = topShelfUpdated, Date().timeIntervalSince(u) < 1800 { return }
        let force = force || !sameServer
        let client = self.client, style = topShelfStyle
        let mems = memories.items, favs = timeline.favorites.shuffled()
        topShelfTask = Task {
            let random = ((try? await client.random(size: 30)) ?? []).map(\.asset)
            let pick = TopShelfFeeder.pick(memories: mems, favorites: favs, random: random)
            if force { TopShelfSnapshot.clear() }
            let snap = try? await TopShelfFeeder.write(memories: pick.memories, photos: pick.photos, style: style, server: server) { id in
                guard let url = client.thumbnailURL(id, .preview) else { return nil }
                return try? await client.data(url)
            }
            if let snap { topShelfUpdated = snap.updated }
            TVTopShelfContentProvider.topShelfContentDidChange()
            topShelfTask = nil
        }
    }

    func clearCaches() {
        ImageLoader.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        timeline.reset()
        memories.reset()
        Task { await reload() }
    }
}
