// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/web_imports.dart' as html;

final supabase = Supabase.instance.client;
final uuid = Uuid();

// Helper function to format sender name: "FirstName LastInitial." e.g., "John S."
String formatSenderNameForNotification(String fullName) {
  if (fullName.isEmpty) return 'MatchMe';

  final parts = fullName.trim().split(RegExp(r'\s+'));
  if (parts.length == 1) {
    return parts[0]; // Just first name if no last name
  }

  // First name + first letter of last name with period
  final firstName = parts[0];
  final lastInitial = parts[parts.length - 1][0].toUpperCase();
  return '$firstName $lastInitial.';
}

// Debouncer for reaction updates to prevent rapid clicks
final Map<String, Timer> _reactionDebouncer = {};

// --- ChatSyncService (Modified to take localDb as parameter) ---
class ChatSyncService {
  final LocalDbService localDb;
  ChatSyncService(this.localDb);

  Future<void> syncMessages(String matchId) async {
    if (matchId.isEmpty) return;
    try {
      debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
      debugPrint('ðŸ”„ SYNC START: syncMessages called for matchId=$matchId');
      debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
      
      final data = await supabase
          .from('chat_messages')
          .select('id, match_id, sender_id, content_original, content_translated, detected_source_language, translated_target_language, created_at, edited_at, delivered_at, read_at, reply_to_message_id')
          .eq('match_id', matchId)
          .order('created_at', ascending: true);
      
      debugPrint('ðŸ”„ SYNC: Retrieved ${data.length} messages from Supabase');
      for (final msg in data) {
        debugPrint('   - Message ${msg['id']}: delivered_at=${msg['delivered_at']}, sender=${msg['sender_id']}');
      }
      
      // Replace all messages for this match with the current database state
      // This ensures deleted messages are removed from local cache
      await localDb.saveMessages(matchId, data.cast<Map<String, dynamic>>());
      
      debugPrint('ðŸ”„ SYNC: Saved ${data.length} messages to local database');
      
      // Mark undelivered messages from the other user as delivered
      // (This user just received them by syncing)
      final currentUserId = supabase.auth.currentUser?.id;
      debugPrint('ðŸ”„ SYNC: currentUserId=$currentUserId');
      
      if (currentUserId != null && data.isNotEmpty) {
        // Collect message IDs that need to be marked as delivered
        final messagesToDeliver = <String>[];
        
        for (final msg in data as List) {
          final msgId = msg['id'] as String?;
          final senderId = msg['sender_id'] as String?;
          final deliveredAt = msg['delivered_at'];
          
          debugPrint('ðŸ”„ SYNC: Checking msg=$msgId (sender=$senderId, delivered=$deliveredAt, isOtherUser=${senderId != currentUserId})');
          
          // If this message is from the other user and not yet delivered, mark it
          if (senderId != null && senderId != currentUserId && (deliveredAt == null || deliveredAt == '')) {
            messagesToDeliver.add(msgId ?? '');
            debugPrint('ðŸ”„ SYNC: âž• Added $msgId to delivery list (from other user, not yet delivered)');
          } else {
            final reason = senderId == currentUserId ? 'from this user' : 'already delivered';
            debugPrint('ðŸ”„ SYNC: â­ï¸  Skipped $msgId ($reason)');
          }
        }
        
        // Batch mark messages as delivered with better error handling
        if (messagesToDeliver.isNotEmpty) {
          debugPrint('ðŸ”„ SYNC: Marking ${messagesToDeliver.length} messages as delivered');
          
          try {
            final results = await Future.wait(
              messagesToDeliver.map((msgId) {
                debugPrint('ðŸ”„ SYNC: Calling RPC mark_message_delivered for $msgId...');
                return supabase.rpc('mark_message_delivered', params: {'p_message_id': msgId})
                  .then((result) {
                    debugPrint('âœ… SYNC: RPC succeeded for $msgId - result=$result');
                    return true;
                  })
                  .catchError((e, st) {
                    debugPrint('âŒ SYNC: RPC FAILED for $msgId');
                    debugPrint('   Error: $e');
                    debugPrint('   Stack: $st');
                    return false;
                  });
              }),
              eagerError: false,
            );
            
            final successCount = results.where((r) => r == true).length;
            debugPrint('ðŸ”„ SYNC: Successfully marked $successCount/${messagesToDeliver.length} messages as delivered');
          } catch (e, st) {
            debugPrint('ðŸ”„ SYNC: Error in batch delivery marking: $e\n$st');
            // Don't throw - marking as delivered is non-critical
          }
        } else {
          debugPrint('ðŸ”„ SYNC: No messages to deliver (either no undelivered messages or no current user)');
        }
      }
    } catch (e, st) {
      debugPrint('âŒ SYNC ERROR: $e\n$st');
      // Keep the error surfaced but avoid noisy logging here.
    }
    debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
    debugPrint('ðŸ”„ SYNC END: syncMessages completed');
    debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
  }

  // Diagnostic function to test if RPC function is working
  Future<void> testRpcFunction(String testMessageId) async {
    try {
      debugPrint('ðŸ§ª TEST: Testing RPC mark_message_delivered with messageId=$testMessageId');
      debugPrint('ðŸ§ª TEST: Current user: ${supabase.auth.currentUser?.id}');
      
      final result = await supabase.rpc('mark_message_delivered', params: {'p_message_id': testMessageId});
      
      debugPrint('âœ… TEST: RPC call succeeded! Result: $result');
      debugPrint('ðŸ§ª TEST: Check Supabase to see if delivered_at was updated for this message');
    } catch (e, st) {
      debugPrint('âŒ TEST: RPC call FAILED!');
      debugPrint('   Error: $e');
      debugPrint('   Type: ${e.runtimeType}');
      debugPrint('   Stack: $st');
      
      // Try to extract more details
      if (e is PostgrestException) {
        debugPrint('   PostgrestException details:');
        debugPrint('   - Code: ${e.code}');
        debugPrint('   - Message: ${e.message}');
        debugPrint('   - Details: ${e.details}');
      }
    }
  }

}

final chatSyncProvider = Provider.family<ChatSyncService, String>(
  (ref, matchId) => ChatSyncService(ref.read(localDbProvider)),
);

