package com.nikhilraj.tethr

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * The two things standing between a paired phone and a link that just works,
 * neither of which an app can grant itself:
 *
 *  - Doze / battery optimisation, which throttles our reconnects.
 *  - The OEM "auto-start" allow-list. On ColorOS, MIUI and similar skins this
 *    is what decides whether the service survives at all, and there is no API
 *    to read or set it — the best any app can do is open the right screen.
 */
object Background {

    fun isBatteryUnrestricted(context: Context): Boolean {
        val pm = context.getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /** Opens the system prompt to exempt Tethr from battery optimisation. */
    fun requestBatteryUnrestricted(context: Context) {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (!launch(context, intent)) {
            launch(
                context,
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    /**
     * Skins that gate background work behind a manual auto-start opt-in.
     *
     * Deliberately keyed on the manufacturer rather than on whether a known
     * auto-start activity resolves: current ColorOS has no such activity —
     * OPPO moved the toggle into each app's own settings page — so probing for
     * components hides the prompt on precisely the phones that need it.
     */
    private val GATED_OEMS = setOf(
        "oppo", "realme", "oneplus", "xiaomi", "redmi", "poco",
        "vivo", "iqoo", "huawei", "honor", "asus", "meizu",
        "tecno", "infinix", "letv", "samsung",
    )

    fun needsAutoStartOptIn(): Boolean {
        val maker = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return GATED_OEMS.any { maker.contains(it) || brand.contains(it) }
    }

    /**
     * Takes the user to wherever this phone hides auto-start. There is no API
     * to read or set it, so the most any app can do is open the screen: the
     * OEM's startup manager where one exists, otherwise Tethr's own app-info
     * page, which is where newer ColorOS keeps "Allow auto launch".
     */
    fun openAutoStart(context: Context) {
        val intent = autoStartIntent(context)
        if (intent != null && launch(context, intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))) return
        openAppSettings(context)
    }

    /** Falls back to Tethr's own app-info page, which every device has. */
    fun openAppSettings(context: Context) {
        launch(
            context,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    /** The first auto-start screen this device actually has. */
    private fun autoStartIntent(context: Context): Intent? {
        val candidates = listOf(
            // OPPO / OnePlus / realme — ColorOS, newest package first.
            "com.oplus.safecenter" to "com.oplus.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            // Xiaomi — MIUI / HyperOS.
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            // vivo — Funtouch / OriginOS.
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            // Huawei / Honor.
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            // Letv / Asus and friends.
            "com.asus.mobilemanager" to "com.asus.mobilemanager.autostart.AutoStartActivity",
        )
        val pm = context.packageManager
        for ((pkg, cls) in candidates) {
            val intent = Intent().setComponent(ComponentName(pkg, cls))
            val resolved =
                if (Build.VERSION.SDK_INT >= 33) {
                    pm.resolveActivity(intent, android.content.pm.PackageManager.ResolveInfoFlags.of(0))
                } else {
                    @Suppress("DEPRECATION") pm.resolveActivity(intent, 0)
                }
            if (resolved != null) return intent
        }
        return null
    }

    private fun launch(context: Context, intent: Intent): Boolean =
        runCatching { context.startActivity(intent); true }.getOrDefault(false)
}
