package com.baseflow.geolocator

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class MatchMeBootReceiver : BroadcastReceiver() {
    companion object {
        private const val PERIODIC_LOCATION_WORK_NAME = "MatchMePeriodicLocation"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != Intent.ACTION_USER_UNLOCKED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        // Always schedule the WorkManager fallback for recovery, regardless of
        // whether we start the service now. This covers cases where the device
        // wakes from Doze or the service was killed by OOM after BOOT_COMPLETED.
        schedulePeriodicFallback(context)

        // Plain prefs for non-sensitive flags; sensitive auth/location keys via
        // SecurePrefsHelper (encrypted first, plain fallback for migration).
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        val wasLoggedIn = prefs.getBoolean("flutter.was_logged_in", false)
        val userId = SecurePrefsHelper.getString(context, "flutter.user_id", null)
        val supabaseUrl = prefs.getString("flutter.supabase_url", null)
        val supabaseKey = prefs.getString("flutter.supabase_key", null)
        val isVisible = prefs.getBoolean("flutter.manual_visibility", true)
        val backgroundMatchingMode = prefs.getBoolean("flutter.background_matching_mode", false)
        val refreshToken = SecurePrefsHelper.getString(context, "flutter.refresh_token", null)
        val userToken = SecurePrefsHelper.getString(context, "flutter.user_token", null)
        val activeShareMatchId = SecurePrefsHelper.getString(context, "flutter.location_share_match_id", null)
        val activeShareKey = SecurePrefsHelper.getString(context, "flutter.location_share_session_key", null)
        // Restore user's preferred GPS rate and throttling so reboot respects Settings even before UI launch
        val gpsInterval = when {
            prefs.contains("flutter.gps_interval") -> prefs.getInt("flutter.gps_interval", 5)
            prefs.contains("gps_interval") -> prefs.getInt("gps_interval", 5)
            else -> 5
        }.coerceAtLeast(1)
        val smartThrottlingEnabled = when {
            prefs.contains("flutter.smart_throttling_enabled") -> prefs.getBoolean("flutter.smart_throttling_enabled", true)
            prefs.contains("smart_throttling_enabled") -> prefs.getBoolean("smart_throttling_enabled", true)
            else -> true
        }

        if (!wasLoggedIn || userId.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) {
            return
        }

        // LOCKED_BOOT_COMPLETED fires before user unlocks credential-encrypted
        // storage. Flutter/SharedPreferences are stored in device-encrypted
        // storage (readable before unlock on FBE devices) but the native
        // service needs tokens that may still be unavailable. Start the
        // service only if either (a) the user already unlocked (received
        // USER_UNLOCKED or BOOT_COMPLETED after first unlock), or (b) we
        // need to resume an active live location share (the GPS icon must
        // come on as soon as possible, even before the user launches the app
        // — Android requires that foreground services be granted a 10 s
        // post-boot window to call startForeground()).
        if (action == Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            activeShareMatchId.isNullOrBlank() && activeShareKey.isNullOrBlank()) {
            // No active share to resume and user hasn't unlocked yet —
            // defer full service start to USER_UNLOCKED / first launch.
            return
        }

        // Avoid double-start when multiple boot/unlock broadcasts fire close
        // together (BOOT_COMPLETED, USER_UNLOCKED, MY_PACKAGE_REPLACED can all
        // arrive within seconds of each other on first unlock).
        val now = System.currentTimeMillis()
        val lastStartAt = prefs.getLong("boot_service_start_ms", 0L)
        if (now - lastStartAt < 30_000L) {
            return
        }

        // Write both long (native) and string/int (Dart SharedPreferences
        // reads longs unreliably) so Flutter boot-resync can detect reboot.
        prefs.edit().putLong("boot_service_start_ms", now).putString("boot_service_start_ms_str", now.toString()).apply()
        try {
            prefs.edit().putInt("flutter.boot_service_start_ms", (now / 1000L).toInt()).apply()
        } catch (_: Exception) {}

        val hasActiveShare =
            !activeShareMatchId.isNullOrBlank() && !activeShareKey.isNullOrBlank()

        // On Android 8+, the boot receiver must use startForegroundService() for
        // any background service start. If the service does not call
        // startForeground() within ~5 seconds of creation, Android raises
        // RemoteServiceException. So only start the service eagerly from the
        // boot broadcast if we know the service will immediately promote itself
        // to foreground (either there is an active live share to resume, or
        // background matching mode is on, or the user is visible and matching
        // should continue). When none of those apply, defer service start to
        // the next WorkManager periodic kick or the user launching the UI.
        val needsEagerStart = hasActiveShare || backgroundMatchingMode

        try {
            if (needsEagerStart && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val serviceIntent = buildServiceIntent(
                    context, userId, supabaseUrl, supabaseKey,
                    userToken, refreshToken, backgroundMatchingMode, isVisible,
                    gpsInterval, smartThrottlingEnabled,
                )
                context.startForegroundService(serviceIntent)
            } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                MatchMeBackgroundService.startService(
                    context, userId, supabaseUrl, supabaseKey,
                    userToken, refreshToken,
                    false, // appInForeground = false (boot path)
                    backgroundMatchingMode, isVisible, true,
                    gpsInterval, smartThrottlingEnabled,
                )
            } else {
                // Android 8+, no need for foreground service right now (user has
                // no active share and background matching is off). Skip the
                // direct service start; WorkManager periodic fallback will catch
                // any missed background-matching runs and the Flutter UI will
                // re-start the service normally on next launch.
            }
        } catch (e: Exception) {
            // WorkManager 15-minute fallback covers this failure case.
            schedulePeriodicFallback(context)
        }
    }

    /**
     * Builds the service Intent matching MatchMeBackgroundService.startService
     * extras shape. Explicitly used on Android 8+ where we must call
     * startForegroundService() directly from the boot receiver (startService()
     * raises IllegalStateException from a background context on API 26+).
     */
    private fun buildServiceIntent(
        context: Context,
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        refreshToken: String?,
        backgroundMatchingMode: Boolean,
        isVisible: Boolean,
        gpsInterval: Int = 5,
        smartThrottlingEnabled: Boolean = true,
    ): Intent {
        val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
            action = MatchMeBackgroundService.ACTION_START
            putExtra(MatchMeBackgroundService.EXTRA_USER_ID, userId)
            putExtra(MatchMeBackgroundService.EXTRA_SUPABASE_URL, supabaseUrl)
            putExtra(MatchMeBackgroundService.EXTRA_SUPABASE_KEY, supabaseKey)
            putExtra(MatchMeBackgroundService.EXTRA_USER_TOKEN, userToken)
            putExtra(MatchMeBackgroundService.EXTRA_REFRESH_TOKEN, refreshToken)
            putExtra(MatchMeBackgroundService.EXTRA_IS_VISIBLE, isVisible)
            putExtra(MatchMeBackgroundService.EXTRA_IS_ONLINE, true)
            putExtra(MatchMeBackgroundService.EXTRA_APP_IN_FOREGROUND, false)
            putExtra(MatchMeBackgroundService.EXTRA_BACKGROUND_MATCHING, backgroundMatchingMode)
            putExtra(MatchMeBackgroundService.EXTRA_GPS_INTERVAL, gpsInterval)
            putExtra(MatchMeBackgroundService.EXTRA_SMART_THROTTLING, smartThrottlingEnabled)
        }
        return intent
    }

    private fun schedulePeriodicFallback(context: Context) {
        try {
            val constraints = androidx.work.Constraints.Builder()
                .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
                .build()
            val workRequest = PeriodicWorkRequestBuilder<LocationWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .setInitialDelay(1, TimeUnit.MINUTES) // modern: don't wait 15m after boot – heartbeat needs 55s chain
                .addTag("matchme-periodic")
                .build()

            WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                PERIODIC_LOCATION_WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                workRequest
            )
            // Also enqueue immediate OneTime chain so first post-boot heartbeat is <61s even before Periodic fires
            try {
                val oneTime = androidx.work.OneTimeWorkRequestBuilder<LocationWorker>()
                    .setInitialDelay(30, TimeUnit.SECONDS)
                    .setConstraints(constraints)
                    // Seed slot A of the ping-pong chain and carry KEY_SLOT so the
                    // worker chains onward to slot B (LocationWorker.chainOneTimeHeartbeat).
                    .setInputData(androidx.work.workDataOf(LocationWorker.KEY_SLOT to LocationWorker.NAME_A))
                    .addTag(LocationWorker.TAG_HEARTBEAT)
                    .build()
                WorkManager.getInstance(context.applicationContext)
                    .enqueueUniqueWork(
                        LocationWorker.NAME_A,
                        androidx.work.ExistingWorkPolicy.KEEP,
                        oneTime
                    )
            } catch (_: Exception) {}
        } catch (e: Exception) {
        }
    }
}
