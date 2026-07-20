import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detail
                .navigationTitle(state.nav.label)
        }
        .overlay(alignment: .topTrailing) {
            if state.incomingCall {
                IncomingCallBanner()
                    .padding(.top, 44)
                    .padding(.trailing, 22)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if state.inCall {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .transition(.opacity)
                    InCallPanel()
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
        }
        .overlay {
            if state.showWelcome {
                WelcomeView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView()
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.incomingCall)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.inCall)
        .animation(.easeOut(duration: 0.3), value: state.showWelcome)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: state.contentAvailable)
        .onReceive(pairing.$hasPaired) { state.setPhonePaired($0) }
        .onReceive(pairing.$liveContacts) { state.liveContacts = $0 }
        .onReceive(pairing.$liveRecents) { state.liveRecents = $0 }
        .onReceive(pairing.$callPhase) { phase in
            // The phone's telephony state is the single source of truth for
            // the incoming-call banner and in-call panel.
            switch phase {
            case .ringing: state.incomingCall = true; state.inCall = false
            case .active:  state.incomingCall = false; state.inCall = true
            case .idle:    state.incomingCall = false; state.inCall = false
            }
        }
        .onReceive(pairing.$callerNumber) { number in
            state.callerNumber = number
            state.callerName = state.liveContacts.first { $0.number == number }?.name
                ?? (number.isEmpty ? "" : number)
        }
        .onReceive(pairing.$muted) { state.muted = $0 }
        .onReceive(pairing.$speaker) { state.speaker = $0 }
        .onChange(of: pairing.mirrorFrame != nil) { _, hasFrame in
            if hasFrame { openWindow(id: "mirror") }
        }
        .onAppear {
            state.onDial = { pairing.dial($0) }
            state.onAnswer = { pairing.answerCall() }
            state.onHangup = { pairing.hangup() }
            state.onSetMute = { pairing.setMute($0) }
            state.onSetSpeaker = { pairing.setSpeaker($0) }
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

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.nav) {
                ForEach(NavItem.allCases) { item in
                    Label {
                        Text(item.label)
                    } icon: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(item.chip, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .badge(state.badge(for: item))
                    .tag(item)
                }
            }
            .listStyle(.sidebar)

            connectionCard
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 238)
    }

    private var connectionCard: some View {
        Card {
            HStack(spacing: 11) {
                DeviceGlyph()
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if pairing.isConnected {
                            LiveDot()
                            Text(batteryText.map { "Connected · \($0)" } ?? "Connected · Wi-Fi")
                        } else if pairing.hasPaired {
                            LiveDot(color: Palette.orange)
                            Text("Not connected")
                        } else {
                            Text("Click to pair a phone")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if pairing.isConnected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 13))
                        .foregroundStyle(.tint)
                }
            }
            .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !pairing.isConnected { state.showOnboarding = true }
        }
        .help(pairing.isConnected ? "Connected" : "Open pairing")
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.2), value: pairing.phase)
    }

    private var batteryText: String? {
        pairing.battery.map { "Battery \($0)%" }
    }
}

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

/// Header bar used at the top of each screen (52pt, hairline separator).
struct ScreenHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}
