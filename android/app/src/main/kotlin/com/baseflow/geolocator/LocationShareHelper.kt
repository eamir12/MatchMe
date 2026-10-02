package com.baseflow.geolocator

import android.content.Context
import android.location.Location
import android.os.Looper
import android.os.PowerManager
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.*
import okhttp3.*
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.Priority
import kotlin.math.max
import kotlin.math.min
import java.io.IOException

/**
 * Helper class that manages live location share broadcasting from the native
 * background service via the Supabase Realtime WebSocket.
 *
 * When the Flutter UI is backgrounded, the native service's Realtime WebSocket
 * connection continues to function. This helper broadcasts encrypted position
 * updates directly over that WebSocket, so no location data is ever persisted
 * in the database.
 *
 * The helper is designed to be called from [MatchMeBackgroundService] and
 * uses the service's OkHttp client, FusedLocationProviderClient, and
 * Realtime WebSocket connection.
 */
class LocationShareHelper(
    private val context: Context,
    private val httpClient: OkHttpClient,
    private val fusedLocationClient: FusedLocationProviderClient,
    private val serviceScope: CoroutineScope,
) {
    private var lsJob: Job? = null

    @Volatile private var lsMatchId: String? = null
    @Volatile private var lsOtherUserId: String? = null
    @Volatile private var lsSessionKey: ByteArray? = null
    @Volatile private var lsIntervalSeconds: Int = 5
    @Volatile var lsExpiresAt: String? = null
        private set

    // WebSocket reference for broadcasting via Realtime
    private var realtimeWs: WebSocket? = null
    private var joinedChannel: Boolean = false

    // Held while the share loop runs so Doze doesn't stall the broadcast cadence.
    private var wakeLock: PowerManager.WakeLock? = null
    private var onEndedCallback: (() -> Unit)? = null

    // Continuous GPS tracking: keeps the GPS chip engaged so the status-bar icon
    // stays visible and fixes arrive in real time. We cache the latest fix and
    // broadcast from cache at the configured interval instead of making one-shot
    // calls (which would power-cycle the chip between ticks).
    @Volatile private var latestCachedLocation: Location? = null
    private var locationCallback: LocationCallback? = null
    @Volatile private var continuousLocationRegistered: Boolean = false

    // These are set by the service before calling start()
    @Volatile var supabaseUrl: String? = null
    @Volatile var supabaseKey: String? = null
    @Volatile var userId: String? = null
    @Volatile var userToken: String? = null
    @Volatile var refreshToken: String? = null

    // Kept in sync by the service from its connectivity state. While offline
    // the loop skips GPS reads and REST checks but keeps running so sharing
    // resumes automatically once connectivity returns.
    @Volatile var isOnline: Boolean = true

    /**
     * Sets the WebSocket reference for the Realtime connection.
     * Called by the service whenever the WebSocket is created/recreated.
     */
    fun setRealtimeWebSocket(ws: WebSocket?) {
        realtimeWs = ws
        joinedChannel = false
    }

    /**
     * Registers a callback invoked whenever the share ends (explicit stop,
     * expiry, or the signal disappearing from the database).
     */
    fun setOnShareEnded(callback: () -> Unit) {
        onEndedCallback = callback
    }

    fun start(
        matchId: String,
        otherUserId: String,
        sessionKeyBase64: String,
        updateIntervalSeconds: Int,
        expiresAtIso: String?,
        bearerAuthHeaderProvider: () -> String,
        ensureValidJwt: suspend () -> Unit,
        refreshJwt: suspend (String) -> Unit,
    ) {
        lsMatchId = matchId
        lsOtherUserId = otherUserId
        lsSessionKey = Base64.decode(sessionKeyBase64, Base64.NO_WRAP)
        lsIntervalSeconds = updateIntervalSeconds
        lsExpiresAt = expiresAtIso
        startContinuousLocation()
        startLoop(bearerAuthHeaderProvider, ensureValidJwt, refreshJwt)
    }

    fun stop() {
        stopContinuousLocation()
        lsJob?.cancel()
        lsJob = null
        leaveChannel()
        releaseWakeLock()
        lsMatchId = null
        lsOtherUserId = null
        lsSessionKey = null
        lsExpiresAt = null
        latestCachedLocation = null
        onEndedCallback?.invoke()
    }

    fun updateExpiresAt(expiresAtIso: String?) {
        lsExpiresAt = expiresAtIso
    }

    private fun startContinuousLocation() {
        if (continuousLocationRegistered) return
        val hasFine = context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val hasCoarse = context.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!hasFine && !hasCoarse) {
            Log.w("LocationShareHelper", "startContinuousLocation: no location permission")
            return
        }

        val intervalMs = 1000L
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, intervalMs)
            .setMinUpdateIntervalMillis(intervalMs / 2)
            .setMinUpdateDistanceMeters(0f)
            .build()

        val cb = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val loc = result.lastLocation ?: return
                latestCachedLocation = loc
            }
        }
        locationCallback = cb
        try {
            fusedLocationClient.requestLocationUpdates(request, cb, Looper.getMainLooper())
            continuousLocationRegistered = true
            Log.d("LocationShareHelper", "Continuous HIGH_ACCURACY location tracking started")
        } catch (e: SecurityException) {
            Log.w("LocationShareHelper", "startContinuousLocation: permission denied", e)
            locationCallback = null
        } catch (e: Exception) {
            Log.w("LocationShareHelper", "startContinuousLocation failed", e)
            locationCallback = null
        }
    }

    private fun stopContinuousLocation() {
        val cb = locationCallback ?: return
        try {
            fusedLocationClient.removeLocationUpdates(cb)
        } catch (_: Exception) {}
        locationCallback = null
        continuousLocationRegistered = false
        latestCachedLocation = null
        Log.d("LocationShareHelper", "Continuous location tracking stopped")
    }

    private fun joinChannel() {
        val ws = realtimeWs ?: return
        val matchId = lsMatchId ?: return
        if (joinedChannel) return

        val joinPayload = JSONObject().apply {
            put("topic", "location-share:$matchId")
            put("event", "phx_join")
            put("payload", JSONObject().apply {
                put("config", JSONObject().apply {
                    put("broadcast", JSONObject().apply {
                        put("ack", false)
                        put("self", false)
                    })
                    put("presence", JSONObject().apply {
                        put("key", "")
                    })
                })
            })
            put("ref", System.currentTimeMillis())
        }
        try {
            ws.send(joinPayload.toString())
            joinedChannel = true
        } catch (e: Exception) {
        }
    }

    private fun leaveChannel() {
        if (!joinedChannel) return
        val ws = realtimeWs ?: return
        val matchId = lsMatchId ?: return
        val leavePayload = JSONObject().apply {
            put("topic", "location-share:$matchId")
            put("event", "phx_leave")
            put("payload", JSONObject())
            put("ref", System.currentTimeMillis())
        }
        try {
            ws.send(leavePayload.toString())
        } catch (e: Exception) {
        }
        joinedChannel = false
    }

    private fun broadcastPosition(lat: Double, lng: Double, heading: Float, speed: Float) {
        Log.d("LocationShareHelper", "broadcastPosition called: ws=$realtimeWs, joined=$joinedChannel")
        val ws = realtimeWs
        if (ws == null) {
            Log.w("LocationShareHelper", "broadcastPosition: WebSocket is null, skipping broadcast")
            return
        }
        val matchId = lsMatchId ?: return
        val key = lsSessionKey ?: return
        if (!joinedChannel) {
            Log.d("LocationShareHelper", "broadcastPosition: joining channel first...")
            joinChannel()
        }

        try {
            val ts = System.currentTimeMillis()
            val jsonPayload = JSONObject().apply {
                put("lat", lat)
                put("lng", lng)
                put("heading", heading)
                put("speed", speed)
                put("ts", ts)
                val sharerId = userId
                if (sharerId != null) put("userId", sharerId)
            }
            val plaintext = jsonPayload.toString().toByteArray(Charsets.UTF_8)

            val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            val keySpec = javax.crypto.spec.SecretKeySpec(key, "AES")
            val iv = ByteArray(12)
            java.security.SecureRandom().nextBytes(iv)
            cipher.init(
                javax.crypto.Cipher.ENCRYPT_MODE,
                keySpec,
                javax.crypto.spec.GCMParameterSpec(128, iv)
            )
            cipher.updateAAD("matchme.location.v1".toByteArray(Charsets.UTF_8))
            val ciphertext = cipher.doFinal(plaintext)

            val combined = ByteArray(iv.size + ciphertext.size)
            System.arraycopy(iv, 0, combined, 0, iv.size)
            System.arraycopy(ciphertext, 0, combined, iv.size, ciphertext.size)

            val encryptedB64 = Base64.encodeToString(combined, Base64.NO_WRAP)

            val broadcastMsg = JSONObject().apply {
                put("topic", "location-share:$matchId")
                put("event", "broadcast")
                put("payload", JSONObject().apply {
                    put("event", "position")
                    put("type", "broadcast")
                    put("data", encryptedB64)
                })
                put("ref", null as String?)
            }
            val msgStr = broadcastMsg.toString()
            Log.d("LocationShareHelper", "Broadcasting encrypted position over WebSocket: $msgStr")
            ws.send(msgStr)
        } catch (e: Exception) {
            Log.e("LocationShareHelper", "Failed to broadcast position: ${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun startLoop(
        bearerAuthHeaderProvider: () -> String,
        ensureValidJwt: suspend () -> Unit,
        refreshJwt: suspend (String) -> Unit,
    ) {
        Log.d("LocationShareHelper", "startLoop started for matchId=$lsMatchId")
        lsJob?.cancel()
        lsJob = serviceScope.launch {
            delay(1000)
            acquireWakeLock()
            while (isActive && lsMatchId != null && lsSessionKey != null) {
                try {
                    // Always enforce expiry locally, even while offline, so an
                    // expired share stops promptly instead of relying solely on
                    // the DB cleanup.
                    if (lsExpiresAt != null) {
                        val expiresMs = parseIsoToMillis(lsExpiresAt!!)
                        if (System.currentTimeMillis() > expiresMs) break
                    }

                    if (isOnline) {
                        try {
                            ensureValidJwt()
                        } catch (_: Exception) {
                        }

                        if (!isSignalActive(bearerAuthHeaderProvider, ensureValidJwt)) break

                        val hasFineLocation = (context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                            == android.content.pm.PackageManager.PERMISSION_GRANTED)
                        val hasCoarseLocation = (context.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                            == android.content.pm.PackageManager.PERMISSION_GRANTED)

                        if (!hasFineLocation && !hasCoarseLocation) {
                            Log.w("LocationShareHelper", "Location permissions not granted. Stopping location share.")
                            break
                        }

                        if (!continuousLocationRegistered) {
                            startContinuousLocation()
                        }

                        var location = latestCachedLocation
                        if (location == null) {
                            Log.d("LocationShareHelper", "No cached location yet; performing one-shot HIGH_ACCURACY fetch...")
                            try {
                                location = withContext(Dispatchers.Main) {
                                    val task = fusedLocationClient.getCurrentLocation(
                                        Priority.PRIORITY_HIGH_ACCURACY, null
                                    )
                                    suspendCancellableCoroutine<Location?> { cont ->
                                        task.addOnSuccessListener { loc -> cont.resume(loc, null) }
                                        task.addOnFailureListener { e ->
                                            Log.w("LocationShareHelper", "One-shot fetch failed: ${e.message}")
                                            cont.resume(null, null)
                                        }
                                    }
                                }
                                if (location != null) latestCachedLocation = location
                            } catch (e: Exception) {
                                Log.w("LocationShareHelper", "One-shot fetch exception", e)
                            }
                        }

                        if (location != null && lsSessionKey != null && lsMatchId != null) {
                            broadcastPosition(
                                location.latitude, location.longitude,
                                location.bearing, location.speed
                            )
                        } else {
                            Log.d("LocationShareHelper", "No location available yet, skipping broadcast tick")
                        }
                    }
                    // While offline, skip GPS reads, JWT refreshes, and REST
                    // checks to conserve battery. The loop keeps running so
                    // broadcasts resume automatically once connectivity
                    // returns (the Realtime WebSocket reconnect re-sets
                    // realtimeWs and re-joins the channel).
                } catch (e: Exception) {
                    // Network or GPS error — will retry on next iteration
                }

                val delayMs = max(lsIntervalSeconds, 2) * 1000L
                // Poll isOnline more frequently while offline so sharing
                // resumes quickly once connectivity is restored.
                delay(if (isOnline) delayMs else min(delayMs, 2000L))
            }
            // Clean up after loop ends. stopContinuousLocation MUST be the
            // first thing here: the loop may have exited during an iteration
            // that reached startContinuousLocation() (e.g. share was valid
            // for a number of ticks, then deleted from the DB mid-stream, so
            // isSignalActive returned false on a later iteration and we
            // broke out). Without this, the HIGH_ACCURACY callback stays
            // registered with FusedLocationProvider → GPS/Location icon
            // remains lit 24/7 until the process dies, draining battery.
            stopContinuousLocation()
            leaveChannel()
            // Best-effort: delete our own signal so the peer transitions to
            // "Stopped" promptly instead of lingering on "Stale" until the
            // server-side expired-signal cleanup runs. Idempotent and scoped
            // to our own sharer_id (safe for mutual sharing). Skipped when
            // the loop was cancelled by an explicit stop() — Dart already
            // deletes the signal on that path.
            try {
                deleteOwnSignal()
            } catch (_: Exception) {}
            releaseWakeLock()
            lsMatchId = null
            lsOtherUserId = null
            lsSessionKey = null
            lsExpiresAt = null
            latestCachedLocation = null
            onEndedCallback?.invoke()
        }
    }

    /**
     * Fetches the other user's display name from the database.
     * This is used for the notification text.
     */
    suspend fun fetchOtherUserName(): String? {
        val otherUserId = lsOtherUserId ?: return null
        val url = supabaseUrl ?: return null
        val key = supabaseKey ?: return null

        val request = Request.Builder()
            .url("$url/rest/v1/users?select=name&id=eq.$otherUserId")
            .get()
            .addHeader("apikey", key)
            .addHeader("Authorization", "Bearer $userToken")
            .build()

        return try {
            val response = httpClient.newCall(request).execute()
            val body = response.body?.string()
            response.close()

            if (body != null) {
                // Parse the JSON array to get the name
                val arr = body.replace("[", "").replace("]", "")
                if (arr.isNotEmpty()) {
                    // Extract name from JSON object string: {"name":"John"}
                    val nameMatch = "\"name\":\"([^\"]*)\"".toRegex().find(arr)
                    return nameMatch?.groupValues?.get(1)
                }
            }
            null
        } catch (e: Exception) {
            null
        }
    }

    private fun acquireWakeLock() {
        try {
            val existing = wakeLock
            if (existing != null && existing.isHeld) return
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MatchMe:LocationShare").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let {
                if (it.isHeld) it.release()
            }
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    /**
     * Best-effort DELETE of our own share signal. Called when the broadcast
     * loop ends naturally (expiry, signal gone, permission lost) so the peer
     * learns promptly via Postgres Changes DELETE instead of sitting on
     * "Stale" until server cleanup. Failures are swallowed: the loop is
     * ending either way and the server cleanup is authoritative.
     */
    private suspend fun deleteOwnSignal() {
        val matchId = lsMatchId ?: return
        val uid = userId ?: return
        val url = supabaseUrl ?: return
        val key = supabaseKey ?: return
        val token = userToken
        try {
            val request = Request.Builder()
                .url("$url/rest/v1/location_share_signals?match_id=eq.$matchId&sharer_id=eq.$uid")
                .delete()
                .addHeader("apikey", key)
                .addHeader("Authorization", if (!token.isNullOrBlank()) "Bearer $token" else "Bearer $key")
                .build()
            val response = httpClient.newCall(request).execute()
            response.close()
        } catch (_: Exception) {
        }
    }

    private suspend fun isSignalActive(
        bearerAuthHeaderProvider: () -> String,
        ensureValidJwt: suspend () -> Unit,
    ): Boolean {
        val matchId = lsMatchId ?: return false
        val uid = userId ?: return false
        val url = supabaseUrl ?: return false
        val key = supabaseKey ?: return false

        val request = Request.Builder()
            .url("$url/rest/v1/location_share_signals?select=id&match_id=eq.$matchId&sharer_id=eq.$uid&or=(expires_at.gt.now(),expires_at.is.null)")
            .get()
            .addHeader("apikey", key)
            .addHeader("Authorization", bearerAuthHeaderProvider())
            .build()

        return try {
            var response = httpClient.newCall(request).execute()
            if (response.code == 401) {
                response.close()
                // Token may be stale after a reboot — refresh and retry once.
                try {
                    ensureValidJwt()
                } catch (_: Exception) {
                }
                response = httpClient.newCall(request).execute()
            }
            val body = response.body?.string()
            response.close()
            body != null && body.contains(""""id"""")
        } catch (e: Exception) {
            true // Assume active on error to avoid premature stop
        }
    }

    private fun parseIsoToMillis(iso: String): Long {
        // Prefer Instant.parse: handles 'Z', fractional seconds, and numeric
        // zone offsets (+02:00) emitted by Dart's toIso8601String(). The old
        // SimpleDateFormat fallback silently mis-parsed offsets and returned
        // 0 on failure (epoch = instant expiry), killing valid shares.
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
                    // Unparseable expiry must NOT kill the share; the DB
                    // signal check + server cleanup remain authoritative.
                    Long.MAX_VALUE
                }
            }
        }
    }
}
