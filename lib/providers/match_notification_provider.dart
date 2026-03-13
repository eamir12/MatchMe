// lib/providers/match_notification_provider.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/web_notification_service.dart';

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
  RealtimeChannel? _profileChannel;
  StreamSubscription? _channelSubscription;
  Timer? _matchedProfilePollTimer;
  Set<String> _matchedOtherUserIds = <String>{};
  final Map<String, DateTime> _lastProfileRealtimeSyncAt = <String, DateTime>{};
  List<String> _extractPhotoPaths(dynamic raw) {
    if (raw is List) {
      return raw.map((e) => e?.toString() ?? '').where((e) => e.isNotEmpty).toList();
    }
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isNotEmpty ? [trimmed] : <String>[];
    }
    return const <String>[];
  }

  @override
  MatchNotificationState build() {
    ref.watch(localizationProvider);
    ref.onDispose(cleanup);
    final userId = supabase.auth.currentUser?.id;
    developer.log('🧩 MatchNotificationProvider build: user=$userId', name: 'MatchMeTrace');
    if (userId == null || userId.trim().isEmpty) {
      cleanup();
      _matchedOtherUserIds = <String>{};
      return MatchNotificationState();
    }
    _setupRealtimeSubscription();
    ref.listen<AsyncValue<List<MatchModel>>>(recentMatchesProvider(userId), (previous, next) {
      final matches = next.asData?.value ?? const <MatchModel>[];

      final activeIds = matches.map((m) => m.id).toSet();
      final updatedNotifications =
          state.notifications.where((n) => activeIds.contains(n.match.id)).toList();

      if (updatedNotifications.length == state.notifications.length) return;

      final newUnreadCount = updatedNotifications.where((n) => !n.viewed).length;
      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );
    });

    ref.listen<AsyncValue<List<MatchModel>>>(recentMatchesProvider(userId), (previous, next) {
      final matches = next.asData?.value ?? const <MatchModel>[];
      final otherUserIds = matches
          .map((m) => m.otherUserId.trim())
          .where((id) => id.isNotEmpty && id != userId)
          .toSet();
      _updateMatchedUserProfileSubscription(userId, otherUserIds);
    }, fireImmediately: true);
    return MatchNotificationState();
  }

  bool _shouldSyncProfileFromRealtime(String userId, Duration minInterval) {
    final now = DateTime.now();
    final last = _lastProfileRealtimeSyncAt[userId];
    if (last != null && now.difference(last) < minInterval) return false;
    _lastProfileRealtimeSyncAt[userId] = now;
    return true;
  }

  void _updateMatchedUserProfileSubscription(String currentUserId, Set<String> otherUserIds) {
    final isSame =
        otherUserIds.length == _matchedOtherUserIds.length &&
        otherUserIds.containsAll(_matchedOtherUserIds);
    developer.log('🧩 Update matched user subscription: currentUser=$currentUserId, newCount=${otherUserIds.length}, prevCount=${_matchedOtherUserIds.length}, isSame=$isSame', name: 'MatchMeTrace');
    if (isSame) return;

    _matchedOtherUserIds = otherUserIds;

    _matchedProfilePollTimer?.cancel();
    _matchedProfilePollTimer = null;

    if (_profileChannel != null) {
      supabase.removeChannel(_profileChannel!);
      _profileChannel = null;
    }

    if (otherUserIds.isEmpty) return;

    _profileChannel = supabase.channel('match_profile_updates_$currentUserId');
    _profileChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          callback: (payload) async {
            if (!ref.mounted) return;
            if (supabase.auth.currentSession == null) return;
            final newRecord = payload.newRecord;
            final changedUserId = newRecord['id']?.toString();
            if (changedUserId == null || changedUserId.isEmpty) return;
            if (changedUserId == currentUserId) return;
            if (!_matchedOtherUserIds.contains(changedUserId)) return;
            developer.log('🧩 Realtime users update for matched user: $changedUserId', name: 'MatchMeTrace');
            final photoPaths = _extractPhotoPaths(newRecord['photos']);
            final localDb = ref.read(localDbProvider);
            final cachedLocal = await localDb.getLocalProfile(changedUserId);
            final cachedPhotos = _extractPhotoPaths(cachedLocal?['photos']);
            final photosChanged = !listEquals(cachedPhotos, photoPaths);
            developer.log('🧩 Photos changed: $photosChanged (old: ${cachedPhotos.length}, new: ${photoPaths.length})', name: 'MatchMeTrace');
            if (photosChanged) {
              final allPaths = <String>{...cachedPhotos, ...photoPaths};
              for (final path in allPaths) {
                StorageHelper.evictImageCache(path);
              }
              final updatedLocal = Map<String, dynamic>.from(cachedLocal ?? {});
              updatedLocal['photos'] = photoPaths;
              updatedLocal['_cached_at'] = DateTime.now().toIso8601String();
              await localDb.saveLocalProfile(changedUserId, updatedLocal);
              final cachedOther = await localDb.getOtherUserProfileWithCacheMeta(changedUserId);
              if (cachedOther != null) {
                final updatedOther = Map<String, dynamic>.from(cachedOther);
                updatedOther['photos'] = photoPaths;
                await localDb.saveOtherUserProfile(changedUserId, updatedOther);
              }
              developer.log('🧩 Local photo caches updated for: $changedUserId', name: 'MatchMeTrace');
            }
            if (photosChanged && ref.mounted) {
              ref.invalidate(otherUserProfileProvider(changedUserId));
              ref.invalidate(userProfileProvider(changedUserId));
              ref.invalidate(recentMatchesProvider(currentUserId));
              ref.invalidate(recentChatsProvider(currentUserId));
              developer.log('🧩 Providers invalidated for: $changedUserId', name: 'MatchMeTrace');
            }
            if (_shouldSyncProfileFromRealtime(changedUserId, const Duration(milliseconds: 100))) {
              developer.log('🧩 Triggering profile sync for: $changedUserId', name: 'MatchMeTrace');
              ref.read(profileSyncProvider).syncProfile(changedUserId);
            } else {
              developer.log('🧩 Skipping profile sync (throttled) for: $changedUserId', name: 'MatchMeTrace');
            }
          },
        )
        .subscribe((status, err) {
          if (!ref.mounted) return;
          if (status == RealtimeSubscribeStatus.subscribed) {
            developer.log('🧩 Users realtime subscribed for currentUser=$currentUserId', name: 'MatchMeTrace');
          }
          if (status == RealtimeSubscribeStatus.closed || status == RealtimeSubscribeStatus.channelError) {
            // Prevent reconnect loop if app is in background
            if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused || 
                WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
              return;
            }

            Future.delayed(const Duration(seconds: 2), () {
              if (!ref.mounted) return;
              if (supabase.auth.currentSession == null) return;
              ref.invalidateSelf();
            });
          }
        });

    for (final id in _matchedOtherUserIds) {
      if (supabase.auth.currentSession == null) break;
      if (_shouldSyncProfileFromRealtime(id, const Duration(milliseconds: 300))) {
        ref.read(profileSyncProvider).syncProfile(id);
      }
    }

    _matchedProfilePollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!ref.mounted) return;
      if (supabase.auth.currentSession == null) return;
      for (final id in _matchedOtherUserIds) {
        if (_shouldSyncProfileFromRealtime(id, const Duration(seconds: 5))) {
          ref.read(profileSyncProvider).syncProfile(id);
        }
      }
    });
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
              
              // Prevent reconnect loop if app is in background
              if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused || 
                  WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
                debugPrint('⏸️ App in background, skipping auto-reconnect');
                return;
              }

              // Try to reconnect after a delay (but only if still mounted)
              Future.delayed(const Duration(seconds: 2), () async {
                if (!ref.mounted) {
                  debugPrint('🔄 Not reconnecting match notifications - notifier unmounted');
                  return;
                }
                if (supabase.auth.currentSession == null) {
                  return;
                }
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
    if (!ref.mounted) {
      debugPrint('🧭 Not handling new match - notifier not mounted');
      return;
    }

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
          // Try cache first
          final localDb = ref.read(localDbProvider);
          final cachedEvent = await localDb.getEventDetails(eventId);

          if (cachedEvent != null) {
            eventName = cachedEvent['event_name'] as String?;
            eventLink = cachedEvent['event_link'] as String?;
            if (kIsWeb) {
              debugPrint('🔍 [WEB] Match notification - Using cached event details: $eventName');
            }
          } else {
            // Fetch from server and cache
            final eventResponse = await supabase
                .from('events')
                .select('id, event_name, event_link, event_venue, start_time, end_time')
                .eq('id', eventId)
                .single();

            eventName = eventResponse['event_name'] as String?;
            eventLink = eventResponse['event_link'] as String?;

            // Cache the full event details
            await localDb.saveEventDetails(eventId, eventResponse);
            debugPrint('   ✓ Fetched and cached event details: $eventName');
          }
          
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
      Future.microtask(() => ref.read(profileSyncProvider).syncProfile(match.otherUserId));

      if (kIsWeb) {
        String? otherUserName;
        try {
          final otherUserId = match.otherUserId.trim();
          if (otherUserId.isNotEmpty) {
            final otherProfile =
                await ref.read(otherUserProfileProvider(otherUserId).future);
            final trimmedName = otherProfile?.name.trim();
            if (trimmedName != null && trimmedName.isNotEmpty) {
              otherUserName = trimmedName;
            }
          }
        } catch (_) {}

        await WebNotificationService.showMatchNotification(
          matchId: match.id,
          matchName: otherUserName ?? 'MatchMe',
          matchPhotoUrl: '',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error handling new match: $e');
      debugPrint('Stack trace: $stackTrace');
    }
  }

  /// Handle match deletion from realtime
  void _handleMatchDeleted(PostgresChangePayload payload, String userId) async {
    if (!ref.mounted) {
      debugPrint('🧭 Not handling match deletion - notifier not mounted');
      return;
    }

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
      // Only adjust the badge if the deleted match was actually represented in notifications.
      final newUnreadCount = updatedNotifications.where((n) => !n.viewed).length;
      if (notificationExists) {
        final wasUnviewed = !state.notifications[notificationIndex].viewed;
        debugPrint('   Notification was ${wasUnviewed ? "UNVIEWED" : "viewed"}');
      } else {
        debugPrint('   Notification not found - leaving unread count unchanged');
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
    _channelSubscription = null;
    _matchChannel?.unsubscribe();
    if (_matchChannel != null) {
      supabase.removeChannel(_matchChannel!);
    }
    _matchChannel = null;
    _profileChannel?.unsubscribe();
    if (_profileChannel != null) {
      supabase.removeChannel(_profileChannel!);
    }
    _profileChannel = null;
    _matchedProfilePollTimer?.cancel();
    _matchedProfilePollTimer = null;
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