// --- UPDATED: chatMessagesProvider (Fixes bugs & uses local DB + realtime)
// Emits a stream of ChatMessageModel lists for a given matchId.
final chatMessagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessageModel>, String>((ref, matchId) {

  try {
    if (matchId.isEmpty) return Stream.value([]);

    final localDb = ref.watch(localDbProvider);
    final localStream = localDb.watchMessages(matchId);

    final StreamController<List<ChatMessageModel>> streamController = StreamController<List<ChatMessageModel>>.broadcast();
    bool disposed = false;
    bool scheduledInitialSync = false;
    Timer? realtimeSyncDebounce;
    Timer? reconnectTimer;


      // Use syncService for an initial full sync once we subscribe
    ChatSyncService? syncService;
    try {
      syncService = ref.read(chatSyncProvider(matchId));
    } catch (e, st) {
      debugPrint('chatSyncProvider init failed for $matchId: $e\n$st');
      syncService = null; // don't fail the provider; fall back to local-only
    }

    final channel = (() {
      try {
        return supabase.channel('public:chat_messages:match_id=eq.$matchId');
      } catch (e, st) {
        debugPrint('Failed to create supabase channel for $matchId: $e\n$st');
        return null;
      }
    })();

// Always emit local cached messages immediately (offline-first).
    final localSubscription = localStream.listen((messagesData) {
      if (disposed || streamController.isClosed) return;
      try {
        // Normalize incoming local cache items to guard against inconsistent types (web IndexedDB variations).
        final normalized = messagesData.map((json) {
          try {
            // Ensure keys are strings and critical IDs are strings
            if (json.containsKey('sender_id') && json['sender_id'] != null && json['sender_id'] is! String) {
              json['sender_id'] = json['sender_id'].toString();
            }
            if (json.containsKey('match_id') && json['match_id'] != null && json['match_id'] is! String) {
              json['match_id'] = json['match_id'].toString();
            }
            if (json.containsKey('id') && json['id'] != null && json['id'] is! String) {
              json['id'] = json['id'].toString();
            }
            // Ensure reaction_summary is a Map if present; otherwise coerce to empty map
            if (json.containsKey('reaction_summary') && json['reaction_summary'] is! Map) {
              json['reaction_summary'] = <String, int>{};
            }
          } catch (_) {}
          return json;
        }).toList();

        final models = normalized.map((json) => ChatMessageModel.fromJson(json)).toList();
        final byId = <String, ChatMessageModel>{};
        for (final m in models) {
          byId[m.id] = m;
        }
        final resolved = models.map((m) {
          final replyId = m.replyToMessageId;
          if (replyId == null) return m;
          final original = byId[replyId];
          if (original == null) return m;
          return m.copyWith(
            replyToSenderId: original.senderId,
            replyToContent: original.contentOriginal,
          );
        }).toList();

        streamController.add(resolved);

        // If there are no messages locally and we haven't scheduled an initial recovery sync,
        // schedule a few background sync attempts to cover intermittent failures (e.g., slow IndexedDB).
        if ((messagesData.isEmpty) && !scheduledInitialSync && syncService != null) {
          scheduledInitialSync = true;
          Future(() async {
            debugPrint('chatMessagesProvider: initial empty local cache for $matchId; scheduling recovery sync attempts');
            final delays = [const Duration(seconds: 1), const Duration(seconds: 2), const Duration(seconds: 4)];
            for (var i = 0; i < delays.length; i++) {
              try {
                await Future.delayed(delays[i]);
                debugPrint('chatMessagesProvider: recovery sync attempt #${i + 1} for $matchId');
                await syncService!.syncMessages(matchId);
                debugPrint('chatMessagesProvider: recovery sync successful for $matchId on attempt #${i + 1}');
                break;
              } catch (e, st) {
                debugPrint('chatMessagesProvider: recovery sync attempt #${i + 1} failed for $matchId: $e\n$st');
              }
            }
          });
        }
      } catch (e, st) {
        // Log parsing errors so we can see why the stream isn't emitting
        try {
          debugPrint('chatMessagesProvider: failed to parse local messages for $matchId: $e\n$st');
          if (messagesData.isNotEmpty) {
            debugPrint('chatMessagesProvider: sample problematic message: ${messagesData.first}');
          }
        } catch (_) {}
      }
    });

  Future<void> handleChanges(PostgresChangePayload payload) async {
    if (disposed || !ref.mounted || syncService == null) {
      return;
    }
    final event = payload.eventType;
    if (event != PostgresChangeEvent.insert &&
        event != PostgresChangeEvent.update &&
        event != PostgresChangeEvent.delete) {
      return;
    }
    realtimeSyncDebounce?.cancel();
    realtimeSyncDebounce = Timer(const Duration(milliseconds: 120), () async {
      if (disposed || !ref.mounted || syncService == null) {
        return;
      }
      try {
        await syncService.syncMessages(matchId);
      } catch (e) {
        debugPrint('Error syncing messages on realtime change for $matchId: $e');
      }
    });
  }

  bool shouldSkipReconnect() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final isBackground = lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached;
    if (isBackground) return true;
    if (!kIsWeb) return false;
    try {
      return html.document.hidden == true ||
          html.document.visibilityState == 'hidden';
    } catch (_) {
      return false;
    }
  }

  Future<void> reconnectChannel() async {
    if (disposed || !ref.mounted || shouldSkipReconnect()) {
      return;
    }
    try {
      // ignore: invalid_use_of_internal_member
      supabase.realtime.connect();
    } catch (e) {
      debugPrint('Error reconnecting realtime socket for $matchId: $e');
    }
    try {
      ref.invalidateSelf();
    } catch (e) {
      debugPrint('Error recreating chat subscription for $matchId: $e');
      if (syncService != null) {
        try {
          await syncService.syncMessages(matchId);
        } catch (syncError) {
          debugPrint('Error syncing messages after reconnect failure for $matchId: $syncError');
        }
      }
    }
  }

  if (channel != null) {
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all, // Catches INSERTs, UPDATEs, and DELETEs
      schema: 'public',
      table: 'chat_messages',
      callback: handleChanges,
    ).subscribe((status, err) async {
      if (!ref.mounted || disposed) {
        // Provider no longer active - ignore subscription callbacks
        return;
      }
      if (status == RealtimeSubscribeStatus.subscribed) {
        reconnectTimer?.cancel();
        // Run a full sync ONCE on subscribe, to catch up (guarded)
        try {
          if (syncService != null) await syncService.syncMessages(matchId);
        } catch (e) {
          debugPrint('Error syncing messages on subscribe for $matchId: $e');
        }
      } else if (status == RealtimeSubscribeStatus.closed || status == RealtimeSubscribeStatus.channelError) {
        debugPrint('âš ï¸ Chat messages subscription disconnected for $matchId - status: $status, error: $err');

        if (shouldSkipReconnect()) {
          debugPrint('Skipping auto-reconnect for chat $matchId due to app visibility/lifecycle');
          return;
        }
        reconnectTimer?.cancel();
        reconnectTimer = Timer(const Duration(seconds: 2), () {
          unawaited(reconnectChannel());
        });
      } else if (err != null) {
        debugPrint('Realtime subscription error for $matchId: $err');
      }
    });
  }

  ref.onDispose(() {
    disposed = true;
    realtimeSyncDebounce?.cancel();
    reconnectTimer?.cancel();
    localSubscription.cancel();
    try {
      if (channel != null) supabase.removeChannel(channel);
    } catch (_) {}
    streamController.close();
  });

  return streamController.stream;
  } catch (e, st) {
    debugPrint('chatMessagesProvider failed to initialize for $matchId: $e\n$st');
    return Stream.value(<ChatMessageModel>[]);
  }
});

