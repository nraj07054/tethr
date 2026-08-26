package com.nikhilraj.tethr

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.app.Activity
import android.media.projection.MediaProjectionManager
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

class MainActivity : ComponentActivity() {
    private val phonePermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            // Contacts and the call log read back empty without permission, so a
            // link that came up before this point is holding an empty sync.
            if (result.values.any { it }) ConnectionService.instance?.refreshPhoneData()
        }

    /**
     * Window focus, not onResume, is what unlocks the clipboard: the platform
     * gates the read on the focused *window*, and onResume runs before the
     * window has it — a read there comes back empty. This is the moment
     * anything copied while Tethr was away can finally reach the Mac.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) ConnectionService.instance?.pushClipboard()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Ask for contacts / call log / calling up front so sync works once linked.
        requestPhonePermissions()
        // Reconnect automatically when the app opens and a Mac is already linked.
        val pairing = PairStore.load(this)
        LinkState.paired.value = pairing != null
        if (pairing != null) ConnectionService.start(this)
        setContent { TethrScreen() }
    }

    private fun requestPhonePermissions() {
        val wanted = listOf(
            Manifest.permission.READ_CONTACTS,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.ANSWER_PHONE_CALLS,
            // Messages. Asked for alongside the rest rather than behind their
            // own prompt: refusing them costs the Messages tab and nothing else,
            // and the Mac copes with an empty thread list either way.
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS,
        ).filter {
            checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (wanted.isNotEmpty()) phonePermissions.launch(wanted.toTypedArray())
    }
}

// Tethr's "Glide" design language, matching the Mac app: a soft neutral canvas,
// floating white cards with generous corner radii, and one solid ink action.
private val Canvas0 = Color(0xFFEFEFF1)
private val Surface = Color(0xFFFFFFFF)
private val SurfaceAlt = Color(0xFFF2F2F5)
private val Ink = Color(0xFF101114)
private val InkSoft = Color(0xFF6C6D74)
private val InkFaint = Color(0xFF9C9DA4)
private val Hairline = Color(0xFFE5E5E9)
private val Green = Color(0xFF1FA85A)
private val Orange = Color(0xFFE8880C)
private val Red = Color(0xFFE03131)
private val Blue = Color(0xFF2563EB)
private val Purple = Color(0xFF7A5AF8)

private val CardShape = RoundedCornerShape(26.dp)
private val TileShape = RoundedCornerShape(18.dp)

@Composable
fun TethrScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val status by LinkState.status.collectAsState()
    val mirroring by LinkState.mirroring.collectAsState()
    // Observed, not read once: the Mac can unlink this phone at any moment and
    // the screen has to follow immediately rather than on the next launch.
    val linked by LinkState.paired.collectAsState()

    // Track whether the "control from Mac" accessibility service is enabled,
    // refreshing when the user returns from Settings.
    var controlEnabled by remember { mutableStateOf(TethrGestureService.isEnabled(context)) }
    var notifAccess by remember { mutableStateOf(TethrNotificationService.isEnabled(context)) }
    var batteryOk by remember { mutableStateOf(Background.isBatteryUnrestricted(context)) }
    var clipboardOk by remember { mutableStateOf(ClipboardReader.canReadInBackground(context)) }
    // Whether this skin gates background work behind a manual opt-in.
    val hasAutoStart = remember { Background.needsAutoStartOptIn() }
    DisposableEffect(Unit) {
        val owner = context as? androidx.lifecycle.LifecycleOwner
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            if (e == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                controlEnabled = TethrGestureService.isEnabled(context)
                notifAccess = TethrNotificationService.isEnabled(context)
                batteryOk = Background.isBatteryUnrestricted(context)
                clipboardOk = ClipboardReader.canReadInBackground(context)
            }
        }
        owner?.lifecycle?.addObserver(obs)
        onDispose { owner?.lifecycle?.removeObserver(obs) }
    }

    val projectionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            ConnectionService.startMirror(context, result.resultCode, data)
        }
    }

    val notifPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    // OpenDocument rather than GetContent: it returns a durable URI the service
    // can still read after this screen has gone away mid-transfer.
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        // Staged for the same reason a share is: the grant does not outlive the
        // screen, and the link may not be up for a while yet.
        Thread {
            FileTransfer.stage(context, uri)?.let {
                ConnectionService.instance?.sendStaged(
                    ConnectionService.Outgoing(it.file, it.name, it.mime)
                )
            }
        }.start()
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        val pairing = result.contents?.let(PairStore::fromQR) ?: return@rememberLauncherForActivityResult
        PairStore.save(context, pairing)
        LinkState.paired.value = true
        ConnectionService.start(context)
    }

    fun scan() {
        if (Build.VERSION.SDK_INT >= 33) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        scanner.launch(ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            // Our own capture screen; the prompt lives in its overlay.
            setCaptureActivity(ScannerActivity::class.java)
            setPrompt("")
            setBeepEnabled(false)
            setOrientationLocked(true)
        })
    }

    fun toggleMirror() {
        if (mirroring) {
            ConnectionService.stopMirror(context)
        } else {
            val mgr = context.getSystemService(MediaProjectionManager::class.java)
            projectionLauncher.launch(mgr.createScreenCaptureIntent())
        }
    }

    fun unlink() {
        // Tell the Mac first, while the secret needed to prove it is still
        // here. Otherwise the Mac stays paired and keeps accepting a phone that
        // has already forgotten it.
        ConnectionService.unlinkFromMac()
        ConnectionService.stop(context)
        PairStore.clear(context)
        LinkState.paired.value = false
        LinkState.status.value = LinkState.Status.Idle
    }

    val connected = status is LinkState.Status.Connected
    val rejected = status is LinkState.Status.Rejected
    val macName = (status as? LinkState.Status.Connected)?.macName

    Box(
        Modifier
            .fillMaxSize()
            .background(Canvas0)
            .windowInsetsPadding(WindowInsets.systemBars)
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(top = 18.dp, bottom = if (linked) 110.dp else 28.dp)
        ) {
            Greeting(macName)

            Spacer(Modifier.height(18.dp))
            StatusRow(status, linked)

            Spacer(Modifier.height(20.dp))
            HeroCard(
                rejected = rejected,
                linked = linked,
                connected = connected,
                mirroring = mirroring,
                macName = macName,
                onScan = ::scan,
                onToggleMirror = ::toggleMirror
            )

            Spacer(Modifier.height(26.dp))
            Text(
                "What runs over the link",
                color = Ink,
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold
            )

            Spacer(Modifier.height(12.dp))
            FeatureRow(
                mirroring = mirroring,
                connected = connected,
                controlEnabled = controlEnabled,
                notifAccess = notifAccess
            )

            if (linked && !controlEnabled) {
                Spacer(Modifier.height(12.dp))
                EnablePrompt(
                    "Enable control from Mac",
                    "Settings → Accessibility → Tethr",
                ) { TethrGestureService.openSettings(context) }
            }

            if (linked && !notifAccess) {
                Spacer(Modifier.height(12.dp))
                EnablePrompt(
                    "Mirror your notifications",
                    "Settings → Notification access → Tethr",
                ) { TethrNotificationService.openSettings(context) }
            }

            if (linked) {
                Spacer(Modifier.height(26.dp))
                Text(
                    "Runs in background",
                    color = Ink,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold
                )
                Spacer(Modifier.height(12.dp))
                FeatureCard(
                    tint = Ink,
                    title = "Reconnects on its own",
                    detail = "After a reboot, with the app closed",
                    live = true
                ) { PowerGlyph(Color.White, 20.dp) }

                if (!batteryOk) {
                    Spacer(Modifier.height(9.dp))
                    EnablePrompt(
                        "Allow background activity",
                        "Stops Android pausing the link to save power",
                    ) { Background.requestBatteryUnrestricted(context) }
                }

                if (connected) {
                    Spacer(Modifier.height(9.dp))
                    EnablePrompt(
                        "Send a file to your Mac",
                        "It lands in Downloads there",
                    ) { filePicker.launch(arrayOf("*/*")) }
                }

                if (!clipboardOk) {
                    Spacer(Modifier.height(9.dp))
                    EnablePrompt(
                        "Share clipboard with the Mac",
                        "Android only lets the app on screen read the clipboard — this is how it answers from the background",
                    ) { ClipboardReader.requestPermission(context) }
                }

                // No API can read or set this one, so it is always offered
                // rather than shown as satisfied.
                if (hasAutoStart) {
                    Spacer(Modifier.height(9.dp))
                    EnablePrompt(
                        "Allow auto-start",
                        "This phone blocks it by default — turn on Auto launch",
                    ) { Background.openAutoStart(context) }
                }
            }
        }

        if (linked) {
            NavPill(
                mirroring = mirroring,
                controlEnabled = controlEnabled,
                onMirror = ::toggleMirror,
                onControl = { TethrGestureService.openSettings(context) },
                onUnlink = ::unlink,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 22.dp)
            )
        }
    }
}

