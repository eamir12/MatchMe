// lib/services/global_sync_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/auth_provider.dart';

final supabase = Supabase.instance.client;

/// This service manages periodic and real-time syncing of core Home/Match data.
class GlobalHomeSyncManager {
  final Ref _ref;
  Timer? _syncTimer;
  Duration _syncInterval = const Duration(seconds: 60);

  // Heartbeat to keep user_activity fresh so online status reflects connectivity
  Timer? _heartbeatTimer;
  Duration _heartbeatInterval = const Duration(seconds: 5);

  GlobalHomeSyncManager(this._ref) {
    // Load config values asynchronously
    Future.microtask(() async {
      _syncInterval = await appConfigService.getDuration(
        'sync.global_interval_seconds',
        defaultValue: const Duration(seconds: 60)
      );
       _heartbeatInterval = await appConfigService.getDuration(
         'sync.heartbeat_interval_seconds',
         defaultValue: const Duration(seconds: 5)
       );
    });

    // Perform immediate sync regardless of connectivity status
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      Future.microtask(() => _runFullSync(userId, checkConnectivity: false));
    }

    _ref.listen<AsyncValue<bool>>(connectivityProvider, (previous, next) {
      if (next.value == true) {
        _startPeriodicSync(); // Start sync when online
        _startHeartbeat(); // Start periodic activity updates when online
      } else {
        _stopPeriodicSync(); // Stop sync when offline
        _stopHeartbeat(); // Stop heartbeats when offline
      }
    }, fireImmediately: true);

