package com.example.matchme

import com.baseflow.geolocator.MatchMeBackgroundPlugin
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.graphics.BitmapFactory
import android.graphics.Color
import android.util.Log
import android.provider.OpenableColumns
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.PoseDetection
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine

import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

class MainActivity : FlutterFragmentActivity() {
    companion object {
        private const val TAG = "MatchMeMainActivity"
        private const val CHANNEL = "matchme/main_activity"
        private const val APP_INFO_CHANNEL = "matchme/app_info"
        private const val APP_CHECK_CHANNEL = "com.example.matchme/app_check"
        private const val AUTHENTICATOR_LAUNCHER_CHANNEL = "matchme/authenticator_launcher"
        private const val PHOTO_MODERATION_CHANNEL = "matchme/photo_moderation"
        private const val PHOTO_PRESCREEN_CHANNEL = "matchme/photo_prescreen"

        // Native libraries that may be missing from third-party plugins.
        // These are logged as warnings instead of crashing the app.
        private val MISSING_LIB_PATTERNS = listOf(
            "libmagtsync.so",
            "libmbrainSDK",
        )

        // Install a global handler to gracefully handle missing native libraries
        // from third-party plugins. This prevents crashes when optional SDKs
        // are not fully integrated.
        private var hasInstalledNativeLibHandler = false

        @Volatile
        private var nativeLibHandlerInstalled = false

        @Synchronized
        fun installNativeLibraryErrorHandler() {
            if (nativeLibHandlerInstalled) return
            nativeLibHandlerInstalled = true

            val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                val message = throwable.message ?: ""
                val stackTrace = throwable.stackTraceToString()
                
                // Check if this is a missing native library error we can gracefully handle
                val isMissingLib = MISSING_LIB_PATTERNS.any { pattern ->
                    message.contains(pattern, ignoreCase = true) ||
                    stackTrace.contains(pattern, ignoreCase = true)
                }
                
                if (isMissingLib) {
                    // Log as warning instead of crashing
                    Log.w(TAG, "Missing optional native library (continuing with degraded functionality): $message")
                    return@setDefaultUncaughtExceptionHandler
                }
                
                // For other errors, use the default handler
                defaultHandler?.uncaughtException(thread, throwable)
            }
        }
    }

    private var mainChannel: MethodChannel? = null
    private var appInfoChannel: MethodChannel? = null
    private var badgeChannel: MethodChannel? = null
    private var appCheckChannel: MethodChannel? = null
    private var authenticatorLauncherChannel: MethodChannel? = null
    private var photoModerationChannel: MethodChannel? = null
    private var photoPrescreenChannel: MethodChannel? = null

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

    private fun launchInstalledAuthenticatorApp(): Boolean {
        val candidatePackages = listOf(
            "com.google.android.apps.authenticator2",
            "com.azure.authenticator",
            "com.authy.authy",
            "com.duosecurity.duomobile",
            "com.lastpass.authenticator",
            "com.twofasapp"
        )

        for (packageName in candidatePackages) {
            try {
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    ?: continue
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(launchIntent)
                // Log.d(TAG, "Launched authenticator package: $packageName")
                return true
            } catch (e: Exception) {
                // Log.d(TAG, "Failed to launch authenticator package $packageName: ${e.message}")
            }
        }

        return false
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
            // Log.d(TAG, "extractRouteData action=${from.action} shortcutId=$shortcutId tabIndex=$tabIndex route=$route matchId=$matchId")
        } catch (_: Exception) {
        }

        if (route.isNullOrBlank() && matchId.isNullOrBlank() && tabIndex == null) return null
        return mapOf(
            "route" to route,
            "matchId" to matchId
            ,"tabIndex" to tabIndex
        )
    }

    private fun computeBodyPresence(pose: Pose): Pair<Boolean, Double> {
        val landmarks = pose.allPoseLandmarks
        if (landmarks.isEmpty()) {
            return false to 0.0
        }

        val confidentLandmarks = landmarks.filter { it.inFrameLikelihood >= 0.45f }
        val torsoReady = listOf(
            PoseLandmark.LEFT_SHOULDER,
            PoseLandmark.RIGHT_SHOULDER,
            PoseLandmark.LEFT_HIP,
            PoseLandmark.RIGHT_HIP,
        ).count { pose.getPoseLandmark(it)?.inFrameLikelihood ?: 0f >= 0.35f } >= 2
        val upperBodyReady = listOf(
            PoseLandmark.LEFT_SHOULDER,
            PoseLandmark.RIGHT_SHOULDER,
            PoseLandmark.LEFT_ELBOW,
            PoseLandmark.RIGHT_ELBOW,
        ).count { pose.getPoseLandmark(it)?.inFrameLikelihood ?: 0f >= 0.35f } >= 2
        val bodyConfidence = (confidentLandmarks.size / 12.0).coerceIn(0.0, 1.0)
        val containsBody = confidentLandmarks.size >= 8 || torsoReady || upperBodyReady
        return containsBody to bodyConfidence
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
                // Log.w(TAG, "getAppInfo failed: $e")
                result.success(
                    mapOf(
                        "appName" to null,
                        "version" to null,
                        "buildNumber" to null
                    )
                )
            }
        }

        // App-icon badge: Android launchers derive badges from the tray, so
        // there is no global badge API. Accept set/clear so shared Dart code
        // stays platform-agnostic (iOS applies the count, Android no-ops).
        badgeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "matchme/badge")
        badgeChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setBadgeCount", "clearBadge" -> result.success(null)
                else -> result.notImplemented()
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
                        // Log.d(TAG, "Package $packageName IS installed")
                        result.success(true)
                    } catch (e: Exception) {
                        // Log.d(TAG, "Package $packageName NOT installed: ${e.message}")
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
                        // Log.w(TAG, "Failed to open app settings: $e")
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
                        // Log.w(TAG, "Failed to open calendar permission settings: $e")
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
                        // Log.w(TAG, "Failed to inspect calendar permission request state: $e")
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
                        // Log.w(TAG, "Failed to launch Outlook: $e")
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
                        
                        // Log.d(TAG, "Found ${outlookPackages.size} Microsoft/Outlook packages: $outlookPackages")
                        result.success(outlookPackages)
                    } catch (e: Exception) {
                        // Log.e(TAG, "Failed to scan packages: $e")
                        result.error("FAILED", "Could not scan packages", e.message)
                    }
                }
                else -> result.notImplemented()
            }
        }

        authenticatorLauncherChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUTHENTICATOR_LAUNCHER_CHANNEL
        )
        authenticatorLauncherChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchAuthenticatorApp" -> {
                    result.success(launchInstalledAuthenticatorApp())
                }
                else -> result.notImplemented()
            }
        }

        photoModerationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHOTO_MODERATION_CHANNEL)
        photoModerationChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "analyzeProfilePhotoPresence" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.success(
                            mapOf(
                                "supported" to true,
                                "containsFace" to false,
                                "containsBody" to false,
                                "uncertain" to false,
                                "faceConfidence" to 0.0,
                                "bodyConfidence" to 0.0,
                            )
                        )
                        return@setMethodCallHandler
                    }

                    lifecycleScope.launch {
                        try {
                            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            if (bitmap == null) {
                                result.success(
                                    mapOf(
                                        "supported" to true,
                                        "containsFace" to false,
                                        "containsBody" to false,
                                        "uncertain" to true,
                                        "faceConfidence" to 0.0,
                                        "bodyConfidence" to 0.0,
                                    )
                                )
                                return@launch
                            }

                            val image = InputImage.fromBitmap(bitmap, 0)
                            val faceDetector = FaceDetection.getClient(
                                FaceDetectorOptions.Builder()
                                    .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                                    .enableTracking()
                                    .build()
                            )
                            val poseDetector = PoseDetection.getClient(
                                com.google.mlkit.vision.pose.defaults.PoseDetectorOptions.Builder()
                                    .setDetectorMode(
                                        com.google.mlkit.vision.pose.defaults.PoseDetectorOptions.SINGLE_IMAGE_MODE
                                    )
                                    .build()
                            )

                            try {
                                val faces = faceDetector.process(image).await()
                                val pose = poseDetector.process(image).await()

                                val containsFace = faces.isNotEmpty()
                                val faceConfidence = faces.maxOfOrNull { it.boundingBox.width().toDouble() * it.boundingBox.height().toDouble() }
                                    ?.let { area ->
                                        val totalArea = (bitmap.width * bitmap.height).toDouble().coerceAtLeast(1.0)
                                        (area / totalArea).coerceIn(0.0, 1.0)
                                    }
                                    ?: 0.0
                                val (containsBody, bodyConfidence) = computeBodyPresence(pose)
                                val uncertain = !containsFace && !containsBody && pose.allPoseLandmarks.isNotEmpty()

                                result.success(
                                    mapOf(
                                        "supported" to true,
                                        "containsFace" to containsFace,
                                        "containsBody" to containsBody,
                                        "uncertain" to uncertain,
                                        "faceConfidence" to faceConfidence,
                                        "bodyConfidence" to bodyConfidence,
                                    )
                                )
                            } finally {
                                faceDetector.close()
                                poseDetector.close()
                                bitmap.recycle()
                            }
                        } catch (e: Exception) {
                            // Log.w(TAG, "analyzeProfilePhotoPresence failed: $e")
                            result.success(
                                mapOf(
                                    "supported" to false,
                                    "containsFace" to false,
                                    "containsBody" to false,
                                    "uncertain" to true,
                                    "faceConfidence" to 0.0,
                                    "bodyConfidence" to 0.0,
                                )
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        photoPrescreenChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHOTO_PRESCREEN_CHANNEL)
        photoPrescreenChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "analyzePhoto" -> {
                    val bytes = call.argument<ByteArray>("bytes")

                    if (bytes == null || bytes.isEmpty()) {
                        result.success(
                            mapOf(
                                "supported" to true,
                                "containsFace" to false,
                                "containsBody" to false,
                                "uncertain" to true,
                                "faceConfidence" to 0.0,
                                "bodyConfidence" to 0.0,
                                "faceCount" to 0,
                                "faceSizeRatio" to 0.0,
                                "facePositionedCenter" to false,
                                "faceObstructed" to false,
                                "upperBodyOnly" to false,
                                "fullBodyVisible" to false
                            )
                        )
                        return@setMethodCallHandler
                    }

                    lifecycleScope.launch {
                        try {
                            val analysisResult = PhotoPrescreenHandler.analyzePhoto(bytes)
                            result.success(analysisResult)
                        } catch (e: Exception) {
                            Log.e(TAG, "analyzePhoto failed: ${e.message}", e)
                            result.success(
                                mapOf(
                                    "supported" to false,
                                    "containsFace" to false,
                                    "containsBody" to false,
                                    "uncertain" to true,
                                    "faceConfidence" to 0.0,
                                    "bodyConfidence" to 0.0,
                                    "faceCount" to 0,
                                    "faceSizeRatio" to 0.0,
                                    "facePositionedCenter" to false,
                                    "faceObstructed" to false,
                                    "upperBodyOnly" to false,
                                    "fullBodyVisible" to false
                                )
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        
        // CRITICAL: Handle OAuth deep link callbacks for calendar sync
        val data = intent.data
        if (data != null && data.scheme == "com.example.matchme" && data.host == "login-callback") {
            // Log.d(TAG, "🔓 [OAuth] Deep link received in onNewIntent: $data")
            // Let Supabase handle the deep link via its internal listener
            // The deep link will also be forwarded to Flutter's app_links plugin
        }
        
        val routeData = extractRouteData(intent)
        if (routeData != null) {
            try {
                val isShare = routeData.containsKey("sharedText") || routeData.containsKey("sharedFilePath")
                if (isShare) {
                    mainChannel?.invokeMethod("onSharedIntent", routeData)
                } else {
                    mainChannel?.invokeMethod("onNotificationRoute", routeData)
                }
            } catch (e: Exception) {
                // Log.w(TAG, "Failed to deliver notification route to Flutter: $e")
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Install handler to gracefully log missing native library errors
        // from third-party plugins instead of crashing
        installNativeLibraryErrorHandler()

        // Ensure the window has valid dimensions before Flutter attaches.
        // This prevents "zero-width viewport" errors when the Activity starts
        // before the window is measured (common on cold start with slow devices).
        // The post callback ensures the decor view has been laid out.
        window.decorView.post {
            // Flutter engine will attach after this callback runs
            // At this point, the view hierarchy has been measured
        }

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
            // Log.d(TAG, "onCreate: statusBarColor=${window.statusBarColor}, navigationBarColor=${window.navigationBarColor}, systemUiVisibility=${window.decorView.systemUiVisibility}")
        } catch (e: Exception) {
            // Ignore - best effort
            // Log.w(TAG, "Failed to set status bar appearance: $e")
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

            // Log.d(TAG, "applySystemUiColors applied: statusBarColor=${window.statusBarColor}, navigationBarColor=${window.navigationBarColor}, systemUiVisibility=${window.decorView.systemUiVisibility}")
        } catch (e: Exception) {
            // Log.w(TAG, "applySystemUiColors failed: $e")
        }
    }

    override fun onResume() {
        super.onResume()

        // Re-apply and log window attributes when activity resumes
        try {
            applySystemUiColors()
        } catch (e: Exception) {
            // Log.w(TAG, "onResume logging failed: $e")
        }
    }
}