@Composable
private fun Greeting(macName: String?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(
                "Tethr",
                color = Ink,
                fontSize = 30.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.8).sp
            )
            Text(
                macName?.let { "Linked to $it" } ?: "Your phone, on your Mac",
                color = InkSoft,
                fontSize = 13.sp
            )
        }
        TethrMark(
            46.dp,
            Modifier.shadow(10.dp, RoundedCornerShape(15.dp), clip = false)
        )
    }
}

@Composable
private fun StatusRow(status: LinkState.Status, linked: Boolean) {
    val pulse by rememberInfiniteTransition(label = "pulse").animateFloat(
        initialValue = 1f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
        label = "pulse"
    )

    val (color, text, animate) = when {
        status is LinkState.Status.Connected -> Triple(Green, "Connected over Wi-Fi", false)
        status is LinkState.Status.Rejected -> Triple(Red, "Pairing failed", false)
        status is LinkState.Status.Unlinked -> Triple(Orange, "Unlinked by your Mac", false)
        linked -> Triple(Orange, "Connecting…", true)
        else -> Triple(InkFaint, "Not linked yet", false)
    }

    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier
                .shadow(8.dp, CircleShape, clip = false)
                .clip(CircleShape)
                .background(Surface)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .size(7.dp)
                    .alpha(if (animate) pulse else 1f)
                    .background(color, CircleShape)
            )
            Spacer(Modifier.width(8.dp))
            Text(text, color = Ink, fontSize = 12.5.sp, fontWeight = FontWeight.Medium)
        }
        Row(
            Modifier
                .clip(CircleShape)
                .border(1.dp, Hairline, CircleShape)
                .padding(horizontal = 14.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Local network only", color = InkSoft, fontSize = 12.5.sp)
        }
    }
}

