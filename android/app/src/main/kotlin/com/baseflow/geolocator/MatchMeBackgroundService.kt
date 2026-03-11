package com.baseflow.geolocator

import android.app.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.Location
import android.os.*
import android.util.Log
import android.net.Uri
import android.provider.Settings
import java.util.concurrent.TimeUnit
import android.util.Base64
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import com.google.android.gms.location.*
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
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
    private var webSocket: WebSocket? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastRealtimeActivity: Long = 0 // Track last message/heartbeat time

    // Realtime connection guards
    private val realtimeLock = Any()
    @Volatile private var isRealtimeConnecting: Boolean = false
    @Volatile private var lastRealtimeConnectAttemptAt: Long = 0
    @Volatile private var lastIntentionalRealtimeCloseAt: Long = 0
    @Volatile private var realtimeConnectStartAt: Long = 0
    private val realtimeDebug = RealtimeDebugState()
    
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
    // Tracks whether the UI process is in the foreground. This is not the same as the user's
    // discoverability/visibility setting.
    @Volatile private var appInForeground: Boolean = false
    @Volatile private var highAccuracyMode: Boolean = false
    private var gpsInterval = 30
    private var smartThrottlingEnabled = true
    private val recentLocations = mutableListOf<Location>()

    // Battery-aware throttling: when battery < 15% and not charging, ensure GPS runs
    // no more frequently than once every 60 seconds.
    @Volatile private var batteryPercent: Int? = null
    @Volatile private var deviceCharging: Boolean = false
    @Volatile private var lowBatteryThrottlingActive: Boolean = false
    private var batteryReceiver: BroadcastReceiver? = null

    private val lowBatteryThresholdPercent = 15
    private val lowBatteryMinIntervalMs = 60000L

    // When Android restarts a START_STICKY service, `intent` may be null.
    // If we don't re-enter foreground mode quickly, the OS can kill/crash-loop us.
    @Volatile private var foregroundStarted: Boolean = false
    
    // Deduplication tracking
    private var lastNotifiedMessageId: String? = null
    private var lastNotifiedMatchId: String? = null
    private val activeNotificationIds = mutableMapOf<String, Int>() // matchId -> notificationId
    private var currentlyViewingChatId: String? = null // Track which chat the user is currently viewing

    // Message history for MessagingStyle (Sender -> List of Messages)
    private val messageHistory = mutableMapOf<String, MutableList<String>>() // matchId -> messages

    // Throttling for notification checks to prevent duplicate concurrent calls
    @Volatile private var lastNotificationCheckTime: Long = 0
    private val notificationCheckThrottleMs = 2000L // Minimum 2 seconds between checks

    private class RealtimeDebugState {
        @Volatile var lastPostgresDebugAt: Long = 0
        @Volatile var postgresDebugCountInWindow: Int = 0

		@Volatile var lastPostgresIgnoredAt: Long = 0
		@Volatile var postgresIgnoredCountInWindow: Int = 0
    }

    private var methodChannel: MethodChannel? = null
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // Disable read timeout for WebSockets
        .writeTimeout(30, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS) // Keep connection alive (reduced to 20s)
        .retryOnConnectionFailure(true)
        .build()

    companion object {
        const val CHANNEL_ID = "matchme_background_service_min" // Changed ID to force update
        const val ALERTS_CHANNEL_ID = "matchme_alerts"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        const val ACTION_UPDATE_VISIBILITY = "UPDATE_VISIBILITY"
        const val ACTION_UPDATE_APP_FOREGROUND = "UPDATE_APP_FOREGROUND"
        const val ACTION_UPDATE_HIGH_ACCURACY = "UPDATE_HIGH_ACCURACY"
        const val ACTION_UPDATE_TOKEN = "UPDATE_TOKEN"
        const val ACTION_UPDATE_CONFIG = "UPDATE_CONFIG"
        const val ACTION_RESET_CHAT_NOTIFICATION = "RESET_CHAT_NOTIFICATION"
        const val ACTION_DISMISS_CHAT_NOTIFICATION = "DISMISS_CHAT_NOTIFICATION"
        const val ACTION_SET_VIEWING_CHAT = "SET_VIEWING_CHAT"
        const val ACTION_CLEAR_VIEWING_CHAT = "CLEAR_VIEWING_CHAT"
        const val ACTION_SET_CONNECTIVITY = "SET_CONNECTIVITY"
        const val ACTION_PROCESS_LOCATION_UPDATE = "PROCESS_LOCATION_UPDATE"
        const val EXTRA_USER_ID = "userId"
        const val EXTRA_SUPABASE_URL = "supabaseUrl"
        const val EXTRA_SUPABASE_KEY = "supabaseKey"
        const val EXTRA_USER_TOKEN = "userToken"
        const val EXTRA_REFRESH_TOKEN = "refreshToken"
        const val EXTRA_IS_VISIBLE = "isVisible"
        const val EXTRA_IS_ONLINE = "isOnline"
        const val EXTRA_APP_IN_FOREGROUND = "appInForeground"
        const val EXTRA_HIGH_ACCURACY = "highAccuracy"
        const val EXTRA_GPS_INTERVAL = "gpsInterval"
        const val EXTRA_SMART_THROTTLING = "smartThrottlingEnabled"
        const val EXTRA_MATCH_ID = "matchId"

        fun startService(
            context: Context,
            userId: String,
            supabaseUrl: String,
            supabaseKey: String,
            userToken: String?,
            refreshToken: String?,
            appInForeground: Boolean = false,
            highAccuracyMode: Boolean = false,
            isVisible: Boolean = true,
            isOnline: Boolean = true,
        ) {
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
                putExtra(EXTRA_HIGH_ACCURACY, highAccuracyMode)
            }
            
            // Only use startForegroundService if we are in background AND high accuracy mode is enabled.
            // This prevents ForegroundServiceDidNotStartInTimeException when we don't intend to show a notification.
            if (!appInForeground && highAccuracyMode) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } else {
                try {
                    context.startService(intent)
                } catch (e: Exception) {
                    // This might happen if app is in background and we try to start service in Standard Mode.
                    Log.w("MatchMeBackgroundService", "Failed to start service via startService", e)
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
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_SET_CONNECTIVITY
                putExtra(EXTRA_IS_ONLINE, isOnline)
            }
            context.startService(intent)
        }

        fun updateAppForeground(context: Context, appInForeground: Boolean) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_APP_FOREGROUND
                putExtra(EXTRA_APP_IN_FOREGROUND, appInForeground)
            }
            context.startService(intent)
        }

        fun updateHighAccuracyMode(context: Context, enabled: Boolean) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_HIGH_ACCURACY
                putExtra(EXTRA_HIGH_ACCURACY, enabled)
            }
            context.startService(intent)
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

        fun resetChatNotification(context: Context, matchId: String) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_RESET_CHAT_NOTIFICATION
                putExtra(EXTRA_MATCH_ID, matchId)
            }
            context.startService(intent)
        }

        fun checkForNotifications(context: Context, messageId: String?) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = "CHECK_NOTIFICATIONS"
                putExtra("specificMessageId", messageId)
            }
            context.startService(intent)
        }

        fun showTranslatedNotification(
            context: Context,
            messageId: String,
            translatedContent: String,
            originalContent: String,
            senderName: String,
            matchId: String? = null
        ) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = "SHOW_TRANSLATED_NOTIFICATION"
                putExtra("messageId", messageId)
                putExtra("translatedContent", translatedContent)
                putExtra("originalContent", originalContent)
                putExtra("senderName", senderName)
                putExtra("matchId", matchId)
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

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Background service created")

        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)

        // Track battery state so we can reduce GPS frequency when the device is low.
        startBatteryMonitoring()
        
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
            highAccuracyMode = prefs.getBoolean("flutter.high_accuracy_mode", false)
            isVisible = prefs.getBoolean("flutter.manual_visibility", true)
            isOnline = prefs.getBoolean("flutter.is_online", true)
            
            // Also restore credentials immediately so we can start foreground service if needed
            userId = prefs.getString("flutter.user_id", null)
            supabaseUrl = prefs.getString("flutter.supabase_url", null)
            supabaseKey = prefs.getString("flutter.supabase_key", null)
            userToken = prefs.getString("flutter.user_token", null)
            refreshToken = prefs.getString("flutter.refresh_token", null)
            
            Log.d(TAG, "Synchronously restored state: highAccuracyMode=$highAccuracyMode, isVisible=$isVisible, userId=${userId != null}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore state synchronously", e)
        }

        // Restore credentials and connect but defer slightly to avoid janking startup.
        serviceScope.launch {
            Log.d(TAG, "[NATIVE] Delaying restoreCredentialsAndConnect by 1500ms to reduce startup contention")
            delay(1500)
            val start = System.currentTimeMillis()
            restoreCredentialsAndConnect()
            Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect completed (elapsed=${System.currentTimeMillis() - start}ms)")
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
                    Log.d(
                        TAG,
                        "Low-battery GPS mode changed: active=$lowBatteryThrottlingActive (battery=${batteryPercent ?: -1}%, charging=$deviceCharging)"
                    )

                    // Apply the new interval quickly (without waiting for the previous delay).
                    if (isVisible) {
                        try {
                            stopLocationUpdates()
                            startLocationUpdates()
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to restart location updates after battery state change", e)
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
            Log.w(TAG, "Failed to register battery receiver", e)
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

    private fun ensureForegroundStarted() {
        if (foregroundStarted) {
            Log.d(TAG, "Foreground already started, skipping")
            return
        }
        if (userId.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) {
            Log.w(TAG, "Cannot start foreground: missing credentials (userId=${!userId.isNullOrBlank()}, url=${!supabaseUrl.isNullOrBlank()}, key=${!supabaseKey.isNullOrBlank()})")
            return
        }
        try {
            startForeground(NOTIFICATION_ID, createNotification())
            foregroundStarted = true
            Log.d(TAG, "Successfully started foreground service")
        } catch (e: SecurityException) {
            Log.e(TAG, "Failed to enter foreground mode - Security Exception: ${e.message}", e)
            // Report permission issue to Flutter so it can show user a dialog
            if (e.message?.contains("FOREGROUND_SERVICE_LOCATION") == true) {
                try {
                    val prefs = securePrefs()
                    prefs.edit().putString("permission_issue_code", "FOREGROUND_SERVICE_LOCATION_DENIED").apply()
                    Log.d(TAG, "Stored permission issue in SharedPreferences for Flutter to handle")
                } catch (ex: Exception) {
                    Log.e(TAG, "Failed to store permission issue", ex)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to enter foreground mode: ${e.javaClass.simpleName}: ${e.message}", e)
        }
    }

    private fun ensureForegroundStopped() {
        if (!foregroundStarted) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to exit foreground mode", e)
        } finally {
            foregroundStarted = false
        }
    }

    private fun updateForegroundState() {
        // High Accuracy Mode Logic:
        // - appInForeground=true:  Hide notification (stopForeground(true)) but keep service running
        // - appInForeground=false: Show notification (startForeground) to keep service running
        //
        // Standard Mode Logic:
        // - appInForeground=true:  Hide notification (stopForeground(true)) but keep service running
        // - appInForeground=false: Stop service (stopSelf) to be a "good citizen". 
        //   We will rely on WorkManager for periodic updates.
        //   For now, this means GPS updates STOP when app is backgrounded in Standard Mode, but WorkManager takes over.

        if (appInForeground) {
            // App is open: we can always hide the notification to be less intrusive
            // We want the service to keep running though.
            ensureForegroundStopped()
            cancelPeriodicWork() // If app is open, we don't need periodic work
            return
        }

        // App is in background
        if (highAccuracyMode && isVisible) {
            // High Accuracy & Visible: Must show notification to keep service alive
            if (userId.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) return
            ensureForegroundStarted()
            cancelPeriodicWork() // Ensure no conflicting periodic work
        } else {
            // Standard Mode: We do NOT want a persistent notification.
            // We should stop the service entirely.
            Log.d(TAG, "Standard Mode active & App in background -> Stopping Service")
            
            // Schedule periodic work before stopping
            schedulePeriodicWork()

            // Ensure background PendingIntent updates are registered before we die
            startBackgroundLocationUpdates()
            
            stopSelf()
        }
    }

    private fun ensureRunningFromStoredState() {
        try {
            restoreCredentialsAndConnect()
            updateForegroundState()
            // Keep realtime/polling alive even if visibility is off.
            connectToRealtime()
            if (isVisible || isOnline) startLocationUpdates() else stopLocationUpdates()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore running state", e)
        }
    }

    private fun restoreCredentialsAndConnect() {
        val start = System.currentTimeMillis()
        Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect: start")

        val prefs = securePrefs()
        // Restore ids and config (always from prefs when missing)
        if (userId.isNullOrBlank()) userId = prefs.getString("flutter.user_id", null)
        if (supabaseUrl.isNullOrBlank()) supabaseUrl = prefs.getString("flutter.supabase_url", null)
        if (supabaseKey.isNullOrBlank()) supabaseKey = prefs.getString("flutter.supabase_key", null)
        // Don't overwrite in-memory token if we already have one (e.g. from ACTION_START this process)
        if (userToken.isNullOrBlank()) userToken = prefs.getString("flutter.user_token", null)
        if (refreshToken.isNullOrBlank()) refreshToken = prefs.getString("flutter.refresh_token", null)
        isVisible = prefs.getBoolean("flutter.manual_visibility", true)
        isOnline = prefs.getBoolean("flutter.is_online", true)
        authPermanentlyFailed = prefs.getBoolean("flutter.auth_permanently_failed", false)
        // If we have a valid token in memory (from app), don't keep permanent failure
        if (!userToken.isNullOrBlank()) authPermanentlyFailed = false
        gpsInterval = prefs.getInt("flutter.gps_interval", 30)
        smartThrottlingEnabled = prefs.getBoolean("flutter.smart_throttling_enabled", true)
        highAccuracyMode = prefs.getBoolean("flutter.high_accuracy_mode", false)

        if (userId != null && supabaseUrl != null && supabaseKey != null) {
            Log.d(TAG, "Restored credentials from storage. Connecting to Realtime immediately.")
            connectToRealtime()
            if (isVisible && isOnline) {
                startLocationUpdates()
            }
        }

        Log.d(TAG, "[NATIVE] restoreCredentialsAndConnect: finished (elapsed=${System.currentTimeMillis() - start}ms)")
    }
    
    private fun saveCredentials(userId: String, url: String, key: String, isVisible: Boolean, gpsInterval: Int, smartThrottlingEnabled: Boolean, token: String?, refreshToken: String?, highAccuracyMode: Boolean) {
        val prefs = securePrefs()
        prefs.edit().apply {
            putBoolean("flutter.was_logged_in", true)
            putString("flutter.user_id", userId)
            putString("flutter.supabase_url", url)
            putString("flutter.supabase_key", key)
            putString("flutter.user_token", token)
            putString("flutter.refresh_token", refreshToken)
            putBoolean("flutter.manual_visibility", isVisible)
            putInt("flutter.gps_interval", gpsInterval)
            putBoolean("flutter.smart_throttling_enabled", smartThrottlingEnabled)
            putBoolean("flutter.high_accuracy_mode", highAccuracyMode)
            apply()
        }
        if (isDebug()) {
            Log.d(TAG, "Credentials and config saved for boot recovery")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Background service started with action: ${intent?.action}")

        when (intent?.action) {
            ACTION_START -> {
                userId = intent.getStringExtra(EXTRA_USER_ID)
                supabaseUrl = intent.getStringExtra(EXTRA_SUPABASE_URL)
                supabaseKey = intent.getStringExtra(EXTRA_SUPABASE_KEY)
                userToken = intent.getStringExtra(EXTRA_USER_TOKEN)
                refreshToken = intent.getStringExtra(EXTRA_REFRESH_TOKEN)
                authPermanentlyFailed = false // Reset auth failure when new tokens are provided
                // Load persisted config for other values
                val prefs = securePrefs()
                
                // Prioritize intent for isVisible (it's passed from Flutter startService)
                if (intent.hasExtra(EXTRA_IS_VISIBLE)) {
                    isVisible = intent.getBooleanExtra(EXTRA_IS_VISIBLE, false)
                    // Persist it immediately so it survives restarts
                    securePrefs().edit().putBoolean("manual_visibility", isVisible).apply()
                } else {
                    isVisible = prefs.getBoolean("manual_visibility", true)
                }

                // Prioritize intent for isOnline (it's passed from Flutter startService)
                if (intent.hasExtra(EXTRA_IS_ONLINE)) {
                    isOnline = intent.getBooleanExtra(EXTRA_IS_ONLINE, true)
                    securePrefs().edit().putBoolean("is_online", isOnline).apply()
                } else {
                    isOnline = prefs.getBoolean("is_online", true)
                }

                gpsInterval = prefs.getInt("gps_interval", 30)
                smartThrottlingEnabled = prefs.getBoolean("smart_throttling_enabled", true)
                
                // Handle highAccuracyMode: prioritize intent, fallback to prefs
                highAccuracyMode = if (intent.hasExtra(EXTRA_HIGH_ACCURACY)) {
                    intent.getBooleanExtra(EXTRA_HIGH_ACCURACY, false)
                } else {
                    prefs.getBoolean("flutter.high_accuracy_mode", false)
                }
                
                appInForeground = intent.getBooleanExtra(EXTRA_APP_IN_FOREGROUND, false)

                Log.d(TAG, "Starting service with userId: $userId, highAccuracy: $highAccuracyMode, isVisible: $isVisible, isOnline: $isOnline")

                if (userId != null && supabaseUrl != null && supabaseKey != null) {
                    saveCredentials(userId!!, supabaseUrl!!, supabaseKey!!, isVisible, gpsInterval, smartThrottlingEnabled, userToken, refreshToken, highAccuracyMode)
                    
                    // CRITICAL: If we were started with startForegroundService() (which happens when
                    // !appInForeground && highAccuracyMode), we MUST call startForeground() immediately
                    // within ~5 seconds, otherwise Android throws ForegroundServiceDidNotStartInTimeException.
                    // The startService() companion detected these conditions and called startForegroundService(),
                    // so we must ensure the foreground notification is shown right away.
                    // NOTE: We must do this regardless of isVisible, because startForegroundService() was already
                    // called based on !appInForeground && highAccuracyMode, and not calling startForeground()
                    // will cause the ForegroundServiceDidNotStartInTimeException.
                    if (!appInForeground && highAccuracyMode) {
                        Log.d(TAG, "ACTION_START with foreground service requirement (appInForeground=$appInForeground, highAccuracy=$highAccuracyMode) -> Immediately ensuring foreground")
                        try {
                            ensureForegroundStarted()
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to start foreground immediately on ACTION_START", e)
                        }
                    }
                    
                    // Now proceed with normal state management
                    updateForegroundState()
                    startServiceRunning()
                    
                    if (isVisible && isOnline) {
                        startLocationUpdates()
                    } else {
                        Log.d(TAG, "Service started but user is invisible or offline -> NOT starting location updates")
                        stopLocationUpdates()
                    }

                    connectToRealtime()
                    // startNotificationPolling() - Removed as redundant with FCM
                }
            }
            ACTION_UPDATE_VISIBILITY -> {
                isVisible = intent.getBooleanExtra(EXTRA_IS_VISIBLE, false)
                Log.d(TAG, "Visibility updated: $isVisible")
                securePrefs().edit().putBoolean("flutter.manual_visibility", isVisible).apply()
                updateForegroundState()
                if (isVisible && isOnline) startLocationUpdates() else stopLocationUpdates()
            }
            ACTION_SET_CONNECTIVITY -> {
                isOnline = intent.getBooleanExtra(EXTRA_IS_ONLINE, true)
                Log.d(TAG, "Connectivity updated: $isOnline")
                securePrefs().edit().putBoolean("flutter.is_online", isOnline).apply()

                if (isVisible && isOnline) {
                    Log.d(TAG, "User came online (and is visible) -> starting location updates")
                    startLocationUpdates()
                } else {
                    Log.d(TAG, "User went offline (or is invisible) -> stopping location updates")
                    stopLocationUpdates()
                }
            }
            ACTION_UPDATE_APP_FOREGROUND -> {
                appInForeground = intent.getBooleanExtra(EXTRA_APP_IN_FOREGROUND, false)
                Log.d(TAG, "App foreground state updated: $appInForeground")
                updateForegroundState()
            }
            ACTION_UPDATE_HIGH_ACCURACY -> {
                highAccuracyMode = intent.getBooleanExtra(EXTRA_HIGH_ACCURACY, false)
                Log.d(TAG, "High accuracy mode updated: $highAccuracyMode")
                securePrefs().edit().putBoolean("flutter.high_accuracy_mode", highAccuracyMode).apply()
                updateForegroundState()
            }
            ACTION_UPDATE_TOKEN -> {
                userToken = intent.getStringExtra(EXTRA_USER_TOKEN)
                val newRefreshToken = intent.getStringExtra(EXTRA_REFRESH_TOKEN)
                if (!newRefreshToken.isNullOrBlank()) {
                    refreshToken = newRefreshToken
                }
                authPermanentlyFailed = false // Reset auth failure when new tokens are provided
                Log.d(TAG, "JWT token updated: ${userToken?.let { "present" } ?: "null"}")

                // Persist refreshed token so a process restart doesn't revert to an expired JWT.
                // Use flutter.* keys to match restoreCredentialsAndConnect() and Flutter prefs.
                try {
                    securePrefs().edit().apply {
                        putString("flutter.user_token", userToken)
                        if (!refreshToken.isNullOrBlank()) {
                            putString("flutter.refresh_token", refreshToken)
                        }
                        apply()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to persist refreshed JWT token: $e")
                }

                // Reconnect to apply new token
                disconnectRealtime()
                connectToRealtime()
            }
            ACTION_UPDATE_CONFIG -> {
                gpsInterval = intent.getIntExtra(EXTRA_GPS_INTERVAL, 30)
                smartThrottlingEnabled = intent.getBooleanExtra(EXTRA_SMART_THROTTLING, true)
                Log.d(TAG, "Config updated: interval=$gpsInterval, throttling=$smartThrottlingEnabled")
                
                // Save config
                securePrefs().edit().apply {
                    putInt("gps_interval", gpsInterval)
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
                    Log.d(TAG, "Resetting notification state for chat: $matchId")
                    if (lastNotifiedMatchId == matchId) {
                        lastNotifiedMatchId = null
                        Log.d(TAG, "Cleared lastNotifiedMatchId for chat: $matchId")
                    } else {
                        Log.d(TAG, "Not clearing lastNotifiedMatchId (current: $lastNotifiedMatchId, requested: $matchId)")
                    }

                    // Clear message history for this specific chat so expanded notifications only show new messages
                    // This ensures expanded notifications only show messages that arrived after entering the chat
                    messageHistory.remove(matchId)
                    Log.d(TAG, "Cleared message history for chat: $matchId")
                }
            }
            ACTION_DISMISS_CHAT_NOTIFICATION -> {
                val matchId = intent.getStringExtra(EXTRA_MATCH_ID)
                if (matchId != null) {
                    val notificationId = activeNotificationIds[matchId]
                    if (notificationId != null) {
                        Log.d(TAG, "Dismissing notification for chat $matchId: $notificationId")
                        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        notificationManager.cancel(notificationId)
                        activeNotificationIds.remove(matchId)
                        Log.d(TAG, "Dismissed notification: $notificationId")
                    } else {
                        Log.d(TAG, "No active notification found for chat: $matchId")
                    }
                }
            }
            ACTION_SET_VIEWING_CHAT -> {
                val matchId = intent.getStringExtra(EXTRA_MATCH_ID)
                currentlyViewingChatId = matchId
                Log.d(TAG, "Set currently viewing chat to: $matchId")
            }
            ACTION_CLEAR_VIEWING_CHAT -> {
                Log.d(TAG, "Cleared currently viewing chat (was: $currentlyViewingChatId)")
                currentlyViewingChatId = null
            }
            "CHECK_NOTIFICATIONS" -> {
                val messageId = intent.getStringExtra("specificMessageId")
                Log.d(TAG, "[ANDROID] Manual notification check triggered for messageId: $messageId")
                // Run notification check in a coroutine
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        if (messageId != null) {
                            Log.d(TAG, "[ANDROID] Waiting 300ms for translation to complete")
                            delay(300) // Wait for translation to be saved
                        }
                        Log.d(TAG, "[ANDROID] Starting notification check for messageId: $messageId")
                        checkForNotifications(messageId)
                        Log.d(TAG, "[ANDROID] Notification check completed for messageId: $messageId")
                    } catch (e: Exception) {
                        Log.e(TAG, "[ANDROID] Error in manual notification check", e)
                    }
                }
            }
            "SHOW_TRANSLATED_NOTIFICATION" -> {
                val messageId = intent.getStringExtra("messageId") ?: ""
                val translatedContent = intent.getStringExtra("translatedContent") ?: ""
                val originalContent = intent.getStringExtra("originalContent") ?: ""
                val senderName = intent.getStringExtra("senderName") ?: "Someone"
                val matchId = intent.getStringExtra("matchId")

                Log.d(TAG, "[ANDROID] Show translated notification: sender='$senderName', translated='$translatedContent', original='$originalContent', matchId='$matchId'")

                // Show notification directly with the translated content
                showTranslatedNotification(senderName, translatedContent, messageId, matchId)
            }
            ACTION_PROCESS_LOCATION_UPDATE -> {
                Log.d(TAG, "Received background location update intent")
                if (LocationResult.hasResult(intent)) {
                    val result = LocationResult.extractResult(intent)
                    result?.lastLocation?.let { location ->
                        Log.d(TAG, "Background location received: ${location.latitude}, ${location.longitude}")
                        handleLocationUpdate(location)
                    }
                } else {
                    Log.d(TAG, "Background location intent received but no result found")
                }

                // If we are in Standard Mode (not High Accuracy), we shouldn't keep the service running
                // unnecessarily. The PendingIntent started us, we did the work, now we can stop.
                if (!highAccuracyMode && !appInForeground) {
                    Log.d(TAG, "Standard Mode background update processed -> Stopping Service")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_STOP -> {
                Log.d(TAG, "ACTION_STOP received - stopping service and clearing sensitive state")
                stopLocationUpdates()
                clearCredentials()
                stopForeground(true)
                foregroundStarted = false
                stopSelf()
                // Clear sensitive fields immediately
                userId = null
                supabaseUrl = null
                supabaseKey = null
                userToken = null
                isVisible = false
            }
            else -> {
                // OS restart (START_STICKY) or unknown intent. Restore state and keep going.
                // CRITICAL: If we were started with startForegroundService() due to a previous state,
                // we MUST call startForeground() immediately within ~5 seconds.
                // Restore persisted state to determine if we need foreground mode.
                try {
                    val prefs = securePrefs()
                    val storedUserId = prefs.getString("flutter.user_id", null)
                    val storedUrl = prefs.getString("flutter.supabase_url", null)
                    val storedKey = prefs.getString("flutter.supabase_key", null)
                    val storedHighAccuracy = prefs.getBoolean("flutter.high_accuracy_mode", false)
                    val storedVisible = prefs.getBoolean("flutter.manual_visibility", true)

                    // If we have credentials and high accuracy mode was active, we may have been started
                    // with startForegroundService(), so establish foreground immediately.
                    if (!storedUserId.isNullOrBlank() && !storedUrl.isNullOrBlank() && !storedKey.isNullOrBlank() &&
                        storedHighAccuracy && storedVisible && userId == null) {
                        Log.d(TAG, "Boot/OS restart with foreground service requirement -> Immediately ensuring foreground")
                        userId = storedUserId
                        supabaseUrl = storedUrl
                        supabaseKey = storedKey
                        try {
                            ensureForegroundStarted()
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to ensure foreground on restart", e)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Error checking for foreground requirement on restart", e)
                }

                maybeRecordBatteryKillIssue(intent)
                ensureRunningFromStoredState()
            }
        }

        return if (highAccuracyMode || appInForeground) START_STICKY else START_NOT_STICKY
    }

    private fun maybeRecordBatteryKillIssue(intent: Intent?) {
        // Heuristic: if Android restarts us with a null/unknown intent and the app is not exempt from
        // battery optimizations, it is often because the OS killed our process in the background.
        // We surface this once so the UI can show a failure-driven dialog.
        try {
            val isStickyRestart = intent == null || intent.action == null
            if (!isStickyRestart) return

            val prefs = securePrefs()
            val wasLoggedIn = prefs.getBoolean("was_logged_in", false)
            val hasCreds = !prefs.getString("user_id", null).isNullOrBlank() &&
                !prefs.getString("supabase_url", null).isNullOrBlank() &&
                !prefs.getString("supabase_key", null).isNullOrBlank()
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
        prefs.edit().apply {
            putBoolean("was_logged_in", true)
            putString("user_id", userId)
            putString("supabase_url", url)
            putString("supabase_key", key)
            putString("user_token", token)
            putString("refresh_token", refreshToken)
            putBoolean("manual_visibility", isVisible)
            putInt("gps_interval", gpsInterval)
            putBoolean("smart_throttling_enabled", smartThrottlingEnabled)
            apply()
        }
        if (isDebug()) {
            Log.d(TAG, "Credentials and config saved for boot recovery")
        }
    }

    private fun saveCredentials(userId: String, url: String, key: String, isVisible: Boolean, gpsInterval: Int, smartThrottlingEnabled: Boolean, token: String?, refreshToken: String?) {
        this.refreshToken = refreshToken
        saveCredentials(userId, url, key, isVisible, gpsInterval, smartThrottlingEnabled, token)
    }

    private fun clearCredentials() {
        val prefs = securePrefs()
        prefs.edit().apply {
            putBoolean("flutter.was_logged_in", false)
            remove("flutter.user_id")
            remove("flutter.supabase_url")
            remove("flutter.supabase_key")
            remove("flutter.user_token")
            remove("flutter.refresh_token")
            remove("flutter.manual_visibility")
            remove("flutter.gps_interval")
            remove("flutter.smart_throttling_enabled")
            apply()
        }
        if (isDebug()) {
            Log.d(TAG, "Credentials cleared from SharedPreferences")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Background service destroyed")
        stopServiceRunning()

        try {
            batteryReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {
        }
        batteryReceiver = null

        locationJob?.cancel() // Stop active loop, but keep PendingIntent updates
        disconnectRealtime()
        serviceScope.cancel()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.d(TAG, "onTaskRemoved: App task removed (swiped away)")
        
        // The app UI is gone, so we are definitely in the background now.
        appInForeground = false
        
        if (highAccuracyMode && isVisible) {
            Log.d(TAG, "onTaskRemoved: High Accuracy Mode & Visible -> Promoting to Foreground Service to persist")
            // Ensure we show the notification so the service survives the process death (or restarts as foreground)
            ensureForegroundStarted()
        } else {
            Log.d(TAG, "onTaskRemoved: Standard Mode -> Switching to Background Updates")
            stopForeground(true)
            startBackgroundLocationUpdates()
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
        val title = "MatchMe Active"
        val text = if (isVisible) "Finding matches nearby" else "Maintaining connection"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_MIN) // Min priority to hide icon
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .build()
    }

    private fun updateNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!foregroundStarted) {
            notificationManager.cancel(NOTIFICATION_ID)
            return
        }
        notificationManager.notify(NOTIFICATION_ID, createNotification())
    }

    private fun startLocationUpdates() {
        if (appInForeground || highAccuracyMode) {
            startForegroundLocationUpdates()
        } else {
            startBackgroundLocationUpdates()
        }
    }

    private fun startBackgroundLocationUpdates() {
        // Ensure foreground loop is stopped
        locationJob?.cancel()
        locationJob = null

        // Allow updates only if visible AND online (same as foreground service logic)
        if (userId == null) return
        if (!isVisible || !isOnline) {
             Log.d(TAG, "Skipping background updates: Not visible or not online (isVisible=$isVisible, isOnline=$isOnline)")
             return
        }

        Log.d(TAG, "Starting BACKGROUND (Standard Mode) location updates (PendingIntent)")
        try {
            // Remove any existing updates to avoid duplication
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
            
            // Standard Mode: 15 minutes, Balanced Power
            val intervalMs = 15 * 60 * 1000L // 15 minutes
            val request = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, intervalMs)
                .setMinUpdateIntervalMillis(intervalMs)
                .setMaxUpdateDelayMillis(intervalMs * 2) // Allow batching to save power
                .build()
                
            fusedLocationClient.requestLocationUpdates(request, getBackgroundLocationPendingIntent())
        } catch (e: SecurityException) {
             Log.e(TAG, "Background location permission not granted", e)
             recordPermissionIssue("location_always")
        } catch (e: Exception) {
             Log.e(TAG, "Error starting background updates", e)
        }
    }

    private fun startForegroundLocationUpdates() {
        // Ensure background updates are removed so we don't double up
        try {
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
        } catch (e: Exception) {}

        if (locationJob?.isActive == true) {
            Log.d(TAG, "Location updates already running")
            return
        }

        Log.d(TAG, "Starting periodic location updates loop (will wait 1000ms before first request)")
        locationJob = serviceScope.launch {
            // Small startup delay to avoid competing with UI rendering and other init work
            val initialDelayMs = 2000L
            delay(initialDelayMs)
            Log.d(TAG, "startLocationUpdates: initial delay completed (${initialDelayMs}ms)")

            while (isActive) {
                if (isVisible && userId != null) {
                    try {
                        Log.d(TAG, "Requesting single location update...")
                        // Use getCurrentLocation for a single, fresh update
                        // This allows the location icon to disappear between updates
                        val locationStart = System.currentTimeMillis()
                        val location = withContext(Dispatchers.Main) {
                            // Must be called on main thread or use a task awaiter
                            val task = fusedLocationClient.getCurrentLocation(
                                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                                null
                            )
                            // Convert Task to suspend function
                            suspendCancellableCoroutine<Location?> { cont ->
                                task.addOnSuccessListener { loc ->
                                    cont.resume(loc, null)
                                }.addOnFailureListener { e ->
                                    cont.resumeWithException(e)
                                }
                            }
                        }

                        val locationElapsed = System.currentTimeMillis() - locationStart

                        if (location != null) {
                            Log.d(TAG, "Location received: ${location.latitude}, ${location.longitude} (elapsed=${locationElapsed}ms)")
                            handleLocationUpdate(location)
                            
                            // Update recent locations for throttling logic
                            recentLocations.add(location)
                            if (recentLocations.size > 5) {
                                recentLocations.removeAt(0)
                            }
                        } else {
                            Log.d(TAG, "Location received was null")
                        }
                    } catch (e: SecurityException) {
                        Log.e(TAG, "Location permission not granted", e)

                        // Permission can change (or be insufficient after reboot). Don't crash-loop.
                        // Record the issue so Flutter can show a friendly dialog, and show a native
                        // notification directing the user to Settings.
                        recordPermissionIssue("location_always")
                        stopLocationUpdates()
                    } catch (e: Exception) {
                        Log.e(TAG, "Error getting location update", e)
                    }
                } else {
                    Log.d(TAG, "Skipping location update: isVisible=$isVisible, userId=${userId != null}")
                }

                // Calculate next interval
                var nextInterval = gpsInterval * 1000L

                if (smartThrottlingEnabled) {
                    if (isStationary()) {
                        // Never increase frequency beyond the configured interval.
                        nextInterval = max(nextInterval, 60000L)
                        Log.d(TAG, "Device is stationary, throttling to >=60s")
                    }

                    if (lowBatteryThrottlingActive) {
                        // Battery < 15% and not charging: reduce GPS usage to once every 60 seconds.
                        nextInterval = max(nextInterval, lowBatteryMinIntervalMs)
                        Log.d(TAG, "Low battery detected, throttling to >=60s")
                    }
                }

                if (!smartThrottlingEnabled || (!lowBatteryThrottlingActive && !isStationary())) {
                    Log.d(TAG, "Using configured interval: ${gpsInterval}s")
                }

                // Wait for next update
                delay(nextInterval)
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

        try {
            showPermissionNotification(code)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to show permission notification", e)
        }
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

    private fun getBackgroundLocationPendingIntent(): PendingIntent {
        val intent = Intent(this, MatchMeBackgroundService::class.java).apply {
            action = ACTION_PROCESS_LOCATION_UPDATE
        }
        return PendingIntent.getService(this, 999, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
    }

    private fun stopLocationUpdates() {
        locationJob?.cancel()
        locationJob = null
        
        // Also ensure background updates are stopped
        try {
            fusedLocationClient.removeLocationUpdates(getBackgroundLocationPendingIntent())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove background updates", e)
        }
        
        Log.d(TAG, "Location updates stopped")
    }

    private fun handleLocationUpdate(location: Location) {
        Log.d(TAG, "handleLocationUpdate called: isVisible=$isVisible, isOnline=$isOnline, userId=$userId, userToken=${if (userToken != null) "present" else "null"}, location=${location.latitude},${location.longitude}")
        
        if (userId == null) return
        if (userToken == null) {
            Log.w(TAG, "Skipping location update (user logged out - no JWT token)")
            return
        }
        if (authPermanentlyFailed) {
            Log.w(TAG, "Skipping location update (auth permanently failed)")
            return
        }

        // If invisible and not online, do nothing
        if (!isVisible && !isOnline) {
            Log.d(TAG, "Skipping location update: isVisible=$isVisible, isOnline=$isOnline")
            return
        }

        serviceScope.launch {
            try {
                if (isVisible) {
                    // Normal behavior: Update location (which updates activity) and match engine
                    Log.d(TAG, "Processing full location update for user $userId")
                    updateLocationInSupabase(location)
                } else if (isOnline) {
                    // Invisible but Online: ONLY update user activity
                    Log.d(TAG, "User invisible but online: Updating activity only")
                    try {
                        ensureValidJwt()
                    } catch (_: Exception) {}
                    updateUserActivity()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle location update", e)
            }
        }
    }

    private suspend fun updateLocationInSupabase(location: Location) {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return

        // Keep JWT valid so location RPC works after reboot.
        try {
            ensureValidJwt()
        } catch (_: Exception) {}

        Log.d(TAG, "Updating location in Supabase: lat=${location.latitude}, lng=${location.longitude}")

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

        var response = httpClient.newCall(request).execute()
        try {
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                // If we got a 401, try refreshing the JWT once and retry.
                if (response.code == 401 && !refreshToken.isNullOrBlank()) {
                    Log.w(TAG, "Location update 401. Attempting JWT refresh + retry...")
                    try {
                        refreshJwtToken(refreshToken!!)
                    } catch (e: Exception) {
                        Log.w(TAG, "JWT refresh failed during location retry", e)
                    }
                    response.close()

                    val retryReq = request.newBuilder()
                        .removeHeader("Authorization")
                        .addHeader("Authorization", bearerAuthHeader())
                        .build()
                    response = httpClient.newCall(retryReq).execute()
                    if (!response.isSuccessful) {
                        val retryBody = response.body?.string()
                        Log.e(TAG, "Failed to update location after retry: ${response.code}, ${response.message}, body: $retryBody")
                    } else {
                        val responseBody = response.body?.string()
                        Log.d(TAG, "Successfully updated location (after retry): $responseBody")
                        checkForNotifications()
                    }
                    return
                }

                Log.e(TAG, "Failed to update location: ${response.code}, ${response.message}, body: $errorBody")
            } else {
                val responseBody = response.body?.string()
                Log.d(TAG, "Successfully updated location: $responseBody")
                
                // After successful location update, check for notifications
                checkForNotifications()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception updating location: ${e.message}", e)
        } finally {
            response.close()
        }
    }

    private fun showTranslatedNotification(senderName: String, content: String, messageId: String, matchId: String? = null) {
        Log.d(TAG, "[ANDROID] Showing translated notification: sender='$senderName', content='$content', matchId='$matchId'")

        val effectiveMatchId = matchId ?: "unknown"

        // Check if we should show notification alert (skip alert if viewing chat AND app is in foreground)
        val isViewingThisChat = effectiveMatchId == currentlyViewingChatId
        val shouldAlert = !isViewingThisChat || !appInForeground

        if (shouldAlert) {
            // Use sender name hash as notification ID to group message notifications per chat
            val notificationId = senderName.hashCode()

            Log.d(TAG, "[ANDROID] Showing notification: sender='$senderName', content='$content', silent=$isViewingThisChat")
            showNotification("New Message", "$senderName: $content", notificationId, senderName, effectiveMatchId, silent = isViewingThisChat)
            activeNotificationIds[effectiveMatchId] = notificationId

            // Update last notified
            lastNotifiedMatchId = effectiveMatchId
            Log.d(TAG, "Set lastNotifiedMatchId to: $effectiveMatchId, stored notificationId: $notificationId")
        } else {
            Log.d(TAG, "[ANDROID] Skipping notification - currently viewing chat and app is in foreground: $effectiveMatchId")
        }
    }

    private suspend fun checkForNotifications(specificMessageId: String? = null) {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return

        // Throttle notification checks to prevent excessive calls
        val now = System.currentTimeMillis()
        if (now - lastNotificationCheckTime < notificationCheckThrottleMs) {
            Log.d(TAG, "Skipping notification check - throttled (last check: ${now - lastNotificationCheckTime}ms ago)")
            return
        }
        lastNotificationCheckTime = now

        Log.d(TAG, "Checking for notifications via RPC... (Message ID: $specificMessageId)")
        val url = "$supabaseUrl/rest/v1/rpc/check_unread_notifications"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
            if (specificMessageId != null) {
                put("p_message_id", specificMessageId)
            }
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val request = okhttp3.Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Authorization", bearerAuthHeader())
            .addHeader("Content-Type", "application/json")
            .build()

        try {
            val response = httpClient.newCall(request).execute()
            if (response.isSuccessful) {
                val responseBody = response.body?.string()
                Log.d(TAG, "Notification check response: $responseBody")
                if (responseBody != null) {
                    // Response is a JSON array with one object
                    val jsonArray = org.json.JSONArray(responseBody)
                    if (jsonArray.length() > 0) {
                        val data = jsonArray.getJSONObject(0)
                        val unreadMatches = data.optInt("unread_matches_count", 0)
                        val unreadMessages = data.optInt("unread_messages_count", 0)
                        
                        if (unreadMatches > 0) {
                            val matchName = data.optString("latest_match_name", "Someone")
                            val matchId = data.optString("latest_match_id", "")
                            
                            // Fallback to hash if ID is missing (backward compatibility with old RPC)
                            val effectiveMatchId = if (matchId.isNotEmpty()) matchId else matchName.hashCode().toString()
                            
                            if (effectiveMatchId != lastNotifiedMatchId) {
                                Log.d(TAG, "Found new unread match: $matchName (ID: $effectiveMatchId)")
                                // Use match name hash as ID to group match notifications
                                showNotification("New Match!", "You matched with $matchName!", matchName.hashCode(), null, effectiveMatchId)
                                lastNotifiedMatchId = effectiveMatchId
                            } else {
                                Log.d(TAG, "Skipping duplicate match notification for ID: $effectiveMatchId")
                            }
                        } else if (unreadMessages > 0) {
                            val sender = data.optString("latest_message_sender", "Someone")
                            val content = data.optString("latest_message_content", "Sent a message")
                            val messageId = data.optString("latest_message_id", "")
                            val matchId = data.optString("latest_match_id", "")
                            val translationEnabled = data.optBoolean("translation_enabled", false)
                            val translationAvailable = data.optBoolean("translation_available", false)

                            // Validate that this is actually an unread message
                            // The RPC function should only return unread messages, but double-check
                            if (messageId.isEmpty()) {
                                Log.d(TAG, "[ANDROID] Skipping notification - message ID is empty (RPC returned inconsistent data)")
                                return@checkForNotifications
                            }

                            if (translationEnabled && !translationAvailable) {
                                Log.d(TAG, "[ANDROID] Skipping notification - translation pending for messageId: $messageId")
                                return@checkForNotifications
                            }

                            // Use match ID for deduplication - one notification per chat
                            val effectiveChatId = if (matchId.isNotEmpty()) matchId else sender.hashCode().toString()

                            // If specificMessageId was requested, we ALWAYS notify, ignoring deduplication
                            // This is because Realtime triggered it, so it MUST be new
                            val isSpecificRequest = specificMessageId != null && specificMessageId == messageId

                            // Always add message to history for expanded notifications, regardless of whether we show notification
                            if (matchId != null) {
                                val history = messageHistory.getOrPut(matchId) { mutableListOf() }
                                val messageText = if (content.startsWith("$sender: ")) content.substring(sender.length + 2) else content
                                // Avoid duplicates in history
                                if (!history.contains(messageText)) {
                                    history.add(messageText)
                                    // Limit history to last 5 messages
                                    if (history.size > 5) history.removeAt(0)
                                    Log.d(TAG, "Added message to history for chat $matchId: $messageText (history size: ${history.size})")
                                } else {
                                    Log.d(TAG, "Skipped duplicate message in history for chat $matchId: $messageText")
                                }
                            }

                            // Don't show notifications when viewing the chat AND app is in foreground
                            val isViewingThisChat = effectiveChatId == currentlyViewingChatId
                            if (isViewingThisChat && appInForeground) {
                                Log.d(TAG, "[ANDROID] Skipping notification - currently viewing chat and app is in foreground: $effectiveChatId")
                                return@checkForNotifications
                            }

                            // Allow notification if:
                            // 1. It's a specific request (immediate trigger), OR
                            // 2. It's not a duplicate
                            val shouldAlert = isSpecificRequest || effectiveChatId != lastNotifiedMatchId

                            if (shouldAlert) {
                                Log.d(TAG, "[ANDROID] Processing message from $sender (Chat ID: $effectiveChatId, viewing: $isViewingThisChat, shouldAlert: $shouldAlert, content: '$content')")
                                // Use sender name hash as notification ID to group message notifications per chat
                                val notificationId = sender.hashCode()
                                Log.d(TAG, "[ANDROID] Showing notification: sender='$sender', content='$content', silent=$isViewingThisChat")
                                showNotification("New Message", "$sender: $content", notificationId, sender, matchId, silent = isViewingThisChat)
                                activeNotificationIds[effectiveChatId] = notificationId

                                // Only update lastNotifiedMatchId if we actually alerted (not for silent notifications)
                                if (shouldAlert) {
                                    lastNotifiedMatchId = effectiveChatId
                                    Log.d(TAG, "Set lastNotifiedMatchId to: $effectiveChatId, stored notificationId: $notificationId")
                                } else {
                                    Log.d(TAG, "Posted silent notification for viewed chat: $effectiveChatId")
                                }
                            } else {
                                Log.d(TAG, "[ANDROID] Skipping duplicate message notification for chat ID: $effectiveChatId (lastNotifiedMatchId: $lastNotifiedMatchId, isSpecificRequest: $isSpecificRequest)")
                            }
                        } else {
                            Log.d(TAG, "No new notifications found")
                        }
                    }
                }
            } else {
                val errorBody = response.body?.string()
                Log.e(TAG, "Notification check failed: ${response.code}, body: $errorBody")
            }
            response.close()
        } catch (e: Exception) {
            Log.e(TAG, "Error checking notifications", e)
        }
    }

    private fun showNotification(title: String, content: String, notificationId: Int? = null, senderName: String? = null, matchId: String? = null, silent: Boolean = false) {
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

        // Try to find the app's launcher icon
        val iconId = try {
            resources.getIdentifier("ic_launcher", "mipmap", packageName)
        } catch (e: Exception) {
            0
        }
        
        // Fallback to system icon if app icon not found
        // Use ic_popup_reminder which is standard and likely to work
        val validIconId = if (iconId != 0) iconId else android.R.drawable.ic_popup_reminder

        Log.d(TAG, "Building notification with iconId: $validIconId (found: ${iconId != 0})")

        val notificationBuilder = NotificationCompat.Builder(this, ALERTS_CHANNEL_ID)
            .setSmallIcon(validIconId)
            .setPriority(if (silent) NotificationCompat.PRIORITY_LOW else NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setAutoCancel(true)
            .setDefaults(if (silent) 0 else NotificationCompat.DEFAULT_ALL) // No sounds/vibration for silent
            .setOnlyAlertOnce(silent) // Silent notifications don't alert
            .setContentIntent(pendingIntent)

        // Use MessagingStyle if senderName is provided (WhatsApp style)
        if (senderName != null && matchId != null) {
            // Get message history for this chat (already populated when messages arrived)
            val history = messageHistory[matchId] ?: mutableListOf()

            // Only use MessagingStyle if we have messages in history
            if (history.isNotEmpty()) {
                val person = Person.Builder().setName(senderName).build()
                val style = NotificationCompat.MessagingStyle(person)

                // Add all messages from history (these are unread messages since history is cleared when chat is entered)
                for (msg in history) {
                    style.addMessage(msg, System.currentTimeMillis(), person)
                }

                notificationBuilder.setStyle(style)
                notificationBuilder.setContentTitle(senderName) // Title is sender name
                notificationBuilder.setContentText("New message") // Simple text without count
            } else {
                // Fallback to standard style if no history available
                notificationBuilder.setContentTitle(title)
                notificationBuilder.setContentText(content)
            }
        } else {
            // Standard style for matches or system alerts
            notificationBuilder.setContentTitle(title)
            notificationBuilder.setContentText(content)
        }

        val notification = notificationBuilder.build()
        
        // Use a unique ID for message notifications so they stack or replace as needed
        Log.d(TAG, "Showing notification ID: $notifyId")
        notificationManager.notify(notifyId, notification)
    }



    private fun startHeartbeat() {
        serviceScope.launch {
            while (isActive) {
                try {
                    ensureValidJwt()
                    updateUserActivity()
                    
                    // Check Realtime connection health
                    val now = System.currentTimeMillis()
                    val timeSinceLastActivity = now - lastRealtimeActivity
                    
                    // If no activity for 60 seconds (heartbeat is every 25s), assume dead
                    if (webSocket == null || timeSinceLastActivity > 60000) {
                        Log.w(TAG, "Realtime connection stale or missing (last activity: ${timeSinceLastActivity}ms ago). Reconnecting...")
                        disconnectRealtime(reason = "stale_or_missing") // Force close existing if any
                        connectToRealtime()
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Heartbeat failed", e)
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

    private suspend fun ensureValidJwt() {
        val token = userToken
        val rt = refreshToken
        
        if (authPermanentlyFailed) {
            Log.w(TAG, "Skipping JWT validation (auth permanently failed)")
            return
        }
        
        if (rt.isNullOrBlank() || supabaseUrl.isNullOrBlank() || supabaseKey.isNullOrBlank()) {
            return
        }

        // If token is missing but we have a refresh token, try to refresh immediately
        if (token.isNullOrBlank()) {
            Log.d(TAG, "User token missing but refresh token available. Refreshing...")
            refreshJwtToken(rt)
            return
        }

        val exp = decodeJwtExpSeconds(token) ?: return
        val now = System.currentTimeMillis() / 1000L
        val secondsLeft = exp - now

        // Refresh when close to expiry (2 minutes).
        if (secondsLeft > 120) return

        Log.d(TAG, "JWT expiring soon ($secondsLeft s). Refreshing in background service...")
        refreshJwtToken(rt)
    }

    private suspend fun refreshJwtToken(currentRefreshToken: String) {
        if (supabaseUrl == null || supabaseKey == null) return

        val url = "${supabaseUrl}/auth/v1/token?grant_type=refresh_token"
        val jsonBody = JSONObject().apply {
            put("refresh_token", currentRefreshToken)
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
                Log.w(TAG, "JWT refresh failed: code=${response.code} body=$body")
                
                // If refresh token is invalid/used, clear it to prevent infinite retry loops
                if (body?.contains("refresh_token_already_used") == true || body?.contains("invalid_grant") == true) {
                    Log.e(TAG, "Refresh token invalidated/used. Clearing credentials to stop retry loop.")
                    refreshToken = null
                    userToken = null
                    authPermanentlyFailed = true
                    securePrefs().edit().remove("flutter.user_token").remove("flutter.refresh_token").putBoolean("flutter.auth_permanently_failed", true).apply()
                }
                
                response.close()
                return
            }
            response.close()

            val json = JSONObject(body)
            val newAccessToken = json.optString("access_token", "")
            val newRefreshToken = json.optString("refresh_token", "")
            if (newAccessToken.isBlank()) {
                Log.w(TAG, "JWT refresh response missing access_token")
                return
            }

            userToken = newAccessToken
            if (newRefreshToken.isNotBlank()) {
                refreshToken = newRefreshToken
            }

            // Persist so service restarts keep working. Use flutter.* keys to match restore.
            try {
                securePrefs().edit().apply {
                    putString("flutter.user_token", userToken)
                    if (!refreshToken.isNullOrBlank()) {
                        putString("flutter.refresh_token", refreshToken)
                    }
                    apply()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to persist refreshed tokens: $e")
            }

            // Reconnect realtime with the new token.
            disconnectRealtime()
            connectToRealtime()
            Log.d(TAG, "JWT refreshed successfully; Realtime reconnected")
        } catch (e: Exception) {
            Log.e(TAG, "JWT refresh exception", e)
        }
    }

    private suspend fun updateUserActivity() {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return
        if (authPermanentlyFailed) {
            Log.w(TAG, "Skipping update_user_activity RPC (auth permanently failed)")
            return
        }
        if (userToken.isNullOrBlank()) {
            Log.w(TAG, "Skipping update_user_activity RPC (missing user JWT)")
            return
        }

        val url = "$supabaseUrl/rest/v1/rpc/update_user_activity"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val request = okhttp3.Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Authorization", "Bearer $userToken")
            .addHeader("Content-Type", "application/json")
            .build()

        val response = httpClient.newCall(request).execute()
        try {
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                Log.e(TAG, "Failed to update user activity: ${response.code}, ${response.message}, body: $errorBody")
            } else {
                Log.d(TAG, "Successfully updated user activity")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception updating user activity: ${e.message}", e)
        } finally {
            response.close()
        }
    }

    // --- Realtime WebSocket Implementation ---

    private fun connectToRealtime() {
        if (supabaseUrl == null || supabaseKey == null) return
        if (authPermanentlyFailed) {
            Log.w(TAG, "Skipping Realtime connect (auth permanently failed)")
            return
        }
        // Don't connect with null token; try refresh once so post-boot we get a token before joining
        if (userToken.isNullOrBlank()) {
            val rt = refreshToken
            if (!rt.isNullOrBlank()) {
                Log.d(TAG, "No access token; refreshing JWT before Realtime connect")
                serviceScope.launch {
                    refreshJwtToken(rt)
                    connectToRealtime()
                }
                return
            }
            Log.d(TAG, "Skipping Realtime connect (no token and no refresh token)")
            return
        }

        val now = System.currentTimeMillis()
        synchronized(realtimeLock) {
            // Debounce repeated connect attempts (e.g., START + UPDATE_TOKEN + heartbeat).
            if (isRealtimeConnecting && (now - lastRealtimeConnectAttemptAt) < 2000) {
                Log.d(TAG, "Skipping Realtime connect (already connecting)")
                return
            }

            if (webSocket != null) {
                // If socket exists, check if it's healthy
                val timeSinceLastActivity = now - lastRealtimeActivity
                if (timeSinceLastActivity < 60000) {
                    return // Healthy enough
                }
                Log.w(TAG, "Existing WebSocket is stale (${timeSinceLastActivity}ms). Reconnecting.")
                disconnectRealtime(reason = "stale")
            }

            isRealtimeConnecting = true
            lastRealtimeConnectAttemptAt = now
        }

        Log.d(TAG, "[NATIVE] connectToRealtime: start")
        realtimeConnectStartAt = System.currentTimeMillis()
        Log.d(TAG, "Connecting to Supabase Realtime...")
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
                val elapsed = System.currentTimeMillis() - realtimeConnectStartAt
                Log.d(TAG, "[NATIVE] Realtime WebSocket Connected (elapsed=${elapsed}ms)")
                lastRealtimeActivity = System.currentTimeMillis()
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                    reconnectDelay = 1000L // Reset backoff
                }
                joinChannel(webSocket)
                startHeartbeat(webSocket)
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                // Log.d(TAG, "Realtime Message: $text") // Verbose
                lastRealtimeActivity = System.currentTimeMillis()
                handleRealtimeMessage(text)
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Realtime WebSocket Closing: $code / $reason")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Realtime WebSocket Closed: $code / $reason")
                this@MatchMeBackgroundService.webSocket = null
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                }

                // Reconnect unless we intentionally closed very recently (token update / stale check).
                val closedAt = System.currentTimeMillis()
                if ((closedAt - lastIntentionalRealtimeCloseAt) < 1500) {
                    Log.d(TAG, "Skipping Realtime reconnect (intentional close)")
                    return
                }

                val delayMs = reconnectDelay
                reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY)
                Log.d(TAG, "Reconnecting in ${delayMs}ms (Backoff)")

                serviceScope.launch {
                    delay(delayMs)
                    connectToRealtime()
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                // Reduce log noise for common network errors
                if (t is java.net.SocketTimeoutException || t is java.net.SocketException || t is javax.net.ssl.SSLHandshakeException) {
                     Log.w(TAG, "Realtime WebSocket Failure: ${t.message} (Retrying in ${reconnectDelay}ms)")
                } else {
                     Log.e(TAG, "Realtime WebSocket Failure: ${t.message}", t)
                }

                this@MatchMeBackgroundService.webSocket = null
                synchronized(realtimeLock) {
                    isRealtimeConnecting = false
                }

                // Retry quickly to minimize downtime (unless we intentionally closed).
                val failedAt = System.currentTimeMillis()
                if ((failedAt - lastIntentionalRealtimeCloseAt) < 1500) {
                    Log.d(TAG, "Skipping Realtime reconnect after failure (intentional close)")
                    return
                }

                val delayMs = reconnectDelay
                reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY)

                serviceScope.launch {
                    delay(delayMs)
                    connectToRealtime()
                }
            }
        })
    }

    private fun disconnectRealtime(reason: String = "Service stopping") {
        synchronized(realtimeLock) {
            lastIntentionalRealtimeCloseAt = System.currentTimeMillis()
            isRealtimeConnecting = false
        }
        webSocket?.close(1000, reason)
        webSocket = null
        realtimeJob?.cancel()
        Log.d(TAG, "Realtime WebSocket Disconnected")
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
            Log.d(
                TAG,
                "Sent Realtime Join: topic=$topic token=${if (userToken.isNullOrBlank()) "null" else "present"}"
            )
        }

        // 1) chat_messages (only messages relevant to this user)
        run {
            val topic = "realtime:public:chat_messages"
            val changes = org.json.JSONArray().put(JSONObject().apply {
                put("event", "INSERT")
                put("schema", "public")
                put("table", "chat_messages")
                if (!filterUserId.isNullOrBlank()) {
                    put("filter", "receiver_id=eq.$filterUserId")
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
                Log.w(TAG, "Skipping matches realtime join (missing userId)")
                return@run
            }
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
                    // Log.d(TAG, "Sent Realtime Heartbeat")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to send Realtime heartbeat", e)
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
                    Log.d(
                        TAG,
                        "Realtime: postgres_changes type=$type hasRecord=${record != null} payloadKeys=${payload?.keys()?.asSequence()?.take(8)?.joinToString(",") ?: "null"}"
                    )
                }

                if (type == "INSERT" && record != null) {
                    if (table == "chat_messages") {
                        val senderId = record.optString("sender_id", "")
                        val messageId = record.optString("id", "")
                        val matchId = record.optString("match_id", "")

                        // If sender is NOT me, it's a new message
                        if (senderId.isNotBlank() && senderId != userId) {
                            Log.d(TAG, "Realtime: New message detected sender=$senderId messageId=$messageId matchId=$matchId")

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
                                        Log.e(TAG, "Error releasing WakeLock", e)
                                    }
                                }
                            }
                        }
                    } else if (table == "matches") {
                        val matchId = record.optString("id", "")
                        Log.d(TAG, "Realtime: New match detected matchId=$matchId")

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
                                    Log.e(TAG, "Error releasing WakeLock", e)
                                }
                            }
                        }
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
						Log.d(TAG, "Realtime: postgres_changes ignored ($meta) (and more in next 30s)")
					}
                }
            } else if (event == "phx_reply") {
                val payload = json.optJSONObject("payload")
                val status = payload?.optString("status")
                if (status == "ok") {
                    Log.d(TAG, "Realtime: Joined channel successfully")
                } else if (status == "error") {
                    Log.e(TAG, "Realtime: Join failed: $payload")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error parsing realtime message", e)
        }
    }

    private fun schedulePeriodicWork() {
        Log.d(TAG, "Scheduling periodic location work (Standard Mode)")
        val workRequest = PeriodicWorkRequestBuilder<LocationWorker>(15, TimeUnit.MINUTES)
            .setInitialDelay(15, TimeUnit.MINUTES) // Don't run immediately, we just had a location
            .build()

        WorkManager.getInstance(applicationContext).enqueueUniquePeriodicWork(
            "MatchMePeriodicLocation",
            ExistingPeriodicWorkPolicy.UPDATE,
            workRequest
        )
    }

    private fun cancelPeriodicWork() {
        Log.d(TAG, "Cancelling periodic location work (High Accuracy Mode or Foreground)")
        WorkManager.getInstance(applicationContext).cancelUniqueWork("MatchMePeriodicLocation")
    }
}
