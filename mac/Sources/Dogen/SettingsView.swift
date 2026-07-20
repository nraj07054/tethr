import SwiftUI

/// Settings — paired device, appearance, sync toggles, permissions.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var syncMessages = true
    @State private var syncNotifications = true
    @State private var syncClipboard = true
    @State private var syncCamera = true

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Settings")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("Paired Device") { pairedDevice }
                    section("Appearance") { appearance }
                    section("Sync") { sync }
                    section("Permissions") { permissions }
                }
                .frame(maxWidth: 660)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionCaption(text: title)
            content()
        }
    }

    private var pairedDevice: some View {
        Card {
            HStack(spacing: 14) {
                DeviceGlyph(size: 44, corner: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 14, weight: .semibold))
                    Text(deviceDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if pairing.isConnected {
                    HStack(spacing: 5) {
                        LiveDot(size: 7)
                        Text("Connected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.green)
                    }
                } else if pairing.hasPaired {
                    HStack(spacing: 5) {
                        LiveDot(color: Palette.orange, size: 7)
                        Text("Not connected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.orange)
                    }
                }
                if pairing.hasPaired {
                    Button("Unpair") { pairing.unpair() }
                        .controlSize(.small)
                } else {
                    Button("Pair…") { state.showOnboarding = true }
                        .controlSize(.small)
                }
            }
            .padding(16)
        }
        .animation(.easeOut(duration: 0.2), value: pairing.phase)
    }

    private var deviceDetail: String {
        guard pairing.hasPaired else { return "Scan a QR code to link your phone" }
        guard pairing.isConnected else { return "Open the Dogen page on your phone to reconnect" }
        if let battery = pairing.battery { return "Wi-Fi · Battery \(battery)%" }
        return "Connected via Wi-Fi"
    }

    private var appearance: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    Text("Theme")
                        .font(.system(size: 14))
                    Spacer()
                    Picker("", selection: state.$appearance) {
                        Text("Light").tag("Light")
                        Text("Dark").tag("Dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { Divider().opacity(0.5) }

                HStack {
                    Text("Accent color")
                        .font(.system(size: 14))
                    Spacer()
                    HStack(spacing: 9) {
                        ForEach(Array(Palette.accentChoices.enumerated()), id: \.offset) { i, choice in
                            Button {
                                state.accentIndex = i
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if state.accentIndex == i {
                                            Circle()
                                                .strokeBorder(.background, lineWidth: 2)
                                                .padding(1)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(choice.name)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var sync: some View {
        Card {
            VStack(spacing: 0) {
                toggleRow("Messages & SMS", $syncMessages, divider: true)
                toggleRow("Notifications", $syncNotifications, divider: true)
                toggleRow("Universal Clipboard", $syncClipboard, divider: true)
                toggleRow("Camera & Mic continuity", $syncCamera, divider: false)
            }
        }
    }

    private func toggleRow(_ label: String, _ binding: Binding<Bool>, divider: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Palette.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if divider { Divider().opacity(0.5) }
        }
    }

    private var permissions: some View {
        Card {
            VStack(spacing: 0) {
                let perms = ["Notification access", "Contacts & Call log", "SMS & MMS", "Local network"]
                ForEach(Array(perms.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 11) {
                        Text(p)
                            .font(.system(size: 14))
                        Spacer()
                        Label("Granted", systemImage: "checkmark")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.green)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .overlay(alignment: .bottom) {
                        if i < perms.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }
}
