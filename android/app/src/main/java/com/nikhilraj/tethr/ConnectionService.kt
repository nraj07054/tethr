package com.nikhilraj.tethr

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.Network
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.CallLog
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/** UI-observable link state. */
object LinkState {
    sealed interface Status {
        data object Idle : Status
        data object Connecting : Status
        data class Connected(val macName: String) : Status
        data object Rejected : Status
        /// The Mac unlinked this phone. Distinct from Idle so the UI can say so
        /// rather than silently reverting to "not linked yet".
        data object Unlinked : Status
    }

    val status = MutableStateFlow<Status>(Status.Idle)
    /// Whether a pairing is stored. Observable because the Mac can revoke it
    /// while someone is looking at the screen — reading PairStore once at
    /// composition would leave the phone claiming to be linked after that.
    val paired = MutableStateFlow(false)
    val mirroring = MutableStateFlow(false)
}

/**
 * Foreground service that keeps the WebSocket link to the Mac alive.
 * Speaks the Tethr pairing protocol: hello -> paired, then a 5s ping heartbeat
 * carrying the battery level. Reconnects automatically with a short backoff.
 */
class ConnectionService : Service() {

    private val client = OkHttpClient.Builder()
        // Short: a dial to an address the phone can't reach must fail fast so
        // the sweep through the Mac's other addresses stays quick.
        .connectTimeout(3, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        // WS-level pings detect half-open sockets (Wi-Fi power save) and
        // surface them as onFailure so the reconnect loop can recover.
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    private val handler = Handler(Looper.getMainLooper())
    private var socket: WebSocket? = null
    private var callController: CallController? = null
    // Non-null once the handshake has finished: from that point every frame in
    // either direction is encrypted. Cleared on every (re)connect, since the
    // keys are derived from that connection's nonces. See [SessionCrypto].
    private var crypto: SessionCrypto? = null
    // Sealing allocates a counter that doubles as the frame's nonce, so the
    // send has to happen under the same lock: if two threads seal and then race
    // to the socket, the frames reach the Mac out of order and it discards the
    // lower counter as a replay. That is what stopped contacts and the call log
    // ever arriving — both are pushed from a worker thread while the 5s
    // heartbeat is sealed on the main one.
    private val sendLock = Any()
    private val nextTransferId = java.util.concurrent.atomic.AtomicInteger(1)
    // Shares arrive whenever the user taps share — often with the app closed and
    // the link still coming up. Holding them until the Mac answers is the
    // difference between "sent" and "silently vanished".
    private val pendingSends = java.util.concurrent.ConcurrentLinkedQueue<Outgoing>()

    /**
     * A file on its way to the Mac, already staged on local disk.
     *
     * Staged rather than referenced by URI because a share's read permission
     * dies with the activity that received it — by the time the link is up and
     * the queue drains, the URI is no longer readable.
     */
    data class Outgoing(val file: java.io.File, val name: String, val mime: String)
    // This session's two nonces, kept so the phone can sign an unlink over the
    // same pair the handshake used — which is what makes it unreplayable.
    private var sessionNonces: Pair<String, String>? = null
    // Watches the system call log so a call that has just ended reaches the Mac
    // on its own, instead of waiting for someone to press refresh.
    private var callLogObserver: ContentObserver? = null
    // Fires only while Tethr is the focused app — which is also the only time
    // the platform lets us read what changed. See [Clipboard].
    private var clipListener: android.content.ClipboardManager.OnPrimaryClipChangedListener? = null
    // A call's row is written and then updated (with its duration) moments after
    // the call ends, so the pushes those changes trigger are coalesced into one.
    private val callLogPush = Runnable { pushPhoneData(contacts = false, callLog = true) }
    // Bumped on every connect() so callbacks from a superseded socket are
    // ignored — stops a cancelled old socket from triggering a reconnect storm.
    private var generation = 0
    private var stopped = false
    // Cursor into Pairing.candidates: which of the Mac's addresses to dial next.
    private var attempt = 0

    // Finding the Mac when its remembered addresses are all stale — a new
    // network, a new DHCP lease, or this phone acting as the hotspot.
    private var finder: MacFinder? = null
    private var probe: SubnetProbe? = null
    private var netCallback: ConnectivityManager.NetworkCallback? = null

    // Named so a pending retry can be cancelled precisely; an anonymous lambda
    // would let retries stack up whenever discovery and backoff both fire.
    private val reconnectRunnable = Runnable { connect() }
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    // Screen mirroring
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var mirrorWidth = 0
    private var mirrorHeight = 0
    // Dedicated thread so JPEG encoding never blocks the UI/network threads.
    private var mirrorThread: HandlerThread? = null
    private var mirrorHandler: Handler? = null
    private var lastFrameAt = 0L

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            handler.post { stopMirroring() }
        }
    }

    /**
     * Event-driven frame pump: fires whenever the screen produces a new frame,
     * so mirroring tracks the phone in real time instead of a fixed 4 fps poll.
     * Two guards keep the link healthy:
     *  - queueSize backpressure: if the socket is already backed up we drop this
     *    frame rather than pile onto OkHttp's send buffer (an unbounded buffer is
     *    what OkHttp kills the connection over, causing the disconnect loop).
     *  - a min interval caps encode/send work during rapid screen changes.
     * acquireLatestImage() discards intermediate frames, so we always send the
     * freshest one.
     */
    private val frameListener = ImageReader.OnImageAvailableListener { reader ->
        val image = reader.acquireLatestImage() ?: return@OnImageAvailableListener
        try {
            val ws = socket ?: return@OnImageAvailableListener
            val now = System.currentTimeMillis()
            if (now - lastFrameAt < MIN_FRAME_INTERVAL_MS) return@OnImageAvailableListener
            if (ws.queueSize() > MAX_QUEUED_BYTES) return@OnImageAvailableListener
            val bytes = encodeFrame(image) ?: return@OnImageAvailableListener
            if (!sendFrame(bytes)) return@OnImageAvailableListener
            lastFrameAt = now
        } finally {
            image.close()
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            sendJson(JSONObject().apply {
                put("type", "ping")
                put("battery", batteryLevel())
                put("notificationAccess", TethrNotificationService.isEnabled(this@ConnectionService))
            })
            handler.postDelayed(this, 5_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        Thread { FileTransfer.sweepStaged(applicationContext) }.start()
    }

    /**
     * Sends one JSON object to the Mac, if the link is up. Used by
     * [TethrNotificationService], which has no socket of its own. Dropping the
     * message when disconnected is correct: the listener re-pushes everything
     * on the shade once the link returns.
     */
    fun sendJson(obj: JSONObject) {
        val ws = socket ?: return
        val session = crypto
        if (session == null) {
            // Only the handshake itself predates the keys, and it deliberately
            // carries nothing worth hiding — nonces and HMACs, never content.
            ws.send(obj.toString())
            return
        }
        runCatching {
            synchronized(sendLock) {
                ws.send(session.seal(SessionCrypto.KIND_JSON, obj.toString().toByteArray()).toByteString())
            }
        }
    }

    /** A JPEG mirror frame, sealed like everything else. */
    private fun sendFrame(bytes: ByteArray): Boolean {
        val ws = socket ?: return false
        val session = crypto ?: return false
        return runCatching {
            synchronized(sendLock) {
                ws.send(session.seal(SessionCrypto.KIND_FRAME, bytes).toByteString())
            }
        }.getOrDefault(false)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_MIRROR -> {
                promoteForeground(mirroring = true)
                startMirroring(intent)
            }
            ACTION_STOP_MIRROR -> stopMirroring()
            ACTION_SEND_FILE -> {
                // Foreground first: this can arrive with the app closed, and a
                // service started from the background must promote immediately.
                promoteForeground(mirroring = false)
                acquireLocks()
                watchNetworks()
                val path = intent.getStringExtra(EXTRA_FILE_PATH)
                val name = intent.getStringExtra(EXTRA_FILE_NAME) ?: "file"
                val mime = intent.getStringExtra(EXTRA_FILE_MIME) ?: "application/octet-stream"
                if (path != null) sendStaged(Outgoing(java.io.File(path), name, mime))
            }
            else -> {
                promoteForeground(mirroring = false)
                acquireLocks()
                watchNetworks()
                // Only open a link if we don't already have one. A start command
                // (START_STICKY redelivery, app reopened, onResume) must not spawn
                // a second socket; reconnection of a dead link is handled by the
                // failure callback -> scheduleReconnect path instead.
                if (socket == null) connect()
            }
        }
        return START_STICKY
    }

    private fun promoteForeground(mirroring: Boolean) {
        val text = if (mirroring) "Mirroring to Mac" else "Connecting…"
        if (Build.VERSION.SDK_INT >= 30) {
            // connectedDevice is the type meant for holding a link to an
            // external device. dataSync, which this used to be, is background-
            // start restricted and time-capped on current Android.
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            if (mirroring) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(NOTIFICATION_ID, buildNotification(text), types)
        } else if (Build.VERSION.SDK_INT >= 29) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            if (mirroring) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            startForeground(NOTIFICATION_ID, buildNotification(text), types)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification(text))
        }
    }

    private fun acquireLocks() {
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
                    as android.net.wifi.WifiManager
            wifiLock = wifi.createWifiLock(
                android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "tethr:link"
            ).apply { acquire() }
        }
        if (wakeLock == null) {
            // Keeps heartbeats flowing while the screen is off; without it Doze
            // freezes the timers and the Mac times the link out.
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tethr:link")
                .apply { acquire() }
        }
    }

    /**
     * Retry the instant the phone joins a network rather than waiting out the
     * backoff. This is what makes the link reappear by itself when you walk in
     * the door and the phone hops onto home Wi-Fi.
     */
    private fun watchNetworks() {
        if (netCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                handler.post { retryNow() }
            }
        }
        runCatching { cm.registerDefaultNetworkCallback(cb) }
            .onSuccess { netCallback = cb }
    }

    private fun retryNow() {
        if (stopped || LinkState.status.value is LinkState.Status.Connected) return
        attempt = 0
        handler.removeCallbacks(reconnectRunnable)
        handler.post(reconnectRunnable)
    }

    /** Look for the Mac on this network while we have no link. */
    private fun startFinding(fullSweep: Boolean) {
        if (stopped) return
        val pairing = PairStore.load(this) ?: return
        if (finder == null) {
            finder = MacFinder(applicationContext) { host, port -> onMacFound(host, port) }
                .also { it.start() }
        }
        // The subnet probe is the heavier of the two, so it only runs once the
        // remembered addresses have all been tried and mDNS has come up empty.
        if (fullSweep) {
            val p = probe ?: SubnetProbe(pairing.wsPort) { host ->
                onMacFound(host, pairing.wsPort)
            }.also { probe = it }
            p.start()
        }
    }

    private fun stopFinding() {
        finder?.stop()
        finder = null
        probe?.stop()
        probe = null
    }

    /** A Mac turned up at [host]: remember the address and dial it right away. */
    private fun onMacFound(host: String, port: Int) {
        if (stopped || LinkState.status.value is LinkState.Status.Connected) return
        val pairing = PairStore.load(this) ?: return
        // Don't restart an attempt that is already in flight to this address.
        if (host == pairing.host && socket != null) return
        PairStore.save(
            this,
            pairing.copy(
                host = host,
                wsPort = port,
                hosts = (listOf(host) + pairing.hosts).distinct().take(MAX_HOSTS)
            )
        )
        attempt = 0
        handler.removeCallbacks(reconnectRunnable)
        handler.post(reconnectRunnable)
    }

    /**
     * A foreground service is supposed to survive its task being swiped away,
     * but several OEM skins kill it regardless. Re-issuing the start is cheap
     * and is a no-op where the platform already behaved.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (!stopped && PairStore.load(this) != null) start(this)
    }

    override fun onDestroy() {
        stopped = true
        instance = null
        stopFinding()
        netCallback?.let { cb ->
            runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) }
        }
        netCallback = null
        stopMirroring()
        callController?.stop()
        callController = null
        stopCallLogWatch()
        stopClipWatch()
        FileTransfer.cancelAll()
        Clipboard.forget()
        handler.removeCallbacksAndMessages(null)
        wifiLock?.takeIf { it.isHeld }?.release()
        wakeLock?.takeIf { it.isHeld }?.release()
        socket?.close(1000, "bye")
        if (LinkState.status.value !is LinkState.Status.Rejected) {
            LinkState.status.value = LinkState.Status.Idle
        }
        super.onDestroy()
    }

    private fun connect() {
        if (stopped) return
        val pairing = PairStore.load(this) ?: run { stopSelf(); return }

        // Retire any previous socket before opening a new one, so we never run
        // two links in parallel. The generation guard below makes the retired
        // socket's callbacks no-ops, so this cancel can't bounce us into a
        // reconnect loop.
        val myGen = ++generation
        handler.removeCallbacks(heartbeat)
        socket?.cancel()
        socket = null
        crypto = null
        sessionNonces = null
        LinkState.status.value = LinkState.Status.Connecting

        // The Mac advertises one address per network interface. Walking them
        // means the same pairing works on the home Wi-Fi, on this phone's
        // hotspot, or over a USB / Bluetooth tether, with no re-scan.
        val hosts = pairing.candidates
        val host = hosts[attempt % hosts.size]
        val request = Request.Builder()
            .url("ws://$host:${pairing.wsPort}/")
            .build()

        socket = client.newWebSocket(request, object : WebSocketListener() {
            private fun superseded() = stopped || myGen != generation
            private var macNonceSeen = ""

            // Nonce for this connection; the Mac must sign it to prove it is
            // the Mac we paired with.
            private val myNonce = Handshake.nonce()

            override fun onOpen(webSocket: WebSocket, response: Response) {
                // Deliberately silent. We say nothing — and above all send no
                // credential — until the peer has challenged us, because with
                // discovery we may have just dialled anything on the network
                // that claims to be a Mac.
            }

            /**
             * Everything after the handshake arrives as a sealed binary frame.
             * A forged, replayed or tampered frame opens to null and is dropped
             * without ever being parsed.
             */
            override fun onMessage(webSocket: WebSocket, bytes: okio.ByteString) {
                if (superseded()) return
                val session = crypto ?: return
                val opened = session.open(bytes.toByteArray()) ?: run {
                    android.util.Log.w("TethrLink", "dropped an unopenable frame")
                    return
                }
                when (opened.first) {
                    SessionCrypto.KIND_JSON -> handleText(webSocket, String(opened.second))
                    SessionCrypto.KIND_FILE -> {
                        val body = opened.second
                        if (body.size < FileTransfer.HEADER) return
                        val buf = java.nio.ByteBuffer.wrap(body)
                        val id = buf.int
                        val offset = buf.long
                        val bytes = body.copyOfRange(FileTransfer.HEADER, body.size)
                        FileTransfer.write(id, offset, bytes)
                    }
                    else -> return
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (superseded()) return
                // Plaintext is only ever the handshake; once keys exist, a peer
                // talking in the clear is not the Mac we verified.
                if (crypto != null) return
                handleText(webSocket, text)
            }

            private fun handleText(webSocket: WebSocket, text: String) {
                val msg = runCatching { JSONObject(text) }.getOrNull() ?: return
                when (msg.optString("type")) {
                    // Answer the Mac's challenge. A paired phone proves it
                    // knows the secret rather than handing it over, so a Mac
                    // impersonating ours learns nothing it can reuse.
                    "challenge" -> {
                        val macNonce = msg.optString("nonce")
                        macNonceSeen = macNonce
                        val secret = pairing.secret
                        webSocket.send(JSONObject().apply {
                            put("type", "hello")
                            put("name", deviceName())
                            put("battery", batteryLevel())
                            put("notificationAccess", TethrNotificationService.isEnabled(this@ConnectionService))
                            put("nonce", myNonce)
                            if (secret != null) {
                                put("proof", Handshake.proof(secret, "phone", macNonce, myNonce))
                            } else {
                                // First pairing only: the QR token bootstraps trust.
                                put("token", pairing.token ?: "")
                            }
                        }.toString())
                    }
                    // Commands from the Mac.
                    "dial" -> callController?.dial(msg.optString("number"))
                    "answer" -> callController?.answer()
                    "hangup", "reject" -> callController?.hangup()
                    "setMute" -> { callController?.setMute(msg.optBoolean("on")); sendCallAudio() }
                    "setSpeaker" -> { callController?.setSpeaker(msg.optBoolean("on")); sendCallAudio() }
                    // Remote control from the Mac (needs the accessibility service enabled).
                    "tap" -> TethrGestureService.instance?.tap(msg.optDouble("x"), msg.optDouble("y"))
                    "swipe" -> TethrGestureService.instance?.swipe(
                        msg.optDouble("x1"), msg.optDouble("y1"),
                        msg.optDouble("x2"), msg.optDouble("y2"),
                        msg.optLong("ms", 180L)
                    )
                    "key" -> TethrGestureService.instance?.global(msg.optString("key"))
                    "dismissNotification" ->
                        TethrNotificationService.instance?.dismiss(msg.optString("key"))
                    "replyNotification" -> TethrNotificationService.instance?.reply(
                        msg.optString("key"), msg.optString("text")
                    )
                    "getNotifications" -> TethrNotificationService.instance?.pushAll()
                    // A Mac catching up after sleep: it cannot trust what it
                    // was last told, so it asks rather than assumes.
                    "requestState" -> handler.post { pushCallStateSnapshot() }
                    "clipboard" -> {
                        val text = msg.optString("text")
                        if (text.isNotEmpty()) handler.post {
                            // Length only: the clipboard is exactly the kind of
                            // thing that must not be written to logcat.
                            android.util.Log.i("TethrClip", "clipboard received: ${text.length} chars")
                            Clipboard.apply(applicationContext, text)
                        }
                    }
                    "unlink" -> {
                        // Only ever acted on with proof. The phone dials
                        // whatever it discovers, so an unauthenticated unlink
                        // would be a one-packet way for anyone on the network
                        // to unpair someone's phone — the same reason a bare
                        // "rejected" is ignored below. Signed over this
                        // connection's nonces, so it cannot be replayed either.
                        val known = pairing.secret
                        val expected = known?.let {
                            Handshake.proof(it, "unlink", macNonceSeen, myNonce)
                        }
                        if (expected != null &&
                            Handshake.constantTimeEquals(msg.optString("proof"), expected)
                        ) {
                            android.util.Log.i("TethrLink", "unlinked by the Mac")
                            PairStore.clear(this@ConnectionService)
                            LinkState.paired.value = false
                            LinkState.status.value = LinkState.Status.Unlinked
                            stopped = true
                            webSocket.close(1000, "unlinked")
                            stopSelf()
                        } else {
                            android.util.Log.w("TethrLink", "ignored an unproven unlink")
                        }
                    }
                    "fileStart" -> {
                        val id = msg.optInt("id")
                        val accepted = FileTransfer.begin(
                            applicationContext, id, msg.optString("name"),
                            msg.optLong("size"), msg.optString("mime")
                        ) != null
                        android.util.Log.i("TethrFile", "fileStart accepted=$accepted")
                        if (!accepted) {
                            sendJson(JSONObject().put("type", "fileCancel").put("id", id))
                        }
                    }
                    "fileEnd" -> {
                        val id = msg.optInt("id")
                        Thread {
                            val name = FileTransfer.finish(applicationContext, id)
                            android.util.Log.i("TethrFile", "saved to Downloads: ${name != null}")
                            sendJson(
                                JSONObject().put("type", "fileDone").put("id", id)
                                    .put("ok", name != null)
                            )
                            if (name != null) handler.post { notifyFileSaved(name) }
                        }.start()
                    }
                    "fileCancel" -> FileTransfer.cancel(msg.optInt("id"))
                    "getClipboard" -> handler.post { pullClipboard() }
                    "getContacts" -> pushPhoneData(contacts = true, callLog = false)
                    "getCallLog" -> pushPhoneData(contacts = false, callLog = true)
                    "paired" -> {
                        val macName = msg.optString("macName", "Mac")
                        val issued = msg.optString("secret").takeIf { it.isNotEmpty() }
                        val known = pairing.secret

                        // Verify the Mac before anything of ours reaches it.
                        // Without this an impostor discovered on the network
                        // would receive contacts, call history and the screen.
                        if (known != null) {
                            val expected = Handshake.proof(known, "mac", macNonceSeen, myNonce)
                            if (!Handshake.constantTimeEquals(msg.optString("proof"), expected)) {
                                android.util.Log.w("TethrLink", "peer failed to prove it is our Mac")
                                webSocket.close(1000, "unverified")
                                // Keep the pairing: the real Mac is still out
                                // there, this was just the wrong peer.
                                scheduleReconnect()
                                return
                            }
                        } else if (issued == null) {
                            webSocket.close(1000, "no secret issued")
                            scheduleReconnect()
                            return
                        }
                        // The Mac is verified and the secret is settled: from
                        // the next frame on, everything is encrypted. Derived
                        // from this connection's nonces, so the keys die with it.
                        val sessionSecret = issued ?: known
                        if (sessionSecret == null) {
                            webSocket.close(1000, "no secret")
                            scheduleReconnect()
                            return
                        }
                        crypto = SessionCrypto(sessionSecret, macNonceSeen, myNonce)
                        sessionNonces = macNonceSeen to myNonce

                        // Promote the address that actually worked, so the next
                        // launch dials it first instead of sweeping again.
                        attempt = 0
                        stopFinding()
                        PairStore.save(
                            this@ConnectionService,
                            pairing.copy(
                                host = host,
                                secret = issued ?: known,
                                macName = macName
                            )
                        )
                        LinkState.paired.value = true
                        LinkState.status.value = LinkState.Status.Connected(macName)
                        handler.post {
                            updateNotification("Connected to $macName")
                            handler.removeCallbacks(heartbeat)
                            handler.post(heartbeat)
                            startCallController()
                            // Before anything else the Mac renders: it may have
                            // been showing a call that ended while it was away.
                            pushCallStateSnapshot()
                            pushPhoneData()
                            startCallLogWatch()
                            startClipWatch()
                            pushClipboard()
                            flushPendingSends()
                            TethrNotificationService.instance?.pushAll()
                        }
                    }
                    "rejected" -> {
                        // Only meaningful while bootstrapping. Once we hold a
                        // secret, an unverified peer saying "rejected" would
                        // otherwise be able to unpair the phone at will — a
                        // one-packet denial of service now that we auto-connect
                        // to whatever we discover.
                        if (pairing.secret == null) {
                            LinkState.status.value = LinkState.Status.Rejected
                            stopped = true
                            webSocket.close(1000, "rejected")
                            stopSelf()
                        } else {
                            webSocket.close(1000, "not our mac")
                            scheduleReconnect()
                        }
                    }
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (superseded()) return
                android.util.Log.w("TethrLink", "onFailure: ${t.javaClass.simpleName}: ${t.message} resp=${response?.code}")
                scheduleReconnect()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (superseded()) return
                android.util.Log.w("TethrLink", "onClosed: code=$code reason=$reason")
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        if (stopped) return
        handler.removeCallbacks(heartbeat)
        LinkState.status.value = LinkState.Status.Connecting

        // Move to the Mac's next address. Sweeping the remaining ones is quick
        // — a wrong address fails fast because it is on another subnet — but we
        // back off properly once a whole sweep has come up empty.
        val count = (PairStore.load(this)?.candidates?.size ?: 1).coerceAtLeast(1)
        attempt++
        val sweeping = count > 1 && attempt % count != 0
        handler.post {
            updateNotification(if (sweeping) "Looking for your Mac…" else "Reconnecting…")
        }
        // Remembered addresses go stale the moment either device changes
        // network, so discovery runs alongside the sweep rather than after it.
        startFinding(fullSweep = !sweeping)
        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, if (sweeping) 600L else 3_000L)
    }

    // MARK: Contacts / call log / call control

    private fun startCallController() {
        if (callController != null) return
        // Telephony reports the current state the moment we register, so a
        // fresh listener always opens with "idle". Remembering the previous
        // state is what tells a call that actually ended apart from that.
        var lastCallState = "idle"
        val ctrl = CallController(applicationContext) { state, number ->
            // Forward every call-state change to the Mac, plus current audio
            // state. The name lookup is a content query and this callback
            // arrives on the main thread mid-ring, so it happens off it.
            pushCallState(state, number)
            sendCallAudio()
            // The row for a call that just ended is written a beat after the
            // state goes idle — pull it then, in case the log's own change
            // notification never arrives (some OEMs suppress it).
            if (state == "idle" && lastCallState != "idle") {
                scheduleCallLogPush(CALL_LOG_SETTLE_MS)
            }
            lastCallState = state
        }
        ctrl.start()
        callController = ctrl
    }

    /** Reports current mic-mute / speakerphone state to the Mac. */
    /**
     * Tell the Mac about a call. The name lookup is a content query and the
     * telephony callback arrives on the main thread mid-ring, so it happens
     * off it.
     */
    private fun pushCallState(state: String, number: String?) {
        Thread {
            val name = number?.takeIf { it.isNotBlank() }
                ?.let { PhoneData.contactName(applicationContext, it) }
            // Whether we identified the caller, never who: the number and
            // the name are the two things that must not reach logcat.
            android.util.Log.i(
                "TethrCall",
                "state=$state number=${number != null} named=${name != null}"
            )
            sendJson(
                JSONObject()
                    .put("type", "callState")
                    .put("state", state)
                    .apply {
                        number?.let { put("number", it) }
                        name?.let { put("name", it) }
                    }
            )
        }.start()
    }

    /**
     * The current call state, sent unprompted rather than on a transition.
     *
     * Sent whenever a Mac finishes verifying, and whenever one asks: a Mac that
     * slept through the end of a call has no other way to find out it is over.
     */
    fun pushCallStateSnapshot() {
        val ctrl = callController ?: return
        val state = ctrl.currentState
        pushCallState(state, if (state == "idle") null else ctrl.currentNumber)
        sendCallAudio()
    }

    private fun sendCallAudio() {
        val c = callController ?: return
        sendJson(
            JSONObject()
                .put("type", "callAudio")
                .put("muted", c.isMuted)
                .put("speaker", c.isSpeakerOn)
        )
    }

    /**
     * Mirrors the system call log to the Mac as Android writes to it, so recents
     * stay current without a manual resync. Registration needs READ_CALL_LOG, so
     * it is retried from every path that pushes phone data — the permission is
     * often granted well after the service starts.
     */
    private fun startCallLogWatch() {
        if (callLogObserver != null) return
        if (!PhoneData.hasPermission(this, android.Manifest.permission.READ_CALL_LOG)) return
        val observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) = scheduleCallLogPush(CALL_LOG_DEBOUNCE_MS)
        }
        val registered = runCatching {
            contentResolver.registerContentObserver(CallLog.Calls.CONTENT_URI, true, observer)
        }.isSuccess
        if (registered) callLogObserver = observer
    }

    /**
     * Sends the clipboard to the Mac, if there is anything new to send and the
     * platform is willing to hand it over.
     */
    fun pushClipboard() {
        if (socket == null) return
        val (text, skip) = Clipboard.takeIfNew(applicationContext)
        if (text == null) {
            android.util.Log.i("TethrClip", "clipboard not sent: $skip")
            return
        }
        sendClipboard(text)
    }

    /**
     * Answers the Mac's request for the phone's clipboard.
     *
     * A plain read first: it costs nothing and succeeds outright whenever Tethr
     * happens to be on screen. Only when the platform stonewalls us does this
     * fall back to [ClipboardReader], which has to take focus to get an answer
     * — not something to do when a direct read would have done.
     */
    private fun pullClipboard() {
        if (socket == null) return
        val (text, skip) = Clipboard.takeIfNew(applicationContext)
        if (text != null) {
            sendClipboard(text)
            return
        }
        // Nothing new, or nothing we're allowed to share: either way, taking
        // focus would buy us nothing.
        if (skip == Clipboard.Skip.UNCHANGED || skip == Clipboard.Skip.SENSITIVE) {
            android.util.Log.i("TethrClip", "clipboard not sent: $skip")
            return
        }
        ClipboardReader.read(applicationContext) { overlayText, overlaySkip ->
            if (overlayText != null) {
                sendClipboard(overlayText)
            } else {
                android.util.Log.i("TethrClip", "clipboard not sent: $overlaySkip (overlay)")
            }
        }
    }

    /** Proves who we are, then tells the Mac to forget this phone. */
    private fun sendSignedUnlink() {
        val secret = PairStore.load(this)?.secret ?: return
        val (macNonce, myNonce) = sessionNonces ?: return
        sendJson(
            JSONObject()
                .put("type", "unlink")
                .put("proof", Handshake.proof(secret, "unlink-phone", macNonce, myNonce))
        )
    }

    /**
     * Streams a file to the Mac in chunks.
     *
     * Paced against the socket's own backlog: pushing a large file as fast as
     * it reads would bury the heartbeat and the mirror behind megabytes of
     * queued frames, and OkHttp kills a connection whose send buffer runs away.
     */
    /** Sends a file the share sheet handed us, deleting the staged copy after. */
    fun sendStaged(item: Outgoing) {
        val ws = socket
        if (ws == null || crypto == null) {
            pendingSends.add(item)
            if (ws == null) connect()
            return
        }
        Thread {
            val size = item.file.length()
            val name = item.name
            val mime = item.mime
            if (size <= 0) {
                android.util.Log.w("TethrFile", "nothing to send")
                item.file.delete()
                return@Thread
            }
            val id = nextTransferId.getAndIncrement()
            sendJson(
                JSONObject().put("type", "fileStart").put("id", id)
                    .put("name", name).put("size", size).put("mime", mime)
            )
            val sent = runCatching {
                item.file.inputStream().use { input ->
                    val buffer = ByteArray(FileTransfer.CHUNK)
                    var offset = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        // Let the socket drain rather than piling on.
                        while (ws.queueSize() > MAX_QUEUED_BYTES && socket === ws) Thread.sleep(15)
                        if (socket !== ws) return@use false
                        val session = crypto ?: return@use false
                        val payload = FileTransfer.header(id, offset) + buffer.copyOf(read)
                        synchronized(sendLock) {
                            ws.send(session.seal(SessionCrypto.KIND_FILE, payload).toByteString())
                        }
                        offset += read
                    }
                    true
                }
            }.getOrDefault(false)
            if (sent) {
                sendJson(JSONObject().put("type", "fileEnd").put("id", id))
            } else {
                sendJson(JSONObject().put("type", "fileCancel").put("id", id))
            }
            android.util.Log.i("TethrFile", "sent $size bytes ok=$sent")
            item.file.delete()
        }.start()
    }

    /** Sends anything shared while the link was still coming up. */
    private fun flushPendingSends() {
        while (true) {
            val item = pendingSends.poll() ?: return
            android.util.Log.i("TethrFile", "sending a queued share")
            sendStaged(item)
        }
    }

    private fun queryName(uri: android.net.Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) return c.getString(i) ?: "file"
        }
        return uri.lastPathSegment ?: "file"
    }

    /**
     * The size has to be right: the receiver refuses any chunk that would take
     * the file past what was declared, so a wrong or missing size does not
     * shorten the transfer — it kills it. OpenableColumns.SIZE is absent for
     * plenty of providers, so the file descriptor is the reliable answer.
     */
    private fun querySize(uri: android.net.Uri): Long {
        runCatching {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (i >= 0 && c.moveToFirst() && !c.isNull(i)) {
                    val n = c.getLong(i)
                    if (n > 0) return n
                }
            }
        }
        return runCatching {
            contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize }
        }.getOrNull()?.takeIf { it > 0 } ?: 0L
    }

    /** Tells the user where an arriving file went — it is not otherwise visible. */
    private fun notifyFileSaved(name: String) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val n = Notification.Builder(this, CHANNEL)
            .setContentTitle("Saved from your Mac")
            .setContentText(name)
            .setSmallIcon(R.drawable.ic_tethr_notification)
            .setAutoCancel(true)
            .build()
        nm.notify(name.hashCode(), n)
    }

    private fun sendClipboard(text: String) {
        if (socket == null) return
        android.util.Log.i("TethrClip", "clipboard sent: ${text.length} chars")
        runCatching {
            sendJson(JSONObject().put("type", "clipboard").put("text", text))
        }
    }

    private fun startClipWatch() {
        if (clipListener != null) return
        val manager = getSystemService(Context.CLIPBOARD_SERVICE)
            as? android.content.ClipboardManager ?: return
        val listener = android.content.ClipboardManager.OnPrimaryClipChangedListener {
            pushClipboard()
        }
        runCatching { manager.addPrimaryClipChangedListener(listener) }
            .onSuccess { clipListener = listener }
    }

    private fun stopClipWatch() {
        val listener = clipListener ?: return
        val manager = getSystemService(Context.CLIPBOARD_SERVICE)
            as? android.content.ClipboardManager
        runCatching { manager?.removePrimaryClipChangedListener(listener) }
        clipListener = null
    }

    private fun stopCallLogWatch() {
        callLogObserver?.let { runCatching { contentResolver.unregisterContentObserver(it) } }
        callLogObserver = null
        handler.removeCallbacks(callLogPush)
    }

    /** Coalesces the several changes one call produces into a single push. */
    private fun scheduleCallLogPush(delayMs: Long) {
        handler.removeCallbacks(callLogPush)
        handler.postDelayed(callLogPush, delayMs)
    }

    /**
     * Re-sends contacts and call history and (re)arms the call-log watch. Called
     * when permissions are granted after the link is already up, where the first
     * push went out empty.
     */
    fun refreshPhoneData() {
        handler.post {
            startCallController()
            startCallLogWatch()
            pushPhoneData()
        }
    }

    /** Queries contacts/call log off the main thread and streams them to the Mac. */
    private fun pushPhoneData(contacts: Boolean = true, callLog: Boolean = true) {
        if (socket == null) return
        Thread {
            if (contacts) {
                val msg = PhoneData.contactsMessage(applicationContext)
                android.util.Log.i("TethrData", "contacts sent: ${msg.getJSONArray("items").length()}")
                sendJson(msg)
            }
            if (callLog) {
                val msg = PhoneData.callLogMessage(applicationContext)
                android.util.Log.i("TethrData", "calllog sent: ${msg.getJSONArray("items").length()}")
                sendJson(msg)
            }
        }.start()
    }

    // MARK: Screen mirroring

    private fun startMirroring(intent: Intent) {
        if (projection != null) return
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val data: Intent = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_RESULT_DATA)
        } ?: return

        val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = runCatching { mgr.getMediaProjection(resultCode, data) }.getOrNull() ?: return
        projection = proj
        proj.registerCallback(projectionCallback, handler)

        val thread = HandlerThread("tethr-mirror").apply { start() }
        mirrorThread = thread
        val mHandler = Handler(thread.looper)
        mirrorHandler = mHandler

        val dm = resources.displayMetrics
        mirrorWidth = 432
        mirrorHeight = dm.heightPixels * mirrorWidth / dm.widthPixels
        lastFrameAt = 0L
        imageReader = ImageReader.newInstance(mirrorWidth, mirrorHeight, PixelFormat.RGBA_8888, 2).apply {
            setOnImageAvailableListener(frameListener, mHandler)
        }
        virtualDisplay = proj.createVirtualDisplay(
            "tethr-mirror", mirrorWidth, mirrorHeight, dm.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, mHandler
        )
        LinkState.mirroring.value = true
    }

    private fun stopMirroring() {
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.setOnImageAvailableListener(null, null)
        imageReader?.close()
        imageReader = null
        projection?.unregisterCallback(projectionCallback)
        projection?.stop()
        projection = null
        mirrorThread?.quitSafely()
        mirrorThread = null
        mirrorHandler = null
        if (LinkState.mirroring.value) {
            LinkState.mirroring.value = false
            sendJson(JSONObject().put("type", "mirrorStopped"))
            promoteForeground(mirroring = false)
        }
    }

    /** Encodes a captured frame to JPEG. Runs on the mirror thread. */
    private fun encodeFrame(image: android.media.Image): ByteArray? {
        val plane = image.planes[0]
        val rowPixels = plane.rowStride / plane.pixelStride
        val bitmap = Bitmap.createBitmap(rowPixels, mirrorHeight, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(plane.buffer)
        val cropped = if (rowPixels != mirrorWidth) {
            Bitmap.createBitmap(bitmap, 0, 0, mirrorWidth, mirrorHeight)
        } else bitmap
        val out = ByteArrayOutputStream()
        cropped.compress(Bitmap.CompressFormat.JPEG, 55, out)
        return out.toByteArray()
    }

    private fun deviceName(): String =
        Build.MODEL.takeIf { it.isNotBlank() } ?: "Android Phone"

    private fun batteryLevel(): Int {
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
    }

    private fun buildNotification(text: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Phone Link", NotificationManager.IMPORTANCE_LOW)
        )
        val tap = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_tethr_notification)
            .setContentTitle("Tethr")
            .setContentText(text)
            .setContentIntent(tap)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        @Volatile
        var instance: ConnectionService? = null

        private const val CHANNEL = "tethr.link"
        private const val NOTIFICATION_ID = 1
        // Drop new frames while more than this many bytes are still buffered on
        // the socket — bounds latency and stops OkHttp's send buffer overflowing.
        private const val MAX_QUEUED_BYTES = 256L * 1024
        // Quiet window after a call-log change before pushing: one call writes
        // its row and then updates it, and we want to send the finished picture.
        private const val CALL_LOG_DEBOUNCE_MS = 1_200L
        // Longer wait from "call ended" — the row may not exist yet at that point.
        private const val CALL_LOG_SETTLE_MS = 2_500L
        // ~30 fps ceiling on encode/send work.
        private const val MIN_FRAME_INTERVAL_MS = 33L
        const val ACTION_START_MIRROR = "com.nikhilraj.tethr.START_MIRROR"
        const val ACTION_STOP_MIRROR = "com.nikhilraj.tethr.STOP_MIRROR"
        const val ACTION_SEND_FILE = "com.nikhilraj.tethr.SEND_FILE"
        const val EXTRA_FILE_PATH = "filePath"
        const val EXTRA_FILE_NAME = "fileName"
        const val EXTRA_FILE_MIME = "fileMime"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        // Cap on remembered addresses, so months of new networks don't make
        // every cold start walk a long list.
        private const val MAX_HOSTS = 8

        fun start(context: Context) {
            context.startForegroundService(Intent(context, ConnectionService::class.java))
        }

        fun startMirror(context: Context, resultCode: Int, data: Intent) {
            context.startForegroundService(
                Intent(context, ConnectionService::class.java)
                    .setAction(ACTION_START_MIRROR)
                    .putExtra(EXTRA_RESULT_CODE, resultCode)
                    .putExtra(EXTRA_RESULT_DATA, data)
            )
        }

        fun stopMirror(context: Context) {
            context.startForegroundService(
                Intent(context, ConnectionService::class.java).setAction(ACTION_STOP_MIRROR)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ConnectionService::class.java))
        }

        /**
         * Unlinks from the Mac end too, so the two never disagree about whether
         * they are paired. Signed over this connection's nonces for the same
         * reason the Mac signs its own: neither side acts on an unproven one.
         */
        fun unlinkFromMac() {
            val service = instance ?: return
            service.sendSignedUnlink()
        }
    }
}