    // Clean up timers if this provider is disposed
    _ref.onDispose(() {
      _stopPeriodicSync();
      _stopHeartbeat();
    });
  }

  void _startHeartbeat() {
    if (_heartbeatTimer != null && _heartbeatTimer!.isActive) return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Immediate update
    supabase.rpc('update_user_activity', params: {'p_user_id': userId}).catchError((e) {
      // Ignore heartbeat errors
    });

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final isOnline = _ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) return;
      supabase.rpc('update_user_activity', params: {'p_user_id': userId}).catchError((e) {});
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startPeriodicSync() {
    if (_syncTimer != null && _syncTimer!.isActive) {
      return;
    }

    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Run the first sync immediately
    Future.microtask(() => _runFullSync(userId, checkConnectivity: true));

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

  Future<void> _runFullSync(String userId, {bool checkConnectivity = true}) async {
    if (checkConnectivity) {
      final isOnline = _ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
    }

    // Core sync tasks
    final syncTasks = <Future>[
      _syncMatches(userId),
      syncChatsNow(userId),
      _syncAllChatHistories(userId),
      _syncEventMatches(),
      _syncUserEvents(userId),
    ];

    await Future.wait(syncTasks);
  }

  // --- Core Sync Logic ---

  Future<void> _syncMatches(String userId) async {
    try {
      final localDb = _ref.read(localDbProvider);
      final defaultWindowSeconds = await appConfigService.getInt(
        'matches.chat_start_window_seconds',
        defaultValue: const Duration(hours: 24).inSeconds,
      );

      final existing = await localDb.watchMatches().first;
      final existingByMatchId = <String, Map<String, dynamic>>{
        for (final m in existing)
          (m['match_id'] ?? m['id'])?.toString() ?? '': m,
      };

      // Fetch matches with event details for event matches
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

      final List<Map<String, dynamic>> matchesData = response.cast<Map<String, dynamic>>();

      // Remove duplicates by ensuring each match pair appears only once
      final seenPairs = <String>{};
      final uniqueMatches = <Map<String, dynamic>>[];

      for (final match in matchesData) {
        if (match['id'] == null || (match['id'] as String).isEmpty) continue;

        final user1Id = match['user1_id'] as String;
        final user2Id = match['user2_id'] as String;

        // Create a consistent key for the pair (always smaller ID first)
        final pairKey = user1Id.compareTo(user2Id) < 0 ? '$user1Id-$user2Id' : '$user2Id-$user1Id';

        if (!seenPairs.contains(pairKey)) {
          seenPairs.add(pairKey);
          uniqueMatches.add(match);
        }
      }

      final List<Map<String, dynamic>> transformedMatches = uniqueMatches.map((match) {
        final eventDetails = match['events'] as Map<String, dynamic>?;
        final matchId = (match['id'] ?? match['match_id'])?.toString() ?? '';
        final existingRow = existingByMatchId[matchId];
        final dynamic existingWindowRaw = existingRow?['chat_start_window_seconds'];
        final int? existingWindowSeconds = existingWindowRaw is int
            ? existingWindowRaw
            : int.tryParse(existingWindowRaw?.toString() ?? '');
        final dynamic incomingWindowRaw = match['chat_start_window_seconds'];
        final int? incomingWindowSeconds = incomingWindowRaw is int
            ? incomingWindowRaw
            : int.tryParse(incomingWindowRaw?.toString() ?? '');
        final resolvedWindowSeconds = incomingWindowSeconds ?? existingWindowSeconds ?? defaultWindowSeconds;
        return {
          'match_id': matchId,
          'user1_id': match['user1_id'],
          'user2_id': match['user2_id'],
          'matched_intent': match['matched_intent'],
          'match_type': match['match_type'],
          'chat_start_window_seconds': resolvedWindowSeconds,
          'created_at': match['created_at'],
          'event_id': match['event_id'],
          'event_name': eventDetails?['event_name'],
          'event_link': eventDetails?['event_link'],
        };
      }).toList();

      await localDb.saveMatches(transformedMatches);
    } catch (_) {
      // suppressed error logging
    }
  }

  Future<void> syncChatsNow(String userId) async {
    if (kIsWeb) {
      debugPrint('🔍 [WEB] syncChatsNow: Starting sync for user: \$userId');
    }
    try {
      final localDb = _ref.read(localDbProvider);

      // Use simplified RPC function for better performance
      try {
        final recent = await supabase.rpc('get_user_recent_chats', params: {'p_user_id': userId, 'p_limit': 5});

        if (kIsWeb) {
          debugPrint('🔍 [WEB] syncChatsNow: Server returned \${recent.length} chats');
          for (final row in recent) {
            if (row is Map<String, dynamic>) {
              debugPrint('🔍 [WEB] syncChatsNow: Server chat ${row['match_id']}: unread_count=${row['unread_count']}');
            }
          }
        }

        if (recent is List) {
          final List<Map<String, dynamic>> transformed = [];

          for (final row in recent) {
            if (row is Map<String, dynamic>) {

              // Simple transformation - data comes pre-enriched from RPC
              transformed.add({
                'match_id': row['match_id'],
                'other_user_id': row['other_user_id'],
                'other_user_name': row['other_name'] ?? 'Unknown User',
                'other_user_photos': row['other_photos'] ?? [],
                'last_message': row['last_message_preview'] ?? '',
                'last_message_at': row['last_message_at'],
                'unread_count': row['unread_count'] ?? 0,
                'updated_at': row['updated_at'],
                'translation_enabled': row['translation_enabled'] ?? false,
                'translation_language': row['translation_language'],
                'last_message_id': row['last_message_id'],
                'last_message_sender_id': row['last_message_sender_id'],
                'last_message_translated': row['last_message_translated'],
              });
            }
          }

          if (kIsWeb) {
            debugPrint('🔍 [WEB] syncChatsNow: About to save \${transformed.length} chats to local DB');
            for (final chat in transformed) {
              debugPrint('🔍 [WEB] syncChatsNow: Saving chat ${chat['match_id']}: unread_count=${chat['unread_count']}');
            }
          }
          await localDb.saveChats(userId, transformed);
          if (kIsWeb) {
            debugPrint('🔍 [WEB] syncChatsNow: Completed saving chats to local DB');
          }
          
          // Sync translation settings from server for each chat to ensure they match database state
          for (final row in recent) {
            if (row is Map<String, dynamic>) {
              final matchId = row['match_id'];
              final translationEnabled = row['translation_enabled'] ?? false;
              final translationLanguage = row['translation_language'];
              
              if (matchId != null) {
                await localDb.syncChatTranslationSettings(userId, matchId, translationEnabled, translationLanguage);
              }
            }
          }

          // Update translation provider state to match server - ensures UI reflects actual server state
          try {
            final translationNotifier = _ref.read(translationProvider.notifier);
            for (final row in recent) {
              if (row is Map<String, dynamic>) {
                final matchId = row['match_id'] as String?;
                final translationEnabled = row['translation_enabled'] == true;
                final translationLanguage = row['translation_language'] as String?;
                
                if (matchId != null) {
                  // Update provider state: if translation enabled, set language; otherwise remove
                  if (translationEnabled && translationLanguage != null) {
                    final currentState = _ref.read(translationProvider);
                    if (currentState[matchId] != translationLanguage) {
                      translationNotifier.setTranslationSilent(matchId, translationLanguage);
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
      } catch (e) {
        debugPrint('❌ syncChatsNow failed: $e');
        // No complex fallback - keep it simple
      }
    } catch (e) {
      debugPrint('❌ syncChatsNow error: $e');
    }
  }

  Future<void> syncMatchesNow(String userId) async {
    try {
      final localDb = _ref.read(localDbProvider);
      final defaultWindowSeconds = await appConfigService.getInt(
        'matches.chat_start_window_seconds',
        defaultValue: const Duration(hours: 24).inSeconds,
      );
      final existing = await localDb.watchMatches().first;
      final existingByMatchId = <String, Map<String, dynamic>>{
        for (final m in existing)
          (m['match_id'] ?? m['id'])?.toString() ?? '': m,
      };

      // Use simplified RPC function for better performance
      try {
        final recent = await supabase.rpc('get_user_recent_matches', params: {'p_user_id': userId, 'p_limit': 5});

        if (recent is List) {
          final rows = recent.whereType<Map<String, dynamic>>().toList();

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
              final matchId = (copy['match_id'] ?? copy['id'])?.toString() ?? '';
              final dynamic incomingWindowRaw = copy['chat_start_window_seconds'];
              final int? incomingWindowSeconds = incomingWindowRaw is int
                  ? incomingWindowRaw
                  : int.tryParse(incomingWindowRaw?.toString() ?? '');
              final dynamic existingWindowRaw =
                  existingByMatchId[matchId]?['chat_start_window_seconds'];
              final int? existingWindowSeconds = existingWindowRaw is int
                  ? existingWindowRaw
                  : int.tryParse(existingWindowRaw?.toString() ?? '');
              final resolvedWindowSeconds =
                  incomingWindowSeconds ?? existingWindowSeconds ?? defaultWindowSeconds;
              copy['chat_start_window_seconds'] = resolvedWindowSeconds;
              return copy;
            }).toList();
            await localDb.saveMatches(normalized);
            return;
          }

          final matchIds =
              rows
                  .map((r) => (r['match_id'] ?? r['id'])?.toString() ?? '')
                  .where((id) => id.isNotEmpty)
                  .toList();

          if (matchIds.isEmpty) {
            await _syncMatches(userId);
            return;
          }

          final matchesResponse = await supabase
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

          final fetched = matchesResponse.cast<Map<String, dynamic>>();
          final byId = <String, Map<String, dynamic>>{
            for (final m in fetched) (m['id']?.toString() ?? ''): m,
          };

          final transformedMatches = <Map<String, dynamic>>[];
          for (final id in matchIds) {
            final m = byId[id];
            if (m == null) continue;
            final eventDetails = m['events'] as Map<String, dynamic>?;
            final dynamic existingWindowRaw = existingByMatchId[id]?['chat_start_window_seconds'];
            final int? existingWindowSeconds = existingWindowRaw is int
                ? existingWindowRaw
                : int.tryParse(existingWindowRaw?.toString() ?? '');
            final resolvedWindowSeconds = existingWindowSeconds ?? defaultWindowSeconds;

            transformedMatches.add({
              'match_id': m['id'],
              'user1_id': m['user1_id'],
              'user2_id': m['user2_id'],
              'matched_intent': m['matched_intent'],
              'match_type': m['match_type'],
              'chat_start_window_seconds': resolvedWindowSeconds,
              'created_at': m['created_at'],
              'event_id': m['event_id'],
              'event_name': eventDetails?['event_name'],
              'event_link': eventDetails?['event_link'],
            });
          }

          if (transformedMatches.isNotEmpty) {
            await localDb.saveMatches(transformedMatches);
            return;
          }

          await _syncMatches(userId);
        }
      } catch (e) {
        debugPrint('syncMatchesNow: get_user_recent_matches RPC failed: $e');
        // Fallback to original method
        await _syncMatches(userId);
      }
    } catch (e) {
      debugPrint('syncMatchesNow error: $e');
    }
  }

  // ---
  // --- UPDATED: This function now performs an incremental sync for messages
  // ---
  Future<void> _syncAllChatHistories(String userId) async {
    try {
      final localDb = _ref.read(localDbProvider);

      // 1. Get all match IDs the user is currently in
      final matchesResponse = await supabase
          .from('matches')
          .select('id')
          .or('user1_id.eq.$userId,user2_id.eq.$userId');

      final allMatchIds = (matchesResponse as List)
          .map((e) => e['id'] as String)
          .where((id) => id.isNotEmpty)
          .toList();

      if (allMatchIds.isEmpty) return;

      // 2. Create a separate sync task for each match
      final syncTasks = allMatchIds.map((matchId) async {
        try {
          // 3. Get the timestamp of the last message we have
          final latestTimestamp = await localDb.getLatestMessageTimestamp(matchId);

          // 4. Build the query
          var query = supabase.from('chat_messages').select('id, match_id, sender_id, content_original, content_translated, created_at, edited_at, delivered_at, read_at, reply_to_message_id').eq('match_id', matchId);

          // 5. If we have a timestamp, only ask for messages *after* it
          if (latestTimestamp != null) {
            query = query.gt('created_at', latestTimestamp);
          }

          final newMessages = await query;

          // 6. Add the new messages to the local cache and get messages to deliver
          if (newMessages.isNotEmpty) {
            final messagesToDeliver = await localDb.addMessages(
              matchId,
              newMessages.cast<Map<String, dynamic>>(),
              currentUserId: userId,
            );
            
            // 7. Mark messages as delivered to server (non-blocking, batch RPC calls)
            if (messagesToDeliver.isNotEmpty) {
              debugPrint('🔄 GLOBAL_SYNC: Marking ${messagesToDeliver.length} messages as delivered for match $matchId');
              unawaited(
                Future.wait(
                  messagesToDeliver.map((msgId) =>
                    supabase.rpc('mark_message_delivered', params: {'p_message_id': msgId})
                      .then((_) {
                        debugPrint('✅ GLOBAL_SYNC: Message $msgId marked as delivered');
                      })
                      .catchError((e) {
                        debugPrint('❌ GLOBAL_SYNC: Failed to mark $msgId as delivered: $e');
                      })
                  ),
                  eagerError: false,
                )
              );
            }
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
          params: {'event_id_param': eventData['id']}
        );

        final attendeeCount = (countResponse as int?) ?? 1;

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

  // --- Periodic event matching sync
  // ---
  Future<void> _syncEventMatches() async {
    try {
      // Get all current events
      final eventsResponse = await supabase
          .from('events')
          .select('id')
          .gte('start_time', DateTime.now().toIso8601String()); // Only future/current events

      final events = eventsResponse as List<dynamic>;

      for (final event in events) {
        final eventId = event['id'] as String;

        // Call backend RPC to perform matching for this event
        await supabase.rpc('perform_event_matching', params: {'p_event_id': eventId});
      }
    } catch (e) {
      // suppressed error logging
    }
  }
  // --- End Core Sync Logic ---

  void restartSyncForUser(String userId) {
    // Stop current sync
    _stopPeriodicSync();
    
    // Start new sync for the new user
    _runFullSync(userId, checkConnectivity: false);
    
    // Restart periodic sync if online
    final isOnline = _ref.read(connectivityProvider).value ?? false;
    if (isOnline) {
      _startPeriodicSync();
    }
  }

  void dispose() {
    _syncTimer?.cancel();
    _syncTimer = null;
    // disposed (logging removed)
  }
}

// Provider to manage the lifecycle of the Global Sync Manager
final globalSyncManagerProvider = Provider<GlobalHomeSyncManager>((ref) {
  final manager = GlobalHomeSyncManager(ref);
  
  // Listen to auth state changes and restart sync when user changes
  ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
    final currentUser = next.value?.session?.user;
    if (currentUser != null) {
      // User logged in or changed, restart sync
      manager.restartSyncForUser(currentUser.id);
    }
  });
  
  ref.onDispose(() => manager.dispose());
  return manager;
});
