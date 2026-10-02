// lib/providers/home_providers.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/background_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:matchme/utils/notification_limits.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/encrypted_notification_preview_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/services/web_location_service.dart';
import 'package:matchme/providers/chat_key_provider.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/providers/chat_provider.dart' show translationProvider;
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/expiry_local_schedule_service.dart';

final supabase = Supabase.instance.client;

// Helper function to format sender name: "FirstName LastInitial." e.g., "John S."
// Falls back to "Unknown User" instead of a brand name so we never advertise the
// app in place of the actual sender.
// Capitalizes first letters regardless of input casing and handles multiple
// first/last names (e.g. Spanish names).
String formatSenderNameForNotification(String fullName) {
  if (fullName.isEmpty) return 'Unknown User';

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
  if (parts.isEmpty) return 'Unknown User';
  if (parts.length == 1) {
    return capWord(parts[0]); // Just first name if no last name
  }

  // First name + first letter of last name with period
  final firstName = capWord(parts[0]);
  final lastInitial = parts[parts.length - 1][0].toUpperCase();
  return '$firstName $lastInitial.';
}

// Resolves the chat counterpart's display name for notifications.
// Priority:
//   1) Local Hive chat row (other_user_name / otherUserName) — already masked,
//      RLS-free, available even when offline.
//   2) Supabase users.name lookup (may fail under transient network / RLS).
//   3) formatSenderNameForNotification of whatever non-empty string we got.
//   4) "Someone" as the last-resort fallback (never the brand name).
Future<String> _resolveChatNotificationSenderName({
  required LocalDbService localDb,
  required String currentUserId,
  required String matchId,
  required String senderId,
}) async {
  // 1) Local chat row (always-masked other_user_name from the recipient's view).
  try {
    final cachedChats = await localDb.loadChats(currentUserId);
    if (cachedChats != null) {
      for (final chat in cachedChats) {
        if (chat['match_id'] == matchId) {
          final raw = (chat['other_user_name'] ?? chat['otherUserName'] ?? '')
              .toString()
              .trim();
          if (raw.isNotEmpty && raw != 'Unknown User') {
            return formatSenderNameForNotification(raw);
          }
          break;
        }
      }
    }
  } catch (_) {
    // ignore and fall through
  }

  // 2) Supabase users.name (best-effort).
  try {
    final userData = await supabase
        .from('users')
        .select('name')
        .eq('id', senderId)
        .single();
    final raw = (userData['name'] as String? ?? '').trim();
    if (raw.isNotEmpty) {
      return formatSenderNameForNotification(raw);
    }
  } catch (_) {
    // ignore and fall through
  }

  return 'Someone';
}

// --- recentMatchesProvider (Reads Local DB Only) ---
final recentMatchesProvider = StreamProvider.autoDispose.family<List<MatchModel>, String>((
  ref,
  userId,
) {
  if (userId.isEmpty) return Stream.value([]);

  // Check if user is still authenticated. Same cached-empty-stream hazard
  // as recentChatsProvider: if this body runs while the auth user differs
  // from [userId] (sign-out transition of a logout/login user switch), the
  // `Stream.value([])` below is cached by Riverpod and the matches tab
  // stays empty even after the correct user signs back in. Rebuild this
  // provider when the authenticated user becomes [userId] again.
  if (supabase.auth.currentUser?.id != userId) {
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (prev, next) {
      if (!ref.mounted) return;
      final currentId = supabase.auth.currentUser?.id;
      if (currentId != userId) return;
      debugPrint(
        '🏠 [recentMatchesProvider] Auth user became $userId — rebuilding provider (was built for a different user)',
      );
      ref.invalidateSelf();
    });
    return Stream.value([]);
  }

  final localDb = ref.watch(localDbProvider);

  // Ensure sync manager is initialized to trigger initial data sync (use read, not watch, to avoid rebuilds)
  ref.read(globalSyncManagerProvider);

  final localStream = localDb.watchMatches(userId);

  return localStream
      .map((list) {
        final mapped = list
            .map((json) => MatchModel.fromJsonRpc(json, userId))
            .toList();
        return mapped;
        // NOTE: no manual ID dedup here - saveMatches already skips identical
        // writes, so any Hive event is a real change. Returning the same instance
        // still emits; use .distinct below with full equality to suppress flicker.
      })
      .distinct(_areMatchesEqual);
});

bool _areMatchesEqual(List<MatchModel> a, List<MatchModel> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.id != y.id) return false;
    if (x.matchOccurrence != y.matchOccurrence) return false;
    if (x.matchedIntent != y.matchedIntent) return false;
    if (x.matchType != y.matchType) return false;
    if (x.otherUserId != y.otherUserId) return false;
    if (x.chatStartWindowSeconds != y.chatStartWindowSeconds) return false;
    if (x.chatStartExtensionSeconds != y.chatStartExtensionSeconds) {
      return false;
    }
    if (x.chatStartExtensionCount != y.chatStartExtensionCount) return false;
    if (x.hasExtended != y.hasExtended) return false;
    if (x.createdAt.millisecondsSinceEpoch !=
        y.createdAt.millisecondsSinceEpoch) {
      return false;
    }
    if ((x.expiresAt?.millisecondsSinceEpoch ?? -1) !=
        (y.expiresAt?.millisecondsSinceEpoch ?? -1)) {
      return false;
    }
    if ((x.mapCenterLat ?? -9999) != (y.mapCenterLat ?? -9999)) return false;
    if ((x.mapCenterLng ?? -9999) != (y.mapCenterLng ?? -9999)) return false;
    if ((x.mapZoom ?? -1) != (y.mapZoom ?? -1)) return false;
    if (x.previousLocations.length != y.previousLocations.length) return false;
  }
  return true;
}

/// Value-equality for dashboard stats maps. `Map.==` is identity-based, so
/// comparing a freshly-fetched `{online, nearby}` map with `!=` is always
/// true — every fetch (realtime user_activity event, resume, timer) would
/// re-emit and rebuild the home stat cards even when the counts were
/// unchanged, contributing to the home-screen "twitch".
bool _sameDashboardStats(Map<String, int?>? a, Map<String, int?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a['online'] == b['online'] && a['nearby'] == b['nearby'];
}

// --- END UPDATE ---

// Track previous chat states for detecting new unread messages via sync path
final Map<String, int> _previousChatUnreadCounts = {};
final Set<String> _pendingTranslatedNotificationMessageIds = <String>{};
final Set<String> _notifiedMessageIds = <String>{};
// Tracks message IDs added to local DB during this session. Used to
// distinguish replayed realtime events (cold-start reconnect) from
// genuine new messages. An UPDATE (translation arrival) for a message
// that was NOT added this session is a replay – skip the notification.
final Set<String> _sessionAddedMessageIds = <String>{};
final Map<String, ChatModel> _recentChatSnapshots = <String, ChatModel>{};
final Set<String> _inFlightPreviewTranslationKeys = <String>{};

// Bounded retries for preview translations: one transient failure (proxy 403
// cooldown, brief decrypt miss) must not wedge the preview blank forever.
// Attempts are keyed like the single-flight set above; each retry re-runs the
// full trigger (cache re-validated first), so a translation that landed
// meanwhile short-circuits before any network call.
final Map<String, int> _previewTranslationAttempts = <String, int>{};
const int _previewTranslationMaxAttempts = 3;
Duration _previewTranslationRetryDelay(int attempt) {
  switch (attempt) {
    case 1:
      return const Duration(seconds: 15);
    case 2:
      return const Duration(seconds: 90);
    default:
      return const Duration(minutes: 5);
  }
}

// Timers for pending translation notifications. If a translation doesn't arrive
// within the timeout, we fire the notification anyway with whatever content is
// available so the user isn't left without a notification.
final Map<String, Timer> _pendingTranslationTimeoutTimers = <String, Timer>{};
const Duration _pendingTranslationTimeout = Duration(seconds: 10);

void _schedulePendingTranslationTimeout(String messageId) {
  // Cancel any existing timer for this message
  _pendingTranslationTimeoutTimers[messageId]?.cancel();
  _pendingTranslationTimeoutTimers[messageId] = Timer(
    _pendingTranslationTimeout,
    () {
      // If the message is still pending after the timeout, the translation
      // never arrived. Remove from pending and clear any other state so the
      // next sync/realtime pass can show the notification with available content.
      if (_pendingTranslatedNotificationMessageIds.remove(messageId)) {
        _pendingTranslationTimeoutTimers.remove(messageId);
      }
    },
  );
}

// Tracks userIds that have already had their one-time initial server sync
// kicked off by recentChatsProvider's first build. Without this guard,
// every provider rebuild (e.g. when the UI language changes) re-arms
// the same `Future(() { syncService.syncChatsNow(userId); })`, so a single
// cold start with 3-4 L10N flips produced 3-4 redundant round-trips.
final Set<String> _initialSyncKickedAt = <String>{};

/// Resets the initial-sync tracking set so that [recentChatsProvider] will
/// re-arm its one-time server sync on the next build for every userId.
/// Called during logout to prevent stale state from leaking across sessions.
void clearInitialSyncKickedAt() => _initialSyncKickedAt.clear();

// --- fast-follow for a translated preview that is not ready yet ---
//
// syncChatsNow is normally driven by the 15s global timer and further gated by
// the 5s + 8s cooldowns in GlobalSyncManager, so a translation that
// translate-proxy had already finished could stay invisible for that whole
// window, leaving the chat row on "Loading…". When we can see that the last
// message still has no readable translation for the UI language, nudge a single
// forced sync shortly after the expected round trip so the row updates as soon
// as the text exists. One shot per (message, language) keeps this from
// degenerating into a poll loop; the normal timer still handles the long tail.
final Set<String> _previewRefreshInFlight = <String>{};
const Duration _previewTranslationRefreshDelay = Duration(seconds: 3);

// --- initialHomeSyncProvider ---
/// Completes once the first server sync of matches + chats has finished for
/// [userId] and the results have been written to the local DB.
///
/// Background: [recentMatchesProvider]/[recentChatsProvider] read the local
/// DB only, so their streams emit the (possibly empty) cached values almost
/// instantly — e.g. right after login, when the previous account's cache was
/// wiped on logout and the new account's server sync hasn't landed yet. An
/// `isLoading` gate therefore opens on an *empty* home that populates
/// seconds later. HomeScreen gates on this provider (when online) so the
/// home is only shown after real server data is in place.
///
/// Offline (or signed-out / mismatched-auth transitions) it completes
/// immediately so cached data is shown without waiting for a sync that can
/// never arrive. Failures and timeouts likewise resolve (showing whatever is
/// cached) instead of hanging the loader forever.
final initialHomeSyncProvider = FutureProvider.autoDispose.family<void, String>((
  ref,
  userId,
) async {
  if (userId.isEmpty) return;
  // Offline: nothing to sync — show cached data immediately.
  if (!offlineCacheManager.isSupabaseAvailable || shouldSkipSupabaseCalls()) {
    return;
  }
  // Only sync for the currently signed-in user. During a logout/login
  // transition this body can run for a userId that is no longer (or not
  // yet) authenticated; syncing then would fetch for the wrong account.
  if (supabase.auth.currentUser?.id != userId) return;
  if (supabase.auth.currentSession == null) return;

  final syncService = ref.read(globalSyncManagerProvider);
  final profileSync = ref.read(profileSyncProvider);
  final localDb = ref.read(localDbProvider);

  // A previous, complete home snapshot can be rendered as soon as Hive is
  // open. Do not make a relaunch wait on network requests that merely
  // confirm cached data. Keep the same refresh work, but make it strictly
  // background work; realtime and the local DB streams update the already
  // rendered screen if anything changed.
  if (await localDb.hasCompleteHomeCache(userId)) {
    debugPrint(
      '✅ [HOME_READY] Complete local home snapshot found for $userId — rendering cache while refresh runs',
    );
    unawaited(
      Future.wait([
        syncService.syncMatchesNow(userId),
        syncService.syncChatsNow(userId, force: true),
        profileSync.syncProfile(userId, source: 'warm-home-refresh'),
      ]).then((_) {
        // Warm matched-user caches (profiles + ratings + photos) so the
        // next startup renders instantly from memory + local storage.
        _warmMatchedUsersAfterHomeSync(ref, userId);
      }),
    );
    // Warm immediately from existing cache too (no network wait).
    unawaited(_warmMatchedUsersAfterHomeSync(ref, userId));
    return;
  }

  try {
    await Future.wait([
      syncService.syncMatchesNow(userId),
      // Forced: bypasses the rapid re-sync cooldowns so the very first
      // sync after login is never silently dropped.
      syncService.syncChatsNow(userId, force: true),
      // The profile stream can emit a cached null before its own
      // best-effort sync completes. Include it in the cold-cache gate so
      // a new login still opens only after every home section is ready.
      profileSync.syncProfile(userId, source: 'cold-home-initial-sync'),
    ]).timeout(const Duration(seconds: 30));
    // Cold start with fresh server data: warm matched-user caches now.
    unawaited(_warmMatchedUsersAfterHomeSync(ref, userId));
  } on TimeoutException {
    debugPrint(
      '⏳ [HOME_READY] Initial home sync timed out for $userId — showing cached data',
    );
  } catch (e) {
    debugPrint(
      '⚠️ [HOME_READY] Initial home sync failed for $userId: $e — showing cached data',
    );
  }
});

// Warms matched-user caches (profiles + ratings + photos) after the home
// sync so the next UI startup renders instantly from memory + local storage.
// Reads other-user ids from the local matches cache (no network), warms
// rating summaries (memory + Hive) and photo signed-URLs/image bytes, and
// refreshes stale other-user profiles in the background (spread to avoid a
// thundering-herd of RPCs). Best-effort: never throws, never blocks UI.
Future<void> _warmMatchedUsersAfterHomeSync(Ref ref, String userId) async {
  try {
    if (userId.isEmpty) return;
    if (supabase.auth.currentUser?.id != userId) return;
    final localDb = ref.read(localDbProvider);
    List<Map<String, dynamic>> matches = const [];
    try {
      matches = await localDb.watchMatches(userId).first;
    } catch (_) {
      return;
    }
    if (matches.isEmpty) return;
    final otherIds = <String>{};
    for (final m in matches) {
      final u1 = (m['user1_id'] ?? '').toString().trim();
      final u2 = (m['user2_id'] ?? '').toString().trim();
      final other = u1 == userId ? u2 : (u2 == userId ? u1 : '');
      if (other.isNotEmpty) otherIds.add(other);
      if (otherIds.length >= 30) break;
    }
    if (otherIds.isEmpty) return;

    // Ratings: memory + Hive warm + background Supabase refresh.
    try {
      MatchRatingService.prefetchSummaries(MatchRatingService(), otherIds);
    } catch (_) {}

    // Photos: prefetch from cached profiles + chats (uses persisted
    // signed-URL cache when valid, so no network when fresh).
    try {
      final sources = <String>{};
      for (final otherId in otherIds) {
        try {
          final profile = await localDb.getLocalProfile(otherId);
          final photos = profile?['photos'];
          if (photos is List) {
            for (final p in photos) {
              final s = p.toString().trim();
              if (s.isNotEmpty) sources.add(s);
              if (sources.length >= 60) break;
            }
          }
        } catch (_) {}
        if (sources.length >= 60) break;
      }
      try {
        final chats = await localDb.loadChats(userId);
        if (chats != null) {
          for (final c in chats) {
            final photos = c['other_user_photos'];
            if (photos is List) {
              for (final p in photos) {
                final s = p.toString().trim();
                if (s.isNotEmpty) sources.add(s);
                if (sources.length >= 60) break;
              }
            }
            if (sources.length >= 60) break;
          }
        }
      } catch (_) {}
      if (sources.isNotEmpty) {
        unawaited(
          StorageHelper.prefetchImageSources(sources).catchError((_) {}),
        );
      }
    } catch (_) {}

    // Profiles: background refresh for stale other-user rows (spread 300ms
    // apart to avoid bursting Supabase on cold start). The UI already shows
    // cached profiles instantly via userProfileProvider's local stream.
    try {
      if (shouldSkipSupabaseCalls()) return;
      final profileSync = ref.read(profileSyncProvider);
      var delayMs = 1500;
      for (final otherId in otherIds) {
        final id = otherId;
        final delay = delayMs;
        delayMs += 300;
        unawaited(
          Future.delayed(Duration(milliseconds: delay), () async {
            try {
              if (supabase.auth.currentUser?.id != userId) return;
              if (shouldSkipSupabaseCalls()) return;
              await profileSync.syncProfile(id, source: 'warm-home-refresh');
            } catch (_) {}
          }),
        );
      }
    } catch (_) {}
  } catch (_) {}
}

// Tracks the last time the user-data channel was kicked into a "reconnect
// recovery" pass (a syncChatsNow + syncMatchesNow fired from a closed/
// error subscribe callback). On cold start the websocket commonly cycles
// through several close/subscribed transitions within a few seconds, so
// without this guard each transition would re-issue the recovery RPC
// chain. 8 s is short enough to still cover real disconnects but long
// enough to absorb a normal cold-start websocket cycle.
final Map<String, DateTime> _lastRealtimeRecoveryAt = <String, DateTime>{};

// Tracks when each channel was last successfully subscribed. Used to
// detect cold-start close-storms: if a channel closes within 5 seconds
// of its last subscription, it's likely a WebSocket reconnect cycle, not
// a real disconnect. Recovery is skipped to avoid redundant syncChatsNow
// calls during cold start.
final Map<String, DateTime> _lastChannelSubscribedAt = <String, DateTime>{};

// Cache of the last semantically-identical input processed by recentChatsProvider's
// asyncMap per (userId, uiLang). When the provider body re-executes (e.g. because
// localizationProvider emits a value even though the locale didn't actually change),
// the stream is re-created and distinct() has no prior emission to compare against,
// so every value passes through. This cache lets asyncMap skip the full processing
// (decryption, translation display, notification dedup) and return the previously
// computed ChatModel list directly, avoiding a UI refresh for no change.
final Map<String, List<Map<String, dynamic>>> _recentChatsProcessedInput =
    <String, List<Map<String, dynamic>>>{};
final Map<String, List<ChatModel>> _recentChatsProcessedResult =
    <String, List<ChatModel>>{};

