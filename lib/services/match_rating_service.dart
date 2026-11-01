import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/string_extensions.dart';

final _supabase = Supabase.instance.client;

class RatingQuestion {
  final String id;
  final String translationKey;
  final int order;
  final bool enabled;

  const RatingQuestion({
    required this.id,
    required this.translationKey,
    required this.order,
    required this.enabled,
  });

  factory RatingQuestion.fromJson(Map<String, dynamic> json) {
    return RatingQuestion(
      id: (json['id'] ?? '').toString(),
      translationKey: (json['translationKey'] ?? '').toString(),
      order: int.tryParse((json['order'] ?? '').toString()) ?? 0,
      enabled: (json['enabled'] is bool) ? json['enabled'] as bool : true,
    );
  }
}

class UserRatingSummary {
  final int ratedByCount;
  final double? q1Avg;
  final double? q2Avg;
  final double? q3Avg;
  final double? q4Avg;
  final double? q5Avg;
  final double? overallAvg;

  const UserRatingSummary({
    required this.ratedByCount,
    required this.q1Avg,
    required this.q2Avg,
    required this.q3Avg,
    required this.q4Avg,
    required this.q5Avg,
    required this.overallAvg,
  });

  factory UserRatingSummary.fromRpcRow(Map<String, dynamic> row) {
    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return UserRatingSummary(
      ratedByCount: int.tryParse((row['rated_by_count'] ?? 0).toString()) ?? 0,
      q1Avg: toDouble(row['q1_avg']),
      q2Avg: toDouble(row['q2_avg']),
      q3Avg: toDouble(row['q3_avg']),
      q4Avg: toDouble(row['q4_avg']),
      q5Avg: toDouble(row['q5_avg']),
      overallAvg: toDouble(row['overall_avg']),
    );
  }

  factory UserRatingSummary.fromCacheMap(Map<String, dynamic> map) {
    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    return UserRatingSummary(
      ratedByCount: int.tryParse((map['rated_by_count'] ?? 0).toString()) ?? 0,
      q1Avg: toDouble(map['q1_avg']),
      q2Avg: toDouble(map['q2_avg']),
      q3Avg: toDouble(map['q3_avg']),
      q4Avg: toDouble(map['q4_avg']),
      q5Avg: toDouble(map['q5_avg']),
      overallAvg: toDouble(map['overall_avg']),
    );
  }

  Map<String, dynamic> toCacheMap() {
    return <String, dynamic>{
      'rated_by_count': ratedByCount,
      'q1_avg': q1Avg,
      'q2_avg': q2Avg,
      'q3_avg': q3Avg,
      'q4_avg': q4Avg,
      'q5_avg': q5Avg,
      'overall_avg': overallAvg,
    };
  }

  bool isSameAs(UserRatingSummary other) {
    return ratedByCount == other.ratedByCount &&
        q1Avg == other.q1Avg &&
        q2Avg == other.q2Avg &&
        q3Avg == other.q3Avg &&
        q4Avg == other.q4Avg &&
        q5Avg == other.q5Avg &&
        overallAvg == other.overallAvg;
  }
}

class DueRatingPrompt {
  final String matchId;
  final String otherUserId;
  final String otherName;
  final DateTime matchCreatedAt;
  final bool otherUserMetConfirmed;
  final bool selfMetConfirmed;

  const DueRatingPrompt({
    required this.matchId,
    required this.otherUserId,
    required this.otherName,
    required this.matchCreatedAt,
    required this.otherUserMetConfirmed,
    required this.selfMetConfirmed,
  });

  factory DueRatingPrompt.fromRpcRow(Map<String, dynamic> row) {
    return DueRatingPrompt(
      matchId: (row['match_id'] ?? '').toString(),
      otherUserId: (row['other_user_id'] ?? '').toString(),
      otherName: (row['other_name'] ?? '').toString()
          .formatAsFirstNameLastInitial(fallback: 'Someone'),
      matchCreatedAt: row['match_created_at'] != null
          ? DateTime.parse(row['match_created_at'].toString())
          : DateTime.now(),
      otherUserMetConfirmed: (row['other_user_met_confirmed'] is bool)
          ? row['other_user_met_confirmed'] as bool
          : false,
      selfMetConfirmed: (row['self_met_confirmed'] is bool)
          ? row['self_met_confirmed'] as bool
          : false,
    );
  }
}

