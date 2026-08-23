package com.nikhilraj.tethr

import android.content.Context
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.View
import android.view.WindowManager

/**
 * Reads the clipboard from the background, which Android otherwise forbids.
 *
 * Since Android 10 the clipboard is readable only by the focused app and the
 * active keyboard: a background service gets back an *empty* clipboard rather
 * than an error, and the clip-changed listener never fires at all. The appop is
 * already "allow" — the gate is a window-focus check inside ClipboardService,
 * so the only way through is to genuinely hold focus.
 *
 * So we do, for about as long as it takes to read: a 1x1 transparent overlay
 * window, focusable, added and removed around a single read. This needs the
 * "display over other apps" permission and it does take focus from whatever is
 * in front, which is why it runs on demand — when the Mac actually wants to
 * paste — rather than on a poll. Most of the time the phone's screen is off and
 * nothing is disturbed at all.
 */
object ClipboardReader {

    /** Whether the overlay route is available; false until the user grants it. */
    fun canReadInBackground(context: Context): Boolean = Settings.canDrawOverlays(context)

    /** Opens the system screen for granting "display over other apps". */
    fun requestPermission(context: Context) {
        val intent = android.content.Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            android.net.Uri.parse("package:${context.packageName}")
        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    /**
     * Reads the clipboard behind a momentary focus overlay. [onResult] is always
     * called exactly once, on the main thread.
     */
    fun read(context: Context, onResult: (String?, Clipboard.Skip) -> Unit) {
        if (!canReadInBackground(context)) {
            android.util.Log.i("TethrClip", "overlay: no permission")
            onResult(null, Clipboard.Skip.BLOCKED)
            return
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
        if (wm == null) {
            onResult(null, Clipboard.Skip.BLOCKED)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        var finished = false
        var probe: View? = null

        // One exit for every path — a focus overlay left behind would sit on
        // top of the phone swallowing focus for good.
        fun finish(text: String?, skip: Clipboard.Skip) {
            if (finished) return
            finished = true
            handler.removeCallbacksAndMessages(null)
            probe?.let { runCatching { wm.removeView(it) } }
            onResult(text, skip)
        }

        val view = object : View(context) {
            override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
                super.onWindowFocusChanged(hasWindowFocus)
                // Reading the moment focus lands keeps the window up for the
                // shortest time the platform allows.
                if (hasWindowFocus) {
                    val (text, skip) = Clipboard.takeIfNew(context)
                    finish(text, skip)
                }
            }
        }
        // A window is only given input focus if something inside it can hold
        // focus, so the probe asks for it explicitly.
        view.isFocusable = true
        view.isFocusableInTouchMode = true
        probe = view

        val params = WindowManager.LayoutParams(
            1, 1, 0, 0,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // Deliberately NOT FLAG_NOT_FOCUSABLE: focus is the entire point.
            // NOT_TOUCH_MODAL keeps taps flowing to whatever is underneath.
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        ).apply {
            // Not fully transparent: a zero-alpha window is a candidate for
            // being skipped entirely, and this is small enough to be invisible.
            alpha = 0.01f
            gravity = android.view.Gravity.TOP or android.view.Gravity.START
        }

        val added = runCatching { wm.addView(view, params); view.requestFocus() }
            .onFailure { android.util.Log.w("TethrClip", "overlay: addView failed: ${it.message}") }
            .isSuccess
        if (!added) {
            finish(null, Clipboard.Skip.BLOCKED)
            return
        }
        // If focus never arrives — screen off, a secure window in front — give
        // up quickly rather than holding the overlay open.
        handler.postDelayed({
            android.util.Log.i("TethrClip", "overlay: focus never arrived")
            finish(null, Clipboard.Skip.BLOCKED)
        }, FOCUS_TIMEOUT_MS)
    }

    // Generous: the window manager can take a beat to hand focus over, and a
    // read that arrives late still beats no read at all.
    private const val FOCUS_TIMEOUT_MS = 1_500L
}
