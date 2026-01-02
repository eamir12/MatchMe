// lib/services/mobile_location_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'location_service.dart';
import 'package:matchme/services/local_db_service.dart';

final supabase = Supabase.instance.client;

class MobileLocationService implements LocationService {
  Timer? _positionUpdateTimer;
  bool _isServiceRunning = false;
  bool _isStarting = false;
  void Function(dynamic)? _locationUpdateCallback;
  int _currentIntervalSeconds = 0;

  @override
  void setSmartThrottlingEnabled(bool enabled) {
    // Mobile stream uses platform LocationSettings; throttling decisions are made by caller (VisibilityNotifier).
    // No-op for mobile implementation.
  }

  Future<bool> _isUserVisible(String userId) async {
    try {
      final response = await supabase.from('users').select('user_visibility_setting, system_visibility_status').eq('id', userId).maybeSingle();
      if (response == null || response['user_visibility_setting'] == null) return true; // default to visible if unknown
      final userSetting = response['user_visibility_setting'] == true;
      final systemVisibility = response['system_visibility_status'] as String? ?? 'visible';
      return userSetting && systemVisibility == 'visible';
    } catch (_) {
      // On error, be conservative and assume visible to avoid stopping unexpectedly.
      return true;
    }
  }

  Future<void> _fetchAndSendLocation(Position position) async {
    debugPrint('📍 Mobile location service: _fetchAndSendLocation called with position: ${position.latitude}, ${position.longitude}');
    final user = supabase.auth.currentUser;
    if (user == null) {
      debugPrint('📍 Mobile location service: No user, stopping location stream');
      stopLocationStream();
      return;
    }

    // Before using or transmitting the location, verify that the user is currently visible.
    final visible = await _isUserVisible(user.id);
    if (!visible) {
      debugPrint('📍 Mobile location service: User is not visible - skipping location handling and stopping stream');
      // Stop the stream as a safety measure
      stopLocationStream();
      return;
    }

    // Update user activity (only if visible)
    try {
      debugPrint('Updating user activity for ${user.id}');
      await supabase.rpc('update_user_activity', params: {'p_user_id': user.id});
      debugPrint('User activity updated successfully');
    } catch (e) {
      debugPrint('Error updating user activity: $e');
      // Ignore activity update errors
    }

    // Location updates are handled by the background service
    // Match engine is now handled server-side autonomously
    // No client-side triggering needed - matches are created by Supabase functions
    debugPrint('📍 Location updated - server-side matching will be triggered automatically');

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

      // Also sync directly to Supabase (mobile platform workaround)
      await _syncLocationToSupabase(user.id, position.latitude, position.longitude, position.speed, position.heading);
    } catch (e) {
      debugPrint('❌ Failed to save/sync location: $e');
    }
  }

  @override
  Future<bool> handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    // For Android 10+ (API 29+), we also need background location permission
    // for the background service to work
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        // Check if we have background location permission
        final bgPermission = await Geolocator.checkPermission();
        if (bgPermission != LocationPermission.always && bgPermission != LocationPermission.whileInUse) {
          debugPrint('Requesting background location permission for Android background service');
          final requestedBgPermission = await Geolocator.requestPermission();
          if (requestedBgPermission != LocationPermission.always) {
            debugPrint('Background location permission not granted - background GPS may not work');
          } else {
            debugPrint('Background location permission granted');
          }
        }
      } catch (e) {
        debugPrint('Error requesting background location permission: $e');
      }
    }

    return true;
  }

  @override
  Future<void> startLocationStream(int intervalSeconds) async {
    if (_isStarting) {
      return;
    }
    _isStarting = true;

    try {
      if (_isServiceRunning && _currentIntervalSeconds == intervalSeconds) {
        return;
      }

      if (_isServiceRunning && _currentIntervalSeconds != intervalSeconds) {
        stopLocationStream();
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final hasPermission = await handleLocationPermission();
      if (!hasPermission) {
        debugPrint('📍 Mobile location service: Location permission denied');
        return;
      }

      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      debugPrint('📍 Mobile location service: Location service enabled: $serviceEnabled');
      if (!serviceEnabled) {
        debugPrint('📍 Mobile location service: Location service is disabled on device');
        return;
      }

      debugPrint('📍 Mobile location service: Setting up periodic location updates with interval: $intervalSeconds');

      // Use getCurrentPosition with timer for more reliable continuous updates
      _positionUpdateTimer?.cancel();
      _positionUpdateTimer = Timer.periodic(Duration(seconds: intervalSeconds), (timer) async {
        try {
          debugPrint('📍 Mobile location service: Timer triggered - getting current position');
          // Use best accuracy for optimal GPS precision on mobile devices
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              timeLimit: Duration(seconds: 15),
            ),
          );
          debugPrint('📍 Mobile location service: Got current position: ${position.latitude}, ${position.longitude}, accuracy: ${position.accuracy}m');
          _locationUpdateCallback?.call(position);
          _fetchAndSendLocation(position);
        } catch (e) {
          debugPrint('❌ Mobile location service: Failed to get current position: $e');
        }
      });

      debugPrint('📍 Mobile location service: Position timer started successfully with interval: ${intervalSeconds}s');

      _isServiceRunning = true;
      _currentIntervalSeconds = intervalSeconds;
    } catch (e) {
      _isServiceRunning = false;
    } finally {
      _isStarting = false;
    }
  }

  @override
  void stopLocationStream() {
    debugPrint('📍 Mobile location service: stopLocationStream called, currently running: $_isServiceRunning');
    if (!_isServiceRunning) {
      return;
    }
    _positionUpdateTimer?.cancel();
    _positionUpdateTimer = null;
    _isServiceRunning = false;
    _currentIntervalSeconds = 0;
    debugPrint('📍 Mobile location service: Location timer stopped');
  }

  @override
  void setLocationUpdateCallback(void Function(dynamic)? callback) {
    _locationUpdateCallback = callback;
  }

  @override
  void setVisibility(bool isVisible) {
    // No-op: visibility checking removed as match engine is now server-side
  }

  /// Sync location data directly to Supabase (mobile platform workaround)
  Future<void> _syncLocationToSupabase(String userId, double latitude, double longitude, double? speed, double? heading) async {
    try {
      debugPrint('🔄 Mobile location service: Syncing location to Supabase for user: $userId, lat: $latitude, lng: $longitude');

      // Use the update_user_location RPC function
      await supabase.rpc('update_user_location', params: {
        'p_user_id': userId,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_speed': speed,
        'p_heading': heading,
      });

      debugPrint('✅ Mobile location service: Location synced to Supabase successfully');
    } catch (e) {
      debugPrint('❌ Mobile location service: Failed to sync location to Supabase: $e');
      // Continue anyway - local DB still has the data for later sync
    }
  }
}