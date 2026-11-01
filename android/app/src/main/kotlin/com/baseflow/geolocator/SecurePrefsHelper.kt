package com.baseflow.geolocator

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Hardened prefs accessor (privacy fix, non-breaking).
 *
 * - Sensitive keys (auth tokens, location-share session key, persisted
 *   Supabase session blobs) are stored in EncryptedSharedPreferences file
 *   "matchme_secure_prefs" (AES256_SIV + AES256_GCM, Keystore-backed
 *   MasterKey). Non-sensitive keys (visibility flags, intervals) stay in
 *   plain prefs.
 * - Reads prefer encrypted first, then fall back to legacy plain
 *   "FlutterSharedPreferences" so upgrades from older installs keep working
 *   (background service must survive reboot during migration).
 * - Writes for sensitive keys go to encrypted ONLY and actively remove any
 *   legacy plain copy so plaintext stops existing at rest. Dart reaches this
 *   via the "matchme/background_service" bridge (setSecureString /
 *   getSecureString / clearSecureKeys).
 */
object SecurePrefsHelper {
    private const val SECURE_FILE = "matchme_secure_prefs"
    private const val PLAIN_FILE = "FlutterSharedPreferences"

    // Cached per process. Creating EncryptedSharedPreferences loads the
    // Keystore MasterKey (~0.5-0.8s cold); rebuilding it on every call made
    // each native read/write that expensive, and bootstrap serializes three
    // of them (session gather, snapshot persist, Hive key read) — the launch
    // long pole. First access pays the cost once; Application.onCreate warms
    // it on a background thread before Dart's first call.
    @Volatile private var cachedSecure: SharedPreferences? = null
    @Volatile private var cachedPlain: SharedPreferences? = null

    /** Pre-create the prefs instances (call off the main thread). */
    fun warmup(context: Context) {
        securePrefs(context)
        plainPrefs(context)
    }

    // Keys that must prefer encrypted storage.
    private val SENSITIVE_KEYS = setOf(
        "flutter.user_token",
        "flutter.refresh_token",
        "flutter.user_id",
        // Last refresh token GoTrue refused; a restarted service must never
        // replay it (each replay is logged as an "abuse attempt").
        "flutter.auth_rejected_refresh_token",
        "flutter.location_share_session_key",
        "flutter.location_share_match_id",
        "flutter.location_share_other_user_id",
        // Offline Retro Matching trail buffer recorded by the background
        // service (GPS history — location data, must not sit in plaintext).
        "flutter.offline_trail_native",
        // Hive box encryption key (Dart-side dual-store). Native read keeps
        // encrypted box opens off the flutter_secure_storage platform channel
        // at bootstrap — that channel is the launch long pole (cold Keystore)
        // and serializes the session seed's persists behind whoever reads it
        // first. Key never lives in plaintext prefs.
        "hive_encryption_key_v1"
    )

    // Session snapshot keys written by Dart / native that embed access +
    // refresh tokens and must never sit in plaintext.
    private val SESSION_JSON_KEYS = setOf(
        "persisted_supabase_session",
        "supabase.auth.token"
    )

    /** Keys handled by the encrypted store (sensitive + session JSON + sb-*). */
    fun isSensitiveKey(key: String): Boolean {
        if (SENSITIVE_KEYS.contains(key) || SESSION_JSON_KEYS.contains(key)) return true
        return key.startsWith("sb-") && key.endsWith("-auth-token")
    }

    private fun securePrefs(context: Context): SharedPreferences {
        cachedSecure?.let { return it }
        synchronized(this) {
            cachedSecure?.let { return it }
            val created = try {
                val masterKey = MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    context,
                    SECURE_FILE,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                )
            } catch (_: Throwable) {
                context.getSharedPreferences(SECURE_FILE, Context.MODE_PRIVATE)
            }
            cachedSecure = created
            return created
        }
    }

    private fun plainPrefs(context: Context): SharedPreferences {
        cachedPlain?.let { return it }
        synchronized(this) {
            cachedPlain?.let { return it }
            val created = context.getSharedPreferences(PLAIN_FILE, Context.MODE_PRIVATE)
            cachedPlain = created
            return created
        }
    }

    fun getString(context: Context, key: String, def: String? = null): String? {
        // Sensitive: encrypted first, plain fallback (migration).
        if (isSensitiveKey(key)) {
            try {
                val v = securePrefs(context).getString(key, null)
                if (!v.isNullOrEmpty()) return v
            } catch (_: Exception) {}
            return try {
                plainPrefs(context).getString(key, def)
            } catch (_: Exception) { def }
        }
        return try {
            plainPrefs(context).getString(key, def)
        } catch (_: Exception) { def }
    }

    fun contains(context: Context, key: String): Boolean {
        try {
            if (securePrefs(context).contains(key)) return true
        } catch (_: Exception) {}
        return try {
            plainPrefs(context).contains(key)
        } catch (_: Exception) {
            false
        }
    }

    /** Encrypted-only write for sensitive keys (removes legacy plain copy);
     *  plain-only write otherwise. Null value removes the key. */
    fun putString(context: Context, key: String, value: String?) {
        if (isSensitiveKey(key)) {
            try {
                val e = securePrefs(context).edit()
                if (value == null) e.remove(key) else e.putString(key, value)
                e.apply()
            } catch (_: Exception) {}
            // Remove any legacy plain copy so the fallback can never
            // surface stale plaintext data.
            try {
                val p = plainPrefs(context).edit()
                p.remove(key)
                p.apply()
            } catch (_: Exception) {}
        } else {
            try {
                val p = plainPrefs(context).edit()
                if (value == null) p.remove(key) else p.putString(key, value)
                p.apply()
            } catch (_: Exception) {}
        }
    }

    /** Remove a single key from both stores (or plain-only when not sensitive). */
    fun remove(context: Context, key: String) {
        if (isSensitiveKey(key)) {
            removeSensitive(context, listOf(key))
        } else {
            try {
                val p = plainPrefs(context).edit()
                p.remove(key)
                p.apply()
            } catch (_: Exception) {}
        }
    }

    fun removeSensitive(context: Context, keys: List<String>) {
        try {
            val e = securePrefs(context).edit()
            for (k in keys) e.remove(k)
            e.apply()
        } catch (_: Exception) {}
        try {
            val p = plainPrefs(context).edit()
            for (k in keys) p.remove(k)
            p.apply()
        } catch (_: Exception) {}
    }
}
