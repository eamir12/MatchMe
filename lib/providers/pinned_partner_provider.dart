// lib/providers/pinned_partner_provider.dart
// Realtime partner pinned home-base status.
//
// PROBLEM:
// - `user_locations` RLS only allows reading your OWN row, so user B can NOT
//   receive `postgres_changes` for user A's pin/unpin directly.
// - The old `_pinnedPartnerProvider` in match_box.dart used a 5-minute
//   keepAlive cache with no realtime -> partner saw pin/unpin up to 5 min late.
//
// SOLUTION (mirrors match_rating_provider.dart):
// - `pinnedPartnerProvider(partnerId)` reads via the SECURITY DEFINER RPC
//   `is_pinned_location_active` (allowed for any authenticated user).
// - `pinnedPartnerRealtimeProvider` keeps it fresh in realtime via:
//   1) Public Realtime Broadcast `pinned_location_updates` / `pinned_changed`
//      sent by the actor's client in pinned_location_provider.dart on
//      pin/extend/unpin/expire. Payload carries only user_id + bool (+ expiry),
//      no coordinates, so no location leak. Bypasses user_locations RLS.
//   2) `postgres_changes` UPDATEs on `users` for the partner (users is
//      readable by all + realtime-enabled). After the server migration
//      20262016000000, pin changes also sync to users.is_pinned_location_active
//      via trigger, so even server-side expiry (cron, actor offline) notifies.
//      Pre-migration this still fires on unrelated profile edits and triggers
//      an RPC refresh (harmless, low volume).
//   3) 30s safety-net poll + connectivity-resume refresh so offline gaps and
//      expiries still converge quickly.
//
// Both MatchBox (match row) and MatchProfileScreen watch this, so pin + unpin
// (+ resume live GPS, which clears the flag server-side) appear immediately.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/shared_realtime_tables.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Broadcast topic + event for pinned-status changes.
///
/// Payload: {'user_id': <actorUid>, 'is_pinned': <bool>, 'expires_at': <iso?>}
/// No coordinates are ever broadcast.
const String kPinnedUpdatesChannel = 'pinned_location_updates';
const String kPinnedChangedEvent = 'pinned_changed';

class _PinnedCacheEntry {
  _PinnedCacheEntry(this.value, this.at);

  final bool value;
  final DateTime at;
}

/// Short TTL cache for [pinnedPartnerProvider] results.
///
/// Every watched partner used to run its own `is_pinned_location_active`
/// RPC on each invalidation, and a single refresh burst (30s poll tick,
/// resume, users-table UPDATE fan-out) invalidated ALL watched partners at
/// once — the 9-call fan-out seen in prod. A short TTL absorbs the bursts:
/// within the window the cached verdict is served, outside it the RPC runs
/// fresh. Direct realtime values (broadcast `is_pinned`, users-row flag)
/// seed the cache so a pushed update is served immediately without any
/// refetch, and expiry is still caught by the RPC at most one TTL later.
const Duration _pinnedCacheTtl = Duration(seconds: 20);
final Map<String, _PinnedCacheEntry> _pinnedCache = {};

/// Whether [partnerId]'s matching currently uses a pinned home-base location.
///
/// Fail-closed to false on any error / empty id / offline.
final pinnedPartnerProvider = FutureProvider.family.autoDispose<bool, String>((
  ref,
  partnerId,
) async {
  final id = partnerId.trim();
  if (id.isEmpty) return false;
  if (shouldSkipSupabaseCalls()) return false;
  final cached = _pinnedCache[id];
  if (cached != null &&
      DateTime.now().difference(cached.at) < _pinnedCacheTtl) {
    return cached.value;
  }
  try {
    final res = await Supabase.instance.client.rpc(
      'is_pinned_location_active',
      params: {'p_user_id': id},
    );
    final value = res == true;
    _pinnedCache[id] = _PinnedCacheEntry(value, DateTime.now());
    return value;
  } catch (_) {
    return false;
  }
});

