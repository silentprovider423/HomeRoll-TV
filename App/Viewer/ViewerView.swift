import AVKit
import SwiftUI

/// Vollbild (Apples „OneUp“ auf dem Apple TV): ←/→ blättern, ↓ Infos, ↑ Miniaturleiste, Klick spielt Live Photo
/// bzw. öffnet das Video, Play/Pause startet die Diashow ab hier, Klick halten = Kontextmenü, ‹ = zurück.
struct ViewerView: View {
    let request: ViewerRequest
    var onClose: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showInfo = false
    @State private var showStrip = false
    @State private var showChrome = true
    @State private var playLive = false
    @State private var video: Asset?
    @State private var slideshow: SlideshowRequest?
    @State private var favorite = false
    @State private var direction: Edge = .trailing
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case stage, strip(String) }

    private var assets: [Asset] { request.assets }
    private var current: Asset? { assets.indices.contains(index) ? assets[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let a = current {
                page(a)
                    .id(a.id)
                    .transition(.asymmetric(insertion: .move(edge: direction).combined(with: .opacity),
                                            removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)))
                    .ignoresSafeArea()
            }
            stage
            if showChrome, !showInfo, let a = current { chrome(a).transition(.opacity) }
            if showInfo, let a = current {
                InfoPanel(asset: a).transition(.move(edge: .top).combined(with: .opacity))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            if showStrip { strip.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.35), value: index)
        .animation(.easeInOut(duration: 0.3), value: showInfo)
        .animation(.easeInOut(duration: 0.3), value: showStrip)
        .onAppear {
            index = min(max(0, request.start), max(0, assets.count - 1))
            focus = .stage
            refreshFavorite()
            prefetch()
            hideChromeSoon()
        }
        .onChange(of: index) { _, _ in playLive = false; refreshFavorite(); prefetch() }
        .onChange(of: focus) { _, f in
            // Fokus zurück auf das Bild (nach oben aus der Leiste gewischt) → Leiste schließen
            if f == .stage, showStrip { showStrip = false }
            if case .strip(let id) = f, let i = assets.firstIndex(where: { $0.id == id }) { go(i) }
        }
        .onExitCommand {
            if showInfo { showInfo = false } else if showStrip { showStrip = false; focus = .stage } else { close() }
        }
        .fullScreenCover(item: $video) { VideoPlayerView(asset: $0) }
        .fullScreenCover(item: $slideshow) { SlideshowView(request: $0) }
    }

    // MARK: Bild

    @ViewBuilder private func page(_ a: Asset) -> some View {
        ZStack {
            AssetImage(id: a.id, size: .preview, upgrade: a.isImage ? .fullsize : nil, mode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if a.isLivePhoto, playLive, let vid = a.livePhotoVideoId {
                LoopingVideo(assetID: vid, loop: false) { playLive = false }
                    .aspectRatio(a.ratio, contentMode: .fit)
                    .transition(.opacity)
            }
            if a.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: 120)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white).shadow(radius: 20)
            }
        }
    }

    /// Unsichtbare Bühne, die den Fokus hält und die Fernbedienung auswertet.
    private var stage: some View {
        Button {
            guard let a = current else { return }
            if a.isVideo { video = a }
            else if a.isLivePhoto { playLive.toggle() }
            else { withAnimation { showChrome.toggle() } }
        } label: {
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(BareButtonStyle())
        .focused($focus, equals: .stage)
        .focusEffectDisabled()
        .ignoresSafeArea()
        .onMoveCommand { dir in
            switch dir {
            case .left: go(index - 1)
            case .right: go(index + 1)
            case .down:
                if showStrip { showStrip = false } else { showInfo.toggle() }
            case .up:
                if showInfo { showInfo = false }
                else if let a = current {
                    showStrip = true
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(60)); focus = .strip(a.id) }
                }
            @unknown default: break
            }
        }
        .onPlayPauseCommand {
            guard let a = current else { return }
            slideshow = SlideshowRequest(assets: assets, startID: a.id)
        }
        .contextMenu {
            if let a = current {
                Button { Task { favorite = await app.toggleFavorite(a) } } label: {
                    Label(favorite ? "Nicht mehr Favorit" : "Als Favorit sichern", systemImage: favorite ? "heart.slash" : "heart")
                }
                Button { slideshow = SlideshowRequest(assets: assets, startID: a.id) } label: {
                    Label("Diashow ab hier", systemImage: "play.rectangle")
                }
                Button { showInfo = true } label: { Label("Infos", systemImage: "info.circle") }
                if a.isLivePhoto {
                    Button { playLive = true } label: { Label("Live Photo abspielen", systemImage: "livephoto.play") }
                }
            }
        }
        .accessibilityIdentifier("viewer-stage")
    }

    /// Datum/Ort oben links, blendet nach ein paar Sekunden aus (wie Apple).
    private func chrome(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text(Fmt.relativeDay(a.date)).font(.title3.weight(.bold))
                if favorite { Image(systemName: "heart.fill") }
                if a.isLivePhoto { Image(systemName: "livephoto") }
            }
            Text([a.city, Fmt.time.string(from: a.date)].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 30).padding(.vertical, 18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(50)
        .allowsHitTesting(false)
    }

    // MARK: Miniaturleiste

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 20) {
                    ForEach(assets) { a in
                        Button {
                            showStrip = false; focus = .stage
                        } label: {
                            FilledImage(id: a.id).frame(width: 180, height: 180)
                        }
                        .buttonStyle(.card)
                        .focused($focus, equals: .strip(a.id))
                        .id(a.id)
                    }
                }
                .padding(.horizontal, 80).padding(.vertical, 30)
            }
            .scrollClipDisabled()
            .onAppear { if let a = current { proxy.scrollTo(a.id, anchor: .center) } }
        }
        .frame(height: 260)
        .glassEffect(.regular, in: Rectangle())
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
        .focusSection()
    }

    // MARK: Ablauf

    private func go(_ i: Int) {
        guard i != index, assets.indices.contains(i) else { return }
        direction = i > index ? .trailing : .leading
        index = i
    }

    private func close() {
        if let a = current { onClose?(a.id) }
        dismiss()
    }

    private func refreshFavorite() { favorite = current.map(app.isFavorite) ?? false }

    private func prefetch() {
        let ids = [index - 1, index + 1, index + 2].filter(assets.indices.contains).map { assets[$0].id }
        ImageLoader.shared.prefetch(ids, .preview)
        // Live Photos spielen kurz beim Hinblättern (wie iOS) – hier nur auf Klick, Vorladen reicht
    }

    private func hideChromeSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showChrome = false }
        }
    }
}

