import SwiftUI

/// Full-window animated welcome screen shown on first launch.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#0A84FF"), Color(hex: "#5E5CE6"), Color(hex: "#AF52DE"), Color(hex: "#FF375F")],
                startPoint: phase ? .topLeading : .bottomTrailing,
                endPoint: phase ? .bottomTrailing : .topLeading
            )
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) {
                    phase = true
                }
            }

            VStack(spacing: 0) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white)
                    .frame(width: 98, height: 98)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 27, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 27, style: .continuous)
                            .strokeBorder(.white.opacity(0.42), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 23, y: 12)

                Text("WELCOME TO")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.top, 28)

                Text("Dogen")
                    .font(.system(size: 58, weight: .bold))
                    .kerning(-1.5)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 2)
                    .padding(.top, 8)

                Text("Your Android phone, beautifully at home on your Mac — calls, messages, files, and your screen in perfect continuity.")
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: 344)
                    .padding(.top, 16)

                Button {
                    state.showWelcome = false
                    if !pairing.hasPaired {
                        state.showOnboarding = true
                    }
                } label: {
                    Text("Get Started")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "#0A0A0C"))
                        .frame(maxWidth: 380)
                        .frame(height: 52)
                        .background(.white.opacity(0.96), in: Capsule())
                        .shadow(color: .black.opacity(0.26), radius: 16, y: 6)
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .padding(.top, 32)

                Button {
                    state.showWelcome = false
                } label: {
                    Text("Explore on my own")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: 380)
                        .frame(height: 38)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 13)
            }
            .padding(44)
        }
    }
}

/// Pairing sheet — branding panel plus QR code and permission list.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        HStack(spacing: 0) {
            branding
                .frame(width: 340)
            pairingPane
        }
        .frame(width: 840, height: 520)
        .onChange(of: pairing.phase) {
            guard pairing.isConnected else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                state.showOnboarding = false
            }
        }
    }

    private var branding: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text("Welcome to Dogen")
                .font(.system(size: 30, weight: .bold))
                .kerning(-0.5)
                .foregroundStyle(.white)
                .padding(.top, 26)

            Text("Bring iPhone-style continuity to your Android phone. Calls, messages, files, and your screen — right on your Mac.")
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                step(1, "Scan the pairing code", active: !pairing.isConnected)
                step(2, "Open the link on your phone", active: !pairing.isConnected)
                step(3, "You're connected", active: pairing.isConnected)
            }
        }
        .padding(38)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(hex: "#0A84FF"), Color(hex: "#5E5CE6"), Color(hex: "#AF52DE")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func step(_ n: Int, _ label: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.white.opacity(active ? 0.22 : 0.15), in: Circle())
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .opacity(active ? 1 : 0.75)
    }

    private var pairingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pair your phone")
                .font(.system(size: 20, weight: .semibold))
            Text("Point your phone's camera at this code and open the link, then keep the page open. Everything stays on your local network — no account, no cloud.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            HStack(spacing: 26) {
                qrArea
                    .frame(width: 172, height: 172)

                VStack(alignment: .leading, spacing: 10) {
                    SectionCaption(text: "Dogen will access")
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(["Screen mirroring & control", "Calls & call history",
                                 "Messages & contacts", "Notifications & clipboard"], id: \.self) { p in
                            HStack(spacing: 9) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.tint)
                                    .frame(width: 20, height: 20)
                                    .background(.tint.opacity(0.16), in: Circle())
                                Text(p)
                                    .font(.system(size: 13.5))
                            }
                        }
                    }
                }
            }
            .padding(.top, 24)

            if let url = pairing.pairURL, !pairing.isConnected {
                (Text("Or open ").foregroundStyle(.secondary)
                    + Text(url).font(.system(size: 12, design: .monospaced))
                    + Text(" in your phone's browser").foregroundStyle(.secondary))
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.top, 14)
            }

            Spacer()

            HStack {
                HStack(spacing: 7) {
                    if pairing.isConnected {
                        LiveDot(size: 8)
                        Text("Connected to \(pairing.deviceName ?? "phone")")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.green)
                    } else {
                        LiveDot(color: Palette.orange, size: 8)
                        Text("Waiting for phone…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    state.showOnboarding = false
                } label: {
                    Text(pairing.isConnected ? "Done" : "Skip for now")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 26)
                        .frame(height: 38)
                        .background(.tint, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97))
            }
            .padding(.top, 20)
        }
        .padding(.top, 40)
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pairing.phase)
    }

    @ViewBuilder
    private var qrArea: some View {
        if pairing.isConnected {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Palette.green)
                Text(pairing.deviceName ?? "Phone")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if let url = pairing.pairURL {
            QRCodeView(string: url)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Waiting for Wi-Fi…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Incoming call banner, top-right.
struct IncomingCallBanner: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var wiggle = false

    private var displayName: String { state.callerName.isEmpty ? "Unknown" : state.callerName }
    private var initials: String {
        let parts = state.callerName.split(separator: " ").compactMap(\.first)
        return parts.isEmpty ? "?" : parts.prefix(2).map(String.init).joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Avatar(initials: initials, tint: Color(hex: "#FF9500"), size: 50)
                    .rotationEffect(.degrees(wiggle ? 6 : -6))
                    .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: wiggle)
                    .onAppear { wiggle = true }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dogen · \(pairing.deviceName ?? "Phone")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(displayName)
                        .font(.system(size: 16, weight: .semibold))
                    if !state.callerNumber.isEmpty {
                        Text(state.callerNumber)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            HStack(spacing: 9) {
                callButton("Decline", symbol: "phone.down.fill", color: Palette.red) {
                    state.declineCall()
                }
                callButton("Accept", symbol: "phone.fill", color: Palette.green) {
                    state.acceptCall()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 358)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.28), radius: 25, y: 12)
    }

    private func callButton(_ label: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(color, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Centered in-call panel with call controls.
struct InCallPanel: View {
    @EnvironmentObject var state: AppState
    @State private var seconds = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var duration: String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var displayName: String { state.callerName.isEmpty ? "Unknown" : state.callerName }
    private var initials: String {
        let parts = state.callerName.split(separator: " ").compactMap(\.first)
        return parts.isEmpty ? "?" : parts.prefix(2).map(String.init).joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            Avatar(initials: initials, tint: Color(hex: "#FF9500"), size: 88)
                .shadow(color: Color(hex: "#FF9500").opacity(0.35), radius: 12, y: 8)
                .padding(.top, 30)
            Text(displayName)
                .font(.system(size: 21, weight: .semibold))
                .padding(.top, 16)
            HStack(spacing: 6) {
                LiveDot()
                Text("\(duration) · Dogen")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, 3)

            // Mute / speaker / hold / DTMF all require the default-dialer role,
            // which we deliberately don't take — so they're not shown. What a
            // companion app can do from here is end the call and jump to mirror.
            HStack(spacing: 30) {
                CallControl(symbol: "rectangle.on.rectangle", label: "mirror", active: false) {
                    state.nav = .mirror
                }
            }
            .padding(.top, 26)

            Button {
                state.endCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Palette.red, in: Circle())
                    .shadow(color: Palette.red.opacity(0.4), radius: 9, y: 6)
            }
            .buttonStyle(PressableStyle())
            .help("End call")
            .padding(.vertical, 24)
        }
        .frame(width: 326)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 40, y: 24)
        .onReceive(timer) { _ in seconds += 1 }
    }
}

