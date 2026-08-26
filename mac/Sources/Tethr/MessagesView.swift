import SwiftUI

/// Messages — thread list plus conversation, sent as SMS through the phone.
struct MessagesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var draft = ""
    @State private var search = ""
    @State private var composing = false
    @FocusState private var draftFocused: Bool

    private var filteredThreads: [MessageThread] {
        search.isEmpty
            ? state.threads
            : state.threads.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.preview.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        Group {
            if let thread = state.currentThread {
                HStack(alignment: .top, spacing: 18) {
                    threadList
                        .frame(width: 296)
                    conversation(thread)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 26)
                .padding(.top, 34)
                .padding(.bottom, 26)
            } else {
                VStack(spacing: 0) {
                    ScreenHeader(title: "Messages", subtitle: "Texts from your phone, typed on a real keyboard")
                    if state.contentAvailable {
                        VStack(spacing: 16) {
                            EmptyState(symbol: "message",
                                       title: "No Messages Yet",
                                       caption: "Conversations appear here once the Tethr app on your phone syncs your texts.")
                            // Without this there is no way to reach the composer
                            // at all until a text happens to arrive.
                            Button { composing = true } label: {
                                Text("New Message")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Glide.onInk)
                                    .padding(.horizontal, 18)
                                    .frame(height: 34)
                                    .background(Glide.inkFill, in: Capsule())
                            }
                            .buttonStyle(PressableStyle())
                        }
                    } else {
                        PairPrompt(symbol: "message",
                                   title: "Texts on Your Mac",
                                   caption: "Scan the QR code with your phone and your conversations will appear here.")
                    }
                }
            }
        }
        .onAppear { state.markThreadRead(state.selectedThread) }
        .sheet(isPresented: $composing) {
            NewMessageSheet { address, text, subId in
                state.startMessage(to: address, text: text, subId: subId)
            }
            .environmentObject(state)
        }
    }

    private var threadList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Messages")
                    .font(.system(size: 27, weight: .bold))
                    .kerning(-0.7)
                    .foregroundStyle(Glide.ink)
                Spacer()
                CircleIconButton(symbol: "square.and.pencil", hint: "New message") {
                    composing = true
                }
            }

            SearchField(placeholder: "Search", text: $search)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(filteredThreads) { thread in
                        ThreadRow(thread: thread, selected: state.selectedThread == thread.id)
                            .onTapGesture {
                                state.selectThread(thread.id)
                                draftFocused = true
                            }
                    }
                }
                .padding(.bottom, 8)
            }
            .overlay {
                if filteredThreads.isEmpty {
                    EmptyState(symbol: "magnifyingglass",
                               title: "No Results",
                               caption: "No conversations match “\(search)”.")
                }
            }
        }
    }

    private func conversation(_ thread: MessageThread) -> some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Thumb(initials: thread.initials, tint: thread.tint, size: 40, radius: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Glide.ink)
                        Text(thread.sim.isEmpty
                             ? "SMS · via \(pairing.deviceName ?? "your phone")"
                             : "SMS · \(thread.sim) · via \(pairing.deviceName ?? "your phone")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Glide.inkSoft)
                    }
                    Spacer()
                    Button {
                        state.dial(state.contacts.first { $0.name == thread.name }?.number ?? "")
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Glide.ink)
                            .frame(width: 36, height: 36)
                            .background(Glide.surfaceAlt, in: Circle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Call \(thread.name)")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider().opacity(0.35)

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 7) {
                            ForEach(thread.messages) { m in
                                HStack {
                                    if m.me { Spacer(minLength: 60) }
                                    Text(m.text)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(m.me ? Glide.onInk : Glide.ink)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 10)
                                        .background(
                                            m.me ? AnyShapeStyle(Glide.inkFill) : AnyShapeStyle(Glide.surfaceAlt),
                                            in: UnevenRoundedRectangle(
                                                topLeadingRadius: 20,
                                                bottomLeadingRadius: m.me ? 20 : 7,
                                                bottomTrailingRadius: m.me ? 7 : 20,
                                                topTrailingRadius: 20,
                                                style: .continuous
                                            )
                                        )
                                        .transition(.scale(scale: 0.92, anchor: m.me ? .bottomTrailing : .bottomLeading)
                                            .combined(with: .opacity))
                                    if !m.me { Spacer(minLength: 60) }
                                }
                                .id(m.id)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                    }
                    .onAppear { proxy.scrollTo(thread.messages.last?.id, anchor: .bottom) }
                    .onChange(of: thread.id) {
                        proxy.scrollTo(state.currentThread?.messages.last?.id, anchor: .bottom)
                    }
                    .onChange(of: thread.messages.count) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                            proxy.scrollTo(thread.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: thread.messages.count)

                HStack(spacing: 8) {
                    TextField("Text Message", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Glide.ink)
                        .focused($draftFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Glide.onInk)
                            .frame(width: 30, height: 30)
                            .background(Glide.inkFill, in: Circle())
                            .opacity(canSend ? 1 : 0.3)
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(!canSend)
                    .help("Send")
                }
                .padding(.leading, 18)
                .padding(.trailing, 6)
                .frame(height: 42)
                .background(Glide.surfaceAlt, in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        state.sendMessage(draft)
        draft = ""
        draftFocused = true
    }
}

