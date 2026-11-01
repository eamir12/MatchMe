package com.baseflow.geolocator

import android.content.Context
import android.os.Build
import okhttp3.Interceptor

/**
 * Tags every native OkHttp request to Supabase with a User-Agent that
 * identifies the user, so the project's Supabase edge logs (which end each
 * line with the request UA) can be attributed even when the request runs
 * with an expired or anonymous token — the traffic that is hardest to trace.
 * Mirrors SupabaseLogIdentity on the Dart side.
 */
object SupabaseIdentity {
    @Volatile
    private var cachedVersion: String? = null

    @Suppress("DEPRECATION")
    private fun appVersion(context: Context): String {
        cachedVersion?.let { return it }
        val version = try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val name = info.versionName ?: "unknown"
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                info.versionCode.toLong()
            }
            "$name+$code"
        } catch (_: Exception) {
            "unknown"
        }
        return version.also { cachedVersion = it }
    }

    fun interceptor(context: Context, userIdProvider: () -> String?): Interceptor {
        // Resolved per request, not here: callers like MatchMeBackgroundService
        // build their OkHttp client in a field initializer, where the Service's
        // base context is not attached yet and getApplicationContext() throws.
        return Interceptor { chain ->
            val appContext = try {
                context.applicationContext ?: context
            } catch (_: Exception) {
                context
            }
            val uid = try {
                userIdProvider()?.takeIf { it.isNotBlank() }
            } catch (_: Exception) {
                null
            }
            val request = chain.request().newBuilder()
                .header(
                    "User-Agent",
                    "MatchMe/${appVersion(appContext)} (android-native; uid=${uid ?: "none"})"
                )
                .build()
            chain.proceed(request)
        }
    }
}