Future<void> _triggerImmediateLastMessageTranslation({
  required LocalDbService localDb,
  required String userId,
  required String matchId,
  required String messageId,
  required String targetLanguage,
  String? sourceLanguage,
}) async {
  final translationKey = '$userId|$matchId|$messageId|$targetLanguage';
  if (!_inFlightPreviewTranslationKeys.add(translationKey)) {
    return;
  }

  // Set when this attempt actually lands a usable translation below; the
  // retry in `finally` only fires while this stays false.
  var translatedOk = false;
  try {
    await TranslationProxy.invoke(
      body: {
        'match_id': matchId,
        'target_language': targetLanguage,
        'message_ids': [messageId],
        if (sourceLanguage != null &&
            sourceLanguage.isNotEmpty &&
            sourceLanguage != 'und')
          'source_language': sourceLanguage,
        'exclude_sender_id': userId,
      },
    );

    final refreshed = await supabase
        .from('chat_messages')
        .select(
          'id, translated_target_language, detected_source_language, encryption_scheme, '
          'content_translated_encrypted, content_translated_nonce, '
          'edited_at, translated_source_edited_at, '
          'sender_id, sender_key_id, recipient_key_id, wrapped_keys, recipient_id',
        )
        .eq('id', messageId)
        .maybeSingle();

    // A translation the server produced before the message was last edited
    // still decrypts (the AAD binds the target language, not the content), so
    // refuse to cache one whose version marker disagrees with `edited_at`.
    // This is the path that refills the Recent Chats row after an edit, so
    // trusting a stale blob here would put the old text straight back.
    final messageEditedAt = normalizeEditMarker(refreshed?['edited_at']);
    final translationIsCurrent = translationEditMarkersMatch(
      normalizeEditMarker(refreshed?['translated_source_edited_at']),
      messageEditedAt,
    );

    String? translated;
    final scheme = (refreshed?['encryption_scheme'] as String?) ?? 'v1';
    if (refreshed != null && translationIsCurrent) {
      if (scheme == 'v1') {
        final encrypted = refreshed['content_translated_encrypted'] as String?;
        final nonce = refreshed['content_translated_nonce'] as String?;
        if (encrypted != null &&
            encrypted.isNotEmpty &&
            nonce != null &&
            nonce.isNotEmpty) {
          try {
            final privateKey = await ChatKeyService.instance
                .loadPrivateKeyBytes(userId);
            if (privateKey != null) {
              final senderId = refreshed['sender_id'] as String?;
              final senderKeyId = refreshed['sender_key_id'] as String?;
              final recipientKeyId = refreshed['recipient_key_id'] as String?;
              final wrappedKeys =
                  refreshed['wrapped_keys'] as Map<String, dynamic>?;
              final recipientId = refreshed['recipient_id'] as String?;
              if (senderId != null &&
                  senderKeyId != null &&
                  recipientKeyId != null &&
                  wrappedKeys != null) {
                translated = await ChatKeyService.instance
                    .decryptMessageTranslatedContent(
                      currentUserId: userId,
                      currentUserPrivateKey: privateKey,
                      messageId: messageId,
                      matchId: matchId,
                      senderId: senderId,
                      senderKeyId: senderKeyId,
                      recipientKeyId: recipientKeyId,
                      contentTranslatedEncryptedBase64: encrypted,
                      contentTranslatedNonceBase64: nonce,
                      wrappedKeys: wrappedKeys,
                      detectedSourceLanguage:
                          refreshed['detected_source_language'] as String? ??
                          'und',
                      targetLanguage: targetLanguage,
                      recipientId: recipientId != null && recipientId.isNotEmpty
                          ? recipientId
                          : null,
                    );
              }
            }
          } catch (_) {}
        }
      }
    }
    final translatedTarget = refreshed?['translated_target_language']
        ?.toString();
    final hasTranslated =
        translated != null && translated.isNotEmpty && translated != 'null';
    final matchesTarget =
        translatedTarget != null &&
        translatedTarget.isNotEmpty &&
        normalizeLanguageCode(translatedTarget) == targetLanguage;

    if (hasTranslated && matchesTarget) {
      translatedOk = true;
      _previewTranslationAttempts.remove(translationKey);
      await localDb.mergeMessages(matchId, [
        {
          'id': messageId,
          'content_translated': translated,
          'translated_target_language': translatedTarget,
          // Version marker binding this translation to the content it was
          // made for. Without it, the open chat's local-plaintext fast path
          // rejects the cached text on edited messages and pays for a server
          // re-fetch (same text, redundant round trip — never a second
          // DeepL call, but wasted time all the same).
          ...?messageEditedAt == null
              ? null
              : {'translated_source_edited_at': messageEditedAt},
          if (refreshed?['detected_source_language'] != null)
            'detected_source_language': refreshed?['detected_source_language'],
          if (refreshed?['content_translated_encrypted'] != null)
            'content_translated_encrypted':
                refreshed?['content_translated_encrypted'],
          if (refreshed?['content_translated_nonce'] != null)
            'content_translated_nonce': refreshed?['content_translated_nonce'],
        },
      ]);
      await localDb.updateChatLastMessageTranslation(
        userId,
        matchId,
        messageId,
        translated,
        targetLanguage: targetLanguage,
        editedAt: messageEditedAt,
      );
    }
  } catch (e) {
    debugPrint(
      '🔄 [SYNC FALLBACK] Immediate preview translation failed for $messageId: $e',
    );
  } finally {
    _inFlightPreviewTranslationKeys.remove(translationKey);
    // Bounded retries so one transient failure (proxy 403 cooldown, brief
    // decrypt miss) can't wedge the preview blank forever: later attempts
    // re-run the whole function (which re-validates the cache first), and are
    // cheap no-ops when the server already translated (skip/claim) — DeepL is
    // still hit once. Gives up after [_previewTranslationMaxAttempts].
    if (!translatedOk) {
      try {
        final attempts = (_previewTranslationAttempts[translationKey] ?? 0) + 1;
        if (attempts <= _previewTranslationMaxAttempts) {
          _previewTranslationAttempts[translationKey] = attempts;
          final delay = _previewTranslationRetryDelay(attempts);
          Timer(delay, () {
            unawaited(
              _triggerImmediateLastMessageTranslation(
                localDb: localDb,
                userId: userId,
                matchId: matchId,
                messageId: messageId,
                targetLanguage: targetLanguage,
                sourceLanguage: sourceLanguage,
              ),
            );
          });
        } else {
          _previewTranslationAttempts.remove(translationKey);
        }
      } catch (_) {}
    }
  }
}

/// Realtime preview fast path for an incoming chat_messages INSERT.
///
/// `syncChatsNow` is periodic (15s) and cooldown-gated, so a new message's
/// Recent-Chats preview used to wait seconds (plus DeepL time) before showing
/// anything. This runs straight off the realtime payload instead:
/// 1. decrypt the original → merge plaintext into the messages box (the open
///    chat's Phase 1/2 also picks it up instantly),
/// 2. recompute the chats-box preview → watchChats emits → the list shows the
///    new original within ~websocket latency,
/// 3. if translation is enabled and needed, fire the single-flight
///    _triggerImmediateLastMessageTranslation (DeepL once; its writeback fills
///    both the messages box and the chats-box preview, which the open chat's
///    Case C / local-plaintext path then reuses without a second DeepL call).
///
/// Fire-and-forget; syncChatsNow remains the backstop. Never throws.
Future<void> _refreshPreviewForIncomingRealtimeMessage({
  required LocalDbService localDb,
  required String currentUserId,
  required String matchId,
  required String messageId,
  required Map<String, dynamic> newRecord,
  required String uiLang,
}) async {
  try {
    final senderId = newRecord['sender_id']?.toString() ?? '';
    final isIncoming = senderId.isNotEmpty && senderId != currentUserId;

    // 1. Decrypt the original for v1 rows (legacy plaintext rows already
    // carry content_original and skip this).
    if (newRecord['encryption_scheme'] == 'v1') {
      final contentEncrypted =
          newRecord['content_original_encrypted'] as String?;
      final contentNonce = newRecord['content_original_nonce'] as String?;
      final senderKeyId = newRecord['sender_key_id'] as String?;
      final recipientKeyId = newRecord['recipient_key_id'] as String?;
      final wrappedKeys = newRecord['wrapped_keys'];
      if (contentEncrypted != null &&
          contentEncrypted.isNotEmpty &&
          contentNonce != null &&
          contentNonce.isNotEmpty &&
          senderKeyId != null &&
          recipientKeyId != null &&
          wrappedKeys != null &&
          isIncoming) {
        try {
          final decrypted =
              await EncryptedNotificationPreviewService.instance.decryptPreview(
                messageId: messageId,
                matchId: matchId,
                senderId: senderId,
                recipientId: currentUserId,
                senderKeyId: senderKeyId,
                recipientKeyId: recipientKeyId,
                contentOriginalEncryptedBase64: contentEncrypted,
                contentOriginalNonceBase64: contentNonce,
                wrappedKeysJson: jsonEncode(wrappedKeys),
              );
          if (decrypted != null && decrypted.isNotEmpty) {
            await localDb.mergeMessages(matchId, [
              {
                'id': messageId,
                'content_original': decrypted,
                if (newRecord['detected_source_language'] != null)
                  'detected_source_language':
                      newRecord['detected_source_language'],
              },
            ]);
          }
        } catch (_) {}
      }
    }

    // 2. Recompute the preview from the messages box (now holding the
    // plaintext) so watchChats emits the new last message immediately.
    try {
      await localDb.recomputeChatLastMessagePreviewFromMessages(
        currentUserId,
        matchId,
      );
    } catch (_) {}

    // 3. Translation, single-flight: only for incoming messages in chats with
    // translation on, and only when no current translation is cached yet.
    if (!isIncoming) return;
    bool translationEnabled = false;
    try {
      translationEnabled = await localDb.isTranslationEnabled(
        matchId,
        userId: currentUserId,
      );
    } catch (_) {
      return;
    }
    if (!translationEnabled) return;
    try {
      final cached = await localDb.getMessageById(matchId, messageId);
      if (cached != null) {
        final rawTranslated =
            (cached['content_translated'] ?? cached['translated_text'])
                as String?;
        final rawTarget =
            (cached['translated_target_language'] ?? cached['translated_lang'])
                ?.toString();
        if (rawTranslated != null &&
            rawTranslated.isNotEmpty &&
            rawTranslated != 'null' &&
            !looksLikeEncryptedBlob(rawTranslated) &&
            rawTarget != null &&
            normalizeLanguageCode(rawTarget) == uiLang &&
            translationEditMarkersMatch(
              normalizeEditMarker(cached['translated_source_edited_at']),
              normalizeEditMarker(cached['edited_at']),
            )) {
          return; // current translation already cached — nothing to do.
        }
        final sourceRaw = (cached['detected_source_language'] ??
                newRecord['detected_source_language'])
            ?.toString();
        if (sourceRaw != null &&
            sourceRaw.isNotEmpty &&
            sourceRaw != 'null' &&
            isValidLanguageCode(sourceRaw) &&
            normalizeLanguageCode(sourceRaw) == uiLang) {
          return; // Case B: message is already in the UI language.
        }
      }
    } catch (_) {}
    final sourceLang = guessLanguageCode(
      newRecord['content_original']?.toString() ?? '',
    );
    unawaited(
      _triggerImmediateLastMessageTranslation(
        localDb: localDb,
        userId: currentUserId,
        matchId: matchId,
        messageId: messageId,
        targetLanguage: uiLang,
        sourceLanguage: sourceLang,
      ),
    );
  } catch (_) {}
}

Duration _jitteredBackoff(int attempt) {
  final base = Duration(milliseconds: (1000 * pow(2, attempt)).round());
  final jitter = Duration(milliseconds: Random().nextInt(1000));
  return base + jitter;
}

