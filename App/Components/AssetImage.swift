import SwiftUI

/// Bild vom Server: sofort der unscharfe ThumbHash, dann die Vorschau (und auf Wunsch danach die volle Größe).
struct AssetImage: View {
    let id: String
    var size: ImmichClient.Size = .thumbnail
    var upgrade: ImmichClient.Size? = nil
    var mode: ContentMode = .fill

    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: mode)
            } else if let ph = ImageLoader.shared.placeholder(id) {
                Image(decorative: ph, scale: 1).resizable().aspectRatio(contentMode: mode)
            } else {
                Rectangle().fill(.white.opacity(0.06))
            }
        }
        .task(id: id) {
            if shownID != id { image = ImageLoader.shared.cached(id, upgrade ?? size) ?? ImageLoader.shared.cached(id, size) }
            shownID = id
            if image == nil, let i = await ImageLoader.shared.load(id, size), !Task.isCancelled { image = i }
            if let upgrade, let i = await ImageLoader.shared.load(id, upgrade), !Task.isCancelled { image = i }
        }
    }
}

/// Füllt den vorgegebenen Rahmen und schneidet ab (Kacheln, Karten).
struct FilledImage: View {
    let id: String
    var size: ImmichClient.Size = .thumbnail
    var body: some View {
        Color.clear
            .overlay { AssetImage(id: id, size: size) }
            .clipped()
    }
}

/// Personenbild (rund).
struct PersonImage: View {
    let id: String
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "person.fill").font(.system(size: 60)).foregroundStyle(.secondary) }
        }
        .clipShape(Circle())
        .task(id: id) {
            guard image == nil, let url = ImmichClient.shared.personThumbURL(id),
                  let d = try? await ImmichClient.shared.data(url) else { return }
            image = await Task.detached { ImageLoader.decode(d, maxPixel: 400) }.value
        }
    }
}

/// Knopf ohne eigenen Fokus-Effekt (Vollbild-Bühnen, die selbst reagieren).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Kleine Abzeichen auf Kacheln (Video-Dauer, Live, Favorit).
struct TileBadges: View {
    let asset: Asset
    var favorite: Bool
    var body: some View {
        ZStack {
            if asset.isVideo {
                Text(Fmt.duration(asset.durationMs)).font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
            } else if asset.isLivePhoto {
                Image(systemName: "livephoto").font(.caption).shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            }
            if favorite {
                Image(systemName: "heart.fill").font(.caption).shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Überschrift einer Rubrik (wie Apples Fotos auf dem Apple TV: groß, fett, links).
struct SectionTitle: View {
    let text: LocalizedStringKey
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(text).font(.title2.weight(.bold))
            if let detail { Text(detail).font(.headline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.top, 30)
        .padding(.bottom, 36)
    }
}

/// Hinweis, wenn etwas leer ist oder noch lädt.
struct EmptyHint: View {
    let icon: String
    let title: LocalizedStringKey
    var text: LocalizedStringKey? = nil
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 80)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let text { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: 900).frame(maxWidth: .infinity).padding(.vertical, 120)
    }
}
