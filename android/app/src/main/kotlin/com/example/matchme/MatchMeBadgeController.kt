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
 *     Google's documented way to publish an explicit count ("you can override
 *     this number for your app ... useful if you're using just one
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
 * ## This notification is the ONLY one that may carry a number
 *
 * Launchers that render a numeric badge *sum* `EXTRA_NUMBER` over every
 * active notification. Posting the count here and also on the conversation
 * cards would therefore show twice the unread total. The cards deliberately
 * carry no number - see MobileLocalNotificationService.
 *
 * ## This notification is the group summary, not a standalone card
 *
 * It is posted as the summary of [GROUP_KEY_CHATS], the group the
 * conversation cards join, and only while at least one conversation card is
 * actually in the tray ([hasChatChildren]). While any chat card is up Android
 * renders the bundle and this summary is its header, so the user sees one
 * "2 unread" stack - never a chat card plus a silent, hard-to-explain
 * "MatchMe / 2 unread" card standing next to it.
 *
 * A summary with no children is drawn as a normal card, which is exactly the
 * noise this gate prevents. So when the last conversation card goes away the
 * carrier goes with it ([syncCarrierPresence]): immediately through the
 * delete intent every native card carries, and within a heartbeat for cards
 * posted through flutter_local_notifications (that plugin has no delete
 * intent). The OEM launcher badge APIs above are unaffected - their number
 * keeps tracking the unread inbox even when no card is up.
 */
object MatchMeBadgeController {
    const val CHANNEL_ID = "matchme_badge"

    /**
     * Notification group holding the per-conversation cards.
     *
     * Mirrored by `NotificationGroups.chats` in
     * lib/utils/notification_channels.dart and by the group the native
     * background service posts its cards with; keep all three in sync.
     */
    const val GROUP_KEY_CHATS = "matchme_chats"

    /** Fixed id so every update replaces the previous carrier instead of stacking. */
    private const val NOTIFICATION_ID = 0x4D42

    /** Sent by a conversation card's delete intent when the user dismisses it. */
    const val ACTION_CHAT_CARD_DISMISSED =
        "com.example.matchme.action.CHAT_CARD_DISMISSED"

    /**
     * Tag of the carrier notification.
     *
     * Tagged so it has its own identity in the tray: the background service
     * cancels server cards by tag (`new_match_*` / `match_*`) and must never
     * mistake this one for a chat card - it is the group *summary*, so being
     * cancelled with the cards would take the badge with it.
     */
    private const val NOTIFICATION_TAG = "matchme_badge"

    /**
     * Last published count and tray text.
     *
     * Only so [syncCarrierPresence] can re-post a carrier that went missing
     * (a card posted after the badge sync would otherwise leave the number
     * unpublished until the next inbox change). Not secret: a count and the
     * localized "N unread" line.
     */
    private const val PREFS_NAME = "matchme_badge_carrier"
    private const val PREF_COUNT = "count"
    private const val PREF_BODY = "body"

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
        remember(appContext, count, body)
        if (hasChatChildren(appContext)) {
            postCarrier(appContext, count, body)
        } else {
            // A summary without children is a standalone card, which is the
            // one thing this notification must never be.
            clearCarrier(appContext)
        }
    }

    /**
     * Makes the tray match the gate: no children, no carrier; children but no
     * carrier, post the last known one.
     *
     * Called from the cards' delete intent and from the background service
     * heartbeat (the flutter_local_notifications plugin has no delete intent).
     */
    fun syncCarrierPresence(context: Context) {
        val appContext = context.applicationContext
        val tray = scanTray(appContext) ?: return
        if (!tray.hasChildren) {
            clearCarrier(appContext)
            return
        }
        if (tray.hasCarrier) return
        val count = cachedCount(appContext)
        if (count <= 0) return
        postCarrier(appContext, count, cachedBody(appContext))
    }

    /**
     * True while at least one conversation card is in the tray.
     *
     * Only the group's children count - the carrier itself is excluded by
     * identity, or it would keep itself alive.
     */
    fun hasChatChildren(context: Context): Boolean {
        // getActiveNotifications() needs M; older releases keep the old
        // always-visible carrier because the tray cannot be inspected.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        // Fail open: a badge without a summary beats no badge at all.
        return scanTray(context)?.hasChildren ?: true
    }

    private class TrayState(val hasChildren: Boolean, val hasCarrier: Boolean)

    /** `null` when the tray cannot be inspected (pre-M or a binder failure). */
    private fun scanTray(context: Context): TrayState? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return null
        return try {
            var hasChildren = false
            var hasCarrier = false
            manager(context.applicationContext).activeNotifications.forEach { sbn ->
                if (sbn.tag == NOTIFICATION_TAG && sbn.id == NOTIFICATION_ID) {
                    hasCarrier = true
                } else if (sbn.notification.group == GROUP_KEY_CHATS) {
                    hasChildren = true
                }
            }
            TrayState(hasChildren, hasCarrier)
        } catch (_: Throwable) {
            null
        }
    }

    private fun remember(context: Context, count: Int, body: String?) {
        try {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putInt(PREF_COUNT, count)
                .putString(PREF_BODY, body)
                .apply()
        } catch (_: Throwable) {
        }
    }

    private fun cachedCount(context: Context): Int = try {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(PREF_COUNT, 0)
    } catch (_: Throwable) {
        0
    }

    private fun cachedBody(context: Context): String? = try {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PREF_BODY, null)
    } catch (_: Throwable) {
        null
    }

    /**
     * Delete intent for a conversation card, so dismissing it can take the
     * group summary with it once it was the last one.
     */
    fun deleteIntent(context: Context): PendingIntent? {
        return try {
            val appContext = context.applicationContext
            val intent = Intent(appContext, MatchMeBadgeCleanupReceiver::class.java).apply {
                action = ACTION_CHAT_CARD_DISMISSED
            }
            PendingIntent.getBroadcast(
                appContext,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } catch (_: Throwable) {
            null
        }
    }

    /** Removes the badge entirely: both the launcher badge and the carrier. */
    fun clear(context: Context) {
        val appContext = context.applicationContext
        remember(appContext, 0, null)
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
            // The badge number itself. Launchers that render numbers read it,
            // and this is the only notification allowed to carry one.
            .setNumber(count)
            // Summary of GROUP_KEY_CHATS, so it collapses into the chat bundle
            // whenever chat cards are up. (NotificationCompat has no
            // setGroup(key, isSummary) overload - the flag is its own call.)
            .setGroup(GROUP_KEY_CHATS)
            .setGroupSummary(true)
            // The conversation cards are the ones that may alert; a badge
            // carrier must never add noise of its own.
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            // Message category so the system keeps it in the conversation
            // space alongside the cards it summarizes.
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setAutoCancel(true)
            // No large icon is ever set, so make the touch-and-hold preview use
            // the status icon instead of rendering without one.
            .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
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
