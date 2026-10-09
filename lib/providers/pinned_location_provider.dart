// lib/providers/pinned_location_provider.dart
// Owns the pinned home-base location feature on the client.
//
// - pin/extend/unpin via the step-1 RPCs (no GPS access here; pin uses the
//   last known position from currentLocationProvider).
// - mirrors state into PinnedLocationGate's SharedPreferences cache so every
//   GPS writer (Dart + native) gates locally with no network.
// - reconciles server-driven expiry (cron clears the flag) via realtime on
//   the own user_locations row + a 30s ticker as fallback.
// - posts a persistent in-app banner while pinned; resumes GPS on unpin/expire.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/location_deduplicator.dart';
import 'package:matchme/utils/offline_utils.dart';

class PinnedLocationState {
  final bool isActive;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final String? label;
  final double? latitude;
  final double? longitude;
  final bool isLoading;
  final bool initialized;
  final String? error;

  const PinnedLocationState({
    this.isActive = false,
    this.expiresAt,
    this.createdAt,
    this.label,
    this.latitude,
    this.longitude,
    this.isLoading = false,
    this.initialized = false,
    this.error,
  });

  Duration? remainingFrom(DateTime now) {
    final exp = expiresAt;
    if (!isActive || exp == null) return null;
    return exp.difference(now);
  }

  PinnedLocationState copyWith({
    bool? isActive,
    DateTime? expiresAt,
    DateTime? createdAt,
    String? label,
    double? latitude,
    double? longitude,
    bool? isLoading,
    bool? initialized,
    String? error,
  }) {
    return PinnedLocationState(
      isActive: isActive ?? this.isActive,
      expiresAt: expiresAt ?? this.expiresAt,
      createdAt: createdAt ?? this.createdAt,
      label: label ?? this.label,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isLoading: isLoading ?? this.isLoading,
      initialized: initialized ?? this.initialized,
      error: error,
    );
  }

  PinnedLocationState cleared() => const PinnedLocationState(initialized: true);
}

class PinnedLocationNotifier extends Notifier<PinnedLocationState> {
  Timer? _ticker;
  RealtimeChannel? _channel;
  String? _channelUserId;
  void Function()? _removeConnectivityListener;
  bool _pendingPinSyncInProgress = false;
  int? _lastNoticedExpiryMs;

  static const _bannerType = 'pinned_location';

  @override
  PinnedLocationState build() {
    // NOTE: no ref.keepAlive() here — this is a manual (non-autoDispose)
    // NotifierProvider, so it already lives for the whole app session.
    // keepAlive() on a non-autoDispose provider throws at build time, which
    // release builds render as a grey box where the card should be.
    ref.onDispose(() {
      _ticker?.cancel();
      _ticker = null;
      _clearRealtime();
      _removeConnectivityListener?.call();
      _removeConnectivityListener = null;
    });
    _removeConnectivityListener = onSupabaseResume(() {
      unawaited(_syncPendingPin());
    });
    // The persistent banner is irrelevant while invisible: hide it when
    // visibility drops, re-post it when visibility returns while pinned.
    // (The in-map PinnedMapStatusBanner widgets gate themselves the same
    // way; this keeps the overlay banner consistent with them.)
    ref.listen(isVisibleProvider, (prev, next) {
      if (!ref.mounted) return;
      if (!state.isActive) return;
      if (next == false) {
        unawaited(_clearBanner());
      } else if (next == true && prev == false) {
        unawaited(_postBanner());
      }
    });
    Future.microtask(() => _init());
    return const PinnedLocationState();
  }

