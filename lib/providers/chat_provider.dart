// lib/providers/chat_provider.dart
import 'dart:async';
import 'dart:convert'; // For jsonEncode

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/translation_cache_manager.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/offline_mutation_queue.dart';
import 'package:matchme/services/supabase_reachability.dart';
import 'package:matchme/services/encrypted_cache_service.dart';

import 'package:matchme/config/security_constants.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/providers/chat_key_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/providers/translation_version_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/services/mobile_local_notification_service.dart';
import 'package:matchme/services/background_service.dart';

final supabase = Supabase.instance.client;
final uuid = Uuid();

// Helper function to format sender name: "FirstName LastInitial." e.g., "John S."
// Capitalizes first letters regardless of how the user typed the name and
// handles multiple first/last names (e.g. Spanish names).
String formatSenderNameForNotification(String fullName) {
  if (fullName.isEmpty) return 'MatchMe';

  String capWord(String word) {
    if (word.isEmpty) return word;
    final hyphenParts = word.split('-');
    return hyphenParts
        .map((h) {
          if (h.isEmpty) return h;
          return h
              .split("'")
              .map((s) {
                if (s.isEmpty) return s;
                final lower = s.toLowerCase();
                return '${lower[0].toUpperCase()}${lower.substring(1)}';
              })
              .join("'");
        })
        .join('-');
  }

  final cleaned = fullName.replaceAll(
    RegExp('[\u200E\u200F\u202A-\u202E]'),
    '',
  );
  final parts = cleaned
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'MatchMe';
  if (parts.length == 1) {
    return capWord(parts[0]); // Just first name if no last name
  }

  // First name + first letter of last name with period
  final firstName = capWord(parts[0]);
  final lastInitial = parts[parts.length - 1][0].toUpperCase();
  return '$firstName $lastInitial.';
}

/// Drops a stale tray card after a peer edit/delete: cancels the Flutter
/// card and clears native history, then re-checks the RPC latest on Android
/// so remaining unreads re-post with correct text. Never throws.
Future<void> _dismissStaleTray(String matchId) async {
  try {
    await MobileLocalNotificationService.dismissChatNotification(matchId);
  } catch (_) {}
  try {
    await BackgroundService.dismissChatNotification(matchId);
  } catch (_) {}
  try {
    await BackgroundService.resetChatNotification(matchId);
  } catch (_) {}
  try {
    await BackgroundService.triggerNotificationCheck(matchId: matchId);
  } catch (_) {}
}

/// Extracts the translated text of [original] for reply-quote previews.
/// Returns null when there is no usable translation (missing, empty, or
/// identical to the original). Used by both Phase 1 and Phase 2 reply
/// resolution so quoted messages render translated when available.
String? replyQuotedTranslatedText(ChatMessageModel original) {
  String? candidate;
  final ct = original.contentTranslated;
  if (ct != null && ct.trim().isNotEmpty) {
    candidate = ct;
  } else {
    final tt = original.translatedText;
    if (tt != null && tt.trim().isNotEmpty) candidate = tt;
  }
  if (candidate == null) return null;
  if (candidate.trim() == original.contentOriginal.trim()) return null;
  return candidate;
}

// Debouncer for reaction updates to prevent rapid clicks
final Map<String, Timer> _reactionDebouncer = {};
Future<void>? _startupTranslationSyncInFlight;

// Cache for language detection results to avoid calling identifyLanguage
// for the same text multiple times during re-evaluation waves.
final Map<String, String> _languageDetectionCache = {};

// In-memory cache for translation results keyed by messageId|targetLanguage.
// translationFamilyProvider is autoDispose, so leaving a chat disposes all
// instances. Without this cache, re-entering a chat re-runs the full async
// pipeline (DB read → decrypt → Supabase fetch) for every visible message,
// causing translations to disappear and then reappear. This cache bridges
// that gap by returning the last-known translation immediately.
// Stores the translation result alongside the translationVersionProvider value
// so that cache entries are only reused when the version hasn't changed.
// Mirrored to SharedPreferences (local storage) so translations survive app
// restarts and are available immediately when Supabase is unreachable.
final Map<String, _TranslationCacheEntry> _translationResultCache = {};

/// SharedPreferences mirror of [_translationResultCache] for cold-start
/// offline display. Hive (`chatMessagesBox`) is the primary local storage
/// for messages/translations/replies; this lightweight prefs layer is a
/// secondary fallback that survives even if a Hive box is slow to open
/// (e.g. cold IndexedDB on web) and satisfies the "memory + local storage"
/// requirement explicitly.
///
/// Translations are message content, so the prefs values are encrypted with
/// the per-user device cache key (EncryptedCacheService, AES-GCM) and
/// prefixed with [_translationEncPrefix]. Legacy plaintext values written
/// before this existed are re-encrypted by [migrateLegacyTranslationPrefs].
const String _translationEncPrefix = 'enc1:';

Future<String?> _loadPersistedTranslation(
  String messageId,
  String targetLanguage,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('chat_translation:$messageId:$targetLanguage');
    if (v == null || v.isEmpty) return null;
    if (v.startsWith(_translationEncPrefix)) {
      return await EncryptedCacheService.instance.decryptFromCache(
        v.substring(_translationEncPrefix.length),
      );
    }
    // Legacy plaintext value: readable as-is, the migration pass will
    // re-encrypt it.
    return v;
  } catch (_) {}
  return null;
}

Future<void> _persistTranslation(
  String messageId,
  String targetLanguage,
  String translation,
) async {
  try {
    if (translation.isEmpty) return;
    // Fail closed: with no per-user cache key available we must not write
    // message content to SharedPreferences in plaintext.
    final encrypted = await EncryptedCacheService.instance.encryptForCache(
      translation,
    );
    if (encrypted == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'chat_translation:$messageId:$targetLanguage',
      '$_translationEncPrefix$encrypted',
    );
  } catch (_) {}
}

/// One-time re-encryption of legacy plaintext `chat_translation:*` prefs
/// entries left by older builds. Entries that cannot be encrypted (no
/// per-user cache key yet) are removed rather than left in plaintext.
bool _translationPrefsMigrationDone = false;
Future<void> migrateLegacyTranslationPrefs() async {
  if (_translationPrefsMigrationDone) return;
  _translationPrefsMigrationDone = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith('chat_translation:'))
        .toList();
    for (final key in keys) {
      try {
        final v = prefs.getString(key);
        if (v == null || v.isEmpty || v.startsWith(_translationEncPrefix)) {
          continue;
        }
        final encrypted = await EncryptedCacheService.instance.encryptForCache(
          v,
        );
        if (encrypted == null) {
          await prefs.remove(key);
        } else {
          await prefs.setString(key, '$_translationEncPrefix$encrypted');
        }
      } catch (_) {
        try {
          await prefs.remove(key);
        } catch (_) {}
      }
    }
  } catch (_) {}
}

class _TranslationCacheEntry {
  final String translation;
  final int version;
  const _TranslationCacheEntry(this.translation, this.version);
}

// In-memory snapshot of the last List<ChatMessageModel> emitted by
// chatMessagesProvider for each matchId.  chatMessagesProvider is
// `autoDispose.family`, so every time the user navigates away from a chat
// and back, the previous emission is discarded by Riverpod.  Without this
// snapshot the chat screen would show its loading spinner until the local
// stream re-yields (which can take a noticeable fraction of a second on
// cold IndexedDB reads or several seconds when many messages need cache
// decryption).  Emitting the cached snapshot in a microtask bridges that
// gap; the local stream will replace it as soon as fresh data arrives.
final Map<String, List<ChatMessageModel>> _lastEmittedMessages = {};

// --- ChatSyncService (Modified to take localDb as parameter) ---
class ChatSyncService {
  final LocalDbService localDb;
  ChatSyncService(this.localDb);

  Future<void> syncMessages(String matchId) async {
    if (matchId.isEmpty) return;
    try {
      // debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
      // debugPrint('ðŸ”„ SYNC START: syncMessages called for matchId=$matchId');
      // debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');

      final data = await supabase
          .from('chat_messages')
          .select(
            'id, match_id, sender_id, created_at, edited_at, delivered_at, read_at, '
            'reaction_summary, reply_to_message_id, '
            'detected_source_language, translated_target_language, '
            'translated_source_edited_at, '
            'encryption_scheme, sender_key_id, recipient_key_id, recipient_id, '
            'content_original_encrypted, content_original_nonce, '
            'content_translated_encrypted, content_translated_nonce, '
            'wrapped_keys, translation_capable',
          )
          .eq('match_id', matchId)
          .order('created_at', ascending: true);

      // debugPrint('ðŸ”„ SYNC: Retrieved ${data.length} messages from Supabase');
      for (final _ in data) {
        // debugPrint('   - Message ${_['id']}: delivered_at=${_['delivered_at']}, sender=${_['sender_id']}');
      }

      // Replace all messages for this match with the current database state
      // This ensures deleted messages are removed from local cache
      await localDb.saveMessages(matchId, data.cast<Map<String, dynamic>>());

      // debugPrint('ðŸ”„ SYNC: Saved ${data.length} messages to local database');

      // Mark undelivered messages from the other user as delivered
      // (This user just received them by syncing)
      final currentUserId = supabase.auth.currentUser?.id;
      // debugPrint('ðŸ”„ SYNC: currentUserId=$currentUserId');

      if (currentUserId != null && data.isNotEmpty) {
        // Collect message IDs that need to be marked as delivered
        final messagesToDeliver = <String>[];

        for (final msg in data as List) {
          final msgId = msg['id'] as String?;
          final senderId = msg['sender_id'] as String?;
          final deliveredAt = msg['delivered_at'];

          // debugPrint('ðŸ”„ SYNC: Checking msg=$msgId (sender=$senderId, delivered=$deliveredAt, isOtherUser=${senderId != currentUserId})');

          // If this message is from the other user and not yet delivered, mark it
          if (senderId != null &&
              senderId != currentUserId &&
              (deliveredAt == null || deliveredAt == '')) {
            messagesToDeliver.add(msgId ?? '');
            // debugPrint('ðŸ”„ SYNC: âž• Added $msgId to delivery list (from other user, not yet delivered)');
          } else {
            final _ = senderId == currentUserId
                ? 'from this user'
                : 'already delivered';
            // debugPrint('ðŸ”„ SYNC: â­ï¸  Skipped $msgId ($reason)');
          }
        }

        // Batch mark messages as delivered with better error handling
        if (messagesToDeliver.isNotEmpty) {
          // debugPrint('ðŸ”„ SYNC: Marking ${messagesToDeliver.length} messages as delivered');

          try {
            final results = await Future.wait(
              messagesToDeliver.map((msgId) {
                // debugPrint('ðŸ”„ SYNC: Calling RPC mark_message_delivered for $msgId...');
                return supabase
                    .rpc(
                      'mark_message_delivered',
                      params: {'p_message_id': msgId},
                    )
                    .then((result) {
                      // debugPrint('âœ… SYNC: RPC succeeded for $msgId - result=$result');
                      return true;
                    })
                    .catchError((e, st) {
                      // debugPrint('âŒ SYNC: RPC FAILED for $msgId');
                      // debugPrint('   Error: $e');
                      // debugPrint('   Stack: $st');
                      return false;
                    });
              }),
              eagerError: false,
            );

            final _ = results.where((r) => r == true).length;
            // debugPrint('ðŸ”„ SYNC: Successfully marked $successCount/${messagesToDeliver.length} messages as delivered');
          } catch (e) {
            // debugPrint('ðŸ”„ SYNC: Error in batch delivery marking: $e\n$st');
            // Don't throw - marking as delivered is non-critical
          }
        } else {
          // debugPrint('ðŸ”„ SYNC: No messages to deliver (either no undelivered messages or no current user)');
        }
      }
    } catch (e) {
      // debugPrint('âŒ SYNC ERROR: $e\n$st');
      // Keep the error surfaced but avoid noisy logging here.
    }
    // debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
    // debugPrint('ðŸ”„ SYNC END: syncMessages completed');
    // debugPrint('â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•');
  }

  // Diagnostic function to test if RPC function is working
  Future<void> testRpcFunction(String testMessageId) async {
    try {
      // debugPrint('ðŸ§ª TEST: Testing RPC mark_message_delivered with messageId=$testMessageId');
      // debugPrint('ðŸ§ª TEST: Current user: ${supabase.auth.currentUser?.id}');

      final _ = await supabase.rpc(
        'mark_message_delivered',
        params: {'p_message_id': testMessageId},
      );

      // debugPrint('âœ… TEST: RPC call succeeded! Result: $_');
      // debugPrint('ðŸ§ª TEST: Check Supabase to see if delivered_at was updated for this message');
    } catch (e) {
      // debugPrint('âŒ TEST: RPC call FAILED!');
      // debugPrint('   Error: $e');
      // debugPrint('   Type: ${e.runtimeType}');
      // debugPrint('   Stack: $st');

      // Try to extract more details
      if (e is PostgrestException) {
        // debugPrint('   PostgrestException details:');
        // debugPrint('   - Code: ${e.code}');
        // debugPrint('   - Message: ${e.message}');
        // debugPrint('   - Details: ${e.details}');
      }
    }
  }
}

final chatSyncProvider = Provider.family<ChatSyncService, String>(
  (ref, matchId) => ChatSyncService(ref.read(localDbProvider)),
);

