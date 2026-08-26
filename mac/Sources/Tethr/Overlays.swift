import SwiftUI

/// First-run welcome.
///
/// Shown once, so it can afford to take a beat and actually explain the product
/// rather than being a splash to dismiss. The staging is deliberate: the link
/// illustration animates first because it says what Tethr *is* faster than the
/// headline does, and the copy then arrives underneath it.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    /// Drives the staggered entrance. Each element keys its delay off this.
    @State private var revealed = false

    private let highlights: [(String, String)] = [
        ("rectangle.on.rectangle", "Mirror & control"),
        ("phone.fill", "Calls"),
        ("bell.badge.fill", "Notifications"),
        ("lock.fill", "Stays on your Wi-Fi"),
    ]

    var body: some View {
        ZStack {
            Glide.canvas.ignoresSafeArea()
            AmbientBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    BrandMark(size: 24, corner: 8)
                    Text("Tethr")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .frame(height: 40)
                .background {
                    Capsule()
                        .fill(Glide.surface)
                        .shadow(color: Glide.cardShadow, radius: 12, y: 5)
                }
                .padding(.bottom, 30)
                .rise(revealed, delay: 0.04)

                DeviceLink()
                    .padding(.bottom, 34)
                    .opacity(revealed ? 1 : 0)
                    .scaleEffect(revealed ? 1 : 0.94)
                    .animation(.spring(response: 0.75, dampingFraction: 0.75), value: revealed)

                Text("Your phone,\nat home on your Mac.")
                    .font(.system(size: 42, weight: .bold))
                    .kerning(-1.3)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Glide.ink)
                    .rise(revealed, delay: 0.10)

                Text("Calls, notifications, clipboard and your screen — streamed straight across your own Wi-Fi. No account, no cloud.")
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Glide.inkSoft)
                    .frame(maxWidth: 430)
                    .padding(.top, 14)
                    .rise(revealed, delay: 0.18)

                HStack(spacing: 9) {
                    ForEach(Array(highlights.enumerated()), id: \.element.0) { i, item in
                        HStack(spacing: 7) {
                            Image(systemName: item.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Glide.inkSoft)
                            Text(item.1)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Glide.ink)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background {
                            Capsule()
                                .fill(Glide.surface)
                                .shadow(color: Glide.cardShadow, radius: 8, y: 3)
                        }
                        // Chips arrive one after another, left to right, so the
                        // row reads as a list rather than appearing as a block.
                        .rise(revealed, delay: 0.26 + Double(i) * 0.06)
                    }
                }
                .padding(.top, 28)

                InkButton(label: "Get Started", height: 52) {
                    state.finishWelcome(pairNext: !pairing.hasPaired)
                }
                .frame(width: 300)
                .padding(.top, 34)
                .rise(revealed, delay: 0.52)

                Button {
                    state.finishWelcome(pairNext: false)
                } label: {
                    Text("Explore on my own")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Glide.inkSoft)
                        .frame(width: 300, height: 38)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .rise(revealed, delay: 0.58)
            }
            .padding(44)
        }
        .onAppear { revealed = true }
    }
}

private extension View {
    /// The entrance every element on the welcome screen shares: up and in.
    func rise(_ on: Bool, delay: Double) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 14)
            .animation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay), value: on)
    }
}

/// Two soft colour fields drifting behind the content.
///
/// Slow and low-contrast on purpose — it should register as depth, not as an
/// animation competing with the copy for attention.
private struct AmbientBackdrop: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            // Two named brand hues rather than whatever accent happens to be
            // selected: the default accent is a near-grey, and at low opacity
            // it reads as a smudge on the canvas instead of as colour.
            blob(Color(hex: "#5B8DEF"), size: 460)
                .offset(x: drift ? -180 : -240, y: drift ? -150 : -110)
            blob(Palette.orange, size: 380)
                .offset(x: drift ? 210 : 260, y: drift ? 140 : 180)
        }
        .onAppear { drift = true }
        .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true), value: drift)
        .allowsHitTesting(false)
    }

    private func blob(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(colors: [color.opacity(0.28), color.opacity(0)],
                               center: .center, startRadius: 0, endRadius: size / 2)
            )
            .frame(width: size, height: size)
            .blur(radius: 34)
    }
}

