import SwiftUI

/// Mediathek wie auf dem Apple TV: Ansicht per Segmentknopf (Jahre · Monate · Tage · Alle Fotos) statt Zoomen.
/// Klick auf ein Jahr → dessen Monate, Klick auf einen Monat → dessen Tage.
struct LibraryView: View {
    enum Level: String, CaseIterable, Identifiable {
        case years, months, days, all
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self { case .years: "Jahre"; case .months: "Monate"; case .days: "Tage"; case .all: "Alle Fotos" }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter
    @AppStorage("libraryLevel") private var level: Level = .all
    @AppStorage("favoritesOnly") private var favoritesOnly = false
    @State private var target: String?
    @FocusState private var focused: String?
    @State private var cache = GroupCache()

    private var source: [Asset] { favoritesOnly ? app.timeline.favorites : app.timeline.assets }

    var body: some View {
        let groups = cache.groups(source, level: level, generation: app.timeline.assets.count &+ app.timeline.generation &* 31 &+ (favoritesOnly ? 7 : 0))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if source.isEmpty {
                        if app.timeline.loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 200) }
                        else if favoritesOnly { EmptyHint(icon: "heart", title: "Keine Favoriten", text: "Halte die Klickfläche auf einem Foto gedrückt, um es zu den Favoriten hinzuzufügen.") }
                        else { EmptyHint(icon: "photo.on.rectangle", title: "Keine Fotos", text: LocalizedStringKey(app.timeline.error ?? "Die Mediathek auf dem Server ist leer.")) }
                    } else {
                        switch level {
                        case .years: yearGrid(groups)
                        case .months: monthGrid(groups)
                        case .days: dayList(groups)
                        case .all: allPhotos(groups)
                        }
                    }
                }
                .padding(.bottom, 80)
            }
            .onChange(of: target) { _, t in
                guard let t else { return }
                // erst rendern lassen, dann springen und fokussieren
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { proxy.scrollTo(t, anchor: .top) }
                    focused = t
                    target = nil
                }
            }
        }
        .refreshable { await app.reload() }
    }

    private var header: some View {
        HStack(spacing: 30) {
            Picker("Ansicht", selection: $level) {
                ForEach(Level.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 900)
            .accessibilityIdentifier("library-level")
            Button { favoritesOnly.toggle() } label: {
                Label(favoritesOnly ? "Nur Favoriten" : "Alle Objekte", systemImage: favoritesOnly ? "heart.fill" : "heart")
            }
            Spacer()
            if app.timeline.loading, !app.timeline.buckets.isEmpty {
                ProgressView(value: Double(app.timeline.loadedBuckets), total: Double(max(1, app.timeline.buckets.count)))
                    .frame(width: 200)
            }
            Text("\(source.count) Objekte").font(.callout).foregroundStyle(.secondary)
        }
        .focusSection()
        .padding(.bottom, 30)
    }

    // MARK: Jahre

    private func yearGrid(_ groups: [TimeGroup]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 50), count: 3), spacing: 60) {
            ForEach(groups) { g in
                Button {
                    level = .months
                    target = g.assets.first.map { monthID($0.date) }
                } label: {
                    BigCard(assetID: g.key?.id, title: g.title, subtitle: g.place)
                }
                .buttonStyle(.card)
                .focused($focused, equals: g.id)
                .id(g.id)
                .contextMenu { Button { presenter.slideshow(g.assets, title: g.title) } label: { Label("Diashow", systemImage: "play.rectangle") } }
            }
        }
    }

    // MARK: Monate

    private func monthGrid(_ groups: [TimeGroup]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 44), count: 4), spacing: 56) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        level = .days
                        target = g.assets.first.map { dayID($0.date) }
                    } label: {
                        FilledImage(id: g.key?.id ?? "", size: .preview).aspectRatio(16 / 10, contentMode: .fit)
                    }
                    .buttonStyle(.card)
                    .focused($focused, equals: g.id)
                    .contextMenu { Button { presenter.slideshow(g.assets, title: g.title) } label: { Label("Diashow", systemImage: "play.rectangle") } }
                    Text(g.title).font(.headline)
                    Text(g.place ?? String(localized: "\(g.assets.count) Objekte")).font(.caption).foregroundStyle(.secondary)
                }
                .id(g.id)
            }
        }
    }

    // MARK: Tage

    private func dayList(_ groups: [TimeGroup]) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(g.title).font(.title3.weight(.bold))
                        if let p = g.place { Text(p).font(.headline).foregroundStyle(.secondary) }
                    }
                    .padding(.top, 24)
                    DayRow(group: g, context: source, focused: $focused)
                }
                .id(g.id)
            }
        }
    }

    // MARK: Alle Fotos (nach Monaten)

    private func allPhotos(_ groups: [TimeGroup]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { g in
                SectionTitle(text: LocalizedStringKey(g.title), detail: g.place).id(g.id)
                    .padding(.bottom, 20)
                PhotoGrid(assets: g.assets, context: source)
            }
        }
    }

    private func monthID(_ d: Date) -> String {
        let c = Calendar.wall.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
    private func dayID(_ d: Date) -> String {
        let c = Calendar.wall.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Merkt sich die Gruppen (Gruppieren von 80 000 Objekten kostet ~50 ms – nicht bei jedem Neuzeichnen).
@MainActor final class GroupCache {
    private var key: (Int, LibraryView.Level, Int)?
    private var value: [TimeGroup] = []
    func groups(_ assets: [Asset], level: LibraryView.Level, generation: Int) -> [TimeGroup] {
        let k = (generation, level, assets.count)
        if let key, key == k { return value }
        let l: TimeGroup.Level = switch level { case .years: .year; case .months, .all: .month; case .days: .day }
        value = TimelineGrouping.groups(assets, level: l)
        key = k
        return value
    }
}

/// Ein Tag: Kacheln in einer Zeile (mit Fokus wischt man seitlich durch), der erste Klick öffnet das Vollbild.
private struct DayRow: View {
    let group: TimeGroup
    let context: [Asset]
    var focused: FocusState<String?>.Binding
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 30) {
                ForEach(group.assets) { a in
                    Button { presenter.open(a, in: context) } label: {
                        FilledImage(id: a.id)
                            .frame(width: a.ratio >= 1 ? 440 : 250, height: 300)
                            .overlay { TileBadges(asset: a, favorite: app.isFavorite(a)) }
                    }
                    .buttonStyle(.card)
                    .focused(focused, equals: a.id)
                    .contextMenu { AssetMenu(asset: a, list: context) }
                }
            }
            .padding(.vertical, 30)
        }
        .scrollClipDisabled()
        .focusSection()
        .onPlayPauseCommand { presenter.slideshow(group.assets, title: group.title) }
    }
}

/// Große Karte mit Titel auf dem Bild (Jahre, Rückblicke).
struct BigCard: View {
    let assetID: String?
    let title: String
    var subtitle: String? = nil
    var aspect: CGFloat = 16 / 10
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let assetID { FilledImage(id: assetID, size: .preview) } else { Rectangle().fill(.white.opacity(0.06)) }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 44, weight: .bold)).lineLimit(2)
                if let subtitle { Text(subtitle).font(.headline).opacity(0.85).lineLimit(1) }
            }
            .foregroundStyle(.white).shadow(radius: 6)
            .padding(28)
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}
