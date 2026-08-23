package com.nikhilraj.tethr

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast

/**
 * Makes Tethr a target in the system share sheet, so anything on the phone —
 * a photo, a video, a PDF, a page from a browser — can be sent to the Mac from
 * wherever it already lives, instead of being hunted down through a picker
 * inside this app.
 *
 * The activity itself never draws: it hands the URIs to the service and closes,
 * so sharing feels like the file simply left.
 */
class ShareActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val uris = extractUris(intent)
        // Counts only, never the URIs themselves — those name the user's files.
        android.util.Log.i("TethrShare", "shared ${uris.size} item(s)")
        when {
            PairStore.load(this) == null ->
                toast("Pair Tethr with your Mac first")
            uris.isEmpty() ->
                toast("Nothing to send")
            else -> {
                toast(if (uris.size == 1) "Sending to your Mac" else "Sending ${uris.size} files")
                // Staged on a worker, but this activity stays alive until it is
                // done: the read permission dies with it.
                Thread {
                    val staged = uris.mapNotNull { FileTransfer.stage(this, it) }
                    runOnUiThread {
                        staged.forEach { forward(it) }
                        finish()
                    }
                }.start()
                return
            }
        }
        finish()
    }

    /**
     * Hands the URI to the service on an intent of its own.
     *
     * Deliberately without FLAG_GRANT_READ_URI_PERMISSION: an app cannot
     * re-grant a permission it was merely given, and asking to will throw. The
     * service does not need one — URI grants are held per UID, and the service
     * shares this activity's, so it can open the stream directly.
     */
    private fun forward(item: FileTransfer.Staged) {
        val intent = Intent(this, ConnectionService::class.java)
            .setAction(ConnectionService.ACTION_SEND_FILE)
            .putExtra(ConnectionService.EXTRA_FILE_PATH, item.file.absolutePath)
            .putExtra(ConnectionService.EXTRA_FILE_NAME, item.name)
            .putExtra(ConnectionService.EXTRA_FILE_MIME, item.mime)
        runCatching {
            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
        }.onFailure { android.util.Log.w("TethrShare", "could not start service: ${it.message}") }
    }

    private fun extractUris(intent: Intent?): List<Uri> {
        intent ?: return emptyList()
        return when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(stream(intent))
            Intent.ACTION_SEND_MULTIPLE -> {
                @Suppress("DEPRECATION")
                val list = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                list.orEmpty().filterNotNull()
            }
            else -> emptyList()
        }
    }

    private fun stream(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    private fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
    }
}
