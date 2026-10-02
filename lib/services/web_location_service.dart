// lib/services/web_location_service.dart
import 'dart:async';
// Import web-specific functionality stub
import '../web_imports.dart' as html;
import 'package:geolocator/geolocator.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'location_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'gps_kalman_filter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/utils/permission_manager.dart';

String _ts() => DateTime.now().toIso8601String();

/// WebLocationService: visibility-aware, generation-protected timer to avoid
/// overlapping timers and duplicated sends when visibility or settings change.
class WebLocationService implements LocationService {
  /// Called after location is successfully synced to Supabase so the
  /// dashboard stats provider can clear its cache and re-fetch nearby count.
  static void Function()? onLocationSynced;

  Timer? _locationTimer;
  StreamSubscription<Position>?
  _positionStreamSubscription; // Continuous position stream (like Google Maps watchPosition)
  Position? _latestPosition; // Track latest position from stream
  bool _isStreaming = false;
  bool _isStarting = false; // Prevent concurrent start operations
  bool _isSending = false; // Prevent concurrent sends
  int? _htmlWatchId; // id returned by navigator.geolocation.watchPosition
  bool _htmlWatchActive = false;
  Completer<Position?>?
  _positionCompleter; // Prevent concurrent getCurrentPosition calls
  bool _isGettingPosition =
      false; // Synchronous flag to catch browser's duplicate callbacks
  bool _isGettingHighPrecisionPosition =
      false; // Prevent concurrent high precision position requests
  int _currentIntervalSeconds = 1; // Effective interval currently applied
  int _requestedIntervalSeconds = 1; // Last requested interval
  int _generation = 0; // Invalidate stale timers when incremented
  bool _smartThrottlingEnabled = false; // honor user's setting only when true
  void Function(dynamic)? _locationUpdateCallback;

  // Short-circuit cache: when all fallbacks in getCurrentPosition fail (e.g.
  // desktop Chrome without a GPS source) the call sequence can take ~1s and
  // emit ~6 log lines per attempt. If multiple consumers (ensureServiceStarted,
  // visibility resume, retries) all ask for a position within a few seconds
  // they would each repeat the entire sequence. Remember the last failed
  // attempt and return null immediately if asked again within [_failureCacheTtl].
  DateTime? _lastFailureAt;
  static const Duration _failureCacheTtl = Duration(seconds: 30);

  int _hiddenThrottleSeconds = 60;

  // GPS capability detection: after the first successful position, we record
  // whether the device appears to have GPS hardware.  Desktops without GPS
  // produce accuracy >500 m (IP/WiFi geolocation); phones with GPS produce
  // accuracy <50 m.  Once known, we skip the `enableHighAccuracy: true`
  // fallback chain on non-GPS devices — it always fails and wastes ~600 ms
  // + 6 log lines per attempt.
  bool?
  _hasGpsCapability; // null = unknown, true = GPS available, false = no GPS

  // Deduplication: when multiple callers ask for a position within this
  // window, the second caller receives the same Future instead of triggering
  // a new browser API call.  Previously the _isGettingPosition flag only
  // caught truly concurrent calls (microseconds apart); calls spaced 1–2 s
  // apart (e.g. ensureServiceStarted + NearbyMapScreen) each ran the full
  // 6-step fallback chain independently.
  DateTime? _lastPositionRequestAt;
  static const Duration _positionRequestDedupWindow = Duration(seconds: 10);

  GPSKalmanFilter? _kalmanFilter;

  Future<GPSKalmanFilter> _getKalmanFilter() async {
    if (_kalmanFilter != null) return _kalmanFilter!;
    try {
      final processNoisePosition = await appConfigService.getDouble(
        'gps.kalman_process_noise_position',
        defaultValue: 0.0001,
      );
      final processNoiseVelocity = await appConfigService.getDouble(
        'gps.kalman_process_noise_velocity',
        defaultValue: 0.001,
      );
      final minAccuracy = await appConfigService.getDouble(
        'gps.kalman_min_accuracy_meters',
        defaultValue: 5.0,
      );
      final maxAccuracy = await appConfigService.getDouble(
        'gps.kalman_max_accuracy_meters',
        defaultValue: 200.0,
      );
      _kalmanFilter = GPSKalmanFilter(
        processNoisePosition: processNoisePosition,
        processNoiseVelocity: processNoiseVelocity,
        minAccuracyMeters: minAccuracy,
        maxAccuracyMeters: maxAccuracy,
      );
    } catch (e) {
      _kalmanFilter = GPSKalmanFilter();
    }
    return _kalmanFilter!;
  }

  // Visibility state to prevent sending when invisible
  bool _isVisible = false;

  WebLocationService() {
    _registerVisibilityListeners();
  }

  @override
  void setSmartThrottlingEnabled(bool enabled) {
    _smartThrottlingEnabled = enabled;
    // _wlog('setSmartThrottlingEnabled: enabled=$enabled (isStreaming=$_isStreaming, requested=$_requestedIntervalSeconds, current=$_currentIntervalSeconds, gen=$_generation)');
    // Immediately apply current requested interval considering the new flag
    try {
      if (_isStreaming) {
        // If page is hidden and throttling is now disabled, restore requested interval
        final docState = html.document.visibilityState;
        final isHidden = docState == 'hidden';
        // _wlog('setSmartThrottlingEnabled: visibilityState=$docState isHidden=$isHidden');
        if (!isHidden) {
          _applyRequestedInterval();
        } else {
          // If hidden and throttling disabled, keep requested (no forced 60s)
          if (!_smartThrottlingEnabled) {
            _applyRequestedInterval();
          }
        }
      }
    } catch (e) {
      // Ignore
    }
  }