// --- recentChatsProvider (Reads Local DB Only) ---
final recentChatsProvider = StreamProvider.family<List<ChatModel>, String>((
  ref,
  userId,
) {
  debugPrint(
    'LocationShare: recentChatsProvider body called for userId=$userId',
  );
  if (userId.isEmpty) {
    return Stream.value([]);
  }

  // Reconnection attempt counters to prevent infinite loops
  int chatMessagesReconnectAttempts = 0;
  int matchesReconnectAttempts = 0;
  int chatsReconnectAttempts = 0;
  final int maxReconnectAttempts = 5;

  // Check if user is still authenticated. When the provider body runs while
  // `supabase.auth.currentUser` differs from [userId] (e.g. a rebuild during
  // the sign-out transition of a logout/login user switch), the returned
  // `Stream.value([])` below would be CACHED by Riverpod for this family
  // member. The chats tab would then keep showing an empty list even after
  // the correct user signs back in and their chats exist in the local Hive
  // cache — the classic "chats never displayed" symptom when switching
  // accounts on the same device. Listen for auth changes and rebuild this
  // provider the moment the authenticated user becomes [userId] again so
  // the Hive stream, realtime channels and initial sync are (re)established.
  if (supabase.auth.currentUser?.id != userId) {
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (prev, next) {
      if (!ref.mounted) return;
      final currentId = supabase.auth.currentUser?.id;
      if (currentId != userId) return;
      debugPrint(
        '🔑 [recentChatsProvider] Auth user became $userId — rebuilding provider (was built for a different user)',
      );
      ref.invalidateSelf();
    });
    return Stream.value([]);
  }

  // After a user switch on the same device the chatKeyProvider singleton
  // may still hold the previous user's private key (the onAuthStateChange
  // stream is not guaranteed to reach its listener on every platform).
  // Re-initialize it for the currently authenticated user before any
  // sync/decryption work so previews decrypt with the correct key. This
  // also purges the previous user's in-memory decryption caches via the
  // user-change detection inside _init().
  final keyNotifier = ref.read(chatKeyProvider.notifier);
  if (keyNotifier.initializedUserId != userId) {
    debugPrint(
      '🔑 [recentChatsProvider] Key initialized for user=${keyNotifier.initializedUserId} but current user=$userId — re-initializing chat key provider',
    );
    unawaited(() async {
      try {
        await keyNotifier.refresh();
        debugPrint(
          '✅ [recentChatsProvider] Chat key provider refreshed for $userId',
        );
      } catch (e, st) {
        debugPrint('⚠️ [recentChatsProvider] Chat key refresh failed: $e\n$st');
      }
    }());
  }

  // Debug log to verify this provider is being called
  // Watch only the language code from localizationProvider so the provider
  // body re-executes only when the UI language actually changes — not on
  // every state emission (e.g. AppConfig-triggered refreshTranslations()).
  // This avoids recreating the stream unnecessarily, which would cause the
  // first emission to always pass through distinct() and trigger a rebuild.
  final uiLangCode = ref.watch(
    localizationProvider.select((s) => s.currentLocale.languageCode),
  );
  if (kDebugMode) {
    debugPrint(
      '🔍 Recent chats provider called for user $userId, UI=$uiLangCode',
    );
  }
  final localDb = ref.read(localDbProvider);

  String currentUiLang() => normalizeLanguageCode(
    ref.read(localizationProvider).currentLocale.languageCode,
  );
  bool compareChatLists(
    List<Map<String, dynamic>> prev,
    List<Map<String, dynamic>> next,
  ) {
    if (prev.length != next.length) return false;
    for (var i = 0; i < prev.length; i++) {
      final prevChat = prev[i];
      final nextChat = next[i];
      if (prevChat['match_id']?.toString() !=
              nextChat['match_id']?.toString() ||
          prevChat['other_user_id']?.toString() !=
              nextChat['other_user_id']?.toString() ||
          prevChat['other_user_name']?.toString() !=
              nextChat['other_user_name']?.toString() ||
          prevChat['last_message']?.toString() !=
              nextChat['last_message']?.toString() ||
          prevChat['last_message_translated']?.toString() !=
              nextChat['last_message_translated']?.toString() ||
          prevChat['last_message_id']?.toString() !=
              nextChat['last_message_id']?.toString() ||
          prevChat['last_message_sender_id']?.toString() !=
              nextChat['last_message_sender_id']?.toString() ||
          prevChat['last_message_at']?.toString() !=
              nextChat['last_message_at']?.toString() ||
          prevChat['unread_count']?.toString() !=
              nextChat['unread_count']?.toString() ||
          prevChat['event_id']?.toString() !=
              nextChat['event_id']?.toString() ||
          prevChat['event_name']?.toString() !=
              nextChat['event_name']?.toString() ||
          prevChat['event_link']?.toString() !=
              nextChat['event_link']?.toString() ||
          prevChat['translation_enabled']?.toString() !=
              nextChat['translation_enabled']?.toString() ||
          prevChat['translation_language']?.toString() !=
              nextChat['translation_language']?.toString() ||
          prevChat['last_message_source_language']?.toString() !=
              nextChat['last_message_source_language']?.toString() ||
          prevChat['matched_intent']?.toString() !=
              nextChat['matched_intent']?.toString()) {
        return false;
      }
    }
    return true;
  }

  final localStream = localDb.watchChats(userId);

  // Add distinct to prevent duplicate emissions when data hasn't changed
  final distinctStream = localStream.distinct((prev, next) {
    return compareChatLists(prev, next);
  });

  // Add logging for web debugging
  if (kIsWeb) {}

  // Use the correct provider name here
  final syncService = ref.read(globalSyncManagerProvider);

  // Skip network sync and realtime when offline - rely on local cache only
  final isOffline = !offlineCacheManager.isSupabaseAvailable;
  debugPrint(
    '⏱️ [BOOTSTRAP] home_providers isOffline=$isOffline isSupabaseAvailable=${offlineCacheManager.isSupabaseAvailable} forceOnline=${offlineCacheManager.isSupabaseAvailable} shouldSkip=${shouldSkipSupabaseCalls()}',
  );

  // Start listening for incoming location share signals from other users.
  // This is a lightweight Postgres Changes subscription that only fires
  // when another user starts sharing their location with us.
  // startListeningForSignals() is idempotent and stays subscribed across
  // screen off/on, so repeated provider rebuilds are no-ops. Guard with
  // hasSignalChannel to avoid even entering setup (and its logs) when healthy.
  if (!isOffline) {
    try {
      final signalNotifier = ref.read(locationShareProvider.notifier);
      if (!signalNotifier.hasSignalChannel) {
        debugPrint(
          'LocationShare: Starting signal listener from recentChatsProvider',
        );
        signalNotifier.startListeningForSignals();
      }
    } catch (e, st) {
      debugPrint('LocationShare: FAILED to start signal listener: $e');
      debugPrint('LocationShare: Stack trace: $st');
    }
  } else {
    debugPrint('LocationShare: Offline, skipping signal listener');
  }

  // Force initial sync to pick up any server-side changes (e.g. orphaned chat
  // rows that were cleaned up by a migration, or chats whose last message was
  // deleted by the other participant).  Without this the provider would rely
  // solely on the local Hive cache until the next realtime event or periodic
  // sync (up to 60s), which means a deleted chat could linger in the UI.
  // Guarded by _initialSyncKickedAt so rebuilds triggered by watched-provider
  // changes (e.g. localizationProvider) don't re-arm a redundant sync.
  if (!isOffline && _initialSyncKickedAt.add(userId)) {
    Future(() async {
      if (!ref.mounted) return;
      // Wait for the chat key to be initialized FOR THIS USER so the sync
      // can decrypt v1 encrypted last-message previews in a single RPC
      // call. Without this, Android fires syncChatsNow before the key
      // loads, then the chatKeyProvider listener fires a second redundant
      // sync once the key arrives. After a user switch on the same device
      // the provider may briefly hold the previous user's key, so checking
      // "any key present" is not enough. We wait up to 2s; if the key
      // still isn't available (e.g. locked account with no recoverable
      // key), proceed without it — decryption is handled later once the
      // key is (re)initialized.
      bool keyReadyForUser() =>
          ref.read(chatKeyProvider).privateKeyBytes != null &&
          ref.read(chatKeyProvider.notifier).initializedUserId == userId;

      if (!keyReadyForUser()) {
        final completer = Completer<void>();
        late final ProviderSubscription sub;
        var done = false;
        var timedOut = false;
        sub = ref.listen<ChatKeyState>(chatKeyProvider, (prev, next) {
          if (!done && keyReadyForUser()) {
            done = true;
            sub.close();
            if (!completer.isCompleted) completer.complete();
            if (timedOut && ref.mounted) {
              // Key arrived after the 2s window — kick a sync with the
              // now-correct key so previews decrypt right away instead of
              // waiting for the next realtime/periodic sync.
              syncService.syncChatsNow(userId);
            }
          }
        });
        // Check again after listen registration (race condition)
        if (!done && keyReadyForUser()) {
          done = true;
          sub.close();
          if (!completer.isCompleted) completer.complete();
        }
        // Timeout: proceed without the key after 2s, but keep listening so
        // the previews still sync once the key becomes available.
        Timer(const Duration(seconds: 2), () {
          timedOut = true;
          if (!completer.isCompleted) completer.complete();
        });
        await completer.future;
      }
      if (!ref.mounted) return;
      syncService.syncChatsNow(userId);
    });
  }

  // Skip realtime channel setup when offline - it will fail to connect and cause retries
  RealtimeChannel? chatUpdateChannel;
  if (!isOffline) {
    chatUpdateChannel = supabase
        .channel('public:chat_messages:for_user_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chat_messages',
          callback: (payload) async {
            // Capture all provider values before any await to avoid
            // "Ref used after disposed" errors when the provider is
            // rebuilt during async gaps.
            if (!ref.mounted) return;
            final localUiLang = ref
                .read(localizationProvider)
                .currentLocale
                .languageCode;

            // Handle message updates (insert, update, delete) - sync chats to update preview
            if (payload.eventType == PostgresChangeEvent.insert ||
                payload.eventType == PostgresChangeEvent.delete ||
                (payload.eventType == PostgresChangeEvent.update &&
                    (payload.oldRecord['content_original'] !=
                            payload.newRecord['content_original'] ||
                        payload.oldRecord['content_original_encrypted'] !=
                            payload.newRecord['content_original_encrypted'] ||
                        payload.oldRecord['content_translated'] !=
                            payload.newRecord['content_translated'] ||
                        payload.oldRecord['content_translated_encrypted'] !=
                            payload.newRecord['content_translated_encrypted'] ||
                        payload.oldRecord['encryption_scheme'] !=
                            payload.newRecord['encryption_scheme']))) {
              try {
                await Future.delayed(
                  await (() async {
                    try {
                      return await appConfigService.getDuration(
                        'ui.home_refresh_delay_ms',
                        defaultValue: const Duration(milliseconds: 100),
                      );
                    } catch (e) {
                      return const Duration(milliseconds: 100);
                    }
                  })(),
                );
                await syncService.syncChatsNow(userId);
              } catch (e) {
                debugPrint('🔄 Error syncing chats on realtime change: $e');
              }
            }

            if (!ref.mounted) return;

            if (payload.eventType == PostgresChangeEvent.insert ||
                payload.eventType == PostgresChangeEvent.update) {
              final senderId = payload.newRecord['sender_id'];
              final currentUserId = supabase.auth.currentUser?.id;
              final matchId = payload.newRecord['match_id'] as String?;
              final messageId = payload.newRecord['id'] as String?;

              if (currentUserId != null && senderId != currentUserId) {
                final originalContent =
                    payload.newRecord['content_original'] as String?;
                final serverTranslatedContent =
                    payload.newRecord['content_translated'] as String?;
                final serverTranslatedEncrypted =
                    payload.newRecord['content_translated_encrypted']
                        as String?;
                final serverTranslatedNonce =
                    payload.newRecord['content_translated_nonce'] as String?;

                final oldTranslatedContent =
                    payload.oldRecord['content_translated'] as String?;
                final oldTranslatedEncrypted =
                    payload.oldRecord['content_translated_encrypted']
                        as String?;

                final hasEncryptedTranslation =
                    serverTranslatedEncrypted != null &&
                    serverTranslatedEncrypted.isNotEmpty &&
                    serverTranslatedEncrypted != 'null' &&
                    serverTranslatedNonce != null &&
                    serverTranslatedNonce.isNotEmpty;

                final hasAnyTranslation = hasEncryptedTranslation;

                // A translation stored before the message was last edited still
                // decrypts (its AAD binds the target language, not the content),
                // so it can neither be shown nor cached as if it described the
                // current text. An edit is a realtime UPDATE, so this path sees it
                // directly and can tell the two apart.
                final rowEditedAt = normalizeEditMarker(
                  payload.newRecord['edited_at'],
                );
                final translationIsCurrent = translationEditMarkersMatch(
                  normalizeEditMarker(
                    payload.newRecord['translated_source_edited_at'],
                  ),
                  rowEditedAt,
                );
                final hasValidTranslationForContent =
                    hasAnyTranslation && translationIsCurrent;

                final wasTranslatedBefore =
                    (oldTranslatedContent != null &&
                        oldTranslatedContent.isNotEmpty &&
                        oldTranslatedContent != 'null') ||
                    (oldTranslatedEncrypted != null &&
                        oldTranslatedEncrypted.isNotEmpty &&
                        oldTranslatedEncrypted != 'null');

                final isTranslationUpdate =
                    payload.eventType == PostgresChangeEvent.update &&
                    hasAnyTranslation &&
                    !wasTranslatedBefore;

                // Try decrypting encrypted message content for notification preview
                String? decryptedContent;
                String? decryptedTranslation;
                final encryptionScheme =
                    payload.newRecord['encryption_scheme'] as String?;

                if (encryptionScheme == 'v1') {
                  final senderKeyId =
                      payload.newRecord['sender_key_id'] as String?;
                  final recipientKeyId =
                      payload.newRecord['recipient_key_id'] as String?;
                  final wrappedKeys = payload.newRecord['wrapped_keys'];
                  final recipientId =
                      payload.newRecord['recipient_id'] as String?;

                  if (senderKeyId != null &&
                      recipientKeyId != null &&
                      wrappedKeys != null &&
                      messageId != null &&
                      matchId != null) {
                    // Decrypt original if needed
                    if (originalContent == null || originalContent.isEmpty) {
                      final contentEncrypted =
                          payload.newRecord['content_original_encrypted']
                              as String?;
                      final contentNonce =
                          payload.newRecord['content_original_nonce']
                              as String?;
                      if (contentEncrypted != null &&
                          contentEncrypted.isNotEmpty &&
                          contentNonce != null) {
                        decryptedContent =
                            await EncryptedNotificationPreviewService.instance
                                .decryptPreview(
                                  messageId: messageId,
                                  matchId: matchId,
                                  senderId: senderId as String,
                                  recipientId:
                                      recipientId != null &&
                                          recipientId.isNotEmpty
                                      ? recipientId
                                      : currentUserId,
                                  senderKeyId: senderKeyId,
                                  recipientKeyId: recipientKeyId,
                                  contentOriginalEncryptedBase64:
                                      contentEncrypted,
                                  contentOriginalNonceBase64: contentNonce,
                                  wrappedKeysJson: jsonEncode(wrappedKeys),
                                );
                      }
                    }

                    // Decrypt translation if available
                    if (hasEncryptedTranslation) {
                      final detLang =
                          payload.newRecord['detected_source_language']
                              as String?;
                      final tgtLang =
                          payload.newRecord['translated_target_language']
                              as String?;
                      decryptedTranslation =
                          await EncryptedNotificationPreviewService.instance
                              .decryptPreview(
                                messageId: messageId,
                                matchId: matchId,
                                senderId: senderId as String,
                                recipientId:
                                    recipientId != null &&
                                        recipientId.isNotEmpty
                                    ? recipientId
                                    : currentUserId,
                                senderKeyId: senderKeyId,
                                recipientKeyId: recipientKeyId,
                                contentOriginalEncryptedBase64:
                                    serverTranslatedEncrypted,
                                contentOriginalNonceBase64:
                                    serverTranslatedNonce,
                                wrappedKeysJson: jsonEncode(wrappedKeys),
                                detectedSourceLanguage: detLang,
                                targetLanguage: tgtLang,
                              );
                    }
                  }
                }

                final usableContent =
                    (originalContent != null && originalContent.isNotEmpty) ||
                    (decryptedContent != null);

                if ((usableContent ||
                        hasAnyTranslation ||
                        encryptionScheme == 'v1') &&
                    messageId != null &&
                    matchId != null) {
                  if (_notifiedMessageIds.contains(messageId)) {
                    if (isTranslationUpdate) {
                      _pendingTranslatedNotificationMessageIds.remove(
                        messageId,
                      );
                      _pendingTranslationTimeoutTimers
                          .remove(messageId)
                          ?.cancel();
                    }
                    return;
                  }

                  // Skip notifications for messages already in local DB.
                  // On cold start the realtime subscription reconnects and
                  // replays INSERT events for every old message – without
                  // this guard every replayed message triggers a spurious
                  // notification.
                  if (payload.eventType == PostgresChangeEvent.insert) {
                    final alreadyExists = await localDb.getMessageById(
                      matchId,
                      messageId,
                    );
                    if (alreadyExists != null) {
                      _notifiedMessageIds.add(messageId);
                      _pendingTranslatedNotificationMessageIds.remove(
                        messageId,
                      );
                      _pendingTranslationTimeoutTimers
                          .remove(messageId)
                          ?.cancel();
                      return;
                    }
                  }

                  // ... (rest of DB saving logic) ...
                  try {
                    if (payload.eventType == PostgresChangeEvent.insert) {
                      final messagesToDeliver = await localDb.addMessages(
                        matchId,
                        [payload.newRecord],
                        currentUserId: currentUserId,
                      );
                      if (messagesToDeliver.isNotEmpty) {
                        unawaited(
                          Future.wait(
                            messagesToDeliver.map(
                              (msgId) => supabase
                                  .rpc(
                                    'mark_message_delivered',
                                    params: {'p_message_id': msgId},
                                  )
                                  .catchError((e) {
                                    debugPrint(
                                      '❌ home_providers: Failed to mark $msgId as delivered: $e',
                                    );
                                  }),
                            ),
                            eagerError: false,
                          ),
                        );
                      }
                    }
                  } catch (e) {
                    debugPrint('❌ Failed to save message to local DB: $e');
                  }

                  // Preview fast path: don't wait for the next syncChatsNow
                  // (+cooldowns) to show the new last message in Recent Chats.
                  // Decrypts + recomputes the preview off the realtime payload
                  // and single-flights the translation when needed.
                  // Fire-and-forget; syncChatsNow remains the backstop.
                  // (matchId/messageId/currentUserId are null-guarded above.)
                  if (payload.eventType == PostgresChangeEvent.insert) {
                    unawaited(
                      _refreshPreviewForIncomingRealtimeMessage(
                        localDb: localDb,
                        currentUserId: currentUserId,
                        matchId: matchId,
                        messageId: messageId,
                        newRecord: payload.newRecord,
                        uiLang: normalizeLanguageCode(localUiLang),
                      ),
                    );
                  }

                  if (payload.eventType == PostgresChangeEvent.insert) {
                    _sessionAddedMessageIds.add(messageId);
                  }

                  bool isTranslationEnabled = false;
                  try {
                    isTranslationEnabled = await localDb.isTranslationEnabled(
                      matchId,
                      userId: currentUserId,
                    );
                  } catch (e) {
                    debugPrint('Failed to check translation status: $e');
                  }

                  // For INSERT events with translation enabled, ALWAYS wait for the
                  // translation UPDATE before showing notification. This ensures the
                  // local browser notification (when UI is open) shows translated text,
                  // matching the behavior of FCM notifications (when UI is closed).
                  //
                  // Previously, we only waited if detectedSource != uiLang, which meant
                  // notifications sometimes showed original text when translate-proxy
                  // hadn't completed yet.
                  if (payload.eventType == PostgresChangeEvent.insert &&
                      isTranslationEnabled) {
                    // Always defer notification when translation is enabled
                    debugPrint(
                      '🔔 [NOTIFY] INSERT event with translation enabled - deferring notification until translation arrives',
                    );
                    _pendingTranslatedNotificationMessageIds.add(messageId);
                    _schedulePendingTranslationTimeout(messageId);
                    return;
                  }

                  if (payload.eventType == PostgresChangeEvent.update) {
                    // Skip replayed translation updates for messages that were
                    // never added to local DB during this session (cold-start
                    // realtime replay).
                    if (!_sessionAddedMessageIds.contains(messageId)) {
                      final alreadyExists = await localDb.getMessageById(
                        matchId,
                        messageId,
                      );
                      if (alreadyExists != null) {
                        _notifiedMessageIds.add(messageId);
                        _pendingTranslatedNotificationMessageIds.remove(
                          messageId,
                        );
                        _pendingTranslationTimeoutTimers
                            .remove(messageId)
                            ?.cancel();
                        return;
                      }
                    }

                    final isPendingTranslation =
                        _pendingTranslatedNotificationMessageIds.contains(
                          messageId,
                        );
                    // Fire if: pending + translation available, OR
                    //          not pending (timeout fired, show with available content)
                    final shouldNotifyTranslationUpdate =
                        hasAnyTranslation ||
                        decryptedTranslation != null ||
                        !isPendingTranslation;
                    if (!shouldNotifyTranslationUpdate) {
                      return;
                    }
                    // Remove from pending set when notification fires
                    _pendingTranslatedNotificationMessageIds.remove(messageId);
                  }

                  final sourceLanguage =
                      payload.newRecord['detected_source_language'] as String?;
                  final translatedText =
                      serverTranslatedContent ?? decryptedTranslation;
                  final bool hasValidTranslation =
                      translatedText != null &&
                      translatedText.isNotEmpty &&
                      translatedText != 'null';

                  String? displayContent;
                  if (isTranslationEnabled &&
                      sourceLanguage != null &&
                      sourceLanguage.isNotEmpty) {
                    final sourceLang = normalizeLanguageCode(sourceLanguage);
                    final uiLang = normalizeLanguageCode(localUiLang);
                    if (sourceLang == uiLang) {
                      // Source matches UI → show original
                      displayContent = decryptedContent ?? originalContent;
                    } else {
                      // Source differs from UI → translation required
                      displayContent = hasValidTranslation
                          ? translatedText
                          : null;
                    }
                  } else if (isTranslationEnabled) {
                    // No source language info → show translation if available, else original
                    displayContent = hasValidTranslation
                        ? translatedText
                        : (decryptedContent ?? originalContent);
                  } else {
                    // Translation disabled → show original
                    displayContent = decryptedContent ?? originalContent;
                  }

                  String trunc(String? s) => s == null
                      ? 'null'
                      : s.length > 20
                      ? '${s.substring(0, 20)}...'
                      : s;
                  debugPrint('🔔 [DEBUG] Notification content selection:');
                  debugPrint('  - isTranslationEnabled: $isTranslationEnabled');
                  debugPrint('  - sourceLanguage: $sourceLanguage');
                  debugPrint('  - hasValidTranslation: $hasValidTranslation');
                  debugPrint('  - translatedText: ${trunc(translatedText)}');
                  debugPrint(
                    '  - decryptedContent: ${trunc(decryptedContent)}',
                  );
                  debugPrint('  - originalContent: ${trunc(originalContent)}');
                  debugPrint('  - displayContent: ${trunc(displayContent)}');

                  // Update the chat preview immediately so the Recent Chats list
                  // shows the translated message at the same time as the
                  // notification. Stamped with the target language and the
                  // content version so the cached preview is only reused while it
                  // still describes the message as it stands.
                  //
                  // When the server says this translation predates the current
                  // content, the preview is cleared rather than written: an edit
                  // keeps the message id, so caching the pre-edit text here is
                  // exactly what left the Recent Chats row stale after the open
                  // chat had already been retranslated.
                  if (hasValidTranslation) {
                    if (hasValidTranslationForContent) {
                      unawaited(
                        localDb.updateChatLastMessageTranslation(
                          currentUserId,
                          matchId,
                          messageId,
                          translatedText,
                          targetLanguage: normalizeLanguageCode(
                            payload.newRecord['translated_target_language']
                                    as String? ??
                                localUiLang,
                          ),
                          editedAt: rowEditedAt,
                        ),
                      );
                    } else if (rowEditedAt != null) {
                      unawaited(
                        localDb.updateChatLastMessageTranslation(
                          currentUserId,
                          matchId,
                          messageId,
                          null,
                        ),
                      );
                    }
                  }

                  if (displayContent == null || displayContent.isEmpty) {
                    debugPrint(
                      '🔔 [NOTIFY] Skipping notification for $messageId - no decrypted content available (sync fallback will handle it)',
                    );
                    return;
                  }

                  final senderName = await _resolveChatNotificationSenderName(
                    localDb: localDb,
                    currentUserId: currentUserId,
                    matchId: matchId,
                    senderId: senderId,
                  );

                  final now = DateTime.now();
                  final timestamp =
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${(now.millisecond ~/ 10).toString().padLeft(2, '0')}';
                  debugPrint(
                    '🔔 [NOTIFY] $timestamp | Chat=$matchId | From=$senderName | MessageId=$messageId | Translation=${isTranslationEnabled ? "YES" : "NO"}',
                  );

                  if (kIsWeb) {
                    final webTime = DateTime.now();
                    final webTimestamp =
                        '${webTime.hour.toString().padLeft(2, '0')}:${webTime.minute.toString().padLeft(2, '0')}:${webTime.second.toString().padLeft(2, '0')}.${(webTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint(
                      '🔔 [WEB_NOTIFY] $webTimestamp | Browser notification',
                    );
                    WebNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  } else if (Platform.isAndroid) {
                    final androidTime = DateTime.now();
                    final androidTimestamp =
                        '${androidTime.hour.toString().padLeft(2, '0')}:${androidTime.minute.toString().padLeft(2, '0')}:${androidTime.second.toString().padLeft(2, '0')}.${(androidTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint(
                      '🔔 [ANDROID_NOTIFY] $androidTimestamp | Background service',
                    );
                    // On Android, trigger the background service to check for notifications immediately
                    // Use translated content for notification if translation is enabled
                    Future.delayed(const Duration(milliseconds: 200), () {
                      BackgroundService.triggerNotificationCheck(
                        messageId: messageId,
                        translatedContent: displayContent,
                        originalContent: originalContent,
                        senderName: senderName,
                        matchId: matchId,
                      );
                    });
                  } else if (Platform.isIOS) {
                    // On iOS, use iOS notification service
                    final iosTime = DateTime.now();
                    final iosTimestamp =
                        '${iosTime.hour.toString().padLeft(2, '0')}:${iosTime.minute.toString().padLeft(2, '0')}:${iosTime.second.toString().padLeft(2, '0')}.${(iosTime.millisecond ~/ 10).toString().padLeft(2, '0')}';
                    debugPrint(
                      '🔔 [IOS_NOTIFY] $iosTimestamp | Local notification',
                    );
                    await MobileLocalNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  }
                  _notifiedMessageIds.add(messageId);
                  _pendingTranslatedNotificationMessageIds.remove(messageId);
                  _pendingTranslationTimeoutTimers.remove(messageId)?.cancel();
                }
              }
            }

            // All INSERT/UPDATE/DELETE events are synced above
          },
        );
  }

  // Defer the subscribe() call past the first frame to avoid blocking UI
  // during cold start. Reduced from 4000ms to 200ms to provide near-instant
  // message delivery while still preventing frame drops during initialization.
  // The 200ms delay is sufficient to let ChatKeyProvider complete without
  // causing noticeable message delays.
  if (!isOffline && chatUpdateChannel != null) {
    (() async {
      final initialDelay = await (() async {
        try {
          return await appConfigService.getDuration(
            'ui.home_initial_delay_ms',
            defaultValue: const Duration(milliseconds: 200),
          );
        } catch (e) {
          return const Duration(milliseconds: 200);
        }
      })();
      Future<void>.delayed(initialDelay, () {
        if (!ref.mounted) return;
        chatUpdateChannel!.subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('✅ Chat messages subscription active');
            chatMessagesReconnectAttempts =
                0; // Reset counter on successful connection
            _lastChannelSubscribedAt['chat_messages_$userId'] = DateTime.now();
          } else if (status == RealtimeSubscribeStatus.closed ||
              status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) {
            if (err != null && !isExpectedOfflineFailure(err)) {
              debugPrint(
                '⚠️ Chat messages subscription disconnected - status: $status, error: $err',
              );
            }

            // If a network/WebSocket error caused the disconnect, force offline to prevent reconnection loops
            if (err != null &&
                (isExpectedOfflineFailure(err) ||
                    err.toString().toLowerCase().contains('closeevent'))) {
              offlineCacheManager.setSupabaseAvailability(false, force: true);
              debugPrint(
                '⏸️ [REALTIME] Network/WebSocket disconnect detected, forcing offline',
              );
              return;
            }

            // Prevent reconnect loop if app is in background
            if (WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.paused ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.detached) {
              debugPrint('⏸️ App in background, skipping auto-reconnect');
              return;
            }

            // Skip reconnection if Supabase communication is paused (offline mode)
            // Use debugPrint to suppress repeated log spam during rebuilds
            if (shouldSkipSupabaseCalls()) {
              debugPrint(
                '⏸️ Supabase communication paused, skipping chat messages reconnection',
              );
              return;
            }

            // Limit reconnection attempts to prevent infinite loops
            if (chatMessagesReconnectAttempts >= maxReconnectAttempts) {
              debugPrint(
                '🔄 Chat messages reconnection attempts exhausted ($maxReconnectAttempts), stopping auto-reconnect',
              );
              return;
            }

            // Cold-start guard: if this channel was subscribed less than 30s ago,
            // the close is likely a WebSocket reconnect cycle (cold-start
            // close-storm), not a real disconnect. Skip recovery to avoid
            // redundant syncChatsNow calls during startup. On web the close-storm
            // can last 5-10s; on Android it can be faster but repeat. 30s covers
            // both platforms.
            final lastSubscribed =
                _lastChannelSubscribedAt['chat_messages_$userId'];
            if (lastSubscribed != null &&
                DateTime.now().difference(lastSubscribed) <
                    const Duration(seconds: 30)) {
              debugPrint(
                '⏸️ Chat messages reconnection skipped: cold-start close-storm (subscribed ${DateTime.now().difference(lastSubscribed).inMilliseconds}ms ago)',
              );
              return;
            }

            // Coalesce close-storms: the realtime websocket commonly cycles
            // through 2-3 close/subscribed transitions in the first few
            // seconds of a cold start (one per table we subscribe to). Without
            // this, each transition would schedule its own syncChatsNow and
            // the UI would see three redundant round-trips. We keep the
            // log + counter increment so the operator still sees that a
            // close happened, but only fire the heavy recovery RPC once
            // per 8 s window.
            final recoveryWindow = _lastRealtimeRecoveryAt[userId];
            if (recoveryWindow != null &&
                DateTime.now().difference(recoveryWindow) <
                    const Duration(seconds: 8)) {
              debugPrint(
                '⏸️ Chat messages reconnection skipped: recovery already in flight',
              );
              return;
            }
            _lastRealtimeRecoveryAt[userId] = DateTime.now();

            // Skip if provider was disposed during the close event processing
            if (!ref.mounted) return;

            chatMessagesReconnectAttempts++;
            final delay = _jitteredBackoff(chatMessagesReconnectAttempts);
            debugPrint(
              '🔄 Attempting to reconnect chat messages subscription (attempt $chatMessagesReconnectAttempts/$maxReconnectAttempts, delay=${delay.inMilliseconds}ms)...',
            );

            Future.delayed(delay, () async {
              if (!ref.mounted) return;
              try {
                await syncService.syncChatsNow(userId);
              } catch (e) {
                debugPrint(
                  '🔄 Reconnect recovery for chat messages failed: $e',
                );
              }
            });
          }
        });
      });
    })();
  }

  // Subscribe to matches table changes for real-time match deletions (skip when offline)
  RealtimeChannel? matchUpdateChannel;
  if (!isOffline) {
    matchUpdateChannel = supabase
        .channel('public:matches:for_user_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'matches',
          callback: (payload) async {
            debugPrint(
              'Realtime: Match ${payload.eventType} detected: ${payload.newRecord}',
            );
            // Ignore callbacks if provider has been disposed
            if (!ref.mounted) return;
            // When matches change, sync chats and matches to reflect any deletions
            try {
              await syncService.syncChatsNow(userId);
              await syncService.syncMatchesNow(userId);
            } catch (e) {
              debugPrint('Error syncing on match realtime update: $e');
            }
          },
        );
  }

  // Defer subscribe to past first frame (reduced to 200ms for near-instant updates)
  if (!isOffline && matchUpdateChannel != null) {
    (() async {
      final initialDelay = await (() async {
        try {
          return await appConfigService.getDuration(
            'ui.home_initial_delay_ms',
            defaultValue: const Duration(milliseconds: 200),
          );
        } catch (e) {
          return const Duration(milliseconds: 200);
        }
      })();
      Future<void>.delayed(initialDelay, () {
        if (!ref.mounted) return;
        matchUpdateChannel!.subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('✅ Matches subscription active');
            matchesReconnectAttempts =
                0; // Reset counter on successful connection
            _lastChannelSubscribedAt['matches_$userId'] = DateTime.now();
          } else if (status == RealtimeSubscribeStatus.closed ||
              status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) {
            if (err != null && !isExpectedOfflineFailure(err)) {
              debugPrint(
                '⚠️ Matches subscription disconnected - status: $status, error: $err',
              );
            }

            // If a network/WebSocket error caused the disconnect, force offline to prevent reconnection loops
            if (err != null &&
                (isExpectedOfflineFailure(err) ||
                    err.toString().toLowerCase().contains('closeevent'))) {
              offlineCacheManager.setSupabaseAvailability(false, force: true);
              debugPrint(
                '⏸️ [REALTIME] Network/WebSocket disconnect detected, forcing offline',
              );
              return;
            }

            // Prevent reconnect loop if app is in background
            if (WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.paused ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.detached) {
              debugPrint('⏸️ App in background, skipping auto-reconnect');
              return;
            }

            // Skip reconnection if Supabase communication is paused (offline mode)
            // Use debugPrint to suppress repeated log spam during rebuilds
            if (shouldSkipSupabaseCalls()) {
              debugPrint(
                '⏸️ Supabase communication paused, skipping matches reconnection',
              );
              return;
            }

            // Limit reconnection attempts to prevent infinite loops
            if (matchesReconnectAttempts >= maxReconnectAttempts) {
              debugPrint(
                '🔄 Matches reconnection attempts exhausted ($maxReconnectAttempts), stopping auto-reconnect',
              );
              return;
            }

            // Cold-start guard: see comment in chat-messages handler (30s window).
            final lastSubscribed = _lastChannelSubscribedAt['matches_$userId'];
            if (lastSubscribed != null &&
                DateTime.now().difference(lastSubscribed) <
                    const Duration(seconds: 30)) {
              debugPrint(
                '⏸️ Matches reconnection skipped: cold-start close-storm (subscribed ${DateTime.now().difference(lastSubscribed).inMilliseconds}ms ago)',
              );
              return;
            }

            // Coalesce close-storms: see comment in chat-messages handler.
            final recoveryWindow = _lastRealtimeRecoveryAt[userId];
            if (recoveryWindow != null &&
                DateTime.now().difference(recoveryWindow) <
                    const Duration(seconds: 8)) {
              debugPrint(
                '⏸️ Matches reconnection skipped: recovery already in flight',
              );
              return;
            }
            _lastRealtimeRecoveryAt[userId] = DateTime.now();

            // Skip if provider was disposed during the close event processing
            if (!ref.mounted) return;

            matchesReconnectAttempts++;
            final delay = _jitteredBackoff(matchesReconnectAttempts);
            debugPrint(
              '🔄 Attempting to reconnect matches subscription (attempt $matchesReconnectAttempts/$maxReconnectAttempts, delay=${delay.inMilliseconds}ms)...',
            );

            Future.delayed(delay, () async {
              if (!ref.mounted) return;
              try {
                await syncService.syncChatsNow(userId);
                await syncService.syncMatchesNow(userId);
              } catch (e) {
                debugPrint('🔄 Reconnect recovery for matches failed: $e');
              }
            });
          }
        });
      });
    })();
  }

  // Subscribe to chats table changes for real-time chat deletions AND
  // translation-toggle sync. The translation columns on `public.chats`
  // (`translation_enabled`, `translation_language`) are a per-user per-match
  // chat option — they should propagate to every device the user is logged
  // in on, not just the device that flipped the toggle. The DELETE handler
  // also still fires from this channel.
  //
  // Both listeners are filtered server-side to `user_id = <currentUser>`.
  // The RLS SELECT policy on public.chats (see
  // 20260108000001_enable_rls_on_chats_with_policies.sql) allows BOTH
  // participants of a match to read the row, so without this filter a
  // user would also receive the other participant's chat-row events and
  // overwrite their own per-user translation state with the other user's.
  RealtimeChannel? chatsUpdateChannel;
  if (!isOffline) {
    chatsUpdateChannel = supabase
        .channel('public:chats:for_user_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) async {
            // Ignore callbacks if provider has been disposed
            if (!ref.mounted) return;
            try {
              final localDb = ref.read(localDbProvider);
              // Immediately remove the chat from local storage so the UI
              // updates right away, without waiting for the RPC round-trip.
              final matchId = payload.oldRecord['match_id'] as String?;
              if (matchId != null && matchId.isNotEmpty) {
                await localDb.deleteChat(matchId, userId: userId);
              }
              // Force a server sync to ensure consistency, bypassing the 5s
              // cooldown that could otherwise block the refresh (e.g. if a
              // message was sent seconds before the deletion).
              await syncService.syncChatsNow(userId, force: true);
            } catch (e) {
              debugPrint('Error syncing on chat deletion: $e');
            }
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chats',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) async {
            if (!ref.mounted) return;
            // Only react to translation-column changes. Other column updates
            // (last_message_*, unread_count, etc.) are reconciled by the
            // chat_messages subscription and periodic syncChatsNow pulls.
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            if (newRecord == null) return;

            final matchId = newRecord['match_id'] as String?;
            if (matchId == null || matchId.isEmpty) return;

            final newEnabled = newRecord['translation_enabled'] == true;
            final newLanguage = newRecord['translation_language'] as String?;
            // Compare the incoming state with the current in-memory state
            // (not with payload.oldRecord). REPLICA IDENTITY on public.chats
            // may be DEFAULT on some installations, in which case oldRecord
            // only contains the composite PK and a column-by-column old/new
            // comparison would silently no-op the "disable translation" case
            // (new=(false, null) vs old=(false, null)). The server is the
            // source of truth, so the new value is always correct; comparing
            // to local state is enough to skip the echo of our own write.
            final newTarget = (newEnabled && newLanguage != null)
                ? newLanguage
                : null;
            final currentState = ref.read(translationProvider);
            if (currentState[matchId] == newTarget) {
              return;
            }

            try {
              final localDb = ref.read(localDbProvider);

              // 1) Update the Hive chats cache so subsequent reads (e.g.
              //    recentChatsProvider) reflect the new toggle state.
              await localDb.syncChatTranslationSettings(
                userId,
                matchId,
                newEnabled,
                newLanguage,
              );

              // 2) Apply the new state through `applyRemoteTranslationUpdate`
              //    so the chat screen's AppBar icon (ref.watch on the
              //    translationProvider) and per-message translations
              //    (translationFamilyProvider, which depends on
              //    translationVersionProvider) both refresh in real time
              //    when the user is already inside the chat. The previous
              //    silent-setter path only mutated the in-memory map and
              //    did not bump the version, so the on-screen UI did not
              //    update until the chat was exited and re-entered.
              await ref
                  .read(translationProvider.notifier)
                  .applyRemoteTranslationUpdate(matchId, newTarget);
            } catch (e) {
              debugPrint(
                'Error syncing chat translation update from realtime: $e',
              );
            }
          },
        );
  }

  // Defer subscribe to past first frame (reduced to 200ms for near-instant updates)
  if (!isOffline && chatsUpdateChannel != null) {
    (() async {
      final initialDelay = await (() async {
        try {
          return await appConfigService.getDuration(
            'ui.home_initial_delay_ms',
            defaultValue: const Duration(milliseconds: 200),
          );
        } catch (e) {
          return const Duration(milliseconds: 200);
        }
      })();
      Future<void>.delayed(initialDelay, () {
        if (!ref.mounted) return;
        chatsUpdateChannel!.subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('✅ Chats subscription active');
            chatsReconnectAttempts =
                0; // Reset counter on successful connection
            final now = DateTime.now();
            final prevSubscribed = _lastChannelSubscribedAt['chats_$userId'];
            _lastChannelSubscribedAt['chats_$userId'] = now;
            // Cold-start guard: if this channel was subscribed very recently,
            // we're in a close-storm reconnection cycle. The initial sync
            // (_initialSyncKickedAt) already handles startup data sync, so
            // skip redundant syncChatsNow calls from re-subscriptions.
            // Uses 30s window to cover both web (5-10s close-storm) and
            // Android (faster reconnection cycles).
            if (prevSubscribed != null &&
                now.difference(prevSubscribed) < const Duration(seconds: 30)) {
              debugPrint(
                '⏸️ Chats re-subscribed during cold start (${now.difference(prevSubscribed).inMilliseconds}ms since last), skipping sync',
              );
            } else if (_lastRealtimeRecoveryAt[userId] != null &&
                now.difference(_lastRealtimeRecoveryAt[userId]!) <
                    const Duration(seconds: 8)) {
              // Another channel's recovery handler already triggered syncChatsNow
              // during this recovery window — skip to avoid redundant round-trips.
              debugPrint(
                '⏸️ Chats subscribe: recovery sync already in flight, skipping',
              );
            } else {
              // Sync on subscribe to catch any missed deletions and ensure
              // local storage is aligned with the server state. Use non-force
              // so the debounce/cooldown can merge this with other pending syncs
              // (e.g. the initial sync kicked off by _initialSyncKickedAt).
              unawaited(syncService.syncChatsNow(userId));
            }
          } else if (status == RealtimeSubscribeStatus.closed ||
              status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) {
            if (err != null && !isExpectedOfflineFailure(err)) {
              debugPrint(
                '⚠️ Chats subscription disconnected - status: $status, error: $err',
              );
            }

            // If a network/WebSocket error caused the disconnect, force offline to prevent reconnection loops
            if (err != null &&
                (isExpectedOfflineFailure(err) ||
                    err.toString().toLowerCase().contains('closeevent'))) {
              offlineCacheManager.setSupabaseAvailability(false, force: true);
              debugPrint(
                '⏸️ [REALTIME] Network/WebSocket disconnect detected, forcing offline',
              );
              return;
            }

            // Prevent reconnect loop if app is in background
            if (WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.paused ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.detached) {
              debugPrint('⏸️ App in background, skipping auto-reconnect');
              return;
            }

            // Skip reconnection if Supabase communication is paused (offline mode)
            // Use debugPrint to suppress repeated log spam during rebuilds
            if (shouldSkipSupabaseCalls()) {
              debugPrint(
                '⏸️ Supabase communication paused, skipping chats reconnection',
              );
              return;
            }

            // Limit reconnection attempts to prevent infinite loops
            if (chatsReconnectAttempts >= maxReconnectAttempts) {
              debugPrint(
                '🔄 Chats reconnection attempts exhausted ($maxReconnectAttempts), stopping auto-reconnect',
              );
              return;
            }

            // Cold-start guard: see comment in chat-messages handler (30s window).
            final lastSubscribed = _lastChannelSubscribedAt['chats_$userId'];
            if (lastSubscribed != null &&
                DateTime.now().difference(lastSubscribed) <
                    const Duration(seconds: 30)) {
              debugPrint(
                '⏸️ Chats reconnection skipped: cold-start close-storm (subscribed ${DateTime.now().difference(lastSubscribed).inMilliseconds}ms ago)',
              );
              return;
            }

            // Coalesce close-storms: see comment in chat-messages handler.
            final recoveryWindow = _lastRealtimeRecoveryAt[userId];
            if (recoveryWindow != null &&
                DateTime.now().difference(recoveryWindow) <
                    const Duration(seconds: 8)) {
              debugPrint(
                '⏸️ Chats reconnection skipped: recovery already in flight',
              );
              return;
            }
            _lastRealtimeRecoveryAt[userId] = DateTime.now();

            // Skip if provider was disposed during the close event processing
            if (!ref.mounted) return;

            chatsReconnectAttempts++;
            final delay = _jitteredBackoff(chatsReconnectAttempts);
            debugPrint(
              '🔄 Attempting to reconnect chats subscription (attempt $chatsReconnectAttempts/$maxReconnectAttempts, delay=${delay.inMilliseconds}ms)...',
            );

            Future.delayed(delay, () async {
              if (!ref.mounted) return;
              try {
                await syncService.syncChatsNow(userId);
              } catch (e) {
                debugPrint('🔄 Reconnect recovery for chats failed: $e');
              }
            });
          }
        });
      });
    })();
  }

  ref.onDispose(() {
    if (chatUpdateChannel != null) supabase.removeChannel(chatUpdateChannel);
    if (matchUpdateChannel != null) supabase.removeChannel(matchUpdateChannel);
    if (chatsUpdateChannel != null) supabase.removeChannel(chatsUpdateChannel);
  });

  // When the chat key becomes available (first load or unlock), re-sync
  // chats so that encrypted last-message previews get decrypted.
  ref.listen<ChatKeyState>(chatKeyProvider, (prev, next) {
    if (!ref.mounted) return;
    if (prev?.privateKeyBytes == null && next.privateKeyBytes != null) {
      // Skip if the initial sync already ran (it now waits for the key
      // before calling syncChatsNow, so decryption is already handled).
      // Without this guard, both _initialSyncKickedAt AND this listener
      // fire syncChatsNow, causing a redundant second RPC on Android.
      if (_initialSyncKickedAt.contains(userId)) return;
      syncService.syncChatsNow(userId);
    }
  });

  /// One-shot forced `syncChatsNow` so a translated preview that is merely slow
  /// to arrive shows up in seconds rather than after the next periodic sync.
  void schedulePreviewTranslationRefresh({
    required String messageId,
    required String targetLanguage,
  }) {
    final key = '$userId|$messageId|$targetLanguage';
    if (!_previewRefreshInFlight.add(key)) return;
    Timer(_previewTranslationRefreshDelay, () {
      _previewRefreshInFlight.remove(key);
      if (ref.mounted) {
        unawaited(syncService.syncChatsNow(userId, force: true));
      }
    });
  }

  // Handle translation display for Recent Chats and detect new messages via sync
  return distinctStream.asyncMap((list) async {
    final uiLang = currentUiLang();
    final cacheKey = '$userId|$uiLang';
    try {
      // Cache guard: if the stream was re-created (provider body re-executed
      // due to localizationProvider emitting without a locale change) and the
      // incoming data is semantically identical to the last processed input,
      // return the previously computed result to avoid a visual refresh.
      final lastInput = _recentChatsProcessedInput[cacheKey];
      if (lastInput != null && compareChatLists(lastInput, list)) {
        return _recentChatsProcessedResult[cacheKey] ?? [];
      }

      debugPrint(
        '🔄 Recent Chats Provider: Processing ${list.length} chats from local DB (data changed)',
      );

      for (final json in list) {
        final matchId = json['match_id']?.toString();
        if (matchId != null && matchId.isNotEmpty) {
          final snapshotKey = '$userId|$matchId';
          final existingChat = _recentChatSnapshots[snapshotKey];
          if (existingChat != null) {
            continue;
          }
          try {
            final chat = ChatModel.fromJsonRpc(json);
            _recentChatSnapshots[snapshotKey] = chat;
          } catch (e) {
            debugPrint(
              'Recent chats snapshot parse failed for $snapshotKey: $e',
            );
          }
        }
      }

      // Defensive filter: skip chats with missing match_id or last_message_id
      // to prevent phantom entries when a match has been deleted while offline
      // or when all messages were deleted (orphaned chat rows). A chat row is
      // only created by a trigger on message insert, so a missing last_message_id
      // means all messages were deleted and the row should not exist.
      final invalidChats = <int>[];
      final validList = <Map<String, dynamic>>[];
      for (int i = 0; i < list.length; i++) {
        final json = list[i];
        final mid = json['match_id']?.toString();
        final oid = json['other_user_id']?.toString();
        final lid = json['last_message_id']?.toString();
        if (mid != null &&
            mid.isNotEmpty &&
            oid != null &&
            oid.isNotEmpty &&
            lid != null &&
            lid.isNotEmpty) {
          validList.add(json);
        } else {
          invalidChats.add(i);
        }
      }
      // Clean up any invalid phantom chats from local cache immediately
      if (invalidChats.isNotEmpty) {
        debugPrint(
          '🧹 Recent Chats: Found ${invalidChats.length} invalid chat(s) — cleaning up',
        );
        try {
          for (final idx in invalidChats) {
            final badMid = list[idx]['match_id']?.toString();
            if (badMid != null && badMid.isNotEmpty) {
              await localDb.deleteChat(badMid, userId: userId);
            }
          }
        } catch (_) {}
      }

      final chats = await Future.wait(
        validList.map((json) async {
          try {
            final chat = ChatModel.fromJsonRpc(json);
            final matchId = json['match_id']?.toString();
            final unreadRaw = json['unread_count'];
            final unreadCount = unreadRaw is int
                ? unreadRaw
                : int.tryParse(unreadRaw?.toString() ?? '') ?? 0;
            final lastMessageSenderId = json['last_message_sender_id']
                ?.toString();

            debugPrint(
              '🔄 Recent Chats Provider: Chat $matchId - unreadCount: $unreadCount',
            );

            // Skip notifications for own messages
            if (lastMessageSenderId == userId && matchId != null) {
              debugPrint(
                '🔄 [SYNC FALLBACK] Skipping notification for own message',
              );
              _previousChatUnreadCounts[matchId] = unreadCount;
              // Continue to next chat without triggering notification
            } else if (matchId != null &&
                lastMessageSenderId != null &&
                unreadCount > 0) {
              final previousUnread = _previousChatUnreadCounts[matchId] ?? 0;

              final lastMessageId = json['last_message_id'] as String?;
              final translationEnabled = json['translation_enabled'] == true;
              final encryptionScheme =
                  json['last_message_encryption_scheme'] as String?;

              final serverTranslatedContent =
                  json['last_message_translated'] as String?;
              final serverTranslatedEncrypted =
                  json['last_message_content_translated_encrypted'] as String?;
              final serverTranslatedNonce =
                  json['last_message_content_translated_nonce'] as String?;
              final targetLang =
                  json['last_message_target_language'] as String?;

              final hasEncryptedTranslation =
                  serverTranslatedEncrypted != null &&
                  serverTranslatedEncrypted.isNotEmpty &&
                  serverTranslatedEncrypted != 'null' &&
                  serverTranslatedNonce != null &&
                  serverTranslatedNonce.isNotEmpty &&
                  targetLang != null &&
                  normalizeLanguageCode(targetLang) == uiLang;

              String? decryptedContent;
              String? decryptedTranslation;

              if (encryptionScheme == 'v1' && lastMessageId != null) {
                final senderKeyId =
                    json['last_message_sender_key_id'] as String?;
                final recipientKeyId =
                    json['last_message_recipient_key_id'] as String?;
                final wrappedKeys = json['last_message_wrapped_keys'];

                if (senderKeyId != null &&
                    recipientKeyId != null &&
                    wrappedKeys != null) {
                  // Decrypt original if needed
                  final contentEncrypted =
                      json['last_message_content_original_encrypted']
                          as String?;
                  final contentNonce =
                      json['last_message_content_original_nonce'] as String?;
                  if (contentEncrypted != null && contentNonce != null) {
                    decryptedContent = await EncryptedNotificationPreviewService
                        .instance
                        .decryptPreview(
                          messageId: lastMessageId,
                          matchId: matchId,
                          senderId: lastMessageSenderId,
                          recipientId: userId,
                          senderKeyId: senderKeyId,
                          recipientKeyId: recipientKeyId,
                          contentOriginalEncryptedBase64: contentEncrypted,
                          contentOriginalNonceBase64: contentNonce,
                          wrappedKeysJson: jsonEncode(wrappedKeys),
                        );
                  }

                  // Decrypt translation if available and matches UI lang
                  if (hasEncryptedTranslation) {
                    decryptedTranslation =
                        await EncryptedNotificationPreviewService.instance
                            .decryptPreview(
                              messageId: lastMessageId,
                              matchId: matchId,
                              senderId: lastMessageSenderId,
                              recipientId: userId,
                              senderKeyId: senderKeyId,
                              recipientKeyId: recipientKeyId,
                              contentOriginalEncryptedBase64:
                                  serverTranslatedEncrypted,
                              contentOriginalNonceBase64: serverTranslatedNonce,
                              wrappedKeysJson: jsonEncode(wrappedKeys),
                            );
                  }
                }
              }

              final hasAnyTranslation =
                  hasEncryptedTranslation || decryptedTranslation != null;

              final isPendingTranslatedNotification =
                  lastMessageId != null &&
                  _pendingTranslatedNotificationMessageIds.contains(
                    lastMessageId,
                  );
              final shouldProcessNotification =
                  unreadCount > previousUnread ||
                  (isPendingTranslatedNotification && hasAnyTranslation);

              if (shouldProcessNotification) {
                // Guard against phantom notifications for old, already-read
                // messages.  This can happen when:
                //   * The realtime channel handler already notified this
                //     message (it adds the id to _notifiedMessageIds before
                //     triggering the sync that drives this fallback), or
                //   * clearUnreadForMatch() resets the local unread count to
                //     0, and the subsequent syncChatsNow() returns the
                //     pre-mark-as-read server state, making unreadCount
                //     appear to jump back up.
                // The realtime handler already short-circuits via the same
                // set; mirror that here so the sync fallback doesn't
                // re-notify.
                if (lastMessageId != null &&
                    lastMessageId.isNotEmpty &&
                    _notifiedMessageIds.contains(lastMessageId)) {
                  debugPrint(
                    '🔄 [SYNC FALLBACK] Skipping notification for chat $matchId — message $lastMessageId already notified',
                  );
                  _previousChatUnreadCounts[matchId] = unreadCount;
                  return chat;
                }

                debugPrint(
                  '🔄 [SYNC FALLBACK] Detected new message(s) via sync for chat $matchId (was $previousUnread, now $unreadCount)',
                );

                // This message arrived via sync, not realtime - trigger notification as fallback
                try {
                  final messageContent =
                      json['last_message'] as String? ?? 'New message';
                  String? detectedSourceLang =
                      json['last_message_source_language']?.toString();
                  if (detectedSourceLang != null &&
                      detectedSourceLang.isNotEmpty &&
                      detectedSourceLang != 'null') {
                    detectedSourceLang = normalizeLanguageCode(
                      detectedSourceLang,
                    );
                    if (!isValidLanguageCode(detectedSourceLang)) {
                      detectedSourceLang = null;
                    }
                  } else {
                    detectedSourceLang = null;
                  }

                  if ((detectedSourceLang == null ||
                          detectedSourceLang.isEmpty) &&
                      lastMessageId != null &&
                      lastMessageId.isNotEmpty) {
                    try {
                      final messages = await localDb.getMessages(matchId);
                      final rawMessage = messages.firstWhere(
                        (m) => (m['id']?.toString() ?? '') == lastMessageId,
                        orElse: () => <String, dynamic>{},
                      );
                      if (rawMessage.isNotEmpty) {
                        final rawSource =
                            (rawMessage['detected_source_language'] ??
                                    rawMessage['source_language'] ??
                                    rawMessage['language'])
                                ?.toString();
                        if (rawSource != null &&
                            rawSource.isNotEmpty &&
                            rawSource != 'null' &&
                            isValidLanguageCode(rawSource)) {
                          detectedSourceLang = normalizeLanguageCode(rawSource);
                        }
                      }
                    } catch (_) {}
                  }

                  // If source is still unknown, try client-side detection on the message content
                  if ((detectedSourceLang == null ||
                          detectedSourceLang.isEmpty) &&
                      messageContent.isNotEmpty &&
                      messageContent != 'New message') {
                    try {
                      final translationService = ref.read(
                        translationServiceProvider,
                      );
                      final clientDetected = normalizeLanguageCode(
                        await translationService.identifyLanguage(
                          messageContent,
                        ),
                      );
                      if (isValidLanguageCode(clientDetected) &&
                          clientDetected != 'und') {
                        detectedSourceLang = clientDetected;
                      }
                    } catch (_) {}
                  }

                  final shouldWaitForTranslation =
                      translationEnabled &&
                      !hasAnyTranslation &&
                      (detectedSourceLang == null ||
                          detectedSourceLang != uiLang);

                  // Only suppress if the message is still in the pending set
                  // (i.e., the translation timeout hasn't fired yet). If the
                  // timeout has already removed it, show the notification with
                  // whatever content is available.
                  if (shouldWaitForTranslation &&
                      lastMessageId != null &&
                      lastMessageId.isNotEmpty &&
                      _pendingTranslatedNotificationMessageIds.contains(
                        lastMessageId,
                      )) {
                    _schedulePendingTranslationTimeout(lastMessageId);
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Waiting for translation before notifying for message $lastMessageId',
                    );
                    _previousChatUnreadCounts[matchId] = unreadCount;
                    return chat;
                  }

                  final translatedText =
                      serverTranslatedContent ?? decryptedTranslation;
                  final bool hasValidTranslation =
                      translatedText != null &&
                      translatedText.isNotEmpty &&
                      translatedText != 'null';

                  final String displayContent;
                  if (translationEnabled &&
                      detectedSourceLang != null &&
                      detectedSourceLang.isNotEmpty) {
                    if (detectedSourceLang == uiLang) {
                      // Source matches UI → show original
                      displayContent = decryptedContent ?? messageContent;
                    } else {
                      // Source differs from UI → translation required
                      displayContent = hasValidTranslation
                          ? translatedText
                          : '';
                    }
                  } else if (translationEnabled) {
                    // No source language info → show translation if available, else original
                    displayContent = hasValidTranslation
                        ? translatedText
                        : (decryptedContent ?? messageContent);
                  } else {
                    // Translation disabled → show original
                    displayContent = decryptedContent ?? messageContent;
                  }

                  if (displayContent.isEmpty) {
                    _previousChatUnreadCounts[matchId] = unreadCount;
                    return chat;
                  }

                  // Fetch sender name (local Hive first, then Supabase, then "Someone")
                  final senderName = await _resolveChatNotificationSenderName(
                    localDb: localDb,
                    currentUserId: userId,
                    matchId: matchId,
                    senderId: lastMessageSenderId,
                  );
                  debugPrint(
                    '🔄 [SYNC FALLBACK] Resolved sender name for notification: "$senderName"',
                  );

                  debugPrint(
                    '🔄 [SYNC FALLBACK] ═══════════════════════════════════════════════════',
                  );
                  debugPrint(
                    '🔄 [SYNC FALLBACK] NOTIFICATION TRIGGER - Message arrived via sync',
                  );
                  debugPrint('🔄 [SYNC FALLBACK] Chat: $matchId');
                  if (translationEnabled) {
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Translation: ENABLED (showing translated message)',
                    );
                  } else {
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Translation: DISABLED (showing original message)',
                    );
                  }
                  debugPrint(
                    '🔄 [SYNC FALLBACK] ═══════════════════════════════════════════════════',
                  );

                  // Trigger notifications via platform-specific services
                  if (kIsWeb) {
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Platform: Web - showing browser notification',
                    );
                    WebNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  } else if (Platform.isAndroid) {
                    // On Android, notification will be handled by background service
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Platform: Android - notification handled by background service',
                    );
                  } else if (Platform.isIOS) {
                    debugPrint(
                      '🔄 [SYNC FALLBACK] Platform: iOS - showing local notification',
                    );
                    await MobileLocalNotificationService.showMessageNotification(
                      chatId: matchId,
                      senderName: senderName,
                      messageContent: displayContent,
                      matchId: matchId,
                    );
                  }
                  if (lastMessageId != null && lastMessageId.isNotEmpty) {
                    _pendingTranslatedNotificationMessageIds.remove(
                      lastMessageId,
                    );
                    _pendingTranslationTimeoutTimers
                        .remove(lastMessageId)
                        ?.cancel();
                    _notifiedMessageIds.add(lastMessageId);
                  }
                } catch (e) {
                  debugPrint(
                    '🔄 [SYNC FALLBACK] Error triggering notification: $e',
                  );
                }
              }

              // Update state to current unread count
              _previousChatUnreadCounts[matchId] = unreadCount;
            }

            final translationEnabled = json['translation_enabled'] == true;
            final lastMessageSenderIdCheck =
                json['last_message_sender_id'] as String?;
            final isIncomingLastMessage =
                lastMessageSenderIdCheck != null &&
                lastMessageSenderIdCheck != userId;

            if (translationEnabled && isIncomingLastMessage) {
              final matchIdForCaseCheck =
                  json['match_id']?.toString() ?? chat.matchId;
              final lastMessageId = json['last_message_id']?.toString();
              String? detectedSourceLang =
                  json['last_message_source_language'] as String?;
              // Normalize up front so an in-flight "#pending#<epoch>" claim
              // from translate-proxy compares equal to the target it names.
              // Comparing the raw column value would make Case C look false
              // and discard a perfectly readable cached translation, blanking
              // the preview for the whole round trip.
              final rawTargetLanguage =
                  json['last_message_target_language'] as String?;
              String? translatedTargetLang = rawTargetLanguage == null
                  ? null
                  : normalizeLanguageCode(rawTargetLanguage);
              var translatedPreview =
                  json['last_message_translated'] as String?;
              // Content version of the last message, and the version the cached
              // preview translation was made for. An edit keeps the message id,
              // so these two — not the id — are what decide whether the cached
              // preview still describes the text on screen.
              final messageEditedAt = normalizeEditMarker(
                json['last_message_edited_at'],
              );
              final previewEditedAt = normalizeEditMarker(
                json['last_message_translated_edited_at'],
              );
              // Set when this pass decrypts a translation itself rather than
              // reading it from the cache, so the stamp written back below
              // records the version the text was actually produced for.
              var previewStampedEditedAt = previewEditedAt;

              // The cache field mirrors the RPC's last_message_translated
              // column, which holds base64 ciphertext for v1 messages. If any
              // earlier sync stored it undecrypted, drop it here so it can
              // never be handed to ChatModel / ChatListItem.
              if (looksLikeEncryptedBlob(translatedPreview)) {
                translatedPreview = null;
              }

              // For v1 (encrypted) messages, try to decrypt the translation if available in the sync payload
              final syncEncScheme =
                  json['last_message_encryption_scheme'] as String?;

              if (syncEncScheme == 'v1') {
                // For v1 encrypted messages, check if the cached translation
                // already matches the current UI language before re-decrypting.
                // syncChatsNow stores the decrypted result with the target
                // language, so if they match, we can reuse it directly — but
                // only while it was made for the message's current content.
                // An edit re-encrypts the message under the same id, so without
                // the marker check the pre-edit text kept rendering here even
                // after the bubble inside the open chat had been retranslated.
                final hasCachedTranslation = previewTranslationIsCurrent(
                  cachedText: translatedPreview,
                  cachedTargetLanguage: translatedTargetLang,
                  cachedEditedAt: previewEditedAt,
                  messageEditedAt: messageEditedAt,
                  uiLanguage: uiLang,
                  normalizeLanguage: normalizeLanguageCode,
                );

                if (!hasCachedTranslation) {
                  translatedPreview = null;
                  final encryptedTranslation =
                      json['last_message_content_translated_encrypted']
                          as String?;
                  final translationNonce =
                      json['last_message_content_translated_nonce'] as String?;
                  final targetLang =
                      json['last_message_target_language'] as String?;

                  if (encryptedTranslation != null &&
                      translationNonce != null &&
                      targetLang != null &&
                      normalizeLanguageCode(targetLang) == uiLang) {
                    final senderKeyId =
                        json['last_message_sender_key_id'] as String?;
                    final recipientKeyId =
                        json['last_message_recipient_key_id'] as String?;
                    final wrappedKeys = json['last_message_wrapped_keys'];
                    final senderId = json['last_message_sender_id'] as String?;

                    // The stored translation is only usable while the server
                    // still vouches that it was made for the current content.
                    // Normally redundant (an edit NULLs the translation and
                    // translate-proxy refuses to skip a marker-mismatched row)
                    // but this is the path that would otherwise decrypt a
                    // pre-edit blob and cache it as the current preview.
                    final serverTranslationIsCurrent =
                        translationEditMarkersMatch(
                          normalizeEditMarker(
                            json['last_message_translated_source_edited_at'],
                          ),
                          messageEditedAt,
                        );

                    if (serverTranslationIsCurrent &&
                        senderKeyId != null &&
                        recipientKeyId != null &&
                        wrappedKeys != null &&
                        senderId != null) {
                      translatedPreview =
                          await EncryptedNotificationPreviewService.instance
                              .decryptPreview(
                                messageId: lastMessageId!,
                                matchId: matchIdForCaseCheck,
                                senderId: senderId,
                                recipientId: userId,
                                senderKeyId: senderKeyId,
                                recipientKeyId: recipientKeyId,
                                contentOriginalEncryptedBase64:
                                    encryptedTranslation,
                                contentOriginalNonceBase64: translationNonce,
                                wrappedKeysJson: jsonEncode(wrappedKeys),
                                detectedSourceLanguage: detectedSourceLang,
                                targetLanguage: uiLang,
                              );
                      // Record the content version this freshly decrypted
                      // preview describes, so the next provider pass can reuse
                      // it from the cache instead of re-decrypting, and so an
                      // edit that lands later is detectable.
                      if (translatedPreview != null &&
                          translatedPreview.isNotEmpty) {
                        previewStampedEditedAt = messageEditedAt;
                        // Persist it once, so the next provider pass can reuse
                        // this text straight from the cache. Guarded on the
                        // marker actually changing: an unconditional write here
                        // would emit a Hive event on every pass and re-trigger
                        // this very stream.
                        if (previewStampedEditedAt != previewEditedAt) {
                          unawaited(
                            localDb.updateChatLastMessageTranslation(
                              userId,
                              matchIdForCaseCheck,
                              lastMessageId,
                              translatedPreview,
                              targetLanguage: uiLang,
                              editedAt: previewStampedEditedAt,
                            ),
                          );
                        }
                      }
                    }
                  }
                } // end if (!hasCachedTranslation)
              } else if (translatedPreview != null) {
                // Verify the stored translation matches current UI language and
                // was made for the message's current content.
                if (!previewTranslationIsCurrent(
                  cachedText: translatedPreview,
                  cachedTargetLanguage: translatedTargetLang,
                  cachedEditedAt: previewEditedAt,
                  messageEditedAt: messageEditedAt,
                  uiLanguage: uiLang,
                  normalizeLanguage: normalizeLanguageCode,
                )) {
                  translatedPreview = null;
                }
              }

              try {
                if (translatedPreview == null &&
                    matchIdForCaseCheck.isNotEmpty &&
                    lastMessageId != null &&
                    lastMessageId.isNotEmpty) {
                  final messages = await localDb.getMessages(
                    matchIdForCaseCheck,
                  );
                  final rawMessage = messages.firstWhere(
                    (m) => (m['id']?.toString() ?? '') == lastMessageId,
                    orElse: () => <String, dynamic>{},
                  );

                  if (rawMessage.isNotEmpty) {
                    final rawSource =
                        (rawMessage['detected_source_language'] ??
                                rawMessage['source_language'] ??
                                rawMessage['language'])
                            ?.toString();
                    if (rawSource != null &&
                        rawSource.isNotEmpty &&
                        rawSource != 'null') {
                      detectedSourceLang = normalizeLanguageCode(rawSource);
                    }

                    final rawTarget =
                        (rawMessage['translated_target_language'] ??
                                rawMessage['translated_lang'])
                            ?.toString();
                    final rawTargetNorm = rawTarget != null
                        ? normalizeLanguageCode(rawTarget)
                        : null;

                    final rawTranslated =
                        (rawMessage['content_translated'] ??
                                rawMessage['translated_text'])
                            as String?;
                    // Cached plaintext is accepted only when it is for the
                    // current UI language (checked below). For v1 rows it must
                    // additionally be made for the message's current content —
                    // the same marker rule the open chat's fast path uses —
                    // otherwise a pre-edit translation would be reused.
                    // Legacy (non-v1) rows predate markers and keep the
                    // previous accept behavior.
                    final rawEncScheme =
                        rawMessage['encryption_scheme'] as String?;
                    final rawCachedUsable =
                        rawTranslated != null &&
                        rawTranslated.isNotEmpty &&
                        rawTranslated != 'null' &&
                        !looksLikeEncryptedBlob(rawTranslated) &&
                        rawTargetNorm == uiLang &&
                        (rawEncScheme != 'v1' ||
                            translationEditMarkersMatch(
                              normalizeEditMarker(
                                rawMessage['translated_source_edited_at'],
                              ),
                              normalizeEditMarker(rawMessage['edited_at']),
                            ));
                    if (rawCachedUsable) {
                      translatedPreview = rawTranslated;
                      previewStampedEditedAt = normalizeEditMarker(
                        rawMessage['edited_at'],
                      );

                      // Update the chat preview cache so we don't have to look this up again
                      unawaited(
                        localDb.updateChatLastMessageTranslation(
                          userId,
                          matchIdForCaseCheck,
                          lastMessageId,
                          translatedPreview,
                          targetLanguage: uiLang,
                          editedAt: previewStampedEditedAt,
                        ),
                      );
                    }
                  }
                }
              } catch (_) {}

              // Final safety net: whatever combination of cache lookups and
              // decryption produced the preview, it must be readable text
              // before it can reach ChatModel. Anything else renders as the
              // "Loading…" placeholder instead of a ciphertext blob.
              if (looksLikeEncryptedBlob(translatedPreview)) {
                translatedPreview = null;
              }

              final hasTranslatedPreview =
                  translatedPreview != null &&
                  translatedPreview.isNotEmpty &&
                  translatedPreview != 'null';

              // Check if this is a NEW message by comparing message IDs
              // OR if translation just became available for the SAME message
              final snapshotKey = '$userId|$matchIdForCaseCheck';
              final previousChat = _recentChatSnapshots[snapshotKey];

              // Determine if this is a new message (either no previous chat OR different message ID)
              final bool isNewMessage =
                  (previousChat == null ||
                  previousChat.lastMessageId != lastMessageId);

              // Handle the case where we need to check for translation availability
              // We can only check previousChat's translation if it exists
              bool translationJustBecameAvailable = false;
              if (previousChat != null) {
                // previousChat exists - check if translation just became available
                final String? prevTranslated =
                    previousChat.lastMessageTranslated;
                final bool prevHadNoTranslation =
                    (prevTranslated == null ||
                    prevTranslated.isEmpty ||
                    prevTranslated == 'null');
                translationJustBecameAvailable =
                    !isNewMessage &&
                    prevHadNoTranslation &&
                    hasTranslatedPreview;
              }

              // If translation just became available for this message, we should show it!
              // This is the key case: new translation arrived for the same message
              if (translationJustBecameAvailable) {
                // Translation just arrived - show it!
                // Keep lastMessage as original, only update lastMessageTranslated
                return chat.copyWith(
                  lastMessageTranslated: translatedPreview,
                  lastMessageSourceLanguage: detectedSourceLang,
                );
              }

              if ((detectedSourceLang == null || detectedSourceLang.isEmpty) &&
                  matchIdForCaseCheck.isNotEmpty &&
                  lastMessageId != null &&
                  lastMessageId.isNotEmpty) {
                try {
                  final serverMessage = await supabase
                      .from('chat_messages')
                      .select(
                        'detected_source_language, translated_target_language, encryption_scheme',
                      )
                      .eq('id', lastMessageId)
                      .maybeSingle();
                  final serverSource =
                      serverMessage?['detected_source_language']?.toString();
                  if (serverSource != null &&
                      serverSource.isNotEmpty &&
                      serverSource != 'null') {
                    detectedSourceLang = normalizeLanguageCode(serverSource);
                  }
                  final serverTarget =
                      serverMessage?['translated_target_language']?.toString();
                  if (serverTarget != null &&
                      serverTarget.isNotEmpty &&
                      serverTarget != 'null') {
                    translatedTargetLang = normalizeLanguageCode(serverTarget);
                  }
                  // The server stores encrypted translations in `chat_messages`.
                  // Keep translation preview derived from the local cache/decryption logic.
                } catch (_) {}
              }

              final hasTranslatedPreviewAfterServerCheck =
                  translatedPreview != null &&
                  translatedPreview.isNotEmpty &&
                  translatedPreview != 'null';

              // Check if server source is suspicious (invalid code, or source == target but != UI)
              // This indicates incorrect language detection in the database
              final bool serverSourceSuspicious =
                  detectedSourceLang != null &&
                  (!isValidLanguageCode(detectedSourceLang) ||
                      (detectedSourceLang == translatedTargetLang &&
                          detectedSourceLang != uiLang));

              // If source is suspicious, try to detect locally
              if (serverSourceSuspicious &&
                  matchIdForCaseCheck.isNotEmpty &&
                  lastMessageId != null) {
                try {
                  final messages = await localDb.getMessages(
                    matchIdForCaseCheck,
                  );
                  final rawMessage = messages.firstWhere(
                    (m) => (m['id']?.toString() ?? '') == lastMessageId,
                    orElse: () => <String, dynamic>{},
                  );
                  if (rawMessage.isNotEmpty) {
                    final originalContent =
                        (rawMessage['content_original'] ??
                                rawMessage['content'])
                            ?.toString();
                    if (originalContent != null && originalContent.isNotEmpty) {
                      final translationService = ref.read(
                        translationServiceProvider,
                      );
                      final textForLangId = _stripEmojisForLanguageId(
                        originalContent,
                      );
                      if (textForLangId.replaceAll(RegExp(r'\s+'), '').length >=
                          2) {
                        final detectedLang = await translationService
                            .identifyLanguage(textForLangId);
                        if (detectedLang.isNotEmpty) {
                          detectedSourceLang = normalizeLanguageCode(
                            detectedLang,
                          );
                          debugPrint(
                            '🔍 Recent chats: Server source suspicious ($detectedSourceLang == $translatedTargetLang), re-detected as $detectedSourceLang',
                          );
                        }
                      }
                    }
                  }
                } catch (e) {
                  debugPrint(
                    '🔍 Recent chats: Failed to re-detect source language: $e',
                  );
                }
              }

              final isCaseBAfterServerCheck =
                  detectedSourceLang != null && detectedSourceLang == uiLang;
              final isCaseCAfterServerCheck =
                  translatedTargetLang != null &&
                  translatedTargetLang == uiLang;

              debugPrint(
                '🔍 Recent chats: Translation check - UI=$uiLang, source=$detectedSourceLang, target=$translatedTargetLang, CaseB=$isCaseBAfterServerCheck, CaseC=$isCaseCAfterServerCheck',
              );

              // If this is a NEW message without translation yet (source unknown or source != UI),
              // don't show anything - wait for translation to become available
              final isAbsoluteLastMessage =
                  lastMessageId != null && lastMessageId == chat.lastMessageId;

              // Whenever the last message is an incoming message that still has
              // no readable text for the UI language, ask for one quick forced
              // sync. Without it the row sits on "Loading…" until the 15s global
              // timer happens to fire, even though translate-proxy may already
              // have written the translation seconds earlier.
              if (!hasTranslatedPreviewAfterServerCheck &&
                  isAbsoluteLastMessage &&
                  !isCaseBAfterServerCheck &&
                  (detectedSourceLang == null ||
                      detectedSourceLang != uiLang) &&
                  lastMessageId.isNotEmpty) {
                schedulePreviewTranslationRefresh(
                  messageId: lastMessageId,
                  targetLanguage: uiLang,
                );
              }

              // An edit keeps the same message id, so isNewMessage is false —
              // yet the stored translation was invalidated and the preview
              // has nothing readable for the UI language. Detect that via the
              // local edited_at marker and run the same immediate
              // translation. The edge regenerates it exactly once: its skip
              // compares the stored version marker against the row's edited_at,
              // so a pre-edit payload never counts as done.
              bool lastMessageEdited = false;
              if (!isNewMessage &&
                  !hasTranslatedPreviewAfterServerCheck &&
                  lastMessageId != null &&
                  lastMessageId.isNotEmpty) {
                try {
                  final editedMsgs = await localDb.getMessages(
                    matchIdForCaseCheck,
                  );
                  final editedRaw = editedMsgs.firstWhere(
                    (m) => (m['id']?.toString() ?? '') == lastMessageId,
                    orElse: () => <String, dynamic>{},
                  );
                  final editedAt = editedRaw['edited_at']?.toString();
                  lastMessageEdited = editedAt != null && editedAt.isNotEmpty;
                } catch (_) {}
              }

              if ((isNewMessage || lastMessageEdited) &&
                  !ref.read(localizationProvider).isLoading &&
                  !hasTranslatedPreviewAfterServerCheck &&
                  (detectedSourceLang == null ||
                      detectedSourceLang != uiLang)) {
                if (isAbsoluteLastMessage &&
                    matchIdForCaseCheck.isNotEmpty &&
                    lastMessageId.isNotEmpty) {
                  final sourceLang = guessLanguageCode(chat.lastMessage);
                  // Only pass source_language if our detection is confident
                  // (not "und" = undetermined).  Latin-script words that don't
                  // match any word list fall back to "en".
                  unawaited(
                    _triggerImmediateLastMessageTranslation(
                      localDb: localDb,
                      userId: userId,
                      matchId: matchIdForCaseCheck,
                      messageId: lastMessageId,
                      targetLanguage: uiLang,
                      sourceLanguage: sourceLang,
                    ),
                  );
                }
                // This is a new incoming message (or edit) in a different
                // language whose translation hasn't landed yet. Return the
                // FRESH row so Recent Chats tracks the last message
                // immediately; ChatListItem shows a blank preview until the
                // translation arrives (never the untranslated original).
                // The translation triggered above fills both the message
                // cache and the chat preview when it completes.
                return chat.copyWith(lastMessageTranslated: translatedPreview);
              }

              if (isCaseBAfterServerCheck) {
                // Case B: UI language matches source language - show original message
                debugPrint(
                  '🔍 Recent chats: Case B triggered - UI matches source, using original message',
                );
                // The chat.lastMessage already contains the correct content from the DB
                // Include the source language so the UI knows to display the original message
                return chat.copyWith(
                  lastMessageSourceLanguage: detectedSourceLang,
                );
              }

              if (hasTranslatedPreviewAfterServerCheck &&
                  isCaseCAfterServerCheck) {
                // Keep lastMessage as original, only update lastMessageTranslated
                return chat.copyWith(
                  lastMessageTranslated: translatedPreview,
                  lastMessageSourceLanguage: detectedSourceLang,
                );
              }

              // If we have source language info, include it in the chat model.
              // Always pass translatedPreview so stale translations (wrong
              // target language) are cleared rather than shown in the UI.
              if (detectedSourceLang != null) {
                return chat.copyWith(
                  lastMessageSourceLanguage: detectedSourceLang,
                  lastMessageTranslated: translatedPreview,
                );
              }

              return chat.copyWith(lastMessageTranslated: translatedPreview);
            }

            return chat;
          } catch (e) {
            final matchId = json['match_id']?.toString() ?? 'unknown_match';
            debugPrint('Recent chats item processing failed for $matchId: $e');
            return null;
          }
        }).toList(),
      );

      final visibleChats =
          chats
              .whereType<ChatModel>()
              .where((chat) => chat.otherUserId != userId)
              .toList()
            ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
      for (final chat in visibleChats) {
        _recentChatSnapshots['$userId|${chat.matchId}'] = chat;
      }
      _recentChatsProcessedInput[cacheKey] = list;
      _recentChatsProcessedResult[cacheKey] = visibleChats;
      return visibleChats;
    } catch (e) {
      _recentChatsProcessedInput.remove(cacheKey);
      _recentChatsProcessedResult.remove(cacheKey);
      debugPrint('Recent chats stream mapping failed: $e');
      return <ChatModel>[];
    }
  });
});

