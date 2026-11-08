import SwiftUI

/// Alben: eigene Alben (sortierbar), geteilte Alben, Personen & Haustiere, Medienarten.
struct AlbumsView: View {
    enum Sort: String, CaseIterable, Identifiable {
        case custom, name, modified
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .custom: "Eigene Reihenfolge"; case .name: "Nach Namen sortieren"; case .modified: "Nach Änderungsdatum sortieren"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @AppStorage("albumSort") private var sort: Sort = .custom
    @State private var albums: [AlbumDTO] = []
    @State private var shared: [AlbumDTO] = []
    @State private var people: [PersonDTO] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        SectionTitle(text: "Alben", detail: albums.isEmpty ? nil : "\(albums.count)")
                        Menu {
                            Picker("Sortieren", selection: $sort) { ForEach(Sort.allCases) { Text($0.title).tag($0) } }
                        } label: { Label("Sortieren", systemImage: "arrow.up.arrow.down") }
                            .padding(.top, 30)
                    }
                    .focusSection()
                    if !loaded { ProgressView().frame(maxWidth: .infinity).padding(60) }
                    else if albums.isEmpty { Text(error ?? String(localized: "Keine Alben")).foregroundStyle(.secondary).padding(.vertical, 30) }
                    albumGrid(sorted(albums))

                    if !shared.isEmpty {
                        SectionTitle(text: "Geteilte Alben", detail: "\(shared.count)").padding(.top, 30)
                        albumGrid(sorted(shared))
                    }

                    if !people.isEmpty {
                        SectionTitle(text: "Personen & Haustiere", detail: "\(people.count)").padding(.top, 30)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 50) {
                                ForEach(people) { p in
                                    NavigationLink(value: Collection.person(p)) {
                                        VStack(spacing: 16) {
                                            PersonImage(id: p.id).frame(width: 220, height: 220)
                                            Text(p.name.isEmpty ? String(localized: "Unbenannt") : p.name).font(.callout).lineLimit(1)
                                        }
                                        .frame(width: 240)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 30)
                        }
                        .scrollClipDisabled()
                        .focusSection()
                    }

                    SectionTitle(text: "Medienarten").padding(.top, 30)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 4), spacing: 40) {
                        ForEach(MediaKind.allCases) { k in
                            NavigationLink(value: Collection.media(k)) {
                                Label(k.title, systemImage: k.icon).font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                            }
                        }
                    }
                    .focusSection()
                }
                .padding(.bottom, 80)
            }
            .navigationDestination(for: Collection.self) { CollectionView(collection: $0) }
        }
        .task { await load() }
    }

    private func albumGrid(_ list: [AlbumDTO]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 44), count: 4), spacing: 56) {
            ForEach(list) { a in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: Collection.album(a)) {
                        Group {
                            if let k = a.albumThumbnailAssetId { FilledImage(id: k, size: .preview) }
                            else { Rectangle().fill(.white.opacity(0.06)).overlay { Image(systemName: "photo.on.rectangle").font(.largeTitle) } }
                        }
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.card)
                    .accessibilityIdentifier("album-\(a.albumName)")
                    Text(a.albumName).font(.headline).lineLimit(1)
                    Text("\(a.assetCount)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .focusSection()
    }

    private func sorted(_ list: [AlbumDTO]) -> [AlbumDTO] {
        switch sort {
        case .custom: list
        case .name: list.sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
        case .modified: list.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        }
    }

    private func load() async {
        do {
            let own = try await app.client.albums()
            let sh = (try? await app.client.sharedAlbums()) ?? []
            // „Geteilt“ = Alben anderer, die mit mir geteilt sind, und eigene mit Freigabe
            shared = sh.filter { s in s.shared == true }
            let sharedIDs = Set(shared.map(\.id))
            albums = own.filter { !sharedIDs.contains($0.id) }
            error = nil
        } catch { self.error = error.localizedDescription }
        people = (try? await app.client.people()) ?? []
        loaded = true
    }
}

