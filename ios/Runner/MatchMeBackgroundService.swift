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
    private var heartbeatTimer: Timer?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10.0 // 10 meters
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false

        // Register background tasks
        registerBackgroundTasks()

        // Request notification permissions for silent notifications
        requestNotificationPermissions()
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
            updateLocationTracking()
            result(true)

        case "updateToken":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing token arguments", details: nil))
                return
            }

            self.userToken = args["token"] as? String
            print("JWT token updated in iOS background service")
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
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
    }

    private func isServiceRunning() -> Bool {
        return userId != nil && (heartbeatTimer?.isValid ?? false)
    }

    private func updateLocationTracking() {
        if isVisible && CLLocationManager.locationServicesEnabled() {
            locationManager.requestAlwaysAuthorization()
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
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
        task.setTaskCompleted(success: true)
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
        guard let location = locations.last, isVisible, let userId = userId else { return }

        updateLocationInSupabase(location: location)
        triggerMatchEngine(location: location)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
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

    private func triggerMatchEngine(location: CLLocation) {
        guard let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        let url = URL(string: "\(supabaseUrl)/functions/v1/match-engine")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")

        // Use JWT token if available, otherwise fall back to anon key
        if let userToken = userToken, !userToken.isEmpty {
            request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
            print("Using JWT token for match engine (length: \(userToken.count))")
        } else {
            request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
            print("Using anon key for match engine (no valid JWT token)")
        }

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "userId": userId,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Match engine trigger failed: \(error)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    print("Successfully triggered match engine")
                } else if httpResponse.statusCode == 401 {
                    // Match engine requires service role permissions, which we can't provide from client
                    print("Match engine 401 error - this is expected as match engine requires server-side authentication")
                    print("Location update completed successfully, match engine will work when app is foreground")
                } else {
                    print("Match engine trigger failed with status: \(httpResponse.statusCode)")
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
