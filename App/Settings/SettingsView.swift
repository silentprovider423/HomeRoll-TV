import SwiftUI

/// Konto, Diashow-Optionen, Top Shelf, Zwischenspeicher, Abmelden.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmLogout = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Konto") {
                    LabeledContent("Server", value: app.client.baseURL?.host() ?? "–")
                    if let n = app.userName { LabeledContent("Angemeldet als", value: n) }
                    LabeledContent("Zugang", value: {
                        if case .apiKey? = app.client.account?.credential { return String(localized: "API-Schlüssel") }
                        return String(localized: "Sitzung")
                    }())
                    LabeledContent("Objekte", value: "\(app.timeline.assets.count)")
                }
                Section("Diashow-Optionen") {
                    Picker("Thema", selection: $app.slideshowOptions.theme) {
                        ForEach(SlideshowTheme.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Musik", selection: $app.slideshowOptions.mood) {
                        ForEach(MemoryMood.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Wiederholen", isOn: $app.slideshowOptions.repeats)
                    Toggle("Zufällige Reihenfolge", isOn: $app.slideshowOptions.shuffle)
                    Picker("Dauer je Foto", selection: $app.slideshowOptions.secondsPerSlide) {
                        ForEach([3.0, 5, 8, 12, 20], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                }
                Section {
                    Picker("Darstellung", selection: $app.topShelfStyle) {
                        Text("Karussell").tag(TopShelfSnapshot.Style.carousel)
                        Text("Reihen").tag(TopShelfSnapshot.Style.sections)
                    }
                    Button("Top Shelf jetzt aktualisieren") { app.refreshTopShelf(force: true) }
                    if let u = app.topShelfUpdated {
                        LabeledContent("Zuletzt", value: u.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: { Text("Top Shelf") } footer: {
                    Text("Liegt HomeRoll TV in der obersten Reihe des Home-Bildschirms, zeigt der Top Shelf Rückblicke und empfohlene Fotos.")
                }
                Section {
                    Button("Neu laden") { Task { await app.reload() } }
                    Button("Zwischenspeicher leeren") { app.clearCaches() }
                    Button("Abmelden", role: .destructive) { confirmLogout = true }
                        .accessibilityIdentifier("logout")
                } footer: {
                    Text("HomeRoll TV \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · nur Ansehen – auf dem Fernseher wird nichts gelöscht oder hochgeladen.")
                }
            }
            .frame(maxWidth: 1300)
            .confirmationDialog("Abmelden?", isPresented: $confirmLogout) {
                Button("Abmelden", role: .destructive) { app.logout() }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }
}