// --- chatServiceProvider (Unchanged) ---
final chatServiceProvider = Provider((ref) => ChatService(ref));

class ChatService {
  final Ref _ref;
  ChatService(this._ref);

  Future<void> sendMessage({
    required String matchId,
    required String text,
    String? replyToMessageId,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);
    final tempId = uuid.v4();
    final optimisticMessage = ChatMessageModel(
      id: tempId,
      matchId: matchId,
      senderId: user.id,
      contentOriginal: text,
      createdAt: DateTime.now(),
      isPending: true,
      replyToMessageId: replyToMessageId,
    );
    try {
      await localDb.addMessages(matchId, [optimisticMessage.toJson()]);
      // Ignore returned delivery messages since this is our own message
    } catch (e) {
      // Keep higher-level error handling; avoid extra logs here.
    }
    final connectivityResult = await Connectivity().checkConnectivity();
    final isOnline = connectivityResult.any((r) => r != ConnectivityResult.none);
    final supabasePayload = {
      'match_id': matchId,
      'sender_id': user.id,
      'content_original': text,
      ...?(switch (replyToMessageId) {
        final id? => {'reply_to_message_id': id},
        _ => null,
      }),
    };
    if (isOnline) {
      try {
        final data = await supabase
            .from('chat_messages')
            .insert(supabasePayload)
            .select();
        if (data.isEmpty) {
          throw Exception('Invalid response format: expected non-empty List, got ${data.runtimeType}');
        }
        final firstItem = data[0];
        await localDb.replaceMessage(matchId, tempId, firstItem);

        // Immediately invalidate recent chats to update the last message preview
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null) {
          _ref.invalidate(recentChatsProvider(currentUserId));
        }

        try {
          final messageId = (firstItem['id'] as String?)?.trim();
          if (messageId != null && messageId.isNotEmpty) {
            unawaited(() async {
              try {
                await supabase.functions.invoke(
                  'push-message',
                  body: {
                    'message_id': messageId,
                    'match_id': matchId,
                  },
                );
              } catch (_) {
              }
            }());
          }
        } catch (_) {
        }
      } catch (e) {
        await _saveToOutbox(supabasePayload);
      }
    } else {
      await _saveToOutbox(supabasePayload);
    }
  }

  Future<void> _saveToOutbox(Map<String, dynamic> messagePayload) async {
    final localDb = _ref.read(localDbProvider);
    await localDb.saveMessageToOutbox(messagePayload);
  }

  /// Set or clear a reaction for a message. p_reaction==null clears reaction for current user.
  Future<void> setReaction({required String matchId, required String messageId, String? reaction}) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);

    // Debounce rapid clicks
    final key = '$matchId:$messageId';
    _reactionDebouncer[key]?.cancel();
    debugPrint('setReaction: scheduling debounced update for $key (reaction=$reaction)');

    final completer = Completer<void>();
    _reactionDebouncer[key] = Timer(const Duration(milliseconds: 300), () async {
      debugPrint('setReaction: debounced timer fired for $key (reaction=$reaction)');
      try {
        await _performSetReaction(matchId, messageId, reaction, user, localDb);
        completer.complete();
      } catch (e) {
        completer.completeError(e);
      } finally {
        _reactionDebouncer.remove(key);
      }
    });

    return completer.future;
  }

  Future<void> _performSetReaction(String matchId, String messageId, String? reaction, User user, LocalDbService localDb) async {
    // Store original state for rollback
    final originalMessages = await localDb.getMessages(matchId);

    try {
      // Optimistic update
      debugPrint('performSetReaction: starting optimistic update for message $messageId (reaction=$reaction)');
      await _applyOptimisticUpdate(matchId, messageId, reaction, user, localDb);
      debugPrint('performSetReaction: optimistic update applied for message $messageId');

      // Server call
      final payload = {
        'p_message_id': messageId,
        'p_reaction': reaction,
      };
      debugPrint('Calling supabase.rpc set_message_reaction with payload: $payload');

      final res = await supabase.rpc('set_message_reaction', params: payload).single();
      debugPrint('set_message_reaction response: $res');

      // Apply server result (may differ from optimistic)
      final Map<String, dynamic> newSummary = Map<String, dynamic>.from(res as Map);
      debugPrint('Applying new reaction_summary for message $messageId: $newSummary');
      await localDb.mergeMessages(matchId, [{'id': messageId, 'reaction_summary': newSummary, 'my_reaction': reaction}]);
      debugPrint('performSetReaction: merge from server applied for message $messageId');

      // Force provider refresh
      try {
        _ref.invalidate(chatMessagesProvider(matchId));
      } catch (e) {
        // ignore if invalidation fails
      }

      // Refresh per-reaction cached reactors from the server for affected keys so
      // local cache matches the authoritative server state immediately.
      try {
        final keys = <String>{};
        keys.addAll(newSummary.keys.map((k) => k.toString()));

        // Also include the previous my_reaction (if any) to ensure it is updated when clearing.
        final prevMy = originalMessages.firstWhere((m) => m['id']?.toString() == messageId, orElse: () => {})['my_reaction'] as String?;
        if (prevMy != null && prevMy.isNotEmpty) keys.add(prevMy);

        if (keys.isNotEmpty) {
          await _refreshCachedReactors(matchId, messageId, keys, localDb);
        }
      } catch (e) {
        debugPrint('Failed to refresh cached reactors after setReaction: $e');
      }

    } catch (e, st) {
      debugPrint('set_message_reaction failed for message $messageId with error: $e\n$st');
      // Rollback optimistic update
      debugPrint('performSetReaction: rolling back optimistic update for message $messageId');
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      rethrow;
    }
  }

  /// Edit a message. Only the message sender may edit; server-side RPC enforces this.
  Future<void> editMessage({required String matchId, required String messageId, required String newText}) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);
    final currentUserId = user.id;

    // Store original messages for rollback
    final originalMessages = await localDb.getMessages(matchId);

    try {
      // Optimistic update locally
      final nowIso = DateTime.now().toIso8601String();
      await localDb.mergeMessages(matchId, [
        {
          'id': messageId,
          'content_original': newText,
          'edited_at': nowIso,
        }
      ]);
      // Recompute the chat's last message preview since we edited the current last message
      await localDb.recomputeChatLastMessagePreviewFromMessages(currentUserId, matchId);
      // Call server RPC to perform secure edit (enforces sender == auth.uid())
      final payload = {
        'p_message_id': messageId,
        'p_new_content': newText,
      };
      debugPrint('Calling supabase.rpc edit_chat_message with payload: $payload');

      dynamic res;
      try {
        res = await supabase.rpc('edit_chat_message', params: payload).single();
        debugPrint('edit_chat_message response: $res');
      } catch (e, st) {
        debugPrint('edit_chat_message failed for message $messageId with error: $e\n$st');
        // Some deployments may expose the RPC under a different name or signature.
        // Attempt a few fallbacks to maximize compatibility.
        // 1) Try historical name `edit_message` with (p_message_id, p_new_content)
        try {
          debugPrint('Attempting fallback RPC edit_message(p_message_id, p_new_content) for message $messageId');
          res = await supabase.rpc('edit_message', params: payload).single();
          debugPrint('edit_message response: $res');
        } catch (e2, st2) {
          debugPrint('edit_message(p_message_id, p_new_content) failed for message $messageId: $e2\n$st2');
          // 2) Try alternative signature edit_message(p_message_id, p_new_content, p_user_id)
          try {
            final payloadWithUser = Map<String, dynamic>.from(payload);
            payloadWithUser['p_user_id'] = user.id;
            debugPrint('Attempting fallback RPC edit_message(p_message_id, p_new_content, p_user_id) for message $messageId');
            res = await supabase.rpc('edit_message', params: payloadWithUser).single();
            debugPrint('edit_message(p_user_id) response: $res');
          } catch (e3, st3) {
            debugPrint('edit_message with p_user_id failed for message $messageId: $e3\n$st3');
            // 3) Final fallback: attempt direct table update (will be subject to RLS/policies)
            try {
              debugPrint('Attempting direct table UPDATE fallback for message $messageId');
              final nowIsoFinal = DateTime.now().toIso8601String();
              final updateRes = await supabase
                  .from('chat_messages')
                  .update({'content_original': newText, 'edited_at': nowIsoFinal})
                  .eq('id', messageId)
                  .select()
                  .single();
              debugPrint('Direct UPDATE response: $updateRes');
              res = updateRes;
            } catch (e4, st4) {
              debugPrint('Direct UPDATE fallback failed for message $messageId: $e4\n$st4');
              // Exhausted fallbacks
              rethrow;
            }
          }
        }
      }

      // Normalize RPC response to a message row Map. The RPC may return different shapes across deployments
      // (a Map row, a List wrapping a row, or simply `true`/boolean on success). Handle gracefully by
      // fetching the authoritative row when needed.
      Map<String, dynamic> resMap;
      try {
        if (res is Map) {
          resMap = Map<String, dynamic>.from(res);
        } else if (res is List) {
          if (res.isNotEmpty && res[0] is Map) {
            resMap = Map<String, dynamic>.from(res[0]);
          } else {
            debugPrint('RPC returned empty List, fetching row for $messageId');
            final rows = await supabase.from('chat_messages').select().eq('id', messageId).limit(1);
            if (rows.isNotEmpty) {
              resMap = Map<String, dynamic>.from(rows[0]);
            } else {
              throw Exception('RPC returned empty list and failed to find row for $messageId');
            }
          }
        } else if (res is bool && res == true) {
          // Some RPCs simply return true on success; fetch the updated row.
          debugPrint('RPC returned boolean true for edit; fetching authoritative row for $messageId');
          final rows = await supabase.from('chat_messages').select().eq('id', messageId).limit(1);
          if (rows.isNotEmpty) {
            resMap = Map<String, dynamic>.from(rows[0]);
          } else {
            throw Exception('RPC returned success but row not found for $messageId');
          }
        } else {
          throw Exception('Unexpected RPC response type for edit: ${res.runtimeType}');
        }
      } catch (e, st) {
        debugPrint('Failed to normalize RPC response for message $messageId: $e\n$st');
        rethrow;
      }

      await localDb.mergeMessages(matchId, [resMap]);
      // Recompute the chat's last message preview after the server confirms the edit
      await localDb.recomputeChatLastMessagePreviewFromMessages(currentUserId, matchId);
      try {
        _ref.invalidate(chatMessagesProvider(matchId));
        _ref.invalidate(recentChatsProvider(currentUserId));
      } catch (e) {
        debugPrint('Failed to invalidate providers after edit: $e');
      }
    } catch (e, st) {
      debugPrint('edit_chat_message failed for message $messageId with error: $e\n$st');
      // Rollback optimistic update
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      await localDb.recomputeChatLastMessagePreviewFromMessages(currentUserId, matchId);
      rethrow;
    }
  }

  /// Delete a message. The server will enforce permissions via RLS/policies.
  Future<void> deleteMessage({required String matchId, required String messageId}) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);
    final currentUserId = user.id;

    // Store original messages for rollback
    final originalMessages = await localDb.getMessages(matchId);

    try {
      // Optimistic local delete
      await localDb.deleteMessage(matchId, messageId);
      // Recompute the chat's last message preview after deletion
      await localDb.recomputeChatLastMessagePreviewFromMessages(currentUserId, matchId);

      // Server delete
      await supabase.from('chat_messages').delete().eq('id', messageId);

      try {
        _ref.invalidate(chatMessagesProvider(matchId));
        // Invalidate recent chats to update the last message preview immediately
        _ref.invalidate(recentChatsProvider(currentUserId));
      } catch (e) {
        debugPrint('Failed to invalidate providers after delete: $e');
      }
    } catch (e) {
      debugPrint('deleteMessage failed: $e');
      // Rollback
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      await localDb.recomputeChatLastMessagePreviewFromMessages(currentUserId, matchId);
      rethrow;
    }
  }

  Future<void> _applyOptimisticUpdate(String matchId, String messageId, String? reaction, User user, LocalDbService localDb) async {
    debugPrint('applyOptimisticUpdate START for message $messageId (reaction=$reaction)');
    final messages = await localDb.getMessages(matchId);
    final idx = messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (idx == -1) {
      debugPrint('applyOptimisticUpdate: message $messageId not found in local cache');
      return;
    }

    final msg = Map<String, dynamic>.from(messages[idx]);

    // Update my_reaction
    if (reaction == null) {
      msg.remove('my_reaction');
    } else {
      msg['my_reaction'] = reaction;
    }

    // Update reaction_summary counts optimistically
    final Map<String, dynamic> summary = (msg['reaction_summary'] is Map) ? Map<String, dynamic>.from(msg['reaction_summary']) : {};
    final prev = messages[idx]['my_reaction'] as String?;

    // Decrement previous reaction
    if (prev != null) {
      final int prevCount = (summary[prev] as int?) ?? 0;
      if (prevCount <= 1) {
        summary.remove(prev);
      } else {
        summary[prev] = prevCount - 1;
      }
    }

    // Increment new reaction
    if (reaction != null) {
      final int cur = (summary[reaction] as int?) ?? 0;
      summary[reaction] = cur + 1;
    }

    msg['reaction_summary'] = summary;
    messages[idx] = msg;
    await localDb.saveMessages(matchId, messages);

    debugPrint('applyOptimisticUpdate DONE for message $messageId -> summary: ${summary.toString()} prev: ${prev ?? 'none'}');

    // Update cached reactors
    await _updateCachedReactors(matchId, messageId, reaction, prev, user.id, localDb);
  }

  Future<void> _updateCachedReactors(String matchId, String messageId, String? reaction, String? prevReaction, String currentUserId, LocalDbService localDb) async {
    try {
      // Remove from previous reaction cache
      if (prevReaction != null) {
        final prevList = await localDb.getCachedReactors(matchId, messageId, prevReaction);
        final updatedPrev = prevList.where((r) => r['user_id'] != currentUserId).toList();
        await localDb.saveCachedReactors(matchId, messageId, prevReaction, updatedPrev);
      }

      // Add to new reaction cache
      if (reaction != null) {
        final profile = await localDb.getLocalProfile(currentUserId);
        String? displayName;
        String? photoUrl;
        if (profile != null) {
          displayName = profile['name'] as String?;
          final photos = profile['photos'];
          if (photos is List && photos.isNotEmpty) photoUrl = photos[0] as String?;
        }

        final newEntry = {
          'user_id': currentUserId,
          'display_name': displayName,
          'photo': photoUrl,
        };

        final curList = await localDb.getCachedReactors(matchId, messageId, reaction);
        final exists = curList.any((r) => r['user_id'] == currentUserId);
        if (!exists) {
          final updated = [...curList, newEntry];
          await localDb.saveCachedReactors(matchId, messageId, reaction, updated);
        }
      }
    } catch (e) {
      // Ignore cache update failures
      debugPrint('Failed to update cached reactors: $e');
    }
  }

  Future<void> _refreshCachedReactors(String matchId, String messageId, Iterable<String> keys, LocalDbService localDb) async {
    for (final k in keys) {
      try {
        final serverList = await getReactors(messageId: messageId, reaction: k);
        // Save whatever the server returns (including empty lists) so local cache matches server state.
        await localDb.saveCachedReactors(matchId, messageId, k, serverList);
      } catch (e) {
        final _ = e;
      }
    }
  }

  Future<void> _rollbackOptimisticUpdate(String matchId, List<Map<String, dynamic>> originalMessages, LocalDbService localDb) async {
    try {
      debugPrint('rollbackOptimisticUpdate: restoring original messages for match $matchId');
      await localDb.saveMessages(matchId, originalMessages);
      // Also invalidate provider to refresh UI
      _ref.invalidate(chatMessagesProvider(matchId));
    } catch (e) {
      debugPrint('Failed to rollback optimistic update: $e');
    }
  }

  /// Get list of reactors for a message/reaction. Returns list of maps with keys:
  /// `user_id`, `display_name`, `photo` (nullable).
  Future<List<Map<String, dynamic>>> getReactors({required String messageId, required String reaction}) async {
    try {
      // Prefer a server-side RPC that returns masked names/photos for reactors (avoids RLS issues).
      try {
        final rpcRows = await supabase.rpc('get_message_reactors', params: {
          'message_id': messageId,
          'reaction': reaction,
        });
        if (rpcRows != null && rpcRows.isNotEmpty) {
          final initial = (rpcRows as List).map<Map<String, dynamic>>((r) {
            final row = r as Map<String, dynamic>;
            return {
              'user_id': row['user_id']?.toString(),
              'display_name': row['display_name'] as String?,
              'photo': row['photo'] as String?,
            };
          }).toList();

          // Post-process: if any returned rows lack photos, attempt to fetch photos from users table as a fallback
          final idsMissingPhotos = initial.where((e) => e['photo'] == null).map((e) => e['user_id'] as String?).whereType<String>().toList();
          if (idsMissingPhotos.isNotEmpty) {
            for (final id in idsMissingPhotos) {
              try {
                final userRows = await supabase.from('users').select('id, photos').eq('id', id).limit(1);
                if (userRows.isNotEmpty) {
                  final ur = userRows[0];
                  final photos = (ur['photos'] is List) ? List<String>.from(ur['photos']) : null;
                  if (photos != null && photos.isNotEmpty) {
                    final idx = initial.indexWhere((e) => e['user_id'] == id);
                    if (idx >= 0) {
                      initial[idx]['photo'] = photos[0];
                    }
                  }
                }
              } catch (e) {
                final _ = e;
              }
            }
          }

          return initial;
        }
      } catch (e) {
        // RPC may not exist or be restricted; fall back to client-side fetching
      }

      final rows = await supabase
          .from('message_reactions')
          .select('user_id')
          .eq('message_id', messageId)
          .eq('reaction', reaction);
      if (rows.isEmpty) return [];
      final ids = rows.map((r) => r['user_id']?.toString()).whereType<String>().toList();
      if (ids.isEmpty) return [];
      // Fetch user names sequentially to avoid PostgREST `in_` method compatibility issues
      final Map<String, Map<String, dynamic>> byId = {};
      for (final id in ids) {
        try {
          final userRows = await supabase.from('users').select('id, name, photos').eq('id', id).limit(1);
          if (userRows.isNotEmpty) {
            final ur = userRows[0];
            final name = ur['name'] as String?;
            final photos = (ur['photos'] is List) ? List<String>.from(ur['photos']) : null;
            byId[id] = {'id': id, 'full_name': name, 'photos': photos};
          }
        } catch (_) {
          // ignore user fetch errors
        }
      }

      String? maskFullName(String? fullName) {
        if (fullName == null) return null;
        final parts = fullName.trim().split(RegExp(r'\s+'));
        if (parts.isEmpty) return null;
        if (parts.length == 1) return parts.first;
        final first = parts.first;
        final lastInitial = parts.last[0].toUpperCase();
        return '$first $lastInitial.';
      }

      final List<Map<String, dynamic>> result = [];
      for (final id in ids) {
        final p = byId[id];
        final masked = p != null ? maskFullName(p['full_name'] as String?) : null;
        result.add({
          'user_id': id,
          'display_name': masked,
          'photo': p != null && (p['photos'] is List && (p['photos'] as List).isNotEmpty) ? (p['photos'][0] as String) : null,
        });
      }

      return result;
    } catch (e) {
      return [];
    }
  }
}
// --- END chatServiceProvider ---

