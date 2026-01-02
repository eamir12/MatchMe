import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/web_location_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';

class CurrentLocationNotifier extends Notifier<Position?> {
  Timer? _updateTimer;
  StreamSubscription<Position>? _positionStreamSubscription;
  Duration _updateInterval = Duration(minutes: 1); // Default, will be updated

  @override
  Position? build() {
    // Fetch initial location when provider is created
    _fetchCurrentLocation();

    // Update interval from profile
    _updateIntervalFromProfile();

    // Set up periodic updates (skip on web - WebLocationService handles this)
    if (!kIsWeb) {
      _startPeriodicUpdates();
    }

    // Start real-time location stream on mobile only
    if (!kIsWeb) {
      _startMobileLocationStream();
    }

    return null;
  }

  Future<void> _updateIntervalFromProfile() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;
      final profileAsync = await ref.read(userProfileProvider(userId).future);
      // Use seconds directly (profile now stores seconds)
      final intervalInSeconds = profileAsync?.gpsIntervalDefault ?? 5;
      _updateInterval = Duration(seconds: intervalInSeconds);
      // Restart timer with new interval (skip on web - WebLocationService handles this)
      if (!kIsWeb) {
        _startPeriodicUpdates();
      }
      // Also restart mobile stream if needed
      if (!kIsWeb) {
        _startMobileLocationStream();
      }
    } catch (e) {
      // Keep default
    }
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      final locationService = ref.read(locationServiceProvider);
      if (locationService is WebLocationService) {
        final position = await locationService.getCurrentPosition();
        if (position != null) {
          await _processNewPosition(position);
        }
      } else {
        // Mobile: prime state immediately with last known (fast) and then try current position.
        final hasPermission = await locationService.handleLocationPermission();
        if (!hasPermission) return;

        try {
          final last = await Geolocator.getLastKnownPosition();
          if (last != null) {
            await _processNewPosition(last);
          }
        } catch (_) {
          // Ignore last-known failures
        }

        try {
          // Use best accuracy for optimal GPS precision on mobile devices
          final current = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
          ).timeout(const Duration(seconds: 15));
          await _processNewPosition(current);
        } catch (_) {
          // Ignore current position failures; stream may still update later.
        }
      }
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _processNewPosition(Position position) async {
    // Update state with new position
    state = position;

    // Save locally
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        final localDb = ref.read(localDbProvider);
        await localDb.saveCurrentLocation(
          userId,
          position.latitude,
          position.longitude,
          speed: position.speed,
          heading: position.heading,
          timestamp: position.timestamp,
        );
      }
    } catch (e) {
      // Ignore location update errors
    }
  }

  void _startPeriodicUpdates() {
    _updateTimer?.cancel();
    _updateTimer = Timer.periodic(_updateInterval, (_) {
      _fetchCurrentLocation();
    });
  }

  void _startMobileLocationStream() {
    // Cancel existing subscription if any
    _positionStreamSubscription?.cancel();

    // Configure location settings similar to mobile location service
    LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.best, // Use best accuracy for optimal GPS precision
        distanceFilter: 5, // meters
        intervalDuration: _updateInterval,
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.best, // Use best accuracy for optimal GPS precision
        activityType: ActivityType.other,
        distanceFilter: 5, // meters
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: false, // Don't show indicator for this stream
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.best, // Use best accuracy
        distanceFilter: 5,
      );
    }

    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) async {
      await _processNewPosition(position);
    });
  }

  Future<void> refreshLocation() async {
    await _fetchCurrentLocation();
  }

}

final currentLocationProvider = NotifierProvider<CurrentLocationNotifier, Position?>(() {
  return CurrentLocationNotifier();
});
