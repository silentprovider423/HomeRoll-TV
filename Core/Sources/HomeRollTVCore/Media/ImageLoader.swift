import CoreGraphics
import Foundation
import ImageIO

/// Lädt Vorschaubilder vom Server (Platte: URLCache des Clients, Speicher: NSCache) und entpackt sie im Hintergrund.
/// Gleichzeitige Anfragen für dasselbe Bild teilen sich einen Download (Kachel + Vorausladen, wie in HomeRoll).
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    var client: ImmichClient = .shared

    init() { cache.totalCostLimit = 300 << 20 }

    func cached(_ id: String, _ size: ImmichClient.Size) -> CGImage? {
        cache.object(forKey: key(id, size) as NSString)?.image
    }

    /// Unscharfes Sofortbild aus dem ThumbHash (≈ 0,1 ms).
    func placeholder(_ id: String) -> CGImage? {
        let k = "ph-\(id)" as NSString
        if let b = cache.object(forKey: k) { return b.image }
        guard let h = HashStore.shared.hash(id), let img = ThumbHash.cgImage(base64: h) else { return nil }
        cache.setObject(Box(img), forKey: k, cost: 32 * 32 * 4)
        return img
    }

    private func key(_ id: String, _ size: ImmichClient.Size) -> String { "\(id)-\(size.rawValue)-\(HashStore.shared.version(id) ?? "")" }

    func load(_ id: String, _ size: ImmichClient.Size) async -> CGImage? {
        let k = key(id, size)
        if let b = cache.object(forKey: k as NSString) { return b.image }
        let task: Task<CGImage?, Never> = lock.withLock {
            if let t = inflight[k] { return t }
            let client = self.client
            let t = Task<CGImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                defer { self?.lock.withLock { _ = self?.inflight.removeValue(forKey: k) } }
                guard let url = client.thumbnailURL(id, size), let data = try? await client.data(url),
                      let img = Self.decode(data, maxPixel: size == .fullsize ? 3840 : 0) else { return nil }
                self?.cache.setObject(Box(img), forKey: k as NSString, cost: img.bytesPerRow * img.height)
                return img
            }
            inflight[k] = t
            return t
        }
        return await task.value
    }

    /// Vorausladen (z. B. nächstes Foto im Vollbild, nächste Szene im Rückblick).
    func prefetch(_ ids: [String], _ size: ImmichClient.Size) {
        for id in ids where cached(id, size) == nil {
            Task.detached(priority: .utility) { [weak self] in _ = await self?.load(id, size) }
        }
    }

    /// Fertig entpacktes Bitmap (WebP/JPEG/HEIC). `maxPixel` 0 = Originalgröße.
    static func decode(_ data: Data, maxPixel: Int = 0) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true]
        if maxPixel > 0 {
            opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        } else if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
        }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func clear() { cache.removeAllObjects() }
}
