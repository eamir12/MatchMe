package com.baseflow.geolocator

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.Location
import android.location.LocationManager
import android.os.*
import android.util.Log
import android.net.Uri
import android.net.ConnectivityManager
import android.net.NetworkRequest
import android.net.NetworkCapabilities
import android.provider.Settings
import java.util.concurrent.TimeUnit
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.example.matchme.MatchMeBadgeController
import com.example.matchme.R
import com.google.android.gms.location.*
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.math.max
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager

class MatchMeBackgroundService : Service() {
    private val TAG = "MatchMeBackgroundService"
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var locationJob: Job? = null
    private var realtimeJob: Job? = null
    private var realtimeReconnectJob: Job? = null
    private var webSocket: WebSocket? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastRealtimeActivity: Long = 0 // Track last message/heartbeat time

    // Realtime connection guards
    private val realtimeLock = Any()
    @Volatile private var isRealtimeConnecting: Boolean = false
    @Volatile private var lastRealtimeConnectAttemptAt: Long = 0
    @Volatile private var lastIntentionalRealtimeCloseAt: Long = 0
    @Volatile private var realtimeConnectStartAt: Long = 0
    @Volatile private var isRealtimeIntentionalClosePending: Boolean = false
    private val realtimeDebug = RealtimeDebugState()
    private lateinit var notificationManager: NotificationManager
    
    // Exponential backoff for Realtime connection
    @Volatile private var reconnectDelay = 1000L
    private val MAX_RECONNECT_DELAY = 60000L

    private var userId: String? = null
    private var supabaseUrl: String? = null
    private var supabaseKey: String? = null
    private var userToken: String? = null
    private var refreshToken: String? = null
    private var isVisible = false
    private var isOnline = true // Default to true until told otherwise
    private var authPermanentlyFailed = false // Track if refresh token was invalidated
    // The exact refresh token the auth server already refused. Kept after the
    // failure flag is re-evaluated: a rejected token must never re-arm auth
    // work, because every replay is logged as another abuse attempt
    // (2026-10-30: 38 replays in four minutes while the app sat on the gate).
    @Volatile private var rejectedRefreshToken: String? = null
    // Tracks whether the UI process is in the foreground. This is not the same as the user's
    // discoverability/visibility setting.
    @Volatile private var appInForeground: Boolean = false
    @Volatile private var backgroundMatchingMode: Boolean = true
    private var backgroundGraceJob: Job? = null
    @Volatile private var gracePeriodActive: Boolean = false
    private var gpsInterval = 5
    private var smartThrottlingEnabled = true
    private val recentLocations = mutableListOf<Location>()
    @Volatile private var lastBackgroundRequestIntervalMs: Long = 0L

    // Battery-aware throttling: when battery < 15% and not charging, ensure GPS runs
    // no more frequently than once every 60 seconds.
    @Volatile private var batteryPercent: Int? = null
    @Volatile private var deviceCharging: Boolean = false
    @Volatile private var lowBatteryThrottlingActive: Boolean = false
    private var batteryReceiver: BroadcastReceiver? = null
    @Volatile private var lastTransientLocationFailureLogAt: Long = 0
    @Volatile private var suppressedTransientLocationFailureCount: Int = 0

    // Mutex to prevent concurrent refresh_token race between heartbeat/location/realtime
    private val refreshMutex = Mutex()

    private val lowBatteryThresholdPercent = 15
    private val lowBatteryMinIntervalMs = 60000L

    // When Android restarts a START_STICKY service, `intent` may be null.
    // If we don't re-enter foreground mode quickly, the OS can kill/crash-loop us.
    @Volatile private var foregroundStarted: Boolean = false
    
    // Deduplication tracking. `lastNotifiedMessageId` is the exact message
    // the last chat notification was posted for: FCM, the Realtime plugin
    // path and the RPC poll can all fire for the same message, and without
    // it each one alerted again (the chat-level `lastNotifiedMatchId` alone
    // is bypassed by design on specific requests). Cleared by
    // ACTION_RESET_CHAT_NOTIFICATION so edits/retractions can re-post.
    private var lastNotifiedMessageId: String? = null
    private var lastNotifiedMatchId: String? = null
    // Match-buzz dedup, separate from message dedup (both share the matchId
    // namespace: a message buzz must never suppress a match buzz). The RAM
    // value alone re-buzzes after every process restart, so it is mirrored
    // to disk and unified with the WorkManager fallback's key — one buzz per
    // match per device, ever.
    private var lastNotifiedMatchBuzzId: String? = null
    private val PREF_LAST_MATCH_BUZZ_ID = "flutter.last_notified_match_id"
    private val PREF_LAST_MESSAGE_ID = "flutter.last_notified_message_id"
    private val PREF_WORKER_NOTIFIED_KEY = "flutter.worker_last_notified_key"
    private val PREF_CHAT_ALERTED_IDS = "flutter.chat_notification_alerted_ids"

    private fun wasMatchBuzzed(matchId: String): Boolean {
        if (matchId.isBlank()) return false
        if (matchId == lastNotifiedMatchBuzzId) return true
        return try {
            val prefs = securePrefs()
            prefs.getString(PREF_LAST_MATCH_BUZZ_ID, null) == matchId ||
                prefs.getString(PREF_WORKER_NOTIFIED_KEY, null) == "match:$matchId"
        } catch (_: Exception) {
            false
        }
    }

    private fun recordMatchBuzzed(matchId: String) {
        if (matchId.isBlank()) return
        lastNotifiedMatchBuzzId = matchId
        try {
            securePrefs().edit()
                .putString(PREF_LAST_MATCH_BUZZ_ID, matchId)
                .putString(PREF_WORKER_NOTIFIED_KEY, "match:$matchId")
                .apply()
        } catch (_: Exception) {
        }
    }

    // Same cross-path / cross-process dedupe as matches, for messages: the
    // exact message that last alerted this device is mirrored to prefs so a
    // service restart or the WorkManager fallback never buzzes it twice.
    private fun wasMessageBuzzed(messageId: String): Boolean {
        if (messageId.isBlank()) return false
        if (messageId == lastNotifiedMessageId) return true
        return try {
            val prefs = securePrefs()
            prefs.getString(PREF_LAST_MESSAGE_ID, null) == messageId ||
                prefs.getString(PREF_WORKER_NOTIFIED_KEY, null) == "msg:$messageId"
        } catch (_: Exception) {
            false
        }
    }

    private fun recordMessageBuzzed(messageId: String) {
        if (messageId.isBlank()) return
        lastNotifiedMessageId = messageId
        try {
            securePrefs().edit()
                .putString(PREF_LAST_MESSAGE_ID, messageId)
                .putString(PREF_WORKER_NOTIFIED_KEY, "msg:$messageId")
                .apply()
        } catch (_: Exception) {
        }
    }

    private fun wasChatNotificationAlerted(matchId: String): Boolean {
        if (matchId.isBlank()) return false
        return try {
            securePrefs().getStringSet(PREF_CHAT_ALERTED_IDS, emptySet())
                ?.contains(matchId) == true
        } catch (_: Exception) {
            false
        }
    }

    private fun recordChatNotificationAlerted(matchId: String) {
        if (matchId.isBlank()) return
        try {
            val prefs = securePrefs()
            val ids = prefs.getStringSet(PREF_CHAT_ALERTED_IDS, emptySet())
                ?.toMutableSet() ?: mutableSetOf()
            ids.add(matchId)
            prefs.edit().putStringSet(PREF_CHAT_ALERTED_IDS, ids).apply()
        } catch (_: Exception) {
        }
    }

    // True when the server FCM push for this match is already sitting in the
    // tray. push-message sends match pushes with the tag "new_match_<matchId>",
    // so the poll/realtime fallback can key off exactly that: the localized
    // card the server posted is the notification, and buzzing here again would
    // stack a second, hardcoded-English card for the same match (the RPC keeps
    // reporting the match unread until the user actually opens it).
    private fun isMatchPushInTray(matchId: String): Boolean {
        if (matchId.isBlank()) return false
        return try {
            val tag = "new_match_$matchId"
            notificationManager.activeNotifications.any { sbn -> sbn.tag == tag }
        } catch (_: Exception) {
            false
        }
    }

    // Same story for chat pushes (push-message tags them "match_<matchId>").
    // When that card is already in the tray — drawn while no client code could
    // run (killed app, notification+data push) — it IS this message's
    // notification: the poll/realtime path that catches up after a restart
    // must record the message and leave the card, not buzz a second time.
    private fun isChatPushInTray(chatId: String): Boolean {
        if (chatId.isBlank()) return false
        return try {
            val tag = "match_$chatId"
            notificationManager.activeNotifications.any { sbn -> sbn.tag == tag }
        } catch (_: Exception) {
            false
        }
    }

    // Cancels the server FCM chat card (push-message tags chat pushes
    // "match_<matchId>") before the native card is (re)posted. In
    // background/killed states the FCM SDK draws that tagged card while the
    // realtime/native path posts its own untagged card with
    // notificationId = matchId.hashCode(); the two identities can never
    // replace each other, so every message stacked a second tray entry.
    // Returns true when a removed card was posted recently — delivery already
    // buzzed the user, so the replacement must not buzz again.
    private fun removeServerChatCard(matchId: String, freshWithinMs: Long = 30_000L): Boolean {
        if (matchId.isBlank()) return false
        return try {
            val tag = "match_$matchId"
            val now = System.currentTimeMillis()
            var removedFresh = false
            notificationManager.activeNotifications
                .filter { sbn -> sbn.tag == tag }
                .forEach { sbn ->
                    if (now - sbn.postTime <= freshWithinMs) removedFresh = true
                    notificationManager.cancel(sbn.tag, sbn.id)
                }
            removedFresh
        } catch (_: Exception) {
            false
        }
    }

    // Same identity story as removeServerChatCard, for match cards
    // (push-message tags match pushes "new_match_<matchId>").
    private fun cancelServerMatchCard(matchId: String): Boolean {
        if (matchId.isBlank()) return false
        return try {
            val tag = "new_match_$matchId"
            var cancelled = false
            notificationManager.activeNotifications
                .filter { sbn -> sbn.tag == tag }
                .forEach { sbn ->
                    notificationManager.cancel(sbn.tag, sbn.id)
                    cancelled = true
                }
            cancelled
        } catch (_: Exception) {
            false
        }
    }

