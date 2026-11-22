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
    // Launch argument "-tab N" opens a given tab (used for the simulator screenshots).
    @State private var tab = UserDefaults.standard.integer(forKey: "tab")

    var body: some View {
        TabView(selection: $tab) {
            LogsView()
                .tabItem { Label("Grumes", systemImage: "list.bullet.rectangle") }
                .tag(0)
            ResonanceView()
                .tabItem { Label("Résonance", systemImage: "waveform") }
                .tag(1)
            LiDARView()
                .tabItem { Label("LiDAR", systemImage: "ruler") }
                .tag(2)
        }
        .tint(.orange)
    }
}
