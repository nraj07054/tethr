import AppKit
import ServiceManagement
import SwiftUI

/// Keeping the Mac end of the link up.
///
/// The Mac is the server here — the phone dials it — so nothing reaches this
/// Mac while Tethr isn't running. Two things follow: the app registers itself
/// as a login item so it is listening before the phone starts looking, and
/// closing the window only puts the window away, leaving the link and the menu
/// bar item alive.
@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var enabled = false
    /// macOS knows about the login item but the user has switched it off in
    /// System Settings. No app can re-enable itself from there, so the UI
    /// stops offering a toggle and points at the right screen instead.
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func set(_ on: Bool) {
        do {
            if on {
                // register() throws if the item is already there, and the
                // toggle can be driven by a status we've just refreshed.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// System Settings ▸ General ▸ Login Items, where a denied item is restored.
    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// The AppKit-level behaviour SwiftUI has no equivalent for: surviving the last
/// window closing, and coming up quietly when macOS launches us at login.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// App Nap throttles timers and coalesces work for a background app with no
    /// visible window — which is exactly how Tethr is meant to run. The link's
    /// watchdog is a 3s timer, so letting it be stretched would have the Mac
    /// deciding the phone had dropped while it was sitting there connected.
    /// Idle system sleep stays allowed: this keeps the app awake, not the Mac.
    private var activity: NSObjectProtocol?

    /// Closing the window must not take the link down with it. The phone stays
    /// connected and the menu bar item is what brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window question: the link has to come up even on a login
        // launch, where no window is ever built. See AppCore.
        MainActor.assumeIsolated { AppCore.shared.start() }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeping the link to the paired phone alive"
        )
        // Signing in should not hand the desktop to Tethr. A login-item launch
        // is not a "default" launch, and that is the one case where we come up
        // hidden, with only the menu bar item to show for it.
        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if isDefaultLaunch {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.hide(nil)
        }
    }
}






