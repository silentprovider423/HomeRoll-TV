import XCTest

/// Rundgang mit der Siri Remote (XCUIRemote) gegen ein Test-Konto. Zugang kommt per Umgebung
/// (TEST_RUNNER_FOTOS_SERVER / TEST_RUNNER_FOTOS_TOKEN beim xcodebuild-Aufruf) – nie im Repo.
@MainActor
final class HomeRollTVUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let server = env["FOTOS_SERVER"], let token = env["FOTOS_TOKEN"] else {
            throw XCTSkip("FOTOS_SERVER/FOTOS_TOKEN fehlen")
        }
        app = XCUIApplication()
        app.launchEnvironment["FOTOS_SERVER"] = server
        app.launchEnvironment["FOTOS_TOKEN"] = token
        switch name {
        case let n where n.contains("testVideo"):
            guard let v = env["FOTOS_VIDEO"] else { throw XCTSkip("FOTOS_VIDEO fehlt") }
            app.launchEnvironment["FOTOS_OPEN"] = "homeroll-tv://asset/\(v)"
        case let n where n.contains("testLoginScreen"):
            app.launchEnvironment["FOTOS_LOGIN_SCREEN"] = "1"
            app.launchEnvironment["FOTOS_PAIRING_HOST"] = "192.0.2.20"
        default: break
        }
        if let lang = env["FOTOS_LANG"] {   // z. B. „en“ für die README-Bildschirmfotos
            app.launchArguments += ["-AppleLanguages", "(\(lang))", "-AppleLocale", lang == "en" ? "en_US" : lang]
        }
        app.launch()
    }

    private func press(_ b: XCUIRemote.Button, _ n: Int = 1, pause: TimeInterval = 0.4) {
        for _ in 0..<n { remote.press(b); Thread.sleep(forTimeInterval: pause) }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways
        add(a)
    }

    /// Rückblicke laden, einen abspielen, Info-Leiste öffnen, schließen.
    func testMemoriesPlayer() throws {
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 40), "Kein Rückblick")
        shot("1-memories")
        // Fokus von der Tab-Leiste nach unten auf das große Band
        press(.down, 2)
        press(.select)
        XCTAssertTrue(app.buttons["memory-stage"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.8)   // Titelkarte
        shot("5-memory-player")
        press(.down)
        XCTAssertTrue(app.otherElements["memory-panel"].waitForExistence(timeout: 5) || app.buttons["Anhalten"].exists)
        press(.menu)   // Leiste zu
        press(.menu)   // Player zu
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 10))
    }

    /// Mediathek: Raster, Vollbild, blättern, Infos, Diashow per Play/Pause.
    func testLibraryViewerSlideshow() throws {
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 40) || app.tabBars.firstMatch.exists)
        press(.right)  // Tab „Mediathek“
        press(.select)
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        press(.down, 3)
        shot("2-library")
        press(.select)
        XCTAssertTrue(app.buttons["viewer-stage"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        press(.right); press(.right)
        shot("3-viewer")
        press(.down)
        XCTAssertTrue(app.otherElements["info-panel"].waitForExistence(timeout: 5))
        shot("4-info")
        press(.down)
        press(.playPause)
        XCTAssertTrue(app.buttons["slideshow-stage"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 5)
        shot("6-slideshow")
        press(.playPause)
        press(.menu)
        press(.menu)
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
    }

    /// Alben: Album öffnen und Diashow-Knopf finden.
    func testAlbums() throws {
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 40) || app.tabBars.firstMatch.exists)
        press(.right, 2)
        press(.select)
        let album = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'album-'")).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 20))
        shot("7-albums")
        press(.down, 2)
        press(.select)
        XCTAssertTrue(app.buttons["collection-slideshow"].waitForExistence(timeout: 10))
        shot("8-album")
        press(.menu)
    }

    /// Video aus dem Vollbild abspielen (System-Transportleiste).
    func testVideo() throws {
        XCTAssertTrue(app.buttons["viewer-stage"].waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 2)
        press(.select)
        Thread.sleep(forTimeInterval: 6)
        shot("9-video")
        XCTAssertFalse(app.buttons["viewer-stage"].isHittable && app.buttons["viewer-stage"].hasFocus, "Player sollte den Fokus haben")
        press(.menu, pause: 2)               // Player zu → zurück im Vollbild
        if !app.buttons["viewer-stage"].waitForExistence(timeout: 5) { press(.menu, pause: 2) }
        XCTAssertTrue(app.buttons["viewer-stage"].waitForExistence(timeout: 10))
    }

    /// Suche: Text eingeben, Treffer erscheinen.
    func testSearch() throws {
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 40) || app.tabBars.firstMatch.exists)
        press(.right, 3)
        press(.select)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        press(.down, pause: 1)               // Fokus von der Tab-Leiste auf die Tastatur
        field.typeText("Bali")
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tile-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        press(.down, pause: 4)               // in die Treffer, Vorschauen laden lassen
        shot("10-search")
    }

    /// Anmeldebildschirm mit QR-Code und Code.
    func testLoginScreen() throws {
        XCTAssertTrue(app.buttons["login-manual"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["pairing-code"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["pairing-code"].label.count, 6)
        shot("0-login")
        press(.select)
        XCTAssertTrue(app.textFields["login-server"].waitForExistence(timeout: 10))
        shot("0-login-manual")
    }

    /// Top Shelf: zurück zum Home-Bildschirm, HomeRoll TV in der obersten Reihe fokussieren.
    func testTopShelf() throws {
        XCTAssertTrue(app.buttons["memory-hero"].waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 8)      // Top-Shelf-Vorschauen laden
        press(.home, pause: 3)
        // Fokus auf unser Symbol in der obersten Reihe (links davon nur Einstellungen o. Ä.)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let icon = springboard.buttons["HomeRoll TV"]
        if icon.waitForExistence(timeout: 5) {
            for _ in 0..<8 where !icon.hasFocus { press(.left, pause: 0.5) }
            for _ in 0..<8 where !icon.hasFocus { press(.right, pause: 0.5) }
        } else {
            press(.right)
        }
        Thread.sleep(forTimeInterval: 6)
        shot("11-topshelf")
        press(.up, pause: 3)                 // ins Top-Shelf-Karussell
        shot("12-topshelf-focused")
    }
}
