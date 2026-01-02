package com.example.matchme

import com.baseflow.geolocator.MatchMeBackgroundPlugin
import android.os.Bundle
import android.graphics.Color
import android.util.Log
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "MatchMeMainActivity"
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

    private fun applySystemUiColors(attempt: Int = 0) {
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

            Log.d(TAG, "applySystemUiColors attempt=$attempt applied: statusBarColor=${window.statusBarColor}, navigationBarColor=${window.navigationBarColor}, systemUiVisibility=${window.decorView.systemUiVisibility}")
        } catch (e: Exception) {
            Log.w(TAG, "applySystemUiColors failed on attempt=$attempt: $e")
        }

        // Retry a few times to handle OEM or system overrides
        if (attempt < 3) {
            val delayMs = when (attempt) {
                0 -> 250L
                1 -> 1000L
                else -> 3000L
            }
            window.decorView.postDelayed({ applySystemUiColors(attempt + 1) }, delayMs)
        }
    }

    override fun onResume() {
        super.onResume()
        // Re-apply and log window attributes when activity resumes
        try {
            applySystemUiColors(0)
        } catch (e: Exception) {
            Log.w(TAG, "onResume logging failed: $e")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(MatchMeBackgroundPlugin())
    }
}
