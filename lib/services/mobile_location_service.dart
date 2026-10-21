// lib/services/mobile_location_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'location_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/utils/permission_manager.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/windows_location_channel.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/offline_trail_service.dart';

final supabase = Supabase.instance.client;

class MobileLocationService implements LocationService {
  Timer? _positionUpdateTimer;
  bool _isServiceRunning = false;
  bool _isStarting = false;
  bool _isSending = false;
  bool _isVisible = true;
  void Function(dynamic)? _locationUpdateCallback;
  int _currentIntervalSeconds = 0;
  int _consecutiveGpsTimeouts = 0;
  DateTime? _lastGpsErrorLogAt;
  // Pinned home-base: while a pin is active there is no GPS timer at all.
  // Presence is kept by a slow, silent heartbeat instead (no GPS access, no
  // per-tick wakeups or logs). _heartbeatMode tracks which mode is running
  // so unpin transitions restart GPS even when the interval is unchanged.
  Timer? _heartbeatTimer;
  bool _heartbeatMode = false;

  // Live map stream: a continuous getPositionStream owned by a foreground UI
  // surface (Nearby map). While it runs, the GPS chip is already producing
  // fixes, so the interval timer stops issuing its own one-shot requests and
  // just transmits the latest streamed fix at the configured interval. The
  // stream itself never transmits — that stays on the timer's cadence.
  StreamSubscription<Position>? _liveStreamSub;
  Position? _latestLiveFix;
  DateTime? _latestLiveFixAt;
  DateTime? _lastLiveIngestAt;
  DateTime? _lastLiveErrorLogAt;
  static const Duration _liveFixStaleness = Duration(seconds: 90);

  /// Slow heartbeat cadence while pinned. Well inside the server's online
  /// window, negligible battery cost, zero GPS access.
  static const Duration _pinnedHeartbeatInterval = Duration(seconds: 60);

  MobileLocationService();

  @override
  void setSmartThrottlingEnabled(bool enabled) {
    // Mobile stream uses platform LocationSettings; throttling decisions are made by caller (VisibilityNotifier).
    // No-op for mobile implementation.
  }

  Future<void> _fetchAndSendLocation(Position position) async {
    print(
      '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] _fetchAndSendLocation entered',
    );
    final user = supabase.auth.currentUser;
    print(
      '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] user=${user?.id ?? 'null'}',
    );
    if (user == null) {
      print(
        '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] No user, stopping stream',
      );
      stopLocationStream();
      return;
    }

    // Unreachable in practice (the GPS timer never runs while pinned and
    // the pin check below guards the rest), kept as a silent backstop.
    if (await PinnedLocationGate.isActive()) {
      return;
    }

    final health = await getCurrentConnectivityHealth();
    print(
      '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] online=${health.isOnline}',
    );
    if (!health.isOnline) {
      // Offline: keep the place locally for retroactive matching (if opted in),
      // then return without touching Supabase. GPS itself works without internet.
      try {
        await OfflineTrailService.instance.recordOfflinePosition(
          user.id,
          position,
        );
      } catch (_) {}
      return;
    }

    // Online-count heartbeat. Must run even when the user is invisible: the
    // online count counts all logged-in users regardless of visibility, and
    // once GPS is stopped for an invisible user there is no other recurring
    // client heartbeat. Sending it before the visibility gate also covers the
    // race where visibility flips off while a position is already in flight —
    // the last position would otherwise stop the stream without ever pinging.
    final skipCalls = shouldSkipSupabaseCalls();
    final canReachSupabase = skipCalls
        ? (await getCurrentConnectivityHealth()).isOnline
        : true;
    print(
      '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] skipCalls=$skipCalls canReachSupabase=$canReachSupabase',
    );
    if (canReachSupabase) {
      try {
        await UserActivityService.instance.pingIfDue(
          user.id,
          source: 'location-update',
        );
        print(
          '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] pingIfDue success',
        );
      } catch (e) {
        print(
          '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] pingIfDue failed: $e',
        );
      }
    }

    if (!_isVisible) {
      // Stop the stream as a safety measure
      print(
        '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] User not visible, stopping stream',
      );
      stopLocationStream();
      return;
    }

    // Location updates are handled by the background service
    // Match engine is now handled server-side autonomously
    // No client-side triggering needed - matches are created by Supabase functions

    try {
      final localDb = LocalDbService();
      await localDb.saveCurrentLocation(
        user.id,
        position.latitude,
        position.longitude,
        speed: position.speed,
        heading: position.heading,
        timestamp: position.timestamp,
      );
      print(
        '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] saved to local DB',
      );

      // Also sync directly to Supabase (mobile platform workaround)
      // Fall back to direct connectivity check so location keeps uploading
      // even when OfflineCacheManager says Supabase is unavailable.
      if (canReachSupabase) {
        print(
          '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] calling _syncLocationToSupabase',
        );
        await _syncLocationToSupabase(
          user.id,
          position.latitude,
          position.longitude,
          position.speed,
          position.heading,
        );
        print(
          '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] _syncLocationToSupabase returned',
        );
      } else {
        print(
          '[${DateTime.now().toIso8601String()}] ⏸️ [MobileLoc] Skipped Supabase sync (canReachSupabase=false)',
        );
      }
    } catch (e) {
      print(
        '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] Location save/sync error: $e',
      );
    }
    print(
      '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] _fetchAndSendLocation complete',
    );
  }

