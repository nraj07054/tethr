package com.nikhilraj.tethr

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Wire-format tests for the encrypted session.
 *
 * The Mac runs a separate implementation of this format in Swift, so the two
 * have to agree byte for byte or the link simply stops working. The sealed
 * frames below were produced by the Mac's SessionCrypto.swift from the fixed
 * secret and nonces used here — if a change to either side breaks compatibility,
 * this fails rather than the link failing on someone's desk.
 */
class SessionCryptoTest {

    private val secret = "TESTSECRET-abcdefghijklmnop"
    private val macNonce = "MACNONCE-0123456789"
    private val phoneNonce = "PHONENONCE-9876543210"

    private fun phone() = SessionCrypto(secret, macNonce, phoneNonce)
    private fun b64(s: String): ByteArray = Base64.getDecoder().decode(s)

    /** Frames sealed by the Mac must open on the phone. */
    @Test
    fun opensFramesSealedByTheMac() {
        val crypto = phone()
        val first = crypto.open(b64("AQEAAAAAAAAAAAAAAABiCu6PVni7PymRK6MR+3Bcg8AxPnXf7hI7/V8g0aq6"))
        assertEquals(SessionCrypto.KIND_JSON, first!!.first)
        assertEquals("""{"type":"ping"}""", String(first.second))

        val second = crypto.open(
            b64("AQEAAAAAAAAAAAAAAAH/NXv5fnGIe8WtdEHiBhXpIrEVOi4jXyhxRAvke05pH/caPfHz4AeVFcTaE5PFyWkB/MjSl10Q")
        )
        assertEquals("""{"type":"dial","number":"+15551234567"}""", String(second!!.second))
    }

    /** A frame replayed after being accepted must be refused. */
    @Test
    fun rejectsReplay() {
        val crypto = phone()
        val frame = b64("AQEAAAAAAAAAAAAAAABiCu6PVni7PymRK6MR+3Bcg8AxPnXf7hI7/V8g0aq6")
        assertTrue(crypto.open(frame) != null)
        assertNull("a replayed frame must not open twice", crypto.open(frame))
    }

    /** A single flipped bit anywhere must make the frame unopenable. */
    @Test
    fun rejectsTamperedFrames() {
        val frame = b64("AQEAAAAAAAAAAAAAAABiCu6PVni7PymRK6MR+3Bcg8AxPnXf7hI7/V8g0aq6")
        for (i in frame.indices) {
            val bad = frame.copyOf()
            bad[i] = (bad[i].toInt() xor 0x01).toByte()
            assertNull("byte $i must not be forgeable", phone().open(bad))
        }
    }

    /** Keys are bound to the handshake, so another session's keys must not work. */
    @Test
    fun rejectsFramesFromAnotherSession() {
        val other = SessionCrypto(secret, macNonce, "DIFFERENT-NONCE")
        assertNull(other.open(b64("AQEAAAAAAAAAAAAAAABiCu6PVni7PymRK6MR+3Bcg8AxPnXf7hI7/V8g0aq6")))
    }

    /** Prints phone-sealed frames for the Swift side to verify against. */
    @Test
    fun sealsFramesForTheMac() {
        val crypto = phone()
        val json = crypto.seal(SessionCrypto.KIND_JSON, """{"type":"hello-from-phone"}""".toByteArray())
        val frame = crypto.seal(SessionCrypto.KIND_FRAME, byteArrayOf(-1, -40, -1, 1))
        println("PHONE_SEALED_JSON " + Base64.getEncoder().encodeToString(json))
        println("PHONE_SEALED_FRAME " + Base64.getEncoder().encodeToString(frame))
        // Header shape: version, kind, then a 12-byte nonce.
        assertEquals(SessionCrypto.VERSION, json[0])
        assertEquals(SessionCrypto.KIND_JSON, json[1])
        assertArrayEquals(ByteArray(4), json.copyOfRange(2, 6))
    }
}
