package com.nikhilraj.tethr

/**
 * Which caller belongs to which call.
 *
 * Android reports one telephony state for the whole phone — "ringing" means
 * *something* is ringing, whether or not another call is already connected —
 * and the number arrives on a separate broadcast. Filing that number correctly
 * is the whole job here, and it used to be done with a single "last number"
 * field: call waiting overwrote the connected caller with the new one and never
 * put it back, so once the interruption was declined every report about the
 * call still in progress named the person who had just been rejected.
 *
 * Separate from [CallController] so it can be tested without a device.
 */
internal class CallNumbers {
    private var active: String? = null
    private var ringing: String? = null
    private var last = IDLE

    /** Files [number] against the call it belongs to, and returns who to report. */
    fun report(state: String, number: String?): String? {
        val previous = last
        last = state
        return when (state) {
            RINGING -> {
                // Whoever is ringing, kept apart from whoever is already on the
                // line. Nothing here touches the connected call.
                if (!number.isNullOrBlank()) ringing = number
                ringing ?: active
            }
            OFFHOOK -> {
                // Ringing to offhook with nothing connected is the ringing call
                // being picked up: it becomes the call on the line.
                if (previous == RINGING && active == null) active = ringing
                // Only ever fills a blank. An offhook broadcast can still carry
                // the incoming number on some devices, and adopting that would
                // reintroduce the overwrite this exists to prevent.
                if (active == null && !number.isNullOrBlank()) active = number
                // Coming back to offhook while a call was already connected is
                // ambiguous: one state for the whole phone means declining the
                // interruption and answering it (which puts the first call on
                // hold) look identical from here. Declining is the common case,
                // and the one that was broken, so the established call keeps the
                // line. A Mac that issued the answer itself knows better.
                ringing = null
                active
            }
            else -> {
                active = null
                ringing = null
                null
            }
        }
    }

    /** Who to name for [state], without advancing anything. */
    fun forState(state: String): String? = when (state) {
        RINGING -> ringing ?: active
        OFFHOOK -> active
        else -> null
    }

    companion object {
        const val IDLE = "idle"
        const val RINGING = "ringing"
        const val OFFHOOK = "offhook"
    }
}