class MatchRatingService {
  static final Map<String, double?> _myMatchOverallRatingCache =
      <String, double?>{};
  static final Set<String> _myMatchOverallRatingLoaded = <String>{};

  /// In-memory cache for matched-user rating summaries (fast UI startup).
  /// Local storage (Hive via LocalDbService) is the persistent layer;
  /// this map is the memory layer. Both are read on UI start so data is
  /// displayed immediately, with Supabase refresh happening in background.
  static final Map<String, UserRatingSummary> _summaryMemoryCache =
      <String, UserRatingSummary>{};
  static final Map<String, DateTime> _summaryMemoryCachedAt =
      <String, DateTime>{};
  static final Set<String> _summaryRefreshInFlight = <String>{};

  /// How long an in-memory summary is considered fresh. When older, a
  /// background refresh is triggered but the cached value is still returned
  /// immediately (stale-while-revalidate).
  static const Duration _summaryMemoryFreshFor = Duration(seconds: 30);

  /// Synchronous memory peek (no I/O). Returns null when not in memory.
  static UserRatingSummary? peekCachedSummaryInMemory(String userId) {
    final id = userId.trim();
    if (id.isEmpty) return null;
    return _summaryMemoryCache[id];
  }

  /// Cache-first read with NO network: memory first, then local storage
  /// (even stale). Used by the UI to render instantly on startup.
  Future<UserRatingSummary?> loadCachedSummary(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    final mem = _summaryMemoryCache[id];
    if (mem != null) return mem;
    try {
      final cached = await LocalDbService.shared
          .getCachedRatingSummaryAllowExpired(id);
      if (cached == null) return null;
      final summary = UserRatingSummary.fromCacheMap(cached);
      _summaryMemoryCache[id] = summary;
      try {
        final at = await LocalDbService.shared.getRatingSummaryCachedAt(id);
        _summaryMemoryCachedAt[id] = at ?? DateTime.now();
      } catch (_) {
        _summaryMemoryCachedAt[id] = DateTime.now();
      }
      return summary;
    } catch (_) {
      return null;
    }
  }

  bool _isSummaryMemoryFresh(String userId) {
    final at = _summaryMemoryCachedAt[userId];
    if (at == null) return false;
    return DateTime.now().difference(at) < _summaryMemoryFreshFor;
  }

  /// Public freshness check for providers: true when memory holds a fresh
  /// value that does not need a background refresh.
  bool isSummaryFreshInMemory(String userId) {
    final id = userId.trim();
    if (id.isEmpty) return false;
    if (!_summaryMemoryCache.containsKey(id)) return false;
    return _isSummaryMemoryFresh(id);
  }

  /// Fetch fresh summary from Supabase and update BOTH memory and local
  /// storage. Throws on network failure (callers decide fallback).
  Future<UserRatingSummary> fetchFreshSummary(String userId) async {
    final id = userId.trim();
    final minCount = await getDisplayMinCount();
    final lastN = await getAggregateLastN();
    final params = <String, dynamic>{'p_user_id': id, 'p_min_count': minCount};
    if (lastN != null) {
      params['p_last_n'] = lastN;
    }

    final result = await _supabase.rpc(
      'get_user_rating_summary',
      params: params,
    );
    final rows = (result is List) ? result : <dynamic>[];
    if (rows.isEmpty) {
      const empty = UserRatingSummary(
        ratedByCount: 0,
        q1Avg: null,
        q2Avg: null,
        q3Avg: null,
        q4Avg: null,
        q5Avg: null,
        overallAvg: null,
      );
      _summaryMemoryCache[id] = empty;
      _summaryMemoryCachedAt[id] = DateTime.now();
      return empty;
    }
    final summary = UserRatingSummary.fromRpcRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
    _summaryMemoryCache[id] = summary;
    _summaryMemoryCachedAt[id] = DateTime.now();
    try {
      await LocalDbService.shared.saveRatingSummary(id, summary.toCacheMap());
    } catch (_) {}
    return summary;
  }

