import SwiftUI
import AppKit

@main
struct DogenApp: App {
    @StateObject private var state = AppState()
    @StateObject private var pairing = PairingManager()

    init() {
        // Running from `swift run` (no app bundle): become a regular app with a Dock icon.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("Dogen") {
            ContentView()
                .environmentObject(state)
                .environmentObject(pairing)
                .frame(minWidth: 900, minHeight: 620)
                .preferredColorScheme(state.colorScheme)
                .tint(state.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Phone") {
                Button("Show Welcome Screen") { state.showWelcome = true }
                Button("Show Pairing Sheet") { state.showOnboarding = true }
            }
        }

        // Separate, phone-shaped window for the live screen mirror.
        Window("Phone Mirror", id: "mirror") {
            MirrorWindow()
                .environmentObject(pairing)
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 690)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(state)
                .environmentObject(pairing)
        } label: {
            Image(systemName: "smartphone")
        }
        .menuBarExtraStyle(.window)
    }
}
