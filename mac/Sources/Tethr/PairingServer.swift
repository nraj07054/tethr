import Foundation
import Network
import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import CryptoKit

/// Real local-network pairing backend.
///
/// Runs two listeners on the Mac:
///  - an HTTP server that serves the phone-side pairing page (what the QR code points at)
///  - a WebSocket server the page connects to for the live link
///
/// Pairing flow: the QR encodes `http://<mac-ip>:<port>/?t=<token>`. The phone's browser
/// loads the page, opens a WebSocket back, and sends the token. The Mac issues a long-lived
/// secret the page stores in localStorage, so reopening the page reconnects without rescanning.
/// A 5s heartbeat (with battery level) keeps the link verified; 15s of silence = disconnected.
final class PairingManager: ObservableObject {
    enum Phase: Equatable { case waiting, connected }

    @Published var phase: Phase = .waiting
    @Published var deviceName: String?
    @Published var battery: Int?
    @Published var pairURL: String?
    /// Every address the phone could reach this Mac on, shown on the pairing sheet.
    @Published var addresses: [String] = []
    @Published var hasPaired = false
    /// Latest mirrored screen frame streamed from the phone (nil = not mirroring).
    @Published var mirrorFrame: NSImage?

    // Live data synced from the phone (replaces mock data once connected).
    @Published var liveContacts: [Contact] = []
    @Published var liveRecents: [RecentCall] = []
    /// Notifications mirrored from the phone, newest first.
    @Published var liveNotifications: [AppNotification] = []
    /// Whether the phone has actually granted notification access.
    @Published var notificationAccess = false
    /// Clipboard history synced from the phone, newest first.
    @Published var liveClips: [ClipItem] = []
    /// The phone's latest copy, for ClipboardWatcher to put on the pasteboard.
    @Published var incomingClip: String?
    /// Real app icons mirrored from the phone, keyed by Android package. The
    /// phone sends each once per link and re-sends on reconnect, so there is
    /// nothing here to persist or invalidate.
    @Published var appIcons: [String: NSImage] = [:]

    /// Telephony state reported by the phone.
    enum CallPhase { case idle, ringing, active }
    @Published var callPhase: CallPhase = .idle
    @Published var callerNumber: String = ""
    /// Who is calling, resolved against the phone's own address book. Empty
    /// when the number isn't a saved contact.
    @Published var callerName: String = ""
    @Published var muted = false
    @Published var speaker = false

    var isConnected: Bool { phase == .connected }

