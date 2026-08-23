package com.nikhilraj.tethr

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import androidx.core.graphics.drawable.toBitmap
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Collections
import java.util.concurrent.Executors

/**
 * Mirrors this phone's notifications to the Mac, and carries actions back.
 *
 * A NotificationListenerService is the only way a third-party app can read
 * other apps' notifications; the user grants it once in Settings. Replying uses
 * the notification's own RemoteInput action, which is what makes "reply from
 * the Mac" work for any messaging app rather than just SMS.
 */
class TethrNotificationService : NotificationListenerService() {

    // Packages whose icon the Mac already holds, so each is encoded and sent
    // once per link rather than on every notification from that app.
    private val sentIcons = Collections.synchronizedSet(HashSet<String>())
    // Decoding an adaptive icon and encoding a PNG is far too slow for the main
    // thread, and one worker keeps a busy shade from spawning a thread per app.
    private val iconWorker = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        iconWorker.shutdownNow()
        super.onDestroy()
    }

    override fun onListenerConnected() {
        instance = this
        // The Mac may have been waiting: send everything already on the shade.
        pushAll()
    }

    override fun onListenerDisconnected() {
        instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val json = describe(sbn) ?: return
        ConnectionService.instance?.sendJson(json)
        pushIcon(sbn.packageName)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        ConnectionService.instance?.sendJson(
            JSONObject().put("type", "notificationRemoved").put("key", sbn.key)
        )
    }

    /**
     * Replaces the Mac's list with everything currently posted. Called whenever
     * a link comes up, so the icon cache resets too: a Mac that has just
     * connected — or just relaunched — is holding no icons.
     */
    fun pushAll() {
        val items = JSONArray()
        val current = runCatching { activeNotifications }.getOrNull() ?: return
        sentIcons.clear()
        for (sbn in current) describe(sbn)?.let { items.put(it) }
        android.util.Log.i("TethrData", "notifications sent: ${items.length()}")
        ConnectionService.instance?.sendJson(
            JSONObject().put("type", "notifications").put("items", items)
        )
        for (sbn in current) pushIcon(sbn.packageName)
    }

    /**
     * Sends an app's launcher icon to the Mac, once per package per link. A
     * notification carries only a monochrome status-bar glyph, so the icon a
     * person would recognise has to be read from PackageManager and encoded here.
     */
    private fun pushIcon(pkg: String) {
        if (pkg == packageName) return
        if (!sentIcons.add(pkg)) return
        runCatching {
            iconWorker.execute {
                val png = iconPng(pkg)
                if (png == null) {
                    // Let a later notification retry — the icon may be readable
                    // once the user grants us visibility of that package.
                    android.util.Log.i("TethrData", "no icon for $pkg")
                    sentIcons.remove(pkg)
                    return@execute
                }
                ConnectionService.instance?.sendJson(
                    JSONObject().put("type", "appIcon").put("pkg", pkg).put("png", png)
                )
            }
        }
    }

    /** The app's icon as a base64 PNG, or null when the package isn't visible. */
    private fun iconPng(pkg: String): String? = runCatching {
        val bitmap = packageManager.getApplicationIcon(pkg).toBitmap(ICON_PX, ICON_PX)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }.getOrNull()

    fun dismiss(key: String) {
        runCatching { cancelNotification(key) }
    }

    /**
     * Sends [text] through the notification's own reply action. Looked up live
     * rather than cached, so a stale key can't fire someone else's intent.
     */
    fun reply(key: String, text: String) {
        val sbn = runCatching { activeNotifications }.getOrNull()
            ?.firstOrNull { it.key == key } ?: return
        val action = sbn.notification.actions?.firstOrNull { !it.remoteInputs.isNullOrEmpty() } ?: return
        val inputs = action.remoteInputs ?: return

        val intent = Intent()
        val results = Bundle()
        for (input in inputs) results.putCharSequence(input.resultKey, text)
        RemoteInput.addResultsToIntent(inputs, intent, results)
        // Some apps only accept the reply when told the input came from free-form text.
        runCatching { RemoteInput.setResultsSource(intent, RemoteInput.SOURCE_FREE_FORM_INPUT) }
        runCatching { action.actionIntent.send(this, 0, intent) }
    }

    /** Flattens a notification, or null if it isn't worth showing on the Mac. */
    private fun describe(sbn: StatusBarNotification): JSONObject? {
        // Never mirror our own foreground-service notification: the Mac would
        // show Tethr telling it about Tethr, and dismissing it kills the link.
        if (sbn.packageName == packageName) return null

        val n = sbn.notification
        val flags = n.flags
        // Ongoing (music, downloads, foreground services) and group summaries
        // are chrome, not messages.
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return null
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return null

        val extras = n.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (title.isBlank() && text.isBlank()) return null

        val canReply = n.actions?.any { !it.remoteInputs.isNullOrEmpty() } == true
        // An app can post under a different name than its own (Gmail posting as
        // an account, say); that substitution is what the phone's shade shows.
        // The extra's constant is hidden API, but the key is stable and is what
        // the platform's own shade reads.
        val substitute = extras.getCharSequence("android.substName")
            ?.toString()?.takeIf { it.isNotBlank() }

        return JSONObject()
            .put("type", "notification")
            .put("key", sbn.key)
            .put("pkg", sbn.packageName)
            .put("app", substitute ?: appLabel(sbn.packageName))
            .put("title", title)
            .put("text", text)
            .put("when", if (sbn.postTime > 0) sbn.postTime else System.currentTimeMillis())
            .put("canReply", canReply)
    }

    private fun appLabel(pkg: String): String = runCatching {
        val pm = packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
    }.getOrNull()?.takeIf { it.isNotBlank() && it != pkg } ?: prettyPackage(pkg)

    /**
     * Last resort for a package that stays invisible to us — a system component
     * with no launcher entry. "com.android.settings" reads as "Settings", which
     * is a far better thing to put on the Mac than the raw package name.
     */
    private fun prettyPackage(pkg: String): String {
        val part = pkg.split('.').lastOrNull { it.isNotBlank() } ?: return pkg
        return part.replaceFirstChar { it.uppercase() }
    }

    companion object {
        @Volatile
        var instance: TethrNotificationService? = null

        // Big enough to stay crisp on a Retina display at the 42pt the Mac
        // draws these at, small enough that a shade full of apps is a few
        // hundred KB over the socket, once.
        private const val ICON_PX = 96

        /** True once the user has granted Tethr notification access in Settings. */
        fun isEnabled(context: Context): Boolean {
            val flat = Settings.Secure.getString(
                context.contentResolver, "enabled_notification_listeners"
            ) ?: return false
            val pkg = context.packageName
            return flat.split(':').any { it.contains(pkg) }
        }

        fun openSettings(context: Context) {
            context.startActivity(
                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
}
