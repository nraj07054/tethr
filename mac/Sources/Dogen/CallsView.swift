import SwiftUI

/// Calls — favorites and recents on the left, dial pad on the right.
struct CallsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Calls")
            if state.contentAvailable {
                HSplitLayout()
            } else {
                PairPrompt(symbol: "phone.arrow.down.left",
                           title: "Calls on Your Mac",
                           caption: "Scan the QR code with your phone to make and take calls from here.")
            }
        }
    }
}

private struct HSplitLayout: View {
    var body: some View {
        HStack(spacing: 0) {
            RecentsPane()
                .frame(maxWidth: .infinity)
            Divider().opacity(0.6)
            DialPadPane()
                .frame(width: 320)
        }
    }
}

private struct RecentsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.recents.isEmpty {
            EmptyState(symbol: "clock.arrow.circlepath",
                       title: "No Call History Yet",
                       caption: "Favorites and recent calls will sync here once the Dogen phone app is installed. The dial pad is ready when you are.")
        } else {
            history
        }
    }

    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !state.favorites.isEmpty {
                    SectionCaption(text: "Favorites")
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(state.favorites) { c in
                                Button {
                                    state.dial(c.number)
                                } label: {
                                    VStack(spacing: 8) {
                                        Avatar(initials: c.initials, tint: c.tint, size: 54)
                                            .shadow(color: c.tint.opacity(0.3), radius: 6, y: 3)
                                        Text(c.first)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(width: 66)
                                }
                                .buttonStyle(PressableStyle())
                                .help("Call \(c.first)")
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                    .padding(.bottom, 24)
                }

                SectionCaption(text: "Recents")
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                LazyVStack(spacing: 0) {
                    ForEach(state.recents) { r in
                        RecentRow(call: r)
                    }
                }
                .padding(.horizontal, 18)
            }
            .padding(.vertical, 16)
        }
    }
}

/// Circular caller avatar — initials when we have a name, a phone glyph otherwise.
private struct CallAvatar: View {
    let call: RecentCall
    var size: CGFloat = 42

    var body: some View {
        Group {
            if call.initials.isEmpty {
                Image(systemName: "phone.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(call.tint.gradient, in: Circle())
            } else {
                Text(call.initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(call.tint.gradient, in: Circle())
            }
        }
    }
}

private struct RecentRow: View {
    @EnvironmentObject var state: AppState
    let call: RecentCall
    @State private var hovering = false

    private var isMissed: Bool { call.direction == .missed }

    var body: some View {
        HStack(spacing: 13) {
            CallAvatar(call: call)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isMissed ? Palette.red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Image(systemName: call.direction.symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(isMissed ? Palette.red : .secondary)
                    Text(call.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(call.when)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Button {
                state.dial(call.number)
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.green)
                    .frame(width: 32, height: 32)
                    .background(Palette.green.opacity(0.15), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .opacity(hovering ? 1 : 0.001)
            .help("Call \(call.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.13), value: hovering)
    }
}

private struct DialPadPane: View {
    @EnvironmentObject var state: AppState

    private let keys: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Group {
                if state.dialpad.isEmpty {
                    Text("Enter a number")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(state.dialpad)
                        .font(.system(size: 32, weight: .light))
                        .kerning(1)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText())
                }
            }
            .frame(height: 44)
            .frame(minWidth: 200, maxWidth: 254)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: state.dialpad)

            let cols = Array(repeating: GridItem(.fixed(74), spacing: 16), count: 3)
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(keys, id: \.0) { key in
                    DialKey(key: key) {
                        state.dialpad += key.0
                    }
                }
            }

            HStack(spacing: 26) {
                Color.clear.frame(width: 64, height: 64)
                Button {
                    state.dial(state.dialpad)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Palette.green, in: Circle())
                        .shadow(color: Palette.green.opacity(state.dialpad.isEmpty ? 0 : 0.4), radius: 9, y: 6)
                        .opacity(state.dialpad.isEmpty ? 0.4 : 1)
                }
                .buttonStyle(PressableStyle())
                .disabled(state.dialpad.isEmpty)
                .help("Call")
                Button {
                    if !state.dialpad.isEmpty { state.dialpad.removeLast() }
                } label: {
                    Image(systemName: "delete.backward")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(state.dialpad.isEmpty)
                .opacity(state.dialpad.isEmpty ? 0.35 : 1)
                .help("Delete")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DialKey: View {
    let key: (String, String)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(key.0)
                    .font(.system(size: 26))
                Text(key.1)
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
                    .frame(height: 10)
            }
            .frame(width: 74, height: 74)
            .background(
                hovering ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.background.opacity(0.55)),
                in: Circle()
            )
            .overlay(Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