/// A Mac and a phone with something travelling between them.
///
/// This is the whole product in one glyph, and it does the job the headline
/// cannot do at a glance: the pulse repeatedly leaving the phone and arriving at
/// the Mac is what "tethered" looks like.
private struct DeviceLink: View {
    @State private var travelling = false
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 0) {
            // Equal-width boxes: the laptop glyph is far wider than the phone,
            // so without them the pair sits visibly left of the text below.
            device("laptopcomputer", size: 62).frame(width: 96)
            track
            device("iphone", size: 46).frame(width: 96)
        }
        .frame(height: 96)
        .onAppear {
            travelling = true
            breathe = true
        }
    }

    private func device(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .light))
            .foregroundStyle(Glide.ink)
            .shadow(color: Glide.cardShadow, radius: 10, y: 5)
            .scaleEffect(breathe ? 1 : 0.985)
            .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: breathe)
    }

    private var track: some View {
        ZStack {
            Capsule()
                .fill(Glide.ink.opacity(0.10))
                .frame(width: 104, height: 3)

            // The pulse runs phone -> Mac: the phone is the source, and seeing
            // it arrive at the Mac is the promise being made.
            Circle()
                .fill(Palette.green)
                .frame(width: 9, height: 9)
                .shadow(color: Palette.green.opacity(0.6), radius: 6)
                .offset(x: travelling ? -52 : 52)
                .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: false),
                           value: travelling)
        }
        .frame(width: 104)
        .padding(.horizontal, 16)
    }
}


/// Pairing sheet — ink branding panel plus QR code and permission list.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        HStack(spacing: 0) {
            branding
                .frame(width: 330)
            pairingPane
        }
        .frame(width: 840, height: 520)
        .background(Glide.surface)
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
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Glide.inkFill)
                .frame(width: 56, height: 56)
                .background(Glide.onInk, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("Pair your phone")
                .font(.system(size: 31, weight: .bold))
                .kerning(-0.9)
                .foregroundStyle(Glide.onInk)
                .padding(.top, 26)

            Text("One scan links the two devices over your local network. Nothing leaves your Wi-Fi.")
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .foregroundStyle(Glide.onInk.opacity(0.72))
                .padding(.top, 12)

            Spacer()

            VStack(alignment: .leading, spacing: 15) {
                step(1, "Open Tethr on your phone", done: pairing.isConnected)
                step(2, "Scan the code on the right", done: pairing.isConnected)
                step(3, "You're connected", done: pairing.isConnected)
            }
        }
        .padding(36)
        .frame(maxHeight: .infinity)
        .background(Glide.inkFill)
    }

    private func step(_ n: Int, _ label: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Glide.inkFill)
                } else {
                    Text("\(n)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Glide.onInk)
                }
            }
            .frame(width: 26, height: 26)
            .background(done ? Glide.onInk : Glide.onInk.opacity(0.16), in: Circle())
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Glide.onInk.opacity(done ? 1 : 0.85))
        }
        .animation(.easeOut(duration: 0.2), value: done)
    }

    private var pairingPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan to connect")
                .font(.system(size: 21, weight: .bold))
                .kerning(-0.4)
                .foregroundStyle(Glide.ink)
            Text("Point your phone's camera at this code and open the link. Keep both devices on the same Wi-Fi network.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Glide.inkSoft)
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 24) {
                qrArea
                    .frame(width: 176, height: 176)

                VStack(alignment: .leading, spacing: 12) {
                    SectionCaption(text: "Tethr will access")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["Screen mirroring & control", "Calls & call history",
                                 "Messages & contacts", "Notifications & clipboard"], id: \.self) { p in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(Glide.onInk)
                                    .frame(width: 20, height: 20)
                                    .background(Glide.inkFill, in: Circle())
                                Text(p)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(Glide.ink)
                            }
                        }
                    }
                }
            }
            .padding(.top, 24)

            if !pairing.isConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No router? Turn on your phone's hotspot and join it from this Mac, or plug in USB and switch on USB tethering — then scan.")
                        .font(.system(size: 11.5))
                        .lineSpacing(2)
                        .foregroundStyle(Glide.inkSoft)
                    if !pairing.addresses.isEmpty {
                        HStack(spacing: 6) {
                            Text("Reachable at")
                                .font(.system(size: 11))
                                .foregroundStyle(Glide.inkFaint)
                            ForEach(pairing.addresses, id: \.self) { ip in
                                Text(ip)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Glide.ink)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(Glide.surfaceAlt, in: Capsule())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.top, 14)
            }

            Spacer()

            HStack {
                if pairing.isConnected {
                    StatusPill(label: "Connected to \(pairing.deviceName ?? "phone")")
                } else {
                    StatusPill(label: "Waiting for phone…", color: Palette.orange)
                }
                Spacer()
                InkButton(label: pairing.isConnected ? "Done" : "Skip for now", height: 42) {
                    state.showOnboarding = false
                }
                .frame(width: 150)
            }
            .padding(.top, 20)
        }
        .padding(.top, 38)
        .padding(.horizontal, 36)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Glide.surface)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: pairing.phase)
    }

    @ViewBuilder
    private var qrArea: some View {
        if pairing.isConnected {
            VStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Palette.green, in: Circle())
                Text(pairing.deviceName ?? "Phone")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Glide.ink)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Glide.surfaceAlt, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if let url = pairing.pairURL {
            // QRCodeView paints its own white card, so it stays scannable in
            // either theme.
            QRCodeView(string: url)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Waiting for Wi-Fi…")
                    .font(.system(size: 12))
                    .foregroundStyle(Glide.inkSoft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Glide.surfaceAlt, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// The look both call cards share, so a ringing phone and a live call read as
/// the same object changing state rather than two different panels.
enum CallCard {
    static var background: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                // A hairline keeps the card's edge readable against a light
                // backdrop, where the material alone almost disappears.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
            }
            // No shadow drawn here on purpose. A shadow inside the window has to
            // be paid for with transparent padding around the card, and that
            // padding is visible as a haze along the edges. macOS draws window
            // shadows outside the frame instead, costing no window area at all —
            // so the panel asks for one and the card fills the window exactly.
    }
}

