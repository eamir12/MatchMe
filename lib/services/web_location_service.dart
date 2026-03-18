// lib/services/web_location_service.dart
import 'dart:async';
// Import web-specific functionality stub
import '../web_imports.dart' as html;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'location_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'gps_kalman_filter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/permission_manager.dart';

String _ts() => DateTime.now().toIso8601String();
void _wlog(String message) => debugPrint('[${_ts()}] 🌍 Web location service: $message');

/// WebLocationService: visibility-aware, generation-protected timer to avoid
/// overlapping timers and duplicated sends when visibility or settings change.
class WebLocationService implements LocationService {
  Timer? _locationTimer;
  StreamSubscription<Position>? _positionStreamSubscription; // Continuous position stream (like Google Maps watchPosition)
  Position? _latestPosition; // Track latest position from stream
  bool _isStreaming = false;
  bool _isStarting = false; // Prevent concurrent start operations
  bool _isSending = false; // Prevent concurrent sends
  int? _htmlWatchId; // id returned by navigator.geolocation.watchPosition
  bool _htmlWatchActive = false;
  Completer<Position?>? _positionCompleter; // Prevent concurrent getCurrentPosition calls
  bool _isGettingPosition = false; // Synchronous flag to catch browser's duplicate callbacks
  bool _isGettingHighPrecisionPosition = false; // Prevent concurrent high precision position requests
  int _currentIntervalSeconds = 1; // Effective interval currently applied
  int _requestedIntervalSeconds = 1; // Last requested interval
  int _generation = 0; // Invalidate stale timers when incremented
  bool _smartThrottlingEnabled = false; // honor user's setting only when true
  void Function(dynamic)? _locationUpdateCallback;
  
  // Kalman filter for smooth GPS tracking
  final GPSKalmanFilter _kalmanFilter = GPSKalmanFilter();

  // Visibility state to prevent sending when invisible
  bool _isVisible = false;

  WebLocationService() {
    _wlog('constructed');
    _registerVisibilityListeners();
  }

