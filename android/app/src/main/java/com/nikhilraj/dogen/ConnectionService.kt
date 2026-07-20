package com.nikhilraj.dogen

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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
    }

    val status = MutableStateFlow<Status>(Status.Idle)
    val mirroring = MutableStateFlow(false)
}

/**
 * Foreground service that keeps the WebSocket link to the Mac alive.
 * Speaks the Dogen pairing protocol: hello -> paired, then a 5s ping heartbeat
 * carrying the battery level. Reconnects automatically with a short backoff.
 */
class ConnectionService : Service() {

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        // WS-level pings detect half-open sockets (Wi-Fi power save) and
        // surface them as onFailure so the reconnect loop can recover.
        .pingInterval(10, TimeUnit.SECONDS)
        .build()

    private val handler = Handler(Looper.getMainLooper())
    private var socket: WebSocket? = null
    private var callController: CallController? = null
    // Bumped on every connect() so callbacks from a superseded socket are
    // ignored — stops a cancelled old socket from triggering a reconnect storm.
    private var generation = 0
    private var stopped = false
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
            ws.send(bytes.toByteString())
            lastFrameAt = now
        } finally {
            image.close()
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            socket?.send(JSONObject().apply {
                put("type", "ping")
                put("battery", batteryLevel())
            }.toString())
            handler.postDelayed(this, 5_000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_MIRROR -> {
                promoteForeground(mirroring = true)
                startMirroring(intent)
            }
            ACTION_STOP_MIRROR -> stopMirroring()
            else -> {
                promoteForeground(mirroring = false)
                acquireLocks()
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
        if (Build.VERSION.SDK_INT >= 29) {
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
                android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "dogen:link"
            ).apply { acquire() }
        }
        if (wakeLock == null) {
            // Keeps heartbeats flowing while the screen is off; without it Doze
            // freezes the timers and the Mac times the link out.
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dogen:link")
                .apply { acquire() }
        }
    }

    override fun onDestroy() {
        stopped = true
        stopMirroring()
        callController?.stop()
        callController = null
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
        LinkState.status.value = LinkState.Status.Connecting

        val request = Request.Builder()
            .url("ws://${pairing.host}:${pairing.wsPort}/")
            .build()

        socket = client.newWebSocket(request, object : WebSocketListener() {
            private fun superseded() = stopped || myGen != generation

            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (superseded()) return
                webSocket.send(JSONObject().apply {
                    put("type", "hello")
                    put("token", pairing.token ?: "")
                    put("secret", pairing.secret)
                    put("name", deviceName())
                    put("battery", batteryLevel())
                }.toString())
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (superseded()) return
                val msg = runCatching { JSONObject(text) }.getOrNull() ?: return
                when (msg.optString("type")) {
                    // Commands from the Mac.
                    "dial" -> callController?.dial(msg.optString("number"))
                    "answer" -> callController?.answer()
                    "hangup", "reject" -> callController?.hangup()
                    "setMute" -> { callController?.setMute(msg.optBoolean("on")); sendCallAudio() }
                    "setSpeaker" -> { callController?.setSpeaker(msg.optBoolean("on")); sendCallAudio() }
                    // Remote control from the Mac (needs the accessibility service enabled).
                    "tap" -> DogenGestureService.instance?.tap(msg.optDouble("x"), msg.optDouble("y"))
                    "swipe" -> DogenGestureService.instance?.swipe(
                        msg.optDouble("x1"), msg.optDouble("y1"),
                        msg.optDouble("x2"), msg.optDouble("y2"),
                        msg.optLong("ms", 180L)
                    )
                    "key" -> DogenGestureService.instance?.global(msg.optString("key"))
                    "getContacts" -> pushPhoneData(contacts = true, callLog = false)
                    "getCallLog" -> pushPhoneData(contacts = false, callLog = true)
                    "paired" -> {
                        val macName = msg.optString("macName", "Mac")
                        PairStore.save(
                            this@ConnectionService,
                            pairing.copy(secret = msg.optString("secret"), macName = macName)
                        )
                        LinkState.status.value = LinkState.Status.Connected(macName)
                        handler.post {
                            updateNotification("Connected to $macName")
                            handler.removeCallbacks(heartbeat)
                            handler.post(heartbeat)
                            startCallController()
                            pushPhoneData()
                        }
                    }
                    "rejected" -> {
                        PairStore.save(this@ConnectionService, pairing.copy(secret = null))
                        LinkState.status.value = LinkState.Status.Rejected
                        stopped = true
                        webSocket.close(1000, "rejected")
                        stopSelf()
                    }
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (superseded()) return
                android.util.Log.w("DogenLink", "onFailure: ${t.javaClass.simpleName}: ${t.message} resp=${response?.code}")
                scheduleReconnect()
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (superseded()) return
                android.util.Log.w("DogenLink", "onClosed: code=$code reason=$reason")
                scheduleReconnect()
            }
        })
    }

    private fun scheduleReconnect() {
        if (stopped) return
        handler.removeCallbacks(heartbeat)
        LinkState.status.value = LinkState.Status.Connecting
        handler.post { updateNotification("Reconnecting…") }
        handler.postDelayed({ connect() }, 3_000)
    }

    // MARK: Contacts / call log / call control

    private fun startCallController() {
        if (callController != null) return
        val ctrl = CallController(applicationContext) { state, number ->
            // Forward every call-state change to the Mac, plus current audio state.
            socket?.send(
                JSONObject()
                    .put("type", "callState")
                    .put("state", state)
                    .apply { number?.let { put("number", it) } }
                    .toString()
            )
            sendCallAudio()
        }
        ctrl.start()
        callController = ctrl
    }

    /** Reports current mic-mute / speakerphone state to the Mac. */
    private fun sendCallAudio() {
        val c = callController ?: return
        socket?.send(
            JSONObject()
                .put("type", "callAudio")
                .put("muted", c.isMuted)
                .put("speaker", c.isSpeakerOn)
                .toString()
        )
    }

    /** Queries contacts/call log off the main thread and streams them to the Mac. */
    private fun pushPhoneData(contacts: Boolean = true, callLog: Boolean = true) {
        val ws = socket ?: return
        Thread {
            if (contacts) {
                val msg = PhoneData.contactsMessage(applicationContext)
                android.util.Log.i("DogenData", "contacts sent: ${msg.getJSONArray("items").length()}")
                runCatching { ws.send(msg.toString()) }
            }
            if (callLog) {
                val msg = PhoneData.callLogMessage(applicationContext)
                android.util.Log.i("DogenData", "calllog sent: ${msg.getJSONArray("items").length()}")
                runCatching { ws.send(msg.toString()) }
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

        val thread = HandlerThread("dogen-mirror").apply { start() }
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
            "dogen-mirror", mirrorWidth, mirrorHeight, dm.densityDpi,
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
            socket?.send(JSONObject().put("type", "mirrorStopped").toString())
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
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Dogen")
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
        private const val CHANNEL = "dogen.link"
        private const val NOTIFICATION_ID = 1
        // Drop new frames while more than this many bytes are still buffered on
        // the socket — bounds latency and stops OkHttp's send buffer overflowing.
        private const val MAX_QUEUED_BYTES = 256L * 1024
        // ~30 fps ceiling on encode/send work.
        private const val MIN_FRAME_INTERVAL_MS = 33L
        const val ACTION_START_MIRROR = "com.nikhilraj.dogen.START_MIRROR"
        const val ACTION_STOP_MIRROR = "com.nikhilraj.dogen.STOP_MIRROR"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

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
    }
}