  Future<void> _requestAndSendCurrentPosition() async {
    if (_isSending || !_isServiceRunning || !_isVisible) {
      return;
    }

    // Silent backstop: the GPS timer never runs while pinned (heartbeat
    // mode instead), but a pin set mid-flight could still land here. Never
    // power the GPS chip for a pinned user.
    if (await PinnedLocationGate.isActive()) {
      return;
    }

    _isSending = true;
    try {
      // Live-stream mode: the map's continuous stream owns the GPS chip and
      // already pushed every fix to the UI callback. Just transmit its
      // latest fix — no second GPS request, no cold-start delay. If the
      // stream died or went quiet (no fix within the staleness window),
      // fall back to a one-shot so transmission keeps working.
      Position? position;
      var usedLiveFix = false;
      if (_liveStreamSub != null) {
        final fix = _latestLiveFix;
        final at = _latestLiveFixAt;
        if (fix != null &&
            at != null &&
            DateTime.now().difference(at) < _liveFixStaleness) {
          position = fix;
          usedLiveFix = true;
        }
      }
      if (position == null) {
        final mobileTimeLimit = await (() async {
          try {
            return await appConfigService.getDuration(
              'gps.mobile_time_limit_seconds',
              defaultValue: const Duration(seconds: 15),
            );
          } catch (e) {
            return const Duration(seconds: 15);
          }
        })();
        position = await WindowsLocationChannel.getPosition(
          accuracy: LocationAccuracy.best,
          timeLimit: mobileTimeLimit,
        );
        if (position == null) {
          throw TimeoutException('No position available');
        }
      }
      _consecutiveGpsTimeouts = 0;
      print(
        '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] Got position (${usedLiveFix ? 'live-stream' : 'one-shot'}): ${position.latitude}, ${position.longitude}, accuracy: ${position.accuracy}m',
      );
      // Live fixes were already delivered to the callback by the stream;
      // re-invoking it would double-count them in the throttling history.
      if (!usedLiveFix) {
        _locationUpdateCallback?.call(position);
      }
      await _fetchAndSendLocation(position);
    } catch (e) {
      _consecutiveGpsTimeouts += 1;
      // Indoors / no GPS fix: best-accuracy one-shot routinely hits the
      // 15s timeLimit every tick. Fall back to the last known position so
      // the stream still produces data instead of error-spamming forever.
      final lower = e.toString().toLowerCase();
      final isTimeout = e is TimeoutException || lower.contains('timeout');
      if (isTimeout) {
        try {
          final last = await WindowsLocationChannel.getLastKnownPosition();
          if (last != null && _isServiceRunning && _isVisible) {
            print(
              '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] GPS timeout — using last known position',
            );
            _locationUpdateCallback?.call(last);
            await _fetchAndSendLocation(last);
            return;
          }
        } catch (_) {}
      }
      // Throttle error logs: first failure + at most every 2 minutes, with
      // the consecutive count so field logs stay useful without spamming
      // every 20s tick (see release incident: 8x TimeoutException in a row).
      final now = DateTime.now();
      final shouldLog =
          _lastGpsErrorLogAt == null ||
          now.difference(_lastGpsErrorLogAt!) >= const Duration(minutes: 2);
      if (shouldLog) {
        _lastGpsErrorLogAt = now;
        print(
          '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] Timer tick error (x$_consecutiveGpsTimeouts): $e',
        );
      }
    } finally {
      _isSending = false;
    }
  }

