package com.nikhilraj.dogen

import android.content.Context
import android.net.Uri
import androidx.core.content.edit

/** Persisted pairing details parsed from the Mac's QR code. */
data class Pairing(
    val host: String,
    val wsPort: Int,
    val token: String?,
    val secret: String?,
    val macName: String?,
)

object PairStore {
    private const val PREFS = "dogen"

    fun load(context: Context): Pairing? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val host = p.getString("host", null) ?: return null
        return Pairing(
            host = host,
            wsPort = p.getInt("wsPort", 8738),
            token = p.getString("token", null),
            secret = p.getString("secret", null),
            macName = p.getString("macName", null),
        )
    }

    /** Parse a scanned pairing URL: http://<ip>:<port>/?t=<token>&ws=<wsPort> */
    fun fromQR(contents: String): Pairing? {
        val uri = Uri.parse(contents)
        val host = uri.host ?: return null
        return Pairing(
            host = host,
            wsPort = uri.getQueryParameter("ws")?.toIntOrNull() ?: 8738,
            token = uri.getQueryParameter("t"),
            secret = null,
            macName = null,
        )
    }

    fun save(context: Context, pairing: Pairing) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
            putString("host", pairing.host)
            putInt("wsPort", pairing.wsPort)
            putString("token", pairing.token)
            putString("secret", pairing.secret)
            putString("macName", pairing.macName)
        }
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { clear() }
    }
}
