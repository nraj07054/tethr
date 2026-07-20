import Foundation
import Network
import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

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
    @Published var hasPaired = false
    /// Latest mirrored screen frame streamed from the phone (nil = not mirroring).
    @Published var mirrorFrame: NSImage?

    // Live data synced from the phone (replaces mock data once connected).
    @Published var liveContacts: [Contact] = []
    @Published var liveRecents: [RecentCall] = []

    /// Telephony state reported by the phone.
    enum CallPhase { case idle, ringing, active }
    @Published var callPhase: CallPhase = .idle
    @Published var callerNumber: String = ""
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
    private var watchdog: Timer?
    private let queue = DispatchQueue(label: "dogen.pairing")

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
        queue.async { [weak self] in
            self?.phone?.cancel()
            self?.phone = nil
        }
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
        guard httpPort != 0, wsPort != 0, let ip = Self.localIPv4() else {
            if pairURL != nil { pairURL = nil }
            return
        }
        let url = "http://\(ip):\(httpPort)/?t=\(token)&ws=\(wsPort)"
        if pairURL != url { pairURL = url }
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
        listener.service = NWListener.Service(name: "Dogen", type: "_dogen._tcp")
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
                    // Binary frames are JPEG screen-mirror frames.
                    let image = NSImage(data: data)
                    DispatchQueue.main.async {
                        self.lastPing = Date()
                        self.mirrorFrame = image
                    }
                } else if opcode == .text {
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

        switch type {
        case "hello":
            let sentToken = obj["token"] as? String
            let sentSecret = obj["secret"] as? String
            let known = secret != nil && sentSecret == secret
            guard known || sentToken == token else {
                sendJSON(["type": "rejected"], to: conn) { conn.cancel() }
                return
            }
            accept(conn, name: obj["name"] as? String ?? "Phone", battery: battery)

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

        case "callState":
            let s = (obj["state"] as? String) ?? "idle"
            let number = obj["number"] as? String
            DispatchQueue.main.async {
                if let number, !number.isEmpty { self.callerNumber = number }
                switch s {
                case "ringing": self.callPhase = .ringing
                case "offhook": self.callPhase = .active
                default: self.callPhase = .idle; self.callerNumber = ""
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

    func dial(_ number: String) { sendCommand(["type": "dial", "number": number]) }
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

    private func accept(_ conn: NWConnection, name: String, battery: Int?) {
        if secret == nil { secret = UUID().uuidString.lowercased() }
        UserDefaults.standard.set(secret, forKey: "pairedSecret")
        UserDefaults.standard.set(name, forKey: "pairedName")

        if let old = phone, old !== conn { old.cancel() }
        phone = conn

        let macName = Host.current().localizedName ?? "Mac"
        sendJSON(["type": "paired", "secret": secret!, "macName": macName], to: conn)

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
            guard let self, self.phone === conn else { return }
            self.phone = nil
            DispatchQueue.main.async {
                self.phase = .waiting
                self.battery = nil
                self.mirrorFrame = nil
            }
        }
    }

    private func sendJSON(_ obj: [String: Any], to conn: NWConnection, then: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
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

    // MARK: - Local IP

    private static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if fallback == nil { fallback = ip }
        }
        return fallback
    }

    // MARK: - Phone-side page

    private static let pageHTML = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <title>Dogen · Phone Link</title><style>
    body{margin:0;font-family:-apple-system,Roboto,system-ui,sans-serif;
      background:linear-gradient(160deg,#0A84FF,#5E5CE6,#AF52DE);min-height:100vh;
      display:flex;align-items:center;justify-content:center;color:#fff}
    .card{background:rgba(255,255,255,.14);backdrop-filter:blur(20px);
      border:1px solid rgba(255,255,255,.25);border-radius:24px;
      padding:36px 30px;max-width:340px;width:86%;text-align:center}
    .logo{font-size:44px}
    h1{font-size:26px;margin:10px 0 2px;letter-spacing:-.5px}
    .sub{opacity:.85;font-size:14px;margin:0 0 24px}
    .status{display:flex;gap:8px;align-items:center;justify-content:center;font-size:15px;font-weight:600}
    .dot{width:9px;height:9px;border-radius:50%;background:#FF9F0A;animation:pulse 1.2s ease-in-out infinite alternate}
    .dot.ok{background:#34C759}.dot.bad{background:#FF453A;animation:none}
    @keyframes pulse{from{opacity:1}to{opacity:.35}}
    .detail{opacity:.8;font-size:13px;margin-top:8px;min-height:18px}
    .hint{opacity:.65;font-size:12px;margin-top:26px;line-height:1.5}
    </style></head><body><div class="card">
    <div class="logo">&#128241;</div><h1>Dogen</h1><p class="sub">Phone Link</p>
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
        secret:localStorage.getItem('dogen-secret'),
        name:await deviceName(),battery:level()})};
      ws.onmessage=e=>{const m=JSON.parse(e.data);
        if(m.type==='paired'){localStorage.setItem('dogen-secret',m.secret);
          setStatus('ok','Connected','Linked to '+(m.macName||'your Mac'))}
        if(m.type==='rejected'){localStorage.removeItem('dogen-secret');
          setStatus('bad','Pairing failed','Scan the QR code in Dogen on your Mac again.');
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