/// Medienarten aus der Zeitleiste (ohne Server-Anfrage).
enum MediaKind: String, CaseIterable, Identifiable, Hashable {
    case favorites, videos, livePhotos, panoramas
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: String(localized: "Favoriten"); case .videos: String(localized: "Videos")
        case .livePhotos: String(localized: "Live Photos"); case .panoramas: String(localized: "Panoramen")
        }
    }
    var icon: String {
        switch self { case .favorites: "heart"; case .videos: "video"; case .livePhotos: "livephoto"; case .panoramas: "pano" }
    }
    func filter(_ a: Asset) -> Bool {
        switch self {
        case .favorites: a.isFavorite
        case .videos: a.isVideo
        case .livePhotos: a.isLivePhoto
        case .panoramas: a.isImage && a.ratio >= 2.0
        }
    }
}

enum Collection: Hashable {
    case album(AlbumDTO), person(PersonDTO), media(MediaKind)
    var title: String {
        switch self {
        case .album(let a): a.albumName
        case .person(let p): p.name.isEmpty ? String(localized: "Unbenannt") : p.name
        case .media(let k): k.title
        }
    }
}

/// Inhalt eines Albums / einer Person / einer Medienart: Kopf mit „Diashow“ und „Rückblick-Video wiedergeben“,
/// darunter das Fokus-Raster. Play/Pause startet die Diashow.
struct CollectionView: View {
    let collection: Collection
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter
    @State private var assets: [Asset] = []
    @State private var loading = true
    @State private var activity: [ActivityDTO] = []
    @State private var showActivity = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.title).font(.system(size: 60, weight: .bold))
                    if let r = range { Text(r).font(.headline).foregroundStyle(.secondary) }
                }
                HStack(spacing: 30) {
                    Button { presenter.slideshow(assets, title: collection.title) } label: {
                        Label("Diashow", systemImage: "play.rectangle.fill")
                    }
                    .disabled(assets.filter(\.isImage).isEmpty)
                    .accessibilityIdentifier("collection-slideshow")
                    Button {
                        if let m = MemoryEngine.adhoc(id: "collection-\(collection.title)", title: collection.title, assets: assets) {
                            presenter.memory = m
                        }
                    } label: { Label("Rückblick-Video wiedergeben", systemImage: "memories") }
                    .disabled(assets.count < 3)
                    if case .album(let a) = collection, a.shared == true {
                        Button { showActivity = true } label: { Label("Aktivität", systemImage: "bubble.left.and.bubble.right") }
                    }
                    Spacer()
                    Text("\(assets.count) Objekte").foregroundStyle(.secondary)
                }
                .focusSection()

                if loading { ProgressView().frame(maxWidth: .infinity).padding(80) }
                else if assets.isEmpty { EmptyHint(icon: "photo", title: "Keine Objekte") }
                else { PhotoGrid(assets: assets, title: collection.title) }
            }
            .padding(.bottom, 80)
        }
        .task { await load() }
        .sheet(isPresented: $showActivity) { ActivityList(items: activity) }
    }

    private var range: String? { assets.isEmpty ? nil : MemoryEngine.range(assets.sorted { $0.date < $1.date }) }

    private func load() async {
        defer { loading = false }
        switch collection {
        case .album(let a):
            let list = (try? await app.client.albumAssets(a.id)) ?? []
            assets = a.order == "desc" ? list.sorted { $0.date > $1.date } : list.sorted { $0.date < $1.date }
            if a.shared == true { activity = (try? await app.client.activities(album: a.id)) ?? [] }
        case .person(let p):
            assets = ((try? await app.client.personAssets(p.id)) ?? []).sorted { $0.date > $1.date }
        case .media(let k):
            assets = app.timeline.assets.filter(k.filter)
        }
    }
}

/// Kommentare und „Gefällt mir“ eines geteilten Albums (nur lesen).
private struct ActivityList: View {
    let items: [ActivityDTO]
    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty { Text("Noch keine Aktivität").foregroundStyle(.secondary) }
                ForEach(items) { a in
                    HStack(spacing: 20) {
                        Image(systemName: a.type == "like" ? "heart.fill" : "text.bubble")
                        VStack(alignment: .leading) {
                            Text(a.user.name).font(.headline)
                            if let c = a.comment { Text(c) }
                        }
                        Spacer()
                        if let d = DateParsing.wallClock(a.createdAt) { Text(Fmt.dayMonthYear.string(from: d)).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Aktivität")
        }
    }
}
