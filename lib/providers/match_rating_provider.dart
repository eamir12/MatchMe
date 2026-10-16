import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final matchRatingServiceProvider = Provider<MatchRatingService>((ref) {
  return MatchRatingService();
});

final ratingQuestionsProvider = FutureProvider<List<RatingQuestion>>((
  ref,
) async {
  final service = ref.read(matchRatingServiceProvider);
  return service.getQuestions();
});

final userRatingSummaryProvider =
    FutureProvider.family<UserRatingSummary, String>((ref, userId) async {
      final service = ref.read(matchRatingServiceProvider);
      final id = userId.trim();
      if (id.isEmpty) {
        return const UserRatingSummary(
          ratedByCount: 0,
          q1Avg: null,
          q2Avg: null,
          q3Avg: null,
          q4Avg: null,
          q5Avg: null,
          overallAvg: null,
        );
      }

      // Cache-first (memory + local storage) for instant UI startup.
      // The cached value is returned immediately; a background Supabase refresh
      // updates memory + Hive and invalidates this provider when fresh data
      // differs, so the UI shows cached stars instantly then live values.
      final cached = await service.loadCachedSummary(id);
      if (cached != null) {
        if (!service.isSummaryFreshInMemory(id) && !shouldSkipSupabaseCalls()) {
          unawaited(() async {
            try {
              final fresh = await service.refreshSummaryInBackground(id);
              if (!ref.mounted) return;
              if (fresh == null) return;
              if (fresh.isSameAs(cached)) return;
              try {
                ref.invalidateSelf();
              } catch (_) {}
            } catch (_) {}
          }());
        }
        return cached;
      }

      // No cache (first-ever view): fetch (service caches to both layers).
      return service.getUserRatingSummary(id);
    });

/// Broadcast topic + event used for rating-summary realtime updates.
///
/// RLS on `match_ratings` only allows the rater or the ratee to SELECT a row,
/// so a user A matched with B can NOT receive `postgres_changes` for ratings
/// that a third user C gave to B. To still update A in realtime we use a
/// public Realtime Broadcast channel that only carries the affected
/// `ratee_id` (no individual scores). Receivers then re-fetch the aggregate
/// via the SECURITY DEFINER `get_user_rating_summary` RPC, which is allowed
/// for any authenticated user.
const String kRatingUpdatesChannel = 'rating_updates';
const String kRatingUpdatedEvent = 'rating_updated';

/// Keeps rating summaries fresh in realtime.
///
/// Watches:
/// * Broadcast `rating_updated` events (sent by the rater's client in
///   [MatchRatingService.submitRating] and by the DB trigger
///   `notify_rating_summary_changed` on any match_ratings write) — works for
///   ALL matched viewers, bypassing the `match_ratings` RLS limitation.
/// * `postgres_changes` INSERTs on `match_ratings` — covers the rater/ratee
///   themselves (RLS permits those rows) even if broadcast is missed.
/// * Periodic safety-net poll + connectivity-resume refresh so offline gaps
///   still converge.
///
/// On any signal for `rateeId`, invalidates
/// `userRatingSummaryProvider(rateeId)` so every `MatchBox` / matches list
/// watching it rebuilds with the fresh aggregate.
///
/// Keep alive by `ref.watch(ratingSummaryRealtimeProvider)` in home + matches
/// screens. The notifier rebuilds when the signed-in user changes, so
/// sign-out -> sign-in re-wires the channels instead of staying dead.
class RatingSummaryRealtimeNotifier extends Notifier<int> {
  Timer? _pollTimer;
  void Function()? _resumeDispose;
  String? _channelUserId;
  int _seenUpdates = 0;

  /// Ratee id from the most recent realtime signal (broadcast or
  /// postgres_changes). Screens showing a single profile (e.g.
  /// MatchProfileScreen) use this to skip refetches for unrelated users.
  /// Null after bulk refreshes (poll/resume) which intentionally update all.
  String? lastUpdatedRateeId;

