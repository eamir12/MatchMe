package com.baseflow.geolocator

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MatchMeBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Log.d("MatchMeBootReceiver", "Device booted, checking if background service should start")

            // Check if user was logged in before reboot
            // This is a simplified implementation - in a real app you'd store this securely
            val prefs = context.getSharedPreferences("matchme_prefs", Context.MODE_PRIVATE)
            val wasLoggedIn = prefs.getBoolean("was_logged_in", false)
            val userId = prefs.getString("user_id", null)
            val supabaseUrl = prefs.getString("supabase_url", null)
            val supabaseKey = prefs.getString("supabase_key", null)

            if (wasLoggedIn && userId != null && supabaseUrl != null && supabaseKey != null) {
                Log.d("MatchMeBootReceiver", "Starting background service after boot")
                MatchMeBackgroundService.startService(context, userId, supabaseUrl, supabaseKey, null)
            }
        }
    }
}
