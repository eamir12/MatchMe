package com.example.matchme

import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.os.Bundle
import android.util.Log

/**
 * Launcher-specific app-icon badge APIs.
 *
 * Android has no global badge API. Most launchers derive the icon badge from
 * the app's notifications, and for those [MatchMeBadgeController]'s carrier
 * notification is the mechanism that works. A number of launchers instead
 * expose a proprietary badge API (a broadcast intent or a content provider):
 * Samsung, Huawei, Sony, OPPO, Vivo, HTC and several third-party launchers.
 * On those devices this is the only way to publish an exact count, because
 * the launcher ignores `Notification.setNumber()`.
 *
 * This mirrors the approach of ShortcutBadger (the reference implementation
 * behind the popular badge plugins), implemented directly so the app does not
 * take a third-party dependency.
 *
 * These APIs are best effort on purpose: several of them cannot report
 * failure (a content provider `insert` happily returns a URI for a write the
 * launcher then discards), so [apply] being true is a positive signal only.
 * It is never used to suppress the notification carrier - see
 * [MatchMeBadgeController.applyCount].
 */
object MatchMeOemBadge {
    private const val TAG = "MatchMeOemBadge"

    private const val ACTION_BADGE_COUNT_UPDATE = "android.intent.action.BADGE_COUNT_UPDATE"
    private const val EXTRA_BADGE_COUNT = "badge_count"
    private const val EXTRA_PACKAGE_NAME = "badge_count_package_name"
    private const val EXTRA_CLASS_NAME = "badge_count_class_name"

    /** Applies [count] through a launcher-specific badge API. */
    fun apply(context: Context, count: Int): Boolean {
        val appContext = context.applicationContext
        val component = launchComponent(appContext) ?: return false
        for (provider in providersFor(appContext)) {
            val ok = try {
                provider.isAvailable(appContext) && provider.apply(appContext, component, count)
            } catch (error: Throwable) {
                Log.w(TAG, "${provider.name} badge failed", error)
                false
            }
            if (ok) {
                Log.i(TAG, "Badge applied via ${provider.name}: $count")
                return true
            }
        }
        return false
    }

    /**
     * Removes the badge from every launcher API present on the device.
     *
     * The badge may have been written by an earlier process (the app is not
     * running while it is killed), so the provider that set it cannot be
     * remembered in memory. Writing zero through every provider that exists
     * is the only way to guarantee a stale badge is cleared; a provider that
     * never held our badge ignores the write.
     */
    fun clear(context: Context) {
        val appContext = context.applicationContext
        val component = launchComponent(appContext) ?: return
        for (provider in allProviders) {
            try {
                if (provider.isAvailable(appContext)) {
                    provider.apply(appContext, component, 0)
                }
            } catch (error: Throwable) {
                Log.w(TAG, "Could not clear ${provider.name} badge", error)
            }
        }
    }

    /**
     * The activity that launches the app.
     *
     * Launchers key their badge on the package plus the launcher activity.
     */
    private fun launchComponent(context: Context): ComponentName? {
        return try {
            context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.component
        } catch (_: Throwable) {
            null
        }
    }

    private fun defaultLauncherPackage(context: Context): String? {
        return try {
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
                ?.activityInfo?.packageName
        } catch (_: Throwable) {
            null
        }
    }

