// lib/providers/match_notification_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/services/local_db_service.dart';

final supabase = Supabase.instance.client;

/// Represents a new match notification
class MatchNotification {
  final MatchModel match;
  final DateTime timestamp;
  final bool viewed;

  MatchNotification({
    required this.match,
    required this.timestamp,
    this.viewed = false,
  });

  MatchNotification copyWith({bool? viewed}) {
    return MatchNotification(
      match: match,
      timestamp: timestamp,
      viewed: viewed ?? this.viewed,
    );
  }
}

/// State for managing match notifications
class MatchNotificationState {
  final List<MatchNotification> notifications;
  final int unreadCount;

  MatchNotificationState({
    this.notifications = const [],
    this.unreadCount = 0,
  });

  MatchNotificationState copyWith({
    List<MatchNotification>? notifications,
    int? unreadCount,
  }) {
    return MatchNotificationState(
      notifications: notifications ?? this.notifications,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

/// Notifier that manages match notifications in real-time
class MatchNotificationNotifier extends Notifier<MatchNotificationState> {
  RealtimeChannel? _matchChannel;
  StreamSubscription? _channelSubscription;

  @override
  MatchNotificationState build() {
    _setupRealtimeSubscription();
    return MatchNotificationState();
  }

  void _setupRealtimeSubscription() {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      debugPrint('⚠️ Cannot setup match notifications: No user ID');
      return;
    }

    // Remove existing subscription if any
    if (_matchChannel != null) {
      debugPrint('🔄 Removing existing match notification channel');
      supabase.removeChannel(_matchChannel!);
      _matchChannel = null;
    }

    try {
      debugPrint('📡 Setting up match notification subscription for user: $userId');
      
      // Create a channel to listen for new matches
      _matchChannel = supabase.channel('match_notifications_$userId');

      // Listen for ALL changes on matches table with verbose logging
      _matchChannel!
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'matches',
            callback: (payload) {
              debugPrint('');
              debugPrint('═══════════════════════════════════════════════════════');
              debugPrint('🔔 REALTIME EVENT RECEIVED ON MATCHES TABLE');
              debugPrint('   Event type: ${payload.eventType}');
              debugPrint('   Table: ${payload.table}');
              debugPrint('   Schema: ${payload.schema}');
              debugPrint('   New Record: ${payload.newRecord}');
              debugPrint('   Old Record: ${payload.oldRecord}');
              debugPrint('═══════════════════════════════════════════════════════');
              debugPrint('');

              // Route to appropriate handler
              if (payload.eventType == PostgresChangeEvent.insert) {
                debugPrint('→ Routing to INSERT handler');
                _handleNewMatch(payload, userId);
              } else if (payload.eventType == PostgresChangeEvent.delete) {
                debugPrint('→ Routing to DELETE handler');
                _handleMatchDeleted(payload, userId);
              } else if (payload.eventType == PostgresChangeEvent.update) {
                debugPrint('→ Routing to UPDATE handler');
                // Handle updates if needed in future
              }
            },
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              debugPrint('✅ Match notifications: Subscribed successfully (INSERT, DELETE, UPDATE)');
            } else if (status == RealtimeSubscribeStatus.closed) {
              debugPrint('❌ Match notifications: Channel closed - attempting reconnect');
              // Try to reconnect after a delay
              Future.delayed(const Duration(seconds: 2), () {
                if (_matchChannel == null) {
                  debugPrint('🔄 Reconnecting match notifications...');
                  _setupRealtimeSubscription();
                }
              });
            } else if (status == RealtimeSubscribeStatus.channelError) {
              debugPrint('❌ Match notifications: Channel error');
            } else if (status == RealtimeSubscribeStatus.timedOut) {
              debugPrint('❌ Match notifications: Timed out');
            }
            if (error != null) {
              debugPrint('❌ Match notifications error: $error');
            }
          });
    } catch (e, stackTrace) {
      debugPrint('❌ Error setting up match notifications: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  void _handleNewMatch(PostgresChangePayload payload, String currentUserId) async {
    try {
      var newRecord = payload.newRecord;
      
      // Check if this match involves the current user
      final userAId = newRecord['user1_id'] as String?;
      final userBId = newRecord['user2_id'] as String?;
      
      if (userAId != currentUserId && userBId != currentUserId) {
        debugPrint('   ⏭️ Match not for current user, skipping');
        return; // Not for this user
      }

      debugPrint('   ✓ Match is for current user');

      // Fetch event details if this is an event match
      String? eventName;
      String? eventLink;
      final eventId = newRecord['event_id'] as String?;
      if (eventId != null && eventId.isNotEmpty) {
        try {
          final eventResponse = await supabase
              .from('events')
              .select('event_name, event_link')
              .eq('id', eventId)
              .single();
          eventName = eventResponse['event_name'] as String?;
          eventLink = eventResponse['event_link'] as String?;
          debugPrint('   ✓ Fetched event details: $eventName');
          
          // Update the match data with event details for local DB
          newRecord = {
            ...newRecord,
            'event_name': eventName,
            'event_link': eventLink,
          };
        } catch (e) {
          debugPrint('   ⚠️ Failed to fetch event details: $e');
        }
      }

      debugPrint('   📝 Adding match to local database...');

      // Add the match to local database for Recent Matches (now with event details)
      final localDb = ref.read(localDbProvider);
      await localDb.addOrUpdateMatch(newRecord);
      
      debugPrint('   ✓ Match added to local DB');

      // Create MatchModel from the new record
      final match = MatchModel(
        id: newRecord['id'] as String,
        userAId: userAId ?? '',
        userBId: userBId ?? '',
        matchedIntent: newRecord['matched_intent'] as String? ?? 'Unknown',
        matchType: newRecord['match_type'] as String? ?? 'proximity',
        createdAt: DateTime.parse(newRecord['created_at'] as String? ?? DateTime.now().toIso8601String()),
        otherUserId: userAId == currentUserId ? userBId ?? '' : userAId ?? '',
        eventId: eventId,
        eventName: eventName,
        eventLink: eventLink,
      );

      // Add to notifications list
      final notification = MatchNotification(
        match: match,
        timestamp: DateTime.now(),
        viewed: false,
      );

      final updatedNotifications = [notification, ...state.notifications];
      final newUnreadCount = updatedNotifications.where((n) => !n.viewed).length;

      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );

      debugPrint('🎉 New match notification added! Total unread: $newUnreadCount');
      debugPrint('✅ Match should now appear in Recent Matches');
    } catch (e, stackTrace) {
      debugPrint('❌ Error handling new match: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Handle match deletion from realtime
  void _handleMatchDeleted(PostgresChangePayload payload, String userId) async {
    try {
      final oldRecord = payload.oldRecord;
      final matchId = oldRecord['id'] as String?;
      
      if (matchId == null) {
        debugPrint('⚠️ Match deletion: No match ID in payload');
        return;
      }

      debugPrint('🗑️ DELETE event received for match: $matchId');
      debugPrint('   Current state - notifications: ${state.notifications.length}, unread: ${state.unreadCount}');

      // Delete from local database via ref
      await ref.read(localDbProvider).deleteMatch(matchId);
      // Ensure we remove the chat from the per-user recent chats cache as well
      await ref.read(localDbProvider).deleteChat(matchId, userId: userId);
      await ref.read(localDbProvider).deleteMessages(matchId);
      debugPrint('   ✓ Delete operations completed - check logs above for details');

      // Check if notification exists for this match
      final notificationIndex = state.notifications.indexWhere((n) => n.match.id == matchId);
      final notificationExists = notificationIndex != -1;
      
      debugPrint('   Notification exists in state: $notificationExists');

      // Remove from notifications if it exists
      final updatedNotifications = state.notifications
          .where((notification) => notification.match.id != matchId)
          .toList();

      // Calculate new unread count
      // If the notification existed and was unviewed, decrease count
      // If it didn't exist but unreadCount > 0, still decrease (safety)
      int newUnreadCount;
      if (notificationExists) {
        final wasUnviewed = !state.notifications[notificationIndex].viewed;
        newUnreadCount = updatedNotifications.where((n) => !n.viewed).length;
        debugPrint('   Notification was ${wasUnviewed ? "UNVIEWED" : "viewed"}');
      } else {
        // Notification not in list - safely decrease unread count if > 0
        newUnreadCount = state.unreadCount > 0 ? state.unreadCount - 1 : 0;
        debugPrint('   Notification not found - decreasing unread count anyway');
      }

      debugPrint('   New state - notifications: ${updatedNotifications.length}, unread: $newUnreadCount');

      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );

      debugPrint('✅ Match deletion handled - badge should now show: $newUnreadCount');
    } catch (e, stackTrace) {
      debugPrint('❌ Error handling match deletion: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Mark a specific notification as viewed
  void markAsViewed(String matchId) {
    final updatedNotifications = state.notifications.map((notification) {
      if (notification.match.id == matchId && !notification.viewed) {
        return notification.copyWith(viewed: true);
      }
      return notification;
    }).toList();

    final newUnreadCount = updatedNotifications.where((n) => !n.viewed).length;

    state = state.copyWith(
      notifications: updatedNotifications,
      unreadCount: newUnreadCount,
    );
  }

  /// Mark all notifications as viewed
  void markAllAsViewed() {
    final updatedNotifications = state.notifications.map((notification) {
      return notification.copyWith(viewed: true);
    }).toList();

    state = state.copyWith(
      notifications: updatedNotifications,
      unreadCount: 0,
    );
  }

  /// Clear old viewed notifications (older than 24 hours)
  void clearOldNotifications() {
    final cutoffTime = DateTime.now().subtract(const Duration(hours: 24));
    final filteredNotifications = state.notifications.where((notification) {
      return !notification.viewed || notification.timestamp.isAfter(cutoffTime);
    }).toList();

    final newUnreadCount = filteredNotifications.where((n) => !n.viewed).length;

    state = state.copyWith(
      notifications: filteredNotifications,
      unreadCount: newUnreadCount,
    );
  }

  void cleanup() {
    _channelSubscription?.cancel();
    _matchChannel?.unsubscribe();
    if (_matchChannel != null) {
      supabase.removeChannel(_matchChannel!);
    }
  }
}

/// Provider for match notifications
final matchNotificationProvider = NotifierProvider<MatchNotificationNotifier, MatchNotificationState>(() {
  return MatchNotificationNotifier();
});

/// Provider for unread match count (convenience)
final unreadMatchCountProvider = Provider<int>((ref) {
  return ref.watch(matchNotificationProvider).unreadCount;
});
