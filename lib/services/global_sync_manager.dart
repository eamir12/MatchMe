// lib/services/global_sync_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/chat_key_provider.dart';
import 'package:matchme/models/user_chat_key_model.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';

final supabase = Supabase.instance.client;

/// This service manages periodic and real-time syncing of core Home/Match data.
class GlobalHomeSyncManager {
  final Ref _ref;
  Timer? _syncTimer;
  Duration _syncInterval = const Duration(seconds: 60);

  // Heartbeat to keep user_activity fresh so online status reflects connectivity
  Timer? _heartbeatTimer;
  Duration _heartbeatInterval = const Duration(seconds: 30);

  // Prevent rapid sync restarts when connectivity bounces
  DateTime? _lastSyncAttempt;
  static const Duration _syncCooldown = Duration(seconds: 10);

  // Prevent multiple priority syncs when connectivity flaps
  DateTime? _lastPrioritySync;
  static const Duration _prioritySyncCooldown = Duration(seconds: 10);

  // Track sync in progress to prevent concurrent syncs
  bool _syncInProgress = false;

  // Track if manager is disposed to prevent operations after dispose
  bool _disposed = false;

  // Debounce timer for syncChatsNow to prevent rapid successive calls
  Timer? _syncChatsDebounceTimer;
  bool _syncChatsScheduled = false;

  // Static cooldown for syncChatsNow to prevent rapid sequential calls from different sources
  static DateTime? _lastSyncChatsCall;
  static const Duration _syncChatsCooldown = Duration(seconds: 5);

  // Post-completion deduplication: tracks when the last syncChatsNow *finished*
  // executing. The existing cooldown only gates on when a call was *scheduled*,
  // so a second call that arrives just after the debounce fires but before the
  // first sync completes will slip through. This guard closes that gap.
  static DateTime? _lastSyncChatsCompleted;
  static const Duration _syncChatsPostCompletionCooldown = Duration(seconds: 8);

  // Rapid-fire guard: silently drops calls within 1s of the last attempt
  static DateTime? _lastSyncChatsAttempt;
  static const Duration _syncChatsMinInterval = Duration(seconds: 1);

  // How long syncChatsNow waits for the chat key to become usable before giving
  // up and persisting whatever it can. Runs concurrently with the server fetch,
  // so this is a backstop, not the normal cost. Bounded because this sits on
  // the critical path of the first home render after sign-in.
  static const Duration _chatKeyReadinessTimeout = Duration(seconds: 5);

  // Fingerprint cache: skips save when server data hasn't changed
  static final Map<String, String> _lastSyncFingerprints = {};

  GlobalHomeSyncManager(this._ref) {
    // Load config values asynchronously
    Future.microtask(() async {
      _syncInterval = await appConfigService.getDuration(
        'sync.global_interval_seconds',
        defaultValue: const Duration(seconds: 15),
      );
      _heartbeatInterval = await appConfigService.getDuration(
        'sync.heartbeat_interval_seconds',
        defaultValue: const Duration(seconds: 30),
      );
    });

    // IMPORTANT: Only sync when we confirm we have a healthy connection.
    // This prevents startup delays when offline. The app will use cached data
    // until Supabase is reachable again, then sync.
    // Use nullable so the *first* health emission isn't treated as a
    // false→true transition. Cold start would otherwise log "transitioning
    // online" and fire priority sync + dashboard refresh + reconnect storm
    // every launch, even though we were never offline.
    bool? wasBackendHealthy;

    _ref.listen<AsyncValue<ConnectivityHealth>>(connectivityHealthProvider, (
      previous,
      next,
    ) {
      final isNowHealthy = next.value?.isBackendHealthy == true;
      final isTransitioningOnline = wasBackendHealthy == false && isNowHealthy;

      if (isNowHealthy) {
        offlineCacheManager.setSupabaseAvailability(true);
        if (isTransitioningOnline) {
          unawaited(
            appConfigService.refresh().catchError((error, stackTrace) {
              debugPrint(
                '⚠️ [SYNC] Failed to refresh app config after reconnect: $error',
              );
            }),
          );
        }

        // Check priority sync cooldown to prevent multiple immediate syncs when connectivity flaps
        bool shouldDoPrioritySync = isTransitioningOnline;
        if (isTransitioningOnline && _lastPrioritySync != null) {
          final timeSinceLastPrioritySync = DateTime.now().difference(
            _lastPrioritySync!,
          );
          if (timeSinceLastPrioritySync < _prioritySyncCooldown) {
            debugPrint(
              '🔄 [SYNC] Skipping priority sync - cooldown active (${timeSinceLastPrioritySync.inSeconds}s < ${_prioritySyncCooldown.inSeconds}s)',
            );
            shouldDoPrioritySync = false;
          }
        }

        // Only start periodic sync if transitioning online or timer not already running
        // This prevents multiple syncs from being triggered when health provider emits multiple times
        final timerAlreadyRunning = _syncTimer != null && _syncTimer!.isActive;
        final authState = _ref.read(authStateProvider).asData?.value;
        final isSignedIn =
            authState != null && authState.session?.user.id != null;
        if (isSignedIn && (isTransitioningOnline || !timerAlreadyRunning)) {
          if (isTransitioningOnline) {
            debugPrint(
              '✅ [SYNC] Backend is healthy (transitioning online) - starting sync and heartbeat',
            );
          } else {
            debugPrint(
              '✅ [SYNC] Backend is healthy - starting sync and heartbeat',
            );
          }
          _startPeriodicSync(prioritySync: shouldDoPrioritySync);
          _startHeartbeat();
        }
        if (isTransitioningOnline && shouldDoPrioritySync) {
          debugPrint(
            '🌐 [SYNC] Just came online - resetting cooldown for immediate sync',
          );
          _lastSyncAttempt = null; // Clear cooldown on online transition
          _lastPrioritySync = DateTime.now(); // Record priority sync time
        }
      } else {
        // Only log "not healthy" once per transition to avoid log spam
        // when the health provider emits multiple offline/degraded events.
        if (wasBackendHealthy == true) {
          debugPrint(
            '⏸️ [SYNC] Backend is not healthy - stopping sync and heartbeat',
          );
        }
        _stopPeriodicSync();
        _stopHeartbeat();
        // Only mark Supabase unavailable once the monitor has actually declared
        // the app offline. Degraded (a single failed probe, still inside the
        // grace period) may just be a transient blip — marking offline there
        // caused the refresh_token_already_used storm to flap availability
        // true->false and spam every provider. Supabase reachability is the
        // only signal, so "offline" status is the whole verdict.
        final h = next.value;
        final realOffline =
            h == null || h.status == ConnectivityHealthStatus.offline;
        if (realOffline) {
          offlineCacheManager.setSupabaseAvailability(false);
        }
      }
      wasBackendHealthy = isNowHealthy;
    }, fireImmediately: true);

    // Clean up timers if this provider is disposed
    _ref.onDispose(() {
      _stopPeriodicSync();
      _stopHeartbeat();
    });
  }

  void _startHeartbeat() {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Check if timer is already running before doing immediate update
    final wasAlreadyRunning =
        _heartbeatTimer != null && _heartbeatTimer!.isActive;

    if (!wasAlreadyRunning) {
      unawaited(
        UserActivityService.instance.pingIfDue(
          userId,
          force: true,
          source: 'heartbeat-start',
        ),
      );
    }

    if (_heartbeatTimer != null && _heartbeatTimer!.isActive) return;

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;
      unawaited(
        UserActivityService.instance.pingIfDue(
          userId,
          source: 'heartbeat-timer',
        ),
      );
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startPeriodicSync({bool prioritySync = false}) {
    if (_syncTimer != null && _syncTimer!.isActive) {
      // If already syncing and this is a priority sync (online transition), trigger immediately
      // But only if a sync is not already in progress
      if (prioritySync && !_syncInProgress) {
        final userId = supabase.auth.currentUser?.id;
        if (userId != null) {
          _runFullSync(userId, checkConnectivity: true, skipCooldown: true);
        }
      }
      return;
    }

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Run the first sync immediately (skip cooldown on priority sync when coming online)
    Future.microtask(
      () => _runFullSync(
        userId,
        checkConnectivity: true,
        skipCooldown: prioritySync,
      ),
    );

    // Schedule the periodic sync
    _syncTimer = Timer.periodic(_syncInterval, (timer) {
      _runFullSync(userId, checkConnectivity: true);
    });
  }

  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
    // stopped (logging removed)
  }

