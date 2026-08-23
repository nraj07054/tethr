import SwiftUI

/// Notifications — mirrored Android notifications with inline reply.
struct NotificationsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Notifications",
                         subtitle: state.notifications.isEmpty
                            ? "Everything from your phone, quietly"
                            : "\(state.notifications.count) waiting for you") {
                if !state.notifications.isEmpty {
                    CircleIconButton(symbol: "xmark", hint: "Clear all") {
                        // Clear them on the phone too — a notification that
                        // only vanished here would come straight back.
                        for n in state.notifications { pairing.dismissNotification(n.key) }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            state.clearNotifications()
                        }
                    }
                }
            }
            if !state.contentAvailable {
                PairPrompt(symbol: "bell.badge",
                           title: "Notifications, Mirrored",
                           caption: "Scan the QR code with your phone to see its notifications and reply from your Mac.")
            } else if pairing.isConnected && !pairing.notificationAccess {
                EmptyState(symbol: "bell.badge.slash",
                           title: "Notification Access Needed",
                           caption: "On your phone, open Settings → Notification access and turn on Tethr. Notifications will start appearing here straight away.")
            } else if state.notifications.isEmpty {
                EmptyState(symbol: "bell.slash",
                           title: "All Caught Up",
                           caption: "New notifications from your phone will appear here.")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 11) {
                        ForEach(state.notifications) { n in
                            NotificationCard(notification: n)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: 660)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.notifications.count)
    }
}

