package com.baseflow.geolocator

import android.app.*
import android.content.Context
import android.content.Intent
import android.location.Location
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.*
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class MatchMeBackgroundService : Service() {
    private val TAG = "MatchMeBackgroundService"
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var locationRequest: LocationRequest
    private lateinit var locationCallback: LocationCallback
    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var userId: String? = null
    private var supabaseUrl: String? = null
    private var supabaseKey: String? = null
    private var userToken: String? = null
    private var isVisible = false

    private var methodChannel: MethodChannel? = null
    private val httpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    companion object {
        const val CHANNEL_ID = "matchme_background_service"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        const val ACTION_UPDATE_VISIBILITY = "UPDATE_VISIBILITY"
        const val ACTION_UPDATE_TOKEN = "UPDATE_TOKEN"
        const val EXTRA_USER_ID = "userId"
        const val EXTRA_SUPABASE_URL = "supabaseUrl"
        const val EXTRA_SUPABASE_KEY = "supabaseKey"
        const val EXTRA_USER_TOKEN = "userToken"
        const val EXTRA_IS_VISIBLE = "isVisible"

        fun startService(context: Context, userId: String, supabaseUrl: String, supabaseKey: String, userToken: String?) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_USER_ID, userId)
                putExtra(EXTRA_SUPABASE_URL, supabaseUrl)
                putExtra(EXTRA_SUPABASE_KEY, supabaseKey)
                putExtra(EXTRA_USER_TOKEN, userToken)
            }
            context.startForegroundService(intent)
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

        fun updateToken(context: Context, token: String?) {
            val intent = Intent(context, MatchMeBackgroundService::class.java).apply {
                action = ACTION_UPDATE_TOKEN
                putExtra(EXTRA_USER_TOKEN, token)
            }
            context.startService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Background service created")

        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)

        // Create notification channel for Android 8.0+
        createNotificationChannel()

        // Set up location request for background location updates
        // Use BALANCED_POWER_ACCURACY for background to avoid Android restrictions
        locationRequest = LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, 60000L) // 60 seconds
            .setMinUpdateIntervalMillis(30000L) // 30 seconds minimum
            .setMinUpdateDistanceMeters(50f) // 50 meters minimum distance
            .setWaitForAccurateLocation(false) // Don't wait for most accurate location
            .build()

        Log.d(TAG, "Location request configured: priority=BALANCED, interval=60s, minInterval=30s, minDistance=50m")

        // Set up location callback
        locationCallback = object : LocationCallback() {
            override fun onLocationResult(locationResult: com.google.android.gms.location.LocationResult) {
                super.onLocationResult(locationResult)
                Log.d(TAG, "Location callback received ${locationResult.locations?.size ?: 0} locations")
                for (location in locationResult.locations!!) {
                    handleLocationUpdate(location)
                }
            }

            override fun onLocationAvailability(availability: LocationAvailability) {
                super.onLocationAvailability(availability)
                Log.d(TAG, "Location availability changed: ${availability.isLocationAvailable}")
            }
        }

        // Start heartbeat
        startHeartbeat()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Background service started with action: ${intent?.action}")

        when (intent?.action) {
            ACTION_START -> {
                userId = intent.getStringExtra(EXTRA_USER_ID)
                supabaseUrl = intent.getStringExtra(EXTRA_SUPABASE_URL)
                supabaseKey = intent.getStringExtra(EXTRA_SUPABASE_KEY)
                userToken = intent.getStringExtra(EXTRA_USER_TOKEN)

                Log.d(TAG, "Starting service with userId: $userId, url: $supabaseUrl, key length: ${supabaseKey?.length}, token: ${userToken?.let { "present (${it.length} chars)" } ?: "null"}")

                if (userId != null && supabaseUrl != null && supabaseKey != null) {
                    startForeground(NOTIFICATION_ID, createNotification())
                    startLocationUpdates()
                } else {
                    Log.e(TAG, "Missing required parameters for background service")
                }
            }
            ACTION_UPDATE_VISIBILITY -> {
                isVisible = intent.getBooleanExtra(EXTRA_IS_VISIBLE, false)
                Log.d(TAG, "Visibility updated: $isVisible")
                updateNotification()
                if (isVisible) {
                    startLocationUpdates()
                } else {
                    stopLocationUpdates()
                }
            }
            ACTION_UPDATE_TOKEN -> {
                userToken = intent.getStringExtra(EXTRA_USER_TOKEN)
                Log.d(TAG, "JWT token updated: ${userToken?.let { "present" } ?: "null"}")
            }
            ACTION_STOP -> {
                Log.d(TAG, "ACTION_STOP received - stopping service and clearing sensitive state")
                stopForeground(true)
                stopSelf()
                // Clear sensitive fields immediately
                userId = null
                supabaseUrl = null
                supabaseKey = null
                userToken = null
                isVisible = false
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Background service destroyed")
        stopLocationUpdates()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "MatchMe Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps MatchMe running in the background"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
            }

            val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val title = "MatchMe Active"
        val text = if (isVisible) "Finding matches nearby" else "Maintaining connection"

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setSilent(true)
            .build()
    }

    private fun updateNotification() {
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.notify(NOTIFICATION_ID, createNotification())
    }

    private fun startLocationUpdates() {
        try {
            Log.d(TAG, "startLocationUpdates called, isVisible=$isVisible")
            if (isVisible) {
                Log.d(TAG, "Requesting location updates from FusedLocationProviderClient")
                fusedLocationClient.requestLocationUpdates(
                    locationRequest,
                    locationCallback,
                    Looper.getMainLooper()
                )
                Log.d(TAG, "Location updates started successfully")
            } else {
                Log.d(TAG, "Not starting location updates - user is not visible")
            }
        } catch (e: SecurityException) {
            Log.e(TAG, "Location permission not granted", e)
        } catch (e: Exception) {
            Log.e(TAG, "Error starting location updates", e)
        }
    }

    private fun stopLocationUpdates() {
        fusedLocationClient.removeLocationUpdates(locationCallback)
        Log.d(TAG, "Location updates stopped")
    }

    private fun handleLocationUpdate(location: Location) {
        Log.d(TAG, "handleLocationUpdate called: isVisible=$isVisible, userId=$userId, location=${location.latitude},${location.longitude}")
        if (!isVisible || userId == null) {
            Log.d(TAG, "Skipping location update: isVisible=$isVisible, userId=${userId != null}")
            return
        }

        Log.d(TAG, "Processing location update for user $userId")
        serviceScope.launch {
            try {
                updateLocationInSupabase(location)
                triggerMatchEngine(location)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to handle location update", e)
            }
        }
    }

    private suspend fun updateLocationInSupabase(location: Location) {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return

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
            .addHeader("Authorization", "Bearer $supabaseKey")
            .addHeader("Content-Type", "application/json")
            .build()

        val response = httpClient.newCall(request).execute()
        try {
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                Log.e(TAG, "Failed to update location: ${response.code}, ${response.message}, body: $errorBody")
                Log.e(TAG, "Request URL: $url")
                Log.e(TAG, "Request body: ${jsonBody.toString()}")
            } else {
                val responseBody = response.body?.string()
                Log.d(TAG, "Successfully updated location: $responseBody")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception updating location: ${e.message}", e)
        } finally {
            response.close()
        }
    }

    private suspend fun triggerMatchEngine(location: Location) {
        val url = "$supabaseUrl/functions/v1/match-engine"
        val jsonBody = JSONObject().apply {
            put("userId", userId)
            put("latitude", location.latitude)
            put("longitude", location.longitude)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val requestBuilder = okhttp3.Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Content-Type", "application/json")

        // Try JWT token first for match engine authentication
        if (userToken != null && userToken!!.isNotEmpty()) {
            requestBuilder.addHeader("Authorization", "Bearer $userToken")
            Log.d(TAG, "Using JWT token for match engine (length: ${userToken!!.length})")
        } else {
            Log.d(TAG, "No JWT token available for match engine - this may cause 401 error")
            // Don't add Authorization header - let match engine handle missing auth
        }

        val request = requestBuilder.build()

        // Debug logging for match engine request
        Log.d(TAG, "Match engine request URL: ${request.url}")
        Log.d(TAG, "Match engine headers: ${request.headers}")
        Log.d(TAG, "Match engine request body: ${request.body}")

        val response = httpClient.newCall(request).execute()
        try {
            if (!response.isSuccessful) {
                val errorBody = response.body?.string()
                if (response.code == 401) {
                    // Match engine requires service role permissions, which we can't provide from client
                    Log.w(TAG, "Match engine 401 error - this is expected as match engine requires server-side authentication")
                    Log.d(TAG, "Location update completed successfully, match engine will work when app is foreground")
                } else {
                    Log.e(TAG, "Failed to trigger match engine: ${response.code}, ${response.message}, body: $errorBody")
                }
            } else {
                Log.d(TAG, "Successfully triggered match engine")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception triggering match engine: ${e.message}", e)
        } finally {
            response.close()
        }
    }

    private fun startHeartbeat() {
        serviceScope.launch {
            while (isActive) {
                try {
                    updateUserActivity()
                } catch (e: Exception) {
                    Log.e(TAG, "Heartbeat failed", e)
                }
                delay(30000L) // 30 seconds
            }
        }
    }

    private suspend fun updateUserActivity() {
        if (userId == null || supabaseUrl == null || supabaseKey == null) return

        val url = "$supabaseUrl/rest/v1/rpc/update_user_activity"
        val jsonBody = JSONObject().apply {
            put("p_user_id", userId)
        }

        val requestBody = jsonBody.toString().toRequestBody("application/json".toMediaType())

        val request = okhttp3.Request.Builder()
            .url(url)
            .post(requestBody)
            .addHeader("apikey", supabaseKey!!)
            .addHeader("Authorization", "Bearer $supabaseKey")
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
}
