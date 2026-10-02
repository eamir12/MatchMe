package com.example.matchme

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class PinnedShortcutReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        try {
            val shortcutId = intent.getStringExtra("shortcut_id")
            // Log.d("MatchMePinnedShortcut", "Pinned shortcut result received. id=$shortcutId")

            val prefs = context.getSharedPreferences("matchme_prefs", Context.MODE_PRIVATE)
            prefs.edit()
                .putBoolean("pinned_shortcut_requested", true)
                .putLong("pinned_shortcut_confirmed_at", System.currentTimeMillis())
                .apply()
        } catch (e: Exception) {
            // Log.w("MatchMePinnedShortcut", "Failed handling pinned shortcut result: $e")
        }
    }
}
