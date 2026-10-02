package com.baseflow.geolocator

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.content.Context.MODE_PRIVATE
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import android.content.pm.ApplicationInfo

class MatchMeBackgroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    private fun isDebug(): Boolean {
        return try {
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        } catch (_: Exception) {
            false
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "matchme/background_service")
        channel.setMethodCallHandler(this)
        context = flutterPluginBinding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                // Initialize is handled in the service itself
                result.success(null)
            }
            "startService" -> {
                val userId = call.argument<String>("userId")
                val supabaseUrl = call.argument<String>("supabaseUrl")
                val supabaseKey = call.argument<String>("supabaseKey")
                val userToken = call.argument<String>("userToken")
                val refreshToken = call.argument<String>("refreshToken")
                val appInForeground = call.argument<Boolean>("appInForeground") ?: false
                val backgroundMatchingMode = call.argument<Boolean>("backgroundMatchingMode") ?: false
                val isVisible = call.argument<Boolean>("isVisible") ?: true
                val isOnline = call.argument<Boolean>("isOnline") ?: true
                val gpsInterval = (call.argument<Int>("gpsInterval") ?: 5).coerceAtLeast(1)
                val smartThrottlingEnabled = call.argument<Boolean>("smartThrottlingEnabled") ?: true

                if (isDebug()) {
                    println("MatchMeBackgroundPlugin: startService called with token: ${userToken?.let { "present" } ?: "null"} interval=$gpsInterval throttling=$smartThrottlingEnabled")
                }

                if (userId != null && supabaseUrl != null && supabaseKey != null) {
                    if (hasLocationPermission()) {
                        MatchMeBackgroundService.startService(context, userId, supabaseUrl, supabaseKey, userToken, refreshToken, appInForeground, backgroundMatchingMode, isVisible, isOnline, gpsInterval, smartThrottlingEnabled)
                        result.success(true)
                    } else {
                        result.error("PERMISSION_DENIED", "Location permission not granted", null)
                    }
                } else {
                    result.error("INVALID_ARGUMENTS", "Missing required arguments", null)
                }
            }
            "stopService" -> {
                MatchMeBackgroundService.stopService(context)
                result.success(true)
            }
            "isRunning" -> {
                result.success(MatchMeBackgroundService.isServiceAlive())
            }
            "getDiagnostics" -> {
                result.success(MatchMeBackgroundService.getDiagnostics())
            }
            "updateVisibility" -> {
                val isVisible = call.argument<Boolean>("isVisible") ?: false
                MatchMeBackgroundService.updateVisibility(context, isVisible)
                result.success(true)
            }
            "setConnectivity" -> {
                val isOnline = call.argument<Boolean>("isOnline") ?: true
                MatchMeBackgroundService.setConnectivity(context, isOnline)
                result.success(true)
            }
            "traceLog" -> {
                val tag = call.argument<String>("tag") ?: "MatchMeTrace"
                val message = call.argument<String>("message") ?: ""
                // Log.d(tag, message)
                result.success(true)
            }
            "updateAppForeground" -> {
                val isForeground = call.argument<Boolean>("isForeground") ?: false
                MatchMeBackgroundService.updateAppForeground(context, isForeground)
                result.success(true)
            }
            "updateBackgroundMatchingMode" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                MatchMeBackgroundService.updateBackgroundMatchingMode(context, enabled)
                result.success(true)
            }
            "updatePinnedState" -> {
                MatchMeBackgroundService.refreshForegroundForPinnedState(context)
                result.success(true)
            }
            "updateToken" -> {
                val token = call.argument<String>("token")
                val refreshToken = call.argument<String>("refreshToken")
                MatchMeBackgroundService.updateToken(context, token, refreshToken)
                result.success(true)
            }
            "setSecureString" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key == null || !SecurePrefsHelper.isSensitiveKey(key)) {
                    result.error("INVALID_ARGUMENTS", "Missing or non-secure key", null)
                } else {
                    SecurePrefsHelper.putString(context, key, value)
                    result.success(true)
                }
            }
            "getSecureString" -> {
                val key = call.argument<String>("key")
                if (key == null || !SecurePrefsHelper.isSensitiveKey(key)) {
                    result.success(null)
                } else {
                    result.success(SecurePrefsHelper.getString(context, key, null))
                }
            }
            "clearSecureKeys" -> {
                val args = call.arguments as? Map<*, *>
                val keys = (args?.get("keys") as? List<*>)?.mapNotNull { it?.toString() } ?: emptyList()
                if (keys.isNotEmpty()) {
                    SecurePrefsHelper.removeSensitive(context, keys)
                }
                result.success(true)
            }
            "updateConfig" -> {
                val gpsInterval = call.argument<Int>("gpsInterval") ?: 30
                val smartThrottlingEnabled = call.argument<Boolean>("smartThrottlingEnabled") ?: true
                MatchMeBackgroundService.updateConfig(context, gpsInterval, smartThrottlingEnabled)
                result.success(true)
            }
            "startLocationShare" -> {
                val matchId = call.argument<String>("matchId")
                val otherUserId = call.argument<String>("otherUserId")
                val sessionKeyBase64 = call.argument<String>("sessionKeyBase64")
                val updateIntervalSeconds = call.argument<Int>("updateIntervalSeconds") ?: 5
                val expiresAtIso = call.argument<String>("expiresAtIso")
                if (matchId != null && otherUserId != null && sessionKeyBase64 != null) {
                    MatchMeBackgroundService.startLocationShare(context, matchId, otherUserId, sessionKeyBase64, updateIntervalSeconds, expiresAtIso)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENTS", "Missing required arguments for location share", null)
                }
            }
            "stopLocationShare" -> {
                MatchMeBackgroundService.stopLocationShare(context)
                result.success(true)
            }
            "updateLocationShareDuration" -> {
                val expiresAtIso = call.argument<String>("expiresAtIso")
                MatchMeBackgroundService.updateLocationShareDuration(context, expiresAtIso)
                result.success(true)
            }
            "checkNotifications" -> {
                val messageId = call.argument<String>("messageId")
                val translatedContent = call.argument<String>("translatedContent")
                val originalContent = call.argument<String>("originalContent")
                val senderName = call.argument<String>("senderName")
                val matchId = call.argument<String>("matchId")

                // Log.d("MatchMeBackgroundPlugin", "[PLUGIN] checkNotifications called with messageId: $messageId, translatedContent: '$translatedContent', originalContent: '$originalContent', senderName: '$senderName', matchId: '$matchId'")

                // If we have translated content, use it directly instead of querying RPC
                if (translatedContent != null && translatedContent != "null" && translatedContent.isNotEmpty()) {
                    // Log.d("MatchMeBackgroundPlugin", "[PLUGIN] Using provided translated content for notification")
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            MatchMeBackgroundService.showTranslatedNotification(
                                context,
                                messageId ?: "",
                                translatedContent,
                                originalContent ?: translatedContent,
                                senderName ?: "Someone",
                                matchId
                            )
                        } catch (e: Exception) {
                            // Log.e("MatchMeBackgroundPlugin", "[PLUGIN] Error showing translated notification", e)
                        }
                    }
                } else {
                    // Fallback to RPC query
                    // Log.d("MatchMeBackgroundPlugin", "[PLUGIN] No translated content provided, falling back to RPC query")
                    CoroutineScope(Dispatchers.IO).launch {
                        try {
                            // Log.d("MatchMeBackgroundPlugin", "[PLUGIN] Calling MatchMeBackgroundService.checkForNotifications")
                            MatchMeBackgroundService.checkForNotifications(context, messageId)
                            // Log.d("MatchMeBackgroundPlugin", "[PLUGIN] checkForNotifications completed")
                        } catch (e: Exception) {
                            // Log.e("MatchMeBackgroundPlugin", "[PLUGIN] Error checking notifications", e)
                        }
                    }
                }
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> {
                result.success(isIgnoringBatteryOptimizations())
            }
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations()
                result.success(true)
            }
            "setPermissionStrings" -> {
                val args = call.arguments as? Map<*, *>
                if (args != null) {
                    val prefs = try {
                        val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                        EncryptedSharedPreferences.create(
                            context,
                            "matchme_prefs",
                            masterKey,
                            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                        )
                    } catch (_: Throwable) {
                        context.getSharedPreferences("matchme_prefs", MODE_PRIVATE)
                    }
                    val edit = prefs.edit()
                    for ((k, v) in args.entries) {
                        val key = k?.toString() ?: continue
                        val value = v?.toString() ?: continue
                        edit.putString(key, value)
                    }
                    edit.apply()
                }
                result.success(true)
            }
            "consumePermissionIssue" -> {
                val prefs = try {
                    val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                    EncryptedSharedPreferences.create(
                        context,
                        "matchme_prefs",
                        masterKey,
                        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                    )
                } catch (_: Throwable) {
                    context.getSharedPreferences("matchme_prefs", MODE_PRIVATE)
                }
                val code = prefs.getString("permission_issue_code", null)
                prefs.edit().remove("permission_issue_code").remove("permission_issue_at").apply()
                result.success(code)
            }
            "setPermissionIssue" -> {
                val code = call.argument<String>("code")
                if (code.isNullOrBlank()) {
                    result.success(false)
                } else {
                    val prefs = try {
                        val masterKey = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                        EncryptedSharedPreferences.create(
                            context,
                            "matchme_prefs",
                            masterKey,
                            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
                        )
                    } catch (_: Throwable) {
                        context.getSharedPreferences("matchme_prefs", MODE_PRIVATE)
                    }
                    prefs.edit().putString("permission_issue_code", code).apply()
                    result.success(true)
                }
            }
            "resetChatNotification" -> {
                val matchId = call.argument<String>("matchId")
                println("MatchMeBackgroundPlugin: resetChatNotification called with matchId: $matchId")
                if (matchId != null) {
                    MatchMeBackgroundService.resetChatNotification(context, matchId)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENTS", "Missing matchId", null)
                }
            }
            "dismissChatNotification" -> {
                val matchId = call.argument<String>("matchId")
                println("MatchMeBackgroundPlugin: dismissChatNotification called with matchId: $matchId")
                if (matchId != null) {
                    MatchMeBackgroundService.dismissChatNotification(context, matchId)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENTS", "Missing matchId", null)
                }
            }
            "setViewingChat" -> {
                val matchId = call.argument<String>("matchId")
                println("MatchMeBackgroundPlugin: setViewingChat called with matchId: $matchId")
                if (matchId != null) {
                    MatchMeBackgroundService.setViewingChat(context, matchId)
                    result.success(true)
                } else {
                    result.error("INVALID_ARGUMENTS", "Missing matchId", null)
                }
            }
            "clearViewingChat" -> {
                println("MatchMeBackgroundPlugin: clearViewingChat called")
                MatchMeBackgroundService.clearViewingChat(context)
                result.success(true)
            }
            "openAppNotificationSettings" -> {
                try {
                    val intent = Intent().apply {
                        flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            action = android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS
                            putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
                        } else {
                            action = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                            data = android.net.Uri.fromParts("package", context.packageName, null)
                        }
                    }
                    context.startActivity(intent)
                    result.success(true)
                } catch (t: Throwable) {
                    result.error("FAILED", t.message, null)
                }
            }
            "getInitialRoute" -> {
                // This is a bit tricky because the plugin doesn't have access to the Activity's intent directly
                // unless we implement ActivityAware.
                // However, since we are launching the app with a new task, the intent should be delivered to the main activity.
                // Flutter handles initial route automatically if the intent has "route" extra.
                // But we are using a custom "route" extra, not the standard Flutter one.
                // Let's return null here and rely on Flutter's deep linking or intent handling if possible.
                // Actually, we can't easily get the intent here without ActivityAware.
                result.success(null)
            }
            "refreshBackgroundNotification" -> {
                MatchMeBackgroundService.refreshNotification(context)
                result.success(true)
            }
            "setBackgroundNotificationStrings" -> {
                val title = call.argument<String>("title")
                val text = call.argument<String>("text")
                try {
                    val prefs = context.getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    prefs.edit().apply {
                        if (!title.isNullOrBlank()) putString("flutter.bgNotificationTitle", title)
                        if (!text.isNullOrBlank()) putString("flutter.bgNotificationText", text)
                        apply()
                    }
                    // Refresh the ongoing notification if the service is running
                    MatchMeBackgroundService.refreshNotification(context)
                } catch (_: Exception) {}
                result.success(true)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            return powerManager.isIgnoringBatteryOptimizations(context.packageName)
        }
        return true
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
        }
    }

    private fun hasLocationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_FINE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.ACCESS_COARSE_LOCATION
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
}
