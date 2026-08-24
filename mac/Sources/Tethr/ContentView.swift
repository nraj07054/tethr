import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 250)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Glide.canvas)
        // The call UI is a floating panel owned by CallPresenter, shown whether
        // or not this window exists — drawing it here too would double it up.
        .overlay {
            if state.showWelcome {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView()
        }
        .onAppear { state.offerPairingIfNeeded(isPaired: pairing.hasPaired) }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.incomingCall)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.inCall)
        .animation(.easeOut(duration: 0.3), value: state.showWelcome)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.contentAvailable)
        // All pairing -> state bridging now lives in LinkBridge, above the
        // window: this view is torn down whenever the window closes, and a
        // closed window must not stop the Mac noticing calls.
        .onChange(of: pairing.mirrorFrame != nil) { _, hasFrame in
            if hasFrame { openWindow(id: "mirror") }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.nav {
        case .mirror: MirrorView()
        case .calls: CallsView()
        case .messages: MessagesView()
        case .notifications: NotificationsView()
        case .files: FilesView()
        case .contacts: ContactsView()
        case .clipboard: ClipboardView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
                // Clears the hidden title bar's traffic lights.
                .padding(.top, 40)
                .padding(.horizontal, 18)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(NavItem.allCases) { item in
                        NavRow(item: item,
                               selected: state.nav == item,
                               badge: state.badge(for: item)) {
                            state.nav = item
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 22)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            connectionCard
        }
        .frame(maxHeight: .infinity)
    }

    private var wordmark: some View {
        HStack(spacing: 11) {
            BrandMark(size: 40, corner: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tethr")
                    .font(.system(size: 21, weight: .bold))
                    .kerning(-0.5)
                    .foregroundStyle(Glide.ink)
                Text("Your phone, on your Mac")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Glide.inkSoft)
            }
        }
    }

    private var connectionCard: some View {
        Card {
            HStack(spacing: 11) {
                DeviceGlyph(size: 36, corner: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if pairing.isConnected {
                            LiveDot()
                            Text(pairing.battery.map { "Connected · \($0)%" } ?? "Connected · Wi-Fi")
                        } else if pairing.hasPaired {
                            LiveDot(color: Palette.orange)
                            Text("Not connected")
                        } else {
                            Text("Tap to pair a phone")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Glide.inkSoft)
                }
                Spacer(minLength: 2)
                Image(systemName: pairing.isConnected ? "checkmark" : "qrcode")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pairing.isConnected ? Palette.green : Glide.ink)
                    .frame(width: 28, height: 28)
                    .background(Glide.surfaceAlt, in: Circle())
            }
            .padding(11)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !pairing.isConnected { state.showOnboarding = true }
        }
        .help(pairing.isConnected ? "Connected" : "Open pairing")
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.2), value: pairing.phase)
    }
}

/// A sidebar destination — an ink capsule with a white icon puck when selected,
/// echoing the floating nav pill in the Tethr design language.
private struct NavRow: View {
    let item: NavItem
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Glide.ink : Glide.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(selected ? Glide.onInk : Glide.surface, in: Circle())
                Text(item.label)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Glide.onInk : Glide.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? Glide.ink : Glide.onInk)
                        .padding(.horizontal, 7)
                        .frame(height: 19)
                        .background(selected ? Glide.onInk : Glide.inkFill, in: Capsule())
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 44)
            .background {
                // The selected destination is the accent's main home. The
                // default choice is Ink, so this looks unchanged until someone
                // actually picks a colour.
                Capsule()
                    .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(hovering ? Glide.surface : Color.clear))
                    .shadow(color: selected ? Glide.cardShadow : .clear, radius: 12, y: 5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selected)
        .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

// MARK: - Screen chrome

/// Locked-screen prompt shown on feature screens before a phone is paired.
struct PairPrompt: View {
    @EnvironmentObject var state: AppState
    let symbol: String
    let title: String
    let caption: String

    var body: some View {
        EmptyState(symbol: symbol, title: title, caption: caption,
                   actionLabel: "Show QR Code") {
            state.showOnboarding = true
        }
    }
}

/// Big-title header used at the top of each screen.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 27, weight: .bold))
                    .kerning(-0.7)
                    .foregroundStyle(Glide.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Glide.inkSoft)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