  @override
  int build() {
    // Re-run this build whenever the signed-in user changes. This provider is
    // keep-alive (NOT autoDispose), so without this a sign-out -> sign-in
    // cycle would leave the old instance alive with channels unregistered and
    // the poll timer canceled — ratings would stop updating in realtime until
    // the app restarts. The select only fires on a user-id change, so token
    // refreshes and other same-user auth events do not rebuild/rewire
    // channels. Fall back to the current session while the auth stream has
    // not emitted yet (cold start), matching the pre-stream behavior.
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
      // Channels were never set up (built while offline) or were paused —
      // re-register so future broadcasts arrive, then re-fetch everything
      // to cover gaps during offline.
      _setupChannels();
      _refreshAll();
    });

    if (!shouldSkipSupabaseCalls()) {
      // Defer past first frame like other realtime providers to avoid
      // cold-start jank.
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

    // 1) Public broadcast — the primary path for "B got rated by C, notify A".
    SupabaseRealtimeManager.instance.register(
      '${kRatingUpdatesChannel}_$userId',
      () {
        if (Supabase.instance.client.auth.currentSession == null) {
          throw Exception(
            'No active session — skipping rating broadcast subscription',
          );
        }
        final channel = Supabase.instance.client.channel(kRatingUpdatesChannel);
        channel.onBroadcast(
          event: kRatingUpdatedEvent,
          callback: (payload) {
            if (!ref.mounted) return;
            if (Supabase.instance.client.auth.currentSession == null) return;
            final rateeId = _extractRateeId(payload);
            if (rateeId == null || rateeId.isEmpty) return;
            _handleRateeUpdated(rateeId, source: 'broadcast');
          },
        );
        channel.subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('⭐ Rating realtime: broadcast subscribed');
          } else if (handleExpectedSupabaseOfflineFailure(err)) {
            return;
          } else if (SupabaseRealtimeManager.instance.isPaused) {
            return;
          } else if (err != null &&
              !isExpectedOfflineFailure(err) &&
              !isAuthRateLimitFailure(err)) {
            debugPrint('⭐ Rating realtime broadcast error: $err');
          }
        });
        return channel;
      },
    );

    // 2) Direct postgres_changes on match_ratings INSERT — RLS restricts this
    // to rows where we are rater or ratee, but that still gives the rater an
    // instant local refresh and covers the ratee's own devices.
    SupabaseRealtimeManager.instance.register(
      'match_ratings_for_user_$userId',
      () {
        if (Supabase.instance.client.auth.currentSession == null) {
          throw Exception(
            'No active session — skipping match_ratings subscription',
          );
        }
        final channel = Supabase.instance.client.channel(
          'match_ratings_for_user_$userId',
        );
        channel
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: 'public',
              table: 'match_ratings',
              callback: (payload) {
                if (!ref.mounted) return;
                if (Supabase.instance.client.auth.currentSession == null) {
                  return;
                }
                final rateeId = payload.newRecord['ratee_id']?.toString() ?? '';
                if (rateeId.isEmpty) return;
                _handleRateeUpdated(rateeId, source: 'postgres_changes');
              },
            )
            .subscribe((status, err) {
              if (status == RealtimeSubscribeStatus.subscribed) {
                debugPrint('⭐ Rating realtime: match_ratings subscribed');
              } else if (handleExpectedSupabaseOfflineFailure(err)) {
                return;
              } else if (SupabaseRealtimeManager.instance.isPaused) {
                return;
              } else if (err != null &&
                  !isExpectedOfflineFailure(err) &&
                  !isAuthRateLimitFailure(err)) {
                debugPrint('⭐ Rating realtime postgres_changes error: $err');
              }
            });
        return channel;
      },
    );
  }

  String? _extractRateeId(Map<String, dynamic> payload) {
    // realtime-dart delivers broadcast as {type, event, payload}; the
    // payload may be nested under 'payload' or be the map itself.
    final dynamic nested = payload['payload'];
    final Map<String, dynamic> data;
    if (nested is Map) {
      data = Map<String, dynamic>.from(nested);
    } else {
      data = payload;
    }
    for (final key in const ['ratee_id', 'rateeId', 'user_id', 'userId']) {
      final v = data[key]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  void _handleRateeUpdated(String rateeId, {required String source}) {
    if (!ref.mounted) return;
    debugPrint('⭐ Rating realtime: $source for ratee=$rateeId — refreshing');
    // Force a network refresh BEFORE notifying listeners. The summary provider
    // is cache-first and (correctly) serves the cached value without hitting
    // Supabase while it is "fresh in memory" (< _summaryMemoryFreshFor). A
    // realtime event, however, means the cache is stale right now, so simply
    // invalidating the provider would keep showing the old stars until the
    // freshness window lapsed (or the 30s poll ran). Refresh first so the new
    // value is already in memory/disk when every watcher rebuilds — the user's
    // own profile render and the match-box / match-profile screens all read the
    // same cache, so they all update together.
    final service = ref.read(matchRatingServiceProvider);
    unawaited(() async {
      await service.forceRefreshSummary(rateeId);
      if (!ref.mounted) return;
      if (Supabase.instance.client.auth.currentSession == null) return;
      _seenUpdates++;
      lastUpdatedRateeId = rateeId;
      state = _seenUpdates;
      try {
        ref.invalidate(userRatingSummaryProvider(rateeId));
      } catch (_) {}
    }());
  }

  void _refreshAll() {
    if (!ref.mounted) return;
    lastUpdatedRateeId = null;
    try {
      // Invalidating the family refreshes every watched summary (typically
      // the ~5 recent matches). Next build re-runs the RPC; unchanged rows
      // resolve to equal data so no flicker.
      ref.invalidate(userRatingSummaryProvider);
    } catch (_) {}
    // Bump state so single-profile screens listening only to the counter
    // also refresh on bulk (poll/resume) refreshes.
    _seenUpdates++;
    state = _seenUpdates;
  }

  /// Manual hook for pull-to-refresh / resume paths.
  void refreshAll() => _refreshAll();

  void _cleanup() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _resumeDispose?.call();
    _resumeDispose = null;
    final userId = _channelUserId;
    if (userId != null && userId.isNotEmpty) {
      SupabaseRealtimeManager.instance.unregister(
        '${kRatingUpdatesChannel}_$userId',
      );
      SupabaseRealtimeManager.instance.unregister(
        'match_ratings_for_user_$userId',
      );
    } else {
      // Best-effort: unregister the shared broadcast if user unknown
      // (does not affect other users' suffixed registrations).
      SupabaseRealtimeManager.instance.unregister(kRatingUpdatesChannel);
    }
  }
}

final ratingSummaryRealtimeProvider =
    NotifierProvider<RatingSummaryRealtimeNotifier, int>(
      () => RatingSummaryRealtimeNotifier(),
    );
