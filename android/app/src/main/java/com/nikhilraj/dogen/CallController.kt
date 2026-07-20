package com.nikhilraj.dogen

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.telecom.TelecomManager

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
 *   is "idle" | "ringing" | "offhook". The number is only available on API < 31
 *   (the platform stopped delivering it to third-party listeners on newer OSes).
 */
class CallController(
    private val context: Context,
    private val onState: (String, String?) -> Unit
) {
    private val telecom = context.getSystemService(Context.TELECOM_SERVICE) as TelecomManager
    private val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var callback: Any? = null

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
        when (val cb = callback) {
            is TelephonyCallback -> if (Build.VERSION.SDK_INT >= 31) telephony.unregisterTelephonyCallback(cb)
            is PhoneStateListener -> @Suppress("DEPRECATION") telephony.listen(cb, PhoneStateListener.LISTEN_NONE)
        }
        callback = null
    }

    private fun report(state: Int, number: String?) {
        val s = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
            else -> "idle"
        }
        onState(s, number)
    }

    /** Places a call on the phone. Requires CALL_PHONE. */
    fun dial(number: String) {
        if (!PhoneData.hasPermission(context, android.Manifest.permission.CALL_PHONE)) return
        val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:${Uri.encode(number)}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
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
