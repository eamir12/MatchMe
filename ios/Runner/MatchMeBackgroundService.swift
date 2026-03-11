//
//  MatchMeBackgroundService.swift
//  Runner
//
//  Created by MatchMe on background service implementation
//

import Foundation
import Flutter
import UIKit
import CoreLocation
import UserNotifications
import BackgroundTasks

public class MatchMeBackgroundService: NSObject, FlutterPlugin, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    private let channel: FlutterMethodChannel
    private let locationManager = CLLocationManager()
    private var userId: String?
    private var supabaseUrl: String?
    private var supabaseKey: String?
    private var userToken: String?
    private var isVisible = false
    private var isOnline = false
    private var highAccuracyMode = false
    private var heartbeatTimer: Timer?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var pendingBackgroundTask: BGAppRefreshTask?
    private var lastHeartbeatTime: Date?

    private let defaults = UserDefaults.standard
    private let kUserId = "mm_user_id"
    private let kSupabaseUrl = "mm_supabase_url"
    private let kSupabaseKey = "mm_supabase_key"
    private let kUserToken = "mm_user_token"
    private let kIsVisible = "mm_is_visible"
    private let kIsOnline = "mm_is_online"
    private let kHighAccuracyMode = "mm_high_accuracy_mode"

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10.0 // 10 meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false

        // Load saved state
        loadState()

        // Register background tasks
        registerBackgroundTasks()

        // Request notification permissions for silent notifications
        requestNotificationPermissions()
        
        // Resume service if we have state
        if userId != nil {
            startBackgroundService()
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "matchme/background_service", binaryMessenger: registrar.messenger())
        let instance = MatchMeBackgroundService(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            result(nil)
        case "startService":
            guard let args = call.arguments as? [String: Any],
                  let userId = args["userId"] as? String,
                  let supabaseUrl = args["supabaseUrl"] as? String,
                  let supabaseKey = args["supabaseKey"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments", details: nil))
                return
            }

            self.userId = userId
            self.supabaseUrl = supabaseUrl
            self.supabaseKey = supabaseKey
            self.userToken = args["userToken"] as? String
            
            if let isOnline = args["isOnline"] as? Bool {
                self.isOnline = isOnline
            }

            if let isVisible = args["isVisible"] as? Bool {
                self.isVisible = isVisible
            }

            if let highAccuracyMode = args["highAccuracyMode"] as? Bool {
                self.highAccuracyMode = highAccuracyMode
            }

            saveState()
            startBackgroundService()
            result(true)

        case "stopService":
            stopBackgroundService()
            result(true)

        case "isRunning":
            result(isServiceRunning())

        case "updateVisibility":
            guard let args = call.arguments as? [String: Any],
                  let isVisible = args["isVisible"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing visibility argument", details: nil))
                return
            }

            self.isVisible = isVisible
            saveState()
            updateLocationTracking()
            // Update heartbeat status based on new visibility/online state
            if isOnline {
                startHeartbeat()
            } else {
                stopHeartbeat()
            }
            result(true)

        case "setConnectivity":
            guard let args = call.arguments as? [String: Any],
                  let isOnline = args["isOnline"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing isOnline argument", details: nil))
                return
            }

            self.isOnline = isOnline
            saveState()
            updateLocationTracking()
            
            if isOnline {
                startHeartbeat()
            } else {
                stopHeartbeat()
            }
            result(true)

        case "updateHighAccuracyMode":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing enabled argument", details: nil))
                return
            }

            self.highAccuracyMode = enabled
            saveState()
            updateLocationTracking()
            result(true)

        case "updateToken":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing token arguments", details: nil))
                return
            }

            self.userToken = args["token"] as? String
            saveState()
            print("JWT token updated in iOS background service")
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func saveState() {
        defaults.set(userId, forKey: kUserId)
        defaults.set(supabaseUrl, forKey: kSupabaseUrl)
        defaults.set(supabaseKey, forKey: kSupabaseKey)
        defaults.set(userToken, forKey: kUserToken)
        defaults.set(isVisible, forKey: kIsVisible)
        defaults.set(isOnline, forKey: kIsOnline)
        defaults.set(highAccuracyMode, forKey: kHighAccuracyMode)
    }

    private func loadState() {
        userId = defaults.string(forKey: kUserId)
        supabaseUrl = defaults.string(forKey: kSupabaseUrl)
        supabaseKey = defaults.string(forKey: kSupabaseKey)
        userToken = defaults.string(forKey: kUserToken)
        isVisible = defaults.bool(forKey: kIsVisible)
        isOnline = defaults.bool(forKey: kIsOnline)
        highAccuracyMode = defaults.bool(forKey: kHighAccuracyMode)
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.matchme.backgroundsync", using: nil) { task in
            self.handleBackgroundSync(task: task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.matchme.locationupdate", using: nil) { task in
            self.handleLocationUpdate(task: task as! BGAppRefreshTask)
        }
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    private func startBackgroundService() {
        // Start heartbeat
        startHeartbeat()

        // Start location updates if visible
        updateLocationTracking()

        // Schedule background tasks
        scheduleBackgroundTasks()

        // Start background task to keep app alive longer
        beginBackgroundTask()
    }

    private func stopBackgroundService() {
        stopHeartbeat()
        locationManager.stopUpdatingLocation()
        endBackgroundTask()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        // Clear sensitive state immediately
        self.userId = nil
        self.supabaseUrl = nil
        self.supabaseKey = nil
        self.userToken = nil
        self.isVisible = false
        self.isOnline = false
        saveState()
    }

    private func isServiceRunning() -> Bool {
        return userId != nil && (heartbeatTimer?.isValid ?? false)
    }

    private func updateLocationTracking() {
        let shouldTrack = isVisible && isOnline
        
        if shouldTrack && CLLocationManager.locationServicesEnabled() {
            locationManager.requestAlwaysAuthorization()
            
            if highAccuracyMode {
                // High Accuracy: Continuous updates with background execution
                locationManager.allowsBackgroundLocationUpdates = true
                locationManager.desiredAccuracy = kCLLocationAccuracyBest
                locationManager.distanceFilter = 10.0 // 10 meters
                locationManager.pausesLocationUpdatesAutomatically = false

                locationManager.startMonitoringSignificantLocationChanges()
                locationManager.startUpdatingLocation()
            } else {
                // Standard Mode: Significant changes only (battery saving)
                // This allows the app to be suspended but woken up for major moves (500m+)
                locationManager.allowsBackgroundLocationUpdates = false // Let app suspend
                locationManager.pausesLocationUpdatesAutomatically = true
                
                locationManager.stopUpdatingLocation()
                locationManager.startMonitoringSignificantLocationChanges()
            }
        } else {
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        
        // If offline, don't start heartbeat
        if !isOnline {
            return
        }
        
        // Heartbeat every 5 minutes (300 seconds) - minimum allowed frequency for activity updates
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.performHeartbeat()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func performHeartbeat() {
        guard let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        lastHeartbeatTime = Date()

        let url = URL(string: "\(supabaseUrl)/rest/v1/rpc/update_user_activity")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["p_user_id": userId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Heartbeat failed: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("Successfully updated user activity")
                } else {
                    print("Heartbeat failed with status: \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }

    private func scheduleBackgroundTasks() {
        // Schedule sync task
        let syncRequest = BGProcessingTaskRequest(identifier: "com.matchme.backgroundsync")
        syncRequest.requiresNetworkConnectivity = true
        syncRequest.requiresExternalPower = false
        syncRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 1 minute

        // Schedule location update task
        let locationRequest = BGAppRefreshTaskRequest(identifier: "com.matchme.locationupdate")
        locationRequest.earliestBeginDate = Date(timeIntervalSinceNow: 120) // 2 minutes

        do {
            try BGTaskScheduler.shared.submit(syncRequest)
            try BGTaskScheduler.shared.submit(locationRequest)
        } catch {
            print("Failed to schedule background tasks: \(error)")
        }
    }

    private func handleBackgroundSync(task: BGProcessingTask) {
        let operation = performBackgroundSync()

        task.expirationHandler = {
            operation.cancel()
        }

        operation.completionBlock = {
            task.setTaskCompleted(success: !operation.isCancelled)
            self.scheduleBackgroundTasks() // Reschedule
        }

        OperationQueue.main.addOperation(operation)
    }

    private func handleLocationUpdate(task: BGAppRefreshTask) {
        print("Executing background location update task")
        
        task.expirationHandler = {
            self.pendingBackgroundTask = nil
            task.setTaskCompleted(success: false)
        }
        
        self.pendingBackgroundTask = task
        
        // Request a single location update
        locationManager.requestLocation()
        
        scheduleBackgroundTasks() // Reschedule
    }

    private func performBackgroundSync() -> Operation {
        return BlockOperation {
            // Perform minimal sync operations
            self.performHeartbeat()

            if self.isVisible {
                // Trigger match engine with last known location if available
                // This would need to be implemented based on stored location
            }
        }
    }

    private func beginBackgroundTask() {
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "MatchMeBackground") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
            backgroundTaskIdentifier = .invalid
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Complete background task if exists
        defer {
            if let task = pendingBackgroundTask {
                task.setTaskCompleted(success: true)
                pendingBackgroundTask = nil
            }
        }

        if isOnline {
             // Update activity if online (throttled)
             if let lastTime = lastHeartbeatTime {
                 if Date().timeIntervalSince(lastTime) > 60 {
                     performHeartbeat()
                 }
             } else {
                 performHeartbeat()
             }
        }

        guard let location = locations.last, isVisible, let userId = userId else { return }

        updateLocationInSupabase(location: location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
        if let task = pendingBackgroundTask {
             task.setTaskCompleted(success: false)
             pendingBackgroundTask = nil
        }
    }

    private func updateLocationInSupabase(location: CLLocation) {
        guard let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        let url = URL(string: "\(supabaseUrl)/rest/v1/rpc/update_user_location")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "p_user_id": userId,
            "p_latitude": location.coordinate.latitude,
            "p_longitude": location.coordinate.longitude,
            "p_speed": location.speed,
            "p_heading": location.course
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Location update failed: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("Successfully updated location")
                } else {
                    print("Location update failed with status: \(httpResponse.statusCode)")
                }
            }
        }.resume()
    }

    // MARK: - UIApplicationDelegate

    public func applicationDidEnterBackground(_ application: UIApplication) {
        beginBackgroundTask()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        endBackgroundTask()
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Handle silent notifications
        completionHandler([])
    }
}