    // Late or redelivered FCM deliveries draw the SDK's tagged card even when
    // our own card for the same chat/match already exists (there is no client
    // hook for notification+data pushes while backgrounded). Whenever a
    // periodic check runs, drop tagged server cards that duplicate a card we
    // currently show. Never cancels a server card unless our own live card
    // for the same chat/match is present, so a notification is never lost.
    private fun sweepDuplicateServerCards() {
        try {
            val active = notificationManager.activeNotifications
            if (active.size < 2) return
            active.forEach { sbn ->
                val tag = sbn.tag ?: return@forEach
                if (tag.startsWith("new_match_")) {
                    val matchId = tag.removePrefix("new_match_")
                    val ourId = activeMatchNotificationIds[matchId]
                    if (ourId != null &&
                        active.any { it.id == ourId && it.tag == null }
                    ) {
                        notificationManager.cancel(sbn.tag, sbn.id)
                    }
                } else if (tag.startsWith("match_") &&
                    !tag.startsWith("match_expiry_")
                ) {
                    val matchId = tag.removePrefix("match_")
                    val ourId = activeNotificationIds[matchId]
                        ?: matchId.hashCode()
                    if (active.any { it.id == ourId && it.tag == null }) {
                        notificationManager.cancel(sbn.tag, sbn.id)
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    // Location share state
    @Volatile private var lsMatchId: String? = null
    @Volatile private var lsOtherUserId: String? = null
    @Volatile private var lsSessionKey: ByteArray? = null
    @Volatile private var lsIntervalSeconds: Int = 5
    @Volatile private var lsExpiresAt: String? = null
    private var lsJob: Job? = null
    
    // Notification countdown timer - updates every second while sharing is active
    private var lsNotificationTimer: kotlinx.coroutines.Job? = null
    private val activeNotificationIds = mutableMapOf<String, Int>() // matchId -> notificationId
    // Same bookkeeping for match ("New Match!") cards so the duplicate sweep
    // and the delayed-push cancel can tell our card apart from the server's.
    private val activeMatchNotificationIds = mutableMapOf<String, Int>() // matchId -> notificationId
    private var currentlyViewingChatId: String? = null // Track which chat the user is currently viewing

    // Unread lines one chat card expands to. Equal to the server's
    // CHAT_PREVIEW_MAX_LINES so the card can never show a different backlog
    // than the push payload described.
    private val maxPreviewLines = 5

    // Throttling for notification checks to prevent duplicate concurrent calls
    @Volatile private var lastNotificationCheckTime: Long = 0
    private val notificationCheckThrottleMs = 2000L // Minimum 2 seconds between checks

    // Connectivity monitoring for detecting when device comes back online
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var connectivityProbeJob: Job? = null
    @Volatile private var wasOffline: Boolean = false
    @Volatile private var wasPinnedSkipping: Boolean = false
    // Last pinned state seen by the heartbeat loop (null until the first tick).
    // Drives the pinned-transition re-evaluation below: while the Flutter
    // engine is dead the UI cannot send ACTION_UPDATE_PINNED_STATE, so pin
    // expiry while the UI is closed would otherwise leave GPS parked until
    // some unrelated event (visibility/connectivity/config/restart).
    @Volatile private var lastHeartbeatPinnedActive: Boolean? = null

    private class RealtimeDebugState {
        @Volatile var lastPostgresDebugAt: Long = 0
        @Volatile var postgresDebugCountInWindow: Int = 0

		@Volatile var lastPostgresIgnoredAt: Long = 0
		@Volatile var postgresIgnoredCountInWindow: Int = 0
    }

    private var methodChannel: MethodChannel? = null
    private var locationShareHelper: LocationShareHelper? = null
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // Disable read timeout for WebSockets
        .writeTimeout(30, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS) // Keep connection alive (reduced to 20s)
        .retryOnConnectionFailure(true)
        // Attribute native traffic in Supabase edge logs (uid resolved lazily
        // per request — userId is restored from secure prefs in onCreate).
        .addInterceptor(SupabaseIdentity.interceptor(this) { userId })
        .build()

    companion object {
        private val diagBuffer = java.util.concurrent.ConcurrentLinkedQueue<String>()
        private const val MAX_DIAG_ENTRIES = 300

        // In-memory event log used to diagnose background GPS/matching issues.
        // Dumped to the Flutter console via the "getDiagnostics" method channel
        // call when the app resumes, so we can see what the native service did
        // (or failed to do) while the UI was in the background.
        private fun addDiag(msg: String) {
            try {
                diagBuffer.add(msg)
                while (diagBuffer.size > MAX_DIAG_ENTRIES) {
                    diagBuffer.poll()
                }
            } catch (_: Exception) {
            }
        }

        fun getDiagnostics(): List<String> {
            val snapshot = diagBuffer.toList()
            return listOf("serviceAlive=${isServiceAlive()}") + snapshot
        }

        const val CHANNEL_ID = "matchme_background_service_min" // Changed ID to force update
        const val ALERTS_CHANNEL_ID = "matchme_alerts"
        const val NOTIFICATION_ID = 1001

        /// Encrypted native buffer of GPS fixes recorded while offline with
        /// Retro Matching opted in and the app UI closed. Merged into the
        /// Dart-side encrypted Hive trail and uploaded on next connectivity.
        const val TRAIL_NATIVE_KEY = "flutter.offline_trail_native"

        /// Buffer caps: hard entry cap and the maximum retention window the
        /// retro feature allows (Dart clamps retention to 2–72h).
        const val MAX_NATIVE_TRAIL_POINTS = 2000
        const val MAX_RETENTION_H = 72
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        const val ACTION_UPDATE_VISIBILITY = "UPDATE_VISIBILITY"
        const val ACTION_UPDATE_APP_FOREGROUND = "UPDATE_APP_FOREGROUND"
        const val ACTION_UPDATE_BACKGROUND_MATCHING = "UPDATE_BACKGROUND_MATCHING"
        const val ACTION_UPDATE_PINNED_STATE = "UPDATE_PINNED_STATE"
        const val ACTION_UPDATE_TOKEN = "UPDATE_TOKEN"
        const val ACTION_UPDATE_CONFIG = "UPDATE_CONFIG"
        const val ACTION_RESET_CHAT_NOTIFICATION = "RESET_CHAT_NOTIFICATION"
        const val ACTION_DISMISS_CHAT_NOTIFICATION = "DISMISS_CHAT_NOTIFICATION"
        const val ACTION_SET_VIEWING_CHAT = "SET_VIEWING_CHAT"
        const val ACTION_CLEAR_VIEWING_CHAT = "CLEAR_VIEWING_CHAT"
        const val ACTION_SET_CONNECTIVITY = "SET_CONNECTIVITY"
        const val ACTION_PROCESS_LOCATION_UPDATE = "PROCESS_LOCATION_UPDATE"
        const val ACTION_START_LOCATION_SHARE = "START_LOCATION_SHARE"
        const val ACTION_STOP_LOCATION_SHARE = "STOP_LOCATION_SHARE"
        const val ACTION_UPDATE_LOCATION_SHARE_DURATION = "UPDATE_LOCATION_SHARE_DURATION"
        const val ACTION_REFRESH_NOTIFICATION = "REFRESH_NOTIFICATION"
        const val EXTRA_LS_MATCH_ID = "lsMatchId"
        const val EXTRA_LS_OTHER_USER_ID = "lsOtherUserId"
        const val EXTRA_LS_SESSION_KEY = "lsSessionKey"
        const val EXTRA_LS_INTERVAL = "lsInterval"
        const val EXTRA_LS_EXPIRES_AT = "lsExpiresAt"
        const val EXTRA_USER_ID = "userId"
        const val EXTRA_SUPABASE_URL = "supabaseUrl"
        const val EXTRA_SUPABASE_KEY = "supabaseKey"
        const val EXTRA_USER_TOKEN = "userToken"
        const val EXTRA_REFRESH_TOKEN = "refreshToken"
        const val EXTRA_IS_VISIBLE = "isVisible"
        const val EXTRA_IS_ONLINE = "isOnline"
        const val EXTRA_APP_IN_FOREGROUND = "appInForeground"
        const val EXTRA_BACKGROUND_MATCHING = "backgroundMatching"
        const val EXTRA_GPS_INTERVAL = "gpsInterval"
        const val EXTRA_SMART_THROTTLING = "smartThrottlingEnabled"
        const val EXTRA_MATCH_ID = "matchId"
        private const val FIX_TIMEOUT_MS = 20000L
        private const val PREF_APP_IN_FOREGROUND = "flutter.app_in_foreground"
        private const val PREF_LS_MATCH_ID = "flutter.location_share_match_id"
        private const val PREF_LS_OTHER_USER_ID = "flutter.location_share_other_user_id"
        private const val PREF_LS_SESSION_KEY = "flutter.location_share_session_key"
        private const val PREF_LS_INTERVAL = "flutter.location_share_interval"
        private const val PREF_LS_EXPIRES_AT = "flutter.location_share_expires_at"
        private const val PREF_RECENT_LOCATIONS = "flutter.recent_locations_json"

        private fun persistAppForegroundState(context: Context, appInForeground: Boolean) {
            try {
                context
                    .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_APP_IN_FOREGROUND, appInForeground)
                    .apply()
            } catch (e: Exception) {
                // Log.w("MatchMeBackgroundService", "Failed to persist app foreground state", e)
            }
        }

        fun startService(
            context: Context,
            userId: String,
            supabaseUrl: String,
            supabaseKey: String,
            userToken: String?,
            refreshToken: String?,
            appInForeground: Boolean = false,
            backgroundMatchingMode: Boolean = false,
            isVisible: Boolean = true,
            isOnline: Boolean = true,
            gpsInterval: Int = 5,
            smartThrottlingEnabled: Boolean = true,
        ) {
            persistAppForegroundState(context, appInForeground)
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_USER_ID, userId)
                putExtra(EXTRA_SUPABASE_URL, supabaseUrl)
                putExtra(EXTRA_SUPABASE_KEY, supabaseKey)
                putExtra(EXTRA_USER_TOKEN, userToken)
                putExtra(EXTRA_REFRESH_TOKEN, refreshToken)
                putExtra(EXTRA_IS_VISIBLE, isVisible)
                putExtra(EXTRA_IS_ONLINE, isOnline)
                putExtra(EXTRA_APP_IN_FOREGROUND, appInForeground)
                putExtra(EXTRA_BACKGROUND_MATCHING, backgroundMatchingMode)
                putExtra(EXTRA_GPS_INTERVAL, gpsInterval)
                putExtra(EXTRA_SMART_THROTTLING, smartThrottlingEnabled)
            }
            
            // On Android 8+, starting a service from a *background execution
            // context* (BroadcastReceiver, Service in another app, …) with a
            // plain context.startService() call raises
            // IllegalStateException: "Not allowed to start service Intent …
            // app is in background UID". If the caller declares
            // appInForeground=false, treat it as a potentially-background
            // context and use startForegroundService() on API 26+. The
            // service itself is responsible for calling startForeground()
            // promptly (it does so via ensureForegroundStarted() whenever
            // background matching mode, visibility, or an active live
            // location share requires it).
            if (!appInForeground) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    try {
                        context.startForegroundService(intent)
                    } catch (e: Exception) {
                        // Some OEMs further restrict foreground service starts
                        // from BOOT_COMPLETED/LOCKED_BOOT_COMPLETED. Swallow;
                        // WorkManager periodic fallback covers this.
                    }
                } else {
                    try {
                        context.startService(intent)
                    } catch (_: Exception) {}
                }
            } else {
                try {
                    context.startService(intent)
                } catch (e: Exception) {
                    // Flutter-initiated start when app was actually in the
                    // background is handled by this fallback path.
                }
            }
        }

        fun stopService(context: Context) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun updateVisibility(context: Context, isVisible: Boolean) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_VISIBILITY
                putExtra(EXTRA_IS_VISIBLE, isVisible)
            }
            context.startService(intent)
        }

        fun setConnectivity(context: Context, isOnline: Boolean) {
            try {
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                prefs.edit().putBoolean("flutter.is_online", isOnline).apply()
            } catch (e: Exception) {
                // Log.w("MatchMeBackgroundService", "Failed to persist connectivity state", e)
            }

            if (!isServiceAlive()) {
                // Log disabled
                return
            }

            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_SET_CONNECTIVITY
                putExtra(EXTRA_IS_ONLINE, isOnline)
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                // Log.w("MatchMeBackgroundService", "Failed to deliver connectivity intent", e)
            }
        }

        fun updateAppForeground(context: Context, appInForeground: Boolean) {
            persistAppForegroundState(context, appInForeground)
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_APP_FOREGROUND
                putExtra(EXTRA_APP_IN_FOREGROUND, appInForeground)
            }
            context.startService(intent)
        }

        fun updateBackgroundMatchingMode(context: Context, enabled: Boolean) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_BACKGROUND_MATCHING
                putExtra(EXTRA_BACKGROUND_MATCHING, enabled)
            }
            context.startService(intent)
        }

        fun refreshForegroundForPinnedState(context: Context) {
            // Pinned home-base changed (pin/unpin/expire): the foreground
            // notification and GPS polling both depend on it, so re-evaluate
            // immediately. The flag itself is read fresh from
            // FlutterSharedPreferences by isPinnedLocationActive().
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_PINNED_STATE
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {}
        }

        fun updateToken(context: Context, token: String?, refreshToken: String?) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_TOKEN
                putExtra(EXTRA_USER_TOKEN, token)
                putExtra(EXTRA_REFRESH_TOKEN, refreshToken)
            }
            context.startService(intent)
        }

        fun updateConfig(context: Context, gpsInterval: Int, smartThrottlingEnabled: Boolean) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_CONFIG
                putExtra(EXTRA_GPS_INTERVAL, gpsInterval)
                putExtra(EXTRA_SMART_THROTTLING, smartThrottlingEnabled)
            }
            context.startService(intent)
        }

        fun refreshNotification(context: Context) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_REFRESH_NOTIFICATION
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {}
        }

        fun startLocationShare(
            context: Context,
            matchId: String,
            otherUserId: String,
            sessionKeyBase64: String,
            updateIntervalSeconds: Int,
            expiresAtIso: String?
        ) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_START_LOCATION_SHARE
                putExtra(EXTRA_LS_MATCH_ID, matchId)
                putExtra(EXTRA_LS_OTHER_USER_ID, otherUserId)
                putExtra(EXTRA_LS_SESSION_KEY, sessionKeyBase64)
                putExtra(EXTRA_LS_INTERVAL, updateIntervalSeconds)
                if (expiresAtIso != null) putExtra(EXTRA_LS_EXPIRES_AT, expiresAtIso)
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
            }
        }

        fun stopLocationShare(context: Context) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_STOP_LOCATION_SHARE
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
            }
        }

        fun updateLocationShareDuration(context: Context, expiresAtIso: String?) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_LOCATION_SHARE_DURATION
                if (expiresAtIso != null) putExtra(EXTRA_LS_EXPIRES_AT, expiresAtIso)
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {}
        }

        fun resetChatNotification(context: Context, matchId: String) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_RESET_CHAT_NOTIFICATION
                putExtra(EXTRA_MATCH_ID, matchId)
            }
            context.startService(intent)
        }

        fun checkForNotifications(context: Context, messageId: String?, matchId: String? = null) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = "CHECK_NOTIFICATIONS"
                putExtra("specificMessageId", messageId)
                if (!matchId.isNullOrBlank()) putExtra(EXTRA_MATCH_ID, matchId)
            }
            context.startService(intent)
        }

        /**
         * Post a chat card from content the server already produced.
         *
         * [title], [previewLines] and [unreadCount] are the push-message
         * content model (localized, plural-resolved, byte-capped and masked
         * according to the recipient's preview setting). Clients that hold it
         * must pass it through instead of re-deriving copy locally: the
         * server is the only party that knows whether previews are on AND
         * that can pluralize for the recipient's language.
         */
        fun showTranslatedNotification(
            context: Context,
            messageId: String,
            translatedContent: String,
            originalContent: String,
            senderName: String,
            matchId: String? = null,
            shouldAlert: Boolean? = null,
            title: String? = null,
            previewLines: List<String>? = null,
            unreadCount: Int = 0,
            previewsEnabled: Boolean? = null,
        ) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = "SHOW_TRANSLATED_NOTIFICATION"
                putExtra("messageId", messageId)
                putExtra("translatedContent", translatedContent)
                putExtra("originalContent", originalContent)
                putExtra("senderName", senderName)
                putExtra("matchId", matchId)
                shouldAlert?.let { putExtra("shouldAlert", it) }
                if (!title.isNullOrBlank()) putExtra("title", title)
                if (!previewLines.isNullOrEmpty()) {
                    putExtra("previewLines", ArrayList(previewLines))
                }
                if (unreadCount > 0) putExtra("unreadCount", unreadCount)
                previewsEnabled?.let { putExtra("previewsEnabled", it) }
            }
            context.startService(intent)
        }

        fun dismissChatNotification(context: Context, matchId: String) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_DISMISS_CHAT_NOTIFICATION
                putExtra(EXTRA_MATCH_ID, matchId)
            }
            context.startService(intent)
        }

        fun setViewingChat(context: Context, matchId: String) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_SET_VIEWING_CHAT
                putExtra(EXTRA_MATCH_ID, matchId)
            }
            context.startService(intent)
        }

        fun clearViewingChat(context: Context) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_CLEAR_VIEWING_CHAT
            }
            context.startService(intent)
        }

        @Volatile
        private var _isServiceRunning = false

        fun startServiceRunning() {
            _isServiceRunning = true
        }

        fun stopServiceRunning() {
            _isServiceRunning = false
        }

        fun isServiceAlive(): Boolean {
            return _isServiceRunning
        }
    }

    private fun isDebug(): Boolean {
        return try {
            (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        } catch (_: Exception) {
            false
        }
    }

    private fun securePrefs(): android.content.SharedPreferences {
        // Use standard SharedPreferences to match Flutter app's storage
        // Flutter uses "FlutterSharedPreferences" as the default filename
        // This ensures consistency between Flutter and Android native code
        return getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    }

    // ------------------------------------------------------------------
    // Notification preference enforcement (killed/background paths bypass
    // every Dart gate, so the native service must mirror the client rules).
    // Keys are the Dart SharedPreferences keys with Flutter's "flutter."
    // prefix, written by lib/providers/user_preferences_provider.dart.
    // ------------------------------------------------------------------

    private fun readPausedUntilMs(): Long {
        val p = securePrefs()
        return try {
            p.getLong("flutter.notifications_paused_until_ms_utc", 0L)
        } catch (_: Exception) {
            try {
                p.getInt("flutter.notifications_paused_until_ms_utc", 0).toLong()
            } catch (_: Exception) {
                0L
            }
        }
    }

    /** Mirrors isPushEnabledForPrefs: paused > global push > matrix[key].push > legacy flag. */
    private fun isNotifTypePushEnabled(matrixKey: String, legacyKey: String): Boolean {
        return try {
            val p = securePrefs()
            if (p.getBoolean("flutter.notifications_paused_indefinitely", false)) return false
            if (readPausedUntilMs() > System.currentTimeMillis()) return false
            if (!p.getBoolean("flutter.notifications_global_push_v1", true)) return false
            val raw = p.getString("flutter.notifications_matrix_v1", null)
            if (!raw.isNullOrBlank()) {
                val entry = org.json.JSONObject(raw).optJSONObject(matrixKey)
                val v = entry?.opt("push")
                if (v is Boolean) return v
            }
            p.getBoolean(legacyKey, true)
        } catch (_: Exception) {
            true
        }
    }

    /** Mirrors isMethodEnabled(sound): global sound > matrix[key].sound > legacy. */
    private fun isNotifTypeSoundEnabled(matrixKey: String, legacyKey: String): Boolean {
        return try {
            val p = securePrefs()
            if (!p.getBoolean("flutter.notifications_global_sound_v1", true)) return false
            val raw = p.getString("flutter.notifications_matrix_v1", null)
            if (!raw.isNullOrBlank()) {
                val entry = org.json.JSONObject(raw).optJSONObject(matrixKey)
                val v = entry?.opt("sound")
                if (v is Boolean) return v
            }
            p.getBoolean(legacyKey, true)
        } catch (_: Exception) {
            true
        }
    }

    /** message_previews flag (default true); when off the tray body is masked. */
    private fun isMessagePreviewsEnabled(): Boolean {
        return try {
            securePrefs().getBoolean("flutter.notifications_message_previews_v1", true)
        } catch (_: Exception) {
            true
        }
    }

    /**
     * Localized, plural-aware chat copy for the cards this service builds.
     *
     * The wording itself lives in [ChatNotificationCopy], shared with the
     * WorkManager fallback card: a message that arrived by push and a message
     * that arrived by poll must not say different things about the same chat.
     */
    private fun chatMessagesTitle(count: Int, senderName: String): String =
        ChatNotificationCopy.messagesTitle(securePrefs(), count, senderName)

    private fun openToReadBody(count: Int): String =
        ChatNotificationCopy.openToReadBody(securePrefs(), count)

    private fun chatPushEnabled(): Boolean =
        isNotifTypePushEnabled("chat_messages", "flutter.notifications_chat")

    private fun chatSoundEnabled(): Boolean =
        isNotifTypeSoundEnabled("chat_messages", "flutter.notifications_sound")

    private fun matchPushEnabled(): Boolean =
        isNotifTypePushEnabled("new_match", "flutter.notifications_new_match")

    private fun matchSoundEnabled(): Boolean =
        isNotifTypeSoundEnabled("new_match", "flutter.notifications_new_match")

    private fun logEvent(msg: String) {
        try {
            val ts = try {
                java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US).format(java.util.Date())
            } catch (_: Exception) {
                System.currentTimeMillis().toString()
            }
            Log.i(TAG, msg)
            addDiag("$ts $msg")
        } catch (_: Exception) {
        }
    }

    override fun onCreate() {
        super.onCreate()
        logEvent("onCreate: alive=${isServiceAlive()}")
        // Log.d(TAG, "Background service created")

        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        locationShareHelper = LocationShareHelper(this, httpClient, fusedLocationClient, serviceScope).apply {
            setOnShareEnded { handleLocationShareEnded() }
        }
        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // Track battery state so we can reduce GPS frequency when the device is low.
        startBatteryMonitoring()
        
        // Start independent connectivity monitoring
        startConnectivityMonitoring()
        
        // Initialize WakeLock
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MatchMe:NotificationWakeLock")
        wakeLock?.setReferenceCounted(true)

        // Create notification channel for Android 8.0+
        createNotificationChannel()

        // CRITICAL FIX: Read persisted state synchronously immediately.
        // This ensures that if the service is restarted (e.g. after process kill) or started
        // via an intent that doesn't include all extras (like UPDATE_APP_FOREGROUND),
        // we have the correct state before updateForegroundState() is called.
        // Waiting for the delayed restoreCredentialsAndConnect is too late for the initial check.
        try {
            val prefs = securePrefs()
            backgroundMatchingMode = prefs.getBoolean("flutter.background_matching_mode", false)
            isVisible = prefs.getBoolean("flutter.manual_visibility", true)
            isOnline = prefs.getBoolean("flutter.is_online", true)
            appInForeground = prefs.getBoolean(PREF_APP_IN_FOREGROUND, false)
            // Restore GPS interval and throttling immediately - needed for correct rate after
            // process kill / device restart before the delayed restoreCredentialsAndConnect runs.
            // Must honor user's Settings rate and throttling preference even when UI is dead.
            gpsInterval = when {
                prefs.contains("flutter.gps_interval") -> prefs.getInt("flutter.gps_interval", 5)
                prefs.contains("gps_interval") -> prefs.getInt("gps_interval", 5)
                else -> 5
            }.coerceAtLeast(1)
            smartThrottlingEnabled = when {
                prefs.contains("flutter.smart_throttling_enabled") -> prefs.getBoolean("flutter.smart_throttling_enabled", true)
                prefs.contains("smart_throttling_enabled") -> prefs.getBoolean("smart_throttling_enabled", true)
                else -> true
            }
            
            // Also restore credentials immediately so we can start foreground service if needed
            userId = SecurePrefsHelper.getString(this, "flutter.user_id", null)
            supabaseUrl = SecurePrefsHelper.getString(this, "flutter.supabase_url", null)
            supabaseKey = SecurePrefsHelper.getString(this, "flutter.supabase_key", null)
            userToken = SecurePrefsHelper.getString(this, "flutter.user_token", null)
            refreshToken = SecurePrefsHelper.getString(this, "flutter.refresh_token", null)
            // Restore the auth failure state synchronously too: the heartbeat
            // starts before the delayed restoreCredentialsAndConnect(), so a
            // process restarted into the background could otherwise spend
            // the revoked token once per wake-up.
            authPermanentlyFailed = prefs.getBoolean("flutter.auth_permanently_failed", false)
            rejectedRefreshToken = try {
                SecurePrefsHelper.getString(this, "flutter.auth_rejected_refresh_token", null)
                    ?.trim()?.takeIf { it.isNotEmpty() }
            } catch (_: Exception) { null }
            
            logEvent("onCreate: restored state: bgMatching=$backgroundMatchingMode isVisible=$isVisible isOnline=$isOnline appInForeground=$appInForeground gpsInterval=$gpsInterval smartThrottling=$smartThrottlingEnabled userId=${userId != null}")
            // Restore stationary history so 60s throttling survives process kill / reboot / UI shutdown / screen off
            try { restoreRecentLocations() } catch (_: Exception) {}
        } catch (e: Exception) {
            // Log.e(TAG, "Failed to restore state synchronously", e)
        }

        // Restore credentials and connect but defer slightly to avoid janking startup.
        serviceScope.launch {
            // Log.d(TAG, "[NATIVE] Delaying restoreCredentialsAndConnect by 1500ms to reduce startup contention")
            delay(1500)
            val start = System.currentTimeMillis()
            restoreCredentialsAndConnect()
            // Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect completed (elapsed=${System.currentTimeMillis() - start}ms)")
        }

        // Foreground-service notification is required to keep running in the background.
        // We may hide it while the UI is in foreground (appInForeground=true), but must show it
        // when the UI is backgrounded to keep the service alive.
        // updateForegroundState() <- REMOVED to prevent loop. It is called in onStartCommand or via ensureRunningFromStoredState

        // Start heartbeat
        startHeartbeat()
    }

    private fun startBatteryMonitoring() {
        if (batteryReceiver != null) return

        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)

        batteryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val modeChanged = updateBatteryState(intent)
                if (modeChanged && smartThrottlingEnabled) {
                    // Log disabled

                    // Apply the new interval quickly (without waiting for the previous delay).
                    if (isVisible) {
                        try {
                            stopLocationUpdates()
                            startLocationUpdates()
                        } catch (e: Exception) {
                            // Log.w(TAG, "Failed to restart location updates after battery state change", e)
                        }
                    }
                }
            }
        }

        // Initialize from the sticky battery intent right away.
        try {
            val initial = registerReceiver(batteryReceiver, filter)
            updateBatteryState(initial)
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to register battery receiver", e)
        }
    }

    private fun updateBatteryState(batteryIntent: Intent?): Boolean {
        if (batteryIntent == null) return false

        val level = batteryIntent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = batteryIntent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val percent = if (level >= 0 && scale > 0) ((level * 100) / scale) else null

        val status = batteryIntent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val plugged = batteryIntent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
        val chargingNow = plugged != 0 || status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL

        batteryPercent = percent
        deviceCharging = chargingNow

        val lowBatteryModeNow = (percent != null && percent < lowBatteryThresholdPercent && !chargingNow)
        val changed = lowBatteryModeNow != lowBatteryThrottlingActive
        lowBatteryThrottlingActive = lowBatteryModeNow
        return changed
    }

    private fun startConnectivityMonitoring() {
        if (connectivityManager == null) return
        
        try {
            // First, check current network status to initialize wasOffline correctly
            val activeNetwork = connectivityManager?.activeNetwork
            val isCurrentlyOnline = activeNetwork != null
            wasOffline = !isCurrentlyOnline
            // Log.d(TAG, "Initializing connectivity monitoring. Current network status: online=$isCurrentlyOnline, wasOffline=$wasOffline")
            
            val networkRequest = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: android.net.Network) {
                    super.onAvailable(network)
                    val wasOfflineBefore = wasOffline
                    
                    // Log.d(TAG, "🌐 Network available (wasOfflineBefore=$wasOfflineBefore, network=$network)")
                    
                    if (wasOfflineBefore) {
                        // Log.d(TAG, "📡 Device came back online (network available)")
                        refreshConnectivityFromProbe("network_available")
                    }
                }

                override fun onLost(network: android.net.Network) {
                    super.onLost(network)
                    // Log.d(TAG, "📡 Network lost: $network")
                    applyConnectivityState(false, "network_lost")
                }
            }
            
            connectivityManager?.registerNetworkCallback(networkRequest, networkCallback!!)
            // Log.d(TAG, "Started monitoring connectivity changes")
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to register connectivity monitoring: ${e.message}", e)
        }
    }

    private fun stopConnectivityMonitoring() {
        try {
            networkCallback?.let { callback ->
                connectivityManager?.unregisterNetworkCallback(callback)
                // Log.d(TAG, "Stopped monitoring connectivity changes")
            }
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to unregister connectivity monitoring: ${e.message}", e)
        }
        networkCallback = null
    }

    private suspend fun probeInternetReachability(timeoutMs: Long = 5000L): Boolean {
        val baseUrl = supabaseUrl?.trim()?.trimEnd('/') ?: return false
        val apiKey = supabaseKey?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val request = Request.Builder()
            .url("$baseUrl/auth/v1/health")
            .get()
            .addHeader("apikey", apiKey)
            .addHeader("Authorization", bearerAuthHeader())
            .addHeader("Cache-Control", "no-cache")
            .build()

        return try {
            httpClient
                .newBuilder()
                .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
                .build()
                .newCall(request)
                .execute()
                .use { response ->
                    response.code in 200..499
                }
        } catch (e: Exception) {
            // Log.d(TAG, "Reachability probe failed: ${e.message}")
            false
        }
    }

    private fun persistOnlineState(online: Boolean) {
        try {
            securePrefs().edit().putBoolean("flutter.is_online", online).apply()
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to persist connectivity state", e)
        }
    }

    private fun applyConnectivityState(newIsOnline: Boolean, source: String) {
        val wasOnlineBefore = isOnline
        isOnline = newIsOnline
        wasOffline = !newIsOnline
        persistOnlineState(newIsOnline)
        locationShareHelper?.isOnline = newIsOnline

        if (wasOnlineBefore == newIsOnline) {
            // Log.d(TAG, "Connectivity unchanged ($source): isOnline=$newIsOnline")
            if (newIsOnline) {
                if (isVisible) startLocationUpdates() else stopLocationUpdates()
            }
            return
        }

        // Log.d(TAG, "Connectivity updated ($source): $wasOnlineBefore -> $newIsOnline, wasOffline=$wasOffline")

        if (newIsOnline) {
            reconnectDelay = 1000L
            if (!isServiceAlive()) {
                // Log.d(TAG, "User came online but service is not running -> skipping Realtime reconnect")
                return
            }
            // Retro Matching: transmit any offline-trail points recorded
            // while offline immediately on connectivity restore — headless,
            // no UI required. Also covers the case where the WorkManager
            // chain died while offline: the periodic worker is the backup,
            // but this is the "as soon as Supabase is reachable" path.
            if (OfflineTrailUploader.isRetroOfflineTrailEnabled(applicationContext) &&
                !userId.isNullOrBlank() &&
                !supabaseUrl.isNullOrBlank() &&
                !supabaseKey.isNullOrBlank()
            ) {
                serviceScope.launch {
                    try {
                        OfflineTrailUploader.upload(
                            applicationContext,
                            userId!!,
                            supabaseUrl!!,
                            supabaseKey!!,
                            userToken,
                            httpClient,
                        )
                    } catch (_: Exception) {}
                }
            }
            // Skip Realtime reconnect when source is app_foreground - this is just an app resume,
            // not an actual connectivity change. The user was already online, the service just
            // stopped monitoring while the app was in background. Calling connectToRealtime() here
            // would trigger update_user_activity RPC, causing the online count to fluctuate.
            if (source == "app_foreground") {
                // Log.d(TAG, "Skipping Realtime reconnect on app_foreground - user was already online")
                if (isVisible) {
                    startLocationUpdates()
                } else {
                    stopLocationUpdates()
                }
                return
            }
            // Log.d(TAG, "User came online -> attempting Realtime reconnect")
            if (isVisible) {
                startLocationUpdates()
            } else {
                stopLocationUpdates()
            }
            connectToRealtime()
        } else {
            // Log.d(TAG, "User went offline -> stopping location updates and Realtime")
            stopLocationUpdates()
            disconnectRealtime(reason = source)
        }
    }

    private fun refreshConnectivityFromProbe(source: String) {
        connectivityProbeJob?.cancel()
        connectivityProbeJob = serviceScope.launch {
            val hasTransport = connectivityManager?.activeNetwork != null
            val reachable = hasTransport && probeInternetReachability()
            applyConnectivityState(reachable, source)
        }
    }

    private fun ensureForegroundStarted() {
        if (foregroundStarted) {
            // Log.d(TAG, "Foreground already started, skipping")
            return
        }
        // Final gate, evaluated at the single choke point every promotion
        // path funnels through: while a pinned home-base is active there is
        // no GPS work to keep alive, so the persistent notification must
        // never be (re)created no matter which caller got here — service
        // start, OS restart, swipe-away, share restore, or state update.
        // Live location sharing is exempt (it genuinely needs foreground).
        if (isPinnedLocationActive() && !isLocationShareActive()) {
            logEvent("ensureForegroundStarted: BLOCKED pinned home-base active (suppressing notification, no GPS work)")
            try {
                ensureForegroundStopped()
            } catch (_: Exception) {
            }
            return
        }
        if (userId.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) {
            logEvent("ensureForegroundStarted: BLOCKED missing credentials (userId=${!userId.isNullOrBlank()}, url=${!supabaseUrl.isNullOrBlank()}, key=${!supabaseKey.isNullOrBlank()})")
            return
        }

        // Check if location permissions are granted before starting foreground service
        val hasFineLocation = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val hasCoarseLocation = checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED

        // FOREGROUND_SERVICE_LOCATION was added in API 34 (Android 14).
        // On older versions the permission constant does not exist, so skip the check.
        if (Build.VERSION.SDK_INT >= 34) {
            val hasForegroundServiceLocation = checkSelfPermission(android.Manifest.permission.FOREGROUND_SERVICE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!hasForegroundServiceLocation) {
                logEvent("ensureForegroundStarted: BLOCKED FOREGROUND_SERVICE_LOCATION denied")
                recordPermissionIssue("FOREGROUND_SERVICE_LOCATION_DENIED")
                return
            }
        }

        if (!hasFineLocation && !hasCoarseLocation) {
            logEvent("ensureForegroundStarted: BLOCKED no fine/coarse location permission")
            recordPermissionIssue("location_always")
            return
        }

        // Android 14+ (API 34) requires background location permission to start foreground service when app is not visible
        if (!appInForeground && Build.VERSION.SDK_INT >= 34) {
            // Check if we have background location permission
            // Note: Android doesn't have a separate permission flag for background location,
            // it's granted via ACCESS_BACKGROUND_LOCATION permission
            val hasBackgroundLocation = checkSelfPermission(android.Manifest.permission.ACCESS_BACKGROUND_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
            Log.d(TAG, "Android 14+ background check: hasBackgroundLocation=$hasBackgroundLocation")

            if (!hasBackgroundLocation) {
                logEvent("ensureForegroundStarted: BLOCKED on Android 14+ background location permission not granted (appInForeground=$appInForeground)")
                recordPermissionIssue("location_always")
                return
            }
        }

        logEvent("ensureForegroundStarted: permission checks passed, calling startForeground() (appInForeground=$appInForeground)")
        try {
            startForeground(NOTIFICATION_ID, createNotification())
            foregroundStarted = true
            logEvent("Foreground service started (notification shown)")
        } catch (e: SecurityException) {
            // Log.e(TAG, "Failed to enter foreground mode - Security Exception: ${e.message}", e)
            // Report permission issue to Flutter so it can show user a dialog
            if (e.message?.contains("FOREGROUND_SERVICE_LOCATION") == true) {
                try {
                    val prefs = securePrefs()
                    prefs.edit().putString("permission_issue_code", "FOREGROUND_SERVICE_LOCATION_DENIED").apply()
                    // Log.d(TAG, "Stored permission issue in SharedPreferences for Flutter to handle")
                } catch (ex: Exception) {
                    // Log.e(TAG, "Failed to store permission issue", ex)
                }
            }
            // If location sharing is active, stop it since we can't continue without permissions
            if (isLocationShareActive()) {
                // Log.w(TAG, "Stopping location share due to permission failure")
                stopLocationShareLoop()
                clearPersistedLocationShareState()
            }
        } catch (e: Exception) {
            // Log.e(TAG, "Failed to enter foreground mode: ${e.javaClass.simpleName}: ${e.message}", e)
            // If location sharing is active, stop it since we can't continue without permissions
            if (isLocationShareActive()) {
                // Log.w(TAG, "Stopping location share due to permission failure")
                stopLocationShareLoop()
                clearPersistedLocationShareState()
            }
        }
    }

    private fun ensureForegroundStopped() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            if (foregroundStarted) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
            }
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to exit foreground mode", e)
        } finally {
            foregroundStarted = false
            try {
                notificationManager.cancel(NOTIFICATION_ID)
            } catch (e: Exception) {
                // Log.w(TAG, "Failed to cancel foreground notification", e)
            }
        }
    }

    private fun updateForegroundState() {
        // Background Matching Mode controls whether the foreground service keeps
        // the app alive when backgrounded.  Live location sharing also requires
        // the foreground service regardless of this setting.

        logEvent("updateForegroundState: appInForeground=$appInForeground bgMatching=$backgroundMatchingMode visible=$isVisible shareActive=${isLocationShareActive()} foregroundStarted=$foregroundStarted gracePeriod=$gracePeriodActive")

        // Pinned home-base is authoritative over the grace period: a stale
        // grace must never freeze suppression. While pinned there is no GPS
        // work to tear down, so there is nothing for the grace to protect —
        // apply suppression immediately and continue to normal logic.
        if (isPinnedLocationActive() && !isLocationShareActive()) {
            if (gracePeriodActive) {
                gracePeriodActive = false
                backgroundGraceJob?.cancel()
                backgroundGraceJob = null
                logEvent("updateForegroundState: pinned home-base active — cancelling grace period")
            }
            logEvent("updateForegroundState: pinned home-base active — suppressing foreground notification (no GPS work; FCM + periodic heartbeat continue)")
            ensureForegroundStopped()
            stopLocationUpdates()
            schedulePeriodicWork()
            return
        }

        if (gracePeriodActive) return

        if (appInForeground) {
            ensureForegroundStopped()
            cancelPeriodicWork()
            return
        }

        // App is in background
        // Pinned home-base suppresses the foreground promotion: no GPS is
        // accessed or uploaded while a pin is active, so there is no
        // background location work to keep alive. Matching continues
        // server-side on the stored pin, chat notifications still arrive
        // via FCM, and periodic WorkManager work keeps heartbeat/online
        // presence. Live location sharing still needs the foreground
        // service and is exempt from the suppression.
        if (isLocationShareActive() ||
            (backgroundMatchingMode && !isPinnedLocationActive())
        ) {
            // Background matching or live sharing must stay in a foreground
            // service so Android does not discard it after the UI is paused,
            // swiped away, or the process is recreated.
            if (userId.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) return
            ensureForegroundStarted()

            if (!foregroundStarted) {
                schedulePeriodicWork()
                startBackgroundLocationUpdates()
                return
            }

            // Keep WorkManager scheduled even when the foreground service is
            // alive: LocationWorker is a no-op when fgAlive==true, so no
            // duplicate GPS, but if Doze/OOM kills the service the 15m
            // periodic + 45s OneTime chain (see schedulePeriodicWork) keeps
            // the user online (<61s) and retries location until the service
            // restarts. Previously this was cancelled, leaving a gap where
            // screen-off + service kill = no location for 6+ minutes.
            schedulePeriodicWork()
        } else {
            if (isPinnedLocationActive()) {
                logEvent("updateForegroundState: pinned home-base active — suppressing foreground notification (no GPS work; FCM + periodic heartbeat continue)")
            }
            // Standard Mode (or suppressed pinned mode): no persistent
            // notification.  Only keep the service alive for heartbeat if a
            // live share is active; otherwise stop the foreground service.
            if (isLocationShareActive()) {
                ensureForegroundStarted()
            } else {
                ensureForegroundStopped()
            }
            // Schedule periodic work as backup for heartbeat / online status.
            schedulePeriodicWork()
        }
    }

    private fun ensureRunningFromStoredState() {
        try {
            restoreCredentialsAndConnect()
            restoreLocationShareState()
            updateForegroundState()
            // Keep realtime/polling alive even if visibility is off.
            connectToRealtime()
            if (isVisible || isOnline) startLocationUpdates() else stopLocationUpdates()
        } catch (e: Exception) {
            // Log.e(TAG, "Failed to restore running state", e)
        }
    }

    private fun isLocationShareActive(): Boolean {
        return lsMatchId != null && lsSessionKey != null
    }

    private fun persistLocationShareState() {
        try {
            if (lsMatchId != null) SecurePrefsHelper.putString(this, PREF_LS_MATCH_ID, lsMatchId)
            if (lsOtherUserId != null) SecurePrefsHelper.putString(this, PREF_LS_OTHER_USER_ID, lsOtherUserId)
            if (lsSessionKey != null) SecurePrefsHelper.putString(this, PREF_LS_SESSION_KEY, Base64.encodeToString(lsSessionKey, Base64.NO_WRAP))
            securePrefs().edit().apply {
                putInt(PREF_LS_INTERVAL, lsIntervalSeconds)
                if (lsExpiresAt != null) {
                    putString(PREF_LS_EXPIRES_AT, lsExpiresAt)
                } else {
                    remove(PREF_LS_EXPIRES_AT)
                }
                apply()
            }
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to persist location share state", e)
        }
    }

    private fun clearPersistedLocationShareState() {
        try {
            SecurePrefsHelper.removeSensitive(this, listOf(PREF_LS_MATCH_ID, PREF_LS_OTHER_USER_ID, PREF_LS_SESSION_KEY))
        } catch (e: Exception) {}
        try {
            securePrefs().edit().apply {
                remove(PREF_LS_INTERVAL)
                remove(PREF_LS_EXPIRES_AT)
                apply()
            }
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to clear persisted location share state", e)
        }
    }

    /**
     * Re-arms a location share that was active when the process died (task
     * removal, OS kill, or reboot). The share loop re-validates the signal in
     * the DB on its first iteration and stops itself if it is no longer valid.
     */
    private fun restoreLocationShareState() {
        try {
            val prefs = securePrefs()
            val matchId = SecurePrefsHelper.getString(this, PREF_LS_MATCH_ID, null)
            val otherUserId = SecurePrefsHelper.getString(this, PREF_LS_OTHER_USER_ID, null)
            val sessionKeyB64 = SecurePrefsHelper.getString(this, PREF_LS_SESSION_KEY, null)
            if (matchId.isNullOrBlank() || otherUserId.isNullOrBlank() || sessionKeyB64.isNullOrBlank()) return

            lsMatchId = matchId
            lsOtherUserId = otherUserId
            lsIntervalSeconds = prefs.getInt(PREF_LS_INTERVAL, 5)
            lsExpiresAt = prefs.getString(PREF_LS_EXPIRES_AT, null)
            lsSessionKey = Base64.decode(sessionKeyB64, Base64.NO_WRAP)

            // If an explicit expiry timestamp is present and it has already
            // passed, the share is stale. The persisted fields may still be
            // present because the Dart layer expired the share silently (e.g.
            // process died before the method-channel stop call reached us) or
            // because the share had a finite duration that naturally ended
            // before the last process kill. Bail out, wipe persisted state,
            // and do NOT start the HIGH_ACCURACY continuous GPS subscription
            // — keeping that alive after expiry is exactly what manifests as
            // the "GPS icon stuck on whenever the app is foregrounded" bug.
            if (!lsExpiresAt.isNullOrBlank()) {
                try {
                    val expiryInstant = java.time.Instant.parse(lsExpiresAt)
                    val nowInstant = java.time.Instant.now()
                    if (!expiryInstant.isAfter(nowInstant)) {
                        clearPersistedLocationShareState()
                        lsMatchId = null
                        lsOtherUserId = null
                        lsSessionKey = null
                        lsExpiresAt = null
                        lsOtherUserName = null
                        return
                    }
                } catch (_: Exception) {
                    // Malformed timestamp: treat as a stale entry.
                    clearPersistedLocationShareState()
                    lsMatchId = null
                    lsOtherUserId = null
                    lsSessionKey = null
                    lsExpiresAt = null
                    lsOtherUserName = null
                    return
                }
            }

            // CRITICAL FIX: Before starting location sharing after restart/reboot,
            // ensure we have all necessary permissions. If not, stop sharing and
            // report issue so user can grant permissions.
            val hasFineLocation = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
            val hasCoarseLocation = checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
            var hasAllPermissions = hasFineLocation || hasCoarseLocation

            if (Build.VERSION.SDK_INT >= 34) {
                val hasForegroundServiceLocation = checkSelfPermission(android.Manifest.permission.FOREGROUND_SERVICE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
                hasAllPermissions = hasAllPermissions && hasForegroundServiceLocation
            }

            if (!hasAllPermissions) {
                // Log.w(TAG, "Location share restored but permissions missing. Stopping share.")
                clearPersistedLocationShareState()
                lsMatchId = null
                lsOtherUserId = null
                lsSessionKey = null
                lsExpiresAt = null
                lsOtherUserName = null
                recordPermissionIssue("location_always")
                return
            }

            startLocationShareLoop()
            // Start the notification countdown timer for real-time updates
            startNotificationTimer()
            // Keep the process alive so the restored share can broadcast.
            if (!appInForeground) ensureForegroundStarted()
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to restore location share state", e)
        }
    }

    private fun handleLocationShareEnded() {
        lsMatchId = null
        lsOtherUserId = null
        lsSessionKey = null
        lsExpiresAt = null
        lsOtherUserName = null
        clearPersistedLocationShareState()
        // Demote back to Standard Mode behavior if we promoted only for the share.
        if (!backgroundMatchingMode && !appInForeground && foregroundStarted) {
            ensureForegroundStopped()
        }
        updateNotification() // Update notification text
    }

    private fun restoreCredentialsAndConnect() {
        val start = System.currentTimeMillis()
        // Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect: start")

        val prefs = securePrefs()
        // Restore ids and config (always from prefs when missing)
        if (userId.isNullOrBlank()) userId = SecurePrefsHelper.getString(this, "flutter.user_id", null)
        if (supabaseUrl.isNullOrBlank()) supabaseUrl = SecurePrefsHelper.getString(this, "flutter.supabase_url", null)
        if (supabaseKey.isNullOrBlank()) supabaseKey = SecurePrefsHelper.getString(this, "flutter.supabase_key", null)
        // Don't overwrite in-memory token if we already have one (e.g. from ACTION_START this process)
        if (userToken.isNullOrBlank()) userToken = SecurePrefsHelper.getString(this, "flutter.user_token", null)
        if (refreshToken.isNullOrBlank()) refreshToken = SecurePrefsHelper.getString(this, "flutter.refresh_token", null)
        isVisible = prefs.getBoolean("flutter.manual_visibility", true)
        isOnline = prefs.getBoolean("flutter.is_online", true)
        appInForeground = prefs.getBoolean(PREF_APP_IN_FOREGROUND, false)
        authPermanentlyFailed = prefs.getBoolean("flutter.auth_permanently_failed", false)
        rejectedRefreshToken = try {
            SecurePrefsHelper.getString(this, "flutter.auth_rejected_refresh_token", null)
                ?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) { null }
        // Deliberately NOT cleared here by mere token presence: a revoked
        // family keeps its token strings forever, and clearing on restore is
        // what let the 2026-10-30 storm replay a revoked token on every
        // launch. Only a successful refresh or a new sign-in clears it.
        gpsInterval = when {
            prefs.contains("flutter.gps_interval") -> prefs.getInt("flutter.gps_interval", 5)
            prefs.contains("gps_interval") -> prefs.getInt("gps_interval", 5)
            else -> 5
        }
        smartThrottlingEnabled = when {
            prefs.contains("flutter.smart_throttling_enabled") -> prefs.getBoolean("flutter.smart_throttling_enabled", true)
            prefs.contains("smart_throttling_enabled") -> prefs.getBoolean("smart_throttling_enabled", true)
            else -> true
        }
        backgroundMatchingMode = prefs.getBoolean("flutter.background_matching_mode", false)
        // Ensure stationary history survives delayed restore (in case onCreate was missed due to direct startService)
        try { if (recentLocations.isEmpty()) restoreRecentLocations() } catch (_: Exception) {}

        if (userId != null && supabaseUrl != null && supabaseKey != null) {
            if (!isServiceAlive()) {
                // Log.d(TAG, "Restored credentials from storage, but service is not running -> skipping Realtime reconnect")
                // Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect: finished (elapsed=${System.currentTimeMillis() - start}ms)")
                return
            }
            // Log.d(TAG, "Restored credentials from storage. Connecting to Realtime immediately.")
            connectToRealtime()
            if (isVisible && isOnline) {
                startLocationUpdates()
            }
        }

        // Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect: finished (elapsed=${System.currentTimeMillis() - start}ms)")
    }
    
    private fun saveCredentials(userId: String, url: String, key: String, isVisible: Boolean, gpsInterval: Int, smartThrottlingEnabled: Boolean, token: String?, refreshToken: String?, backgroundMatchingMode: Boolean) {
        val prefs = securePrefs()
        try {
            SecurePrefsHelper.putString(this, "flutter.user_id", userId)
            SecurePrefsHelper.putString(this, "flutter.user_token", token)
            SecurePrefsHelper.putString(this, "flutter.refresh_token", refreshToken)
        } catch (_: Exception) {}
        prefs.edit().apply {
            putBoolean("flutter.was_logged_in", true)
            putString("flutter.supabase_url", url)
            putString("flutter.supabase_key", key)
            putBoolean("flutter.manual_visibility", isVisible)
            putInt("flutter.gps_interval", gpsInterval)
            putBoolean("flutter.smart_throttling_enabled", smartThrottlingEnabled)
            putBoolean("flutter.background_matching_mode", backgroundMatchingMode)
            apply()
        }
        if (isDebug()) {
            // Log.d(TAG, "Credentials and config saved for boot recovery")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        logEvent("onStartCommand: action=${intent?.action ?: "null"} startId=$startId")
        if (!isServiceAlive()) {
            // Log.d(TAG, "Marking service as running at onStartCommand entry (action=${intent?.action})")
        }
        startServiceRunning()

        when (intent?.action) {
            ACTION_START -> {
                userId = intent.getStringExtra(EXTRA_USER_ID)
                supabaseUrl = intent.getStringExtra(EXTRA_SUPABASE_URL)
                supabaseKey = intent.getStringExtra(EXTRA_SUPABASE_KEY)
                // Only a CHANGED refresh token proves the session is alive
                // (a new sign-in, or a rotation Dart already completed).
                // A revoked family keeps replaying the same token on every
                // launch, so token presence alone must never clear the flag —
                // and a token the server already refused never clears it even
                // when its string differs from the one this process holds.
                val incomingRefreshToken =
                    intent.getStringExtra(EXTRA_REFRESH_TOKEN)?.trim()
                if (!incomingRefreshToken.isNullOrBlank() &&
                    incomingRefreshToken != refreshToken?.trim() &&
                    !isRejectedRefreshToken(incomingRefreshToken)
                ) {
                    authPermanentlyFailed = false
                    try {
                        securePrefs().edit()
                            .putBoolean("flutter.auth_permanently_failed", false)
                            .apply()
                    } catch (_: Exception) {}
                }
                userToken = intent.getStringExtra(EXTRA_USER_TOKEN)
                refreshToken = intent.getStringExtra(EXTRA_REFRESH_TOKEN)
                // Load persisted config for other values
                val prefs = securePrefs()

                // Resolve initial isVisible by applying the *exact same*
                // priority that Dart's BackgroundService.start uses when it
                // reads prefs before the method-channel call. This closes the
                // bootstrap race where Dart writes effective_visibility=false
                // to SharedPreferences but then passes a stale
                // intent-extra isVisible=true here because the provider had
                // not yet applied the effective visibility when
                // startService() ran. A stale true intent value would leave
                // startForegroundLocationUpdates running (PRIORITY_BALANCED
                // polls every gpsInterval seconds) → Android's location-in-use
                // privacy indicator appears continuously and the user thinks
                // the GPS chip is stuck on. Priority order mirrors Dart:
                //   1. effective_visibility (written by VisibilityProvider after
                //      invisibility rules run)
                //   2. manual_visibility     (user's explicit toggle)
                //   3. intent extra EXTRA_IS_VISIBLE (provided by Flutter start)
                //   4. default true
                val hasEffective = prefs.contains("flutter.effective_visibility")
                val hasManual = prefs.contains("flutter.manual_visibility")
                when {
                    hasEffective -> isVisible = prefs.getBoolean("flutter.effective_visibility", true)
                    hasManual    -> isVisible = prefs.getBoolean("flutter.manual_visibility", true)
                    intent.hasExtra(EXTRA_IS_VISIBLE) -> {
                        isVisible = intent.getBooleanExtra(EXTRA_IS_VISIBLE, false)
                        // Persist the intent-supplied value for future starts
                        // so subsequent boot-resolver paths don't diverge.
                        securePrefs().edit().putBoolean("flutter.manual_visibility", isVisible).apply()
                    }
                    else -> isVisible = true
                }

                // Prioritize intent for isOnline (it's passed from Flutter startService)
                if (intent.hasExtra(EXTRA_IS_ONLINE)) {
                    isOnline = intent.getBooleanExtra(EXTRA_IS_ONLINE, true)
                    persistOnlineState(isOnline)
                } else {
                    isOnline = prefs.getBoolean("flutter.is_online", true)
                }

                // Prefer intent-supplied GPS config (authoritative Settings value from Flutter),
                // fallback to persisted prefs. Supports both flutter.* and legacy keys for migration.
                gpsInterval = when {
                    intent.hasExtra(EXTRA_GPS_INTERVAL) -> intent.getIntExtra(EXTRA_GPS_INTERVAL, 5).coerceAtLeast(1)
                    prefs.contains("flutter.gps_interval") -> prefs.getInt("flutter.gps_interval", 5)
                    prefs.contains("gps_interval") -> prefs.getInt("gps_interval", 5)
                    else -> 5
                }
                smartThrottlingEnabled = when {
                    intent.hasExtra(EXTRA_SMART_THROTTLING) -> intent.getBooleanExtra(EXTRA_SMART_THROTTLING, true)
                    prefs.contains("flutter.smart_throttling_enabled") -> prefs.getBoolean("flutter.smart_throttling_enabled", true)
                    prefs.contains("smart_throttling_enabled") -> prefs.getBoolean("smart_throttling_enabled", true)
                    else -> true
                }
                // Ensure canonical flutter.* keys are persisted so background/Worker reads are consistent
                try {
                    prefs.edit().apply {
                        putInt("flutter.gps_interval", gpsInterval)
                        putInt("gps_interval", gpsInterval)
                        putBoolean("flutter.smart_throttling_enabled", smartThrottlingEnabled)
                        putBoolean("smart_throttling_enabled", smartThrottlingEnabled)
                        apply()
                    }
                } catch (_: Exception) {}
                
                // Handle backgroundMatchingMode: prioritize intent, fallback to prefs
                backgroundMatchingMode = if (intent.hasExtra(EXTRA_BACKGROUND_MATCHING)) {
                    intent.getBooleanExtra(EXTRA_BACKGROUND_MATCHING, false)
                } else {
                    prefs.getBoolean("flutter.background_matching_mode", false)
                }
                
                appInForeground = intent.getBooleanExtra(EXTRA_APP_IN_FOREGROUND, false)
                persistAppForegroundState(this, appInForeground)

                logEvent("ACTION_START: user=${userId ?: "null"} backgroundMatching=$backgroundMatchingMode isVisible=$isVisible isOnline=$isOnline appInForeground=$appInForeground gpsInterval=$gpsInterval smartThrottling=$smartThrottlingEnabled")

                if (userId != null && supabaseUrl != null && supabaseKey != null) {
                    saveCredentials(userId!!, supabaseUrl!!, supabaseKey!!, isVisible, gpsInterval, smartThrottlingEnabled, userToken, refreshToken, backgroundMatchingMode)

                    // Restore an active location share BEFORE we update the
                    // foreground state. Boot/background-service starts go
                    // through `context.startForegroundService()` on Android
                    // 8+, which requires that the service call
                    // `Service.startForeground()` within ~5 seconds. The
                    // `updateForegroundState()` call below checks
                    // `isLocationShareActive()` (lsMatchId != null &&
                    // lsSessionKey != null) — so state must be restored into
                    // those RAM fields before updateForegroundState runs.
                    restoreLocationShareState()

                    if (!appInForeground && (isLocationShareActive() ||
                            (backgroundMatchingMode && !isPinnedLocationActive()))) {
                        try {
                            ensureForegroundStarted()
                        } catch (e: Exception) {
                        }
                    }
                    
                    // Now proceed with normal state management
                    updateForegroundState()
                    
                    if (isVisible && isOnline) {
                        startLocationUpdates()
                    } else {
                        // Log.d(TAG, "Service started but user is invisible or offline -> NOT starting location updates")
                        stopLocationUpdates()
                    }

                    connectToRealtime()
                    refreshConnectivityFromProbe("action_start")
                    // startNotificationPolling() - Removed as redundant with FCM
                }
            }
            ACTION_UPDATE_VISIBILITY -> {
                val requestedVisibility = intent.getBooleanExtra(EXTRA_IS_VISIBLE, false)
                if (requestedVisibility == isVisible) {
                    // Log.d(TAG, "Visibility unchanged; skipping update (isVisible=$isVisible)")
                    return START_STICKY
                }
                isVisible = requestedVisibility
                logEvent("ACTION_UPDATE_VISIBILITY: isVisible=$isVisible (bgMatching=$backgroundMatchingMode)")
                securePrefs().edit().putBoolean("flutter.manual_visibility", isVisible).apply()
                updateForegroundState()
                if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
            }
            ACTION_SET_CONNECTIVITY -> {
                val newIsOnline = intent.getBooleanExtra(EXTRA_IS_ONLINE, true)
                logEvent("ACTION_SET_CONNECTIVITY: isOnline=$newIsOnline (prev=$isOnline)")
                applyConnectivityState(newIsOnline, "flutter")
            }
            ACTION_UPDATE_APP_FOREGROUND -> {
                val requestedForeground = intent.getBooleanExtra(EXTRA_APP_IN_FOREGROUND, false)
                if (requestedForeground == appInForeground && !gracePeriodActive) {
                    logEvent("ACTION_UPDATE_APP_FOREGROUND: unchanged (appInForeground=$appInForeground) skipped")
                    return START_STICKY
                }

                if (requestedForeground) {
                    // App returning to foreground — cancel any pending grace-period job.
                    backgroundGraceJob?.cancel()
                    backgroundGraceJob = null
                    if (gracePeriodActive) {
                        gracePeriodActive = false
                        logEvent("ACTION_UPDATE_APP_FOREGROUND: grace period cancelled (app returning to foreground)")
                    }
                    appInForeground = true
                    persistAppForegroundState(this, true)
                    logEvent("ACTION_UPDATE_APP_FOREGROUND: appInForeground=true (visible=$isVisible online=$isOnline bgMatching=$backgroundMatchingMode)")
                    updateForegroundState()
                    refreshConnectivityFromProbe("app_foreground")
                    if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                } else {
                    // App going to background
                    if (!backgroundMatchingMode && !isLocationShareActive()) {
                        // Background Matching is OFF and no live share — apply grace period
                        // so brief app switches don't cut GPS immediately.
                        if (gracePeriodActive) {
                            logEvent("ACTION_UPDATE_APP_FOREGROUND: already in grace period, skipping")
                            return START_STICKY
                        }
                        gracePeriodActive = true
                        logEvent("ACTION_UPDATE_APP_FOREGROUND: starting 30s grace period (bgMatching=false)")
                        backgroundGraceJob = serviceScope.launch {
                            delay(30_000L)
                            gracePeriodActive = false
                            appInForeground = false
                            persistAppForegroundState(this@MatchMeBackgroundService, false)
                            logEvent("ACTION_UPDATE_APP_FOREGROUND: grace period expired, appInForeground=false")
                            updateForegroundState()
                            if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                        }
                    } else {
                        // Background Matching is ON or live share active — transition immediately.
                        backgroundGraceJob?.cancel()
                        backgroundGraceJob = null
                        gracePeriodActive = false
                        appInForeground = false
                        persistAppForegroundState(this, false)
                        logEvent("ACTION_UPDATE_APP_FOREGROUND: appInForeground=false (visible=$isVisible online=$isOnline bgMatching=$backgroundMatchingMode)")
                        updateForegroundState()
                        if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                    }
                }
            }
            ACTION_UPDATE_BACKGROUND_MATCHING -> {
                backgroundMatchingMode = intent.getBooleanExtra(EXTRA_BACKGROUND_MATCHING, false)
                logEvent("ACTION_UPDATE_BACKGROUND_MATCHING: bgMatching=$backgroundMatchingMode")
                securePrefs().edit().putBoolean("flutter.background_matching_mode", backgroundMatchingMode).apply()
                updateForegroundState()
                if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
            }
            ACTION_UPDATE_PINNED_STATE -> {
                logEvent("ACTION_UPDATE_PINNED_STATE: pinned=${isPinnedLocationActive()} (bgMatching=$backgroundMatchingMode)")
                updateForegroundState()
                if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
            }
            ACTION_UPDATE_TOKEN -> {
                val previousToken = userToken
                val previousRefreshToken = refreshToken
                val hasTokenExtra = intent.hasExtra(EXTRA_USER_TOKEN)
                val hasRefreshTokenExtra = intent.hasExtra(EXTRA_REFRESH_TOKEN)
                val newToken = intent.getStringExtra(EXTRA_USER_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }
                val newRefreshToken = intent.getStringExtra(EXTRA_REFRESH_TOKEN)?.trim()?.takeIf { it.isNotEmpty() }
                val nextRefreshToken = when {
                    hasRefreshTokenExtra -> newRefreshToken
                    hasTokenExtra && newToken == null -> null
                    else -> previousRefreshToken
                }
                val accessTokenChanged = previousToken != newToken
                val refreshTokenChanged = previousRefreshToken != nextRefreshToken
                if (!accessTokenChanged && !refreshTokenChanged) {
                    // Log.d(TAG, "JWT token unchanged; skipping update")
                } else {
                    userToken = newToken
                    refreshToken = nextRefreshToken
                    // A changed token only proves a live session when the
                    // server has not already refused it; the dead family's
                    // token keeps arriving here on every Dart re-push.
                    if (!isRejectedRefreshToken(nextRefreshToken)) {
                        authPermanentlyFailed = false
                    }
                    // Log.d(TAG, "JWT token updated: accessChanged=$accessTokenChanged refreshChanged=$refreshTokenChanged")

                    // Persist refreshed token so a process restart doesn't revert to an expired JWT.
                    // Use flutter.* keys to match restoreCredentialsAndConnect().
                    try {
                        SecurePrefsHelper.putString(this, "flutter.user_token", if (userToken.isNullOrBlank()) null else userToken)
                        SecurePrefsHelper.putString(this, "flutter.refresh_token", if (refreshToken.isNullOrBlank()) null else refreshToken)
                    } catch (e: Exception) {
                        // Log.w(TAG, "Failed to persist refreshed JWT token: $e")
                    }

                    if (!accessTokenChanged) {
                        // Log.d(TAG, "Realtime reconnect skipped: access token unchanged")
                    } else {
                        disconnectRealtime()
                        connectToRealtime()
                    }
                }
            }
            ACTION_UPDATE_CONFIG -> {
                gpsInterval = intent.getIntExtra(EXTRA_GPS_INTERVAL, 5).coerceAtLeast(1)
                smartThrottlingEnabled = intent.getBooleanExtra(EXTRA_SMART_THROTTLING, true)
                // Log.d(TAG, "Config updated: interval=$gpsInterval, throttling=$smartThrottlingEnabled")
                
                // Save config - write canonical flutter.* keys plus legacy for migration
                securePrefs().edit().apply {
                    putInt("flutter.gps_interval", gpsInterval)
                    putInt("gps_interval", gpsInterval)
                    putBoolean("flutter.smart_throttling_enabled", smartThrottlingEnabled)
                    putBoolean("smart_throttling_enabled", smartThrottlingEnabled)
                    apply()
                }
                
                // Restart location updates to apply new interval immediately
                if (isVisible) {
                    stopLocationUpdates()
                    startLocationUpdates()
                }
                // Ensure Realtime is connected (in case it dropped)
                connectToRealtime()
            }
            ACTION_RESET_CHAT_NOTIFICATION -> {
                val matchId = intent.getStringExtra(EXTRA_MATCH_ID)
                if (matchId != null) {
                    // Log.d(TAG, "Resetting notification state for chat: $matchId")
                    if (lastNotifiedMatchId == matchId) {
                        lastNotifiedMatchId = null
                        // Log.d(TAG, "Cleared lastNotifiedMatchId for chat: $matchId")
                    } else {
                        // Log.d(TAG, "Not clearing lastNotifiedMatchId (current: $lastNotifiedMatchId, requested: $matchId)")
                    }
                    if (lastNotifiedMatchBuzzId == matchId) {
                        lastNotifiedMatchBuzzId = null
                        // Log.d(TAG, "Cleared lastNotifiedMatchBuzzId for chat: $matchId")
                    }
                    try {
                        val ids = securePrefs()
                            .getStringSet(PREF_CHAT_ALERTED_IDS, emptySet())
                            ?.toMutableSet() ?: mutableSetOf()
                        ids.remove(matchId)
                        securePrefs().edit().putStringSet(PREF_CHAT_ALERTED_IDS, ids).apply()
                    } catch (_: Exception) {
                    }

                    // Allow the following post to alert even if the latest
                    // unread message was already notified before its content
                    // changed (edit/retraction repost flow). Cross-process
                    // dedupe mirrors are cleared with it, but only when they
                    // actually hold a message key so a match buzz record is
                    // left alone.
                    val clearedMessageId = lastNotifiedMessageId
                        ?: (try {
                            securePrefs().getString(PREF_LAST_MESSAGE_ID, null)
                        } catch (_: Exception) {
                            null
                        })
                    lastNotifiedMessageId = null
                    try {
                        val prefs = securePrefs()
                        val edit = prefs.edit().remove(PREF_LAST_MESSAGE_ID)
                        if (prefs.getString(PREF_WORKER_NOTIFIED_KEY, null) == "msg:$clearedMessageId") {
                            edit.remove(PREF_WORKER_NOTIFIED_KEY)
                        }
                        edit.apply()
                    } catch (_: Exception) {
                    }
                }
            }
            ACTION_DISMISS_CHAT_NOTIFICATION -> {
                val matchId = intent.getStringExtra(EXTRA_MATCH_ID)
                if (matchId != null) {
                    val notificationId = activeNotificationIds[matchId]
                    if (notificationId != null) {
                        // Log.d(TAG, "Dismissing notification for chat $matchId: $notificationId")
                        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        notificationManager.cancel(notificationId)
                        activeNotificationIds.remove(matchId)
                        // Log.d(TAG, "Dismissed notification: $notificationId")
                    } else {
                        // Log.d(TAG, "No active notification found for chat: $matchId")
                    }
                    // The FCM SDK's tagged card for this chat is not tracked in
                    // activeNotificationIds; drop it too so entering the chat
                    // always clears whatever card represents it.
                    removeServerChatCard(matchId)
                }
            }
            ACTION_SET_VIEWING_CHAT -> {
                val matchId = intent.getStringExtra(EXTRA_MATCH_ID)
                currentlyViewingChatId = matchId
                // Log.d(TAG, "Set currently viewing chat to: $matchId")
            }
            ACTION_CLEAR_VIEWING_CHAT -> {
                // Log.d(TAG, "Cleared currently viewing chat (was: $currentlyViewingChatId)")
                currentlyViewingChatId = null
            }
            "CHECK_NOTIFICATIONS" -> {
                val messageId = intent.getStringExtra("specificMessageId")
                val serverCardMatchId = intent.getStringExtra(EXTRA_MATCH_ID)
                // Log.d(TAG, "[ANDROID] Manual notification check triggered for messageId: $messageId")
                // Run notification check in a coroutine
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (messageId != null) {
                            // Log.d(TAG, "[ANDROID] Waiting 300ms for translation to complete")
                            delay(300) // Wait for translation to be saved
                        }
                        // Log.d(TAG, "[ANDROID] Starting notification check for messageId: $messageId")
                        checkForNotifications(messageId, serverCardMatchId)
                        // Log.d(TAG, "[ANDROID] Notification check completed for messageId: $messageId")
                    } catch (e: Exception) {
                        // Log.e(TAG, "[ANDROID] Error in manual notification check", e)
                    }
                }
            }
            "SHOW_TRANSLATED_NOTIFICATION" -> {
                val messageId = intent.getStringExtra("messageId") ?: ""
                val translatedContent = intent.getStringExtra("translatedContent") ?: ""
                val originalContent = intent.getStringExtra("originalContent") ?: ""
                val senderName = intent.getStringExtra("senderName") ?: "Someone"
                val matchId = intent.getStringExtra("matchId")
                val shouldAlert = if (intent.hasExtra("shouldAlert")) {
                    intent.getBooleanExtra("shouldAlert", true)
                } else {
                    null
                }
                val modelTitle = intent.getStringExtra("title")
                val previewLines = intent.getStringArrayListExtra("previewLines")
                val unreadCount = intent.getIntExtra("unreadCount", 0)
                val previewsEnabled = if (intent.hasExtra("previewsEnabled")) {
                    intent.getBooleanExtra("previewsEnabled", true)
                } else {
                    null
                }

                // Log.d(TAG, "[ANDROID] Show translated notification: sender='$senderName', translated='$translatedContent', original='$originalContent', matchId='$matchId'")

                // Show notification directly with the translated content
                showTranslatedNotification(
                    senderName,
                    translatedContent,
                    messageId,
                    matchId,
                    shouldAlert,
                    modelTitle,
                    previewLines.orEmpty(),
                    unreadCount,
                    previewsEnabled,
                )
            }
            ACTION_PROCESS_LOCATION_UPDATE -> {
                logEvent("ACTION_PROCESS_LOCATION_UPDATE: hasResult=${LocationResult.hasResult(intent)} visible=$isVisible appForeground=$appInForeground shareActive=${isLocationShareActive()}")
                if (LocationResult.hasResult(intent)) {
                    val result = LocationResult.extractResult(intent)
                    result?.lastLocation?.let { location ->
                        logEvent("Background PendingIntent location: ${location.latitude},${location.longitude}")
                        rememberRecentLocation(location)
                        handleLocationUpdate(location)
                        maybeRestartBackgroundRequestForNewInterval()
                    }
                } else {
                    // Log.d(TAG, "Background location intent received but no result found")
                }

                // Visible users keep the service (and its foreground polling
                // loop) alive; only stop the service when the user is
                // invisible so no location work lingers.
                if (!isVisible && !appInForeground && !isLocationShareActive()) {
                    // Log.d(TAG, "Standard Mode background update processed -> Stopping Service")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_STOP -> {
                logEvent("ACTION_STOP received")
                // Log.d(TAG, "ACTION_STOP received - stopping service and clearing sensitive state")
                stopLocationUpdates()
                clearCredentials()
                persistAppForegroundState(this, false)
                ensureForegroundStopped()
                stopSelf()
                // Clear sensitive fields immediately
                userId = null
                supabaseUrl = null
                supabaseKey = null
                userToken = null
                isVisible = false
            }
            ACTION_START_LOCATION_SHARE -> {
                lsMatchId = intent.getStringExtra(EXTRA_LS_MATCH_ID)
                lsOtherUserId = intent.getStringExtra(EXTRA_LS_OTHER_USER_ID)
                val sessionKeyB64 = intent.getStringExtra(EXTRA_LS_SESSION_KEY)
                lsIntervalSeconds = intent.getIntExtra(EXTRA_LS_INTERVAL, 5)
                lsExpiresAt = intent.getStringExtra(EXTRA_LS_EXPIRES_AT)
                lsOtherUserName = null // Reset cached username
                if (sessionKeyB64 != null) {
                    lsSessionKey = Base64.decode(sessionKeyB64, Base64.NO_WRAP)
                }
                persistLocationShareState()
                startLocationShareLoop()
                // Start the notification countdown timer
                startNotificationTimer()
                // Promote to foreground while sharing so the process survives task
                // removal and background restrictions in Standard Mode.
                if (!appInForeground && isLocationShareActive()) {
                    ensureForegroundStarted()
                }
                // Update notification with location sharing text
                updateNotification()
            }
            ACTION_STOP_LOCATION_SHARE -> {
                stopLocationShareLoop()
            }
            ACTION_UPDATE_LOCATION_SHARE_DURATION -> {
                val newExpiresAt = if (intent.hasExtra(EXTRA_LS_EXPIRES_AT)) {
                    intent.getStringExtra(EXTRA_LS_EXPIRES_AT)
                } else {
                    null
                }
                lsExpiresAt = newExpiresAt
                locationShareHelper?.updateExpiresAt(newExpiresAt)
                persistLocationShareState()
                if (lsNotificationTimer == null && isLocationShareActive()) {
                    startNotificationTimer()
                }
                updateNotification()
            }
            ACTION_REFRESH_NOTIFICATION -> {
                logEvent("ACTION_REFRESH_NOTIFICATION: refreshing foreground notification")
                if (foregroundStarted) {
                    updateNotification()
                }
            }
            else -> {
                // OS restart (START_STICKY) or unknown intent. Restore state and keep going.
                // CRITICAL: If we were started with startForegroundService() due to a previous state,
                // we MUST call startForeground() immediately within ~5 seconds.
                // Restore persisted state to determine if we need foreground mode.
                try {
                    val prefs = securePrefs()
                    val storedUserId = SecurePrefsHelper.getString(this, "flutter.user_id", null)
                    val storedUrl = SecurePrefsHelper.getString(this, "flutter.supabase_url", null)
                    val storedKey = SecurePrefsHelper.getString(this, "flutter.supabase_key", null)
                    val storedBackgroundMatching = prefs.getBoolean("flutter.background_matching_mode", false)
                    val storedVisible = prefs.getBoolean("flutter.manual_visibility", true)

                    if (!storedUserId.isNullOrBlank() && !storedUrl.isNullOrBlank() && !storedKey.isNullOrBlank() &&
                        storedVisible && userId == null &&
                        !isPinnedLocationActive()) {
                        // Log.d(TAG, "Boot/OS restart with foreground service requirement -> Immediately ensuring foreground")
                        // Pinned home-base is exempt: no GPS work to keep alive,
                        // so no persistent notification after a restart either.
                        userId = storedUserId
                        supabaseUrl = storedUrl
                        supabaseKey = storedKey
                        try {
                            ensureForegroundStarted()
                        } catch (e: Exception) {
                            // Log.w(TAG, "Failed to ensure foreground on restart", e)
                        }
                    }
                } catch (e: Exception) {
                    // Log.w(TAG, "Error checking for foreground requirement on restart", e)
                }

                maybeRecordBatteryKillIssue(intent)
                ensureRunningFromStoredState()
            }
        }

        return if (backgroundMatchingMode || appInForeground || isLocationShareActive()) {
            START_STICKY
        } else {
            START_NOT_STICKY
        }
    }

    private fun maybeRecordBatteryKillIssue(intent: Intent?) {
        // Heuristic: if Android restarts us with a null/unknown intent and the app is not exempt from
        // battery optimizations, it is often because the OS killed our process in the background.
        // We surface this once so the UI can show a failure-driven dialog.
        try {
            val isStickyRestart = intent == null || intent.action == null
            if (!isStickyRestart) return

            val prefs = securePrefs()
            val wasLoggedIn = prefs.getBoolean("flutter.was_logged_in", false)
            val hasCreds = !SecurePrefsHelper.getString(this, "flutter.user_id", null).isNullOrBlank() &&
                !SecurePrefsHelper.getString(this, "flutter.supabase_url", null).isNullOrBlank() &&
                !SecurePrefsHelper.getString(this, "flutter.supabase_key", null).isNullOrBlank()
            if (!wasLoggedIn || !hasCreds) return

            if (isIgnoringBatteryOptimizationsCompat()) return

            // Avoid spamming on repeated restarts before the user opens UI.
            recordPermissionIssueIfNotRecent("battery_optimizations", 6 * 60 * 60 * 1000L)
        } catch (_: Exception) {
        }
    }

    private fun isIgnoringBatteryOptimizationsCompat(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }
    }

    private fun recordPermissionIssueIfNotRecent(code: String, minIntervalMs: Long) {
        try {
            val prefs = securePrefs()
            val existing = prefs.getString("permission_issue_code", null)
            val at = prefs.getLong("permission_issue_at", 0L)
            val now = System.currentTimeMillis()
            if (existing == code && at > 0 && now - at < minIntervalMs) return
        } catch (_: Exception) {
        }

        recordPermissionIssue(code)
    }

    private fun bearerAuthHeader(): String {
        // Prefer user JWT for RLS-protected RPCs; fall back to anon/service key only when needed.
        val t = userToken
        return if (!t.isNullOrBlank()) {
            "Bearer $t"
        } else {
            "Bearer ${supabaseKey ?: ""}"
        }
    }

    private fun saveCredentials(userId: String, url: String, key: String, isVisible: Boolean, gpsInterval: Int, smartThrottlingEnabled: Boolean, token: String?) {
        val prefs = securePrefs()
        try {
            SecurePrefsHelper.putString(this, "flutter.user_id", userId)
            SecurePrefsHelper.putString(this, "flutter.user_token", token)
            SecurePrefsHelper.putString(this, "flutter.refresh_token", refreshToken)
        } catch (_: Exception) {}
        prefs.edit().apply {
            putBoolean("flutter.was_logged_in", true)
            putString("flutter.supabase_url", url)
            putString("flutter.supabase_key", key)
            putBoolean("flutter.manual_visibility", isVisible)
            putInt("flutter.gps_interval", gpsInterval)
            putBoolean("flutter.smart_throttling_enabled", smartThrottlingEnabled)
            apply()
        }
        if (isDebug()) {
            // Log.d(TAG, "Credentials and config saved for boot recovery")
        }
    }

    private fun saveCredentials(userId: String, url: String, key: String, isVisible: Boolean, gpsInterval: Int, smartThrottlingEnabled: Boolean, token: String?, refreshToken: String?) {
        this.refreshToken = refreshToken
        saveCredentials(userId, url, key, isVisible, gpsInterval, smartThrottlingEnabled, token)
    }

    private fun clearCredentials() {
        forgetRejectedRefreshToken()
        try {
            SecurePrefsHelper.removeSensitive(this, listOf("flutter.user_id", "flutter.user_token", "flutter.refresh_token"))
        } catch (_: Exception) {}
        val prefs = securePrefs()
        prefs.edit().apply {
            putBoolean("flutter.was_logged_in", false)
            putBoolean("flutter.auth_permanently_failed", false)
            remove("flutter.supabase_url")
            remove("flutter.supabase_key")
            remove("flutter.manual_visibility")
            remove("flutter.gps_interval")
            remove("flutter.smart_throttling_enabled")
            apply()
        }
        if (isDebug()) {
            // Log.d(TAG, "Credentials cleared from SharedPreferences")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        logEvent("onDestroy")
        stopServiceRunning()
        stopConnectivityMonitoring()
        connectivityProbeJob?.cancel()

        try {
            batteryReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        batteryReceiver = null

        locationJob?.cancel() // Stop active loop, but keep PendingIntent updates
        stopLocationShareLoop()
        disconnectRealtime()
        serviceScope.cancel()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        logEvent("onTaskRemoved: visible=$isVisible bgMatching=$backgroundMatchingMode shareActive=${isLocationShareActive()} foregroundStarted=$foregroundStarted")

        // The app UI is gone, so we are definitely in the background now.
        appInForeground = false
        persistAppForegroundState(this, false)

        if (isLocationShareActive() ||
            (backgroundMatchingMode && !isPinnedLocationActive())
        ) {
            ensureForegroundStarted()
            if (!foregroundStarted) {
                // Foreground promotion failed; fall back to PendingIntent
                // updates (guarded: invisible/offline users get none).
                schedulePeriodicWork()
                startBackgroundLocationUpdates()
            } else if (isVisible && isOnline) {
                startLocationUpdates()
            }
        } else {
            // Invisible user: keep the heartbeat alive via WorkManager but do
            // not access GPS at all.
            ensureForegroundStopped()
            stopLocationUpdates()
            schedulePeriodicWork()
            stopSelf()
        }

        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Channel for persistent background service (Min importance to hide icon)
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "MatchMe Background Service",
                NotificationManager.IMPORTANCE_MIN
            ).apply {
                description = "Keeps MatchMe running in the background"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }
            notificationManager.createNotificationChannel(serviceChannel)

            // Channel for alerts (High importance)
            val alertsChannel = NotificationChannel(
                ALERTS_CHANNEL_ID,
                "MatchMe Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications for new matches and messages"
                setShowBadge(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableLights(true)
                enableVibration(true)
            }
            notificationManager.createNotificationChannel(alertsChannel)
        }
    }

    private fun createNotification(): Notification {
        // Localized strings are written by Dart via SharedPreferences
        // (flutter.bgNotificationTitle / flutter.bgNotificationText) whenever the
        // user's display language changes. Fall back to English defaults.
        val prefs = securePrefs()
        val localizedTitle = prefs.getString("flutter.bgNotificationTitle", null)?.trim()?.takeIf { it.isNotEmpty() } ?: "MatchMe Active"
        val localizedText = prefs.getString("flutter.bgNotificationText", null)?.trim()?.takeIf { it.isNotEmpty() } ?: "You are visible and background matching is enabled."
        val title = localizedTitle
        val text = when {
            isVisible -> localizedText
            isLocationShareActive() -> {
                // Get the countdown text for active location sharing
                getLiveLocationCountdownText()
            }
            else -> "Maintaining connection"
        }

        // Intent to open the MatchMe home screen (tab 0) when the notification is tapped.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra("tabIndex", 0)
        }
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_MIN) // Min priority to hide icon
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .setContentIntent(pendingIntent)
            .setAutoCancel(false)
            .build()
    }

    private fun startNotificationTimer() {
        // Cancel any existing timer
        lsNotificationTimer?.cancel()
        
        // Start a new coroutine that updates the notification every second
        lsNotificationTimer = serviceScope.launch {
            while (isActive) {
                try {
                    // Only update if location share is active
                    if (isLocationShareActive()) {
                        updateNotification()
                    } else {
                        break
                    }
                    delay(1000) // Update every second
                } catch (e: Exception) {
                    // Ignore errors but continue trying
                }
            }
        }
    }

    private fun updateNotification() {
        if (!foregroundStarted) {
            notificationManager.cancel(NOTIFICATION_ID)
            return
        }
        notificationManager.notify(NOTIFICATION_ID, createNotification())
    }

    private fun getLiveLocationCountdownText(): String {
        val matchId = lsMatchId ?: return "Live location sharing"
        val otherUserId = lsOtherUserId ?: return "Live location sharing"
        val expiresAt = lsExpiresAt

        // Fetch the other user's name
        val otherUserName = lsOtherUserName ?: run {
            // Fetch from DB if not cached
            serviceScope.launch {
                lsOtherUserName = locationShareHelper?.fetchOtherUserName()
                // Rebuild notification with updated text
                updateNotification()
            }
            "someone"
        }

        // Calculate remaining time
        val remainingText = if (expiresAt != null) {
            val expiresMs = parseIsoToMillis(expiresAt)
            val nowMs = System.currentTimeMillis()
            val remainingMs = expiresMs - nowMs

            if (remainingMs <= 0) {
                "until expired"
            } else {
                val remainingSeconds = remainingMs / 1000
                when {
                    remainingSeconds < 60 -> "${remainingSeconds}s remaining"
                    remainingSeconds < 3600 -> "${remainingSeconds / 60}m ${remainingSeconds % 60}s remaining"
                    remainingSeconds < 86400 -> "${remainingSeconds / 3600}h ${(remainingSeconds % 3600) / 60}m remaining"
                    else -> "${remainingSeconds / 86400}d ${(remainingSeconds % 86400) / 3600}h remaining"
                }
            }
        } else {
            "until you stop"
        }

        return "You are currently sharing your live location with $otherUserName for $remainingText"
    }

    private fun parseIsoToMillis(iso: String): Long {
        // See LocationShareHelper.parseIsoToMillis: Instant.parse handles Z /
        // fractional / numeric offsets; never return epoch-0 on failure or a
        // valid share would look instantly expired.
        return try {
            java.time.Instant.parse(iso).toEpochMilli()
        } catch (_: Exception) {
            try {
                val trimmed = iso.trim()
                val hasZone = trimmed.endsWith("Z", ignoreCase = true) ||
                    trimmed.contains("+") ||
                    (trimmed.lastIndexOf('-') > trimmed.indexOf('T'))
                java.time.Instant.parse(if (hasZone) trimmed else trimmed + "Z").toEpochMilli()
            } catch (_: Exception) {
                try {
                    val sdf = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", java.util.Locale.US)
                    sdf.timeZone = java.util.TimeZone.getTimeZone("UTC")
                    val clean = if (iso.contains('.')) iso.substringBefore('.') + "Z" else iso
                    sdf.parse(clean)?.time ?: Long.MAX_VALUE
                } catch (_: Exception) {
                    Long.MAX_VALUE
                }
            }
        }
    }

    private var lsOtherUserName: String? = null

    private fun startLocationUpdates() {
        logEvent("startLocationUpdates: appInForeground=$appInForeground visible=$isVisible online=$isOnline bgMatching=$backgroundMatchingMode foregroundStarted=$foregroundStarted")
        if (appInForeground) {
            stopLocationUpdates()
            return
        }
        // Offline GPS is allowed when Retro Matching is opted in: fixes are
        // recorded on-device (appendOfflineTrailPoint) and uploaded when
        // connectivity returns. GPS works without internet; Supabase does not.
        if (!isVisible || (!isOnline && !isRetroOfflineTrailEnabled())) {
            stopLocationUpdates()
            return
        }
        if (!backgroundMatchingMode) {
            // User chose GPS only when the UI is open — do not run native
            // background location updates.
            stopLocationUpdates()
            return
        }
        if (isPinnedLocationActive() && !isLocationShareActive()) {
            // Pinned home-base: never touch the GPS hardware. Uploads are
            // already dropped in handleLocationUpdate; this stops the fixes
            // from being requested in the first place.
            logEvent("startLocationUpdates: pinned home-base active — GPS not accessed")
            stopLocationUpdates()
            return
        }
        // Visible + online + bgMatching on + UI not in the foreground: run
        // one-shot GPS polling from inside the foreground service.
        if (foregroundStarted) {
            startForegroundLocationUpdates()
        } else {
            startBackgroundLocationUpdates()
        }
    }

    private fun startBackgroundLocationUpdates() {
        locationJob?.cancel()
        locationJob = null

        // Allow updates only if visible AND (online OR retro offline trail)
        if (userId == null) return
        if (!isVisible || (!isOnline && !isRetroOfflineTrailEnabled())) {
             // Log.d(TAG, "Skipping background updates: Not visible or not online (isVisible=$isVisible, isOnline=$isOnline)")
             return
        }
        if (isPinnedLocationActive() && !isLocationShareActive()) {
            // Pinned home-base: never touch the GPS hardware (heartbeat-only
            // presence is kept by the periodic worker instead).
            logEvent("startBackgroundLocationUpdates: pinned home-base active — GPS not accessed")
            stopLocationUpdates()
            return
        }

        logEvent("startBackgroundLocationUpdates (PendingIntent fallback): visible=$isVisible online=$isOnline")
        try {
            // Remove any existing updates to avoid duplication
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
            
            val intervalMs = effectiveGpsIntervalMs()
            lastBackgroundRequestIntervalMs = intervalMs
            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
                .setMinUpdateIntervalMillis(intervalMs)
                .setMaxUpdateDelayMillis(intervalMs * 2) // Allow batching to save power
                .build()
                
            fusedLocationClient.requestLocationUpdates(request, getBackgroundLocationPendingIntent())
        } catch (e: SecurityException) {
            logEvent("startBackgroundLocationUpdates: SecurityException - background location permission missing")
             recordPermissionIssue("location_always")
        } catch (e: Exception) {
            logEvent("startBackgroundLocationUpdates: error ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun startForegroundLocationUpdates() {
        // Ensure background updates are removed so we don't double up
        try {
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
        } catch (e: Exception) {}

        if (locationJob?.isActive == true) {
            // Log.d(TAG, "Location updates already running")
            return
        }

        logEvent("Foreground location polling started (visible=$isVisible, online=$isOnline, interval=${effectiveGpsIntervalMs()}ms)")

        locationJob = serviceScope.launch {
            val initialDelayMs = 2000L
            delay(initialDelayMs)

            while (isActive) {
                if (isVisible && (isOnline || isRetroOfflineTrailEnabled()) && userId != null) {
                    try {
                        // Bound each fix request so a stalled GPS never blocks
                        // the polling loop (and never keeps the location
                        // privacy indicator lit indefinitely).
                        val location = withTimeoutOrNull(FIX_TIMEOUT_MS) {
                            val task = fusedLocationClient.getCurrentLocation(
                                Priority.PRIORITY_HIGH_ACCURACY,
                                null
                            )
                            suspendCancellableCoroutine<Location?> { cont ->
                                task.addOnSuccessListener { loc ->
                                    if (cont.isCancelled) return@addOnSuccessListener
                                    cont.resume(loc, null)
                                }.addOnFailureListener { e ->
                                    if (cont.isCancelled) return@addOnFailureListener
                                    cont.resumeWithException(e)
                                }
                            }
                        }

                        if (location != null) {
                            logEvent("GPS fix acquired: ${location.latitude},${location.longitude} accuracy=${location.accuracy}m")
                            rememberRecentLocation(location)
                            handleLocationUpdate(location)
                        } else {
                            logEvent("GPS fix unavailable this cycle")
                        }
                    } catch (e: SecurityException) {
                        Log.e(TAG, "Foreground location: permission denied", e)
                        recordPermissionIssue("location_always")
                        stopLocationUpdates()
                    } catch (e: Exception) {
                        Log.w(TAG, "Foreground location poll failed: ${e.message}")
                    }
                }

                delay(effectiveGpsIntervalMs())
            }
        }
    }

    private fun recordPermissionIssue(code: String) {
        try {
            val prefs = securePrefs()
            prefs.edit().apply {
                putString("permission_issue_code", code)
                putLong("permission_issue_at", System.currentTimeMillis())
                apply()
            }
        } catch (_: Exception) {
        }
        // Modern: also request system exemption immediately when we detect the kill reason,
        // not just notify. This is the user-visible fix for Xiaomi/Samsung Doze.
        if (code == "battery_optimizations") {
            try { requestIgnoreBatteryOptimizationsIfNeeded() } catch (_: Exception) {}
        }
        try {
            showPermissionNotification(code)
        } catch (e: Exception) {
        }
    }

    private fun requestIgnoreBatteryOptimizationsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(packageName)) return
            // Don't spam – the notification already has the action, this is a best-effort
            // direct system dialog for the foreground session.
        } catch (_: Exception) {}
    }

    private fun showPermissionNotification(code: String) {
        val prefs = securePrefs()
        val titleKey = when (code) {
            "location_always" -> "perm_location_always_title"
            "notifications" -> "perm_notifications_title"
            "battery_optimizations" -> "perm_battery_title"
            else -> "perm_location_always_title"
        }
        val bodyKey = when (code) {
            "location_always" -> "perm_location_always_body"
            "notifications" -> "perm_notifications_body"
            "battery_optimizations" -> "perm_battery_body"
            else -> "perm_location_always_body"
        }
        val actionKey = "perm_action_open_settings"

        val title = prefs.getString(titleKey, "MatchMe needs permission") ?: "MatchMe needs permission"
        val body = prefs.getString(bodyKey, "Please update permissions in Settings") ?: "Please update permissions in Settings"
        val actionLabel = prefs.getString(actionKey, "Open settings") ?: "Open settings"

        val settingsIntent = when (code) {
            "notifications" -> {
                Intent().apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        this.action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    } else {
                        this.action = Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                        data = Uri.parse("package:$packageName")
                    }
                }
            }
            "battery_optimizations" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                } else {
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    }
                }
            }
            else -> {
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
            }
        }
        val pending = PendingIntent.getActivity(
            this,
            9100 + code.hashCode(),
            settingsIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, ALERTS_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .addAction(0, actionLabel, pending)
            .setContentIntent(pending)
            .build()

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(9000 + code.hashCode(), notification)
    }

    private fun isStationary(): Boolean {
        if (recentLocations.size < 5) return false
        
        // Check if all recent locations are within 10 meters of each other
        val first = recentLocations.first()
        for (loc in recentLocations) {
            if (loc.distanceTo(first) > 10.0) {
                return false
            }
        }
        return true
    }

    private fun rememberRecentLocation(location: Location) {
        recentLocations.add(location)
        if (recentLocations.size > 5) {
            recentLocations.removeAt(0)
        }
        persistRecentLocations()
    }

    private fun persistRecentLocations() {
        try {
            val arr = org.json.JSONArray()
            for (loc in recentLocations) {
                val obj = org.json.JSONObject()
                obj.put("lat", loc.latitude)
                obj.put("lng", loc.longitude)
                obj.put("acc", loc.accuracy.toDouble())
                obj.put("time", loc.time)
                arr.put(obj)
            }
            securePrefs().edit().putString(PREF_RECENT_LOCATIONS, arr.toString()).apply()
        } catch (_: Exception) {}
    }

    private fun restoreRecentLocations() {
        try {
            val s = securePrefs().getString(PREF_RECENT_LOCATIONS, null) ?: return
            if (s.isBlank()) return
            val arr = org.json.JSONArray(s)
            recentLocations.clear()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val loc = Location("persisted")
                loc.latitude = o.getDouble("lat")
                loc.longitude = o.getDouble("lng")
                loc.accuracy = o.optDouble("acc", 10.0).toFloat()
                loc.time = o.optLong("time", System.currentTimeMillis())
                // Keep persisted entries only if reasonably recent (30 min) to avoid stale stationary after reboot hours later
                if (System.currentTimeMillis() - loc.time > 30 * 60 * 1000L) continue
                recentLocations.add(loc)
            }
            // Trim to 5
            while (recentLocations.size > 5) recentLocations.removeAt(0)
        } catch (_: Exception) {}
    }

    private fun effectiveGpsIntervalMs(): Long {
        var nextInterval = gpsInterval.coerceAtLeast(1) * 1000L
        if (smartThrottlingEnabled) {
            if (isStationary()) {
                nextInterval = max(nextInterval, 60000L)
            }
            if (lowBatteryThrottlingActive) {
                nextInterval = max(nextInterval, lowBatteryMinIntervalMs)
            }
        }
        return nextInterval
    }

    private fun maybeRestartBackgroundRequestForNewInterval() {
        if (appInForeground || backgroundMatchingMode || !isVisible || !isOnline) {
            return
        }
        val nextIntervalMs = effectiveGpsIntervalMs()
        if (nextIntervalMs != lastBackgroundRequestIntervalMs) {
            startBackgroundLocationUpdates()
        }
    }

    private fun getBackgroundLocationPendingIntent(): PendingIntent {
        val intent = Intent(this, MatchMeBackgroundService::class.java).apply {
            action = ACTION_PROCESS_LOCATION_UPDATE
        }
        return PendingIntent.getService(this, 999, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
    }

    private fun stopLocationUpdates() {
        locationJob?.cancel()
        locationJob = null
        lastBackgroundRequestIntervalMs = 0L
        
        // Also ensure background updates are stopped
        try {
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
        } catch (e: Exception) {
            // Log.w(TAG, "Failed to remove background updates", e)
        }
        
        // Log.d(TAG, "Location updates stopped")
        logEvent("stopLocationUpdates: locationJobActive=${locationJob?.isActive == true}")
    }

    private fun startLocationShareLoop() {
        Log.d(TAG, "startLocationShareLoop called")
        val h = locationShareHelper ?: return
        val key = lsSessionKey ?: return
        h.supabaseUrl = supabaseUrl
        h.supabaseKey = supabaseKey
        h.userId = userId
        h.userToken = userToken
        h.refreshToken = refreshToken
        h.isOnline = isOnline
        h.start(
            matchId = lsMatchId ?: return,
            otherUserId = lsOtherUserId ?: "",
            sessionKeyBase64 = Base64.encodeToString(key, Base64.NO_WRAP),
            updateIntervalSeconds = lsIntervalSeconds,
            expiresAtIso = lsExpiresAt,
            bearerAuthHeaderProvider = { bearerAuthHeader() },
            ensureValidJwt = { ensureValidJwt() },
            refreshJwt = { token -> refreshJwtToken(token) }
        )
        Log.d(TAG, "startLocationShareLoop completed")
    }

    private fun stopLocationShareLoop() {
        // stop() triggers the onEnded callback -> handleLocationShareEnded()
        locationShareHelper?.stop()
        // Stop the notification countdown timer
        lsNotificationTimer?.cancel()
        lsNotificationTimer = null
    }

    private fun isPinnedLocationActive(): Boolean {
        // Pinned home-base (written by Flutter): never upload live GPS while set.
        // Keys mirror PinnedLocationGate in Dart (flutter.* in FlutterSharedPreferences).
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (!prefs.getBoolean("flutter.pinned_location_active", false)) return false
            val expMs = try {
                prefs.getLong("flutter.pinned_location_expires_at_ms", 0L)
            } catch (_: Exception) {
                prefs.getInt("flutter.pinned_location_expires_at_ms", 0).toLong()
            }
            expMs > System.currentTimeMillis()
        } catch (_: Exception) {
            false
        }
    }

    private fun isRetroOfflineTrailEnabled(): Boolean {
        // Retro Matching opt-in (Retro matching toggle in Settings → Matching).
        // Written by Dart to plain SharedPreferences; mirrored from the synced
        // profile flag on every profile sync.
        return try {
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.retro_enabled", false)
        } catch (_: Exception) {
            false
        }
    }

    /// Records an offline GPS fix into the native trail buffer so Retro
    /// Matching keeps working while the app UI is closed (the Dart-side
    /// recorder only runs while the Flutter engine is alive, and the two
    /// never overlap: native GPS polling stops while the app is foreground).
    /// The buffer is encrypted (SecurePrefsHelper sensitive key); the Dart
    /// side merges it into the encrypted Hive trail and uploads it when
    /// connectivity returns or the app is next opened.
    private fun appendOfflineTrailPoint(location: Location) {
        try {
            val iso = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }.format(java.util.Date(location.time))
            val arr = try {
                val raw = SecurePrefsHelper.getString(applicationContext, TRAIL_NATIVE_KEY, null)
                if (raw.isNullOrBlank()) org.json.JSONArray() else org.json.JSONArray(raw)
            } catch (_: Exception) {
                org.json.JSONArray()
            }
            // Drop points older than the maximum retention window (72h).
            val cutoff = System.currentTimeMillis() - MAX_RETENTION_H * 3600_000L
            while (arr.length() > 0) {
                val ts = try {
                    parseIsoToMillis(arr.getJSONObject(0).optString("recorded_at"))
                } catch (_: Exception) { 0L }
                if (ts in 1..cutoff) arr.remove(0) else break
            }
            val obj = org.json.JSONObject().apply {
                put("lat", location.latitude)
                put("lng", location.longitude)
                put("recorded_at", iso)
                put("accuracy", location.accuracy.toDouble())
                put("speed", if (location.hasSpeed()) location.speed.toDouble() else JSONObject.NULL)
                put("heading", if (location.hasBearing()) location.bearing.toDouble() else JSONObject.NULL)
            }
            arr.put(obj)
            while (arr.length() > MAX_NATIVE_TRAIL_POINTS) arr.remove(0)
            SecurePrefsHelper.putString(applicationContext, TRAIL_NATIVE_KEY, arr.toString())
        } catch (_: Exception) {}
    }

    private fun handleLocationUpdate(location: Location) {
        // Log.d(TAG, "handleLocationUpdate called: isVisible=$isVisible, isOnline=$isOnline, userId=$userId, userToken=${if (userToken != null) "present" else "null"}, location=${location.latitude},${location.longitude}")
        
        if (userId == null) return
        if (userToken == null) {
            // Log.w(TAG, "Skipping location update (user logged out - no JWT token)")
            return
        }
        if (authPermanentlyFailed) {
            // Log.w(TAG, "Skipping location update (auth permanently failed)")
            return
        }

        // Pinned home-base: heartbeat only, never upload live GPS.
        if (isPinnedLocationActive()) {
            if (!wasPinnedSkipping) {
                wasPinnedSkipping = true
                logEvent("📌 Pinned location ACTIVE — GPS paused, GPS not accessed for upload (heartbeat only)")
            }
            if (isOnline) {
                serviceScope.launch {
                    try {
                        ensureValidJwt()
                    } catch (_: Exception) {}
                    updateUserActivity()
                }
            }
            return
        }
        if (wasPinnedSkipping) {
            wasPinnedSkipping = false
            logEvent("▶️ Pinned location REMOVED/expired — GPS resumed")
        }

        // If invisible and not online, do nothing
        if (!isVisible && !isOnline) {
            // Log.d(TAG, "Skipping location update: isVisible=$isVisible, isOnline=$isOnline")
            return
        }

        // Offline + Retro Matching opt-in: keep the place on-device for
        // retroactive matching instead of attempting doomed uploads. GPS
        // works without internet; Supabase does not. The Dart side merges
        // this encrypted buffer into the encrypted Hive trail and uploads
        // everything when connectivity returns (the Dart recorder only runs
        // while the app UI is alive, so the two never duplicate a point).
        if (!isOnline) {
            if (isRetroOfflineTrailEnabled()) {
                appendOfflineTrailPoint(location)
            }
            return
        }

        serviceScope.launch {
            try {
                if (isVisible) {
                    // Normal behavior: Update location (which updates activity) and match engine
                    logEvent("handleLocationUpdate: uploading to Supabase (visible=$isVisible)")
                    updateLocationInSupabase(location)
                } else if (isOnline) {
                    // Invisible but Online: ONLY update user activity
                    // Log.d(TAG, "User invisible but online: Updating activity only")
                    try {
                        ensureValidJwt()
                    } catch (_: Exception) {}
                    updateUserActivity()
                }
            } catch (e: Exception) {
                logLocationUpdateFailure("Failed to handle location update", e)
            }
        }
    }

    private suspend fun updateLocationInSupabase(location: Location) {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return

        // Keep JWT valid so location RPC works after reboot.
        try {
            ensureValidJwt()
        } catch (_: Exception) {}

        // Log.d(TAG, "Updating location in Supabase: lat=${location.latitude}, lng=${location.longitude}")

        val url = "$supabaseUrl/rest/v1/rpc/update_user_location"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
            put("p_latitude", location.latitude)
            put("p_longitude", location.longitude)
            put("p_speed", location.speed)
            put("p_heading", location.bearing)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val request = okhttp3.Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Authorization", bearerAuthHeader())
            .addHeader("Content-Type", "application/json")
            .build()

        var response: Response? = null
        try {
            response = httpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                
                // Handle errors gracefully
                when (response.code) {
                    404, 409 -> {
                        // 404: Foreign key constraint (user_id not in users table - user was deleted)
                        // 409: Conflict errors (can indicate user deletion scenarios)
                        if (errorBody?.contains("foreign key constraint") == true || 
                            errorBody?.contains("is not present in table") == true) {
                            // Log.d(TAG, "Location update skipped: user was deleted (graceful error ${response.code})")
                            // This is expected when a user is deleted between app startup and location sync
                            return
                        }
                        // Log.w(TAG, "Location update error ${response.code}: $errorBody")
                    }
                    401 -> {
                        // Retry with refreshed token
                        if (!refreshToken.isNullOrBlank()) {
                            // Log.w(TAG, "Location update 401. Attempting JWT refresh + retry...")
                            try {
                                refreshJwtToken(refreshToken!!)
                            } catch (e: Exception) {
                                // Log.w(TAG, "JWT refresh failed during location retry", e)
                            }
                            response.close()

                            val retryReq = request.newBuilder()
                                .removeHeader("Authorization")
                                .addHeader("Authorization", bearerAuthHeader())
                                .build()
                            response = httpClient.newCall(retryReq).execute()
                            if (!response.isSuccessful) {
                                val retryBody = response.body?.string()
                                // Log.e(TAG, "Failed to update location after retry: ${response.code}, ${response.message}, body: $retryBody")
                            } else {
                                val responseBody = response.body?.string()
                                // Log.d(TAG, "Successfully updated location (after retry): $responseBody")
                                checkForNotifications()
                            }
                            return
                        }
                        // Log.e(TAG, "Location update failed (401 auth error): $errorBody")
                    }
                    else -> {
                        // Log.e(TAG, "Failed to update location: ${response.code}, ${response.message}, body: $errorBody")
                    }
                }
            } else {
                val responseBody = response.body?.string()
                // Log.d(TAG, "Successfully updated location: $responseBody")
                
                // After successful location update, check for notifications
                checkForNotifications()
            }
        } catch (e: Exception) {
            logLocationUpdateFailure("Exception updating location", e)
        } finally {
            response?.close()
        }
    }

    private fun logLocationUpdateFailure(message: String, error: Throwable) {
        if (isTransientNetworkError(error)) {
            logTransientLocationFailure(message, error)
            return
        }
        // Log.e(TAG, message, error)
    }

    private fun logTransientLocationFailure(message: String, error: Throwable) {
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

    private fun showTranslatedNotification(
        senderName: String,
        content: String,
        messageId: String,
        matchId: String? = null,
        shouldAlertOverride: Boolean? = null,
        modelTitle: String? = null,
        previewLines: List<String> = emptyList(),
        unreadCount: Int = 0,
        previewsEnabledFlag: Boolean? = null,
    ) {
        // Log.d(TAG, "[ANDROID] Showing translated notification: sender='$senderName', content='$content', matchId='$matchId'")

        // Settings enforcement: killed/background paths bypass Dart's gates.
        if (!chatPushEnabled()) {
            return
        }

        // Same message can arrive via several paths (Realtime plugin, FCM,
        // RPC poll). Only the first one alerts; later ones must not buzz
        // again for an identical message (checked across process restarts
        // too — see wasMessageBuzzed).
        if (wasMessageBuzzed(messageId)) {
            return
        }

        val effectiveMatchId = matchId ?: "unknown"

        // Previews off is checked twice on purpose: the server masks the copy
        // it puts in the payload, and the local preference is re-read here
        // because it can have changed since that push was produced. Either one
        // off means the card quotes no text, only the backlog.
        val previewsOff = !isMessagePreviewsEnabled() || previewsEnabledFlag == false
        val hasCount = unreadCount > 0
        // Previews off and no count in the payload (the Realtime path reports one
        // message, not a backlog): this card may only state how much is waiting,
        // so hand over to the poll, which reads the real per-chat count.
        if (previewsOff && !hasCount) {
            serviceScope.launch {
                checkForNotifications(messageId, effectiveMatchId)
            }
            return
        }
        val lines = if (previewsOff) {
            emptyList()
        } else {
            previewLines.map { it.trim() }.filter { it.isNotEmpty() }.takeLast(maxPreviewLines)
        }
        val maskedSender = maskFullName(senderName)
        // A payload that carries no count must not claim one: the card names the
        // sender instead of inventing a total.
        val count = if (hasCount) unreadCount else 1

        // Check if we should show notification alert (skip alert if viewing chat AND app is in foreground)
        val isViewingThisChat = effectiveMatchId == currentlyViewingChatId
        if (isViewingThisChat && appInForeground) return

        val title = when {
            !modelTitle.isNullOrBlank() -> modelTitle
            hasCount -> chatMessagesTitle(count, maskedSender)
            else -> maskedSender
        }
        val body = when {
            previewsOff -> openToReadBody(count)
            content.isNotBlank() -> content
            lines.size == 1 -> lines[0]
            else -> openToReadBody(count)
        }

        val shouldAlert = shouldAlertOverride ?: !wasChatNotificationAlerted(effectiveMatchId)

        if (!wasMessageBuzzed(messageId)) {
            // Use the chat ID hash as the notification ID so all messages from the same
            // chat group together (was previously senderName.hashCode(), which could
            // collide when two chats have senders with the same name hash).
            val notificationId = effectiveMatchId.hashCode()

            // Collapse the FCM SDK's tagged card onto this one (single tray
            // entry per chat). Silent when a fresh server card was just
            // dropped while the app is not foreground: delivery already
            // buzzed for this message.
            val replacedFreshServerCard = removeServerChatCard(effectiveMatchId)

            // Log.d(TAG, "[ANDROID] Showing notification: sender='$senderName', content='$content', silent=$isViewingThisChat")
            showNotification(
                title = title,
                content = body,
                notificationId = notificationId,
                matchId = effectiveMatchId,
                silent = isViewingThisChat || !shouldAlert || (replacedFreshServerCard && !appInForeground),
                soundEnabled = shouldAlert && chatSoundEnabled(),
                previewLines = lines,
            )
            activeNotificationIds[effectiveMatchId] = notificationId

            // Update last notified
            lastNotifiedMatchId = effectiveMatchId
            if (shouldAlert) recordChatNotificationAlerted(effectiveMatchId)
            recordMessageBuzzed(messageId)
            // Log.d(TAG, "Set lastNotifiedMatchId to: $effectiveMatchId, stored notificationId: $notificationId")
        } else {
            // Log.d(TAG, "[ANDROID] Skipping notification - currently viewing chat and app is in foreground: $effectiveMatchId")
        }
    }

    private suspend fun checkForNotifications(
        specificMessageId: String? = null,
        serverCardMatchId: String? = null
    ) {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return
        // A session whose refresh already failed permanently cannot poll:
        // sending its dead token produced a silent 401 every cycle.
        if (authPermanentlyFailed) return

        // Throttle notification checks to prevent excessive calls. Specific
        // requests (a message id from FCM/Realtime) are immediate triggers
        // and must not be swallowed by a check that ran moments earlier.
        if (specificMessageId == null) {
            val now = System.currentTimeMillis()
            if (now - lastNotificationCheckTime < notificationCheckThrottleMs) {
                // Log.d(TAG, "Skipping notification check - throttled (last check: ${now - lastNotificationCheckTime}ms ago)")
                return
            }
            lastNotificationCheckTime = now
        }

        // The FCM SDK's tagged card for this chat (drawn by the push that
        // triggered this check) is superseded the moment this request runs:
        // drop it up front — even when the RPC ends up answering "nothing
        // unread" — and remember whether it had just buzzed so the
        // replacement card stays silent. Only for explicit message requests:
        // match-triggered checks must not cancel a chat card.
        val capturedServerCardFresh =
            if (!serverCardMatchId.isNullOrBlank() && specificMessageId != null) {
                removeServerChatCard(serverCardMatchId)
            } else {
                false
            }

        // Keep the JWT fresh even when Dart is gone (killed app / Doze): the
        // poll is the only notification safety net in that state.
        try { ensureValidJwt() } catch (_: Exception) {}

        // Log.d(TAG, "Checking for notifications via RPC... (Message ID: $specificMessageId)")
        val url = "$supabaseUrl/rest/v1/rpc/check_unread_notifications"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
            if (specificMessageId != null) {
                put("p_message_id", specificMessageId)
            }
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val response = executeWithFreshJwt {
            okhttp3.Request.Builder()
                .url(url)
                .post(requestBody)
                .addHeader("apikey", supabaseKey!!)
                .addHeader("Authorization", bearerAuthHeader())
                .addHeader("Content-Type", "application/json")
                .build()
        } ?: return

        try {
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                // Log.d(TAG, "Notification check response: $responseBody")
                if (responseBody != null) {
                    // Response is a JSON array with one object
                    val jsonArray = org.json.JSONArray(responseBody)
                    if (jsonArray.length() > 0) {
                        val data = jsonArray.getJSONObject(0)
                        val unreadMatches = data.optInt("unread_matches_count", 0)
                        val unreadMessages = data.optInt("unread_messages_count", 0)
                        
                        if (unreadMatches > 0) {
                            val rawMatchName = data.optString("latest_match_name", "Someone")
                            // Normalize through maskFullName ("John S.") so the
                            // match card always matches the format the app's other
                            // screens use - regardless of which producer wrote the
                            // name (RPC, server push, older raw payloads).
                            // Hashing keeps the raw name: the notify-id and the
                            // legacy match-id fallback must stay stable.
                            val matchName = maskFullName(rawMatchName)
                            val matchId = data.optString("latest_match_id", "")

                            // Fallback to hash if ID is missing (backward compatibility with old RPC)
                            val effectiveMatchId = if (matchId.isNotEmpty()) matchId else rawMatchName.hashCode().toString()
                            
                            if (!wasMatchBuzzed(effectiveMatchId)) {
                                if (isMatchPushInTray(effectiveMatchId)) {
                                    // Server push already displayed this match
                                    // — record it as buzzed so the poll, the
                                    // realtime path and the WorkManager
                                    // fallback never re-buzz it either.
                                    recordMatchBuzzed(effectiveMatchId)
                                } else {
                                    // Log.d(TAG, "Found new unread match: $matchName (ID: $effectiveMatchId)")
                                    // Match cards share an ID with the Dart FCM renderer.
                                    val matchNotifyId = if (matchId.isNotEmpty()) {
                                        matchId.hashCode()
                                    } else {
                                        matchName.hashCode()
                                    }
                                    showNotification(
                                        "New Match!",
                                        "You matched with $matchName!",
                                        matchNotifyId,
                                        effectiveMatchId,
                                        onlyAlertOnce = true,
                                        soundEnabled = matchSoundEnabled(),
                                    )
                                    activeMatchNotificationIds[effectiveMatchId] = matchNotifyId
                                    recordMatchBuzzed(effectiveMatchId)
                                }
                            } else {
                                // Log.d(TAG, "Skipping duplicate match notification for ID: $effectiveMatchId")
                                // Already buzzed earlier (Realtime/poll recorded it).
                                // A delayed FCM delivery or a queue retry can still
                                // draw the SDK's tagged card next to our own: drop
                                // it while our own card is actually showing so the
                                // match keeps exactly one tray entry.
                                val ourNotifyId = activeMatchNotificationIds[effectiveMatchId]
                                val ourCardActive = ourNotifyId != null &&
                                    notificationManager.activeNotifications.any {
                                        it.id == ourNotifyId && it.tag == null
                                    }
                                if (ourCardActive && isMatchPushInTray(effectiveMatchId)) {
                                    cancelServerMatchCard(effectiveMatchId)
                                }
                            }
                        } else if (unreadMessages > 0) {
                            // The RPC cannot decrypt (chats are end-to-end
                            // encrypted) and returns no message body, so this
                            // path builds the card from the backlog alone: how
                            // many are waiting in this chat, never what they
                            // say. Step aside when previews are on or an
                            // enabled translation is still pending, because
                            // then the push payload is the only source allowed
                            // to quote text.
                            val rawSender = data.optString("latest_message_sender", "Someone")
                            val sender = if (rawSender.isBlank() || rawSender == "null") "Someone" else rawSender
                            if (isMessagePreviewsEnabled() || data.optBoolean("translation_enabled", false)) {
                                return@checkForNotifications
                            }
                            val messageId = data.optString("latest_message_id", "")
                            val matchId = data.optString("latest_match_id", "")
                            // unread_messages_count is the total across chats and
                            // the specific-message branch pins it at 1, so the
                            // per-chat figure comes from its own column.
                            val chatUnreadCount = data.optInt("latest_chat_unread_count", 0).coerceAtLeast(1)


                            // Validate that this is actually an unread message
                            // The RPC function should only return unread messages, but double-check
                            if (messageId.isEmpty()) {
                                // Log.d(TAG, "[ANDROID] Skipping notification - message ID is empty (RPC returned inconsistent data)")
                                return@checkForNotifications
                            }

                            // One alert per message across all trigger paths
                            // (FCM push, Realtime, poll) — RAM + prefs, so a
                            // process restart cannot re-buzz either.
                            if (wasMessageBuzzed(messageId)) {
                                return@checkForNotifications
                            }

                            // Use match ID for deduplication - one notification per chat
                            val effectiveChatId = if (matchId.isNotEmpty()) matchId else sender.hashCode().toString()

                            // The chat's FCM card may already be showing (drawn
                            // while the app was killed/backgrounded, so no code
                            // recorded the buzz). That card is the notification
                            // for this message: record it and leave the card —
                            // re-posting here would buzz a second time for the
                            // same message right after the app restarts.
                            if (isChatPushInTray(effectiveChatId)) {
                                lastNotifiedMatchId = effectiveChatId
                                recordMessageBuzzed(messageId)
                                return@checkForNotifications
                            }

                            // If specificMessageId was requested, we ALWAYS notify, ignoring deduplication
                            // This is because Realtime triggered it, so it MUST be new
                            val isSpecificRequest = specificMessageId != null && specificMessageId == messageId

                            // Don't show notifications when viewing the chat AND app is in foreground
                            val isViewingThisChat = effectiveChatId == currentlyViewingChatId
                            if (isViewingThisChat && appInForeground) {
                                // Log.d(TAG, "[ANDROID] Skipping notification - currently viewing chat and app is in foreground: $effectiveChatId")
                                return@checkForNotifications
                            }

                            // Allow notification if:
                            // 1. It's a specific request (immediate trigger), OR
                            // 2. It's not a duplicate
                            val shouldAlert = !wasChatNotificationAlerted(effectiveChatId)

                            if (isSpecificRequest || !wasMessageBuzzed(messageId)) {
                                // Use the chat ID hash as the notification ID so all messages from the same
                                // chat group together (was previously sender.hashCode(), which could
                                // collide when two chats have senders with the same name hash).
                                val notificationId = effectiveChatId.hashCode()
                                // Collapse the FCM SDK's tagged card onto this
                                // one (see removeServerChatCard): one tray
                                // entry per chat no matter which path fired.
                                // The up-front capture already dropped the
                                // card this request was triggered by; skip a
                                // redundant second scan in that case.
                                val replacedFreshServerCard =
                                    (capturedServerCardFresh &&
                                        serverCardMatchId == effectiveChatId) ||
                                        removeServerChatCard(effectiveChatId)
                                showNotification(
                                    title = chatMessagesTitle(chatUnreadCount, maskFullName(sender)),
                                    content = openToReadBody(chatUnreadCount),
                                    notificationId = notificationId,
                                    matchId = matchId,
                                    silent = isViewingThisChat || !shouldAlert || (replacedFreshServerCard && !appInForeground),
                                    soundEnabled = shouldAlert && chatSoundEnabled(),
                                )
                                activeNotificationIds[effectiveChatId] = notificationId

                                lastNotifiedMatchId = effectiveChatId
                                if (shouldAlert) recordChatNotificationAlerted(effectiveChatId)
                                recordMessageBuzzed(messageId)
                            } else {
                                // Log.d(TAG, "[ANDROID] Skipping duplicate message notification for chat ID: $effectiveChatId (lastNotifiedMatchId: $lastNotifiedMatchId, isSpecificRequest: $isSpecificRequest)")
                            }
                        } else {
                            // Log.d(TAG, "No new notifications found")
                        }
                    }
                }
            } else {
                val errorBody = response.body?.string()
                // Log.e(TAG, "Notification check failed: ${response.code}, body: $errorBody")
            }
        } catch (e: Exception) {
            // Log.e(TAG, "Error checking notifications", e)
        } finally {
            // Early returns inside the block above must not leak the response.
            try { response.close() } catch (_: Exception) {}
            // Late/redelivered pushes draw server cards invisibly (no client
            // hook for notification+data while backgrounded); converge the
            // tray on every check so one card per chat/match is enforced,
            // including the early-return paths above.
            sweepDuplicateServerCards()
        }
    }

    // Notification limits (mirrors lib/utils/notification_limits.dart,
    // supabase/functions/_shared/notification_limits.ts).
    // FCM/APNs = 4096 bytes; byte-based because Hebrew/emoji are multi-byte.
    private fun notifUtf8Bytes(s: String): Int = s.toByteArray(Charsets.UTF_8).size

    private fun truncateNotifBytes(s: String, maxBytes: Int): String {
        if (notifUtf8Bytes(s) <= maxBytes) return s
        val budget = maxBytes - 3 // reserve for …
        if (budget <= 0) return ""
        val out = StringBuilder()
        var used = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val charCount = Character.charCount(cp)
            val ch = s.substring(i, i + charCount)
            val b = ch.toByteArray(Charsets.UTF_8).size
            if (used + b > budget) break
            out.append(ch)
            used += b
            i += charCount
        }
        return "$out…"
    }

    // See ChatNotificationCopy.maskFullName - the same rule the server's
    // mask_full_name applies, shared with the WorkManager fallback card.
    private fun maskFullName(raw: String?): String =
        ChatNotificationCopy.maskFullName(raw)

    private fun showNotification(
        title: String,
        content: String,
        notificationId: Int? = null,
        matchId: String? = null,
        silent: Boolean = false,
        onlyAlertOnce: Boolean = false,
        soundEnabled: Boolean = true,
        previewLines: List<String> = emptyList(),
    ) {
        // Transport/display guard: never overflow tray or FCM 4KB budget.
        val safeTitle = truncateNotifBytes(title.trim(), 500)
        val safeContent = truncateNotifBytes(content.trim(), 1500)
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        
        // Use provided ID or fallback to timestamp (unique per call)
        val notifyId = notificationId ?: System.currentTimeMillis().toInt()

        // Create intent to open app
        val safeMatchId = matchId?.trim().orEmpty()
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            // Bring existing task to front when possible; deliver intent via onNewIntent (launchMode=singleTop).
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (safeMatchId.isNotEmpty()) {
                putExtra("route", "/chat/$safeMatchId")
                putExtra("matchId", safeMatchId)
            }
        }
        
        val pendingIntent = if (intent != null) {
            // Unique requestCode per notification/chat so older notifications open the right conversation.
            val requestCode = if (safeMatchId.isNotEmpty()) safeMatchId.hashCode() else notifyId
            PendingIntent.getActivity(
                this, 
                requestCode, 
                intent, 
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else {
            null
        }

        // Small icon must be white-on-transparent (Material); launcher/mipmap is wrong here.
        val iconId = try {
            resources.getIdentifier("ic_stat_matchme", "drawable", packageName)
        } catch (e: Exception) {
            0
        }

        val validIconId = if (iconId != 0) iconId else android.R.drawable.ic_popup_reminder

        // Log.d(TAG, "Building notification with iconId: $validIconId (found: ${iconId != 0})")

        val notificationBuilder = NotificationCompat.Builder(this, ALERTS_CHANNEL_ID)
            .setSmallIcon(validIconId)
            .setColor(ContextCompat.getColor(this, R.color.notification_accent))
            .setPriority(if (silent) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setDefaults(if (silent || !soundEnabled) 0 else NotificationCompat.DEFAULT_ALL) // Respect sound preference
            .setOnlyAlertOnce(silent || onlyAlertOnce)
            .setContentIntent(pendingIntent)
            // Bundle with the other conversation cards under the unread-badge
            // carrier, which is posted as this group's summary
            // (MatchMeBadgeController). Without a group every chat sits in the
            // tray on its own next to a standalone "N unread" card.
            .setGroup(MatchMeBadgeController.GROUP_KEY_CHATS)
            // This card, not the summary, is the one allowed to alert.
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            // Lets the badge carrier (this group's summary) disappear with the
            // last conversation card instead of outliving it as a standalone
            // "N unread" card. See MatchMeBadgeCleanupReceiver.
            .setDeleteIntent(MatchMeBadgeController.deleteIntent(this))

        // The sender's face in the largeIcon slot, which is the one place a
        // tray card shows a picture beside the name rather than per row. Plain
        // decoration: a conversation whose avatar was never mirrored, or was
        // evicted with the chat, posts the same card without it.
        if (safeMatchId.isNotEmpty()) {
            try {
                NotificationAvatarStore.bitmapFor(this, safeMatchId)
                    ?.let { notificationBuilder.setLargeIcon(it) }
            } catch (_: Exception) {
            }
        }

        // The collapsed card is title + body; expanding adds the unread lines
        // the server already ordered oldest-first and byte-capped. One line is
        // the body itself, so a style would repeat it.
        //
        // InboxStyle and not MessagingStyle: MessagingStyle draws the sender's
        // Person icon on every row and ignores largeIcon, so it can never give
        // the one-avatar-beside-the-name layout the tray is moving to, and it
        // titles itself "N messages" from its own count rather than the
        // server's localized copy.
        val lines = previewLines
            .map { truncateNotifBytes(it.trim(), 500) }
            .filter { it.isNotEmpty() }
            .takeLast(maxPreviewLines)

        notificationBuilder.setContentTitle(safeTitle)
        notificationBuilder.setContentText(safeContent)
        if (lines.size > 1) {
            val style = NotificationCompat.InboxStyle().setBigContentTitle(safeTitle)
            lines.forEach { style.addLine(it) }
            notificationBuilder.setStyle(style)
        }

        val notification = notificationBuilder.build()
        
        // Use a unique ID for message notifications so they stack or replace as needed
        // Log.d(TAG, "Showing notification ID: $notifyId")
        notificationManager.notify(notifyId, notification)
    }



    private fun startHeartbeat() {
        serviceScope.launch {
            while (isActive) {
                try {
                    ensureValidJwt()
                    updateUserActivity()
                    checkVisibilityFromDbIfNeeded()
                    // Cards posted through flutter_local_notifications cannot
                    // carry a delete intent, so a swipe of the last one would
                    // leave the badge carrier alone in the tray until the next
                    // badge update. Cheap idempotent sweep, once per heartbeat.
                    try {
                        MatchMeBadgeController.syncCarrierPresence(applicationContext)
                    } catch (_: Throwable) {}

                    // Pinned-state transition watcher. isPinnedLocationActive()
                    // is time-based, so this catches both scheduled expiry and
                    // a pin cleared/activated server-side (e.g. set from
                    // another device) while the UI is closed. Idempotent with
                    // ACTION_UPDATE_PINNED_STATE: both just re-run
                    // updateForegroundState + start/stopLocationUpdates.
                    val pinnedNow = isPinnedLocationActive()
                    val pinnedBefore = lastHeartbeatPinnedActive
                    if (pinnedBefore != null && pinnedBefore != pinnedNow) {
                        logEvent("📌 Pinned location transition ($pinnedBefore -> $pinnedNow) detected by heartbeat — re-evaluating foreground/GPS")
                        updateForegroundState()
                        if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                    }
                    lastHeartbeatPinnedActive = pinnedNow

                    val hasRealtimeCredentials =
                        !userId.isNullOrBlank() &&
                        !supabaseUrl.isNullOrBlank() &&
                        !supabaseKey.isNullOrBlank() &&
                        (!userToken.isNullOrBlank() || !refreshToken.isNullOrBlank())

                    if (!hasRealtimeCredentials) {
                        delay(30000L)
                        continue
                    }

                    // Check Realtime connection health
                    val now = System.currentTimeMillis()
                    if (lastRealtimeActivity <= 0L) {
                        lastRealtimeActivity = now
                    }
                    val timeSinceLastActivity = now - lastRealtimeActivity

                    if (!isServiceAlive()) {
                        return@launch
                    }

                    // If no activity for 60 seconds (heartbeat is every 25s), assume dead
                    if (webSocket == null) {
                        // Log.d(TAG, "Realtime connection missing. Reconnecting...")
                        connectToRealtime()
                    } else if (timeSinceLastActivity > 60000) {
                        // Log.w(TAG, "Realtime connection stale (last activity: ${timeSinceLastActivity}ms ago). Reconnecting...")
                        disconnectRealtime(reason = "stale_or_missing") // Force close existing if any
                        connectToRealtime()
                    }
                } catch (e: Exception) {
                    // Log.e(TAG, "Heartbeat failed", e)
                }
                delay(30000L) // 30 seconds
            }
        }
    }

    private fun decodeJwtExpSeconds(token: String): Long? {
        return try {
            val parts = token.split('.')
            if (parts.size < 2) return null
            val payload = parts[1]
            val decoded = Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
            val json = JSONObject(String(decoded, Charsets.UTF_8))
            if (json.has("exp")) json.getLong("exp") else null
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Adopts the newest token pair this device knows about.
     *
     * Dart and this service rotate the same single-use refresh token from
     * different processes. Spending a copy the other side already rotated
     * returns `refresh_token_already_used`, and GoTrue then revokes the whole
     * family. Refresh tokens are opaque, so the paired access token's `exp` is
     * the only freshness signal: the newest pair wins and is written back to
     * the shared prefs so both sides converge.
     */
    private fun adoptNewestKnownTokens(): Boolean {
        val ownExp = userToken?.let { decodeJwtExpSeconds(it) } ?: Long.MIN_VALUE
        var bestAccess = userToken
        var bestRefresh = refreshToken
        var bestExp = ownExp

        // Dart's writeAuthTokens mirror, written atomically with the pair.
        val prefsAccess = try { SecurePrefsHelper.getString(this, "flutter.user_token", null)?.trim() } catch (_: Exception) { null }
        val prefsRefresh = try { SecurePrefsHelper.getString(this, "flutter.refresh_token", null)?.trim() } catch (_: Exception) { null }
        val prefsExp = prefsAccess?.takeIf { it.isNotBlank() }?.let { decodeJwtExpSeconds(it) }
        if (!prefsAccess.isNullOrBlank() && prefsExp != null && prefsExp > bestExp) {
            bestAccess = prefsAccess
            bestRefresh = prefsRefresh
            bestExp = prefsExp
        }

        // The dual-stored session snapshot, written by Dart on every auth
        // event and by this service after its own rotations.
        try {
            val raw = SecurePrefsHelper.getString(this, "persisted_supabase_session", null)
            if (!raw.isNullOrBlank()) {
                val current = JSONObject(raw).optJSONObject("currentSession")
                val snapAccess = current?.optString("access_token", "")?.trim()
                val snapRefresh = current?.optString("refresh_token", "")?.trim()
                val snapExp = snapAccess?.takeIf { it.isNotBlank() }?.let { decodeJwtExpSeconds(it) }
                if (!snapAccess.isNullOrBlank() && snapExp != null && snapExp > bestExp) {
                    bestAccess = snapAccess
                    if (!snapRefresh.isNullOrBlank()) bestRefresh = snapRefresh
                    bestExp = snapExp
                }
            }
        } catch (_: Exception) {}

        if (bestAccess.isNullOrBlank() || bestExp <= ownExp) return false
        userToken = bestAccess
        if (!bestRefresh.isNullOrBlank()) refreshToken = bestRefresh
        // Adoption is not proof of life: the adopted pair may be just as
        // revoked as the one this process held. The flag clears only on a
        // successful refresh or an explicit new/changed token from Dart
        // (ACTION_START / ACTION_UPDATE_TOKEN).
        try {
            SecurePrefsHelper.putString(this, "flutter.user_token", userToken)
            if (!refreshToken.isNullOrBlank()) {
                SecurePrefsHelper.putString(this, "flutter.refresh_token", refreshToken)
            }
        } catch (_: Exception) {}
        return true
    }

    private suspend fun ensureValidJwt() {
        // Never spend a token the other process already rotated: adopt the
        // newest known pair before deciding whether a refresh is due.
        adoptNewestKnownTokens()

        if (authPermanentlyFailed) {
            return
        }

        val token = userToken
        val rt = refreshToken

        if (rt.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) {
            return
        }

        // When the Flutter UI is in the foreground, Dart is the sole owner of
        // token rotation; its newest pair was already adopted above.
        if (appInForeground) {
            return
        }

        // If token is missing but we have a refresh token, try to refresh immediately
        if (token.isNullOrBlank()) {
            refreshJwtToken(rt)
            return
        }

        val exp = decodeJwtExpSeconds(token) ?: return
        val now = System.currentTimeMillis() / 1000L
        val secondsLeft = exp - now

        // Refresh when close to expiry (2 minutes).
        if (secondsLeft > 120) return

        if (secondsLeft <= 0) {
            // Log.w(TAG, "JWT already expired ($secondsLeft s). Refreshing in background service...")
        } else {
            // Log.d(TAG, "JWT expiring soon ($secondsLeft s). Refreshing in background service...")
        }
        refreshJwtToken(rt)
    }

    /**
     * Executes [build] and, when the server rejects the bearer token with a
     * 401, refreshes the access token once and retries the request a single
     * time. Returns null when the request failed to execute or no retry is
     * possible — callers own closing the returned response.
     *
     * Shared fix for the recurring okhttp 401s on
     * check_unread_notifications / update_user_activity / report_client_error:
     * those paths kept sending the token captured at session start, so every
     * background cycle silently failed until the app was reopened.
     */
    private suspend fun executeWithFreshJwt(build: () -> okhttp3.Request): okhttp3.Response? {
        repeat(2) { attempt ->
            val request = try {
                build()
            } catch (_: Exception) {
                return null
            }
            val response = try {
                httpClient.newCall(request).execute()
            } catch (_: Exception) {
                return null
            }
            if (response.code != 401 || attempt == 1) {
                return response
            }
            try { response.close() } catch (_: Exception) {}

            // A newer pair may have arrived from Dart since this request was
            // built; retry with it instead of spending the older refresh token.
            if (adoptNewestKnownTokens()) {
                val adoptedExp = userToken?.let { decodeJwtExpSeconds(it) } ?: 0L
                if (adoptedExp - System.currentTimeMillis() / 1000L > 120L) {
                    return@repeat
                }
            }

            // Access token rejected: refresh once, then rebuild with the new
            // bearer header and retry.
            val rt = refreshToken
            if (rt.isNullOrBlank()) {
                return null
            }
            refreshJwtToken(rt)
            if (authPermanentlyFailed || userToken.isNullOrBlank()) {
                return null
            }
        }
        return null
    }

    private suspend fun syncTokensToDartStorage(newAccessToken: String, newRefreshToken: String?, fullResponse: JSONObject) {
        try {
            val prefs = securePrefs()
            val expiresIn = fullResponse.optInt("expires_in", 3600)
            val expiresAt = (System.currentTimeMillis() / 1000L) + expiresIn
            // Update persisted_supabase_session if it exists (encrypted store)
            val persisted = SecurePrefsHelper.getString(this, "persisted_supabase_session", null)
            if (!persisted.isNullOrBlank()) {
                try {
                    val outer = JSONObject(persisted)
                    val current = outer.optJSONObject("currentSession")
                    if (current != null) {
                        current.put("access_token", newAccessToken)
                        if (!newRefreshToken.isNullOrBlank()) {
                            current.put("refresh_token", newRefreshToken)
                        }
                        current.put("expires_in", expiresIn)
                        current.put("expires_at", expiresAt)
                        // Update user if present in response
                        val userObj = fullResponse.optJSONObject("user")
                        if (userObj != null) {
                            current.put("user", userObj)
                        }
                        outer.put("currentSession", current)
                        outer.put("expiresAt", expiresAt)
                        SecurePrefsHelper.putString(this, "persisted_supabase_session", outer.toString())
                    }
                } catch (_: Exception) {
                    // If parsing fails, write a minimal session for Dart recovery
                    try {
                        val userObj = fullResponse.optJSONObject("user")
                        if (userObj != null) {
                            val minimalSession = JSONObject().apply {
                                put("access_token", newAccessToken)
                                if (!newRefreshToken.isNullOrBlank()) put("refresh_token", newRefreshToken)
                                put("expires_in", expiresIn)
                                put("expires_at", expiresAt)
                                put("token_type", "bearer")
                                put("user", userObj)
                            }
                            val outer = JSONObject().apply {
                                put("currentSession", minimalSession)
                                put("expiresAt", expiresAt)
                            }
                            SecurePrefsHelper.putString(this, "persisted_supabase_session", outer.toString())
                        }
                    } catch (_: Exception) {}
                }
            } else {
                // No existing persisted session, create one for Dart recovery
                try {
                    val userObj = fullResponse.optJSONObject("user")
                    if (userObj != null) {
                        val minimalSession = JSONObject().apply {
                            put("access_token", newAccessToken)
                            if (!newRefreshToken.isNullOrBlank()) put("refresh_token", newRefreshToken)
                            put("expires_in", expiresIn)
                            put("expires_at", expiresAt)
                            put("token_type", "bearer")
                            put("user", userObj)
                        }
                        val outer = JSONObject().apply {
                            put("currentSession", minimalSession)
                            put("expiresAt", expiresAt)
                        }
                        SecurePrefsHelper.putString(this, "persisted_supabase_session", outer.toString())
                    }
                } catch (_: Exception) {}
            }
            // Also try to update supabase.auth.token if present (SDK's key)
            val sbToken = SecurePrefsHelper.getString(this, "supabase.auth.token", null)
            if (!sbToken.isNullOrBlank()) {
                try {
                    val outer = JSONObject(sbToken)
                    val current = outer.optJSONObject("currentSession") ?: outer
                    if (current != null) {
                        current.put("access_token", newAccessToken)
                        if (!newRefreshToken.isNullOrBlank()) current.put("refresh_token", newRefreshToken)
                        current.put("expires_at", expiresAt)
                        // Preserve structure
                        if (outer.has("currentSession")) {
                            outer.put("currentSession", current)
                            outer.put("expiresAt", expiresAt)
                            SecurePrefsHelper.putString(this, "supabase.auth.token", outer.toString())
                        } else {
                            // Direct session object
                            SecurePrefsHelper.putString(this, "supabase.auth.token", current.toString())
                        }
                    }
                } catch (_: Exception) {}
            }
            // Also handle sb-<ref>-auth-token keys used by newer supabase_flutter
            try {
                val allKeys = prefs.all.keys
                for (key in allKeys) {
                    if (SecurePrefsHelper.isSensitiveKey(key)) {
                        val valStr = SecurePrefsHelper.getString(this, key, null) ?: continue
                        if (valStr.isBlank()) continue
                        try {
                            val obj = JSONObject(valStr)
                            // Supabase Dart stores as {currentSession: {...}, expiresAt: ...} or direct session
                            val current = obj.optJSONObject("currentSession") ?: obj
                            current.put("access_token", newAccessToken)
                            if (!newRefreshToken.isNullOrBlank()) current.put("refresh_token", newRefreshToken)
                            current.put("expires_at", expiresAt)
                            if (obj.has("currentSession")) {
                                obj.put("currentSession", current)
                                obj.put("expiresAt", expiresAt)
                                SecurePrefsHelper.putString(this, key, obj.toString())
                            } else {
                                SecurePrefsHelper.putString(this, key, current.toString())
                            }
                        } catch (_: Exception) {}
                    }
                }
            } catch (_: Exception) {}
        } catch (_: Exception) {}
    }

    /** True when [token] is the exact refresh token the auth server refused. */
    private fun isRejectedRefreshToken(token: String?): Boolean {
        val candidate = token?.trim()
        return !candidate.isNullOrEmpty() && candidate == rejectedRefreshToken
    }

    /** Remembers a server-rejected refresh token across process restarts. */
    private fun rememberRejectedRefreshToken(token: String?) {
        val candidate = token?.trim()
        if (candidate.isNullOrEmpty()) return
        rejectedRefreshToken = candidate
        try {
            SecurePrefsHelper.putString(this, "flutter.auth_rejected_refresh_token", candidate)
        } catch (_: Exception) {}
    }

    /** A successful refresh proves a new family; stop blocking the old token. */
    private fun forgetRejectedRefreshToken() {
        rejectedRefreshToken = null
        try {
            SecurePrefsHelper.putString(this, "flutter.auth_rejected_refresh_token", null)
        } catch (_: Exception) {}
    }

    private suspend fun refreshJwtToken(currentRefreshToken: String) {
        if (supabaseUrl == null || supabaseKey == null) return
        // Serialize concurrent refreshes to avoid rotating token reuse
        if (!refreshMutex.tryLock()) {
            // Another refresh in progress, skip
            return
        }
        try {
            // Adopt the newest pair Dart wrote before spending anything:
            // replaying a rotated token makes GoTrue revoke the whole family.
            if (adoptNewestKnownTokens()) {
                val adoptedExp = userToken?.let { decodeJwtExpSeconds(it) } ?: 0L
                if (adoptedExp - System.currentTimeMillis() / 1000L > 120L) return
            }
            val tokenToUse = refreshToken?.trim().takeUnless { it.isNullOrBlank() }
                ?: currentRefreshToken
            // Chokepoint for every caller (heartbeat, realtime connect, 401
            // retry): never send a token the server has already refused.
            if (authPermanentlyFailed && isRejectedRefreshToken(tokenToUse)) return

            val url = "${supabaseUrl}/auth/v1/token?grant_type=refresh_token"
            val jsonBody = JSONObject().apply {
                put("refresh_token", tokenToUse)
            }
            val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

            val request = okhttp3.Request.Builder()
                .url(url)
                .post(requestBody)
                .addHeader("apikey", supabaseKey!!)
                .addHeader("Content-Type", "application/json")
                .build()

            try {
                val response = httpClient.newCall(request).execute()
                val body = response.body?.string()
                if (!response.isSuccessful || body.isNullOrBlank()) {
                    // Handle token reuse race gracefully: check if Dart already refreshed
                    if (body?.contains("refresh_token_already_used") == true ||
                        body?.contains("invalid_grant") == true ||
                        body?.contains("refresh_token_not_found") == true) {
                        if (adoptNewestKnownTokens() &&
                            refreshToken != tokenToUse &&
                            !isRejectedRefreshToken(refreshToken)
                        ) {
                            // Dart refreshed concurrently and wrote a newer pair
                            // - adopt it and reconnect instead of marking failed.
                            try { securePrefs().edit().putBoolean("flutter.auth_permanently_failed", false).apply() } catch (_: Exception) {}
                            disconnectRealtime()
                            connectToRealtime()
                            response.close()
                            return
                        }
                        // Do not clear tokens destructively - just mark failed without deleting valid new tokens
                        // Keep current tokens for potential recovery, only set flag
                        rememberRejectedRefreshToken(tokenToUse)
                        authPermanentlyFailed = true
                        try { securePrefs().edit().putBoolean("flutter.auth_permanently_failed", true).apply() } catch (_: Exception) {}
                        // Do NOT remove flutter.user_token/refresh_token here - Dart may still have valid session
                    }
                    
                    response.close()
                    return
                }
                response.close()

                val json = JSONObject(body)
                val newAccessToken = json.optString("access_token", "")
                val newRefreshToken = json.optString("refresh_token", "")
                if (newAccessToken.isBlank()) {
                    return
                }

                userToken = newAccessToken
                if (newRefreshToken.isNotBlank()) {
                    refreshToken = newRefreshToken
                }

                // Persist so service restarts keep working. Use flutter.* keys to match restore.
                try {
                    SecurePrefsHelper.putString(this, "flutter.user_token", userToken)
                    if (!refreshToken.isNullOrBlank()) {
                        SecurePrefsHelper.putString(this, "flutter.refresh_token", refreshToken)
                    }
                    try { securePrefs().edit().putBoolean("flutter.auth_permanently_failed", false).apply() } catch (_: Exception) {}
                } catch (e: Exception) {
                }
                // Sync to Dart's persisted session storage for seamless recovery
                try {
                    syncTokensToDartStorage(newAccessToken, if (newRefreshToken.isNotBlank()) newRefreshToken else null, json)
                } catch (_: Exception) {}

                authPermanentlyFailed = false
                forgetRejectedRefreshToken()

                // Reconnect realtime with the new token.
                disconnectRealtime()
                connectToRealtime()
            } catch (e: Exception) {
            }
        } finally {
            try { refreshMutex.unlock() } catch (_: Exception) {}
        }
    }

    /**
     * True when the cached access token is usable right now.
     *
     * This tick (every 30 s, and on resume) can run while the token Dart just
     * refreshed is still being persisted, so the request used to go out with a
     * JWT that had already expired and spend its one attempt on a 401 (the
     * edge-log line at 2026-10-29T13:11:42Z carried a token 25 min past
     * `exp`). Refreshing first - which adopts Dart's newer pair before
     * spending the rotation - removes that round trip; skipping the tick when
     * no fresh token can be obtained is safe because the next tick retries in
     * 30 s.
     *
     * Tokens whose `exp` cannot be parsed are sent as before and left to the
     * 401 retry in [executeWithFreshJwt].
     */
    private suspend fun ensureFreshAccessToken(): Boolean {
        val secondsLeft = accessTokenSecondsLeft() ?: return true
        if (secondsLeft > 60L) return true
        refreshToken?.takeIf { it.isNotBlank() }?.let { refreshJwtToken(it) }
        if (authPermanentlyFailed) return false
        return (accessTokenSecondsLeft() ?: 0L) > 60L
    }

    private fun accessTokenSecondsLeft(): Long? {
        val token = userToken ?: return null
        val exp = decodeJwtExpSeconds(token) ?: return null
        return exp - System.currentTimeMillis() / 1000L
    }

    private suspend fun updateUserActivity() {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return
        if (authPermanentlyFailed) {
            // Log.w(TAG, "Skipping update_user_activity RPC (auth permanently failed)")
            return
        }
        if (userToken.isNullOrBlank()) {
            // Log.w(TAG, "Skipping update_user_activity RPC (missing user JWT)")
            return
        }
        if (!ensureFreshAccessToken()) {
            // Log.w(TAG, "Skipping update_user_activity RPC (no fresh JWT yet)")
            return
        }

        val url = "$supabaseUrl/rest/v1/rpc/update_user_activity"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        // Refresh-and-retry once on 401 so a rotated/expired token does not
        // turn the online heartbeat into a silent failure for the session.
        val response = executeWithFreshJwt {
            okhttp3.Request.Builder()
                .url(url)
                .post(requestBody)
                .addHeader("apikey", supabaseKey!!)
                .addHeader("Authorization", bearerAuthHeader())
                .addHeader("Content-Type", "application/json")
                .build()
        } ?: return

        try {
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                
                // Handle 400 errors gracefully (often indicates user data issues or deletion)
                if (response.code == 400) {
                    // Check if this is a "null value in is_visible column" error (user deleted during async operations)
                    if (errorBody?.contains("is_visible") == true || errorBody?.contains("not-null constraint") == true) {
                        // Log.d(TAG, "User activity update failed due to deleted user (graceful): ${response.code}")
                        // This is expected when a user is deleted; silently continue
                    } else {
                        // Log.e(TAG, "Failed to update user activity: ${response.code}, ${response.message}, body: $errorBody")
                    }
                } else if (response.code == 401 &&
                    (errorBody?.contains("JWT expired") == true ||
                     errorBody?.contains("invalid JWT") == true)
                ) {
                    userToken = null
                    try {
                        SecurePrefsHelper.remove(this, "flutter.user_token")
                    } catch (_: Exception) {
                    }
                    // Log.e(TAG, "Failed to update user activity (JWT expired): ${response.code}")
                } else {
                    // Log.e(TAG, "Failed to update user activity: ${response.code}, ${response.message}, body: $errorBody")
                }
            } else {
                // Log.d(TAG, "Successfully updated user activity")
            }
        } catch (e: Exception) {
            // Log.e(TAG, "Exception updating user activity: ${e.message}", e)
        } finally {
            response.close()
        }
    }

    // --- Realtime WebSocket Implementation ---

    private fun connectToRealtime() {
        if (supabaseUrl == null || supabaseKey == null) return
        if (!isServiceAlive()) {
            // Log.d(TAG, "Skipping Realtime connect (service not running)")
            return
        }
        if (!isOnline) {
            // Log.d(TAG, "Skipping Realtime connect (offline)")
            disconnectRealtime(reason = "offline")
            return
        }
        if (authPermanentlyFailed) {
            // Log.w(TAG, "Skipping Realtime connect (auth permanently failed)")
            return
        }
        // Don't connect with a null token; adopt the newest known pair first
        // (Dart may have rotated it while this service held the old one).
        adoptNewestKnownTokens()
        if (userToken.isNullOrBlank()) {
            val rt = refreshToken
            if (!rt.isNullOrBlank()) {
                // Log.d(TAG, "No access token; refreshing JWT before Realtime connect")
                serviceScope.launch {
                    refreshJwtToken(rt)
                    connectToRealtime()
                }
                return
            }
            // Log.d(TAG, "Skipping Realtime connect (no token and no refresh token)")
            return
        }

        val now = System.currentTimeMillis()
        synchronized(realtimeLock) {
            // Debounce repeated connect attempts (e.g., START + UPDATE_TOKEN + heartbeat).
            if (isRealtimeConnecting && (now - lastRealtimeConnectAttemptAt) < 2000) {
                // Log.d(TAG, "Skipping Realtime connect (already connecting)")
                return
            }

            if (webSocket != null) {
                // If socket exists, check if it's healthy
                val timeSinceLastActivity = now - lastRealtimeActivity
                if (timeSinceLastActivity < 60000) {
                    return // Healthy enough
                }
                // Log.w(TAG, "Existing WebSocket is stale (${timeSinceLastActivity}ms). Reconnecting.")
                disconnectRealtime(reason = "stale")
            }

            isRealtimeConnecting = true
            lastRealtimeConnectAttemptAt = now
        }

        // Log.d(TAG, "[NATIVE] connectToRealtime: start")
        realtimeConnectStartAt = System.currentTimeMillis()
        // Log.d(TAG, "Connecting to Supabase Realtime...")
        lastRealtimeActivity = now // Reset timer to give it a chance to connect
        
        // Construct WebSocket URL
        // Replace https:// with wss:// and append /realtime/v1/websocket
        val baseUrl = supabaseUrl!!.trimEnd('/')
        val wsUrl = baseUrl.replace("https://", "wss://") + "/realtime/v1/websocket?apikey=$supabaseKey&vsn=1.0.0"
        
        val request = okhttp3.Request.Builder()
            .url(wsUrl)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Authorization", "Bearer ${userToken ?: supabaseKey}")
            .build()

        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                locationShareHelper?.setRealtimeWebSocket(webSocket)
                val elapsed = System.currentTimeMillis() - realtimeConnectStartAt
                // Log.d(TAG, "[NATIVE] Realtime WebSocket Connected (elapsed=${elapsed}ms)")
                lastRealtimeActivity = System.currentTimeMillis()
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                    reconnectDelay = 1000L // Reset backoff
                    isRealtimeIntentionalClosePending = false
                }
                joinChannel(webSocket)
                startHeartbeat(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                // // Log.d(TAG, "Realtime Message: $text") // Verbose
                lastRealtimeActivity = System.currentTimeMillis()
                handleRealtimeMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                // Log.d(TAG, "Realtime WebSocket Closing: $code / $reason")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                // Log.d(TAG, "Realtime WebSocket Closed: $code / $reason")
                this@MatchMeBackgroundService.webSocket = null
                locationShareHelper?.setRealtimeWebSocket(null)
                realtimeReconnectJob?.cancel()
                realtimeReconnectJob = null
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                }

                // Reconnect unless we intentionally closed very recently (token update / stale check).
                val closedAt = System.currentTimeMillis()
                if (isRealtimeIntentionalClosePending || (closedAt - lastIntentionalRealtimeCloseAt) < 3000) {
                    isRealtimeIntentionalClosePending = false
                    // Log.d(TAG, "Skipping Realtime reconnect (intentional close)")
                    return
                }
                if (!isServiceAlive()) {
                    // Log.d(TAG, "Skipping Realtime reconnect (service not running)")
                    return
                }
                if (!isOnline) {
                    // Log.d(TAG, "Skipping Realtime reconnect (offline)")
                    return
                }

                val delayMs = reconnectDelay
                reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY)
                // Log.d(TAG, "Reconnecting in ${delayMs}ms (Backoff)")

                scheduleRealtimeReconnect(delayMs)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                val failedAt = System.currentTimeMillis()
                val intentionalClose =
                    isRealtimeIntentionalClosePending ||
                    (failedAt - lastIntentionalRealtimeCloseAt) < 3000

                // Handle common graceful disconnections
                if (intentionalClose) {
                    // Log.d(TAG, "Realtime WebSocket closed after intentional shutdown: ${t.message}")
                } else if (t is java.io.IOException && t.message?.contains("closed", ignoreCase = true) == true) {
                    // Log.d(TAG, "Realtime WebSocket closed gracefully: ${t.message}")
                } else if (t is java.net.SocketTimeoutException || t is java.net.SocketException || t is javax.net.ssl.SSLHandshakeException) {
                    // Reduce log noise for common network errors
                    // Log.w(TAG, "Realtime WebSocket Failure: ${t.message} (Retrying in ${reconnectDelay}ms)")
                } else {
                    // Log.e(TAG, "Realtime WebSocket Failure: ${t.message}", t)
                }

                this@MatchMeBackgroundService.webSocket = null
                locationShareHelper?.setRealtimeWebSocket(null)
                realtimeReconnectJob?.cancel()
                realtimeReconnectJob = null
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                }

                // Retry quickly to minimize downtime (unless we intentionally closed).
                if (intentionalClose) {
                    isRealtimeIntentionalClosePending = false
                    // Log.d(TAG, "Skipping Realtime reconnect after failure (intentional close)")
                    return
                }
                if (!isServiceAlive()) {
                    // Log.d(TAG, "Skipping Realtime reconnect after failure (service not running)")
                    return
                }
                if (!isOnline) {
                    // Log.d(TAG, "Skipping Realtime reconnect after failure (offline)")
                    return
                }

                val delayMs = reconnectDelay
                reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY)

                scheduleRealtimeReconnect(delayMs)
            }
        })
    }

    private fun scheduleRealtimeReconnect(delayMs: Long) {
        realtimeReconnectJob?.cancel()
        realtimeReconnectJob = serviceScope.launch {
            delay(delayMs)
            if (!isActive || !isServiceAlive()) {
                // Log.d(TAG, "Skipping scheduled Realtime reconnect (service not running)")
                return@launch
            }
            if (!isOnline) {
                // Log.d(TAG, "Skipping scheduled Realtime reconnect (offline)")
                return@launch
            }
            connectToRealtime()
        }
    }

    private fun disconnectRealtime(reason: String = "Service stopping") {
        synchronized(realtimeLock) {
            lastIntentionalRealtimeCloseAt = System.currentTimeMillis()
            isRealtimeConnecting = false
            isRealtimeIntentionalClosePending = true
        }
        realtimeReconnectJob?.cancel()
        realtimeReconnectJob = null
        webSocket?.close(1000, reason)
        locationShareHelper?.setRealtimeWebSocket(null)
        webSocket = null
        realtimeJob?.cancel()
        // Log.d(TAG, "Realtime WebSocket Disconnected")
    }

    private fun joinChannel(ws: WebSocket) {
        // Join channels to listen for INSERTs on chat_messages and matches.
        // Using Realtime reduces latency vs polling and helps after device reboot.

        val filterUserId = userId

        fun sendJoin(topic: String, postgresChanges: org.json.JSONArray) {
            val payload = JSONObject().apply {
                put("config", JSONObject().apply {
                    put("postgres_changes", postgresChanges)
                })
                if (userToken != null) {
                    put("access_token", userToken)
                }
            }

            val joinMessage = JSONObject().apply {
                put("topic", topic)
                put("event", "phx_join")
                put("payload", payload)
                put("ref", System.currentTimeMillis().toString())
            }

            ws.send(joinMessage.toString())
            // Log disabled
        }

        // 1) chat_messages (only messages relevant to this user)
        run {
            val topic = "realtime:public:chat_messages"
            val changes = org.json.JSONArray().put(JSONObject().apply {
                put("event", "INSERT")
                put("schema", "public")
                put("table", "chat_messages")
                if (!filterUserId.isNullOrBlank()) {
                    put("filter", "recipient_id=eq.$filterUserId")
                }
            })
            sendJoin(topic, changes)
        }

        // 2) matches (two filters because Realtime doesn't support OR filters)
        run {
            val topic = "realtime:public:matches"
            val changes = org.json.JSONArray()
            if (!filterUserId.isNullOrBlank()) {
                changes.put(JSONObject().apply {
                    put("event", "INSERT")
                    put("schema", "public")
                    put("table", "matches")
                    put("filter", "user1_id=eq.$filterUserId")
                })
                changes.put(JSONObject().apply {
                    put("event", "INSERT")
                    put("schema", "public")
                    put("table", "matches")
                    put("filter", "user2_id=eq.$filterUserId")
                })
            } else {
                // If we don't have a userId, don't join matches to avoid noise.
                // Log.w(TAG, "Skipping matches realtime join (missing userId)")
                return@run
            }
            sendJoin(topic, changes)
        }

        // 3) users: listen for visibility changes (user_visibility_setting, system_visibility_status)
        run {
            if (filterUserId.isNullOrBlank()) {
                // Log.w(TAG, "Skipping users visibility realtime join (missing userId)")
                return@run
            }
            val topic = "realtime:public:users"
            val changes = org.json.JSONArray().put(JSONObject().apply {
                put("event", "UPDATE")
                put("schema", "public")
                put("table", "users")
                put("filter", "id=eq.$filterUserId")
            })
            sendJoin(topic, changes)
        }
    }

    private fun startHeartbeat(ws: WebSocket) {
        realtimeJob?.cancel()
        realtimeJob = serviceScope.launch {
            while (isActive && webSocket != null) {
                delay(25000) // 25 seconds (Supabase timeout is usually 30-60s)
                
                // Acquire WakeLock briefly to ensure heartbeat is sent even in Doze mode
                wakeLock?.acquire(1000)
                try {
                    val heartbeat = JSONObject().apply {
                        put("topic", "phoenix")
                        put("event", "heartbeat")
                        put("payload", JSONObject())
                        put("ref", System.currentTimeMillis().toString())
                    }
                    ws.send(heartbeat.toString())
                    // // Log.d(TAG, "Sent Realtime Heartbeat")
                } catch (e: Exception) {
                    // Log.e(TAG, "Failed to send Realtime heartbeat", e)
                } finally {
                    if (wakeLock?.isHeld == true) {
                        wakeLock?.release()
                    }
                }
            }
        }
    }

    private fun handleRealtimeMessage(text: String) {
        try {
            val json = JSONObject(text)
            val event = json.optString("event")
            
            if (event == "postgres_changes") {
                val payload = json.optJSONObject("payload")
                val dataObj = payload?.optJSONObject("data")

                // Supabase may wrap the record as payload.data.record.
                val type = dataObj?.optString("type")
                    ?: payload?.optString("type")
                    ?: ""

				// Helpful metadata when debugging noisy feeds.
				val schema = dataObj?.optString("schema") ?: payload?.optString("schema") ?: ""
				val table = dataObj?.optString("table") ?: payload?.optString("table") ?: ""
				val commitTimestamp = dataObj?.optString("commit_timestamp") ?: payload?.optString("commit_timestamp") ?: ""

                val record = dataObj?.optJSONObject("record")
                    ?: payload?.optJSONObject("record")
                    ?: dataObj

                // Lightweight instrumentation: log a couple of postgres_changes messages per 30s window.
                val now = System.currentTimeMillis()
                if ((now - realtimeDebug.lastPostgresDebugAt) > 30000) {
                    realtimeDebug.lastPostgresDebugAt = now
                    realtimeDebug.postgresDebugCountInWindow = 0
                }
                if (realtimeDebug.postgresDebugCountInWindow < 2) {
                    realtimeDebug.postgresDebugCountInWindow += 1
                    // Log disabled
                }

                if (type == "INSERT" && record != null) {
                    if (table == "chat_messages") {
                        val senderId = record.optString("sender_id", "")
                        val messageId = record.optString("id", "")
                        val matchId = record.optString("match_id", "")

                        // If sender is NOT me, it's a new message
                        if (senderId.isNotBlank() && senderId != userId) {
                            // Log.d(TAG, "Realtime: New message detected sender=$senderId messageId=$messageId matchId=$matchId")

                            // Acquire WakeLock to ensure we can fetch details even if device is dozing
                            wakeLock?.acquire(10000) // 10 seconds timeout safety

                            serviceScope.launch {
                                try {
                                    checkForNotifications(messageId.ifBlank { null })
                                } finally {
                                    try {
                                        if (wakeLock?.isHeld == true) {
                                            wakeLock?.release()
                                        }
                                    } catch (e: Exception) {
                                        // Log.e(TAG, "Error releasing WakeLock", e)
                                    }
                                }
                            }
                        }
                    } else if (table == "matches") {
                        val matchId = record.optString("id", "")
                        // Log.d(TAG, "Realtime: New match detected matchId=$matchId")

                        // Acquire WakeLock briefly to fetch details and notify.
                        wakeLock?.acquire(10000)
                        serviceScope.launch {
                            try {
                                // Reuse existing RPC logic (includes de-dupe) to show match notifications.
                                checkForNotifications(null)
                            } finally {
                                try {
                                    if (wakeLock?.isHeld == true) {
                                        wakeLock?.release()
                                    }
                                } catch (e: Exception) {
                                    // Log.e(TAG, "Error releasing WakeLock", e)
                                }
                            }
                        }
                    }
                } else if (type == "UPDATE" && record != null && table == "users") {
                    // Realtime visibility update
                    val remoteManual = record.optBoolean("user_visibility_setting", false)
                    val remoteSystem = record.optString("system_visibility_status", "visible")
                    val shouldBeVisible = remoteManual && remoteSystem == "visible"
                    if (shouldBeVisible != isVisible) {
                        isVisible = shouldBeVisible
                        securePrefs().edit().putBoolean("flutter.manual_visibility", isVisible).apply()
                        updateForegroundState()
                        if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                    }
                } else if (type.isNotBlank() && type != "INSERT") {
					// Avoid log spam: summarize non-INSERT messages (often UPDATEs) once per 30s window.
					val now = System.currentTimeMillis()
					if ((now - realtimeDebug.lastPostgresIgnoredAt) > 30000) {
						realtimeDebug.lastPostgresIgnoredAt = now
						realtimeDebug.postgresIgnoredCountInWindow = 0
					}
					realtimeDebug.postgresIgnoredCountInWindow += 1
					if (realtimeDebug.postgresIgnoredCountInWindow == 1) {
						val meta = listOf(
							type.ifBlank { "?" },
							"${schema.ifBlank { "?" }}.${table.ifBlank { "?" }}",
							commitTimestamp.ifBlank { "" },
						).filter { it.isNotBlank() }.joinToString(" ")
						// Log.d(TAG, "Realtime: postgres_changes ignored ($meta) (and more in next 30s)")
					}
				}
            } else if (event == "phx_reply") {
                val payload = json.optJSONObject("payload")
                val status = payload?.optString("status")
                if (status == "ok") {
                    // Log.d(TAG, "Realtime: Joined channel successfully")
                } else if (status == "error") {
                    // Log.e(TAG, "Realtime: Join failed: $payload")
                    // Report with user_id so server logs stay attributable even though
                    // postgres_logs for realtime never include bind-param values.
                    reportRealtimeJoinError(json.optString("topic"), payload.toString())
                }
            }
        } catch (e: Exception) {
            // Log.e(TAG, "Error parsing realtime message", e)
        }
    }

    // Throttle map so a failing subscription (e.g. stale filter on an old build)
    // reports at most once per topic per hour instead of on every reconnect.
    private val realtimeJoinErrorLastReportAt = mutableMapOf<String, Long>()

    private fun reportRealtimeJoinError(topic: String, detail: String) {
        val uid = userId ?: return
        val url = supabaseUrl ?: return
        val key = supabaseKey ?: return
        // Allow a dead-but-refreshable access token through: the helper below
        // refreshes once on 401. Only give up when there is nothing to refresh.
        if (userToken.isNullOrBlank() && refreshToken.isNullOrBlank()) return
        val now = System.currentTimeMillis()
        val last = realtimeJoinErrorLastReportAt[topic] ?: 0L
        if (now - last < 3600000L) return
        realtimeJoinErrorLastReportAt[topic] = now
        val appVersion: String? = try {
            packageManager.getPackageInfo(packageName, 0)?.versionName
        } catch (_: Exception) { null }
        serviceScope.launch {
            try {
                val body = JSONObject().apply {
                    put("p_source", "realtime_join")
                    put("p_error_message", ("phx_reply error topic=$topic detail=$detail").take(2000))
                    put("p_user_id", uid)
                    if (!appVersion.isNullOrBlank()) put("p_app_version", appVersion)
                    put("p_context", JSONObject().apply {
                        put("topic", topic)
                        put("response", detail.take(1000))
                    })
                }
                val reqBody = body.toString().toRequestBody("application/json".toMediaType())
                executeWithFreshJwt {
                    okhttp3.Request.Builder()
                        .url("$url/rest/v1/rpc/report_client_error")
                        .post(reqBody)
                        .addHeader("apikey", key)
                        .addHeader("Authorization", bearerAuthHeader())
                        .addHeader("Content-Type", "application/json")
                        .build()
                }?.close() // ignore result; table is the record
            } catch (_: Exception) {
                // Reporting must never break the service.
            }
        }
    }

    private var lastVisibilityDbCheckAt: Long = 0
    private val visibilityDbCheckIntervalMs: Long = 15000L // Check at most every 15s

    private suspend fun checkVisibilityFromDbIfNeeded() {
        if (userId == null || supabaseUrl == null || supabaseKey.isNullOrBlank()) return
        if (userToken.isNullOrBlank()) return

        val now = System.currentTimeMillis()
        if (now - lastVisibilityDbCheckAt < visibilityDbCheckIntervalMs) return
        lastVisibilityDbCheckAt = now

        try {
            val request = Request.Builder()
                .url("$supabaseUrl/rest/v1/users?select=user_visibility_setting,system_visibility_status&id=eq.$userId")
                .get()
                .addHeader("apikey", supabaseKey!!)
                .addHeader("Authorization", "Bearer $userToken")
                .addHeader("Cache-Control", "no-cache")
                .build()

            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use

                val body = response.body?.string() ?: return@use
                val array = org.json.JSONArray(body)
                if (array.length() == 0) return@use

                val obj = array.getJSONObject(0)
                val remoteManual = obj.optBoolean("user_visibility_setting", false)
                val remoteSystem = obj.optString("system_visibility_status", "visible")

                val shouldBeVisible = remoteManual && remoteSystem == "visible"
                if (shouldBeVisible != isVisible) {
                    isVisible = shouldBeVisible
                    securePrefs().edit().putBoolean("flutter.manual_visibility", isVisible).apply()
                    updateForegroundState()
                    if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
                }
            }
        } catch (_: Exception) {
        }
    }

    // Dedupe state for schedulePeriodicWork below. Every updateForegroundState
    // call ends there (several per minute during bootstrap cascades), and each
    // REPLACE/UPDATE cancels the in-flight worker — which WorkManager logs as
    // scary WorkerStoppedException stack traces. Only reschedule when the
    // schedule inputs actually changed.
    @Volatile private var periodicWorkScheduled = false
    @Volatile private var lastHeartbeatKickMs = 0L

    private fun schedulePeriodicWork() {
        // Periodic work is clamped by OS to 15m minimum; it is the fallback
        // when the Foreground Service is dead (Doze kill, swipe, crash).
        // LocationWorker itself re-enqueues a heart-beat OneTime when
        // backgroundMatchingMode==true && service dead so online stays <61s.
        // The heartbeat now respects the user's Settings GPS rate (capped to 60s for online window).
        // Enqueued once per process lifetime: the spec never changes, and
        // re-enqueueing would just cancel+restart the live worker (log spam,
        // wasted wakeups). WorkManager persists it across restarts anyway.
        if (!periodicWorkScheduled) {
            try {
                val workRequest = PeriodicWorkRequestBuilder<LocationWorker>(15, TimeUnit.MINUTES)
                    .setInitialDelay(1, TimeUnit.MINUTES)
                    // KEY_SLOT: this worker also runs the ping-pong chain, so it must
                    // know which slot it occupies before chaining onward.
                    .setInputData(androidx.work.workDataOf(LocationWorker.KEY_SLOT to LocationWorker.NAME_A))
                    .addTag(LocationWorker.TAG_HEARTBEAT)
                    .build()

                // KEEP, not UPDATE: the spec never changes, and UPDATE would
                // cancel a live worker (log spam + wasted wakeup) for no gain.
                // cancelPeriodicWork() resets the flag when we truly want it
                // gone (e.g. returning to foreground).
                WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
                    "MatchMePeriodicLocation",
                    ExistingPeriodicWorkPolicy.KEEP,
                    workRequest
                )
                periodicWorkScheduled = true
            } catch (_: Exception) {}
        }
        // Also enqueue a short-delay OneTime heartbeat so the first dead-service
        // gap isn't 15m. LocationWorker chains the next OneTime itself.
        // Use user's Settings rate (capped to 60s) instead of hard 45s.
        // Throttled: a kickstarted heartbeat is still pending/running within
        // its delay window, so re-kicking would only cancel it (more traces).
        try {
            val prefs = securePrefs()
            val gpsInterval = when {
                prefs.contains("flutter.gps_interval") -> prefs.getInt("flutter.gps_interval", 5)
                prefs.contains("gps_interval") -> prefs.getInt("gps_interval", 5)
                else -> 5
            }.coerceAtLeast(1).coerceAtMost(60)
            val oneTimeDelay = gpsInterval.coerceAtMost(45).toLong()
            val now = System.currentTimeMillis()
            if (now - lastHeartbeatKickMs < oneTimeDelay * 1000L) {
                return
            }
            lastHeartbeatKickMs = now
            // Seed slot A of the ping-pong chain (see LocationWorker.chainOneTimeHeartbeat).
            // The KEY_SLOT input data is what makes the seeded worker chain onward to
            // slot B instead of re-seeding itself. Tag is added so every link of the
            // chain is discoverable by tag (tags are per-request and are NOT inherited
            // across enqueueUniqueWork).
            val oneTime = androidx.work.OneTimeWorkRequestBuilder<LocationWorker>()
                .setInitialDelay(oneTimeDelay, TimeUnit.SECONDS)
                .setInputData(androidx.work.workDataOf(LocationWorker.KEY_SLOT to LocationWorker.NAME_A))
                .addTag(LocationWorker.TAG_HEARTBEAT)
                .build()
            // KEEP, not REPLACE: replacing a pending/running heartbeat cancels live
            // work (the WorkerStoppedException traces) without buying an earlier
            // kick. KEEP is safe here because the worker's own successor targets the
            // *other* slot name, so this seed can never collide with the running worker.
            WorkManager.getInstance(applicationContext).enqueueUniqueWork(
                LocationWorker.NAME_A,
                androidx.work.ExistingWorkPolicy.KEEP,
                oneTime
            )
        } catch (_: Exception) {}
    }

    private fun cancelPeriodicWork() {
        WorkManager.getInstance(applicationContext).cancelUniqueWork("MatchMePeriodicLocation")
        try {
            // Cancel every slot, not just one: with the ping-pong chain the pending
            // link alternates between names, so cancelling a single name would leave
            // the chain alive.
            for (name in LocationWorker.ALL_UNIQUE_NAMES) {
                try {
                    WorkManager.getInstance(applicationContext).cancelUniqueWork(name)
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        periodicWorkScheduled = false
        lastHeartbeatKickMs = 0L
    }
}
