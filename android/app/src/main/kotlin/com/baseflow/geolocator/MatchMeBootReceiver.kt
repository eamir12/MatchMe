package com.baseflow.geolocator

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class MatchMeBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_USER_UNLOCKED) return

        Log.d("MatchMeBootReceiver", "Received $action, checking if background service should start")

        // Use standard SharedPreferences to match Flutter app's storage
        // Flutter uses "FlutterSharedPreferences" as the default filename
        // This ensures was_logged_in flag is consistent between Flutter and Android native
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        // Avoid double-start when both BOOT_COMPLETED and USER_UNLOCKED fire.
        val now = System.currentTimeMillis()
        val lastStartAt = prefs.getLong("boot_service_start_ms", 0L)
        if (now - lastStartAt < 30_000L) {
            Log.d("MatchMeBootReceiver", "Skipping service start (recently started ${now - lastStartAt}ms ago)")
            return
        }

        val wasLoggedIn = prefs.getBoolean("flutter.was_logged_in", false)
        val userId = prefs.getString("flutter.user_id", null)
        val supabaseUrl = prefs.getString("flutter.supabase_url", null)
        val supabaseKey = prefs.getString("flutter.supabase_key", null)
        val isVisible = prefs.getBoolean("flutter.manual_visibility", true)
        val highAccuracyMode = prefs.getBoolean("flutter.high_accuracy_mode", false)
        val refreshToken = prefs.getString("flutter.refresh_token", null)
        val userToken = prefs.getString("flutter.user_token", null)

        if (wasLoggedIn && !userId.isNullOrBlank() && !supabaseUrl.isNullOrBlank() && !supabaseKey.isNullOrBlank()) {
            prefs.edit().putLong("boot_service_start_ms", now).apply()
            Log.d("MatchMeBootReceiver", "Starting background service after $action (isVisible=$isVisible, highAccuracyMode=$highAccuracyMode)")
            // Pass stored access token when available so Realtime joins with auth (no token=null)
            MatchMeBackgroundService.startService(context, userId!!, supabaseUrl!!, supabaseKey!!, userToken, refreshToken, false, highAccuracyMode, isVisible, true)
        } else {
            Log.d(
                "MatchMeBootReceiver",
                "Not starting service: wasLoggedIn=$wasLoggedIn userIdPresent=${!userId.isNullOrBlank()} urlPresent=${!supabaseUrl.isNullOrBlank()} keyPresent=${!supabaseKey.isNullOrBlank()}"
            )
        }
    }
}
