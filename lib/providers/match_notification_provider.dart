// lib/providers/match_notification_provider.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/web_imports.dart' as html;
import 'package:matchme/utils/offline_utils.dart';

final supabase = Supabase.instance.client;

/// Represents a new match notification
class MatchNotification {
  final MatchModel match;
  final DateTime timestamp;
  final bool viewed;

  /// True when this banner was raised because the *other* participant
  /// extended the match's chat window, rather than because the match is new.
  /// The two share a surface but carry different copy and different urgency.
  final bool isExtension;

  MatchNotification({
    required this.match,
    required this.timestamp,
    this.viewed = false,
    this.isExtension = false,
  });

  MatchNotification copyWith({bool? viewed}) {
    return MatchNotification(
      match: match,
      timestamp: timestamp,
      viewed: viewed ?? this.viewed,
      isExtension: isExtension,
    );
  }
}

/// State for managing match notifications
class MatchNotificationState {
  final List<MatchNotification> notifications;
  final int unreadCount;

  MatchNotificationState({this.notifications = const [], this.unreadCount = 0});

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
  Timer? _matchedProfilePollTimer;
  Timer? _fallbackMatchesPollTimer;
  Set<String> _matchedOtherUserIds = <String>{};
  void Function()? _resumeDispose;
  final Map<String, DateTime> _lastProfileRealtimeSyncAt = <String, DateTime>{};
  dynamic
  _webVisibilityListener; // Web visibility listener for minimized window support

  // Track subscription state to prevent repeated setup
  bool _matchChannelSubscribed = false;
  DateTime? _lastResumeSubscriptionAt;
  String? _matchChannelName;

  // Reconnection state for timedOut/closed subscriptions
  static const int _maxReconnectAttempts = 5;
  int _reconnectAttempts = 0;
  DateTime? _lastReconnectAt;
  Timer? _reconnectTimer;

  // Tracks the userId that was used to create channels, so cleanup can
  // unregister them even after currentUser becomes null on sign-out.
  String _currentUserId = '';

  // Guards against concurrent setup calls (e.g. from delayed init + onResume)
  bool _isSettingUp = false;

  Duration _jitteredBackoff(int attempt) {
    final base = Duration(milliseconds: (1000 * math.pow(2, attempt)).round());
    final jitter = Duration(milliseconds: math.Random().nextInt(1000));
    return base + jitter;
  }

