package com.nikhilraj.dogen

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
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import android.app.Activity
import android.media.projection.MediaProjectionManager
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

class MainActivity : ComponentActivity() {
    private val phonePermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Ask for contacts / call log / calling up front so sync works once linked.
        requestPhonePermissions()
        // Reconnect automatically when the app opens and a Mac is already linked.
        if (PairStore.load(this) != null) ConnectionService.start(this)
        setContent { DogenScreen() }
    }

    private fun requestPhonePermissions() {
        val wanted = listOf(
            Manifest.permission.READ_CONTACTS,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.ANSWER_PHONE_CALLS,
        ).filter {
            checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        if (wanted.isNotEmpty()) phonePermissions.launch(wanted.toTypedArray())
    }
}

private val Bg = Color(0xFF0E0F13)     // flat mono background
private val Green = Color(0xFF34C759)
private val Orange = Color(0xFFFF9F0A)
private val Red = Color(0xFFFF453A)
private val Ink = Color(0xFF0A0A0C)

@Composable
fun DogenScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val status by LinkState.status.collectAsState()
    val mirroring by LinkState.mirroring.collectAsState()
    var linked by remember { mutableStateOf(PairStore.load(context) != null) }

    // Track whether the "control from Mac" accessibility service is enabled,
    // refreshing when the user returns from Settings.
    var controlEnabled by remember { mutableStateOf(DogenGestureService.isEnabled(context)) }
    DisposableEffect(Unit) {
        val owner = context as? androidx.lifecycle.LifecycleOwner
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            if (e == androidx.lifecycle.Lifecycle.Event.ON_RESUME) {
                controlEnabled = DogenGestureService.isEnabled(context)
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

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        val pairing = result.contents?.let(PairStore::fromQR) ?: return@rememberLauncherForActivityResult
        PairStore.save(context, pairing)
        linked = true
        ConnectionService.start(context)
    }

    fun scan() {
        if (Build.VERSION.SDK_INT >= 33) {
            notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        scanner.launch(ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            setPrompt("Scan the QR code shown in Dogen on your Mac")
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

    val connected = status is LinkState.Status.Connected
    val rejected = status is LinkState.Status.Rejected

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Bg),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Hero glyph
            Box(
                modifier = Modifier
                    .size(88.dp)
                    .shadow(20.dp, RoundedCornerShape(26.dp), clip = false)
                    .clip(RoundedCornerShape(26.dp))
                    .background(
                        Brush.linearGradient(
                            listOf(Color.White.copy(alpha = 0.3f), Color.White.copy(alpha = 0.12f))
                        )
                    )
                    .border(1.dp, Color.White.copy(alpha = 0.4f), RoundedCornerShape(26.dp)),
                contentAlignment = Alignment.Center
            ) {
                Text("📱", fontSize = 40.sp)
            }

            Spacer(Modifier.height(22.dp))
            Text("Dogen", color = Color.White, fontSize = 36.sp, fontWeight = FontWeight.Bold)
            Text(
                "Your phone, on your Mac",
                color = Color.White.copy(alpha = 0.82f),
                fontSize = 15.sp
            )

            Spacer(Modifier.height(22.dp))
            StatusPill(status, linked)

            Spacer(Modifier.height(26.dp))
            GlassCard {
                when {
                    rejected -> {
                        CardText(
                            "Pairing failed",
                            "The code didn't match. Scan the QR code shown in Dogen on your Mac again."
                        )
                        Spacer(Modifier.height(20.dp))
                        PrimaryButton("Scan Again", onClick = ::scan)
                    }
                    !linked -> {
                        CardText(
                            "Link your Mac",
                            "Open Dogen on your Mac and scan the QR code to connect over Wi-Fi."
                        )
                        Spacer(Modifier.height(20.dp))
                        PrimaryButton("Scan QR Code", onClick = ::scan)
                    }
                    connected -> {
                        CardText(
                            if (mirroring) "Mirroring your screen" else "Ready to mirror",
                            if (mirroring) "Your screen is streaming to your Mac in real time."
                            else "Stream your phone's screen to your Mac in real time."
                        )
                        Spacer(Modifier.height(20.dp))
                        PrimaryButton(
                            if (mirroring) "Stop Mirroring" else "Mirror Screen",
                            onClick = ::toggleMirror,
                            accent = if (mirroring) Red else null
                        )
                    }
                    else -> CardText(
                        "Connecting…",
                        "Keep Dogen open — the link keeps running in the background."
                    )
                }
            }

            Spacer(Modifier.height(24.dp))
            FeatureRow()

            if (linked && !controlEnabled) {
                Spacer(Modifier.height(14.dp))
                TextButton(onClick = { DogenGestureService.openSettings(context) }) {
                    Text(
                        "Enable control from Mac  →",
                        color = Color.White.copy(alpha = 0.92f),
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            if (linked) {
                Spacer(Modifier.height(2.dp))
                TextButton(onClick = {
                    ConnectionService.stop(context)
                    PairStore.clear(context)
                    linked = false
                    LinkState.status.value = LinkState.Status.Idle
                }) {
                    Text("Unlink Mac", color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp)
                }
            }
        }
    }
}

@Composable
private fun GlassCard(content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .background(Color.White.copy(alpha = 0.15f))
            .border(1.dp, Color.White.copy(alpha = 0.25f), RoundedCornerShape(28.dp))
            .padding(horizontal = 24.dp, vertical = 26.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        content = content
    )
}

@Composable
private fun ColumnScope.CardText(title: String, body: String) {
    Text(
        title,
        color = Color.White,
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
        textAlign = TextAlign.Center
    )
    Spacer(Modifier.height(7.dp))
    Text(
        body,
        color = Color.White.copy(alpha = 0.74f),
        fontSize = 14.sp,
        lineHeight = 20.sp,
        textAlign = TextAlign.Center
    )
}

@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit, accent: Color? = null) {
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.White,
            contentColor = accent ?: Ink
        ),
        shape = RoundedCornerShape(50),
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp)
    ) {
        Text(label, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
    }
}

@Composable
private fun FeatureRow() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        FeatureChip("🖥️", "Mirror", Modifier.weight(1f))
        FeatureChip("📞", "Calls", Modifier.weight(1f))
        FeatureChip("👤", "Contacts", Modifier.weight(1f))
    }
}

@Composable
private fun FeatureChip(emoji: String, label: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .background(Color.White.copy(alpha = 0.1f))
            .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(18.dp))
            .padding(vertical = 15.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(emoji, fontSize = 22.sp)
        Spacer(Modifier.height(6.dp))
        Text(label, color = Color.White.copy(alpha = 0.9f), fontSize = 12.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun StatusPill(status: LinkState.Status, linked: Boolean) {
    val pulse by rememberInfiniteTransition(label = "pulse").animateFloat(
        initialValue = 1f,
        targetValue = 0.3f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
        label = "pulse"
    )

    val (color, text, animate) = when {
        status is LinkState.Status.Connected ->
            Triple(Green, "Connected to ${status.macName}", false)
        status is LinkState.Status.Rejected ->
            Triple(Red, "Pairing failed", false)
        linked -> Triple(Orange, "Connecting…", true)
        else -> Triple(Color.White, "Not linked yet", false)
    }

    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Color.White.copy(alpha = 0.14f))
            .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(50))
            .padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(8.dp)
                .alpha(if (animate) pulse else 1f)
                .background(color, CircleShape)
        )
        Spacer(Modifier.width(8.dp))
        Text(text, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}
