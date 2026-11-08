import SwiftUI

/// Diashow im Vollbild: Überblenden (3 s, Apples Apple-TV-Vorlage), Magazin (mehrere Fotos je Seite) oder Ken Burns,
/// optional mit Musik, Wiederholen. Play/Pause hält an, ←/→ blättert, ↓ zeigt die Optionen, ‹ beendet.
/// Der Bildschirm bleibt an (isIdleTimerDisabled).
struct SlideshowView: View {
    let request: SlideshowRequest
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var pages: [SlidePage] = []
    @State private var index = 0
    @State private var playing = true
    @State private var showOptions = false
    @State private var pageStart = Date()
    @State private var pausedAt: Date?
    @State private var ended = false
    @State private var music = MemoryMusic()
    @FocusState private var focus: Bool

    private var options: SlideshowOptions { app.slideshowOptions }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing || options.theme != .kenBurns)) { ctx in
                if pages.indices.contains(index) {
                    let p = progress(ctx.date)
                    pageView(pages[index], progress: p)
                        .id(pages[index].id)
                        .transition(transition)
                }
            }
            .ignoresSafeArea()

            Button { togglePlay() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(BareButtonStyle())
                .focusEffectDisabled()
                .focused($focus)
                .ignoresSafeArea()
                .onMoveCommand { dir in
                    switch dir {
                    case .left: step(-1)
                    case .right: step(1)
                    case .down, .up: showOptions = true
                    @unknown default: break
                    }
                }
                .onPlayPauseCommand { togglePlay() }
                .accessibilityIdentifier("slideshow-stage")

            if !playing || ended { pausedBadge }
        }
        .animation(.easeInOut(duration: options.theme.transition), value: index)
        .onAppear { setup() }
        .onDisappear { teardown() }
        .onExitCommand { dismiss() }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { now in tick(now) }
        .sheet(isPresented: $showOptions, onDismiss: { rebuild(keeping: true) }) { SlideshowOptionsView() }
        .onChange(of: options.mood) { _, m in if playing { music.play(m) } }
    }

    private var transition: AnyTransition {
        switch options.theme {
        case .dissolve, .kenBurns: .opacity
        case .magazine: .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity))
        }
    }

    // MARK: Seiten

    @ViewBuilder private func pageView(_ page: SlidePage, progress: Double) -> some View {
        GeometryReader { geo in
            let size = geo.size
            switch page.layout {
            case .single:
                if let a = page.assets.first {
                    if options.theme == .kenBurns {
                        KenBurnsImage(id: a.id, seed: page.id, progress: progress, size: size)
                    } else if options.theme == .magazine {
                        framed(a.id, size: size.insetBy(70))
                    } else {
                        AssetImage(id: a.id, size: .preview, upgrade: .fullsize, mode: .fit).frame(width: size.width, height: size.height)
                    }
                }
            case .pair:
                HStack(spacing: 40) {
                    ForEach(page.assets) { framed($0.id, size: CGSize(width: (size.width - 180) / 2, height: size.height - 140)) }
                }
                .frame(width: size.width, height: size.height)
            case .strip:
                HStack(spacing: 30) {
                    ForEach(page.assets) { framed($0.id, size: CGSize(width: (size.width - 200) / 3, height: size.height - 160)) }
                }
                .frame(width: size.width, height: size.height)
            case .trio:
                HStack(spacing: 30) {
                    framed(page.assets[0].id, size: CGSize(width: size.width * 0.6 - 60, height: size.height - 140))
                    VStack(spacing: 30) {
                        ForEach(page.assets.dropFirst()) {
                            framed($0.id, size: CGSize(width: size.width * 0.4 - 80, height: (size.height - 170) / 2))
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
            }
        }
    }

    /// Foto mit weißem Rand und Schatten (Magazin-Stil).
    private func framed(_ id: String, size: CGSize) -> some View {
        FilledImage(id: id, size: .preview)
            .frame(width: size.width, height: size.height)
            .padding(10).background(.white)
            .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pausedBadge: some View {
        VStack(spacing: 14) {
            Image(systemName: ended ? "arrow.counterclockwise" : "pause.fill").font(.system(size: 60))
            Text(ended ? "Diashow beendet – Play zum Wiederholen" : "Angehalten – ↓ für Optionen").font(.headline)
            if !request.title.isEmpty { Text(request.title).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(40)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36))
        .allowsHitTesting(false)
    }

    // MARK: Ablauf

    private func setup() {
        focus = true
        rebuild(keeping: false)
        UIApplication.shared.isIdleTimerDisabled = true
        music.play(options.mood)
        let ids = pages.prefix(3).flatMap { $0.assets.map(\.id) }
        ImageLoader.shared.prefetch(ids, .preview)
    }

    private func teardown() {
        music.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func rebuild(keeping: Bool) {
        let currentID = pages.indices.contains(index) ? pages[index].assets.first?.id : request.startID
        pages = SlideshowPlanner.pages(request.assets, theme: options.theme, shuffle: options.shuffle, seed: UInt64(request.assets.count))
        index = SlideshowPlanner.index(of: keeping ? currentID : request.startID, in: pages)
        pageStart = Date()
        if keeping, playing { music.play(options.mood) }
    }

    private func progress(_ now: Date) -> Double {
        let t = (pausedAt ?? now).timeIntervalSince(pageStart)
        return min(1, max(0, t / (options.secondsPerSlide + options.theme.transition)))
    }

    private func tick(_ now: Date) {
        guard playing, !showOptions, !pages.isEmpty else { return }
        if now.timeIntervalSince(pageStart) >= options.secondsPerSlide + options.theme.transition { step(1) }
    }

    private func step(_ d: Int) {
        guard !pages.isEmpty else { return }
        if d > 0 {
            guard let n = SlideshowPlanner.next(index, count: pages.count, repeats: options.repeats) else {
                ended = true; playing = false; music.pause(); return
            }
            index = n
        } else {
            index = SlideshowPlanner.previous(index, count: pages.count)
        }
        pageStart = Date()
        if pausedAt != nil { pausedAt = Date() }
        let next = [index + 1, index + 2].map { $0 % pages.count }.flatMap { pages[$0].assets.map(\.id) }
        ImageLoader.shared.prefetch(next, .preview)
    }

    private func togglePlay() {
        if ended {
            ended = false; index = 0; pageStart = Date(); pausedAt = nil; playing = true; music.play(options.mood); return
        }
        playing.toggle()
        if playing {
            if let p = pausedAt { pageStart = pageStart.addingTimeInterval(Date().timeIntervalSince(p)) }
            pausedAt = nil
            music.resume()
        } else {
            pausedAt = Date()
            music.pause()
        }
    }
}

/// Ken-Burns-Bild: Zoom und Schwenk aus dem Fortschritt (friert bei Pause ein).
struct KenBurnsImage: View {
    let id: String
    let seed: Int
    let progress: Double
    let size: CGSize
    var body: some View {
        let k = KenBurns.at(seed: seed, progress: progress)
        AssetImage(id: id, size: .preview, upgrade: .fullsize)
            .frame(width: size.width, height: size.height)
            .scaleEffect(k.scale)
            .offset(x: k.dx * size.width, y: k.dy * size.height)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(0, width - 2 * d), height: max(0, height - 2 * d)) }
}

/// „Diashow-Optionen“ – Thema, Musik, Wiederholen, Zufällig, Dauer je Foto.
struct SlideshowOptionsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Thema") {
                    Picker("Thema", selection: $app.slideshowOptions.theme) {
                        ForEach(SlideshowTheme.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Musik") {
                    Picker("Musik", selection: $app.slideshowOptions.mood) {
                        ForEach(MemoryMood.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                }
                Section {
                    Toggle("Wiederholen", isOn: $app.slideshowOptions.repeats)
                    Toggle("Zufällige Reihenfolge", isOn: $app.slideshowOptions.shuffle)
                    Picker("Dauer je Foto", selection: $app.slideshowOptions.secondsPerSlide) {
                        ForEach([3.0, 5, 8, 12, 20], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                }
            }
            .navigationTitle("Diashow-Optionen")
        }
    }
}
