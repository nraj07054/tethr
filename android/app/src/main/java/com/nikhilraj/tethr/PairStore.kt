package com.nikhilraj.tethr

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
    /** Every address the Mac advertised — Wi-Fi, hotspot, USB, Bluetooth PAN. */
    val hosts: List<String> = emptyList(),
) {
    /**
     * Addresses to dial, last known good first. The Mac has one of these per
     * network interface, so trying them all is what lets the link come up over
     * a hotspot or a USB/Bluetooth tether with no router involved.
     */
    val candidates: List<String> get() = (listOf(host) + hosts).distinct()
}

object PairStore {
    private const val PREFS = "tethr"

    fun load(context: Context): Pairing? {
        val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val host = p.getString("host", null) ?: return null
        return Pairing(
            host = host,
            wsPort = p.getInt("wsPort", 8738),
            token = p.getString("token", null),
            secret = p.getString("secret", null),
            macName = p.getString("macName", null),
            hosts = p.getString("hosts", null).orEmpty()
                .split(",").map(String::trim).filter(String::isNotEmpty),
        )
    }

    /**
     * Parse a scanned pairing URL:
     * http://<ip>:<port>/?t=<token>&ws=<wsPort>&hosts=<ip,ip,...>
     */
    fun fromQR(contents: String): Pairing? {
        val uri = Uri.parse(contents)
        val host = uri.host ?: return null
        val advertised = uri.getQueryParameter("hosts").orEmpty()
            .split(",").map(String::trim).filter(String::isNotEmpty)
        return Pairing(
            host = host,
            wsPort = uri.getQueryParameter("ws")?.toIntOrNull() ?: 8738,
            token = uri.getQueryParameter("t"),
            secret = null,
            macName = null,
            hosts = (listOf(host) + advertised).distinct(),
        )
    }

    fun save(context: Context, pairing: Pairing) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
            putString("host", pairing.host)
            putInt("wsPort", pairing.wsPort)
            putString("token", pairing.token)
            putString("secret", pairing.secret)
            putString("macName", pairing.macName)
            putString("hosts", pairing.hosts.joinToString(","))
        }
    }

    fun clear(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { clear() }
    }
}
