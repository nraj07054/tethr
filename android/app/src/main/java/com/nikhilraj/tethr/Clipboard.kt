package com.nikhilraj.tethr

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build

/**
 * The phone's half of the shared clipboard.
 *
 * Mac -> phone is unrestricted. Phone -> Mac is not: since Android 10 only the
 * focused app and the active input method may read the clipboard, so a
 * background service reads back null however much the clipboard holds. That is
 * a platform rule with no workaround short of being the system keyboard, so the
 * phone pushes what it has whenever it legitimately can — while Tethr is on
 * screen, and on the clip-changed callback that only fires for a foreground app.
 *
 * [lastSeen] closes the loop that would otherwise form: writing what the Mac
 * sent trips the change listener, which would send it straight back.
 */
object Clipboard {

    @Volatile
    private var lastSeen: String? = null

    private fun manager(context: Context): ClipboardManager? =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager

    /** Puts the Mac's clipboard on the phone. */
    fun apply(context: Context, text: String) {
        if (text.isEmpty()) return
        lastSeen = text
        runCatching {
            manager(context)?.setPrimaryClip(ClipData.newPlainText("Tethr", text))
        }
    }

    /** Why a read produced nothing — the three cases need telling apart. */
    enum class Skip { NOTHING, BLOCKED, SENSITIVE, UNCHANGED }

    /**
     * The clipboard's current text, or null when it is empty or the platform
     * won't let us look.
     */
    fun current(context: Context): String? = read(context).first

    /**
     * The clipboard's text and, when there isn't any, the reason. A null clip
     * from a background app is the platform refusing rather than an empty
     * clipboard, and that distinction is the whole story of why phone -> Mac
     * sync behaves the way it does.
     */
    fun read(context: Context): Pair<String?, Skip> {
        val manager = manager(context) ?: return null to Skip.BLOCKED
        val clip = runCatching { manager.primaryClip }.getOrNull()
            ?: return null to (if (manager.hasPrimaryClip()) Skip.BLOCKED else Skip.NOTHING)
        if (isSensitive(clip.description)) return null to Skip.SENSITIVE
        if (clip.itemCount == 0) return null to Skip.NOTHING
        val text = runCatching { clip.getItemAt(0).coerceToText(context)?.toString() }
            .getOrNull()?.takeIf { it.isNotEmpty() } ?: return null to Skip.NOTHING
        if (looksLikeSecret(text)) return null to Skip.SENSITIVE
        return text to Skip.NOTHING
    }

    /**
     * Whether the app that did the copying marked this as not for sharing.
     *
     * Password managers, banking apps and keyboards set this flag on exactly
     * the clips that must not leave the phone, and honouring it is the only
     * reliable signal there is — everything else is guesswork about content.
     */
    private fun isSensitive(description: ClipDescription?): Boolean {
        val extras = description?.extras ?: return false
        val flagged = if (Build.VERSION.SDK_INT >= 33) {
            extras.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE, false)
        } else {
            // The constant is API 33, but the key predates it and OEM keyboards
            // and password managers have been setting it for longer.
            extras.getBoolean("android.content.extra.IS_SENSITIVE", false)
        }
        return flagged
    }

    /**
     * A deliberately narrow guess for secrets the source app failed to flag.
     *
     * Only bare one-time codes: a short run of digits on its own is a verifi-
     * cation code far more often than it is something worth having on the Mac.
     * Anything wider starts eating real copies — a password is not reliably
     * distinguishable from any other short string, so this does not try.
     */
    private fun looksLikeSecret(text: String): Boolean {
        val trimmed = text.trim()
        return trimmed.length in 4..8 && trimmed.all { it.isDigit() }
    }

    /**
     * The clipboard's text if it is something the Mac hasn't seen, else null.
     * Marks it seen, so the same copy is never sent twice.
     */
    fun takeIfNew(context: Context): Pair<String?, Skip> {
        val (text, skip) = read(context)
        if (text == null) return null to skip
        if (text == lastSeen) return null to Skip.UNCHANGED
        lastSeen = text
        return text to Skip.NOTHING
    }

    /** Called when the link drops, so a reconnect resyncs whatever is held. */
    fun forget() {
        lastSeen = null
    }
}
