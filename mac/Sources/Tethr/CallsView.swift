import SwiftUI

/// Calls — favourites and filtered recents on the left, dial pad on the right.
struct CallsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    enum Filter: Hashable { case all, missed, incoming, outgoing }
    @State private var filter: Filter = .all

    private var filtered: [RecentCall] {
        switch filter {
        case .all: state.recents
        case .missed: state.recents.filter { $0.direction == .missed }
        case .incoming: state.recents.filter { $0.direction == .incoming }
        case .outgoing: state.recents.filter { $0.direction == .outgoing }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Calls",
                         subtitle: pairing.deviceName.map { "Dialling through \($0)" } ?? "Dial and answer from your Mac") {
                if state.contentAvailable {
                    CircleIconButton(symbol: "arrow.clockwise", hint: "Resync call history") {
                        pairing.requestPhoneData()
                    }
                }
            }

            if state.contentAvailable {
                if !state.recents.isEmpty {
                    ChipBar(options: [(Filter.all, "All"), (.missed, "Missed"),
                                      (.incoming, "Incoming"), (.outgoing, "Outgoing")],
                            selection: $filter)
                        .padding(.bottom, 16)
                }
                HStack(alignment: .top, spacing: 18) {
                    RecentsPane(calls: filtered, unfiltered: state.recents.isEmpty)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    DialPadPane()
                        .frame(width: 312)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
            } else {
                PairPrompt(symbol: "phone.arrow.down.left",
                           title: "Calls on Your Mac",
                           caption: "Scan the QR code with your phone to make and take calls from here.")
            }
        }
    }
}

private struct RecentsPane: View {
    @EnvironmentObject var state: AppState
    let calls: [RecentCall]
    let unfiltered: Bool

    var body: some View {
        if unfiltered {
            EmptyState(symbol: "clock.arrow.circlepath",
                       title: "No Call History Yet",
                       caption: "Favourites and recent calls sync here from your phone. The dial pad is ready when you are.")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if !state.favorites.isEmpty { favourites }
                    recents
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var favourites: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(text: "Quick dial") {
                Text("Your most recent people")
                    .font(.system(size: 12))
                    .foregroundStyle(Glide.inkSoft)
            }
            Card {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(state.favorites) { c in
                            Button {
                                state.dial(c.number)
                            } label: {
                                VStack(spacing: 9) {
                                    Avatar(initials: c.initials, tint: c.tint, size: 52)
                                        .shadow(color: c.tint.opacity(0.28), radius: 8, y: 4)
                                    Text(c.first)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Glide.ink)
                                        .lineLimit(1)
                                }
                                .frame(width: 68)
                            }
                            .buttonStyle(PressableStyle())
                            .help("Call \(c.first)")
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(text: "Recents") {
                Text("\(calls.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Glide.inkSoft)
            }
            if calls.isEmpty {
                Card {
                    Text("Nothing here for this filter.")
                        .font(.system(size: 13))
                        .foregroundStyle(Glide.inkSoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                }
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(calls) { r in
                        RecentRow(call: r)
                    }
                }
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
        Card {
            HStack(spacing: 13) {
                Thumb(initials: call.initials,
                      symbol: call.initials.isEmpty ? "phone.fill" : nil,
                      tint: call.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(call.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(isMissed ? Palette.red : Glide.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Image(systemName: call.direction.symbol)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(isMissed ? Palette.red : Glide.inkFaint)
                        Text(call.label)
                            .font(.system(size: 12))
                            .foregroundStyle(Glide.inkSoft)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(call.when)
                    .font(.system(size: 12))
                    .foregroundStyle(Glide.inkFaint)
                    .layoutPriority(1)
                Button {
                    state.dial(call.number)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(hovering ? Glide.onInk : Glide.ink)
                        .frame(width: 36, height: 36)
                        .background(hovering ? Glide.inkFill : Glide.surfaceAlt, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Call \(call.name)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

private struct DialPadPane: View {
    @EnvironmentObject var state: AppState
    @FocusState private var typing: Bool

    private let keys: [(String, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: "Dial pad")
            Card {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        // A real field, not a label: the keys are for pointing,
                        // but anyone with a number in front of them will type it.
                        ZStack(alignment: .leading) {
                            if state.dialpad.isEmpty {
                                Text("Enter a number")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Glide.inkFaint)
                                    .allowsHitTesting(false)
                            }
                            TextField("", text: $state.dialpad)
                                .textFieldStyle(.plain)
                                .focused($typing)
                                .font(.system(size: 27, weight: .semibold))
                                .kerning(0.5)
                                .monospacedDigit()
                                .foregroundStyle(Glide.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                                // Return dials, so a typed number needs no mouse.
                                .onSubmit { state.dial(state.dialpad) }
                                // Paste a number from anywhere and it arrives
                                // full of spaces, brackets and dashes.
                                .onChange(of: state.dialpad) { _, new in
                                    let cleaned = new.filter { $0.isNumber || "+*#".contains($0) }
                                    if cleaned != new { state.dialpad = cleaned }
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            if !state.dialpad.isEmpty { state.dialpad.removeLast() }
                        } label: {
                            Image(systemName: "delete.backward")
                                .font(.system(size: 14))
                                .foregroundStyle(Glide.inkSoft)
                                .frame(width: 34, height: 34)
                                .contentShape(Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .disabled(state.dialpad.isEmpty)
                        .opacity(state.dialpad.isEmpty ? 0 : 1)
                        .help("Delete")
                    }
                    .frame(height: 40)
                    .animation(.spring(response: 0.25, dampingFraction: 0.85), value: state.dialpad)

                    let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(keys, id: \.0) { key in
                            DialKey(key: key) { state.dialpad += key.0 }
                        }
                    }

                    InkButton(label: "Call", symbol: "phone.fill") {
                        state.dial(state.dialpad)
                    }
                    .opacity(state.dialpad.isEmpty ? 0.4 : 1)
                    .disabled(state.dialpad.isEmpty)
                    .animation(.easeOut(duration: 0.18), value: state.dialpad.isEmpty)
                }
                .padding(16)
            }
        }
    }
}

private struct DialKey: View {
    let key: (String, String)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(key.0)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Glide.ink)
                Text(key.1)
                    .font(.system(size: 8.5, weight: .bold))
                    .kerning(1.2)
                    .foregroundStyle(Glide.inkFaint)
                    .frame(height: 10)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(hovering ? Glide.inkFill.opacity(0.08) : Glide.surfaceAlt,
                        in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.93))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