  List<String> _extractPhotoPaths(dynamic raw) {
    if (raw is List) {
      final result = <String>[];
      for (final e in raw) {
        final str = e?.toString() ?? '';
        if (str.isNotEmpty) result.add(str);
      }
      return result;
    }
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isNotEmpty ? [trimmed] : <String>[];
    }
    return const <String>[];
  }

  @override
  MatchNotificationState build() {
    ref.onDispose(() {
      cleanup();
      _detachWebVisibilityListener();
    });
    final userId = supabase.auth.currentUser?.id;
    developer.log(
      '🧩 MatchNotificationProvider build: user=$userId',
      name: 'MatchMeTrace',
    );
    if (userId == null || userId.trim().isEmpty) {
      _currentUserId = '';
      cleanup();
      _matchedOtherUserIds = <String>{};
      return MatchNotificationState();
    }
    _currentUserId = userId;

    // Listen to auth state to clean up when user signs out or switches
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (
      previous,
      next,
    ) async {
      final authState = next.asData?.value;
      if (authState == null) return;
      final event = authState.event;
      if (event == AuthChangeEvent.signedOut) {
        cleanup();
        _matchedOtherUserIds = <String>{};
        state = MatchNotificationState();
      }
    });

    // Register callback to set up subscription when connectivity is restored.
    // Clean up old callback first to prevent accumulation on rebuilds.
    // 30s cooldown suppresses duplicate fires from the ConnectivityRestoreCoordinator
    // (8s min interval is not enough on cold start when the FCM registerSession's
    // setSupabaseAvailability(true) also fires a restore ~10s after the first one).
    _resumeDispose?.call();
    _resumeDispose = onSupabaseResume(() {
      if (!ref.mounted) return;
      // Idempotency: if a healthy channel is already alive, do nothing and
      // don't log a noisy "Connectivity restored - setting up subscription"
      // message. ConnectivityRestoreCoordinator and the FCM registerSession
      // both publish resume events during cold start, so without this check
      // we end up with a "Connectivity restored" log line immediately
      // followed by an "already subscribed" line for no reason.
      // Screen off/on must not recreate: check the manager's live channel,
      // not just the local subscribed flag (which lags the async ACK).
      final uid = supabase.auth.currentUser?.id;
      if (uid != null &&
          SupabaseRealtimeManager.instance.isActive(
            'match_notifications_$uid',
          )) {
        return;
      }
      if (_matchChannelSubscribed && _matchChannel != null) {
        return;
      }
      final now = DateTime.now();
      if (_lastResumeSubscriptionAt != null &&
          now.difference(_lastResumeSubscriptionAt!) <
              const Duration(seconds: 30)) {
        return;
      }
      _lastResumeSubscriptionAt = now;
      if (kDebugMode) {
        debugPrint(
          '📡 Match notifications: Connectivity restored - setting up subscription',
        );
      }
      unawaited(_setupRealtimeSubscription());
    });

    // Only set up subscription immediately if we're currently online
    // If we're offline, the callback above will set it up when connectivity is restored.
    //
    // Defer the initial setup past the first frame. The phx_join +
    // subscription messages that .subscribe() emits travel over a method
    // channel and a freshly-opened WebSocket; on cold start the first
    // such subscribe lands inside the post-bootstrap frame and was
    // visible in logs as a 62-frame skip (Davey ~2 s) right after the
    // ChatKeyProvider post-frame init. Reduced from 4s to 200ms to enable
    // near-instant match notifications while still avoiding frame drops.
    // Missed notifications during the 200ms window are picked up by the
    // initial match-fetch in bootstrap and the next sync cycle.
    if (!shouldSkipSupabaseCalls()) {
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!ref.mounted) return;
        if (shouldSkipSupabaseCalls()) {
          debugPrint(
            '⏸️ Match notifications: Delayed setup skipped - now offline',
          );
          return;
        }
        final delayedUid = supabase.auth.currentUser?.id;
        if (delayedUid != null &&
            SupabaseRealtimeManager.instance.isActive(
              'match_notifications_$delayedUid',
            )) {
          return;
        }
        if (_matchChannelSubscribed && _matchChannel != null) return;
        unawaited(_setupRealtimeSubscription());
      });
    } else {
      debugPrint(
        '⏸️ Match notifications: Skipping initial setup - currently offline',
      );
    }
    _attachWebVisibilityListener();
    // Fallback poll for missed realtime inserts (e.g., Android was offline during
    // Gradle install while match was created). Realtime is primary, but polling
    // every 15s guarantees eventual consistency across platforms.
    _fallbackMatchesPollTimer?.cancel();
    _fallbackMatchesPollTimer = Timer.periodic(const Duration(seconds: 15), (
      _,
    ) {
      if (!ref.mounted) return;
      if (shouldSkipSupabaseCalls()) return;
      final current = supabase.auth.currentUser?.id;
      if (current == null || current != userId) return;
      unawaited(ref.read(globalSyncManagerProvider).syncMatchesNow(userId));
    });
    ref.listen<AsyncValue<List<MatchModel>>>(recentMatchesProvider(userId), (
      previous,
      next,
    ) {
      final matches = next.asData?.value ?? const <MatchModel>[];

      final activeIds = <String>{};
      for (final m in matches) {
        activeIds.add(m.id);
      }
      final updatedNotifications = state.notifications
          .where((n) => activeIds.contains(n.match.id))
          .toList();

      if (updatedNotifications.length == state.notifications.length) return;

      final newUnreadCount = updatedNotifications
          .where((n) => !n.viewed)
          .length;
      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );
      final otherUserIds = matches
          .map((m) => m.otherUserId.trim())
          .where((id) => id.isNotEmpty && id != userId)
          .toSet();
      _updateMatchedUserProfileSubscription(userId, otherUserIds);
    });

    // Prime matched-user subscription after initial provider build completes.
    Future.microtask(() {
      if (!ref.mounted) return;
      final initialMatches =
          ref.read(recentMatchesProvider(userId)).asData?.value ??
          const <MatchModel>[];
      final initialOtherUserIds = initialMatches
          .map((m) => m.otherUserId.trim())
          .where((id) => id.isNotEmpty && id != userId)
          .toSet();
      _updateMatchedUserProfileSubscription(userId, initialOtherUserIds);
    });
    return MatchNotificationState();
  }

  bool _shouldSyncProfileFromRealtime(String userId, Duration minInterval) {
    final now = DateTime.now();
    final last = _lastProfileRealtimeSyncAt[userId];
    if (last != null && now.difference(last) < minInterval) return false;
    _lastProfileRealtimeSyncAt[userId] = now;
    return true;
  }

  void _updateMatchedUserProfileSubscription(
    String currentUserId,
    Set<String> otherUserIds,
  ) {
    final isSame =
        otherUserIds.length == _matchedOtherUserIds.length &&
        otherUserIds.containsAll(_matchedOtherUserIds);
    developer.log(
      '🧩 Update matched user subscription: currentUser=$currentUserId, newCount=${otherUserIds.length}, prevCount=${_matchedOtherUserIds.length}, isSame=$isSame',
      name: 'MatchMeTrace',
    );
    if (isSame) return;

    _matchedOtherUserIds = otherUserIds;

    _matchedProfilePollTimer?.cancel();
    _matchedProfilePollTimer = null;

    SupabaseRealtimeManager.instance.unregister(
      'match_profile_updates_$currentUserId',
    );

    if (otherUserIds.isEmpty) return;

    final channelName = 'match_profile_updates_$currentUserId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      final channel = supabase.channel(channelName);
      channel
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
              developer.log(
                '🧩 Realtime users update for matched user: $changedUserId',
                name: 'MatchMeTrace',
              );
              final photoPaths = _extractPhotoPaths(newRecord['photos']);
              final localDb = ref.read(localDbProvider);
              final cachedLocal = await localDb.getLocalProfile(changedUserId);
              final cachedPhotos = _extractPhotoPaths(cachedLocal?['photos']);
              final photosChanged = !listEquals(cachedPhotos, photoPaths);
              developer.log(
                '🧩 Photos changed: $photosChanged (old: ${cachedPhotos.length}, new: ${photoPaths.length})',
                name: 'MatchMeTrace',
              );
              if (photosChanged) {
                final allPaths = <String>{...cachedPhotos, ...photoPaths};
                for (final path in allPaths) {
                  StorageHelper.evictImageCache(path);
                }
                final updatedLocal = Map<String, dynamic>.from(
                  cachedLocal ?? {},
                );
                updatedLocal['photos'] = photoPaths;
                updatedLocal['_cached_at'] = DateTime.now().toIso8601String();
                await localDb.saveLocalProfile(changedUserId, updatedLocal);
                final cachedOther = await localDb
                    .getOtherUserProfileWithCacheMeta(changedUserId);
                if (cachedOther != null) {
                  final updatedOther = Map<String, dynamic>.from(cachedOther);
                  updatedOther['photos'] = photoPaths;
                  await localDb.saveOtherUserProfile(
                    changedUserId,
                    updatedOther,
                  );
                }
                developer.log(
                  '🧩 Local photo caches updated for: $changedUserId',
                  name: 'MatchMeTrace',
                );
              }
              if (photosChanged && ref.mounted) {
                ref.invalidate(otherUserProfileProvider(changedUserId));
                ref.invalidate(userProfileProvider(changedUserId));
                ref.invalidate(recentMatchesProvider(currentUserId));
                ref.invalidate(recentChatsProvider(currentUserId));
                developer.log(
                  '🧩 Providers invalidated for: $changedUserId',
                  name: 'MatchMeTrace',
                );
              }
              if (_shouldSyncProfileFromRealtime(
                changedUserId,
                const Duration(milliseconds: 100),
              )) {
                developer.log(
                  '🧩 Triggering profile sync for: $changedUserId',
                  name: 'MatchMeTrace',
                );
                ref
                    .read(profileSyncProvider)
                    .syncProfile(
                      changedUserId,
                      source: 'matched-user-realtime',
                    );
              } else {
                developer.log(
                  '🧩 Skipping profile sync (throttled) for: $changedUserId',
                  name: 'MatchMeTrace',
                );
              }
            },
          )
          .subscribe((status, err) {
            try {
              if (!ref.mounted) return;
              if (status == RealtimeSubscribeStatus.subscribed) {
                developer.log(
                  '🧩 Users realtime subscribed for currentUser=$currentUserId',
                  name: 'MatchMeTrace',
                );
              } else if (handleExpectedSupabaseOfflineFailure(err)) {
                return;
              } else if (SupabaseRealtimeManager.instance.isPaused) {
                return;
              }
            } catch (e) {
              developer.log(
                '⚠️ Profile channel subscription error (caught): $e',
                name: 'MatchMeTrace',
              );
            }
          });
      return channel;
    });

    var staggerMs = 0;
    for (final id in _matchedOtherUserIds) {
      if (supabase.auth.currentSession == null) break;
      if (_shouldSyncProfileFromRealtime(
        id,
        const Duration(milliseconds: 1200),
      )) {
        final targetId = id;
        unawaited(
          Future.delayed(Duration(milliseconds: staggerMs), () {
            if (!ref.mounted) return;
            if (supabase.auth.currentSession == null) return;
            ref
                .read(profileSyncProvider)
                .syncProfile(
                  targetId,
                  source: 'matched-user-subscription-init',
                );
          }),
        );
        staggerMs += 350;
      }
    }
  }

  Future<void> _setupRealtimeSubscription() async {
    debugPrint(
      '⏱️ [BOOTSTRAP] match_notification _setup called shouldSkip=${shouldSkipSupabaseCalls()} isSupabaseAvailable=${!shouldSkipSupabaseCalls()}',
    );
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      return;
    }

    // Skip if Supabase communication is paused
    if (shouldSkipSupabaseCalls()) {
      debugPrint(
        '⏸️ Match notifications: Skipped - Supabase communication paused',
      );
      return;
    }

    final channelName = 'match_notifications_$userId';

    // Stay subscribed across screen off/on: if the manager already holds a
    // live channel for this name, keep it. Recreating here is what caused a
    // fresh "Subscribed successfully" log on every resume.
    if (SupabaseRealtimeManager.instance.isActive(channelName)) {
      _matchChannelName = channelName;
      // Adopt healthy state so later resume callbacks stay no-ops. The actual
      // channel object lives in the manager (see getChannel); the subscribe
      // ACK already fired when it was first created.
      final live = SupabaseRealtimeManager.instance.getChannel(channelName);
      if (live != null) _matchChannel = live;
      _matchChannelSubscribed = true;
      _isSettingUp = false;
      return;
    }

    // Skip setup if already subscribed OR subscribing to prevent repeated channel creation
    if (_matchChannelSubscribed && _matchChannel != null) {
      debugPrint('🔄 Match notifications already subscribed, skipping setup');
      return;
    }

    // Prevent concurrent setup calls (e.g. delayed init fires while onResume is active).
    // Note: _isSettingUp covers the sync gap only; the async subscribe ACK gap
    // is covered by the isActive() check above once the channel exists.
    if (_isSettingUp) {
      debugPrint('⏸️ Match notifications: setup already in progress, skipping');
      return;
    }
    _isSettingUp = true;

    // Reset reconnect state for a fresh subscription attempt
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    // No manual removeChannel here: SupabaseRealtimeManager.register() owns
    // channel lifecycle. Removing the old channel unconditionally forced churn
    // on every setup call. A genuinely stale channel is cleared via
    // unregister() on error/closed paths below, letting register() create fresh.
    _matchChannelName = channelName;
    SupabaseRealtimeManager.instance.register(channelName, () {
      // When SupabaseRealtimeManager.resumeAll() re-activates this factory
      // after a connectivity restore, the user may have signed out in the
      // meantime — verify the session is still valid before subscribing.
      if (supabase.auth.currentSession == null) {
        throw Exception(
          'No active session — skipping match notification subscription',
        );
      }

      debugPrint('📡 Setting up match notification subscription');

      final channel = supabase.channel(channelName);

      // Listen for ALL changes on matches table with verbose logging
      channel
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'matches',
            callback: (payload) {
              print('');
              print('═══════════════════════════════════════════════════════');
              print('🔔 REALTIME EVENT RECEIVED ON MATCHES TABLE');
              print('   Event type: ${payload.eventType}');
              print('   Table: ${payload.table}');
              print('   Schema: ${payload.schema}');
              print('   New Record: ${payload.newRecord}');
              print('   Old Record: ${payload.oldRecord}');
              print('═══════════════════════════════════════════════════════');
              print('');

              // Route to appropriate handler
              if (payload.eventType == PostgresChangeEvent.insert) {
                print('→ Routing to INSERT handler');
                _handleNewMatch(payload, userId);
              } else if (payload.eventType == PostgresChangeEvent.delete) {
                print('→ Routing to DELETE handler');
                _handleMatchDeleted(payload, userId);
              } else if (payload.eventType == PostgresChangeEvent.update) {
                print('→ Routing to UPDATE handler');
                _handleMatchUpdated(payload, userId);
              }
            },
          )
          .subscribe((status, error) {
            try {
              if (status == RealtimeSubscribeStatus.subscribed) {
                debugPrint(
                  '✅ Match notifications: Subscribed successfully (INSERT, DELETE, UPDATE)',
                );
                _matchChannelSubscribed = true;
                _reconnectAttempts = 0;
              } else if (status == RealtimeSubscribeStatus.closed ||
                  status == RealtimeSubscribeStatus.channelError ||
                  status == RealtimeSubscribeStatus.timedOut) {
                if (handleExpectedSupabaseOfflineFailure(error)) {
                  return;
                }
                // Dead refresh token / RLS rejection: server reachable but
                // session invalid — don't hot-retry here. REST fallback +
                // onSupabaseResume (after refresh) will re-subscribe.
                if (error != null && isAuthRateLimitFailure(error)) {
                  _matchChannelSubscribed = false;
                  return;
                }
                if (SupabaseRealtimeManager.instance.isPaused) return;
                debugPrint(
                  '❌ Match notifications: status=$status, error=$error',
                );
                _matchChannelSubscribed = false;
                // Unregister from SupabaseRealtimeManager to remove the stale
                // channel from the _active map and from Supabase, so that a
                // subsequent register() call can create a fresh channel.
                if (_matchChannelName != null) {
                  SupabaseRealtimeManager.instance.unregister(
                    _matchChannelName!,
                  );
                }
                _matchChannel = null;

                // Auto-reconnect with jittered exponential backoff
                if (_reconnectAttempts >= _maxReconnectAttempts) {
                  debugPrint(
                    '❌ Match notifications: Reconnection attempts exhausted ($_maxReconnectAttempts), stopping auto-reconnect',
                  );
                  return;
                }
                // Stop reconnecting if user is no longer authenticated
                if (supabase.auth.currentUser?.id == null) {
                  debugPrint(
                    '⏸️ Match notifications: Stopping reconnect — no authenticated user',
                  );
                  return;
                }
                // 8-second recovery window coalescing to avoid rapid re-subscribes
                // when multiple status events fire in quick succession.
                if (_lastReconnectAt != null &&
                    DateTime.now().difference(_lastReconnectAt!) <
                        const Duration(seconds: 8)) {
                  return;
                }
                _lastReconnectAt = DateTime.now();
                _reconnectAttempts++;
                final delay = _jitteredBackoff(_reconnectAttempts);
                debugPrint(
                  '🔄 Match notifications: Scheduling reconnect (attempt $_reconnectAttempts/$_maxReconnectAttempts, delay=${delay.inMilliseconds}ms)',
                );
                _reconnectTimer?.cancel();
                _reconnectTimer = Timer(delay, () {
                  if (!ref.mounted) return;
                  if (supabase.auth.currentUser?.id == null) return;
                  if (shouldSkipSupabaseCalls()) return;
                  debugPrint(
                    '🔄 Match notifications: Executing reconnect (attempt $_reconnectAttempts)',
                  );
                  unawaited(_setupRealtimeSubscription());
                });
              } else if (SupabaseRealtimeManager.instance.isPaused) {
                return;
              }

              if (error != null &&
                  !isExpectedOfflineFailure(error) &&
                  !isAuthRateLimitFailure(error)) {
                debugPrint('❌ Match notifications error: $error');
              }
            } catch (e) {
              if (!shouldSkipSupabaseCalls()) {
                print('⚠️ Match notifications subscription error (caught): $e');
              }
            }
          });
      _matchChannel = channel;
      return channel;
    });
    _isSettingUp = false;
  }

  void _handleNewMatch(
    PostgresChangePayload payload,
    String currentUserId,
  ) async {
    if (!ref.mounted) {
      print('🧭 Not handling new match - notifier not mounted');
      return;
    }

    try {
      var newRecord = payload.newRecord;

      // Check if this match involves the current user
      final userAId = newRecord['user1_id'] as String?;
      final userBId = newRecord['user2_id'] as String?;

      if (userAId != currentUserId && userBId != currentUserId) {
        print('   ⏭️ Match not for current user, skipping');
        return; // Not for this user
      }

      print('   ✓ Match is for current user');

      // Skip if this match already exists in notifications (dedup for duplicate realtime events)
      final matchId = newRecord['id'] as String?;
      if (matchId != null &&
          state.notifications.any((n) => n.match.id == matchId)) {
        print(
          '   ⏭️ Match $matchId already in notifications, skipping duplicate',
        );
        return;
      }

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
              print(
                '🔍 [WEB] Match notification - Using cached event details: $eventName',
              );
            }
          } else {
            // Fetch from server and cache
            final eventResponse = await supabase
                .from('events')
                .select(
                  'id, event_name, event_link, event_venue, start_time, end_time',
                )
                .eq('id', eventId)
                .single();

            eventName = eventResponse['event_name'] as String?;
            eventLink = eventResponse['event_link'] as String?;

            // Cache the full event details
            await localDb.saveEventDetails(eventId, eventResponse);
            print('   ✓ Fetched and cached event details: $eventName');
          }

          // Update the match data with event details for local DB
          newRecord = {
            ...newRecord,
            'event_name': eventName,
            'event_link': eventLink,
          };
        } catch (e) {
          print('   ⚠️ Failed to fetch event details: $e');
        }
      }

      print('   📝 Adding match to local database...');

      // Add the match to local database for Recent Matches (now with event details)
      final localDb = ref.read(localDbProvider);
      await localDb.addOrUpdateMatch(currentUserId, newRecord);

      print('   ✓ Match added to local DB');

      // Create MatchModel from the new record (including coarse map + rematch)
      double? parseCoord(dynamic v) => v == null
          ? null
          : (v is double
                ? v
                : (v is int ? v.toDouble() : double.tryParse(v.toString())));
      final match = MatchModel(
        id: newRecord['id'] as String,
        userAId: userAId ?? '',
        userBId: userBId ?? '',
        matchedIntent: newRecord['matched_intent'] as String? ?? 'Unknown',
        matchType: newRecord['match_type'] as String? ?? 'proximity',
        createdAt: DateTime.parse(
          newRecord['created_at'] as String? ??
              DateTime.now().toIso8601String(),
        ),
        otherUserId: userAId == currentUserId ? userBId ?? '' : userAId ?? '',
        eventId: eventId,
        eventName: eventName,
        eventLink: eventLink,
        matchOccurrence:
            (newRecord['match_occurrence'] is int
                    ? newRecord['match_occurrence'] as int
                    : int.tryParse(
                            newRecord['match_occurrence']?.toString() ?? '1',
                          ) ??
                          1)
                .clamp(1, 3),
        mapCenterLat: parseCoord(newRecord['map_center_lat']),
        mapCenterLng: parseCoord(newRecord['map_center_lng']),
        mapZoom: parseCoord(newRecord['map_zoom']),
        previousLocations: const [],
        isRetroactive: (newRecord['is_retroactive'] ?? false) is bool
            ? (newRecord['is_retroactive'] ?? false) as bool
            : (newRecord['is_retroactive'] ?? false).toString().toLowerCase() ==
                  'true',
      );

      // Add to notifications list
      final notification = MatchNotification(
        match: match,
        timestamp: DateTime.now(),
        viewed: false,
      );

      final updatedNotifications = [notification, ...state.notifications];
      final newUnreadCount = updatedNotifications
          .where((n) => !n.viewed)
          .length;

      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );

      print('🎉 New match notification added! Total unread: $newUnreadCount');
      print('✅ Match should now appear in Recent Matches');

      // Sync matches and chats to ensure all providers are updated
      unawaited(
        ref.read(globalSyncManagerProvider).syncMatchesNow(currentUserId),
      );
      unawaited(
        ref.read(globalSyncManagerProvider).syncChatsNow(currentUserId),
      );

      Future.microtask(
        () => ref
            .read(profileSyncProvider)
            .syncProfile(match.otherUserId, source: 'new-match-notification'),
      );

      if (kIsWeb) {
        String? otherUserName;
        try {
          final otherUserId = match.otherUserId.trim();
          if (otherUserId.isNotEmpty) {
            final otherProfile = await ref.read(
              otherUserProfileProvider(otherUserId).future,
            );
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
      print('❌ Error handling new match: $e');
      print('Stack trace: $stackTrace');
    }
  }

  /// Handle match deletion from realtime
  void _handleMatchDeleted(PostgresChangePayload payload, String userId) async {
    if (!ref.mounted) {
      print('🧭 Not handling match deletion - notifier not mounted');
      return;
    }

    try {
      final oldRecord = payload.oldRecord;
      final matchId = oldRecord['id'] as String?;

      if (matchId == null) {
        print('⚠️ Match deletion: No match ID in payload');
        return;
      }

      print('🗑️ DELETE event received for match: $matchId');
      print(
        '   Current state - notifications: ${state.notifications.length}, unread: ${state.unreadCount}',
      );

      // Delete from local database via ref
      await ref.read(localDbProvider).deleteMatch(matchId, userId: userId);
      // Ensure we remove the chat from the per-user recent chats cache as well
      await ref.read(localDbProvider).deleteChat(matchId, userId: userId);
      await ref.read(localDbProvider).deleteMessages(matchId);
      print('   ✓ Delete operations completed - check logs above for details');

      // Sync matches and chats to ensure all providers are updated
      unawaited(ref.read(globalSyncManagerProvider).syncMatchesNow(userId));
      unawaited(ref.read(globalSyncManagerProvider).syncChatsNow(userId));

      // Check if notification exists for this match
      final notificationIndex = state.notifications.indexWhere(
        (n) => n.match.id == matchId,
      );
      final notificationExists = notificationIndex != -1;

      print('   Notification exists in state: $notificationExists');

      // Remove from notifications if it exists
      final updatedNotifications = state.notifications
          .where((notification) => notification.match.id != matchId)
          .toList();

      // Calculate new unread count
      // Only adjust the badge if the deleted match was actually represented in notifications.
      final newUnreadCount = updatedNotifications
          .where((n) => !n.viewed)
          .length;
      if (notificationExists) {
        final wasUnviewed = !state.notifications[notificationIndex].viewed;
        print('   Notification was ${wasUnviewed ? "UNVIEWED" : "viewed"}');
      } else {
        print('   Notification not found - leaving unread count unchanged');
      }

      print(
        '   New state - notifications: ${updatedNotifications.length}, unread: $newUnreadCount',
      );

      state = state.copyWith(
        notifications: updatedNotifications,
        unreadCount: newUnreadCount,
      );

      print(
        '✅ Match deletion handled - badge should now show: $newUnreadCount',
      );
    } catch (e, stackTrace) {
      print('❌ Error handling match deletion: $e');
      print('Stack trace: $stackTrace');
    }
  }

  /// Handle match update from realtime (e.g., extension)
  void _handleMatchUpdated(PostgresChangePayload payload, String userId) async {
    if (!ref.mounted) {
      print('🧭 Not handling match update - notifier not mounted');
      return;
    }

    try {
      final newRecord = payload.newRecord;
      final oldRecord = payload.oldRecord;
      final matchId = newRecord['id'] as String?;

      if (matchId == null) {
        print('⚠️ Match update: No match ID in payload');
        return;
      }

      print('🔄 UPDATE event received for match: $matchId');

      // Sync matches to ensure local DB has the updated extension data
      unawaited(ref.read(globalSyncManagerProvider).syncMatchesNow(userId));

      // Invalidate the recentMatchesProvider to trigger UI refresh
      ref.invalidate(recentMatchesProvider(userId));

      // Did the *other* participant just extend the chat window? If so, raise
      // an in-app banner: extending is the cheapest signal of interest in the
      // product, and without this the peer only ever discovers it by opening
      // the app and spotting the badge.
      await _maybeNotifyPeerExtended(
        matchId: matchId,
        newRecord: newRecord,
        oldRecord: oldRecord,
        userId: userId,
      );
    } catch (e, stackTrace) {
      print('❌ Error handling match update: $e');
      print('Stack trace: $stackTrace');
    }
  }

  /// In-app channel gate for a notification type, honouring the global pause.
  bool _isInAppEnabled(NotificationType type) {
    try {
      final notifs = ref.read(userPreferencesProvider).notifications;
      if (notifs.isPausedNow) return false;
      return notifs.isMethodEnabled(type, NotificationMethod.inApp);
    } catch (_) {
      return true;
    }
  }

  /// Raise an in-app banner when the peer extends a match.
  ///
  /// Detection is a before/after diff on the *peer's* per-user extension
  /// column, which makes it naturally idempotent: `extend_match_chat_window`
  /// enforces one extension per participant, and even if that changed the
  /// transition 0 -> N only fires on the write that caused it.
  Future<void> _maybeNotifyPeerExtended({
    required String matchId,
    required Map<String, dynamic> newRecord,
    required Map<String, dynamic> oldRecord,
    required String userId,
  }) async {
    try {
      final user1Id = newRecord['user1_id']?.toString() ?? '';
      final user2Id = newRecord['user2_id']?.toString() ?? '';
      if (user1Id.isEmpty || user2Id.isEmpty) return;

      final iAmUser1 = user1Id == userId;
      if (!iAmUser1 && user2Id != userId) return;

      // Column holding the *peer's* extension seconds.
      final peerCol = iAmUser1
          ? 'chat_start_user2_extension_seconds'
          : 'chat_start_user1_extension_seconds';

      int intOf(String key, Map<String, dynamic> rec) {
        final v = rec[key];
        if (v is int) return v;
        if (v is num) return v.toInt();
        return int.tryParse(v?.toString() ?? '') ?? 0;
      }

      final beforeSec = intOf(peerCol, oldRecord);
      final afterSec = intOf(peerCol, newRecord);
      if (afterSec <= 0 || beforeSec > 0) return;

      if (!_isInAppEnabled(NotificationType.matchExtended)) {
        return;
      }
      // Reuse the cached MatchModel so the banner has the same shape as a
      // new-match banner (otherUserId, matchedIntent, matchType, event info).
      // If it isn't cached we skip the banner rather than fabricate a partial
      // model — the push notification still covers this case.
      final cached = ref.read(recentMatchesProvider(userId)).asData?.value;
      final matches = cached ?? const <MatchModel>[];
      final idx = matches.indexWhere((m) => m.id == matchId);
      if (idx < 0) {
        print(
          '⏱️ Peer extended match $matchId — no cached match, push-only banner',
        );
        return;
      }
      final match = matches[idx];

      final notification = MatchNotification(
        match: match,
        timestamp: DateTime.now(),
        viewed: false,
        isExtension: true,
      );

      state = state.copyWith(
        notifications: [notification, ...state.notifications],
        unreadCount: state.unreadCount + 1,
      );

      print('⏱️ Peer extended match $matchId — in-app banner raised');
    } catch (e) {
      // An in-app banner is a nicety; never let it break the sync path.
      print('⚠️ _maybeNotifyPeerExtended failed: $e');
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

    state = state.copyWith(notifications: updatedNotifications, unreadCount: 0);
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _matchChannelSubscribed = false;
    _isSettingUp = false;
    _matchChannel = null;
    if (_matchChannelName != null) {
      SupabaseRealtimeManager.instance.unregister(_matchChannelName!);
      _matchChannelName = null;
    }
    _matchedProfilePollTimer?.cancel();
    _matchedProfilePollTimer = null;
    _fallbackMatchesPollTimer?.cancel();
    _fallbackMatchesPollTimer = null;
    // Unregister profile-update channel using the stored userId (not
    // currentUser, which may be null after sign-out).
    if (_currentUserId.isNotEmpty) {
      SupabaseRealtimeManager.instance.unregister(
        'match_profile_updates_$_currentUserId',
      );
    }
    // Remove the onSupabaseResume callback so connectivity restore cannot
    // re-subscribe channels after the user has signed out.
    _resumeDispose?.call();
    _resumeDispose = null;
    // Detach the web visibility listener to prevent re-subscription when the
    // browser tab becomes visible after sign-out.
    _detachWebVisibilityListener();
  }

  void _attachWebVisibilityListener() {
    if (!kIsWeb) return;
    // Prevent duplicate listeners on rebuilds
    if (_webVisibilityListener != null) return;
    DateTime? lastHiddenAt;
    try {
      // Track hides so rapid focus switches (Alt-Tab, minimize/maximize)
      // don't re-run setup on every bounce — the channel stays alive across
      // brief hides and _setupRealtimeSubscription is a no-op for it anyway.
      _webVisibilityListener = (_) {
        try {
          if (html.document.hidden == true ||
              html.document.visibilityState == 'hidden') {
            lastHiddenAt = DateTime.now();
            return;
          }
          if (lastHiddenAt != null &&
              DateTime.now().difference(lastHiddenAt!) <
                  const Duration(seconds: 10)) {
            lastHiddenAt = null;
            return;
          }
          lastHiddenAt = null;
          if (html.document.visibilityState == 'visible' &&
              html.document.hidden != true) {
            // Tab became visible - re-establish subscriptions
            unawaited(_setupRealtimeSubscription());
          }
        } catch (_) {}
      };
      html.document.addEventListener(
        'visibilitychange',
        _webVisibilityListener,
      );
    } catch (_) {}
  }

  void _detachWebVisibilityListener() {
    if (!kIsWeb || _webVisibilityListener == null) return;
    try {
      html.document.removeEventListener(
        'visibilitychange',
        _webVisibilityListener,
      );
      _webVisibilityListener = null;
    } catch (_) {}
  }
}

/// Provider for match notifications
final matchNotificationProvider =
    NotifierProvider<MatchNotificationNotifier, MatchNotificationState>(() {
      return MatchNotificationNotifier();
    });

/// Provider for unread match count (convenience)
final unreadMatchCountProvider = Provider<int>((ref) {
  return ref.watch(matchNotificationProvider).unreadCount;
});