  Future<void> _runFullSync(
    String userId, {
    bool checkConnectivity = true,
    bool skipCooldown = false,
  }) async {
    if (_disposed) {
      final currentAuthUser = supabase.auth.currentUser?.id;
      if (currentAuthUser != null &&
          currentAuthUser == userId &&
          userId.isNotEmpty) {
        _disposed = false;
      } else {
        return;
      }
    }

    // Screen off / background: native MatchMeBackgroundService keeps Realtime +
    // heartbeat. Dart REST sync hits Doze DNS limits and spams failed host lookup logs.
    if (!isAppUiInForeground()) {
      return;
    }

    // Prevent concurrent syncs
    if (_syncInProgress) {
      debugPrint('⏸️ [SYNC] Sync already in progress, skipping...');
      return;
    }

    // Apply cooldown between sync attempts to prevent rapid retrials
    // (unless this is a priority sync from online transition)
    if (!skipCooldown) {
      final now = DateTime.now();
      if (_lastSyncAttempt != null &&
          now.difference(_lastSyncAttempt!).inSeconds <
              _syncCooldown.inSeconds) {
        debugPrint(
          '⏸️ [SYNC] Sync attempted too recently, applying cooldown...',
        );
        return;
      }
      _lastSyncAttempt = now;
    } else {
      debugPrint('🚀 [SYNC] Priority sync - skipping cooldown');
      _lastSyncAttempt = DateTime.now();
    }

    _syncInProgress = true;

    try {
      if (checkConnectivity) {
        final health = _ref.read(connectivityHealthProvider).value;
        if (health?.isBackendHealthy != true) {
          if (health?.status == ConnectivityHealthStatus.offline) {
            offlineCacheManager.setSupabaseAvailability(false);
          }
          return;
        }
      }

      // Core sync tasks - wrap with error tracking.
      // Auth/rate-limit/RLS rejections (dead refresh token, 429, 42501) are
      // treated like offline: back off quietly with cache instead of
      // spamming logs and hammering Supabase into a rate-limit spiral.
      bool anyTaskFailed = false;
      bool isBenignSyncFailure(Object e) =>
          isExpectedOfflineFailure(e) || isAuthRateLimitFailure(e);

      // Replay queued offline mutations (e.g. chat-translation toggles made
      // while offline) BEFORE pulling server state. syncChatsNow treats the
      // server row as canonical and would otherwise overwrite the local
      // intent with the stale pre-toggle value for one full sync cycle.
      try {
        final pendingMutations = await offlineCacheManager
            .getPendingMutationCount();
        if (pendingMutations > 0) {
          await _syncPendingMutations();
        }
      } catch (_) {
        // Mutation replay is best-effort; anything left queued retries on
        // the next sync cycle.
      }

      final syncTasks = [
        _syncMatches(userId).catchError((e) {
          if (!isBenignSyncFailure(e)) {
            debugPrint('⚠️ [SYNC] Matches sync failed: $e');
          }
          if (!isBenignSyncFailure(e)) anyTaskFailed = true;
        }),
        syncChatsNow(userId).catchError((e) {
          if (!isBenignSyncFailure(e)) {
            debugPrint('⚠️ [SYNC] Chats sync failed: $e');
          }
          if (!isBenignSyncFailure(e)) anyTaskFailed = true;
        }),
        _syncAllChatHistories(userId).catchError((e) {
          if (!isBenignSyncFailure(e)) {
            debugPrint('⚠️ [SYNC] Chat histories sync failed: $e');
          }
          if (!isBenignSyncFailure(e)) anyTaskFailed = true;
        }),
        _syncUserEvents(userId).catchError((e) {
          if (!isBenignSyncFailure(e)) {
            debugPrint('⚠️ [SYNC] User events sync failed: $e');
          }
          if (!isBenignSyncFailure(e)) anyTaskFailed = true;
        }),
        _syncPendingMutations().catchError((e) {
          debugPrint('⚠️ [SYNC] Pending mutations sync failed: $e');
          // Don't mark as failed - mutations can be retried
        }),
      ];

      await Future.wait(syncTasks, eagerError: false);

      // If all tasks succeeded, mark Supabase as available. No manual invalidate:
      // Hive watch + distinct emits only on real change, keeping refresh invisible.
      if (!anyTaskFailed) {
        offlineCacheManager.setSupabaseAvailability(true);
        debugPrint('✅ [SYNC] All sync tasks completed successfully');
        // Pick up tiles for any newly synced match locations (de-duplicated
        // per session; no-op when nothing is new).
        unawaited(
          MapTileCacheService.instance.warmCachedMatchMinimaps(),
        );
      } else {
        debugPrint(
          '⚠️ [SYNC] Some sync tasks failed - keeping current connectivity state',
        );
      }
    } finally {
      _syncInProgress = false;
    }
  }

  /// Sync all pending mutations to Supabase
  Future<void> _syncPendingMutations() async {
    final pendingCount = await offlineCacheManager.getPendingMutationCount();
    if (pendingCount == 0) return;

    debugPrint('🔄 [SYNC] Syncing $pendingCount pending mutations...');
    final result = await offlineCacheManager.syncPendingMutations();

    if (result.isSuccess) {
      debugPrint(
        '✅ [SYNC] All ${result.successful} mutations synced successfully',
      );
    } else {
      debugPrint(
        '⚠️ [SYNC] Mutation sync partial: ${result.successful} successful, ${result.failed} failed',
      );
      if (result.errors.isNotEmpty) {
        debugPrint('   Errors: ${result.errors.join(', ')}');
      }
    }
  }

  // --- Core Sync Logic ---

