// lib/services/offline_cache_manager.dart
// Service for managing comprehensive offline caching and fallback data strategy
// Provides cached data when Supabase is unavailable

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show imageCache;
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/services/calendar_sync_service.dart';
import 'package:matchme/services/offline_mutation_queue.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Manages offline-first caching and provides fallback data
class OfflineCacheManager {
  static final OfflineCacheManager _instance = OfflineCacheManager._internal();
  static const Duration _transientFailureGracePeriod = Duration(seconds: 20);
  static const int _requiredConsecutiveUnavailableSignals = 4;

  /// Get the singleton instance of OfflineCacheManager
  static OfflineCacheManager get instance => _instance;

  factory OfflineCacheManager() => _instance;

  OfflineCacheManager._internal();

  SupabaseClient get _supabase => Supabase.instance.client;
  bool _isSupabaseAvailable = true;
  bool _forceOnline = false;
  DateTime? _lastSupabaseCheckTime;
  DateTime? _lastSupabaseAvailableAt = DateTime.now();
  DateTime? _pendingUnavailableSince;
  int _consecutiveUnavailableSignals = 0;
  DateTime? _lastResumedAt;

  /// Fired when availability actually flips (true <-> false). Lets providers
  /// rebuild without polling the non-reactive singleton.
  void Function(bool available)? onAvailabilityChanged;

  /// Resume grace window: a forced offline verdict arriving right after the
  /// app returns to the foreground is almost always a half-dead socket or a
  /// cold DNS/TLS handshake, not a real outage.
  static const Duration _resumeGracePeriod = Duration(seconds: 12);

  void noteAppResumed() {
    _lastResumedAt = DateTime.now();
  }

  /// Check if Supabase is currently available
  bool get isSupabaseAvailable => _forceOnline || _isSupabaseAvailable;

  /// Force the manager to report as online regardless of actual state.
  /// Used when High Accuracy mode is enabled – the app should never appear offline.
  /// When we are in a hard offline state (no transport / internet probe failed),
  /// don't immediately force online — let the connectivity probe restore it.
  void setForceOnline(bool enabled) {
    if (enabled == _forceOnline) return;
    if (enabled) {
      if (!_isSupabaseAvailable) {
        // Hard offline (airplane / dead carrier) — keep offline until
        // connectivity actually recovers, otherwise every provider sees
        // isSupabaseAvailable==true and spams Failed host lookup.
        return;
      }
      _forceOnline = true;
      _pendingUnavailableSince = null;
      _consecutiveUnavailableSignals = 0;
      _applyAvailability(true, DateTime.now());
    } else {
      _forceOnline = false;
    }
  }

  /// Set the Supabase availability status (used by connectivity monitoring)
  void setSupabaseAvailability(bool available, {bool force = false}) {
    final now = DateTime.now();
    // Don't spam log when already in desired state (common during wifi toggle storm)
    final alreadyInState = !force
        ? available == _isSupabaseAvailable
        : available == _isSupabaseAvailable && (!available || !_forceOnline);
    if (alreadyInState && !force) {
      return;
    }
    if (alreadyInState && force && available == _isSupabaseAvailable) {
      // For force=false->false with _forceOnline already false, nothing to do
      // For force=true with _forceOnline true and available false, we still need to clear _forceOnline
      if (available == false && _forceOnline) {
        // Will clear forceOnline below, so don't return
      } else {
        return;
      }
    }
    _lastSupabaseCheckTime = now;
    final stack = StackTrace.current.toString().split('\n').take(5).join(' | ');
    debugPrint(
      '⏱️ [BOOTSTRAP] setSupabaseAvailability called: $available force=$force current=$_isSupabaseAvailable forceOnline=$_forceOnline stack=$stack',
    );

    if (force) {
      // Guard: forced offline during the resume grace window is converted to a
      // normal (grace + streak) signal so one realtime/HTTP error on wake
      // cannot flip the app offline.
      if (!available &&
          _lastResumedAt != null &&
          now.difference(_lastResumedAt!) < _resumeGracePeriod) {
        debugPrint(
          '🌐 [OFFLINE] Suppressing forced-offline during resume grace '
          '(${now.difference(_lastResumedAt!).inSeconds}s since resume)',
        );
        force = false;
      } else {
        _pendingUnavailableSince = null;
        _consecutiveUnavailableSignals = 0;
        _applyAvailability(available, now);
        return;
      }
    }

    if (available) {
      _pendingUnavailableSince = null;
      _consecutiveUnavailableSignals = 0;
      _applyAvailability(true, now);
      return;
    }

    if (!_isSupabaseAvailable) {
      return;
    }

    _pendingUnavailableSince ??= now;
    _consecutiveUnavailableSignals += 1;

    final graceElapsed =
        _lastSupabaseAvailableAt == null ||
        now.difference(_lastSupabaseAvailableAt!) >=
            _transientFailureGracePeriod;
    final enoughSignals =
        _consecutiveUnavailableSignals >=
        _requiredConsecutiveUnavailableSignals;

    if (graceElapsed && enoughSignals) {
      _applyAvailability(false, now);
      return;
    }

    debugPrint(
      '🌐 [OFFLINE] Ignoring transient Supabase failure '
      '($_consecutiveUnavailableSignals/$_requiredConsecutiveUnavailableSignals, '
      'graceElapsed=$graceElapsed)',
    );
    debugPrint(
      '⏱️ [BOOTSTRAP] Ignoring transient failure $available (x/$_consecutiveUnavailableSignals grace=$graceElapsed)',
    );
  }

