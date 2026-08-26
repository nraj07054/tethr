package com.nikhilraj.tethr

import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import org.json.JSONArray
import org.json.JSONObject

/**
 * The phone's SMS threads, and sending one.
 *
 * Reading SMS needs READ_SMS, which Google Play only grants to an app that is
 * the device's default SMS handler. Tethr is sideloaded rather than published,
 * so it can hold the permission — but it is why Messages can never ship through
 * the Play Store, and why the phone asks for it separately from everything else.
 *
 * Only SMS is handled. MMS lives in a different provider with its own parts
 * table for attachments, and a picture message would arrive here as an empty
 * body — so those threads are skipped rather than shown blank.
 */
object Sms {

    /** Newest messages first, capped so a years-old inbox cannot stall the link. */
    private const val THREAD_LIMIT = 60
    private const val MESSAGES_PER_THREAD = 80

    /** The content URI to watch for any change to the SMS store. */
    val OBSERVE_URI: Uri = Telephony.Sms.CONTENT_URI

    fun canRead(context: Context): Boolean =
        PhoneData.hasPermission(context, android.Manifest.permission.READ_SMS)

    fun canSend(context: Context): Boolean =
        PhoneData.hasPermission(context, android.Manifest.permission.SEND_SMS)

    /**
     * {"type":"threads","items":[{"id","address","name","when","unread","messages":[...]}]}
     *
     * The thread id is the provider's own, so the Mac can merge an updated
     * thread onto the one it already has rather than growing a duplicate.
     */
    fun threadsMessage(context: Context): JSONObject {
        val items = JSONArray()
        if (canRead(context)) {
            // One pass over the messages, newest first, bucketed by thread. The
            // conversations table would give snippets in one query, but not the
            // bodies, and a second query per thread costs more than this does.
            val cursor: Cursor? = context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                arrayOf(
                    Telephony.Sms._ID,
                    Telephony.Sms.THREAD_ID,
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.DATE,
                    Telephony.Sms.TYPE,
                    Telephony.Sms.READ,
                    Telephony.Sms.SUBSCRIPTION_ID
                ),
                null, null,
                Telephony.Sms.DATE + " DESC"
            )
            val threads = LinkedHashMap<String, Thread>()
            cursor?.use { c ->
                val idIdx = c.getColumnIndex(Telephony.Sms._ID)
                val threadIdx = c.getColumnIndex(Telephony.Sms.THREAD_ID)
                val addrIdx = c.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIdx = c.getColumnIndex(Telephony.Sms.BODY)
                val dateIdx = c.getColumnIndex(Telephony.Sms.DATE)
                val typeIdx = c.getColumnIndex(Telephony.Sms.TYPE)
                val readIdx = c.getColumnIndex(Telephony.Sms.READ)
                val subIdx = c.getColumnIndex(Telephony.Sms.SUBSCRIPTION_ID)
                while (c.moveToNext()) {
                    val threadId = c.getString(threadIdx)?.trim().orEmpty()
                    if (threadId.isEmpty()) continue
                    val body = c.getString(bodyIdx).orEmpty()
                    val address = c.getString(addrIdx)?.trim().orEmpty()
                    // An MMS row surfaces here with nothing in it; showing an
                    // empty bubble is worse than leaving it out.
                    if (body.isEmpty() && address.isEmpty()) continue

                    val thread = threads[threadId]
                        ?: if (threads.size >= THREAD_LIMIT) continue
                        else Thread(threadId, address).also { threads[threadId] = it }
                    if (thread.address.isEmpty() && address.isNotEmpty()) thread.address = address
                    if (thread.messages.length() >= MESSAGES_PER_THREAD) continue

                    // MESSAGE_TYPE_INBOX is the only one that is genuinely from
                    // them; sent, outbox, queued and failed are all ours.
                    val mine = c.getInt(typeIdx) != Telephony.Sms.MESSAGE_TYPE_INBOX
                    if (!mine && c.getInt(readIdx) == 0) thread.unread++
                    thread.messages.put(
                        JSONObject()
                            .put("id", c.getString(idIdx).orEmpty())
                            .put("me", mine)
                            .put("text", body)
                            .put("when", c.getLong(dateIdx))
                    )
                    // The newest message decides which SIM the thread belongs
                    // to, so a reply leaves from the number the other side has
                    // been talking to rather than whichever SIM is default.
                    if (c.getLong(dateIdx) > thread.newest) {
                        thread.newest = c.getLong(dateIdx)
                        if (subIdx >= 0) thread.subId = c.getInt(subIdx)
                    }
                }
            }
            for (t in threads.values) {
                // Oldest first, which is the order a conversation is read in.
                val ordered = JSONArray()
                for (i in t.messages.length() - 1 downTo 0) ordered.put(t.messages.get(i))
                val name = t.address.takeIf { it.isNotEmpty() }
                    ?.let { PhoneData.contactName(context, it) }
                items.put(
                    JSONObject()
                        .put("id", t.id)
                        .put("address", t.address)
                        .put("name", name.orEmpty().ifEmpty { t.address.ifEmpty { "Unknown" } })
                        .put("when", t.newest)
                        .put("unread", t.unread)
                        .put("subId", t.subId)
                        .put("sim", simLabel(context, t.subId))
                        .put("messages", ordered)
                )
            }
        }
        return JSONObject().put("type", "threads").put("items", items)
    }

    /**
     * Sends [text] to [address]. Long messages are split into the multipart
     * form the radio requires — a single sendTextMessage silently truncates
     * anything past one segment.
     */
    fun send(context: Context, address: String, text: String, subId: Int = -1): Boolean {
        if (!canSend(context) || address.isBlank() || text.isEmpty()) return false
        return runCatching {
            val default = context.getSystemService(SmsManager::class.java)
                ?: return@runCatching false
            // On a dual-SIM phone the default manager sends from whichever SIM
            // is set as the default for SMS, which is wrong for a conversation
            // that arrived on the other one: the recipient would see a number
            // they have never been texted from, on a different carrier and
            // tariff. Pin it to the subscription the thread belongs to.
            val manager = if (subId >= 0) {
                runCatching { default.createForSubscriptionId(subId) }.getOrDefault(default)
            } else {
                default
            }
            val parts = manager.divideMessage(text)
            if (parts.size > 1) {
                manager.sendMultipartTextMessage(address, null, parts, null, null)
            } else {
                manager.sendTextMessage(address, null, text, null, null)
            }
            true
        }.getOrDefault(false)
    }

    /**
     * {"type":"sims","items":[{"subId","label","slot"}...]}
     *
     * So the Mac can say which SIM a reply will leave from, and offer a choice
     * for a conversation that does not exist yet. Empty on a single-SIM phone,
     * which the Mac reads as "nothing to choose".
     */
    fun simsMessage(context: Context): JSONObject {
        val items = JSONArray()
        if (PhoneData.hasPermission(context, android.Manifest.permission.READ_PHONE_STATE)) {
            runCatching {
                val manager = context.getSystemService(SubscriptionManager::class.java)
                val active = manager?.activeSubscriptionInfoList.orEmpty()
                // A single SIM is not a choice, and naming it would only add a
                // control that cannot do anything.
                if (active.size > 1) {
                    for (info in active) {
                        val carrier = info.carrierName?.toString()?.trim().orEmpty()
                        val display = info.displayName?.toString()?.trim().orEmpty()
                        items.put(
                            JSONObject()
                                .put("subId", info.subscriptionId)
                                .put("slot", info.simSlotIndex + 1)
                                .put(
                                    "label",
                                    display.ifEmpty { carrier }
                                        .ifEmpty { "SIM ${info.simSlotIndex + 1}" }
                                )
                        )
                    }
                }
            }
        }
        return JSONObject().put("type", "sims").put("items", items)
    }

    /** The SIM's name for one subscription, or "" when there is nothing to say. */
    private fun simLabel(context: Context, subId: Int): String {
        if (subId < 0) return ""
        if (!PhoneData.hasPermission(context, android.Manifest.permission.READ_PHONE_STATE)) return ""
        return runCatching {
            val manager = context.getSystemService(SubscriptionManager::class.java)
            val active = manager?.activeSubscriptionInfoList.orEmpty()
            if (active.size < 2) return ""
            val info = active.firstOrNull { it.subscriptionId == subId } ?: return ""
            info.displayName?.toString()?.trim().orEmpty()
                .ifEmpty { info.carrierName?.toString()?.trim().orEmpty() }
                .ifEmpty { "SIM ${info.simSlotIndex + 1}" }
        }.getOrDefault("")
    }

    /** Marks every message in a thread read, so the phone's own badge clears too. */
    fun markRead(context: Context, threadId: String) {
        if (!canRead(context) || threadId.isBlank()) return
        runCatching {
            val values = android.content.ContentValues().apply {
                put(Telephony.Sms.READ, 1)
                put(Telephony.Sms.SEEN, 1)
            }
            context.contentResolver.update(
                Telephony.Sms.CONTENT_URI, values,
                "${Telephony.Sms.THREAD_ID} = ? AND ${Telephony.Sms.READ} = 0",
                arrayOf(threadId)
            )
        }
    }

    private class Thread(val id: String, var address: String) {
        val messages = JSONArray()
        var unread = 0
        var newest = 0L
        /** Which SIM the newest message used; -1 until a row says otherwise. */
        var subId = -1
    }
}