/// The one big card on the screen — dark hero block plus the primary action.
@Composable
private fun HeroCard(
    rejected: Boolean,
    linked: Boolean,
    connected: Boolean,
    mirroring: Boolean,
    macName: String?,
    onScan: () -> Unit,
    onToggleMirror: () -> Unit
) {
    data class Copy(val tag: String, val title: String, val body: String,
                    val action: String, val onClick: () -> Unit, val destructive: Boolean)

    val copy = when {
        rejected -> Copy(
            "Pairing", "Pairing failed",
            "The code didn't match. Scan the QR code shown in Tethr on your Mac again.",
            "Scan Again", onScan, false
        )
        !linked -> Copy(
            "Step 1 of 1", "Link your Mac",
            "Open Tethr on your Mac and scan the QR code to connect over Wi-Fi.",
            "Scan QR Code", onScan, false
        )
        connected && mirroring -> Copy(
            "Live", "Mirroring your screen",
            "Your screen is streaming to ${macName ?: "your Mac"} in real time.",
            "Stop Mirroring", onToggleMirror, true
        )
        connected -> Copy(
            "Ready", "Mirror your screen",
            "Stream this phone's screen to ${macName ?: "your Mac"} and control it from there.",
            "Mirror Screen", onToggleMirror, false
        )
        else -> Copy(
            "Reconnecting", "Connecting…",
            "Keep Tethr open — the link keeps running in the background.",
            "Mirror Screen", onToggleMirror, false
        )
    }

    Column(
        Modifier
            .fillMaxWidth()
            .shadow(16.dp, CardShape, clip = false)
            .clip(CardShape)
            .background(Surface)
    ) {
        // Dark hero block, the way a photo sits at the top of a card.
        Box(
            Modifier
                .fillMaxWidth()
                .height(168.dp)
                .clip(CardShape)
                .background(Ink)
        ) {
            Box(
                Modifier
                    .align(Alignment.Center)
                    .size(74.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(Color.White.copy(alpha = 0.10f))
                    .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(24.dp)),
                contentAlignment = Alignment.Center
            ) {
                PhoneGlyph(Color.White, 32.dp)
            }
            Row(
                Modifier
                    .align(Alignment.TopStart)
                    .padding(16.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f))
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    copy.tag,
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold
                )
            }
        }

        Column(Modifier.padding(20.dp)) {
            Text(
                copy.title,
                color = Ink,
                fontSize = 21.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.4).sp
            )
            Spacer(Modifier.height(6.dp))
            Text(copy.body, color = InkSoft, fontSize = 14.sp, lineHeight = 20.sp)
            Spacer(Modifier.height(18.dp))
            PrimaryButton(copy.action, copy.onClick, destructive = copy.destructive)
        }
    }
}