/// The incoming-call card.
///
/// This no longer sits inside the app's canvas — it floats in its own panel over
/// whatever you happen to be working in, so it is styled to survive that: a
/// vibrant material that sits on any backdrop, a heavier shadow to lift it off
/// the app underneath, and a live pulse so it reads as *ringing* from the corner
/// of the eye rather than as one more static notification.
struct IncomingCallBanner: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var pulse = false

    private var displayName: String {
        state.callerName.isEmpty ? "Unknown caller" : state.callerName
    }

    /// Only worth a line of its own when it says something the name doesn't.
    private var subtitle: String? {
        guard !state.callerNumber.isEmpty, state.callerNumber != displayName else { return nil }
        return state.callerNumber
    }

    private var initials: String {
        let parts = state.callerName.split(separator: " ").compactMap(\.first).filter(\.isLetter)
        return parts.isEmpty ? "?" : parts.prefix(2).map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming · \(pairing.deviceName ?? "Phone")")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.55)
                    .textCase(.uppercase)
                    .foregroundStyle(Glide.inkSoft)
                Text(displayName)
                    .font(.system(size: 15.5, weight: .bold))
                    .kerning(-0.2)
                    .foregroundStyle(Glide.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Glide.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // Round and unlabelled, beside the caller rather than stacked
            // beneath. The words cost a whole row of height, and a red phone
            // dropping and a green one lifting are the two most legible icons
            // in the language.
            roundAction(symbol: "phone.down.fill", fill: Palette.red, hint: "Decline") {
                state.declineCall()
            }
            roundAction(symbol: "phone.fill", fill: Palette.green, hint: "Accept") {
                state.acceptCall()
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CallCard.background)
        .overlay(alignment: .topTrailing) { HideCardButton() }
        .onAppear { pulse = true }
    }

    /// Rings expanding out of the avatar — the visual equivalent of a ringtone,
    /// and what makes the panel catch the eye from across a screen.
    private var avatar: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Palette.green.opacity(0.45), lineWidth: 2)
                    .frame(width: 44, height: 44)
                    // Starts just outside the avatar so a ring is visible even
                    // in the instant before the animation begins.
                    .scaleEffect(pulse ? 1.65 : 1.08)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(
                        .easeOut(duration: 1.9)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.95),
                        value: pulse
                    )
            }
            // Circular, not the app's usual rounded square: it has to match the
            // rings expanding out of it, and a caller reads as a person.
            Thumb(initials: initials, tint: Palette.green, size: 58, radius: 29)
                .shadow(color: Palette.green.opacity(0.35), radius: 10, y: 5)
        }
        .frame(width: 58, height: 58)
    }


    private func actionButton(_ label: String, symbol: String, fill: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .bold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background {
                Capsule()
                    .fill(fill)
                    .shadow(color: fill.opacity(0.4), radius: 9, y: 4)
            }
        }
        .buttonStyle(PressableStyle(scale: 0.96))
    }
}


/// Centered in-call panel with call controls.
/// A round, unlabelled call action — the compact card's answer to a button row.
private func roundAction(symbol: String, fill: Color, hint: String,
                         action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background {
                Circle()
                    .fill(fill)
                    .shadow(color: fill.opacity(0.4), radius: 7, y: 3)
            }
    }
    .buttonStyle(PressableStyle(scale: 0.92))
    .help(hint)
}

