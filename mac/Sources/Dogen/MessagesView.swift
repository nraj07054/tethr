import SwiftUI

/// Messages — thread list plus conversation, "SMS via Pixel 8 Pro".
struct MessagesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @State private var draft = ""
    @State private var search = ""
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
                HStack(spacing: 0) {
                    threadList
                        .frame(width: 296)
                    Divider().opacity(0.6)
                    conversation(thread)
                }
            } else {
                VStack(spacing: 0) {
                    ScreenHeader(title: "Messages")
                    if state.contentAvailable {
                        EmptyState(symbol: "message",
                                   title: "No Messages Yet",
                                   caption: "Conversations will appear here once the Dogen phone app syncs your texts.")
                    } else {
                        PairPrompt(symbol: "message",
                                   title: "Texts on Your Mac",
                                   caption: "Scan the QR code with your phone and your conversations will appear here.")
                    }
                }
            }
        }
        .onAppear { state.markThreadRead(state.selectedThread) }
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Messages") {
                Button {
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New message")
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredThreads) { thread in
                        ThreadRow(thread: thread, selected: state.selectedThread == thread.id)
                            .onTapGesture {
                                state.selectThread(thread.id)
                                draftFocused = true
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
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
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Avatar(initials: thread.initials, tint: thread.tint, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.name)
                        .font(.system(size: 14, weight: .semibold))
                    Text("SMS · via \(pairing.deviceName ?? "phone")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.dial(state.contacts.first { $0.name == thread.name }?.number ?? "")
                } label: {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
                .help("Call \(thread.name)")
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(thread.messages) { m in
                            HStack {
                                if m.me { Spacer(minLength: 60) }
                                Text(m.text)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(m.me ? .white : .primary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 8)
                                    .background(
                                        m.me ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                        in: UnevenRoundedRectangle(
                                            topLeadingRadius: 19,
                                            bottomLeadingRadius: m.me ? 19 : 6,
                                            bottomTrailingRadius: m.me ? 6 : 19,
                                            topTrailingRadius: 19,
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
                    .padding(.horizontal, 22)
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
                    .focused($draftFocused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.tint, in: Circle())
                        .opacity(canSend ? 1 : 0.35)
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend)
                .help("Send")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(height: 38)
            .background(.background.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
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

private struct ThreadRow: View {
    let thread: MessageThread
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Avatar(initials: thread.initials, tint: thread.tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(thread.when)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(thread.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if thread.unread > 0 {
                        Circle().fill(.tint).frame(width: 9, height: 9)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            selected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .hoverHighlight(cornerRadius: 11)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: thread.unread)
    }
}
