// lib/services/location_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'mobile_location_service.dart';
import 'web_location_service.dart';

// Abstract class defining the contract for location services
abstract class LocationService {
  Future<void> startLocationStream(int intervalSeconds);
  void stopLocationStream({bool keepLiveStream = false});
  Future<bool> handleLocationPermission();
  void setLocationUpdateCallback(void Function(dynamic)? callback);

  // New: allow toggling whether the service should enforce smart throttling
  // (e.g. hidden => minimum 60s). Implementations should no-op if not applicable.
  void setSmartThrottlingEnabled(bool enabled);

  /// Continuous position stream for a foreground UI surface (the Nearby map).
  /// While active, the interval timer stops powering the GPS chip itself and
  /// transmits the latest streamed fix at the configured interval instead —
  /// the UI follows movement in realtime while transmission keeps honoring
  /// the user's GPS frequency setting.
  ///
  /// Returns false when the stream is unavailable (web) or a gate fails
  /// (no user, pin active, no permission, location services off). Idempotent:
  /// calling start again while running returns true without restarting.
  Future<bool> startMapLiveStream();

  /// Stops the map live stream; the interval timer resumes one-shot GPS.
  /// No-op when the stream is not running.
  void stopMapLiveStream();

  // Set visibility state to prevent sending location when invisible
  void setVisibility(bool isVisible);

  /// Whether a GPS timer is actually running right now (as opposed to
  /// merely requested). Parked/inactive streams report false so callers
  /// never mistake a parked or failed start for a live GPS timer.
  bool get isGpsTimerRunning;
}

// Provider that selects the correct implementation based on platform
final locationServiceProvider = Provider<LocationService>((ref) {
  if (kIsWeb) {
    return WebLocationService();
  } else {
    return MobileLocationService();
  }
});
