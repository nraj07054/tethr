import SwiftUI

/// Notifications — mirrored Android notifications with inline reply.
struct NotificationsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Notifications") {
                Button("Clear All") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        state.clearNotifications()
                    }
                }
                .controlSize(.small)
                .disabled(state.notifications.isEmpty)
            }
            if !state.contentAvailable {
                PairPrompt(symbol: "bell.badge",
                           title: "Notifications, Mirrored",
                           caption: "Scan the QR code with your phone to see its notifications and reply from your Mac.")
            } else if state.notifications.isEmpty {
                EmptyState(symbol: "bell.slash",
                           title: "All Caught Up",
                           caption: "New notifications from your phone will appear here.")
            } else {
                ScrollView {
                    VStack(spacing: 11) {
                        ForEach(state.notifications) { n in
                            NotificationCard(notification: n)
                                .transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.notifications.count)
    }
}

private struct NotificationCard: View {
    @EnvironmentObject var state: AppState
    let notification: AppNotification
    @State private var reply = ""
    @State private var hovering = false

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: notification.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(notification.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(notification.app.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(notification.when)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Text(notification.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(notification.body)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if notification.canReply {
                        HStack(spacing: 8) {
                            TextField("Reply…", text: $reply)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                            Button {
                                reply = ""
                            } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.tint, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, 5)
                        .frame(height: 32)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                        .padding(.top, 9)
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
        }
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        state.dismissNotification(notification.id)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                }
                .buttonStyle(PressableStyle())
                .offset(x: 7, y: -7)
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
                    .font(.system(size: 14))
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.body)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    Text("From \(clip.source) · \(clip.when)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
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
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        if copied {
                            Text("Copied")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(copied ? AnyShapeStyle(Palette.green) : AnyShapeStyle(.secondary))
                    .contentShape(Rectangle())
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
            ScreenHeader(title: "Contacts") {
                if !state.contacts.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 11)
                    .frame(width: 200, height: 30)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            if state.contacts.isEmpty {
                if state.contentAvailable {
                    EmptyState(symbol: "person.crop.circle",
                               title: "No Contacts Yet",
                               caption: "Contacts will sync here once the Dogen phone app is installed on your phone.")
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filtered) { c in
                            ContactRow(contact: c)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct ContactRow: View {
    @EnvironmentObject var state: AppState
    let contact: Contact

    var body: some View {
        HStack(spacing: 13) {
            Avatar(initials: contact.initials, tint: contact.tint, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(contact.number)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.nav = .messages
            } label: {
                Image(systemName: "message")
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.quaternary.opacity(0.4), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Message \(contact.first)")
            Button {
                state.dial(contact.number)
            } label: {
                Image(systemName: "phone.fill")
                    .foregroundStyle(Palette.green)
                    .frame(width: 34, height: 34)
                    .background(.quaternary.opacity(0.4), in: Circle())
            }
            .buttonStyle(PressableStyle())
            .help("Call \(contact.first)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .hoverHighlight()
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}

/// File Transfer — active transfer, dropzone, and files on the phone.
struct FilesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var pairing: PairingManager

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "File Transfer") {
                if state.contentAvailable {
                    Button(pairing.deviceName ?? "Phone") {}
                        .controlSize(.small)
                }
            }
            if state.contentAvailable {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        dropzone
                        phoneFiles
                            .frame(width: 300)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            } else {
                PairPrompt(symbol: "folder",
                           title: "Move Files Both Ways",
                           caption: "Scan the QR code with your phone, then drag files here to send them across.")
            }
        }
    }

    private var activeTransfer: some View {
        Card {
            HStack(spacing: 13) {
                Text("IMG")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Palette.purple, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Kyoto-2024.zip → Mac")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("18.2 MB of 44 MB · 12s left")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: 0.41)
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var dropzone: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 58, height: 58)
                .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
            VStack(spacing: 3) {
                Text("Drag files here to send")
                    .font(.system(size: 14, weight: .semibold))
                Text("Drop photos, videos, or documents to transfer to \(pairing.deviceName ?? "your phone")")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(.separator)
        )
    }

    private var phoneFiles: some View {
        Card {
            VStack(spacing: 0) {
                SectionCaption(text: "On \(pairing.deviceName ?? "Phone")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                if state.files.isEmpty {
                    Text("Files from your phone will appear here\nonce the Dogen phone app syncs.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.files) { f in
                            HStack(spacing: 11) {
                                Image(systemName: f.glyph)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(f.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text("\(f.size) · \(f.when)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(6)
                }
                }
            }
        }
    }
}

/// Universal Clipboard — synced clipboard history.
struct ClipboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Universal Clipboard") {
                if !state.clips.isEmpty {
                    Button("Clear History") {}
                        .controlSize(.small)
                }
            }
            if state.clips.isEmpty {
                if state.contentAvailable {
                    EmptyState(symbol: "clipboard",
                               title: "Nothing Copied Yet",
                               caption: "Clipboard history will sync here once the Dogen phone app is installed on your phone.")
                } else {
                    PairPrompt(symbol: "clipboard",
                               title: "One Clipboard, Two Devices",
                               caption: "Scan the QR code with your phone — anything you copy will sync both ways.")
                }
            } else {
                clipList
            }
        }
    }

    private var clipList: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 7) {
                        LiveDot(size: 7)
                        Text("Synced both ways with Pixel 8 Pro · last copied just now")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(state.clips) { clip in
                            ClipRow(clip: clip)
                        }
                    }
                }
                .frame(maxWidth: 660)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