// ---
// --- UPDATED: Translation State Management (listens to locale changes)
// ---
typedef TranslationStates = Map<String, String>;

/* Notification payload sent when translations are auto-disabled for a match. */
class TranslationNotification {
  final String matchId;
  final String text;
  TranslationNotification({required this.matchId, required this.text});
}

class TranslationNotificationNotifier extends Notifier<TranslationNotification?> {
  @override
  TranslationNotification? build() => null;

  void notify(TranslationNotification n) {
    state = n;
    Future.delayed(const Duration(seconds: 4), () {
      if (ref.mounted) state = null;
    });
  }

  void clear() {
    if (ref.mounted) state = null;
  }
}

final translationNotificationProvider = NotifierProvider<TranslationNotificationNotifier, TranslationNotification?>(() {
  return TranslationNotificationNotifier();
});

class TranslationNotifier extends Notifier<TranslationStates> {
  // Base prefs key - actual stored key is namespaced per-user: '${_prefsKeyBase}_<userId>'
  static const String _prefsKeyBase = 'translation_states';

  @override
  TranslationStates build() {
    // Load for the currently signed-in user (if any)
    _loadFromPrefsForCurrentUser();

    // Also listen to auth state changes so we can reload when user signs in/out/switches
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      _loadFromPrefsForCurrentUser();
    });

    // When the UI language changes, remove any cached translations whose target
    // language is now the same as the UI â€” they are redundant and should be cleared.
    ref.listen(localizationProvider, (previous, next) {
      try {
        final newLang = next.currentLocale.languageCode;
        // For each match where the user currently has translations enabled, clear cached translated
        // content only if the messages were originally written in the new UI language. We do NOT
        // change the user's translation setting â€” the system will never toggle it automatically.
        final matchesWithTranslation = state.keys.toList();
        if (matchesWithTranslation.isEmpty) return;

        // Schedule cleanup after a small delay to allow the localization change to settle
        Future.delayed(const Duration(milliseconds: 250), () async {
          if (!ref.mounted) return; // provider disposed
          try {
            String? userId;
            try {
              userId = Supabase.instance.client.auth.currentUser?.id;
            } catch (_) {
              userId = null;
            }

            final localDb = ref.read(localDbProvider);
            for (final matchId in matchesWithTranslation) {
              if (!ref.mounted) return;

              // Check messages for any that have detected source language == newLang
              try {
                final messages = await localDb.getMessages(matchId);
                final shouldClear = messages.any((m) {
                  final detected = (m['detected_source_language'] ?? m['source_language'] ?? m['language']) as String?;
                  return detected != null && detected.toString().toLowerCase().startsWith(newLang.toLowerCase());
                });

                if (shouldClear) {
                  await localDb.clearCachedTranslationsForMatch(matchId, userId: userId);
                  // Trigger UI refresh for translations
                  if (ref.mounted) ref.read(translationVersionProvider.notifier).increment();
                }
              } catch (_) {
                // ignore per-match errors - best-effort
              }
            }
          } catch (_) {
            // ignore errors - cleanup is best-effort
          }
        });
      } catch (_) {}
    });

    return {}; // Return empty state initially, will be updated when loaded
  }

  String _prefsKeyForUser(String? userId) => '$_prefsKeyBase${userId == null ? '' : '_$userId'}';

  Future<void> _loadFromPrefsForCurrentUser() async {
    // Supabase.instance may not be initialized in test environments; guard against that.
    String? userId;
    try {
      userId = Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      // Supabase not initialized (e.g., in tests); skip loading from prefs for now.
      return;
    }
    await _loadFromPrefsForUser(userId);
  }

  Future<void> _loadFromPrefsForUser(String? userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = _prefsKeyForUser(userId);
      final jsonString = prefs.getString(key);
      if (jsonString != null) {
        final Map<String, dynamic> decoded = jsonDecode(jsonString);
        final Map<String, String> loaded = {};
        decoded.forEach((key, value) {
          if (value != null) loaded[key] = value as String;
        });
        state = loaded;
      } else {
        // No stored prefs for this user - leave state empty
        state = {};
      }
    } catch (e) {
      // Ignore errors, keep empty state
    }
  }

  Future<void> _saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final key = _prefsKeyForUser(userId);
      final jsonString = jsonEncode(state);
      await prefs.setString(key, jsonString);
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> setTranslation(String matchId, String? targetLang) async {
    final previous = state[matchId];

    // Optimistically update in-memory state and prefs
    if (targetLang == null) {
      state = {...state}..remove(matchId);
    } else {
      state = {
        ...state,
        matchId: targetLang,
      };
    }
    await _saveToPrefs();

    final userId = Supabase.instance.client.auth.currentUser?.id;

    // Immediately update local cache to reflect the new flag for UX
    try {
      if (userId != null) {
        final localDb = ref.read(localDbProvider);
        await localDb.updateChatTranslation(userId, matchId, targetLang != null, targetLang);
      }
    } catch (_) {
      // best-effort
    }

    // Notify UI providers to refresh translations
    ref.read(translationVersionProvider.notifier).increment();

    // If translation was turned OFF, clear any cached translations
    if (targetLang == null && matchId.isNotEmpty) {
      try {
        final localDb = ref.read(localDbProvider);
        await localDb.clearCachedTranslationsForMatch(matchId, userId: userId);
      } catch (e) {
        // Ignore failures - clearing cache is best-effort
      }
    }

    // Persist to server; if it fails, revert and rethrow so callers can show UI feedback
    try {
      if (userId != null) {
        await Supabase.instance.client.rpc('set_chat_translation', params: {
          'p_user_id': userId,
          'p_match_id': matchId,
          'p_enabled': targetLang != null,
          'p_language': targetLang,
        });

        // After successful write, trigger a background sync to pick up server canonical data
        try {
          await ref.read(globalSyncManagerProvider).syncChatsNow(userId);
          ref.invalidate(recentChatsProvider(userId));
        } catch (_) {}
      }
    } catch (e) {
      // Revert optimistic update
      if (previous == null) {
        state = {...state}..remove(matchId);
      } else {
        state = {...state, matchId: previous};
      }
      await _saveToPrefs();

      // Revert local cache
      try {
        if (userId != null) {
          final localDb = ref.read(localDbProvider);
          await localDb.updateChatTranslation(userId, matchId, previous != null, previous);
        }
      } catch (_) {}

      rethrow;
    }
  }

  /// Silent update to translation state - used during sync to match server state
  /// Does NOT save to prefs or database - just updates in-memory state
  void setTranslationSilent(String matchId, String targetLang) {
    state = {
      ...state,
      matchId: targetLang,
    };
  }

  /// Silent removal from translation state - used during sync
  /// Does NOT save to prefs or database - just updates in-memory state
  void clearTranslationSilent(String matchId) {
    state = {...state}..remove(matchId);
  }
}

