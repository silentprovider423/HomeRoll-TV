import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.loggedIn {
                MainTabs()
            } else {
                LoginView()
            }
        }
        // Ziele aus dem Top Shelf
        .fullScreenCover(item: $app.viewer) { ViewerView(request: $0) }
        .fullScreenCover(item: $app.slideshow) { SlideshowView(request: $0) }
        .fullScreenCover(item: $app.playingMemory) { MemoryPlayerView(memory: $0) }
    }
}

/// Tab-Leiste oben (tvOS 26: schwebende Glas-Leiste) – Rückblicke · Mediathek · Alben · Suchen, dazu Einstellungen.
struct MainTabs: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("Rückblicke", systemImage: "memories", value: MainTab.memories) {
                MemoriesView().presenterHost()
            }
            Tab("Mediathek", systemImage: "photo.on.rectangle", value: MainTab.library) {
                LibraryView().presenterHost()
            }
            Tab("Alben", systemImage: "rectangle.stack", value: MainTab.albums) {
                AlbumsView().presenterHost()
            }
            Tab("Suchen", systemImage: "magnifyingglass", value: MainTab.search, role: .search) {
                SearchView().presenterHost()
            }
            Tab("Einstellungen", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }
        }
    }
}
