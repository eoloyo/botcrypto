import SwiftUI

@main
struct GrumeLabApp: App {
    @StateObject private var store = LogStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LogsView()
                .tabItem { Label("Grumes", systemImage: "list.bullet.rectangle") }
            ResonanceView()
                .tabItem { Label("Résonance", systemImage: "waveform") }
            LiDARView()
                .tabItem { Label("LiDAR", systemImage: "ruler") }
        }
        .tint(.orange)
    }
}