  /// Background refresh: updates memory + local storage, never throws.
  /// Returns the fresh value, or null when offline / failed / skipped.
  /// Guarded against concurrent refreshes for the same user.
  Future<UserRatingSummary?> refreshSummaryInBackground(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    if (shouldSkipSupabaseCalls()) return null;
    if (_supabase.auth.currentUser == null) return null;
    if (!_summaryRefreshInFlight.add(id)) return null;
    try {
      return await fetchFreshSummary(id);
    } catch (e) {
      debugPrint('⭐ Rating cache: background refresh failed for $id: $e');
      return null;
    } finally {
      _summaryRefreshInFlight.remove(id);
    }
  }

  /// Force a fresh Supabase fetch for [userId], bypassing the
  /// stale-while-revalidate throttle that [_summaryMemoryFreshFor] applies.
  ///
  /// Callers (the realtime rating listener) use this when they are told a
  /// specific user's aggregate changed: the memory/disk cache is known-stale
  /// even if it was written moments ago, so returning it would delay the
  /// update by up to the freshness window. Updates memory + local storage so
  /// the very next provider build reads the new value; never throws.
  Future<UserRatingSummary?> forceRefreshSummary(String userId) async {
    final id = userId.trim();
    if (id.isEmpty) return null;
    if (shouldSkipSupabaseCalls()) return null;
    if (_supabase.auth.currentUser == null) return null;
    try {
      return await fetchFreshSummary(id);
    } catch (e) {
      debugPrint('⭐ Rating cache: force refresh failed for $id: $e');
      return null;
    }
  }

  /// Prefetch a batch of matched-user summaries in the background.
  /// Fire-and-forget: warms memory + local storage so lists render instantly.
  static void prefetchSummaries(
    MatchRatingService service,
    Iterable<String> userIds,
  ) {
    final unique = <String>{};
    for (final raw in userIds) {
      final id = raw.trim();
      if (id.isNotEmpty) unique.add(id);
      if (unique.length >= 30) break;
    }
    if (unique.isEmpty) return;
    unawaited(
      Future(() async {
        for (final id in unique) {
          try {
            // Warm memory from disk first (instant for next build).
            await service.loadCachedSummary(id);
            // Refresh stale entries in background without blocking UI.
            final at = _summaryMemoryCachedAt[id];
            final isFresh =
                at != null &&
                DateTime.now().difference(at) < _summaryMemoryFreshFor;
            if (!isFresh) {
              await service.refreshSummaryInBackground(id);
            }
          } catch (_) {}
        }
      }),
    );
  }

  Future<bool> hasUserRatedMatch(String matchId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return false;

    // Cache-first (memory via Hive): show instantly, refresh in background.
    try {
      final cached = await LocalDbService.shared.getCachedHasRatedMatch(
        matchId,
      );
      if (cached != null) {
        if (!shouldSkipSupabaseCalls()) {
          unawaited(() async {
            try {
              final row = await _supabase
                  .from('match_ratings')
                  .select('id')
                  .eq('match_id', matchId)
                  .eq('rater_id', userId)
                  .maybeSingle();
              final rated = row != null;
              if (rated != cached) {
                await LocalDbService.shared.saveHasRatedMatch(matchId, rated);
              }
            } catch (_) {}
          }());
        }
        return cached;
      }
    } catch (_) {}

    if (shouldSkipSupabaseCalls()) {
      return false;
    }

    final row = await _supabase
        .from('match_ratings')
        .select('id')
        .eq('match_id', matchId)
        .eq('rater_id', userId)
        .maybeSingle();
    final rated = row != null;
    await LocalDbService.shared.saveHasRatedMatch(matchId, rated);
    return rated;
  }