  Future<void> _init() async {
    var hasPendingPin = false;
    try {
      await _restorePendingPin();
      hasPendingPin = await PinnedLocationGate.readPendingPin() != null;
    } catch (error, stackTrace) {
      debugPrint(
        '[PinnedLoc] Could not restore pending pin: $error\n$stackTrace',
      );
    }
    if (!ref.mounted) return;
    if (hasPendingPin) {
      _ensureRealtime();
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
      return;
    }
    // Cache-first: seed from local gate cache instantly (memory + disk) so
    // UI renders without waiting for server, then reconcile in background.
    try {
      final active = await PinnedLocationGate.isActive();
      if (ref.mounted && active) {
        final prefs = await _readGatePrefs();
        state = PinnedLocationState(
          isActive: true,
          expiresAt: prefs.expiresAt,
          createdAt: prefs.createdAt,
          label: prefs.label,
          initialized: true,
        );
      }
    } catch (_) {}
    await refresh();
    _ensureRealtime();
    _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  /// Read label/expiry from the gate's SharedPreferences cache (no network).
  Future<({DateTime? expiresAt, DateTime? createdAt, String? label})>
  _readGatePrefs() async {
    try {
      final prefs = await PinnedLocationGate.readCachePrefs();
      return (
        expiresAt: prefs.expiresAt,
        createdAt: prefs.createdAt,
        label: prefs.label,
      );
    } catch (_) {
      return (expiresAt: null, createdAt: null, label: null);
    }
  }

  Future<void> _restorePendingPin() async {
    final pending = await PinnedLocationGate.readPendingPin();
    if (pending == null) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null && pending.userId != userId) {
      await PinnedLocationGate.clearPendingPin();
      await PinnedLocationGate.clearPinCache();
      return;
    }
    if (!pending.expiresAt.isAfter(DateTime.now().toUtc())) {
      await PinnedLocationGate.clearPendingPin();
      await PinnedLocationGate.clearPinCache();
      return;
    }

    await PinnedLocationGate.writePinCache(
      expiresAt: pending.expiresAt,
      createdAt: pending.createdAt,
      label: pending.label,
    );
    if (!ref.mounted) return;
    state = PinnedLocationState(
      isActive: true,
      expiresAt: pending.expiresAt,
      createdAt: pending.createdAt,
      label: pending.label,
      initialized: true,
    );
    try {
      await ref
          .read(isVisibleProvider.notifier)
          .updateLocationStreamInterval(force: true);
    } catch (_) {}
    await _notifyNativePinnedStateChanged();
    await _postBanner();
    await _syncPendingPin();
  }

  void _tick() {
    if (!ref.mounted) return;
    final s = state;
    if (!s.isActive || s.expiresAt == null) return;
    if (s.expiresAt!.isBefore(DateTime.now().toUtc())) {
      // Local expiry tripped before server reconcile: fail open to GPS.
      unawaited(_handleExpired(expiresAt: s.expiresAt));
    } else {
      unawaited(_syncPendingPin());
      // Refresh countdown UI without changing state identity semantics.
      state = s.copyWith();
    }
  }

  /// Pull server truth and reconcile cache/banner/GPS.
  Future<void> refresh() async {
    if (!ref.mounted) return;
    try {
      final pending = await PinnedLocationGate.readPendingPin();
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (pending != null &&
          pending.userId == userId &&
          pending.expiresAt.isAfter(DateTime.now().toUtc())) {
        return;
      }
      final server = await PinnedLocationGate.fetchServerState();
      if (!ref.mounted) return;
      if (server == null) {
        state = state.copyWith(initialized: true);
        return;
      }
      if (server.active && server.expiresAt != null) {
        await PinnedLocationGate.writePinCache(
          expiresAt: server.expiresAt!,
          createdAt: server.createdAt,
          label: server.label,
        );
        state = PinnedLocationState(
          isActive: true,
          expiresAt: server.expiresAt,
          createdAt: server.createdAt,
          label: server.label,
          latitude: server.lat,
          longitude: server.lng,
          initialized: true,
        );
        _lastNoticedExpiryMs = null;
        await _postBanner();
        // Server reconcile can activate a pin (e.g. set elsewhere): park
        // the GPS timer here too, not just on the pin button path.
        try {
          await ref
              .read(isVisibleProvider.notifier)
              .updateLocationStreamInterval(force: true);
        } catch (_) {}
        // Server reconcile can activate a pin (e.g. set elsewhere): make
        // sure the native side suppresses its notification / GPS as well.
        await _notifyNativePinnedStateChanged();
      } else {
        if (state.isActive) {
          await _handleExpired(expiresAt: state.expiresAt);
        } else {
          await PinnedLocationGate.clearPinCache();
          state = const PinnedLocationState(initialized: true);
          await _clearBanner();
        }
      }
    } catch (_) {
      if (ref.mounted) state = state.copyWith(initialized: true);
    }
  }

