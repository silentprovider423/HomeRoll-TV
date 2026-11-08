import AVFoundation
import SwiftUI

/// Rückblick-Player im Vollbild (16:9). Zeitleiste aus Szenen im Takt der Musik, Ken Burns, Titelkarte.
/// Fernbedienung: Play/Pause hält an, ←/→ Szene vor/zurück, ↓ oder Klick = Info-Leiste (Mix, Musik, Ton, Favorit,
/// Endlosschleife), ‹ schließt. Am Ende „Als Nächstes ansehen“ mit Countdown und „Wiederholen“ (Apples PXStoryTV…).
struct MemoryPlayerView: View {
    let memory: Memory
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var current: Memory?
    @State private var scenes: [StoryScene] = []
    @State private var clock = StoryClock()
    @State private var mix = MemoryMix.all[0]
    @State private var muted = false
    @State private var loop = false
    @State private var panel = false
    @State private var ended = false
    @State private var countdown = 8
    @State private var music = MemoryMusic()
    @State private var videos = StoryVideos()
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case stage, panel, next, replay }

    private var m: Memory { current ?? memory }
    private var total: Double { StoryTimeline.total(scenes) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                TimelineView(.animation(paused: !clock.playing)) { ctx in
                    stage(t: clock.time(ctx.date), size: geo.size)
                }
                .memoryStyle(mix.style)

                Button { togglePanel() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                    .buttonStyle(BareButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .stage)
                    .disabled(ended)
                    .onMoveCommand { dir in
                        switch dir {
                        case .left: skip(-1)
                        case .right: skip(1)
                        case .down: openPanel()
                        default: break
                        }
                    }
                    .accessibilityIdentifier("memory-stage")

                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    progressBar(t: clock.time(ctx.date)).frame(maxHeight: .infinity, alignment: .top)
                }
                .opacity(panel || !clock.playing ? 1 : 0.0)
                .allowsHitTesting(false)

                if panel && !ended { infoPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
                if ended { endOverlay(size: geo.size).transition(.opacity) }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: panel)
        .animation(.easeInOut(duration: 0.4), value: ended)
        .onPlayPauseCommand { ended ? restart() : (clock.playing ? pause() : resume()) }
        .onExitCommand {
            if panel { panel = false; focus = .stage } else { close() }
        }
        .onAppear { start(memory) }
        .onDisappear { music.stop(); videos.stop(); UIApplication.shared.isIdleTimerDisabled = false }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in tick() }
        .onChange(of: focus) { _, f in if f == .stage, panel { panel = false } }
    }

    // MARK: Bühne

    @ViewBuilder private func stage(t: Double, size: CGSize) -> some View {
        let i = StoryTimeline.index(at: t, in: scenes)
        ZStack {
            if scenes.indices.contains(i) {
                let s = scenes[i]
                // vorige Szene bleibt darunter, bis die neue ganz eingeblendet ist (keine schwarze Lücke)
                if i > 0, t - s.start < StoryTimeline.fade { sceneView(scenes[i - 1], t: t, size: size) }
                let f = min(1, (t - s.start) / StoryTimeline.fade)
                sceneView(s, t: t, size: size)
                    .opacity(s.transition == .push ? 1 : f)
                    .offset(x: s.transition == .push ? (1 - ease(f)) * size.width : 0)
                    .scaleEffect(s.transition == .zoom ? 1.12 - 0.12 * ease(f) : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    @ViewBuilder private func sceneView(_ s: StoryScene, t: Double, size: CGSize) -> some View {
        let p = max(0, min(1, (t - s.start) / (s.duration + StoryTimeline.fade)))
        switch s.kind {
        case .title:
            ZStack(alignment: .bottomLeading) {
                KenBurnsImage(id: m.key.id, seed: 98, progress: p, size: size)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                let a = min(1, max(0, (t - 0.3) / 0.9))
                VStack(alignment: .leading, spacing: 10) {
                    Text(m.title).font(.system(size: 86, weight: .bold)).lineLimit(2)
                    Text(m.subtitle).font(.system(size: 30, weight: .semibold)).opacity(0.85)
                }
                .foregroundStyle(.white).shadow(radius: 14)
                .opacity(a).scaleEffect(1.06 - 0.06 * a, anchor: .bottomLeading)
                .padding(.horizontal, 110).padding(.bottom, 110)
            }
        case .one(let a):
            KenBurnsImage(id: a.id, seed: s.id, progress: p, size: size)
        case .two(let a, let b):
            HStack(spacing: 6) {
                KenBurnsImage(id: a.id, seed: s.id, progress: p, size: CGSize(width: (size.width - 6) / 2, height: size.height))
                KenBurnsImage(id: b.id, seed: s.id + 1, progress: p, size: CGSize(width: (size.width - 6) / 2, height: size.height))
            }
        case .three(let a, let b, let c):
            HStack(spacing: 6) {
                let w = (size.width - 12) / 3
                KenBurnsImage(id: a.id, seed: s.id, progress: p, size: CGSize(width: w, height: size.height))
                KenBurnsImage(id: b.id, seed: s.id + 1, progress: p, size: CGSize(width: w, height: size.height))
                KenBurnsImage(id: c.id, seed: s.id + 2, progress: p, size: CGSize(width: w, height: size.height))
            }
        case .video(let a):
            ZStack {
                KenBurnsImage(id: a.id, seed: s.id, progress: 0, size: size)
                if let player = videos.player(a) { PlayerSurface(player: player) }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// Dünne Fortschrittsleiste je Szene (wie die Sprungleiste bei Apple).
    private func progressBar(t: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: total > 0 ? g.size.width * min(1, t / total) : 0)
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 110).padding(.top, 60)
    }

    // MARK: Info-Leiste

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.title).font(.title3.weight(.bold))
                Text("\(m.subtitle) · \(mix.title)").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 26) {
                Button { clock.playing ? pause() : resume() } label: {
                    Label(clock.playing ? "Anhalten" : "Wiedergabe", systemImage: clock.playing ? "pause.fill" : "play.fill")
                }
                .focused($focus, equals: .panel)
                Menu {
                    ForEach(Array(MemoryMix.all.enumerated()), id: \.offset) { i, x in
                        Button(x.title) { setMix(i) }
                    }
                } label: { Label("Rückblick-Mixe", systemImage: "wand.and.stars") }
                Menu {
                    ForEach(MemoryMood.allCases) { mood in
                        Button { setMood(mood) } label: { Label(mood.title, systemImage: mood.icon) }
                    }
                } label: { Label("Musik", systemImage: "music.note") }
                Button { muted.toggle(); music.muted = muted } label: {
                    Label(muted ? "Ton an" : "Ton aus", systemImage: muted ? "speaker.wave.2" : "speaker.slash")
                }
                Button { app.memories.toggleFavorite(m, client: app.client) } label: {
                    let fav = app.memories.isFavorite(m)
                    Label(fav ? "Favorit" : "Favorisieren", systemImage: fav ? "heart.fill" : "heart")
                }
                Button { loop.toggle() } label: {
                    Label("Endlosschleife", systemImage: loop ? "repeat.circle.fill" : "repeat")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, 80).padding(.bottom, 60)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("memory-panel")
    }

    // MARK: Ende

    private func endOverlay(size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 40) {
                if let next = app.memories.next(after: m) {
                    Text("Als Nächstes ansehen").font(.title2.weight(.bold))
                    Button { playNext() } label: {
                        BigCard(assetID: next.key.id, title: next.title, subtitle: next.subtitle).frame(width: 760)
                    }
                    .buttonStyle(.card)
                    .focused($focus, equals: .next)
                    .accessibilityIdentifier("memory-next")
                    Text("Startet in \(countdown) s").font(.headline).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 30) {
                    Button { restart() } label: { Label("Wiederholen", systemImage: "arrow.counterclockwise") }
                        .focused($focus, equals: .replay)
                    Button { close() } label: { Label("Schließen", systemImage: "xmark") }
                }
            }
        }
        .focusSection()
    }

    // MARK: Ablauf

    private func start(_ memory: Memory) {
        current = memory
        mix = MemoryMix.all[app.memories.prefs.mix[memory.id] ?? (memory.id.utf8.reduce(0) { $0 &+ Int($1) } % 2 == 0 ? 0 : 4)]
        scenes = StoryTimeline.build(memory.assets, mood: mix.mood)
        ended = false; panel = false; countdown = 8
        clock = StoryClock()
        clock.play()
        music.play(mix.mood); music.muted = muted
        UIApplication.shared.isIdleTimerDisabled = true
        focus = .stage
        preload(from: 0)
    }

    private func tick() {
        let t = clock.time()
        if ended { return }
        if total > 0, t >= total {
            if loop { clock.seek(0); return }
            finish(); return
        }
        let i = StoryTimeline.index(at: t, in: scenes)
        if scenes.indices.contains(i), case .video(let a) = scenes[i].kind {
            videos.sync(current: a, timeInScene: t - scenes[i].start, playing: clock.playing)
        } else { videos.sync(current: nil, timeInScene: 0, playing: false) }
        preload(from: i + 1)
    }

    private func preload(from i: Int) {
        let ids = scenes.dropFirst(max(0, i)).prefix(2).flatMap { $0.assets.map(\.id) }
        ImageLoader.shared.prefetch(ids, .preview)
    }

    private func skip(_ d: Int) {
        guard !scenes.isEmpty else { return }
        let i = StoryTimeline.index(at: clock.time(), in: scenes)
        let j = min(max(0, i + d), scenes.count - 1)
        clock.seek(scenes[j].start)
    }

    private func pause() { clock.pause(); music.pause(); videos.sync(current: nil, timeInScene: 0, playing: false) }
    private func resume() { clock.play(); music.resume() }

    private func togglePanel() { panel ? (panel = false) : openPanel() }
    private func openPanel() {
        panel = true
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(50)); focus = .panel }
    }

    private func restart() {
        ended = false; countdown = 8
        clock.seek(0); clock.play(); music.play(mix.mood); music.muted = muted
        focus = .stage
    }

    private func finish() {
        clock.pause(); music.pause(); videos.stop()
        ended = true
        focus = app.memories.next(after: m) != nil ? .next : .replay
        countdown = 8
        Task { @MainActor in
            while ended, countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard ended else { return }
                countdown -= 1
            }
            if ended, app.memories.next(after: m) != nil { playNext() }
        }
    }

    private func playNext() {
        guard let next = app.memories.next(after: m) else { return }
        music.stop(); videos.stop()
        start(next)
    }

    private func setMix(_ i: Int) {
        mix = MemoryMix.all[i]
        app.memories.update { $0.mix[m.id] = i }
        rebuildKeepingTime()
    }

    private func setMood(_ mood: MemoryMood) {
        mix = MemoryMix(mood: mood, style: mix.style)
        rebuildKeepingTime()
    }

    private func rebuildKeepingTime() {
        let t = clock.time(), old = total
        scenes = StoryTimeline.build(m.assets, mood: mix.mood)
        clock.seek(old > 0 ? t / old * total : 0)
        if clock.playing { music.play(mix.mood); music.muted = muted }
    }

    private func close() {
        music.stop(); videos.stop()
        dismiss()
        app.playingMemory = nil
    }
}

