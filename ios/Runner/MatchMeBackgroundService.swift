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
import BackgroundTasks
import CryptoKit

public class MatchMeBackgroundService: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate, CLLocationManagerDelegate {
    private static var backgroundTaskService: MatchMeBackgroundService?
    private static var pendingBackgroundTasks: [(task: BGTask, isLocationUpdate: Bool)] = []

    private let channel: FlutterMethodChannel
    private let locationManager = CLLocationManager()
    private var userId: String?
    private var supabaseUrl: String?
    private var supabaseKey: String?
    private var userToken: String?
    private var isVisible = false
    private var isOnline = false
    private var backgroundMatchingMode = false
    private var gpsInterval = 5
    private var smartThrottlingEnabled = true
    private var appInForeground = UIApplication.shared.applicationState == .active
    private var lifecycleIsBackgrounded: Bool?
    private var heartbeatTimer: Timer?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTaskTimeoutTimer: Timer?
    private var pendingBackgroundTask: BGAppRefreshTask?
    private var lastHeartbeatTime: Date?
    private var wasPinnedSkipping = false
    private var matchingTimer: Timer?
    private var lastMatchingLocation: CLLocation?
    private var lastMatchingSentAt: Date?
    private var recentMatchingLocations: [CLLocation] = []

    // Live location share state (mirrors Android LocationShareHelper)
    private var lsMatchId: String?
    private var lsOtherUserId: String?
    private var lsSessionKey: Data?
    private var lsIntervalSeconds: Int = 5
    private var lsExpiresAt: String?
    private var lsShareTimer: Timer?
    private var lsWebSocket: URLSessionWebSocketTask?
    private var lsWebSocketSession: URLSession?
    private var lsJoinedChannel = false
    private var lastLocationForShare: CLLocation?
    private var refreshToken: String?
    private var lsRestoreAttempted = false

    private let defaults = UserDefaults.standard
    private let kUserId = "mm_user_id"
    private let kSupabaseUrl = "mm_supabase_url"
    private let kSupabaseKey = "mm_supabase_key"
    private let kUserToken = "mm_user_token"
    private let kIsVisible = "mm_is_visible"
    private let kIsOnline = "mm_is_online"
    private let kBackgroundMatchingMode = "mm_background_matching_mode"
    private let kGpsInterval = "flutter.gps_interval"
    private let kSmartThrottlingEnabled = "flutter.smart_throttling_enabled"

    // Flutter's shared_preferences writes to UserDefaults.standard on iOS
    // with "flutter."-prefixed keys, so we read/write the same domain.
    private let kLsMatchId = "flutter.location_share_match_id"
    private let kLsOtherUserId = "flutter.location_share_other_user_id"
    private let kLsSessionKey = "flutter.location_share_session_key"
    private let kLsInterval = "flutter.location_share_interval"
    private let kLsExpiresAt = "flutter.location_share_expires_at"
    private let kRefreshToken = "flutter.refresh_token"
    private let kUserTokenKey = "flutter.user_token"
    private let kRecentLocations = "flutter.recent_locations_json"
    // Pinned home-base (written by Flutter, mirrored from PinnedLocationGate).
    private let kPinnedActive = "flutter.pinned_location_active"
    private let kPinnedExpiresAtMs = "flutter.pinned_location_expires_at_ms"