/// A single in-call control button; fills white when its state is active
/// (e.g. muted or speaker on), mirroring the iOS in-call look.
private struct CallControl: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(active ? Color(hex: "#0A0A0C") : .primary)
                    .frame(width: 62, height: 62)
                    .background(active ? AnyShapeStyle(.white) : AnyShapeStyle(.quaternary.opacity(0.5)),
                               in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

/// Menu bar popover — device status, ongoing call, and quick actions.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DeviceGlyph(size: 40, corner: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        if pairing.isConnected {
                            LiveDot()
                            Text(pairing.battery.map { "Connected · Wi-Fi · \($0)%" } ?? "Connected · Wi-Fi")
                        } else if pairing.hasPaired {
                            LiveDot(color: Palette.orange)
                            Text("Not connected")
                        } else {
                            Text("Open Dogen to pair")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            if state.inCall {
                HStack(spacing: 11) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.callerName.isEmpty ? "Ongoing call" : state.callerName)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Ongoing call")
                            .font(.system(size: 11))
                            .opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Button("End") { state.endCall() }
                        .font(.system(size: 12, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(.white.opacity(0.25), in: Capsule())
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Palette.green, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(12)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                quickTile("Mirror", symbol: "rectangle.on.rectangle", nav: .mirror)
                quickTile("Send File", symbol: "square.and.arrow.up", nav: .files)
                quickTile("Messages", symbol: "message", nav: .messages)
                quickTile("Clipboard", symbol: "clipboard", nav: .clipboard)
            }
            .padding(12)

            Button {
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Open Dogen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 302)
    }

    private func quickTile(_ label: String, symbol: String, nav: NavItem) -> some View {
        Button {
            state.nav = nav
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