/// Starting a conversation that does not exist yet.
///
/// Recipients come from the synced address book, but the field takes a typed
/// number too — a first text often goes to someone who is not saved yet, and
/// requiring a contact first would be the wrong way round.
private struct NewMessageSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let send: (String, String, Int) -> Void

    @State private var to = ""
    @State private var body_ = ""
    @State private var subId = -1
    @FocusState private var toFocused: Bool

    /// Contacts matching what has been typed, by name or by number.
    private var suggestions: [Contact] {
        let q = to.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        // Nothing to suggest once the typed text *is* the chosen recipient.
        if state.contacts.contains(where: { $0.number == q }) { return [] }
        return Array(
            state.contacts.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.number.filter(\.isNumber).contains(q.filter(\.isNumber))
            }.prefix(5)
        )
    }

    private var address: String { to.trimmingCharacters(in: .whitespaces) }
    private var canSend: Bool {
        !address.isEmpty && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Message")
                .font(.system(size: 19, weight: .bold))
                .kerning(-0.3)
                .foregroundStyle(Glide.ink)

            VStack(alignment: .leading, spacing: 8) {
                Text("To")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Glide.inkSoft)
                TextField("Name or number", text: $to)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($toFocused)
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .background(Glide.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                ForEach(suggestions) { contact in
                    Button {
                        to = contact.number
                        toFocused = false
                    } label: {
                        HStack(spacing: 10) {
                            Thumb(initials: contact.initials, tint: contact.tint, size: 28, radius: 9)
                            Text(contact.name)
                                .font(.system(size: 13))
                                .foregroundStyle(Glide.ink)
                            Spacer()
                            Text(contact.number)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Glide.inkSoft)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Only shown on a dual-SIM phone: the phone sends an empty list
            // when there is nothing to choose between.
            if state.sims.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Send from")
                        .font(.system(size: 11, weight: .semibold))
                        .kerning(0.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Glide.inkSoft)
                    Picker("", selection: $subId) {
                        ForEach(state.sims) { sim in
                            Text("SIM \(sim.slot) · \(sim.label)").tag(sim.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Message")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Glide.inkSoft)
                TextEditor(text: $body_)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 96)
                    .background(Glide.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Glide.inkSoft)
                Button {
                    send(address, body_, subId)
                    dismiss()
                } label: {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Glide.onInk)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Glide.inkFill, in: Capsule())
                        .opacity(canSend ? 1 : 0.4)
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(Glide.surface)
        .onAppear {
            toFocused = true
            // Default to the first SIM rather than -1, so the segmented control
            // never opens with nothing selected.
            if subId < 0, let first = state.sims.first { subId = first.id }
        }
    }
}

private struct ThreadRow: View {
    let thread: MessageThread
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Thumb(initials: thread.initials, tint: thread.tint, size: 44, radius: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(selected ? Glide.onInk : Glide.ink)
                        .lineLimit(1)
                    Spacer()
                    Text(thread.when)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Glide.onInk.opacity(0.7) : Glide.inkFaint)
                }
                HStack(spacing: 6) {
                    Text(thread.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(selected ? Glide.onInk.opacity(0.75) : Glide.inkSoft)
                        .lineLimit(1)
                    Spacer()
                    if thread.unread > 0 {
                        Text("\(thread.unread)")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(selected ? Glide.ink : Glide.onInk)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(selected ? Glide.onInk : Glide.inkFill, in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .fill(selected ? Glide.inkFill : Glide.surface)
                .shadow(color: Glide.cardShadow, radius: selected ? 14 : 8, y: 4)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: selected)
        .animation(.easeOut(duration: 0.18), value: thread.unread)
    }
}