@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit, destructive: Boolean = false) {
    Row(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .shadow(10.dp, CircleShape, clip = false)
            .clip(CircleShape)
            .background(if (destructive) Red else Ink)
            .clickable(onClick = onClick)
            .padding(horizontal = 22.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            label,
            color = Color.White,
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f)
        )
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(Color.White),
            contentAlignment = Alignment.Center
        ) {
            ArrowGlyph(if (destructive) Red else Ink, 15.dp)
        }
    }
}

@Composable
private fun FeatureRow(
    mirroring: Boolean,
    connected: Boolean,
    controlEnabled: Boolean,
    notifAccess: Boolean,
) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        FeatureCard(
            tint = Blue,
            title = "Screen mirroring",
            detail = if (mirroring) "Streaming now" else "Ready when you are",
            live = mirroring
        ) { PhoneGlyph(Color.White, 20.dp) }
        FeatureCard(
            tint = Green,
            title = "Calls & contacts",
            detail = if (connected) "Synced with your Mac" else "Syncs once connected",
            live = connected
        ) { CallGlyph(Color.White, 20.dp) }
        FeatureCard(
            tint = Purple,
            title = "Control from Mac",
            detail = if (controlEnabled) "Taps and swipes enabled" else "Turn on in Accessibility",
            live = controlEnabled
        ) { TouchGlyph(Color.White, 20.dp) }
        FeatureCard(
            tint = Orange,
            title = "Notifications",
            detail = if (notifAccess) "Mirrored to your Mac" else "Turn on notification access",
            live = notifAccess
        ) { BellGlyph(Color.White, 20.dp) }
    }
}

@Composable
private fun FeatureCard(
    tint: Color,
    title: String,
    detail: String,
    live: Boolean,
    glyph: @Composable () -> Unit
) {
    Row(
        Modifier
            .fillMaxWidth()
            .shadow(10.dp, TileShape, clip = false)
            .clip(TileShape)
            .background(Surface)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(44.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(tint),
            contentAlignment = Alignment.Center
        ) { glyph() }
        Spacer(Modifier.width(13.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Ink, fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, color = InkSoft, fontSize = 12.5.sp)
        }
        if (live) {
            Box(Modifier.size(8.dp).background(Green, CircleShape))
            Spacer(Modifier.width(8.dp))
        }
    }
}

@Composable
private fun EnablePrompt(title: String, subtitle: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(TileShape)
            .background(SurfaceAlt)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, color = Ink, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold)
            Text(subtitle, color = InkSoft, fontSize = 12.sp)
        }
        Box(
            Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(Ink),
            contentAlignment = Alignment.Center
        ) {
            ArrowGlyph(Color.White, 13.dp)
        }
    }
}

/// Floating dark pill of actions — the signature control of the design.
@Composable
private fun NavPill(
    mirroring: Boolean,
    controlEnabled: Boolean,
    onMirror: () -> Unit,
    onControl: () -> Unit,
    onUnlink: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier
            .shadow(20.dp, CircleShape, clip = false)
            .clip(CircleShape)
            .background(Ink)
            .padding(7.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        PillItem("Mirror", active = mirroring, onClick = onMirror) { tint ->
            PhoneGlyph(tint, 18.dp)
        }
        PillItem("Control", active = controlEnabled, onClick = onControl) { tint ->
            TouchGlyph(tint, 18.dp)
        }
        PillItem("Unlink", active = false, onClick = onUnlink) { tint ->
            PowerGlyph(tint, 18.dp)
        }
    }
}

@Composable
private fun PillItem(
    label: String,
    active: Boolean,
    onClick: () -> Unit,
    glyph: @Composable (Color) -> Unit
) {
    val tint = if (active) Ink else Color.White
    Row(
        Modifier
            .clip(CircleShape)
            .background(if (active) Color.White else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        glyph(tint)
        Spacer(Modifier.width(8.dp))
        Text(
            label,
            color = if (active) Ink else Color.White.copy(alpha = 0.86f),
            fontSize = 12.5.sp,
            fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium
        )
    }
}

// MARK: - Glyphs

/// The Tethr mark. Unlike the glyphs below it is real artwork, shared with the
/// launcher icon and the Mac app. `PhoneGlyph` stands for the *phone*; this
/// stands for the app.
///
/// The artwork's own corners are much tighter than the Glide radius, so it is
/// re-clipped to sit in the same visual family as the cards around it.
@Composable
private fun TethrMark(size: Dp, modifier: Modifier = Modifier, corner: Dp = 15.dp) {
    Image(
        painter = painterResource(R.drawable.tethr_logo),
        contentDescription = "Tethr",
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(corner))
    )
}

