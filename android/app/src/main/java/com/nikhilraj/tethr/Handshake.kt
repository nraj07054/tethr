package com.nikhilraj.tethr

import android.util.Base64
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Proof-of-secret handshake shared with the Mac.
 *
 * The pairing secret is transmitted exactly once, when the QR is first scanned.
 * Every connection after that proves knowledge of it instead. That matters
 * because the phone now finds the Mac by discovery: it may dial anything on the
 * network advertising itself as Tethr, so nothing secret can be volunteered
 * before the peer has been verified, and both sides must prove themselves.
 */
object Handshake {
    private val random = SecureRandom()

    /** A fresh 256-bit nonce, base64. */
    fun nonce(): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.NO_WRAP)
    }

    /**
     * HMAC-SHA256 over both nonces, tagged by [role] so the phone's proof can
     * never be replayed back as the Mac's. Both nonces are included so a proof
     * captured from one connection is worthless on the next.
     */
    fun proof(secret: String, role: String, macNonce: String, phoneNonce: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret.toByteArray(), "HmacSHA256"))
        val signed = mac.doFinal("$role:$macNonce:$phoneNonce".toByteArray())
        return Base64.encodeToString(signed, Base64.NO_WRAP)
    }

    /** Compares without leaking where two values diverge. */
    fun constantTimeEquals(a: String, b: String): Boolean {
        val x = a.toByteArray()
        val y = b.toByteArray()
        if (x.size != y.size) return false
        var diff = 0
        for (i in x.indices) diff = diff or (x[i].toInt() xor y[i].toInt())
        return diff == 0
    }
}