// Dashboard stats provider - cached stats with real-time updates
/// Fetches the live dashboard stats (online + nearby) for [userId] directly
/// from the server. Returns the stats map plus the radius actually used for
/// the nearby query so callers can log it without re-reading config.
///
/// `online` is computed as `get_online_others_count() + 1`: the signed-in
/// user is online by definition, so the count is correct the moment it is
/// fetched and never has to wait for the user's own user_activity row /
/// session registration to commit server-side. This eliminates the whole class
/// of "self not yet marked online" timing bugs (and the debounced session
/// registration, the 60s cooldown, and the heartbeat no longer matter for the
/// displayed count at all).
Future<({Map<String, int?> stats, int radiusMeters, double radiusKm})>
_fetchLiveDashboardStats(String userId) async {
  // The online-others count does not depend on the radius, so start it before
  // resolving the radius rather than after. That collapses what used to be four
  // serial round trips (config -> users -> online RPC -> nearby RPC) into two.
  final onlineOthersFuture = supabase.rpc(
    'get_online_others_count',
    params: {'p_user_id': userId},
  );

  // Get the user's radius setting from the users table (stored in meters)
  int userRadiusMeters = await (() async {
    try {
      return await appConfigService.getInt(
        'profile.match_radius_default_meters',
        defaultValue: 100,
      );
    } catch (e) {
      return 100;
    }
  })();
  try {
    final userResponse = await supabase
        .from('users')
        .select('match_radius_default')
        .eq('id', userId)
        .single();
    userRadiusMeters =
        (userResponse['match_radius_default'] as int?) ?? userRadiusMeters;
  } catch (e) {
    if (!isExpectedOfflineFailure(e)) {
      debugPrint('Could not fetch user radius, using default: $e');
    }
  }

  // Convert meters to km for the RPC call - use exact precision
  final userRadiusKm = userRadiusMeters / 1000.0;

  final nearbyFuture = supabase.rpc(
    'get_nearby_users_count',
    params: {'p_user_id': userId, 'p_radius_km': userRadiusKm},
  );

  final othersOnlineCount = ((await onlineOthersFuture) as int?) ?? 0;
  final nearbyCount = ((await nearbyFuture) as int?) ?? 0;

  return (
    stats: <String, int?>{
      'nearby': nearbyCount,
      'online': othersOnlineCount + 1,
    },
    radiusMeters: userRadiusMeters,
    radiusKm: userRadiusKm,
  );
}

