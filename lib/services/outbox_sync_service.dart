// lib/services/outbox_sync_service.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/chat_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart'; // <-- 1. IMPORT
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:flutter/foundation.dart';

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

  bool _isPermanentBioDuplicateError(Object error) {
    return error is PostgrestException &&
        error.message.toLowerCase().contains('bio_already_in_use');
  }

  OutboxSyncService(this._ref) {
    // --- 2. LISTEN TO THE NEW PROVIDER ---
    // We listen to our reliable, app-wide connectivity provider
    _ref.listen(connectivityProvider, (
      AsyncValue<bool>? previous,
      AsyncValue<bool> next,
    ) {
      final bool isNowOnline = next.value ?? false;
      if (isNowOnline) {
        _trySync(); // Try to sync immediately when connection is restored

        // Also update user activity immediately so other users see them online again
        final user = supabase.auth.currentUser;
        // DEBUG: Log auth state before RPC call
        final session = supabase.auth.currentSession;
        final tokenPresent = session != null && session.accessToken.isNotEmpty;
        debugPrint('🔐 [OUTBOX] Before RPC - token: $tokenPresent');
        if (user != null && !shouldSkipSupabaseCalls()) {
          UserActivityService.instance.pingIfDue(
            user.id,
            force: true,
            source: 'outbox-sync',
          );
        }
      }
    });
    // --- END UPDATE ---

    // Listen to the local outboxes (chat and profile)
    _outboxSubscription = _ref.read(localDbProvider).watchOutbox().listen((
      messages,
    ) {
      _checkAndStartSync();
    });

    // Listen to the profile outbox
    _profileOutboxSubscription = _ref
        .read(localDbProvider)
        .watchProfileOutbox()
        .listen((updates) {
          if (updates.isNotEmpty) {
            _startRetryTimer(); // Start polling if we have updates
            _trySync(); // Unified sync (handles full_profile_save as well)
          } else {
            _stopRetryTimer(); // Stop polling if outbox is empty
          }
        });

    // Listen to visibility outbox (user_visibility_setting updates)
    _visibilityOutboxSubscription = _ref
        .read(localDbProvider)
        .watchVisibilityOutbox()
        .listen((_) {
          _checkAndStartSync();
        });

    // Listen to invisibility rules outbox (user_invisibility_rules updates)
    _invisibilityRulesOutboxSubscription = _ref
        .read(localDbProvider)
        .watchInvisibilityRulesOutbox()
        .listen((_) {
          _checkAndStartSync();
        });

    // Listen to profile edit requests outbox
    _profileEditRequestsOutboxSubscription = _ref
        .read(localDbProvider)
        .watchOutbox()
        .listen((outbox) {
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
    _loadRetryIntervalAndStart();
  }

  Future<void> _loadRetryIntervalAndStart() async {
    try {
      final interval = await appConfigService.getDuration(
        'sync.outbox_retry_interval_seconds',
        defaultValue: const Duration(seconds: 5),
      );
      _retryTimer = Timer.periodic(interval, (timer) {
        _trySync();
      });
    } catch (e) {
      _retryTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
        _trySync();
      });
    }
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
      _trySync(); // And try an initial sync
    } else {
      _stopRetryTimer(); // Stop polling if outboxes are empty
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
    _isSyncing = true;

    try {
      // Check both chat and profile outboxes
      final localDb = _ref.read(localDbProvider);
      final chatOutboxStream = await localDb.watchOutbox().first;
      final profileOutboxStream = await localDb.watchProfileOutbox().first;
      final visibilityOutboxStream = await localDb
          .watchVisibilityOutbox()
          .first;
      final rulesOutboxStream = await localDb
          .watchInvisibilityRulesOutbox()
          .first;

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

      if (!hasChatMessages &&
          !hasProfileUpdates &&
          !hasVisibilityUpdates &&
          !hasRulesUpdates &&
          !hasProfileEditRequests) {
        _stopRetryTimer();
        return;
      }

      // 3. Check connectivity using the provider's *current* value
      final isNowOnline = _ref.read(connectivityProvider).value ?? false;

      if (!isNowOnline) {
        _startRetryTimer(); // Ensure timer is running
        return;
      }

      final session = supabase.auth.currentSession;
      final user = supabase.auth.currentUser;
      if (session == null || user == null) {
        // Don't attempt to sync if not logged in
        _stopRetryTimer();
        return;
      }

      // Check if session is expired — attempt one refresh before giving
      // up. Previously this skipped forever until restart, leaving the
      // outbox stuck after a normal expiry even when refresh would succeed.
      final expiresAt = session.expiresAt;
      if (expiresAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch / 1000;
        if (expiresAt <= now) {
          try {
            final refreshed = await SessionService.safeRefreshSession().timeout(
              const Duration(seconds: 3),
            );
            if (!refreshed || supabase.auth.currentSession == null) {
              print('[OUTBOX] Skipping sync - session expired');
              _stopRetryTimer();
              return;
            }
          } catch (e) {
            if (isExpectedOfflineFailure(e) || e is TimeoutException) {
              _startRetryTimer();
              return;
            }
            // Dead refresh token / auth rejection: keep timer stopped until
            // next outbox/connectivity event to avoid hot-looping Supabase.
            if (!isAuthRateLimitFailure(e)) {
              print('[OUTBOX] Skipping sync - session refresh failed: $e');
            }
            _stopRetryTimer();
            return;
          }
        }
      }

      // First sync chat messages
      if (hasChatMessages) {
        final chatKeys = List.from(chatOutboxStream.keys);
        final currentUserId = user.id;

        for (var key in chatKeys) {
          final messageString = chatOutboxStream[key];
          if (messageString == null) continue;

          try {
            final messagePayload =
                jsonDecode(messageString) as Map<String, dynamic>;

            // CRITICAL: Verify the sender_id matches the current authenticated user.
            // If it doesn't, this message belongs to a previous session/user and should not be synced.
            if (messagePayload['sender_id'] != currentUserId) {
              debugPrint(
                '[OUTBOX] Removing stale message from outbox (sender_id mismatch)',
              );
              await localDb.removeMessageFromOutbox(key);
              continue;
            }

            final matchId = messagePayload['match_id'];
            final messageType = (messagePayload['type'] ?? '').toString();
            debugPrint(
              '[OUTBOX] Attempting to sync message $key for match $matchId (type=$messageType)',
            );

            // ── Pending-encryption path ─────────────────────────────────
            // Messages queued while the device was offline are stored as
            // plaintext. When connectivity comes back we encrypt them now
            // (so we never persist plaintext to the server) and then push
            // the encrypted row to Supabase.
            Map<String, dynamic> payloadForSupabase = messagePayload;
            if (messageType == 'chat_message_pending_encryption') {
              final text = messagePayload['text'] as String?;
              final msgId = messagePayload['id'] as String?;
              if (text == null || msgId == null) {
                print(
                  '[OUTBOX] Pending-encryption payload missing text/id, removing: $key',
                );
                await localDb.removeMessageFromOutbox(key);
                continue;
              }
              try {
                final chatService = _ref.read(chatServiceProvider);
                final encryption = await chatService.encryptMessageContent(
                  text: text,
                  matchId: matchId as String,
                  messageId: msgId,
                  user: user,
                );
                if (encryption == null) {
                  // Encryption is still not possible (e.g. recipient has no
                  // active key yet, or the user's own keys are not loaded).
                  // Keep the message in the outbox and try again later.
                  print(
                    '[OUTBOX] Pending-encryption: encryption not available for $key, will retry.',
                  );
                  _startRetryTimer();
                  break;
                }
                // Build a regular supabase-shaped payload from the
                // encrypted fields, preserving the original id/text metadata
                // we already have.
                payloadForSupabase = <String, dynamic>{
                  ...messagePayload,
                  ...encryption,
                  // Strip the offline-only fields so they aren't sent.
                  'text': null,
                  'type': null,
                  'queued_at': null,
                };
              } catch (e) {
                print(
                  '[OUTBOX] Pending-encryption: error encrypting $key: $e. Will retry.',
                );
                _startRetryTimer();
                break;
              }
            }

            // Only insert columns that exist in the current `chat_messages` schema.
            final insertPayload = <String, dynamic>{
              if (payloadForSupabase['id'] != null)
                'id': payloadForSupabase['id'],
              'match_id': matchId,
              'sender_id': payloadForSupabase['sender_id'],
              if (payloadForSupabase['recipient_id'] != null)
                'recipient_id': payloadForSupabase['recipient_id'],
              'encryption_scheme':
                  payloadForSupabase['encryption_scheme'] ?? 'v1',
              if (payloadForSupabase['sender_key_id'] != null)
                'sender_key_id': payloadForSupabase['sender_key_id'],
              if (payloadForSupabase['recipient_key_id'] != null)
                'recipient_key_id': payloadForSupabase['recipient_key_id'],
              if (payloadForSupabase['content_original_encrypted'] != null)
                'content_original_encrypted':
                    payloadForSupabase['content_original_encrypted'],
              if (payloadForSupabase['content_original_nonce'] != null)
                'content_original_nonce':
                    payloadForSupabase['content_original_nonce'],
              if (payloadForSupabase['content_translated_encrypted'] != null)
                'content_translated_encrypted':
                    payloadForSupabase['content_translated_encrypted'],
              if (payloadForSupabase['content_translated_nonce'] != null)
                'content_translated_nonce':
                    payloadForSupabase['content_translated_nonce'],
              'wrapped_keys':
                  payloadForSupabase['wrapped_keys'] ?? <String, dynamic>{},
              if (payloadForSupabase['reply_to_message_id'] != null)
                'reply_to_message_id':
                    payloadForSupabase['reply_to_message_id'],
              if (payloadForSupabase['detected_source_language'] != null)
                'detected_source_language':
                    payloadForSupabase['detected_source_language'],
              if (payloadForSupabase['translated_target_language'] != null)
                'translated_target_language':
                    payloadForSupabase['translated_target_language'],
            };

            final response = await supabase
                .from('chat_messages')
                .insert(insertPayload)
                .select();
            print(
              '[OUTBOX] ✅ Sync successful for message $key (DB id: ${response.isNotEmpty ? response[0]['id'] : 'unknown'})',
            );

            await localDb.removeMessageFromOutbox(key);

            // Manually trigger a refresh for the chat provider.
            if (matchId != null) {
              _ref.read(chatSyncProvider(matchId)).syncMessages(matchId);
            }
          } on PostgrestException catch (e) {
            final isPermanent =
                e.code == '42501' || // RLS violation
                e.code == '42P01' || // Table not found
                e.code == '23503' || // Foreign key violation
                e.code ==
                    '23505' || // Duplicate key — message already in DB, remove from outbox
                e.message.contains('403') ||
                e.message.contains('Forbidden');

            if (isPermanent) {
              print(
                '[OUTBOX] Permanent error syncing message $key (code=${e.code}): ${e.message}. Removing from outbox.',
              );
              await localDb.removeMessageFromOutbox(key);
            } else {
              print(
                '[OUTBOX] Temporary error syncing message $key (code=${e.code}): ${e.message}. Will retry.',
              );
              _startRetryTimer();
              break;
            }
          } catch (e) {
            print(
              '[OUTBOX] Unexpected error syncing message $key: $e. Will retry.',
            );
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
            final updatePayload =
                jsonDecode(updateString) as Map<String, dynamic>;
            final userId = updatePayload['userId'] as String;
            final type = (updatePayload['type'] ?? '').toString();

            if (type == 'full_profile_save') {
              final updates =
                  (updatePayload['updates'] as Map?)?.cast<String, dynamic>() ??
                  <String, dynamic>{};
              final profilePayload = (updatePayload['profilePayload'] as Map?)
                  ?.cast<String, dynamic>();

              if (updates.isNotEmpty) {
                await supabase.from('users').update(updates).eq('id', userId);
              }

              if (profilePayload != null && profilePayload.isNotEmpty) {
                try {
                  await supabase
                      .from('user_profiles')
                      .upsert(profilePayload, onConflict: 'user_id');
                } on PostgrestException catch (e) {
                  final msg = e.message.toLowerCase();
                  if (msg.contains('pkey') ||
                      msg.contains('primary key') ||
                      msg.contains('no unique or exclusion constraint')) {
                    await supabase
                        .from('user_profiles')
                        .delete()
                        .eq('user_id', userId);
                    await supabase.from('user_profiles').insert(profilePayload);
                  } else {
                    rethrow;
                  }
                }
              }
            } else if (type == 'profile_update') {
              // Wizard answers that live only in user_profiles (religion,
              // lifestyle, family) must not be replayed against the users
              // table: those columns no longer exist there, so the update
              // would fail forever and the local value would later be
              // overwritten by the next server sync.
              final profilePayload = (updatePayload['profilePayload'] as Map?)
                  ?.cast<String, dynamic>();
              if (profilePayload != null && profilePayload.isNotEmpty) {
                await supabase
                    .from('user_profiles')
                    .upsert(profilePayload, onConflict: 'user_id');
              }
            } else {
              // Default: simple users-table update payload
              final updates = updatePayload['updates'] as Map<String, dynamic>;
              await supabase.from('users').update(updates).eq('id', userId);
            }

            await localDb.removeProfileUpdateFromOutbox(key);

            // Trigger profile sync to ensure local cache is updated
            _ref
                .read(profileSyncProvider)
                .syncProfile(userId, source: 'profile-outbox-sync');
          } catch (e) {
            if (_isPermanentBioDuplicateError(e)) {
              try {
                final payload =
                    jsonDecode(updateString) as Map<String, dynamic>;
                final userId = (payload['userId'] ?? payload['user_id'] ?? '')
                    .toString();
                await localDb.removeProfileUpdateFromOutbox(key);
                if (userId.isNotEmpty) {
                  _ref
                      .read(profileSyncProvider)
                      .syncProfile(userId, source: 'profile-outbox-sync');
                }
                continue;
              } catch (_) {}
            }
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
            final userId = (payload['userId'] ?? payload['user_id'] ?? '')
                .toString();
            final isVisible = payload['isVisible'] == true;
            if (userId.isEmpty) continue;

            // Update users table
            await supabase
                .from('users')
                .update({'user_visibility_setting': isVisible})
                .eq('id', userId);

            // Update visibility in user_activity
            if (!shouldSkipSupabaseCalls()) {
              await supabase.rpc(
                'update_user_visibility',
                params: {'p_user_id': userId},
              );
            }

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
            final userId = (payload['userId'] ?? payload['user_id'] ?? '')
                .toString();
            final rulesData =
                (payload['rulesData'] ?? payload['rules_data'] ?? '')
                    .toString();
            if (userId.isEmpty || rulesData.isEmpty) continue;
            await supabase.from('user_invisibility_rules').upsert({
              'user_id': userId,
              'rules_data': rulesData,
            }, onConflict: 'user_id');
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
            final dbData = Map<String, dynamic>.from(requestData)
              ..remove('type');
            await supabase.from('profile_edit_requests').insert(dbData);
            await localDb.removeMessageFromOutbox(key);
          } catch (e) {
            if (e.toString().contains('profile_edit_request_already_pending')) {
              await localDb.removeMessageFromOutbox(key);
              continue;
            }
            _startRetryTimer();
            break;
          }
        }
      }
    } finally {
      _isSyncing = false;
    }
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