  void _registerVisibilityListeners() {
    try {
      html.document.addEventListener('visibilitychange', (ev) {
        final stateStr = html.document.visibilityState;
        final isHidden = stateStr == 'hidden';
        // _wlog('visibilitychange: state=$stateStr isHidden=$isHidden (smartThrottling=$_smartThrottlingEnabled, requested=$_requestedIntervalSeconds, current=$_currentIntervalSeconds, gen=$_generation)');
        if (isHidden) {
          _applyEffectiveIntervalWhenHidden();
        } else {
          _applyRequestedInterval();
        }
      });

      html.window.addEventListener('pagehide', (ev) {
        // _wlog('pagehide: applying hidden interval (smartThrottling=$_smartThrottlingEnabled)');
        _applyEffectiveIntervalWhenHidden();
      });

      html.window.addEventListener('pageshow', (ev) {
        // _wlog('pageshow: applying requested interval (requested=$_requestedIntervalSeconds)');
        _applyRequestedInterval();
      });
    } catch (e) {
      // Ignore
    }
  }

  @override
  Future<bool> handleLocationPermission() async {
    try {
      // On web, try the Permissions API first to check state without triggering
      // a prompt.  This avoids the "already getting position" re-entrance that
      // Geolocator.checkPermission() → Geolocator.requestPermission() can
      // cause when multiple callers stack up.
      try {
        final state = await html.window.navigator.permissions.queryState(
          'geolocation',
        );
        if (state == 'granted') return true;
        if (state == 'denied') {
          // Browser-level deny — user must change it in browser settings.
          return false;
        }
        // state == 'prompt' — permission hasn't been asked yet.  Fall
        // through to Geolocator which will trigger the browser prompt.
      } catch (_) {
        // Permissions API not supported or conversion failed — fall through.
      }

      LocationPermission permission = await Geolocator.checkPermission();

      // If permission is already granted, return true
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        return true;
      }

      // If permission is denied, check if we've already requested it this run
      if (permission == LocationPermission.denied) {
        if (PermissionManager.hasBeenRequestedThisRun('location')) {
          return false;
        }

        permission = await Geolocator.requestPermission();
        PermissionManager.markRequested('location');
      }

      final hasPermission =
          permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      return hasPermission;
    } catch (e) {
      return false;
    }
  }

  Position? _positionFromBrowserGeolocation(html.WebGeolocationPosition pos) {
    final coords = pos.coords;
    final lat = coords.latitude;
    final lon = coords.longitude;
    if (lat == null || lon == null) return null;

    final timestamp = pos.timestamp == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(pos.timestamp!);

    return Position(
      latitude: lat,
      longitude: lon,
      timestamp: timestamp,
      accuracy: coords.accuracy ?? double.infinity,
      altitude: coords.altitude ?? 0.0,
      altitudeAccuracy: coords.altitudeAccuracy ?? 0.0,
      heading: coords.heading ?? 0.0,
      headingAccuracy: coords.headingAccuracy ?? 0.0,
      speed: coords.speed ?? 0.0,
      speedAccuracy: coords.speedAccuracy ?? 0.0,
    );
  }

  Future<Position?> _getBrowserCurrentPosition({
    required bool enableHighAccuracy,
    Duration timeout = const Duration(seconds: 20),
    int maximumAge = 0,
  }) async {
    final completer = Completer<Position?>();
    try {
      html.window.navigator.geolocation.getCurrentPosition(
        (pos) {
          if (completer.isCompleted) return;
          completer.complete(_positionFromBrowserGeolocation(pos));
        },
        (code, message) {
          if (completer.isCompleted) return;
          completer.complete(null);
        },
        html.WebGeolocationOptions(
          enableHighAccuracy: enableHighAccuracy,
          maximumAge: maximumAge,
          timeout: timeout.inMilliseconds,
        ),
      );
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (!completer.isCompleted) completer.complete(null);
        return null;
      },
    );
  }

  /// One-shot watch: subscribes to navigator.geolocation.watchPosition and
  /// returns the first reading the browser produces, then unsubscribes. This
  /// is used as a final fallback when the synchronous getCurrentPosition
  /// chain keeps returning POSITION_UNAVAILABLE on desktop Chrome (where the
  /// Wi-Fi/IP geolocation pipeline may not be ready when the page loads).
  Future<Position?> _getBrowserWatchPosition({
    required bool enableHighAccuracy,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<Position?>();
    try {
      final geolocation = html.window.navigator.geolocation;
      final watchId = geolocation.watchPosition(
        (pos) {
          if (completer.isCompleted) return;
          completer.complete(_positionFromBrowserGeolocation(pos));
        },
        (code, message) {
          if (completer.isCompleted) return;
          completer.complete(null);
        },
        html.WebGeolocationOptions(
          enableHighAccuracy: enableHighAccuracy,
          maximumAge: 0,
          timeout: timeout.inMilliseconds,
        ),
      );
      completer.future.whenComplete(() {
        try {
          geolocation.clearWatch(watchId);
        } catch (_) {}
      });
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        if (!completer.isCompleted) completer.complete(null);
        return null;
      },
    );
  }

  /// Best-effort probe for whether the page is being served from a secure
  /// context. Geolocation requires a secure context on modern browsers; if
  /// the page is served over plain HTTP the API is allowed to exist but the
  /// browser will refuse to return a position. We log this once per call so
  /// misconfigured deployments are obvious in the log.
  bool _isSecureContext() {
    try {
      final dynamic win = html.window;
      final value = win.isSecureContext;
      return value == true;
    } catch (_) {
      return true;
    }
  }

  Future<Position?> getCurrentPosition() async {
    final now = DateTime.now();

    // Short-circuit 1: if the most recent lookup failed completely and another
    // consumer asks again within _failureCacheTtl, skip the full fallback
    // chain (which takes ~1s and emits ~6 log lines) and return null.
    if (_latestPosition == null &&
        _lastFailureAt != null &&
        now.difference(_lastFailureAt!) < _failureCacheTtl) {
      return null;
    }

    // Short-circuit 2: deduplication window.  When multiple callers (e.g.
    // ensureServiceStarted, NearbyMapScreen.refreshLocation, timer tick)
    // ask for a position within a few seconds, the second caller returns
    // the cached position instead of triggering a new browser API call.
    // This is the main fix for the "7 getCurrentPosition calls in 16 s"
    // problem.
    if (_lastPositionRequestAt != null &&
        now.difference(_lastPositionRequestAt!) < _positionRequestDedupWindow) {
      if (_latestPosition != null) return _latestPosition;
      // If a request is currently in progress, share its Future
      if (_positionCompleter != null && !_positionCompleter!.isCompleted) {
        return _positionCompleter!.future;
      }
    }

    // Double-check pattern: synchronous flag + async completer
    if (_isGettingPosition) {
      print(
        '[${_ts()}] 🌍 Web location service: getCurrentPosition - already getting position',
      );
      // Return last known position if available
      if (_latestPosition != null) return _latestPosition;
      try {
        final last = await Geolocator.getLastKnownPosition();
        print(
          '[${_ts()}] 🌍 Web location service: getCurrentPosition - lastKnown=${last != null}',
        );
        return last;
      } catch (e) {
        return null;
      }
    }

    // Set synchronous flag BEFORE creating completer
    _isGettingPosition = true;
    _lastPositionRequestAt = now;

    // Create a new completer for this request
    _positionCompleter = Completer<Position?>();

    Position? position;

    try {
      final hasPermission = await handleLocationPermission();
      final secureContext = _isSecureContext();
      print(
        '[${_ts()}] 🌍 Web location service: getCurrentPosition - hasPermission=$hasPermission isSecureContext=$secureContext gpsCapability=$_hasGpsCapability',
      );
      if (!hasPermission) {
        position = null;
      } else {
        // ── Adaptive fallback chain ──────────────────────────────────
        // On desktop Chrome without GPS hardware, `enableHighAccuracy: true`
        // always fails with POSITION_UNAVAILABLE.  Once we detect this (see
        // _updateGpsCapability), we skip the high-accuracy attempts entirely
        // and go straight to IP/WiFi geolocation (enableHighAccuracy: false),
        // saving ~600 ms + 6 log lines per call.

        final tryHighAccuracy =
            _hasGpsCapability != false; // true or null (unknown)

        if (tryHighAccuracy) {
          // Attempt 1: high accuracy (GPS).  On desktop without GPS this
          // returns POSITION_UNAVAILABLE in <10 ms.
          try {
            position = await _getBrowserCurrentPosition(
              enableHighAccuracy: true,
              timeout: const Duration(seconds: 25),
            );
            print(
              '[${_ts()}] 🌍 Web location service: getCurrentPosition - highAccuracy=${position != null}',
            );
          } catch (e) {
            print(
              '[${_ts()}] 🌍 Web location service: getCurrentPosition - highAccuracy exception: $e',
            );
          }
        } else {
          print(
            '[${_ts()}] 🌍 Web location service: getCurrentPosition - skipping enableHighAccuracy:true (no GPS hardware detected)',
          );
        }

        // If high accuracy failed (null/exception) or was skipped,
        // try fallbacks to ensure we can still get a position on desktop
        // Chrome which may not have GPS hardware.
        if (position == null) {
          // Yield once so the browser's network/wifi-geolocation pipeline
          // has a chance to produce a result.
          await Future.delayed(const Duration(milliseconds: 200));

          if (tryHighAccuracy) {
            print(
              '[${_ts()}] 🌍 Web location service: getCurrentPosition - high accuracy failed, trying fallbacks',
            );
          }

          // Fallback 2: use _latestPosition from continuous stream
          if (position == null && _latestPosition != null) {
            position = _latestPosition;
            print(
              '[${_ts()}] 🌍 Web location service: getCurrentPosition - using _latestPosition',
            );
          }

          // Fallback 3: low accuracy (IP/WiFi geolocation) — this is the
          // primary path on desktop without GPS.
          if (position == null) {
            try {
              position = await _getBrowserCurrentPosition(
                enableHighAccuracy: false,
                timeout: const Duration(seconds: 15),
                maximumAge: 300000, // 5 minutes
              );
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - lowAccuracy=${position != null}',
              );
            } catch (_) {
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - lowAccuracy exception',
              );
            }
          }

          // Fallback 4: last known position from Geolocator
          if (position == null) {
            try {
              position = await Geolocator.getLastKnownPosition();
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - lastKnown=${position != null}',
              );
            } catch (_) {
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - lastKnown exception',
              );
            }
          }

          // Fallback 5 (last resort): subscribe to the next position event
          // the browser produces (watchPosition).  Different from retrying
          // getCurrentPosition with a relaxed maxAge — on a browser with no
          // position source that would just time out again.  We cap at 3 s.
          if (position == null) {
            print(
              '[${_ts()}] 🌍 Web location service: getCurrentPosition - all fallbacks failed, waiting briefly for next browser position event',
            );
            await Future.delayed(const Duration(milliseconds: 500));
            try {
              position = await _getBrowserWatchPosition(
                enableHighAccuracy: false,
                timeout: const Duration(seconds: 3),
              );
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - watchFallback=${position != null}',
              );
            } catch (_) {
              print(
                '[${_ts()}] 🌍 Web location service: getCurrentPosition - watchFallback exception',
              );
            }
          }
        }
      }
    } catch (e) {
      print(
        '[${_ts()}] 🌍 Web location service: getCurrentPosition - outer exception: $e',
      );
      position = null;
    }

    if (position == null) {
      // Terminal log: makes it obvious in the log when the browser has no
      // usable location source (no GPS, no Wi-Fi geolocation, IP lookup
      // unavailable, or page served from an insecure context). This is
      // expected on desktop Chrome and is the dominant reason nearby=0
      // in the dashboard stats.
      print(
        '[${_ts()}] 🌍 Web location service: getCurrentPosition - returning null (no position source available; nearby stats will be 0)',
      );
    }

    // Record GPS capability from this position's accuracy so subsequent
    // calls can skip the high-accuracy chain on non-GPS devices.
    _updateGpsCapability(position);

    // Complete our completer safely
    if (_positionCompleter != null && !_positionCompleter!.isCompleted) {
      _positionCompleter!.complete(position);
    }

    // Record success/failure for the short-circuit cache. We treat "no
    // permission" as a terminal failure (the user can grant it later via
    // settings, which resets this via a successful watch). All other
    // fallbacks exhausting also counts as a failure.
    if (position == null) {
      _lastFailureAt = DateTime.now();
    } else {
      _lastFailureAt = null;
      _latestPosition = position;
    }

    // Update the deduplication timestamp so subsequent callers within the
    // window return the cached result instead of starting a new request.
    _lastPositionRequestAt = DateTime.now();

    _isGettingPosition = false;
    _positionCompleter = null;
    return position;
  }

  /// Infer whether the device has GPS hardware from the accuracy of a
  /// successful position fix.
  ///
  /// - accuracy < 50 m  → GPS (phone, tablet with GPS, laptop with BT GPS)
  /// - accuracy > 500 m → IP/WiFi geolocation only (desktop without GPS)
  ///
  /// Once known, we store the result in [_hasGpsCapability] so subsequent
  /// calls skip the `enableHighAccuracy: true` chain on non-GPS devices.
  void _updateGpsCapability(Position? position) {
    if (position == null) return;
    // Only set once per session — the device's hardware doesn't change.
    if (_hasGpsCapability != null) return;

    if (position.accuracy < 50) {
      _hasGpsCapability = true;
      print(
        '[${_ts()}] 🌍 Web location service: GPS capability detected = true (accuracy: ${position.accuracy.toStringAsFixed(0)}m)',
      );
    } else if (position.accuracy > 500) {
      _hasGpsCapability = false;
      print(
        '[${_ts()}] 🌍 Web location service: GPS capability detected = false (accuracy: ${position.accuracy.toStringAsFixed(0)}m — using IP/WiFi geolocation only)',
      );
    }
    // If accuracy is between 50–500 m, we don't know yet — leave as null.
  }

  /// Get high-precision location by taking multiple readings and averaging them.
  /// This significantly improves accuracy for saving location-based rules.
  /// Returns null if unable to get any readings.
  ///
  /// On devices without GPS (desktop Chrome), this is skipped entirely —
  /// averaging 5 IP/WiFi readings with ~1 km accuracy doesn't improve
  /// anything and just wastes 10+ seconds.
  Future<Position?> getHighPrecisionPosition({
    int sampleCount = 5,
    Duration sampleInterval = const Duration(seconds: 2),
    double maxAccuracyMeters = 50.0,
  }) async {
    if (_isGettingHighPrecisionPosition) {
      return null; // Prevent concurrent calls
    }

    // Skip entirely when we know there's no GPS — sampling IP-based
    // positions repeatedly doesn't improve accuracy.
    if (_hasGpsCapability == false) {
      print(
        '[${_ts()}] 🌍 Web location service: getHighPrecisionPosition - skipped (no GPS hardware)',
      );
      return _latestPosition;
    }

    _isGettingHighPrecisionPosition = true;
    try {
      final hasPermission = await handleLocationPermission();
      if (!hasPermission) return null;

      final allPositions = <Position>[];
      final goodPositions = <Position>[];

      for (int i = 0; i < sampleCount; i++) {
        try {
          // Use our protected getCurrentPosition method to avoid "Future already completed" errors
          // Add a delay before each call (except first) to ensure previous call completes
          if (i > 0) {
            await Future.delayed(sampleInterval);
          }

          final position = await getCurrentPosition().timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              // print('[${_ts()}] ⚠️ Web location service: Timeout getting position sample ${i + 1}/$sampleCount');
              return null;
            },
          );

          if (position != null) {
            allPositions.add(position);

            // Track readings with good accuracy
            if (position.accuracy <= maxAccuracyMeters) {
              goodPositions.add(position);
            }
          } else {
            // print('[${_ts()}] ⚠️ Web location service: Null position from sample ${i + 1}/$sampleCount');
          }
        } catch (e) {
          // Catch "Future already completed" and other errors
          // This is a known issue with geolocator_web package
          // print('[${_ts()}] ⚠️ Web location service: Error getting position sample ${i + 1}/$sampleCount: $e');
          // Continue to next sample - we'll use whatever samples we successfully collected
        }
      }

      if (allPositions.isEmpty) {
        return null;
      }

      // Use good readings if available, otherwise use best available readings
      final positionsToUse = goodPositions.isNotEmpty
          ? goodPositions
          : allPositions;

      if (goodPositions.isEmpty) {
        // Sort by accuracy to use the best readings available
        allPositions.sort((a, b) => a.accuracy.compareTo(b.accuracy));
      }

      // Average the coordinates from selected readings
      double sumLat = 0, sumLon = 0, sumAccuracy = 0;
      for (final p in positionsToUse) {
        sumLat += p.latitude;
        sumLon += p.longitude;
        sumAccuracy += p.accuracy;
      }
      final avgLat = sumLat / positionsToUse.length;
      final avgLon = sumLon / positionsToUse.length;
      final avgAccuracy = sumAccuracy / positionsToUse.length;

      // Return a position with averaged coordinates
      return Position(
        latitude: avgLat,
        longitude: avgLon,
        timestamp: DateTime.now(),
        accuracy: avgAccuracy,
        altitude: positionsToUse.first.altitude,
        altitudeAccuracy: positionsToUse.first.altitudeAccuracy,
        heading: positionsToUse.first.heading,
        headingAccuracy: positionsToUse.first.headingAccuracy,
        speed: positionsToUse.first.speed,
        speedAccuracy: positionsToUse.first.speedAccuracy,
      );
    } catch (e) {
      return null;
    } finally {
      _isGettingHighPrecisionPosition = false;
    }
  }

  // Single protected send that avoids overlap
  Future<void> _sendLocationUpdate() async {
    if (_isSending) {
      // _wlog('_sendLocationUpdate skipped: already sending');
      return;
    }
    _isSending = true;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        // _wlog('_sendLocationUpdate aborted: no current user');
        return;
      }

      final health = await getCurrentConnectivityHealth();
      if (!health.isOnline) {
        // print('[${_ts()}] 🌍 Web location service: Device is offline, skipping location update');
        return;
      }

      // Update user activity regardless of visibility status (like mobile does)
      print(
        '[${_ts()}] 🌍 Web location service: Updating user activity for ${user.id}',
      );
      await UserActivityService.instance.pingIfDue(
        user.id,
        source: 'web-location',
      );
      print(
        '[${_ts()}] 🌍 Web location service: User activity updated successfully',
      );

      // Do not send location updates if user is invisible
      // This prevents location tracking when user has disabled visibility
      if (!_isVisible) {
        print(
          '[${_ts()}] 🌍 Web location service: User is invisible (mode), skipping location update',
        );
        return;
      }

      // Pinned home-base: heartbeat already sent above; never access GPS
      // or overwrite the pin while it is active.
      if (await PinnedLocationGate.isActive()) {
        print(
          '[${_ts()}] 🌍 Web location service: Pinned location active, skipping GPS access and upload',
        );
        return;
      }

      // Safety re-check: hidden/throttled tabs can receive the realtime visibility
      // update after the timer already fired. Verify directly from DB before sending.
      try {
        final userId = user.id;
        final resp = await Supabase.instance.client
            .from('users')
            .select('user_visibility_setting, system_visibility_status')
            .eq('id', userId)
            .maybeSingle();
        final remoteManual = resp?['user_visibility_setting'] == true;
        final remoteSystem =
            (resp?['system_visibility_status'] as String?) ?? 'visible';
        if (!remoteManual || remoteSystem != 'visible') {
          print(
            '[${_ts()}] 🌍 Web location service: Visibility re-check shows invisible, aborting send',
          );
          return;
        }
      } catch (_) {}

      print(
        '[${_ts()}] 🌍 Web location service: About to send location update for visible user (tab: ${html.document.visibilityState})',
      );

      // Accuracy thresholds
      // Web browsers often have poor initial accuracy (IP geolocation, outdated WiFi databases)
      // Accept up to 1500m to allow matching to work, but prefer better accuracy
      final maxAcceptableAccuracyMeters = await (() async {
        try {
          return await appConfigService.getDouble(
            'gps.web_max_acceptable_accuracy_meters',
            defaultValue: 1500.0,
          );
        } catch (e) {
          // print('[${_ts()}] 🌍 Web location service: Error getting max acceptable accuracy config, using default: $e');
          return 1500.0;
        }
      })(); // Accept locations up to 1.5km (web browsers can be inaccurate)
      final preferredAccuracyMeters = await (() async {
        try {
          return await appConfigService.getDouble(
            'gps.web_preferred_accuracy_meters',
            defaultValue: 200.0,
          );
        } catch (e) {
          // print('[${_ts()}] 🌍 Web location service: Error getting preferred accuracy config, using default: $e');
          return 200.0;
        }
      })(); // Prefer locations better than 200m
      final kalmanFilterThresholdMeters = await (() async {
        try {
          return await appConfigService.getDouble(
            'gps.kalman_filter_skip_threshold_meters',
            defaultValue: 100.0,
          );
        } catch (e) {
          // print('[${_ts()}] 🌍 Web location service: Error getting Kalman filter threshold config, using default: $e');
          return 100.0;
        }
      })(); // Skip Kalman filter for very inaccurate readings

      Position? rawPosition;

      // Use latest position from continuous stream or last known if available
      if (_latestPosition != null) {
        rawPosition = _latestPosition;
        print(
          '[${_ts()}] 🌍 Web location service: Using _latestPosition (accuracy: ${rawPosition!.accuracy}m, streamActive: ${_positionStreamSubscription != null})',
        );
      } else if (_positionStreamSubscription != null && _isStreaming) {
        // Stream is active but hasn't emitted a position yet — wait briefly for it
        print(
          '[${_ts()}] 🌍 Web location service: Stream active but no position yet, waiting up to 5s',
        );
        for (int i = 0; i < 5; i++) {
          await Future.delayed(const Duration(seconds: 1));
          if (_latestPosition != null) {
            rawPosition = _latestPosition;
            print(
              '[${_ts()}] 🌍 Web location service: Got position from stream after ${i + 1}s wait',
            );
            break;
          }
        }
      }

      // Fallback to single getCurrentPosition if no position available yet
      if (rawPosition == null) {
        print(
          '[${_ts()}] 🌍 Web location service: No position available, using getCurrentPosition fallback',
        );
        try {
          // Try custom browser implementation first
          rawPosition = await getCurrentPosition().timeout(
            const Duration(seconds: 20),
          );

          // If custom fails, try Geolocator's default web implementation as a last resort
          if (rawPosition == null) {
            print(
              '[${_ts()}] 🌍 Web location service: Custom getCurrentPosition failed, trying Geolocator.getCurrentPosition',
            );
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
            rawPosition = await Geolocator.getCurrentPosition(
              locationSettings: LocationSettings(
                accuracy: LocationAccuracy.medium,
                timeLimit: mobileTimeLimit,
              ),
            );
          }
        } catch (e) {
          print(
            '[${_ts()}] ❌ Web location service: Location acquisition fallback failed: $e',
          );
        }
      }

      if (rawPosition == null) {
        print(
          '[${_ts()}] ❌ Web location service: Unable to get any position (latest=$_latestPosition, sub=${_positionStreamSubscription != null}, streaming=$_isStreaming)',
        );
        return;
      }

      // Promote nullable rawPosition to a local non-nullable variable to satisfy
      // analyzer (avoid losing promotion across awaits).
      Position currentRaw = rawPosition;

      // print('[${_ts()}] 🌍 Web location service: Got position: ${currentRaw.latitude}, ${currentRaw.longitude}, accuracy: ${currentRaw.accuracy}m');

      // If accuracy is worse than preferred, attempt a short high-precision sampling
      // to try to match what Google Maps does (continuous watch + refined fixes).
      if (currentRaw.accuracy > preferredAccuracyMeters) {
        try {
          // print('[${_ts()}] 🌍 Web location service: Accuracy ${currentRaw.accuracy}m worse than preferred ${preferredAccuracyMeters}m — attempting high-precision sampling');
          final high = await getHighPrecisionPosition(
            sampleCount: 5,
            sampleInterval: await (() async {
              try {
                return await appConfigService.getDuration(
                  'performance.web_location_sample_interval_seconds',
                  defaultValue: const Duration(seconds: 2),
                );
              } catch (e) {
                return const Duration(seconds: 2);
              }
            })(),
            maxAccuracyMeters: preferredAccuracyMeters,
          ).timeout(const Duration(seconds: 20), onTimeout: () => null);

          if (high != null && high.accuracy <= currentRaw.accuracy) {
            // print('[${_ts()}] 🌍 Web location service: Using high-precision sampled position (accuracy ${high.accuracy}m)');
            currentRaw = high;
          } else {
            // print('[${_ts()}] 🌍 Web location service: High-precision sampling did not improve accuracy');
          }
        } catch (e) {
          // print('[${_ts()}] ⚠️ Web location service: High-precision sampling failed: $e');
        }
      }

      // Warn about poor accuracy but accept it (web browsers can be very inaccurate)
      if (currentRaw.accuracy > preferredAccuracyMeters) {
        if (currentRaw.accuracy > maxAcceptableAccuracyMeters) {
          // print('[${_ts()}] ⚠️ Web location service: Very poor accuracy (${currentRaw.accuracy.toStringAsFixed(0)}m) but accepting to allow matching. Consider moving to a location with better WiFi/GPS signal.');
        } else {
          // print('[${_ts()}] ⚠️ Web location service: Moderate accuracy (${currentRaw.accuracy.toStringAsFixed(0)}m). Web browsers often have limited location accuracy compared to mobile GPS.');
        }
      }

      // Accept the location regardless of accuracy (web browsers are inherently less accurate)
      // The matching algorithm can handle moderate inaccuracies

      // Apply Kalman filter only for reasonably accurate readings
      // Skip filter for very inaccurate readings to avoid introducing drift
      Position finalPosition;
      if (currentRaw.accuracy <= kalmanFilterThresholdMeters) {
        // Use Kalman filter for better smoothing of accurate readings
        // On web, Position objects may be LegacyJavaScriptObject instances, which can cause type casting errors
        try {
          finalPosition = (await _getKalmanFilter()).filter(currentRaw);
          // print('[${_ts()}] 🌍 Web location service: Filtered position: ${finalPosition.latitude}, ${finalPosition.longitude}, accuracy: ${finalPosition.accuracy}m (raw accuracy: ${currentRaw.accuracy}m)');
        } catch (e) {
          // If Kalman filter fails (e.g., LegacyJavaScriptObject type error on web), use raw position
          // print('[${_ts()}] 🌍 Web location service: Kalman filter failed, using raw position: $e');
          finalPosition = currentRaw;
        }
      } else {
        // For very inaccurate readings, use raw position to avoid filter drift
        finalPosition = currentRaw;
        // print('[${_ts()}] 🌍 Web location service: Using raw position (accuracy too poor for Kalman filter): ${finalPosition.latitude}, ${finalPosition.longitude}, accuracy: ${finalPosition.accuracy}m');
      }

      // Use final position for callback
      // Deferred to next microtask to prevent re-entrant frame scheduling
      // in Flutter web (Assertion failed: window.dart:99:12).
      if (_locationUpdateCallback != null) {
        final cb = _locationUpdateCallback;
        final pos = finalPosition;
        Timer.run(() {
          try {
            cb!(pos);
          } catch (cbErr) {
            // Ignore
          }
        });
      }

      // Save location to local database AND sync directly to Supabase
      try {
        final localDb = LocalDbService();
        await localDb.saveCurrentLocation(
          user.id,
          finalPosition.latitude,
          finalPosition.longitude,
          speed: finalPosition.speed,
          heading: finalPosition.heading,
          timestamp: finalPosition.timestamp,
        );

        // Also sync directly to Supabase for web platform
        await _syncLocationToSupabase(
          user.id,
          finalPosition.latitude,
          finalPosition.longitude,
          finalPosition.speed,
          finalPosition.heading,
        );

        print(
          '[${_ts()}] 📍 Location saved to local DB and synced to Supabase (accuracy: ${finalPosition.accuracy}m)',
        );

        // Notify listeners that location was synced so nearby count can be
        // re-fetched (the realtime subscription filters own-user changes).
        onLocationSynced?.call();
      } catch (e) {
        // print('[${_ts()}] ❌ Failed to save/sync location: $e');
      }

      // Match engine is now handled server-side autonomously
      // No client-side triggering needed - matches are created by Supabase functions
      // print('[${_ts()}] 📍 Location updated - server-side matching will be triggered automatically');
    } finally {
      _isSending = false;
    }
  }

  // Start stream with requested interval; effective interval respects visibility and setting
  @override
  Future<void> startLocationStream(int intervalSeconds) async {
    // print('[${_ts()}] 🌍 Web location service: startLocationStream called with interval $intervalSeconds');
    if (_isStarting) {
      // print('[${_ts()}] 🌍 Web location service: Already starting, returning');
      return;
    }

    _requestedIntervalSeconds = intervalSeconds;

    try {
      if (_hiddenThrottleSeconds == 60) {
        try {
          final val = await appConfigService.getInt(
            'gps.web_hidden_throttle_seconds',
            defaultValue: 60,
          );
          _hiddenThrottleSeconds = val;
        } catch (_) {}
      }
      final docState = html.document.visibilityState;
      final isHidden = docState == 'hidden';

      final effectiveInterval = (_smartThrottlingEnabled && isHidden)
          ? (intervalSeconds < _hiddenThrottleSeconds
                ? _hiddenThrottleSeconds
                : intervalSeconds)
          : intervalSeconds;
      // _wlog('startLocationStream: visibilityState=$docState isHidden=$isHidden smartThrottling=$_smartThrottlingEnabled requested=$intervalSeconds effective=$effectiveInterval (current=$_currentIntervalSeconds, isStreaming=$_isStreaming, gen=$_generation)');

      // If already streaming with same effective interval, do nothing (no callback fire, no restart)
      if (_isStreaming && _currentIntervalSeconds == effectiveInterval) {
        // _wlog('startLocationStream: no-op (already streaming at effective interval)');
        return; // Early return - no callback, no restart, no state change
      }

      _isStarting = true; // Set flag only after confirming we need to proceed

      // stop previous timer and bump generation to invalidate stale timers
      _stopInternal(); // synchronous stop

      // start streaming with new generation
      _generation++;
      final gen = _generation;
      _isStreaming = true;
      _currentIntervalSeconds = effectiveInterval;
      // _wlog('startLocationStream: started streaming (gen=$gen, current=$_currentIntervalSeconds)');

      // Use continuous position stream (like Google Maps watchPosition) for better accuracy
      // This allows location to refine over time as GPS/WiFi acquires better signal
      // print('[${_ts()}] 🌍 Web location service: Starting continuous position stream (Google Maps approach)');
      final hasPermission = await handleLocationPermission();
      if (hasPermission) {
        try {
          // Start position stream with best accuracy
          // This continuously monitors position and allows it to refine over time
          bool firstPosition = true;
          _positionStreamSubscription =
              Geolocator.getPositionStream(
                locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.best,
                  distanceFilter:
                      0, // Update on any movement (let browser decide when to update)
                ),
              ).listen(
                (Position position) {
                  // Store latest position from stream
                  _latestPosition = position;
                  // print('[${_ts()}] 🌍 Web location service: Position stream update: ${position.latitude}, ${position.longitude}, accuracy: ${position.accuracy}m');

                  // Trigger immediate send on first position from a new stream
                  // Deferred to prevent re-entrant frame scheduling.
                  if (firstPosition) {
                    firstPosition = false;
                    Timer.run(() => _sendLocationUpdate());
                  }

                  // Call callback when position updates (deferred to next microtask)
                  if (_locationUpdateCallback != null) {
                    final cb = _locationUpdateCallback;
                    final pos = position;
                    Timer.run(() {
                      try {
                        cb!(pos);
                      } catch (e) {
                        // Ignore callback errors
                      }
                    });
                  }
                },
                onError: (error) {
                  // print('[${_ts()}] ⚠️ Web location service: Position stream error: $error');
                },
                cancelOnError: false, // Keep stream alive even on errors
              );
        } catch (e) {
          // print('[${_ts()}] ⚠️ Web location service: Failed to start position stream: $e, falling back to timer-based updates');
          _positionStreamSubscription = null;
        }
        // If Geolocator web stream couldn't be started or is unreliable on some browsers,
        // start a direct `navigator.geolocation.watchPosition` with enableHighAccuracy:true
        // — this more closely matches Google Maps' approach.
        if (_positionStreamSubscription == null) {
          try {
            final watchId = html.window.navigator.geolocation.watchPosition(
              (pos) {
                try {
                  final coords = pos.coords;
                  final p = Position(
                    latitude: coords.latitude ?? 0.0,
                    longitude: coords.longitude ?? 0.0,
                    timestamp: DateTime.now(),
                    accuracy: coords.accuracy ?? double.infinity,
                    altitude: coords.altitude ?? 0.0,
                    altitudeAccuracy: coords.altitudeAccuracy ?? 0.0,
                    heading: coords.heading ?? 0.0,
                    headingAccuracy: coords.headingAccuracy ?? 0.0,
                    speed: coords.speed ?? 0.0,
                    speedAccuracy: coords.speedAccuracy ?? 0.0,
                  );
                  _latestPosition = p;
                  // print('[${_ts()}] 🌍 Web location service: HTML watchPosition update: ${p.latitude}, ${p.longitude}, accuracy: ${p.accuracy}m');
                  if (_locationUpdateCallback != null) {
                    final cb = _locationUpdateCallback;
                    final pos = p;
                    Timer.run(() {
                      try {
                        cb!(pos);
                      } catch (_) {}
                    });
                  }
                } catch (e) {
                  // print('[${_ts()}] ⚠️ Web location service: Error processing HTML watchPosition update: $e');
                }
              },
              (code, message) {
                // print('[${_ts()}] ⚠️ Web location service: HTML watchPosition error: $code $message');
              },
              const html.WebGeolocationOptions(
                enableHighAccuracy: true,
                maximumAge: 0,
                timeout: 10000,
              ),
            );
            _htmlWatchId = watchId;
            _htmlWatchActive = true;
            // print('[${_ts()}] 🌍 Web location service: Started HTML watchPosition (id: $_htmlWatchId)');
          } catch (e) {
            // print('[${_ts()}] ⚠️ Web location service: Could not start HTML watchPosition: $e');
            _htmlWatchActive = false;
            _htmlWatchId = null;
          }
        }
      }

      // Also use timer to periodically send updates to Supabase (even with stream running)
      // The stream provides continuous refinement, timer controls update frequency
      _locationTimer = Timer.periodic(
        Duration(seconds: _currentIntervalSeconds),
        (timer) async {
          // _wlog('timer tick (gen=$gen, currentGen=$_generation, interval=$_currentIntervalSeconds, isStreaming=$_isStreaming, isVisible=$_isVisible)');
          // If this timer is stale, cancel quietly and return
          if (gen != _generation) {
            try {
              timer.cancel();
            } catch (_) {}
            return;
          }
          if (!_isStreaming) {
            try {
              timer.cancel();
            } catch (_) {}
            return;
          }
          // Use latest position from stream if available, otherwise get new one
          await _sendLocationUpdate();
        },
      );

      // Send initial update
      await _sendLocationUpdate();
    } catch (e) {
      _isStreaming = false;
      _locationTimer?.cancel();
      _locationTimer = null;
    } finally {
      _isStarting = false;
    }
  }

  void _applyRequestedInterval() {
    try {
      final docState = html.document.visibilityState;
      final isHidden = docState == 'hidden';
      final effectiveInterval = (_smartThrottlingEnabled && isHidden)
          ? (_requestedIntervalSeconds < _hiddenThrottleSeconds
                ? _hiddenThrottleSeconds
                : _requestedIntervalSeconds)
          : _requestedIntervalSeconds;
      // _wlog('_applyRequestedInterval: visibilityState=$docState isHidden=$isHidden smartThrottling=$_smartThrottlingEnabled requested=$_requestedIntervalSeconds effective=$effectiveInterval (isStreaming=$_isStreaming, current=$_currentIntervalSeconds, gen=$_generation)');

      if (!_isStreaming) {
        _currentIntervalSeconds = effectiveInterval;
        // _wlog('_applyRequestedInterval: not streaming; updated current interval to $_currentIntervalSeconds');
        return;
      }

      if (_currentIntervalSeconds == effectiveInterval) {
        // _wlog('_applyRequestedInterval: no-op (interval unchanged)');
        return;
      }

      _generation++;
      _currentIntervalSeconds = effectiveInterval;
      _stopInternal();
      // start a fresh timer for the new effective value (keep streaming true)
      _isStreaming = true;
      final gen = _generation;
      // print('[${_ts()}] 🌍 Web location service: Starting timer with interval $_currentIntervalSeconds s');
      _locationTimer = Timer.periodic(Duration(seconds: _currentIntervalSeconds), (
        timer,
      ) async {
        if (gen != _generation) {
          // print('[${_ts()}] 🌍 Web location service: Timer generation changed, cancelling');
          try {
            timer.cancel();
          } catch (_) {}
          return;
        }
        if (!_isStreaming) {
          // print('[${_ts()}] 🌍 Web location service: Streaming stopped, cancelling timer');
          try {
            timer.cancel();
          } catch (_) {}
          return;
        }
        // print('[${_ts()}] 🌍 Web location service: Timer fired, calling _sendLocationUpdate');
        await _sendLocationUpdate();
      });
    } catch (e) {
      // Ignore
    }
  }

  void _applyEffectiveIntervalWhenHidden() {
    try {
      if (!_smartThrottlingEnabled) {
        // _wlog('_applyEffectiveIntervalWhenHidden: smart throttling disabled; no-op');
        return;
      }

      final hiddenInterval = _requestedIntervalSeconds < _hiddenThrottleSeconds
          ? _hiddenThrottleSeconds
          : _requestedIntervalSeconds;
      // _wlog('_applyEffectiveIntervalWhenHidden: requested=$_requestedIntervalSeconds hiddenInterval=$hiddenInterval (isStreaming=$_isStreaming, current=$_currentIntervalSeconds, gen=$_generation)');

      if (!_isStreaming) {
        _currentIntervalSeconds = hiddenInterval;
        // _wlog('_applyEffectiveIntervalWhenHidden: not streaming; updated current interval to $_currentIntervalSeconds');
        return;
      }

      if (_currentIntervalSeconds == hiddenInterval) {
        // _wlog('_applyEffectiveIntervalWhenHidden: no-op (interval unchanged)');
        return;
      }

      _generation++;
      _currentIntervalSeconds = hiddenInterval;
      _stopInternal();
      _isStreaming = true;
      final gen = _generation;
      _locationTimer = Timer.periodic(
        Duration(seconds: _currentIntervalSeconds),
        (timer) async {
          // _wlog('hidden timer tick (gen=$gen, currentGen=$_generation, interval=$_currentIntervalSeconds, isStreaming=$_isStreaming, isVisible=$_isVisible)');
          if (gen != _generation) {
            try {
              timer.cancel();
            } catch (_) {}
            return;
          }
          if (!_isStreaming) {
            try {
              timer.cancel();
            } catch (_) {}
            return;
          }
          await _sendLocationUpdate();
        },
      );
    } catch (e) {
      // Ignore
    }
  }

  // Stop immediately and bump generation to invalidate previous timers
  void _stopInternal() {
    _generation++;
    // _wlog('_stopInternal: stopping (newGen=$_generation, hadTimer=${_locationTimer != null}, htmlWatchActive=$_htmlWatchActive)');
    if (_locationTimer != null) {
      try {
        _locationTimer!.cancel();
      } catch (_) {}
      _locationTimer = null;
    }
    _isStreaming = false;
    _isSending = false;
    // Stop HTML watch if active
    try {
      if (_htmlWatchActive && _htmlWatchId != null) {
        try {
          html.window.navigator.geolocation.clearWatch(_htmlWatchId!);
        } catch (_) {}
        _htmlWatchActive = false;
        _htmlWatchId = null;
        // print('[${_ts()}] 🌍 Web location service: Cleared HTML watchPosition');
      }
    } catch (e) {
      // Ignore errors while clearing watch
    }
  }

  @override
  void stopLocationStream({bool keepLiveStream = false}) {
    // _wlog('stopLocationStream called');
    _isStarting = false;
    _stopInternal();
    // Reset Kalman filter for fresh start next time
    _kalmanFilter?.reset();
    // Ensure position stream is stopped
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    // PRESERVE _latestPosition across restarts so the next send doesn't
    // start with a 5-second gap. The new stream will overwrite it when it
    // emits its first position (typically < 1s).
  }

  // Map live-stream API is mobile-only: the web service already runs a
  // continuous browser position stream, so currentLocationProvider updates
  // at browser rate without any extra surface-specific stream.
  @override
  Future<bool> startMapLiveStream() async {
    return false;
  }

  @override
  void stopMapLiveStream() {}

  @override
  void setLocationUpdateCallback(void Function(dynamic)? callback) {
    _locationUpdateCallback = callback;
    // _wlog('setLocationUpdateCallback: ${callback == null ? 'null' : 'set'}');
  }

  @override
  void setVisibility(bool isVisible) {
    _isVisible = isVisible;
    // _wlog('setVisibility: isVisible=$_isVisible');
  }

  @override
  bool get isGpsTimerRunning => _isStreaming;

  /// Sync location data directly to Supabase (web platform workaround)
  Future<void> _syncLocationToSupabase(
    String userId,
    double latitude,
    double longitude,
    double? speed,
    double? heading,
  ) async {
    try {
      print('[${_ts()}] 🔄 Syncing location to Supabase');

      // 1. Try the update_user_location RPC function first (optimized for matching)
      try {
        await Supabase.instance.client.rpc(
          'update_user_location',
          params: {
            'p_user_id': userId,
            'p_latitude': latitude,
            'p_longitude': longitude,
            'p_speed': speed,
            'p_heading': heading,
          },
        );
        print('[${_ts()}] ✅ Location synced to Supabase successfully via RPC');
        return;
      } catch (rpcError) {
        print(
          '[${_ts()}] ⚠️ RPC location sync failed, trying direct upsert: $rpcError',
        );
      }

      // 2. Fallback: Direct upsert to user_locations table
      await Supabase.instance.client.from('user_locations').upsert({
        'user_id': userId,
        'latitude': latitude,
        'longitude': longitude,
        'speed': speed,
        'heading': heading,
        'updated_at': DateTime.now().toIso8601String(),
      });

      print(
        '[${_ts()}] ✅ Location synced to Supabase successfully via direct upsert',
      );
    } catch (e) {
      print('[${_ts()}] ❌ All location sync methods failed: $e');
      // Continue anyway - local DB still has the data for later sync
    }
  }
}
