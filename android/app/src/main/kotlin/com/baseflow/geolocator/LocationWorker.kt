package com.baseflow.geolocator

import android.content.Context
import android.content.SharedPreferences
import android.location.Location
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
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

    override suspend fun doWork(): Result {
        Log.d(TAG, "Starting periodic location update work")

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

        val userId = readString("flutter.user_id", "user_id")
        val supabaseUrl = readString("flutter.supabase_url", "supabase_url")
        val supabaseKey = readString("flutter.supabase_key", "supabase_key")
        val userToken = readString("flutter.user_token", "user_token")
        val highAccuracyMode = readBool("flutter.high_accuracy_mode", "high_accuracy_mode", false)
        val isVisible = readBool("flutter.manual_visibility", "manual_visibility", true)
        val isOnline = readBool("flutter.is_online", "is_online", true)

        if (userId == null || supabaseUrl == null || supabaseKey == null) {
            Log.w(TAG, "Missing credentials, skipping work")
            return Result.failure()
        }

        // If High Accuracy Mode is enabled, the Foreground Service should be running.
        // We don't need to do anything here (or maybe we do as a backup?).
        // Let's assume the service handles it.
        if (highAccuracyMode) {
            Log.d(TAG, "High Accuracy Mode enabled, skipping periodic work (Service handles it)")
            return Result.success()
        }

        if (!isVisible || !isOnline) {
            Log.d(TAG, "User invisible or offline, skipping location update")
            return Result.success()
        }

        // 2. Get Location
        try {
            val fusedLocationClient = LocationServices.getFusedLocationProviderClient(applicationContext)
            
            // Use PRIORITY_BALANCED_POWER_ACCURACY for periodic updates to save battery
            val location = fusedLocationClient.getCurrentLocation(
                Priority.PRIORITY_BALANCED_POWER_ACCURACY,
                null
            ).await()

            if (location != null) {
                Log.d(TAG, "Got location: ${location.latitude}, ${location.longitude}")
                
                // 3. Send to Supabase
                updateLocationInSupabase(userId, supabaseUrl, supabaseKey, userToken, location)
                
                // 4. Trigger Match Engine
                triggerMatchEngine(userId, supabaseUrl, supabaseKey, userToken, location)
            } else {
                Log.w(TAG, "Failed to get location (null)")
            }

        } catch (e: SecurityException) {
            Log.e(TAG, "Missing location permissions", e)
            return Result.failure()
        } catch (e: Exception) {
            Log.e(TAG, "Error getting location", e)
            return Result.retry()
        }

        return Result.success()
    }

    private fun updateLocationInSupabase(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        location: Location
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
                Log.e(TAG, "Failed to update location: ${response.code}")
            } else {
                Log.d(TAG, "Successfully updated location in Supabase")
            }
            response.close()
        } catch (e: Exception) {
            Log.e(TAG, "Exception updating location in Supabase", e)
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
                     Log.d(TAG, "Match engine 401 (expected if requiring service role)")
                } else {
                     Log.e(TAG, "Failed to trigger match engine: ${response.code}")
                }
            } else {
                Log.d(TAG, "Successfully triggered match engine")
            }
            response.close()
        } catch (e: Exception) {
            Log.e(TAG, "Exception triggering match engine", e)
        }
    }
}