  Future<double?> getMyOverallRatingForMatch(String matchId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return null;

    if (_myMatchOverallRatingLoaded.contains(matchId)) {
      return _myMatchOverallRatingCache[matchId];
    }

    // Cache-first: Hive (local storage) + memory for instant startup.
    try {
      final diskCached = await LocalDbService.shared.getCachedMyMatchRating(
        matchId,
      );
      if (diskCached != null) {
        _myMatchOverallRatingLoaded.add(matchId);
        _myMatchOverallRatingCache[matchId] = diskCached;
        if (!shouldSkipSupabaseCalls()) {
          unawaited(() async {
            try {
              final row = await _supabase
                  .from('match_ratings')
                  .select('q1,q2,q3,q4,q5')
                  .eq('match_id', matchId)
                  .eq('rater_id', userId)
                  .maybeSingle();
              if (row == null) return;
              final q1 = int.tryParse((row['q1'] ?? '').toString()) ?? 0;
              final q2 = int.tryParse((row['q2'] ?? '').toString()) ?? 0;
              final q3 = int.tryParse((row['q3'] ?? '').toString()) ?? 0;
              final q4 = int.tryParse((row['q4'] ?? '').toString()) ?? 0;
              final q5 = int.tryParse((row['q5'] ?? '').toString()) ?? 0;
              final avg = (q1 + q2 + q3 + q4 + q5) / 5.0;
              _myMatchOverallRatingCache[matchId] = avg;
              await LocalDbService.shared.saveMyMatchRating(matchId, avg);
            } catch (_) {}
          }());
        }
        return diskCached;
      }
    } catch (_) {}

    if (shouldSkipSupabaseCalls()) {
      _myMatchOverallRatingLoaded.add(matchId);
      _myMatchOverallRatingCache[matchId] = null;
      return null;
    }

    final row = await _supabase
        .from('match_ratings')
        .select('q1,q2,q3,q4,q5')
        .eq('match_id', matchId)
        .eq('rater_id', userId)
        .maybeSingle();

    _myMatchOverallRatingLoaded.add(matchId);
    if (row == null) {
      _myMatchOverallRatingCache[matchId] = null;
      return null;
    }

    final q1 = int.tryParse((row['q1'] ?? '').toString()) ?? 0;
    final q2 = int.tryParse((row['q2'] ?? '').toString()) ?? 0;
    final q3 = int.tryParse((row['q3'] ?? '').toString()) ?? 0;
    final q4 = int.tryParse((row['q4'] ?? '').toString()) ?? 0;
    final q5 = int.tryParse((row['q5'] ?? '').toString()) ?? 0;
    final avg = (q1 + q2 + q3 + q4 + q5) / 5.0;
    _myMatchOverallRatingCache[matchId] = avg;
    await LocalDbService.shared.saveMyMatchRating(matchId, avg);
    return avg;
  }

  Future<bool> isEnabled() async {
    return appConfigService.getBool('ratings.enabled', defaultValue: true);
  }

  Future<int> getScaleMin() async {
    return appConfigService.getInt('ratings.scale_min', defaultValue: 1);
  }

  Future<int> getScaleMax() async {
    return appConfigService.getInt('ratings.scale_max', defaultValue: 5);
  }

  Future<int> getPromptInitialDelaySeconds() async {
    return appConfigService.getInt(
      'ratings.prompt_initial_delay_seconds',
      defaultValue: 20 * 60 * 60,
    );
  }

  Future<int> getPromptRepeatDelaySeconds() async {
    return appConfigService.getInt(
      'ratings.prompt_repeat_delay_seconds',
      defaultValue: 72 * 60 * 60,
    );
  }

  Future<int> getDisplayMinCount() async {
    return appConfigService.getInt(
      'ratings.display_min_count',
      defaultValue: 5,
    );
  }

  Future<int?> getAggregateLastN() async {
    final raw = await appConfigService.getInt(
      'ratings.aggregate_last_n',
      defaultValue: 0,
    );
    if (raw <= 0) return null;
    return raw;
  }

  static List<RatingQuestion>? _questionsMemory;
  static DateTime? _questionsMemoryAt;
  static const Duration _questionsFreshFor = Duration(hours: 1);
  static bool _questionsRefreshInFlight = false;