/// In-memory warm cache of dashboard stats fetched at auth time, keyed by user
/// id. Lets the dashboard provider seed its very first emission with an
/// already-correct count instead of showing a placeholder while its own fetch
/// completes. Values older than a few seconds are ignored so a late provider
/// creation never flashes a stale number.
final Map<String, ({Map<String, int?> stats, DateTime at})>
_warmDashboardStatsByUser = {};

/// Pre-fetches live dashboard stats for [userId] right after an auth event
/// (signedIn / cold-start initialSession), before the home screen builds, so
/// the online count is displayed immediately when the dashboard first renders.
Future<void> warmDashboardStatsForUser(String userId) async {
  if (userId.isEmpty) return;
  if (supabase.auth.currentSession == null) return;
  try {
    final live = await _fetchLiveDashboardStats(userId);
    _warmDashboardStatsByUser[userId] = (stats: live.stats, at: DateTime.now());
    unawaited(
      LocalDbService.instance.then(
        (localDb) => localDb.saveDashboardStats(
          userId,
          live.stats['online'] ?? 0,
          live.stats['nearby'] ?? 0,
        ),
      ),
    );
  } catch (e) {
    _warmDashboardStatsByUser.remove(userId);
  }
}

final dashboardStatsProvider = StreamProvider.autoDispose<Map<String, int?>>((
  ref,
) {
  final userId = supabase.auth.currentUser?.id;

  if (userId == null) {
    return Stream.value({'nearby': 0, 'online': 0});
  }

  final controller = StreamController<Map<String, int?>>();
  final localDb = ref.read(localDbProvider);
  Timer? periodicRefreshTimer;
  Timer? userActivityDebounceTimer;
  DateTime? lastFetchStatsTime;
  Map<String, int?>? lastEmittedStats;
  DateTime? lastActivityCommitTimestamp;
  final lastSeenActivityStateByUser = <String, String>{};
  bool isFetchingStats = false;

  void logDashboardStatsDecision({
    required String phase,
    required Map<String, int?> stats,
    required String reason,
    bool usedCache = false,
    bool skippedServerFetch = false,
    String? source,
  }) {
    final online = stats['online'] ?? 0;
    final nearby = stats['nearby'] ?? 0;
    final sourceLabel = source ?? 'unknown';
    debugPrint(
      '📊 [HOME_STATS] phase=$phase online=$online nearby=$nearby displayedToUser=$online source=$sourceLabel cacheUsed=$usedCache skippedServerFetch=$skippedServerFetch reason=$reason',
    );
    if (online == 0) {
      debugPrint('📊 [HOME_STATS] zero online count explanation: $reason');
    }
  }

  // Online and nearby counts are intentionally never cached: they are
  // realtime dashboard stats and should always reflect the current server state.
  Future<Map<String, int?>> fetchStats({
    bool useCache = false,
    bool saveToCache = false,
    bool force = false,
  }) async {
    // Throttle: prevent fetching more than once every 2 seconds unless forced
    // Also prevent concurrent fetches
    if (!force) {
      if (isFetchingStats) {
        return lastEmittedStats ?? {'nearby': 0, 'online': 0};
      }
      final now = DateTime.now();
      if (lastFetchStatsTime != null &&
          now.difference(lastFetchStatsTime!).inMilliseconds < 2000) {
        return lastEmittedStats ?? {'nearby': 0, 'online': 0};
      }
    }

    // Validate auth session before making API calls to prevent 401 errors on login screen
    final session = supabase.auth.currentSession;
    if (session == null) {
      final zeroStats = {'nearby': 0, 'online': 0};
      debugPrint('fetchStats: No valid auth session, returning empty stats');
      logDashboardStatsDecision(
        phase: 'auth-missing',
        stats: zeroStats,
        reason:
            'No valid auth session exists, so the home screen shows 0 because there is no signed-in user to query.',
        usedCache: false,
        skippedServerFetch: true,
        source: 'auth_guard',
      );
      return zeroStats;
    }

    // Verify token is not expired
    if (session.expiresAt != null) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (session.expiresAt! < now) {
        final zeroStats = {'nearby': 0, 'online': 0};
        debugPrint('fetchStats: Token expired, returning empty stats');
        logDashboardStatsDecision(
          phase: 'token-expired',
          stats: zeroStats,
          reason:
              'The Supabase session token is expired, so the dashboard cannot query the server and displays 0.',
          usedCache: false,
          skippedServerFetch: true,
          source: 'auth_guard',
        );
        return zeroStats;
      }
    }

    lastFetchStatsTime = DateTime.now();
    isFetchingStats = true;

    try {
      // Live dashboard counters intentionally do not use local DB cache.
      if (!force) {
        if (shouldSkipSupabaseCalls()) {
          final zeroStats = {'nearby': 0, 'online': 0};
          debugPrint(
            '📊 Dashboard stats: Skipping server fetch - Supabase paused',
          );
          logDashboardStatsDecision(
            phase: 'supabase-paused',
            stats: zeroStats,
            reason:
                'Supabase is paused/offline and the live online/nearby counters intentionally do not use cache, so the UI shows 0 until connectivity is restored.',
            usedCache: false,
            skippedServerFetch: true,
            source: 'empty_default',
          );
          return zeroStats;
        }
      }

      // Fetch fresh stats from server
      if (kIsWeb) {}

      final live = await _fetchLiveDashboardStats(userId);
      final freshStats = live.stats;
      final userRadiusMeters = live.radiusMeters;
      final userRadiusKm = live.radiusKm;
      final nearbyCount = freshStats['nearby'] ?? 0;

      logDashboardStatsDecision(
        phase: 'rpc-fetched',
        stats: freshStats,
        reason:
            'Fresh server query from public.get_online_others_count() (last_activity > NOW() - 61s, excluding self) plus 1 for the signed-in user, so the count is correct immediately and never waits for self to be marked online.',
        source: 'supabase_rpc',
      );

      // Format radius for log in user's preferred units
      // Guard: provider may have been disposed during the async supabase calls above
      if (!ref.mounted) return {'nearby': 0, 'online': 0};
      final usesImperial = await ref.read(unitSystemProvider.future);
      String radiusLog;
      if (usesImperial) {
        final feet = userRadiusMeters * 3.28084;
        radiusLog = '${feet.round()} feet';
      } else {
        radiusLog = userRadiusMeters >= 1000
            ? '${(userRadiusMeters / 1000.0).toStringAsFixed(1)} km'
            : '$userRadiusMeters m';
      }
      radiusLog +=
          ' (DB: ${userRadiusMeters}m → ${userRadiusKm}km used for query)';

      debugPrint(
        'Dashboard stats fetched: online=${freshStats['online']}, nearby=$nearbyCount (radius=$radiusLog)',
      );

      // Cache the fresh stats if requested
      if (saveToCache) {
        await localDb.saveDashboardStats(
          userId,
          freshStats['online'] ?? 0,
          nearbyCount,
        );
      }

      return freshStats;
    } catch (e) {
      if (!isExpectedOfflineFailure(e)) {
        debugPrint('Error fetching dashboard stats: $e');
      }

      // Live dashboard counters never fall back to stale cache; they display
      // current server state only. Keep the last known correct count when
      // available; otherwise keep online as "unknown" (placeholder) instead of
      // presenting 0 as if it were a real count.
      final zeroStats =
          lastEmittedStats ?? <String, int?>{'nearby': 0, 'online': null};
      logDashboardStatsDecision(
        phase: 'error-fallback',
        stats: zeroStats,
        reason:
            'The live online/nearby RPC failed. The dashboard keeps the last known correct count if available, otherwise online stays unknown (placeholder) until the next successful refresh.',
        usedCache: false,
        source: 'empty_default',
      );
      return zeroStats;
    } finally {
      isFetchingStats = false;
    }
  }

  bool shouldRefreshForActivityChange({
    required String changedUserId,
    required Map<String, dynamic>? newRecord,
    Map<String, dynamic>? oldRecord,
  }) {
    final newOnline = newRecord?['is_online'];
    final newVisible = newRecord?['is_visible'];
    final oldOnline = oldRecord?['is_online'];
    final oldVisible = oldRecord?['is_visible'];
    final hasStatusFields =
        newOnline != null ||
        newVisible != null ||
        oldOnline != null ||
        oldVisible != null;

    if (!hasStatusFields) {
      return false;
    }

    if (oldRecord != null &&
        oldRecord.containsKey('is_online') &&
        oldRecord.containsKey('is_visible') &&
        newOnline == oldOnline &&
        newVisible == oldVisible) {
      return false;
    }

    final nextState = '${newOnline ?? oldOnline}|${newVisible ?? oldVisible}';
    if (lastSeenActivityStateByUser[changedUserId] == nextState) {
      return false;
    }
    lastSeenActivityStateByUser[changedUserId] = nextState;
    return true;
  }

  // Register callback to refresh stats when connectivity is restored.
  // Cooldown guards against duplicate fires from the ConnectivityRestoreCoordinator
  // (8s min interval is not enough on cold start when the FCM registerSession's
  // setSupabaseAvailability(true) also fires a restore ~10s after the first one).
  DateTime? lastResumeStatsRefreshAt;
  final disposeResumeListener = onSupabaseResume(() async {
    if (!ref.mounted || controller.isClosed) return;
    final now = DateTime.now();
    if (lastResumeStatsRefreshAt != null &&
        now.difference(lastResumeStatsRefreshAt!) <
            const Duration(seconds: 30)) {
      return;
    }
    lastResumeStatsRefreshAt = now;
    debugPrint('📊 Dashboard stats: Connectivity restored, forcing refresh');
    try {
      final fresh = await fetchStats(
        useCache: false,
        saveToCache: false,
        force: true,
      );
      // Guard: controller may have been closed during the await above
      // (e.g. autoDispose triggered because all watchers were removed)
      if (controller.isClosed) return;
      if (!_sameDashboardStats(fresh, lastEmittedStats)) {
        controller.add(fresh);
        lastEmittedStats = fresh;
      }
    } catch (e) {
      debugPrint(
        '📊 Dashboard stats: Error on connectivity restore refresh: $e',
      );
    }
  });

  // Seed the first emission from the auth-time warm fetch (fetched on
  // signedIn / cold-start, before this provider existed) so the count is on
  // screen immediately. Only trust it if fresh; the fetch below then corrects
  // it if the server has changed in the meantime.
  final warm = _warmDashboardStatsByUser.remove(userId);
  if (warm != null &&
      DateTime.now().difference(warm.at) < const Duration(seconds: 30)) {
    lastEmittedStats = warm.stats;
    controller.add(warm.stats);
  }

  // Live counters (online/nearby) are intentionally NEVER read from disk:
  // they must reflect current server state only. Emit the bootstrap memory
  // warm value (a live RPC from seconds ago) if present, then fetch live.
  // No Hive snapshot is used here by design.
  (() async {
    try {
      final fresh = await fetchStats(useCache: false, saveToCache: false);
      if (!_sameDashboardStats(fresh, lastEmittedStats)) {
        controller.add(fresh);
        lastEmittedStats = fresh;
      }
    } catch (_) {
      // ignore initial refresh errors
    }
  })();

  // On web, listen for post-location-sync callbacks so the nearby count is
  // re-fetched immediately after the user's own location row is committed.
  // Without this, the initial nearby=0 result (fetched before the RPC
  // completed) persists until the next periodic refresh because the realtime
  // subscription filters own-user location changes.
  if (kIsWeb) {
    WebLocationService.onLocationSynced = () async {
      if (!ref.mounted || controller.isClosed) return;
      try {
        await localDb.clearDashboardStatsCache(userId);
        // Small delay so Postgres can commit the location row before the query
        await Future.delayed(const Duration(milliseconds: 500));
        if (!ref.mounted || controller.isClosed) return;
        final fresh = await fetchStats(
          useCache: false,
          saveToCache: false,
          force: true,
        );
        if (!_sameDashboardStats(fresh, lastEmittedStats)) {
          controller.add(fresh);
          lastEmittedStats = fresh;
        }
      } catch (_) {}
    };
  }

  // Refresh the online count immediately after session registration
  // completes. On a fresh login the initial fetchStats runs BEFORE the
  // debounced registerSession (5s), so is_online is still false and the
  // count is cached as 0; the registration then flips the user_activity row
  // online server-side (session trigger). Without this callback the count
  // would stay stale until the 30-minute periodic timer, because realtime on
  // user_activity is not reliable in this environment.
  Future<void> onSessionRegisteredHandler() async {
    if (!ref.mounted || controller.isClosed) return;
    try {
      // Live counters intentionally never use a cache, so no cache invalidation
      // is required here. The next server fetch reflects the current reality.
      final fresh = await fetchStats(
        useCache: false,
        saveToCache: false,
        force: true,
      );
      logDashboardStatsDecision(
        phase: 'session-registration-refresh',
        stats: fresh,
        reason:
            'Session registration completed and the dashboard refreshed the live online/nearby count directly from the server without any cache layer.',
        source: 'session_registered_callback',
      );
      if (!_sameDashboardStats(fresh, lastEmittedStats)) {
        controller.add(fresh);
        lastEmittedStats = fresh;
      }
    } catch (_) {}
  }

  SessionService.onSessionRegistered = onSessionRegisteredHandler;

  // We intentionally avoid the Supabase Presence channel here.
  // `realtime_client` 2.7.0 can throw an uncaught null-cast exception during
  // presence sync after reconnects, especially around auth/OAuth transitions.
  // Instead, we rely on WebSocket subscriptions for real-time updates and use
  // a longer-interval fallback timer (30 minutes) to ensure data freshness.
  // This eliminates the flashing caused by constant polling.
  periodicRefreshTimer = Timer.periodic(const Duration(minutes: 30), (_) {
    if (!ref.mounted || controller.isClosed) return;
    if (supabase.auth.currentSession == null) {
      debugPrint('fetchStats skipped in periodic timer: No valid session');
      return;
    }
    fetchStats(useCache: false, saveToCache: false).then((stats) {
      try {
        // Only emit if stats have changed
        if (!_sameDashboardStats(stats, lastEmittedStats)) {
          controller.add(stats);
          lastEmittedStats = stats;
        }
      } catch (_) {
        // ignore closed controller
      }
    });
  });

  // Subscribe to users table for visibility setting changes
  // This works because users table RLS allows reading all users
  final visibilityChannelName = 'dashboard_stats_visibility_$userId';
  RealtimeChannel? visibilityChannel;
  SupabaseRealtimeManager.instance.register(visibilityChannelName, () {
    visibilityChannel = supabase
        .channel(visibilityChannelName)
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          callback: (payload) {
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final oldRecord = payload.oldRecord as Map<String, dynamic>?;
            final changedUserId =
                (newRecord?['id'] ?? oldRecord?['id']) as String?;

            if (changedUserId == null || changedUserId == userId) return;

            final bool userVisibilityFieldPresent =
                (newRecord?.containsKey('user_visibility_setting') ?? false) ||
                (oldRecord?.containsKey('user_visibility_setting') ?? false);
            final bool systemVisibilityFieldPresent =
                (newRecord?.containsKey('system_visibility_status') ?? false) ||
                (oldRecord?.containsKey('system_visibility_status') ?? false);
            if (!userVisibilityFieldPresent && !systemVisibilityFieldPresent) {
              return;
            }

            final newVisible = newRecord?['user_visibility_setting'] as bool?;
            final oldVisible = oldRecord?['user_visibility_setting'] as bool?;
            final newSystem = newRecord?['system_visibility_status']
                ?.toString();
            final oldSystem = oldRecord?['system_visibility_status']
                ?.toString();
            final bool shouldRefetch =
                oldRecord == null ||
                newVisible != oldVisible ||
                newSystem != oldSystem;
            if (!shouldRefetch) return;

            debugPrint('Another user visibility setting changed');
            if (!ref.mounted) return;
            if (supabase.auth.currentSession == null) {
              debugPrint(
                'fetchStats skipped in visibility callback: No valid session',
              );
              return;
            }
            // Delay nearby count refresh when visibility changes to allow
            // location sync to complete. Without this delay, users who just
            // became visible may see nearby=0 because user_locations has no
            // fresh position yet, even though GPS is actively tracking.
            fetchStats(useCache: false, saveToCache: false).then((stats) {
              try {
                if (!_sameDashboardStats(stats, lastEmittedStats)) {
                  controller.add(stats);
                  lastEmittedStats = stats;
                }
              } catch (e) {
                // ignore closed controller
              }
            });
            // Schedule a follow-up refresh after a short delay to pick up
            // the location that should have synced by then.
            Future.delayed(const Duration(seconds: 3), () {
              if (!ref.mounted) return;
              if (supabase.auth.currentSession == null) return;
              fetchStats(useCache: false, saveToCache: false).then((stats) {
                try {
                  if (!_sameDashboardStats(stats, lastEmittedStats)) {
                    controller.add(stats);
                    lastEmittedStats = stats;
                  }
                } catch (e) {
                  // ignore closed controller
                }
              });
            });
          },
        )
        .subscribe((status, err) {
          if (handleExpectedSupabaseOfflineFailure(err)) {
            return;
          }
          if (SupabaseRealtimeManager.instance.isPaused) return;
          if (err != null) {
            debugPrint('Visibility channel status: $status, error: $err');
          }
        });
    return visibilityChannel!;
  });

  // Subscribe to user_locations table for location changes that affect nearby count
  final locationChannelName = 'dashboard_stats_location_$userId';
  RealtimeChannel? locationChannel;
  SupabaseRealtimeManager.instance.register(locationChannelName, () {
    locationChannel = supabase
        .channel(locationChannelName)
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_locations',
          callback: (payload) {
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final oldRecord = payload.oldRecord as Map<String, dynamic>?;
            final changedUserId =
                (newRecord?['user_id'] ?? oldRecord?['user_id']) as String?;

            if (changedUserId == null || changedUserId == userId) return;

            debugPrint(
              'Another user location changed - refreshing nearby count',
            );
            if (!ref.mounted) return;
            if (supabase.auth.currentSession == null) {
              debugPrint(
                'fetchStats skipped in location callback: No valid session',
              );
              return;
            }
            fetchStats(useCache: false, saveToCache: false).then((stats) {
              try {
                if (!_sameDashboardStats(stats, lastEmittedStats)) {
                  controller.add(stats);
                  lastEmittedStats = stats;
                }
              } catch (e) {
                // ignore closed controller
              }
            });
          },
        )
        .subscribe((status, err) {
          if (handleExpectedSupabaseOfflineFailure(err)) {
            return;
          }
          if (SupabaseRealtimeManager.instance.isPaused) return;
          if (err != null) {
            debugPrint('Location channel status: $status, error: $err');
          }
        });
    return locationChannel!;
  });

  // Subscribe to user_activity table for online status changes
  // This ensures the online count updates immediately when users come online/offline
  // Filter out own user_activity changes server-side to avoid wasted processing
  final activityChannelName = 'dashboard_stats_activity_$userId';
  RealtimeChannel? activityChannel;
  SupabaseRealtimeManager.instance.register(activityChannelName, () {
    activityChannel = supabase
        .channel(activityChannelName)
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'user_activity',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.neq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            if (payload.commitTimestamp == lastActivityCommitTimestamp) {
              return;
            }
            lastActivityCommitTimestamp = payload.commitTimestamp;

            debugPrint(
              '🔄 [REALTIME] user_activity INSERT event received: $payload',
            );
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final changedUserId = newRecord?['user_id'] as String?;

            debugPrint(
              '🔄 [REALTIME] Changed user ID: $changedUserId, My user ID: $userId',
            );
            if (changedUserId == null || changedUserId == userId) {
              debugPrint(
                '🔄 [REALTIME] Skipping - changed user is null or is me',
              );
              return;
            }

            if (!shouldRefreshForActivityChange(
              changedUserId: changedUserId,
              newRecord: newRecord,
            )) {
              debugPrint('🔄 [REALTIME] Skipping - activity data unchanged');
              return;
            }

            debugPrint(
              '🔄 [REALTIME] Another user activity changed - refreshing online count',
            );
            if (!ref.mounted) return;
            if (supabase.auth.currentSession == null) {
              debugPrint(
                'fetchStats skipped in activity callback: No valid session',
              );
              return;
            }
            fetchStats(useCache: false, saveToCache: false).then((stats) {
              try {
                if (!_sameDashboardStats(stats, lastEmittedStats)) {
                  controller.add(stats);
                  lastEmittedStats = stats;
                }
              } catch (e) {
                // ignore closed controller
              }
            });
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_activity',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.neq,
            column: 'user_id',
            value: userId,
          ),
          callback: (payload) {
            if (payload.commitTimestamp == lastActivityCommitTimestamp) {
              return;
            }
            lastActivityCommitTimestamp = payload.commitTimestamp;

            debugPrint(
              '🔄 [REALTIME] user_activity UPDATE event received: $payload',
            );
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final oldRecord = payload.oldRecord as Map<String, dynamic>?;
            final changedUserId =
                (newRecord?['user_id'] ?? oldRecord?['user_id']) as String?;

            debugPrint(
              '🔄 [REALTIME] Changed user ID: $changedUserId, My user ID: $userId',
            );
            if (changedUserId == null || changedUserId == userId) {
              debugPrint(
                '🔄 [REALTIME] Skipping - changed user is null or is me',
              );
              return;
            }

            if (!shouldRefreshForActivityChange(
              changedUserId: changedUserId,
              newRecord: newRecord,
              oldRecord: oldRecord,
            )) {
              debugPrint('🔄 [REALTIME] Skipping - activity data unchanged');
              return;
            }

            userActivityDebounceTimer?.cancel();
            userActivityDebounceTimer = Timer(
              const Duration(milliseconds: 500),
              () {
                debugPrint(
                  '🔄 [REALTIME] Another user activity updated - refreshing online count (debounced)',
                );
                if (!ref.mounted) return;
                if (supabase.auth.currentSession == null) {
                  debugPrint(
                    'fetchStats skipped in activity update callback: No valid session',
                  );
                  return;
                }
                fetchStats(useCache: false, saveToCache: false).then((stats) {
                  try {
                    if (!_sameDashboardStats(stats, lastEmittedStats)) {
                      controller.add(stats);
                      lastEmittedStats = stats;
                    }
                  } catch (e) {
                    // ignore closed controller
                  }
                });
              },
            );
          },
        )
        .subscribe((status, err) {
          if (handleExpectedSupabaseOfflineFailure(err)) {
            return;
          }
          if (SupabaseRealtimeManager.instance.isPaused) return;
          if (err != null) {
            debugPrint(
              '🔄 [REALTIME] Activity channel status: $status, error: $err',
            );
          }
        });
    return activityChannel!;
  });

  // Listen to connectivity changes and force refresh when coming back online
  StreamSubscription? connectivitySubscription;
  ConnectivityHealthStatus? lastConnectivityStatus;
  connectivitySubscription = listenConnectivityChanged((_) async {
    if (!ref.mounted || controller.isClosed) return;

    // Check current connectivity health
    final currentHealth = await ref.read(connectivityHealthProvider.future);
    if (currentHealth.status != lastConnectivityStatus) {
      if (lastConnectivityStatus == ConnectivityHealthStatus.offline &&
          currentHealth.status == ConnectivityHealthStatus.online) {
        debugPrint(
          '🌐 Dashboard stats: Device came back online - forcing refresh',
        );
        if (supabase.auth.currentSession == null) {
          debugPrint(
            'fetchStats skipped in connectivity callback: No valid session',
          );
          return;
        }
        fetchStats(useCache: false, saveToCache: false, force: true).then((
          stats,
        ) {
          try {
            if (!_sameDashboardStats(stats, lastEmittedStats)) {
              controller.add(stats);
              lastEmittedStats = stats;
            }
          } catch (_) {
            // ignore closed controller
          }
        });
      }
      lastConnectivityStatus = currentHealth.status;
    }
  });

  // Set up periodic refresh as a fallback. Realtime updates above remain the
  // primary path for visible dashboard changes; this timer only covers missed
  // websocket events or stale local cache.
  // The cron job now handles setting is_online=false for stale users (triggers real-time events)
  // This timer is just a safety net for edge cases (e.g., cron job delays, missed real-time events)
  Timer? cacheRefreshTimer;
  (() async {
    const minRevalidationSeconds = 300;
    final configuredRevalidationSeconds = await (() async {
      try {
        return await appConfigService.getInt(
          'ui.home_revalidation_seconds',
          defaultValue: minRevalidationSeconds,
        );
      } catch (e) {
        return minRevalidationSeconds;
      }
    })();
    final revalidationSeconds = max(
      configuredRevalidationSeconds,
      minRevalidationSeconds,
    );
    if (configuredRevalidationSeconds < minRevalidationSeconds && kDebugMode) {
      debugPrint(
        '📊 Dashboard stats: Clamped revalidation from '
        '${configuredRevalidationSeconds}s to ${revalidationSeconds}s',
      );
    }
    if (!ref.mounted) return;
    cacheRefreshTimer = Timer.periodic(Duration(seconds: revalidationSeconds), (
      _,
    ) {
      if (!controller.isClosed && ref.mounted) {
        // Skip if no valid session
        if (supabase.auth.currentSession == null) {
          debugPrint(
            'fetchStats skipped in cache refresh timer: No valid session',
          );
          return;
        }

        // Refresh cache with fresh data from server and emit if changed
        fetchStats(useCache: false, saveToCache: false).then((stats) {
          try {
            // Emit to stream if stats have changed
            if (!_sameDashboardStats(stats, lastEmittedStats)) {
              controller.add(stats);
              lastEmittedStats = stats;
            }
          } catch (e) {
            // ignore closed controller
          }
        });
      }
    });
  })();

  ref.onDispose(() {
    disposeResumeListener();
    SupabaseRealtimeManager.instance.unregister(visibilityChannelName);
    SupabaseRealtimeManager.instance.unregister(locationChannelName);
    SupabaseRealtimeManager.instance.unregister(activityChannelName);
    periodicRefreshTimer?.cancel();
    cacheRefreshTimer?.cancel();
    userActivityDebounceTimer?.cancel();
    connectivitySubscription?.cancel();
    if (kIsWeb) {
      WebLocationService.onLocationSynced = null;
    }
    if (identical(
      SessionService.onSessionRegistered,
      onSessionRegisteredHandler,
    )) {
      SessionService.onSessionRegistered = null;
    }
    controller.close();
  });

  return controller.stream;
});