/// Best-effort broadcast that [userId]'s pinned flag changed.
///
/// Called by the actor after pin/extend/unpin/expire. Receivers refresh via
/// the RPC above, so the broadcast itself carries no sensitive data.
Future<void> broadcastPinnedChanged(
  String userId, {
  required bool isPinned,
  DateTime? expiresAt,
}) async {
  final id = userId.trim();
  if (id.isEmpty || shouldSkipSupabaseCalls()) return;
  RealtimeChannel? channel;
  try {
    final client = Supabase.instance.client;
    channel = client.channel(kPinnedUpdatesChannel);
    final subscribed = Completer<void>();
    channel.onBroadcast(event: kPinnedChangedEvent, callback: (_) {});
    channel.subscribe((status, err) {
      if (!subscribed.isCompleted) subscribed.complete();
    });
    try {
      await subscribed.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Continue best-effort.
    }
    try {
      await channel
          .sendBroadcastMessage(
            event: kPinnedChangedEvent,
            payload: {
              'user_id': id,
              'is_pinned': isPinned,
              if (expiresAt != null)
                'expires_at': expiresAt.toUtc().toIso8601String(),
            },
          )
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Best-effort only.
    }
  } catch (e) {
    debugPrint('📍 Pinned broadcast send failed (best-effort): $e');
  } finally {
    if (channel != null) {
      try {
        await Supabase.instance.client
            .removeChannel(channel)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
  }
}

/// Keeps [pinnedPartnerProvider] fresh in realtime for every visible partner.
///
/// Watch it (e.g. `ref.watch(pinnedPartnerRealtimeProvider)`) in any screen
/// showing MatchBox rows or a MatchProfile so the broadcast subscription stays
/// alive. The notifier rebuilds when the signed-in user changes.
class PinnedPartnerRealtimeNotifier extends Notifier<int> {
  Timer? _pollTimer;
  void Function()? _resumeDispose;
  String? _channelUserId;
  SharedTableSubscription? _usersSubscription;
  int _seenUpdates = 0;

  /// Partner id from the most recent signal. Null after bulk refreshes.
  String? lastUpdatedUserId;

  @override
  int build() {
    final authUserId = ref.watch(
      authStateProvider.select((async) => async.value?.session?.user.id),
    );
    final userId = authUserId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      _cleanup();
      _channelUserId = null;
      return _seenUpdates;
    }
    _channelUserId = userId;

    ref.onDispose(_cleanup);

    _resumeDispose?.call();
    _resumeDispose = onSupabaseResume(() {
      if (!ref.mounted) return;
      if (shouldSkipSupabaseCalls()) return;
      final current = Supabase.instance.client.auth.currentUser?.id;
      if (current == null || current != _channelUserId) return;
      _setupChannels();
      _refreshAll();
    });

    if (!shouldSkipSupabaseCalls()) {
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!ref.mounted) return;
        if (shouldSkipSupabaseCalls()) return;
        if (Supabase.instance.client.auth.currentUser?.id != _channelUserId) {
          return;
        }
        _setupChannels();
      });
    }

    _pollTimer?.cancel();
    // 30s matches rating realtime cadence: converges expiries + missed
    // broadcasts (e.g. actor's cron expiry while viewer offline) without
    // spamming the RPC (only refetches watched partners).
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!ref.mounted) return;
      if (shouldSkipSupabaseCalls()) return;
      if (Supabase.instance.client.auth.currentUser?.id != _channelUserId) {
        return;
      }
      _refreshAll();
    });

    return _seenUpdates;
  }

  void _setupChannels() {
    final userId = _channelUserId;
    if (userId == null || userId.isEmpty) return;

    // 1) Public broadcast — primary path for pin/unpin/extend. Registered
    // under the channel's real topic (the bare name the server broadcasts
    // on): the manager's health check verifies channels by registered name,
    // so a suffixed registration here would never match the live topic and
    // the channel would be torn down and re-created forever.
    SupabaseRealtimeManager.instance.register(kPinnedUpdatesChannel, () {
      if (Supabase.instance.client.auth.currentSession == null) {
        throw Exception(
          'No active session — skipping pinned broadcast subscription',
        );
      }
      final channel = Supabase.instance.client.channel(kPinnedUpdatesChannel);
      channel.onBroadcast(
        event: kPinnedChangedEvent,
        callback: (payload) {
          if (!ref.mounted) return;
          if (Supabase.instance.client.auth.currentSession == null) return;
          final changedId = _extractUserId(payload);
          if (changedId == null || changedId.isEmpty) return;
          _handlePartnerUpdated(
            changedId,
            source: 'broadcast',
            knownValue: _extractBool(payload, 'is_pinned'),
          );
        },
      );
      channel.subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          debugPrint('📍 Pinned realtime: broadcast subscribed');
        } else if (handleExpectedSupabaseOfflineFailure(err)) {
          return;
        } else if (SupabaseRealtimeManager.instance.isPaused) {
          return;
        } else if (err != null &&
            !isExpectedOfflineFailure(err) &&
            !isAuthRateLimitFailure(err)) {
          debugPrint('📍 Pinned realtime broadcast error: $err');
        }
      });
      return channel;
    });

    // 2) users-table UPDATEs — secondary path. `users` is SELECT-readable by
    // all authenticated + in the realtime publication, so partner updates
    // arrive here. Post-migration the pin trigger bumps this row on every pin
    // change (including server-side cron expiry); pre-migration any profile
    // edit still triggers a cheap RPC refresh.
    _usersSubscription ??= SharedRealtimeTables.instance.subscribe(
      table: SharedRealtimeTable.users,
      userId: userId,
      events: const {PostgresChangeEvent.update},
      onPayload: (payload) {
        if (!ref.mounted) return;
        if (Supabase.instance.client.auth.currentSession == null) {
          return;
        }
        final newRec = payload.newRecord;
        final oldRec = payload.oldRecord;
        final changedId =
            (newRec['id'] ?? oldRec['id'])?.toString().trim() ?? '';
        if (changedId.isEmpty || changedId == userId) return;
        // Fast path post-migration: row carries the flag directly.
        final direct = _extractDirectPinned(newRec);
        if (direct != null) {
          _handlePartnerUpdated(
            changedId,
            source: 'users-direct',
            knownValue: direct,
          );
        } else {
          // Pre-migration or unrelated edit: RPC refresh (cheap, rare).
          _handlePartnerUpdated(changedId, source: 'users');
        }
      },
    );
  }

  String? _extractUserId(Map<String, dynamic> payload) {
    final dynamic nested = payload['payload'];
    final Map<String, dynamic> data;
    if (nested is Map) {
      data = Map<String, dynamic>.from(nested);
    } else {
      data = payload;
    }
    for (final key in const ['user_id', 'userId', 'partner_id', 'partnerId']) {
      final v = data[key]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Bool member of a broadcast payload (handles the nested `payload` map
  /// shape some realtime versions deliver). Null when absent/not a bool.
  bool? _extractBool(Map<String, dynamic> payload, String key) {
    final dynamic nested = payload['payload'];
    final Map<String, dynamic> data;
    if (nested is Map) {
      data = Map<String, dynamic>.from(nested);
    } else {
      data = payload;
    }
    final v = data[key];
    return v is bool ? v : null;
  }

  /// Post-migration fast path: users row carries the pinned flag.
  /// Returns null when columns are absent (pre-migration) or payload lacks them.
  bool? _extractDirectPinned(dynamic record) {
    try {
      if (record is! Map) return null;
      if (!record.containsKey('is_pinned_location_active')) return null;
      final raw = record['is_pinned_location_active'];
      if (raw is bool) {
        // Respect expiry when the column is present.
        final expRaw = record['pinned_expires_at'];
        if (expRaw != null) {
          final exp = DateTime.tryParse(expRaw.toString());
          if (exp != null && !exp.toUtc().isAfter(DateTime.now().toUtc())) {
            return false;
          }
        }
        return raw;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _handlePartnerUpdated(
    String partnerId, {
    required String source,
    bool? knownValue,
  }) {
    if (!ref.mounted) return;
    if (knownValue != null) {
      // Authoritative push value: seed the cache so the invalidation below
      // serves it without an RPC round trip.
      _pinnedCache[partnerId] = _PinnedCacheEntry(knownValue, DateTime.now());
    }
    debugPrint(
      '📍 Pinned realtime: $source for partner=$partnerId — refreshing',
    );
    _seenUpdates++;
    lastUpdatedUserId = partnerId;
    state = _seenUpdates;
    try {
      ref.invalidate(pinnedPartnerProvider(partnerId));
    } catch (_) {}
  }

  void _refreshAll() {
    if (!ref.mounted) return;
    lastUpdatedUserId = null;
    try {
      ref.invalidate(pinnedPartnerProvider);
    } catch (_) {}
    _seenUpdates++;
    state = _seenUpdates;
  }

  /// Manual hook for pull-to-refresh / resume paths.
  void refreshAll() => _refreshAll();

  /// Refresh a single partner (e.g. when opening their profile).
  void refreshPartner(String partnerId) {
    final id = partnerId.trim();
    if (id.isEmpty || !ref.mounted) return;
    lastUpdatedUserId = id;
    try {
      ref.invalidate(pinnedPartnerProvider(id));
    } catch (_) {}
    _seenUpdates++;
    state = _seenUpdates;
  }

  void _cleanup() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _resumeDispose?.call();
    _resumeDispose = null;
    // Session-scoped cache: a different signed-in user must never inherit
    // verdicts fetched for the previous one.
    _pinnedCache.clear();
    SupabaseRealtimeManager.instance.unregister(kPinnedUpdatesChannel);
    _usersSubscription?.cancel();
    _usersSubscription = null;
  }
}

final pinnedPartnerRealtimeProvider =
    NotifierProvider<PinnedPartnerRealtimeNotifier, int>(
      PinnedPartnerRealtimeNotifier.new,
    );
