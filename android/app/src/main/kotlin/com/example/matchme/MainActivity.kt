package com.example.matchme

import com.baseflow.geolocator.MatchMeBackgroundPlugin
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.graphics.Color
import android.util.Log
import android.provider.OpenableColumns
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine

import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val TAG = "MatchMeMainActivity"
        private const val CHANNEL = "matchme/main_activity"
        private const val APP_INFO_CHANNEL = "matchme/app_info"
        private const val APP_CHECK_CHANNEL = "com.example.matchme/app_check"
    }

    private var mainChannel: MethodChannel? = null
    private var appInfoChannel: MethodChannel? = null
    private var appCheckChannel: MethodChannel? = null

    override fun getRenderMode(): RenderMode = RenderMode.texture

    private fun copySharedUriToCache(uri: Uri): String? {
        return try {
            val resolver = applicationContext.contentResolver
            val mime = try { resolver.getType(uri) } catch (_: Exception) { null }
            var ext = when {
                mime == null -> null
                mime.equals("application/pdf", ignoreCase = true) -> "pdf"
                mime.equals("text/calendar", ignoreCase = true) -> "ics"
                mime.startsWith("image/", ignoreCase = true) -> mime.substringAfter("image/").substringBefore(";").lowercase()
                else -> null
            }

            if (ext.isNullOrBlank()) {
                try {
                    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0 && cursor.moveToFirst()) {
                            val displayName = cursor.getString(nameIndex) ?: ""
                            val dot = displayName.lastIndexOf('.')
                            if (dot >= 0 && dot < displayName.length - 1) {
                                ext = displayName.substring(dot + 1).lowercase()
                            }
                        }
                    }
                } catch (_: Exception) {
                }
            }

            val suffix = if (!ext.isNullOrBlank()) ".$ext" else ""
            val outFile = File(cacheDir, "shared_${System.currentTimeMillis()}_${UUID.randomUUID()}$suffix")
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            outFile.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun extractRouteData(from: Intent?): Map<String, Any?>? {
        if (from == null) return null

        try {
            val action = from.action
            if (Intent.ACTION_SEND == action || Intent.ACTION_SEND_MULTIPLE == action) {
                val type = from.type
                val sharedText = try {
                    from.getStringExtra(Intent.EXTRA_TEXT)?.trim()
                        ?: from.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim()
                } catch (_: Exception) {
                    null
                }

                if (!sharedText.isNullOrBlank() && (type?.startsWith("text/") == true || type.isNullOrBlank())) {
                    return mapOf("sharedText" to sharedText)
                }

                val uri: Uri? = try {
                    when (action) {
                        Intent.ACTION_SEND -> from.getParcelableExtra(Intent.EXTRA_STREAM)
                        Intent.ACTION_SEND_MULTIPLE -> {
                            val list = from.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                            list?.firstOrNull()
                        }
                        else -> null
                    }
                } catch (_: Exception) {
                    null
                }

                if (uri != null) {
                    val cachedPath = copySharedUriToCache(uri)
                    if (!cachedPath.isNullOrBlank()) {
                        return mapOf("sharedFilePath" to cachedPath)
                    }
                }
            }

            if (Intent.ACTION_VIEW == action) {
                val data = from.data
                if (data != null) {
                    val scheme = data.scheme?.lowercase()
                    if (scheme == "http" || scheme == "https") {
                        return mapOf("sharedText" to data.toString())
                    }
                    if (scheme == "content" || scheme == "file") {
                        val cachedPath = copySharedUriToCache(data)
                        if (!cachedPath.isNullOrBlank()) {
                            return mapOf("sharedFilePath" to cachedPath)
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }

        val shortcutId = try {
            // Static/dynamic shortcuts include this extra.
            from.getStringExtra("android.content.pm.extra.SHORTCUT_ID")
                ?: from.getStringExtra("android.intent.extra.shortcut.ID")
        } catch (_: Exception) {
            null
        }

        if (!from.hasExtra("route") && !from.hasExtra("matchId") && !from.hasExtra("tabIndex") && shortcutId.isNullOrBlank()) return null
        val route = from.getStringExtra("route")
        val matchId = from.getStringExtra("matchId")
        var tabIndex: Int? = try {
            if (!from.hasExtra("tabIndex")) {
                null
            } else {
                val rawAny = from.extras?.get("tabIndex")
                when (rawAny) {
                    is Int -> rawAny
                    is String -> rawAny.toIntOrNull()
                    else -> {
                        // Fallback: some launchers may store as a numeric extra.
                        val v = from.getIntExtra("tabIndex", Int.MIN_VALUE)
                        if (v == Int.MIN_VALUE) null else v
                    }
                }
            }
        } catch (_: Exception) {
            null
        }

        // If tabIndex wasn't supplied, infer it from the shortcut id.
        if (tabIndex == null && !shortcutId.isNullOrBlank()) {
            tabIndex = when (shortcutId) {
                "matchme_home" -> 0
                "matchme_matches" -> 1
                "matchme_chats" -> 2
                "matchme_profile" -> 3
                else -> null
            }
        }

        try {
            Log.d(TAG, "extractRouteData action=${from.action} shortcutId=$shortcutId tabIndex=$tabIndex route=$route matchId=$matchId")
        } catch (_: Exception) {
        }

        if (route.isNullOrBlank() && matchId.isNullOrBlank() && tabIndex == null) return null
        return mapOf(
            "route" to route,
            "matchId" to matchId
            ,"tabIndex" to tabIndex
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Register the background service plugin manually if not already registered
        if (!flutterEngine.plugins.has(MatchMeBackgroundPlugin::class.java)) {
            flutterEngine.plugins.add(MatchMeBackgroundPlugin())
        }
        
        mainChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        mainChannel?.setMethodCallHandler { call, result ->
            if (call.method == "getInitialRoute") {
                val data = extractRouteData(intent)
                result.success(data)

                // Consume extras so subsequent calls don't re-navigate.
                try {
                    intent?.removeExtra("route")
                    intent?.removeExtra("matchId")
                    intent?.removeExtra("tabIndex")
                    intent?.removeExtra(Intent.EXTRA_TEXT)
                    intent?.removeExtra(Intent.EXTRA_STREAM)
                } catch (_: Exception) {
                }
            } else {
                // Forward other calls to the plugin if needed, or let the plugin handle them
                // Since we registered the plugin in the engine, it should handle its own calls.
                // But we are using the SAME channel name. This is a conflict.
                // The plugin registers itself in onAttachedToEngine.
                // We should use a different channel or let the plugin handle it.
                // But the plugin doesn't have access to the Intent easily.
                // Let's use a different channel for this specific call.
                result.notImplemented()
            }
        }

        appInfoChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_INFO_CHANNEL)
        appInfoChannel?.setMethodCallHandler { call, result ->
            if (call.method != "getAppInfo") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            try {
                val packageName = applicationContext.packageName
                val pm = applicationContext.packageManager

                @Suppress("DEPRECATION")
                val pkgInfo = pm.getPackageInfo(packageName, 0)

                val appName = try {
                    val appInfo = pkgInfo.applicationInfo ?: applicationInfo
                    val label = pm.getApplicationLabel(appInfo)
                    label?.toString()
                } catch (_: Exception) {
                    null
                }

                val versionName = pkgInfo.versionName
                val buildNumber = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                    pkgInfo.longVersionCode.toString()
                } else {
                    @Suppress("DEPRECATION")
                    pkgInfo.versionCode.toString()
                }

                result.success(
                    mapOf(
                        "appName" to appName,
                        "version" to versionName,
                        "buildNumber" to buildNumber
                    )
                )
            } catch (e: Exception) {
                Log.w(TAG, "getAppInfo failed: $e")
                result.success(
                    mapOf(
                        "appName" to null,
                        "version" to null,
                        "buildNumber" to null
                    )
                )
            }
        }

        // MethodChannel for checking if apps are installed
        appCheckChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, APP_CHECK_CHANNEL)
        appCheckChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isAppInstalled" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("INVALID_ARGUMENT", "Package name is required", null)
                        return@setMethodCallHandler
                    }
                    
                    try {
                        @Suppress("DEPRECATION")
                        packageManager.getPackageInfo(packageName, 0)
                        Log.d(TAG, "Package $packageName IS installed")
                        result.success(true)
                    } catch (e: Exception) {
                        Log.d(TAG, "Package $packageName NOT installed: ${e.message}")
                        result.success(false)
                    }
                }
                "openAppSettings" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName == null) {
                        result.error("INVALID_ARGUMENT", "Package name is required", null)
                        return@setMethodCallHandler
                    }
                    
                    try {
                        val intent = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        intent.data = android.net.Uri.parse("package:$packageName")
                        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to open app settings: $e")
                        result.error("FAILED", "Could not open app settings", e.message)
                    }
                }
                "openCalendarPermissionSettings" -> {
                    val packageName = call.argument<String>("packageName") ?: applicationContext.packageName
                    try {
                        val intents = listOf(
                            Intent("android.intent.action.MANAGE_APP_PERMISSION").apply {
                                putExtra("android.intent.extra.PACKAGE_NAME", packageName)
                                putExtra("android.intent.extra.PERMISSION_NAME", android.Manifest.permission.READ_CALENDAR)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            },
                            Intent("android.intent.action.MANAGE_APP_PERMISSIONS").apply {
                                putExtra("android.intent.extra.PACKAGE_NAME", packageName)
                                putExtra("extra_pkgname", packageName)
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            },
                            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = android.net.Uri.parse("package:$packageName")
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            }
                        )
                        var opened = false
                        for (intent in intents) {
                            if (intent.resolveActivity(packageManager) != null) {
                                startActivity(intent)
                                opened = true
                                break
                            }
                        }
                        result.success(opened)
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to open calendar permission settings: $e")
                        result.error("FAILED", "Could not open calendar permission settings", e.message)
                    }
                }
                "getCalendarPermissionRequestState" -> {
                    try {
                        val readGranted = ContextCompat.checkSelfPermission(
                            this,
                            android.Manifest.permission.READ_CALENDAR
                        ) == PackageManager.PERMISSION_GRANTED
                        val writeGranted = ContextCompat.checkSelfPermission(
                            this,
                            android.Manifest.permission.WRITE_CALENDAR
                        ) == PackageManager.PERMISSION_GRANTED
                        val shouldShowReadRationale = ActivityCompat.shouldShowRequestPermissionRationale(
                            this,
                            android.Manifest.permission.READ_CALENDAR
                        )
                        val shouldShowWriteRationale = ActivityCompat.shouldShowRequestPermissionRationale(
                            this,
                            android.Manifest.permission.WRITE_CALENDAR
                        )
                        result.success(
                            mapOf(
                                "readGranted" to readGranted,
                                "writeGranted" to writeGranted,
                                "shouldShowReadRationale" to shouldShowReadRationale,
                                "shouldShowWriteRationale" to shouldShowWriteRationale
                            )
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to inspect calendar permission request state: $e")
                        result.error("FAILED", "Could not inspect calendar permission request state", e.message)
                    }
                }
                "launchOutlookApp" -> {
                    val packageName = "com.microsoft.office.outlook"
                    try {
                        // Try to launch Outlook app directly
                        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                        if (launchIntent != null) {
                            launchIntent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            startActivity(launchIntent)
                            result.success(true)
                        } else {
                            result.error("NOT_FOUND", "Outlook app not found", null)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to launch Outlook: $e")
                        result.error("FAILED", "Could not launch Outlook app", e.message)
                    }
                }
                "findOutlookPackages" -> {
                    try {
                        val installedPackages = packageManager.getInstalledPackages(0)
                        val outlookPackages = installedPackages.filter { pkg ->
                            val pkgName = pkg.packageName.lowercase()
                            pkgName.contains("microsoft") || 
                            pkgName.contains("outlook") || 
                            pkgName.contains("office")
                        }.map { it.packageName }
                        
                        Log.d(TAG, "Found ${outlookPackages.size} Microsoft/Outlook packages: $outlookPackages")
                        result.success(outlookPackages)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to scan packages: $e")
                        result.error("FAILED", "Could not scan packages", e.message)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val data = extractRouteData(intent)
        if (data != null) {
            try {
                val isShare = data.containsKey("sharedText") || data.containsKey("sharedFilePath")
                if (isShare) {
                    mainChannel?.invokeMethod("onSharedIntent", data)
                } else {
                    mainChannel?.invokeMethod("onNotificationRoute", data)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to deliver notification route to Flutter: $e")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Ensure status bar is visible and uses dark icons on a white background
        try {
            // Force status bar color to white and navigation bar color to white
            window.statusBarColor = Color.WHITE
            window.navigationBarColor = Color.WHITE

            // Ensure system windows are drawn behind the app content properly
            WindowCompat.setDecorFitsSystemWindows(window, true)

            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                // Set the APPEARANCE_LIGHT_STATUS_BARS bit to request dark status bar icons
                window.insetsController?.setSystemBarsAppearance(
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                )
                // Also request light navigation bar icons if supported
                try {
                    window.insetsController?.setSystemBarsAppearance(
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                    )
                } catch (_: Exception) {
                    // ignore if not supported
                }
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            }

            // Log initial window state
            Log.d(TAG, "onCreate: statusBarColor=${window.statusBarColor}, navigationBarColor=${window.navigationBarColor}, systemUiVisibility=${window.decorView.systemUiVisibility}")
        } catch (e: Exception) {
            // Ignore - best effort
            Log.w(TAG, "Failed to set status bar appearance: $e")
        }
    }

    private fun applySystemUiColors() {
        try {
            window.statusBarColor = Color.WHITE
            window.navigationBarColor = Color.WHITE
            WindowCompat.setDecorFitsSystemWindows(window, true)

            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                window.insetsController?.setSystemBarsAppearance(
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                )
                try {
                    window.insetsController?.setSystemBarsAppearance(
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                        android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                    )
                } catch (_: Exception) {
                }
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
            }

            Log.d(TAG, "applySystemUiColors applied: statusBarColor=${window.statusBarColor}, navigationBarColor=${window.navigationBarColor}, systemUiVisibility=${window.decorView.systemUiVisibility}")
        } catch (e: Exception) {
            Log.w(TAG, "applySystemUiColors failed: $e")
        }
    }

    override fun onResume() {
        super.onResume()

        // Re-apply and log window attributes when activity resumes
        try {
            applySystemUiColors()
        } catch (e: Exception) {
            Log.w(TAG, "onResume logging failed: $e")
        }
    }
}