// --- UPDATED: chatMessagesProvider (Fixes bugs & uses local DB + realtime)
// Emits a stream of ChatMessageModel lists for a given matchId.
final chatMessagesProvider = StreamProvider.autoDispose.family<List<ChatMessageModel>, String>((
  ref,
  matchId,
) {
  try {
    if (matchId.isEmpty) return Stream.value([]);

    // Keep the provider alive to prevent excessive recreation during widget rebuilds
    final keepAliveLink = ref.keepAlive();
    Timer? keepAliveTimer;
    void resetKeepAlive() {
      keepAliveTimer?.cancel();
      keepAliveTimer = Timer(const Duration(minutes: 5), () {
        keepAliveLink.close();
      });
    }

    resetKeepAlive();

    final localDb = ref.watch(localDbProvider);
    ref.watch(chatKeyProvider.select((s) => s.privateKeyBytes));
    // After a user switch on the same device the chatKeyProvider singleton
    // may still hold the previous user's private key (the onAuthStateChange
    // stream is not guaranteed to reach its listener on every platform).
    // Re-initialize it for the currently authenticated user so Phase 2
    // decryption below uses the correct key (this also purges the previous
    // user's in-memory decryption caches via user-change detection in _init).
    final currentAuthUserId = supabase.auth.currentUser?.id;
    if (currentAuthUserId != null) {
      final keyNotifier = ref.read(chatKeyProvider.notifier);
      // Never fire a key refresh from build while offline: _init() would
      // early-return without progress, emit a new privateKeyBytes instance,
      // rebuild this provider (loading -> data), and loop. Offline boot now
      // also sets initializedUserId, so this is a second guard.
      if (keyNotifier.initializedUserId != currentAuthUserId &&
          !shouldSkipSupabaseCalls()) {
        debugPrint(
          '🔑 [chatMessagesProvider] Key initialized for user=${keyNotifier.initializedUserId} but current user=$currentAuthUserId — re-initializing chat key provider',
        );
        unawaited(() async {
          try {
            await keyNotifier.refresh();
            debugPrint(
              '✅ [chatMessagesProvider] Chat key provider refreshed for $currentAuthUserId',
            );
          } catch (e, st) {
            debugPrint(
              '⚠️ [chatMessagesProvider] Chat key refresh failed: $e\n$st',
            );
          }
        }());
      }
    }
    final localStream = localDb.watchMessages(matchId);

    final StreamController<List<ChatMessageModel>> streamController =
        StreamController<List<ChatMessageModel>>.broadcast();
    bool disposed = false;
    bool scheduledInitialSync = false;
    Timer? realtimeSyncDebounce;
    Timer? emitDebounce;
    // Debounce the cross-device auto-heal trigger to avoid infinite loops
    // if the underlying issue is something other than a stale local key.
    DateTime? lastAutoHealTriggeredAt;
    // Emit the last-known list of messages immediately on provider build
    // so the chat screen is never stuck on its loading spinner if the
    // user navigates back into a chat they were just viewing.  The local
    // stream will re-emit (and replace) the snapshot as soon as it yields.
    final cachedSnapshot = _lastEmittedMessages[matchId];
    if (cachedSnapshot != null) {
      Future.microtask(() {
        if (!disposed && !streamController.isClosed) {
          streamController.add(cachedSnapshot);
        }
      });
    }
    // Coalesce rapid stream emissions so the chat UI only rebuilds once
    // when multiple sync/decryption cycles fire in quick succession.
    void debouncedEmit(List<ChatMessageModel> messages) {
      if (disposed || streamController.isClosed) return;
      _lastEmittedMessages[matchId] = messages;
      emitDebounce?.cancel();
      emitDebounce = Timer(const Duration(milliseconds: 50), () {
        if (!disposed && !streamController.isClosed) {
          streamController.add(messages);
        }
      });
    }

    // Use syncService for an initial full sync once we subscribe
    ChatSyncService? syncService;
    try {
      syncService = ref.read(chatSyncProvider(matchId));
    } catch (e) {
      // debugPrint('chatSyncProvider init failed for $matchId: $e\n$st');
      syncService = null; // don't fail the provider; fall back to local-only
    }

    final channelName = 'public:chat_messages:match_id=eq.$matchId';
    RealtimeChannel? channel;

    // Always emit local cached messages immediately (offline-first).
    final localSubscription = localStream.listen((messagesData) async {
      // Reduced logging to avoid spam - only log message count changes
      if (disposed || streamController.isClosed) return;
      try {
        // Normalize incoming local cache items to guard against inconsistent types (web IndexedDB variations).
        final normalized = messagesData.map((json) {
          try {
            // Ensure keys are strings and critical IDs are strings
            if (json.containsKey('sender_id') &&
                json['sender_id'] != null &&
                json['sender_id'] is! String) {
              json['sender_id'] = json['sender_id'].toString();
            }
            if (json.containsKey('match_id') &&
                json['match_id'] != null &&
                json['match_id'] is! String) {
              json['match_id'] = json['match_id'].toString();
            }
            if (json.containsKey('id') &&
                json['id'] != null &&
                json['id'] is! String) {
              json['id'] = json['id'].toString();
            }
            // Ensure reaction_summary is a Map if present; otherwise coerce to empty map
            if (json.containsKey('reaction_summary') &&
                json['reaction_summary'] is! Map) {
              json['reaction_summary'] = <String, int>{};
            }
          } catch (_) {}
          return json;
        }).toList();

        var models = normalized
            .map((json) => ChatMessageModel.fromJson(json))
            .toList();

        // Phase 1 — Emit raw models immediately so the loading spinner
        // disappears.  Decryption runs asynchronously in Phase 2.
        final byIdPhase1 = <String, ChatMessageModel>{};
        for (final m in models) {
          byIdPhase1[m.id] = m;
        }
        final resolvedPhase1 = models.map((m) {
          final replyId = m.replyToMessageId;
          if (replyId == null) return m;
          final original = byIdPhase1[replyId];
          if (original == null) return m;
          return m.copyWith(
            replyToSenderId: original.senderId,
            replyToContent: original.contentOriginal,
            replyToContentTranslated: replyQuotedTranslatedText(original),
          );
        }).toList();
        debugPrint(
          '✨ [Phase1] Emitting ${resolvedPhase1.length} messages to UI',
        );
        debouncedEmit(resolvedPhase1);

        // Phase 2 — Decrypt v1 encrypted messages in the background
        // and re-emit when done.
        try {
          debugPrint(
            '🔓 [Phase2] Starting decryption for ${models.length} messages',
          );
          final chatKeyState = ref.read(chatKeyProvider);
          final currentUserId = supabase.auth.currentUser?.id;
          final chatKeyService = ChatKeyService.instance;
          final decryptedUpdates = <Map<String, dynamic>>[];
          final cleanupTranslations = <String>[];
          if (currentUserId != null) {
            final locale = ref.read(localizationProvider);
            final uiLang = locale.currentLocale.languageCode;
            final normalizedTarget = normalizeLanguageCode(uiLang);

            // Phase 2 — Decrypt all v1 encrypted messages IN PARALLEL so
            // N messages take ~per_msg_time instead of N × per_msg_time.
            final results = await Future.wait(
              List.generate(models.length, (i) async {
                final m = models[i];
                String? decryptedOriginal;
                String? decryptedTranslated;
                bool attemptedDecryption = false;

                if (m.encryptionScheme == 'v1' &&
                    m.contentOriginalEncrypted != null &&
                    m.contentOriginalEncrypted!.isNotEmpty &&
                    m.contentOriginalNonce != null &&
                    m.wrappedKeys != null &&
                    m.contentOriginal.isEmpty) {
                  if (chatKeyState.privateKeyBytes != null) {
                    attemptedDecryption = true;
                    try {
                      decryptedOriginal = await chatKeyService
                          .decryptMessageContent(
                            currentUserId: currentUserId,
                            currentUserPrivateKey:
                                chatKeyState.privateKeyBytes!,
                            messageId: m.id,
                            matchId: m.matchId,
                            senderId: m.senderId,
                            senderKeyId: m.senderKeyId!,
                            recipientKeyId: m.recipientKeyId!,
                            contentOriginalEncryptedBase64:
                                m.contentOriginalEncrypted!,
                            contentOriginalNonceBase64: m.contentOriginalNonce!,
                            wrappedKeys: m.wrappedKeys!,
                            recipientId:
                                m.recipientId != null &&
                                    m.recipientId!.isNotEmpty
                                ? m.recipientId
                                : null,
                          );
                      if (decryptedOriginal == null) {
                        debugPrint(
                          '❌ [Phase2] decryptMessageContent returned null for msg=${m.id} sender=${m.senderId} senderKey=${m.senderKeyId} recipientKey=${m.recipientKeyId} — likely AAD/shared-secret/wrap mismatch',
                        );
                      }
                    } catch (decErr) {
                      debugPrint(
                        '❌ [Phase2] decryptMessageContent threw for msg=${m.id} sender=${m.senderId} senderKey=${m.senderKeyId} recipientKey=${m.recipientKeyId} error=$decErr',
                      );
                    }
                  } else {
                    debugPrint(
                      '⚠️ [Phase2] No private key for msg=${m.id} sender=${m.senderId} — message will stay as "Loading..."',
                    );
                  }
                  if (decryptedOriginal == null) {
                    try {
                      final cached =
                          normalized[i]['content_original_encrypted_cache']
                              as String?;
                      if (cached != null && cached.isNotEmpty) {
                        decryptedOriginal = await EncryptedCacheService.instance
                            .decryptFromCache(cached);
                      }
                    } catch (_) {}
                  }
                }

                if (m.encryptionScheme == 'v1' &&
                    m.contentTranslatedEncrypted != null &&
                    m.contentTranslatedEncrypted!.isNotEmpty &&
                    m.contentTranslatedNonce != null &&
                    m.wrappedKeys != null &&
                    (m.contentTranslated == null ||
                        m.contentTranslated!.isEmpty)) {
                  if (chatKeyState.privateKeyBytes != null) {
                    final sourceLang = m.detectedSourceLanguage;
                    final storedTarget = m.translatedTargetLanguage;
                    if (sourceLang != null &&
                        sourceLang.isNotEmpty &&
                        isValidLanguageCode(sourceLang) &&
                        storedTarget != null &&
                        storedTarget.isNotEmpty &&
                        normalizeLanguageCode(storedTarget) ==
                            normalizedTarget) {
                      try {
                        decryptedTranslated = await chatKeyService
                            .decryptMessageTranslatedContent(
                              currentUserId: currentUserId,
                              currentUserPrivateKey:
                                  chatKeyState.privateKeyBytes!,
                              messageId: m.id,
                              matchId: m.matchId,
                              senderId: m.senderId,
                              senderKeyId: m.senderKeyId!,
                              recipientKeyId: m.recipientKeyId!,
                              contentTranslatedEncryptedBase64:
                                  m.contentTranslatedEncrypted!,
                              contentTranslatedNonceBase64:
                                  m.contentTranslatedNonce!,
                              wrappedKeys: m.wrappedKeys!,
                              detectedSourceLanguage: sourceLang,
                              targetLanguage: normalizedTarget,
                              recipientId:
                                  m.recipientId != null &&
                                      m.recipientId!.isNotEmpty
                                  ? m.recipientId
                                  : null,
                            );
                      } catch (e) {
                        debugPrint(
                          '[chatMessagesProvider] decryptMessageTranslatedContent failed: $e',
                        );
                        debugPrint(
                          '  MID: ${m.id} src=$sourceLang tgt=$normalizedTarget storedTarget=$storedTarget sender=${m.senderId}',
                        );
                      }
                    }
                  }
                  if (decryptedTranslated == null) {
                    try {
                      final cached =
                          normalized[i]['content_translated_encrypted_cache']
                              as String?;
                      if (cached != null && cached.isNotEmpty) {
                        decryptedTranslated = await EncryptedCacheService
                            .instance
                            .decryptFromCache(cached);
                      }
                    } catch (e) {
                      debugPrint(
                        '[chatMessagesProvider] cache fallback failed: $e',
                      );
                    }
                  }
                }
                return {
                  'i': i,
                  'original': decryptedOriginal,
                  'translated': decryptedTranslated,
                  'attempted': attemptedDecryption,
                  'failed': attemptedDecryption && decryptedOriginal == null,
                };
              }),
            );

            // Apply all decrypted content to models and collect DB writes.
            for (final r in results) {
              final idx = r['i'] as int;
              final decryptedOriginal = r['original'] as String?;
              final decryptedTranslated = r['translated'] as String?;
              final m = models[idx];
              // Only add to DB write if the original content was empty (prevents infinite loops)
              if (decryptedOriginal != null &&
                  decryptedOriginal.isNotEmpty &&
                  m.contentOriginal.isEmpty) {
                models[idx] = m.copyWith(contentOriginal: decryptedOriginal);
                decryptedUpdates.add({
                  'id': m.id,
                  'content_original': decryptedOriginal,
                });
              }
              if (decryptedTranslated != null &&
                  decryptedTranslated.isNotEmpty &&
                  (m.contentTranslated == null ||
                      m.contentTranslated!.isEmpty)) {
                models[idx] = m.copyWith(
                  contentTranslated: decryptedTranslated,
                  translatedText: decryptedTranslated,
                );
                decryptedUpdates.add({
                  'id': m.id,
                  'content_translated': decryptedTranslated,
                });
                // Propagate this message's translation to any locally cached
                // reply that quotes it, so reply previews render translated
                // immediately (memory + local storage) and survive restarts
                // even when Supabase is unreachable. The final byId
                // resolution below also covers the in-memory emit; this
                // persists it to Hive for cold-start offline display.
                for (int j = 0; j < models.length; j++) {
                  if (j == idx) continue;
                  final quoting = models[j];
                  if (quoting.replyToMessageId == null ||
                      quoting.replyToMessageId != m.id) {
                    continue;
                  }
                  if (quoting.replyToContentTranslated == null ||
                      quoting.replyToContentTranslated!.isEmpty) {
                    models[j] = quoting.copyWith(
                      replyToContentTranslated: decryptedTranslated,
                    );
                    decryptedUpdates.add({
                      'id': quoting.id,
                      'reply_to_content_translated': decryptedTranslated,
                    });
                  }
                }
              } else if (chatKeyState.privateKeyBytes != null &&
                  m.contentTranslatedEncrypted != null &&
                  m.encryptionScheme == 'v1') {
                cleanupTranslations.add(m.id);
              }
            }

            // If a v1-encrypted message sent by the current user (cross-device
            // send) failed to decrypt, the most likely cause is a stale or
            // missing local key. Trigger a key-provider refresh which will
            // re-run the auto-heal: stale-key detection for an existing local
            // key, or key recovery/rotation when no key is present.
            // Guarded: only count messages where decryption was actually
            // attempted (i.e. plaintext was empty) to avoid false positives
            // for the sender's own optimistic messages that already carry
            // plaintext in the local row. Also debounced to prevent
            // infinite-loop thrash if the underlying issue is something else.
            final crossDeviceFailures = results
                .where((r) => r['failed'] == true)
                .length;
            final now = DateTime.now();
            final shouldTrigger =
                crossDeviceFailures > 0 &&
                chatKeyState.isLoaded &&
                (lastAutoHealTriggeredAt == null ||
                    now.difference(lastAutoHealTriggeredAt!) >
                        const Duration(seconds: 30));
            if (shouldTrigger) {
              lastAutoHealTriggeredAt = now;
              debugPrint(
                '🔁 [Phase2] $crossDeviceFailures cross-device message(s) failed to decrypt — refreshing chat key provider (likely stale local key)',
              );
              try {
                // Defer to avoid mutating providers mid-Phase-2.
                Future.microtask(() async {
                  try {
                    await ref.read(chatKeyProvider.notifier).refresh();
                    debugPrint(
                      '✅ [Phase2] Chat key provider refreshed after cross-device failure',
                    );
                  } catch (e) {
                    debugPrint(
                      '⚠️ [Phase2] Chat key provider refresh failed: $e',
                    );
                  }
                });
              } catch (_) {}
            } else if (crossDeviceFailures > 0) {
              debugPrint(
                '⏸️ [Phase2] $crossDeviceFailures cross-device failure(s) detected, but auto-heal debounced (last=${lastAutoHealTriggeredAt?.toIso8601String()})',
              );
            }
          }

          // Persist all decrypted content — single batch write.
          // ENABLED with guard: Only write when content changes from empty to non-empty.
          // This prevents infinite watch loops while ensuring decrypted content persists
          // across stream re-emissions. The guard in the loop above ensures we only
          // write when the original DB value was empty.
          if (decryptedUpdates.isNotEmpty) {
            try {
              await localDb.mergeMessages(matchId, decryptedUpdates);
            } catch (_) {}
            // Mirror translations to local-storage prefs as well (secondary
            // fallback for cold-start offline display when Hive is slow).
            // Values are stored encrypted (see _persistTranslation) — the
            // shared helper keeps the format consistent.
            try {
              String? prefsTarget;
              try {
                prefsTarget = normalizeLanguageCode(
                  ref.read(localizationProvider).currentLocale.languageCode,
                );
              } catch (_) {}
              if (prefsTarget != null && prefsTarget.isNotEmpty) {
                for (final u in decryptedUpdates) {
                  final mid = u['id']?.toString();
                  final tr = u['content_translated']?.toString();
                  if (mid != null &&
                      mid.isNotEmpty &&
                      tr != null &&
                      tr.isNotEmpty) {
                    unawaited(_persistTranslation(mid, prefsTarget, tr));
                    _translationResultCache['$mid|$prefsTarget'] =
                        _TranslationCacheEntry(
                          tr,
                          ref.read(translationVersionProvider),
                        );
                  }
                }
              }
            } catch (_) {}
          }

          // Clean up translations that failed to decrypt — DISABLED for same reason.
          // Translation cleanup writes also trigger the watch loop. These encrypted
          // translations will simply remain in the DB and be skipped during Phase 2
          // decryption (no harm, just unused data).
          //
          // for (final mid in cleanupTranslations) {
          //   try {
          //     await localDb.mergeMessages(matchId, [{
          //       'id': mid,
          //       'content_translated_encrypted': null,
          //       'content_translated_nonce': null,
          //     }]);
          //   } catch (_) {}
          // }

          // Update the chats-box last-message preview is also commented out to avoid
          // triggering additional DB writes during Phase 2. The preview will be updated
          // by the sendMessage flow (after INSERT) and by sync operations, which is
          // sufficient for keeping the chat list current.
          //
          // if (currentUserId != null) {
          //   try {
          //     await localDb.recomputeChatLastMessagePreviewFromMessages(
          //       currentUserId,
          //       matchId,
          //     );
          //   } catch (_) {}
          // }

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
              replyToContentTranslated: replyQuotedTranslatedText(original),
            );
          }).toList();

          debouncedEmit(resolved);
          // Persist resolved reply previews to Hive (best-effort, no await)
          // so incoming reply quotes survive app restarts and render
          // immediately offline. Only writes rows that gained a preview.
          try {
            final replyWrites = <Map<String, dynamic>>[];
            // Need the pre-resolution rows to diff against; re-read cheaply
            // from the already-loaded normalized cache.
            for (final r in resolved) {
              if (r.replyToMessageId == null) continue;
              final hasPreview =
                  (r.replyToContent != null && r.replyToContent!.isNotEmpty) ||
                  (r.replyToContentTranslated != null &&
                      r.replyToContentTranslated!.isNotEmpty);
              if (!hasPreview) continue;
              replyWrites.add({
                'id': r.id,
                'reply_to_sender_id': r.replyToSenderId,
                'reply_to_content': r.replyToContent,
                if (r.replyToContentTranslated != null &&
                    r.replyToContentTranslated!.isNotEmpty)
                  'reply_to_content_translated': r.replyToContentTranslated,
              });
            }
            if (replyWrites.isNotEmpty) {
              unawaited(
                localDb.mergeMessages(matchId, replyWrites).catchError((_) {}),
              );
            }
          } catch (_) {}
          debugPrint(
            '🔓 [Phase2] Completed - emitted ${resolved.length} messages (${decryptedUpdates.length} decrypted)',
          );
        } catch (_) {
          // Phase 2 best-effort; Phase 1 emission already happened.
        }

        // If there are no messages locally and we haven't scheduled an initial recovery sync,
        // schedule a few background sync attempts to cover intermittent failures (e.g., slow IndexedDB).
        if ((messagesData.isEmpty) &&
            !scheduledInitialSync &&
            syncService != null) {
          scheduledInitialSync = true;
          Future(() async {
            // debugPrint('chatMessagesProvider: initial empty local cache for $matchId; scheduling recovery sync attempts');
            final delays = [
              const Duration(seconds: 1),
              const Duration(seconds: 2),
              const Duration(seconds: 4),
            ];
            for (var i = 0; i < delays.length; i++) {
              try {
                await Future.delayed(delays[i]);
                // debugPrint('chatMessagesProvider: recovery sync attempt #${i + 1} for $matchId');
                await syncService!.syncMessages(matchId);
                // debugPrint('chatMessagesProvider: recovery sync successful for $matchId on attempt #${i + 1}');
                break;
              } catch (e) {
                // debugPrint('chatMessagesProvider: recovery sync attempt #${i + 1} failed for $matchId: $e\n$st');
              }
            }
          });
        }
      } catch (e) {
        // Log parsing errors so we can see why the stream isn't emitting
        try {
          // debugPrint('chatMessagesProvider: failed to parse local messages for $matchId: $e\n$st');
          if (messagesData.isNotEmpty) {
            // debugPrint('chatMessagesProvider: sample problematic message: ${messagesData.first}');
          }
        } catch (_) {}
      }
    });

    /// True when [oldRow] looks like a REPLICA IDENTITY DEFAULT payload:
    /// only the PK (and at most one bookkeeping key), no content columns.
    bool isPkOnlyOldRecord(Map<String, dynamic> oldRow) {
      if (oldRow.isEmpty) return true;
      if (oldRow.containsKey('match_id') ||
          oldRow.containsKey('sender_id') ||
          oldRow.containsKey('content_original_encrypted') ||
          oldRow.containsKey('delivered_at') ||
          oldRow.containsKey('read_at')) {
        return false;
      }
      return true;
    }

    /// Normalized scalar compare: treats null/missing/'' as equal and
    /// stringifies Maps/Lists deterministically.
    String normFieldValue(dynamic v) {
      if (v == null) return '';
      if (v is Map || v is List) {
        try {
          return jsonEncode(v);
        } catch (_) {
          return v.toString();
        }
      }
      return v.toString();
    }

    /// Returns true when [newRow] and [oldRow] only differ in status fields
    /// (read_at / delivered_at / reaction_summary / my_reaction) and not in
    /// any content / metadata field that would require a full re-sync.
    ///
    /// NOTE: `chat_messages` uses REPLICA IDENTITY DEFAULT, so realtime
    /// UPDATE payloads carry a PK-only oldRecord (`{id}`). In that case this
    /// returns false by design — callers must fall back to
    /// [isStatusOnlyVsCached], which compares the realtime newRecord against
    /// the local Hive row instead.
    bool isStatusOnlyChange(
      Map<String, dynamic> oldRow,
      Map<String, dynamic> newRow,
    ) {
      // PK-only oldRecord (REPLICA IDENTITY DEFAULT): cannot tell what
      // changed from old-vs-new, so decline and let the caller compare
      // newRecord against the local cache.
      if (isPkOnlyOldRecord(oldRow)) return false;
      const statusFields = <String>{
        'read_at',
        'delivered_at',
        'reaction_summary',
        'my_reaction',
      };
      for (final entry in newRow.entries) {
        if (statusFields.contains(entry.key)) continue;
        if (oldRow[entry.key] != entry.value) return false;
      }
      for (final entry in oldRow.entries) {
        if (statusFields.contains(entry.key)) continue;
        if (!newRow.containsKey(entry.key)) return false;
      }
      return true;
    }

    /// Status-only check against the LOCAL cached row instead of the realtime
    /// oldRecord. Returns true when every non-status field in [newRow] matches
    /// [cachedRow]. Local-only keys (`isPending`) are ignored.
    bool isStatusOnlyVsCached(
      Map<String, dynamic> cachedRow,
      Map<String, dynamic> newRow,
    ) {
      const statusFields = <String>{
        'read_at',
        'delivered_at',
        'reaction_summary',
        'my_reaction',
      };
      const localOnlyFields = <String>{'isPending'};
      final keys = <String>{
        ...cachedRow.keys.map((k) => k.toString()),
        ...newRow.keys.map((k) => k.toString()),
      };
      for (final key in keys) {
        if (statusFields.contains(key)) continue;
        if (localOnlyFields.contains(key)) continue;
        if (normFieldValue(cachedRow[key]) != normFieldValue(newRow[key])) {
          return false;
        }
      }
      return true;
    }

    /// Encrypted-content-only check against the LOCAL cached row: true when
    /// the only differences vs [cachedRow] are translation/ciphertext/metadata
    /// columns (i.e. safe to `mergeMessages` a single row instead of a full
    /// re-select + full Hive rewrite + full re-decrypt).
    bool isEncryptedContentOnlyVsCached(
      Map<String, dynamic> cachedRow,
      Map<String, dynamic> newRow,
    ) {
      const excludedFields = <String>{
        'read_at',
        'delivered_at',
        'reaction_summary',
        'my_reaction',
        'content_translated_encrypted',
        'content_translated_nonce',
        'translated_target_language',
        'translated_source_edited_at',
        'detected_source_language',
        'edited_at',
      };
      const localOnlyFields = <String>{'isPending'};
      final keys = <String>{
        ...cachedRow.keys.map((k) => k.toString()),
        ...newRow.keys.map((k) => k.toString()),
      };
      for (final key in keys) {
        if (excludedFields.contains(key)) continue;
        if (localOnlyFields.contains(key)) continue;
        if (normFieldValue(cachedRow[key]) != normFieldValue(newRow[key])) {
          return false;
        }
      }
      return true;
    }

    /// True iff the only differing fields between [oldRow] and [newRow] are
    /// the encrypted-content columns (or other non-status metadata like
    /// `edited_at`, `detected_source_language`, `translated_target_language`).
    /// Used by the per-match realtime channel's fast path so a translation
    /// UPDATE or content edit doesn't force a full table re-select + full
    /// Hive re-write + full re-decrypt cycle.
    ///
    /// Same REPLICA IDENTITY caveat as [isStatusOnlyChange]: returns false
    /// for PK-only oldRecords — callers must use [isEncryptedContentOnlyVsCached].
    bool isEncryptedContentChange(
      Map<String, dynamic> oldRow,
      Map<String, dynamic> newRow,
    ) {
      if (isPkOnlyOldRecord(oldRow)) return false;
      const excludedFields = <String>{
        'read_at',
        'delivered_at',
        'reaction_summary',
        'my_reaction',
        'content_translated_encrypted',
        'content_translated_nonce',
        'translated_target_language',
        'translated_source_edited_at',
        'detected_source_language',
        'edited_at',
      };
      for (final entry in newRow.entries) {
        if (excludedFields.contains(entry.key)) continue;
        if (oldRow[entry.key] != entry.value) return false;
      }
      for (final entry in oldRow.entries) {
        if (excludedFields.contains(entry.key)) continue;
        if (!newRow.containsKey(entry.key)) return false;
      }
      return true;
    }

    /// Applies a status-only realtime update to the local cache without
    /// triggering a full sync or Phase 2 re-decryption.
    Future<void> applyStatusOnlyUpdate(
      String matchId,
      Map<String, dynamic> newRow,
      Map<String, dynamic> oldRow,
    ) async {
      final messageId = newRow['id']?.toString();
      if (messageId == null || messageId.isEmpty) return;

      String? readAt;
      if (newRow['read_at'] != null && newRow['read_at'] != oldRow['read_at']) {
        readAt = newRow['read_at'].toString();
      }
      String? deliveredAt;
      if (newRow['delivered_at'] != null &&
          newRow['delivered_at'] != oldRow['delivered_at']) {
        deliveredAt = newRow['delivered_at'].toString();
      }
      Map<String, int>? reactionSummary;
      if (newRow['reaction_summary'] != null &&
          newRow['reaction_summary'] != oldRow['reaction_summary']) {
        final raw = newRow['reaction_summary'];
        if (raw is Map) {
          reactionSummary = <String, int>{};
          raw.forEach((k, v) {
            final key = k?.toString() ?? '';
            if (key.isEmpty) return;
            final intVal = v is num
                ? v.toInt()
                : (int.tryParse(v.toString()) ?? 0);
            if (intVal > 0) reactionSummary![key] = intVal;
          });
        }
      }
      String? myReaction;
      var clearMyReaction = false;
      if (newRow['my_reaction'] != oldRow['my_reaction']) {
        final mr = newRow['my_reaction'];
        if (mr == null || (mr is String && mr.isEmpty)) {
          clearMyReaction = true;
        } else {
          myReaction = mr.toString();
        }
      }

      if (readAt == null &&
          deliveredAt == null &&
          reactionSummary == null &&
          myReaction == null &&
          !clearMyReaction) {
        return;
      }

      try {
        final localDb = ref.read(localDbProvider);
        await localDb.mergeMessageStatus(
          matchId,
          messageId,
          readAt: readAt,
          deliveredAt: deliveredAt,
          reactionSummary: reactionSummary,
          myReaction: myReaction,
          clearMyReaction: clearMyReaction,
        );
      } catch (_) {
        // Best-effort; if the merge fails, the next full sync will fix it.
      }
    }

    Future<void> handleChanges(PostgresChangePayload payload) async {
      if (disposed || !ref.mounted) {
        return;
      }
      final event = payload.eventType;
      if (event != PostgresChangeEvent.insert &&
          event != PostgresChangeEvent.update &&
          event != PostgresChangeEvent.delete) {
        return;
      }

      // Fast path: for UPDATE events whose only change is a status field
      // (read_at / delivered_at / reaction_summary / my_reaction), update
      // the single message in the local cache directly.  This avoids a full
      // re-query of every message in the match and a re-decrypt cycle, so the
      // sender's checkmarks switch from single → double → blue in real time
      // the way WhatsApp / Telegram do, instead of after a multi-second
      // background sync.
      //
      // chat_messages uses REPLICA IDENTITY DEFAULT, so payload.oldRecord is
      // PK-only and an old-vs-new comparison can never succeed. Compare the
      // realtime newRecord against the local Hive row instead.
      if (event == PostgresChangeEvent.update) {
        // Cheap path first: works when the DB ever moves to REPLICA IDENTITY
        // FULL (or for tables that already have it).
        if (isStatusOnlyChange(payload.oldRecord, payload.newRecord)) {
          try {
            await applyStatusOnlyUpdate(
              matchId,
              payload.newRecord,
              payload.oldRecord,
            );
          } catch (_) {
            // Best-effort; fall through to the full sync on failure.
          }
          return;
        }
        // Robust path: PK-only oldRecord → diff newRecord vs local cache.
        try {
          final newRecord = payload.newRecord;
          if (newRecord['match_id']?.toString() == matchId) {
            final messageId = newRecord['id']?.toString();
            if (messageId != null && messageId.isNotEmpty) {
              final cached = await localDb.getMessageById(matchId, messageId);
              if (cached == null) {
                // UPDATE for a row we never cached (replay / out-of-order /
                // arrived before initial sync): merge the payload row directly
                // instead of paying for a full re-select.
                await localDb.mergeMessages(matchId, [newRecord]);
                return;
              }
              if (isStatusOnlyVsCached(cached, newRecord)) {
                await applyStatusOnlyUpdate(matchId, newRecord, cached);
                return;
              }
              // Not status-only → fall through to the encrypted-content and
              // genuine-edit handlers below (they also compare vs local).
            }
          }
        } catch (_) {
          // Fall through to the full sync on any failure.
        }
      }

      // Fast path: for INSERT events the realtime payload IS the new row.
      // Insert it into the local cache directly instead of doing a full
      // from('chat_messages').select(...).eq('match_id', matchId) round-trip
      // + full Hive re-write + Phase 2 re-decrypt cycle. The full sync is
      // still done on initial subscribe (catch-up) so we never lose
      // messages — we just stop paying the round-trip + N-row JSON
      // re-encode cost on every realtime event.
      //
      // Why this matters: previously every INSERT debounced 120 ms, then
      // hit Supabase, then rewrote the entire chat_messages JSON blob for
      // the match, then ran Phase 1 → Phase 2 decryption again on every
      // message in the chat. For a 100-message chat this is several
      // hundred ms of network + serialization + AES-GCM work that the
      // user has to wait through before the new bubble appears.
      if (event == PostgresChangeEvent.insert) {
        try {
          final newRecord = payload.newRecord;
          final newMatchId = newRecord['match_id']?.toString();
          if (newMatchId == matchId) {
            final currentUserId = supabase.auth.currentUser?.id;
            await localDb.addMessages(matchId, [
              newRecord,
            ], currentUserId: currentUserId);
            // If the message is incoming, mark it delivered in the
            // background. We don't await — the bubble can show without
            // waiting for the RPC.
            if (currentUserId != null &&
                newRecord['sender_id']?.toString() != currentUserId) {
              final mid = newRecord['id']?.toString();
              if (mid != null && mid.isNotEmpty) {
                unawaited(
                  supabase
                      .rpc(
                        'mark_message_delivered',
                        params: {'p_message_id': mid},
                      )
                      .catchError((e) {
                        // Best-effort; the next sync will reconcile.
                      }),
                );
              }
            }
            return;
          }
        } catch (_) {
          // Fall through to the full sync on any failure.
        }
      }

      // Retraction: a peer edit changes `edited_at`, so any tray card showing
      // the old text is stale. Dismiss it (native history is cleared too);
      // Android then re-checks the RPC latest so remaining unreads re-post.
      // Translation-only UPDATEs don't touch `edited_at` and keep the tray.
      // An edit also invalidates any cached translation of the old content:
      // when the edited message is incoming and was translated to the
      // current UI language, drop the stale cache immediately so
      // translationFamilyProvider retranslates the new content (Case A)
      // instead of reusing the old translation.
      //
      // Genuine-edit verification: realtime oldRecord is typically PK-only
      // (replica identity), so comparing payload old-vs-new edited_at fires
      // on EVERY update of an edited message — including translate-proxy's
      // own claim/final writes. Reacting to those (merge/clear/bump, let
      // alone server writes) would steal in-flight translation claims in a
      // loop ("Claim lost ... discarding our translation" forever, ending
      // with no translation at all). Instead verify against the local cache:
      // an edit is genuine only if it carries ciphertext (or edited_at) the
      // local row doesn't have yet. Replays then no-op (idempotent).
      if (event == PostgresChangeEvent.update) {
        try {
          final newEdited = payload.newRecord['edited_at']?.toString();
          final newRecordId = payload.newRecord['id']?.toString();
          bool isGenuineEdit = false;
          Map<String, dynamic> localMsgForEdit = {};
          if (newEdited != null &&
              newEdited.isNotEmpty &&
              newRecordId != null &&
              newRecordId.isNotEmpty) {
            try {
              final cached = await localDb.getMessages(matchId);
              localMsgForEdit = cached.firstWhere(
                (m) => m['id']?.toString() == newRecordId,
                orElse: () => {},
              );
              if (localMsgForEdit.isEmpty) {
                // First sight of an edited message (e.g. realtime arrived
                // before the initial sync cached it).
                isGenuineEdit = true;
              } else {
                final newCipher = payload
                    .newRecord['content_original_encrypted']
                    ?.toString();
                final localCipher =
                    localMsgForEdit['content_original_encrypted']?.toString();
                if (newCipher != null &&
                    newCipher.isNotEmpty &&
                    localCipher != null &&
                    localCipher.isNotEmpty &&
                    newCipher != localCipher) {
                  isGenuineEdit = true;
                } else if (localMsgForEdit['edited_at']?.toString() !=
                    newEdited) {
                  isGenuineEdit = true;
                }
              }
            } catch (_) {}
          }
          if (isGenuineEdit) {
            unawaited(_dismissStaleTray(matchId));
            try {
              final currentUserId = supabase.auth.currentUser?.id;
              final senderId =
                  payload.newRecord['sender_id']?.toString() ??
                  payload.oldRecord['sender_id']?.toString();
              final messageId = newRecordId;
              final isIncoming =
                  currentUserId != null &&
                  senderId != null &&
                  senderId != currentUserId &&
                  messageId != null &&
                  messageId.isNotEmpty;
              if (isIncoming && ref.mounted) {
                bool translationEnabled = false;
                try {
                  translationEnabled =
                      ref.read(translationProvider)[matchId] != null;
                } catch (_) {
                  translationEnabled = false;
                }
                if (translationEnabled) {
                  String targetLanguage = '';
                  try {
                    targetLanguage = normalizeLanguageCode(
                      ref.read(localizationProvider).currentLocale.languageCode,
                    );
                  } catch (_) {
                    targetLanguage = '';
                  }
                  if (targetLanguage.isNotEmpty) {
                    // Determine whether the edited message had been
                    // translated to the current UI language. Check the
                    // realtime payload first, then fall back to the local
                    // cache (payload oldRecord may be incomplete and
                    // encrypted rows never carry plaintext in the payload).
                    bool hadTranslationForUi = false;
                    bool hadCachedPlain = false;
                    try {
                      final oldTargetRaw =
                          (payload.oldRecord['translated_target_language'] ??
                                  payload.oldRecord['translated_lang'])
                              ?.toString() ??
                          (payload.newRecord['translated_target_language'] ??
                                  payload.newRecord['translated_lang'])
                              ?.toString() ??
                          '';
                      if (oldTargetRaw.isNotEmpty &&
                          normalizeLanguageCode(oldTargetRaw) ==
                              targetLanguage) {
                        hadTranslationForUi = true;
                      }
                      if ((payload.oldRecord['content_translated']
                                  ?.toString()
                                  .isNotEmpty ==
                              true) ||
                          (payload.newRecord['content_translated']
                                  ?.toString()
                                  .isNotEmpty ==
                              true)) {
                        hadCachedPlain = true;
                      }
                    } catch (_) {}
                    if (!hadTranslationForUi && !hadCachedPlain) {
                      // Reuse the row already fetched for genuine-edit
                      // verification above instead of re-reading the cache.
                      try {
                        final localMsg = localMsgForEdit;
                        if (localMsg.isNotEmpty) {
                          final localTarget =
                              (localMsg['translated_target_language'] ??
                                      localMsg['translated_lang'])
                                  ?.toString() ??
                              '';
                          if (localTarget.isNotEmpty &&
                              normalizeLanguageCode(localTarget) ==
                                  targetLanguage) {
                            hadTranslationForUi = true;
                          }
                          final localPlain =
                              (localMsg['content_translated'] ??
                                      localMsg['translated_text'])
                                  ?.toString() ??
                              '';
                          if (localPlain.isNotEmpty && localPlain != 'null') {
                            hadCachedPlain = true;
                          }
                          // Even without a cached plaintext, an encrypted
                          // translation payload for the current UI means the
                          // message was translated.
                          if (!hadTranslationForUi && !hadCachedPlain) {
                            final hasEnc =
                                (localMsg['content_translated_encrypted']
                                        ?.toString()
                                        .isNotEmpty ==
                                    true) &&
                                localTarget.isNotEmpty &&
                                normalizeLanguageCode(localTarget) ==
                                    targetLanguage;
                            if (hasEnc) hadTranslationForUi = true;
                          }
                        }
                      } catch (_) {}
                    }
                    if (hadTranslationForUi || hadCachedPlain) {
                      // Merge the edited row immediately so the new
                      // ciphertext is in the local cache (mergeMessages
                      // drops the stale translation of the old content).
                      try {
                        await localDb.mergeMessages(matchId, [
                          payload.newRecord,
                        ]);
                      } catch (_) {}
                      try {
                        await localDb.clearCachedTranslationsForMessages(
                          matchId,
                          [messageId],
                        );
                      } catch (_) {}
                      // An edit keeps the message id, so the Recent Chats
                      // preview is keyed to the same row and would otherwise
                      // keep rendering the translation of the text the peer
                      // replaced. Drop it here — the chat-list pipeline then
                      // shows its loading state and refills from the
                      // translation this very edit triggers, rather than
                      // depending on the user to re-enter the chat.
                      try {
                        await localDb.updateChatLastMessageTranslation(
                          currentUserId,
                          matchId,
                          messageId,
                          null,
                        );
                      } catch (_) {}
                      // The version bump re-evaluates the bubble: with the local
                      // cache cleared it takes Case A, and the edge skips only
                      // marker-matching rows, so the new content is translated
                      // exactly once.
                      // NOTE: never NULL the server translation columns here:
                      // that unconditional write also destroys translate-proxy
                      // `#pending#` claim markers, making every in-flight
                      // translation fail with "Claim lost" in a loop.
                      try {
                        ref
                            .read(translationVersionProvider.notifier)
                            .increment();
                      } catch (_) {}
                    }
                  }
                }
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      // Fast path: for UPDATE events that change encrypted-content fields
      // (the typical "server just wrote content_translated_encrypted"
      // case) the payload row carries the new values. Merge just the
      // changed message into the local cache — same rationale as the
      // INSERT path above. This avoids a multi-second full re-sync that
      // would otherwise be triggered by every translation webhook
      // delivery.
      //
      // Like the status path above, oldRecord is PK-only under REPLICA
      // IDENTITY DEFAULT, so also try the local-cache comparison.
      if (event == PostgresChangeEvent.update) {
        try {
          final newRecord = payload.newRecord;
          final oldRecord = payload.oldRecord;
          final newMatchId = newRecord['match_id']?.toString();
          if (newMatchId == matchId &&
              isEncryptedContentChange(oldRecord, newRecord)) {
            await localDb.mergeMessages(matchId, [newRecord]);
            // A translation payload just landed: re-evaluate visible bubbles
            // so Case C serves it (and stamps the chat-list preview). This is
            // network-free — cached translations short-circuit before any
            // proxy call — and the version increment is debounced, so bursts
            // of translation writes coalesce into one re-evaluation.
            try {
              if (ref.mounted) {
                ref.read(translationVersionProvider.notifier).increment();
              }
            } catch (_) {}
            return;
          }
          if (newMatchId == matchId && isPkOnlyOldRecord(oldRecord)) {
            final messageId = newRecord['id']?.toString();
            if (messageId != null && messageId.isNotEmpty) {
              final cached = await localDb.getMessageById(matchId, messageId);
              if (cached != null &&
                  isEncryptedContentOnlyVsCached(cached, newRecord)) {
                await localDb.mergeMessages(matchId, [newRecord]);
                try {
                  if (ref.mounted) {
                    ref.read(translationVersionProvider.notifier).increment();
                  }
                } catch (_) {}
                return;
              }
            }
          }
        } catch (_) {
          // Fall through to the full sync on any failure.
        }
      }

      // Fast path: DELETE events are rare (message recall); apply the
      // payload's id directly without a round-trip. The tray card may show
      // the deleted text, so dismiss it like an edit.
      if (event == PostgresChangeEvent.delete) {
        try {
          final oldRecord = payload.oldRecord;
          final deletedId = oldRecord['id']?.toString();
          if (deletedId != null && deletedId.isNotEmpty) {
            await localDb.deleteMessage(matchId, deletedId);
            unawaited(_dismissStaleTray(matchId));
            return;
          }
        } catch (_) {
          // Fall through to the full sync on any failure.
        }
      }

      if (syncService == null) return;
      realtimeSyncDebounce?.cancel();
      realtimeSyncDebounce = Timer(const Duration(milliseconds: 120), () async {
        if (disposed || !ref.mounted || syncService == null) {
          return;
        }
        try {
          await syncService.syncMessages(matchId);
        } catch (e) {
          // debugPrint('Error syncing messages on realtime change for $matchId: $e');
        }
      });
    }

    SupabaseRealtimeManager.instance.register(channelName, () {
      channel = supabase.channel(channelName);
      channel!
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'chat_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'match_id',
              value: matchId,
            ),
            callback: handleChanges,
          )
          .subscribe((status, err) async {
            if (!ref.mounted || disposed) return;
            if (status == RealtimeSubscribeStatus.subscribed) {
              // Run a full sync ONCE on subscribe, to catch up (guarded)
              try {
                if (syncService != null) {
                  await syncService.syncMessages(matchId);
                }
              } catch (e) {
                // debugPrint('Error syncing messages on subscribe for $matchId: $e');
              }
            } else if (err != null) {
              // debugPrint('Realtime subscription error for $matchId: $err');
            }
          });
      return channel!;
    });

    ref.onDispose(() {
      disposed = true;
      keepAliveTimer?.cancel();
      realtimeSyncDebounce?.cancel();
      emitDebounce?.cancel();
      localSubscription.cancel();
      SupabaseRealtimeManager.instance.unregister(channelName);
      streamController.close();
    });

    return streamController.stream;
  } catch (e) {
    // debugPrint('chatMessagesProvider failed to initialize for $matchId: $e\n$st');
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
    final sourceLang = guessLanguageCode(text);

    // Resolve the quoted preview at send time so the optimistic bubble shows
    // the reply immediately (WhatsApp-style), even before the provider's
    // byId resolution re-emits. Falls back to provider resolution afterwards.
    String? replyToSenderId;
    String? replyToContent;
    if (replyToMessageId != null && replyToMessageId.isNotEmpty) {
      try {
        final existing = await localDb.getMessages(matchId);
        for (final row in existing) {
          if (row['id']?.toString() == replyToMessageId) {
            replyToSenderId = row['sender_id']?.toString();
            final c = row['content_original']?.toString() ?? '';
            if (c.trim().isNotEmpty) replyToContent = c;
            break;
          }
        }
      } catch (_) {}
    }

    // Detect connectivity up front. When the device is offline we cannot
    // fetch the recipient's chat key from Supabase, so we cannot encrypt
    // the message. In that case the message is added optimistically to
    // the local DB (so the sender sees it immediately, with a clock icon)
    // and the plaintext is queued in the chat outbox. The
    // OutboxSyncService picks it up automatically when connectivity is
    // restored, encrypts it using the cached key, and uploads it to
    // Supabase. The queued payload survives app restarts and device
    // reboots because it lives in a persistent Hive box.
    // Supabase reachability is the only signal: if we cannot round-trip with
    // it, the recipient's chat key is not coming and the send has to take the
    // offline path. A working internet with a dead backend is still offline.
    final isOnline =
        (await probeSupabaseReachability(
          log: (m) => debugPrint('📤 [sendMessage:probe] $m'),
        )).isReachable;

    if (!isOnline) {
      // ── OFFLINE PATH ─────────────────────────────────────────────
      // Add the optimistic message to local DB so the sender sees it
      // appear immediately with the watch-later "pending" icon. We
      // intentionally do NOT include any encryption fields because we
      // could not fetch the recipient's public key. The OutboxSyncService
      // will encrypt and sync the message when the device comes back
      // online; the resulting server echo will then clear `isPending`.
      final pendingMessage = ChatMessageModel(
        id: tempId,
        matchId: matchId,
        senderId: user.id,
        contentOriginal: text,
        createdAt: DateTime.now(),
        isPending: true,
        replyToMessageId: replyToMessageId,
        replyToSenderId: replyToSenderId,
        replyToContent: replyToContent,
        encryptionScheme: '',
        translationCapable: false,
      );
      try {
        debugPrint(
          '📤 [sendMessage:offline] Adding optimistic message: $tempId',
        );
        await localDb.addMessages(matchId, [pendingMessage.toJson()]);
      } catch (e) {
        debugPrint(
          '❌ [sendMessage:offline] Error adding optimistic message: $e',
        );
      }

      // Queue the plaintext message in the persistent outbox. The
      // OutboxSyncService drains this queue when connectivity is
      // restored.
      final pendingPayload = <String, dynamic>{
        'type': 'chat_message_pending_encryption',
        'id': tempId,
        'match_id': matchId,
        'sender_id': user.id,
        'text': text,
        'reply_to_message_id': replyToMessageId,
        if (sourceLang != 'und') 'detected_source_language': sourceLang,
        'queued_at': DateTime.now().toIso8601String(),
      };
      await _saveToOutbox(pendingPayload);
      return;
    }

    // ── ONLINE PATH ────────────────────────────────────────────────
    // Try to encrypt using the helper. This requires fetching the
    // recipient's active chat key from Supabase, so it can fail for
    // reasons unrelated to connectivity (e.g. the recipient has no key
    // yet, or the user's own keys are not loaded). We treat any
    // encryption failure here as a hard error and surface it to the
    // caller — sending unencrypted messages is not allowed by design.
    final encryption = await encryptMessageContent(
      text: text,
      matchId: matchId,
      messageId: tempId,
      user: user,
    );
    if (encryption == null) {
      throw Exception(
        'Cannot send message: encryption not available. Ensure encryption keys are loaded.',
      );
    }

    final senderKeyId = encryption['sender_key_id'] as String?;
    final recipientKeyId = encryption['recipient_key_id'] as String?;
    final messageRecipientId = encryption['recipient_id'] as String?;
    final contentOriginalEncrypted =
        encryption['content_original_encrypted'] as String?;
    final contentOriginalNonce =
        encryption['content_original_nonce'] as String?;
    final wrappedKeys = encryption['wrapped_keys'] as Map<String, dynamic>?;

    final optimisticMessage = ChatMessageModel(
      id: tempId,
      matchId: matchId,
      senderId: user.id,
      contentOriginal: text,
      createdAt: DateTime.now(),
      isPending: true,
      replyToMessageId: replyToMessageId,
      replyToSenderId: replyToSenderId,
      replyToContent: replyToContent,
      encryptionScheme: 'v1',
      senderKeyId: senderKeyId,
      recipientKeyId: recipientKeyId,
      recipientId: messageRecipientId,
      contentOriginalEncrypted: contentOriginalEncrypted,
      contentOriginalNonce: contentOriginalNonce,
      wrappedKeys: wrappedKeys,
      translationCapable: false,
    );
    try {
      debugPrint('📤 [sendMessage:online] Adding optimistic message: $tempId');
      await localDb.addMessages(matchId, [optimisticMessage.toJson()]);
    } catch (e) {
      debugPrint('❌ [sendMessage:online] Error adding optimistic message: $e');
    }
    final supabasePayload = <String, dynamic>{
      'id': tempId,
      'match_id': matchId,
      'sender_id': user.id,
      if (sourceLang != 'und') 'detected_source_language': sourceLang,
      'encryption_scheme': 'v1',
      'sender_key_id': senderKeyId,
      'recipient_key_id': recipientKeyId,
      'recipient_id': messageRecipientId,
      'content_original_encrypted': contentOriginalEncrypted,
      'content_original_nonce': contentOriginalNonce,
      'wrapped_keys': wrappedKeys,
      'reply_to_message_id': replyToMessageId,
    };
    try {
      final data = await supabase
          .from('chat_messages')
          .insert(supabasePayload)
          .select();
      if (data.isEmpty) {
        throw Exception(
          'Invalid response format: expected non-empty List, got ${data.runtimeType}',
        );
      }
      final firstItem = data[0];
      // The bubble reads `message.contentOriginal` (the local decrypted
      // plaintext) FIRST and only falls back to "Loading..." if it's
      // empty AND the message is encrypted. The optimistic row we added
      // before this insert carries the user's plaintext in
      // `content_original` (snake_case — the model's toJson() key, as
      // stored in the local messages box).
      // The previous implementation called `replaceMessage` which
      // discarded the entire optimistic row and substituted the server
      // row — and the server row has `content_original=NULL` per the
      // v1 encryption constraint, so the bubble would jump back to
      // "Loading..." until Phase 2 re-decrypted the ciphertext. That's
      // the same multi-second wait we just fixed in the bubble branch,
      // but caused by the sender path instead of the receiver path.
      //
      // Fix: use `mergeMessages` (server fields over local) and
      // re-attach the optimistic plaintexts to `firstItem` so they
      // survive the merge into the local row. We do NOT touch
      // `content_original_encrypted`/`_nonce` here — those are the
      // canonical server values, and they were already on the
      // optimistic row (we sent them up in supabasePayload).
      final existingMessages = await localDb.getMessages(matchId);
      final optimisticRow = existingMessages.firstWhere(
        (m) => m['id'] == tempId,
        orElse: () => const <String, dynamic>{},
      );
      if (optimisticRow.isNotEmpty) {
        if (optimisticRow['content_original'] is String &&
            (optimisticRow['content_original'] as String).isNotEmpty) {
          firstItem['content_original'] = optimisticRow['content_original'];
        }
      }
      await localDb.mergeMessages(matchId, [firstItem]);
      // Update the chats-box last-message preview immediately so the sender
      // sees their new last message in the chat list without waiting for a
      // realtime sync round-trip.
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        user.id,
        matchId,
      );

      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId != null) {
        _ref.invalidate(recentChatsProvider(currentUserId));
      }

      // Push notification is now triggered by a database webhook on INSERT
      // to chat_messages, not by the sender's client. See migration
      // 20260604000000_setup_push_message_webhook.sql for setup details.
    } catch (e) {
      await _saveToOutbox(supabasePayload);
    }
  }

  Future<void> _saveToOutbox(Map<String, dynamic> messagePayload) async {
    final localDb = _ref.read(localDbProvider);
    await localDb.saveMessageToOutbox(messagePayload);
  }

  /// Set or clear a reaction for a message. p_reaction==null clears reaction for current user.
  Future<void> setReaction({
    required String matchId,
    required String messageId,
    String? reaction,
  }) async {
    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);

    // Debounce rapid clicks
    final key = '$matchId:$messageId';
    _reactionDebouncer[key]?.cancel();
    // debugPrint('setReaction: scheduling debounced update for $key (reaction=$reaction)');

    final completer = Completer<void>();
    _reactionDebouncer[key] = Timer(const Duration(milliseconds: 300), () async {
      // debugPrint('setReaction: debounced timer fired for $key (reaction=$reaction)');
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

  Future<void> _performSetReaction(
    String matchId,
    String messageId,
    String? reaction,
    User user,
    LocalDbService localDb,
  ) async {
    // Store original state for rollback
    final originalMessages = await localDb.getMessages(matchId);

    try {
      // Optimistic update
      // debugPrint('performSetReaction: starting optimistic update for message $messageId (reaction=$reaction)');
      await _applyOptimisticUpdate(matchId, messageId, reaction, user, localDb);
      // debugPrint('performSetReaction: optimistic update applied for message $messageId');

      // Server call
      final payload = {'p_message_id': messageId, 'p_reaction': reaction};
      // debugPrint('Calling supabase.rpc set_message_reaction with payload: $payload');

      final res = await supabase
          .rpc('set_message_reaction', params: payload)
          .single();
      // debugPrint('set_message_reaction response: $res');

      // Apply server result (may differ from optimistic)
      final Map<String, dynamic> newSummary = Map<String, dynamic>.from(
        res as Map,
      );
      // debugPrint('Applying new reaction_summary for message $messageId: $newSummary');
      await localDb.mergeMessages(matchId, [
        {
          'id': messageId,
          'reaction_summary': newSummary,
          'my_reaction': reaction,
        },
      ]);
      // debugPrint('performSetReaction: merge from server applied for message $messageId');

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
        final prevMy =
            originalMessages.firstWhere(
                  (m) => m['id']?.toString() == messageId,
                  orElse: () => {},
                )['my_reaction']
                as String?;
        if (prevMy != null && prevMy.isNotEmpty) keys.add(prevMy);

        if (keys.isNotEmpty) {
          await _refreshCachedReactors(matchId, messageId, keys, localDb);
        }
      } catch (e) {
        // debugPrint('Failed to refresh cached reactors after setReaction: $e');
      }
    } catch (e) {
      // debugPrint('set_message_reaction failed for message $messageId with error: $e\n$st');
      // Rollback optimistic update
      // debugPrint('performSetReaction: rolling back optimistic update for message $messageId');
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      rethrow;
    }
  }

  /// Encrypt message content for a given match. Returns null if encryption is not possible.
  /// Extracted from [sendMessage] for reuse in [editMessage] and the outbox
  /// sync service (so that messages queued while offline get encrypted the
  /// moment connectivity is restored).
  Future<Map<String, dynamic>?> encryptMessageContent({
    required String text,
    required String matchId,
    required String messageId,
    required User user,
  }) async {
    final chatKeyState = _ref.read(chatKeyProvider);
    final ChatKeyService chatKeyService = ChatKeyService.instance;

    final bool canEncrypt =
        chatKeyState.isLoaded &&
        chatKeyState.activeKey != null &&
        chatKeyState.privateKeyBytes != null;
    if (!canEncrypt) return null;

    final String? senderKeyId = chatKeyState.activeKey?.id;
    if (senderKeyId == null) return null;

    try {
      final matchResp = await supabase
          .from('matches')
          .select('user1_id, user2_id')
          .eq('id', matchId)
          .maybeSingle();
      if (matchResp == null) return null;

      final recipientId = matchResp['user1_id'] == user.id
          ? matchResp['user2_id'] as String
          : matchResp['user1_id'] as String;

      final recipientActive = await chatKeyService.fetchActiveKey(recipientId);
      if (recipientActive == null) return null;

      final recipientKeyId = recipientActive.id;
      final crypto = CryptoService.instance;
      final senderPrivateKey = chatKeyState.privateKeyBytes!;
      final recipientPublicKeyBytes = base64Decode(
        recipientActive.publicKeyBase64,
      );

      final messageKey = await crypto.generateMessageKey();
      final contentNonce = crypto.generateNonce();

      final encryptedContent = await crypto.encryptOriginal(
        plaintext: Uint8List.fromList(utf8.encode(text)),
        messageKey: messageKey,
        nonce: contentNonce,
        messageId: messageId,
        matchId: matchId,
        senderId: user.id,
        recipientId: recipientId,
        senderKeyId: senderKeyId,
        recipientKeyId: recipientKeyId,
      );

      final contentOriginalEncrypted = base64Encode(encryptedContent);
      final contentOriginalNonce = base64Encode(contentNonce);

      final messageIdBytes = Uint8List.fromList(utf8.encode(messageId));

      final sharedSecret = await crypto.x25519SharedSecretFromPrivateKey(
        myPrivateKey: senderPrivateKey,
        theirPublicKey: recipientPublicKeyBytes,
      );

      final recipientWrapKey = await crypto.hkdfDeriveBytes(
        inputKeyMaterial: sharedSecret,
        salt: messageIdBytes,
        info: SecurityConstants.recipientWrapInfoLabel,
      );

      final recipientWrapNonce = crypto.generateNonce();
      final recipientWrapAad = crypto.buildWrapAad(
        purpose: 'recipient',
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientOrSupabaseKeyId: recipientKeyId,
      );

      final recipientWrappedMessageKey = await crypto.wrapMessageKey(
        messageKey: messageKey,
        wrapKey: recipientWrapKey,
        nonce: recipientWrapNonce,
        aad: recipientWrapAad,
      );

      final supabasePublicKeyBytes = base64Decode(
        SecurityConstants.supabaseTranslationPublicKeyBase64,
      );

      final supabaseSharedSecret = await crypto
          .x25519SharedSecretFromPrivateKey(
            myPrivateKey: senderPrivateKey,
            theirPublicKey: supabasePublicKeyBytes,
          );

      final supabaseWrapKey = await crypto.hkdfDeriveBytes(
        inputKeyMaterial: supabaseSharedSecret,
        salt: messageIdBytes,
        info: SecurityConstants.supabaseWrapInfoLabel,
      );

      final supabaseWrapNonce = crypto.generateNonce();
      final supabaseWrapAad = crypto.buildWrapAad(
        purpose: 'supabase',
        messageId: messageId,
        senderKeyId: senderKeyId,
        recipientOrSupabaseKeyId: SecurityConstants.supabaseTranslationKeyId,
      );

      final supabaseWrappedMessageKey = await crypto.wrapMessageKey(
        messageKey: messageKey,
        wrapKey: supabaseWrapKey,
        nonce: supabaseWrapNonce,
        aad: supabaseWrapAad,
      );

      final wrappedKeys = {
        'recipient': {
          'nonce': base64Encode(recipientWrapNonce),
          'ciphertext': base64Encode(recipientWrappedMessageKey),
        },
        'supabase': {
          'nonce': base64Encode(supabaseWrapNonce),
          'ciphertext': base64Encode(supabaseWrappedMessageKey),
        },
      };

      return {
        'encryption_scheme': 'v1',
        'sender_key_id': senderKeyId,
        'recipient_key_id': recipientKeyId,
        'recipient_id': recipientId,
        'content_original_encrypted': contentOriginalEncrypted,
        'content_original_nonce': contentOriginalNonce,
        'wrapped_keys': wrappedKeys,
      };
    } catch (e) {
      debugPrint('🔐 [encryptMessageContent] Encryption failed: $e');
      return null;
    }
  }

  /// Edit a message. Only the message sender may edit; server-side RPC enforces this.
  Future<void> editMessage({
    required String matchId,
    required String messageId,
    required String newText,
  }) async {
    if (shouldSkipSupabaseCalls()) {
      throw Exception('Cannot edit message while offline');
    }

    final user = supabase.auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    final localDb = _ref.read(localDbProvider);
    final currentUserId = user.id;

    // Store original messages for rollback
    final originalMessages = await localDb.getMessages(matchId);

    // Encrypt the new content — plaintext is never allowed to be saved.
    final encryptionFields = await encryptMessageContent(
      text: newText,
      matchId: matchId,
      messageId: messageId,
      user: user,
    );
    if (encryptionFields == null) {
      throw Exception(
        'Cannot edit message: encryption is required but failed. '
        'Ensure both parties have active encryption keys.',
      );
    }
    final contentForServer =
        encryptionFields['content_original_encrypted'] as String;

    try {
      // Optimistic update locally
      final nowIso = DateTime.now().toIso8601String();
      await localDb.mergeMessages(matchId, [
        {'id': messageId, 'content_original': newText, 'edited_at': nowIso},
      ]);
      // Recompute the chat's last message preview since we edited the current last message
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );
      // Build encrypted payload for the server
      final payload = <String, dynamic>{
        'p_message_id': messageId,
        'p_new_content': contentForServer,
        'p_encryption_scheme': encryptionFields['encryption_scheme'],
        'p_content_original_nonce': encryptionFields['content_original_nonce'],
        'p_wrapped_keys': encryptionFields['wrapped_keys'],
        'p_sender_key_id': encryptionFields['sender_key_id'],
        'p_recipient_key_id': encryptionFields['recipient_key_id'],
        'p_recipient_id': encryptionFields['recipient_id'],
      };

      dynamic res;
      try {
        res = await supabase.rpc('edit_chat_message', params: payload).single();
      } catch (e) {
        // Fallback: attempt direct table update (subject to RLS policies)
        try {
          final nowIsoFinal = DateTime.now().toIso8601String();
          final updatePayload = <String, dynamic>{
            'content_original_encrypted': contentForServer,
            'encryption_scheme': encryptionFields['encryption_scheme'],
            'content_original_nonce':
                encryptionFields['content_original_nonce'],
            'wrapped_keys': encryptionFields['wrapped_keys'],
            'sender_key_id': encryptionFields['sender_key_id'],
            'recipient_key_id': encryptionFields['recipient_key_id'],
            'recipient_id': encryptionFields['recipient_id'],
            // An edit invalidates any translation of the previous content:
            // clear the stored translation (mirrors the edit_chat_message
            // RPC) so the recipient retranslates the new text instead of
            // reusing the stale translation.
            'content_translated_encrypted': null,
            'content_translated_nonce': null,
            'translated_target_language': null,
            'edited_at': nowIsoFinal,
          };
          final updateRes = await supabase
              .from('chat_messages')
              .update(updatePayload)
              .eq('id', messageId)
              .select()
              .single();
          res = updateRes;
        } catch (e4) {
          rethrow;
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
            // debugPrint('RPC returned empty List, fetching row for $messageId');
            final rows = await supabase
                .from('chat_messages')
                .select()
                .eq('id', messageId)
                .limit(1);
            if (rows.isNotEmpty) {
              resMap = Map<String, dynamic>.from(rows[0]);
            } else {
              throw Exception(
                'RPC returned empty list and failed to find row for $messageId',
              );
            }
          }
        } else if (res is bool && res == true) {
          // Some RPCs simply return true on success; fetch the updated row.
          // debugPrint('RPC returned boolean true for edit; fetching authoritative row for $messageId');
          final rows = await supabase
              .from('chat_messages')
              .select()
              .eq('id', messageId)
              .limit(1);
          if (rows.isNotEmpty) {
            resMap = Map<String, dynamic>.from(rows[0]);
          } else {
            throw Exception(
              'RPC returned success but row not found for $messageId',
            );
          }
        } else {
          throw Exception(
            'Unexpected RPC response type for edit: ${res.runtimeType}',
          );
        }
      } catch (e) {
        // debugPrint('Failed to normalize RPC response for message $messageId: $e\n$st');
        rethrow;
      }

      await localDb.mergeMessages(matchId, [resMap]);
      // Recompute the chat's last message preview after the server confirms the edit
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );
      // Tell the recipient to drop/rebuild the stale tray card (silent push).
      unawaited(
        _notifyMessageRetraction(
          matchId: matchId,
          messageId: messageId,
          kind: 'message_edited',
        ),
      );
      try {
        _ref.invalidate(chatMessagesProvider(matchId));
        _ref.invalidate(recentChatsProvider(currentUserId));
      } catch (e) {
        // debugPrint('Failed to invalidate providers after edit: $e');
      }
    } catch (e) {
      // debugPrint('edit_chat_message failed for message $messageId with error: $e\n$st');
      // Rollback optimistic update
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );
      rethrow;
    }
  }

  /// Delete a message. The server will enforce permissions via RLS/policies.
  Future<void> deleteMessage({
    required String matchId,
    required String messageId,
  }) async {
    if (shouldSkipSupabaseCalls()) {
      throw Exception('Cannot delete message while offline');
    }

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
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );

      // Server delete
      await supabase.from('chat_messages').delete().eq('id', messageId);

      // Tell the recipient to drop the stale tray card (silent push).
      unawaited(
        _notifyMessageRetraction(
          matchId: matchId,
          messageId: messageId,
          kind: 'message_deleted',
        ),
      );
      try {
        _ref.invalidate(chatMessagesProvider(matchId));
        // Invalidate recent chats to update the last message preview immediately
        _ref.invalidate(recentChatsProvider(currentUserId));
      } catch (e) {
        // debugPrint('Failed to invalidate providers after delete: $e');
      }
    } catch (e) {
      // debugPrint('deleteMessage failed: $e');
      // Rollback
      await _rollbackOptimisticUpdate(matchId, originalMessages, localDb);
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );
      rethrow;
    }
  }

  /// Fire-and-forget silent retraction push so the recipient's tray drops or
  /// rebuilds the stale card for an edited/deleted message. Never throws.
  Future<void> _notifyMessageRetraction({
    required String matchId,
    required String messageId,
    required String kind,
  }) async {
    try {
      if (shouldSkipSupabaseCalls()) return;
      if (supabase.auth.currentUser == null) return;
      await supabase.functions.invoke(
        'push-message',
        body: {'kind': kind, 'match_id': matchId, 'message_id': messageId},
      );
    } catch (_) {}
  }

  Future<void> _applyOptimisticUpdate(
    String matchId,
    String messageId,
    String? reaction,
    User user,
    LocalDbService localDb,
  ) async {
    // debugPrint('applyOptimisticUpdate START for message $messageId (reaction=$reaction)');
    final messages = await localDb.getMessages(matchId);
    final idx = messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (idx == -1) {
      // debugPrint('applyOptimisticUpdate: message $messageId not found in local cache');
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
    final Map<String, dynamic> summary = (msg['reaction_summary'] is Map)
        ? Map<String, dynamic>.from(msg['reaction_summary'])
        : {};
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

    // debugPrint('applyOptimisticUpdate DONE for message $messageId -> summary: ${summary.toString()} prev: ${prev ?? 'none'}');

    // Update cached reactors
    await _updateCachedReactors(
      matchId,
      messageId,
      reaction,
      prev,
      user.id,
      localDb,
    );
  }

  Future<void> _updateCachedReactors(
    String matchId,
    String messageId,
    String? reaction,
    String? prevReaction,
    String currentUserId,
    LocalDbService localDb,
  ) async {
    try {
      // Remove from previous reaction cache
      if (prevReaction != null) {
        final prevList = await localDb.getCachedReactors(
          matchId,
          messageId,
          prevReaction,
        );
        final updatedPrev = prevList
            .where((r) => r['user_id'] != currentUserId)
            .toList();
        await localDb.saveCachedReactors(
          matchId,
          messageId,
          prevReaction,
          updatedPrev,
        );
      }

      // Add to new reaction cache
      if (reaction != null) {
        final profile = await localDb.getLocalProfile(currentUserId);
        String? displayName;
        String? photoUrl;
        if (profile != null) {
          displayName = profile['name'] as String?;
          final photos = profile['photos'];
          if (photos is List && photos.isNotEmpty) {
            photoUrl = photos[0] as String?;
          }
        }

        final newEntry = {
          'user_id': currentUserId,
          'display_name': displayName,
          'photo': photoUrl,
        };

        final curList = await localDb.getCachedReactors(
          matchId,
          messageId,
          reaction,
        );
        final exists = curList.any((r) => r['user_id'] == currentUserId);
        if (!exists) {
          final updated = [...curList, newEntry];
          await localDb.saveCachedReactors(
            matchId,
            messageId,
            reaction,
            updated,
          );
        }
      }
    } catch (e) {
      // Ignore cache update failures
      // debugPrint('Failed to update cached reactors: $e');
    }
  }

  Future<void> _refreshCachedReactors(
    String matchId,
    String messageId,
    Iterable<String> keys,
    LocalDbService localDb,
  ) async {
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

  Future<void> _rollbackOptimisticUpdate(
    String matchId,
    List<Map<String, dynamic>> originalMessages,
    LocalDbService localDb,
  ) async {
    try {
      // debugPrint('rollbackOptimisticUpdate: restoring original messages for match $matchId');
      await localDb.saveMessages(matchId, originalMessages);
      // Also invalidate provider to refresh UI
      _ref.invalidate(chatMessagesProvider(matchId));
    } catch (e) {
      // debugPrint('Failed to rollback optimistic update: $e');
    }
  }

  /// Get list of reactors for a message/reaction. Returns list of maps with keys:
  /// `user_id`, `display_name`, `photo` (nullable).
  Future<List<Map<String, dynamic>>> getReactors({
    required String messageId,
    required String reaction,
  }) async {
    if (shouldSkipSupabaseCalls()) return [];

    try {
      // Prefer a server-side RPC that returns masked names/photos for reactors (avoids RLS issues).
      try {
        final rpcRows = await supabase.rpc(
          'get_message_reactors',
          params: {'message_id': messageId, 'reaction': reaction},
        );
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
          final idsMissingPhotos = initial
              .where((e) => e['photo'] == null)
              .map((e) => e['user_id'] as String?)
              .whereType<String>()
              .toList();
          if (idsMissingPhotos.isNotEmpty) {
            for (final id in idsMissingPhotos) {
              try {
                final profileRows = await supabase
                    .from('user_profiles')
                    .select('user_id, photos')
                    .eq('user_id', id)
                    .limit(1);
                if (profileRows.isNotEmpty) {
                  final pr = profileRows[0];
                  final photos = (pr['photos'] is List)
                      ? List<String>.from(pr['photos'])
                      : null;
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
      final ids = rows
          .map((r) => r['user_id']?.toString())
          .whereType<String>()
          .toList();
      if (ids.isEmpty) return [];
      // Fetch user names sequentially to avoid PostgREST `in_` method compatibility issues
      final Map<String, Map<String, dynamic>> byId = {};
      for (final id in ids) {
        try {
          final userRows = await supabase
              .from('users')
              .select('name')
              .eq('id', id)
              .limit(1);
          if (userRows.isNotEmpty) {
            final name = userRows[0]['name'] as String?;
            List<String>? photos;
            try {
              final profileRows = await supabase
                  .from('user_profiles')
                  .select('photos')
                  .eq('user_id', id)
                  .limit(1);
              if (profileRows.isNotEmpty && profileRows[0]['photos'] is List) {
                photos = List<String>.from(profileRows[0]['photos']);
              }
            } catch (_) {
              // ignore photos fetch errors
            }
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
        final masked = p != null
            ? maskFullName(p['full_name'] as String?)
            : null;
        result.add({
          'user_id': id,
          'display_name': masked,
          'photo':
              p != null &&
                  (p['photos'] is List && (p['photos'] as List).isNotEmpty)
              ? (p['photos'][0] as String)
              : null,
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

class TranslationNotificationNotifier
    extends Notifier<TranslationNotification?> {
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

final translationNotificationProvider =
    NotifierProvider<TranslationNotificationNotifier, TranslationNotification?>(
      () {
        return TranslationNotificationNotifier();
      },
    );

class TranslationNotifier extends Notifier<TranslationStates> {
  // Base prefs key - actual stored key is namespaced per-user: '${_prefsKeyBase}_<userId>'
  static const String _prefsKeyBase = 'translation_states';

  @override
  TranslationStates build() {
    // Load for the currently signed-in user (if any)
    _loadFromPrefsForCurrentUser();

    // Also listen to auth state changes so we can reload when user signs in/out/switches
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      // Only clear state when auth state actually changes (user signs in/out),
      // not when it's just loading or has an error
      final prevData = previous?.hasValue == true
          ? previous!.asData!.value
          : null;
      final nextData = next.hasValue ? next.asData!.value : null;

      if (prevData != nextData) {
        // IMPORTANT: Clear state immediately when auth state changes to prevent
        // serving matches from the previous user while the new user's prefs are loading.
        // The old state will be overwritten by _loadFromPrefsForCurrentUser() when it completes.
        state = {};
        _loadFromPrefsForCurrentUser();
      }
    });

    // When the UI language changes, update the in-memory translation state to
    // the new language and clear stale cached translations so that
    // translationFamilyProvider re-evaluates every visible bubble immediately
    // when the user opens a chat.
    ref.listen(localizationProvider, (previous, next) {
      try {
        if (next.isLoading) return;
        final prevLang = previous?.isLoading == false
            ? previous!.currentLocale.languageCode
            : null;
        final newLang = next.currentLocale.languageCode;
        if (prevLang == newLang) return; // no actual language change

        // Schedule translation after a small delay to allow the localization change to settle
        Future.delayed(const Duration(milliseconds: 250), () async {
          if (!ref.mounted) return; // provider disposed
          try {
            String? userId;
            try {
              userId = Supabase.instance.client.auth.currentUser?.id;
            } catch (_) {
              userId = null;
            }

            if (userId == null) return;

            final localDb = ref.read(localDbProvider);
            final targetLanguage = normalizeLanguageCode(newLang);

            // Determine which chats have translation enabled.
            // Prefer in-memory state (populated by syncChatsNow), but if state
            // is empty fall back to a direct Supabase query so the language
            // switch works even on the very first app launch before any sync.
            List<String> matchesWithTranslation = state.keys.toList();
            if (matchesWithTranslation.isEmpty && !shouldSkipSupabaseCalls()) {
              try {
                final rows = await Supabase.instance.client
                    .from('chats')
                    .select('match_id')
                    .eq('user_id', userId)
                    .eq('translation_enabled', true);
                matchesWithTranslation = (rows as List)
                    .map((r) => r['match_id']?.toString() ?? '')
                    .where((id) => id.isNotEmpty)
                    .toList();
              } catch (_) {}
            }

            if (matchesWithTranslation.isEmpty) return;

            // Validate each match to ensure user is authorized.
            // This prevents 403 errors from orphaned chats (matches where user
            // is no longer a participant due to data corruption or deletion).
            final validatedMatches = <String>[];
            for (final matchId in matchesWithTranslation) {
              try {
                final matchResponse = await Supabase.instance.client
                    .from('matches')
                    .select('id, user1_id, user2_id')
                    .eq('id', matchId)
                    .maybeSingle();

                if (matchResponse == null) {
                  debugPrint(
                    '[L10N] Chat validation: match_id $matchId does not exist in matches table. Skipping.',
                  );
                  continue;
                }

                final user1Id = matchResponse['user1_id'] as String?;
                final user2Id = matchResponse['user2_id'] as String?;

                if (userId != user1Id && userId != user2Id) {
                  debugPrint(
                    '[L10N] Chat validation: User $userId is not authorized for match $matchId (user1=$user1Id, user2=$user2Id). Skipping.',
                  );
                  continue;
                }

                validatedMatches.add(matchId);
              } catch (e) {
                debugPrint(
                  '[L10N] Chat validation error for match $matchId: $e',
                );
                continue;
              }
            }

            matchesWithTranslation = validatedMatches;
            if (matchesWithTranslation.isEmpty) return;

            // Update the in-memory translation state so that
            // translationProvider[matchId] returns the new language immediately.
            // Without this, translationEnabled evaluates to false and
            // translationFamilyProvider is never invoked in the chat screen.
            if (ref.mounted) {
              final updatedState = <String, String>{};
              for (final matchId in matchesWithTranslation) {
                updatedState[matchId] = targetLanguage;
              }
              state = updatedState;
              await _saveToPrefs();
            }

            for (final matchId in matchesWithTranslation) {
              if (!ref.mounted) return;

              try {
                final messages = await localDb.getMessages(matchId);
                if (messages.isEmpty) continue;

                // Don't translate here - let locale_provider.dart handle the smart retranslation
                // Clear only STALE cached translations so that when the user opens the
                // chat, bubbles needing translation go through translationFamilyProvider
                // Case A. Messages already cached for the new UI language (e.g. the
                // absolute-last message just smart-translated + mergeMessages'd by
                // locale_provider) are preserved, so entering the chat reuses them
                // via Case C instead of sending them to DeepL again.
                final staleIds = messages
                    .where((m) {
                      if (m['sender_id']?.toString() == userId) return false;
                      final msgId = m['id']?.toString();
                      if (msgId == null || msgId.isEmpty) return false;
                      final msgTarget = normalizeLanguageCode(
                        ((m['translated_target_language'] ??
                                    m['translated_lang'])
                                ?.toString() ??
                            ''),
                      );
                      return msgTarget != targetLanguage;
                    })
                    .map((m) => m['id']?.toString())
                    .whereType<String>()
                    .toList();

                if (staleIds.isNotEmpty) {
                  await localDb.clearCachedTranslationsForMessages(
                    matchId,
                    staleIds,
                  );
                }

                // Trigger UI refresh for translations
                if (ref.mounted) {
                  ref.read(translationVersionProvider.notifier).increment();
                }
              } catch (_) {
                // ignore per-match errors - best-effort
              }
            }
          } catch (_) {
            // ignore errors - translation is best-effort
          }
        });
      } catch (_) {}
    });

    return {}; // Return empty state initially, will be updated when loaded
  }

  String _prefsKeyForUser(String? userId) =>
      '$_prefsKeyBase${userId == null ? '' : '_$userId'}';

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
        // No stored prefs entry for this user (never written on this
        // device — e.g. the toggle was last changed on another device, or
        // this is the first launch). Fall back to the local Hive chats
        // cache so chats whose translation was enabled keep showing
        // translations even when the device is offline and the server
        // cannot be asked. An explicitly written empty map ("{}") is NOT
        // hydrated: that means the user turned every chat off.
        state = {};
        await _hydrateFromLocalChats(userId);
      }
    } catch (e) {
      // Ignore errors, keep empty state
    }
  }

  /// Populates the in-memory translation state from the local Hive chats
  /// cache (`recentChats_<userId>` rows). Best-effort offline fallback used
  /// only when no prefs entry exists for this user.
  Future<void> _hydrateFromLocalChats(String? userId) async {
    try {
      if (userId == null || userId.isEmpty) return;
      final localDb = ref.read(localDbProvider);
      final chats = await localDb.loadChats(userId);
      String targetFallback;
      try {
        targetFallback = normalizeLanguageCode(
          ref.read(localizationProvider).currentLocale.languageCode,
        );
      } catch (_) {
        targetFallback = 'en';
      }
      final hydrated = <String, String>{};
      for (final chat in chats ?? const <Map<String, dynamic>>[]) {
        if (chat['translation_enabled']?.toString() != 'true') continue;
        final mid = chat['match_id']?.toString();
        if (mid == null || mid.isEmpty) continue;
        final lang = chat['translation_language']?.toString();
        hydrated[mid] =
            (lang != null && lang.isNotEmpty)
            ? normalizeLanguageCode(lang)
            : targetFallback;
      }
      if (hydrated.isNotEmpty && ref.mounted) {
        state = hydrated;
      }
    } catch (_) {}
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
      state = {...state, matchId: targetLang};
    }
    await _saveToPrefs();

    final userId = Supabase.instance.client.auth.currentUser?.id;

    // Immediately update local cache to reflect the new flag for UX
    try {
      if (userId != null) {
        final localDb = ref.read(localDbProvider);
        await localDb.updateChatTranslation(
          userId,
          matchId,
          targetLang != null,
          targetLang,
        );
      }
    } catch (_) {
      // best-effort
    }

    // Notify UI providers to refresh translations
    ref.read(translationVersionProvider.notifier).increment();

    // Persist to server; skip if offline but still succeed locally
    // This allows toggling translations on/off even when offline
    if (!shouldSkipSupabaseCalls()) {
      try {
        if (userId != null) {
          await Supabase.instance.client.rpc(
            'set_chat_translation',
            params: {
              'p_user_id': userId,
              'p_match_id': matchId,
              'p_enabled': targetLang != null,
              'p_language': targetLang,
            },
          );

          // After successful write, trigger a background sync to pick up server
          // canonical data. We intentionally do NOT invalidate
          // `recentChatsProvider` here: the local Hive cache has already been
          // updated above (`updateChatTranslation`) and the provider watches
          // the box via `localDb.watchChats`, so it will re-emit on its own.
          //
          // Invalidating would tear down the `chatsUpdateChannel` realtime
          // subscription and re-create it after a 200ms `Future.delayed`.
          // During that window the originating device is unsubscribed, and
          // there is a race condition with the Supabase Realtime server
          // processing the unsubscribe/subscribe cycle that can also prevent
          // the OTHER device from receiving the UPDATE event. The toggle
          // sync from the originating device to the other device then only
          // takes effect on the next periodic 60s `syncChatsNow` pull (which
          // is what the user observed as "works after exit/re-enter").
          try {
            await ref.read(globalSyncManagerProvider).syncChatsNow(userId);
          } catch (_) {}
        }
      } catch (e) {
        // Revert optimistic update only if RPC call fails
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
            await localDb.updateChatTranslation(
              userId,
              matchId,
              previous != null,
              previous,
            );
          }
        } catch (_) {}

        rethrow;
      }
    } else {
      // Offline: in-memory state, prefs and the local Hive chats row are
      // already updated. Queue the server RPC so the toggle is replayed on
      // reconnect — otherwise the next syncChatsNow would pull the stale
      // server row and silently revert the user's offline choice.
      try {
        if (userId != null && userId.isNotEmpty) {
          await OfflineMutationQueue.instance.queueMutation(
            type: 'rpc',
            table: 'set_chat_translation',
            payload: {
              'p_user_id': userId,
              'p_match_id': matchId,
              'p_enabled': targetLang != null,
              'p_language': targetLang,
            },
          );
        }
      } catch (_) {}
    }
  }

  /// Apply a translation-state change that originated from the server (a
  /// realtime UPDATE on public.chats). Does everything `setTranslation` does
  /// locally except the server round-trip (the event is the server's
  /// confirmation) and the redundant post-write sync. Idempotent: a no-op
  /// when the new state already matches the current state.
  ///
  /// The previous "silent" setters only mutated `state`, which did not
  /// persist to SharedPreferences or Hive and did not bump the version
  /// counter. As a result, when a chat screen was already on screen the
  /// AppBar icon and per-message `translationFamilyProvider` results
  /// didn't refresh until the chat was exited and re-entered (which is
  /// when the periodic 60s `syncChatsNow` had finally re-read the row).
  Future<void> applyRemoteTranslationUpdate(
    String matchId,
    String? targetLang,
  ) async {
    if (matchId.isEmpty) return;
    final previous = state[matchId];
    if (targetLang == null) {
      if (previous == null) return; // Already off
      state = {...state}..remove(matchId);
    } else {
      if (previous == targetLang) return; // Already set to this target
      state = {...state, matchId: targetLang};
    }

    // Mirror to SharedPreferences so a provider rebuild (e.g. via
    // ref.invalidate) would re-load the correct value rather than the
    // pre-event value.
    await _saveToPrefs();

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      try {
        final localDb = ref.read(localDbProvider);
        await localDb.updateChatTranslation(
          userId,
          matchId,
          targetLang != null,
          targetLang,
        );
      } catch (_) {
        // best-effort
      }
    }

    // Bump the version counter so `translationFamilyProvider` re-evaluates
    // each visible message in the chat screen.
    ref.read(translationVersionProvider.notifier).increment();
  }

  /// Silent update to translation state - used during sync to match server state.
  /// Does NOT save to prefs or database - just updates in-memory state.
  /// Deferred to a microtask so a sync-driven state change can never
  /// collide with an in-flight widget build (e.g. a SnackBar
  /// `_OverlayEntryWidget` being mounted). Without the microtask, the
  /// state notification can cascade through a `Consumer`'s
  /// `_updateTickerMode` -> `TickerProvider._updateEffectiveMode` chain
  /// and trigger the
  ///   "UncontrolledProviderScope ... cannot be marked as needing to build"
  /// assertion that crashes the chat sync path.
  void setTranslationSilent(String matchId, String targetLang) {
    Future.microtask(() {
      if (!ref.mounted) return;
      if (state[matchId] == targetLang) return;
      state = {...state, matchId: targetLang};
    });
  }

  /// Silent removal from translation state - used during sync.
  /// Does NOT save to prefs or database - just updates in-memory state.
  /// Deferred to a microtask for the same reason as [setTranslationSilent].
  void clearTranslationSilent(String matchId) {
    Future.microtask(() {
      if (!ref.mounted) return;
      if (!state.containsKey(matchId)) return;
      state = {...state}..remove(matchId);
    });
  }
}

final translationProvider =
    NotifierProvider<TranslationNotifier, TranslationStates>(() {
      return TranslationNotifier();
    });
// --- END Translation State ---

// --- Translation Batch State (Prevents multiple simultaneous batch calls per match) ---
final translationBatchStateProvider =
    NotifierProvider<TranslationBatchNotifier, Map<String, bool>>(
      () => TranslationBatchNotifier(),
    );

class TranslationBatchNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => {};

  /// Shared in-flight batch futures keyed by "$matchId|$targetLanguage".
  ///
  /// The FIRST bubble needing translation runs the single shared batch for
  /// the match+language; every other visible bubble for the same
  /// match+language awaits the same future instead of firing its own
  /// overlapping request. Previously each bubble built its own batch (self +
  /// recent candidates), so N visible bubbles produced N concurrent
  /// translate-proxy requests whose id lists overlapped — and because none
  /// had committed yet, every request re-sent the same messages to DeepL.
  final Map<String, Future<void>> _inFlightBatches = {};

  Future<void>? inFlightBatch(String matchId, String targetLanguage) =>
      _inFlightBatches['$matchId|$targetLanguage'];

  void registerInFlightBatch(
    String matchId,
    String targetLanguage,
    Future<void> future,
  ) {
    _inFlightBatches['$matchId|$targetLanguage'] = future;
  }

  /// Only the owning future may clear its slot — a waiter that timed out and
  /// started a replacement batch must not have its slot removed by the old
  /// leader's cleanup.
  void clearInFlightBatch(
    String matchId,
    String targetLanguage,
    Future<void> future,
  ) {
    final key = '$matchId|$targetLanguage';
    if (identical(_inFlightBatches[key], future)) {
      _inFlightBatches.remove(key);
    }
  }

  bool isRunning(String matchId) => state[matchId] ?? false;

  void setRunning(String matchId, bool running) {
    state = {...state, matchId: running};
  }

  /// Per-message guard: prevents duplicate concurrent proxy calls for the
  /// SAME message (e.g. rapid rebuilds), while allowing DIFFERENT visible
  /// messages to translate in parallel. Key format: "$matchId|$messageId".
  /// This is what makes "all currently displayed incoming messages translate
  /// immediately on chat open" work — a per-match lock would let only the
  /// first bubble through and starve the rest. Off-screen messages have no
  /// provider instance (ListView.builder), so they still stay lazy until
  /// scrolled into view.
  bool isRunningForMessage(String matchId, String messageId) =>
      state['$matchId|$messageId'] ?? false;

  void setRunningForMessage(String matchId, String messageId, bool running) {
    final key = '$matchId|$messageId';
    state = {...state, key: running};
  }
}
// --- END Translation Batch State ---

// --- Available Translation Languages Per Match ---
/// Provider that tracks which languages have translations available in a specific match
/// Returns list of language codes (e.g., ['en', 'es', 'he']) that have cached translations
final availableTranslationLanguagesProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, matchId) async {
      try {
        // Watch the chat messages to detect available translations
        final messagesAsync = ref.watch(chatMessagesProvider(matchId));

        // If messages are loading or errored, use last known available languages
        if (messagesAsync.isLoading) {
          return await TranslationCacheManager.getDownloadedLanguagesForMatch(
            matchId,
          );
        }

        if (messagesAsync.hasError) {
          return await TranslationCacheManager.getDownloadedLanguagesForMatch(
            matchId,
          );
        }

        final messages = messagesAsync.asData?.value ?? [];
        if (messages.isEmpty) {
          return [];
        }

        // Detect all unique languages that have translations in this match
        final Set<String> availableLangs = {};

        for (final msg in messages) {
          final translatedLang = msg.translatedLang;
          if (translatedLang != null && translatedLang.isNotEmpty) {
            // Normalize the language code
            final normalized = normalizeLanguageCode(translatedLang);
            availableLangs.add(normalized);
          }
        }

        // Update the cache manager tracking for faster lookups
        for (final lang in availableLangs) {
          await TranslationCacheManager.markLanguageDownloadedForMatch(
            matchId,
            lang,
          );
        }

        return availableLangs.toList()..sort();
      } catch (e) {
        // On error, return cached list
        return TranslationCacheManager.getDownloadedLanguagesForMatch(matchId);
      }
    });

/// Get human-readable names for language codes
Map<String, String> getLanguageDisplayNames(List<String> langCodes) {
  const Map<String, String> displayNames = {
    'en': 'English',
    'es': 'Español',
    'he': 'עברית (Hebrew)',
  };

  final result = <String, String>{};
  for (final code in langCodes) {
    result[code] = displayNames[code] ?? code.toUpperCase();
  }
  return result;
}
// --- END Available Translation Languages Provider ---

// ---
// --- *** UPDATED: translationFamilyProvider (translates to current UI language)
// --- Translates incoming messages to the current app UI language when translation is enabled.
// --- Only translates messages from other users, not outgoing messages.
// --- Uses smart Case A/B/C logic based on server-side translation data:
// --- - Case A: UI != source AND UI != target -> Call translate-proxy
// --- - Case B: UI == source -> Show original (no AI)
// --- - Case C: UI == target -> Reuse existing translation (no AI)
// ---
final translationFamilyProvider = FutureProvider.autoDispose.family<String, String>((
  ref,
  paramsString,
) async {
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

  // Check in-memory cache first — returning the cached result immediately
  // avoids the async gap (DB read → decrypt → Supabase fetch) that causes
  // translations to flash when re-entering a chat.
  final cacheKey = '$messageId|$targetLanguage';
  final cachedEntry = _translationResultCache[cacheKey];
  final currentVersion = ref.read(translationVersionProvider);
  if (cachedEntry != null && cachedEntry.version == currentVersion) {
    return cachedEntry.translation;
  }

  String translateResult(String result) {
    _translationResultCache[cacheKey] = _TranslationCacheEntry(
      result,
      currentVersion,
    );
    // Mirror to local storage (SharedPreferences) so the translation is
    // available immediately on the next cold start, even when Supabase is
    // unreachable. Hive remains the primary store (via mergeMessages);
    // this is a lightweight secondary fallback. Fire-and-forget.
    try {
      final mid = messageId;
      final tlang = targetLanguage;
      unawaited(_persistTranslation(mid, tlang, result));
    } catch (_) {}
    return result;
  }

  // Cold-start offline fallback: if the in-memory cache missed (fresh app
  // launch), check the SharedPreferences mirror before touching Hive. This
  // lets a chat opened with no connectivity render its last-known
  // translation instantly, without waiting for Hive + decrypt.
  try {
    final persisted = await _loadPersistedTranslation(
      messageId,
      targetLanguage,
    );
    if (persisted != null && persisted.isNotEmpty) {
      // Populate the in-memory cache so subsequent rebuilds hit it.
      _translationResultCache[cacheKey] = _TranslationCacheEntry(
        persisted,
        currentVersion,
      );
      // Don't return yet: the Hive plaintext below is authoritative and may
      // be newer (e.g. after an edit). This warms the cache only; the
      // authoritative local-plaintext fast-path below decides what to show.
    }
  } catch (_) {}

  // Read all provider values before any async gap to avoid disposed-ref crashes.
  // The autoDispose family provider can be disposed during any await, making ref
  // unusable for subsequent ref.read/ref.watch calls.
  final chatKeyState = ref.read(chatKeyProvider);
  final currentUserId = supabase.auth.currentUser?.id ?? '';

  final messages = await localDb.getMessages(matchId);
  if (!ref.mounted) return text;
  final message = messages.firstWhere(
    (m) => m['id'].toString() == messageId,
    orElse: () => {},
  );
  final senderId = message['sender_id'] as String?;

  // Get server-side translation data (set by translate-proxy edge function)
  final serverSourceLang = message['detected_source_language'] as String?;
  final serverTargetLang =
      (message['translated_target_language'] as String?) ??
      (message['translated_lang'] as String?);
  // Server stores encrypted translations in `chat_messages`.
  final String? serverTranslation = null;

  // OFFLINE-FIRST FAST PATH (memory + local storage): if Hive already holds
  // a plaintext translation for the current UI language, reuse it
  // immediately without requiring the chat private key or Supabase.
  // This is what makes translations appear instantly on cold start with no
  // connectivity. The AAD-bound decrypt below remains authoritative when it
  // succeeds; this path only serves the already-verified local plaintext.
  final localPlaintext =
      (message['content_translated'] as String?) ??
      (message['translated_text'] as String?);
  final localTargetRaw =
      (message['translated_target_language'] as String?) ??
      (message['translated_lang'] as String?);
  if (localPlaintext != null &&
      localPlaintext.isNotEmpty &&
      localPlaintext != 'null' &&
      localTargetRaw != null &&
      localTargetRaw.isNotEmpty) {
    try {
      if (normalizeLanguageCode(localTargetRaw) == targetLanguage) {
        // Ensure the cached plaintext still describes the current content.
        // Its AAD binds the target language but not the content, so verify
        // the version marker when the row was edited.
        final editedAt = message['edited_at']?.toString();
        if (editedAt == null ||
            editedAt.isEmpty ||
            translationEditMarkersMatch(
              message['translated_source_edited_at']?.toString(),
              editedAt,
            )) {
          return translateResult(localPlaintext);
        }
      }
    } catch (_) {}
  }

  // For encrypted messages, content_translated_encrypted may contain the
  // translation for the CURRENT target language (set by a recent batch or
  // smart retranslation), while content_translated may hold stale text from
  // a previous language.  Always try to decrypt content_translated_encrypted
  // for v1 messages — the decryption AAD includes the target language, so
  // it will only succeed if the encrypted translation matches the current UI.
  String? decryptedTranslation;
  final encScheme = message['encryption_scheme'] as String?;
  // Track whether Supabase has encrypted data for this message.
  // If it does, the message is effectively v1 even if the local DB
  // doesn't have encryption_scheme set (e.g., messages synced before
  // the encryption_scheme column was added).
  bool hasSupabaseEncrypted = false;
  if (encScheme == 'v1') {
    final encryptedTranslated =
        message['content_translated_encrypted'] as String?;
    final translatedNonce = message['content_translated_nonce'] as String?;
    if (encryptedTranslated != null &&
        encryptedTranslated.isNotEmpty &&
        translatedNonce != null &&
        translatedNonce.isNotEmpty) {
      if (chatKeyState.privateKeyBytes != null) {
        final String effectiveRecipientId =
            message['recipient_id'] as String? ?? '';
        decryptedTranslation = await ChatKeyService.instance
            .decryptMessageTranslatedContent(
              currentUserId: currentUserId,
              currentUserPrivateKey: chatKeyState.privateKeyBytes!,
              messageId: message['id'] as String,
              matchId: matchId,
              senderId: message['sender_id'] as String,
              senderKeyId: message['sender_key_id'] as String,
              recipientKeyId: message['recipient_key_id'] as String,
              contentTranslatedEncryptedBase64: encryptedTranslated,
              contentTranslatedNonceBase64: translatedNonce,
              wrappedKeys:
                  (message['wrapped_keys'] as Map<String, dynamic>?) ?? {},
              // Always use UI language as target language — the edge function
              // always encrypts for the current UI locale, but serverTargetLang
              // in the local DB may be stale from a previous language.
              detectedSourceLanguage: serverSourceLang ?? 'und',
              targetLanguage: targetLanguage,
              recipientId: effectiveRecipientId.isNotEmpty
                  ? effectiveRecipientId
                  : null,
            );
        if (!ref.mounted) return text;
      } else if (!shouldSkipSupabaseCalls()) {
        debugPrint(
          '[Translation] Cannot decrypt content_translated_encrypted: private key not loaded',
        );
      }
      // DCK-encrypted local fallback (memory + local storage): when the chat
      // private key is unavailable (cold offline boot, locked key) the
      // device-cache-key backup stored alongside the row still lets the
      // translation render immediately. Mirrors Phase 2's fallback.
      if (decryptedTranslation == null) {
        try {
          final cached =
              message['content_translated_encrypted_cache'] as String?;
          if (cached != null && cached.isNotEmpty) {
            decryptedTranslation = await EncryptedCacheService.instance
                .decryptFromCache(cached);
            if (!ref.mounted) return text;
            // Only trust the DCK backup when its target matches the UI.
            if (decryptedTranslation != null &&
                decryptedTranslation.isNotEmpty) {
              final cachedTarget = normalizeLanguageCode(
                (localTargetRaw ?? serverTargetLang ?? '').toString(),
              );
              if (cachedTarget.isNotEmpty && cachedTarget != targetLanguage) {
                decryptedTranslation = null;
              } else if (decryptedTranslation.trim() == text.trim()) {
                // Identical to original: not a real translation.
                decryptedTranslation = null;
              }
            }
          }
        } catch (_) {}
      }
    }

    // If local decrypt failed (content_translated_encrypted was unavailable
    // locally because Phase 2 cleared it, or the local data is stale), try
    // fetching content_translated_encrypted from Supabase.  This is the
    // authoritative source — the edge function always encrypts for the current
    // UI language.  Successful decryption (the AAD includes targetLanguage)
    // guarantees the translation is for the current UI.
    if (decryptedTranslation == null && !shouldSkipSupabaseCalls()) {
      try {
        final serverMsg = await supabase
            .from('chat_messages')
            .select(
              'id, content_translated_encrypted, content_translated_nonce, '
              'sender_key_id, recipient_key_id, wrapped_keys, sender_id, recipient_id',
            )
            .eq('id', messageId)
            .maybeSingle();
        if (!ref.mounted) return text;
        if (serverMsg != null) {
          final serverEncrypted =
              serverMsg['content_translated_encrypted'] as String?;
          final serverNonce = serverMsg['content_translated_nonce'] as String?;
          if (serverEncrypted != null &&
              serverEncrypted.isNotEmpty &&
              serverNonce != null &&
              serverNonce.isNotEmpty) {
            hasSupabaseEncrypted = true;
            if (chatKeyState.privateKeyBytes != null) {
              final serverSenderId =
                  (serverMsg['sender_id'] ?? message['sender_id']) as String;
              final serverSenderKeyId =
                  (serverMsg['sender_key_id'] ?? message['sender_key_id'])
                      as String;
              final serverRecipientKeyId =
                  (serverMsg['recipient_key_id'] ?? message['recipient_key_id'])
                      as String;
              final serverWrappedKeys =
                  (serverMsg['wrapped_keys'] as Map<String, dynamic>?) ??
                  (message['wrapped_keys'] as Map<String, dynamic>?) ??
                  {};
              String? serverRecipientId = serverMsg['recipient_id'] as String?;
              if (serverRecipientId == null || serverRecipientId.isEmpty) {
                serverRecipientId = message['recipient_id'] as String?;
              }
              decryptedTranslation = await ChatKeyService.instance
                  .decryptMessageTranslatedContent(
                    currentUserId: currentUserId,
                    currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                    messageId: message['id'] as String,
                    matchId: matchId,
                    senderId: serverSenderId,
                    senderKeyId: serverSenderKeyId,
                    recipientKeyId: serverRecipientKeyId,
                    contentTranslatedEncryptedBase64: serverEncrypted,
                    contentTranslatedNonceBase64: serverNonce,
                    wrappedKeys: serverWrappedKeys,
                    detectedSourceLanguage: serverSourceLang ?? 'und',
                    targetLanguage: targetLanguage,
                    recipientId:
                        serverRecipientId != null &&
                            serverRecipientId.isNotEmpty
                        ? serverRecipientId
                        : null,
                  );
              if (!ref.mounted) return text;
              if (decryptedTranslation != null &&
                  decryptedTranslation.isNotEmpty) {
                await localDb.mergeMessages(matchId, [
                  {
                    'id': messageId,
                    'content_translated': decryptedTranslation,
                    'translated_target_language': targetLanguage,
                  },
                ]);
              }
            }
          }
        }
      } catch (e) {
        debugPrint(
          '[Translation] Supabase content_translated_encrypted fetch/decrypt failed: $e',
        );
      }
    }
  }

  // An edit invalidates translations made for previous content, but the
  // translation AAD binds the target language — NOT the original content —
  // so a pre-edit encrypted blob still decrypts after an edit. When this
  // message was edited, the stored translation is trustworthy only if its
  // version marker (`translated_source_edited_at`, stamped at translation
  // time) still matches the row's `edited_at`. Verify against server truth
  // instead of trusting the local payload blindly:
  // - marker mismatch -> the translation predates the current content: drop
  //   the stale local payload so Case A retranslates exactly once (the edge
  //   skips only marker-matching rows, so no second DeepL call follows);
  // - marker matches but server holds a DIFFERENT blob for the UI language
  //   -> someone already retranslated the new content: adopt it;
  // - otherwise -> translation is current: use it (Case C).
  // Messages that were never edited skip this entirely (no extra fetch).
  if (decryptedTranslation != null &&
      decryptedTranslation.isNotEmpty &&
      !shouldSkipSupabaseCalls()) {
    final localEditedAt = message['edited_at']?.toString();
    if (localEditedAt != null && localEditedAt.isNotEmpty) {
      try {
        final truth = await supabase
            .from('chat_messages')
            .select(
              'id, content_translated_encrypted, content_translated_nonce, translated_target_language, translated_source_edited_at, edited_at, detected_source_language, encryption_scheme, sender_id, sender_key_id, recipient_key_id, wrapped_keys, match_id, recipient_id',
            )
            .eq('id', messageId)
            .maybeSingle();
        if (!ref.mounted) return text;
        if (truth != null) {
          final truthBlob = truth['content_translated_encrypted'] as String?;
          final truthTarget = truth['translated_target_language'] as String?;
          final truthMarker = truth['translated_source_edited_at']?.toString();
          final truthEdited = truth['edited_at']?.toString();
          final localBlob = message['content_translated_encrypted'] as String?;
          final serverMatchesUi =
              truthTarget != null &&
              truthTarget.isNotEmpty &&
              normalizeLanguageCode(truthTarget) == targetLanguage;
          if (!translationEditMarkersMatch(truthMarker, truthEdited)) {
            // Edit invalidated the server translation: drop the stale local
            // payload (plaintext + target + blob) and fall through to Case A.
            try {
              await localDb.mergeMessages(matchId, [
                {
                  'id': messageId,
                  'content_translated': null,
                  'content_translated_encrypted': null,
                  'content_translated_nonce': null,
                  'translated_target_language': null,
                },
              ]);
              await localDb.clearCachedTranslationsForMessages(matchId, [
                messageId,
              ]);
            } catch (_) {}
            decryptedTranslation = null;
          } else if (truthBlob != localBlob &&
              serverMatchesUi &&
              truthBlob != null &&
              truthBlob.isNotEmpty) {
            // Server already carries a (newer) translation for the current
            // UI language: decrypt and adopt it instead of the stale local.
            try {
              if (chatKeyState.privateKeyBytes != null) {
                final truthNonce = truth['content_translated_nonce'] as String?;
                if (truthNonce != null && truthNonce.isNotEmpty) {
                  final adopted = await ChatKeyService.instance
                      .decryptMessageTranslatedContent(
                        currentUserId: currentUserId,
                        currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                        messageId: message['id'] as String,
                        matchId: matchId,
                        senderId: truth['sender_id'] as String,
                        senderKeyId: truth['sender_key_id'] as String,
                        recipientKeyId: truth['recipient_key_id'] as String,
                        contentTranslatedEncryptedBase64: truthBlob,
                        contentTranslatedNonceBase64: truthNonce,
                        wrappedKeys:
                            (truth['wrapped_keys'] as Map<String, dynamic>?) ??
                            {},
                        detectedSourceLanguage:
                            truth['detected_source_language'] as String? ??
                            'und',
                        targetLanguage: targetLanguage,
                        recipientId: () {
                          final rid = truth['recipient_id'] as String?;
                          return rid != null && rid.isNotEmpty ? rid : null;
                        }(),
                      );
                  if (!ref.mounted) return translateResult(text);
                  if (adopted != null && adopted.isNotEmpty) {
                    decryptedTranslation = adopted;
                    try {
                      await localDb.mergeMessages(matchId, [
                        {
                          'id': messageId,
                          'content_translated': adopted,
                          'content_translated_encrypted': truthBlob,
                          'content_translated_nonce': truthNonce,
                          'translated_target_language':
                              // Non-null here: serverMatchesUi above requires
                              // a non-empty truthTarget for the UI language.
                              truthTarget,
                        },
                      ]);
                    } catch (_) {}
                    // Keep the chat-list preview consistent with the adopted
                    // translation (mirrors fetchAndApplyFreshTranslation).
                    try {
                      final previewUserId = supabase.auth.currentUser?.id;
                      if (previewUserId != null) {
                        await localDb.updateChatLastMessageTranslation(
                          previewUserId,
                          matchId,
                          messageId,
                          adopted,
                          targetLanguage: truthTarget,
                          editedAt: normalizeEditMarker(truth['edited_at']),
                        );
                      }
                    } catch (_) {}
                  } else {
                    decryptedTranslation = null;
                  }
                }
              }
            } catch (_) {
              // Best-effort: on any failure fall through to Case A below.
              decryptedTranslation = null;
            }
          }
        }
      } catch (_) {
        // Best-effort verification only: on failure keep trusting the local
        // (existing) behaviour rather than blocking the bubble.
      }
    }
  }

  // For encrypted (v1) messages, prefer the decrypted translation over the
  // server translation.  The server/content_translated column is only set
  // client-side by mergeMessages after a previous successful decryption for
  // an older language.  The decryptedTranslation above was derived from
  // content_translated_encrypted (which was created by the edge function for
  // the CURRENT target language), so it takes precedence.
  // If Supabase has encrypted data (hasSupabaseEncrypted) but decryption
  // failed (MAC error because the encrypted data is for a different
  // language), effectiveServerTranslation will be null, forcing Case A to
  // translate for the current UI language — preventing stale serverTranslation
  // from being returned for a wrong target language.
  final bool isEncrypted = (encScheme == 'v1') || hasSupabaseEncrypted;
  final effectiveServerTranslation = isEncrypted
      ? decryptedTranslation
      : (decryptedTranslation ?? serverTranslation);

  // Check if this is an outgoing message (from current user) - don't translate those
  if (senderId == currentUserId) {
    // This is our own message, don't translate it
    return translateResult(text);
  }

  // 3. Case A/B/C Logic using server-side translation data
  // Normalize language codes for comparison
  final normalizedSource = serverSourceLang != null
      ? normalizeLanguageCode(serverSourceLang)
      : null;
  final normalizedTarget = serverTargetLang != null
      ? normalizeLanguageCode(serverTargetLang)
      : null;

  debugPrint(
    'ðŸ”„ Translation Provider: Case A/B/C check - UI=$targetLanguage, source=$normalizedSource, target=$normalizedTarget',
  );

  // --- Early short-circuit: skip expensive language detection when
  //     the server data already determines the case. ---
  // Case B check from server data: UI language == server source language
  if (normalizedSource != null &&
      targetLanguage == normalizedSource &&
      isValidLanguageCode(normalizedSource)) {
    debugPrint(
      'ðŸ”„ Translation Provider: Case B - UI matches source ($normalizedSource) from server data, showing original',
    );
    return translateResult(text);
  }
  // Case C check from server data: UI language == server target language
  // AND we have a non-encrypted translation already.
  if (!isEncrypted &&
      effectiveServerTranslation != null &&
      effectiveServerTranslation.isNotEmpty &&
      normalizedTarget != null &&
      targetLanguage == normalizedTarget) {
    debugPrint(
      'ðŸ”„ Translation Provider: Case C - UI matches target ($normalizedTarget) from server data, reusing existing translation',
    );
    return translateResult(effectiveServerTranslation);
  }

  // Always prefer client-side language detection over the server's
  // detected_source_language, which can be wrong for short messages
  // (e.g. "Ten" detected as Polish "pl" → "this" instead of English).
  // Server value is only used as fallback when local detection fails.
  String? sourceLanguage;
  final textForLangId = _stripEmojisForLanguageId(text);
  try {
    if (textForLangId.replaceAll(RegExp(r'\s+'), '').length >= 2) {
      // Use cached result if we already detected this text's language.
      sourceLanguage = _languageDetectionCache[textForLangId];
      if (sourceLanguage != null) {
        debugPrint(
          '💡 Translation Provider: Cache hit for source: $sourceLanguage',
        );
      } else {
        final translationService = ref.read(translationServiceProvider);
        final detectedLang = await translationService.identifyLanguage(
          textForLangId,
        );
        if (detectedLang.isNotEmpty) {
          sourceLanguage = normalizeLanguageCode(detectedLang);
          _languageDetectionCache[textForLangId] = sourceLanguage;
          debugPrint(
            '💡 Translation Provider: Client detected source: $sourceLanguage',
          );
        }
      }
    }
  } catch (e) {
    debugPrint('💡 Translation Provider: Local language detection failed: $e');
  }

  // Fall back to server value if local detection yielded nothing
  // AND the server value is a valid code (not "ts"/"st" garbage).
  if ((sourceLanguage == null || sourceLanguage == 'und') &&
      normalizedSource != null &&
      isValidLanguageCode(normalizedSource)) {
    sourceLanguage = normalizedSource;
    debugPrint(
      '💡 Translation Provider: Falling back to server source: $sourceLanguage',
    );
  }

  // Case B (PRIORITY): UI language == source language -> Show original (no AI needed)
  // This takes priority over Case C because if the message is already in the user's language,
  // we should show the original regardless of any existing translations
  if (sourceLanguage != null && sourceLanguage == targetLanguage) {
    debugPrint(
      'ðŸ”„ Translation Provider: Case B - UI matches source ($sourceLanguage), showing original',
    );
    return translateResult(text);
  }

  // Case C: UI language == target language -> Reuse existing translation (no AI needed)
  // Only use this if Case B didn't match (i.e., source != UI)
  // For encrypted (v1) messages, a successful decryption of
  // content_translated_encrypted (with UI language in the AAD) guarantees the
  // translation is for the current UI, even if serverTargetLang in the local DB
  // is stale from a previous language.  We now fetch directly from Supabase
  // above (if local decrypt failed), so decryptedTranslation is authoritative.
  // By requiring decryptedTranslation != null for v1 messages, we prevent
  // returning stale cached translation text that was set
  // by mergeMessages in a previous session for a different language.
  // The isEncrypted flag covers both locally-known v1 (encScheme == 'v1') and
  // messages whose encryption_scheme was lost locally but found in Supabase
  // (hasSupabaseEncrypted).  For encrypted messages, only a successful decrypt
  // permits Case C.
  final bool targetMatchesCurrentUi =
      normalizedTarget != null && normalizedTarget == targetLanguage;
  if (effectiveServerTranslation != null &&
      effectiveServerTranslation.isNotEmpty &&
      targetMatchesCurrentUi) {
    debugPrint(
      'ðŸ”„ Translation Provider: Case C - UI matches target ($normalizedTarget), reusing existing translation',
    );
    // Stamp the chat-list preview as well: Case C is the common path once a
    // translation exists locally (e.g. it just arrived via the realtime
    // fast-path merge), and without this the Recent Messages row keeps
    // showing "Loading…" until some other path rewrites it. The callee
    // no-ops unless this message is the chat's last one.
    if (currentUserId.isNotEmpty) {
      try {
        await localDb.updateChatLastMessageTranslation(
          currentUserId,
          matchId,
          messageId,
          effectiveServerTranslation,
          targetLanguage: targetLanguage,
          // Reaching Case C means the cached translation was verified against
          // the row's `edited_at` above, so it describes the current content.
          // Recording that is what lets the chat list detect the next edit
          // instead of preserving this preview forever. Left null when the
          // verification could not run (offline), which fails safe: the
          // preview is then only reusable for a never-edited message.
          editedAt: normalizeEditMarker(message['edited_at']),
        );
      } catch (_) {}
    }
    return translateResult(effectiveServerTranslation);
  }

  // If we couldn't detect source language and there's no existing translation, show original
  if (sourceLanguage == null &&
      (normalizedTarget == null ||
          effectiveServerTranslation == null ||
          effectiveServerTranslation.isEmpty)) {
    debugPrint(
      'ðŸ”„ Translation Provider: No language info available, showing original',
    );
    return translateResult(text);
  }

  // Case A: UI != source AND UI != target -> Need to translate
  // Translate only this specific message as the user scrolls to it.
  debugPrint(
    'ðŸ”„ Translation Provider: Case A - Translating message for UI=$targetLanguage, source=$sourceLanguage, target=$normalizedTarget',
  );

  // Check if we're offline - if so, track this message for auto-fetch when online
  final isOffline = shouldSkipSupabaseCalls();
  if (isOffline) {
    _addPendingTranslation(matchId, messageId);
    return translateResult(text);
  }

  // If the message has an encrypted translation that we couldn't decrypt
  // (broken AAD from old webhook), clear it now so the batch query picks it up.
  // Only clear when the provider is still mounted — if it was disposed during
  // an async gap, our fetch/decrypt results are unreliable and may reflect a
  // temporary failure, not stale data. Deleting valid encrypted translations
  // in that case would make the problem self-perpetuating.
  // IMPORTANT (language switch, e.g. old -> new): only wipe when the stored
  // target already claims to be the current UI language. A stale target (e.g.
  // stored old lang while UI is now new lang) must be LEFT intact so the proxy
  // overwrites it with the new language; wiping it first would destroy the
  // only good copy and leave the bubble untranslated if the proxy call fails.
  // Spec reminder (any languages): after a switch, only the absolute-last
  // incoming message is auto-translated for the chat-list preview; every
  // displayed bubble re-translates on demand when the chat is opened (Case A
  // below), off-screen bubbles stay lazy until scrolled into view.
  if (ref.mounted &&
      effectiveServerTranslation == null &&
      serverTranslation == null &&
      decryptedTranslation == null &&
      normalizedTarget == targetLanguage) {
    final msgFromDb = (await localDb.getMessages(
      matchId,
    )).where((m) => m['id']?.toString() == messageId).firstOrNull;
    if (msgFromDb?['content_translated_encrypted'] != null) {
      // Never wipe while a proxy translation is in flight: the server holds
      // a `#pending#` claim marker, and NULLing it would fail that
      // translation with "Claim lost — discarding our translation".
      bool claimPending = false;
      try {
        final truthRow = await supabase
            .from('chat_messages')
            .select('translated_target_language')
            .eq('id', messageId)
            .maybeSingle();
        if (!ref.mounted) return text;
        final truthTarget = truthRow?['translated_target_language'] as String?;
        claimPending = truthTarget != null && truthTarget.contains('#pending#');
      } catch (_) {}
      if (!claimPending) {
        try {
          await supabase
              .from('chat_messages')
              .update({
                'content_translated_encrypted': null,
                'content_translated_nonce': null,
              })
              .eq('id', messageId);
          await localDb.mergeMessages(matchId, [
            {
              'id': messageId,
              'content_translated_encrypted': null,
              'content_translated_nonce': null,
            },
          ]);
        } catch (_) {}
      }
    }
  }

  // Before triggering a batch translate, try fetching the message directly
  // from Supabase.  The smart retranslation may have already created a
  // content_translated_encrypted for the current UI language, but the local DB
  // still has the old broken data (from the initial webhook).  Fetching fresh
  // data avoids an unnecessary batch round trip.
  if (effectiveServerTranslation == null && serverTranslation == null) {
    try {
      // Read providers before async gap to avoid disposed-ref crash
      final chatKeyState = ref.read(chatKeyProvider);
      final freshData = await supabase
          .from('chat_messages')
          .select(
            'id, content_translated_encrypted, content_translated_nonce, translated_target_language, detected_source_language, encryption_scheme, sender_id, sender_key_id, recipient_key_id, wrapped_keys, match_id, recipient_id, edited_at, translated_source_edited_at',
          )
          .eq('id', messageId)
          .maybeSingle();
      if (!ref.mounted) return text;
      if (freshData != null) {
        final freshEnc = freshData['content_translated_encrypted'] as String?;
        final freshNonce = freshData['content_translated_nonce'] as String?;
        final freshTarget = freshData['translated_target_language'] as String?;
        final freshEncScheme = freshData['encryption_scheme'] as String?;
        final freshEditedAt = normalizeEditMarker(freshData['edited_at']);
        // Only adopt a stored translation the server vouches was made for the
        // row's current content. Its AAD binds the target language but not the
        // content, so a pre-edit blob decrypts cleanly here and would be
        // rendered (and cached as the chat-list preview) for edited text.
        final freshTranslationIsCurrent = translationEditMarkersMatch(
          normalizeEditMarker(freshData['translated_source_edited_at']),
          freshEditedAt,
        );
        if (freshEnc != null &&
            freshEnc.isNotEmpty &&
            freshNonce != null &&
            freshNonce.isNotEmpty &&
            freshEncScheme == 'v1' &&
            freshTarget == targetLanguage &&
            freshTranslationIsCurrent) {
          if (chatKeyState.privateKeyBytes != null) {
            String? recipientId = freshData['recipient_id'] as String?;
            final freshDecrypted = await ChatKeyService.instance
                .decryptMessageTranslatedContent(
                  currentUserId: currentUserId,
                  currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                  messageId: freshData['id'] as String,
                  matchId: matchId,
                  senderId: freshData['sender_id'] as String,
                  senderKeyId: freshData['sender_key_id'] as String,
                  recipientKeyId: freshData['recipient_key_id'] as String,
                  contentTranslatedEncryptedBase64: freshEnc,
                  contentTranslatedNonceBase64: freshNonce,
                  wrappedKeys:
                      (freshData['wrapped_keys'] as Map<String, dynamic>?) ??
                      {},
                  detectedSourceLanguage:
                      freshData['detected_source_language'] as String? ?? 'und',
                  targetLanguage: targetLanguage,
                  recipientId: recipientId != null && recipientId.isNotEmpty
                      ? recipientId
                      : null,
                );
            if (!ref.mounted) return text;
            if (freshDecrypted != null && freshDecrypted.isNotEmpty) {
              await localDb.mergeMessages(matchId, [
                {
                  'id': messageId,
                  'translated_target_language': freshTarget ?? targetLanguage,
                  // Local cache field (not part of server schema) used by UI rendering.
                  'content_translated': freshDecrypted,
                },
              ]);
              final currentUserId2 = supabase.auth.currentUser?.id;
              if (currentUserId2 != null) {
                await localDb.updateChatLastMessageTranslation(
                  currentUserId2,
                  matchId,
                  messageId,
                  freshDecrypted,
                  targetLanguage: freshTarget ?? targetLanguage,
                  editedAt: freshEditedAt,
                );
              }
              return translateResult(freshDecrypted);
            }
          }
        }
      }
    } catch (_) {}
  }

  // Translate via a per-match, per-language SINGLE-FLIGHT batch.
  //
  // On chat open / language switch, every currently displayed incoming
  // bubble fires its own provider instance. Previously each instance built
  // its own overlapping batch (self + the most recent candidates), so N
  // visible bubbles produced N concurrent translate-proxy requests whose id
  // lists overlapped — and because none of the batches had committed yet,
  // every request re-sent the same messages to DeepL (observed as identical
  // messages translated 3x within one second in the edge function logs).
  //
  // Now the FIRST bubble (the "leader") runs the one shared batch for the
  // match+language; every other bubble ("waiter") awaits that same future
  // and then reads its own translation from Supabase. A waiter whose message
  // was not covered by the leader's batch (e.g. it fell outside the
  // recent-12 window) retries once as the leader of a follow-up batch,
  // which the server-side skip/claim reduces to a cheap no-op for anything
  // already translated. Off-screen messages have no provider instance yet
  // (ListView.builder) and translate lazily when scrolled into view.
  //
  // The per-message flag MUST be released on every exit path via the
  // try/finally below; without it, any throw would leave the flag stuck on
  // `true` for this message, freezing re-translation of that bubble until
  // the next app launch. Other bubbles use different keys and are never
  // blocked.
  final batchState = ref.read(translationBatchStateProvider.notifier);
  if (batchState.isRunningForMessage(matchId, messageId)) {
    // debugPrint('🔄 Translation Provider: Already translating $messageId, skipping duplicate');
    return translateResult(text);
  }

  /// Runs the one shared batch request for this match + language: candidate
  /// ids from the local DB, minus ids Supabase already has translated for
  /// the target language, then a single TranslationProxy.invoke. Shared by
  /// every visible bubble via [TranslationBatchNotifier.inFlightBatch].
  Future<void> runSharedBatch() async {
    final currentMessages = await localDb.getMessages(matchId);
    if (!ref.mounted) return;

    final candidateMessageIds = currentMessages
        .where((msg) {
          if (msg['sender_id']?.toString() == currentUserId) {
            return false;
          }
          final msgId = msg['id']?.toString();
          if (msgId == null || msgId.isEmpty) {
            return false;
          }
          final original = msg['content_original']?.toString();
          if (original == null || original.isEmpty || original == 'null') {
            return false;
          }

          final msgTarget = normalizeLanguageCode(
            ((msg['translated_target_language'] ?? msg['translated_lang'])
                    ?.toString() ??
                ''),
          );
          if (msgTarget == targetLanguage) {
            return false;
          }

          final msgSourceRaw = msg['detected_source_language']?.toString();
          if (isValidLanguageCode(msgSourceRaw) &&
              normalizeLanguageCode(msgSourceRaw!) == targetLanguage) {
            return false;
          }

          return true;
        })
        .map((msg) => msg['id']!.toString())
        .toList();

    // Batch the most recent incoming messages that still need translation.
    // This avoids a burst of one translate-proxy request per visible bubble,
    // which can trigger the client's 403 cooldown and leave older bubbles
    // stuck showing their original text after repeated language switches.
    final requestMessageIds = <String>{
      ...candidateMessageIds.length > 12
          ? candidateMessageIds.sublist(candidateMessageIds.length - 12)
          : candidateMessageIds,
      messageId,
    }.toList();

    // Server-truth guard: localDb may still hold the old target language for
    // the absolute-last message (smart retranslation updates Supabase first;
    // the local merge may not have landed yet, or this chat was opened before
    // smart finished). Exclude any batched id other than the current bubble
    // that Supabase already has translated for targetLanguage, so the
    // already-translated last message never goes to DeepL again — only the
    // rest of the messages that still need translation are sent.
    var effectiveRequestIds = requestMessageIds;
    if (!shouldSkipSupabaseCalls() && requestMessageIds.length > 1) {
      try {
        final rows = await supabase
            .from('chat_messages')
            .select(
              'id, translated_target_language, content_translated_encrypted, content_translated_nonce',
            )
            .inFilter('id', requestMessageIds);
        if (!ref.mounted) return;
        final alreadyDone = <String>{};
        for (final row in (rows as List)) {
          final rowId = row['id']?.toString();
          if (rowId == null || rowId == messageId) continue;
          final rowTarget = (row['translated_target_language'] as String?)
              ?.toLowerCase();
          final rowEnc = row['content_translated_encrypted'] as String?;
          final rowNonce = row['content_translated_nonce'] as String?;
          if (rowTarget == targetLanguage.toLowerCase() &&
              rowEnc != null &&
              rowEnc.isNotEmpty &&
              rowEnc != 'null' &&
              rowNonce != null &&
              rowNonce.isNotEmpty) {
            alreadyDone.add(rowId);
          }
        }
        if (alreadyDone.isNotEmpty) {
          effectiveRequestIds = requestMessageIds
              .where((id) => id == messageId || !alreadyDone.contains(id))
              .toList();
          debugPrint(
            '🔄 Translation Provider: Excluding ${alreadyDone.length} already-translated message(s) from batch for UI=$targetLanguage',
          );
        }
      } catch (_) {
        // Best-effort guard only — fall back to the local candidate list.
      }
    }

    final requestBody = {
      'match_id': matchId,
      'target_language': targetLanguage,
      // translate-proxy expects message_ids for batch translation.
      'message_ids': effectiveRequestIds,
      // IMPORTANT: Only translate messages from OTHER users (incoming messages)
      // This prevents translating our own messages when we change our UI language
      'exclude_sender_id': currentUserId,
    };

    // Pass client-side source language detection so DeepL never auto-detects
    // short ambiguous words incorrectly (e.g. "Ten" → Polish "pl" → "this").
    if (effectiveRequestIds.length == 1 &&
        sourceLanguage != null &&
        sourceLanguage.isNotEmpty &&
        sourceLanguage != 'und') {
      requestBody['source_language'] = sourceLanguage;
    }

    // #region debug-point A:translation-request
    unawaited(
      http
          .post(
            Uri.parse('http://10.0.0.2:7777/event'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sessionId': 'chat-retranslation-miss',
              'runId': 'post-fix',
              'hypothesisId': 'A',
              'location':
                  'chat_provider.dart:translationFamilyProvider:request',
              'msg': '[DEBUG] translation request start',
              'data': {
                'matchId': matchId,
                'messageId': messageId,
                'targetLanguage': targetLanguage,
                'sourceLanguage': sourceLanguage,
                'normalizedTarget': normalizedTarget,
                'isEncrypted': isEncrypted,
                'requestMessageCount': effectiveRequestIds.length,
              },
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .catchError((_) => http.Response('', 204)),
    );
    // #endregion

    final response = await TranslationProxy.invoke(body: requestBody);

    // Check if provider is still mounted before using ref
    if (!ref.mounted) {
      // debugPrint('ðŸ”„ Translation Provider: Provider disposed, returning original text');
      return;
    }

    if (response.data != null) {
      final _ = response.data['translated'] ?? 0;
      // #region debug-point A:translation-response
      unawaited(
        http
            .post(
              Uri.parse('http://10.0.0.2:7777/event'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'sessionId': 'chat-retranslation-miss',
                'runId': 'post-fix',
                'hypothesisId': 'A',
                'location':
                    'chat_provider.dart:translationFamilyProvider:response',
                'msg': '[DEBUG] translation request completed',
                'data': {
                  'matchId': matchId,
                  'messageId': messageId,
                  'translatedCount': response.data['translated'],
                  'responseKeys': response.data is Map
                      ? (response.data as Map).keys.toList()
                      : null,
                },
                'ts': DateTime.now().millisecondsSinceEpoch,
              }),
            )
            .catchError((_) => http.Response('', 204)),
      );
      // #endregion
    }
  }

  /// Fetches this message's row straight from Supabase (server truth after
  /// a batch), decrypts the encrypted translation, merges it into the local
  /// DB and refreshes the chat preview. Returns the translation usable for
  /// the current UI language, or null. Runs for the leader AND for waiters.
  Future<String?> fetchAndApplyFreshTranslation() async {
    // After batch translation, the NEW translation should be in Supabase
    // IMPORTANT: Fetch directly from Supabase, not from local cache, to get fresh data
    final chatKeyState = ref.read(chatKeyProvider);
    final freshData = await supabase
        .from('chat_messages')
        .select(
          'id, content_translated_encrypted, content_translated_nonce, translated_target_language, detected_source_language, encryption_scheme, sender_id, sender_key_id, recipient_key_id, wrapped_keys, match_id, recipient_id, edited_at, translated_source_edited_at',
        )
        .eq('match_id', matchId)
        .eq('id', messageId)
        .maybeSingle();

    // #region debug-point B:fresh-fetch
    unawaited(
      http
          .post(
            Uri.parse('http://10.0.0.2:7777/event'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sessionId': 'chat-retranslation-miss',
              'runId': 'post-fix',
              'hypothesisId': 'B',
              'location':
                  'chat_provider.dart:translationFamilyProvider:freshFetch',
              'msg': '[DEBUG] fetched post-translation payload',
              'data': {
                'matchId': matchId,
                'messageId': messageId,
                'freshTargetLang': freshData?['translated_target_language'],
                'freshEncScheme': freshData?['encryption_scheme'],
                'hasEncrypted':
                    (freshData?['content_translated_encrypted'] as String?)
                        ?.isNotEmpty ==
                    true,
                'hasNonce':
                    (freshData?['content_translated_nonce'] as String?)
                        ?.isNotEmpty ==
                    true,
              },
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .catchError((_) => http.Response('', 204)),
    );
    // #endregion

    if (!ref.mounted) return null;

    // Server stores encrypted translations in chat_messages.
    final newTranslation = null;
    final newTargetLang = freshData?['translated_target_language'] as String?;
    // Content version the post-batch payload describes. A translation stored
    // for an earlier version of the content still decrypts, so refuse to adopt
    // it — the batch is over, and the only correct outcome now is "no
    // translation yet", which the chat-list preview and the bubble both
    // resolve to their loading state rather than to pre-edit text.
    final freshEditedAt = normalizeEditMarker(freshData?['edited_at']);
    final freshTranslationIsCurrent = translationEditMarkersMatch(
      normalizeEditMarker(freshData?['translated_source_edited_at']),
      freshEditedAt,
    );

    // For encrypted messages, content_translated is NULL in the DB.
    // Try to decrypt content_translated_encrypted directly.
    String? decryptedTranslation;
    final encScheme = freshData?['encryption_scheme'] as String?;
    if ((newTranslation == null ||
            newTranslation.isEmpty ||
            newTranslation == 'null') &&
        encScheme == 'v1') {
      final encrypted = freshData?['content_translated_encrypted'] as String?;
      final nonce = freshData?['content_translated_nonce'] as String?;
      if (encrypted != null &&
          encrypted.isNotEmpty &&
          nonce != null &&
          nonce.isNotEmpty) {
        try {
          if (chatKeyState.privateKeyBytes != null) {
            String? effectiveRecipientId =
                freshData!['recipient_id'] as String?;
            decryptedTranslation = await ChatKeyService.instance
                .decryptMessageTranslatedContent(
                  currentUserId: currentUserId,
                  currentUserPrivateKey: chatKeyState.privateKeyBytes!,
                  messageId: freshData['id'] as String,
                  matchId: matchId,
                  senderId: freshData['sender_id'] as String,
                  senderKeyId: freshData['sender_key_id'] as String,
                  recipientKeyId: freshData['recipient_key_id'] as String,
                  contentTranslatedEncryptedBase64: encrypted,
                  contentTranslatedNonceBase64: nonce,
                  wrappedKeys:
                      (freshData['wrapped_keys'] as Map<String, dynamic>?) ??
                      {},
                  detectedSourceLanguage:
                      freshData['detected_source_language'] as String? ?? 'und',
                  targetLanguage: newTargetLang ?? targetLanguage,
                  recipientId:
                      effectiveRecipientId != null &&
                          effectiveRecipientId.isNotEmpty
                      ? effectiveRecipientId
                      : null,
                );
          }
        } catch (e) {
          debugPrint(
            '[Translation] decryptMessageTranslatedContent (freshData) failed: $e',
          );
        }

        // Fallback to encrypted cache
        if (decryptedTranslation == null) {
          try {
            final cached =
                freshData?['content_translated_encrypted_cache'] as String?;
            if (cached != null && cached.isNotEmpty) {
              decryptedTranslation = await EncryptedCacheService.instance
                  .decryptFromCache(cached);
              debugPrint(
                '[Translation] Decrypted via encrypted cache fallback',
              );
            }
          } catch (e) {
            debugPrint('[Translation] Encrypted cache fallback failed: $e');
          }
        }
      }
    }

    // #region debug-point B:decrypt-result
    unawaited(
      http
          .post(
            Uri.parse('http://10.0.0.2:7777/event'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sessionId': 'chat-retranslation-miss',
              'runId': 'post-fix',
              'hypothesisId': 'B',
              'location':
                  'chat_provider.dart:translationFamilyProvider:decrypt',
              'msg': '[DEBUG] decrypt result evaluated',
              'data': {
                'matchId': matchId,
                'messageId': messageId,
                'newTargetLang': newTargetLang,
                'targetLanguage': targetLanguage,
                'hasEffectiveTranslation':
                    ((newTranslation ?? decryptedTranslation)
                        ?.toString()
                        .isNotEmpty ??
                    false),
                'effectiveTranslationLength':
                    (newTranslation ?? decryptedTranslation)
                        ?.toString()
                        .length ??
                    0,
              },
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .catchError((_) => http.Response('', 204)),
    );
    // #endregion

    // Use the decrypted translation
    final effectiveTranslation = newTranslation ?? decryptedTranslation;

    // Return the fresh translation if it matches our target language
    if (effectiveTranslation != null &&
        effectiveTranslation.isNotEmpty &&
        effectiveTranslation != 'null' &&
        newTargetLang == targetLanguage &&
        freshTranslationIsCurrent) {
      // Persist to local DB so subsequent evaluations find it
      // via Case C / hasTranslationForTarget
      try {
        await localDb.mergeMessages(matchId, [
          {
            'id': messageId,
            'content_translated': effectiveTranslation,
            'translated_target_language': newTargetLang ?? targetLanguage,
          },
        ]);
        // #region debug-point C:writeback
        unawaited(
          http
              .post(
                Uri.parse('http://10.0.0.2:7777/event'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({
                  'sessionId': 'chat-retranslation-miss',
                  'runId': 'post-fix',
                  'hypothesisId': 'C',
                  'location':
                      'chat_provider.dart:translationFamilyProvider:writeback',
                  'msg': '[DEBUG] local translation writeback completed',
                  'data': {
                    'matchId': matchId,
                    'messageId': messageId,
                    'newTargetLang': newTargetLang,
                    'translationLength': effectiveTranslation.length,
                  },
                  'ts': DateTime.now().millisecondsSinceEpoch,
                }),
              )
              .catchError((_) => http.Response('', 204)),
        );
        // #endregion
      } catch (_) {}

      // Update chat preview with translated message
      try {
        final currentUserId = supabase.auth.currentUser?.id;
        if (currentUserId != null) {
          await localDb.updateChatLastMessageTranslation(
            currentUserId,
            matchId,
            messageId,
            effectiveTranslation,
            targetLanguage: newTargetLang ?? targetLanguage,
            editedAt: freshEditedAt,
          );
        }
      } catch (e) {}

      return translateResult(effectiveTranslation);
    }
    return null;
  }

  batchState.setRunningForMessage(matchId, messageId, true);
  try {
    for (var round = 0; round < 2; round++) {
      if (!ref.mounted) return text;

      final inFlight = batchState.inFlightBatch(matchId, targetLanguage);
      if (inFlight != null) {
        // Another bubble is already translating this match for this
        // language — wait for its batch instead of racing it with an
        // overlapping request. (Bounded so a hung batch cannot block us
        // forever; the server-side claim keeps any late request safe.)
        try {
          await inFlight.timeout(const Duration(seconds: 30));
        } catch (_) {}
        final translation = await fetchAndApplyFreshTranslation();
        if (translation != null) return translation;
        continue; // our message wasn't covered — retry once as the leader
      }

      // Leader: run the one shared batch for this match + language.
      final batchFuture = runSharedBatch();
      batchState.registerInFlightBatch(matchId, targetLanguage, batchFuture);
      batchState.setRunning(matchId, true);
      try {
        await batchFuture;
      } finally {
        batchState.clearInFlightBatch(matchId, targetLanguage, batchFuture);
        batchState.setRunning(matchId, false);
      }
      final translation = await fetchAndApplyFreshTranslation();
      if (translation != null) return translation;
    }
  } catch (e) {
    // #region debug-point E:provider-error
    unawaited(
      http
          .post(
            Uri.parse('http://10.0.0.2:7777/event'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sessionId': 'chat-retranslation-miss',
              'runId': 'post-fix',
              'hypothesisId': 'E',
              'location': 'chat_provider.dart:translationFamilyProvider:catch',
              'msg': '[DEBUG] translation provider caught error',
              'data': {
                'matchId': matchId,
                'messageId': messageId,
                'error': e.toString(),
              },
              'ts': DateTime.now().millisecondsSinceEpoch,
            }),
          )
          .catchError((_) => http.Response('', 204)),
    );
    // #endregion
  } finally {
    // Always release this message's flag so a later rebuild of the SAME
    // bubble can retry. Other bubbles use different keys and never waited.
    batchState.setRunningForMessage(matchId, messageId, false);
    batchState.setRunning(matchId, false);
  }

  // Check mounted again before returning
  if (!ref.mounted) {
    return translateResult(text);
  }

  // Return original text if no fresh translation available
  return translateResult(text);
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
  return RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]',
    unicode: true,
  ).hasMatch(grapheme);
}

/// Provider to ensure the last incoming chat message is aligned with the current UI language.
/// On app run/resume, this re-checks translation-enabled chats and translates only the
/// last message for each chat (the one shown in the chat preview). Other messages will be
/// translated on-demand when viewed.
final pendingMessageTranslationProvider = FutureProvider<void>((ref) async {
  if (_startupTranslationSyncInFlight != null) {
    await _startupTranslationSyncInFlight;
    return;
  }
  final completer = Completer<void>();
  _startupTranslationSyncInFlight = completer.future;
  if (offlineCacheManager.shouldUseCachedData()) {
    completer.complete();
    _startupTranslationSyncInFlight = null;
    return;
  }
  try {
    final authState = ref.watch(authStateProvider).value;
    if (authState == null) return;

    final session = authState.session;
    if (session == null) return;

    final userId = session.user.id;
    if (userId.isEmpty) return;

    await ref.read(localizationProvider.notifier).whenInitialized;
    final targetLanguage = normalizeLanguageCode(
      ref.read(localizationProvider).currentLocale.languageCode,
    );

    if (targetLanguage.isEmpty || targetLanguage == 'und') return;

    // debugPrint('🔄 Startup translation sync: target=$targetLanguage (lazy mode - only last message)');

    final chats = await supabase
        .from('chats')
        .select('match_id')
        .eq('user_id', userId)
        .eq('translation_enabled', true);

    if (chats.isEmpty) {
      // debugPrint('✅ Startup translation sync: no translation-enabled chats');
      return;
    }

    final localDb = ref.read(localDbProvider);

    // Batch chats to prevent rate limiting: process 3 at a time with 500ms delay between batches
    const int batchSize = 3;
    const Duration batchDelay = Duration(milliseconds: 500);

    for (
      int batchStart = 0;
      batchStart < chats.length;
      batchStart += batchSize
    ) {
      // Check auth before each batch in case user logged out mid-loop
      final currentSession = supabase.auth.currentSession;
      if (currentSession == null || currentSession.accessToken.isEmpty) {
        debugPrint('[Translation Sync] User logged out mid-sync, stopping');
        break;
      }

      // Extract batch
      final batchEnd = (batchStart + batchSize).clamp(0, chats.length);
      final batch = (chats as List).sublist(batchStart, batchEnd);

      // Process this batch in parallel
      await Future.wait(
        batch.map((rawChat) async {
          try {
            final matchId = rawChat['match_id']?.toString() ?? '';
            if (matchId.isEmpty) return;

            // Get the last message from local DB to check if it needs translation
            final messages = await localDb.getMessages(matchId);
            if (messages.isEmpty) return;

            final lastMessage = messages.last;
            final lastMessageId = lastMessage['id']?.toString();
            final senderId = lastMessage['sender_id']?.toString();

            if (lastMessageId == null || senderId == null) return;

            // Only translate if it's from the other user (incoming message)
            if (senderId == userId) return;

            // Check if translation is needed (Case A: UI != source AND UI != target)
            String? serverSourceLang =
                lastMessage['detected_source_language'] as String?;
            final serverTargetLang =
                (lastMessage['translated_target_language'] as String?) ??
                (lastMessage['translated_lang'] as String?);

            // Validate server's detected source language
            // If invalid (e.g. "st", "ts", null), try client-side detection
            if (!isValidLanguageCode(serverSourceLang)) {
              final originalContent =
                  lastMessage['content_original'] as String?;
              if (originalContent != null && originalContent.isNotEmpty) {
                try {
                  final translationService = ref.read(
                    translationServiceProvider,
                  );
                  final clientDetected = normalizeLanguageCode(
                    await translationService.identifyLanguage(originalContent),
                  );
                  if (isValidLanguageCode(clientDetected) &&
                      clientDetected != 'und') {
                    serverSourceLang = clientDetected;
                  }
                } catch (_) {}
              }
            }

            final normalizedSource = serverSourceLang != null
                ? normalizeLanguageCode(serverSourceLang)
                : null;
            final normalizedTarget = serverTargetLang != null
                ? normalizeLanguageCode(serverTargetLang)
                : null;

            // Check if translation is needed
            final needsTranslation =
                (normalizedSource != null &&
                    normalizedSource != targetLanguage) &&
                (normalizedTarget == null ||
                    normalizedTarget != targetLanguage);

            if (needsTranslation) {
              // Don't translate here - let locale_provider.dart handle this
              // This provider should only trigger UI updates, not API calls
              // The actual translation will happen when user opens the chat via translationFamilyProvider

              // Clear cached translations for ALL messages so they translate on-demand
              final allIncomingIds = messages
                  .where((m) => m['sender_id']?.toString() != userId)
                  .map((m) => m['id']?.toString())
                  .whereType<String>()
                  .toList();

              if (allIncomingIds.isNotEmpty) {
                await localDb.clearCachedTranslationsForMessages(
                  matchId,
                  allIncomingIds,
                );
              }

              // Trigger UI refresh
              if (ref.mounted) {
                ref.read(translationVersionProvider.notifier).increment();
              }
            }
          } catch (e) {
            // debugPrint('⚠️ Startup translation sync failed for a chat: $e');
          }
        }),
      );

      // Add delay between batches to prevent rate limiting (except after last batch)
      if (batchEnd < chats.length) {
        await Future.delayed(batchDelay);
      }
    }

    if (ref.mounted) {
      await ref.read(globalSyncManagerProvider).syncChatsNow(userId);
      // NOTE: Intentionally NOT incrementing translationVersionProvider here.
      // syncChatsNow already updates the local DB which re-emits via
      // chatMessagesProvider → widget rebuild → translationFamilyProvider.
      // The chat screen's own connectivity listener also handles the
      // re-evaluation trigger on reconnect. An extra increment here
      // would cause a 2nd complete re-evaluation of ALL messages.
    }

    // debugPrint('✅ Startup translation sync complete (lazy mode)');
  } catch (e) {
    // debugPrint('⚠️ Startup translation sync error: $e');
  } finally {
    if (!completer.isCompleted) {
      completer.complete();
    }
    _startupTranslationSyncInFlight = null;
  }
});

// --- Auto-fetch translations on reconnect ---
/// Provider that watches connectivity and automatically fetches missing translations
/// for the currently viewed chat when coming back online
final translationAutoFetchOnReconnectProvider = FutureProvider<void>((
  ref,
) async {
  // This provider listens to connectivity changes and the current viewed chat
  // When reconnecting, it automatically fetches translations for messages that need them

  // We'll rely on the translationFamilyProvider which is already watching
  // connectivity and will automatically call translate-proxy when needed
  // This happens through the Case A/B/C logic when messages are viewed

  await Future.value(); // Completes immediately
});

// Store for tracking which messages have pending translations
final Map<String, Set<String>> _messagesWithPendingTranslations = {};

/// Mark a message as having a pending translation (needs to be fetched when online)
void _addPendingTranslation(String matchId, String messageId) {
  _messagesWithPendingTranslations.putIfAbsent(matchId, () => {});
  _messagesWithPendingTranslations[matchId]!.add(messageId);
}

/// Get all messages with pending translations for a match
Set<String> getPendingTranslations(String matchId) {
  return _messagesWithPendingTranslations[matchId] ?? {};
}

/// Clear pending translations for a match
void clearPendingTranslations(String matchId) {
  _messagesWithPendingTranslations.remove(matchId);
}
