import TVServices

/// Top-Shelf-Erweiterung: liest den Schnappschuss, den die App samt Vorschaubildern in den Gruppen-Ordner gelegt hat
/// (das System lädt die Bilder selbst und kennt unseren Server-Zugang nicht → nur file://-Bilder).
/// Karussell: Rückblicke (mit „Abspielen“) und empfohlene Fotos; Reihen: „Rückblicke“ + „Empfohlene Fotos“.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(content())
    }

    private func content() -> (any TVTopShelfContent)? {
        guard let snap = TopShelfSnapshot.load(), !(snap.memories.isEmpty && snap.photos.isEmpty) else { return nil }
        let folder = TopShelfSnapshot.folder
        switch snap.style {
        case .carousel:
            let items = (snap.memories + snap.photos).map { carousel($0, folder: folder) }
            return TVTopShelfCarouselContent(style: .details, items: items)
        case .sections:
            var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
            if !snap.memories.isEmpty {
                let c = TVTopShelfItemCollection(items: snap.memories.map { sectioned($0, folder: folder) })
                c.title = String(localized: "Rückblicke")
                sections.append(c)
            }
            if !snap.photos.isEmpty {
                let c = TVTopShelfItemCollection(items: snap.photos.map { sectioned($0, folder: folder) })
                c.title = String(localized: "Empfohlene Fotos")
                sections.append(c)
            }
            return TVTopShelfSectionedContent(sections: sections)
        }
    }

    private func carousel(_ i: TopShelfSnapshot.Item, folder: URL) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: i.id)
        item.title = i.title
        item.summary = i.subtitle
        item.contextTitle = i.isMemory ? String(localized: "Rückblick") : String(localized: "Empfohlenes Foto")
        item.creationDate = i.date
        let url = folder.appendingPathComponent(i.file)
        item.setImageURL(url, for: .screenScale1x)
        item.setImageURL(url, for: .screenScale2x)
        if let link = URL(string: i.link) {
            item.displayAction = TVTopShelfAction(url: link)
            if i.isMemory { item.playAction = TVTopShelfAction(url: link) }
        }
        return item
    }

    private func sectioned(_ i: TopShelfSnapshot.Item, folder: URL) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: i.id)
        item.title = i.title
        item.imageShape = .hdtv
        let url = folder.appendingPathComponent(i.file)
        item.setImageURL(url, for: .screenScale1x)
        item.setImageURL(url, for: .screenScale2x)
        if let link = URL(string: i.link) {
            item.displayAction = TVTopShelfAction(url: link)
            if i.isMemory { item.playAction = TVTopShelfAction(url: link) }
        }
        return item
    }
}
