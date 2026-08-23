package com.nikhilraj.tethr

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.ArrayDeque
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Finds the paired Mac on whatever network we happen to be on, using the
 * Bonjour service the Mac already advertises (`_tethr._tcp`).
 *
 * This is what lets the link come up at home, at a café, or after the router
 * hands the Mac a new lease, without re-scanning the QR: the Mac's address is
 * discovered rather than remembered. Pairing itself is unaffected — the stored
 * secret still decides whether a Mac we find is actually ours.
 */
class MacFinder(
    context: Context,
    private val onFound: (host: String, port: Int) -> Unit,
) {
    private val app = context.applicationContext
    private val nsd = app.getSystemService(NsdManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // NsdManager rejects overlapping resolves with FAILURE_ALREADY_ACTIVE, so
    // services are resolved strictly one at a time.
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (listener != null || nsd == null) return
        acquireMulticastLock()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onServiceLost(service: NsdServiceInfo) {}
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.trim('.') != SERVICE_TYPE.trim('.')) return
                handler.post {
                    pending.addLast(service)
                    resolveNext()
                }
            }
            override fun onStartDiscoveryFailed(type: String, code: Int) {
                handler.post { stop() }
            }
            override fun onStopDiscoveryFailed(type: String, code: Int) {
                handler.post { stop() }
            }
        }
        listener = l
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
            .onFailure {
                listener = null
                releaseMulticastLock()
            }
    }

    fun stop() {
        listener?.let { l -> runCatching { nsd?.stopServiceDiscovery(l) } }
        listener = null
        pending.clear()
        resolving = false
        releaseMulticastLock()
    }

    private fun resolveNext() {
        if (resolving || nsd == null) return
        val next = pending.pollFirst() ?: return
        resolving = true
        // resolveService is deprecated at API 34 in favour of
        // registerServiceInfoCallback, but minSdk here is 26.
        @Suppress("DEPRECATION")
        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                handler.post {
                    resolving = false
                    resolveNext()
                }
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val addr = info.host
                val port = info.port
                handler.post {
                    resolving = false
                    // IPv4 only: an IPv6 literal would need bracketing in the
                    // ws:// URL, and every path we care about offers v4.
                    if (addr is Inet4Address && port > 0) {
                        addr.hostAddress?.let { onFound(it, port) }
                    }
                    resolveNext()
                }
            }
        })
    }

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        val wifi = app.getSystemService(WifiManager::class.java) ?: return
        multicastLock = runCatching {
            wifi.createMulticastLock("tethr:nsd").apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) runCatching { lock.release() }
        }
        multicastLock = null
    }

    private companion object {
        const val SERVICE_TYPE = "_tethr._tcp."
    }
}

/**
 * The finder of last resort, for the one case mDNS can't cover: when this
 * phone *is* the network. Over a Wi-Fi hotspot or USB tether the Mac is a
 * client of ours, and Android's mDNS daemon doesn't serve those interfaces —
 * so we simply walk our own subnet looking for something answering on the
 * Mac's port. Also covers guest networks that filter multicast.
 */
class SubnetProbe(
    private val port: Int,
    private val onFound: (host: String) -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val done = AtomicBoolean(false)
    private var pool: ExecutorService? = null

    fun start() {
        val running = pool
        if (running != null && !running.isTerminated) return
        val targets = targets()
        if (targets.isEmpty()) return

        done.set(false)
        val ex = Executors.newFixedThreadPool(THREADS)
        pool = ex
        for (ip in targets) {
            ex.execute {
                if (done.get()) return@execute
                val open = runCatching {
                    Socket().use { s ->
                        s.connect(InetSocketAddress(ip, port), TIMEOUT_MS)
                        true
                    }
                }.getOrDefault(false)
                // First answer wins; the rest of the sweep is abandoned.
                if (open && done.compareAndSet(false, true)) {
                    handler.post { onFound(ip) }
                }
            }
        }
        ex.shutdown()
    }

    fun stop() {
        done.set(true)
        pool?.shutdownNow()
        pool = null
    }

    /**
     * Every other host on a /24 that *we* are hosting.
     *
     * Deliberately limited to tethering interfaces. Sweeping a network we
     * merely joined — an office or café LAN — would be scanning other people's
     * machines, which is both rude and the kind of traffic that trips intrusion
     * detection. On our own hotspot the only hosts are our own clients, and it
     * is the one case mDNS cannot serve.
     */
    private fun targets(): List<String> {
        val out = mutableListOf<String>()
        val interfaces = runCatching {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        }.getOrDefault(emptyList())

        for (nif in interfaces) {
            val usable = runCatching { nif.isUp && !nif.isLoopback }.getOrDefault(false)
            if (!usable) continue
            if (!isTether(nif.name.orEmpty())) continue
            for (ia in nif.interfaceAddresses) {
                val addr = ia.address
                if (addr !is Inet4Address) continue
                // /24 or tighter only. Cellular hands out a /8 — 16M probes.
                if (ia.networkPrefixLength < 24) continue
                val self = addr.hostAddress ?: continue
                val o = addr.address
                val prefix = "${o[0].toInt() and 0xFF}.${o[1].toInt() and 0xFF}.${o[2].toInt() and 0xFF}"
                for (host in 1..254) {
                    val ip = "$prefix.$host"
                    if (ip != self) out.add(ip)
                }
                if (out.size >= MAX_TARGETS) return out
            }
        }
        return out
    }

    /** Interfaces Android uses when this phone is the one providing the network. */
    private fun isTether(name: String): Boolean =
        TETHER_PREFIXES.any { name.startsWith(it) }

    private companion object {
        const val THREADS = 48
        const val TIMEOUT_MS = 350
        const val MAX_TARGETS = 512
        // Wi-Fi hotspot (ap0 / swlan0), USB tethering (rndis0 / ncm0), Bluetooth PAN.
        val TETHER_PREFIXES = listOf("ap", "swlan", "rndis", "ncm", "usb", "bt-pan", "tether")
    }
}
