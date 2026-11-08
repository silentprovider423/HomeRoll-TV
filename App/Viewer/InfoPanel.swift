import SwiftUI

/// Infos zum Foto (nach unten wischen): Datum, Ort, Kamera, Personen, Alben, Beschreibung.
struct InfoPanel: View {
    let asset: Asset
    @State private var dto: AssetDTO?
    @State private var albums: [AlbumDTO] = []

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Fmt.fullDate.string(from: asset.date)).font(.title3.weight(.bold))
                Text(Fmt.time.string(from: asset.date)).foregroundStyle(.secondary)
                if let place = place { Label(place, systemImage: "mappin.and.ellipse") }
                if let d = description, !d.isEmpty { Text(d).font(.callout).lineLimit(3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                if let cam = camera { Label(cam, systemImage: "camera") }
                if let lens = dto?.exifInfo?.lensModel { Text(lens).font(.callout).foregroundStyle(.secondary) }
                if let exp = exposure { Text(exp).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                if let size = dimensions { Text(size).font(.callout).foregroundStyle(.secondary) }
                if let name = dto?.originalFileName { Text(name).font(.caption).foregroundStyle(.tertiary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                if let people = dto?.people?.filter({ !$0.name.isEmpty }), !people.isEmpty {
                    Label(people.map(\.name).joined(separator: ", "), systemImage: "person.2")
                }
                if !albums.isEmpty {
                    Label(albums.map(\.albumName).joined(separator: ", "), systemImage: "rectangle.stack")
                }
                if asset.isLivePhoto { Label("Live Photo", systemImage: "livephoto") }
                if asset.isVideo { Label(Fmt.duration(asset.durationMs), systemImage: "video") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(44)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, 60).padding(.top, 40)
        .task(id: asset.id) {
            dto = try? await ImmichClient.shared.asset(asset.id)
            albums = (try? await ImmichClient.shared.albums(containing: asset.id)) ?? []
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info-panel")
    }

    private var place: String? {
        let e = dto?.exifInfo
        let parts = [e?.city ?? asset.city, e?.state, e?.country ?? asset.country].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }
    private var description: String? { dto?.description ?? dto?.exifInfo?.description }
    private var camera: String? {
        guard let e = dto?.exifInfo else { return nil }
        let s = [e.make, e.model].compactMap { $0 }.joined(separator: " ")
        return s.isEmpty ? nil : s
    }
    private var exposure: String? {
        guard let e = dto?.exifInfo else { return nil }
        var parts: [String] = []
        if let f = e.focalLength { parts.append("\(Int(f.rounded())) mm") }
        if let n = e.fNumber { parts.append(String(format: "ƒ%.1f", n)) }
        if let t = e.exposureTime { parts.append("\(t) s") }
        if let iso = e.iso { parts.append("ISO \(Int(iso))") }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
    private var dimensions: String? {
        guard let w = dto?.exifInfo?.exifImageWidth, let h = dto?.exifInfo?.exifImageHeight, w > 0 else { return nil }
        var s = "\(Int(w)) × \(Int(h))"
        if let b = dto?.exifInfo?.fileSizeInByte { s += " · " + ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
        return s
    }
}
