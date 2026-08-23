package com.nikhilraj.tethr

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * Files moving between the phone and the Mac.
 *
 * Transfers are chunked rather than sent whole: a photo or a video would
 * otherwise have to be held in memory twice on both devices, and a single
 * enormous frame would sit in the socket's send buffer long enough to stall the
 * heartbeat and the screen mirror behind it. Each chunk carries the transfer id
 * and its offset, so it can be written straight to the right place in the file
 * and arriving out of order costs nothing.
 *
 * Incoming files land in the app's own cache first and are only published to
 * the device's Downloads once complete, so an interrupted transfer never leaves
 * a half-written file sitting in the user's gallery.
 */
object FileTransfer {

    /** Chunk payload: [4-byte id][8-byte offset][bytes]. */
    const val HEADER = 12
    /** Big enough to keep the link busy, small enough not to hog the socket. */
    const val CHUNK = 128 * 1024
    /** Refuse absurd transfers outright rather than filling the disk. */
    private const val MAX_SIZE = 8L * 1024 * 1024 * 1024
    /** Bounds open file handles and staged partial files. */
    private const val MAX_CONCURRENT = 4
    /** Ceiling on staged-but-unsent copies sitting in our cache. */
    private const val MAX_STAGED_BYTES = 2L * 1024 * 1024 * 1024

    class Incoming(
        val id: Int,
        val name: String,
        val size: Long,
        val mime: String,
        val file: File,
    ) {
        var received: Long = 0
    }

    private val incoming = HashMap<Int, Incoming>()

    /** A staged copy of something the user asked to send. */
    data class Staged(val file: File, val name: String, val mime: String)

    /**
     * Copies a shared URI into our own cache, right now, while its read
     * permission is still alive.
     *
     * A share's grant belongs to the activity that received it and dies when
     * that activity finishes — long before a queued transfer would get around
     * to reading it. Copying first costs a little disk and makes sending
     * reliable even if the Mac is not reachable for another ten minutes.
     */
    fun stage(context: Context, uri: Uri): Staged? = runCatching {
        val name = displayName(context, uri)
        val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
        val dir = File(context.cacheDir, "outgoing").apply { mkdirs() }
        val file = File(dir, "${System.nanoTime()}-${sanitise(name)}")
        context.contentResolver.openInputStream(uri)?.use { input ->
            file.outputStream().use { input.copyTo(it) }
        } ?: return null
        if (file.length() <= 0L) {
            file.delete()
            return null
        }
        Staged(file, sanitise(name), mime)
    }.onFailure {
        android.util.Log.w("TethrShare", "staging failed: ${it.javaClass.simpleName}: ${it.message}")
    }.getOrNull()

    private fun displayName(context: Context, uri: Uri): String {
        runCatching {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (i >= 0 && c.moveToFirst()) c.getString(i)?.let { return it }
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    }

    fun header(id: Int, offset: Long): ByteArray {
        val out = ByteArray(HEADER)
        ByteBuffer.wrap(out).putInt(id).putLong(offset)
        return out
    }

    fun begin(context: Context, id: Int, name: String, size: Long, mime: String): Incoming? {
        // The peer is authenticated, but "authenticated" is not "trusted with
        // this device's disk": a bug or a compromised Mac must not be able to
        // fill it, and every field below arrives from the other side.
        if (size < 0 || size > MAX_SIZE) return null
        synchronized(incoming) { if (incoming.size >= MAX_CONCURRENT) return null }
        cancel(id)
        val dir = File(context.cacheDir, "incoming").apply { mkdirs() }
        // Named by id, not by the sender's filename: a peer must never get to
        // choose a path on this device.
        val file = File(dir, "$id.part")
        file.delete()
        val t = Incoming(id, sanitise(name), size, mime, file)
        synchronized(incoming) { incoming[id] = t }
        return t
    }

    fun write(id: Int, offset: Long, bytes: ByteArray): Incoming? {
        val t = synchronized(incoming) { incoming[id] } ?: return null
        // Without this a single chunk claiming a huge offset would punch out a
        // file far larger than the transfer ever declared.
        if (offset < 0 || bytes.size < 0 || offset + bytes.size > t.size) {
            android.util.Log.w("TethrFile", "chunk outside the declared size; dropping transfer")
            cancel(id)
            return null
        }
        runCatching {
            RandomAccessFile(t.file, "rw").use { raf ->
                raf.seek(offset)
                raf.write(bytes)
            }
            t.received += bytes.size
        }
        return t
    }

    /** Publishes a finished transfer to Downloads and returns its display name. */
    fun finish(context: Context, id: Int): String? {
        val t = synchronized(incoming) { incoming.remove(id) } ?: return null
        if (!t.file.exists()) return null
        val saved = runCatching { publish(context, t) }.getOrDefault(false)
        t.file.delete()
        return if (saved) t.name else null
    }

    fun cancel(id: Int) {
        val t = synchronized(incoming) { incoming.remove(id) } ?: return
        t.file.delete()
    }

    /**
     * Clears staged copies left behind by sends that never completed — a share
     * taken while the Mac was unreachable, or a crash mid-transfer. Without this
     * the cache would only ever grow, holding copies of the user's own photos.
     */
    fun sweepStaged(context: Context, maxAgeMs: Long = 24 * 60 * 60 * 1000L) {
        val dir = File(context.cacheDir, "outgoing")
        val cutoff = System.currentTimeMillis() - maxAgeMs
        dir.listFiles()?.forEach { if (it.lastModified() < cutoff) it.delete() }
        // Also drop the oldest if the directory has run away regardless of age.
        val files = dir.listFiles()?.sortedBy { it.lastModified() } ?: return
        var total = files.sumOf { it.length() }
        for (f in files) {
            if (total <= MAX_STAGED_BYTES) break
            total -= f.length()
            f.delete()
        }
    }

    fun cancelAll() {
        synchronized(incoming) {
            incoming.values.forEach { it.file.delete() }
            incoming.clear()
        }
    }

    private fun publish(context: Context, t: Incoming): Boolean {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, t.name)
                put(MediaStore.Downloads.MIME_TYPE, t.mime.ifEmpty { "application/octet-stream" })
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri: Uri = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            ) ?: return false
            resolver.openOutputStream(uri)?.use { out ->
                t.file.inputStream().use { it.copyTo(out) }
            } ?: return false
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return true
        }
        @Suppress("DEPRECATION")
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        downloads.mkdirs()
        val dest = File(downloads, t.name)
        t.file.inputStream().use { input -> dest.outputStream().use { input.copyTo(it) } }
        return true
    }

    /**
     * Strips anything that could steer the file out of Downloads. The name
     * arrives from the other device, so it is untrusted input.
     */
    private fun sanitise(name: String): String {
        val base = name.substringAfterLast('/').substringAfterLast('\\')
            .filter { it.isLetterOrDigit() || it in " ._-()[]" }
            .trim()
        return base.ifEmpty { "tethr-file" }.take(120)
    }
}