    /// True while a pinned home-base is active: no live GPS may be uploaded.
    private func isPinnedLocationActive() -> Bool {
        guard defaults.bool(forKey: kPinnedActive) else { return false }
        let expMs = defaults.object(forKey: kPinnedExpiresAtMs) as? Int
            ?? Int(defaults.double(forKey: kPinnedExpiresAtMs))
        guard expMs > 0 else { return false }
        return Int64(expMs) > Int64(Date().timeIntervalSince1970 * 1000)
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        // Load saved state
        loadState()

        // Monitor battery for smart throttling - must survive reboot / UI killed
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateChanged), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryStateChanged), name: UIDevice.batteryStateDidChangeNotification, object: nil)

        // Restore an active location share across app restarts.
        restoreLocationShareState()

        // Resume service if we have state
        if userId != nil {
            startBackgroundService()
        }

        Self.backgroundTaskService = self
        let pendingTasks = Self.pendingBackgroundTasks
        Self.pendingBackgroundTasks.removeAll()
        for pendingTask in pendingTasks {
            handleBackgroundTask(pendingTask.task, isLocationUpdate: pendingTask.isLocationUpdate)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "matchme/background_service", binaryMessenger: registrar.messenger())
        let instance = MatchMeBackgroundService(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
        registrar.addSceneDelegate(instance)
    }

    public static func registerBackgroundTaskHandlers() {
        let syncRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.matchme.backgroundsync",
            using: nil
        ) { task in
            dispatchBackgroundTask(task, isLocationUpdate: false)
        }
        let locationRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.matchme.locationupdate",
            using: nil
        ) { task in
            dispatchBackgroundTask(task, isLocationUpdate: true)
        }

        if !syncRegistered || !locationRegistered {
            print("MatchMeBackgroundService: failed to register one or more background task handlers")
        }
    }

    private static func dispatchBackgroundTask(_ task: BGTask, isLocationUpdate: Bool) {
        guard let service = backgroundTaskService else {
            pendingBackgroundTasks.append((task: task, isLocationUpdate: isLocationUpdate))
            return
        }
        service.handleBackgroundTask(task, isLocationUpdate: isLocationUpdate)
    }

    private func handleBackgroundTask(_ task: BGTask, isLocationUpdate: Bool) {
        if isLocationUpdate, let locationTask = task as? BGAppRefreshTask {
            handleLocationUpdate(task: locationTask)
        } else if !isLocationUpdate, let syncTask = task as? BGProcessingTask {
            handleBackgroundSync(task: syncTask)
        } else {
            task.setTaskCompleted(success: false)
        }
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

            if let backgroundMatchingMode = args["backgroundMatchingMode"] as? Bool {
                self.backgroundMatchingMode = backgroundMatchingMode
            }

            if let appInForeground = args["appInForeground"] as? Bool {
                self.appInForeground = appInForeground
            }

            if let gpsInterval = args["gpsInterval"] as? Int {
                self.gpsInterval = max(gpsInterval, 1)
            } else if let gpsInterval = args["gps_interval"] as? Int {
                self.gpsInterval = max(gpsInterval, 1)
            }
            if let smartThrottling = args["smartThrottlingEnabled"] as? Bool {
                self.smartThrottlingEnabled = smartThrottling
            } else if let smartThrottling = args["smart_throttling_enabled"] as? Bool {
                self.smartThrottlingEnabled = smartThrottling
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

        case "updateBackgroundMatchingMode":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing enabled argument", details: nil))
                return
            }

            self.backgroundMatchingMode = enabled
            saveState()
            updateLocationTracking()
            result(true)

        case "updateAppForeground":
            guard let args = call.arguments as? [String: Any],
                  let isForeground = args["isForeground"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing isForeground argument", details: nil))
                return
            }

            self.appInForeground = isForeground
            updateLocationTracking()
            result(true)

        case "updateConfig":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing config arguments", details: nil))
                return
            }

            let nextInterval = (args["gpsInterval"] as? Int) ?? 5
            let nextSmartThrottling = (args["smartThrottlingEnabled"] as? Bool) ?? true
            gpsInterval = max(nextInterval, 1)
            smartThrottlingEnabled = nextSmartThrottling
            saveState()
            updateLocationTracking()
            result(true)

        case "updateToken":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing token arguments", details: nil))
                return
            }

            self.userToken = args["token"] as? String
            if let rt = args["refreshToken"] as? String, !rt.trimmingCharacters(in: .whitespaces).isEmpty {
                self.refreshToken = rt
                defaults.set(rt, forKey: self.kRefreshToken)
                defaults.set(rt, forKey: "flutter.refresh_token")
            }
            if let tok = self.userToken {
                defaults.set(tok, forKey: self.kUserTokenKey)
                defaults.set(tok, forKey: self.kUserToken)
            }
            saveState()
            print("JWT token updated in iOS background service")
            result(true)

        case "startLocationShare":
            guard let args = call.arguments as? [String: Any],
                  let matchId = args["matchId"] as? String,
                  let otherUserId = args["otherUserId"] as? String,
                  let sessionKeyBase64 = args["sessionKeyBase64"] as? String,
                  let sessionKey = Data(base64Encoded: sessionKeyBase64) else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing required arguments for location share", details: nil))
                return
            }

            lsMatchId = matchId
            lsOtherUserId = otherUserId
            lsSessionKey = sessionKey
            lsIntervalSeconds = (args["updateIntervalSeconds"] as? Int) ?? 5
            lsExpiresAt = args["expiresAtIso"] as? String
            persistLocationShareState()
            startLocationShareLoop()
            // Ensure continuous location updates keep flowing in the background.
            updateLocationTracking()
            result(true)

        case "stopLocationShare":
            stopLocationShareLoop()
            result(true)

        case "updateLocationShareDuration":
            let args = call.arguments as? [String: Any]
            lsExpiresAt = args?["expiresAtIso"] as? String
            persistLocationShareState()
            // Expiry is re-evaluated on every broadcastShareTick (60 s) against the
            // now-updated lsExpiresAt. We additionally fire an immediate tick so that
            // a reduction of duration to "now" (or expired) causes an instant stop.
            if isLocationShareActive() {
                broadcastShareTick()
            }
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
        defaults.set(backgroundMatchingMode, forKey: kBackgroundMatchingMode)
        defaults.set(gpsInterval, forKey: kGpsInterval)
        defaults.set(smartThrottlingEnabled, forKey: kSmartThrottlingEnabled)
    }

    private func loadState() {
        userId = defaults.string(forKey: kUserId)
        supabaseUrl = defaults.string(forKey: kSupabaseUrl)
        supabaseKey = defaults.string(forKey: kSupabaseKey)
        userToken = defaults.string(forKey: kUserToken)
        isVisible = defaults.object(forKey: kIsVisible) as? Bool ?? true
        isOnline = defaults.object(forKey: kIsOnline) as? Bool ?? true
        backgroundMatchingMode = defaults.object(forKey: kBackgroundMatchingMode) as? Bool ?? false
        gpsInterval = defaults.object(forKey: kGpsInterval) as? Int ?? 5
        smartThrottlingEnabled = defaults.object(forKey: kSmartThrottlingEnabled) as? Bool ?? true
        refreshToken = defaults.string(forKey: kRefreshToken)
        restoreRecentLocations()
    }

    private func persistRecentLocations() {
        let arr: [[String: Any]] = recentMatchingLocations.map { loc in
            ["lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude, "acc": loc.horizontalAccuracy, "time": loc.timestamp.timeIntervalSince1970 * 1000]
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: kRecentLocations)
        }
    }

    private func restoreRecentLocations() {
        guard let json = defaults.string(forKey: kRecentLocations), let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        recentMatchingLocations.removeAll()
        let now = Date().timeIntervalSince1970 * 1000
        for dict in arr {
            guard let lat = dict["lat"] as? Double, let lng = dict["lng"] as? Double else { continue }
            let acc = dict["acc"] as? Double ?? 10.0
            let t = dict["time"] as? Double ?? now
            if now - t > 30 * 60 * 1000 { continue } // stale >30 min
            let loc = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), altitude: 0, horizontalAccuracy: acc, verticalAccuracy: -1, timestamp: Date(timeIntervalSince1970: t/1000))
            recentMatchingLocations.append(loc)
        }
        if recentMatchingLocations.count > 5 {
            recentMatchingLocations = Array(recentMatchingLocations.suffix(5))
        }
    }

    private func startBackgroundService() {
        // Start heartbeat
        startHeartbeat()

        // Start location updates if visible
        updateLocationTracking()

        // Schedule background tasks
        scheduleBackgroundTasks()
    }

    private func stopBackgroundService() {
        stopHeartbeat()
        stopMatchingTimer()
        stopLocationShareLoop()
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
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
        let shareActive = isLocationShareActive()
        // Pinned home-base pauses matching GPS (explicit live location shares
        // still run: they are per-match, user-initiated consent).
        let pinned = isPinnedLocationActive()
        if pinned && !shareActive && !wasPinnedSkipping {
            wasPinnedSkipping = true
            print("📌 [iOS-BG] Pinned location ACTIVE — GPS paused, GPS not accessed for matching (heartbeat only)")
        } else if !pinned && wasPinnedSkipping {
            wasPinnedSkipping = false
            print("▶️ [iOS-BG] Pinned location REMOVED/expired — GPS resumed")
        }
        let shouldTrack = ((isVisible && isOnline && !pinned) || shareActive)
        if !shouldTrack {
            stopMatchingTimer()
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
            return
        }

        let authorizationStatus = locationManager.authorizationStatus
        if authorizationStatus == .restricted || authorizationStatus == .denied {
            stopMatchingTimer()
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
            return
        }

        if authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
            return
        }

        let nativeMatchingActive = shouldUseNativeMatchingUpdates()
        if nativeMatchingActive || shareActive {
            if authorizationStatus == .authorizedWhenInUse {
                locationManager.requestAlwaysAuthorization()
            }
            locationManager.allowsBackgroundLocationUpdates = !appInForeground || shareActive
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
            locationManager.pausesLocationUpdatesAutomatically = false

            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startUpdatingLocation()
            if nativeMatchingActive {
                startMatchingTimer()
            } else {
                stopMatchingTimer()
            }
        } else {
            stopMatchingTimer()
            locationManager.allowsBackgroundLocationUpdates = false
            locationManager.pausesLocationUpdatesAutomatically = true
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
        }
    }

    private func shouldUseNativeMatchingUpdates() -> Bool {
        return !appInForeground
    }

    private func rememberRecentLocation(_ location: CLLocation) {
        recentMatchingLocations.append(location)
        if recentMatchingLocations.count > 5 {
            recentMatchingLocations.removeFirst(recentMatchingLocations.count - 5)
        }
        persistRecentLocations()
    }

    private func isStationary() -> Bool {
        guard recentMatchingLocations.count >= 5,
              let first = recentMatchingLocations.first else {
            return false
        }
        return recentMatchingLocations.allSatisfy { $0.distance(from: first) <= 10.0 }
    }

    private func effectiveMatchingInterval() -> TimeInterval {
        var interval = TimeInterval(max(gpsInterval, 1))
        if smartThrottlingEnabled {
            if isStationary() {
                interval = max(interval, 60.0)
            }
            if isBatteryLowThrottled() {
                interval = max(interval, 60.0)
            }
        }
        return interval
    }

    private func isBatteryLowThrottled() -> Bool {
        guard smartThrottlingEnabled else { return false }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel // 0.0..1.0, -1 if unknown
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full
        if charging { return false }
        if level < 0 { return false }
        return level < 0.15
    }

    @objc private func batteryStateChanged() {
        guard smartThrottlingEnabled, isVisible, isOnline else { return }
        // Re-evaluate effective interval immediately - matches Android BatteryReceiver
        if shouldUseNativeMatchingUpdates() {
            startMatchingTimer()
        }
        updateLocationTracking()
    }

    private func stopMatchingTimer() {
        matchingTimer?.invalidate()
        matchingTimer = nil
        lastMatchingSentAt = nil
    }

    private func startMatchingTimer() {
        guard shouldUseNativeMatchingUpdates(), isVisible, isOnline else {
            stopMatchingTimer()
            return
        }

        let interval = effectiveMatchingInterval()
        if let timer = matchingTimer, timer.isValid, abs(timer.timeInterval - interval) < 0.5 {
            return
        }

        matchingTimer?.invalidate()
        matchingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendLatestMatchingLocationIfDue()
        }
        if lastMatchingSentAt == nil {
            sendLatestMatchingLocationIfDue(force: true)
        }
    }

    private func sendLatestMatchingLocationIfDue(force: Bool = false) {
        guard shouldUseNativeMatchingUpdates(),
              isVisible,
              isOnline,
              let location = lastMatchingLocation else {
            return
        }

        let now = Date()
        let interval = effectiveMatchingInterval()
        if !force, let lastMatchingSentAt, now.timeIntervalSince(lastMatchingSentAt) < interval {
            return
        }

        self.lastMatchingSentAt = now
        updateLocationInSupabase(location: location)

        if let timer = matchingTimer, abs(timer.timeInterval - interval) >= 0.5 {
            startMatchingTimer()
        }
    }

    private func isLocationShareActive() -> Bool {
        return lsMatchId != nil && lsSessionKey != nil
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        // Modern iOS: Timer suspends when app is suspended. Keep lightweight heartbeat
        // via BGTaskScheduler + CLLocation significant-change. Timer is for foreground
        // fast path; background path is in scheduleBackgroundTasks/handleBackgroundSync.
        // Don't gate on isOnline – offline->online transition needs immediate heartbeat
        // and CLLocation may still have cached fix to keep 15m window.
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isOnline {
                // Still try – update_user_activity will no-op server-side if truly offline,
                // but will succeed immediately when transport returns (no 30s wait)
                self.performHeartbeat()
                return
            }
            self.performHeartbeat()
        }
        performHeartbeat()
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
        // Prefer user JWT for RLS; fallback to anon key only if token missing (e.g. cold start before refresh)
        let bearer = (userToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? userToken! : supabaseKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
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
        let syncRequest = BGProcessingTaskRequest(identifier: "com.matchme.backgroundsync")
        syncRequest.requiresNetworkConnectivity = true
        syncRequest.requiresExternalPower = false
        syncRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30) // 30s – heartbeat must be <61s

        let locationRequest = BGAppRefreshTaskRequest(identifier: "com.matchme.locationupdate")
        locationRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60) // 60s, not 900 – 15m visible window needs <15m

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
        if backgroundTaskIdentifier != .invalid {
            return
        }
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "MatchMeBackground") {
            self.endBackgroundTask()
        }
        backgroundTaskTimeoutTimer?.invalidate()
        backgroundTaskTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        backgroundTaskTimeoutTimer?.invalidate()
        backgroundTaskTimeoutTimer = nil
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

        // Cache the latest position for the location share loop.
        if let latest = locations.last {
            lastLocationForShare = latest
            lastMatchingLocation = latest
            rememberRecentLocation(latest)
        }

        // ✅ NEW: Broadcast immediately when location updates and share is active
        // This is the key change - iOS was relying on timer for broadcasts,
        // but timer stops when app is suspended. Now we broadcast immediately
        // when location updates via CLLocationManager delegate.
        if isLocationShareActive(), let location = locations.last, isOnline {
            broadcastPosition(location: location)
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

        guard locations.last != nil, isVisible, !isPinnedLocationActive(), userId != nil else { return }

        if shouldUseNativeMatchingUpdates() {
            sendLatestMatchingLocationIfDue(force: lastMatchingSentAt == nil)
            startMatchingTimer()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location manager failed: \(error)")
        if let task = pendingBackgroundTask {
             task.setTaskCompleted(success: false)
             pendingBackgroundTask = nil
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateLocationTracking()
    }

    private func updateLocationInSupabase(location: CLLocation) {
        guard let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        let url = URL(string: "\(supabaseUrl)/rest/v1/rpc/update_user_location")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        let bearer2 = (userToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? userToken! : supabaseKey
        request.setValue("Bearer \(bearer2)", forHTTPHeaderField: "Authorization")
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
        enterBackground()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        enterForeground()
    }

    public func sceneDidEnterBackground(_ scene: UIScene) {
        enterBackground()
    }

    public func sceneWillEnterForeground(_ scene: UIScene) {
        enterForeground()
    }

    private func enterBackground() {
        guard lifecycleIsBackgrounded != true else { return }
        lifecycleIsBackgrounded = true
        appInForeground = false
        beginBackgroundTask()
        updateLocationTracking()
    }

    private func enterForeground() {
        guard lifecycleIsBackgrounded != false else { return }
        lifecycleIsBackgrounded = false
        appInForeground = true
        endBackgroundTask()
        updateLocationTracking()
    }

    // MARK: - Live Location Share

    private func persistLocationShareState() {
        let d = defaults
        d.set(lsMatchId, forKey: kLsMatchId)
        d.set(lsOtherUserId, forKey: kLsOtherUserId)
        if let key = lsSessionKey {
            d.set(key.base64EncodedString(), forKey: kLsSessionKey)
        } else {
            d.removeObject(forKey: kLsSessionKey)
        }
        d.set(lsIntervalSeconds, forKey: kLsInterval)
        if let expiresAt = lsExpiresAt {
            d.set(expiresAt, forKey: kLsExpiresAt)
        } else {
            d.removeObject(forKey: kLsExpiresAt)
        }
    }

    private func clearPersistedLocationShareState() {
        let d = defaults
        d.removeObject(forKey: kLsMatchId)
        d.removeObject(forKey: kLsOtherUserId)
        d.removeObject(forKey: kLsSessionKey)
        d.removeObject(forKey: kLsInterval)
        d.removeObject(forKey: kLsExpiresAt)
    }

    /// Re-arms a location share that was active when the process was
    /// relaunched. The loop re-validates the signal in the DB on its first
    /// tick and stops itself if it is no longer valid.
    private func restoreLocationShareState() {
        guard !lsRestoreAttempted else { return }
        lsRestoreAttempted = true

        let d = defaults
        guard let matchId = d.string(forKey: kLsMatchId), !matchId.isEmpty,
              let otherUserId = d.string(forKey: kLsOtherUserId), !otherUserId.isEmpty,
              let keyB64 = d.string(forKey: kLsSessionKey),
              let key = Data(base64Encoded: keyB64), !key.isEmpty else { return }

        lsMatchId = matchId
        lsOtherUserId = otherUserId
        lsSessionKey = key
        let storedInterval = d.integer(forKey: kLsInterval)
        lsIntervalSeconds = storedInterval > 0 ? storedInterval : 5
        lsExpiresAt = d.string(forKey: kLsExpiresAt)
        if let rt = d.string(forKey: kRefreshToken) {
            refreshToken = rt
        }
        // Mirror Android: never resurrect an already-expired share on
        // relaunch — it would keep HIGH_ACCURACY GPS alive and broadcast
        // nothing useful while the receiver sits on "Stale".
        if isShareExpired() {
            lsMatchId = nil
            lsOtherUserId = nil
            lsSessionKey = nil
            lsExpiresAt = nil
            clearPersistedLocationShareState()
            updateLocationTracking()
            return
        }
        startLocationShareLoop()
        updateLocationTracking()
    }

    private func startLocationShareLoop() {
        lsShareTimer?.invalidate()
        broadcastShareTick()
        
        // Changed from max(TimerInterval, 2.0) to longer interval
        // Timer now serves as backup for signal validity checks only
        // (not for primary broadcasts - those come from didUpdateLocations)
        let interval = max(TimeInterval(lsIntervalSeconds), 60.0)
        lsShareTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.broadcastShareTick()
        }
    }

    private func stopLocationShareLoop() {
        lsShareTimer?.invalidate()
        lsShareTimer = nil
        // Best-effort DELETE of our own signal so the peer moves to
        // "Stopped" promptly instead of lingering on "Stale" until server
        // cleanup. Idempotent; Dart already deletes on explicit stops.
        deleteOwnShareSignal()
        lsWebSocket?.cancel(with: .goingAway, reason: nil)
        lsWebSocket = nil
        lsWebSocketSession?.invalidateAndCancel()
        lsWebSocketSession = nil
        lsJoinedChannel = false
        lsMatchId = nil
        lsOtherUserId = nil
        lsSessionKey = nil
        lsExpiresAt = nil
        clearPersistedLocationShareState()
        // Downgrade tracking if nothing else requires continuous updates.
        updateLocationTracking()
    }

    /// Best-effort DELETE of our own share signal so the peer moves to
    /// "Stopped" promptly instead of lingering on "Stale" until server
    /// cleanup. Fire-and-forget; failures are swallowed.
    private func deleteOwnShareSignal() {
        guard let matchId = lsMatchId,
              let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }
        guard let url = URL(string: "\(supabaseUrl)/rest/v1/location_share_signals?match_id=eq.\(matchId)&sharer_id=eq.\(userId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(userToken ?? supabaseKey)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func broadcastShareTick() {
        guard lsMatchId != nil, lsSessionKey != nil else { return }
        if isShareExpired() {
            stopLocationShareLoop()
            return
        }
        // While offline, skip GPS reads and DB checks to conserve battery.
        // The timer keeps running so broadcasts resume automatically once
        // connectivity returns.
        if !isOnline { return }
        isShareSignalActive { [weak self] active in
            guard let self = self else { return }
            guard active else {
                self.stopLocationShareLoop()
                return
            }
            guard let location = self.lastLocationForShare else { return }
            self.broadcastPosition(location: location)
        }
    }

    private func isShareExpired() -> Bool {
        guard let expiresAt = lsExpiresAt else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: expiresAt)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: expiresAt)
        }
        guard let date = date else { return false }
        return date.timeIntervalSinceNow <= 0
    }

    private func isShareSignalActive(completion: @escaping (Bool) -> Void) {
        guard let matchId = lsMatchId,
              let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else {
            completion(false)
            return
        }

        let url = URL(string: "\(supabaseUrl)/rest/v1/location_share_signals?select=id&match_id=eq.\(matchId)&sharer_id=eq.\(userId)&or=(expires_at.gt.now(),expires_at.is.null)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(userToken ?? supabaseKey)", forHTTPHeaderField: "Authorization")

        let checkActive: (Bool) -> Void = { active in
            DispatchQueue.main.async {
                completion(active)
            }
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard error == nil, let httpResponse = response as? HTTPURLResponse else {
                checkActive(true) // Assume active on error to avoid premature stop
                return
            }
            if httpResponse.statusCode == 401 {
                // Token may be stale after a relaunch — refresh and retry once.
                self?.refreshJwtToken { success in
                    guard success, let self = self else {
                        checkActive(true)
                        return
                    }
                    var retry = URLRequest(url: url)
                    retry.httpMethod = "GET"
                    retry.setValue(supabaseKey, forHTTPHeaderField: "apikey")
                    retry.setValue("Bearer \(self.userToken ?? supabaseKey)", forHTTPHeaderField: "Authorization")
                    URLSession.shared.dataTask(with: retry) { data2, response2, error2 in
                        guard error2 == nil, let http2 = response2 as? HTTPURLResponse, http2.statusCode == 200,
                              let data2 = data2 else {
                            checkActive(true)
                            return
                        }
                        let arr = (try? JSONSerialization.jsonObject(with: data2)) as? [Any]
                        checkActive(!(arr?.isEmpty ?? true))
                    }.resume()
                }
                return
            }
            guard httpResponse.statusCode == 200, let data = data else {
                checkActive(true)
                return
            }
            let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            checkActive(!(arr?.isEmpty ?? true))
        }.resume()
    }

    private func isJwtExpiringSoon(token: String?) -> Bool {
        guard let token = token, !token.isEmpty else { return true }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var payload = String(parts[1])
        // Base64URL decode
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = payload.count % 4
        if pad > 0 { payload += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return false }
        let now = Date().timeIntervalSince1970
        return exp - now <= 120
    }

    private func syncTokensToDartStorage(newAccessToken: String, newRefreshToken: String?, responseJson: [String: Any]) {
        let expiresIn = responseJson["expires_in"] as? Int ?? 3600
        let expiresAt = Int(Date().timeIntervalSince1970) + expiresIn
        // Update persisted_supabase_session
        if let persisted = defaults.string(forKey: "persisted_supabase_session"), !persisted.isEmpty,
           let data = persisted.data(using: .utf8),
           var outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var current = outer["currentSession"] as? [String: Any] ?? [:]
            current["access_token"] = newAccessToken
            if let rt = newRefreshToken, !rt.isEmpty { current["refresh_token"] = rt }
            current["expires_in"] = expiresIn
            current["expires_at"] = expiresAt
            if let user = responseJson["user"] as? [String: Any] { current["user"] = user }
            outer["currentSession"] = current
            outer["expiresAt"] = expiresAt
            if let newData = try? JSONSerialization.data(withJSONObject: outer), let str = String(data: newData, encoding: .utf8) {
                defaults.set(str, forKey: "persisted_supabase_session")
            }
        } else if let user = responseJson["user"] as? [String: Any] {
            var minimal: [String: Any] = [
                "access_token": newAccessToken,
                "expires_in": expiresIn,
                "expires_at": expiresAt,
                "token_type": "bearer",
                "user": user
            ]
            if let rt = newRefreshToken, !rt.isEmpty { minimal["refresh_token"] = rt }
            let outer: [String: Any] = ["currentSession": minimal, "expiresAt": expiresAt]
            if let newData = try? JSONSerialization.data(withJSONObject: outer), let str = String(data: newData, encoding: .utf8) {
                defaults.set(str, forKey: "persisted_supabase_session")
            }
        }
        // Update sb-*-auth-token keys
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sb-") && key.hasSuffix("-auth-token") {
            guard let val = defaults.string(forKey: key), !val.isEmpty,
                  let data = val.data(using: .utf8),
                  var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var current = obj["currentSession"] as? [String: Any] ?? obj
            current["access_token"] = newAccessToken
            if let rt = newRefreshToken, !rt.isEmpty { current["refresh_token"] = rt }
            current["expires_at"] = expiresAt
            if obj["currentSession"] != nil {
                obj["currentSession"] = current
                obj["expiresAt"] = expiresAt
                if let newData = try? JSONSerialization.data(withJSONObject: obj), let str = String(data: newData, encoding: .utf8) {
                    defaults.set(str, forKey: key)
                }
            } else {
                if let newData = try? JSONSerialization.data(withJSONObject: current), let str = String(data: newData, encoding: .utf8) {
                    defaults.set(str, forKey: key)
                }
            }
        }
    }

    private var isRefreshing = false

    private func refreshJwtToken(completion: @escaping (Bool) -> Void) {
        // When UI is foreground, Dart owns refresh - don't race
        if appInForeground {
            // Adopt any newer token Dart may have written
            if let latestRt = defaults.string(forKey: kRefreshToken)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !latestRt.isEmpty, latestRt != refreshToken {
                refreshToken = latestRt
                userToken = defaults.string(forKey: kUserTokenKey) ?? defaults.string(forKey: kUserToken)
            }
            completion(false)
            return
        }
        if isRefreshing {
            completion(false)
            return
        }
        isRefreshing = true

        // Re-read latest token in case Dart won race
        let latestBefore = defaults.string(forKey: kRefreshToken)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenToUse: String
        if let lb = latestBefore, !lb.isEmpty, lb != refreshToken {
            refreshToken = lb
            userToken = defaults.string(forKey: kUserTokenKey) ?? defaults.string(forKey: kUserToken)
            // If new token is still valid, no need to refresh
            if let tok = userToken, !isJwtExpiringSoon(token: tok) {
                isRefreshing = false
                completion(false)
                return
            }
            tokenToUse = lb
        } else {
            guard let rt = refreshToken, !rt.isEmpty,
                  let _ = supabaseUrl,
                  let _ = supabaseKey else {
                isRefreshing = false
                completion(false)
                return
            }
            tokenToUse = rt
        }

        guard let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else {
            isRefreshing = false
            completion(false)
            return
        }

        let url = URL(string: "\(supabaseUrl)/auth/v1/token?grant_type=refresh_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": tokenToUse])

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(false); return }
            defer { self.isRefreshing = false }
            // Check for already_used race - if Dart refreshed concurrently, adopt its token
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if bodyStr.contains("refresh_token_already_used") || bodyStr.contains("invalid_grant") || bodyStr.contains("refresh_token_not_found") {
                    let latestAfter = self.defaults.string(forKey: self.kRefreshToken)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let latestAtAfter = self.defaults.string(forKey: self.kUserTokenKey) ?? self.defaults.string(forKey: self.kUserToken)
                    if let la = latestAfter, !la.isEmpty, la != tokenToUse {
                        self.refreshToken = la
                        if let at = latestAtAfter, !at.isEmpty { self.userToken = at }
                        completion(true)
                        return
                    }
                }
                completion(false)
                return
            }
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let newToken = json["access_token"] as? String,
                  !newToken.isEmpty else {
                completion(false)
                return
            }

            self.userToken = newToken
            var newRefresh: String? = nil
            if let nr = json["refresh_token"] as? String, !nr.isEmpty {
                self.refreshToken = nr
                newRefresh = nr
            }
            // Persist so the Dart app and future restores use the fresh tokens.
            self.defaults.set(newToken, forKey: self.kUserTokenKey)
            self.defaults.set(newToken, forKey: self.kUserToken)
            if let nr = newRefresh {
                self.defaults.set(nr, forKey: self.kRefreshToken)
                self.defaults.set(nr, forKey: "flutter.refresh_token")
            } else if let rt = self.refreshToken {
                self.defaults.set(rt, forKey: "flutter.refresh_token")
            }
            self.saveState()
            self.syncTokensToDartStorage(newAccessToken: newToken, newRefreshToken: newRefresh, responseJson: json)
            completion(true)
        }.resume()
    }

    private func connectShareWebSocketIfNeeded() {
        guard lsWebSocket == nil,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        let baseUrl = supabaseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let wsUrlString = baseUrl.replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
            + "/realtime/v1/websocket?apikey=\(supabaseKey)&vsn=1.0.0"
        guard let url = URL(string: wsUrlString) else { return }

        var request = URLRequest(url: url)
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(userToken ?? supabaseKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()
        lsWebSocketSession = session
        lsWebSocket = ws
        lsJoinedChannel = false
        receiveShareMessages()
    }

    private func receiveShareMessages() {
        lsWebSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.receiveShareMessages()
            case .failure:
                self.handleShareSocketFailure()
            }
        }
    }

    private func handleShareSocketFailure() {
        lsWebSocket?.cancel(with: .goingAway, reason: nil)
        lsWebSocket = nil
        lsJoinedChannel = false
        // The next tick will attempt to reconnect.
    }

    private func sendShareMessage(_ dict: [String: Any]) {
        guard let ws = lsWebSocket,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.handleShareSocketFailure()
            }
        }
    }

    private func joinShareChannel() {
        guard !lsJoinedChannel, let matchId = lsMatchId else { return }
        let joinPayload: [String: Any] = [
            "topic": "location-share:\(matchId)",
            "event": "phx_join",
            "payload": [
                "config": [
                    "broadcast": ["ack": false, "self": false],
                    "presence": ["key": ""]
                ]
            ],
            "ref": Int(Date().timeIntervalSince1970 * 1000)
        ]
        sendShareMessage(joinPayload)
        lsJoinedChannel = true
    }

    private func broadcastPosition(location: CLLocation) {
        guard let matchId = lsMatchId, let key = lsSessionKey else { return }
        if lsWebSocket == nil {
            connectShareWebSocketIfNeeded()
        }
        guard let ws = lsWebSocket else { return }
        if !lsJoinedChannel {
            joinShareChannel()
        }

        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var positionPayload: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lng": location.coordinate.longitude,
            "heading": location.course,
            "speed": location.speed,
            "ts": ts
        ]
        if let sharerId = userId {
            positionPayload["userId"] = sharerId
        }
        guard let plaintext = try? JSONSerialization.data(withJSONObject: positionPayload) else { return }

        // AES-GCM with a random 12-byte IV; combined layout is
        // nonce(12) || ciphertext || tag(16), matching the Dart/Android side.
        guard let encryptedB64 = encryptPositionPayload(plaintext, key: key) else { return }

        let broadcastMsg: [String: Any] = [
            "topic": "location-share:\(matchId)",
            "event": "broadcast",
            "payload": [
                "event": "position",
                "type": "broadcast",
                "data": encryptedB64
            ],
            "ref": NSNull()
        ]
        sendShareMessage(broadcastMsg)
    }

    private func encryptPositionPayload(_ plaintext: Data, key: Data) -> String? {
        do {
            let symmetricKey = SymmetricKey(data: key)
            let nonce = AES.GCM.Nonce() // Random 12-byte nonce
            let aad = Data("matchme.location.v1".utf8)
            let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce, authenticating: aad)
            guard let combined = sealedBox.combined else { return nil }
            return combined.base64EncodedString()
        } catch {
            return nil
        }
    }

}