    private var secret: String?
    private let token = UUID().uuidString.lowercased()
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var phone: NWConnection?
    private var httpPort: UInt16 = 0
    private var wsPort: UInt16 = 0
    private var lastPing = Date()
    /// Non-nil once the handshake with `phone` has finished: from that point
    /// every frame in either direction is encrypted. Derived from that
    /// connection's nonces, so it dies with the connection. See [SessionCrypto].
    private var crypto: SessionCrypto?
    /// This session's two nonces, kept so an unlink can be signed over the same
    /// pair the handshake used — which is what makes it unreplayable.
    private var sessionNonces: (mac: String, phone: String)?
    private var watchdog: Timer?
    private let queue = DispatchQueue(label: "tethr.pairing")
    /// Per-connection challenge nonces, cleared when the connection goes away.
    private var nonces: [ObjectIdentifier: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        secret = defaults.string(forKey: "pairedSecret")
        deviceName = defaults.string(forKey: "pairedName")
        hasPaired = secret != nil
        startWebSocketServer()
        startHTTPServer()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func unpair() {
        // Tell the phone before forgetting the secret, because proving this is
        // us needs it. Unlinking one end only would leave the phone dialling a
        // Mac that will never accept it again.
        //
        // Signed rather than just sent: the phone auto-connects to whatever it
        // discovers, so an unauthenticated "we're done" would let anyone on the
        // network unpair someone's phone with one packet. That is exactly why
        // the phone ignores a bare "rejected" today.
        let revoking = secret
        queue.async { [weak self] in
            guard let self else { return }
            if let phone = self.phone, let revoking, let nonces = self.sessionNonces {
                let proof = Self.proof(secret: revoking, role: "unlink",
                                       a: nonces.mac, b: nonces.phone)
                self.sendJSON(["type": "unlink", "proof": proof], to: phone) {
                    phone.cancel()
                }
            } else {
                self.phone?.cancel()
            }
            self.phone = nil
            self.crypto = nil
            self.sessionNonces = nil
        }
        forgetPairing()
    }

    /// Drops this Mac's half of the pairing. Split out so an unlink arriving
    /// from the phone clears the same state without sending one back.
    private func forgetPairing() {
        secret = nil
        UserDefaults.standard.removeObject(forKey: "pairedSecret")
        UserDefaults.standard.removeObject(forKey: "pairedName")
        deviceName = nil
        battery = nil
        phase = .waiting
        hasPaired = false
    }

    // MARK: - Liveness

    private func tick() {
        // Backstop only. A live TCP socket keeps the link up even when the
        // phone page is backgrounded and its JS heartbeat is paused; a truly
        // dead socket is caught fast by keepalive -> connectionClosed(). So
        // this generous window just cleans up a wedged-but-open connection.
        if phase == .connected, Date().timeIntervalSince(lastPing) > 45 {
            queue.async { [weak self] in
                self?.phone?.cancel()
                self?.phone = nil
            }
            phase = .waiting
            battery = nil
            mirrorFrame = nil
        }
        refreshPairURL()
    }

    private func refreshPairURL() {
        let ips = Self.localIPv4Candidates()
        guard httpPort != 0, wsPort != 0, let primary = ips.first else {
            if pairURL != nil { pairURL = nil }
            if !addresses.isEmpty { addresses = [] }
            return
        }
        // Every address goes into the QR, not just the primary one. The phone
        // tries each in turn, so it finds us over a hotspot / USB / Bluetooth
        // PAN link exactly the same way it finds us over a router.
        let hosts = ips.joined(separator: ",")
        let url = "http://\(primary):\(httpPort)/?t=\(token)&ws=\(wsPort)&hosts=\(hosts)"
        if pairURL != url { pairURL = url }
        if addresses != ips { addresses = ips }
    }

    // MARK: - WebSocket server

    private func startWebSocketServer() {
        // TCP keepalive lets the OS detect a genuinely dead phone (crashed,
        // off Wi-Fi) within ~20s, while keeping an idle-but-alive socket up.
        // This is what really tells us the link dropped — not the JS heartbeat,
        // which mobile browsers throttle/pause whenever the page is backgrounded.
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.enableKeepalive = true
        tcpOpts.keepaliveIdle = 5
        tcpOpts.keepaliveInterval = 5
        tcpOpts.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener: NWListener
        if let fixed = try? NWListener(using: params, on: 8738) {
            listener = fixed
        } else if let any = try? NWListener(using: params) {
            listener = any
        } else {
            return
        }

        // Advertising over Bonjour makes macOS raise the Local Network
        // permission prompt; without it, inbound LAN data is silently dropped.
        // It is also how the phone finds us again on a network neither device
        // has seen before — see MacFinder on the Android side.
        //
        // The instance name is a random per-install tag, NOT the Mac's name:
        // this advert is readable by anyone on the network, so it must not
        // announce whose machine this is. The tag only exists to keep two Macs
        // running Tethr from colliding. The real name is sent to the phone
        // after it has authenticated, never in the broadcast.
        listener.service = NWListener.Service(name: "Tethr-\(Self.advertTag)",
                                              type: "_tethr._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            DispatchQueue.main.async {
                self.wsPort = listener.port?.rawValue ?? 0
                self.refreshPairURL()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.connectionClosed(conn)
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.challenge(conn)
            self.receiveLoop(conn)
        }
        listener.start(queue: queue)
        wsListener = listener
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata)?.opcode

            // Close only on a real error, an explicit close frame, or an empty
            // completion carrying no frame at all (true end of stream). We must
            // decide this from the opcode/error — NOT from "data == nil", because
            // WebSocket ping/pong are payload-less control frames: the phone's
            // OkHttp sends a ping every 10s, and reading that as a disconnect was
            // exactly what caused the ~10s connect/disconnect flapping.
            if error != nil || opcode == .close || (opcode == nil && (data?.isEmpty ?? true)) {
                self.connectionClosed(conn)
                return
            }

            if let data, !data.isEmpty {
                if opcode == .binary {
                    // Everything after the handshake is a sealed frame. One
                    // that is forged, replayed or tampered with opens to nil and
                    // is dropped without ever being parsed or displayed.
                    // A forged, replayed or tampered frame opens to nil and is
                    // dropped without ever being parsed or displayed.
                    guard conn === self.phone, let crypto = self.crypto,
                          let opened = crypto.open(data) else {
                        self.receiveLoop(conn)
                        return
                    }
                    switch opened.kind {
                    case SessionCrypto.kindJSON:
                        self.handleMessage(opened.payload, from: conn)
                    case SessionCrypto.kindFile:
                        let body = opened.payload
                        guard body.count >= FileTransfers.header else { break }
                        let id = Int(body.subdata(in: 0..<4).withUnsafeBytes {
                            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
                        })
                        let offset = body.subdata(in: 4..<12).withUnsafeBytes {
                            Int64(bigEndian: $0.loadUnaligned(as: Int64.self))
                        }
                        let slice = body.subdata(in: FileTransfers.header..<body.count)
                        DispatchQueue.main.async { self.files?.write(id: id, offset: offset, data: slice) }
                    case SessionCrypto.kindFrame:
                        let image = NSImage(data: opened.payload)
                        DispatchQueue.main.async {
                            self.lastPing = Date()
                            self.mirrorFrame = image
                        }
                    default:
                        break
                    }
                } else if opcode == .text {
                    // Plaintext is only ever the handshake. Once keys exist, a
                    // peer talking in the clear is not the phone we verified.
                    if conn === self.phone, self.crypto != nil {
                        self.receiveLoop(conn)
                        return
                    }
                    self.handleMessage(data, from: conn)
                }
            }
            // ping/pong (and any empty non-close frame): keep listening.
            self.receiveLoop(conn)
        }
    }

    private func handleMessage(_ data: Data, from conn: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let battery = obj["battery"] as? Int
        if let access = obj["notificationAccess"] as? Bool {
            DispatchQueue.main.async {
                if self.notificationAccess != access { self.notificationAccess = access }
                // Access revoked on the phone: drop what we were showing.
                if !access, !self.liveNotifications.isEmpty { self.liveNotifications = [] }
            }
        }

        switch type {
        case "hello":
            let sentToken = obj["token"] as? String
            let phoneNonce = obj["nonce"] as? String ?? ""
            let macNonce = nonces[ObjectIdentifier(conn)] ?? ""

            // A paired phone proves it knows the secret over both nonces rather
            // than sending it, so the secret never crosses the wire after
            // pairing and a replayed proof is useless on the next connection.
            let proved: Bool
            if let secret, let proof = obj["proof"] as? String, !macNonce.isEmpty {
                proved = Self.constantTimeEquals(
                    proof, Self.proof(secret: secret, role: "phone", a: macNonce, b: phoneNonce))
            } else {
                proved = false
            }

            // The QR token bootstraps a device that has no secret yet. It stays
            // valid for re-pairing — someone reading it has to be looking at
            // this screen — and is the only path on which the secret is sent.
            let viaToken = !(sentToken ?? "").isEmpty && sentToken == token

            // The legacy raw-secret hello is gone. It sent the secret itself
            // over a plaintext socket on every connection — the weakest thing
            // on the wire, and incompatible with a session that is encrypted
            // from the handshake onwards.
            guard proved || viaToken else {
                sendJSON(["type": "rejected"], to: conn) { conn.cancel() }
                return
            }
            accept(conn, name: obj["name"] as? String ?? "Phone", battery: battery,
                   phoneNonce: phoneNonce, sendSecret: viaToken)

        case "ping":
            DispatchQueue.main.async {
                self.lastPing = Date()
                if let battery { self.battery = battery }
            }

        case "mirrorStopped":
            DispatchQueue.main.async { self.mirrorFrame = nil }

        case "contacts":
            let items = obj["items"] as? [[String: Any]] ?? []
            let contacts = items.enumerated().map { i, it in
                Contact(name: (it["name"] as? String) ?? "",
                        number: (it["number"] as? String) ?? "",
                        tint: Palette.avatarTints[i % Palette.avatarTints.count])
            }
            DispatchQueue.main.async { self.liveContacts = contacts }

        case "calllog":
            let items = obj["items"] as? [[String: Any]] ?? []
            let recents = items.map { Self.recentCall(from: $0) }
            DispatchQueue.main.async { self.liveRecents = recents }

        case "notification":
            guard let item = Self.notification(from: obj) else { return }
            DispatchQueue.main.async {
                // Same key = an update (a message thread gaining a reply), so
                // replace in place rather than stacking duplicates.
                if let i = self.liveNotifications.firstIndex(where: { $0.key == item.key }) {
                    self.liveNotifications[i] = item
                } else {
                    self.liveNotifications.insert(item, at: 0)
                }
            }

        case "notifications":
            let items = obj["items"] as? [[String: Any]] ?? []
            let parsed = items.compactMap(Self.notification(from:)).reversed()
            DispatchQueue.main.async { self.liveNotifications = Array(parsed) }

        case "unlink":
            // The phone unlinking on its end. Proven for the same reason ours
            // is: forgetting a pairing is destructive, so it takes proof.
            guard let secret, let nonces = sessionNonces,
                  let proof = obj["proof"] as? String,
                  Self.constantTimeEquals(
                    proof,
                    Self.proof(secret: secret, role: "unlink-phone",
                               a: nonces.mac, b: nonces.phone))
            else { return }
            conn.cancel()
            DispatchQueue.main.async { self.forgetPairing() }

        case "fileStart":
            guard let id = obj["id"] as? Int, let name = obj["name"] as? String else { return }
            let size = (obj["size"] as? NSNumber)?.int64Value ?? 0
            let mime = obj["mime"] as? String ?? ""
            DispatchQueue.main.async { self.files?.begin(id: id, name: name, size: size, mime: mime) }

        case "fileEnd":
            guard let id = obj["id"] as? Int else { return }
            DispatchQueue.main.async { self.files?.finish(id: id) }

        case "fileCancel":
            guard let id = obj["id"] as? Int else { return }
            DispatchQueue.main.async { self.files?.cancel(id: id, reason: "The phone stopped sending") }

        case "fileDone":
            guard let id = obj["id"] as? Int else { return }
            let ok = (obj["ok"] as? Bool) ?? false
            DispatchQueue.main.async { self.files?.completed(id: id, ok: ok) }

        case "clipboard":
            guard let text = obj["text"] as? String, !text.isEmpty else { return }
            DispatchQueue.main.async {
                self.incomingClip = text
                self.liveClips.insert(
                    ClipItem(symbol: Self.clipSymbol(for: text),
                             body: text,
                             source: self.deviceName ?? "Phone",
                             when: Self.shortTime(Date())),
                    at: 0
                )
                // A history, not an archive — the useful end is the recent end.
                if self.liveClips.count > 50 { self.liveClips.removeLast() }
            }

        case "appIcon":
            guard let pkg = obj["pkg"] as? String,
                  let encoded = obj["png"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let icon = NSImage(data: data) else { return }
            DispatchQueue.main.async { self.appIcons[pkg] = icon }

        case "notificationRemoved":
            guard let key = obj["key"] as? String else { return }
            DispatchQueue.main.async {
                self.liveNotifications.removeAll { $0.key == key }
            }

        case "callState":
            let s = (obj["state"] as? String) ?? "idle"
            let number = obj["number"] as? String
            let name = obj["name"] as? String
            DispatchQueue.main.async {
                if let number, !number.isEmpty { self.callerNumber = number }
                if let name, !name.isEmpty { self.callerName = name }
                switch s {
                case "ringing": self.callPhase = .ringing
                case "offhook": self.callPhase = .active
                default:
                    self.callPhase = .idle
                    self.callerNumber = ""
                    self.callerName = ""
                }
            }

        case "callAudio":
            let muted = (obj["muted"] as? Bool) ?? false
            let speaker = (obj["speaker"] as? Bool) ?? false
            DispatchQueue.main.async {
                self.muted = muted
                self.speaker = speaker
            }

        default:
            break
        }
    }

    // MARK: - Commands to the phone

    func dial(_ number: String) {
        sendCommand(["type": "dial", "number": number])
        // Android stopped reporting outgoing numbers to third-party apps, so an
        // outgoing call arrives back as a bare "offhook" with nobody attached.
        // When the Mac placed the call it already knows who it dialled.
        DispatchQueue.main.async {
            self.callerNumber = number
            self.callerName = ""
        }
    }
    func answerCall() { sendCommand(["type": "answer"]) }
    func hangup() { sendCommand(["type": "hangup"]) }
    func setMute(_ on: Bool) { sendCommand(["type": "setMute", "on": on]) }
    func setSpeaker(_ on: Bool) { sendCommand(["type": "setSpeaker", "on": on]) }

    // Remote control of the phone screen. Coordinates are normalized 0…1 so they
    // map to the phone regardless of its resolution.
    func tap(x: Double, y: Double) { sendCommand(["type": "tap", "x": x, "y": y]) }
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Int) {
        sendCommand(["type": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms])
    }
    func pressKey(_ key: String) { sendCommand(["type": "key", "key": key]) }
    /// Dismiss a notification on the phone — it disappears from the shade too.
    func dismissNotification(_ key: String) {
        sendCommand(["type": "dismissNotification", "key": key])
    }

    /// Reply through the notification's own action on the phone.
    func replyToNotification(_ key: String, text: String) {
        sendCommand(["type": "replyNotification", "key": key, "text": text])
    }

    /// Pushes this Mac's clipboard to the phone, and keeps it in the history so
    /// the screen shows both sides of the sync rather than only what arrived.
    func sendClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        sendCommand(["type": "clipboard", "text": text])
        DispatchQueue.main.async {
            self.liveClips.insert(
                ClipItem(symbol: Self.clipSymbol(for: text),
                         body: text,
                         source: "this Mac",
                         when: Self.shortTime(Date())),
                at: 0
            )
            if self.liveClips.count > 50 { self.liveClips.removeLast() }
        }
    }

    /// The transfer list, wired up at launch so incoming files have somewhere
    /// to land regardless of which window is open.
    weak var files: FileTransfers?

    func sendFileStart(id: Int, name: String, size: Int64, mime: String) {
        sendCommand(["type": "fileStart", "id": id, "name": name, "size": size, "mime": mime])
    }

    func sendFileEnd(id: Int) { sendCommand(["type": "fileEnd", "id": id]) }
    func sendFileCancel(id: Int) { sendCommand(["type": "fileCancel", "id": id]) }

    /// Sends one chunk and waits for the socket to take it, which is what paces
    /// a large file: without the wait we would queue the whole thing at once and
    /// bury the heartbeat and screen mirror behind it.
    func sendFileChunk(id: Int, offset: Int64, data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let phone = self.phone, let crypto = self.crypto else {
                    continuation.resume(returning: false); return
                }
                var payload = Data()
                payload.append(withUnsafeBytes(of: UInt32(id).bigEndian) { Data($0) })
                payload.append(withUnsafeBytes(of: offset.bigEndian) { Data($0) })
                payload.append(data)
                guard let sealed = crypto.seal(kind: SessionCrypto.kindFile, payload: payload) else {
                    continuation.resume(returning: false); return
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "file", metadata: [metadata])
                phone.send(content: sealed, contentContext: context, isComplete: true,
                           completion: .contentProcessed { error in
                               continuation.resume(returning: error == nil)
                           })
            }
        }
    }

    /// Ask the phone for whatever it currently holds.
    func requestClipboard() { sendCommand(["type": "getClipboard"]) }

    /// A glanceable hint at what a clip is, so the list doesn't read as one
    /// undifferentiated wall of text.
    private static func clipSymbol(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return "link" }
        if trimmed.contains("@"), !trimmed.contains(" ") { return "envelope" }
        if trimmed.allSatisfy({ $0.isNumber || "+-() ".contains($0) }), trimmed.count >= 7 {
            return "phone"
        }
        return "doc.plaintext"
    }

    /// Ask the phone to (re)send contacts and call history.
    func requestPhoneData() {
        sendCommand(["type": "getContacts"])
        sendCommand(["type": "getCallLog"])
    }

    private func sendCommand(_ obj: [String: Any]) {
        queue.async { [weak self] in
            guard let self, let phone = self.phone else { return }
            self.sendJSON(obj, to: phone)
        }
    }

    /// Builds an AppNotification from a mirrored notification row.
    private static func notification(from it: [String: Any]) -> AppNotification? {
        guard let key = it["key"] as? String else { return nil }
        let epochMs = (it["when"] as? NSNumber)?.doubleValue ?? 0
        let date = Date(timeIntervalSince1970: epochMs / 1000)
        return AppNotification(
            key: key,
            pkg: (it["pkg"] as? String) ?? "",
            app: (it["app"] as? String) ?? "Phone",
            title: (it["title"] as? String) ?? "",
            body: (it["text"] as? String) ?? "",
            when: Self.shortTime(date),
            canReply: (it["canReply"] as? Bool) ?? false
        )
    }

    /// "now" / "12m" / "3h" / a date, like a phone's own shade.
    private static func shortTime(_ date: Date) -> String {
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Builds a RecentCall from a call-log JSON row (epoch-ms `when`, seconds `duration`).
    private static func recentCall(from it: [String: Any]) -> RecentCall {
        let name = (it["name"] as? String) ?? ""
        let number = (it["number"] as? String) ?? ""
        let dirRaw = (it["direction"] as? String) ?? "incoming"
        let direction: CallDirection = switch dirRaw {
            case "outgoing": .outgoing
            case "missed": .missed
            default: .incoming
        }
        let duration = (it["duration"] as? NSNumber)?.intValue ?? 0
        let epochMs = (it["when"] as? NSNumber)?.doubleValue ?? 0
        let date = Date(timeIntervalSince1970: epochMs / 1000)

        var label = dirRaw.capitalized
        if direction != .missed, duration > 0 {
            label += " · \(duration / 60)m \(duration % 60)s"
        }
        return RecentCall(name: name.isEmpty ? number : name,
                          number: number,
                          direction: direction,
                          label: label,
                          when: Self.relativeWhen(date))
    }

    private static func relativeWhen(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        } else if cal.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func accept(_ conn: NWConnection, name: String, battery: Int?,
                        phoneNonce: String = "", sendSecret: Bool = false) {
        if secret == nil { secret = Self.randomSecret() }
        UserDefaults.standard.set(secret, forKey: "pairedSecret")
        UserDefaults.standard.set(name, forKey: "pairedName")

        if let old = phone, old !== conn { old.cancel() }
        phone = conn
        // A superseded connection's keys must not encrypt this one's handshake.
        crypto = nil

        let macNonce = nonces[ObjectIdentifier(conn)] ?? ""
        var reply: [String: Any] = [
            "type": "paired",
            "macName": Self.macName,
            // Lets the phone confirm we are the Mac it paired with before it
            // streams contacts, call history or its screen to us.
            "proof": Self.proof(secret: secret!, role: "mac", a: macNonce, b: phoneNonce),
        ]
        // The secret leaves this Mac only in response to a valid QR token.
        if sendSecret { reply["secret"] = secret! }
        // Sent in the clear — it is the last plaintext message. Everything from
        // here on is sealed, so the keys come up immediately after it.
        sendJSON(reply, to: conn)
        crypto = SessionCrypto(secret: secret!, macNonce: macNonce, phoneNonce: phoneNonce)
        sessionNonces = (mac: macNonce, phone: phoneNonce)

        DispatchQueue.main.async {
            self.lastPing = Date()
            self.deviceName = name
            self.battery = battery
            self.phase = .connected
            self.hasPaired = true
        }
    }

    private func connectionClosed(_ conn: NWConnection) {
        // Always release the socket — otherwise a superseded/abandoned
        // connection lingers in CLOSE_WAIT and its unread frames pile up in the
        // kernel buffer. cancel() on an already-dead connection is a no-op.
        conn.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            self.nonces.removeValue(forKey: ObjectIdentifier(conn))
            guard self.phone === conn else { return }
            self.phone = nil
            self.crypto = nil
            self.sessionNonces = nil
            DispatchQueue.main.async {
                self.phase = .waiting
                self.battery = nil
                self.mirrorFrame = nil
            }
        }
    }

    // MARK: - Handshake crypto

    /// Sends this connection a fresh nonce to sign. Called before any data is
    /// exchanged, so an unauthenticated peer never gets further than this.
    private func challenge(_ conn: NWConnection) {
        let nonce = Self.randomToken()
        nonces[ObjectIdentifier(conn)] = nonce
        sendJSON(["type": "challenge", "nonce": nonce], to: conn)
    }

    /// HMAC-SHA256 over both nonces, tagged by role so a phone's proof can
    /// never be replayed back as the Mac's.
    private static func proof(secret: String, role: String, a: String, b: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let message = Data("\(role):\(a):\(b)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).base64EncodedString()
    }

    /// Compares without leaking where two values diverge.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// 256 bits from the system CSPRNG — a UUID carries only ~122 bits and is
    /// not generated for cryptographic use.
    private static func randomSecret() -> String { randomToken() }

    private func sendJSON(_ obj: [String: Any], to conn: NWConnection, then: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // Only the handshake predates the keys, and it deliberately carries
        // nothing worth hiding — nonces and HMACs, never content.
        if conn === phone, let crypto, let sealed = crypto.seal(kind: SessionCrypto.kindJSON, payload: data) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "sealed", metadata: [metadata])
            conn.send(content: sealed, contentContext: context, isComplete: true,
                      completion: .contentProcessed { _ in then?() })
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in then?() })
    }

    // MARK: - HTTP server (serves the phone pairing page)

    private func startHTTPServer() {
        let listener: NWListener
        if let fixed = try? NWListener(using: .tcp, on: 8737) {
            listener = fixed
        } else if let any = try? NWListener(using: .tcp) {
            listener = any
        } else {
            return
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            DispatchQueue.main.async {
                self.httpPort = listener.port?.rawValue ?? 0
                self.refreshPairURL()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
                guard let self else { return }
                let body = Data(Self.pageHTML
                    .replacingOccurrences(of: "__WSPORT__", with: String(self.wsPort))
                    .replacingOccurrences(of: "__LOGO__", with: Self.logoDataURI)
                    .utf8)
                let head = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        listener.start(queue: queue)
        httpListener = listener
    }

    /// This Mac's display name. Sent to the phone only after it authenticates.
    static let macName: String = Host.current().localizedName ?? "Mac"

    /// Random, stable, non-identifying tag used in the Bonjour instance name.
    static let advertTag: String = {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "advertTag") { return existing }
        let tag = String(UUID().uuidString.lowercased().prefix(6))
        defaults.set(tag, forKey: "advertTag")
        return tag
    }()

    // MARK: - Local IP

    /// Every IPv4 address this Mac can be reached on, best guess first.
    ///
    /// No router is required: the phone's own hotspot (we join it as a client),
    /// USB tethering, Bluetooth PAN and a network this Mac is sharing all show
    /// up here as just another interface. Advertising the whole list — rather
    /// than guessing one — is what lets the phone reach us over whichever of
    /// them happens to be up, and switch between them without a re-pair.
    static func localIPv4Candidates() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var found: [(rank: Int, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)

            let rank: Int
            if name == "en0" {
                rank = 0            // Wi-Fi — the home network, or the phone's hotspot
            } else if name.hasPrefix("en") || name.hasPrefix("bond") {
                rank = 1            // USB tethering, Ethernet, Bluetooth PAN
            } else if name.hasPrefix("bridge") || name.hasPrefix("ap") {
                rank = 2            // a network this Mac is sharing
            } else {
                continue            // VPNs, utun, awdl: not reachable from the phone
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            // A self-assigned address means that interface never got a lease.
            guard !ip.hasPrefix("169.254.") else { continue }
            found.append((rank, ip))
        }

        var seen = Set<String>()
        return found.sorted { $0.rank < $1.rank }.map(\.ip).filter { seen.insert($0).inserted }
    }

    // MARK: - Phone-side page

    /// The mark, inlined as a data URI: the phone loads this page straight off
    /// the Mac with no second request possible.
    private static let logoDataURI: String = {
        guard let logo = Brand.logo,
              let tiff = logo.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    private static let pageHTML = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <title>Tethr · Phone Link</title><style>
    body{margin:0;font-family:-apple-system,Roboto,system-ui,sans-serif;
      background:linear-gradient(160deg,#0A84FF,#5E5CE6,#AF52DE);min-height:100vh;
      display:flex;align-items:center;justify-content:center;color:#fff}
    .card{background:rgba(255,255,255,.14);backdrop-filter:blur(20px);
      border:1px solid rgba(255,255,255,.25);border-radius:24px;
      padding:36px 30px;max-width:340px;width:86%;text-align:center}
    .logo{width:56px;height:56px;border-radius:16px;display:block;margin:0 auto}
    h1{font-size:26px;margin:10px 0 2px;letter-spacing:-.5px}
    .sub{opacity:.85;font-size:14px;margin:0 0 24px}
    .status{display:flex;gap:8px;align-items:center;justify-content:center;font-size:15px;font-weight:600}
    .dot{width:9px;height:9px;border-radius:50%;background:#FF9F0A;animation:pulse 1.2s ease-in-out infinite alternate}
    .dot.ok{background:#34C759}.dot.bad{background:#FF453A;animation:none}
    @keyframes pulse{from{opacity:1}to{opacity:.35}}
    .detail{opacity:.8;font-size:13px;margin-top:8px;min-height:18px}
    .hint{opacity:.65;font-size:12px;margin-top:26px;line-height:1.5}
    </style></head><body><div class="card">
    <img class="logo" src="__LOGO__" alt=""><h1>Tethr</h1><p class="sub">Phone Link</p>
    <div class="status"><span id="dot" class="dot"></span><span id="st">Connecting&hellip;</span></div>
    <div class="detail" id="detail"></div>
    <p class="hint">Keep this page open to stay connected to your Mac.
    Add it to your home screen for one-tap reconnecting.</p>
    </div><script>
    const WSPORT="__WSPORT__";
    const token=new URLSearchParams(location.search).get('t')||'';
    let ws=null,batt=null;
    const $=id=>document.getElementById(id);
    function setStatus(cls,txt,detail){
      $('dot').className='dot'+(cls?' '+cls:'');
      $('st').textContent=txt;$('detail').textContent=detail||'';
    }
    async function deviceName(){
      try{const d=await navigator.userAgentData.getHighEntropyValues(['model']);
        if(d.model&&d.model!=='K')return d.model}catch(e){}
      const m=navigator.userAgent.match(/Android [^;]+; ([^;)]+?)(?: Build|\))/);
      if(m&&m[1]!=='K')return m[1];
      if(/iPhone/.test(navigator.userAgent))return 'iPhone';
      if(/Android/.test(navigator.userAgent))return 'Android Phone';
      return 'Phone';
    }
    function level(){return batt?Math.round(batt.level*100):null}
    if(navigator.getBattery)navigator.getBattery().then(b=>{batt=b});
    function send(o){if(ws&&ws.readyState===1)ws.send(JSON.stringify(o))}
    async function connect(){
      if(ws&&ws.readyState<=1)return;   // already connecting/open — avoid dup sockets
      setStatus('','Connecting…');
      ws=new WebSocket('ws://'+location.hostname+':'+WSPORT+'/');
      ws.onopen=async()=>{send({type:'hello',token:token,
        secret:localStorage.getItem('tethr-secret'),
        name:await deviceName(),battery:level()})};
      ws.onmessage=e=>{const m=JSON.parse(e.data);
        if(m.type==='paired'){if(m.secret)localStorage.setItem('tethr-secret',m.secret);
          setStatus('ok','Connected','Linked to '+(m.macName||'your Mac'))}
        if(m.type==='rejected'){localStorage.removeItem('tethr-secret');
          setStatus('bad','Pairing failed','Scan the QR code in Tethr on your Mac again.');
          ws.onclose=null;ws.close()}};
      ws.onclose=()=>{setStatus('','Reconnecting…');setTimeout(connect,2000)};
      ws.onerror=()=>{try{ws.close()}catch(e){}};
    }
    setInterval(()=>send({type:'ping',battery:level()}),5000);
    let lock=null;
    async function grabLock(){try{lock=await navigator.wakeLock.request('screen')}catch(e){}}
    document.addEventListener('visibilitychange',()=>{
      if(document.visibilityState==='visible'){grabLock();
        if(!ws||ws.readyState>1)connect()}});
    grabLock();connect();
    </script></body></html>
    """#
}

/// Real QR code rendered from a string (replaces the old mock pattern).
struct QRCodeView: View {
    let string: String

    var body: some View {
        Group {
            if let image = Self.image(for: string) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
