import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case mirror, calls, messages, notifications, files, contacts, clipboard, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mirror: "Phone Mirroring"
        case .calls: "Calls"
        case .messages: "Messages"
        case .notifications: "Notifications"
        case .files: "File Transfer"
        case .contacts: "Contacts"
        case .clipboard: "Clipboard"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .mirror: "rectangle.on.rectangle"
        case .calls: "phone.fill"
        case .messages: "message.fill"
        case .notifications: "bell.badge.fill"
        case .files: "folder.fill"
        case .contacts: "person.crop.circle.fill"
        case .clipboard: "clipboard.fill"
        case .settings: "slider.horizontal.3"
        }
    }

    var chip: LinearGradient {
        let colors: [Color] = switch self {
        case .mirror: [Color(hex: "#5B8DEF"), Color(hex: "#3567D6")]
        case .calls: [Color(hex: "#34C759"), Color(hex: "#28A745")]
        case .messages: [Color(hex: "#34C759"), Color(hex: "#25A150")]
        case .notifications: [Color(hex: "#FF453A"), Color(hex: "#E0352B")]
        case .files: [Color(hex: "#5AC8FA"), Color(hex: "#0A84FF")]
        case .contacts: [Color(hex: "#AF8BFF"), Color(hex: "#8A5CF6")]
        case .clipboard: [Color(hex: "#FF9F0A"), Color(hex: "#F57C00")]
        case .settings: [Color(hex: "#8E8E93"), Color(hex: "#636366")]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var nav: NavItem = .mirror
    @Published var selectedThread: MessageThread.ID = UUID()
    @Published var threads: [MessageThread] = []
    @Published var notifications: [AppNotification] = []
    /// True once a phone is paired — unlocks screen content.
    @Published var contentAvailable = false

    // Live data synced from the phone (bridged from PairingManager).
    @Published var liveContacts: [Contact] = []
    @Published var liveRecents: [RecentCall] = []

    // Current call presentation (driven by the phone's telephony state).
    @Published var callerName: String = ""
    @Published var callerNumber: String = ""

    // In-call audio state (reflects what the phone reports).
    @Published var muted = false
    @Published var speaker = false

    // Actions routed to the phone; wired up by ContentView.
    var onDial: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onHangup: (() -> Void)?
    var onSetMute: ((Bool) -> Void)?
    var onSetSpeaker: ((Bool) -> Void)?

    // Flip immediately for a snappy UI; the phone confirms the real state back.
    func toggleMute() { muted.toggle(); onSetMute?(muted) }
    func toggleSpeaker() { speaker.toggle(); onSetSpeaker?(speaker) }

    private var phonePaired = false

    init() {}

    /// Driven by PairingManager; content unlocks after the QR pairing completes.
    func setPhonePaired(_ paired: Bool) {
        phonePaired = paired
        contentAvailable = paired
    }

    // All screen content comes from the live phone link.
    var recents: [RecentCall] { liveRecents }
    /// Favorites = your most recent *named* callers (deduped), like iOS —
    /// more useful than an alphabetical slice of the address book.
    var favorites: [Contact] {
        var seen = Set<String>()
        var result: [Contact] = []
        for call in liveRecents where !call.initials.isEmpty {
            let key = call.number.isEmpty ? call.name : call.number
            guard seen.insert(key).inserted else { continue }
            result.append(Contact(name: call.name, number: call.number, tint: call.tint))
            if result.count == 6 { break }
        }
        return result
    }
    var contacts: [Contact] { liveContacts }
    var files: [FileItem] { [] }
    var clips: [ClipItem] { [] }

    /// Places a call on the phone.
    func dial(_ number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onDial?(trimmed)
    }

    // Overlays
    @Published var showWelcome = true
    @Published var showOnboarding = false
    @Published var incomingCall = false
    @Published var inCall = false

    // Dialpad
    @Published var dialpad = ""

    // Appearance
    @AppStorage("appearance") var appearance: String = "Light"
    @AppStorage("accentIndex") var accentIndex: Int = 0

    var colorScheme: ColorScheme { appearance == "Dark" ? .dark : .light }
    var accent: Color { Palette.accentChoices[accentIndex].color }

    var currentThread: MessageThread? {
        threads.first { $0.id == selectedThread } ?? threads.first
    }

    var unreadMessages: Int { threads.reduce(0) { $0 + $1.unread } }

    func badge(for item: NavItem) -> Int {
        switch item {
        case .messages: unreadMessages
        case .notifications: notifications.count
        default: 0
        }
    }

    func selectThread(_ id: MessageThread.ID) {
        selectedThread = id
        markThreadRead(id)
    }

    func markThreadRead(_ id: MessageThread.ID) {
        guard let i = threads.firstIndex(where: { $0.id == id }), threads[i].unread > 0 else { return }
        threads[i].unread = 0
    }

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = threads.firstIndex(where: { $0.id == selectedThread }) else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        threads[i].messages.append(Message(me: true, text: trimmed, when: stamp))
        threads[i].preview = trimmed
        threads[i].when = stamp
    }

    func dismissNotification(_ id: AppNotification.ID) {
        notifications.removeAll { $0.id == id }
    }

    func clearNotifications() {
        notifications.removeAll()
    }

    /// Answer the ringing call on the phone.
    func acceptCall() {
        incomingCall = false
        onAnswer?()
    }

    /// Reject a ringing call or hang up the active one on the phone.
    func endCall() {
        inCall = false
        onHangup?()
    }

    func declineCall() {
        incomingCall = false
        onHangup?()
    }
}