private struct NotificationCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    let notification: AppNotification
    @State private var reply = ""
    @State private var hovering = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 13) {
                AppIcon(pkg: notification.pkg, symbol: notification.symbol,
                        tint: notification.tint, size: 42, radius: 14)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(notification.app)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Glide.inkSoft)
                        Spacer()
                        Text(notification.when)
                            .font(.system(size: 11))
                            .foregroundStyle(Glide.inkFaint)
                    }
                    Text(notification.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                    Text(notification.body)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .foregroundStyle(Glide.inkSoft)
                    if notification.canReply {
                        HStack(spacing: 8) {
                            TextField("Reply…", text: $reply)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Glide.ink)
                            Button {
                                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                pairing.replyToNotification(notification.key, text: text)
                                reply = ""
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(Glide.onInk)
                                    .frame(width: 26, height: 26)
                                    .background(Glide.inkFill, in: Circle())
                            }
                            .buttonStyle(PressableStyle())
                        }
                        .padding(.leading, 15)
                        .padding(.trailing, 5)
                        .frame(height: 36)
                        .background(Glide.surfaceAlt, in: Capsule())
                        .padding(.top, 11)
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    pairing.dismissNotification(notification.key)
                    // Remove locally for instant feedback; the phone's own
                    // removal message arrives moments later and is idempotent.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        state.dismissNotification(notification.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Glide.onInk)
                        .frame(width: 22, height: 22)
                        .background(Glide.inkFill, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .offset(x: 8, y: -8)
                .transition(.scale.combined(with: .opacity))
                .help("Dismiss")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

private struct ClipRow: View {
    let clip: ClipItem
    @State private var copied = false

    var body: some View {
        Card {
            HStack(spacing: 13) {
                Image(systemName: clip.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Glide.ink)
                    .frame(width: 42, height: 42)
                    .background(Glide.surfaceAlt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.body)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Glide.ink)
                        .lineLimit(1)
                    Text("From \(clip.source) · \(clip.when)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Glide.inkSoft)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(clip.body, forType: .string)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.easeOut(duration: 0.2)) { copied = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(copied ? Palette.green : Glide.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Glide.surfaceAlt, in: Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(copied)
                .help("Copy to Mac clipboard")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }
}

/// Contacts — searchable list with message/call actions.
struct ContactsView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""

    private var filtered: [Contact] {
        search.isEmpty
            ? state.contacts
            : state.contacts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Contacts",
                         subtitle: state.contacts.isEmpty
                            ? "Everyone from your phone's address book"
                            : "\(state.contacts.count) people, synced from your phone") {
                if !state.contacts.isEmpty {
                    SearchField(placeholder: "Search", text: $search, width: 220)
                }
            }
            if state.contacts.isEmpty {
                if state.contentAvailable {
                    EmptyState(symbol: "person.crop.circle",
                               title: "No Contacts Yet",
                               caption: "Contacts sync here once the Tethr app on your phone has permission to read them.")
                } else {
                    PairPrompt(symbol: "person.crop.circle",
                               title: "Contacts on Your Mac",
                               caption: "Scan the QR code with your phone and your contacts will sync here.")
                }
            } else if filtered.isEmpty {
                EmptyState(symbol: "person.crop.circle.badge.questionmark",
                           title: "No Contacts Found",
                           caption: "No contacts match “\(search)”. Try a different name.")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 9) {
                        ForEach(filtered) { c in
                            ContactRow(contact: c)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ContactRow: View {
    @EnvironmentObject var state: AppState
    let contact: Contact
    @State private var hovering = false

    var body: some View {
        Card {
            HStack(spacing: 13) {
                Thumb(initials: contact.initials, tint: contact.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                    Text(contact.number)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Glide.inkSoft)
                }
                Spacer()
                Button {
                    state.nav = .messages
                } label: {
                    Image(systemName: "message.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Glide.ink)
                        .frame(width: 36, height: 36)
                        .background(Glide.surfaceAlt, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Message \(contact.first)")
                Button {
                    state.dial(contact.number)
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(hovering ? Glide.onInk : Glide.ink)
                        .frame(width: 36, height: 36)
                        .background(hovering ? Glide.inkFill : Glide.surfaceAlt, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .help("Call \(contact.first)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// File Transfer — dropzone plus the files sitting on the phone.
struct FilesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager
    @EnvironmentObject var files: FileTransfers
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "File Transfer",
                         subtitle: "Move photos, videos and documents both ways") {
                if state.contentAvailable {
                    if files.transfers.contains(where: { $0.state != .running }) {
                        CircleIconButton(symbol: "trash", hint: "Clear finished") {
                            files.clearFinished()
                        }
                    }
                    StatusPill(label: pairing.deviceName ?? "Phone",
                               color: pairing.isConnected ? Palette.green : Palette.orange)
                }
            }
            if state.contentAvailable {
                HStack(alignment: .top, spacing: 18) {
                    dropzone
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transferList
                        .frame(width: 340)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            } else {
                PairPrompt(symbol: "folder",
                           title: "Move Files Both Ways",
                           caption: "Scan the QR code with your phone, then drag files here to send them across.")
            }
        }
    }

    private var dropzone: some View {
        VStack(spacing: 0) {
            Image(systemName: hovering ? "arrow.down.circle.fill" : "square.and.arrow.up")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(hovering ? Palette.green : Glide.ink)
                .frame(width: 66, height: 66)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Glide.surface)
                        .shadow(color: Glide.cardShadow, radius: 14, y: 6)
                }
            Text(hovering ? "Drop to send" : "Drag files here to send")
                .font(.system(size: 16, weight: .bold))
                .kerning(-0.2)
                .foregroundStyle(Glide.ink)
                .padding(.top, 16)
            Text("They land in Downloads on \(pairing.deviceName ?? "your phone").")
                .font(.system(size: 13))
                .foregroundStyle(Glide.inkSoft)
                .padding(.top, 6)

            Button("Choose Files…") { pick() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Glide.onInk)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(Glide.inkFill, in: Capsule())
                .padding(.top, 18)
                .disabled(!pairing.isConnected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(hovering ? Palette.green : Glide.inkFaint.opacity(0.5))
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        // The drop target accepts real file URLs only — dragging text or an
        // image out of a browser would otherwise look accepted and do nothing.
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            guard pairing.isConnected else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in files.send(url) }
                }
            }
            return true
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { files.send($0) }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionCaption(text: "Transfers")
            if files.transfers.isEmpty {
                Card {
                    Text("Nothing sent yet. Files from your phone arrive here too.")
                        .font(.system(size: 13))
                        .foregroundStyle(Glide.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 9) {
                        ForEach(files.transfers) { TransferRow(transfer: $0) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer

    private var subtitle: String {
        switch transfer.state {
        case .running:
            return "\(Self.bytes(transfer.moved)) of \(Self.bytes(transfer.size))"
        case .done:
            return transfer.direction == .toPhone ? "Sent · \(Self.bytes(transfer.size))"
                                                  : "Saved to Downloads"
        case .failed(let why):
            return why
        }
    }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: transfer.direction == .toPhone
                      ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Glide.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Glide.inkSoft)
                    if transfer.state == .running {
                        ProgressView(value: transfer.fraction)
                            .progressViewStyle(.linear)
                            .tint(Glide.inkFill)
                    }
                }
                Spacer(minLength: 0)
                if transfer.state == .done, let url = transfer.url {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Glide.ink)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .running: Glide.inkSoft
        case .done: Palette.green
        case .failed: Palette.red
        }
    }

    /// Sizes people can read at a glance, not exact byte counts.
    private static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Universal Clipboard — synced clipboard history.
struct ClipboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Clipboard",
                         subtitle: "Copy on one device, paste on the other") {
                CircleIconButton(symbol: "arrow.clockwise", hint: "Fetch the phone's clipboard") {
                    pairing.requestClipboard()
                }
            }
            if state.clips.isEmpty {
                if state.contentAvailable {
                    EmptyState(symbol: "clipboard",
                               title: "Nothing Copied Yet",
                               caption: "Clipboard history syncs here once the Tethr app on your phone starts sharing it.")
                } else {
                    PairPrompt(symbol: "clipboard",
                               title: "One Clipboard, Two Devices",
                               caption: "Scan the QR code with your phone — anything you copy will sync both ways.")
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        StatusPill(label: "Synced both ways with \(pairing.deviceName ?? "your phone")")
                        VStack(spacing: 9) {
                            ForEach(state.clips) { clip in
                                ClipRow(clip: clip)
                            }
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { pairing.requestClipboard() }
    }
}
