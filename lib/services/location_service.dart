// lib/services/location_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/foundation.dart' show debugPrint;
import 'mobile_location_service.dart';
import 'web_location_service.dart';

// Abstract class defining the contract for location services
abstract class LocationService {
  Future<void> startLocationStream(int intervalSeconds);
  void stopLocationStream();
  Future<bool> handleLocationPermission();
  void setLocationUpdateCallback(void Function(dynamic)? callback);

  // New: allow toggling whether the service should enforce smart throttling
  // (e.g. hidden => minimum 60s). Implementations should no-op if not applicable.
  void setSmartThrottlingEnabled(bool enabled);

  // Set visibility state to prevent sending location when invisible
  void setVisibility(bool isVisible);
}

// Provider that selects the correct implementation based on platform
final locationServiceProvider = Provider<LocationService>((ref) {
  if (kIsWeb) {
    debugPrint('[${DateTime.now().toIso8601String()}] 📍 locationServiceProvider: using WebLocationService');
    return WebLocationService();
  } else {
    debugPrint('[${DateTime.now().toIso8601String()}] 📍 locationServiceProvider: using MobileLocationService');
    return MobileLocationService();
  }
});
