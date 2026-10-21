package com.example.matchme

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Android app-icon badge.
 *
 * iOS has a global badge API (`UIApplication.applicationIconBadgeNumber`).
 * Android has none, so the count is published through two independent
 * channels at once:
 *
 *  1. A notification that carries `Notification.setNumber(count)`. This is
 *     Google's documented way to publish an explicit count ("you can
 *     override this number for your app ... useful if you're using just one
 *     notification to represent multiple new messages") and it is what the
 *     launchers that render a number read. Stock Pixel/AOSP renders a dot
 *     only - a launcher limitation no app can change.
 *  2. A launcher-specific badge API (Samsung, Huawei, Sony, OPPO, Vivo, HTC,
 *     Nova, ...). Those launchers ignore `setNumber` and only accept their
 *     own provider/broadcast. See [MatchMeOemBadge].
 *
 * Both carry the same value, so whichever mechanism a launcher honors shows
 * the correct count and they cannot disagree. The second one is best effort:
 * several OEM APIs cannot report failure, so it is never allowed to replace
 * the notification (a silently ignored OEM write would otherwise leave the
 * icon with no badge at all).
 *
 * The carrier notification is silent (IMPORTANCE_MIN, no sound, no
 * vibration, no heads-up): it is a badge, not a message.
 */
object MatchMeBadgeController {
    const val CHANNEL_ID = "matchme_badge"

    /** Fixed id so every update replaces the previous carrier instead of stacking. */
    private const val NOTIFICATION_ID = 0x4D42

    /**
     * Tag of the carrier notification.
     *
     * Tagged so it has its own identity in the tray: the background service
     * cancels server cards by tag (`new_match_*` / `match_*`) and must never
     * mistake this one for a chat card.
     */
    private const val NOTIFICATION_TAG = "matchme_badge"

    private fun manager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Unread badge",
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Keeps the app icon badge in sync with the unread count"
            setShowBadge(true)
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        // Idempotent: re-creating an existing channel updates its mutable
        // properties (showBadge in particular), it never resets the user's
        // own channel settings.
        manager(context).createNotificationChannel(channel)
    }

    /**
     * Opens the app when the carrier is tapped.
     *
     * Without a content intent the tray entry is inert, which reads as a
     * broken notification to the user.
     */
    private fun launchIntent(context: Context): PendingIntent? {
        return try {
            val intent = context.packageManager
                .getLaunchIntentForPackage(context.packageName) ?: return null
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            PendingIntent.getActivity(context, 0, intent, flags)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Publishes [count] as the app-icon badge.
     *
     * [body] is the localized text shown under the app name in the tray; it
     * is informational only and does not affect the badge number.
     */
    fun applyCount(context: Context, count: Int, body: String?) {
        val appContext = context.applicationContext
        if (count <= 0) {
            clear(appContext)
            return
        }
        // Best effort: launchers that ignore `setNumber` only read their own
        // badge API. A failure here is expected on most devices and is not
        // allowed to suppress the notification carrier.
        MatchMeOemBadge.apply(appContext, count)
        postCarrier(appContext, count, body)
    }

    /** Removes the badge entirely: both the launcher badge and the carrier. */
    fun clear(context: Context) {
        val appContext = context.applicationContext
        MatchMeOemBadge.clear(appContext)
        clearCarrier(appContext)
    }

    /**
     * Posts the notification that carries the count.
     *
     * One dedicated notification on a channel of its own, so the published
     * number is unambiguous: a launcher can never end up adding two different
     * numbers together.
     */
    private fun postCarrier(context: Context, count: Int, body: String?) {
        val appContext = context.applicationContext
        if (!canPostNotifications(appContext)) return
        ensureChannel(appContext)

        val label = try {
            appContext.applicationInfo.loadLabel(appContext.packageManager).toString()
        } catch (_: Throwable) {
            "MatchMe"
        }
        val text = body?.trim().orEmpty().ifEmpty { count.toString() }

        val builder = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_matchme)
            .setContentTitle(label)
            .setContentText(text)
            // The badge number itself. Launchers that render numbers read it.
            .setNumber(count)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setAutoCancel(true)
            // Silent on every supported release: the channel governs Android
            // 8+, these flags keep Android 7 quiet too.
            .setSilent(true)
        launchIntent(appContext)?.let { builder.setContentIntent(it) }
        val notification = builder.build()

        manager(appContext).notify(NOTIFICATION_TAG, NOTIFICATION_ID, notification)
    }

    /** Removes the notification carrier, if it is posted. */
    private fun clearCarrier(context: Context) {
        manager(context.applicationContext).cancel(NOTIFICATION_TAG, NOTIFICATION_ID)
    }
}