/// Videos der Szenen (stumm wie bei Apple; die Musik läuft weiter).
@MainActor
final class StoryVideos {
    private var players: [String: AVPlayer] = [:]
    func player(_ a: Asset) -> AVPlayer? {
        if let p = players[a.id] { return p }
        guard let url = ImmichClient.shared.videoURL(a.id) else { return nil }
        let p = AVPlayer(playerItem: AVPlayerItem(asset: ImmichClient.shared.avAsset(url)))
        p.isMuted = true; p.automaticallyWaitsToMinimizeStalling = false
        players[a.id] = p
        return p
    }
    /// Nur das Video der aktuellen Szene läuft, im Gleichschritt mit der Uhr.
    func sync(current: Asset?, timeInScene: Double, playing: Bool) {
        for (id, p) in players where id != current?.id { p.pause() }
        guard let a = current, let p = player(a) else { return }
        if abs(p.currentTime().seconds - timeInScene) > 0.6 {
            p.seek(to: CMTime(seconds: timeInScene, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playing { if p.rate == 0 { p.play() } } else { p.pause() }
    }
    func stop() { players.values.forEach { $0.pause() }; players = [:] }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView(); v.playerLayer.player = player; v.playerLayer.videoGravity = .resizeAspect; return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) { v.playerLayer.player = player }
}

extension View {
    /// Farbstil eines Rückblick-Mixes.
    @ViewBuilder func memoryStyle(_ s: MemoryStyle) -> some View {
        switch s {
        case .natural: self
        case .warm: self.saturation(1.08).colorMultiply(Color(red: 1, green: 0.93, blue: 0.84))
        case .cool: self.saturation(0.95).colorMultiply(Color(red: 0.86, green: 0.94, blue: 1))
        case .vivid: self.saturation(1.35).contrast(1.06)
        case .contrast: self.contrast(1.3).saturation(0.9)
        case .mono: self.grayscale(1).contrast(1.15)
        }
    }
}
