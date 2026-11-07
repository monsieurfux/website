import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: RingEngine
    @State private var tab = 0
    @State private var showSettings = false

    private var dotColor: Color {
        if engine.connected { return Theme.lime }
        return engine.statusText == "disconnected" ? Theme.idle : Theme.warn
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                RingScreen()
                    .chromeTabBar()
                    .tabItem { Label("Ring", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(0)
                LibraryScreen()
                    .chromeTabBar()
                    .tabItem { Label("Recordings", systemImage: "mic") }
                    .tag(1)
                LogsScreen(logs: engine.logStore)
                    .chromeTabBar()
                    .tabItem { Label("Logs", systemImage: "doc.text") }
                    .tag(2)
            }
            .onChange(of: tab) { newTab in
                if newTab == 1 { engine.refreshLibrary() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("VoxLibre").font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(dotColor).frame(width: 8, height: 8)
                            Text(engine.statusText)
                                .font(.caption)
                                .foregroundColor(Theme.muted)
                        }
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if engine.configured {
                        Button(engine.statusText == "disconnected" ? "Connect" : "Disconnect") {
                            engine.toggleConnect()
                        }
                    }
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(Theme.bgChrome, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .overlay(alignment: .bottom) {
            if let t = engine.toastItem {
                Text(t.text)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.bgFilter)
                    .foregroundColor(Theme.text)
                    .clipShape(Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.toastItem)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

private extension View {
    /// Dark chrome for the tab bar. Must be applied to the tab's content, not to the TabView.
    func chromeTabBar() -> some View {
        self
            .toolbarBackground(Theme.bgChrome, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}
