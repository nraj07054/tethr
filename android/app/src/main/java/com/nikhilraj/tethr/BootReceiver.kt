package com.nikhilraj.tethr

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings the link back after a reboot or an app update, so a paired phone
 * reconnects on its own and the app never has to be opened.
 *
 * Receiving BOOT_COMPLETED is one of the few exemptions to Android 12+'s ban on
 * starting a foreground service from the background, which is what makes it
 * legal to start ConnectionService straight from here.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            // Some OEMs (including ColorOS) send this instead on a fast boot.
            "android.intent.action.QUICKBOOT_POWERON",
            "com.oppo.intent.action.QUICKBOOT_POWERON",
            -> if (PairStore.load(context) != null) ConnectionService.start(context)
        }
    }
}
