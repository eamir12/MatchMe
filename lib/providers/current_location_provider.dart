import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/web_location_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:flutter/foundation.dart';

class CurrentLocationNotifier extends Notifier<Position?> {
  @override
  Position? build() {
    // Do NOT start any continuous GPS work from here.
    // GPS should be driven by the existing visibility + throttling logic in
    // `IsVisible`/`LocationService`. This provider only stores the latest known
    // position for UI/rules and caches it locally.
    _loadCachedLocation();

    return null;
  }

  Future<void> _loadCachedLocation() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;
      final localDb = ref.read(localDbProvider);
      final cached = await localDb.getCurrentLocation(userId);
      if (cached == null) return;

      final lat = (cached['latitude'] as num?)?.toDouble();
      final lon = (cached['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) return;

      final tsRaw = cached['timestamp']?.toString();
      final ts = tsRaw != null ? DateTime.tryParse(tsRaw) : null;

      state = Position(
        latitude: lat,
        longitude: lon,
        timestamp: ts ?? DateTime.now(),
        accuracy: double.infinity,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: (cached['heading'] as num?)?.toDouble() ?? 0.0,
        headingAccuracy: 0.0,
        speed: (cached['speed'] as num?)?.toDouble() ?? 0.0,
        speedAccuracy: 0.0,
      );
    } catch (_) {
      // Ignore cache load failures
    }
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      // Don't attempt to fetch position while offline
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) {
        debugPrint('🟠 CurrentLocationNotifier: offline - skipping fetchCurrentLocation');
        return;
      }

      final locationService = ref.read(locationServiceProvider);
      if (locationService is WebLocationService) {
        final position = await locationService.getCurrentPosition();
        if (position != null) {
          await _processNewPosition(position);
        }
      } else {
        // Mobile: one-shot fetch only (should be called sparingly).
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

  Future<void> updateFromService(Position position) async {
    await _processNewPosition(position);
  }

  Future<void> refreshLocation() async {
    await _fetchCurrentLocation();
  }
}

final currentLocationProvider = NotifierProvider<CurrentLocationNotifier, Position?>(() {
  return CurrentLocationNotifier();
});