// Total unread chat count provider
// Uses ref.listen instead of ref.watch to avoid triggering invalidateSelf
// during the TickerMode resume flow, which causes a Riverpod reentrancy
// assertion (pause-count mismatch) when recentChatsProvider is resumed.
class TotalUnreadChatCountNotifier extends Notifier<int> {
  @override
  int build() {
    final userId = supabase.auth.currentUser?.id ?? '';
    final chatsAsync = ref.read(recentChatsProvider(userId));
    final initialValue = chatsAsync.asData?.value ?? [];
    final initial = initialValue.where((chat) => chat.unreadCount > 0).length;

    ref.listen(recentChatsProvider(userId), (prev, next) {
      final chats = next.value ?? [];
      final count = chats.where((chat) => chat.unreadCount > 0).length;
      if (count != state) {
        Future.microtask(() => state = count);
      }
    });

    return initial;
  }
}

final totalUnreadChatCountProvider =
    NotifierProvider<TotalUnreadChatCountNotifier, int>(
      TotalUnreadChatCountNotifier.new,
    );

// Navigation index notifier
class NavigationIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void setIndex(int index) {
    state = index;
  }
}

// Navigation index provider
final navigationIndexProvider = NotifierProvider<NavigationIndexNotifier, int>(
  () {
    return NavigationIndexNotifier();
  },
);

