package com.nikhilraj.tethr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The caller reported for each call, across the transitions the platform
 * actually emits. The call-waiting cases are the ones that used to be wrong.
 */
class CallNumbersTest {

    private val alice = "+15550001"
    private val bob = "+15550002"

    @Test fun `incoming call is named while ringing and after answering`() {
        val n = CallNumbers()
        assertEquals(alice, n.report(CallNumbers.RINGING, alice))
        // Picking up arrives with no number of its own.
        assertEquals(alice, n.report(CallNumbers.OFFHOOK, null))
        assertNull(n.report(CallNumbers.IDLE, null))
    }

    @Test fun `declining call waiting leaves the first caller on the line`() {
        val n = CallNumbers()
        n.report(CallNumbers.RINGING, alice)
        n.report(CallNumbers.OFFHOOK, null)
        // Bob rings through; the whole phone reads as "ringing".
        assertEquals(bob, n.report(CallNumbers.RINGING, bob))
        // Bob declined: back to offhook, and Alice is still the one on the call.
        assertEquals(alice, n.report(CallNumbers.OFFHOOK, null))
    }

    @Test fun `an offhook broadcast carrying the ringing number cannot hijack the call`() {
        val n = CallNumbers()
        n.report(CallNumbers.RINGING, alice)
        n.report(CallNumbers.OFFHOOK, null)
        n.report(CallNumbers.RINGING, bob)
        // Some devices repeat the incoming number on the offhook broadcast.
        assertEquals(alice, n.report(CallNumbers.OFFHOOK, bob))
    }

    @Test fun `ending everything retires both callers`() {
        val n = CallNumbers()
        n.report(CallNumbers.RINGING, alice)
        n.report(CallNumbers.OFFHOOK, null)
        n.report(CallNumbers.RINGING, bob)
        assertNull(n.report(CallNumbers.IDLE, null))
        // A fresh call after that starts from nothing.
        assertEquals(bob, n.report(CallNumbers.RINGING, bob))
    }

    @Test fun `outgoing call has no number to report`() {
        val n = CallNumbers()
        // Android stopped handing outgoing numbers to third-party apps, so this
        // arrives bare and the Mac fills in what it dialled.
        assertNull(n.report(CallNumbers.OFFHOOK, null))
    }

    @Test fun `forState answers without advancing the state machine`() {
        val n = CallNumbers()
        n.report(CallNumbers.RINGING, alice)
        n.report(CallNumbers.OFFHOOK, null)
        n.report(CallNumbers.RINGING, bob)
        assertEquals(bob, n.forState(CallNumbers.RINGING))
        assertEquals(alice, n.forState(CallNumbers.OFFHOOK))
        assertNull(n.forState(CallNumbers.IDLE))
        // Unchanged by the questions above.
        assertEquals(alice, n.report(CallNumbers.OFFHOOK, null))
    }
}
