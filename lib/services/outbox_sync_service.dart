// lib/services/outbox_sync_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart'; // <-- 1. IMPORT
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class OutboxSyncService {
  final Ref _ref;
  bool _isSyncing = false;
  StreamSubscription? _outboxSubscription;
  StreamSubscription? _profileOutboxSubscription;
  StreamSubscription? _visibilityOutboxSubscription;
  StreamSubscription? _invisibilityRulesOutboxSubscription;
  StreamSubscription? _profileEditRequestsOutboxSubscription;
  Timer? _retryTimer;

  OutboxSyncService(this._ref) {
    // --- 2. LISTEN TO THE NEW PROVIDER ---
    // We listen to our reliable, app-wide connectivity provider
    _ref.listen(connectivityProvider, (AsyncValue<bool>? previous, AsyncValue<bool> next) {
      final bool isNowOnline = next.value ?? false;
      if (isNowOnline) {
        _trySync(); // Try to sync immediately when connection is restored

        // Also update user activity immediately so other users see them online again
        final user = supabase.auth.currentUser;
        if (user != null) {
          supabase.rpc('update_user_activity', params: {'p_user_id': user.id}).catchError((e) {
            // Ignore errors - activity update is best-effort
          });
        }
      }
    });
    // --- END UPDATE ---

    // Listen to the local outboxes (chat and profile)
    _outboxSubscription = _ref.read(localDbProvider).watchOutbox().listen((messages) {
      _checkAndStartSync();
    });

    // Listen to the profile outbox
    _profileOutboxSubscription = _ref.read(localDbProvider).watchProfileOutbox().listen((updates) {
      if (updates.isNotEmpty) {
        _startRetryTimer(); // Start polling if we have updates
        _trySync();  // Unified sync (handles full_profile_save as well)
      } else {
        _stopRetryTimer();  // Stop polling if outbox is empty
      }
    });

    // Listen to visibility outbox (user_visibility_setting updates)
    _visibilityOutboxSubscription = _ref.read(localDbProvider).watchVisibilityOutbox().listen((_) {
      _checkAndStartSync();
    });

    // Listen to invisibility rules outbox (user_invisibility_rules updates)
    _invisibilityRulesOutboxSubscription = _ref.read(localDbProvider).watchInvisibilityRulesOutbox().listen((_) {
      _checkAndStartSync();
    });

    // Listen to profile edit requests outbox
    _profileEditRequestsOutboxSubscription = _ref.read(localDbProvider).watchOutbox().listen((outbox) {
      // Filter for profile_edit_requests type
      final hasProfileEditRequests = outbox.values.any((value) {
        try {
          final data = jsonDecode(value) as Map<String, dynamic>;
          return data['type'] == 'profile_edit_requests';
        } catch (_) {
          return false;
        }
      });
      if (hasProfileEditRequests) {
        _checkAndStartSync();
      }
    });

    // Check initial connection status
    _trySync();
  }

  void _startRetryTimer() {
    if (_retryTimer != null && _retryTimer!.isActive) return;
    _retryTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _trySync();
    });
  }

  void _checkAndStartSync() async {
    final localDb = _ref.read(localDbProvider);
    final chatOutbox = await localDb.watchOutbox().first;
    final profileOutbox = await localDb.watchProfileOutbox().first;
    final visibilityOutbox = await localDb.watchVisibilityOutbox().first;
    final rulesOutbox = await localDb.watchInvisibilityRulesOutbox().first;

    final hasMessages =
        chatOutbox.isNotEmpty ||
        profileOutbox.isNotEmpty ||
        visibilityOutbox.isNotEmpty ||
        rulesOutbox.isNotEmpty;

    if (hasMessages) {
      _startRetryTimer(); // Start polling if we have messages
      _trySync();         // And try an initial sync
    } else {
      _stopRetryTimer();  // Stop polling if outboxes are empty
    }
  }

  void _stopRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _trySync() async {
    if (_isSyncing) {
      return;
    }

    // Check both chat and profile outboxes
    final localDb = _ref.read(localDbProvider);
    final chatOutboxStream = await localDb.watchOutbox().first;
    final profileOutboxStream = await localDb.watchProfileOutbox().first;
    final visibilityOutboxStream = await localDb.watchVisibilityOutbox().first;
    final rulesOutboxStream = await localDb.watchInvisibilityRulesOutbox().first;

    final hasChatMessages = chatOutboxStream.isNotEmpty;
    final hasProfileUpdates = profileOutboxStream.isNotEmpty;
    final hasVisibilityUpdates = visibilityOutboxStream.isNotEmpty;
    final hasRulesUpdates = rulesOutboxStream.isNotEmpty;

    // Check for profile edit requests in the general outbox
    final hasProfileEditRequests = chatOutboxStream.values.any((value) {
      try {
        final data = jsonDecode(value) as Map<String, dynamic>;
        return data['type'] == 'profile_edit_requests';
      } catch (_) {
        return false;
      }
    });

    if (!hasChatMessages && !hasProfileUpdates && !hasVisibilityUpdates && !hasRulesUpdates && !hasProfileEditRequests) {
      _stopRetryTimer();
      return;
    }

    // 3. Check connectivity using the provider's *current* value
    final isNowOnline = _ref.read(connectivityProvider).value ?? false;

    if (!isNowOnline) {
      _startRetryTimer(); // Ensure timer is running
      return;
    }

    _isSyncing = true;

    // First sync chat messages
    if (hasChatMessages) {
      final chatKeys = List.from(chatOutboxStream.keys);
      for (var key in chatKeys) {
        final messageString = chatOutboxStream[key];
        if (messageString == null) continue;

        try {
          final messagePayload = jsonDecode(messageString) as Map<String, dynamic>;

          await supabase.from('chat_messages').insert({
            'match_id': messagePayload['match_id'],
            'sender_id': messagePayload['sender_id'],
            'content_original': messagePayload['content_original'],
          });

          await localDb.removeMessageFromOutbox(key);

          // Manually trigger a refresh for the chat provider.
          final matchId = messagePayload['match_id'];
          _ref.read(chatSyncProvider(matchId)).syncMessages(matchId);

        } catch (e) {
          _startRetryTimer(); // Start timer on error
          break;
        }
      }
    }

    // Then sync profile updates
    if (hasProfileUpdates) {
      final profileKeys = List.from(profileOutboxStream.keys);
      for (var key in profileKeys) {
        final updateString = profileOutboxStream[key];
        if (updateString == null) continue;

        try {
          final updatePayload = jsonDecode(updateString) as Map<String, dynamic>;
          final userId = updatePayload['userId'] as String;
          final type = (updatePayload['type'] ?? '').toString();

          if (type == 'full_profile_save') {
            // Full profile save: users table + user_profiles upserts (+ deletions computed at sync time)
            final updates = (updatePayload['updates'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
            final profilesToUpsert = (updatePayload['profilesToUpsert'] as List?)
                    ?.cast<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                <Map<String, dynamic>>[];

            final activeModes = (updatePayload['activeModes'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                <String>[];

            if (updates.isNotEmpty) {
              await supabase.from('users').update(updates).eq('id', userId);
            }

            // Compute deletions against server state now that we're online.
            final existingProfilesData =
                await supabase.from('user_profiles').select('intent_type').eq('user_id', userId);
            final existingIntentTypes = (existingProfilesData as List<dynamic>)
                .map((p) => p['intent_type'] as String)
                .toSet();
            final activeNormalized = activeModes.map((m) => m.trim().toLowerCase()).toSet();
            final intentsToDelete = <String>[];
            for (final existing in existingIntentTypes) {
              if (!activeNormalized.contains(existing.trim().toLowerCase())) {
                intentsToDelete.add(existing);
              }
            }

            if (profilesToUpsert.isNotEmpty) {
              try {
                await supabase.from('user_profiles').upsert(profilesToUpsert, onConflict: 'user_id,intent_type');
              } on PostgrestException catch (e) {
                final msg = e.message.toLowerCase();
                if (msg.contains('pkey') ||
                    msg.contains('primary key') ||
                    msg.contains('no unique or exclusion constraint')) {
                  await supabase.from('user_profiles').delete().eq('user_id', userId);
                  await supabase.from('user_profiles').insert(profilesToUpsert);
                } else {
                  rethrow;
                }
              }
            }

            if (intentsToDelete.isNotEmpty) {
              await supabase
                  .from('user_profiles')
                  .delete()
                  .eq('user_id', userId)
                  .inFilter('intent_type', intentsToDelete);
            }
          } else {
            // Default: simple users-table update payload
            final updates = updatePayload['updates'] as Map<String, dynamic>;
            await supabase.from('users').update(updates).eq('id', userId);
          }

          await localDb.removeProfileUpdateFromOutbox(key);

          // Trigger profile sync to ensure local cache is updated
          _ref.read(profileSyncProvider).syncProfile(userId);

        } catch (e) {
          _startRetryTimer(); // Start timer on error
          break;
        }
      }
    }

    // Then sync visibility updates
    if (hasVisibilityUpdates) {
      final visKeys = List.from(visibilityOutboxStream.keys);
      for (final key in visKeys) {
        final payloadStr = visibilityOutboxStream[key];
        if (payloadStr == null) continue;
        try {
          final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
          final userId = (payload['userId'] ?? payload['user_id'] ?? '').toString();
          final isVisible = payload['isVisible'] == true;
          if (userId.isEmpty) continue;
          await supabase.from('users').update({'user_visibility_setting': isVisible}).eq('id', userId);
          await localDb.removeVisibilityUpdateFromOutbox(key);
        } catch (e) {
          _startRetryTimer();
          break;
        }
      }
    }

    // Finally sync invisibility rules updates
    if (hasRulesUpdates) {
      final ruleKeys = List.from(rulesOutboxStream.keys);
      for (final key in ruleKeys) {
        final payloadStr = rulesOutboxStream[key];
        if (payloadStr == null) continue;
        try {
          final payload = jsonDecode(payloadStr) as Map<String, dynamic>;
          final userId = (payload['userId'] ?? payload['user_id'] ?? '').toString();
          final rulesData = (payload['rulesData'] ?? payload['rules_data'] ?? '').toString();
          if (userId.isEmpty || rulesData.isEmpty) continue;
          await supabase.from('user_invisibility_rules').upsert(
            {'user_id': userId, 'rules_data': rulesData},
            onConflict: 'user_id',
          );
          await localDb.removeInvisibilityRulesUpdateFromOutbox(key);
        } catch (e) {
          _startRetryTimer();
          break;
        }
      }
    }

    // Finally sync profile edit requests
    if (hasProfileEditRequests) {
      final requestKeys = chatOutboxStream.keys.where((key) {
        try {
          final value = chatOutboxStream[key];
          if (value == null) return false;
          final data = jsonDecode(value) as Map<String, dynamic>;
          return data['type'] == 'profile_edit_requests';
        } catch (_) {
          return false;
        }
      }).toList();

      for (final key in requestKeys) {
        final payloadStr = chatOutboxStream[key];
        if (payloadStr == null) continue;
        try {
          final requestData = jsonDecode(payloadStr) as Map<String, dynamic>;
          // Remove the type field as it's not needed for the database
          final dbData = Map<String, dynamic>.from(requestData)..remove('type');
          await supabase.from('profile_edit_requests').insert(dbData);
          await localDb.removeMessageFromOutbox(key);
        } catch (e) {
          _startRetryTimer();
          break;
        }
      }
    }

    _isSyncing = false;
  }

  void dispose() {
    _outboxSubscription?.cancel();
    _profileOutboxSubscription?.cancel();
    _visibilityOutboxSubscription?.cancel();
    _invisibilityRulesOutboxSubscription?.cancel();
    _profileEditRequestsOutboxSubscription?.cancel();
    _retryTimer?.cancel();
  }
}

// Provider to "boot" the service
final outboxSyncProvider = Provider<OutboxSyncService>((ref) {
  final service = OutboxSyncService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