/// Sends the floating card away without touching the call.
///
/// The card had no way out: it sat over everything for the whole length of a
/// call, and the only things that dismissed it were answering, declining or
/// hanging up — so staying on a call meant living with it. Hiding is a purely
/// local act. The call carries on, the phone is not told anything, and the next
/// call brings the card back.
private struct HideCardButton: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.hideCallCard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Glide.inkSoft)
                .frame(width: 18, height: 18)
                .background(Glide.surfaceAlt, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Hide — the call keeps going")
        // Quiet but always there. Revealing it only on hover would hide the
        // one control someone goes looking for precisely because the card is
        // in their way.
        .opacity(hovering ? 1 : 0.45)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .padding(7)
        .onHover { hovering = $0 }
    }
}

struct InCallPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Counted from the moment the call was answered, not from when the panel
    /// appeared — the panel can be rebuilt mid-call, and for an outgoing call
    /// there is no answer moment to count from at all.
    private var duration: String? {
        guard let start = state.callConnectedAt else { return nil }
        let elapsed = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private var displayName: String {
        state.callerName.isEmpty ? "Unknown caller" : state.callerName
    }

    private var initials: String {
        let parts = state.callerName.split(separator: " ").compactMap(\.first).filter(\.isLetter)
        return parts.isEmpty ? "?" : parts.prefix(2).map(String.init).joined().uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Thumb(initials: initials, tint: Palette.green, size: 44, radius: 22)
                .shadow(color: Palette.green.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("On a call · \(pairing.deviceName ?? "Phone")")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.55)
                    .textCase(.uppercase)
                    .foregroundStyle(Glide.inkSoft)
                Text(displayName)
                    .font(.system(size: 15.5, weight: .bold))
                    .kerning(-0.2)
                    .foregroundStyle(Glide.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 5) {
                    LiveDot()
                    // No invented duration for an outgoing call: a timer that
                    // disagrees with the phone's own is worse than none.
                    Text(duration ?? "On your phone")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Glide.inkSoft)
                }
            }
            Spacer(minLength: 6)
            // Mute, speaker, hold and DTMF all require the default-dialer role,
            // which Tethr deliberately does not take. Ending the call is the one
            // thing a companion app can genuinely do from here.
            roundAction(symbol: "phone.down.fill", fill: Palette.red, hint: "End call") {
                state.endCall()
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        // Fills the panel exactly. Anything less leaves window showing through
        // around the card, which reads as a stray translucent border.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CallCard.background)
        .overlay(alignment: .topTrailing) { HideCardButton() }
        .onReceive(timer) { now = $0 }
    }
}

/// Menu bar popover — device status, ongoing call, and quick actions.
struct MenuBarPanel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DeviceGlyph(size: 40, corner: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairing.deviceName ?? "No phone paired")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                    HStack(spacing: 5) {
                        if pairing.isConnected {
                            LiveDot()
                            Text(pairing.battery.map { "Connected · \($0)%" } ?? "Connected · Wi-Fi")
                        } else if pairing.hasPaired {
                            LiveDot(color: Palette.orange)
                            Text("Not connected")
                        } else {
                            Text("Open Tethr to pair")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Glide.inkSoft)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            if state.inCall {
                HStack(spacing: 11) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Glide.onInk)
                    VStack(alignment: .leading, spacing: 1) {
                        // The ongoing call's own caller: while a second call
                        // rings through, `callerName` is whoever is ringing.
                        Text(state.ongoingCallerName.isEmpty ? "Ongoing call" : state.ongoingCallerName)
                            .font(.system(size: 13, weight: .semibold))
                        Text("Ongoing call")
                            .font(.system(size: 11))
                            .opacity(0.7)
                    }
                    .foregroundStyle(Glide.onInk)
                    Spacer()
                    Button {
                        state.endCall()
                    } label: {
                        Text("End")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Glide.ink)
                            .padding(.horizontal, 13)
                            .frame(height: 26)
                            .background(Glide.onInk, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.95))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(Glide.inkFill, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                quickTile("Mirror", symbol: "rectangle.on.rectangle", nav: .mirror)
                quickTile("Send File", symbol: "square.and.arrow.up", nav: .files)
                quickTile("Messages", symbol: "message", nav: .messages)
                quickTile("Clipboard", symbol: "clipboard", nav: .clipboard)
            }

            InkButton(label: "Open Tethr", height: 40) { showWindow() }
        }
        .padding(14)
        .frame(width: 306)
        .background(Glide.canvas)
    }

    /// Brings the window back. Tethr keeps running with its window closed, so
    /// by the time someone reaches for the menu bar there may be no window left
    /// to activate — openWindow rebuilds it, and unhide covers a login launch
    /// that came up hidden.
    private func showWindow() {
        NSApp.unhide(nil)
        openWindow(id: TethrApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func quickTile(_ label: String, symbol: String, nav: NavItem) -> some View {
        Button {
            state.nav = nav
            showWindow()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Glide.ink)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Glide.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .fill(Glide.surface)
                    .shadow(color: Glide.cardShadow, radius: 8, y: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
    }
}