/// The user id whose navigation context has already been initialised this
/// process, or null if none has been.
///
/// [MainNavigationScreen] resets the tab to Home in `initState`. Its State is
/// destroyed and recreated whenever `ProfileCheckScreen` re-renders it from a
/// different position in the tree (it is emitted both as a direct child of the
/// screen switch and nested inside a `FutureBuilder` fallback), which happens
/// whenever the profile future re-resolves - for example during the transient
/// session churn of a calendar OAuth. That reset is what threw the user back to
/// the Home tab mid-task.
///
/// Recording the user here, outside the widget State, makes the reset happen
/// once per user per process instead of once per State instance: a genuine cold
/// start still lands on Home, and so does an account switch, but re-entering
/// the shell for the same user preserves the tab they were on.
class NavigationContextInitNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  bool isInitialisedFor(String? userId) =>
      userId != null && userId.isNotEmpty && state == userId;

  void markInitialisedFor(String userId) => state = userId;

  void reset() => state = null;
}

final navigationContextInitProvider =
    NotifierProvider<NavigationContextInitNotifier, String?>(
      () => NavigationContextInitNotifier(),
    );

// Global app resume tracker for preventing unnecessary reloads
class AppResumeNotifier extends Notifier<DateTime?> {
  DateTime? _resumeTime;
  bool _hasLoadedAdsOnce = false;

