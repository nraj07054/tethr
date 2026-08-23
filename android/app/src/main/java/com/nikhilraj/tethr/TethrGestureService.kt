package com.nikhilraj.tethr

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.provider.Settings
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * Lets the Mac drive the phone. An AccessibilityService is the only no-root way
 * a third-party app can inject taps/swipes into other apps. The user enables it
 * once in Settings; after that the Mac's clicks on the mirror window become real
 * gestures here. Coordinates arrive normalized (0…1) and are scaled to the
 * display, so they map correctly whatever the phone's resolution.
 */
class TethrGestureService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    private fun displaySize(): Pair<Int, Int> {
        val wm = getSystemService(WindowManager::class.java)
        val b = wm.currentWindowMetrics.bounds
        return b.width() to b.height()
    }

    fun tap(fx: Double, fy: Double) {
        val (w, h) = displaySize()
        val path = Path().apply { moveTo((fx * w).toFloat(), (fy * h).toFloat()) }
        dispatchGesture(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, 60))
                .build(),
            null, null
        )
    }

    fun swipe(fx1: Double, fy1: Double, fx2: Double, fy2: Double, ms: Long) {
        val (w, h) = displaySize()
        val path = Path().apply {
            moveTo((fx1 * w).toFloat(), (fy1 * h).toFloat())
            lineTo((fx2 * w).toFloat(), (fy2 * h).toFloat())
        }
        dispatchGesture(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, ms.coerceIn(20, 2000)))
                .build(),
            null, null
        )
    }

    fun global(key: String) {
        val action = when (key) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            else -> return
        }
        performGlobalAction(action)
    }

    companion object {
        @Volatile
        var instance: TethrGestureService? = null

        /** True once the user has enabled Tethr's control service in Settings. */
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            val id = "${context.packageName}/${TethrGestureService::class.java.name}"
            return flat.split(':').any { it.equals(id, ignoreCase = true) }
        }

        fun openSettings(context: Context) {
            context.startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}