final translationProvider = NotifierProvider<TranslationNotifier, TranslationStates>(() {
  return TranslationNotifier();
});
// --- END Translation State ---

// --- Translation Batch State (Prevents multiple simultaneous batch calls per match) ---
final translationBatchStateProvider = NotifierProvider<TranslationBatchNotifier, Map<String, bool>>(() => TranslationBatchNotifier());

class TranslationBatchNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  bool isRunning(String matchId) => state[matchId] ?? false;

  void setRunning(String matchId, bool running) {
    state = {...state, matchId: running};
  }
}
// --- END Translation Batch State ---

// ---
// --- *** UPDATED: translationFamilyProvider (translates to current UI language)
// --- Translates incoming messages to the current app UI language when translation is enabled.
// --- Only translates messages from other users, not outgoing messages.
// --- Uses smart Case A/B/C logic based on server-side translation data:
// --- - Case A: UI != source AND UI != target -> Call translate-proxy
// --- - Case B: UI == source -> Show original (no AI)
// --- - Case C: UI == target -> Reuse existing translation (no AI)
// ---
final translationFamilyProvider = FutureProvider.autoDispose
    .family<String, String>((ref, paramsString) async {
  // Depend on translation version to ensure re-evaluation when toggled
  ref.watch(translationVersionProvider);

  final Map<String, dynamic> params;
  try {
    params = jsonDecode(paramsString) as Map<String, dynamic>;
  } catch (e) {

    return 'Error parsing params';
  }

  final text = params['text'] as String?;
  final matchId = params['matchId'] as String?;
  final messageId = params['messageId'] as String?;

  if (text == null || matchId == null || messageId == null || text.isEmpty) {
    return text ?? 'Error: invalid params';
  }

  final localDb = ref.read(localDbProvider);

  // 1. Check if translation is even on for this chat
  final translationEnabled = ref.watch(translationProvider)[matchId] != null;

  if (!translationEnabled) {
    // Translation is off for this chat.
    return text;
  }

  // 2. Get the current UI language as the target language
  final currentUILocale = ref.watch(localizationProvider).currentLocale;
  final targetLanguage = normalizeLanguageCode(currentUILocale.languageCode);

  // 2. Load message data once from local DB for both sender check and cache check
  if (matchId.isEmpty) return text;

  final messages = await localDb.getMessages(matchId);
  final message = messages.firstWhere((m) => m['id'].toString() == messageId, orElse: () => {});
  final senderId = message['sender_id'] as String?;
  
  // Get server-side translation data (set by translate-proxy edge function)
  final serverSourceLang = message['detected_source_language'] as String?;
  final serverTargetLang = message['translated_target_language'] as String?;
  final serverTranslation = message['content_translated'] as String?;

  // Check if this is an outgoing message (from current user) - don't translate those
  final currentUserId = supabase.auth.currentUser?.id;
  if (senderId == currentUserId) {
    // This is our own message, don't translate it
    return text;
  }

  // 3. Case A/B/C Logic using server-side translation data
  // Normalize language codes for comparison
  final normalizedSource = serverSourceLang != null ? normalizeLanguageCode(serverSourceLang) : null;
  final normalizedTarget = serverTargetLang != null ? normalizeLanguageCode(serverTargetLang) : null;

  debugPrint('ðŸ”„ Translation Provider: Case A/B/C check - UI=$targetLanguage, source=$normalizedSource, target=$normalizedTarget');

  // Case B: UI language == source language -> Show original (no AI needed)
  if (normalizedSource != null && normalizedSource == targetLanguage) {
    debugPrint('ðŸ”„ Translation Provider: Case B - UI matches source, showing original');
    return text;
  }

  // Case C: UI language == target language -> Reuse existing translation (no AI needed)
  if (normalizedTarget != null && normalizedTarget == targetLanguage && 
      serverTranslation != null && serverTranslation.isNotEmpty) {
    debugPrint('ðŸ”„ Translation Provider: Case C - UI matches target, reusing existing translation');
    return serverTranslation;
  }

  // Case A: UI != source AND UI != target -> Need to translate
  // Use batch mode to translate ALL incoming messages (not just this one)
  // This ensures all messages are translated and saved to Supabase for sync
  debugPrint('ðŸ”„ Translation Provider: Case A - Using batch translate for incoming messages');

  // Try to detect source language locally if not available from server
  String? sourceLanguage = normalizedSource;
  if (sourceLanguage == null) {
    try {
      final translationService = ref.read(translationServiceProvider);
      final textForLangId = _stripEmojisForLanguageId(text);
      if (textForLangId.replaceAll(RegExp(r'\s+'), '').length >= 2) {
        sourceLanguage = await translationService.identifyLanguage(textForLangId);
        debugPrint('ðŸ”„ Translation Provider: Locally detected source language: $sourceLanguage');
      }
    } catch (e) {
      debugPrint('ðŸ”„ Translation Provider: Local language detection failed: $e');
      sourceLanguage = null;
    }
  }

  // Always retranslate when in Case A - we need translations for a different language
  // Case A means: UI != source AND UI != target, so we definitely need new translations
  final doRetranslation = true;

  // Call translate-proxy in BATCH mode to translate ALL incoming messages
  // This ensures proper sync with Supabase and uses exclude_sender_id to only
  // translate messages from OTHER users (incoming messages)
  final batchState = ref.read(translationBatchStateProvider.notifier);
  try {
    if (batchState.isRunning(matchId)) {
      debugPrint('ðŸ”„ Translation Provider: Batch already running for $matchId, skipping');
      return text;
    }
    batchState.setRunning(matchId, true);

    final requestBody = {
      'match_id': matchId,
      'target_language': targetLanguage,
      // translate-proxy expects snake_case: retranslate_all
      'retranslate_all': doRetranslation,
      // IMPORTANT: Only translate messages from OTHER users (incoming messages)
      // This prevents translating our own messages when we change our UI language
      'exclude_sender_id': currentUserId,
    };
    
    // BUG FIX: Do NOT pass source_language - edge function auto-detects
    // if (sourceLanguage != null && sourceLanguage.isNotEmpty) {
    //   requestBody['source_language'] = sourceLanguage;
    // }
    
    debugPrint('ðŸ”„ Translation Provider: Calling translate-proxy batch for match $matchId, target=$targetLanguage, exclude $currentUserId');
    
    final response = await supabase.functions.invoke('translate-proxy', body: requestBody);
    
    // Check if provider is still mounted before using ref
    if (!ref.mounted) {
      debugPrint('ðŸ”„ Translation Provider: Provider disposed, returning original text');
      batchState.setRunning(matchId, false);
      return text;
    }
    
    if (response.data != null) {
      final translated = response.data['translated'] ?? 0;
      debugPrint('ðŸ”„ Translation Provider: Batch translate response - translated: $translated');
      
      // Invalidate to refresh data from Supabase - only if still mounted
      if (ref.mounted) {
        ref.invalidate(translationVersionProvider);
      }
      
      // After batch translation, the NEW translation should be in Supabase
      // IMPORTANT: Fetch directly from Supabase, not from local cache, to get fresh data
      if (ref.mounted) {
        // Fetch fresh data directly from Supabase to bypass local cache
        final freshData = await supabase
            .from('chat_messages')
            .select('id, content_translated, translated_target_language')
            .eq('match_id', matchId)
            .eq('id', messageId)
            .maybeSingle();
        
        final newTranslation = freshData?['content_translated'] as String?;
        final newTargetLang = freshData?['translated_target_language'] as String?;
        
        debugPrint('ðŸ”„ Translation Provider: After batch - fresh newTranslation: $newTranslation, newTargetLang: $newTargetLang');
        
        // Return the fresh translation if it matches our target language
        if (newTranslation != null && 
            newTranslation.isNotEmpty && 
            newTranslation != 'null' &&
            newTargetLang == targetLanguage) {
          debugPrint('ðŸ”„ Translation Provider: Returning fresh translation from DB');
          
          // Update chat preview with translated message
          try {
            final currentUserId = supabase.auth.currentUser?.id;
            if (currentUserId != null) {
              await localDb.updateChatLastMessageTranslation(
                currentUserId,
                matchId,
                messageId,
                newTranslation,
              );
              debugPrint('ðŸ”„ Translation Provider: Updated chat preview with translation');
              
              // Show notification for newly translated message
              try {
                // Get message details to determine if this was an incoming message
                final messages = await localDb.getMessages(matchId);
                final messageData = messages.firstWhere((m) => m['id'].toString() == messageId, orElse: () => {});
                final senderId = messageData['sender_id'] as String?;
                final originalContent = messageData['content_original'] as String?;
                
                // Only show notification for incoming messages (not our own)
                if (senderId != null && senderId != currentUserId && originalContent != null) {
                  // Fetch sender name
                  String senderName = 'MatchMe';
                  try {
                    final userData = await supabase
                        .from('users')
                        .select('name')
                        .eq('id', senderId)
                        .single();
                    senderName = formatSenderNameForNotification(userData['name'] as String? ?? 'MatchMe');
                  } catch (e) {
                    debugPrint('Failed to fetch sender name for delayed notification: $e');
                  }
                  
                  // Show delayed notification with translated content
                  if (kIsWeb) {
                    WebNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: newTranslation,
                      matchId: matchId,
                    );
                  } else if (Platform.isAndroid) {
                    await MobileLocalNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: newTranslation,
                      matchId: matchId,
                    );
                  }
                  debugPrint('ðŸ”„ Translation Provider: Showed delayed notification with translation');
                }
              } catch (e) {
                debugPrint('ðŸ”„ Translation Provider: Failed to show delayed notification: $e');
              }
            }
          } catch (e) {
            debugPrint('ðŸ”„ Translation Provider: Failed to update chat preview: $e');
          }
          
          return newTranslation;
        }
      }
    }
  } catch (e) {
    debugPrint('ðŸ”„ Translation Provider: Batch translate call failed: $e');
    batchState.setRunning(matchId, false);
  }

  // Check mounted again before returning
  if (!ref.mounted) {
    return text;
  }

  // Reset batch state if not already reset
  batchState.setRunning(matchId, false);

  // Return original text if no fresh translation available
  return text;
});

