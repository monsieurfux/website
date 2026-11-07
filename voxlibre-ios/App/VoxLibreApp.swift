import SwiftUI

@main
struct VoxLibreApp: App {
    @StateObject private var engine = RingEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.lime)
        }
    }
}
