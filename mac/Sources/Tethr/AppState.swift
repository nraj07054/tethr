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
    /// Empty until a thread is picked or one arrives; `currentThread` falls
    /// back to the newest, so the pane is never blank when there is mail.
    @Published var selectedThread: MessageThread.ID = ""
    @Published var threads: [MessageThread] = []
    @Published var notifications: [AppNotification] = []
    /// True once a phone is paired — unlocks screen content.
    @Published var contentAvailable = false

    // Live data synced from the phone (bridged from PairingManager).
    @Published var liveContacts: [Contact] = []
    @Published var liveRecents: [RecentCall] = []
    @Published var liveClips: [ClipItem] = []
    /// The phone's SIMs, when it has more than one.
    @Published var sims: [SimCard] = []

    // Current call presentation (driven by the phone's telephony state).
    @Published var callerName: String = ""
    @Published var callerNumber: String = ""
    /// When the call was actually answered, if that is knowable.
    ///
    /// It is only knowable for an incoming call: the phone reports "ringing"
    /// and then "offhook", and that transition *is* the moment of answering.
    /// An outgoing call goes straight to "offhook" the instant it is dialled —
    /// Android does not tell a third-party app when the far end picks up — so
    /// timing from there would count ringing the phone's own timer never does.
    @Published var callConnectedAt: Date?

    /// The connected call, held aside for as long as a second one is ringing.
    ///
    /// Android reports one telephony state and one caller for the whole phone,
    /// so a call arriving during another looks identical to a call arriving out
    /// of the blue: the state goes to "ringing" and the caller is overwritten
    /// with the new number. Taking that at face value threw the call already in
    /// progress away — decline the interruption and the panel had nothing left
    /// to show, because the call underneath it had been forgotten while it rang.
    /// Keeping it here means declining call waiting puts the first call back,
    /// with the caller it actually has and a timer that never restarted.
    private var ongoing: (name: String, number: String, connectedAt: Date?)?

    /// Who is on the line, ignoring anyone currently ringing through.
    var ongoingCallerName: String { ongoing?.name ?? callerName }

    // In-call audio state (reflects what the phone reports).
    @Published var muted = false
    @Published var speaker = false

    // Actions routed to the phone; wired up by ContentView.
    var onDial: ((String) -> Void)?
    var onAnswer: (() -> Void)?
    var onHangup: (() -> Void)?
    var onSetMute: ((Bool) -> Void)?
    var onSetSpeaker: ((Bool) -> Void)?
    /// (address, text, subId) — routed to the phone, which actually sends it.
    /// `subId` names the SIM; -1 leaves the choice to the phone's default.
    var onSendMessage: ((String, String, Int) -> Void)?
    var onThreadRead: ((String) -> Void)?
    /// Sends the floating call card away. The call is untouched.
    var onHideCallCard: (() -> Void)?

    /// Who is calling. The phone resolves the name against its own address book,
    /// which is the reliable answer; matching the synced contacts is the
    /// fallback for a number it couldn't place, and showing the bare number
    /// beats showing "Unknown".
    func applyCaller(number: String, name: String) {
        callerNumber = number
        if !name.isEmpty {
            callerName = name
        } else if !number.isEmpty {
            callerName = liveContacts.first { $0.number.matchesPhoneNumber(number) }?.name ?? number
        } else {
            callerName = ""
        }
    }

    // Flip immediately for a snappy UI; the phone confirms the real state back.
    func toggleMute() { muted.toggle(); onSetMute?(muted) }
    func toggleSpeaker() { speaker.toggle(); onSetSpeaker?(speaker) }

    private var phonePaired = false

    init() {}

    /// Driven by PairingManager; content unlocks after the QR pairing completes.
    func setPhonePaired(_ paired: Bool) {
        phonePaired = paired
        contentAvailable = paired
        // A phone that is already paired means setup happened at some point —
        // reinstalling Tethr shouldn't put someone back through the intro.
        if paired, showWelcome {
            UserDefaults.standard.set(true, forKey: Self.seenWelcomeKey)
            showWelcome = false
        }
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
    var clips: [ClipItem] { liveClips }

    /// Places a call on the phone.
    func dial(_ number: String) {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onDial?(trimmed)
    }

    // Overlays
    /// First-run only. A welcome screen that greets you every launch stops
    /// being a welcome and becomes a door to push past, so once someone has
    /// been through it Tethr opens straight into the app.
    @Published var showWelcome: Bool = !UserDefaults.standard.bool(forKey: AppState.seenWelcomeKey)
    @Published var showOnboarding = false
    /// Guards the one-shot "not paired yet, offer the QR" nudge on launch.
    private var offeredPairing = false

    static let seenWelcomeKey = "hasSeenWelcome"

    /// Leaves the welcome screen for good.
    func finishWelcome(pairNext: Bool) {
        UserDefaults.standard.set(true, forKey: Self.seenWelcomeKey)
        showWelcome = false
        offeredPairing = true
        if pairNext { showOnboarding = true }
    }

    /// On a later launch that is still unpaired, put the QR in front of them
    /// rather than leaving every screen saying "scan the QR code" with no QR.
    func offerPairingIfNeeded(isPaired: Bool) {
        guard !offeredPairing else { return }
        offeredPairing = true
        guard !showWelcome, !isPaired else { return }
        showOnboarding = true
    }
    @Published var incomingCall = false
    @Published var inCall = false

    // Dialpad
    @Published var dialpad = ""

    // MARK: Appearance
    //
    // @Published rather than @AppStorage. @AppStorage is a DynamicProperty
    // built for use inside a View: in an ObservableObject it reads and writes
    // UserDefaults perfectly well but never fires objectWillChange, so nothing
    // observing this object redraws. That is why picking a theme or an accent
    // stored the choice and changed nothing on screen — not even the swatch's
    // own selection ring.
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "Light" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }
    @Published var accentIndex: Int = UserDefaults.standard.integer(forKey: "accentIndex") {
        didSet { UserDefaults.standard.set(accentIndex, forKey: "accentIndex") }
    }

    var colorScheme: ColorScheme { appearance == "Dark" ? .dark : .light }
    /// Clamped: a stored index outlives the list it points into if the choices
    /// are ever changed, and an out-of-range read would crash on launch.
    var accent: Color {
        Palette.accentChoices[min(max(accentIndex, 0), Palette.accentChoices.count - 1)].color
    }

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

    /// Starts a conversation that has no thread yet.
    ///
    /// Nothing is added locally: the phone has to write the message before a
    /// thread id exists, and inventing one here would leave a placeholder that
    /// the phone's own copy could never merge with. It comes back as a real
    /// thread within a beat, and is selected then.
    func startMessage(to address: String, text: String, subId: Int) {
        let number = address.trimmingCharacters(in: .whitespaces)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, !trimmed.isEmpty else { return }
        awaitingThreadFor = number
        onSendMessage?(number, trimmed, subId)
    }

    /// The recipient of a message sent before its thread existed, so the thread
    /// can be opened as soon as the phone reports it.
    private var awaitingThreadFor: String?

    /// Called when a fresh set of threads arrives from the phone.
    func applyThreads(_ incoming: [MessageThread]) {
        threads = incoming
        guard let wanted = awaitingThreadFor else { return }
        let digits = wanted.filter(\.isNumber)
        if let match = incoming.first(where: {
            $0.address == wanted || (!digits.isEmpty && $0.address.filter(\.isNumber).hasSuffix(digits))
        }) {
            selectedThread = match.id
            awaitingThreadFor = nil
        }
    }

    func markThreadRead(_ id: MessageThread.ID) {
        guard let i = threads.firstIndex(where: { $0.id == id }), threads[i].unread > 0 else { return }
        threads[i].unread = 0
        // Clear it on the phone too, so reading on the Mac does not leave the
        // notification sitting in the shade.
        onThreadRead?(id)
    }

    /// Sends `text` to the open thread, through the phone's own radio.
    ///
    /// The bubble is added straight away and the phone echoes the real row back
    /// a moment later, replacing it. Waiting for that round trip instead would
    /// leave the composer looking broken on a slow link.
    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = threads.firstIndex(where: { $0.id == currentThread?.id }) else { return }
        let stamp = Date.now.formatted(date: .omitted, time: .shortened)
        threads[i].messages.append(
            // Prefixed so it cannot collide with a provider row id, and so the
            // echo that replaces it is not mistaken for a second message.
            Message(id: "pending-\(UUID().uuidString)", me: true, text: trimmed, when: stamp)
        )
        threads[i].preview = trimmed
        threads[i].when = stamp
        // Replies leave from the SIM the conversation is already on.
        onSendMessage?(threads[i].address, trimmed, threads[i].subId)
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
        // Answering during another call puts that one on hold, so the call on
        // the line is now this one — it, not the held call, is what the panel
        // goes back to when the phone next reports in.
        if ongoing != nil { ongoing = (callerName, callerNumber, Date()) }
        onAnswer?()
    }

    /// Reject a ringing call or hang up the active one on the phone.
    func endCall() {
        inCall = false
        ongoing = nil
        onHangup?()
    }

    func declineCall() {
        incomingCall = false
        // Declining call waiting leaves the first call up. Restore it here
        // rather than waiting for the phone to say so: the next report arrives
        // carrying the *declined* caller's number, and until it lands there is
        // nothing on screen at all.
        if ongoing != nil {
            inCall = true
            resumeOngoingCall()
        }
        onHangup?()
    }

    // MARK: Call phase, as reported by the phone

    /// True once the card has been dismissed for the current call, so it stays
    /// away until a new one starts.
    private(set) var callCardHidden = false

    /// Dismisses the floating card for this call only.
    func hideCallCard() {
        callCardHidden = true
        onHideCallCard?()
    }

    /// A call is ringing. Only clears the in-call panel when there was no call
    /// to begin with — otherwise this is call waiting over a live call.
    func markCallRinging() {
        // A new call earns the card back, however firmly the last one was
        // dismissed — otherwise hiding once would silently cost every call
        // after it.
        if ongoing == nil { callCardHidden = false }
        incomingCall = true
        guard ongoing == nil else { return }
        inCall = false
        callConnectedAt = nil
    }

    /// A call is connected. Either the one that was already up coming back
    /// after an interruption, or a new one to hold on to.
    ///
    /// - Parameter answeredNow: true when the phone went straight from ringing
    ///   to offhook, which is the moment an incoming call was picked up.
    func markCallActive(answeredNow: Bool) {
        // An outgoing call reaches here without ringing first; it is new too.
        if ongoing == nil { callCardHidden = false }
        incomingCall = false
        inCall = true
        if ongoing != nil {
            resumeOngoingCall()
        } else {
            callConnectedAt = answeredNow ? Date() : nil
            ongoing = (callerName, callerNumber, callConnectedAt)
        }
    }

    /// The phone is idle: no call, ringing or otherwise.
    func markCallIdle() {
        callCardHidden = false
        incomingCall = false
        inCall = false
        callConnectedAt = nil
        ongoing = nil
    }

    private func resumeOngoingCall() {
        guard let ongoing else { return }
        callerName = ongoing.name
        callerNumber = ongoing.number
        callConnectedAt = ongoing.connectedAt
    }
}
