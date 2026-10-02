package com.baseflow.geolocator

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/**
 * Headless uploader for the native offline-trail buffer: GPS fixes the
 * background service recorded while the device was offline and the app UI
 * was closed. Sends the encrypted buffer to the `upload_offline_trail` RPC
 * in 200-point chunks (same RPC and chunk size as the Dart side), and clears
 * the buffer only when every point was acknowledged — on a failed chunk the
 * remainder stays buffered for the next attempt. The Dart-side merge/upload
 * remains a fallback (e.g. when the stored token has expired).
 */
object OfflineTrailUploader {

    fun isRetroOfflineTrailEnabled(context: Context): Boolean {
        return try {
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getBoolean("flutter.retro_enabled", false)
        } catch (_: Exception) {
            false
        }
    }

    fun upload(
        context: Context,
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        client: OkHttpClient,
    ) {
        val raw = SecurePrefsHelper.getString(
            context,
            MatchMeBackgroundService.TRAIL_NATIVE_KEY,
            null,
        )
        if (raw.isNullOrBlank()) return
        val kept = try {
            org.json.JSONArray(raw)
        } catch (_: Exception) {
            SecurePrefsHelper.putString(context, MatchMeBackgroundService.TRAIL_NATIVE_KEY, null)
            return
        }
        if (kept.length() == 0) {
            SecurePrefsHelper.putString(context, MatchMeBackgroundService.TRAIL_NATIVE_KEY, null)
            return
        }

        // Drop points older than the user's retention window (2–72h).
        val retentionHours = try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            (if (prefs.contains("flutter.retro_retention_hours")) {
                prefs.getInt("flutter.retro_retention_hours", 24)
            } else 24).coerceIn(2, 72)
        } catch (_: Exception) {
            24
        }
        val cutoff = System.currentTimeMillis() - retentionHours * 3600_000L
        val fresh = org.json.JSONArray()
        for (i in 0 until kept.length()) {
            val o = kept.optJSONObject(i) ?: continue
            val ts = parseTrailTimestamp(o.optString("recorded_at"))
            if (ts == 0L || ts >= cutoff) fresh.put(o)
        }
        if (fresh.length() == 0) {
            SecurePrefsHelper.putString(context, MatchMeBackgroundService.TRAIL_NATIVE_KEY, null)
            return
        }

        var chunk = org.json.JSONArray()
        var acked = 0
        val total = fresh.length()
        var i = 0
        while (i < total) {
            chunk.put(fresh.get(i))
            i++
            if (chunk.length() >= 200 || i == total) {
                val ok = postTrailChunk(userId, supabaseUrl, supabaseKey, userToken, chunk, client)
                if (!ok) break
                acked += chunk.length()
                chunk = org.json.JSONArray()
            }
        }
        when {
            acked >= total ->
                SecurePrefsHelper.putString(
                    context,
                    MatchMeBackgroundService.TRAIL_NATIVE_KEY,
                    null,
                )
            acked > 0 -> {
                // Keep only what the server has not acknowledged.
                val remainder = org.json.JSONArray()
                for (j in acked until total) remainder.put(fresh.get(j))
                SecurePrefsHelper.putString(
                    context,
                    MatchMeBackgroundService.TRAIL_NATIVE_KEY,
                    remainder.toString(),
                )
            }
        }
    }

    private fun postTrailChunk(
        userId: String,
        supabaseUrl: String,
        supabaseKey: String,
        userToken: String?,
        points: org.json.JSONArray,
        client: OkHttpClient,
    ): Boolean {
        return try {
            val url = "$supabaseUrl/rest/v1/rpc/upload_offline_trail"
            val body = org.json.JSONObject().put("p_points", points)
            val req = Request.Builder()
                .url(url)
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .addHeader("apikey", supabaseKey)
                .addHeader("Content-Type", "application/json")
            if (userToken != null) req.addHeader("Authorization", "Bearer $userToken")
            else req.addHeader("Authorization", "Bearer $supabaseKey")
            val resp = client.newCall(req.build()).execute()
            val ok = resp.isSuccessful
            try {
                resp.close()
            } catch (_: Exception) {
            }
            ok
        } catch (_: Exception) {
            false
        }
    }

    private fun parseTrailTimestamp(iso: String): Long {
        return try {
            val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            fmt.timeZone = TimeZone.getTimeZone("UTC")
            fmt.parse(iso)?.time ?: 0L
        } catch (_: Exception) {
            0L
        }
    }
}
