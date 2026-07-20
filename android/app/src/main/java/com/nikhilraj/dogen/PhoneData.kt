package com.nikhilraj.dogen

import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Reads contacts and the call log from the device and serialises them into the
 * JSON messages the Mac understands. Every query is permission-guarded and
 * returns an empty payload (never throws) when the permission is missing, so a
 * partially-granted device still syncs whatever it can.
 */
object PhoneData {

    fun hasPermission(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    /** {"type":"contacts","items":[{"name","number"}...]} — deduped, name-sorted. */
    fun contactsMessage(context: Context): JSONObject {
        val items = JSONArray()
        if (hasPermission(context, android.Manifest.permission.READ_CONTACTS)) {
            val seen = HashSet<String>()
            val cursor = context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                ),
                null, null,
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " ASC"
            )
            cursor?.use { c ->
                val nameIdx = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val numIdx = c.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                while (c.moveToNext()) {
                    val name = c.getString(nameIdx)?.trim().orEmpty()
                    val number = c.getString(numIdx)?.trim().orEmpty()
                    if (number.isEmpty()) continue
                    val key = number.filter { it.isDigit() }.takeLast(10) + "|" + name
                    if (!seen.add(key)) continue
                    items.put(JSONObject().put("name", name.ifEmpty { number }).put("number", number))
                }
            }
        }
        return JSONObject().put("type", "contacts").put("items", items)
    }

    /** {"type":"calllog","items":[{"name","number","direction","when","duration"}...]}. */
    fun callLogMessage(context: Context, limit: Int = 100): JSONObject {
        val items = JSONArray()
        if (hasPermission(context, android.Manifest.permission.READ_CALL_LOG)) {
            val cursor = context.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(
                    CallLog.Calls.CACHED_NAME,
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.DATE,
                    CallLog.Calls.DURATION
                ),
                null, null,
                CallLog.Calls.DATE + " DESC"
            )
            cursor?.use { c ->
                val nameIdx = c.getColumnIndex(CallLog.Calls.CACHED_NAME)
                val numIdx = c.getColumnIndex(CallLog.Calls.NUMBER)
                val typeIdx = c.getColumnIndex(CallLog.Calls.TYPE)
                val dateIdx = c.getColumnIndex(CallLog.Calls.DATE)
                val durIdx = c.getColumnIndex(CallLog.Calls.DURATION)
                var n = 0
                while (c.moveToNext() && n < limit) {
                    val number = c.getString(numIdx)?.trim().orEmpty()
                    val name = c.getString(nameIdx)?.trim().orEmpty()
                    val direction = when (c.getInt(typeIdx)) {
                        CallLog.Calls.INCOMING_TYPE -> "incoming"
                        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE -> "missed"
                        else -> "incoming"
                    }
                    items.put(
                        JSONObject()
                            .put("name", name.ifEmpty { number.ifEmpty { "Unknown" } })
                            .put("number", number)
                            .put("direction", direction)
                            .put("when", c.getLong(dateIdx))
                            .put("duration", c.getLong(durIdx))
                    )
                    n++
                }
            }
        }
        return JSONObject().put("type", "calllog").put("items", items)
    }
}
