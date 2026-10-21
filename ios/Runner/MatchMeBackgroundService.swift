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
import Network

public class MatchMeBackgroundService: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate, CLLocationManagerDelegate {
    private static var backgroundTaskService: MatchMeBackgroundService?
    private static var pendingBackgroundTasks: [(task: BGTask, isLocationUpdate: Bool)] = []

    // MARK: - Diagnostics ring buffer
    //
    // Mirrors Android's `MatchMeBackgroundService.diagBuffer` (300 entries,
    // `logEvent` -> `addDiag`). The Dart side dumps this buffer on resume via
    // the `getDiagnostics` method-channel call so field logs show what the
    // native layer actually did (or failed to do) while the UI was closed.
    private static var diagBuffer: [String] = []
    private static let maxDiagEntries = 300
    private static let diagLock = NSLock()

    private static func addDiag(_ msg: String) {
        diagLock.lock()
        diagBuffer.append(msg)
        while diagBuffer.count > maxDiagEntries {
            diagBuffer.removeFirst()
        }
        diagLock.unlock()
    }

    private static func diagSnapshot() -> [String] {
        diagLock.lock()
        defer { diagLock.unlock() }
        return diagBuffer
    }

    /// Human-readable age of a timestamp, for the diagnostics snapshot.
    private static func ageDescription(_ date: Date?) -> String {
        guard let date = date else { return "never" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m\(seconds % 60)s ago"
    }

    /// Timestamped event log entry. Written to the OS log AND the ring
    /// buffer so it can be pulled into the Flutter console after a resume.
    ///
    /// Safe to call from any thread (the buffer is lock-protected).
    private func logEvent(_ msg: String) {
        let ts = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        let line = "\(ts) \(msg)"
        print("[MatchMeBG] \(line)")
        MatchMeBackgroundService.addDiag(line)
    }

    /// Runs a block on the main thread (immediately when already there).
    ///
    /// `CLLocationManager` and the shared service state must only be touched
    /// from the main thread. Several callbacks — the `NWPathMonitor` handler
    /// and `URLSession` completion handlers — arrive on background queues, so
    /// every mutation of that state funnels through here.
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

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
    private var lastHeartbeatSuccessAt: Date?
    private var lastHeartbeatPinnedActive: Bool?
    private var lastLocationUploadAt: Date?
    // Suppresses repeated network-failure lines in the diagnostics buffer.
    private var hasLoggedUploadFailure = false
    private var hasLoggedUploadSuccess = false
    private var hasLoggedHeartbeatFailure = false
    private var hasLoggedHeartbeatSuccess = false
    private var wasPinnedSkipping = false
    private var matchingTimer: Timer?
    private var lastMatchingLocation: CLLocation?
    private var lastMatchingSentAt: Date?
    private var recentMatchingLocations: [CLLocation] = []

    // Connectivity: iOS gets a native transport signal via NWPathMonitor so
    // the service can recover on its own after a network drop (Android gets
    // this from ConnectivityManager + a Supabase reachability probe).
    //
    // Starts as `false` so the FIRST satisfied path counts as a transition
    // and runs the recovery branch (otherwise a service that started while
    // offline would never pick the network up).
    private var pathMonitor: NWPathMonitor?
    private var networkAvailable = false

    // Permission issue raised by the native layer, surfaced to Dart via the
    // `consumePermissionIssue` channel call (parity with Android's
    // `recordPermissionIssue`).
    private var permissionIssueCode: String?

    // iOS shows the "Always" upgrade prompt at most once per install, so we
    // only ask once per process.
    private var didRequestAlwaysAuthorization = false

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
    // Persisted liveness timestamps: the diagnostics header must still show
    // how long ago the last heartbeat/upload succeeded after the process was
    // relaunched in the background (which is exactly the situation the
    // header exists to debug).
    private let kLastHeartbeatSuccessAt = "mm_last_heartbeat_success_at"
    private let kLastLocationUploadAt = "mm_last_location_upload_at"

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
    // Permission issue raised natively, consumed by Dart on resume.
    private let kPermissionIssue = "mm_permission_issue_code"

    /// True while a pinned home-base is active: no live GPS may be uploaded.
    private func isPinnedLocationActive() -> Bool {
        guard defaults.bool(forKey: kPinnedActive) else { return false }
        let expMs = defaults.object(forKey: kPinnedExpiresAtMs) as? Int
            ?? Int(defaults.double(forKey: kPinnedExpiresAtMs))
        guard expMs > 0 else { return false }
        return Int64(expMs) > Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Human-readable CLAuthorizationStatus for Dart and the diagnostics log.
    private func locationAuthorizationStatusString(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "whenInUse"
        @unknown default: return "unknown"
        }
    }

    /// Records a permission issue for Dart to surface (parity with Android's
    /// `recordPermissionIssue`). Dart reads it via `consumePermissionIssue`
    /// and shows the matching dialog with a deep link to system settings.
    private func recordPermissionIssue(_ code: String) {
        guard permissionIssueCode != code else { return }
        permissionIssueCode = code
        defaults.set(code, forKey: kPermissionIssue)
        logEvent("⚠️ Permission issue recorded: \(code)")
    }

    private func clearPermissionIssue(_ code: String) {
        // The issue can survive a process restart (it is persisted), so the
        // in-memory value alone is not enough to decide whether there is
        // anything to clear — otherwise the "Always location" dialog would
        // be shown on every single launch.
        let persisted = defaults.string(forKey: kPermissionIssue)
        guard permissionIssueCode == code || persisted == code else { return }
        permissionIssueCode = nil
        defaults.removeObject(forKey: kPermissionIssue)
        logEvent("✅ Permission issue cleared: \(code)")
    }

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        // Do NOT arm background updates here: `updateLocationTracking()` sets
        // this once authorization and the user's preferences are known.
        // Arming it at plugin-construction time (before Dart has said
        // anything) serves no purpose and only widens the window in which the
        // manager is configured for background delivery.
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false
        // Load saved state
        loadState()

        // Native connectivity signal. Android uses ConnectivityManager plus a
        // Supabase reachability probe; on iOS NWPathMonitor gives us the
        // transport state so the service can retry the moment the network
        // comes back instead of waiting for Dart (which is suspended in the
        // background and cannot deliver `setConnectivity`).
        startPathMonitor()

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

    // MARK: - Connectivity monitor

    /// Watches the OS network path so the service can self-heal after a
    /// network drop. When the path becomes satisfied we immediately retry the
    /// presence heartbeat and re-evaluate location tracking — this is the
    /// iOS equivalent of Android's `NetworkCallback.onAvailable` ->
    /// `refreshConnectivityFromProbe`.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let available = path.status == .satisfied
            // The handler runs on the monitor's own queue; the service state
            // and CLLocationManager must only be touched on the main thread.
            self.onMain { [weak self] in
                guard let self = self else { return }
                // A queued path update can arrive after the service was
                // stopped — do not resurrect it.
                guard self.userId != nil else { return }
                let wasAvailable = self.networkAvailable
                self.networkAvailable = available
                guard available != wasAvailable else { return }
                if available {
                    self.logEvent("📶 Network became available — resuming background uploads")
                    self.isOnline = true
                    self.updateLocationTracking()
                    self.performHeartbeat()
                } else {
                    self.logEvent("📶 Network lost — background uploads will retry when it returns")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.app.matchme.pathmonitor"))
        pathMonitor = monitor
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

        case "getDiagnostics":
            // Parity with Android's `getDiagnostics`: returns the in-memory
            // event log plus a liveness header, so the Flutter console can
            // show what the native layer did while the UI was closed.
            //
            // The staleness of the last successful heartbeat / location
            // upload is included because it is the single most useful number
            // when diagnosing "the user vanished from the admin counts".
            var snapshot = [
                // The heartbeat timer being armed means the service was
                // started and has not been stopped — NOT that the process is
                // currently running (iOS may have suspended it). Use the
                // heartbeat/upload ages below to judge liveness.
                "heartbeatTimerArmed=\(isServiceRunning())",
                "visible=\(isVisible)",
                "online=\(isOnline)",
                "appInForeground=\(appInForeground)",
                "authorization=\(locationAuthorizationStatusString(locationManager.authorizationStatus))",
                "lastHeartbeatSuccess=\(Self.ageDescription(lastHeartbeatSuccessAt))",
                "lastLocationUpload=\(Self.ageDescription(lastLocationUploadAt))",
                "networkAvailable=\(networkAvailable)",
                "pinned=\(isPinnedLocationActive())",
            ]
            snapshot.append(contentsOf: MatchMeBackgroundService.diagSnapshot())
            result(snapshot)

        case "updatePinnedState":
            // Parity with Android's `updatePinnedState`: the pinned flag is
            // read fresh from shared defaults, so we only need to re-evaluate
            // the foreground/GPS state.
            logEvent("updatePinnedState: pinned=\(isPinnedLocationActive()) (bgMatching=\(backgroundMatchingMode))")
            updateLocationTracking()
            result(true)

        case "consumePermissionIssue":
            // Parity with Android's `consumePermissionIssue`: read + clear.
            let code = permissionIssueCode ?? defaults.string(forKey: kPermissionIssue)
            permissionIssueCode = nil
            defaults.removeObject(forKey: kPermissionIssue)
            result(code)

        case "setPermissionIssue":
            guard let args = call.arguments as? [String: Any],
                  let code = args["code"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing code argument", details: nil))
                return
            }
            permissionIssueCode = code
            defaults.set(code, forKey: kPermissionIssue)
            result(true)

        case "getLocationAuthorizationStatus":
            // Lets Dart ask the native layer for the real CLAuthorizationStatus
            // instead of inferring it from geolocator's coarse mapping.
            result(locationAuthorizationStatusString(locationManager.authorizationStatus))

        case "updateVisibility":
            guard let args = call.arguments as? [String: Any],
                  let isVisible = args["isVisible"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing visibility argument", details: nil))
                return
            }

            self.isVisible = isVisible
            saveState()
            updateLocationTracking()
            // Keep the heartbeat alive regardless of visibility: the server
            // derives `user_activity.is_visible` from `users.user_visibility_setting`
            // itself, and a stopped heartbeat would drop the user out of the
            // online window within 61s of an invisible -> visible flip.
            if heartbeatTimer?.isValid != true && userId != nil {
                startHeartbeat()
            }
            result(true)

        case "setConnectivity":
            guard let args = call.arguments as? [String: Any],
                  let isOnline = args["isOnline"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing isOnline argument", details: nil))
                return
            }

            let changed = self.isOnline != isOnline
            self.isOnline = isOnline
            saveState()
            updateLocationTracking()

            // Parity with Android: the heartbeat coroutine keeps running while
            // offline (a failed request is harmless and the service recovers
            // by itself when the network returns). Only the location upload
            // path is affected by connectivity, and that is now best-effort.
            if heartbeatTimer?.isValid != true && userId != nil {
                startHeartbeat()
            }
            if changed {
                logEvent("📡 setConnectivity: isOnline=\(isOnline)")
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
            // Refresh presence the moment the UI goes away instead of waiting
            // for the next timer tick: the Dart-side heartbeat stops as soon
            // as the app is suspended, and the server drops a user from the
            // online/visible counts 61s after `last_activity`.
            if !isForeground {
                performHeartbeat()
            }
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
        if let date = lastHeartbeatSuccessAt {
            defaults.set(date.timeIntervalSince1970, forKey: kLastHeartbeatSuccessAt)
        } else {
            defaults.removeObject(forKey: kLastHeartbeatSuccessAt)
        }
        if let date = lastLocationUploadAt {
            defaults.set(date.timeIntervalSince1970, forKey: kLastLocationUploadAt)
        } else {
            defaults.removeObject(forKey: kLastLocationUploadAt)
        }
    }

    /// Persists a liveness timestamp, but at most once a minute so a 5 s
    /// upload cadence does not turn into a UserDefaults write every 5 s.
    /// The stored value is therefore accurate to within ~60 s, which is
    /// plenty for the `lastHeartbeatSuccess` / `lastLocationUpload` ages in
    /// the diagnostics header.
    private func persistLiveness(_ date: Date, forKey key: String) {
        let stored = defaults.double(forKey: key)
        if stored <= 0 || date.timeIntervalSince1970 - stored >= 60 {
            defaults.set(date.timeIntervalSince1970, forKey: key)
        }
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
        // Restore the persisted permission issue so it can be cleared again
        // (e.g. after the user grants "Always" in Settings) and so it is not
        // re-reported as a fresh transition on every launch.
        permissionIssueCode = defaults.string(forKey: kPermissionIssue)
        let heartbeatSuccess = defaults.double(forKey: kLastHeartbeatSuccessAt)
        if heartbeatSuccess > 0 {
            lastHeartbeatSuccessAt = Date(timeIntervalSince1970: heartbeatSuccess)
        }
        let locationUpload = defaults.double(forKey: kLastLocationUploadAt)
        if locationUpload > 0 {
            lastLocationUploadAt = Date(timeIntervalSince1970: locationUpload)
        }
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
        logEvent("▶️ Background service starting (visible=\(isVisible) online=\(isOnline) bgMatching=\(backgroundMatchingMode) auth=\(locationAuthorizationStatusString(locationManager.authorizationStatus)))")
        // (Re-)arm the connectivity monitor: it is cancelled when the service
        // stops so a stopped service cannot be resurrected by a network
        // transition.
        startPathMonitor()
        // Start heartbeat
        startHeartbeat()

        // Start location updates if visible
        updateLocationTracking()

        // Schedule background tasks
        scheduleBackgroundTasks()
    }

    private func stopBackgroundService() {
        stopHeartbeat()
        // Stop the connectivity monitor FIRST: a path update already queued on
        // the monitor queue would otherwise run after the service was stopped
        // and resurrect it.
        pathMonitor?.cancel()
        pathMonitor = nil
        // Reset the service state BEFORE tearing down the location/share
        // subsystems: those call `updateLocationTracking()`, which would
        // otherwise re-arm the GPS with the old state and upload one last
        // coordinate after the user asked to stop.
        self.userId = nil
        self.supabaseUrl = nil
        self.supabaseKey = nil
        self.userToken = nil
        self.isVisible = false
        self.isOnline = false
        self.lastHeartbeatSuccessAt = nil
        self.lastLocationUploadAt = nil
        self.hasLoggedHeartbeatSuccess = false
        self.hasLoggedHeartbeatFailure = false
        self.hasLoggedUploadFailure = false
        self.hasLoggedUploadSuccess = false
        saveState()

        stopMatchingTimer()
        stopLocationShareLoop()
        // Belt and braces: the share teardown re-evaluates the tracking
        // state, which can arm the matching timer again.
        stopMatchingTimer()
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        endBackgroundTask()
        BGTaskScheduler.shared.cancelAllTaskRequests()
        logEvent("⏹ Background service stopped")
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
            logEvent("📌 Pinned location ACTIVE — GPS paused, GPS not accessed for matching (heartbeat only)")
        } else if !pinned && wasPinnedSkipping {
            wasPinnedSkipping = false
            logEvent("▶️ Pinned location REMOVED/expired — GPS resumed")
        }

        // NOTE: `isOnline` is intentionally NOT part of this gate.
        //
        // Android keeps its foreground service alive and simply skips the
        // upload while offline, so the service recovers by itself when the
        // network returns. On iOS the equivalent recovery signal (Dart's
        // `setConnectivity`) cannot arrive while the app is suspended, so a
        // single failed Supabase probe used to stop GPS *and* the heartbeat
        // permanently — the user silently went offline and vanished from the
        // admin online/visible counts. Uploads are now best-effort: a failed
        // request simply retries on the next location fix.
        //
        // Presence parity with Android: the Android foreground service keeps
        // the presence heartbeat running for every logged-in user, visible or
        // not, and the WorkManager chain keeps it alive even when the
        // service is killed. On iOS the ONLY way to keep the process alive in
        // the background is continuous location updates (there is no
        // foreground service), so the location manager stays running for
        // every logged-in user (the service itself only runs while logged
        // in), even when they are invisible.
        //
        // Coordinates are a separate matter — see `sendLatestMatchingLocationIfDue`.
        let shouldTrack = (userId != nil && !pinned) || shareActive

        // "While Using the App" is NOT enough for iOS background location:
        // the OS suspends the app as soon as the UI closes, so no location
        // ever arrives and no presence heartbeat can be sent. This is the
        // iOS equivalent of Android's ACCESS_BACKGROUND_LOCATION check —
        // surface it to Dart so the user gets a dialog with a deep link to
        // Settings (iOS only ever shows the upgrade prompt once, so the
        // Settings deep link is the only recovery path).
        //
        // Only raised when Background Matching Mode is ON: a user who
        // explicitly turned background matching off does not need "Always",
        // and the dialog would otherwise reappear on every launch for every
        // user who chose "While Using" (the coordinator de-dupes per
        // process, not across launches).
        //
        // This check runs BEFORE the `shouldTrack` early return so a user who
        // granted "Always" in Settings always has the stale issue cleared.
        let authorizationStatus = locationManager.authorizationStatus
        if authorizationStatus == .authorizedAlways {
            clearPermissionIssue("location_always")
        } else if authorizationStatus == .authorizedWhenInUse && backgroundMatchingMode {
            // `recordPermissionIssue` only logs on transition, so this does
            // not spam the diagnostics buffer.
            recordPermissionIssue("location_always")
        } else if !backgroundMatchingMode {
            clearPermissionIssue("location_always")
        }

        if !shouldTrack {
            stopMatchingTimer()
            locationManager.stopUpdatingLocation()
            locationManager.allowsBackgroundLocationUpdates = false
            if pinned {
                // Pinned home-base: no continuous GPS and no coordinate
                // upload (the upload path is gated by the pin), but keep the
                // significant-change monitor registered.
                //
                // Be realistic about what this buys: significant-change
                // monitoring does NOT keep the process running. iOS relaunches
                // the app for significant location changes, so the heartbeat
                // only flows when such an event wakes us — a stationary
                // pinned user still falls out of the 61s presence window.
                // Android covers the same case continuously with its
                // WorkManager heartbeat chain; this is the closest iOS
                // equivalent without keeping a live GPS fix running against
                // the user's explicit "don't track me" choice.
                locationManager.startMonitoringSignificantLocationChanges()
            } else {
                locationManager.stopMonitoringSignificantLocationChanges()
            }
            return
        }

        if authorizationStatus == .restricted || authorizationStatus == .denied {
            stopMatchingTimer()
            locationManager.stopUpdatingLocation()
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.allowsBackgroundLocationUpdates = false
            if backgroundMatchingMode {
                recordPermissionIssue("location_always")
            }
            return
        }

        if authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
            return
        }

        let nativeMatchingActive = shouldUseNativeMatchingUpdates()
        if nativeMatchingActive || shareActive {
            if authorizationStatus == .authorizedWhenInUse {
                // iOS only ever shows the upgrade prompt once per install, so
                // ask at most once per process and rely on the Settings deep
                // link for the (very common) "user declined it" case.
                if !didRequestAlwaysAuthorization {
                    didRequestAlwaysAuthorization = true
                    locationManager.requestAlwaysAuthorization()
                }
            }
            locationManager.allowsBackgroundLocationUpdates = !appInForeground || shareActive
            // Only spend the battery on high accuracy when the position will
            // actually be uploaded (visible + Background Matching Mode on).
            // Otherwise the updates exist purely to keep the process alive
            // so the presence heartbeat can keep flowing.
            //
            // An active live-location share is always high accuracy: it is
            // per-match and explicitly consented, so it must not inherit the
            // Background Matching Mode toggle (Android keeps the share at
            // PRIORITY_HIGH_ACCURACY regardless of the mode).
            if (isVisible && backgroundMatchingMode) || shareActive {
                locationManager.desiredAccuracy = kCLLocationAccuracyBest
                locationManager.distanceFilter = kCLDistanceFilterNone
            } else {
                locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                locationManager.distanceFilter = kCLDistanceFilterNone
            }
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
        guard smartThrottlingEnabled, isVisible else { return }
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
        // Background Matching Mode gates the coordinate upload. On Android
        // the same switch stops the native GPS entirely
        // (MatchMeBackgroundService.kt: `if (!backgroundMatchingMode) { stopLocationUpdates() }`),
        // so on iOS it has to gate the upload as well — otherwise the
        // setting would do nothing at all on this platform, which is what
        // used to happen.
        //
        // The presence heartbeat is deliberately NOT gated by it: Android
        // keeps `update_user_activity` running regardless of the mode.
        guard shouldUseNativeMatchingUpdates(),
              isVisible,
              backgroundMatchingMode else {
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
        // NOTE: `isOnline` is deliberately not a gate here. The upload is
        // best-effort: a failed request simply retries on the next location
        // fix. Gating on a cached connectivity flag meant that one failed
        // Supabase probe could silently stop all background coordinates for
        // the rest of the session (iOS never receives the Dart-side
        // `setConnectivity(true)` while the app is suspended).
        //
        // `backgroundMatchingMode` gates the upload (see
        // `startMatchingTimer`): with Background Matching Mode off, the app
        // keeps the user "online" but stops transmitting their position.
        guard shouldUseNativeMatchingUpdates(),
              isVisible,
              backgroundMatchingMode,
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

    // Presence heartbeat.
    //
    // The server treats a user as online when `user_activity.last_activity`
    // is younger than 61 seconds (see `online_presence_user_ids` and
    // `is_user_truly_visible` in the Supabase migrations). Android keeps that
    // window alive with a foreground service plus a WorkManager chain; iOS
    // has neither, so the heartbeat has to be:
    //
    //   * driven by BOTH a timer and every incoming location fix, so it keeps
    //     running while the app is suspended (an app kept alive by the
    //     `location` background mode still receives location callbacks and
    //     runs its run loop), and
    //   * never stopped by a transient connectivity loss — Android's
    //     heartbeat coroutine keeps running when offline too, and a failed
    //     request is harmless.
    private static let heartbeatInterval: TimeInterval = 25.0

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: MatchMeBackgroundService.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            self.performHeartbeat()
        }
        performHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Sends the presence heartbeat (`update_user_activity` RPC).
    ///
    /// Refreshes the JWT and retries once on 401, matching Android's
    /// `executeWithFreshJwt` behaviour, so a rotated/expired token cannot
    /// silently turn the online heartbeat into a no-op for the session.
    ///
    /// The retry is limited to one attempt: a persistent 401/403 means the
    /// session itself is rejected (deleted user, revoked session), and
    /// retrying forever would hammer the endpoint.
    private func performHeartbeat(isAuthRetry: Bool = false) {
        guard let userId = userId,
              let supabaseUrl = supabaseUrl,
              let supabaseKey = supabaseKey else { return }

        lastHeartbeatTime = Date()

        // Pinned-state transition watcher. The pin is time-based, so this
        // catches a scheduled expiry (or a pin changed from another device)
        // while the UI is closed. Parity with Android's heartbeat watcher.
        let pinnedNow = isPinnedLocationActive()
        if let pinnedBefore = lastHeartbeatPinnedActive, pinnedBefore != pinnedNow {
            logEvent("📌 Pinned location transition (\(pinnedBefore) -> \(pinnedNow)) detected by heartbeat — re-evaluating GPS")
            onMain { [weak self] in
                self?.updateLocationTracking()
            }
        }
        lastHeartbeatPinnedActive = pinnedNow

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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                // Same reasoning as the location upload: only the first
                // failure of an outage goes into the ring buffer. The
                // latch is read and written on the main thread — the
                // completion runs on the URLSession queue.
                let message = error.localizedDescription
                self.onMain { [weak self] in
                    guard let self = self else { return }
                    if !self.hasLoggedHeartbeatFailure {
                        self.hasLoggedHeartbeatFailure = true
                        self.hasLoggedHeartbeatSuccess = false
                        self.logEvent("💓 Heartbeat failed: \(message)")
                    } else {
                        print("[MatchMeBG] 💓 Heartbeat failed: \(message)")
                    }
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else { return }
            if httpResponse.statusCode == 200 {
                self.onMain { [weak self] in
                    guard let self = self, self.userId != nil else { return }
                    let wasFailing = self.hasLoggedHeartbeatFailure
                    self.hasLoggedHeartbeatFailure = false
                    self.lastHeartbeatSuccessAt = Date()
                    self.isOnline = true
                    // Log the success once per service start / after a
                    // failure, never every 25 s (that would evict the
                    // interesting events from the 300-entry ring buffer).
                    if wasFailing || !self.hasLoggedHeartbeatSuccess {
                        self.hasLoggedHeartbeatSuccess = true
                        self.logEvent(
                            wasFailing
                                ? "💓 Heartbeat recovered — presence restored"
                                : "💓 Heartbeat OK — presence maintained"
                        )
                    }
                    if let successAt = self.lastHeartbeatSuccessAt {
                        self.persistLiveness(successAt, forKey: self.kLastHeartbeatSuccessAt)
                    }
                }
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // Token rotated/expired — refresh once and retry, exactly like
                // Android's `executeWithFreshJwt`.
                guard !isAuthRetry else {
                    self.logEvent("💓 Heartbeat still rejected after token refresh (\(httpResponse.statusCode))")
                    return
                }
                self.logEvent("💓 Heartbeat got \(httpResponse.statusCode) — refreshing token and retrying")
                self.refreshJwtToken { [weak self] refreshed in
                    guard refreshed, let self = self else { return }
                    // The refresh completion runs on the URLSession queue;
                    // the retry touches shared service state, so it has to
                    // hop back to the main thread.
                    self.onMain { self.performHeartbeat(isAuthRetry: true) }
                }
            } else {
                // A persistent 5xx repeats every heartbeat (25 s) and would
                // fill the ring buffer within a couple of hours, evicting the
                // events the buffer exists for. Latch it like the network
                // failures above (main-thread confined, as above).
                let status = httpResponse.statusCode
                self.onMain { [weak self] in
                    guard let self = self else { return }
                    if !self.hasLoggedHeartbeatFailure {
                        self.hasLoggedHeartbeatFailure = true
                        self.hasLoggedHeartbeatSuccess = false
                        self.logEvent("💓 Heartbeat failed with status: \(status)")
                    } else {
                        print("[MatchMeBG] 💓 Heartbeat failed with status: \(status)")
                    }
                }
            }
        }.resume()
    }

    private func scheduleBackgroundTasks() {
        // IMPORTANT (iOS reality check):
        //
        // BGTaskScheduler does NOT honour sub-minute intervals. `earliestBeginDate`
        // is a *request*; the OS decides when to run the task, typically many
        // minutes later and only when the device is idle/charging. These tasks
        // are therefore a BEST-EFFORT keep-alive, NOT the presence heartbeat.
        //
        // The presence heartbeat is driven by CLLocationManager callbacks
        // (see `locationManager(_:didUpdateLocations:)`), which DO keep
        // running while the app is suspended because the `location` background
        // mode keeps the process alive.
        let syncRequest = BGProcessingTaskRequest(identifier: "com.matchme.backgroundsync")
        syncRequest.requiresNetworkConnectivity = true
        syncRequest.requiresExternalPower = false
        syncRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30)

        let locationRequest = BGAppRefreshTaskRequest(identifier: "com.matchme.locationupdate")
        locationRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60)

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

        // Request a single location update.
        // BGTaskScheduler invokes the handler on a background queue, but
        // CLLocationManager must be driven from the main thread.
        onMain { [weak self] in
            self?.locationManager.requestLocation()
        }

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

        // Event-driven presence heartbeat.
        //
        // This is what keeps the user inside the 61-second online window
        // while the UI is closed: an app held alive by the `location`
        // background mode still receives location callbacks and runs its run
        // loop, so the heartbeat must be driven by the callbacks as well as
        // by the timer. The throttle is 25s (not 60s) so a single missed
        // tick cannot push `last_activity` past the server's window.
        //
        // Not gated on `isOnline`: a failed request is harmless, and the
        // heartbeat must keep trying so the user comes back online the
        // instant the network returns (parity with Android's heartbeat
        // coroutine, which also runs while offline).
        if let lastTime = lastHeartbeatTime {
            if Date().timeIntervalSince(lastTime) > MatchMeBackgroundService.heartbeatInterval {
                performHeartbeat()
            }
        } else {
            performHeartbeat()
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

    private func updateLocationInSupabase(location: CLLocation, isAuthRetry: Bool = false) {
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

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                // Network failures repeat every few seconds while the device
                // is offline. Logging each one floods the 300-entry ring
                // buffer and evicts the events we actually want to see, so
                // only the first failure of an outage is recorded. The latch
                // is main-thread confined: this completion runs on the
                // URLSession queue.
                let message = error.localizedDescription
                self.onMain { [weak self] in
                    guard let self = self else { return }
                    if !self.hasLoggedUploadFailure {
                        self.hasLoggedUploadFailure = true
                        self.hasLoggedUploadSuccess = false
                        self.logEvent("📍 Location update failed: \(message)")
                    } else {
                        print("[MatchMeBG] 📍 Location update failed: \(message)")
                    }
                }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else { return }
            if httpResponse.statusCode == 200 {
                let latitude = location.coordinate.latitude
                let longitude = location.coordinate.longitude
                self.onMain { [weak self] in
                    guard let self = self, self.userId != nil else { return }
                    let wasFailing = self.hasLoggedUploadFailure
                    self.hasLoggedUploadFailure = false
                    self.lastLocationUploadAt = Date()
                    self.isOnline = true
                    // Log the first success (or the recovery) instead of
                    // every fix: at a 5 s cadence, one line per upload would
                    // evict everything else from the 300-entry buffer.
                    if wasFailing {
                        self.hasLoggedUploadSuccess = true
                        self.logEvent("📍 Location upload recovered — coordinates flowing")
                    } else if !self.hasLoggedUploadSuccess {
                        self.hasLoggedUploadSuccess = true
                        self.logEvent("📍 Location uploaded: \(latitude), \(longitude)")
                    } else {
                        print("[MatchMeBG] 📍 Location uploaded: \(latitude), \(longitude)")
                    }
                    if let uploadedAt = self.lastLocationUploadAt {
                        self.persistLiveness(uploadedAt, forKey: self.kLastLocationUploadAt)
                    }
                }
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // Token rotated/expired — refresh once and retry, matching
                // Android's `executeWithFreshJwt`.
                guard !isAuthRetry else {
                    self.logEvent("📍 Location update still rejected after token refresh (\(httpResponse.statusCode))")
                    return
                }
                self.logEvent("📍 Location update got \(httpResponse.statusCode) — refreshing token and retrying")
                self.refreshJwtToken { [weak self] refreshed in
                    guard refreshed, let self = self else { return }
                    // The refresh completion runs on the URLSession queue;
                    // the retry touches shared service state, so it has to
                    // hop back to the main thread.
                    self.onMain {
                        self.updateLocationInSupabase(
                            location: location,
                            isAuthRetry: true
                        )
                    }
                }
            } else {
                // Latched like the network failures, so a persistent 5xx does
                // not flood the diagnostics ring buffer.
                let status = httpResponse.statusCode
                self.onMain { [weak self] in
                    guard let self = self else { return }
                    if !self.hasLoggedUploadFailure {
                        self.hasLoggedUploadFailure = true
                        self.hasLoggedUploadSuccess = false
                        self.logEvent("📍 Location update failed with status: \(status)")
                    } else {
                        print("[MatchMeBG] 📍 Location update failed with status: \(status)")
                    }
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
        logEvent("🌙 App entered background — handing GPS over to the native service")
        beginBackgroundTask()
        updateLocationTracking()
        // Refresh presence right now: the Dart-side heartbeat stops as soon
        // as the app is suspended, so the native side must own the window
        // from this point on.
        performHeartbeat()
    }

    private func enterForeground() {
        guard lifecycleIsBackgrounded != false else { return }
        lifecycleIsBackgrounded = false
        appInForeground = true
        logEvent("🌅 App entered foreground — native GPS handover released")
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

    /// Refreshes the Supabase JWT and hands the new token back to the caller.
    ///
    /// The whole routine runs on the main thread: it reads and writes shared
    /// state (`userToken`, `refreshToken`, `isRefreshing`) that the Dart-side
    /// `updateToken` handler and the heartbeat both touch, and it used to
    /// run on the URLSession queue — a data race that could let two
    /// concurrent 401 handlers both refresh, burning the refresh token
    /// ("refresh_token_already_used").
    private func refreshJwtToken(completion: @escaping (Bool) -> Void) {
        onMain { [weak self] in
            self?.performJwtRefresh(completion: completion)
        }
    }

    private func performJwtRefresh(completion: @escaping (Bool) -> Void) {
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
            // The response arrives on the URLSession queue: hop back to the
            // main thread before touching any shared state.
            self.onMain {
                self.handleJwtRefreshResponse(
                    data: data,
                    response: response,
                    error: error,
                    tokenToUse: tokenToUse,
                    completion: completion
                )
            }
        }.resume()
    }

    private func handleJwtRefreshResponse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        tokenToUse: String,
        completion: @escaping (Bool) -> Void
    ) {
        defer { isRefreshing = false }
        // Check for already_used race - if Dart refreshed concurrently, adopt its token
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyStr.contains("refresh_token_already_used") || bodyStr.contains("invalid_grant") || bodyStr.contains("refresh_token_not_found") {
                let latestAfter = defaults.string(forKey: kRefreshToken)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let latestAtAfter = defaults.string(forKey: kUserTokenKey) ?? defaults.string(forKey: kUserToken)
                if let la = latestAfter, !la.isEmpty, la != tokenToUse {
                    refreshToken = la
                    if let at = latestAtAfter, !at.isEmpty { userToken = at }
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

        userToken = newToken
        var newRefresh: String? = nil
        if let nr = json["refresh_token"] as? String, !nr.isEmpty {
            refreshToken = nr
            newRefresh = nr
        }
        // Persist so the Dart app and future restores use the fresh tokens.
        defaults.set(newToken, forKey: kUserTokenKey)
        defaults.set(newToken, forKey: kUserToken)
        if let nr = newRefresh {
            defaults.set(nr, forKey: kRefreshToken)
            defaults.set(nr, forKey: "flutter.refresh_token")
        } else if let rt = refreshToken {
            defaults.set(rt, forKey: "flutter.refresh_token")
        }
        saveState()
        syncTokensToDartStorage(newAccessToken: newToken, newRefreshToken: newRefresh, responseJson: json)
        completion(true)
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
