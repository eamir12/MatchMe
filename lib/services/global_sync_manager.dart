// lib/services/global_sync_manager.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/auth_provider.dart';

final supabase = Supabase.instance.client;

/// This service manages periodic and real-time syncing of core Home/Match data.
class GlobalHomeSyncManager {
  final Ref _ref;
  Timer? _syncTimer;
  final Duration _syncInterval = const Duration(seconds: 60);

  // Heartbeat to keep user_activity fresh so online status reflects connectivity
  Timer? _heartbeatTimer;
  final Duration _heartbeatInterval = const Duration(seconds: 20);

  GlobalHomeSyncManager(this._ref) {
    // Perform immediate sync regardless of connectivity status
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      _runFullSync(userId, checkConnectivity: false);
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
    _runFullSync(userId, checkConnectivity: true);

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

      final List<Map<String, dynamic>> transformedMatches = uniqueMatches
          .map((match) {
        final eventDetails = match['events'] as Map<String, dynamic>?;
        return {
          'match_id': match['id'],
          'user1_id': match['user1_id'],
          'user2_id': match['user2_id'],
          'matched_intent': match['matched_intent'],
          'match_type': match['match_type'],
          'created_at': match['created_at'],
          'event_id': match['event_id'],
          'event_name': eventDetails?['event_name'],
          'event_link': eventDetails?['event_link'],
        };
      }).toList();

      final localDb = _ref.read(localDbProvider);
      await localDb.saveMatches(transformedMatches);
    } catch (_) {
      // suppressed error logging
    }
  }

  Future<void> syncChatsNow(String userId) async {
    try {
      final localDb = _ref.read(localDbProvider);

      // Use server-side function to get recent chats with unread counts
      try {
        final recent = await supabase.rpc('get_user_chats', params: {'p_user_id': userId, 'p_limit': 5});
        if (recent is List) {
          final List<Map<String, dynamic>> transformed = [];

          // Collect match IDs to enrich with match/event info in a single pass
          final Set<String> matchIds = {};
          for (final row in recent) {
            final mid = row['match_id']?.toString();
            if (mid != null && mid.isNotEmpty) matchIds.add(mid);
          }

          final Map<String, Map<String, dynamic>> matchById = {};
          if (matchIds.isNotEmpty) {
            try {
              final orClause = matchIds.map((m) => 'id.eq.$m').join(',');
              final matchesResponse = await supabase
                  .from('matches')
                  .select('id, created_at, event_id, events:event_id (event_name, event_link)')
                  .or(orClause);

              for (final m in matchesResponse) {
                // Normalize to Map<String, dynamic> to satisfy typing and avoid unnecessary casts
                final mm = Map<String, dynamic>.from(m as Map);
                matchById[mm['id'] as String] = mm;
              }
            } catch (_) {
              // Non-fatal: we'll proceed without match enrichment
            }
          }

          for (final row in recent) {
            try {
              final matchId = row['match_id']?.toString() ?? '';
              final lastMessageId = row['last_message_id']?.toString() ?? '';

              final matchData = matchById[matchId];

              transformed.add({
                'match_id': matchId,
                'other_user_id': row['other_user_id'],
                // Server side masks full names; fall back to any legacy field if present
                'other_user_name': row['other_name'] ?? row['other_user_name'] ?? 'Unknown User',
                // Keep legacy keys the UI expects
                'last_message_content': row['last_message_preview'] ?? '',
                'last_message_translated': row['last_message_translated'],
                'last_message_id': lastMessageId,
                'last_message_at': row['last_message_at'],
                'unread_count': row['unread_count'] ?? 0,
                'match_created_at': matchData != null ? matchData['created_at'] : null,
                'event_id': matchData != null ? matchData['event_id'] : null,
                'event_name': matchData != null && matchData['events'] != null ? (matchData['events'] as Map<String, dynamic>)['event_name'] : null,
                'event_link': matchData != null && matchData['events'] != null ? (matchData['events'] as Map<String, dynamic>)['event_link'] : null,
                'translation_enabled': row['translation_enabled'] ?? false,
                'translation_language': row['translation_language'],
              });

              // Ensure latest message exists in local cache for translation and UI lookups
              if (lastMessageId.isNotEmpty) {
                try {
                  final messagesResponse = await supabase
                      .from('chat_messages')
                      .select('id, content_original, content_translated, created_at, sender_id')
                      .eq('id', lastMessageId)
                      .limit(1);
                  if (messagesResponse.isNotEmpty) {
                    await localDb.addMessages(matchId, [Map<String, dynamic>.from(messagesResponse.first as Map)]);
                  }
                } catch (_) {
                  // ignore per-message fetch errors
                }
              }
            } catch (_) {
              // ignore malformed row
            }
          }

          await localDb.saveChats(userId, transformed);
        }
      } catch (e) {
        debugPrint('syncChatsNow: get_user_chats RPC failed: $e');
        // Fall back to previous behavior: attempt a best-effort lightweight sync
        // (keep previous logic simplified)
        final matchesResponse = await supabase
            .from('matches')
            .select('id, user1_id, user2_id, matched_intent, created_at, event_id, events:event_id (event_name, event_link)')
            .or('user1_id.eq.$userId,user2_id.eq.$userId');

        final List<Map<String, dynamic>> chats = [];

        for (final match in matchesResponse) {
          final matchId = match['id'] as String;
          final messagesResponse = await supabase
              .from('chat_messages')
              .select('id, content_original, content_translated, created_at, sender_id')
              .eq('match_id', matchId)
              .order('created_at', ascending: false)
              .limit(1);

          if (messagesResponse.isNotEmpty) {
            final latestMessage = messagesResponse.first;

            final userAId = match['user2_id'] as String;
            final userBId = match['user1_id'] as String;
            final otherUserId = (userAId == userId) ? userBId : userAId;
            final eventData = match['events'] as Map<String, dynamic>?;

            final String? contentTranslated = latestMessage['content_translated'] as String?;
            final lastMessageContent = latestMessage['content_original'] ?? '';

            chats.add({
              'match_id': matchId,
              'other_user_id': otherUserId,
              'other_user_name': 'Unknown User',
              'last_message_content': lastMessageContent,
              'last_message_translated': contentTranslated,
              'last_message_id': latestMessage['id'],
              'last_message_at': latestMessage['created_at'],
              'unread_count': 0,
              'match_created_at': match['created_at'],
              'event_id': match['event_id'],
              'event_name': eventData?['event_name'],
              'event_link': eventData?['event_link'],
            });

            try {
              await localDb.addMessages(matchId, [Map<String, dynamic>.from(latestMessage as Map)]);
            } catch (e) {
              // Ignore local DB save errors here
            }
          }
        }

        await localDb.saveChats(userId, chats);
      }
    } catch (e) {
      // suppressed error logging
    }
  }

  Future<void> syncMatchesNow(String userId) async {
    await _syncMatches(userId);
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
          var query = supabase.from('chat_messages').select().eq('match_id', matchId);

          // 5. If we have a timestamp, only ask for messages *after* it
          if (latestTimestamp != null) {
            query = query.gt('created_at', latestTimestamp);
          }

          final newMessages = await query;

          // 6. Add the new messages to the local cache
          if (newMessages.isNotEmpty) {
            await localDb.addMessages(matchId, newMessages.cast<Map<String, dynamic>>());
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