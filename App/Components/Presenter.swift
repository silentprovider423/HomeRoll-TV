import SwiftUI

/// Öffnet Vollbild, Diashow und Rückblick-Player für einen Bildschirm (ein Ort für alle Vollbild-Ebenen) und merkt
/// sich, welches Foto zuletzt zu sehen war – das Raster setzt den Fokus beim Zurückkommen dorthin (wie Apple).
@MainActor @Observable
final class Presenter {
    var viewer: ViewerRequest?
    var slideshow: SlideshowRequest?
    var memory: Memory?
    var returnedID: String?

    func open(_ a: Asset, in list: [Asset]) {
        viewer = ViewerRequest(assets: list, start: list.firstIndex(where: { $0.id == a.id }) ?? 0)
    }
    func slideshow(_ list: [Asset], from id: String? = nil, title: String = "") {
        guard !list.isEmpty else { return }
        slideshow = SlideshowRequest(assets: list, startID: id, title: title)
    }
}

private struct PresenterHost: ViewModifier {
    @State private var presenter = Presenter()
    func body(content: Content) -> some View {
        @Bindable var p = presenter
        content
            .environment(presenter)
            .fullScreenCover(item: $p.viewer) { req in
                ViewerView(request: req) { presenter.returnedID = $0 }
            }
            .fullScreenCover(item: $p.slideshow) { SlideshowView(request: $0) }
            .fullScreenCover(item: $p.memory) { MemoryPlayerView(memory: $0) }
    }
}

extension View {
    func presenterHost() -> some View { modifier(PresenterHost()) }
}

/// Fokus-Raster mit quadratischen Kacheln (Apples Mediathek-Raster auf dem Fernseher). Klick öffnet das Vollbild,
/// Play/Pause startet die Diashow ab der fokussierten Kachel, Klick halten öffnet das Kontextmenü.
struct PhotoGrid: View {
    let assets: [Asset]
    /// Wohin das Vollbild blättern darf (Standard: dieselben Fotos)
    var context: [Asset]? = nil
    var columns = 6
    var title: String = ""
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter
    @FocusState private var focused: String?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 36), count: columns), spacing: 36) {
            ForEach(assets) { a in
                Button { presenter.open(a, in: context ?? assets) } label: {
                    FilledImage(id: a.id)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { TileBadges(asset: a, favorite: app.isFavorite(a)) }
                }
                .buttonStyle(.card)
                .focused($focused, equals: a.id)
                .contextMenu { AssetMenu(asset: a, list: context ?? assets, title: title) }
                .accessibilityLabel(Text(Fmt.dayLongMonthYear.string(from: a.date)))
                .accessibilityIdentifier("tile-\(a.id)")
            }
        }
        .onPlayPauseCommand { presenter.slideshow(context ?? assets, from: focused, title: title) }
        .onChange(of: presenter.returnedID) { _, id in
            if let id, assets.contains(where: { $0.id == id }) { focused = id }
        }
    }
}

/// Kontextmenü an Foto-Kacheln und im Vollbild.
struct AssetMenu: View {
    let asset: Asset
    let list: [Asset]
    var title: String = ""
    @Environment(AppModel.self) private var app
    @Environment(Presenter.self) private var presenter

    var body: some View {
        let fav = app.isFavorite(asset)
        Button { Task { _ = await app.toggleFavorite(asset) } } label: {
            Label(fav ? "Nicht mehr Favorit" : "Als Favorit sichern", systemImage: fav ? "heart.slash" : "heart")
        }
        Button { presenter.slideshow(list, from: asset.id, title: title) } label: {
            Label("Diashow ab hier", systemImage: "play.rectangle")
        }
    }
}
