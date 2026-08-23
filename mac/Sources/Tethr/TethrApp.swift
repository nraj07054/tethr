import SwiftUI
import AppKit

@main
struct TethrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // The shared instances AppCore already started; wrapped in @StateObject
    // only so SwiftUI observes them, never to create them.
    @StateObject private var state = AppCore.shared.state
    @StateObject private var pairing = AppCore.shared.pairing
    @StateObject private var files = AppCore.shared.files

    init() {
        // Running from `swift run` (no app bundle): become a regular app with a Dock icon.
        // Activation is left to the delegate, which knows whether this launch
        // was someone opening Tethr or macOS starting it at login.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// Named so the menu bar item can reopen the window after it is closed —
    /// activating the app alone does nothing once SwiftUI has torn it down.
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Tethr", id: TethrApp.mainWindowID) {
            ContentView()
                .environmentObject(state)
                .environmentObject(pairing)
                .environmentObject(files)
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
                .tint(state.accent)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 690)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(state)
                .environmentObject(pairing)
                .tint(state.accent)
        } label: {
            if let mark = Brand.menuBarGlyph {
                Image(nsImage: mark)
            } else {
                Image(systemName: "smartphone")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