  @override
  DateTime? build() => _resumeTime;

  void markResumed() {
    _resumeTime = DateTime.now();
    state = _resumeTime;
    // Clear the resume flag after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      _resumeTime = null;
      state = null;
    });
  }

  bool shouldSkipAdLoad() {
    // Never skip on first load
    if (!_hasLoadedAdsOnce) {
      _hasLoadedAdsOnce = true;
      return false;
    }

    if (_resumeTime == null) return false;
    // Skip ad loads if resume was less than 3 seconds ago
    return DateTime.now().difference(_resumeTime!).inSeconds < 3;
  }
}

final appResumeNotifierProvider =
    NotifierProvider<AppResumeNotifier, DateTime?>(AppResumeNotifier.new);

// Activity update provider - updates user activity when accessed
final activityUpdateProvider = Provider.autoDispose<void>((ref) {
  final user = supabase.auth.currentUser;
  if (user != null && !shouldSkipSupabaseCalls()) {
    UserActivityService.instance.pingIfDue(
      user.id,
      source: 'activity-update-provider',
    );
  }
});

// Potential matches provider - fetches users that could be matches
// Uses server-side get_potential_matches RPC for distance computation,
// match exclusion, and radius filtering — no client-side Haversine needed.
final potentialMatchesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final user = supabase.auth.currentUser;
      if (user == null) return [];

      try {
        // Get current user's location and settings
        final userResponse = await supabase
            .from('users')
            .select('match_radius_default')
            .eq('id', user.id)
            .single();

        final userRadiusMeters =
            (userResponse['match_radius_default'] as int?) ?? 50000;
        final matchRadiusKm = (userRadiusMeters / 1000.0);

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

        // Call server-side RPC that handles: distance calc, match exclusion, radius filter, sorting
        final response = await supabase.rpc(
          'get_potential_matches',
          params: {
            'p_user_id': user.id,
            'p_latitude': userLat,
            'p_longitude': userLng,
            'p_radius_km': matchRadiusKm,
          },
        );

        final rawList = response as List<dynamic>? ?? [];
        final potentialMatches = rawList.map((item) {
          final row = item as Map<String, dynamic>;
          return {
            'id': row['user_id'],
            'display_name': row['display_name'],
            'profile_data': row['profile_data'],
            'distance': row['distance_km'],
            'location': {
              'latitude': row['latitude'],
              'longitude': row['longitude'],
            },
          };
        }).toList();

        return potentialMatches;
      } catch (e) {
        debugPrint('Error fetching potential matches: $e');
        return [];
      }
    });

// --- userChatIdsProvider ---
// Returns a set of match IDs that have chats for the given user
final userChatIdsProvider = StreamProvider.autoDispose.family<Set<String>, String>(
  (ref, userId) {
    if (userId.isEmpty) {
      return Stream.value(<String>{});
    }

    final localDb = ref.watch(localDbProvider);
    final localStream = localDb.watchChats(userId);

    return localStream
        .map((chats) {
          return chats
              .map((chat) => chat['match_id'] as String?)
              .whereType<String>()
              .toSet();
          // Suppress emissions when the id set is unchanged. Every Hive chat
          // write (e.g. a re-sync after window focus) otherwise produced a new
          // Set instance — and `Set.==` is identity-based — rebuilding the home
          // screen (which watches this provider twice) for no visible change.
        })
        .distinct((prev, next) {
          if (identical(prev, next)) return true;
          if (prev.length != next.length) return false;
          return prev.containsAll(next);
        });
  },
);

// --- matchExpiryNowProvider ---
// Provides the current DateTime for calculating match expiry countdown
// Updates every second to keep countdown timers accurate
final matchExpiryNowProvider = StreamProvider<DateTime>((ref) {
  final controller = StreamController<DateTime>();

  // Emit current time immediately
  controller.add(DateTime.now());

  // Update every second
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (!controller.isClosed) {
      controller.add(DateTime.now());
    }
  });

  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });

  return controller.stream;
});

final matchChatStartExpiryWarningProvider =
    NotifierProvider<MatchChatStartExpiryWarningNotifier, Object?>(() {
      return MatchChatStartExpiryWarningNotifier();
    });

class MatchChatStartExpiryWarningNotifier extends Notifier<Object?> {
  List<MatchModel> _matches = const [];
  Set<String> _chatIds = const <String>{};
  LocalizationState? _l10n;
  DateTime? _now;

  bool _checkScheduled = false;
  bool _checkInProgress = false;

  List<Duration> _warningThresholds = const [Duration(minutes: 60)];
  DateTime? _warningThresholdsFetchedAt;

  final Set<String> _notifiedThisSession = <String>{};
  final Set<String> _checkInFlightMatchIds = <String>{};

  @override
  Object? build() {
    final userId = supabase.auth.currentUser?.id ?? '';
    if (userId.isEmpty) return null;

    ref.listen<AsyncValue<List<MatchModel>>>(recentMatchesProvider(userId), (
      previous,
      next,
    ) {
      _matches = next.asData?.value ?? const [];
      _scheduleCheck();
    });

    ref.listen<AsyncValue<Set<String>>>(userChatIdsProvider(userId), (
      previous,
      next,
    ) {
      _chatIds = next.asData?.value ?? const <String>{};
      _scheduleCheck();
    });

    ref.listen<LocalizationState>(localizationProvider, (previous, next) {
      _l10n = next;
      _scheduleCheck();
    });

    ref.listen<AsyncValue<DateTime>>(matchExpiryNowProvider, (previous, next) {
      final v = next.asData?.value;
      if (v != null) {
        _now = v;
        _scheduleCheck();
      }
    });

    Future.microtask(_scheduleCheck);

    return null;
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    Future.microtask(() async {
      _checkScheduled = false;
      await _checkForWarnings();
    });
  }

  Future<List<Duration>> _getWarningThresholds(DateTime now) async {
    final last = _warningThresholdsFetchedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return _warningThresholds;
    }

    _warningThresholdsFetchedAt = now;
    final configured = await appConfigService.getDurationList(
      'matches.chat_start_expiry_warning_seconds',
      defaultValue: const [Duration(minutes: 60)],
    );

    final cleaned = configured.where((d) => d > Duration.zero).toSet().toList()
      ..sort((a, b) => a.inSeconds.compareTo(b.inSeconds));
    _warningThresholds = cleaned.isEmpty
        ? const [Duration(minutes: 60)]
        : cleaned;
    return _warningThresholds;
  }

  Future<String?> _getCachedOtherUserName(
    LocalDbService localDb,
    String otherUserId,
  ) async {
    if (otherUserId.trim().isEmpty) return null;
    try {
      final cached = await localDb.getOtherUserProfile(otherUserId);
      if (cached == null) return null;
      final raw =
          (cached['name'] ??
                  cached['display_name'] ??
                  cached['displayName'] ??
                  '')
              .toString();
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return formatSenderNameForNotification(trimmed);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveOtherUserName(
    LocalDbService localDb,
    String otherUserId,
  ) async {
    final cached = await _getCachedOtherUserName(localDb, otherUserId);
    if (cached != null && cached.trim().isNotEmpty) return cached;

    try {
      final profile = await ref.read(
        otherUserProfileProvider(otherUserId).future,
      );
      final raw = profile?.name.toString() ?? '';
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      return formatSenderNameForNotification(trimmed);
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkForWarnings() async {
    if (_checkInProgress) return;
    _checkInProgress = true;

    try {
      final l10n = _l10n;
      if (l10n == null) return;

      final userId = supabase.auth.currentUser?.id ?? '';
      if (userId.isEmpty) return;

      final matches = _matches;
      if (matches.isEmpty) return;

      final now = _now ?? DateTime.now();
      final thresholds = await _getWarningThresholds(now);
      final startThreshold = thresholds.isEmpty
          ? const Duration(minutes: 60)
          : thresholds.last;

      final localDb = ref.read(localDbProvider);
      final prefs = await SharedPreferences.getInstance();

      for (final match in matches) {
        final matchId = match.id.trim();
        if (matchId.isEmpty) continue;

        if (_chatIds.contains(matchId)) {
          // Chat started: OS-scheduled countdown is obsolete.
          unawaited(ExpiryLocalScheduleService.cancelForMatch(matchId));
          continue;
        }

        final remaining = match.remainingFrom(now);
        if (remaining <= Duration.zero) {
          unawaited(ExpiryLocalScheduleService.cancelForMatch(matchId));
          continue;
        }
        if (remaining > startThreshold) continue;

        // OS-scheduled backup alarms so the countdown fires even when the
        // isolate is dead (killed app, stale FCM token, Doze). Fire times in
        // the past are skipped; the immediate path below handles "now".
        // Cached name keeps this scan cheap (no network per match).
        final expiresAt = match.effectiveExpiresAt;
        try {
          final cachedName = await _getCachedOtherUserName(
            localDb,
            match.otherUserId,
          );
          final schedName = (cachedName == null || cachedName.trim().isEmpty)
              ? l10n.getString('generalUnknown')
              : firstTokenName(cachedName);
          unawaited(
            ExpiryLocalScheduleService.syncMatchExpiry(
              matchId: matchId,
              expiryAt: expiresAt,
              thresholds: thresholds,
              titleFor: (minutesLeft) => l10n.getString(
                'matchExpiryTitle',
                params: {'count': minutesLeft.toString()},
              ),
              bodyFor: (minutesLeft) => l10n.getString(
                'matchExpiryBody',
                params: {
                  'count': minutesLeft.toString(),
                  'otherUserName': schedName,
                },
              ),
            ),
          );
        } catch (_) {}

        Duration? thresholdToSend;
        for (final t in thresholds) {
          if (remaining <= t) {
            thresholdToSend = t;
            break;
          }
        }
        if (thresholdToSend == null) continue;

        // Include the exact expiry timestamp in dedup keys so that
        // after an extension (which moves expiry forward) the same
        // threshold can fire again for the new expiry window.
        // This fixes the "no notification after extend" bug.
        // (expiresAt computed above for the OS-scheduled backup alarms.)
        final expiryKey = expiresAt.millisecondsSinceEpoch.toString();
        const templateVersion = 'match_expiry_minutes_v2';
        final sessionKey =
            '$matchId:${thresholdToSend.inSeconds}:$expiryKey:$templateVersion';
        if (_notifiedThisSession.contains(sessionKey)) continue;
        if (_checkInFlightMatchIds.contains(matchId)) continue;
        _checkInFlightMatchIds.add(matchId);

        try {
          final prefsKey =
              'match_chat_start_expiry_warned_${matchId}_${thresholdToSend.inSeconds}_${expiryKey}_$templateVersion';
          final alreadyNotified = prefs.getBool(prefsKey) ?? false;
          if (alreadyNotified) {
            _notifiedThisSession.add(sessionKey);
            continue;
          }

          await prefs.setBool(prefsKey, true);
          _notifiedThisSession.add(sessionKey);

          final otherName = await _resolveOtherUserName(
            localDb,
            match.otherUserId,
          );
          final minutesLeft = max(1, (remaining.inSeconds / 60).ceil());
          final otherUserName = (otherName == null || otherName.trim().isEmpty)
              ? l10n.getString('generalUnknown')
              : firstTokenName(otherName);

          final title = l10n.getString(
            'matchExpiryTitle',
            params: {'count': minutesLeft.toString()},
          );
          final body = l10n.getString(
            'matchExpiryBody',
            params: {
              'count': minutesLeft.toString(),
              'otherUserName': otherUserName,
            },
          );

          if (kIsWeb) {
            await WebNotificationService.showMatchNotification(
              matchId: matchId,
              matchName: otherUserName,
              matchPhotoUrl: '',
            );
          } else {
            await MobileLocalNotificationService.showMatchExpiryNotification(
              matchId: matchId,
              title: title,
              body: body,
              notificationKey:
                  'chat_start_expiry_${thresholdToSend.inSeconds}_${expiryKey}_$templateVersion',
            );
          }
        } catch (_) {
        } finally {
          _checkInFlightMatchIds.remove(matchId);
        }
      }
    } finally {
      _checkInProgress = false;
    }
  }
}

// Helper functions for language detection
bool _looksLikeEmoji(String grapheme) {
  return RegExp(
    r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}]',
    unicode: true,
  ).hasMatch(grapheme);
}

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
