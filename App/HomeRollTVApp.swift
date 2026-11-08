import SwiftUI

@main
struct HomeRollTVApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .onOpenURL { app.open($0) }
                .onChange(of: phase) { _, p in
                    // Beim Verlassen der App den Top Shelf auffrischen (der Home-Bildschirm zeigt ihn gleich)
                    if p == .background || p == .inactive { app.refreshTopShelf() }
                }
        }
    }
}
