import SwiftUI

@main
@MainActor
struct RoamedApp: App {

    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.settings)
                .environmentObject(container.tracker)
                .tint(RoamedTheme.accent)
        }
    }
}
