// Erzeugt App-Symbol (3 Ebenen für den Parallax-Effekt) und Top-Shelf-Standbilder für tvOS:
//   swift tools/make-icon.swift Resources/Assets.xcassets
// Eigenes Motiv (Fotostapel mit Landschaft auf Abendhimmel) – kein Apple-Symbol.
import AppKit

enum Layer { case back, middle, front, flat }

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

/// Zeichnet in ein Koordinatensystem 1600×960 (5:3 wie das tvOS-Symbol), skaliert auf `w`×`h`.
func render(_ w: Int, _ h: Int, layer: Layer, wide: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let W = CGFloat(w), H = CGFloat(h)

    func background() {
        let g = CGGradient(colorsSpace: nil, colors: [rgb(0x1B1F3B), rgb(0x3B2A6B), rgb(0xC2577A)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        // weiche Lichtflecken
        for (x, y, r, c) in [(0.18, 0.8, 0.35, 0x6C8CFF), (0.85, 0.25, 0.3, 0xFF9E6B)] as [(CGFloat, CGFloat, CGFloat, UInt32)] {
            let rg = CGGradient(colorsSpace: nil, colors: [rgb(c, 0.35), rgb(c, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(rg, startCenter: CGPoint(x: x * W, y: y * H), startRadius: 0,
                                   endCenter: CGPoint(x: x * W, y: y * H), endRadius: r * max(W, H), options: [])
        }
    }

    // Motiv-Koordinaten relativ zur Höhe, mittig
    let unit = H / 960
    let cx = W / 2, cy = H / 2
    func card(_ angle: CGFloat, _ dx: CGFloat, _ dy: CGFloat, _ photo: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: cx + dx * unit, y: cy + dy * unit)
        ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -330 * unit, y: -230 * unit, width: 660 * unit, height: 460 * unit)
        ctx.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 40 * unit, color: rgb(0x000000, 0.45))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34 * unit, cornerHeight: 34 * unit, transform: nil))
        ctx.setFillColor(rgb(0xF4F1EC)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let inner = r.insetBy(dx: 24 * unit, dy: 24 * unit)
        let ip = CGPath(roundedRect: inner, cornerWidth: 18 * unit, cornerHeight: 18 * unit, transform: nil)
        ctx.addPath(ip); ctx.clip()
        if photo {
            let sky = CGGradient(colorsSpace: nil, colors: [rgb(0xFFB36B), rgb(0xF0647A), rgb(0x5B4BC4)] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: inner.minY), end: CGPoint(x: 0, y: inner.maxY), options: [])
            ctx.addEllipse(in: CGRect(x: inner.midX + 40 * unit, y: inner.minY + 150 * unit, width: 130 * unit, height: 130 * unit))
            ctx.setFillColor(rgb(0xFFE7A3)); ctx.fillPath()
            let back = CGMutablePath()
            back.move(to: CGPoint(x: inner.minX, y: inner.minY + 120 * unit))
            back.addLine(to: CGPoint(x: inner.minX + 200 * unit, y: inner.minY + 250 * unit))
            back.addLine(to: CGPoint(x: inner.minX + 360 * unit, y: inner.minY + 140 * unit))
            back.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + 230 * unit))
            back.addLine(to: CGPoint(x: inner.maxX, y: inner.minY)); back.addLine(to: CGPoint(x: inner.minX, y: inner.minY)); back.closeSubpath()
            ctx.addPath(back); ctx.setFillColor(rgb(0x3A2F78)); ctx.fillPath()
            let front = CGMutablePath()
            front.move(to: CGPoint(x: inner.minX, y: inner.minY + 40 * unit))
            front.addLine(to: CGPoint(x: inner.minX + 260 * unit, y: inner.minY + 160 * unit))
            front.addLine(to: CGPoint(x: inner.minX + 420 * unit, y: inner.minY + 70 * unit))
            front.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + 130 * unit))
            front.addLine(to: CGPoint(x: inner.maxX, y: inner.minY)); front.addLine(to: CGPoint(x: inner.minX, y: inner.minY)); front.closeSubpath()
            ctx.addPath(front); ctx.setFillColor(rgb(0x1E1A45)); ctx.fillPath()
        } else {
            let g = CGGradient(colorsSpace: nil, colors: [rgb(0x7FA7FF), rgb(0x9C7BFF)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: inner.minX, y: inner.minY), end: CGPoint(x: inner.maxX, y: inner.maxY), options: [])
        }
        ctx.restoreGState()
    }

    switch layer {
    case .back: background()
    case .middle: card(-9, -60, 10, false)
    case .front: card(4, 40, -10, true)
    case .flat:
        background()
        if wide {
            // Top-Shelf-Standbild: Stapel rechts, Name links
            ctx.saveGState(); ctx.translateBy(x: W * 0.18, y: 0)
        }
        card(-9, -60, 10, false); card(4, 40, -10, true)
        if wide { ctx.restoreGState() }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func json(_ obj: Any, _ url: URL) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets")
let fm = FileManager.default
try? fm.removeItem(at: root)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
json(["info": info], root.appendingPathComponent("Contents.json"))
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
try! fm.createDirectory(at: brand, withIntermediateDirectories: true)

/// Bildstapel (3 Ebenen) in den Größen `sizes` (Punkte, Skalen).
func imagestack(_ name: String, w: Int, h: Int, scales: [Int]) {
    let dir = brand.appendingPathComponent("\(name).imagestack")
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let layers: [(String, Layer)] = [("Front", .front), ("Middle", .middle), ("Back", .back)]
    json(["info": info, "layers": layers.map { ["filename": "\($0.0).imagestacklayer"] }], dir.appendingPathComponent("Contents.json"))
    for (lname, l) in layers {
        let ld = dir.appendingPathComponent("\(lname).imagestacklayer")
        let set = ld.appendingPathComponent("Content.imageset")
        try! fm.createDirectory(at: set, withIntermediateDirectories: true)
        json(["info": info], ld.appendingPathComponent("Contents.json"))
        var images: [[String: Any]] = []
        for s in scales {
            let file = "\(lname.lowercased())@\(s)x.png"
            png(render(w * s, h * s, layer: l), set.appendingPathComponent(file))
            images.append(["idiom": "tv", "scale": "\(s)x", "filename": file])
        }
        json(["info": info, "images": images], set.appendingPathComponent("Contents.json"))
    }
}

func imageset(_ name: String, w: Int, h: Int, scales: [Int]) {
    let set = brand.appendingPathComponent("\(name).imageset")
    try! fm.createDirectory(at: set, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for s in scales {
        let file = "shelf@\(s)x.png"
        png(render(w * s, h * s, layer: .flat, wide: true), set.appendingPathComponent(file))
        images.append(["idiom": "tv", "scale": "\(s)x", "filename": file])
    }
    json(["info": info, "images": images], set.appendingPathComponent("Contents.json"))
}

imagestack("App Icon", w: 400, h: 240, scales: [1, 2])
imagestack("App Icon - App Store", w: 1280, h: 768, scales: [1])
imageset("Top Shelf Image", w: 1920, h: 720, scales: [1, 2])
imageset("Top Shelf Image Wide", w: 2320, h: 720, scales: [1, 2])
json(["info": info, "assets": [
    ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
]], brand.appendingPathComponent("Contents.json"))

// Vorschau fürs README
png(render(800, 480, layer: .flat), URL(fileURLWithPath: "docs/icon.png"))
print("Symbol geschrieben nach \(root.path)")
