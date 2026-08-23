package com.nikhilraj.tethr

import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypts everything that crosses the link once the handshake has finished.
 *
 * The handshake authenticates the peer but used to leave the rest of the
 * session in the clear: contacts, call history, notification text, clipboard
 * contents and the screen itself all travelled as plaintext over the LAN, so
 * anyone on the same Wi-Fi could read the lot passively. This closes that.
 *
 * Keys come from the pairing secret both sides already share, so no new trust
 * is needed — but they are derived per connection, over both handshake nonces,
 * so a recording of one session cannot be decrypted with keys from another. The
 * two directions get separate keys, which is what makes it safe for both ends
 * to number their frames from zero without ever colliding on a nonce.
 */
class SessionCrypto(secret: String, macNonce: String, phoneNonce: String) {

    /** Phone -> Mac. */
    private val sendKey: SecretKeySpec
    /** Mac -> phone. */
    private val receiveKey: SecretKeySpec

    private var sendCounter = 0L
    /** Highest counter accepted so far; anything at or below it is a replay. */
    private var lastReceived = -1L

    init {
        // Both nonces, so the keys are bound to this specific handshake.
        val salt = (macNonce + phoneNonce).toByteArray()
        val ikm = secret.toByteArray()
        sendKey = SecretKeySpec(hkdf(ikm, salt, INFO_PHONE_TO_MAC), "AES")
        receiveKey = SecretKeySpec(hkdf(ikm, salt, INFO_MAC_TO_PHONE), "AES")
    }

    /**
     * Wraps [payload] into a self-describing encrypted frame.
     *
     * Synchronized because counters are nonces here. Contacts and the call log
     * are sealed on a worker thread while the heartbeat seals on the main one,
     * and two threads reading the same counter would reuse a GCM nonce under one
     * key — which loses confidentiality outright and lets frames be forged.
     * Callers must also *send* under the same lock, or the frames arrive out of
     * order and the far end drops the older one as a replay.
     */
    @Synchronized
    fun seal(kind: Byte, payload: ByteArray): ByteArray {
        val header = header(kind, sendCounter++)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, sendKey, GCMParameterSpec(TAG_BITS, header.copyOfRange(2, 14)))
        // The header travels in the clear but is authenticated, so the version,
        // the kind and the counter cannot be tampered with in flight.
        cipher.updateAAD(header)
        return header + cipher.doFinal(payload)
    }

    /** Unwraps a frame, or null if it is malformed, forged, or a replay. */
    @Synchronized
    fun open(frame: ByteArray): Pair<Byte, ByteArray>? {
        if (frame.size < HEADER + TAG_BITS / 8) return null
        if (frame[0] != VERSION) return null
        val kind = frame[1]
        val nonce = frame.copyOfRange(2, HEADER)
        val counter = ByteBuffer.wrap(nonce, 4, 8).long
        // Strictly increasing: a frame captured off the wire cannot be pushed
        // back in later, even though it would otherwise decrypt perfectly.
        if (counter <= lastReceived) return null
        return runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, receiveKey, GCMParameterSpec(TAG_BITS, nonce))
            cipher.updateAAD(frame.copyOfRange(0, HEADER))
            val plain = cipher.doFinal(frame, HEADER, frame.size - HEADER)
            lastReceived = counter
            kind to plain
        }.getOrNull()
    }

    private fun header(kind: Byte, counter: Long): ByteArray {
        val out = ByteArray(HEADER)
        out[0] = VERSION
        out[1] = kind
        // 4 zero bytes then the counter: 96-bit nonce, never repeated for a key.
        ByteBuffer.wrap(out, 6, 8).putLong(counter)
        return out
    }

    companion object {
        const val VERSION: Byte = 1
        /** A UTF-8 JSON message — everything the two ends say to each other. */
        const val KIND_JSON: Byte = 1
        /** A JPEG screen-mirror frame. */
        const val KIND_FRAME: Byte = 2
        /**
         * A slice of a file in flight. The payload carries its own small header
         * — a 4-byte transfer id and an 8-byte offset — so chunks can be written
         * straight to the right place without buffering the whole file.
         */
        const val KIND_FILE: Byte = 3

        private const val HEADER = 14
        private const val TAG_BITS = 128
        private val INFO_PHONE_TO_MAC = "tethr/v1 phone->mac".toByteArray()
        private val INFO_MAC_TO_PHONE = "tethr/v1 mac->phone".toByteArray()

        /** HKDF-SHA256 (RFC 5869): extract, then expand. */
        private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int = 32): ByteArray {
            val extract = Mac.getInstance("HmacSHA256")
            extract.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = extract.doFinal(ikm)

            val expand = Mac.getInstance("HmacSHA256")
            expand.init(SecretKeySpec(prk, "HmacSHA256"))
            val out = ByteArray(length)
            var block = ByteArray(0)
            var filled = 0
            var counter = 1
            while (filled < length) {
                expand.reset()
                expand.update(block)
                expand.update(info)
                expand.update(counter.toByte())
                block = expand.doFinal()
                val take = minOf(block.size, length - filled)
                System.arraycopy(block, 0, out, filled, take)
                filled += take
                counter++
            }
            return out
        }
    }
}
