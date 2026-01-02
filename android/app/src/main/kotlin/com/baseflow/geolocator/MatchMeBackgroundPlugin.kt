package com.baseflow.geolocator

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MatchMeBackgroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

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

                println("MatchMeBackgroundPlugin: startService called with token: ${userToken?.let { "present (${it.length} chars)" } ?: "null"}")

                if (userId != null && supabaseUrl != null && supabaseKey != null) {
                    if (hasLocationPermission()) {
                        MatchMeBackgroundService.startService(context, userId, supabaseUrl, supabaseKey, userToken)
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
                // For simplicity, we'll assume it's running if we can check it
                // In a real implementation, you'd track service state
                result.success(true)
            }
            "updateVisibility" -> {
                val isVisible = call.argument<Boolean>("isVisible") ?: false
                MatchMeBackgroundService.updateVisibility(context, isVisible)
                result.success(true)
            }
            "updateToken" -> {
                val token = call.argument<String>("token")
                MatchMeBackgroundService.updateToken(context, token)
                result.success(true)
            }
            else -> {
                result.notImplemented()
            }
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
