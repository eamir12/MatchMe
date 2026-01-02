// lib/providers/home_providers.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/chat_provider.dart'; // to read translationNotifierProvider
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:matchme/utils/resume_diagnostics.dart';

final supabase = Supabase.instance.client;

// --- recentMatchesProvider (Reads Local DB Only) ---
final recentMatchesProvider = StreamProvider.autoDispose.family<
  List<MatchModel>,
  String
>((ref, userId) {
  if (userId.isEmpty) return Stream.value([]);

  // Diagnostics: log provider lifecycle
  try {
    ResumeDiagnostics.log('recentMatchesProvider created for user=$userId');
    ref.onDispose(() {
      ResumeDiagnostics.log('recentMatchesProvider disposed for user=$userId');
    });
  } catch (_) {}

  final localDb = ref.watch(localDbProvider);

  // Ensure sync manager is initialized to trigger initial data sync
  ref.watch(globalSyncManagerProvider);

  final localStream = localDb.watchMatches();

  return localStream.map((list) {
    return list
        .map((json) {
          // --- THIS IS THE FIX ---
          // We must validate the raw data that MatchModel.fromJsonRpc uses
          // to determine the 'other' user.

          final String? userAId = json['user1_id']?.toString();
          final String? userBId = json['user2_id']?.toString();

          // 1. Check if match_id is present and not empty
          final String? matchId = json['match_id']?.toString();
          if (matchId == null || matchId.isEmpty) {
            return null; // Mark as null to be filtered out
          }

          // 2. Check if both user IDs are present and not empty
          if (userAId == null ||
              userAId.isEmpty ||
              userBId == null ||
              userBId.isEmpty) {
            return null; // Mark as null to be filtered out
          }

          // 2. Check that ONE of them is the current user (and not both).
          //    This prevents a match with oneself or a match where the user isn't involved.
          final bool isUserA = (userAId == userId);
          final bool isUserB = (userBId == userId);

          if (isUserA == isUserB) {
            // If both are false (user not in match) OR both are true (self-match)
            return null; // Mark as null
          }

          // If all checks pass, it's safe to create the model.
          return MatchModel.fromJsonRpc(json, userId);
          // --- END FIX ---
        })
        .whereType<MatchModel>() // This filters out all the nulls
        .toList();
  });
});

// --- END UPDATE ---

// --- recentChatsProvider (Reads Local DB Only) ---
final recentChatsProvider = StreamProvider.family<
  List<ChatModel>,
  String
>((ref, userId) {
  if (userId.isEmpty) {
    return Stream.value([]);
  }

  final localDb = ref.watch(localDbProvider);

  final localStream = localDb.watchChats(userId);

  // Use the correct provider name here
  final syncService = ref.read(globalSyncManagerProvider);

  final chatUpdateChannel = supabase
      .channel('public:chat_messages:for_user_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_messages',
        callback: (payload) async {
            // Immediately sync chats when messages change to ensure Recent Chats updates promptly
            await syncService.syncChatsNow(userId);
          },
      )
      .subscribe((status, err) {
        if (status == RealtimeSubscribeStatus.subscribed) {
        }
      });

  ref.onDispose(() {
    supabase.removeChannel(chatUpdateChannel);
  });

  // Watch translationProvider so we refresh recent chats when the translation target changes (e.g., user changed UI language)
  final translationStatesSnapshot = ref.watch(translationProvider);

  // Watch translationVersionProvider so we refresh when translations complete in background
  ref.watch(translationVersionProvider);

  // We need asyncMap because we'll optionally await the local DB to fetch the last-message's cached translation.
  return localStream.asyncMap((list) async {
    // Build initial ChatModel list and keep track of raw JSON for cached translation access
    final chatData = list.map((json) {
      return {
        'model': ChatModel.fromJsonRpc(json),
        'rawJson': json,
      };
    }).toList();

    // Filter out chats where the other user is the same as the current user
    final filteredChatData = chatData.where((data) => (data['model'] as ChatModel).otherUserId != userId).toList();



    // For each chat, if translation is turned on for that match, try to substitute the cached translated text.
    // NOTE: Only substitute the lastMessage when the last message was received (i.e., sender != current user)
    final List<ChatModel> processed = [];

    for (final data in filteredChatData) {
      final ChatModel chat = data['model'] as ChatModel;
      final Map<String, dynamic> rawJson = data['rawJson'] as Map<String, dynamic>;

      final targetLanguage = translationStatesSnapshot[chat.matchId];
      if (targetLanguage == null || chat.lastMessageId.isEmpty) {
        processed.add(chat);
        continue;
      }

      // First, check if we have a cached translated last message in the chat record itself
      final cachedChatTranslation = rawJson['last_message_translated'] as String?;
      if (cachedChatTranslation != null && cachedChatTranslation.isNotEmpty) {
        processed.add(chat.copyWith(lastMessage: cachedChatTranslation));
        continue;
      }

      // Fallback: do the expensive lookup if we don't have the cached translation
      try {
        // Get only the specific last message instead of all messages
        final message = await localDb.getMessageById(chat.matchId, chat.lastMessageId);

        // If we couldn't find the last message in the cache, skip translation substitution.
        if (message == null || message.isEmpty) {
          processed.add(chat);
          continue;
        }

        // Ensure we only show a translated last message when the last message was RECEIVED,
        // i.e., the message's sender_id is NOT the current user.
        final String senderId = message['sender_id']?.toString() ?? '';
        if (senderId == userId) {
          // Last message was sent by the current user — do not show the translated text in
          // Recent Chats / Home; keep the original lastMessage.
          processed.add(chat);
          continue;
        }

        final cachedTranslation = message['translated_text'] as String?;
        final cachedLang = message['translated_lang'] as String?;

        if (cachedTranslation != null &&
            cachedTranslation.isNotEmpty &&
            cachedLang == targetLanguage) {
          // Replace lastMessage with the cached translation
          processed.add(chat.copyWith(lastMessage: cachedTranslation));
        } else {
          // No cached translation available, trigger translation in background
          final translationParams = jsonEncode({
            'text': message['content_original'],
            'matchId': chat.matchId,
            'messageId': chat.lastMessageId,
            'otherUserId': senderId,
          });
          // Trigger translation asynchronously - don't await to avoid blocking UI
          ref.read(translationFamilyProvider(translationParams));
          processed.add(chat);
        }
      } catch (e) {
        processed.add(chat);
      }
    }


    return processed;
  });
});