  void _applyAvailability(bool available, DateTime timestamp) {
    final wasUnavailable = !_isSupabaseAvailable;
    final oldValue = _isSupabaseAvailable;
    if (available != _isSupabaseAvailable) {
      debugPrint(
        '🌐 [OFFLINE] Supabase availability changed: '
        '$oldValue -> $available',
      );
      // Also log with BOOTSTRAP prefix so it passes main.dart debugPrint filter
      debugPrint(
        '⏱️ [BOOTSTRAP] OFFLINE availability $oldValue -> $available (forceOnline=$_forceOnline)',
      );
      try {
        onAvailabilityChanged?.call(available);
      } catch (e) {
        debugPrint('⚠️ [OFFLINE] onAvailabilityChanged error: $e');
      }
    }
    _isSupabaseAvailable = available;
    _lastSupabaseCheckTime = timestamp;
    if (available) {
      _lastSupabaseAvailableAt = timestamp;
      // Notify that Supabase is now available again - trigger resume callbacks
      if (wasUnavailable) {
        _triggerResumeCallbacks();
      }
    } else {
      // Going offline — ensure forceOnline doesn't mask offline
      // even if High Accuracy was previously enabled.
      if (_forceOnline) {
        debugPrint(
          '🌐 [OFFLINE] Clearing forceOnline due to offline transition',
        );
      }
      _forceOnline = false;
      if (oldValue && !available) {
        try {
          SupabaseRealtimeManager.instance.pauseAll();
        } catch (_) {}
      }
    }
  }

  /// Trigger all registered resume callbacks when Supabase becomes available
  void _triggerResumeCallbacks() {
    try {
      scheduleMicrotask(() {
        try {
          notifySupabaseResumed();
        } catch (e) {
          debugPrint('⚠️ [OFFLINE] Error in resume callback trigger: $e');
        }
      });
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Error scheduling resume callbacks: $e');
    }
  }

  /// Check if we should consider Supabase as unavailable based on cached status
  bool shouldUseCachedData() {
    return !_isSupabaseAvailable;
  }

  /// Get cached user profile for offline display
  Future<Map<String, dynamic>?> getCachedUserProfile(String userId) async {
    try {
      final localDb = await LocalDbService.instance;
      return await localDb.loadProfile(userId);
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached profile: $e');
      return null;
    }
  }