// Strip emojis and most non-letter characters to improve language identification.
String _stripEmojisForLanguageId(String input) {
  final buf = StringBuffer();
  for (final rune in input.runes) {
    final s = String.fromCharCodes([rune]);
    if (_looksLikeEmoji(s)) continue;
    if (RegExp(r'[\p{L}\p{N}\s]', unicode: true).hasMatch(s)) {
      buf.write(s);
    } else {
      buf.write(' ');
    }
  }
  return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

// Simple fallback language detection based on character patterns
// NOTE: This function is kept for potential future use but is not currently needed
// as we rely on server-side translation data (detected_source_language, translated_target_language)
// String _guessLanguageFromText(String text) {
//   if (text.trim().isEmpty) return 'und';
//   ... (omitted for brevity)
//   return 'und';
// }

bool _looksLikeEmoji(String grapheme) {
  // Broad, best-effort emoji/pictographic range match.
  return RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true).hasMatch(grapheme);
}

/// Provider to ensure incoming chat messages are aligned with the current UI language.
/// On app run/resume, this re-checks translation-enabled chats and applies
/// the existing batch translation logic for incoming messages where needed.
final pendingMessageTranslationProvider = FutureProvider<void>((ref) async {
  final authState = ref.watch(authStateProvider).value;
  if (authState == null) return;

  final session = authState.session;
  if (session == null) return;

  final userId = session.user.id;
  if (userId.isEmpty) return;

  try {
    final targetLanguage = normalizeLanguageCode(
      ref.read(localizationProvider).currentLocale.languageCode,
    );

    debugPrint('🔄 Startup translation sync: target=$targetLanguage');

    final chats = await supabase
        .from('chats')
        .select('match_id')
        .eq('user_id', userId)
        .eq('translation_enabled', true);

    if (chats.isEmpty) {
      debugPrint('✅ Startup translation sync: no translation-enabled chats');
      return;
    }

    final localDb = ref.read(localDbProvider);
    int syncedChats = 0;

    for (final rawChat in chats as List) {
      try {
        final matchId = rawChat['match_id']?.toString() ?? '';
        if (matchId.isEmpty) {
          continue;
        }

        await supabase.functions.invoke(
          'translate-proxy',
          body: {
            'match_id': matchId,
            'target_language': targetLanguage,
            'retranslate_all': true,
            'exclude_sender_id': userId,
          },
        );

        final latestIncoming = await supabase
            .from('chat_messages')
            .select('id, content_translated, translated_target_language')
            .eq('match_id', matchId)
            .neq('sender_id', userId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();

        final latestMessageId = latestIncoming?['id']?.toString();
        final latestTranslated = latestIncoming?['content_translated'] as String?;
        final latestTarget = latestIncoming?['translated_target_language']?.toString();
        final hasTranslated = latestTranslated != null &&
            latestTranslated.isNotEmpty &&
            latestTranslated != 'null';
        final matchesTarget = latestTarget != null &&
            latestTarget.isNotEmpty &&
            normalizeLanguageCode(latestTarget) == targetLanguage;

        if (latestMessageId != null &&
            latestMessageId.isNotEmpty &&
            hasTranslated &&
            matchesTarget) {
          await localDb.updateChatLastMessageTranslation(
            userId,
            matchId,
            latestMessageId,
            latestTranslated,
          );
        }

        syncedChats++;
      } catch (e) {
        debugPrint('⚠️ Startup translation sync failed for a chat: $e');
      }
    }

    if (ref.mounted) {
      await ref.read(globalSyncManagerProvider).syncChatsNow(userId);
      ref.read(translationVersionProvider.notifier).increment();
    }

    debugPrint('✅ Startup translation sync complete for $syncedChats chats');
  } catch (e) {
    debugPrint('⚠️ Startup translation sync error: $e');
  }
});
