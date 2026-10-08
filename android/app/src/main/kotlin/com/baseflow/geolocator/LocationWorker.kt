package com.baseflow.geolocator

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.location.Location
import android.os.BatteryManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.tasks.await
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.util.concurrent.TimeUnit

class LocationWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    private val TAG = "LocationWorker"
    private var lastTransientLocationFailureLogAt: Long = 0
    private var suppressedTransientLocationFailureCount: Int = 0
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun getPrefs(): SharedPreferences {
        // Use standard SharedPreferences to match Flutter app's storage
        // Flutter uses "FlutterSharedPreferences" as the default filename
        // This ensures consistency between Flutter and Android native code
        return applicationContext.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    }

    // True when the server FCM push for this match is already in the tray
    // (push-message tags match pushes "new_match_<matchId>"). Mirrors the
    // foreground service check so the WorkManager fallback never stacks a
    // second, hardcoded-English card on top of the server's localized one.
    private fun isMatchPushInTray(matchId: String): Boolean {
        if (matchId.isBlank()) return false
        return try {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            val tag = "new_match_$matchId"
            nm?.activeNotifications?.any { sbn -> sbn.tag == tag } ?: false
        } catch (_: Exception) {
            false
        }
    }

    // Sensitive keys are read through SecurePrefsHelper (encrypted-first,
    // legacy plain fallback) so tokens never sit in plaintext at rest.
    private fun sensitiveRead(primaryKey: String, fallbackKey: String): String? {
        val primary = SecurePrefsHelper.getString(applicationContext, primaryKey, null)
        if (!primary.isNullOrBlank()) return primary
        val fallback = SecurePrefsHelper.getString(applicationContext, fallbackKey, null)
        if (!fallback.isNullOrBlank()) return fallback
        val p = getPrefs().getString(primaryKey, null)
        if (!p.isNullOrBlank()) return p
        val f = getPrefs().getString(fallbackKey, null)
        return if (f.isNullOrBlank()) null else f
    }

    override suspend fun doWork(): Result {
        // Never let an unexpected throw kill the heartbeat chain silently.
        // A transient failure (e.g. right after BOOT_COMPLETED the Keystore
        // is not unlocked yet and EncryptedSharedPreferences cannot decrypt)
        // must retry with WorkManager backoff instead of failing — a failed
        // chain leaves the user showing offline once the FG service dies.
        return try {
            doWorkInner()
        } catch (_: Exception) {
            if (runAttemptCount < MAX_TRANSIENT_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    private suspend fun doWorkInner(): Result {
        // Log.d(TAG, "Starting periodic location update work")

        // 1. Load credentials and settings
        val securePrefs = getPrefs()

        fun readString(primaryKey: String, fallbackKey: String): String? {
            val a = securePrefs.getString(primaryKey, null)
            if (!a.isNullOrBlank()) return a
            val b = securePrefs.getString(fallbackKey, null)
            return if (b.isNullOrBlank()) null else b
        }

        fun readBool(primaryKey: String, fallbackKey: String, default: Boolean): Boolean {
            return if (securePrefs.contains(primaryKey)) securePrefs.getBoolean(primaryKey, default)
            else securePrefs.getBoolean(fallbackKey, default)
        }

        val userId = sensitiveRead("flutter.user_id", "user_id")
        val supabaseUrl = readString("flutter.supabase_url", "supabase_url")
        val supabaseKey = readString("flutter.supabase_key", "supabase_key")
        val userToken = sensitiveRead("flutter.user_token", "user_token")
        val backgroundMatchingMode = readBool("flutter.background_matching_mode", "high_accuracy_mode", true)
        val isVisible = readBool("flutter.manual_visibility", "manual_visibility", true)
        val isOnline = readBool("flutter.is_online", "is_online", true)

        // Write timestamp immediately to indicate WorkManager is running and network is believed connected
        // This happens before any early returns, so Flutter can use this as evidence of connectivity
        securePrefs.edit().putString("flutter.workmanager_last_success_ms", System.currentTimeMillis().toString()).apply()
        // Read user's Settings rate and throttling flag - canonical flutter.* key first, legacy fallback
        val gpsIntervalSeconds = run {
            val v = if (securePrefs.contains("flutter.gps_interval")) securePrefs.getInt("flutter.gps_interval", 5)
            else securePrefs.getInt("gps_interval", 5)
            v.coerceAtLeast(1)
        }
        val smartThrottlingEnabled = run {
            if (securePrefs.contains("flutter.smart_throttling_enabled")) securePrefs.getBoolean("flutter.smart_throttling_enabled", true)
            else securePrefs.getBoolean("smart_throttling_enabled", true)
        }
        // Helper to check battery low throttling - matches MatchMeBackgroundService logic
        fun isBatteryLowThrottled(): Boolean {
            if (!smartThrottlingEnabled) return false
            return try {
                val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
                val batt = applicationContext.registerReceiver(null, filter) ?: return false
                val level = batt.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = batt.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                val status = batt.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                val plugged = batt.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
                val charging = plugged != 0 || status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                if (charging) return false
                val pct = if (level >= 0 && scale > 0) (level * 100) / scale else return false
                pct < 15
            } catch (_: Exception) { false }
        }
        fun isStationaryFromPrefs(): Boolean {
            if (!smartThrottlingEnabled) return false
            return try {
                val jsonStr = securePrefs.getString("flutter.recent_locations_json", null)
                    ?: securePrefs.getString("recent_locations_json", null) ?: return false
                if (jsonStr.isBlank()) return false
                val arr = org.json.JSONArray(jsonStr)
                if (arr.length() < 5) return false
                val first = arr.getJSONObject(0)
                val firstLat = first.getDouble("lat")
                val firstLng = first.getDouble("lng")
                val firstLoc = Location("persisted").apply { latitude = firstLat; longitude = firstLng }
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    val loc = Location("persisted").apply { latitude = o.getDouble("lat"); longitude = o.getDouble("lng") }
                    // Skip stale entries >30 min - same window as service
                    val t = o.optLong("time", 0L)
                    if (t != 0L && System.currentTimeMillis() - t > 30 * 60 * 1000L) return false
                    if (loc.distanceTo(firstLoc) > 10.0) return false
                }
                true
            } catch (_: Exception) { false }
        }
        fun persistWorkerLocation(loc: Location) {
            try {
                val existingStr = securePrefs.getString("flutter.recent_locations_json", null)
                val arr = if (existingStr.isNullOrBlank()) org.json.JSONArray() else org.json.JSONArray(existingStr)
                val obj = org.json.JSONObject()
                obj.put("lat", loc.latitude)
                obj.put("lng", loc.longitude)
                obj.put("acc", loc.accuracy.toDouble())
                obj.put("time", loc.time)
                arr.put(obj)
                while (arr.length() > 5) arr.remove(0)
                securePrefs.edit().putString("flutter.recent_locations_json", arr.toString()).apply()
            } catch (_: Exception) {}
        }
        // Chain a follow-up OneTime heartbeat when FG is dead & bgMatching ON so we
        // don't wait 15m (periodic minimum) for the next online ping (61s window).
        // Respect user's Settings rate + smart throttling (battery low -> 60s, stationary -> 60s), but cap at 60s
        // so online heartbeat never exceeds 61s window.
        fun effectiveIntervalSeconds(): Int {
            var interval = gpsIntervalSeconds
            // Battery-aware throttling: when smart throttling enabled and battery <15% not charging -> 60s
            if (isBatteryLowThrottled()) {
                interval = maxOf(interval, 60)
            }
            if (isStationaryFromPrefs()) {
                interval = maxOf(interval, 60)
            }
            return interval
        }
        fun chainOneTimeHeartbeat() {
            try {
                val effective = effectiveIntervalSeconds().coerceAtLeast(1)
                val delaySeconds = effective.coerceAtMost(55).toLong() // 55s < 61s window + 6s jitter/Doze
                // Ping-pong between two unique names instead of REPLACE-ing a single
                // name. REPLACE on the name this worker is currently running under
                // cancels this very worker mid-flight, which WorkManager surfaces as a
                // WorkerStoppedException stack trace and which discards the Result of
                // any in-flight heartbeat/location request.
                //
                // Enqueueing onto the *other* name means the successor can never
                // collide with the currently-running worker. KEEP is then safe: if the
                // other slot already holds a pending link the chain is already alive,
                // so skipping the insert loses nothing and never cancels anything.
                val nextName = if (inputData.getString(KEY_SLOT) == NAME_A) NAME_B else NAME_A
                val next = OneTimeWorkRequestBuilder<LocationWorker>()
                    .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                    .setInputData(workDataOf(KEY_SLOT to nextName))
                    .addTag(TAG_HEARTBEAT)
                    .build()
                WorkManager.getInstance(applicationContext)
                    .enqueueUniqueWork(nextName, ExistingWorkPolicy.KEEP, next)
            } catch (_: Exception) {}
        }

        if (userId == null || supabaseUrl == null || supabaseKey == null) {
            // Log.w(TAG, "Missing credentials, skipping work")
            // Post-reboot the Keystore may take minutes to become readable;
            // retry with backoff so the chain self-heals. A hard failure here
            // silently kills the heartbeat until the app is reopened.
            return if (runAttemptCount < MAX_TRANSIENT_ATTEMPTS) {
                Result.retry()
            } else {
                Result.failure()
            }
        }

        // Retro Matching: headlessly upload offline-trail points the
        // background service recorded while the app UI was closed. Runs on
        // every worker cycle with connectivity, so places upload without the
        // Flutter engine ever being started. Failures keep the buffer for
        // the next cycle (and the Dart merge/upload remains a fallback).
        if (OfflineTrailUploader.isRetroOfflineTrailEnabled(applicationContext)) {
            try {
                OfflineTrailUploader.upload(
                    applicationContext,
                    userId,
                    supabaseUrl,
                    supabaseKey,
                    userToken,
                    httpClient,
                )
            } catch (_: Exception) {}
        }

        // Notification safety net: when the foreground service is dead
        // (killed / reboot / Doze / FCM token stale / data-only throttled),
        // WorkManager is the only keeper. Poll the same
        // check_unread_notifications RPC the FG service uses and post a
        // native tray notification so chat/match fire no matter the UI state.
        // Runs even when invisible/offline or pinned — messages still matter.
        try {
            if (!isMatchMeBackgroundServiceRunning()) {
                checkAndNotifyFallback(
                    userId, supabaseUrl, supabaseKey, userToken, securePrefs,
                )
            }
        } catch (_: Exception) {}

        // Pinned home-base (written by Flutter): no GPS access, heartbeat only.
        // Keys mirror PinnedLocationGate in Dart.
        val pinnedActive = try {
            if (!securePrefs.getBoolean("flutter.pinned_location_active", false)) false
            else {
                val expMs = try {
                    securePrefs.getLong("flutter.pinned_location_expires_at_ms", 0L)
                } catch (_: Exception) {
                    securePrefs.getInt("flutter.pinned_location_expires_at_ms", 0).toLong()
                }
                expMs > System.currentTimeMillis()
            }
        } catch (_: Exception) { false }
        if (pinnedActive) {
            try { updateUserActivity(userId, supabaseUrl, supabaseKey, userToken, securePrefs) } catch (_: Exception) {}
            chainOneTimeHeartbeat()
            return Result.success()
        }

        if (!isOnline) {
            // Truly offline (no transport): a heartbeat cannot succeed, skip.
            return Result.success()
        }

        if (!isVisible) {
            // Invisible means hidden, NOT offline: the online count counts all
            // logged-in users regardless of visibility, so keep is_online /
            // last_activity fresh with a heartbeat-only ping. Never touch GPS
            // or location upload here (mirrors the pinned path above).
            try { updateUserActivity(userId, supabaseUrl, supabaseKey, userToken, securePrefs) } catch (_: Exception) {}
            chainOneTimeHeartbeat()
            return Result.success()
        }

        // If Background Matching Mode is ON but the Foreground Service is dead
        // (killed by Doze / swipe / crash), the worker is the last resort to
        // keep is_online / last_activity fresh inside the 61s window.
        // Previously we bailed here and the user went offline ~60s after
        // screen-off until the UI resumed. Now we keep a lightweight
        // update_user_activity heartbeat even without a GPS fix.
        val fgAlive = isMatchMeBackgroundServiceRunning()
        if (fgAlive) {
            // Service alive already polls GPS + heartbeat; avoid duplicate GPS.
            // But keep the OneTime chain alive so kill after this worker still heartbeats <61s.
            // Modern OEMs (Xiaomi/Samsung) defer Periodic 15m to hours – chain is the real keep-alive.
            chainOneTimeHeartbeat()
            return Result.success()
        }
        // Service dead: WorkManager is the only keeper. Must heartbeat even if bg=OFF for visible users,
        // and must keep location fresh for is_user_truly_visible 15m. Use expedited path.
        try {
            val fusedLocationClient = LocationServices.getFusedLocationProviderClient(applicationContext)
            val location = fusedLocationClient.getCurrentLocation(
                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                null
            ).await()
            if (location != null) {
                try { persistWorkerLocation(location) } catch (_: Exception) {}
                updateLocationInSupabase(userId, supabaseUrl, supabaseKey, userToken, location, securePrefs)
            }
        } catch (_: Exception) {}
        updateUserActivity(userId, supabaseUrl, supabaseKey, userToken, securePrefs)
        chainOneTimeHeartbeat()
        return Result.success()

        // 2. Get Location
        try {
            val fusedLocationClient = LocationServices.getFusedLocationProviderClient(applicationContext)
            
            // Use PRIORITY_BALANCED_POWER_ACCURACY for periodic updates to save battery
            val location = fusedLocationClient.getCurrentLocation(
                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                null
            ).await()

            if (location != null) {
                // Log.d(TAG, "Got location: ${location.latitude}, ${location.longitude}")

                // 3. Send to Supabase
                updateLocationInSupabase(userId, supabaseUrl, supabaseKey, userToken, location, securePrefs)

                // 4. Update user activity to keep online status current (fixes nearby count issue in Standard Mode)
                updateUserActivity(userId, supabaseUrl, supabaseKey, userToken, securePrefs)

                // 5. Trigger Match Engine
                triggerMatchEngine(userId, supabaseUrl, supabaseKey, userToken, location)
            } else {
                // Log.w(TAG, "Failed to get location (null)")
            }

        } catch (e: SecurityException) {
            // Log.e(TAG, "Missing location permissions", e)
            return Result.failure()
        } catch (e: Exception) {
            // Log.e(TAG, "Error getting location", e)
            return Result.retry()
        }

        return Result.success()
    }

    private fun isRetroOfflineTrailEnabled(): Boolean {
        return OfflineTrailUploader.isRetroOfflineTrailEnabled(applicationContext)
    }

    private fun checkAndNotifyFallback(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        prefs: SharedPreferences,
    ) {
        try {
            val url = "$supabaseUrl/rest/v1/rpc/check_unread_notifications"
            val jsonBody = JSONObject().apply { put("p_user_id", userId) }
            val body = jsonBody.toString().toRequestBody("application/json".toMediaType())
            val reqBuilder = Request.Builder()
                .url(url)
                .post(body)
                .addHeader("apikey", supabaseKey)
                .addHeader("Content-Type", "application/json")
            if (userToken != null) reqBuilder.addHeader("Authorization", "Bearer $userToken")
            else reqBuilder.addHeader("Authorization", "Bearer $supabaseKey")
            val resp = httpClient.newCall(reqBuilder.build()).execute()
            if (!resp.isSuccessful) { try { resp.close() } catch (_: Exception) {}; return }
            val raw = try { resp.body?.string() } catch (_: Exception) { null }
            try { resp.close() } catch (_: Exception) {}
            if (raw.isNullOrBlank()) return
            val arr = try { org.json.JSONArray(raw) } catch (_: Exception) { return }
            if (arr.length() == 0) return
            val data = arr.getJSONObject(0)
            val unreadMatches = data.optInt("unread_matches_count", 0)
            val unreadMessages = data.optInt("unread_messages_count", 0)
            if (unreadMatches <= 0 && unreadMessages <= 0) {
                try {
                    checkAdminFallback(userId, supabaseUrl, supabaseKey, userToken, prefs)
                } catch (_: Exception) {}
                return
            }

            val viewingChat = try {
                prefs.getString("flutter.viewing_chat_id", null)
                    ?: prefs.getString("viewing_chat_id", null)
            } catch (_: Exception) { null }

            if (unreadMatches > 0) {
                val matchName = data.optString("latest_match_name", "Someone")
                val matchId = data.optString("latest_match_id", "")
                if (matchId.isNotBlank()) {
                    // Canonical per-match dedup, shared with the foreground
                    // service (same key it reads/writes): one buzz per match
                    // per device, ever — across restarts and across the two
                    // paths. The legacy worker key is still consulted so
                    // matches buzzed before this upgrade don't re-buzz, but
                    // it is no longer written for matches: sharing one key
                    // with message dedup ("msg:*") let any chat activity wipe
                    // the match record and re-buzz old matches every run.
                    val alreadyBuzzed = try {
                        prefs.getString("flutter.last_notified_match_id", null) == matchId ||
                        prefs.getString("flutter.worker_last_notified_key", null) == "match:$matchId"
                    } catch (_: Exception) { false }
                    if (alreadyBuzzed) return
                    if (isMatchPushInTray(matchId)) {
                        // The server FCM push already displayed this match —
                        // share the service's dedup key so no path re-buzzes it.
                        try {
                            prefs.edit()
                                .putString("flutter.last_notified_match_id", matchId)
                                .putString("flutter.worker_last_notified_key", "match:$matchId")
                                .apply()
                        } catch (_: Exception) {}
                        return
                    }
                    try {
                        prefs.edit().putString("flutter.last_notified_match_id", matchId).apply()
                    } catch (_: Exception) {}
                    showFallbackNotification(
                        title = "New Match!",
                        content = "You matched with $matchName!",
                        notifyId = matchName.hashCode(),
                        matchId = matchId,
                    )
                    try {
                        checkAdminFallback(userId, supabaseUrl, supabaseKey, userToken, prefs)
                    } catch (_: Exception) {}
                    return
                }
                val dedupKey = "match:$matchName"
                val lastKey = try { prefs.getString("flutter.worker_last_notified_key", null) } catch (_: Exception) { null }
                if (dedupKey == lastKey) return
                try { prefs.edit().putString("flutter.worker_last_notified_key", dedupKey).apply() } catch (_: Exception) {}
                showFallbackNotification(
                    title = "New Match!",
                    content = "You matched with $matchName!",
                    notifyId = matchName.hashCode(),
                    matchId = null,
                )
                try {
                    checkAdminFallback(userId, supabaseUrl, supabaseKey, userToken, prefs)
                } catch (_: Exception) {}
                return
            }

            // unreadMessages > 0
            val sender = data.optString("latest_message_sender", "Someone")
            val content = data.optString("latest_message_content", "Sent a message")
            val messageId = data.optString("latest_message_id", "")
            val matchId = data.optString("latest_match_id", "")
            if (messageId.isBlank()) return
            val lastMsg = try { prefs.getString("flutter.worker_last_notified_key", null) } catch (_: Exception) { null }
            if ("msg:$messageId" == lastMsg) return
            // Suppress only when the user is actively viewing THIS chat.
            if (matchId.isNotBlank() && viewingChat != null && viewingChat == matchId) return
            try { prefs.edit().putString("flutter.worker_last_notified_key", "msg:$messageId").apply() } catch (_: Exception) {}
            showFallbackNotification(
                title = sender.ifBlank { "New message" },
                content = content.ifBlank { "Sent a message" },
                notifyId = (if (matchId.isNotBlank()) matchId else sender).hashCode(),
                matchId = matchId.ifBlank { null },
            )
            // Fall through to admin check (a device can have both).
            try {
                checkAdminFallback(userId, supabaseUrl, supabaseKey, userToken, prefs)
            } catch (_: Exception) {}
            return
        } catch (_: Exception) {}
        // No unread chat/match — still check admin broadcasts (FCM token may
        // be stale while WorkManager still runs post-reboot/killed).
        try {
            checkAdminFallback(userId, supabaseUrl, supabaseKey, userToken, prefs)
        } catch (_: Exception) {}
    }

    private fun checkAdminFallback(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        prefs: SharedPreferences,
    ) {
        try {
            // Latest pending delivery for this user (RLS: user can read own rows).
            val deliveriesUrl = "$supabaseUrl/rest/v1/admin_broadcast_deliveries" +
                "?user_id=eq.$userId&delivery_status=eq.pending&order=created_at.desc&limit=1" +
                "&select=broadcast_id,created_at"
            val getReq = Request.Builder()
                .url(deliveriesUrl)
                .get()
                .addHeader("apikey", supabaseKey)
                .addHeader("Content-Type", "application/json")
            if (userToken != null) getReq.addHeader("Authorization", "Bearer $userToken")
            else getReq.addHeader("Authorization", "Bearer $supabaseKey")
            val getResp = httpClient.newCall(getReq.build()).execute()
            if (!getResp.isSuccessful) { try { getResp.close() } catch (_: Exception) {}; return }
            val rawList = try { getResp.body?.string() } catch (_: Exception) { null }
            try { getResp.close() } catch (_: Exception) {}
            if (rawList.isNullOrBlank()) return
            val arr = try { org.json.JSONArray(rawList) } catch (_: Exception) { return }
            if (arr.length() == 0) return
            val broadcastId = arr.getJSONObject(0).optString("broadcast_id", "")
            if (broadcastId.isBlank()) return
            val lastAdmin = try { prefs.getString("flutter.worker_last_admin_id", null) } catch (_: Exception) { null }
            if (broadcastId == lastAdmin) return
            // Fetch broadcast copy (RLS: sent broadcasts readable).
            val bUrl = "$supabaseUrl/rest/v1/admin_broadcasts?id=eq.$broadcastId&select=title,message"
            val bReq = Request.Builder()
                .url(bUrl)
                .get()
                .addHeader("apikey", supabaseKey)
            if (userToken != null) bReq.addHeader("Authorization", "Bearer $userToken")
            else bReq.addHeader("Authorization", "Bearer $supabaseKey")
            val bResp = httpClient.newCall(bReq.build()).execute()
            if (!bResp.isSuccessful) { try { bResp.close() } catch (_: Exception) {}; return }
            val bRaw = try { bResp.body?.string() } catch (_: Exception) { null }
            try { bResp.close() } catch (_: Exception) {}
            if (bRaw.isNullOrBlank()) return
            val bArr = try { org.json.JSONArray(bRaw) } catch (_: Exception) { return }
            if (bArr.length() == 0) return
            val title = bArr.getJSONObject(0).optString("title", "Admin Message").ifBlank { "Admin Message" }
            val message = bArr.getJSONObject(0).optString("message", "")
            try { prefs.edit().putString("flutter.worker_last_admin_id", broadcastId).apply() } catch (_: Exception) {}
            showFallbackNotification(
                title = title,
                content = message.ifBlank { "New announcement" },
                notifyId = broadcastId.hashCode(),
                matchId = null,
                channelId = "admin_broadcasts",
                channelName = "Admin Broadcasts",
            )
        } catch (_: Exception) {}
    }

    private fun showFallbackNotification(
        title: String,
        content: String,
        notifyId: Int,
        matchId: String?,
        channelId: String = "chat_messages",
        channelName: String = "Chat Messages",
    ) {
        try {
            val nm = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    if (nm.getNotificationChannel(channelId) == null) {
                        nm.createNotificationChannel(
                            NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH)
                        )
                    }
                } catch (_: Exception) {}
            }
            val safeMatchId = matchId?.trim().orEmpty()
            val intent = applicationContext.packageManager.getLaunchIntentForPackage(applicationContext.packageName)?.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                if (safeMatchId.isNotEmpty()) {
                    putExtra("route", "/chat/$safeMatchId")
                    putExtra("matchId", safeMatchId)
                }
            }
            val pi = if (intent != null) {
                PendingIntent.getActivity(
                    applicationContext,
                    if (safeMatchId.isNotEmpty()) safeMatchId.hashCode() else notifyId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            } else null
            val iconId = try {
                applicationContext.resources.getIdentifier("ic_stat_matchme", "drawable", applicationContext.packageName)
            } catch (_: Exception) { 0 }
            val validIcon = if (iconId != 0) iconId else android.R.drawable.ic_popup_reminder
            val color = try { ContextCompat.getColor(applicationContext, applicationContext.resources.getIdentifier("notification_accent", "color", applicationContext.packageName)) } catch (_: Exception) { 0 }
            val builder = NotificationCompat.Builder(applicationContext, channelId)
                .setSmallIcon(validIcon)
                .setContentTitle(title.ifBlank { "MatchMe" })
                .setContentText(content.ifBlank { "New message" })
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setContentIntent(pi)
            try { if (color != 0) builder.setColor(color) } catch (_: Exception) {}
            nm.notify(notifyId, builder.build())
        } catch (_: Exception) {}
    }

    private fun isMatchMeBackgroundServiceRunning(): Boolean {
        return try {
            val am = applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
            @Suppress("DEPRECATION")
            val services = am.getRunningServices(Int.MAX_VALUE)
            services.any { it.service.className == MatchMeBackgroundService::class.java.name }
        } catch (e: Exception) {
            false
        }
    }

    private fun updateLocationInSupabase(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        location: Location,
        securePrefs: SharedPreferences
    ) {
        val url = "$supabaseUrl/rest/v1/rpc/update_user_location"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
            put("p_latitude", location.latitude)
            put("p_longitude", location.longitude)
            put("p_speed", location.speed)
            put("p_heading", location.bearing)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())
        val requestBuilder = Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey)
            .addHeader("Content-Type", "application/json")

        if (userToken != null) {
            requestBuilder.addHeader("Authorization", "Bearer $userToken")
        } else {
            requestBuilder.addHeader("Authorization", "Bearer $supabaseKey")
        }

        try {
            val response = httpClient.newCall(requestBuilder.build()).execute()
            if (!response.isSuccessful) {
                // Log.e(TAG, "Failed to update location: ${response.code}")
            } else {
                // Log.d(TAG, "Successfully updated location in Supabase")
                // Write timestamp for Flutter to read as evidence of connectivity
                securePrefs.edit().putString("flutter.workmanager_last_success_ms", System.currentTimeMillis().toString()).apply()
            }
            response.close()
        } catch (e: Exception) {
            logLocationUpdateFailure("Exception updating location in Supabase", e)
        }
    }

    private fun updateUserActivity(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        securePrefs: SharedPreferences
    ) {
        val url = "$supabaseUrl/rest/v1/rpc/update_user_activity"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())
        val requestBuilder = Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey)
            .addHeader("Content-Type", "application/json")

        if (userToken != null) {
            requestBuilder.addHeader("Authorization", "Bearer $userToken")
        } else {
            requestBuilder.addHeader("Authorization", "Bearer $supabaseKey")
        }

        try {
            val response = httpClient.newCall(requestBuilder.build()).execute()
            if (!response.isSuccessful) {
                // Log.e(TAG, "Failed to update user activity: ${response.code}")
            } else {
                // Log.d(TAG, "Successfully updated user activity in Supabase")
                // Write timestamp for Flutter to read as evidence of connectivity
                securePrefs.edit().putString("flutter.workmanager_last_success_ms", System.currentTimeMillis().toString()).apply()
            }
            response.close()
        } catch (e: Exception) {
            // Log.e(TAG, "Exception updating user activity", e)
        }
    }

    private fun triggerMatchEngine(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        location: Location
    ) {
        val url = "$supabaseUrl/functions/v1/match-engine"
        val jsonBody = JSONObject().apply {
            put("userId", userId)
            put("latitude", location.latitude)
            put("longitude", location.longitude)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())
        val requestBuilder = Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey)
            .addHeader("Content-Type", "application/json")

        if (userToken != null) {
            requestBuilder.addHeader("Authorization", "Bearer $userToken")
        } else {
            requestBuilder.addHeader("Authorization", "Bearer $supabaseKey")
        }

        try {
            val response = httpClient.newCall(requestBuilder.build()).execute()
            if (!response.isSuccessful) {
                // 401 is expected if using anon key for secure function
                if (response.code == 401) {
                     // Log.d(TAG, "Match engine 401 (expected if requiring service role)")
                } else {
                     // Log.e(TAG, "Failed to trigger match engine: ${response.code}")
                }
            } else {
                // Log.d(TAG, "Successfully triggered match engine")
            }
            response.close()
        } catch (e: Exception) {
            // Log.e(TAG, "Exception triggering match engine", e)
        }
    }

    private fun logLocationUpdateFailure(message: String, error: Throwable) {
        if (isTransientNetworkError(error)) {
            val now = System.currentTimeMillis()
            if ((now - lastTransientLocationFailureLogAt) < 30000L) {
                suppressedTransientLocationFailureCount += 1
                return
            }

            val suppressedCount = suppressedTransientLocationFailureCount
            suppressedTransientLocationFailureCount = 0
            lastTransientLocationFailureLogAt = now
            val suffix = if (suppressedCount > 0) {
                " (suppressed $suppressedCount similar failures)"
            } else {
                ""
            }
            // Log disabled
            return
        }

        // Log.e(TAG, message, error)
    }

    private fun isTransientNetworkError(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is java.net.SocketException ||
                current is java.net.SocketTimeoutException ||
                current is java.net.UnknownHostException ||
                current is java.io.InterruptedIOException ||
                current is javax.net.ssl.SSLException) {
                return true
            }
            current = current.cause
        }
        return false
    }

    companion object {
        const val NAME_A = "MatchMeHeartbeatOneTimeA"
        const val NAME_B = "MatchMeHeartbeatOneTimeB"
        const val KEY_SLOT = "matchme_hb_slot"
        const val TAG_HEARTBEAT = "matchme-heartbeat"

        /// Max retries for transient failures (unreadable Keystore right
        /// after boot, missing credentials until the app process writes
        /// them). With the default 30s exponential backoff this spans
        /// roughly 30s + 1m + 2m + 4m + 8m before giving up.
        const val MAX_TRANSIENT_ATTEMPTS = 5

        /**
         * Both slot names plus the legacy single name, so callers that need to
         * tear the whole chain down (e.g. returning to foreground) cannot miss a
         * link. The legacy name is kept so work enqueued by an older build is
         * still cancelled instead of lingering until it runs.
         */
        val ALL_UNIQUE_NAMES = listOf(NAME_A, NAME_B, "MatchMeHeartbeatOneTime")
    }
}