/// Bewegung eines Live Photos bzw. kurzer Videoausschnitt (stumm bis auf Live Photos, wie bei Apple mit Ton).
struct LoopingVideo: UIViewRepresentable {
    let assetID: String
    var loop = true
    var muted = false
    var onEnd: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        guard let url = ImmichClient.shared.videoURL(assetID) else { return v }
        let item = AVPlayerItem(asset: ImmichClient.shared.avAsset(url))
        let p = AVQueuePlayer(playerItem: item)
        p.isMuted = muted
        if loop { context.coordinator.looper = AVPlayerLooper(player: p, templateItem: item) }
        else {
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                MainActor.assumeIsolated { onEnd?() }
            }
        }
        v.playerLayer.player = p
        v.playerLayer.videoGravity = .resizeAspect
        p.play()
        return v
    }
    func updateUIView(_ v: PlayerUIView, context: Context) {}
    static func dismantleUIView(_ v: PlayerUIView, coordinator: Coordinator) {
        v.playerLayer.player?.pause()
        if let o = coordinator.observer { NotificationCenter.default.removeObserver(o) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var looper: AVPlayerLooper?; var observer: NSObjectProtocol? }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Video im Vollbild mit der tvOS-Transportleiste (Klickrand ±10 s, Wischen = Spulen, ‹ = zurück).
struct VideoPlayerView: UIViewControllerRepresentable {
    let asset: Asset

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer()
        vc.player = player
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = Fmt.dayLongMonthYear.string(from: asset.date) as NSString
        title.extendedLanguageTag = "und"
        let id = asset.id
        Task { @MainActor in
            let client = ImmichClient.shared
            var item: AVPlayerItem?
            if let url = client.videoURL(id) {
                let a = client.avAsset(url)
                if (try? await a.load(.isPlayable)) == true { item = AVPlayerItem(asset: a) }
            }
            if item == nil, let fb = await client.playableFallback(for: id) { item = AVPlayerItem(asset: fb) }
            guard let item else { return }
            item.externalMetadata = [title]
            player.replaceCurrentItem(with: item)
            player.play()
        }
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) { vc.player?.pause() }
}
