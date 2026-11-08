import SwiftUI

/// Rückblicke (Startseite): großes Band mit dem wichtigsten Rückblick, darunter alle als Kacheln.
/// Klick spielt ab, Klick halten öffnet Favorit / Weniger solche / Löschen.
struct MemoriesView: View {
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter
    @AppStorage("memoriesFavoritesOnly") private var favoritesOnly = false

    private var items: [Memory] { favoritesOnly ? app.memories.favorites : app.memories.items }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker("Filter", selection: $favoritesOnly) {
                        Text("Alle Rückblicke").tag(false)
                        Text("Favoriten").tag(true)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 700)
                    Spacer()
                }
                .focusSection()
                .padding(.bottom, 30)

                if items.isEmpty {
                    if app.timeline.loading || (app.timeline.assets.isEmpty && app.timeline.error == nil) {
                        VStack(spacing: 20) {
                            ProgressView()
                            Text("Rückblicke werden zusammengestellt …").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 200)
                    } else if favoritesOnly {
                        EmptyHint(icon: "heart", title: "Keine Lieblingsrückblicke", text: "Halte die Klickfläche auf einem Rückblick gedrückt und wähle „Zu Rückblickfavoriten hinzufügen“.")
                    } else {
                        EmptyHint(icon: "memories", title: "Noch keine Rückblicke", text: "Rückblicke entstehen aus Reisen, Jahren und Tagen wie heute in früheren Jahren.")
                    }
                } else {
                    if let first = items.first {
                        Button { presenter.memory = first } label: {
                            BigCard(assetID: first.key.id, title: first.title, subtitle: first.subtitle, aspect: 21 / 9)
                        }
                        .buttonStyle(.card)
                        .contextMenu { MemoryMenu(memory: first) }
                        .accessibilityIdentifier("memory-hero")
                    }
                    if items.count > 1 {
                        SectionTitle(text: "Für dich").padding(.bottom, 24)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 50), count: 3), spacing: 60) {
                            ForEach(items.dropFirst()) { m in
                                Button { presenter.memory = m } label: {
                                    BigCard(assetID: m.key.id, title: m.title, subtitle: m.subtitle)
                                        .overlay(alignment: .topTrailing) {
                                            if app.memories.isFavorite(m) {
                                                Image(systemName: "heart.fill").font(.title3).padding(22).shadow(radius: 4)
                                            }
                                        }
                                }
                                .buttonStyle(.card)
                                .contextMenu { MemoryMenu(memory: m) }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
    }
}

/// Kontextmenü eines Rückblicks (Apples InteractiveMemoryActionMenu…).
struct MemoryMenu: View {
    let memory: Memory
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter

    var body: some View {
        Button { presenter.memory = memory } label: { Label("Abspielen", systemImage: "play.fill") }
        Button { presenter.slideshow(memory.assets, title: memory.title) } label: { Label("Diashow", systemImage: "play.rectangle") }
        let fav = app.memories.isFavorite(memory)
        Button { app.memories.toggleFavorite(memory, client: app.client) } label: {
            Label(fav ? "Aus Rückblickfavoriten entfernen" : "Zu Rückblickfavoriten hinzufügen", systemImage: fav ? "heart.slash" : "heart")
        }
        if let place = memory.place {
            Button { app.memories.update { $0.lessPlaces.insert(place) } } label: {
                Label("Weniger Rückblicke wie diesen zeigen", systemImage: "hand.thumbsdown")
            }
        }
        Button(role: .destructive) { app.memories.update { $0.deleted.insert(memory.id) } } label: {
            Label("Rückblick löschen", systemImage: "trash")
        }
    }
}
