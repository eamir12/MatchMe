// lib/services/offline_trail_service.dart
// Records places while offline and uploads them later for retroactive matching.
// Retention is per-user (chosen time); upload chunks to the upload_offline_trail RPC.

import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/native_secure_store.dart';
import 'package:matchme/services/pinned_location_gate.dart';

class OfflineTrailService {
  OfflineTrailService._();
  static final OfflineTrailService instance = OfflineTrailService._();

  static const String prefsEnabledKey = 'flutter.retro_enabled';
  static const String prefsRetentionHoursKey = 'flutter.retro_retention_hours';

  /// Native (Android) encrypted buffer of GPS fixes recorded by the
  /// background service while the app UI was closed. Mirrors
  /// MatchMeBackgroundService.TRAIL_NATIVE_KEY.
  static const String _nativeTrailKey = 'flutter.offline_trail_native';

  static const int defaultRetentionHours = 24;
  static const int minRetentionHours = 2;
  static const int maxRetentionHours = 72;
  static const int uploadChunkSize = 200;

  bool _uploading = false;

  Future<bool> isEnabledForCurrentUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(prefsEnabledKey);
      if (v != null) return v;
    } catch (_) {}
    // The pref was never written on this install (the flag was toggled on
    // another device, or the profile row was set server-side). Fall back to
    // the synced profile flag and re-seed the pref — the settings toggle
    // shows the profile flag, so recording must agree with it. The native
    // background service also reads this pref directly.
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return false;
      final profile = await LocalDbService.shared.getLocalProfile(user.id);
      final enabled =
          profile?['retro_matching_enabled']?.toString() == 'true' ||
          profile?['retroMatchingEnabled']?.toString() == 'true';
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(prefsEnabledKey, enabled);
      } catch (_) {}
      return enabled;
    } catch (_) {
      return false;
    }
  }

  Future<int> retentionHoursForCurrentUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(prefsRetentionHoursKey) ?? defaultRetentionHours;
      return v.clamp(minRetentionHours, maxRetentionHours);
    } catch (_) {
      return defaultRetentionHours;
    }
  }

  Future<void> setLocalPrefs({
    required bool enabled,
    required int retentionHours,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsEnabledKey, enabled);
    await prefs.setInt(
      prefsRetentionHoursKey,
      retentionHours.clamp(minRetentionHours, maxRetentionHours),
    );
  }

  /// Called on every GPS tick that arrived while offline.
  Future<void> recordOfflinePosition(String userId, Position position) async {
    if (userId.isEmpty) return;
    if (!await isEnabledForCurrentUser()) return;
    // Pinned home-base: do not record real movement while pinned.
    if (await PinnedLocationGate.isActive()) return;
    if (position.accuracy > 150) return; // drop very inaccurate fixes
    final retention = await retentionHoursForCurrentUser();
    final db = LocalDbService.shared;
    await db.appendOfflineTrailPoint(
      userId,
      position.latitude,
      position.longitude,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading,
      recordedAt: position.timestamp.toUtc(),
    );
    await db.pruneOfflineTrail(userId, Duration(hours: retention));
  }

  Future<int> pendingCount(String userId) async {
    await importNativeTrail();
    return LocalDbService.shared.getOfflineTrailCount(userId);
  }

  /// Merges GPS fixes the native background service recorded while the app
  /// UI was closed (encrypted native buffer) into the encrypted Hive trail,
  /// then clears the native buffer. Dedupe against adjacent points is
  /// handled by [LocalDbService.appendOfflineTrailPoint].
  Future<void> importNativeTrail() async {
    if (!NativeSecureStore.isAndroid) return;
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      final raw = await NativeSecureStore.getString(_nativeTrailKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        await NativeSecureStore.clearKeys([_nativeTrailKey]);
        return;
      }
      final db = LocalDbService.shared;
      for (final p in decoded) {
        if (p is! Map) continue;
        final lat = (p['lat'] as num?)?.toDouble();
        final lng = (p['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        await db.appendOfflineTrailPoint(
          user.id,
          lat,
          lng,
          accuracy: (p['accuracy'] as num?)?.toDouble(),
          speed: (p['speed'] as num?)?.toDouble(),
          heading: (p['heading'] as num?)?.toDouble(),
          recordedAt: DateTime.tryParse(p['recorded_at']?.toString() ?? ''),
        );
      }
      final retention = await retentionHoursForCurrentUser();
      await db.pruneOfflineTrail(user.id, Duration(hours: retention));
      await NativeSecureStore.clearKeys([_nativeTrailKey]);
    } catch (_) {}
  }

  /// Uploads kept places in chunks. Clears local copy only on RPC ack.
  /// Returns total points acknowledged by the database.
  Future<int> uploadPendingTrail({bool deleteLocalOnSuccess = true}) async {
    if (_uploading) return 0;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return 0;
    if (!await isEnabledForCurrentUser()) return 0;
    _uploading = true;
    try {
      // Pull in any points the native background service recorded while the
      // app UI was closed, so they upload in the same pass.
      await importNativeTrail();
      final db = LocalDbService.shared;
      final retention = await retentionHoursForCurrentUser();
      await db.pruneOfflineTrail(user.id, Duration(hours: retention));
      final all = await db.getOfflineTrail(user.id);
      if (all.isEmpty) return 0;
      // Drop anything older than chosen time (can't be matched anymore).
      final cutoff = DateTime.now().toUtc().subtract(
        Duration(hours: retention),
      );
      final fresh = all.where((p) {
        final ts = DateTime.tryParse(p['recorded_at']?.toString() ?? '');
        return ts != null && !ts.toUtc().isBefore(cutoff);
      }).toList();
      if (fresh.isEmpty) {
        if (deleteLocalOnSuccess) await db.clearOfflineTrail(user.id);
        return 0;
      }
      var acked = 0;
      for (var i = 0; i < fresh.length; i += uploadChunkSize) {
        final chunk = fresh.sublist(
          i,
          (i + uploadChunkSize > fresh.length)
              ? fresh.length
              : i + uploadChunkSize,
        );
        try {
          await Supabase.instance.client.rpc(
            'upload_offline_trail',
            params: {'p_points': chunk},
          );
          acked += chunk.length;
        } catch (_) {
          // Stop on first failing chunk; keep remainder locally for next retry.
          break;
        }
      }
      if (deleteLocalOnSuccess && acked >= fresh.length) {
        await db.clearOfflineTrail(user.id);
      }
      return acked;
    } finally {
      _uploading = false;
    }
  }

  /// "Delete my saved places now": wipes both sides.
  Future<void> deleteEverywhere() async {
    final user = Supabase.instance.client.auth.currentUser;
    try {
      await Supabase.instance.client.rpc('delete_my_offline_trail');
    } catch (_) {}
    if (user != null) {
      try {
        await LocalDbService.shared.clearOfflineTrail(user.id);
      } catch (_) {}
    }
    // Also wipe the native background-service buffer (Android).
    try {
      await NativeSecureStore.clearKeys([_nativeTrailKey]);
    } catch (_) {}
  }
}