  @override
  void setSmartThrottlingEnabled(bool enabled) {
    _smartThrottlingEnabled = enabled;
    _wlog('setSmartThrottlingEnabled: enabled=$enabled (isStreaming=$_isStreaming, requested=$_requestedIntervalSeconds, current=$_currentIntervalSeconds, gen=$_generation)');
    // Immediately apply current requested interval considering the new flag
    try {
      if (_isStreaming) {
        // If page is hidden and throttling is now disabled, restore requested interval
        final docState = html.document.visibilityState;
        final isHidden = docState == 'hidden';
        _wlog('setSmartThrottlingEnabled: visibilityState=$docState isHidden=$isHidden');
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
        _wlog('visibilitychange: state=$stateStr isHidden=$isHidden (smartThrottling=$_smartThrottlingEnabled, requested=$_requestedIntervalSeconds, current=$_currentIntervalSeconds, gen=$_generation)');
        if (isHidden) {
          _applyEffectiveIntervalWhenHidden();
        } else {
          _applyRequestedInterval();
        }
      });

      html.window.addEventListener('pagehide', (ev) {
        _wlog('pagehide: applying hidden interval (smartThrottling=$_smartThrottlingEnabled)');
        _applyEffectiveIntervalWhenHidden();
      });

      html.window.addEventListener('pageshow', (ev) {
        _wlog('pageshow: applying requested interval (requested=$_requestedIntervalSeconds)');
        _applyRequestedInterval();
      });
    } catch (e) {
      // Ignore
    }
  }

  @override
  Future<bool> handleLocationPermission() async {
    try {
      debugPrint('[${_ts()}] 🌍 Web location service: Checking location permission');
      LocationPermission permission = await Geolocator.checkPermission();
      debugPrint('[${_ts()}] 🌍 Web location service: Current permission: $permission');

      // If permission is already granted, return true
      if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
        return true;
      }

      // If permission is denied, check if we've already requested it this run
      if (permission == LocationPermission.denied) {
        if (PermissionManager.hasBeenRequestedThisRun('location')) {
          debugPrint('[${_ts()}] 🌍 Web location service: Location permission already requested this run, not requesting again');
          return false;
        }
        
        debugPrint('[${_ts()}] 🌍 Web location service: Permission denied, requesting permission');
        permission = await Geolocator.requestPermission();
        PermissionManager.markRequested('location');
        debugPrint('[${_ts()}] 🌍 Web location service: Permission after request: $permission');
      }

      final hasPermission = permission == LocationPermission.whileInUse || permission == LocationPermission.always;
      debugPrint('[${_ts()}] 🌍 Web location service: Final permission result: $hasPermission');
      return hasPermission;
    } catch (e) {
      return false;
    }
  }

  double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return null;
  }

  int? _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  Position? _positionFromBrowserGeolocation(dynamic pos) {
    try {
      final coords = pos?.coords;
      final lat = _toDouble(coords?.latitude);
      final lon = _toDouble(coords?.longitude);
      if (lat == null || lon == null) return null;

      final accuracy = _toDouble(coords?.accuracy) ?? double.infinity;
      final altitude = _toDouble(coords?.altitude) ?? 0.0;
      final altitudeAccuracy = _toDouble(coords?.altitudeAccuracy) ?? 0.0;
      final heading = _toDouble(coords?.heading) ?? 0.0;
      final headingAccuracy = _toDouble(coords?.headingAccuracy) ?? 0.0;
      final speed = _toDouble(coords?.speed) ?? 0.0;
      final speedAccuracy = _toDouble(coords?.speedAccuracy) ?? 0.0;

      DateTime timestamp = DateTime.now();
      final tsMs = _toInt(pos?.timestamp);
      if (tsMs != null) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(tsMs);
      }

      return Position(
        latitude: lat,
        longitude: lon,
        timestamp: timestamp,
        accuracy: accuracy,
        altitude: altitude,
        altitudeAccuracy: altitudeAccuracy,
        heading: heading,
        headingAccuracy: headingAccuracy,
        speed: speed,
        speedAccuracy: speedAccuracy,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Position?> _getBrowserCurrentPosition({
    required bool enableHighAccuracy,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final completer = Completer<Position?>();
    try {
      final geolocation = (html.window as dynamic).navigator?.geolocation;
      if (geolocation == null) {
        completer.complete(null);
      } else {
        geolocation.getCurrentPosition(
          (pos) {
            if (completer.isCompleted) return;
            completer.complete(_positionFromBrowserGeolocation(pos));
          },
          (err) {
            if (completer.isCompleted) return;
            completer.complete(null);
          },
          {
            'enableHighAccuracy': enableHighAccuracy,
            'maximumAge': 0,
            'timeout': timeout.inMilliseconds,
          },
        );
      }
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

  Future<Position?> getCurrentPosition() async {
    // Double-check pattern: synchronous flag + async completer
    if (_isGettingPosition) {
      // Return last known position if available
      if (_latestPosition != null) return _latestPosition;
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (e) {
        return null;
      }
    }

    // If there's already a pending request, return that Future instead of creating a new one
    if (_positionCompleter != null && !_positionCompleter!.isCompleted) {
      return _positionCompleter!.future;
    }

    // Set synchronous flag BEFORE creating completer
    _isGettingPosition = true;

    // Create a new completer for this request
    _positionCompleter = Completer<Position?>();

    Position? position;

    try {
      final hasPermission = await handleLocationPermission();
      if (!hasPermission) {
        position = null;
      } else {
        try {
          position = await _getBrowserCurrentPosition(
            enableHighAccuracy: true,
            timeout: const Duration(seconds: 20),
          );
        } catch (e) {
          if (_latestPosition != null) {
            position = _latestPosition;
          }
          try {
            position = await Geolocator.getLastKnownPosition();
          } catch (e2) {
            position = null;
          }
        }
      }
    } catch (e) {
      position = null;
    }

    // Complete our completer safely
    if (_positionCompleter != null && !_positionCompleter!.isCompleted) {
      _positionCompleter!.complete(position);
    }

    _isGettingPosition = false;
    _positionCompleter = null;
    return position;
  }

  /// Get high-precision location by taking multiple readings and averaging them.
  /// This significantly improves accuracy for saving location-based rules.
  /// Returns null if unable to get any readings.
  Future<Position?> getHighPrecisionPosition({
    int sampleCount = 5,
    Duration sampleInterval = const Duration(seconds: 2),
    double maxAccuracyMeters = 50.0,
  }) async {
    if (_isGettingHighPrecisionPosition) {
      return null; // Prevent concurrent calls
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
              debugPrint('[${_ts()}] ⚠️ Web location service: Timeout getting position sample ${i + 1}/$sampleCount');
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
            debugPrint('[${_ts()}] ⚠️ Web location service: Null position from sample ${i + 1}/$sampleCount');
          }
        } catch (e) {
          // Catch "Future already completed" and other errors
          // This is a known issue with geolocator_web package
          debugPrint('[${_ts()}] ⚠️ Web location service: Error getting position sample ${i + 1}/$sampleCount: $e');
          // Continue to next sample - we'll use whatever samples we successfully collected
        }
      }
      
      if (allPositions.isEmpty) {
        return null;
      }
      
      // Use good readings if available, otherwise use best available readings
      final positionsToUse = goodPositions.isNotEmpty ? goodPositions : allPositions;
      
      if (goodPositions.isEmpty) {
        // Sort by accuracy to use the best readings available
        allPositions.sort((a, b) => a.accuracy.compareTo(b.accuracy));
      }
      
      // Average the coordinates from selected readings
      final avgLat = positionsToUse.map((p) => p.latitude).reduce((a, b) => a + b) / positionsToUse.length;
      final avgLon = positionsToUse.map((p) => p.longitude).reduce((a, b) => a + b) / positionsToUse.length;
      final avgAccuracy = positionsToUse.map((p) => p.accuracy).reduce((a, b) => a + b) / positionsToUse.length;
      
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
      _wlog('_sendLocationUpdate skipped: already sending');
      return;
    }
    _isSending = true;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _wlog('_sendLocationUpdate aborted: no current user');
        return;
      }

      final health = await getCurrentConnectivityHealth();
      if (!health.isOnline) {
        debugPrint('[${_ts()}] 🌍 Web location service: Device is offline, skipping location update');
        return;
      }

      // Update user activity regardless of visibility status (like mobile does)
      try {
        debugPrint('[${_ts()}] 🌍 Web location service: Updating user activity for $user.id');
        await Supabase.instance.client.rpc('update_user_activity', params: {'p_user_id': user.id});
        debugPrint('[${_ts()}] 🌍 Web location service: User activity updated successfully');
      } catch (e) {
        debugPrint('[${_ts()}] 🌍 Web location service: Error updating user activity: $e');
        // Ignore activity update errors
      }

      // Do not send location updates if user is invisible
      // This prevents location tracking when user has disabled visibility
      if (!_isVisible) {
        debugPrint('[${_ts()}] 🌍 Web location service: User is invisible, skipping location update');
        return;
      }

      debugPrint('[${_ts()}] 🌍 Web location service: About to send location update for visible user');

      // Accuracy thresholds
      // Web browsers often have poor initial accuracy (IP geolocation, outdated WiFi databases)
      // Accept up to 1500m to allow matching to work, but prefer better accuracy
      final maxAcceptableAccuracyMeters = await appConfigService.getDouble(
        'gps.web_max_acceptable_accuracy_meters',
        defaultValue: 1500.0
      ); // Accept locations up to 1.5km (web browsers can be inaccurate)
      final preferredAccuracyMeters = await appConfigService.getDouble(
        'gps.web_preferred_accuracy_meters',
        defaultValue: 200.0
      ); // Prefer locations better than 200m
      final kalmanFilterThresholdMeters = await appConfigService.getDouble(
        'gps.kalman_filter_skip_threshold_meters',
        defaultValue: 100.0
      ); // Skip Kalman filter for very inaccurate readings

      Position? rawPosition;
      
      // Use latest position from continuous stream if available (Google Maps watchPosition approach)
      // The stream continuously refines location over time as GPS/WiFi acquires better signal
      if (_latestPosition != null && _positionStreamSubscription != null) {
        rawPosition = _latestPosition;
        debugPrint('[${_ts()}] 🌍 Web location service: Using latest position from continuous stream (Google Maps watchPosition approach)');
      } else {
        // Fallback to single getCurrentPosition if stream isn't available
        debugPrint('[${_ts()}] 🌍 Web location service: Stream not available, using getCurrentPosition fallback');
        try {
          rawPosition = await getCurrentPosition().timeout(const Duration(seconds: 20));
        } catch (e) {
          debugPrint('[${_ts()}] ❌ Web location service: getCurrentPosition failed: $e');
          return;
        }
      }
      
      if (rawPosition == null) {
        debugPrint('[${_ts()}] ❌ Web location service: Unable to get any position');
        return;
      }

      // Promote nullable rawPosition to a local non-nullable variable to satisfy
      // analyzer (avoid losing promotion across awaits).
      Position currentRaw = rawPosition;

      debugPrint('[${_ts()}] 🌍 Web location service: Got position: ${currentRaw.latitude}, ${currentRaw.longitude}, accuracy: ${currentRaw.accuracy}m');

      // If accuracy is worse than preferred, attempt a short high-precision sampling
      // to try to match what Google Maps does (continuous watch + refined fixes).
      if (currentRaw.accuracy > preferredAccuracyMeters) {
        try {
          debugPrint('[${_ts()}] 🌍 Web location service: Accuracy ${currentRaw.accuracy}m worse than preferred ${preferredAccuracyMeters}m — attempting high-precision sampling');
          final high = await getHighPrecisionPosition(
            sampleCount: 5,
            sampleInterval: const Duration(seconds: 2),
            maxAccuracyMeters: preferredAccuracyMeters,
          ).timeout(const Duration(seconds: 20), onTimeout: () => null);

          if (high != null && high.accuracy <= currentRaw.accuracy) {
            debugPrint('[${_ts()}] 🌍 Web location service: Using high-precision sampled position (accuracy ${high.accuracy}m)');
            currentRaw = high;
          } else {
            debugPrint('[${_ts()}] 🌍 Web location service: High-precision sampling did not improve accuracy');
          }
        } catch (e) {
          debugPrint('[${_ts()}] ⚠️ Web location service: High-precision sampling failed: $e');
        }
      }

      // Warn about poor accuracy but accept it (web browsers can be very inaccurate)
      if (currentRaw.accuracy > preferredAccuracyMeters) {
        if (currentRaw.accuracy > maxAcceptableAccuracyMeters) {
          debugPrint('[${_ts()}] ⚠️ Web location service: Very poor accuracy (${currentRaw.accuracy.toStringAsFixed(0)}m) but accepting to allow matching. Consider moving to a location with better WiFi/GPS signal.');
        } else {
          debugPrint('[${_ts()}] ⚠️ Web location service: Moderate accuracy (${currentRaw.accuracy.toStringAsFixed(0)}m). Web browsers often have limited location accuracy compared to mobile GPS.');
        }
      }
      
      // Accept the location regardless of accuracy (web browsers are inherently less accurate)
      // The matching algorithm can handle moderate inaccuracies

      // Apply Kalman filter only for reasonably accurate readings
      // Skip filter for very inaccurate readings to avoid introducing drift
      Position finalPosition;
      if (currentRaw.accuracy <= kalmanFilterThresholdMeters) {
        // Use Kalman filter for better smoothing of accurate readings
        finalPosition = _kalmanFilter.filter(currentRaw);
        debugPrint('[${_ts()}] 🌍 Web location service: Filtered position: ${finalPosition.latitude}, ${finalPosition.longitude}, accuracy: ${finalPosition.accuracy}m (raw accuracy: ${currentRaw.accuracy}m)');
      } else {
        // For very inaccurate readings, use raw position to avoid filter drift
        finalPosition = currentRaw;
        debugPrint('[${_ts()}] 🌍 Web location service: Using raw position (accuracy too poor for Kalman filter): ${finalPosition.latitude}, ${finalPosition.longitude}, accuracy: ${finalPosition.accuracy}m');
      }

      // Use final position for callback
      if (_locationUpdateCallback != null) {
        try {
          _locationUpdateCallback!(finalPosition);
        } catch (cbErr) {
          // Ignore
        }
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
        await _syncLocationToSupabase(user.id, finalPosition.latitude, finalPosition.longitude, finalPosition.speed, finalPosition.heading);

        debugPrint('[${_ts()}] 📍 Location saved to local DB and synced to Supabase (lat: ${finalPosition.latitude}, lng: ${finalPosition.longitude}, accuracy: ${finalPosition.accuracy}m)');
      } catch (e) {
        debugPrint('[${_ts()}] ❌ Failed to save/sync location: $e');
      }

      // Match engine is now handled server-side autonomously
      // No client-side triggering needed - matches are created by Supabase functions
      debugPrint('[${_ts()}] 📍 Location updated - server-side matching will be triggered automatically');
    } finally {
      _isSending = false;
    }
  }

  // Start stream with requested interval; effective interval respects visibility and setting
  @override
  Future<void> startLocationStream(int intervalSeconds) async {
    debugPrint('[${_ts()}] 🌍 Web location service: startLocationStream called with interval $intervalSeconds');
    if (_isStarting) {
      debugPrint('[${_ts()}] 🌍 Web location service: Already starting, returning');
      return;
    }

    _requestedIntervalSeconds = intervalSeconds;

    try {
      final docState = html.document.visibilityState;
      final isHidden = docState == 'hidden';

      // Only apply hidden-minimum behavior if smart throttling is enabled
      final effectiveInterval = (_smartThrottlingEnabled && isHidden)
          ? (intervalSeconds < 60 ? 60 : intervalSeconds)
          : intervalSeconds;
      _wlog('startLocationStream: visibilityState=$docState isHidden=$isHidden smartThrottling=$_smartThrottlingEnabled requested=$intervalSeconds effective=$effectiveInterval (current=$_currentIntervalSeconds, isStreaming=$_isStreaming, gen=$_generation)');

      // If already streaming with same effective interval, do nothing (no callback fire, no restart)
      if (_isStreaming && _currentIntervalSeconds == effectiveInterval) {
        _wlog('startLocationStream: no-op (already streaming at effective interval)');
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
      _wlog('startLocationStream: started streaming (gen=$gen, current=$_currentIntervalSeconds)');

      // Use continuous position stream (like Google Maps watchPosition) for better accuracy
      // This allows location to refine over time as GPS/WiFi acquires better signal
      debugPrint('[${_ts()}] 🌍 Web location service: Starting continuous position stream (Google Maps approach)');
      final hasPermission = await handleLocationPermission();
      if (hasPermission) {
        try {
          // Start position stream with best accuracy
          // This continuously monitors position and allows it to refine over time
          _positionStreamSubscription = Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0, // Update on any movement (let browser decide when to update)
            ),
          ).listen(
            (Position position) {
              // Store latest position from stream
              _latestPosition = position;
              debugPrint('[${_ts()}] 🌍 Web location service: Position stream update: ${position.latitude}, ${position.longitude}, accuracy: ${position.accuracy}m');
              
              // Call callback immediately when position updates
              if (_locationUpdateCallback != null) {
                try {
                  _locationUpdateCallback!(position);
                } catch (e) {
                  // Ignore callback errors
                }
              }
            },
            onError: (error) {
              debugPrint('[${_ts()}] ⚠️ Web location service: Position stream error: $error');
            },
            cancelOnError: false, // Keep stream alive even on errors
          );
        } catch (e) {
          debugPrint('[${_ts()}] ⚠️ Web location service: Failed to start position stream: $e, falling back to timer-based updates');
          _positionStreamSubscription = null;
        }
        // If Geolocator web stream couldn't be started or is unreliable on some browsers,
        // start a direct `navigator.geolocation.watchPosition` with enableHighAccuracy:true
        // — this more closely matches Google Maps' approach.
        if (_positionStreamSubscription == null) {
          try {
            final watchId = (html.window as dynamic).navigator.geolocation.watchPosition(
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
                  debugPrint('[${_ts()}] 🌍 Web location service: HTML watchPosition update: ${p.latitude}, ${p.longitude}, accuracy: ${p.accuracy}m');
                  if (_locationUpdateCallback != null) {
                    try {
                      _locationUpdateCallback!(p);
                    } catch (_) {}
                  }
                } catch (e) {
                  debugPrint('[${_ts()}] ⚠️ Web location service: Error processing HTML watchPosition update: $e');
                }
              },
              (err) {
                debugPrint('[${_ts()}] ⚠️ Web location service: HTML watchPosition error: $err');
              },
              {'enableHighAccuracy': true, 'maximumAge': 0, 'timeout': 10000},
            );
            _htmlWatchId = watchId;
            _htmlWatchActive = true;
            debugPrint('[${_ts()}] 🌍 Web location service: Started HTML watchPosition (id: $_htmlWatchId)');
          } catch (e) {
            debugPrint('[${_ts()}] ⚠️ Web location service: Could not start HTML watchPosition: $e');
            _htmlWatchActive = false;
            _htmlWatchId = null;
          }
        }
      }

      // Also use timer to periodically send updates to Supabase (even with stream running)
      // The stream provides continuous refinement, timer controls update frequency
      _locationTimer = Timer.periodic(Duration(seconds: _currentIntervalSeconds), (timer) async {
        _wlog('timer tick (gen=$gen, currentGen=$_generation, interval=$_currentIntervalSeconds, isStreaming=$_isStreaming, isVisible=$_isVisible)');
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
      });

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
          ? (_requestedIntervalSeconds < 60 ? 60 : _requestedIntervalSeconds)
          : _requestedIntervalSeconds;
      _wlog('_applyRequestedInterval: visibilityState=$docState isHidden=$isHidden smartThrottling=$_smartThrottlingEnabled requested=$_requestedIntervalSeconds effective=$effectiveInterval (isStreaming=$_isStreaming, current=$_currentIntervalSeconds, gen=$_generation)');

      if (!_isStreaming) {
        _currentIntervalSeconds = effectiveInterval;
        _wlog('_applyRequestedInterval: not streaming; updated current interval to $_currentIntervalSeconds');
        return;
      }

      if (_currentIntervalSeconds == effectiveInterval) {
        _wlog('_applyRequestedInterval: no-op (interval unchanged)');
        return;
      }

      _generation++;
      _currentIntervalSeconds = effectiveInterval;
      _stopInternal();
      // start a fresh timer for the new effective value (keep streaming true)
      _isStreaming = true;
      final gen = _generation;
      debugPrint('[${_ts()}] 🌍 Web location service: Starting timer with interval $_currentIntervalSeconds s');
      _locationTimer = Timer.periodic(Duration(seconds: _currentIntervalSeconds), (timer) async {
        if (gen != _generation) {
          debugPrint('[${_ts()}] 🌍 Web location service: Timer generation changed, cancelling');
          try {
            timer.cancel();
          } catch (_) {}
          return;
        }
        if (!_isStreaming) {
          debugPrint('[${_ts()}] 🌍 Web location service: Streaming stopped, cancelling timer');
          try {
            timer.cancel();
          } catch (_) {}
          return;
        }
        debugPrint('[${_ts()}] 🌍 Web location service: Timer fired, calling _sendLocationUpdate');
        await _sendLocationUpdate();
      });
    } catch (e) {
      // Ignore
    }
  }

  void _applyEffectiveIntervalWhenHidden() {
    try {
      if (!_smartThrottlingEnabled) {
        _wlog('_applyEffectiveIntervalWhenHidden: smart throttling disabled; no-op');
        return;
      }

      final hiddenInterval = _requestedIntervalSeconds < 60 ? 60 : _requestedIntervalSeconds;
      _wlog('_applyEffectiveIntervalWhenHidden: requested=$_requestedIntervalSeconds hiddenInterval=$hiddenInterval (isStreaming=$_isStreaming, current=$_currentIntervalSeconds, gen=$_generation)');

      if (!_isStreaming) {
        _currentIntervalSeconds = hiddenInterval;
        _wlog('_applyEffectiveIntervalWhenHidden: not streaming; updated current interval to $_currentIntervalSeconds');
        return;
      }

      if (_currentIntervalSeconds == hiddenInterval) {
        _wlog('_applyEffectiveIntervalWhenHidden: no-op (interval unchanged)');
        return;
      }

      _generation++;
      _currentIntervalSeconds = hiddenInterval;
      _stopInternal();
      _isStreaming = true;
      final gen = _generation;
      _locationTimer = Timer.periodic(Duration(seconds: _currentIntervalSeconds), (timer) async {
        _wlog('hidden timer tick (gen=$gen, currentGen=$_generation, interval=$_currentIntervalSeconds, isStreaming=$_isStreaming, isVisible=$_isVisible)');
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
      });
    } catch (e) {
      // Ignore
    }
  }

  // Stop immediately and bump generation to invalidate previous timers
  void _stopInternal() {
    _generation++;
    _wlog('_stopInternal: stopping (newGen=$_generation, hadTimer=${_locationTimer != null}, htmlWatchActive=$_htmlWatchActive)');
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
          (html.window as dynamic).navigator.geolocation.clearWatch(_htmlWatchId);
        } catch (_) {}
        _htmlWatchActive = false;
        _htmlWatchId = null;
        debugPrint('[${_ts()}] 🌍 Web location service: Cleared HTML watchPosition');
      }
    } catch (e) {
      // Ignore errors while clearing watch
    }
  }

  @override
  void stopLocationStream() {
    _wlog('stopLocationStream called');
    _isStarting = false;
    _stopInternal();
    // Reset Kalman filter for fresh start next time
    _kalmanFilter.reset();
    // Ensure position stream is stopped
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    _latestPosition = null;
  }

  @override
  void setLocationUpdateCallback(void Function(dynamic)? callback) {
    _locationUpdateCallback = callback;
    _wlog('setLocationUpdateCallback: ${callback == null ? 'null' : 'set'}');
  }

  @override
  void setVisibility(bool isVisible) {
    _isVisible = isVisible;
    _wlog('setVisibility: isVisible=$_isVisible');
  }

  /// Sync location data directly to Supabase (web platform workaround)
  Future<void> _syncLocationToSupabase(String userId, double latitude, double longitude, double? speed, double? heading) async {
    try {
      debugPrint('[${_ts()}] 🔄 Syncing location to Supabase for user: $userId, lat: $latitude, lng: $longitude');

      // Use the update_user_location RPC function that should exist in Supabase
      await Supabase.instance.client.rpc('update_user_location', params: {
        'p_user_id': userId,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_speed': speed,
        'p_heading': heading,
      });

      debugPrint('[${_ts()}] ✅ Location synced to Supabase successfully');
    } catch (e) {
      debugPrint('[${_ts()}] ❌ Failed to sync location to Supabase: $e');
      // Continue anyway - local DB still has the data for later sync
    }
  }
}