  /// Get cached recent matches for offline display
  Future<List<Map<String, dynamic>>> getCachedRecentMatches(
    String userId,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      final matches = await localDb.watchMatches(userId).first;
      return matches;
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached matches: $e');
      return [];
    }
  }

  /// Get cached recent chats for offline display
  Future<List<Map<String, dynamic>>> getCachedRecentChats(String userId) async {
    try {
      final localDb = await LocalDbService.instance;
      final chats = await localDb.loadChats(userId);
      return chats ?? [];
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached chats: $e');
      return [];
    }
  }

  /// Get cached chat messages for offline display
  Future<List<Map<String, dynamic>>> getCachedChatMessages(
    String matchId,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      final messages = await localDb.loadMessages(matchId);
      return messages ?? [];
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached messages: $e');
      return [];
    }
  }

  /// Get cached user events for offline display
  Future<List<Map<String, dynamic>>> getCachedUserEvents(String userId) async {
    try {
      final localDb = await LocalDbService.instance;
      final events = await localDb.getCachedUserEvents(userId);
      return events ?? [];
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached events: $e');
      return [];
    }
  }

  /// Get cached online count for status display
  /// Falls back to a reasonable default when unavailable
  Future<int> getCachedOnlineCount() async {
    try {
      final localDb = await LocalDbService.instance;
      final count = await localDb.getLastKnownOnlineCount();
      return count ?? 0;
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to load cached online count: $e');
      return 0;
    }
  }

  /// Cache the current online count for later use
  Future<void> cacheOnlineCount(int count) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveLastKnownOnlineCount(count);
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache online count: $e');
    }
  }

  /// Cache user data for offline use
  Future<void> cacheUserData(
    String userId,
    Map<String, dynamic> userData,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveProfile(userId, userData);
      debugPrint('✅ [OFFLINE] Cached user data');
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache user data: $e');
    }
  }

  /// Cache match data for offline use
  Future<void> cacheMatches(
    String userId,
    List<Map<String, dynamic>> matches,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveMatches(userId, matches);
      debugPrint('✅ [OFFLINE] Cached ${matches.length} matches');
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache matches: $e');
    }
  }

  /// Cache chat data for offline use
  Future<void> cacheChatData(
    String userId,
    List<Map<String, dynamic>> chats,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveChats(userId, chats);
      debugPrint('✅ [OFFLINE] Cached ${chats.length} chats');
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache chat data: $e');
    }
  }

  /// Cache individual chat messages for offline use
  Future<void> cacheMessages(
    String matchId,
    List<Map<String, dynamic>> messages,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveMessages(matchId, messages);
      debugPrint(
        '✅ [OFFLINE] Cached ${messages.length} messages for match $matchId',
      );
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache messages: $e');
    }
  }

  /// Cache events for offline use
  Future<void> cacheUserEvents(
    String userId,
    List<Map<String, dynamic>> events,
  ) async {
    try {
      final localDb = await LocalDbService.instance;
      await localDb.saveCachedUserEvents(userId, events);
      debugPrint('✅ [OFFLINE] Cached ${events.length} events');
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to cache events: $e');
    }
  }

  /// Get a user's display name from cache
  Future<String?> getCachedUserDisplayName(String userId) async {
    try {
      final profile = await getCachedUserProfile(userId);
      if (profile != null) {
        return (profile['profile_name'] as String?) ?? 'User';
      }
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to get cached display name: $e');
    }
    return null;
  }

  /// Get a user's profile photo from cache
  Future<String?> getCachedUserProfilePhoto(String userId) async {
    try {
      final profile = await getCachedUserProfile(userId);
      if (profile != null) {
        return profile['profilePhotoUrl'] as String?;
      }
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to get cached profile photo: $e');
    }
    return null;
  }

  /// Clear offline cache on logout (previously a no-op that only logged).
  ///
  /// Strict but non-breaking: wipes the signed-out user's session data via
  /// LocalDbService.clearUserData, clears in-memory image cache, and removes
  /// sensitive SharedPreferences keys. Server data is untouched and re-syncs
  /// on next login. Pass [wipeAllUsers] (account deletion) to clearDatabase().
  Future<void> clearAllOfflineCache({
    bool wipeAllUsers = false,
    String? userId,
  }) async {
    try {
      final outgoingUserId = userId ?? _supabase.auth.currentUser?.id;
      final localDb = await LocalDbService.instance;
      if (wipeAllUsers) {
        await localDb.clearDatabase();
      } else if (outgoingUserId != null && outgoingUserId.isNotEmpty) {
        await localDb.clearUserData(outgoingUserId);
      } else {
        throw StateError(
          'Cannot clear account cache without the outgoing user ID.',
        );
      }
      // In-memory image cache (profile photos) must not survive logout.
      imageCache.clear();
      imageCache.clearLiveImages();
      try {
        await OfflineImageCache.instance.clear();
      } catch (error) {
        debugPrint('⚠️ [OFFLINE] Failed to clear cached image bytes: $error');
      }
      // Sensitive prefs shim for native service (tokens/location key).
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_id');
      await prefs.remove('was_logged_in');
      await prefs.remove('flutter.user_token');
      await prefs.remove('flutter.refresh_token');
      await prefs.remove('flutter.location_share_session_key');
      await prefs.remove('flutter.location_share_match_id');
      await prefs.remove('flutter.location_share_other_user_id');
      await prefs.remove('flutter.location_share_interval');
      await prefs.remove('flutter.location_share_expires_at');
      await prefs.remove('oauth_original_session_json');
      await prefs.remove('oauth_original_user_id');
      // Translation mirrors are keyed by message ID, not account.
      final chatTranslationKeys = prefs
          .getKeys()
          .where((key) => key.startsWith('chat_translation:'))
          .toList();
      for (final key in chatTranslationKeys) {
        await prefs.remove(key);
      }
      final translationStateKeys = prefs
          .getKeys()
          .where((key) => key.startsWith('translation_states'))
          .toList();
      for (final key in translationStateKeys) {
        await prefs.remove(key);
      }
      await StorageHelper.clearSessionCache();
      await CalendarSyncService.clearPersistedCalendarCredentials();
      // Wipe user-scoped SecureStorage keys (offline chat-cache DCK, native
      // encrypted copies) so the signed-out user's secrets don't persist.
      final secure = SecureStorageService.instance;
      if (outgoingUserId != null && outgoingUserId.isNotEmpty) {
        EncryptedCacheService.instance.clearMemoryCache(
          userId: outgoingUserId,
        );
        await secure.delete('chat_cache_key:$outgoingUserId');
      }
      await secure.delete('oauth_original_session_json');
      await secure.delete('oauth_original_user_id');
      HiveEncryptionService.instance.clearCache();
      debugPrint(
        '[OFFLINE] Cleared offline cache for user '
        '${outgoingUserId ?? 'all users'}',
      );
    } catch (e) {
      debugPrint('[OFFLINE] Failed to clear offline cache: $e');
      rethrow;
    }
  }

  /// Get statistics about cached data
  Future<OfflineCacheStats> getCacheStats() async {
    try {
      final userId = _supabase.auth.currentUser?.id;
      final matchesList = userId != null
          ? await getCachedRecentMatches(userId)
          : [];
      int chatCount = 0;
      int messageCount = 0;

      if (userId != null) {
        final chats = await getCachedRecentChats(userId);
        chatCount = chats.length;

        for (final chat in chats) {
          final matchId = chat['match_id'] as String?;
          if (matchId != null) {
            final messages = await getCachedChatMessages(matchId);
            messageCount += messages.length;
          }
        }
      }

      return OfflineCacheStats(
        cachedMatches: matchesList.length,
        cachedChats: chatCount,
        cachedMessages: messageCount,
        lastCheckTime: _lastSupabaseCheckTime,
        isSupabaseAvailable: _isSupabaseAvailable,
      );
    } catch (e) {
      debugPrint('⚠️ [OFFLINE] Failed to get cache stats: $e');
      return OfflineCacheStats(
        cachedMatches: 0,
        cachedChats: 0,
        cachedMessages: 0,
        lastCheckTime: _lastSupabaseCheckTime,
        isSupabaseAvailable: _isSupabaseAvailable,
      );
    }
  }

  /// Get count of pending mutations waiting to sync
  Future<int> getPendingMutationCount() async {
    return OfflineMutationQueue.instance.getPendingCount();
  }

  /// Get list of pending mutations
  Future<List<OfflineMutation>> getPendingMutations() async {
    return OfflineMutationQueue.instance.getPendingMutations();
  }

  /// Sync all pending mutations to Supabase
  Future<SyncResult> syncPendingMutations() async {
    debugPrint('🔄 [OFFLINE] Starting mutation sync...');
    final result = await OfflineMutationQueue.instance.syncPendingMutations(
      supabase: _supabase,
    );
    debugPrint('🔄 [OFFLINE] Mutation sync complete');
    return result;
  }

  /// Check if there are pending mutations
  Future<bool> hasPendingMutations() async {
    final count = await getPendingMutationCount();
    return count > 0;
  }

  /// Listen to pending mutations stream
  Stream<List<OfflineMutation>> get pendingMutationsChanged =>
      OfflineMutationQueue.instance.queueChanged;
}

/// Statistics about the offline cache
class OfflineCacheStats {
  final int cachedMatches;
  final int cachedChats;
  final int cachedMessages;
  final DateTime? lastCheckTime;
  final bool isSupabaseAvailable;

  OfflineCacheStats({
    required this.cachedMatches,
    required this.cachedChats,
    required this.cachedMessages,
    required this.lastCheckTime,
    required this.isSupabaseAvailable,
  });

  bool get hasAnyCachedData =>
      cachedMatches > 0 || cachedChats > 0 || cachedMessages > 0;

  String get debugSummary =>
      'Cached: $cachedMatches matches, $cachedChats chats, $cachedMessages messages (Supabase: $isSupabaseAvailable)';
}

/// Global instance for easier access throughout the app
final offlineCacheManager = OfflineCacheManager.instance;
