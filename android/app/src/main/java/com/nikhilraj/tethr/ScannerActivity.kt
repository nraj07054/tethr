package com.nikhilraj.tethr

import android.os.Bundle
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.CaptureManager
import com.journeyapps.barcodescanner.DecoratedBarcodeView

/**
 * QR capture, dressed to match the rest of the app.
 *
 * ZXing's stock screen is a black rectangle with a red laser line. This keeps
 * its decoding and its result contract — so ScanContract in MainActivity is
 * unchanged — while replacing the chrome with a full-bleed preview, a cut-out
 * viewfinder and the app's own type.
 */
class ScannerActivity : ComponentActivity() {
    private lateinit var capture: CaptureManager
    private lateinit var barcodeView: DecoratedBarcodeView
    private var torchOn by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_scanner)

        barcodeView = findViewById(R.id.barcode_view)
        // Drop ZXing's own viewfinder and status line — ours replaces both.
        barcodeView.viewFinder.visibility = View.GONE
        barcodeView.setStatusText("")

        // Start with the lamp definitively off so the button's state and the
        // hardware agree from the first frame.
        barcodeView.setTorchOff()

        capture = CaptureManager(this, barcodeView)
        capture.initializeFromIntent(intent, savedInstanceState)
        capture.decode()

        findViewById<ComposeView>(R.id.overlay).setContent {
            ScannerOverlay(
                torchOn = torchOn,
                onTorch = {
                    torchOn = !torchOn
                    if (torchOn) barcodeView.setTorchOn() else barcodeView.setTorchOff()
                },
                onClose = { finish() },
            )
        }
    }

    override fun onResume() {
        super.onResume()
        capture.onResume()
    }

    override fun onPause() {
        super.onPause()
        capture.onPause()
    }

    override fun onDestroy() {
        super.onDestroy()
        capture.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        capture.onSaveInstanceState(outState)
    }

    @Deprecated("Required by CaptureManager's permission flow")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        @Suppress("DEPRECATION")
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        capture.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}

private val Ink = Color(0xFF101114)
private val CutOut = 268.dp

@Composable
private fun ScannerOverlay(torchOn: Boolean, onTorch: () -> Unit, onClose: () -> Unit) {
    // The cut-out's position is measured rather than assumed, so the hole in
    // the scrim lines up with the frame on any screen size.
    var hole by remember { mutableStateOf(Rect.Zero) }
    val radius = with(LocalDensity.current) { 30.dp.toPx() }

    Box(Modifier.fillMaxSize()) {
        Canvas(
            Modifier
                .fillMaxSize()
                // BlendMode.Clear only punches through within its own layer.
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
        ) {
            drawRect(Color.Black.copy(alpha = 0.62f))
            if (!hole.isEmpty) {
                drawRoundRect(
                    color = Color.Transparent,
                    topLeft = hole.topLeft,
                    size = hole.size,
                    cornerRadius = CornerRadius(radius),
                    blendMode = BlendMode.Clear,
                )
            }
        }

        Column(
            Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.systemBars)
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RoundButton(onClick = onClose, filled = false) { tint -> CloseGlyph(tint) }
                Spacer(Modifier.weight(1f))
                RoundButton(onClick = onTorch, filled = torchOn) { tint -> TorchGlyph(tint) }
            }

            Spacer(Modifier.weight(1f))

            Box(
                Modifier
                    .size(CutOut)
                    .onGloballyPositioned { hole = it.boundsInRoot() },
            ) {
                Frame()
            }

            Spacer(Modifier.height(34.dp))
            Text(
                "Scan the code on your Mac",
                color = Color.White,
                fontSize = 22.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = (-0.4).sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                "Open Tethr on your Mac and point your camera at the QR code it shows.",
                color = Color.White.copy(alpha = 0.72f),
                fontSize = 14.sp,
                lineHeight = 20.sp,
                textAlign = TextAlign.Center,
            )

            Spacer(Modifier.weight(1f))

            Text(
                "Both devices on the same Wi-Fi — or on your hotspot",
                color = Color.White.copy(alpha = 0.86f),
                fontSize = 12.5.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.14f))
                    .padding(horizontal = 16.dp, vertical = 11.dp),
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** Corner brackets plus a sweeping scan line, inside the cut-out. */
@Composable
private fun Frame() {
    val sweep by rememberInfiniteTransition(label = "sweep").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2200, easing = LinearEasing), RepeatMode.Reverse),
        label = "sweep",
    )

    Canvas(Modifier.fillMaxSize()) {
        val w = size.width
        val h = size.height
        val stroke = 4.dp.toPx()
        val arm = 38.dp.toPx()
        // Start the arms past the corner radius so they sit on straight edges.
        val pad = stroke / 2f + 30.dp.toPx() * 0.45f

        fun bracket(x: Float, y: Float, dx: Float, dy: Float) {
            drawLine(
                Color.White, Offset(x, y), Offset(x + dx * arm, y),
                strokeWidth = stroke, cap = StrokeCap.Round,
            )
            drawLine(
                Color.White, Offset(x, y), Offset(x, y + dy * arm),
                strokeWidth = stroke, cap = StrokeCap.Round,
            )
        }
        bracket(pad, pad, 1f, 1f)
        bracket(w - pad, pad, -1f, 1f)
        bracket(pad, h - pad, 1f, -1f)
        bracket(w - pad, h - pad, -1f, -1f)

        val y = arm + (h - 2 * arm) * sweep
        drawLine(
            brush = Brush.horizontalGradient(
                listOf(Color.Transparent, Color.White.copy(alpha = 0.85f), Color.Transparent)
            ),
            start = Offset(arm * 0.5f, y),
            end = Offset(w - arm * 0.5f, y),
            strokeWidth = 2.dp.toPx(),
            cap = StrokeCap.Round,
        )
    }
}

@Composable
private fun RoundButton(onClick: () -> Unit, filled: Boolean, glyph: @Composable (Color) -> Unit) {
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (filled) Color.White else Color.White.copy(alpha = 0.18f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        glyph(if (filled) Ink else Color.White)
    }
}

@Composable
private fun CloseGlyph(tint: Color) {
    Canvas(Modifier.size(16.dp)) {
        val s = size.width
        val w = 2.2f.dp.toPx()
        drawLine(tint, Offset(0f, 0f), Offset(s, s), w, StrokeCap.Round)
        drawLine(tint, Offset(s, 0f), Offset(0f, s), w, StrokeCap.Round)
    }
}

@Composable
private fun TorchGlyph(tint: Color) {
    Canvas(Modifier.size(18.dp)) {
        val w = size.width
        val h = size.height
        val stroke = w * 0.11f
        drawCircle(tint, radius = w * 0.22f, center = Offset(w / 2, h * 0.45f))
        for (i in 0 until 8) {
            val a = Math.toRadians(i * 45.0)
            val cos = kotlin.math.cos(a).toFloat()
            val sin = kotlin.math.sin(a).toFloat()
            drawLine(
                tint,
                Offset(w / 2 + w * 0.34f * cos, h * 0.45f + w * 0.34f * sin),
                Offset(w / 2 + w * 0.46f * cos, h * 0.45f + w * 0.46f * sin),
                stroke, StrokeCap.Round,
            )
        }
    }
}
