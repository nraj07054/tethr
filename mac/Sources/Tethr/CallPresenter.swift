import AppKit
import Combine
import SwiftUI

/// The app's live objects, owned outside SwiftUI.
///
/// These used to be `@StateObject`s wired together in `ContentView.onAppear`,
/// which quietly tied the whole link to a window existing. That breaks exactly
/// where it matters most: launched at login Tethr comes up hidden, no window is
/// ever built, `onAppear` never runs — and the Mac would sit there paired but
/// deaf to calls, notifications and the clipboard. Starting from the app
/// delegate instead means the link is live whether or not anything is on screen.
@MainActor
final class AppCore {
    static let shared = AppCore()

    let state = AppState()
    let pairing = PairingManager()
    let clipboard = ClipboardWatcher()
    let files = FileTransfers()
    private lazy var bridge = LinkBridge(state: state, pairing: pairing)
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        bridge.start()
        // Commands out to the phone, wired here for the same reason the state
        // coming back is: these used to be set in ContentView.onAppear, so
        // until a window had been opened once they were all nil — and Decline
        // on the floating call panel quietly dismissed the banner without ever
        // telling the phone to reject anything. Launched at login, which is how
        // Tethr is meant to run, that was every call.
        state.onDial = { [pairing] in pairing.dial($0) }
        state.onAnswer = { [pairing] in pairing.answerCall() }
        state.onHangup = { [pairing] in pairing.hangup() }
        state.onSetMute = { [pairing] in pairing.setMute($0) }
        state.onSetSpeaker = { [pairing] in pairing.setSpeaker($0) }
        state.onSendMessage = { [pairing] address, text, subId in
            pairing.sendSms(to: address, text: text, subId: subId)
        }
        state.onThreadRead = { [pairing] in pairing.markThreadRead($0) }
        state.onHideCallCard = { [bridge] in bridge.hideCallCard() }
        clipboard.attach(to: pairing)
        // Wired here rather than in a view: a file can arrive whether or not
        // any window is open, and it needs somewhere to land either way.
        files.attach(to: pairing)
        pairing.files = files
    }
}

/// Mirrors the phone's live state into [AppState], independently of any window.
///
/// This bridging used to live in ContentView's `.onReceive` modifiers, which
/// tied it to the main window's lifetime: close the window and the Mac stopped
/// noticing calls, contacts and notifications altogether. Tethr is meant to run
/// with its window closed, so the link's state has to be owned above the window,
/// not inside one.
@MainActor
final class LinkBridge: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private let state: AppState
    private let pairing: PairingManager
    private let calls: CallPresenter

    init(state: AppState, pairing: PairingManager) {
        self.state = state
        self.pairing = pairing
        self.calls = CallPresenter(state: state, pairing: pairing)
    }

    func start() {
        // Waking is the one moment the Mac knows its picture of the phone may
        // be wrong: call state is pushed on transitions, and any transition
        // that happened while this machine was asleep was sent into a dead
        // socket. Without asking, a call that ended overnight is still on
        // screen in the morning, timer and all.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pairing.requestState() }
        }
        // Same reasoning for a link that dropped and came back: the phone sends
        // a snapshot once it has verified a Mac, and this covers a socket that
        // was replaced without the phone re-running that path.
        pairing.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard phase == .connected else { return }
                self?.pairing.requestState()
            }
            .store(in: &cancellables)

        pairing.$hasPaired.sink { [state] in state.setPhonePaired($0) }.store(in: &cancellables)
        pairing.$liveContacts.sink { [state] in state.liveContacts = $0 }.store(in: &cancellables)
        pairing.$liveRecents.sink { [state] in state.liveRecents = $0 }.store(in: &cancellables)
        pairing.$liveNotifications.sink { [state] in state.notifications = $0 }.store(in: &cancellables)
        pairing.$liveClips.sink { [state] in state.liveClips = $0 }.store(in: &cancellables)
        // Threads replace wholesale rather than merge: the phone sends each
        // conversation as it now stands, and its row ids keep SwiftUI from
        // treating an updated thread as a brand-new one.
        pairing.$liveThreads.sink { [state] in state.applyThreads($0) }.store(in: &cancellables)
        pairing.$liveSims.sink { [state] in state.sims = $0 }.store(in: &cancellables)
        pairing.$muted.sink { [state] in state.muted = $0 }.store(in: &cancellables)
        pairing.$speaker.sink { [state] in state.speaker = $0 }.store(in: &cancellables)

        pairing.$callerNumber
            .sink { [state, pairing] number in
                state.applyCaller(number: number, name: pairing.callerName)
            }
            .store(in: &cancellables)
        pairing.$callerName
            .sink { [state, pairing] name in
                state.applyCaller(number: pairing.callerNumber, name: name)
            }
            .store(in: &cancellables)

        pairing.$callPhase
            .removeDuplicates()
            .sink { [weak self] phase in self?.apply(phase) }
            .store(in: &cancellables)
    }

    /// The phone's telephony state is the single source of truth for the
    /// incoming-call banner and the in-call panel.
    ///
    /// It reports one state for the whole phone, though, so it cannot say
    /// "ringing *while* another call is up" — which is why deciding what that
    /// means for the two panels is left to AppState, the only place that knows
    /// whether there was already a call underneath.
    private func apply(_ phase: PairingManager.CallPhase) {
        switch phase {
        case .ringing:
            state.markCallRinging()
        case .active:
            // Answered, and we know exactly when — but only because we watched
            // it ring first. See AppState.callConnectedAt.
            state.markCallActive(answeredNow: previousPhase == .ringing)
        case .idle:
            state.markCallIdle()
        }
        previousPhase = phase
        calls.update(for: phase)
    }

    private var previousPhase: PairingManager.CallPhase = .idle

    /// Forwarded from AppState's hide button.
    func hideCallCard() { calls.hide() }
}