  /// Best-effort escalation from "While Using the App" to "Always" on iOS.
  ///
  /// iOS only ever presents the "Allow While Using / Change to Always"
  /// upgrade prompt ONCE per install. If the user declines it there, the OS
  /// will never ask again and the only recovery path is the Settings app —
  /// which is why PermissionCoordinator shows a deep link when this fails.
  ///
  /// Safe to call repeatedly: `requestAlwaysAuthorization` is a no-op once
  /// the prompt has been used up, and it never throws.
  Future<void> _requestIosAlwaysAuthorizationIfNeeded() async {
    try {
      // iOS refuses to show the "Always" upgrade prompt before "While Using"
      // has been granted (permission_handler raises
      // MISSING_WHENINUSE_PERMISSION). Ask for the foreground permission
      // only if the app already has it — the normal foreground flow is
      // responsible for the very first prompt.
      final whenInUse = await Permission.locationWhenInUse.status;
      if (!whenInUse.isGranted) return;

      final current = await WindowsLocationChannel.checkPermission();
      if (current != LocationPermission.whileInUse) return;

      final status = await Permission.locationAlways.request();
      if (status.isGranted || status.isLimited) {
        print('[MobileLoc] iOS background location: "Always" granted');
      } else {
        print(
          '[MobileLoc] iOS background location: "Always" not granted — '
          'background location needs Settings > Privacy > Location > Always',
        );
        // Let the native layer know so it can flag the issue for the UI.
        await BackgroundService.setNativePermissionIssueCode('location_always');
      }
    } catch (e) {
      print('[MobileLoc] iOS background location permission error: $e');
    }
  }

  @override
  Future<bool> handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await WindowsLocationChannel.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    permission = await WindowsLocationChannel.checkPermission();