  Future<void> _syncMatches(String userId) async {
    if (shouldSkipSupabaseCalls()) {
      debugPrint('⏸️ [SYNC] _syncMatches: skipped - offline');
      return;
    }
    try {
      final localDb = _ref.read(localDbProvider);
      final defaultWindowSeconds = await appConfigService.getInt(
        'matches.chat_start_window_seconds',
        defaultValue: const Duration(hours: 24).inSeconds,
      );

      final existing = await localDb.watchMatches(userId).first;
      final existingByMatchId = <String, Map<String, dynamic>>{
        for (final m in existing)
          (m['match_id'] ?? m['id'])?.toString() ?? '': m,
      };

      // Fetch matches with coarse map viewport (privacy option 3)
      List<Map<String, dynamic>> matchesData;
      try {
        final response = await supabase
            .from('matches')
            .select('''
              id,
              user1_id,
              user2_id,
              matched_intent,
              match_type,
              created_at,
              chat_start_window_seconds,
              chat_start_extension_seconds,
              chat_start_extension_count,
              chat_start_user1_extension_seconds,
              chat_start_user2_extension_seconds,
              chat_start_user1_extended_at,
              chat_start_user2_extended_at,
              event_id,
              match_occurrence,
              map_center_lat,
              map_center_lng,
              map_zoom,
              is_retroactive,
              events:event_id (event_name, event_link)
            ''')
            .or('user1_id.eq.$userId,user2_id.eq.$userId');
        matchesData = response.cast<Map<String, dynamic>>();
      } catch (_) {
        // Fallback when new columns are not yet migrated (backward compat)
        try {
          final response = await supabase
              .from('matches')
              .select('''
                id,
                user1_id,
                user2_id,
                matched_intent,
                match_type,
                created_at,
                chat_start_window_seconds,
                chat_start_extension_seconds,
                chat_start_extension_count,
                event_id,
                events:event_id (event_name, event_link)
              ''')
              .or('user1_id.eq.$userId,user2_id.eq.$userId');
          matchesData = response.cast<Map<String, dynamic>>();
        } catch (_) {
          final response = await supabase
              .from('matches')
              .select('''
                id,
                user1_id,
                user2_id,
                matched_intent,
                match_type,
                created_at,
                event_id,
                events:event_id (event_name, event_link)
              ''')
              .or('user1_id.eq.$userId,user2_id.eq.$userId');
          matchesData = response.cast<Map<String, dynamic>>();
        }
      }

      // Deduplicate by match ID (each match has a unique id)
      final seenIds = <String>{};
      final uniqueMatches = <Map<String, dynamic>>[];

      for (final match in matchesData) {
        final id = match['id']?.toString() ?? '';
        if (id.isEmpty || !seenIds.add(id)) continue;
        uniqueMatches.add(match);
      }

      final List<Map<String, dynamic>> transformedMatches = uniqueMatches.map((
        match,
      ) {
        final eventDetails = match['events'] as Map<String, dynamic>?;
        final matchId = (match['id'] ?? match['match_id'])?.toString() ?? '';
        final existingRow = existingByMatchId[matchId];
        final dynamic existingWindowRaw =
            existingRow?['chat_start_window_seconds'];
        final int? existingWindowSeconds = existingWindowRaw is int
            ? existingWindowRaw
            : int.tryParse(existingWindowRaw?.toString() ?? '');
        final dynamic incomingWindowRaw = match['chat_start_window_seconds'];
        final int? incomingWindowSeconds = incomingWindowRaw is int
            ? incomingWindowRaw
            : int.tryParse(incomingWindowRaw?.toString() ?? '');
        final resolvedWindowSeconds =
            incomingWindowSeconds ??
            existingWindowSeconds ??
            defaultWindowSeconds;
        // Extension fields (server is source of truth when present)
        int resolveExt(String key) {
          final dynamic incoming = match[key];
          final int? inc = incoming is int
              ? incoming
              : int.tryParse(incoming?.toString() ?? '');
          if (inc != null) return inc;
          final dynamic existing = existingRow?[key];
          final int? ex = existing is int
              ? existing
              : int.tryParse(existing?.toString() ?? '');
          return ex ?? 0;
        }

        final resolvedExtSeconds = resolveExt('chat_start_extension_seconds');
        final resolvedExtCount = resolveExt('chat_start_extension_count');
        final dynamic incomingHasExt = match['has_extended'];
        // Per-user extension tracking lives directly on matches: a user has
        // extended when their per-user extension amount is > 0. The row already
        // carries user1_id/user2_id, so no per-user side table is needed.
        final bool isUser1 = (match['user1_id']?.toString() ?? '') == userId;
        final int myExtSeconds = resolveExt(
          isUser1
              ? 'chat_start_user1_extension_seconds'
              : 'chat_start_user2_extension_seconds',
        );
        // When the server hasn't run the consolidation migration yet, the
        // per-user columns are absent from the response; fall back to this
        // user's cached has_extended value only in that case.
        final bool hasPerUserColumns =
            match.containsKey('chat_start_user1_extension_seconds') ||
            (existingRow?.containsKey('chat_start_user1_extension_seconds') ??
                false);
        final bool resolvedHasExtended =
            myExtSeconds > 0 ||
            incomingHasExt == true ||
            incomingHasExt?.toString().toLowerCase() == 'true' ||
            (!hasPerUserColumns && existingRow?['has_extended'] == true);
        return {
          'match_id': matchId,
          'user1_id': match['user1_id'],
          'user2_id': match['user2_id'],
          'matched_intent': match['matched_intent'],
          'match_type': match['match_type'],
          'chat_start_window_seconds': resolvedWindowSeconds,
          'chat_start_extension_seconds': resolvedExtSeconds,
          'chat_start_extension_count': resolvedExtCount,
          'has_extended': resolvedHasExtended,
          'created_at': match['created_at'],
          'event_id': match['event_id'],
          'event_name': eventDetails?['event_name'],
          'event_link': eventDetails?['event_link'],
          if (match['expires_at'] != null) 'expires_at': match['expires_at'],
          // Coarse map + rematch (privacy option 3)
          if (match['match_occurrence'] != null)
            'match_occurrence': match['match_occurrence'],
          if (match['map_center_lat'] != null)
            'map_center_lat': match['map_center_lat'],
          if (match['map_center_lng'] != null)
            'map_center_lng': match['map_center_lng'],
          if (match['map_zoom'] != null) 'map_zoom': match['map_zoom'],
          if (existingRow?['match_occurrence'] != null &&
              match['match_occurrence'] == null)
            'match_occurrence': existingRow!['match_occurrence'],
          if (existingRow?['map_center_lat'] != null &&
              match['map_center_lat'] == null)
            'map_center_lat': existingRow!['map_center_lat'],
          if (existingRow?['map_center_lng'] != null &&
              match['map_center_lng'] == null)
            'map_center_lng': existingRow!['map_center_lng'],
          if (existingRow?['map_zoom'] != null && match['map_zoom'] == null)
            'map_zoom': existingRow!['map_zoom'],
          // History for rematch maps - _syncMatches reads direct matches table (no previous_locations),
          // so preserve from cache to avoid wiping what syncMatchesNow saved from RPC.
          if (existingRow?['previous_locations'] != null)
            'previous_locations': existingRow!['previous_locations']
          else if (existingRow?['locations_history'] != null)
            'previous_locations': existingRow!['locations_history'],
        };
      }).toList();

      await localDb.saveMatches(userId, transformedMatches);
      debugPrint(
        '✅ [CACHE] Saved ${transformedMatches.length} matches to offline cache',
      );
      // Warm matched-user caches (ratings memory+Hive, photo signed-URLs +
      // image bytes) in background so the next UI start renders instantly.
      // Fire-and-forget: never blocks sync.
      unawaited(_warmMatchedUsersCache(userId, transformedMatches));
      unawaited(
        MapTileCacheService.instance
            .warmCachedMatchMinimaps()
            .catchError((_) {}),
      );
    } catch (e) {
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        debugPrint('⚠️ [SYNC] _syncMatches failed: $e');
        rethrow;
      }
    }
  }

  /// Background warm-up for matched-user data (ratings + photos).
  ///
  /// Called after matches are saved. Reads other-user ids from [matches],
  /// warms rating summaries (memory + Hive) and prefetches profile photos
  /// (signed-URL cache + image disk cache) so lists render instantly on the
  /// next startup. Best-effort: never throws, never blocks sync.
  Future<void> _warmMatchedUsersCache(
    String userId,
    List<Map<String, dynamic>> matches,
  ) async {
    try {
      if (userId.isEmpty || matches.isEmpty) return;
      final otherIds = <String>{};
      for (final m in matches) {
        final u1 = (m['user1_id'] ?? '').toString().trim();
        final u2 = (m['user2_id'] ?? '').toString().trim();
        final other = u1 == userId ? u2 : (u2 == userId ? u1 : '');
        if (other.isNotEmpty) otherIds.add(other);
      }
      if (otherIds.isEmpty) return;

      // 1) Ratings: warm memory from Hive + background Supabase refresh.
      try {
        MatchRatingService.prefetchSummaries(MatchRatingService(), otherIds);
      } catch (_) {}

      // 2) Photos: collect cached photo paths (profiles + chats) and prefetch.
      try {
        final localDb = _ref.read(localDbProvider);
        final sources = <String>{};
        for (final otherId in otherIds) {
          try {
            final profile = await localDb.getLocalProfile(otherId);
            final photos = profile?['photos'];
            if (photos is List) {
              for (final p in photos) {
                final s = p.toString().trim();
                if (s.isNotEmpty) sources.add(s);
              }
            }
          } catch (_) {}
        }
        try {
          final chats = await localDb.loadChats(userId);
          if (chats != null) {
            for (final c in chats) {
              final photos = c['other_user_photos'];
              if (photos is List) {
                for (final p in photos) {
                  final s = p.toString().trim();
                  if (s.isNotEmpty) sources.add(s);
                }
              }
            }
          }
        } catch (_) {}
        if (sources.isNotEmpty) {
          unawaited(
            StorageHelper.prefetchImageSources(sources).catchError((_) {}),
          );
        }
      } catch (_) {}
    } catch (_) {}
  }

  /// Waits (briefly) for [chatKeyProvider] to finish initializing for [userId].
  ///
  /// The first sync after sign-in can fire before the key provider has loaded
  /// the user's private key, which would leave the very first sync persisting
  /// undecrypted message previews that only the next periodic sync could fix.
  /// Callers start this *before* their network fetch so the wait overlaps the
  /// round trip rather than adding to it.
  ///
  /// Always completes (never throws) and is a no-op when the signed-in user is
  /// not [userId], or when the key is already usable.
  Future<void> _awaitChatKeyReadiness(String userId) async {
    // Never throws: callers start this before their network fetch and may not
    // await it on an error path, so a rejection here would surface as an
    // unhandled async error rather than a sync failure.
    try {
      if (supabase.auth.currentUser?.id != userId) return;

      final keyNotifier = _ref.read(chatKeyProvider.notifier);
      bool keyTerminal() {
        final s = _ref.read(chatKeyProvider);
        return s.isLoaded &&
            keyNotifier.initializedUserId == userId &&
            (s.privateKeyBytes != null || s.isLocked);
      }

      if (keyTerminal()) return;

      final deadline = DateTime.now().add(_chatKeyReadinessTimeout);
      while (!keyTerminal() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      if (kDebugMode) {
        final s = _ref.read(chatKeyProvider);
        debugPrint(
          '🔑 [syncChatsNow] Key readiness for $userId: '
          'loaded=${s.isLoaded} locked=${s.isLocked} '
          'hasKey=${s.privateKeyBytes != null} '
          'initializedFor=${keyNotifier.initializedUserId}',
        );
      }
    } catch (error) {
      debugPrint('⚠️ [syncChatsNow] chat key readiness check failed: $error');
    }
  }

  Future<void> syncChatsNow(String userId, {bool force = false}) async {
    if (_disposed) {
      final currentAuthUser = supabase.auth.currentUser?.id;
      if (currentAuthUser != null &&
          currentAuthUser == userId &&
          userId.isNotEmpty) {
        _disposed = false;
      } else {
        return;
      }
    }

    // Skip sync if Supabase communication is paused
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '⏸️ [SYNC] syncChatsNow: Skipped - Supabase communication paused',
      );
      return;
    }

    // Rapid-fire guard: silently drops non-force calls within 1s of the last
    // attempt to avoid noisy cooldown prints when many event sources fire at once.
    final now = DateTime.now();
    if (!force &&
        _lastSyncChatsAttempt != null &&
        now.difference(_lastSyncChatsAttempt!) < _syncChatsMinInterval) {
      _lastSyncChatsAttempt = now;
      return;
    }
    _lastSyncChatsAttempt = now;

    // Static cooldown to prevent rapid sequential calls from different sources.
    // When force is true (e.g., triggered by a chats DELETE realtime event),
    // bypass the cooldown so the client reflects the deletion promptly.
    if (!force && _lastSyncChatsCall != null) {
      final timeSinceLastCall = now.difference(_lastSyncChatsCall!);
      if (timeSinceLastCall < _syncChatsCooldown) {
        if (kIsWeb) {
          debugPrint(
            '🔍 [WEB] syncChatsNow: Skipping - cooldown active (${timeSinceLastCall.inSeconds}s < ${_syncChatsCooldown.inSeconds}s)',
          );
        }
        return;
      }
    }

    // Post-completion deduplication: skip if the last sync finished very
    // recently (covers the gap where the debounce timer fired but the next
    // call arrives before the cooldown expires).
    if (!force && _lastSyncChatsCompleted != null) {
      final timeSinceCompleted = now.difference(_lastSyncChatsCompleted!);
      if (timeSinceCompleted < _syncChatsPostCompletionCooldown) {
        if (kIsWeb) {
          debugPrint(
            '🔍 [WEB] syncChatsNow: Skipping - recently completed (${timeSinceCompleted.inSeconds}s < ${_syncChatsPostCompletionCooldown.inSeconds}s)',
          );
        }
        return;
      }
    }

    // If a sync is already scheduled or in progress, return early.
    // However, if forced, we let it through to ensure the deletion is reflected.
    if (!force && _syncChatsScheduled) {
      return;
    }

    // Mark as scheduled and set cooldown timestamp IMMEDIATELY so subsequent
    // calls within the cooldown window see the updated timestamp. Previously
    // this was set inside the debounce callback, which meant two rapid calls
    // both passed the cooldown check before either debounce fired.
    _syncChatsScheduled = true;
    _lastSyncChatsCall = now;

    // Cancel existing debounce timer
    _syncChatsDebounceTimer?.cancel();

    // Create a completer to make this awaitable
    final completer = Completer<void>();

    _syncChatsDebounceTimer = Timer(
      // `force` callers (notably initialHomeSyncProvider) *await* this, so the
      // 500ms debounce was pure serial latency on the first home render. Only
      // unforced calls need the coalescing window.
      force ? Duration.zero : const Duration(milliseconds: 500),
      () async {
        if (_disposed) {
          _syncChatsScheduled = false;
          completer.complete();
          return;
        }
        if (kIsWeb && kDebugMode) {
          debugPrint('🔍 [WEB] syncChatsNow: Starting sync');
        }
        try {
          final localDb = _ref.read(localDbProvider);

          // Use simplified RPC function for better performance
          try {
            // The first sync after sign-in can fire before the chat key provider
            // has finished initializing for this user. Start that readiness poll
            // *now*, concurrently with the network round trip, instead of after
            // it - previously the two ran back to back, so the poll's whole
            // duration added to the time before the home screen could render.
            final keyReady = _awaitChatKeyReadiness(userId);

            // Full-list sync: the Chats and Matches screens read the same
            // Hive cache this writes, so the fetch must cover every active
            // chat — not a Home-sized preview page. The Home "Recent" tabs
            // cap their own display via home.recent_items_limit.
            final fullLimit = await appConfigService.getInt(
              'sync.full_items_limit',
              defaultValue: 500,
            );
            final recent = await supabase.rpc(
              'get_user_recent_chats',
              params: {'p_user_id': userId, 'p_limit': fullLimit},
            );

            await keyReady;

            if (kDebugMode) {
              debugPrint(
                '📊 syncChatsNow: Server returned ${recent.length} chats',
              );
              for (final row in recent) {
                if (row is Map) {
                  final map = Map<String, dynamic>.from(row);
                  debugPrint(
                    '📊 syncChatsNow: Server chat ${map['match_id']}: unread_count=${map['unread_count']}',
                  );
                }
              }
            } else {
              debugPrint(
                '📊 syncChatsNow: Server returned ${recent.length} chats',
              );
            }

            if (recent is List) {
              final List<Map<String, dynamic>> transformed = [];

              for (final row in recent) {
                if (row is Map) {
                  // Convert to Map<String, dynamic> to handle platform differences
                  // (web returns Map<String, dynamic>, mobile may return Map<dynamic, dynamic>)
                  final map = Map<String, dynamic>.from(row);
                  final encryptionScheme =
                      map['last_message_encryption_scheme'] as String?;
                  transformed.add({
                    'match_id': map['match_id'],
                    'other_user_id': map['other_user_id'],
                    'other_user_name': map['other_name'] ?? 'Unknown User',
                    'other_user_photos': map['other_photos'],
                    'last_message': encryptionScheme == 'v1'
                        ? ''
                        : (map['last_message_preview'] ?? ''),
                    'last_message_at': map['last_message_at'],
                    'unread_count': map['unread_count'] ?? 0,
                    'updated_at': map['updated_at'],
                    'translation_enabled': map['translation_enabled'] ?? false,
                    'translation_language': map['translation_language'],
                    'last_message_id': map['last_message_id'],
                    'last_message_sender_id': map['last_message_sender_id'],
                    // get_user_recent_chats returns
                    // chat_messages.content_translated_encrypted in this column,
                    // i.e. raw base64 ciphertext for v1 messages. Phase 3 below
                    // overwrites it with plaintext once the chat key is usable.
                    // Until then it is unreadable, so never cache it: an empty
                    // value lets saveChats keep the last known good plaintext
                    // instead of replacing it with a blob the user cannot read.
                    'last_message_translated': encryptionScheme == 'v1'
                        ? null
                        : map['last_message_translated'],
                    'last_message_source_language':
                        map['last_message_source_language'],
                    'last_message_target_language':
                        map['last_message_target_language'],
                    'last_message_encryption_scheme': encryptionScheme,
                    'last_message_sender_key_id':
                        map['last_message_sender_key_id'],
                    'last_message_recipient_key_id':
                        map['last_message_recipient_key_id'],
                    'last_message_recipient_id':
                        map['last_message_recipient_id'],
                    'last_message_content_original_encrypted':
                        map['last_message_content_original_encrypted'],
                    'last_message_content_original_nonce':
                        map['last_message_content_original_nonce'],
                    'last_message_content_translated_encrypted':
                        map['last_message_content_translated_encrypted'],
                    'last_message_content_translated_nonce':
                        map['last_message_content_translated_nonce'],
                    'last_message_wrapped_keys':
                        map['last_message_wrapped_keys'],
                    'matched_intent':
                        map['matched_intent'] ?? map['matchedIntent'],
                    // Content version of the last message. Paired with the
                    // `last_message_translated_edited_at` the client stamps when
                    // it caches a decrypted preview, this is what lets the chat
                    // list tell a translation of the current text from one made
                    // before the message was edited (an edit keeps the id).
                    'last_message_edited_at': map['last_message_edited_at'],
                    'last_message_translated_source_edited_at':
                        map['last_message_translated_source_edited_at'],
                    // Per-user archive marker. The chats list splits into
                    // active/archived views on this; null = active chat.
                    'archived_at': map['archived_at'],
                  });
                }
              }

              // Chat-key readiness is awaited above, concurrently with the RPC.
              final chatKeyState = _ref.read(chatKeyProvider);
              final Map<String, Map<String, dynamic>> msgById = {};
              if (chatKeyState.privateKeyBytes != null &&
                  chatKeyState.privateKeyBytes!.isNotEmpty &&
                  _ref.read(chatKeyProvider.notifier).initializedUserId ==
                      userId) {
                final chatKeyService = ChatKeyService.instance;

                // Phase 1: fetch msgData for all last messages.
                //
                // One batched `in_` query rather than one round trip per chat:
                // this loop previously ran N sequential PostgREST requests, which
                // dominated the first home render for users with a full chat list.
                final messageIds = <String>[];
                for (final chat in transformed) {
                  final id = chat['last_message_id'] as String?;
                  if (id != null && id.isNotEmpty) messageIds.add(id);
                }
                if (messageIds.isNotEmpty) {
                  try {
                    final rows = await supabase
                        .from('chat_messages')
                        .select(
                          'id, match_id, sender_id, recipient_id, created_at, '
                          'delivered_at, read_at, reaction_summary, reply_to_message_id, '
                          'translation_capable, encryption_scheme, sender_key_id, recipient_key_id, '
                          'content_original_encrypted, content_original_nonce, '
                          'content_translated_encrypted, content_translated_nonce, '
                          'wrapped_keys, '
                          'detected_source_language, translated_target_language, '
                          'edited_at, translated_source_edited_at',
                        )
                        .inFilter('id', messageIds);
                    for (final row in rows) {
                      final map = Map<String, dynamic>.from(row as Map);
                      final id = map['id'] as String?;
                      if (id != null) msgById[id] = map;
                    }
                  } catch (e) {
                    if (kDebugMode) {
                      debugPrint(
                        '⚠️ [syncChatsNow] batched chat_messages fetch failed: $e',
                      );
                    }
                  }
                }

                final List<Map<String, dynamic>?> allMsgData = transformed
                    .map(
                      (chat) =>
                          msgById[chat['last_message_id'] as String? ?? ''],
                    )
                    .toList();

                // Collect unique peer key IDs
                final Set<String> uniquePeerKeyIds = {};
                for (final msgData in allMsgData) {
                  if (msgData != null && msgData['encryption_scheme'] == 'v1') {
                    final sid = msgData['sender_id'] as String;
                    final peerKeyId = userId == sid
                        ? msgData['recipient_key_id'] as String
                        : msgData['sender_key_id'] as String;
                    uniquePeerKeyIds.add(peerKeyId);
                  }
                }

                // Phase 2: pre-fetch all unique peer keys in parallel
                final Map<String, UserChatKeyModel?> peerKeys = {};
                if (uniquePeerKeyIds.isNotEmpty) {
                  final futures = uniquePeerKeyIds.map((id) async {
                    peerKeys[id] = await chatKeyService.fetchPeerPublicKey(id);
                  });
                  await Future.wait(futures);
                }

                // Phase 3: decrypt using pre-fetched peer keys
                for (int i = 0; i < transformed.length; i++) {
                  final msgData = allMsgData[i];
                  if (msgData == null) continue;
                  transformed[i]['last_message_encryption_scheme'] =
                      msgData['encryption_scheme'] as String?;
                  if (msgData['encryption_scheme'] != 'v1') continue;
                  final wrappedKeys = msgData['wrapped_keys'];
                  if (wrappedKeys is! Map) continue;

                  final sid = msgData['sender_id'] as String;
                  final peerKeyId = userId == sid
                      ? msgData['recipient_key_id'] as String
                      : msgData['sender_key_id'] as String;
                  final peerKey = peerKeys[peerKeyId];

                  // Decrypt original content
                  try {
                    final decryptedOriginal = await chatKeyService
                        .decryptMessageContent(
                          currentUserId: userId,
                          currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                          messageId: msgData['id'] as String,
                          matchId: msgData['match_id'] as String,
                          senderId: sid,
                          senderKeyId: msgData['sender_key_id'] as String,
                          recipientKeyId: msgData['recipient_key_id'] as String,
                          contentOriginalEncryptedBase64:
                              msgData['content_original_encrypted'] as String,
                          contentOriginalNonceBase64:
                              msgData['content_original_nonce'] as String,
                          wrappedKeys: Map<String, dynamic>.from(wrappedKeys),
                          recipientId: msgData['recipient_id'] as String?,
                          prefetchedPeerKey: peerKey,
                        );
                    if (decryptedOriginal != null) {
                      transformed[i]['last_message'] = decryptedOriginal;
                    }
                  } catch (_) {}

                  // Decrypt translated content
                  final translatedEncrypted =
                      msgData['content_translated_encrypted'] as String?;
                  final translatedNonce =
                      msgData['content_translated_nonce'] as String?;
                  if (translatedEncrypted == null || translatedNonce == null) {
                    continue;
                  }
                  // Only decrypt a translation the server still vouches for. The
                  // translation AAD binds the target language but not the original
                  // content, so a pre-edit blob decrypts cleanly and would be
                  // cached as if it described the edited text.
                  final rowEditedAt = normalizeEditMarker(msgData['edited_at']);
                  if (!translationEditMarkersMatch(
                    normalizeEditMarker(msgData['translated_source_edited_at']),
                    rowEditedAt,
                  )) {
                    continue;
                  }
                  try {
                    final decryptedTranslated = await chatKeyService
                        .decryptMessageTranslatedContent(
                          currentUserId: userId,
                          currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                          messageId: msgData['id'] as String,
                          matchId: msgData['match_id'] as String,
                          senderId: sid,
                          senderKeyId: msgData['sender_key_id'] as String,
                          recipientKeyId: msgData['recipient_key_id'] as String,
                          contentTranslatedEncryptedBase64: translatedEncrypted,
                          contentTranslatedNonceBase64: translatedNonce,
                          wrappedKeys: Map<String, dynamic>.from(wrappedKeys),
                          detectedSourceLanguage:
                              (msgData['detected_source_language']
                                  as String?) ??
                              'und',
                          targetLanguage:
                              (msgData['translated_target_language']
                                  as String?) ??
                              '',
                          recipientId: msgData['recipient_id'] as String?,
                          prefetchedPeerKey: peerKey,
                        );
                    if (decryptedTranslated != null) {
                      transformed[i]['last_message_translated'] =
                          decryptedTranslated;
                      // Bind the cached preview to the content version it was
                      // made for, so later syncs can tell it apart from a
                      // pre-edit preview (an edit keeps the message id).
                      if (rowEditedAt != null) {
                        transformed[i]['last_message_translated_edited_at'] =
                            rowEditedAt;
                      }
                    }
                  } catch (_) {}
                }
              }

              // The chats RPC already fetched each latest message to render
              // its preview. Persist that row too, so opening a conversation
              // offline still shows the content the user has already seen.
              // Merge rather than replace so any previously cached history is
              // retained.
              for (var i = 0; i < transformed.length; i++) {
                final chat = transformed[i];
                final messageId = chat['last_message_id']?.toString() ?? '';
                final matchId = chat['match_id']?.toString() ?? '';
                if (messageId.isEmpty || matchId.isEmpty) continue;

                final source = msgById[messageId];
                final preview = chat['last_message']?.toString() ?? '';
                if (source == null && preview.isEmpty) continue;

                final cachedMessage = <String, dynamic>{
                  ...?source,
                  'id': messageId,
                  'match_id': matchId,
                  'sender_id':
                      source?['sender_id'] ?? chat['last_message_sender_id'],
                  'created_at':
                      source?['created_at'] ?? chat['last_message_at'],
                  'encryption_scheme':
                      source?['encryption_scheme'] ??
                      chat['last_message_encryption_scheme'] ??
                      'legacy',
                  if (preview.isNotEmpty) 'content_original': preview,
                  if ((chat['last_message_translated']?.toString() ?? '')
                      .isNotEmpty)
                    'content_translated': chat['last_message_translated'],
                  'edited_at':
                      source?['edited_at'] ?? chat['last_message_edited_at'],
                  'translated_source_edited_at':
                      source?['translated_source_edited_at'] ??
                      chat['last_message_translated_source_edited_at'],
                };
                await localDb.mergeMessages(matchId, [cachedMessage]);
              }

              // Enrich matched_intent from local matches cache when the RPC
              // hasn't yet been upgraded (old server) or returned null.
              final needsEnrich = transformed.any(
                (c) =>
                    c['matched_intent'] == null ||
                    (c['matched_intent'] as String).trim().isEmpty,
              );
              if (needsEnrich) {
                try {
                  final localDbForEnrich = _ref.read(localDbProvider);
                  final cachedMatches = await localDbForEnrich
                      .watchMatches(userId)
                      .first;
                  final intentByMatchId = <String, String>{
                    for (final m in cachedMatches)
                      (m['match_id'] ?? m['id']).toString():
                          (m['matched_intent'] ?? '').toString(),
                  };
                  for (final chat in transformed) {
                    if (chat['matched_intent'] == null ||
                        (chat['matched_intent'] as String).trim().isEmpty) {
                      final mid = chat['match_id']?.toString() ?? '';
                      final fallback = intentByMatchId[mid];
                      if (fallback != null && fallback.trim().isNotEmpty) {
                        chat['matched_intent'] = fallback;
                      }
                    }
                  }
                } catch (_) {}
              }

              // Fingerprint check: skip save if data hasn't changed
              final fingerprint = _computeChatsFingerdebugPrint(transformed);
              final previousFingerprint = _lastSyncFingerprints[userId];
              if (previousFingerprint == fingerprint) {
                if (transformed.isEmpty && recent.isNotEmpty) {
                  debugPrint(
                    '⚠️ syncChatsNow: Server returned ${recent.length} rows but transformed is 0 - check row types',
                  );
                }
              } else {
                _lastSyncFingerprints[userId] = fingerprint;

                debugPrint(
                  '📊 syncChatsNow: About to save ${transformed.length} chats to local DB',
                );
                for (final chat in transformed) {
                  debugPrint(
                    '📊 syncChatsNow: Saving chat ${chat['match_id']}: unread_count=${chat['unread_count']}',
                  );
                }
                // Guard: don't overwrite valid local cache with empty server response.
                // A transient RPC blip (e.g. auth refresh, RLS race, connection pool)
                // can return zero rows even though the user has chats.
                if (transformed.isEmpty) {
                  if (kIsWeb) {
                    debugPrint(
                      '🔍 [WEB] syncChatsNow: Server returned 0 chats — clearing local cache',
                    );
                  }
                  await localDb.saveChats(userId, transformed);
                } else {
                  await localDb.saveChats(userId, transformed);
                }
                if (kIsWeb) {
                  debugPrint(
                    '🔍 [WEB] syncChatsNow: Completed saving chats to local DB',
                  );
                }

                // Sync translation settings from server for each chat to ensure
                // they match database state. Hive writes are independent, so run
                // them concurrently instead of one round trip per chat.
                final translationWrites = <Future<void>>[];
                for (final row in recent) {
                  if (row is! Map) continue;
                  final map = Map<String, dynamic>.from(row);
                  final matchId = map['match_id'];
                  if (matchId == null) continue;
                  translationWrites.add(
                    localDb.syncChatTranslationSettings(
                      userId,
                      matchId,
                      map['translation_enabled'] ?? false,
                      map['translation_language'],
                    ),
                  );
                }
                await Future.wait(translationWrites);

                // Update translation provider state to match server - ensures UI reflects actual server state
                try {
                  final translationNotifier = _ref.read(
                    translationProvider.notifier,
                  );
                  for (final row in recent) {
                    if (row is Map) {
                      final map = Map<String, dynamic>.from(row);
                      final matchId = map['match_id'] as String?;
                      final translationEnabled =
                          map['translation_enabled'] == true;
                      final translationLanguage =
                          map['translation_language'] as String?;

                      if (matchId != null) {
                        // Update provider state: if translation enabled, set language; otherwise remove
                        if (translationEnabled && translationLanguage != null) {
                          final currentState = _ref.read(translationProvider);
                          if (currentState[matchId] != translationLanguage) {
                            translationNotifier.setTranslationSilent(
                              matchId,
                              translationLanguage,
                            );
                          }
                        } else {
                          // Translation is disabled, remove from provider state
                          final currentState = _ref.read(translationProvider);
                          if (currentState.containsKey(matchId)) {
                            translationNotifier.clearTranslationSilent(matchId);
                          }
                        }
                      }
                    }
                  }
                } catch (e) {
                  // Ignore provider update errors - they're best-effort
                  debugPrint('⚠️ Failed to update translation provider: $e');
                }
              }
            }
          } catch (e) {
            if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
              debugPrint('❌ syncChatsNow failed: $e');
            }
            // No complex fallback - keep it simple
          }
        } catch (e) {
          if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
            debugPrint('❌ syncChatsNow error: $e');
          }
        } finally {
          _syncChatsScheduled = false;
          _lastSyncChatsCompleted = DateTime.now();
          completer.complete();
        }
      },
    );

    return completer.future;
  }

  static String _computeChatsFingerdebugPrint(
    List<Map<String, dynamic>> chats,
  ) {
    final buffer = StringBuffer();
    for (final chat in chats) {
      // `last_message_edited_at` is part of the fingerprint: an edit changes
      // neither the preview text nor the message id, so without it a sync that
      // only observed an edit would be skipped and the stale cached
      // translation would never be re-evaluated.
      buffer.write(
        '${chat['match_id']}|${chat['unread_count']}|${chat['last_message_id']}|${chat['last_message']}|${chat['translation_enabled']}|${chat['translation_language']}|${chat['last_message_translated']}|${chat['last_message_target_language']}|${chat['last_message_translated_edited_at']}|${chat['last_message_edited_at']}|${chat['matched_intent']}|',
      );
    }
    return buffer.toString();
  }

  Future<void> syncMatchesNow(String userId) async {
    if (_disposed) {
      final currentAuthUser = supabase.auth.currentUser?.id;
      if (currentAuthUser != null &&
          currentAuthUser == userId &&
          userId.isNotEmpty) {
        _disposed = false;
      } else {
        return;
      }
    }

    // Skip sync if Supabase communication is paused
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '⏸️ [SYNC] syncMatchesNow: Skipped - Supabase communication paused',
      );
      return;
    }

    try {
      final localDb = _ref.read(localDbProvider);
      final defaultWindowSeconds = await appConfigService.getInt(
        'matches.chat_start_window_seconds',
        defaultValue: const Duration(hours: 24).inSeconds,
      );
      final existing = await localDb.watchMatches(userId).first;
      final existingByMatchId = <String, Map<String, dynamic>>{
        for (final m in existing)
          (m['match_id'] ?? m['id'])?.toString() ?? '': m,
      };

      // Use simplified RPC function for better performance
      try {
        // Full-list sync (see syncChatsNow): the Matches screen reads this
        // cache, so fetch every active match; Home previews cap in the UI.
        final fullLimit = await appConfigService.getInt(
          'sync.full_items_limit',
          defaultValue: 500,
        );
        final recent = await supabase.rpc(
          'get_user_recent_matches',
          params: {'p_user_id': userId, 'p_limit': fullLimit},
        );

        if (recent is List) {
          final rows = recent
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();

          final hasFullShape =
              rows.isNotEmpty &&
              rows.first.containsKey('user1_id') &&
              rows.first.containsKey('user2_id') &&
              rows.first.containsKey('matched_intent') &&
              rows.first.containsKey('match_type') &&
              rows.first.containsKey('created_at');

          if (hasFullShape) {
            final normalized = rows.map((r) {
              final copy = Map<String, dynamic>.from(r);
              final matchId =
                  (copy['match_id'] ?? copy['id'])?.toString() ?? '';
              final dynamic incomingWindowRaw =
                  copy['chat_start_window_seconds'];
              final int? incomingWindowSeconds = incomingWindowRaw is int
                  ? incomingWindowRaw
                  : int.tryParse(incomingWindowRaw?.toString() ?? '');
              final dynamic existingWindowRaw =
                  existingByMatchId[matchId]?['chat_start_window_seconds'];
              final int? existingWindowSeconds = existingWindowRaw is int
                  ? existingWindowRaw
                  : int.tryParse(existingWindowRaw?.toString() ?? '');
              final resolvedWindowSeconds =
                  incomingWindowSeconds ??
                  existingWindowSeconds ??
                  defaultWindowSeconds;
              copy['chat_start_window_seconds'] = resolvedWindowSeconds;
              // Preserve extension fields from RPC when present; fallback to cached values
              // Note: has_extended is user-specific and should always come from RPC, not cached values
              for (final key in [
                'chat_start_extension_seconds',
                'chat_start_extension_count',
                'expires_at',
              ]) {
                final dynamic incoming = copy[key];
                if (incoming == null) {
                  final dynamic existing = existingByMatchId[matchId]?[key];
                  if (existing != null) copy[key] = existing;
                }
              }
              // has_extended is user-specific - always use RPC value, never fallback to cache
              if (copy['has_extended'] == null) {
                copy['has_extended'] = false;
              }
              // Normalize extension ints that may arrive as strings
              for (final k in [
                'chat_start_extension_seconds',
                'chat_start_extension_count',
              ]) {
                final dynamic v = copy[k];
                if (v != null && v is! int) {
                  copy[k] = int.tryParse(v.toString()) ?? 0;
                }
              }
              // Normalize rematch + coarse map fields (preserve cached if RPC missing)
              for (final k in [
                'match_occurrence',
                'map_center_lat',
                'map_center_lng',
                'map_zoom',
              ]) {
                if (copy[k] == null) {
                  final dynamic existing = existingByMatchId[matchId]?[k];
                  if (existing != null) copy[k] = existing;
                }
              }
              if (copy['match_occurrence'] != null &&
                  copy['match_occurrence'] is! int) {
                copy['match_occurrence'] =
                    int.tryParse(copy['match_occurrence'].toString()) ?? 1;
              }
              // Preserve previous_locations (history for rematch maps) - critical for showing both towns
              if (copy['previous_locations'] == null) {
                final dynamic existingPrev =
                    existingByMatchId[matchId]?['previous_locations'] ??
                    existingByMatchId[matchId]?['locations_history'];
                if (existingPrev != null) {
                  copy['previous_locations'] = existingPrev;
                } else if (copy['locations_history'] != null) {
                  copy['previous_locations'] = copy['locations_history'];
                }
              }
              return copy;
            }).toList();
            // Merge, don't overwrite: RPC now reads matches directly, but _syncMatches
            // (all rows) can still have more than RPC limit. Overwriting would flip
            // list causing visible refresh. Prune below removes truly expired.
            final mergedById = <String, Map<String, dynamic>>{
              for (final m in existing)
                (m['match_id'] ?? m['id'])?.toString() ?? '':
                    Map<String, dynamic>.from(m),
            };
            for (final c in normalized) {
              final id = (c['match_id'] ?? c['id'])?.toString() ?? '';
              if (id.isNotEmpty) mergedById[id] = c;
            }
            mergedById.remove('');
            final mergedList = mergedById.values.toList();
            await localDb.saveMatches(userId, mergedList);
            unawaited(_warmMatchedUsersCache(userId, mergedList));
            unawaited(
              MapTileCacheService.instance
                  .warmCachedMatchMinimaps()
                  .catchError((_) {}),
            );
            return;
          }

          final matchIds = rows
              .map((r) => (r['match_id'] ?? r['id'])?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toList();

          if (matchIds.isEmpty) {
            await _syncMatches(userId);
            return;
          }

          List<Map<String, dynamic>> fetched;
          try {
            final resp = await supabase
                .from('matches')
                .select('''
                  id,
                  user1_id,
                  user2_id,
                  matched_intent,
                  match_type,
                  created_at,
                  chat_start_window_seconds,
                  chat_start_extension_seconds,
                  chat_start_extension_count,
                  event_id,
                  match_occurrence,
                  map_center_lat,
                  map_center_lng,
                  map_zoom,
                  is_retroactive,
                  events:event_id (event_name, event_link)
                ''')
                .inFilter('id', matchIds);
            fetched = resp.cast<Map<String, dynamic>>();
          } catch (_) {
            try {
              final resp = await supabase
                  .from('matches')
                  .select('''
                    id,
                    user1_id,
                    user2_id,
                    matched_intent,
                    match_type,
                    created_at,
                    chat_start_window_seconds,
                    chat_start_extension_seconds,
                    chat_start_extension_count,
                    event_id,
                    events:event_id (event_name, event_link)
                  ''')
                  .inFilter('id', matchIds);
              fetched = resp.cast<Map<String, dynamic>>();
            } catch (_) {
              final resp = await supabase
                  .from('matches')
                  .select('''
                    id,
                    user1_id,
                    user2_id,
                    matched_intent,
                    match_type,
                    created_at,
                    event_id,
                    events:event_id (event_name, event_link)
                  ''')
                  .inFilter('id', matchIds);
              fetched = resp.cast<Map<String, dynamic>>();
            }
          }

          final byId = <String, Map<String, dynamic>>{
            for (final m in fetched) (m['id']?.toString() ?? ''): m,
          };

          final transformedMatches = <Map<String, dynamic>>[];
          for (final id in matchIds) {
            final m = byId[id];
            if (m == null) continue;
            final eventDetails = m['events'] as Map<String, dynamic>?;
            final dynamic existingWindowRaw =
                existingByMatchId[id]?['chat_start_window_seconds'];
            final int? existingWindowSeconds = existingWindowRaw is int
                ? existingWindowRaw
                : int.tryParse(existingWindowRaw?.toString() ?? '');
            final resolvedWindowSeconds =
                existingWindowSeconds ?? defaultWindowSeconds;
            // Resolve extension fields: prefer server, fallback to cached
            int resolveExtFromRow(String key) {
              final dynamic incoming = m[key];
              final int? inc = incoming is int
                  ? incoming
                  : int.tryParse(incoming?.toString() ?? '');
              if (inc != null) return inc;
              final dynamic existing = existingByMatchId[id]?[key];
              final int? ex = existing is int
                  ? existing
                  : int.tryParse(existing?.toString() ?? '');
              return ex ?? 0;
            }

            // Also check if the RPC row already had extension data for this id
            final rpcRow = rows.firstWhere(
              (r) => (r['match_id'] ?? r['id'])?.toString() == id,
              orElse: () => <String, dynamic>{},
            );
            int finalExtSeconds = resolveExtFromRow(
              'chat_start_extension_seconds',
            );
            int finalExtCount = resolveExtFromRow('chat_start_extension_count');
            if (rpcRow.isNotEmpty) {
              final dynamic rpcExt = rpcRow['chat_start_extension_seconds'];
              final int? rpcExtVal = rpcExt is int
                  ? rpcExt
                  : int.tryParse(rpcExt?.toString() ?? '');
              if (rpcExtVal != null) finalExtSeconds = rpcExtVal;
              final dynamic rpcCount = rpcRow['chat_start_extension_count'];
              final int? rpcCountVal = rpcCount is int
                  ? rpcCount
                  : int.tryParse(rpcCount?.toString() ?? '');
              if (rpcCountVal != null) finalExtCount = rpcCountVal;
            }
            final dynamic rpcHasExt = rpcRow['has_extended'];
            // has_extended is user-specific - always use RPC value, never fallback to cache
            final bool hasExt =
                rpcHasExt == true ||
                rpcHasExt?.toString().toLowerCase() == 'true';

            transformedMatches.add({
              'match_id': m['id'],
              'user1_id': m['user1_id'],
              'user2_id': m['user2_id'],
              'matched_intent': m['matched_intent'],
              'match_type': m['match_type'],
              'chat_start_window_seconds':
                  m['chat_start_window_seconds'] ?? resolvedWindowSeconds,
              'chat_start_extension_seconds': finalExtSeconds,
              'chat_start_extension_count': finalExtCount,
              'has_extended': hasExt,
              'created_at': m['created_at'],
              'event_id': m['event_id'],
              'event_name': eventDetails?['event_name'],
              'event_link': eventDetails?['event_link'],
              if (rpcRow['expires_at'] != null)
                'expires_at': rpcRow['expires_at'],
              if (m['expires_at'] != null) 'expires_at': m['expires_at'],
              // coarse map + rematch
              if (m['match_occurrence'] != null)
                'match_occurrence': m['match_occurrence']
              else if (rpcRow['match_occurrence'] != null)
                'match_occurrence': rpcRow['match_occurrence']
              else if (existingByMatchId[id]?['match_occurrence'] != null)
                'match_occurrence': existingByMatchId[id]!['match_occurrence'],
              if (m['map_center_lat'] != null)
                'map_center_lat': m['map_center_lat']
              else if (rpcRow['map_center_lat'] != null)
                'map_center_lat': rpcRow['map_center_lat']
              else if (existingByMatchId[id]?['map_center_lat'] != null)
                'map_center_lat': existingByMatchId[id]!['map_center_lat'],
              if (m['map_center_lng'] != null)
                'map_center_lng': m['map_center_lng']
              else if (rpcRow['map_center_lng'] != null)
                'map_center_lng': rpcRow['map_center_lng']
              else if (existingByMatchId[id]?['map_center_lng'] != null)
                'map_center_lng': existingByMatchId[id]!['map_center_lng'],
              if (m['map_zoom'] != null)
                'map_zoom': m['map_zoom']
              else if (rpcRow['map_zoom'] != null)
                'map_zoom': rpcRow['map_zoom']
              else if (existingByMatchId[id]?['map_zoom'] != null)
                'map_zoom': existingByMatchId[id]!['map_zoom'],
              // history for rematch maps (critical: without this, only Location #2 shows)
              if (rpcRow['previous_locations'] != null)
                'previous_locations': rpcRow['previous_locations']
              else if (rpcRow['locations_history'] != null)
                'previous_locations': rpcRow['locations_history']
              else if (existingByMatchId[id]?['previous_locations'] != null)
                'previous_locations':
                    existingByMatchId[id]!['previous_locations']
              else if (existingByMatchId[id]?['locations_history'] != null)
                'previous_locations':
                    existingByMatchId[id]!['locations_history'],
            });
          }

          if (transformedMatches.isNotEmpty) {
            // Same merge reason as above: RPC subset must not wipe existing
            // matches with chats (Ingela) that _syncMatches/direct table has.
            final mergedById = <String, Map<String, dynamic>>{
              for (final m in existing)
                (m['match_id'] ?? m['id'])?.toString() ?? '':
                    Map<String, dynamic>.from(m),
            };
            for (final c in transformedMatches) {
              final id = (c['match_id'] ?? c['id'])?.toString() ?? '';
              if (id.isNotEmpty) mergedById[id] = c;
            }
            mergedById.remove('');
            final mergedList2 = mergedById.values.toList();
            await localDb.saveMatches(userId, mergedList2);
            unawaited(_warmMatchedUsersCache(userId, mergedList2));
            unawaited(
              MapTileCacheService.instance
                  .warmCachedMatchMinimaps()
                  .catchError((_) {}),
            );
            return;
          }

          await _syncMatches(userId);
        }
      } catch (e) {
        if (!isExpectedOfflineFailure(e)) {
          debugPrint('syncMatchesNow: get_user_recent_matches RPC failed: $e');
        }
        // Fallback to original method
        await _syncMatches(userId);
      }
    } catch (e) {
      if (!isExpectedOfflineFailure(e)) {
        debugPrint('syncMatchesNow error: $e');
      }
    }

    // Prune expired locally. Hive watch + distinct provider already emit only on
    // real change, so no manual invalidate (which caused visible reload).
    try {
      final localDb = _ref.read(localDbProvider);
      final chats = await localDb.watchChats(userId).first;
      final chatIds = chats
          .map((c) => c['match_id']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet();
      await localDb.pruneExpiredMatches(userId, chatIds);
    } catch (_) {}
  }

  // ---
  // --- UPDATED: This function now performs an incremental sync for messages
  // ---
  Future<void> _syncAllChatHistories(String userId) async {
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '⏸️ [SYNC] _syncAllChatHistories: Skipped - Supabase communication paused',
      );
      return;
    }

    try {
      final localDb = _ref.read(localDbProvider);

      // 1. Get all match IDs the user is currently in. Page this query too,
      // since users with a long history can exceed the REST response limit.
      const pageSize = 1000;
      final allMatchIds = <String>[];
      var matchOffset = 0;
      while (true) {
        final matchesResponse = await supabase
            .from('matches')
            .select('id')
            .or('user1_id.eq.$userId,user2_id.eq.$userId')
            .order('id', ascending: true)
            .range(matchOffset, matchOffset + pageSize - 1);
        final matchPage = (matchesResponse as List)
            .map((e) => e['id'] as String)
            .where((id) => id.isNotEmpty)
            .toList();
        allMatchIds.addAll(matchPage);
        if (matchPage.length < pageSize) break;
        matchOffset += pageSize;
      }

      if (allMatchIds.isEmpty) return;

      // 2. Create a separate sync task for each match
      final syncTasks = allMatchIds.map((matchId) async {
        try {
          // 3. Get the timestamp of the last message we have
          final latestTimestamp = await localDb.getLatestMessageTimestamp(
            matchId,
          );

          // Supabase/PostgREST limits each response page. Fetch every page so
          // long-running conversations are fully available from local storage.
          var offset = 0;
          while (true) {
            var query = supabase
                .from('chat_messages')
                .select(
                  'id, match_id, sender_id, created_at, edited_at, delivered_at, read_at, '
                  'reaction_summary, reply_to_message_id, '
                  'encryption_scheme, sender_key_id, recipient_key_id, recipient_id, '
                  'content_original_encrypted, content_original_nonce, '
                  'content_translated_encrypted, content_translated_nonce, '
                  'wrapped_keys, translation_capable, detected_source_language, translated_target_language',
                )
                .eq('match_id', matchId);

            // Re-fetch the newest cached timestamp too, so messages sharing
            // that timestamp are not skipped; localDb deduplicates by ID.
            if (latestTimestamp != null) {
              query = query.gte('created_at', latestTimestamp);
            }

            final newMessages = await query
                .order('created_at', ascending: true)
                .order('id', ascending: true)
                .range(offset, offset + pageSize - 1);

            if (newMessages.isEmpty) break;
            final messagesToDeliver = await localDb.addMessages(
              matchId,
              newMessages.cast<Map<String, dynamic>>(),
              currentUserId: userId,
            );

            if (messagesToDeliver.isNotEmpty) {
              debugPrint(
                '🔄 GLOBAL_SYNC: Marking ${messagesToDeliver.length} messages as delivered for match $matchId',
              );
              unawaited(
                Future.wait(
                  messagesToDeliver.map(
                    (msgId) => supabase
                        .rpc(
                          'mark_message_delivered',
                          params: {'p_message_id': msgId},
                        )
                        .then((_) {
                          debugPrint(
                            '✅ GLOBAL_SYNC: Message $msgId marked as delivered',
                          );
                        })
                        .catchError((e) {
                          debugPrint(
                            '❌ GLOBAL_SYNC: Failed to mark $msgId as delivered: $e',
                          );
                        }),
                  ),
                  eagerError: false,
                ),
              );
            }

            if (newMessages.length < pageSize) break;
            offset += pageSize;
          }
        } catch (_) {
          // suppressed error logging per-match to avoid noisy logs
        }
      }).toList();

      // 7. Run all sync tasks in parallel
      await Future.wait(syncTasks);
    } catch (_) {
      // suppressed error logging
    }
  }

  // --- User events sync
  // ---
  Future<void> _syncUserEvents(String userId) async {
    try {
      final localDb = _ref.read(localDbProvider);

      // Query events the current user is attending
      final response = await supabase
          .from('event_attendees')
          .select('''
            notes,
            events!inner(
              id,
              event_name,
              event_venue,
              start_time,
              end_time,
              event_link
            )
          ''')
          .eq('user_id', userId)
          .order('events(start_time)', ascending: true);

      // Transform the response to include attendee count
      final List<Map<String, dynamic>> eventsData = [];

      for (final row in response as List) {
        final eventData = row['events'] as Map<String, dynamic>;

        // Get attendee count for this event
        final countResponse = await supabase.rpc(
          'count_event_attendees',
          params: {'event_id_param': eventData['id']},
        );

        final attendeeCount = countResponse is num
            ? countResponse.toInt()
            : int.tryParse('${countResponse ?? ''}');

        final fullEventData = {
          ...eventData,
          'notes': row['notes'],
          'attendee_count': attendeeCount,
        };

        eventsData.add(fullEventData);
      }

      // Cache the events data
      await localDb.saveUserEvents(userId, eventsData);
    } catch (_) {
      // Silently fail - events sync is not critical
    }
  }

  // --- End Core Sync Logic ---

  bool get isDisposed => _disposed;

  void restartSyncForUser(String userId) {
    // Stop current sync
    _stopPeriodicSync();
    _syncChatsDebounceTimer?.cancel();
    _syncChatsDebounceTimer = null;
    _syncChatsScheduled = false;

    // Reset disposed flag so sync operations can run again after a logout/login cycle
    _disposed = false;

    // Reset sync state to ensure new user's data is fetched immediately
    // Prevents stale _syncInProgress from blocking a fresh sync when user changes
    _syncInProgress = false;
    _lastSyncAttempt = null;

    // Clear cached fingerprints so the upcoming sync always writes to Hive.
    // Without this, a user re-logging (e.g. auto-switch back from another
    // account) would match the old fingerprint and skip saveChats, which
    // means no BoxEvent fires on the watchChats stream and the UI provider
    // never re-emits — leaving "No recent chats" even though data exists.
    _lastSyncFingerprints.remove(userId);

    // Reset the static chat-sync cooldown/debounce state left behind by the
    // previous user. These are process-lifetime statics on purpose (rapid
    // re-sync protection), but after a logout/login user switch a cooldown
    // set seconds ago by the previous account would silently DROP the new
    // user's very first syncChatsNow — leaving their chats missing from the
    // UI until the next periodic (60s) sync fires.
    _lastSyncChatsCall = null;
    _lastSyncChatsCompleted = null;
    _lastSyncChatsAttempt = null;

    // Start new sync for the new user
    _runFullSync(userId, checkConnectivity: false);

    // Restart periodic sync if online
    final isOnline = _ref.read(connectivityProvider).value ?? false;
    if (isOnline) {
      _startPeriodicSync();
    }
  }

  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    _syncTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _syncChatsDebounceTimer?.cancel();
    _syncChatsDebounceTimer = null;
    _lastSyncFingerprints.clear();
  }
}

// Provider to manage the lifecycle of the Global Sync Manager
final globalSyncManagerProvider = Provider<GlobalHomeSyncManager>((ref) {
  final manager = GlobalHomeSyncManager(ref);

  // Listen to auth state changes and handle sync lifecycle on login / logout / user change
  ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
    final currentUser = next.value?.session?.user;
    if (currentUser == null) {
      // User logged out, stop all sync activity
      manager.dispose();
    } else {
      final prevUser = previous?.value?.session?.user;
      if (prevUser?.id != currentUser.id || manager.isDisposed) {
        manager.restartSyncForUser(currentUser.id);
      }
    }
  });

  ref.onDispose(() => manager.dispose());
  return manager;
});
