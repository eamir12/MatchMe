package com.example.matchme

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Removes the badge carrier once the last conversation card is gone.
 *
 * Every card the app builds itself sets this receiver as its delete intent;
 * cards posted through flutter_local_notifications cannot carry one, so those
 * are swept by MatchMeBackgroundService's heartbeat instead.
 */
class MatchMeBadgeCleanupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != MatchMeBadgeController.ACTION_CHAT_CARD_DISMISSED) return
        val appContext = context.applicationContext
        // "Clear all" and per-card swipes fire this while the tray is still
        // updating, so let the dismissals settle before deciding.
        val pending = goAsync()
        Handler(Looper.getMainLooper()).postDelayed(
            {
                try {
                    MatchMeBadgeController.syncCarrierPresence(appContext)
                } catch (_: Throwable) {
                } finally {
                    pending.finish()
                }
            },
            500L,
        )
    }
}
