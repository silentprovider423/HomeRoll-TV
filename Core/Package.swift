// swift-tools-version: 6.0
// Gemeinsame Logik von HomeRoll TV (API, Modelle, Rückblicke, Diashow, Kopplung, Top Shelf).
// Baut für tvOS (App + Top-Shelf-Erweiterung) und für macOS, damit die Tests ohne tvOS-Simulator laufen.
import PackageDescription

let package = Package(
    name: "HomeRollTVCore",
    platforms: [.macOS(.v15), .tvOS("26.0")],
    products: [.library(name: "HomeRollTVCore", targets: ["HomeRollTVCore"])],
    targets: [
        .target(name: "HomeRollTVCore"),
        .testTarget(name: "HomeRollTVCoreTests", dependencies: ["HomeRollTVCore"]),
    ]
)
