import SwiftUI

/// Settings — paired device, appearance, sync toggles, permissions.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @StateObject private var login = LaunchAtLogin()
    @State private var syncMessages = true
    @State private var syncNotifications = true
    @State private var syncClipboard = true
    @State private var syncCamera = true

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Settings", subtitle: "How Tethr behaves on this Mac")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    section("Paired device") { pairedDevice }
                    section("Background") { background }
                    section("Appearance") { appearance }
                    section("Sync") { sync }
                    section("Permissions") { permissions }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 26)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionCaption(text: title)
            content()
        }
    }

    private var pairedDevice: some View {
        Card {
            HStack(spacing: 14) {
                DeviceGlyph(size: 46, corner: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                    Text(deviceDetail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Glide.inkSoft)
                }
                Spacer()
                if pairing.isConnected {
                    StatusPill(label: "Connected")
                } else if pairing.hasPaired {
                    StatusPill(label: "Offline", color: Palette.orange)
                }
                Button {
                    if pairing.hasPaired { pairing.unpair() } else { state.showOnboarding = true }
                } label: {
                    Text(pairing.hasPaired ? "Unpair" : "Pair…")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(pairing.hasPaired ? Glide.ink : Glide.onInk)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(pairing.hasPaired ? AnyShapeStyle(Glide.surfaceAlt) : AnyShapeStyle(Glide.inkFill),
                                    in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
            }
            .padding(16)
        }
        .animation(.easeOut(duration: 0.2), value: pairing.phase)
    }

    private var deviceDetail: String {
        guard pairing.hasPaired else { return "Scan a QR code to link your phone" }
        guard pairing.isConnected else { return "Open the Tethr app on your phone to reconnect" }
        if let battery = pairing.battery { return "Wi-Fi · Battery \(battery)%" }
        return "Connected via Wi-Fi"
    }

    private var appearance: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    rowLabel("Theme")
                    Spacer()
                    HStack(spacing: 8) {
                        Chip(label: "Light", selected: state.appearance == "Light") {
                            state.appearance = "Light"
                        }
                        Chip(label: "Dark", selected: state.appearance == "Dark") {
                            state.appearance = "Dark"
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider().opacity(0.35).padding(.horizontal, 16)

                HStack {
                    rowLabel("Accent colour")
                    Spacer()
                    HStack(spacing: 10) {
                        ForEach(Array(Palette.accentChoices.enumerated()), id: \.offset) { i, choice in
                            Button {
                                state.accentIndex = i
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Glide.surface, lineWidth: 2)
                                            .padding(1)
                                            .opacity(state.accentIndex == i ? 1 : 0)
                                    }
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Glide.ink, lineWidth: 1.5)
                                            .opacity(state.accentIndex == i ? 1 : 0)
                                    }
                            }
                            .buttonStyle(PressableStyle(scale: 0.88))
                            .help(choice.name)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
            }
        }
    }

    /// Tethr is the server the phone dials, so the link only exists while this
    /// app is running. That makes "start at login" the setting that decides
    /// whether the phone is connected when you sit down at the Mac.
    private var background: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Start Tethr at login")
                        Text(loginCaption)
                            .font(.system(size: 12.5))
                            .foregroundStyle(login.lastError == nil ? Glide.inkSoft : Palette.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if login.needsApproval {
                        Button("Open Login Items") { login.openLoginItemSettings() }
                            .font(.system(size: 12.5, weight: .semibold))
                    } else {
                        Toggle("", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(Glide.inkFill)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider().opacity(0.35).padding(.horizontal, 16)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Runs with the window closed")
                        Text("Closing the window leaves Tethr in the menu bar with the phone still connected. Quitting is what ends the link.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Glide.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .onAppear { login.refresh() }
    }

    private var loginCaption: String {
        if let error = login.lastError { return error }
        if login.needsApproval {
            return "Turned off in System Settings — Tethr can't switch it back on itself."
        }
        return login.enabled
            ? "Tethr starts with your Mac, so the phone reconnects on its own."
            : "The phone can't reach this Mac while Tethr isn't running."
    }

    private var sync: some View {
        Card {
            VStack(spacing: 0) {
                toggleRow("Messages & SMS", $syncMessages, divider: true)
                toggleRow("Notifications", $syncNotifications, divider: true)
                toggleRow("Universal clipboard", $syncClipboard, divider: true)
                toggleRow("Camera & mic continuity", $syncCamera, divider: false)
            }
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Glide.ink)
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>, divider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                rowLabel(label)
                Spacer()
                Toggle("", isOn: binding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(Glide.inkFill)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if divider { Divider().opacity(0.35).padding(.horizontal, 16) }
        }
    }

    private var permissions: some View {
        Card {
            VStack(spacing: 0) {
                // Real state, not decoration: each row reports what the phone
                // has actually granted.
                let perms: [(String, Bool)] = [
                    ("Notification access", pairing.notificationAccess),
                    ("Contacts & call log", !state.contacts.isEmpty || !state.recents.isEmpty),
                    ("Local network", pairing.isConnected),
                ]
                ForEach(Array(perms.enumerated()), id: \.offset) { i, entry in
                    let (p, granted) = entry
                    VStack(spacing: 0) {
                        HStack(spacing: 11) {
                            rowLabel(p)
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: granted ? "checkmark" : "exclamationmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text(granted ? "Granted" : "Not granted")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(granted ? Palette.green : Palette.orange)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background((granted ? Palette.green : Palette.orange).opacity(0.12), in: Capsule())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        if i < perms.count - 1 {
                            Divider().opacity(0.35).padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }
}