  /// Pin the last known position. Never triggers a fresh GPS fix here;
  /// if nothing is cached yet, one single refresh is attempted.
  Future<void> pinCurrent({required Duration duration, String? label}) async {
    if (state.isLoading) return;
    if (duration <= Duration.zero || duration > const Duration(days: 14)) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Pinned location duration must be 14 days or less',
      );
    }
    state = state.copyWith(isLoading: true, error: null);
    var savingOfflineIntent = false;
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        throw StateError('Authentication is required to pin a location');
      }
      final normalizedLabel = (label ?? '').trim();
      var pos = ref.read(currentLocationProvider);
      if (pos == null && !shouldSkipSupabaseCalls()) {
        try {
          await ref.read(currentLocationProvider.notifier).refreshLocation();
        } catch (_) {}
        pos = ref.read(currentLocationProvider);
      }
      if (shouldSkipSupabaseCalls()) {
        savingOfflineIntent = true;
        await _saveOfflinePin(
          userId: userId,
          duration: duration,
          label: normalizedLabel,
          position: pos,
        );
        return;
      }
      // Anti-fraud (migration 20262087000000): the server pins the position
      // IT has observed from live GPS and ignores the coordinates sent
      // here (kept for signature compatibility). A missing local cached fix
      // is therefore not fatal — the server decides whether its own
      // observation is fresh enough to pin.
      final res = await client.rpc(
        'pin_current_location',
        params: {
          'p_user_id': userId,
          'p_latitude': pos?.latitude,
          'p_longitude': pos?.longitude,
          'p_label': normalizedLabel.isEmpty ? null : normalizedLabel,
          'p_duration_seconds': duration.inSeconds,
        },
      );
      final expiresAt = DateTime.parse(res.toString()).toUtc();
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
        createdAt: expiresAt.subtract(duration),
        label: normalizedLabel,
      );
      await PinnedLocationGate.clearPendingPin();
      if (!ref.mounted) return;
      state = PinnedLocationState(
        isActive: true,
        expiresAt: expiresAt,
        createdAt: expiresAt.subtract(duration),
        label: normalizedLabel.isEmpty ? null : normalizedLabel,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
        initialized: true,
      );
      if (pos == null) {
        // Hydrate the pinned coordinates from server truth.
        unawaited(refresh());
      }
      _lastNoticedExpiryMs = null;
      await _postBanner();
      // Park the Dart GPS timer NOW (no 5s wakeups/log spam while pinned;
      // slow silent heartbeat keeps presence instead). Unpin/expire resume
      // via _resumeLiveGps.
      try {
        await ref
            .read(isVisibleProvider.notifier)
            .updateLocationStreamInterval(force: true);
      } catch (_) {}
      // Native side: suppress the persistent notification and stop GPS
      // polling while the pin is active (matching continues server-side,
      // chat notifications still arrive via FCM).
      await _notifyNativePinnedStateChanged();
      print(
        '[${DateTime.now().toIso8601String()}] 📌 [PinnedLoc] Pinned location SET (${pos?.latitude}, ${pos?.longitude}) label=${(label ?? '').trim().isEmpty ? '-' : label!.trim()} expires=$expiresAt — GPS paused, GPS not accessed anymore',
      );
      // Realtime: tell every match partner immediately (match row + profile).
      _broadcastOwnPinned(isPinned: true, expiresAt: expiresAt);
    } catch (e) {
      if (!savingOfflineIntent &&
          (isExpectedOfflineFailure(e) || shouldSkipSupabaseCalls())) {
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          final pos = ref.read(currentLocationProvider);
          savingOfflineIntent = true;
          await _saveOfflinePin(
            userId: userId,
            duration: duration,
            label: (label ?? '').trim(),
            position: pos,
          );
          return;
        }
      }
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
    if (ref.mounted) state = state.copyWith(isLoading: false, error: null);
  }

  Future<void> _saveOfflinePin({
    required String userId,
    required Duration duration,
    required String label,
    required Position? position,
  }) async {
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(duration);
    final normalizedLabel = label.isEmpty ? null : label;
    try {
      await PinnedLocationGate.writePendingPin(
        userId: userId,
        expiresAt: expiresAt,
        createdAt: now,
        label: normalizedLabel,
      );
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
        createdAt: now,
        label: normalizedLabel,
      );
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: error.toString());
      }
      rethrow;
    }
    if (!ref.mounted) return;
    state = PinnedLocationState(
      isActive: true,
      expiresAt: expiresAt,
      createdAt: now,
      label: normalizedLabel,
      latitude: position?.latitude,
      longitude: position?.longitude,
      isLoading: false,
      initialized: true,
    );
    _lastNoticedExpiryMs = null;
    await _postBanner();
    try {
      await ref
          .read(isVisibleProvider.notifier)
          .updateLocationStreamInterval(force: true);
    } catch (_) {}
    await _notifyNativePinnedStateChanged();
    debugPrint(
      '[PinnedLoc] Saved offline pin intent for $userId; awaiting Supabase sync',
    );
  }

  Future<void> _syncPendingPin() async {
    if (_pendingPinSyncInProgress || shouldSkipSupabaseCalls()) return;
    _pendingPinSyncInProgress = true;
    try {
      final pending = await PinnedLocationGate.readPendingPin();
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (pending == null || userId == null) return;
      if (pending.userId != userId) {
        await PinnedLocationGate.clearPendingPin();
        await PinnedLocationGate.clearPinCache();
        if (ref.mounted) state = const PinnedLocationState(initialized: true);
        return;
      }

      final now = DateTime.now().toUtc();
      final remainingSeconds = pending.expiresAt.difference(now).inSeconds;
      if (remainingSeconds < 60) {
        await PinnedLocationGate.clearPendingPin();
        await PinnedLocationGate.clearPinCache();
        if (ref.mounted) state = const PinnedLocationState(initialized: true);
        await _clearBanner();
        await _resumeLiveGps();
        await _notifyNativePinnedStateChanged();
        return;
      }

      if (pending.action == 'extend') {
        final server = await PinnedLocationGate.fetchServerState();
        if (server == null) {
          throw StateError('Unable to read pinned location before extending');
        }
        if (!server.active || server.expiresAt == null) {
          await PinnedLocationGate.clearPendingPin();
          await PinnedLocationGate.clearPinCache();
          if (ref.mounted) {
            state = const PinnedLocationState(initialized: true);
          }
          await _clearBanner();
          await _resumeLiveGps();
          await _notifyNativePinnedStateChanged();
          return;
        }

        final extraSeconds = pending.expiresAt
            .difference(server.expiresAt!)
            .inSeconds;
        final maxExpiry = server.createdAt?.add(const Duration(days: 14));
        if (maxExpiry == null || pending.expiresAt.isAfter(maxExpiry)) {
          throw StateError('Pinned location cannot exceed 14 days total');
        }
        var expiresAt = server.expiresAt!;
        if (extraSeconds >= 60) {
          final result = await client.rpc(
            'extend_pinned_location',
            params: {'p_user_id': userId, 'p_extra_seconds': extraSeconds},
          );
          expiresAt = DateTime.parse(result.toString()).toUtc();
        }
        await PinnedLocationGate.writePinCache(
          expiresAt: expiresAt,
          createdAt: server.createdAt,
          label: pending.label ?? server.label,
        );
        if (ref.mounted) {
          state = PinnedLocationState(
            isActive: true,
            expiresAt: expiresAt,
            createdAt: server.createdAt,
            label: pending.label ?? server.label,
            latitude: server.lat,
            longitude: server.lng,
            initialized: true,
          );
        }
        await PinnedLocationGate.clearPendingPin();
        await _postBanner();
        await _notifyNativePinnedStateChanged();
        _broadcastOwnPinned(isPinned: true, expiresAt: expiresAt);
        debugPrint('[PinnedLoc] Offline pin extension synchronized');
        return;
      }

      final params = {
        'p_user_id': userId,
        'p_label': pending.label,
        'p_duration_seconds': remainingSeconds.clamp(60, 1209600),
      };
      var result = await client.rpc(
        'pin_current_location_from_observation',
        params: params,
      );
      if (result == null) {
        final position = await _acquireFreshPosition();
        await client.rpc(
          'update_user_location',
          params: {
            'p_user_id': userId,
            'p_latitude': position.latitude,
            'p_longitude': position.longitude,
            'p_speed': position.speed,
            'p_heading': position.heading,
          },
        );
        result = await client.rpc(
          'pin_current_location_from_observation',
          params: params,
        );
      }
      if (result is! Map) {
        throw StateError(
          'Supabase did not return the pinned location after syncing',
        );
      }

      final expiresAt = DateTime.parse(result['expires_at'].toString()).toUtc();
      final latitude = (result['latitude'] as num).toDouble();
      final longitude = (result['longitude'] as num).toDouble();
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
        createdAt: DateTime.parse(result['created_at'].toString()).toUtc(),
        label: pending.label,
      );
      if (ref.mounted) {
        state = PinnedLocationState(
          isActive: true,
          expiresAt: expiresAt,
          createdAt: DateTime.parse(result['created_at'].toString()).toUtc(),
          label: pending.label,
          latitude: latitude,
          longitude: longitude,
          initialized: true,
        );
      }
      await PinnedLocationGate.clearPendingPin();
      await _postBanner();
      await _notifyNativePinnedStateChanged();
      _broadcastOwnPinned(isPinned: true, expiresAt: expiresAt);
      debugPrint('[PinnedLoc] Offline pin synchronized to Supabase');
    } catch (error, stackTrace) {
      debugPrint('[PinnedLoc] Offline pin sync failed: $error\n$stackTrace');
    } finally {
      _pendingPinSyncInProgress = false;
    }
  }

  Future<Position> _acquireFreshPosition() async {
    final locationService = ref.read(locationServiceProvider);
    if (!await locationService.handleLocationPermission()) {
      throw StateError('Location permission is required to finish pin setup');
    }
    final position = await LocationDeduplicator.getPosition(
      label: 'offlinePinnedLocationSync',
      fetcher: () => Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      ).timeout(const Duration(seconds: 15)),
    );
    if (position == null) {
      throw StateError('No fresh location was available to finish pin setup');
    }
    await ref
        .read(currentLocationProvider.notifier)
        .updateFromService(position);
    return position;
  }

  Future<void> extend({required Duration extra}) async {
    if (state.isLoading || !state.isActive) return;
    state = state.copyWith(isLoading: true, error: null);
    var savingOfflineIntent = false;
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        throw StateError('Authentication is required to extend a pin');
      }
      final createdAt = state.createdAt;
      final currentExpiry = state.expiresAt;
      if (createdAt == null ||
          currentExpiry == null ||
          currentExpiry.add(extra).isAfter(
            createdAt.add(const Duration(days: 14)),
          )) {
        throw StateError('Pinned location cannot exceed 14 days total');
      }
      if (shouldSkipSupabaseCalls()) {
        savingOfflineIntent = true;
        await _saveOfflineExtension(userId: userId, extra: extra);
        return;
      }
      final pending = await PinnedLocationGate.readPendingPin();
      if (pending != null) {
        savingOfflineIntent = true;
        await _saveOfflineExtension(userId: userId, extra: extra);
        return;
      }
      final res = await client.rpc(
        'extend_pinned_location',
        params: {'p_user_id': userId, 'p_extra_seconds': extra.inSeconds},
      );
      final expiresAt = DateTime.parse(res.toString()).toUtc();
      await PinnedLocationGate.clearPendingPin();
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
        createdAt: state.createdAt,
        label: state.label,
      );
      if (!ref.mounted) return;
      state = state.copyWith(expiresAt: expiresAt, isLoading: false);
      _lastNoticedExpiryMs = null;
      await _postBanner();
      print(
        '[${DateTime.now().toIso8601String()}] 📌 [PinnedLoc] Pinned location EXTENDED — new expiry=$expiresAt, GPS stays paused',
      );
      // Realtime: refreshed expiry must reach partners immediately.
      _broadcastOwnPinned(isPinned: true, expiresAt: expiresAt);
    } catch (e) {
      if (!savingOfflineIntent &&
          (isExpectedOfflineFailure(e) || shouldSkipSupabaseCalls())) {
        final userId = Supabase.instance.client.auth.currentUser?.id;
        if (userId != null) {
          savingOfflineIntent = true;
          await _saveOfflineExtension(userId: userId, extra: extra);
          return;
        }
      }
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
  }

  Future<void> _saveOfflineExtension({
    required String userId,
    required Duration extra,
  }) async {
    final currentExpiry = state.expiresAt;
    final createdAt = state.createdAt;
    if (currentExpiry == null ||
        createdAt == null ||
        !currentExpiry.isAfter(DateTime.now().toUtc())) {
      throw StateError('There is no active pinned location to extend');
    }
    final requestedExpiry = currentExpiry.add(extra);
    if (requestedExpiry.isAfter(createdAt.add(const Duration(days: 14)))) {
      throw StateError('Pinned location cannot exceed 14 days total');
    }
    try {
      await PinnedLocationGate.writePendingExtension(
        userId: userId,
        expiresAt: requestedExpiry,
        createdAt: createdAt,
        extra: extra,
        label: state.label,
      );
      await PinnedLocationGate.writePinCache(
        expiresAt: requestedExpiry,
        createdAt: createdAt,
        label: state.label,
      );
    } catch (error) {
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: error.toString());
      }
      rethrow;
    }
    if (!ref.mounted) return;
    state = state.copyWith(
      expiresAt: requestedExpiry,
      isLoading: false,
      error: null,
    );
    _lastNoticedExpiryMs = null;
    await _postBanner();
    _broadcastOwnPinned(isPinned: true, expiresAt: requestedExpiry);
    debugPrint(
      '[PinnedLoc] Saved offline pin extension for $userId; awaiting Supabase sync',
    );
    if (!shouldSkipSupabaseCalls()) {
      unawaited(_syncPendingPin());
    }
  }

  Future<void> unpin() async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      await PinnedLocationGate.clearPendingPin();
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        try {
          await Supabase.instance.client.rpc(
            'unpin_location',
            params: {'p_user_id': uid},
          );
        } catch (_) {}
      }
      await PinnedLocationGate.clearPinCache();
      if (!ref.mounted) return;
      state = const PinnedLocationState(initialized: true);
      await _clearBanner();
      print(
        '[${DateTime.now().toIso8601String()}] ▶️ [PinnedLoc] Pinned location REMOVED by user — GPS resumed',
      );
      await _resumeLiveGps();
      // Native side: re-evaluate the foreground notification / GPS polling
      // now that the pin is gone.
      await _notifyNativePinnedStateChanged();
      // Realtime: removal (+ resume of live GPS) must reach partners
      // immediately in their match row + match profile.
      _broadcastOwnPinned(isPinned: false);
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
  }

  /// Fire-and-forget broadcast of our own pinned flag to match partners.
  /// Best-effort: receivers fall back to the 30s RPC poll + resume refresh.
  void _broadcastOwnPinned({required bool isPinned, DateTime? expiresAt}) {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null || uid.trim().isEmpty) return;
      unawaited(
        broadcastPinnedChanged(uid, isPinned: isPinned, expiresAt: expiresAt),
      );
    } catch (_) {}
  }

  Future<void> _handleExpired({DateTime? expiresAt}) async {
    final expiryMs = expiresAt?.toUtc().millisecondsSinceEpoch;
    await PinnedLocationGate.clearPendingPin();
    await PinnedLocationGate.clearPinCache();
    if (!ref.mounted) return;
    state = const PinnedLocationState(initialized: true);
    await _clearBanner();
    print(
      '[${DateTime.now().toIso8601String()}] ⌛ [PinnedLoc] Pinned location EXPIRED (was $expiresAt) — GPS resumed',
    );
    await _resumeLiveGps();
    // Native side: re-evaluate the foreground notification / GPS polling
    // now that the pin is gone.
    await _notifyNativePinnedStateChanged();
    // Realtime: local expiry (ticker / server reconcile) must also notify
    // partners immediately; server cron expiry while we're offline is covered
    // by the viewers' 30s poll + users-table trigger post-migration.
    _broadcastOwnPinned(isPinned: false);
    // One transient notice per expiry so the ticker doesn't spam.
    if (expiryMs != null && expiryMs == _lastNoticedExpiryMs) return;
    _lastNoticedExpiryMs = expiryMs;
    try {
      final l10n = ref.read(localizationProvider);
      ref
          .read(systemNotificationProvider.notifier)
          .notify(
            SystemNotification(
              text: l10n.getString('pinnedLocationExpired'),
              notificationType: 'pinned_location_expired',
            ),
          );
    } catch (_) {}
  }

  /// Best-effort signal so the native service re-evaluates the persistent
  /// notification and GPS polling right away on pin changes. Never throws
  /// and never blocks pin/unpin flows (e.g. on web/desktop or when the
  /// native channel is unavailable).
  Future<void> _notifyNativePinnedStateChanged() async {
    try {
      await BackgroundService.notifyPinnedStateChanged();
    } catch (_) {}
  }

  Future<void> _resumeLiveGps() async {
    // Only resume GPS when the user is actually visible: unpinning or
    // expiry while invisible must not restart location tracking.
    try {
      if (!ref.read(isVisibleProvider)) return;
    } catch (_) {}
    try {
      await ref.read(isVisibleProvider.notifier).updateLocationStreamInterval();
    } catch (_) {}
  }

  Future<void> _postBanner() async {
    try {
      // No banner while invisible: nothing is broadcast, so there is
      // nothing to announce. The visibility listener above re-posts when
      // the user becomes visible again while the pin is still active.
      // Background execution and notifications are unaffected — a pinned
      // app access no GPS, so it keeps functioning in the background and
      // notifications keep arriving even with the UI closed.
      try {
        if (!ref.read(isVisibleProvider)) return;
      } catch (_) {}
      if (!state.isActive) return;
      final l10n = ref.read(localizationProvider);
      final label = state.label;
      final text = l10n.getString(
        'pinnedLocationBanner',
        params: {'label': (label == null || label.isEmpty) ? '' : ' "$label"'},
      );
      ref
          .read(systemNotificationProvider.notifier)
          .notify(
            SystemNotification(
              text: text,
              isPersistent: true,
              notificationType: _bannerType,
              actionText: l10n.getString('pinnedLocationManage'),
            ),
          );
    } catch (_) {}
  }

  Future<void> _clearBanner() async {
    try {
      ref.read(systemNotificationProvider.notifier).clearType(_bannerType);
    } catch (_) {}
  }

  void _clearRealtime() {
    final uid = _channelUserId;
    _channel = null;
    _channelUserId = null;
    if (uid != null) {
      try {
        SupabaseRealtimeManager.instance.unregister('pinned_location_$uid');
      } catch (_) {}
    }
  }

  void _ensureRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      _clearRealtime();
      return;
    }
    if (_channel != null && _channelUserId == uid) return;
    _clearRealtime();
    final channelName = 'pinned_location_$uid';
    try {
      SupabaseRealtimeManager.instance.register(channelName, () {
        _channel = Supabase.instance.client
            .channel(channelName)
            .onPostgresChanges(
              event: PostgresChangeEvent.update,
              schema: 'public',
              table: 'user_locations',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'user_id',
                value: uid,
              ),
              callback: (_) {
                if (!ref.mounted) return;
                unawaited(refresh());
              },
            )
            .subscribe();
        _channelUserId = uid;
        return _channel!;
      });
    } catch (_) {}
  }
}

final pinnedLocationProvider =
    NotifierProvider<PinnedLocationNotifier, PinnedLocationState>(
      PinnedLocationNotifier.new,
    );