    /** Receivers for [action]; empty when nothing on the device answers it. */
    private fun broadcastReceivers(context: Context, action: String): List<ResolveInfo> {
        return try {
            context.packageManager.queryBroadcastReceivers(Intent(action), 0)
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * Providers to try for the current launcher, generic broadcast first.
     *
     * The generic `BADGE_COUNT_UPDATE` broadcast comes first because that is
     * the path modern launchers implement (ShortcutBadger's `DefaultBadger`
     * is preferred over the Samsung provider for the same reason). The
     * launcher-specific provider is the fallback for devices where only that
     * proprietary API exists.
     */
    private fun providersFor(context: Context): List<BadgeProvider> {
        val specific = when (defaultLauncherPackage(context)) {
            "com.sec.android.app.launcher", "com.sec.android.app.twlauncher" -> listOf(
                SamsungAppsProvider, SamsungBadgeProvider
            )
            "com.huawei.android.launcher" -> listOf(HuaweiProvider)
            "com.sonymobile.home", "com.sonyericsson.home" -> listOf(SonyProvider)
            "com.teslacoilsw.launcher" -> listOf(NovaProvider)
            "com.oppo.launcher" -> listOf(OppoProvider)
            "com.vivo.launcher" -> listOf(VivoProvider)
            "com.htc.launcher" -> listOf(HtcProvider)
            "com.zte.launcher" -> listOf(ZteProvider)
            "com.asus.launcher" -> listOf(AsusProvider)
            "com.anddoes.launcher" -> listOf(ApexProvider)
            "com.dlto.atom.launcher" -> listOf(AdwProvider)
            else -> emptyList()
        }
        return listOf(DefaultBroadcastProvider) + specific
    }

    private interface BadgeProvider {
        val name: String
        fun isAvailable(context: Context): Boolean
        fun apply(context: Context, component: ComponentName, count: Int): Boolean
    }

    /**
     * The generic `BADGE_COUNT_UPDATE` broadcast.
     *
     * Answered by Nova, Apex, ADW, Solid, KISS, LaunchTime, LG and newer
     * Samsung One UI builds.
     */
    private object DefaultBroadcastProvider : BadgeProvider {
        override val name = "default-broadcast"

        override fun isAvailable(context: Context): Boolean =
            broadcastReceivers(context, ACTION_BADGE_COUNT_UPDATE).isNotEmpty()

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val intent = Intent(ACTION_BADGE_COUNT_UPDATE)
                .putExtra(EXTRA_BADGE_COUNT, count)
                .putExtra(EXTRA_PACKAGE_NAME, component.packageName)
                .putExtra(EXTRA_CLASS_NAME, component.className)
            val receivers = broadcastReceivers(context, intent.action ?: return false)
            var sent = false
            for (info in receivers) {
                val pkg = info.resolvePackageName ?: continue
                // Explicit broadcast: on Android 8+ an implicit one would not
                // reach a launcher that is not exported for it.
                context.sendBroadcast(Intent(intent).setPackage(pkg))
                sent = true
            }
            return sent
        }
    }

    /**
     * Samsung One UI (current): `content://com.sec.badge/apps`.
     */
    private object SamsungAppsProvider : BadgeProvider {
        override val name = "samsung-apps"

        private const val AUTHORITY = "com.sec.badge"
        private const val PATH = "content://com.sec.badge/apps?notify=true"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val resolver = context.contentResolver
            val uri = Uri.parse(PATH)
            var changed = false
            var entryFound = false
            resolver.query(
                uri, arrayOf("_id", "class"), "package=?", arrayOf(component.packageName), null
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getInt(0)
                    val cls = cursor.getString(1)
                    val values = ContentValues().apply { put("badgecount", count) }
                    if (resolver.update(uri, values, "_id=?", arrayOf(id.toString())) > 0) {
                        changed = true
                    }
                    if (cls == component.className) entryFound = true
                }
            }
            if (!entryFound) {
                val values = ContentValues().apply {
                    put("package", component.packageName)
                    put("class", component.className)
                    put("badgecount", count)
                }
                // A provider that accepted the row returns its URI; a null
                // result means the write was rejected, which must not be
                // reported as success.
                if (resolver.insert(uri, values) != null) changed = true
            }
            return changed
        }
    }

    /**
     * Samsung (legacy One UI / TouchWiz): `com.sec.android.provider.badge`.
     */
    private object SamsungBadgeProvider : BadgeProvider {
        override val name = "samsung-badge"

        private const val AUTHORITY = "com.sec.android.provider.badge"
        private const val PATH = "content://com.sec.android.provider.badge/count"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val extras = Bundle().apply {
                putInt(EXTRA_BADGE_COUNT, count)
                putString(EXTRA_PACKAGE_NAME, component.packageName)
            }
            return context.contentResolver.call(Uri.parse(PATH), "update", null, extras) != null
        }
    }

    /** Huawei EMUI: `com.huawei.android.launcher.settings/badge`. */
    private object HuaweiProvider : BadgeProvider {
        override val name = "huawei"

        private const val AUTHORITY = "com.huawei.android.launcher.settings"
        private const val PATH = "content://com.huawei.android.launcher.settings/badge/"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val extras = Bundle().apply {
                putString("package", component.packageName)
                putString("class", component.className)
                putInt("badgenumber", count)
            }
            return context.contentResolver
                .call(Uri.parse(PATH), "change_badge", null, extras) != null
        }
    }

    /** Sony Xperia: `com.sonymobile.home.resourceprovider/badge`. */
    private object SonyProvider : BadgeProvider {
        override val name = "sony"

        private const val AUTHORITY = "com.sonymobile.home.resourceprovider"
        private const val PATH = "content://com.sonymobile.home.resourceprovider/badge"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val values = ContentValues().apply {
                put("badge_count", count)
                put("package_name", component.packageName)
                put("activity_name", component.className)
            }
            return context.contentResolver.insert(Uri.parse(PATH), values) != null
        }
    }

    /** Nova Launcher: `com.teslacoilsw.notifier/unread_count`. */
    private object NovaProvider : BadgeProvider {
        override val name = "nova"

        private const val AUTHORITY = "com.teslacoilsw.notifier"
        private const val PATH = "content://com.teslacoilsw.notifier/unread_count"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val values = ContentValues().apply {
                put("tag", "${component.packageName}/${component.className}")
                put("count", count)
            }
            return context.contentResolver.insert(Uri.parse(PATH), values) != null
        }
    }

    /** OPPO ColorOS: `com.android.badge/badge`. */
    private object OppoProvider : BadgeProvider {
        override val name = "oppo"

        private const val AUTHORITY = "com.android.badge"
        private const val PATH = "content://com.android.badge/badge"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val extras = Bundle().apply { putInt("app_badge_count", count) }
            return context.contentResolver
                .call(Uri.parse(PATH), "setAppBadgeCount", null, extras) != null
        }
    }

    /** Vivo: `launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM`. */
    private object VivoProvider : BadgeProvider {
        override val name = "vivo"

        private const val ACTION = "launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM"

        override fun isAvailable(context: Context): Boolean {
            return broadcastReceivers(context, ACTION).isNotEmpty()
        }

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val intent = Intent(ACTION)
                .putExtra("packageName", component.packageName)
                .putExtra("className", component.className)
                .putExtra("notificationNum", count)
            val receivers = broadcastReceivers(context, intent.action ?: return false)
            var sent = false
            for (info in receivers) {
                val pkg = info.resolvePackageName ?: continue
                context.sendBroadcast(Intent(intent).setPackage(pkg))
                sent = true
            }
            return sent
        }
    }

    /** HTC Sense: `com.htc.launcher.action.SET_NOTIFICATION` + `UPDATE_SHORTCUT`. */
    private object HtcProvider : BadgeProvider {
        override val name = "htc"

        private const val ACTION_SET = "com.htc.launcher.action.SET_NOTIFICATION"
        private const val ACTION_UPDATE = "com.htc.launcher.action.UPDATE_SHORTCUT"

        override fun isAvailable(context: Context): Boolean {
            return broadcastReceivers(context, ACTION_SET).isNotEmpty() ||
                broadcastReceivers(context, ACTION_UPDATE).isNotEmpty()
        }

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val set = Intent(ACTION_SET)
                .putExtra("com.htc.launcher.extra.COMPONENT", component.flattenToShortString())
                .putExtra("com.htc.launcher.extra.COUNT", count)
            val update = Intent(ACTION_UPDATE)
                .putExtra("packagename", component.packageName)
                .putExtra("count", count)
            var sent = false
            for (intent in listOf(set, update)) {
                val action = intent.action ?: continue
                val receivers = broadcastReceivers(context, action)
                for (info in receivers) {
                    val pkg = info.resolvePackageName ?: continue
                    context.sendBroadcast(Intent(intent).setPackage(pkg))
                    sent = true
                }
            }
            return sent
        }
    }

    /** ZTE: `com.android.launcher3.cornermark.unreadbadge`. */
    private object ZteProvider : BadgeProvider {
        override val name = "zte"

        private const val AUTHORITY = "com.android.launcher3.cornermark.unreadbadge"
        private const val PATH = "content://com.android.launcher3.cornermark.unreadbadge"

        override fun isAvailable(context: Context): Boolean =
            context.packageManager.resolveContentProvider(AUTHORITY, 0) != null

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val extras = Bundle().apply {
                putInt("app_badge_count", count)
                putString("app_badge_component_name", component.flattenToString())
            }
            return context.contentResolver
                .call(Uri.parse(PATH), "setAppUnreadCount", null, extras) != null
        }
    }

    /** ASUS ZenUI: `com.asus.launcher.action.UPDATE_BADGE`. */
    private object AsusProvider : BadgeProvider {
        override val name = "asus"

        private const val ACTION = "com.asus.launcher.action.UPDATE_BADGE"

        override fun isAvailable(context: Context): Boolean {
            return broadcastReceivers(context, ACTION).isNotEmpty()
        }

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val intent = Intent(ACTION)
                .putExtra("badge_count", count)
                .putExtra("package_name", component.packageName)
                .putExtra("activity_name", component.className)
            val receivers = broadcastReceivers(context, intent.action ?: return false)
            var sent = false
            for (info in receivers) {
                val pkg = info.resolvePackageName ?: continue
                context.sendBroadcast(Intent(intent).setPackage(pkg))
                sent = true
            }
            return sent
        }
    }

    /** Apex Launcher: `com.anddoes.launcher.UPDATE_COUNT`. */
    private object ApexProvider : BadgeProvider {
        override val name = "apex"

        private const val ACTION = "com.anddoes.launcher.UPDATE_COUNT"

        override fun isAvailable(context: Context): Boolean {
            return broadcastReceivers(context, ACTION).isNotEmpty()
        }

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val intent = Intent(ACTION)
                .putExtra("badge_count", count)
                .putExtra("package_name", component.packageName)
                .putExtra("activity_name", component.className)
            val receivers = broadcastReceivers(context, intent.action ?: return false)
            var sent = false
            for (info in receivers) {
                val pkg = info.resolvePackageName ?: continue
                context.sendBroadcast(Intent(intent).setPackage(pkg))
                sent = true
            }
            return sent
        }
    }

    /** ADW Launcher: `com.dlto.atom.launcher.BADGE_COUNT_UPDATE`. */
    private object AdwProvider : BadgeProvider {
        override val name = "adw"

        private const val ACTION = "com.dlto.atom.launcher.BADGE_COUNT_UPDATE"

        override fun isAvailable(context: Context): Boolean {
            return broadcastReceivers(context, ACTION).isNotEmpty()
        }

        override fun apply(context: Context, component: ComponentName, count: Int): Boolean {
            val intent = Intent(ACTION)
                .putExtra("badge_count", count)
                .putExtra("package_name", component.packageName)
                .putExtra("activity_name", component.className)
            val receivers = broadcastReceivers(context, intent.action ?: return false)
            var sent = false
            for (info in receivers) {
                val pkg = info.resolvePackageName ?: continue
                context.sendBroadcast(Intent(intent).setPackage(pkg))
                sent = true
            }
            return sent
        }
    }

    /** Every provider, used by [clear] so no stale badge can survive a restart. */
    private val allProviders = listOf(
        DefaultBroadcastProvider,
        SamsungAppsProvider,
        SamsungBadgeProvider,
        HuaweiProvider,
        SonyProvider,
        NovaProvider,
        OppoProvider,
        VivoProvider,
        HtcProvider,
        ZteProvider,
        AsusProvider,
        ApexProvider,
        AdwProvider,
    )
}