/// Puts a ringing or ongoing call on screen whether or not Tethr's window is open.
///
/// A floating panel rather than a SwiftUI scene: it has to appear over whatever
/// you are working in, without pulling you out of it. `orderFrontRegardless`
/// shows it while Tethr stays in the background, and a non-activating panel lets
/// Answer and Decline be clicked without bringing the whole app forward.
@MainActor
final class CallPresenter {
    private let state: AppState
    private let pairing: PairingManager
    private var panel: CallPanel?

    init(state: AppState, pairing: PairingManager) {
        self.state = state
        self.pairing = pairing
    }

    func update(for phase: PairingManager.CallPhase) {
        switch phase {
        case .idle:
            panel?.orderOut(nil)
        case .ringing, .active:
            // Dismissed for this call: the phone may keep reporting it, but the
            // card was asked to go away and should stay away.
            guard !state.callCardHidden else { return }
            show(compact: phase == .ringing)
        }
    }

    /// Sends the card away without touching the call.
    func hide() { panel?.orderOut(nil) }

    private func show(compact: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // One size for both states: the card is the same shape ringing or
        // connected, so resizing mid-call would only make it jump. Roomy enough
        // for the card's shadow, since the window itself is transparent.
        _ = compact
        // Sized to the card itself now that it fills the window: no padding is
        // needed for a shadow the window draws outside its own frame.
        //
        // A notification's proportions, not a dialog's. The old 360x172 came
        // from stacking a 58pt avatar above a full-width button row, which made
        // a card that sat over your work for the length of a call and looked
        // like it wanted answering rather than glancing at. Actions moved
        // beside the caller, so this is roughly a system banner: 344x90.
        let size = NSSize(width: 336, height: 86)
        panel.setContentSize(size)
        positionTopRight(panel, size: size)
        // Regardless: the window shows even though Tethr is not the active app,
        // which is the entire point of it.
        panel.orderFrontRegardless()
    }

    private func positionTopRight(_ panel: CallPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - size.width - 24,
                             y: visible.maxY - size.height - 24)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> CallPanel {
        let content = CallWindowContent()
            .environmentObject(state)
            .environmentObject(pairing)

        // Borderless, not .titled: a titled panel keeps window chrome and a
        // title-bar inset even with the title hidden, and its frame does not
        // line up with the rounded card drawn inside it.
        let panel = CallPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 336, height: 86)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: content)
        panel.isMovableByWindowBackground = true
        // The window draws the shadow, outside its own frame, so the card can
        // fill the window edge to edge with no transparent margin to show
        // through. The ragged silhouette this used to produce came from a
        // mostly-transparent window with a small card floating in the middle;
        // a card that fills it gives the compositor a clean rounded rect.
        panel.hasShadow = true
        panel.level = .floating
        // Survives Tethr losing focus, and follows you between Spaces — a call
        // is not something to leave behind on desktop 1.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// A borderless panel still has to be able to take key status, or the Accept
/// and Decline buttons would not respond to the first click.
private final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel's contents: the same banner and in-call panel the main window uses.
private struct CallWindowContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            if state.incomingCall {
                IncomingCallBanner()
            } else if state.inCall {
                InCallPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Applied in the body, not at construction: the panel is built once and
        // has to follow the accent if it changes mid-session.
        .tint(state.accent)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.incomingCall)
    }
}
