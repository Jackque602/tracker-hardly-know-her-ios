import SwiftUI

@MainActor
struct RootView: View {

    @EnvironmentObject private var container: AppContainer

    var body: some View {
        TabView {
            MapScreen(container: container)
                .tabItem { Label("Map", systemImage: "map") }

            StatsScreen(container: container)
                .tabItem { Label("Stats", systemImage: "chart.bar") }

            SettingsScreen(container: container)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