  Future<List<RatingQuestion>> getQuestions() async {
    List<RatingQuestion> fromJsonItems(List<Map<String, dynamic>> items) {
      final questions = items.map((m) => RatingQuestion.fromJson(m)).toList();
      questions.sort((a, b) => a.order.compareTo(b.order));
      return questions
          .where((q) => q.enabled && q.translationKey.isNotEmpty)
          .toList();
    }

    Future<void> refreshInBackground() async {
      if (shouldSkipSupabaseCalls()) return;
      if (_questionsRefreshInFlight) return;
      if (_questionsMemoryAt != null &&
          DateTime.now().difference(_questionsMemoryAt!) < _questionsFreshFor) {
        return;
      }
      _questionsRefreshInFlight = true;
      try {
        final raw = await appConfigService.getList(
          'ratings.questions',
          defaultValue: const [],
        );
        if (raw.isEmpty) return;
        final jsonItems = <Map<String, dynamic>>[];
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            jsonItems.add(item);
          } else if (item is Map) {
            jsonItems.add(Map<String, dynamic>.from(item));
          }
        }
        if (jsonItems.isEmpty) return;
        final fresh = fromJsonItems(jsonItems);
        if (fresh.isEmpty) return;
        _questionsMemory = fresh;
        _questionsMemoryAt = DateTime.now();
        await LocalDbService.shared.saveRatingQuestions(jsonItems);
      } catch (_) {
      } finally {
        _questionsRefreshInFlight = false;
      }
    }

    // 1) Memory layer — instant.
    if (_questionsMemory != null && _questionsMemory!.isNotEmpty) {
      unawaited(refreshInBackground());
      return _questionsMemory!;
    }

    // 2) Local-storage layer — fast, survives restarts. Displayed immediately.
    try {
      final cached = await LocalDbService.shared.getCachedRatingQuestions();
      if (cached != null && cached.isNotEmpty) {
        final list = fromJsonItems(cached);
        if (list.isNotEmpty) {
          _questionsMemory = list;
          // _questionsMemoryAt stays null so background refresh runs once.
          unawaited(refreshInBackground());
          return list;
        }
      }
    } catch (_) {}

    final raw = await appConfigService.getList(
      'ratings.questions',
      defaultValue: const [],
    );
    if (raw.isNotEmpty) {
      final questions = <RatingQuestion>[];
      final jsonItems = <Map<String, dynamic>>[];
      for (final item in raw) {
        Map<String, dynamic> json;
        if (item is Map<String, dynamic>) {
          json = item;
        } else if (item is Map) {
          json = Map<String, dynamic>.from(item);
        } else {
          continue;
        }
        questions.add(RatingQuestion.fromJson(json));
        jsonItems.add(json);
      }
      questions.sort((a, b) => a.order.compareTo(b.order));
      final filtered = questions
          .where((q) => q.enabled && q.translationKey.isNotEmpty)
          .toList();
      await LocalDbService.shared.saveRatingQuestions(jsonItems);
      _questionsMemory = filtered;
      _questionsMemoryAt = DateTime.now();
      return filtered;
    }
    final cached = await LocalDbService.shared.getCachedRatingQuestions();
    if (cached != null && cached.isNotEmpty) {
      final questions = cached.map((m) => RatingQuestion.fromJson(m)).toList();
      questions.sort((a, b) => a.order.compareTo(b.order));
      final filtered = questions
          .where((q) => q.enabled && q.translationKey.isNotEmpty)
          .toList();
      _questionsMemory = filtered;
      return filtered;
    }
    return [];
  }

  Future<DueRatingPrompt?> getNextDuePrompt({int limit = 1}) async {
    if (shouldSkipSupabaseCalls()) return null;

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return null;
    final enabled = await isEnabled();
    if (!enabled) return null;

    final initialDelaySeconds = await getPromptInitialDelaySeconds();
    final result = await _supabase.rpc(
      'get_due_match_rating_prompts',
      params: {
        'p_user_id': userId,
        'p_initial_delay_seconds': initialDelaySeconds,
        'p_limit': limit,
      },
    );

    final rows = (result is List) ? result : <dynamic>[];
    if (rows.isEmpty) return null;
    return DueRatingPrompt.fromRpcRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  Future<void> setMetAnswer({
    required String matchId,
    required bool met,
  }) async {
    if (shouldSkipSupabaseCalls()) return;

    final repeatDelaySeconds = await getPromptRepeatDelaySeconds();
    await _supabase.rpc(
      'set_match_met_answer',
      params: {
        'p_match_id': matchId,
        'p_met': met,
        'p_repeat_delay_seconds': repeatDelaySeconds,
      },
    );
  }

  Future<void> submitRating({
    required String matchId,
    required List<int> answers,
  }) async {
    if (shouldSkipSupabaseCalls()) return;

    if (answers.length < 5) {
      throw ArgumentError('answers_must_have_5_values');
    }
    await _supabase.rpc(
      'submit_match_rating',
      params: {
        'p_match_id': matchId,
        'p_q1': answers[0],
        'p_q2': answers[1],
        'p_q3': answers[2],
        'p_q4': answers[3],
        'p_q5': answers[4],
      },
    );

    final avg =
        (answers[0] + answers[1] + answers[2] + answers[3] + answers[4]) / 5.0;
    _myMatchOverallRatingLoaded.add(matchId);
    _myMatchOverallRatingCache[matchId] = avg;
    await LocalDbService.shared.saveHasRatedMatch(matchId, true);
    await LocalDbService.shared.saveMyMatchRating(matchId, avg);

    // Notify other matched viewers in realtime. RLS on match_ratings blocks
    // them from receiving postgres_changes for this row (they are neither
    // rater nor ratee), so broadcast just the ratee_id; receivers re-fetch
    // the aggregate via the SECURITY DEFINER RPC. Best-effort: never fail
    // the rating flow because broadcast failed.
    try {
      final rateeId = await _resolveRateeIdForMatch(matchId);
      if (rateeId != null && rateeId.isNotEmpty) {
        unawaited(broadcastRatingUpdated(rateeId));
      }
    } catch (_) {}
  }

  Future<String?> _resolveRateeIdForMatch(String matchId) async {
    try {
      final row = await _supabase
          .from('matches')
          .select('user1_id,user2_id')
          .eq('id', matchId)
          .maybeSingle();
      if (row == null) return null;
      final current = _supabase.auth.currentUser?.id;
      final u1 = (row['user1_id'] ?? '').toString();
      final u2 = (row['user2_id'] ?? '').toString();
      if (current != null && current.isNotEmpty) {
        if (u1 == current) return u2.isNotEmpty ? u2 : null;
        if (u2 == current) return u1.isNotEmpty ? u1 : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Sends a public broadcast that [rateeId]'s aggregate rating changed.
  ///
  /// Topic/event must match [kRatingUpdatesChannel]/[kRatingUpdatedEvent] in
  /// `match_rating_provider.dart` (kept as literals here to avoid a
  /// provider->service import cycle). Payload carries only the ratee id —
  /// no individual scores — so no private rating data leaks.
  static Future<void> broadcastRatingUpdated(String rateeId) async {
    final id = rateeId.trim();
    if (id.isEmpty || shouldSkipSupabaseCalls()) return;
    RealtimeChannel? channel;
    try {
      channel = _supabase.channel('rating_updates');
      final subscribed = Completer<void>();
      channel.onBroadcast(event: 'rating_updated', callback: (_) {});
      channel.subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed &&
            !subscribed.isCompleted) {
          subscribed.complete();
        } else if ((status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut ||
                status == RealtimeSubscribeStatus.closed) &&
            !subscribed.isCompleted) {
          subscribed.complete();
        }
      });
      try {
        await subscribed.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Continue best-effort: try to send even if subscribe ack is slow.
      }
      try {
        await channel
            .sendBroadcastMessage(
              event: 'rating_updated',
              payload: {'ratee_id': id},
            )
            .timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // Best-effort only.
      }
    } catch (e) {
      debugPrint('⭐ Rating broadcast send failed (best-effort): $e');
    } finally {
      if (channel != null) {
        try {
          await _supabase
              .removeChannel(channel)
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
  }

  static final Map<String, bool> _pendingPromptMemory = <String, bool>{};

  Future<bool> hasPendingRatingPrompt(String matchId) async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return false;

    // Cache-first (memory + Hive): display instantly, refresh in background.
    final mem = _pendingPromptMemory[matchId];
    if (mem != null) {
      if (!shouldSkipSupabaseCalls()) {
        unawaited(() async {
          try {
            final row = await _supabase
                .from('pending_rating_prompts')
                .select('match_id')
                .eq('user_id', userId)
                .eq('match_id', matchId)
                .maybeSingle();
            final pending = row != null;
            if (pending != mem) {
              _pendingPromptMemory[matchId] = pending;
              await LocalDbService.shared.savePendingRatingPrompt(
                matchId,
                pending,
              );
            }
          } catch (_) {}
        }());
      }
      return mem;
    }
    try {
      final disk = await LocalDbService.shared.getCachedPendingRatingPrompt(
        matchId,
      );
      if (disk != null) {
        _pendingPromptMemory[matchId] = disk;
        if (!shouldSkipSupabaseCalls()) {
          unawaited(() async {
            try {
              final row = await _supabase
                  .from('pending_rating_prompts')
                  .select('match_id')
                  .eq('user_id', userId)
                  .eq('match_id', matchId)
                  .maybeSingle();
              final pending = row != null;
              if (pending != disk) {
                _pendingPromptMemory[matchId] = pending;
                await LocalDbService.shared.savePendingRatingPrompt(
                  matchId,
                  pending,
                );
              }
            } catch (_) {}
          }());
        }
        return disk;
      }
    } catch (_) {}

    if (shouldSkipSupabaseCalls()) return false;

    try {
      final row = await _supabase
          .from('pending_rating_prompts')
          .select('match_id')
          .eq('user_id', userId)
          .eq('match_id', matchId)
          .maybeSingle();
      final pending = row != null;
      _pendingPromptMemory[matchId] = pending;
      try {
        await LocalDbService.shared.savePendingRatingPrompt(matchId, pending);
      } catch (_) {}
      return pending;
    } catch (e) {
      return false;
    }
  }

  Future<UserRatingSummary> getUserRatingSummary(String userId) async {
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

    // 1) Memory layer — instant, no I/O.
    final mem = _summaryMemoryCache[id];
    if (mem != null) {
      // Stale-while-revalidate: show memory now, refresh in background.
      if (!_isSummaryMemoryFresh(id) && !shouldSkipSupabaseCalls()) {
        unawaited(refreshSummaryInBackground(id));
      }
      return mem;
    }

    // 2) Local-storage layer (Hive, even stale) — fast, survives restarts.
    // Displayed immediately so UI never waits on network at startup.
    try {
      final cached = await LocalDbService.shared
          .getCachedRatingSummaryAllowExpired(id);
      if (cached != null) {
        final summary = UserRatingSummary.fromCacheMap(cached);
        _summaryMemoryCache[id] = summary;
        try {
          final at = await LocalDbService.shared.getRatingSummaryCachedAt(id);
          _summaryMemoryCachedAt[id] = at ?? DateTime.now();
        } catch (_) {
          _summaryMemoryCachedAt[id] = DateTime.now();
        }
        if (!shouldSkipSupabaseCalls()) {
          unawaited(refreshSummaryInBackground(id));
        }
        return summary;
      }
    } catch (_) {}

    // 3) No cache at all.
    if (shouldSkipSupabaseCalls()) {
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

    // First-ever load: must fetch (nothing to display yet), then cache to
    // BOTH memory and local storage for the next startup.
    try {
      return await fetchFreshSummary(id);
    } catch (_) {
      // Network failed — fall back to expiry-respecting cache, else empty.
      try {
        final fallback = await LocalDbService.shared.getCachedRatingSummary(id);
        if (fallback != null) {
          final summary = UserRatingSummary.fromCacheMap(fallback);
          _summaryMemoryCache[id] = summary;
          _summaryMemoryCachedAt[id] = DateTime.now();
          return summary;
        }
      } catch (_) {}
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
  }
}