// Dashboard stats provider - real-time updates for online and nearby counts
final dashboardStatsProvider = StreamProvider<Map<String, int>>((ref) {
  final userId = supabase.auth.currentUser?.id;
  debugPrint('Dashboard stats provider initialized for user: $userId');

  if (userId == null) {
    debugPrint('Dashboard stats provider: No user ID, returning empty stream');
    return Stream.value({'nearby': 0, 'online': 0});
  }

  final controller = StreamController<Map<String, int>>();

  // Function to fetch current stats
  Future<Map<String, int>> fetchStats() async {
    try {
      // Call the database functions to get real counts
      final onlineResponse = await supabase.rpc('get_online_users_count', params: {'p_user_id': userId});
      final nearbyResponse = await supabase.rpc('get_nearby_users_count', params: {'p_user_id': userId, 'p_radius_km': 50});

      final onlineCount = (onlineResponse as int?) ?? 0;
      final nearbyCount = (nearbyResponse as int?) ?? 0;

      debugPrint('Dashboard stats fetched: online=$onlineCount, nearby=$nearbyCount');
      return {'nearby': nearbyCount, 'online': onlineCount};
    } catch (e) {
      debugPrint('Error fetching dashboard stats: $e');
      // Fallback to zeros if functions don't exist or fail
      return {'nearby': 0, 'online': 0};
    }
  }

  // Emit initial stats
  fetchStats().then(controller.add);

  // Set up real-time subscriptions
  final activityChannel = supabase
      .channel('dashboard_stats_activity_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_activity',
        callback: (payload) {
          debugPrint('Activity change detected: $payload');
          // When user_activity table changes, refetch and emit new stats
          fetchStats().then(controller.add);
        },
      )
      .subscribe((status, err) {
        debugPrint('Activity channel status for $userId: $status, error: $err');
      });

  // Presence channel: subscribe to global presence events so we get immediate
  // notifications when other clients connect/disconnect (fast online/offline updates)
  final presenceChannel = supabase.channel('presence:online');

  try {
    presenceChannel.onPresenceSync((_) {
      debugPrint('Presence sync detected for dashboard stats');
      // Presence changes are an immediate signal that someone connected/disconnected - emit a quick online count
      try {
        final dynamic raw = presenceChannel.presenceState();
        int presenceCount = 0;
        if (raw is Map) {
          presenceCount = raw.keys.length;
        } else if (raw is List) {
          presenceCount = raw.length;
        }
        // Use presence-derived count for immediate UI reaction, but also refresh full stats in background
        fetchStats().then((stats) {
          controller.add({'nearby': stats['nearby'] ?? 0, 'online': presenceCount});
        });
      } catch (e) {
        // If presence parsing fails, fallback to full fetch
        fetchStats().then(controller.add);
      }
    });
  } catch (e) {
    // Some SDK versions may not support onPresenceSync - fall back to periodic polling
  }

  presenceChannel.subscribe((status, [err]) {
    debugPrint('Presence channel status for $userId: $status, error: $err');
    if (status == RealtimeSubscribeStatus.subscribed) {
      // Track a simple presence meta for this user so other clients see us as connected
      try {
        final meta = {
          'online': true,
          'ts': DateTime.now().toUtc().toIso8601String(),
          'user_id': userId,
        };
        presenceChannel.track(meta);
      } catch (e) {
        // ignore track errors
      }
    }
  });

  final visibilityChannel = supabase
      .channel('dashboard_stats_visibility_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        callback: (payload) {
          debugPrint('Visibility change detected: $payload');
          // Check if this is another user's visibility change
          final newRecord = payload.newRecord as Map<String, dynamic>?;
          final oldRecord = payload.oldRecord as Map<String, dynamic>?;
          final changedUserId = newRecord?['id'] as String?;

          if (changedUserId != null && changedUserId != userId && newRecord != null && oldRecord != null) {
            final newVisible = newRecord['user_visibility_setting'] as bool?;
            final oldVisible = oldRecord['user_visibility_setting'] as bool?;

            if (newVisible != oldVisible) {
              debugPrint('Another user visibility setting changed: $changedUserId, setting: $newVisible');
              // Another user's visibility setting changed, refetch and emit new stats
              fetchStats().then(controller.add);
            }
          }
        },
      )
      .subscribe((status, err) {
        debugPrint('Visibility channel status for $userId: $status, error: $err');
      });

  ref.onDispose(() {
    supabase.removeChannel(activityChannel);
    supabase.removeChannel(visibilityChannel);
    supabase.removeChannel(presenceChannel);
    controller.close();
  });

  return controller.stream;
});

