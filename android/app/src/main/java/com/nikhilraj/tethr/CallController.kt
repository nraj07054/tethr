package com.nikhilraj.tethr

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat

/**
 * Dialing and call control from the Mac.
 *
 * What works for a third-party app: place a call (ACTION_CALL), observe call
 * state (idle/ringing/offhook), and accept / end the current call via
 * TelecomManager. What is NOT possible without being a system/OEM app: capturing
 * the live call *audio* stream — Android blocks VOICE_CALL capture for non-system
 * apps, so call audio can only reach the Mac over Bluetooth Hands-Free Profile,
 * never over this socket.
 *
 * @param onState called on every call-state change: (state, number?) where state
 *   is "idle" | "ringing" | "offhook".
 */
class CallController(
    private val context: Context,
    private val onState: (String, String?) -> Unit
) {
    private val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
    private val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var callback: Any? = null
    // The last state reported, so a number arriving separately can be paired
    // with the state it belongs to.
    private var lastState = TelephonyManager.CALL_STATE_IDLE
    private var lastNumber: String? = null

    /**
     * The caller's number, which the telephony callback no longer carries.
     *
     * Since API 31 TelephonyCallback.CallStateListener reports the state and
     * nothing else — the platform stopped handing third-party listeners the
     * number, so on any current Android the Mac was being told a call had
     * started but never who from. The legacy PHONE_STATE broadcast still
     * carries it, and still delivers it unredacted to an app holding
     * READ_CALL_LOG, which is the one path left to identify a caller.
     */
    private val phoneStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                ?.takeIf { it.isNotBlank() }
            // The broadcast carries the state as well, and has to be trusted for
            // it: it frequently beats the telephony callback, and reporting it
            // against a stale state would file a ringing phone's number under
            // "idle" — which then throws that very number away.
            val state = when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                TelephonyManager.EXTRA_STATE_RINGING -> TelephonyManager.CALL_STATE_RINGING
                TelephonyManager.EXTRA_STATE_OFFHOOK -> TelephonyManager.CALL_STATE_OFFHOOK
                TelephonyManager.EXTRA_STATE_IDLE -> TelephonyManager.CALL_STATE_IDLE
                else -> return
            }
            // The callback reports the same transitions, so only speak up when
            // this carries something it didn't: a number, or a state change.
            if (number == null && state == lastState) return
            report(state, number)
        }
    }

    // MARK: In-call audio (mute mic / speakerphone) — the parts a third-party
    // app CAN control, via AudioManager. (Live call audio itself cannot.)

    val isMuted: Boolean get() = audio.isMicrophoneMute

    val isSpeakerOn: Boolean
        get() = if (Build.VERSION.SDK_INT >= 31)
            audio.communicationDevice?.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        else @Suppress("DEPRECATION") audio.isSpeakerphoneOn

    fun setMute(on: Boolean) {
        runCatching { audio.isMicrophoneMute = on }
    }

    fun setSpeaker(on: Boolean) {
        runCatching {
            if (Build.VERSION.SDK_INT >= 31) {
                if (on) {
                    audio.availableCommunicationDevices
                        .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                        ?.let { audio.setCommunicationDevice(it) }
                } else {
                    audio.clearCommunicationDevice()
                }
            } else {
                @Suppress("DEPRECATION") audio.isSpeakerphoneOn = on
            }
        }
    }

    fun start() {
        if (!PhoneData.hasPermission(context, android.Manifest.permission.READ_PHONE_STATE)) return
        // A system protected broadcast, so it has to be registered as exported.
        runCatching {
            ContextCompat.registerReceiver(
                context,
                phoneStateReceiver,
                IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED),
                ContextCompat.RECEIVER_EXPORTED
            )
        }
        if (Build.VERSION.SDK_INT >= 31) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = report(state, null)
            }
            callback = cb
            telephony.registerTelephonyCallback(context.mainExecutor, cb)
        } else {
            @Suppress("DEPRECATION")
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) =
                    report(state, phoneNumber?.takeIf { it.isNotBlank() })
            }
            callback = listener
            @Suppress("DEPRECATION")
            telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
        }
    }

    fun stop() {
        runCatching { context.unregisterReceiver(phoneStateReceiver) }
        when (val cb = callback) {
            is TelephonyCallback -> if (Build.VERSION.SDK_INT >= 31) telephony.unregisterTelephonyCallback(cb)
            is PhoneStateListener -> @Suppress("DEPRECATION") telephony.listen(cb, PhoneStateListener.LISTEN_NONE)
        }
        callback = null
    }

    private fun report(state: Int, number: String?) {
        lastState = state
        val s = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
            else -> "idle"
        }
        // A call ending retires its number; anything else keeps the one we have,
        // so answering a call doesn't blank out who is on the line.
        if (s == "idle") lastNumber = null else if (!number.isNullOrBlank()) lastNumber = number
        onState(s, lastNumber)
    }

    /**
     * Places a call on the phone. Requires CALL_PHONE.
     *
     * Telecom places the call rather than an ACTION_CALL activity, because this
     * runs from a background service: since Android 10 an app that is not in
     * the foreground cannot start an activity at all, so dialling from the Mac
     * silently did nothing whenever the phone's own app happened to be closed —
     * the platform swallowed it as a background activity start. Handing the
     * number to Telecom makes the *system* place the call and bring up the
     * dialler, which is not something the app is being asked to do from the
     * background.
     */
    @SuppressLint("MissingPermission")
    fun dial(number: String) {
        if (!PhoneData.hasPermission(context, android.Manifest.permission.CALL_PHONE)) return
        val placed = runCatching {
            telecom.placeCall(Uri.fromParts("tel", number, null), Bundle())
        }.isSuccess
        if (placed) return
        // Older or vendor-restricted devices: the activity still works whenever
        // the app does happen to be in the foreground, which is where this
        // always worked before.
        runCatching {
            context.startActivity(
                Intent(Intent.ACTION_CALL, Uri.parse("tel:${Uri.encode(number)}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    /** Answers the currently ringing call. Requires ANSWER_PHONE_CALLS (API 26+). */
    @SuppressLint("MissingPermission")
    fun answer() {
        if (Build.VERSION.SDK_INT >= 26 &&
            PhoneData.hasPermission(context, android.Manifest.permission.ANSWER_PHONE_CALLS)
        ) runCatching { telecom.acceptRingingCall() }
    }

    /** Rejects a ringing call or hangs up the active one. Requires ANSWER_PHONE_CALLS (API 28+). */
    @SuppressLint("MissingPermission")
    fun hangup() {
        if (Build.VERSION.SDK_INT >= 28 &&
            PhoneData.hasPermission(context, android.Manifest.permission.ANSWER_PHONE_CALLS)
        ) runCatching { telecom.endCall() }
    }
}
