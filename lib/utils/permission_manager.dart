// lib/utils/permission_manager.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/visibility_provider.dart';

/// Manages all app permissions with the following behavior:
/// 1. On first install, requests all permissions sequentially before showing home screen
/// 2. After first install, only requests permissions as needed
/// 3. Location permission is only requested if user is visible
/// 4. Each permission is requested only once per app run
class PermissionManager {
  PermissionManager._();
  static final PermissionManager instance = PermissionManager._();

  // Track which permissions have been requested this run
  static final Set<String> _requestedThisRun = <String>{};
  
  // Track if first install permission flow has completed
  static const String _firstInstallCompleteKey = 'permissions_first_install_complete';

  /// Check if this is the first install (permissions not yet requested)
  static Future<bool> isFirstInstall() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final completed = prefs.getBool(_firstInstallCompleteKey);
      return completed != true; // Return true if not completed (first install)
    } catch (_) {
      return true; // Default to first install if we can't check
    }
  }

  /// Mark first install as complete
  static Future<void> markFirstInstallComplete() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_firstInstallCompleteKey, true);
    } catch (_) {
      // Ignore
    }
  }

  /// Check if a permission has been requested this run
  static bool hasBeenRequestedThisRun(String permissionKey) {
    return _requestedThisRun.contains(permissionKey);
  }

  /// Mark a permission as requested this run (public for use by location services)
  static void markRequested(String permissionKey) {
    _requestedThisRun.add(permissionKey);
  }

  /// Request notification permission (works on Android 13+)
  static Future<bool> requestNotificationPermission() async {
    if (kIsWeb) return true; // Web doesn't need notification permission
    
    const key = 'notification';
    if (hasBeenRequestedThisRun(key)) {
      // Already requested this run, just check status
      final status = await Permission.notification.status;
      return status.isGranted;
    }

    markRequested(key);
    
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (status.isGranted) return true;
      if (status.isDenied) {
        final result = await Permission.notification.request();
        return result.isGranted;
      }
      return false;
    }
    
    // iOS notification permission is handled differently
    return true;
  }

  /// Request location permission (only if user is visible)
  static Future<bool> requestLocationPermission({
    required WidgetRef ref,
    bool forceRequest = false,
  }) async {
    const key = 'location';
    
    // Check if user is visible (unless force request)
    if (!forceRequest) {
      try {
        final isVisible = ref.read(isVisibleProvider);
        if (!isVisible) {
          debugPrint('📍 PermissionManager: User is invisible, skipping location permission request');
          return false;
        }
      } catch (_) {
        // If we can't check visibility, proceed (might be during initialization)
      }
    }

    if (hasBeenRequestedThisRun(key)) {
      // Already requested this run, just check status
      final permission = await Geolocator.checkPermission();
      return permission == LocationPermission.whileInUse || 
             permission == LocationPermission.always;
    }

    markRequested(key);

    try {
      // Check if location services are enabled
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('📍 PermissionManager: Location services are disabled');
        return false;
      }

      // Check current permission status
      LocationPermission permission = await Geolocator.checkPermission();
      
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('📍 PermissionManager: Location permission denied');
          return false;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('📍 PermissionManager: Location permission denied forever');
        return false;
      }

      // For Android, background location is handled by PermissionCoordinator
      // when needed for background service

      return permission == LocationPermission.whileInUse || 
             permission == LocationPermission.always;
    } catch (e) {
      debugPrint('📍 PermissionManager: Error requesting location permission: $e');
      return false;
    }
  }

  /// Request camera permission
  static Future<bool> requestCameraPermission() async {
    if (kIsWeb) return true; // Web handles camera permission via browser
    
    const key = 'camera';
    if (hasBeenRequestedThisRun(key)) {
      final status = await Permission.camera.status;
      return status.isGranted;
    }

    markRequested(key);

    try {
      final status = await Permission.camera.status;
      if (status.isGranted) return true;
      if (status.isDenied) {
        final result = await Permission.camera.request();
        return result.isGranted;
      }
      return false;
    } catch (e) {
      debugPrint('📷 PermissionManager: Error requesting camera permission: $e');
      return false;
    }
  }

  /// Request photos/storage permission
  static Future<bool> requestPhotosPermission() async {
    if (kIsWeb) return true; // Web handles photos via browser
    
    const key = 'photos';
    if (hasBeenRequestedThisRun(key)) {
      // Check appropriate permission based on platform
      if (Platform.isAndroid) {
        // Android 13+ uses photos permission, older uses storage
        final androidVersion = int.tryParse(Platform.version.split('.').first) ?? 0;
        if (Platform.version.contains('33') || androidVersion >= 33) {
          final status = await Permission.photos.status;
          return status.isGranted;
        } else {
          final status = await Permission.storage.status;
          return status.isGranted;
        }
      } else if (Platform.isIOS) {
        final status = await Permission.photos.status;
        return status.isGranted;
      }
      return true;
    }

    markRequested(key);

    try {
      if (Platform.isAndroid) {
        // Android 13+ uses photos permission, older uses storage
        final androidVersion = int.tryParse(Platform.version.split('.').first) ?? 0;
        if (Platform.version.contains('33') || androidVersion >= 33) {
          final status = await Permission.photos.status;
          if (status.isGranted) return true;
          if (status.isDenied) {
            final result = await Permission.photos.request();
            return result.isGranted;
          }
        } else {
          final status = await Permission.storage.status;
          if (status.isGranted) return true;
          if (status.isDenied) {
            final result = await Permission.storage.request();
            return result.isGranted;
          }
        }
      } else if (Platform.isIOS) {
        final status = await Permission.photos.status;
        if (status.isGranted) return true;
        if (status.isDenied) {
          final result = await Permission.photos.request();
          return result.isGranted;
        }
      }
      return true;
    } catch (e) {
      debugPrint('🖼️ PermissionManager: Error requesting photos permission: $e');
      return true; // Default to true for web/unknown platforms
    }
  }

  /// Request all permissions sequentially (for first install)
  /// Returns true if all critical permissions were granted
  static Future<Map<String, bool>> requestAllPermissionsSequentially({
    required BuildContext context,
    required WidgetRef ref,
    bool requestLocation = true,
  }) async {
    final results = <String, bool>{};

    // 1. Notifications
    debugPrint('🔔 Requesting notification permission...');
    results['notification'] = await requestNotificationPermission();

    // 2. Camera
    debugPrint('📷 Requesting camera permission...');
    results['camera'] = await requestCameraPermission();

    // 3. Photos/Storage
    debugPrint('🖼️ Requesting photos permission...');
    results['photos'] = await requestPhotosPermission();

    // 4. Location (only if user is visible or explicitly requested)
    if (requestLocation) {
      debugPrint('📍 Requesting location permission...');
      results['location'] = await requestLocationPermission(ref: ref, forceRequest: true);
    } else {
      results['location'] = false;
    }

    // Mark first install as complete
    await markFirstInstallComplete();

    return results;
  }

  static Future<Map<String, bool>> requestAllMissingPermissionsSequentially({
    required BuildContext context,
    required WidgetRef ref,
    bool requestLocation = true,
  }) async {
    final results = <String, bool>{};

    debugPrint('🔔 Requesting notification permission...');
    results['notification'] = await requestNotificationPermission();

    debugPrint('📷 Requesting camera permission...');
    results['camera'] = await requestCameraPermission();

    debugPrint('🖼️ Requesting photos permission...');
    results['photos'] = await requestPhotosPermission();

    if (requestLocation) {
      debugPrint('📍 Requesting location permission...');
      results['location'] =
          await requestLocationPermission(ref: ref, forceRequest: true);
    } else {
      results['location'] = false;
    }

    return results;
  }

  /// Request a specific permission on-demand (after first install)
  static Future<bool> requestPermissionOnDemand({
    required String permissionType,
    required WidgetRef ref,
  }) async {
    switch (permissionType) {
      case 'notification':
        return await requestNotificationPermission();
      case 'location':
        return await requestLocationPermission(ref: ref);
      case 'camera':
        return await requestCameraPermission();
      case 'photos':
        return await requestPhotosPermission();
      default:
        return false;
    }
  }

  /// Reset the "requested this run" tracking (useful for testing)
  static void resetRequestedTracking() {
    _requestedThisRun.clear();
  }
}