// Total unread chat count provider
final totalUnreadChatCountProvider = Provider<int>((ref) {
  final chatsAsync = ref.watch(recentChatsProvider(supabase.auth.currentUser?.id ?? ''));
  final chats = chatsAsync.asData?.value ?? [];
  return chats.fold<int>(0, (sum, chat) => sum + chat.unreadCount);
});

// Navigation index notifier
class NavigationIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) {
    state = index;
  }
}

// Navigation index provider
final navigationIndexProvider = NotifierProvider<NavigationIndexNotifier, int>(() {
  return NavigationIndexNotifier();
});

// Activity update provider - updates user activity when accessed
final activityUpdateProvider = Provider.autoDispose<void>((ref) {
  final user = supabase.auth.currentUser;
  if (user != null) {
    // Update activity asynchronously but don't wait for it
    supabase.rpc('update_user_activity', params: {'p_user_id': user.id}).catchError((e) {
      debugPrint('Error updating user activity: $e');
      return null;
    });
  }
});

// Potential matches provider - fetches users that could be matches
final potentialMatchesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final user = supabase.auth.currentUser;
  if (user == null) return [];

  try {
    // Get current user's location and settings
    final userResponse = await supabase
        .from('users')
        .select('match_radius_default')
        .eq('id', user.id)
        .single();

    final matchRadius = userResponse['match_radius_default'] as int? ?? 50; // default 50km

    // Get current user's location
    final locationResponse = await supabase
        .from('user_locations')
        .select('latitude, longitude')
        .eq('user_id', user.id)
        .order('updated_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (locationResponse == null) return [];

    final userLat = locationResponse['latitude'] as double;
    final userLng = locationResponse['longitude'] as double;

    // Get existing matches to exclude
    final existingMatches = await supabase
        .from('matches')
        .select('user1_id, user2_id')
        .or('user1_id.eq.${user.id},user2_id.eq.${user.id}');

    final matchedUserIds = <String>{};
    for (final match in existingMatches) {
      if (match['user1_id'] != user.id) matchedUserIds.add(match['user1_id']);
      if (match['user2_id'] != user.id) matchedUserIds.add(match['user2_id']);
    }

    // Query potential matches
    final potentialUsers = await supabase
        .from('users')
        .select('''
          id,
          display_name,
          profile_data,
          user_locations!inner(latitude, longitude)
        ''')
        .eq('user_visibility_setting', true)
        .neq('id', user.id)
        .not('id', 'in', '(${matchedUserIds.join(',')})')
        .filter('user_locations.latitude', 'not.is', null)
        .filter('user_locations.longitude', 'not.is', null);

    // Filter by distance
    final potentialMatches = <Map<String, dynamic>>[];
    for (final userData in potentialUsers) {
      final locations = userData['user_locations'] as List<dynamic>;
      if (locations.isNotEmpty) {
        final location = locations.first;
        final lat = location['latitude'] as double?;
        final lng = location['longitude'] as double?;
        if (lat != null && lng != null) {
          final distance = _calculateDistance(userLat, userLng, lat, lng);
          if (distance <= matchRadius) {
            potentialMatches.add({
              ...userData,
              'distance': distance,
              'location': location,
            });
          }
        }
      }
    }

    // Sort by distance
    potentialMatches.sort((a, b) => (a['distance'] as double).compareTo(b['distance'] as double));

    return potentialMatches;
  } catch (e) {
    debugPrint('Error fetching potential matches: $e');
    return [];
  }
});

// Helper function to calculate distance between two points
double _calculateDistance(double lat1, double lng1, double lat2, double lng2) {
  const double earthRadius = 6371; // km
  final double dLat = _degreesToRadians(lat2 - lat1);
  final double dLng = _degreesToRadians(lng2 - lng1);
  final double a = sin(dLat / 2) * sin(dLat / 2) +
      cos(_degreesToRadians(lat1)) * cos(_degreesToRadians(lat2)) * sin(dLng / 2) * sin(dLng / 2);
  final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return earthRadius * c;
}

double _degreesToRadians(double degrees) => degrees * (3.141592653589793 / 180);