    // For iOS we need "Always" authorization for background location.
    //
    // This MUST run before the early return below. It used to sit at the
    // bottom of this method, behind `if (permission == whileInUse) return true`,
    // which made it unreachable on every launch after the first: iOS only
    // offers the "Allow While Using / Change to Always" upgrade prompt once
    // per install, so a user who picked "While Using" was stuck with
    // `authorizedWhenInUse` forever — the OS then suspends the app as soon as
    // the UI closes and no background location ever arrives.
    //
    // The upgrade request itself is best-effort: iOS silently ignores it if
    // it has already shown the prompt. The recovery path for those users is
    // the Settings deep link surfaced by PermissionCoordinator.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _requestIosAlwaysAuthorizationIfNeeded();
    }

    // If permission is already granted, return true
    if (permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always) {
      return true;
    }

    // If permission was denied forever, return false
    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    // If permission is denied, check if we've already requested it this run
    // If so, don't request again (respects "request once per run" requirement)
    if (permission == LocationPermission.denied) {
      if (PermissionManager.hasBeenRequestedThisRun('location')) {
        return false;
      }

      // Request permission (PermissionManager will track this)
      permission = await WindowsLocationChannel.requestPermission();
      PermissionManager.markRequested('location');

      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    // For iOS, we need always authorization for background location sharing.
    // (The upgrade attempt itself now happens at the top of this method via
    // `_requestIosAlwaysAuthorizationIfNeeded`, before the early return for an
    // already-granted permission. This second call covers the fresh-install
    // flow, where "While Using" was only just granted above and iOS will
    // now show the one-time "Change to Always" prompt.)
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _requestIosAlwaysAuthorizationIfNeeded();
    }

    // For Android 10+ (API 29+), we also need background location permission
    // for the background service to work
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        // Check if we have background location permission
        final bgPermission = await WindowsLocationChannel.checkPermission();
        if (bgPermission != LocationPermission.always &&
            bgPermission != LocationPermission.whileInUse) {
          // Background location permission not granted - background GPS may not work
          // Don't request background location here - it's handled by PermissionCoordinator when needed
        }
      } catch (e) {
        // Silently ignore background location permission check errors
      }
    }

    return true;
  }

  @override
  Future<void> startLocationStream(int intervalSeconds) async {
    // Never start GPS without an authenticated user
    if (supabase.auth.currentUser == null) {
      print(
        '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] Cannot start — no authenticated user',
      );
      return;
    }

    // Pinned home-base parks GPS entirely: no GPS timer, no per-tick
    // wakeups, no log spam — just a slow silent heartbeat that keeps
    // online presence. Checked first so a parked stream can never
    // short-circuit the resume path below on stale interval state.
    if (PinnedLocationGate.isActiveCached ||
        await PinnedLocationGate.isActive()) {
      _enterHeartbeatMode();
      return;
    }
    if (_heartbeatMode) {
      // Resuming from parked mode: drop heartbeat state so the GPS path
      // below starts fresh even when the requested interval is unchanged.
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _heartbeatMode = false;
      _isServiceRunning = false;
      _currentIntervalSeconds = 0;
      print(
        '[${DateTime.now().toIso8601String()}] ▶️ [MobileLoc] GPS resumed after pin',
      );
    }
    if (_isStarting) {
      return;
    }
    _isStarting = true;

    try {
      if (_isServiceRunning && _currentIntervalSeconds == intervalSeconds) {
        return;
      }

      if (_isServiceRunning && _currentIntervalSeconds != intervalSeconds) {
        stopLocationStream(keepLiveStream: true);
        final restartDelayMs = await (() async {
          try {
            return await appConfigService.getInt(
              'performance.mobile_location_restart_delay_ms',
              defaultValue: 200,
            );
          } catch (e) {
            return 200;
          }
        })();
        await Future.delayed(Duration(milliseconds: restartDelayMs));
      }

      final hasPermission = await handleLocationPermission();
      if (!hasPermission) {
        return;
      }

      // Check if location services are enabled
      final serviceEnabled = await WindowsLocationChannel.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return;
      }

      // Re-check the pin after the slow permission/system checks above: a
      // pin set in that window must park instead of starting GPS.
      if (PinnedLocationGate.isActiveCached ||
          await PinnedLocationGate.isActive()) {
        _enterHeartbeatMode();
        return;
      }

      // Use one-shot GPS reads so the location indicator only appears when a
      // location request is actually made at the configured interval.
      _positionUpdateTimer?.cancel();
      print(
        '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] Timer created: interval=$intervalSeconds',
      );
      _isServiceRunning = true;
      _currentIntervalSeconds = intervalSeconds;

      unawaited(_requestAndSendCurrentPosition());

      _positionUpdateTimer = Timer.periodic(Duration(seconds: intervalSeconds), (
        timer,
      ) {
        print(
          '[${DateTime.now().toIso8601String()}] 📍 [MobileLoc] Timer tick: interval=$intervalSeconds',
        );
        unawaited(_requestAndSendCurrentPosition());
      });
    } catch (e) {
      _isServiceRunning = false;
    } finally {
      _isStarting = false;
    }
  }

  /// Parks GPS for a pinned home-base: cancels any GPS timer and ensures a
  /// slow, silent heartbeat instead. Idempotent — repeated calls (e.g. from
  /// stream re-evaluations while still pinned) only log the transition once
  /// and never recreate timers.
  void _enterHeartbeatMode() {
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _stopLiveStream();
    final firstPark = !_heartbeatMode;
    _heartbeatMode = true;
    _isServiceRunning = true;
    _heartbeatTimer ??= Timer.periodic(_pinnedHeartbeatInterval, (_) {
      unawaited(_sendPinnedHeartbeat());
    });
    if (firstPark) {
      print(
        '[${DateTime.now().toIso8601String()}] 📌 [MobileLoc] GPS parked for pinned location — heartbeat every ${_pinnedHeartbeatInterval.inSeconds}s, no GPS access',
      );
    }
  }

  /// Presence-only ping while parked. Silent by design (no per-tick logs);
  /// failures surface through pingIfDue's own error log.
  Future<void> _sendPinnedHeartbeat() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;
      // Pin gone but heartbeat still scheduled (e.g. unpin raced the
      // re-eval): do nothing — the resume path restarts GPS.
      if (!PinnedLocationGate.isActiveCached &&
          !await PinnedLocationGate.isActive()) {
        return;
      }
      await UserActivityService.instance.pingIfDue(
        user.id,
        source: 'location-update-pinned',
      );
    } catch (_) {}
  }

  @override
  void stopLocationStream({bool keepLiveStream = false}) {
    final hadWork =
        _isServiceRunning || _heartbeatMode || _liveStreamSub != null;
    if (!hadWork) {
      return;
    }
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _heartbeatMode = false;
    _isSending = false;
    _isServiceRunning = false;
    _currentIntervalSeconds = 0;
    _consecutiveGpsTimeouts = 0;
    _lastGpsErrorLogAt = null;
    // Full stop (invisible, offline, logout, app backgrounded without
    // background matching) kills the live map stream too. Internal timer
    // restarts (interval changes) keep it running — the stream is owned by
    // the map screen and survives timer churn.
    if (!keepLiveStream) {
      _stopLiveStream();
    }
  }

  /// Internal: cancel the live stream and drop its cached fix.
  void _stopLiveStream() {
    _liveStreamSub?.cancel();
    _liveStreamSub = null;
    _latestLiveFix = null;
    _latestLiveFixAt = null;
    _lastLiveIngestAt = null;
  }

  /// Platform-tuned settings for the live map stream. The generic
  /// [LocationSettings] carries no time interval, and geolocator's Android
  /// implementation then defaults the native interval to 5000 ms — while
  /// driving, the map would move in one 5-second jump. Android therefore
  /// gets an explicit 1 s interval; iOS paces itself via accuracy and
  /// distanceFilter (no interval knob). Runs only while a map screen is in
  /// the foreground, so the higher cadence is bounded by screen-on time.
  static LocationSettings _liveMapStreamSettings() {
    if (kIsWeb) {
      return const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
          intervalDuration: const Duration(milliseconds: 1000),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
        );
      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
        );
    }
  }

  @override
  Future<bool> startMapLiveStream() async {
    if (supabase.auth.currentUser == null) {
      return false;
    }
    // Pinned home-base: never power the GPS hardware, same as the timer.
    if (PinnedLocationGate.isActiveCached ||
        await PinnedLocationGate.isActive()) {
      return false;
    }
    final hasPermission = await handleLocationPermission();
    if (!hasPermission) {
      return false;
    }
    final serviceEnabled = await WindowsLocationChannel.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }
    if (_liveStreamSub != null) {
      return true;
    }
    print(
      '[${DateTime.now().toIso8601String()}] 📡 [MobileLoc] Live map stream starting (platform settings, ~1Hz fixes, distanceFilter=5m) — timer will transmit latest fix',
    );
    _liveStreamSub =
        Geolocator.getPositionStream(
          locationSettings: _liveMapStreamSettings(),
        ).listen(
          (position) {
            _latestLiveFix = position;
            _latestLiveFixAt = DateTime.now();
            // Push to the UI (map marker/camera + local cache) at most ~2Hz;
            // high-speed movement can produce fixes far more often than the UI
            // needs. Transmission is unaffected: the timer reads _latestLiveFix.
            final now = DateTime.now();
            if (_lastLiveIngestAt != null &&
                now.difference(_lastLiveIngestAt!) <
                    const Duration(milliseconds: 500)) {
              return;
            }
            _lastLiveIngestAt = now;
            _locationUpdateCallback?.call(position);
          },
          onError: (Object e) {
            // Transient stream errors are logged (throttled) but the subscription
            // is kept: if it truly died, _latestLiveFixAt goes stale and the timer
            // falls back to one-shot GPS on its own.
            final now = DateTime.now();
            if (_lastLiveErrorLogAt == null ||
                now.difference(_lastLiveErrorLogAt!) >=
                    const Duration(minutes: 2)) {
              _lastLiveErrorLogAt = now;
              print(
                '[${DateTime.now().toIso8601String()}] ❌ [MobileLoc] Live map stream error: $e',
              );
            }
          },
        );
    return true;
  }

  @override
  void stopMapLiveStream() {
    if (_liveStreamSub == null) {
      return;
    }
    _stopLiveStream();
    print(
      '[${DateTime.now().toIso8601String()}] 📡 [MobileLoc] Live map stream stopped — timer resumes one-shot GPS',
    );
  }

  @override
  void setLocationUpdateCallback(void Function(dynamic)? callback) {
    _locationUpdateCallback = callback;
  }

  @override
  void setVisibility(bool isVisible) {
    _isVisible = isVisible;
  }

  /// True only while the GPS polling timer exists. Heartbeat-only parked
  /// mode reports false so interval bookkeeping restarts GPS on unpin
  /// instead of assuming it is already running.
  @override
  bool get isGpsTimerRunning => _positionUpdateTimer != null;

  /// Sync location data directly to Supabase (mobile platform workaround)
  /// The caller (_fetchAndSendLocation) decides whether Supabase is reachable,
  /// so this method no longer blocks on OfflineCacheManager state.
  Future<void> _syncLocationToSupabase(
    String userId,
    double latitude,
    double longitude,
    double? speed,
    double? heading,
  ) async {
    try {
      // Use the update_user_location RPC function
      await supabase.rpc(
        'update_user_location',
        params: {
          'p_user_id': userId,
          'p_latitude': latitude,
          'p_longitude': longitude,
          'p_speed': speed,
          'p_heading': heading,
        },
      );
    } catch (e) {
      // Continue anyway - local DB still has the data for later sync
    }
  }
}
