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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/pinned_partner_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';

class PinnedLocationState {
  final bool isActive;
  final DateTime? expiresAt;
  final String? label;
  final double? latitude;
  final double? longitude;
  final bool isLoading;
  final bool initialized;
  final String? error;

  const PinnedLocationState({
    this.isActive = false,
    this.expiresAt,
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
    // Cache-first: seed from local gate cache instantly (memory + disk) so
    // UI renders without waiting for server, then reconcile in background.
    try {
      final active = await PinnedLocationGate.isActive();
      if (ref.mounted && active) {
        final prefs = await _readGatePrefs();
        state = PinnedLocationState(
          isActive: true,
          expiresAt: prefs.expiresAt,
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
  Future<({DateTime? expiresAt, String? label})> _readGatePrefs() async {
    try {
      final prefs = await PinnedLocationGate.readCachePrefs();
      return (expiresAt: prefs.expiresAt, label: prefs.label);
    } catch (_) {
      return (expiresAt: null, label: null);
    }
  }

  void _tick() {
    if (!ref.mounted) return;
    final s = state;
    if (!s.isActive || s.expiresAt == null) return;
    if (s.expiresAt!.isBefore(DateTime.now().toUtc())) {
      // Local expiry tripped before server reconcile: fail open to GPS.
      unawaited(_handleExpired(expiresAt: s.expiresAt));
    } else {
      // Refresh countdown UI without changing state identity semantics.
      state = s.copyWith();
    }
  }

  /// Pull server truth and reconcile cache/banner/GPS.
  Future<void> refresh() async {
    if (!ref.mounted) return;
    try {
      final server = await PinnedLocationGate.fetchServerState();
      if (!ref.mounted) return;
      if (server == null) {
        state = state.copyWith(initialized: true);
        return;
      }
      if (server.active && server.expiresAt != null) {
        await PinnedLocationGate.writePinCache(
          expiresAt: server.expiresAt!,
          label: server.label,
        );
        state = PinnedLocationState(
          isActive: true,
          expiresAt: server.expiresAt,
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
    state = state.copyWith(isLoading: true, error: null);
    try {
      var pos = ref.read(currentLocationProvider);
      if (pos == null) {
        try {
          await ref.read(currentLocationProvider.notifier).refreshLocation();
        } catch (_) {}
        pos = ref.read(currentLocationProvider);
      }
      if (pos == null) throw Exception('no cached position to pin');
      final res = await Supabase.instance.client.rpc(
        'pin_current_location',
        params: {
          'p_user_id': Supabase.instance.client.auth.currentUser!.id,
          'p_latitude': pos.latitude,
          'p_longitude': pos.longitude,
          'p_label': (label ?? '').trim().isEmpty ? null : label!.trim(),
          'p_duration_seconds': duration.inSeconds,
        },
      );
      final expiresAt = DateTime.parse(res.toString()).toUtc();
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
        label: label,
      );
      if (!ref.mounted) return;
      state = PinnedLocationState(
        isActive: true,
        expiresAt: expiresAt,
        label: (label ?? '').trim().isEmpty ? null : label!.trim(),
        latitude: pos.latitude,
        longitude: pos.longitude,
        initialized: true,
      );
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
        '[${DateTime.now().toIso8601String()}] 📌 [PinnedLoc] Pinned location SET (${pos.latitude}, ${pos.longitude}) label=${(label ?? '').trim().isEmpty ? '-' : label!.trim()} expires=$expiresAt — GPS paused, GPS not accessed anymore',
      );
      // Realtime: tell every match partner immediately (match row + profile).
      _broadcastOwnPinned(isPinned: true, expiresAt: expiresAt);
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
    if (ref.mounted) state = state.copyWith(isLoading: false, error: null);
  }

  Future<void> extend({required Duration extra}) async {
    if (state.isLoading || !state.isActive) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
      final res = await Supabase.instance.client.rpc(
        'extend_pinned_location',
        params: {
          'p_user_id': Supabase.instance.client.auth.currentUser!.id,
          'p_extra_seconds': extra.inSeconds,
        },
      );
      final expiresAt = DateTime.parse(res.toString()).toUtc();
      await PinnedLocationGate.writePinCache(
        expiresAt: expiresAt,
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
      if (ref.mounted) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      rethrow;
    }
  }

  Future<void> unpin() async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, error: null);
    try {
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