// The rest are drawn rather than shipped as assets, so the app carries no
// per-density icon set for them.

@Composable
private fun PhoneGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = Stroke(width = w * 0.09f, cap = StrokeCap.Round)
        drawRoundRect(
            color = tint,
            topLeft = Offset(w * 0.24f, h * 0.06f),
            size = Size(w * 0.52f, h * 0.88f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * 0.14f),
            style = stroke
        )
        drawLine(
            color = tint,
            start = Offset(w * 0.42f, h * 0.81f),
            end = Offset(w * 0.58f, h * 0.81f),
            strokeWidth = w * 0.09f,
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun CallGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val path = androidx.compose.ui.graphics.Path().apply {
            moveTo(w * 0.20f, h * 0.16f)
            lineTo(w * 0.36f, h * 0.16f)
            lineTo(w * 0.44f, h * 0.38f)
            lineTo(w * 0.33f, h * 0.47f)
            cubicTo(w * 0.40f, h * 0.62f, w * 0.52f, h * 0.72f, w * 0.64f, h * 0.78f)
            lineTo(w * 0.73f, h * 0.66f)
            lineTo(w * 0.86f, h * 0.75f)
            lineTo(w * 0.86f, h * 0.88f)
            cubicTo(w * 0.55f, h * 0.94f, w * 0.14f, h * 0.55f, w * 0.20f, h * 0.16f)
        }
        drawPath(path, tint, style = Stroke(width = w * 0.10f, cap = StrokeCap.Round))
    }
}

@Composable
private fun BellGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = size.toPx()
        val h = size.toPx()
        val stroke = w * 0.10f
        val path = androidx.compose.ui.graphics.Path().apply {
            moveTo(w * 0.24f, h * 0.66f)
            cubicTo(w * 0.24f, h * 0.30f, w * 0.36f, h * 0.20f, w * 0.50f, h * 0.20f)
            cubicTo(w * 0.64f, h * 0.20f, w * 0.76f, h * 0.30f, w * 0.76f, h * 0.66f)
            close()
        }
        drawPath(path, tint, style = Stroke(width = stroke, cap = StrokeCap.Round))
        drawLine(
            tint, Offset(w * 0.16f, h * 0.68f), Offset(w * 0.84f, h * 0.68f),
            strokeWidth = stroke, cap = StrokeCap.Round
        )
        drawLine(
            tint, Offset(w * 0.43f, h * 0.80f), Offset(w * 0.57f, h * 0.80f),
            strokeWidth = stroke, cap = StrokeCap.Round
        )
    }
}

@Composable
private fun TouchGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        drawCircle(tint, radius = w * 0.30f, style = Stroke(width = w * 0.09f))
        drawCircle(tint, radius = w * 0.11f)
    }
}

@Composable
private fun PowerGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        drawArc(
            color = tint,
            startAngle = -60f,
            sweepAngle = 300f,
            useCenter = false,
            topLeft = Offset(w * 0.16f, h * 0.20f),
            size = Size(w * 0.68f, h * 0.68f),
            style = Stroke(width = w * 0.09f, cap = StrokeCap.Round)
        )
        drawLine(
            color = tint,
            start = Offset(w * 0.5f, h * 0.10f),
            end = Offset(w * 0.5f, h * 0.46f),
            strokeWidth = w * 0.09f,
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun ArrowGlyph(tint: Color, size: Dp) {
    Canvas(Modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = w * 0.11f
        drawLine(tint, Offset(w * 0.18f, h * 0.5f), Offset(w * 0.80f, h * 0.5f), stroke, StrokeCap.Round)
        drawLine(tint, Offset(w * 0.56f, h * 0.26f), Offset(w * 0.82f, h * 0.5f), stroke, StrokeCap.Round)
        drawLine(tint, Offset(w * 0.56f, h * 0.74f), Offset(w * 0.82f, h * 0.5f), stroke, StrokeCap.Round)
    }
}
