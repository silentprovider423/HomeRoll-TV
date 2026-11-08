import SwiftUI

/// Suchen: Bildschirmtastatur oben (Diktat per Siri-Taste macht das System), darunter Treffer als Fokus-Raster.
/// Ohne Eingabe: Vorschläge (Personen, Orte, Kategorien). Freitext geht an die KI-Suche des Servers,
/// erkannte Orte/Personen/Jahre werden zu Filtern.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var results: [Asset] = []
    @State private var searching = false
    @State private var error: String?
    @State private var cities: [String] = []
    @State private var people: [PersonDTO] = []
    @State private var labels: [String] = []

    private static let ideas = ["Strand", "Sonnenuntergang", "Berge", "Essen", "Hund", "Katze", "Schnee", "Stadt", "Auto", "Blumen"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        suggestions
                    } else if searching && results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(100)
                    } else if let error {
                        EmptyHint(icon: "exclamationmark.triangle", title: "Suche fehlgeschlagen", text: LocalizedStringKey(error))
                    } else if results.isEmpty {
                        EmptyHint(icon: "magnifyingglass", title: "Keine Ergebnisse", text: "Versuche andere Begriffe, einen Ort oder ein Jahr.")
                    } else {
                        SectionTitle(text: "Ergebnisse", detail: ([String(results.count)] + labels).joined(separator: " · "))
                            .padding(.bottom, 24)
                        PhotoGrid(assets: results, title: query)
                    }
                }
                .padding(.bottom, 80)
            }
            .navigationDestination(for: Collection.self) { CollectionView(collection: $0) }
        }
        .searchable(text: $query, prompt: Text("Fotos, Personen, Orte …"))
        .searchSuggestions {
            ForEach(matches, id: \.self) { s in Text(s).searchCompletion(s) }
        }
        .task(id: query) {
            // Tippen auf der Fernbedienung ist langsam – kurz warten, dann suchen
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await run(query)
        }
        .task {
            cities = (try? await app.client.suggestions("city")) ?? []
            people = ((try? await app.client.people()) ?? []).filter { !$0.name.isEmpty }
        }
    }

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return (people.map(\.name) + cities).filter { $0.localizedCaseInsensitiveContains(q) }.prefix(6).map { $0 }
    }

    // MARK: Vorschläge

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !people.isEmpty {
                SectionTitle(text: "Personen")
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 44) {
                        ForEach(people) { p in
                            NavigationLink(value: Collection.person(p)) {
                                VStack(spacing: 14) {
                                    PersonImage(id: p.id).frame(width: 180, height: 180)
                                    Text(p.name).font(.callout).lineLimit(1)
                                }
                                .frame(width: 200)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            if !cities.isEmpty {
                SectionTitle(text: "Orte")
                chips(Array(cities.prefix(16)), icon: "mappin.and.ellipse")
            }
            SectionTitle(text: "Kategorien")
            chips([String(localized: "Videos"), String(localized: "Live Photos"), String(localized: "Favoriten")] + Self.ideas.map { L($0) },
                  icon: "sparkle.magnifyingglass")
        }
    }

    private func chips(_ words: [String], icon: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 30), count: 4), spacing: 30) {
            ForEach(words, id: \.self) { w in
                Button { query = w } label: {
                    Label(w, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 20)
        .focusSection()
    }

    // MARK: Suche

    private func run(_ q: String) async {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { results = []; labels = []; error = nil; return }
        searching = true; error = nil
        defer { searching = false }
        let plan = SearchPlan.make(text, cities: cities, people: people)
        labels = plan.labels
        do {
            let found: [AssetDTO] = plan.freeText.isEmpty
                ? try await app.client.search(filter: plan.filter, size: 500)
                : try await app.client.smartSearch(plan.freeText, filter: plan.filter, size: 200)
            guard q == query else { return }
            results = found.map(\.asset)
        } catch {
            guard q == query else { return }
            self.error = error.localizedDescription
            results = []
        }
    }
}

/// Übersetzt einen Text, der erst zur Laufzeit feststeht. Fehlt die Übersetzung, bleibt er, wie er ist.
func L(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }
