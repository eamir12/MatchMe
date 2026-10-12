package com.example.matchme

import android.app.Application
import com.baseflow.geolocator.SecurePrefsHelper

class MatchMeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Warm the encrypted prefs store off the main thread: creating it
        // loads the Keystore MasterKey (~0.5-0.8s cold) and bootstrap's first
        // native reads (session seed, Hive key) serialize behind it. Starting
        // here overlaps that cost with Flutter engine startup.
        Thread {
            try {
                SecurePrefsHelper.warmup(applicationContext)
            } catch (_: Throwable) {
            }
        }.start()
    }
}
