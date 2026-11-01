// lib/services/local_db_service.dart
// Local DB service (Hive) with added option-hierarchy cache helpers.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert'; // For jsonEncode/Decode
import 'dart:async';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:matchme/services/notification_avatar_service.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/translation_edit_marker.dart';

// --- Hive Box Names (Unchanged) ---
const String _kProfileBox = 'userProfileBox';
const String _kMatchesBox = 'recentMatchesBox';
const String _kChatsBox = 'recentChatsBox';
const String _kChatMessagesBox = 'chatMessagesBox';
const String _kOutboxBox = 'outboxBox';
const String _kProfileOutboxBox = 'profileOutboxBox';
const String _kVisibilityOutboxBox = 'visibilityOutboxBox';
const String _kInvisibilityRulesOutboxBox = 'invisibilityRulesOutboxBox';
const String _kEventsBox = 'userEventsBox';
const String _kSettingsBox = 'userSettingsBox';
const String _kTranslationsBox = 'translationsBox';

// New options box name:
const String _kOptionsBox = 'optionHierarchyBox';

// Encrypted chat boxes
const String _kChatOutboxBox = 'chatOutboxBox';

// Offline trail (places recorded while offline for retroactive matching)
const String _kOfflineTrailBox = 'offlineTrailBox';
const int _kOfflineTrailMaxPoints = 2000;

// Settings box keys
const String _kSubscriptionTiersKey = 'subscription_tiers_cache';

/// A single message that matched a full-text search.
///
/// [field] records whether the hit was on the original text, the machine
/// translation, or a quoted reply, so the UI can say which. Searching
/// translated text matters: a Hebrew speaker searching an English word (or the
/// reverse) finds nothing unless the translation is searched too.
class MessageSearchHit {
  const MessageSearchHit({
    required this.matchId,
    required this.messageId,
    required this.field,
    required this.senderId,
    required this.createdAt,
    required this.snippet,
  });

  final String matchId;
  final String messageId;

  /// 'original', 'translated' or 'reply'.
  final String field;
  final String senderId;
  final String createdAt;

  /// Surrounding text with the match visible, for display in the row.
  final String snippet;
}

class LocalDbService {
  static LocalDbService? _instance;
  static LocalDbService get shared {
    _instance ??= LocalDbService();
    return _instance!;
  }

  static Future<LocalDbService> get instance async {
    _instance ??= shared;
    await _instance!.init();
    return _instance!;
  }

  Box? _profileBox;
  Box<String>? _matchesBox;
  Box<String>? _chatsBox;
  Box<String>? _messagesBox;
  Box<String>? _outboxBox;
  Box<String>? _profileOutboxBox;
  Box<String>? _visibilityOutboxBox;
  Box<String>? _invisibilityRulesOutboxBox;
  Box<String>? _eventsBox;
  Box<String>? _settingsBox;
  Box<String>? _translationsBox;
  Box<String>? _chatOutboxBox;
  Box? _optionsBox;
  Box<String>? _offlineTrailBox;
  bool _initialized = false;

  /// True once [init] has opened the startup-critical encrypted boxes.
  /// Callers that must not block (e.g. first-paint cache reads) can fall back
  /// to another source while background initialization is still running.
  static bool get isInitialized => _instance?._initialized ?? false;
  bool _optionalWarmupStarted = false;

  Completer<void>? _initCompleter;

  Future<void> init() async {
    if (_initialized) return;
    if (_initCompleter != null) {
      // Already initializing, wait for it to complete
      return _initCompleter!.future;
    }
    _initCompleter = Completer<void>();
    final start = DateTime.now();
    ResumeDiagnostics.log('LocalDb.init start');

    try {
      // Open startup-critical boxes ENCRYPTED (AES-256, key in Keystore/
      // Keychain via HiveEncryptionService). Migration from legacy plaintext
      // boxes is handled inside openEncryptedBox (copy -> delete -> reopen).
      final crypto = HiveEncryptionService.instance;
      await Future.wait([
        crypto
            .openEncryptedBoxDynamic(_kProfileBox)
            .then((box) => _profileBox = box),
        crypto
            .openEncryptedBox<String>(_kMatchesBox)
            .then((box) => _matchesBox = box),
        crypto
            .openEncryptedBox<String>(_kChatsBox)
            .then((box) => _chatsBox = box),
        crypto
            .openEncryptedBox<String>(_kChatMessagesBox)
            .then((box) => _messagesBox = box),
        crypto
            .openEncryptedBox<String>(_kSettingsBox)
            .then((box) => _settingsBox = box),
        crypto
            .openEncryptedBox<String>(_kTranslationsBox)
            .then((box) => _translationsBox = box),
      ]);
      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
      _warmOptionalBoxesInBackground();

      if (kIsWeb) {
        // print('🔍 [WEB] LocalDb.init - All boxes opened successfully');
        // Perform a quick health check on web
        await _performWebStorageHealthCheck();
      }
    } catch (e) {
      ResumeDiagnostics.log('LocalDb.init failed: $e');
      _initCompleter!.completeError(e);
      _initCompleter = null;
      if (kIsWeb) {
        // print('🔍 [WEB] LocalDb.init - FAILED: $e');
        // Try recovery for web
        await _attemptWebStorageRecovery();
      }
      rethrow;
    }

    final duration = DateTime.now().difference(start).inMilliseconds;
    ResumeDiagnostics.log('LocalDb.init completed in ${duration}ms');
  }

  void _warmOptionalBoxesInBackground() {
    if (_optionalWarmupStarted) return;
    _optionalWarmupStarted = true;
    unawaited(() async {
      try {
        // Open optional boxes ENCRYPTED in parallel.
        final crypto = HiveEncryptionService.instance;
        await Future.wait([
          crypto
              .openEncryptedBox<String>(_kOutboxBox)
              .then((box) => _outboxBox = box),
          crypto
              .openEncryptedBox<String>(_kProfileOutboxBox)
              .then((box) => _profileOutboxBox = box),
          crypto
              .openEncryptedBox<String>(_kVisibilityOutboxBox)
              .then((box) => _visibilityOutboxBox = box),
          crypto
              .openEncryptedBox<String>(_kInvisibilityRulesOutboxBox)
              .then((box) => _invisibilityRulesOutboxBox = box),
          crypto
              .openEncryptedBox<String>(_kEventsBox)
              .then((box) => _eventsBox = box),
          crypto
              .openEncryptedBoxDynamic(_kOptionsBox)
              .then((box) => _optionsBox = box),
        ]);
      } catch (e) {
        // print('LocalDb optional warmup failed: $e');
      }
    }());
  }

  // Web-specific storage health check and recovery methods
  Future<void> _performWebStorageHealthCheck() async {
    try {
      // Test using existing settings box instead of creating a new one
      final box = await _getSettingsBox();
      final testKey = 'health_check_${DateTime.now().millisecondsSinceEpoch}';
      final testValue = DateTime.now().toIso8601String();

      await box.put(testKey, testValue);
      final retrievedValue = box.get(testKey);

      // Clean up
      await box.delete(testKey);

      if (retrievedValue == testValue) {
        // print('🔍 [WEB] Storage health check: PASSED');
      } else {
        // print('🔍 [WEB] Storage health check: FAILED - read/write test failed');
      }
    } catch (e) {
      // print('🔍 [WEB] Storage health check: FAILED - $e');
      // Don't try recovery here as it might cause issues during init
    }
  }

  Future<void> _attemptWebStorageRecovery() async {
    // print('🔍 [WEB] Attempting storage recovery...');

    try {
      // Try to reset initialization state and retry
      _initialized = false;
      _profileBox = null;
      _matchesBox = null;
      _chatsBox = null;
      _messagesBox = null;
      _outboxBox = null;
      _profileOutboxBox = null;
      _visibilityOutboxBox = null;
      _invisibilityRulesOutboxBox = null;
      _eventsBox = null;
      _settingsBox = null;
      _translationsBox = null;
      _optionsBox = null;
      _optionalWarmupStarted = false;

      // Try to clear any corrupted boxes
      await Hive.deleteBoxFromDisk(_kProfileBox);
      await Hive.deleteBoxFromDisk(_kMatchesBox);
      await Hive.deleteBoxFromDisk(_kChatsBox);
      await Hive.deleteBoxFromDisk(_kChatMessagesBox);
      await Hive.deleteBoxFromDisk(_kOutboxBox);
      await Hive.deleteBoxFromDisk(_kProfileOutboxBox);
      await Hive.deleteBoxFromDisk(_kVisibilityOutboxBox);
      await Hive.deleteBoxFromDisk(_kInvisibilityRulesOutboxBox);
      await Hive.deleteBoxFromDisk(_kEventsBox);
      await Hive.deleteBoxFromDisk(_kSettingsBox);
      await Hive.deleteBoxFromDisk(_kTranslationsBox);
      await Hive.deleteBoxFromDisk(_kOptionsBox);

      // print('🔍 [WEB] Cleared corrupted boxes, retrying initialization...');

      // Retry initialization
      await init();
      // print('🔍 [WEB] Storage recovery: SUCCESS');
    } catch (e) {
      // print('🔍 [WEB] Storage recovery: FAILED - $e');
      // If recovery fails, we'll let the error propagate
      rethrow;
    }
  }

  // --- Box Getters (Optimized) ---
  Future<Box> _getProfileBox() async {
    if (_profileBox == null) {
      await init();
      _profileBox ??= await HiveEncryptionService.instance
          .openEncryptedBoxDynamic(_kProfileBox);
    }
    return _profileBox!;
  }

  Future<Box<String>> _getMatchesBox() async {
    if (_matchesBox == null) {
      await init();
      _matchesBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kMatchesBox);
    }
    return _matchesBox!;
  }

  Future<Box<String>> _getChatsBox() async {
    if (_chatsBox == null) {
      await init();
      _chatsBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kChatsBox);
    }
    return _chatsBox!;
  }

  Future<Box<String>> _getMessagesBox() async {
    if (_messagesBox == null) {
      await init();
      _messagesBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kChatMessagesBox);
    }
    return _messagesBox!;
  }

  Future<Box<String>> _getOutboxBox() async {
    if (_outboxBox == null) {
      await init();
      _outboxBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kOutboxBox);
    }
    return _outboxBox!;
  }

  Future<Box<String>> _getProfileOutboxBox() async {
    if (_profileOutboxBox == null) {
      await init();
      _profileOutboxBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kProfileOutboxBox);
    }
    return _profileOutboxBox!;
  }

  Future<Box<String>> _getVisibilityOutboxBox() async {
    if (_visibilityOutboxBox == null) {
      await init();
      _visibilityOutboxBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kVisibilityOutboxBox);
    }
    return _visibilityOutboxBox!;
  }

  Future<Box<String>> _getInvisibilityRulesOutboxBox() async {
    if (_invisibilityRulesOutboxBox == null) {
      await init();
      _invisibilityRulesOutboxBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kInvisibilityRulesOutboxBox);
    }
    return _invisibilityRulesOutboxBox!;
  }

  Future<Box<String>> _getEventsBox() async {
    if (_eventsBox == null) {
      await init();
      _eventsBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kEventsBox);
    }
    return _eventsBox!;
  }

  Future<Box<String>> _getSettingsBox() async {
    if (_settingsBox == null) {
      await init();
      _settingsBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kSettingsBox);
    }
    return _settingsBox!;
  }

  Future<Box<String>> _getTranslationsBox() async {
    if (_translationsBox == null) {
      await init();
      _translationsBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kTranslationsBox);
    }
    return _translationsBox!;
  }

  Future<Box<String>> _getChatOutboxBox() async {
    if (_chatOutboxBox == null) {
      await init();
      _chatOutboxBox ??= await HiveEncryptionService.instance
          .openEncryptedBox<String>(_kChatOutboxBox);
    }
    return _chatOutboxBox!;
  }

  Future<Box<String>> _getOfflineTrailBox() async {
    _offlineTrailBox ??= await HiveEncryptionService.instance
        .openEncryptedBox<String>(_kOfflineTrailBox);
    return _offlineTrailBox!;
  }

  // --- Profile Methods ---
  Future<void> saveLocalProfile(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    final box = await _getProfileBox();
    await box.put(userId, jsonEncode(profileData));
  }

  /// Removes profile rows left from a previous login (same device, different account).
  Future<void> clearStaleLocalProfilesForUser(String currentUserId) async {
    final keepId = currentUserId.trim();
    if (keepId.isEmpty) return;
    try {
      final box = await _getProfileBox();
      final toDelete = <dynamic>[];
      for (final key in box.keys) {
        final k = key.toString();
        if (k == keepId) continue;
        if (k.startsWith('other_user_')) continue;
        toDelete.add(key);
      }
      for (final key in toDelete) {
        await box.delete(key);
      }
    } catch (_) {}
  }

  Stream<Map<String, dynamic>?> watchLocalProfile(String userId) async* {
    final box = await _getProfileBox();
    final currentProfile = box.get(userId);
    if (currentProfile != null) {
      yield jsonDecode(currentProfile) as Map<String, dynamic>;
    } else {
      yield null;
    }
    yield* box.watch(key: userId).map((event) {
      if (event.value != null) {
        return jsonDecode(event.value) as Map<String, dynamic>;
      }
      return null;
    });
  }

  Future<Set<String>> loadApprovedPrimaryPhotos(String userId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('approved_primary_photos_$userId');
      if (raw == null) return <String>{};
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final result = <String>{};
        for (final e in decoded) {
          final str = e.toString();
          if (str.isNotEmpty) result.add(str);
        }
        return result;
      }
    } catch (_) {}
    return <String>{};
  }

  Future<void> setApprovedPrimaryPhotos(
    String userId,
    Set<String> photos,
  ) async {
    final box = await _getSettingsBox();
    final cleaned = photos.where((e) => e.isNotEmpty).toSet();
    await box.put(
      'approved_primary_photos_$userId',
      jsonEncode(cleaned.toList()),
    );
  }

  Future<void> addApprovedPrimaryPhoto(String userId, String photoPath) async {
    if (photoPath.isEmpty) return;
    final current = await loadApprovedPrimaryPhotos(userId);
    if (current.contains(photoPath)) return;
    current.add(photoPath);
    final box = await _getSettingsBox();
    await box.put(
      'approved_primary_photos_$userId',
      jsonEncode(current.toList()),
    );
  }

  Future<void> removeApprovedPrimaryPhoto(
    String userId,
    String photoPath,
  ) async {
    if (photoPath.isEmpty) return;
    final current = await loadApprovedPrimaryPhotos(userId);
    if (!current.contains(photoPath)) return;
    current.remove(photoPath);
    final box = await _getSettingsBox();
    await box.put(
      'approved_primary_photos_$userId',
      jsonEncode(current.toList()),
    );
  }

  // --- Home Screen List Methods ---
  Future<bool> saveMatches(
    String userId,
    List<Map<String, dynamic>> matches,
  ) async {
    final box = await _getMatchesBox();
    final key = 'recent_matches_$userId';
    // Persist minimap snapshots for all matches so they render offline even before opening profile
    try {
      for (final match in matches) {
        final matchId = (match['id'] ?? match['match_id'])?.toString() ?? '';
        if (matchId.isEmpty) continue;
        final locs = _extractDisplayableLocationsFromMatch(match, matchId);
        if (locs.isNotEmpty) {
          await saveMatchMinimapSnapshot(matchId, locs);
        }
      }
    } catch (_) {}
    // Avoid Hive watch event when nothing changed - prevents visible list flicker
    // on every 15s sync when data is identical.
    try {
      final existing = box.get(key);
      final next = jsonEncode(matches);
      if (existing == next) return false;
    } catch (_) {}
    await box.put(key, jsonEncode(matches));
    return true;
  }

  /// Returns true only when this user has a complete, locally readable home
  /// snapshot. Empty match/chat lists are valid snapshots: the important
  /// distinction is between "the server confirmed there are none" (a stored
  /// empty list) and "we have not fetched this account yet" (no key at all).
  ///
  /// This is intentionally scoped to the user. It is used by the startup gate
  /// to decide whether a relaunch can render from disk while a refresh runs in
  /// the background, without allowing a first login to show a partial home.
  Future<bool> hasCompleteHomeCache(String userId) async {
    if (userId.trim().isEmpty) return false;
    try {
      final profile = await getLocalProfile(userId);
      if (profile == null) return false;

      final matchesBox = await _getMatchesBox();
      final chatsBox = await _getChatsBox();
      final matches = matchesBox.get('recent_matches_$userId');
      final chats = chatsBox.get('recent_chats_$userId');
      if (matches is! String || chats is! String) return false;

      // Treat malformed cache rows as a cache miss so the normal server-sync
      // path repairs them instead of exposing a misleading empty home.
      if (jsonDecode(matches) is! List || jsonDecode(chats) is! List) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Deletes expired matches (no chat, expiry in past) from local cache for [userId].
  /// Called periodically and after sync to ensure UI instantly reflects expiry
  /// even before the server cron has deleted the row.
  Future<int> pruneExpiredMatches(String userId, Set<String> chatIds) async {
    final box = await _getMatchesBox();
    final key = 'recent_matches_$userId';
    final raw = box.get(key);
    if (raw == null) return 0;
    List<Map<String, dynamic>> list;
    try {
      list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return 0;
    }
    final now = DateTime.now().toUtc();
    final retained = <Map<String, dynamic>>[];
    int pruned = 0;
    // Also check local messages box - if messages exist, match has a chat even if
    // chats cache hasn't synced yet (prevents deleting Ingela-type matches).
    Box<String>? msgBox;
    try {
      msgBox = await _getMessagesBox();
    } catch (_) {}
    for (final json in list) {
      final matchId = (json['match_id'] ?? json['id'])?.toString() ?? '';
      if (matchId.isEmpty) {
        retained.add(json);
        continue;
      }
      if (chatIds.contains(matchId)) {
        retained.add(json);
        continue;
      }
      if (msgBox != null) {
        try {
          final rawMsgs = msgBox.get(matchId);
          if (rawMsgs != null &&
              rawMsgs.trim().isNotEmpty &&
              rawMsgs.trim() != '[]') {
            retained.add(json);
            continue;
          }
        } catch (_) {}
      }
      final createdAtStr = json['created_at']?.toString();
      if (createdAtStr == null || createdAtStr.isEmpty) {
        retained.add(json);
        continue;
      }
      final createdAt = DateTime.tryParse(createdAtStr);
      if (createdAt == null) {
        retained.add(json);
        continue;
      }
      final windowRaw = json['chat_start_window_seconds'];
      final extRaw = json['chat_start_extension_seconds'];
      final window = windowRaw is int
          ? windowRaw
          : int.tryParse(windowRaw?.toString() ?? '') ?? 86400;
      final ext = extRaw is int
          ? extRaw
          : int.tryParse(extRaw?.toString() ?? '') ?? 0;
      final expiry = createdAt.toUtc().add(Duration(seconds: window + ext));
      if (expiry.isAfter(now)) {
        retained.add(json);
      } else {
        pruned++;
      }
    }
    if (pruned > 0) {
      await box.put(key, jsonEncode(retained));
    }
    return pruned;
  }

  Future<void> addOrUpdateMatch(
    String userId,
    Map<String, dynamic> matchData,
  ) async {
    final box = await _getMatchesBox();
    final key = 'recent_matches_$userId';
    final currentMatches = box.get(key);

    List<Map<String, dynamic>> matches = [];
    if (currentMatches != null) {
      matches = (jsonDecode(currentMatches) as List)
          .cast<Map<String, dynamic>>();
    }

    // Preserve previous_locations from existing cache (realtime INSERT has no history)
    Map<String, dynamic>? existingForId;
    for (final m in matches) {
      if (m['match_id'] == matchData['id']) {
        existingForId = m;
        break;
      }
    }
    // Create the match object with consistent keys (including coarse map + rematch)
    final match = {
      'match_id': matchData['id'],
      'user1_id': matchData['user1_id'],
      'user2_id': matchData['user2_id'],
      'match_type': matchData['match_type'],
      'matched_intent': matchData['matched_intent'],
      'event_id': matchData['event_id'],
      'event_name': matchData['event_name'],
      'event_link': matchData['event_link'],
      'created_at': matchData['created_at'],
      if (matchData['match_occurrence'] != null)
        'match_occurrence': matchData['match_occurrence'],
      if (matchData['map_center_lat'] != null)
        'map_center_lat': matchData['map_center_lat'],
      if (matchData['map_center_lng'] != null)
        'map_center_lng': matchData['map_center_lng'],
      if (matchData['map_zoom'] != null) 'map_zoom': matchData['map_zoom'],
      if (matchData['chat_start_window_seconds'] != null)
        'chat_start_window_seconds': matchData['chat_start_window_seconds'],
      if (matchData['chat_start_extension_seconds'] != null)
        'chat_start_extension_seconds':
            matchData['chat_start_extension_seconds'],
      if (matchData['chat_start_extension_count'] != null)
        'chat_start_extension_count': matchData['chat_start_extension_count'],
      if (matchData['expires_at'] != null)
        'expires_at': matchData['expires_at'],
      if (matchData['has_extended'] != null)
        'has_extended': matchData['has_extended'],
      if (matchData['previous_locations'] != null)
        'previous_locations': matchData['previous_locations']
      else if (matchData['locations_history'] != null)
        'previous_locations': matchData['locations_history']
      else if (existingForId?['previous_locations'] != null)
        'previous_locations': existingForId!['previous_locations'],
    };

    // Remove if already exists (update case)
    matches.removeWhere((m) => m['match_id'] == match['match_id']);

    // Add to the beginning
    matches.insert(0, match);

    await box.put(key, jsonEncode(matches));
  }

  Future<void> deleteMatch(String matchId, {required String userId}) async {
    final box = await _getMatchesBox();
    final key = 'recent_matches_$userId';
    final currentMatches = box.get(key);
    if (currentMatches != null) {
      final matches = (jsonDecode(currentMatches) as List)
          .cast<Map<String, dynamic>>();
      final updatedMatches = matches
          .where((match) => match['match_id'] != matchId)
          .toList();
      await box.put(key, jsonEncode(updatedMatches));
    }
  }

  /// Persist the displayable match-location (minimap) snapshot for [matchId]
  /// in local storage so the match profile minimap renders offline.
  /// Called whenever the profile has fresh displayable locations (online).
  Future<void> saveMatchMinimapSnapshot(
    String matchId,
    List<Map<String, dynamic>> locations,
  ) async {
    try {
      if (matchId.isEmpty || locations.isEmpty) return;
      final box = await _getSettingsBox();
      await box.put('match_minimap_$matchId', jsonEncode(locations));
    } catch (_) {}
  }

  /// Load the persisted minimap snapshot for [matchId] (offline fallback).
  /// Returns an empty list when nothing was cached yet.
  Future<List<Map<String, dynamic>>> getMatchMinimapSnapshot(
    String matchId,
  ) async {
    try {
      if (matchId.isEmpty) return const [];
      final box = await _getSettingsBox();
      final raw = box.get('match_minimap_$matchId');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw) as List;
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// All persisted minimap snapshots keyed by matchId. Used to pre-warm the
  /// map tile cache so every known match location renders offline.
  Future<Map<String, List<Map<String, dynamic>>>>
  getAllMatchMinimapSnapshots() async {
    try {
      final box = await _getSettingsBox();
      final result = <String, List<Map<String, dynamic>>>{};
      for (final key in box.keys) {
        final k = key.toString();
        if (!k.startsWith('match_minimap_')) continue;
        final raw = box.get(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw) as List;
          result[k.substring('match_minimap_'.length)] = decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        } catch (_) {}
      }

      // Also inspect matches box to ensure all cached matches across all chats
      // have minimap snapshots available offline and queued for tile warming.
      try {
        final matchesBox = await _getMatchesBox();
        for (final key in matchesBox.keys) {
          final k = key.toString();
          if (!k.startsWith('recent_matches_')) continue;
          final raw = matchesBox.get(key);
          if (raw == null || raw.isEmpty) continue;
          try {
            final decoded = jsonDecode(raw) as List;
            for (final item in decoded) {
              if (item is! Map) continue;
              final m = Map<String, dynamic>.from(item);
              final matchId = (m['id'] ?? m['match_id'])?.toString() ?? '';
              if (matchId.isEmpty || result.containsKey(matchId)) continue;
              final locs = _extractDisplayableLocationsFromMatch(m, matchId);
              if (locs.isNotEmpty) {
                result[matchId] = locs;
                await saveMatchMinimapSnapshot(matchId, locs);
              }
            }
          } catch (_) {}
        }
      } catch (_) {}

      return result;
    } catch (_) {
      return const {};
    }
  }

  /// Extracts displayable location maps (MatchLocation format) from a cached match row.
  List<Map<String, dynamic>> _extractDisplayableLocationsFromMatch(
    Map<dynamic, dynamic> m,
    String matchId,
  ) {
    final list = <Map<String, dynamic>>[];
    double? parseCoord(dynamic v) => v == null
        ? null
        : (v is num ? v.toDouble() : double.tryParse(v.toString()));
    int parseOcc(dynamic v) =>
        v == null ? 1 : (v is int ? v : int.tryParse(v.toString()) ?? 1);

    final occ = parseOcc(m['match_occurrence'] ?? m['matchOccurrence']);
    final cLat = parseCoord(
      m['map_center_lat'] ?? m['mapCenterLat'] ?? m['center_lat'],
    );
    final cLng = parseCoord(
      m['map_center_lng'] ?? m['mapCenterLng'] ?? m['center_lng'],
    );
    final zoom = parseCoord(m['map_zoom'] ?? m['mapZoom'] ?? m['zoom']);
    final u1Lat = parseCoord(
      m['user1_lat'] ?? m['user1Lat'] ?? m['user1_latitude'],
    );
    final u1Lng = parseCoord(
      m['user1_lng'] ?? m['user1Lng'] ?? m['user1_longitude'],
    );
    final u2Lat = parseCoord(
      m['user2_lat'] ?? m['user2Lat'] ?? m['user2_latitude'],
    );
    final u2Lng = parseCoord(
      m['user2_lng'] ?? m['user2Lng'] ?? m['user2_longitude'],
    );
    final intent = (m['matched_intent'] ?? m['matchedIntent'])?.toString();
    final createdAt = m['created_at']?.toString() ?? m['createdAt']?.toString();

    // Check previous locations
    final prev = m['previous_locations'] ?? m['locations_history'];
    if (prev is List) {
      for (final p in prev) {
        if (p is Map) {
          final pMap = Map<String, dynamic>.from(p);
          final pLat = parseCoord(
            pMap['map_center_lat'] ??
                pMap['mapCenterLat'] ??
                pMap['center_lat'],
          );
          final pLng = parseCoord(
            pMap['map_center_lng'] ??
                pMap['mapCenterLng'] ??
                pMap['center_lng'],
          );
          final pU1Lat = parseCoord(
            pMap['user1_lat'] ?? pMap['user1Lat'] ?? pMap['user1_latitude'],
          );
          final pU2Lat = parseCoord(
            pMap['user2_lat'] ?? pMap['user2Lat'] ?? pMap['user2_latitude'],
          );
          final hasLoc =
              (pLat != null && pLng != null) ||
              (pU1Lat != null && pU2Lat != null);
          if (hasLoc) {
            pMap['match_id'] ??= matchId;
            list.add(pMap);
          }
        }
      }
    }

    final hasCurrent =
        (cLat != null && cLng != null) ||
        (u1Lat != null && u1Lng != null && u2Lat != null && u2Lng != null);
    if (hasCurrent) {
      final currentMap = <String, dynamic>{
        'occurrence': occ,
        'match_id': matchId,
        'map_center_lat': ?cLat,
        'map_center_lng': ?cLng,
        'map_zoom': ?zoom,
        'user1_lat': ?u1Lat,
        'user1_lng': ?u1Lng,
        'user2_lat': ?u2Lat,
        'user2_lng': ?u2Lng,
        'matched_intent': ?intent,
        'created_at': ?createdAt,
      };
      if (!list.any((e) => e['occurrence'] == occ)) {
        list.add(currentMap);
      }
    }

    list.sort(
      (a, b) => parseOcc(a['occurrence']).compareTo(parseOcc(b['occurrence'])),
    );
    return list;
  }

  Future<void> deleteChat(String matchId, {String? userId}) async {
    final box = await _getChatsBox();

    // Legacy/global key (kept for backward compatibility)
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      final chats = (jsonDecode(globalChats) as List)
          .cast<Map<String, dynamic>>();
      final updatedChats = chats
          .where((chat) => chat['match_id'] != matchId)
          .toList();
      await box.put(globalKey, jsonEncode(updatedChats));
    }

    // Per-user key (the one used by saveChats/watchChats)
    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        final chats = (jsonDecode(userChats) as List)
            .cast<Map<String, dynamic>>();
        final updatedChats = chats
            .where((chat) => chat['match_id'] != matchId)
            .toList();
        await box.put(userKey, jsonEncode(updatedChats));
      }
    }

    // Also clear all associated data for this chat
    // print('🗑️ deleteChat: Clearing all data for chat $matchId');
    await clearChatMessages(matchId);
    if (userId != null && userId.isNotEmpty) {
      await clearChatTranslationSettings(userId, matchId);
    }
    // A conversation that is gone takes its notification avatar with it.
    unawaited(NotificationAvatarService.instance.evict(matchId));
  }

  Future<void> addOrUpdateChat(Map<String, dynamic> chat) async {
    final box = await _getChatsBox();
    final currentChats = box.get('recent_chats');

    List<Map<String, dynamic>> chats = [];
    if (currentChats != null) {
      chats = (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();
    }

    // Remove if already exists (update case)
    chats.removeWhere((c) => c['match_id'] == chat['match_id']);

    // Add to the beginning
    chats.insert(0, chat);

    await box.put('recent_chats', jsonEncode(chats));
  }

  Future<void> updateChatLastMessageTranslation(
    String userId,
    String matchId,
    String lastMessageId,
    String? translatedText, {
    String? targetLanguage,
    String? editedAt,
  }) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);
    if (currentChats == null) return;

    var chats = (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();

    // Find and update the chat with this matchId and lastMessageId
    var rowIndex = -1;
    for (int i = 0; i < chats.length; i++) {
      if (chats[i]['match_id'] == matchId &&
          chats[i]['last_message_id'] == lastMessageId) {
        rowIndex = i;
        break;
      }
    }
    if (rowIndex == -1 &&
        translatedText != null &&
        translatedText.trim().isNotEmpty) {
      // Stale preview row: the chat's last_message_id advanced (or was never
      // set) before this translation landed, so the id check below would drop
      // a valid translation and wedge the preview blank — while the open chat
      // (which reads the messages box) shows it fine. Recompute the preview
      // from the messages box first; when the translated message is still the
      // latest, the row matches afterwards and the write below proceeds.
      // Clearing calls (translatedText == null) intentionally skip this: they
      // must never resurrect a row for a superseded message.
      try {
        await recomputeChatLastMessagePreviewFromMessages(userId, matchId);
        final refreshed = box.get(key);
        if (refreshed != null) {
          chats = (jsonDecode(refreshed) as List).cast<Map<String, dynamic>>();
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId &&
                chats[i]['last_message_id'] == lastMessageId) {
              rowIndex = i;
              break;
            }
          }
        }
      } catch (_) {}
      if (rowIndex == -1) return;
    }
    if (rowIndex != -1) {
      final i = rowIndex;
      // Never store raw ciphertext as a preview. Callers in the realtime and
      // sync-fallback notification paths can hand us the RPC's
      // last_message_translated column, which is base64 ciphertext for v1
      // messages and unreadable for the user. Clearing the field leaves the
      // chat list preview blank until the decrypt path produces real text.
      if (looksLikeEncryptedBlob(translatedText)) {
        translatedText = null;
      }
      if (translatedText == null || translatedText.trim().isEmpty) {
        chats[i].remove('last_message_translated');
        chats[i].remove('last_message_target_language');
        chats[i].remove('last_message_translated_edited_at');
      } else {
        chats[i]['last_message_translated'] = translatedText;
        if (targetLanguage != null) {
          chats[i]['last_message_target_language'] = targetLanguage;
        }
        // Bind the preview to the content version it was made for. An edit
        // keeps `last_message_id` the same, so this marker is the only thing
        // that distinguishes a translation of the current text from one of
        // the text before the edit. Callers that don't know the message's
        // `edited_at` pass null, which matches only a never-edited message —
        // the same fail-safe direction as `translationEditMarkersMatch`.
        if (editedAt != null) {
          chats[i]['last_message_translated_edited_at'] = editedAt;
        }
      }
      await box.put(key, jsonEncode(chats));
    }
  }

  // --- Event UI Preferences ---
  /// Persist the user's preference for showing past events locally.
  Future<void> saveShowPastEvents(String userId, bool value) async {
    final box = await _getSettingsBox();
    await box.put('show_past_events_$userId', value ? '1' : '0');
  }

  /// Load the user's preference for showing past events; defaults to false.
  Future<bool> loadShowPastEvents(String userId) async {
    final box = await _getSettingsBox();
    final val = box.get('show_past_events_$userId');
    if (val == null) return false;
    return val == '1' || val == 'true';
  }

  /// Clear cached translations for specific message IDs in a match.
  ///
  /// Clears both the legacy fields (`translated_text` / `translated_lang`) and
  /// the current plaintext cache fields (`content_translated` /
  /// `translated_target_language`) so that Phase 2 decryption and
  /// `translationFamilyProvider` re-evaluate the message for the current UI
  /// language instead of serving a stale translation from a previous language.
  ///
  /// The encrypted translation payload (`content_translated_encrypted` /
  /// `content_translated_nonce` / `content_translated_encrypted_cache`) is
  /// cleared as well: the translation AAD binds the target language but NOT
  /// the original content, so a stored blob made for pre-edit content still
  /// decrypts after an edit and would be served as a stale translation.
  /// Dropping it forces a fresh translate-proxy round trip. The authoritative
  /// copy lives in Supabase, so nothing is lost — the provider refetches it
  /// when needed.
  Future<void> clearCachedTranslationsForMessages(
    String matchId,
    List<String> messageIds,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _clearCachedTranslationsForMessagesUnlocked(matchId, messageIds),
    );
  }

  Future<void> _clearCachedTranslationsForMessagesUnlocked(
    String matchId,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;

    final messagesBox = await _getMessagesBox();
    final currentMessages = messagesBox.get(matchId);
    if (currentMessages != null) {
      try {
        final messages = (jsonDecode(currentMessages) as List)
            .cast<Map<String, dynamic>>();
        final messageIdSet = messageIds.toSet();
        var changed = false;
        for (int i = 0; i < messages.length; i++) {
          final msgId = messages[i]['id']?.toString();
          if (msgId != null && messageIdSet.contains(msgId)) {
            // Legacy fields (old schema)
            if (messages[i].containsKey('translated_text') ||
                messages[i].containsKey('translated_lang')) {
              messages[i].remove('translated_text');
              messages[i].remove('translated_lang');
              changed = true;
            }
            // Current plaintext cache fields — clearing these forces Phase 2
            // to re-decrypt content_translated_encrypted for the new UI language,
            // and forces translationFamilyProvider into Case A (re-translate).
            if (messages[i].containsKey('content_translated') ||
                messages[i].containsKey('translated_target_language')) {
              messages[i].remove('content_translated');
              messages[i].remove('translated_target_language');
              changed = true;
            }
            // Encrypted translation payload — must go together with the
            // plaintext above (see method doc): after a message edit the old
            // blob still decrypts and would be served as a stale translation.
            if (messages[i].containsKey('content_translated_encrypted') ||
                messages[i].containsKey('content_translated_nonce') ||
                messages[i].containsKey('content_translated_encrypted_cache')) {
              messages[i].remove('content_translated_encrypted');
              messages[i].remove('content_translated_nonce');
              messages[i].remove('content_translated_encrypted_cache');
              changed = true;
            }
            // Reply translation — clear when the parent message's translation
            // is cleared so the reply quote re-evaluates against the new content.
            if (messages[i].containsKey('reply_to_content_translated')) {
              messages[i].remove('reply_to_content_translated');
              changed = true;
            }
          }
        }
        if (changed) {
          await messagesBox.put(matchId, jsonEncode(messages));
        }
      } catch (_) {
        // ignore parse errors
      }
    }
  }

  /// Clear any cached translations for a given match (messages and recent chat entries).
  /// If [userId] is provided, it will also clear the per-user recent chats key (`recent_chats_$userId`).
  Future<void> clearCachedTranslationsForMatch(
    String matchId, {
    String? userId,
  }) {
    return _withMessagesWrite(
      matchId,
      () => _clearCachedTranslationsForMatchUnlocked(matchId, userId: userId),
    );
  }

  Future<void> _clearCachedTranslationsForMatchUnlocked(
    String matchId, {
    String? userId,
  }) async {
    // 1) Clear message-level cached translations
    final messagesBox = await _getMessagesBox();
    final currentMessages = messagesBox.get(matchId);
    if (currentMessages != null) {
      try {
        final messages = (jsonDecode(currentMessages) as List)
            .cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < messages.length; i++) {
          // Legacy fields (old schema)
          if (messages[i].containsKey('translated_text') ||
              messages[i].containsKey('translated_lang')) {
            messages[i].remove('translated_text');
            messages[i].remove('translated_lang');
            changed = true;
          }
          // Current plaintext cache fields
          if (messages[i].containsKey('content_translated') ||
              messages[i].containsKey('translated_target_language')) {
            messages[i].remove('content_translated');
            messages[i].remove('translated_target_language');
            changed = true;
          }
        }
        if (changed) {
          await messagesBox.put(matchId, jsonEncode(messages));
        }
      } catch (_) {
        // ignore parse errors
      }
    }

    // 2) Clear recent_chats entries (global key)
    final box = await _getChatsBox();
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List)
            .cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < chats.length; i++) {
          if (chats[i]['match_id'] == matchId &&
              chats[i].containsKey('last_message_translated')) {
            chats[i].remove('last_message_translated');
            changed = true;
          }
        }
        if (changed) await box.put(globalKey, jsonEncode(chats));
      } catch (_) {
        // ignore
      }
    }

    // 3) Clear per-user recent_chats key if userId provided
    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List)
              .cast<Map<String, dynamic>>();
          var changed = false;
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId &&
                chats[i].containsKey('last_message_translated')) {
              chats[i].remove('last_message_translated');
              changed = true;
            }
          }
          if (changed) await box.put(userKey, jsonEncode(chats));
        } catch (_) {
          // ignore
        }
      }
    }
  }

  Future<void> deleteMessages(String matchId) {
    return _withMessagesWrite(matchId, () async {
      final box = await _getMessagesBox();
      await box.delete(matchId);
    });
  }

  Future<void> deleteMessage(String matchId, String messageId) {
    return _withMessagesWrite(
      matchId,
      () => _deleteMessageUnlocked(matchId, messageId),
    );
  }

  Future<void> _deleteMessageUnlocked(String matchId, String messageId) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);
    final updatedMessages = messages
        .where((m) => m['id'] != messageId)
        .toList();
    await box.put(matchId, jsonEncode(updatedMessages));
  }

  Stream<List<Map<String, dynamic>>> watchMatches(String userId) async* {
    ResumeDiagnostics.log('LocalDb.watchMatches called for userId=$userId');

    final box = await _getMatchesBox();
    final key = 'recent_matches_$userId';

    // Yield initial value
    final currentMatches = box.get(key);
    if (currentMatches != null) {
      try {
        yield (jsonDecode(currentMatches) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        yield const [];
      }
    } else {
      yield const [];
    }

    // Watch for changes
    await for (final event in box.watch(key: key)) {
      if (event.value != null && !event.deleted) {
        try {
          yield (jsonDecode(event.value) as List).cast<Map<String, dynamic>>();
        } catch (_) {
          yield const [];
        }
      } else {
        yield const [];
      }
    }
  }

  Future<void> saveChats(
    String userId,
    List<Map<String, dynamic>> chats,
  ) async {
    try {
      final box = await _getChatsBox();

      bool looksLikeEncryptedPreview(String? value) =>
          looksLikeEncryptedBlob(value);

      // Merge with existing per-user cache to preserve cached translations
      final key = 'recent_chats_$userId';
      final currentChats = box.get(key);
      if (currentChats != null) {
        try {
          final existing = (jsonDecode(currentChats) as List)
              .cast<Map<String, dynamic>>();
          final Map<String, Map<String, dynamic>> existingByMatch = {
            for (var c in existing) (c['match_id']?.toString() ?? ''): c,
          };

          for (int i = 0; i < chats.length; i++) {
            final incoming = chats[i];
            final matchId = incoming['match_id']?.toString() ?? '';
            if (matchId.isEmpty) continue;

            final existingEntry = existingByMatch[matchId];
            if (existingEntry != null) {
              final incomingName = incoming['other_user_name']
                  ?.toString()
                  .trim();
              final cachedName = existingEntry['other_user_name']
                  ?.toString()
                  .trim();
              final incomingNameUnavailable =
                  incomingName == null ||
                  incomingName.isEmpty ||
                  incomingName.toLowerCase() == 'unknown' ||
                  incomingName.toLowerCase() == 'unknown user';
              if (incomingNameUnavailable &&
                  cachedName != null &&
                  cachedName.isNotEmpty &&
                  cachedName.toLowerCase() != 'unknown' &&
                  cachedName.toLowerCase() != 'unknown user') {
                incoming['other_user_name'] = cachedName;
              }

              if (incoming['other_user_photos'] == null &&
                  existingEntry['other_user_photos'] != null) {
                incoming['other_user_photos'] =
                    existingEntry['other_user_photos'];
              }

              // IMPORTANT: Always use server-provided translation_enabled and translation_language
              // Supabase is the source of truth. When a chat is deleted and recreated,
              // the client cache must reset to server values (default false).
              // Do NOT preserve cached translation settings.

              final incomingLastId = incoming['last_message_id']?.toString();
              final existingLastId = existingEntry['last_message_id']
                  ?.toString();

              // Preserve existing last_message when the server returns it empty
              // (e.g. for v1 encrypted messages where the server doesn't have
              // the decrypted content).  The local DB may have a decrypted preview
              // set by recomputeChatLastMessagePreviewFromMessages.
              //
              // Only for the SAME message, though: when the server's
              // last_message_id has advanced, the cached text describes the
              // previous message, and keeping it would pin that text under the
              // new id. Rows that render last_message directly (translation
              // disabled, or source == UI language) would then show the
              // previous message until some later sync happened to heal the
              // row. A new id with no readable plaintext stays blank — the
              // pending state — and is filled by recompute/decrypt/sync.
              final incomingMsg = incoming['last_message'] as String?;
              final existingMsg = existingEntry['last_message'] as String?;
              final incomingEncryptedPreview =
                  incoming['last_message_content_original_encrypted']
                      as String?;
              final incomingScheme =
                  incoming['last_message_encryption_scheme'] as String?;
              final sameMessageAsIncoming =
                  incomingLastId == null ||
                  incomingLastId.isEmpty ||
                  incomingLastId == existingLastId;
              final existingLooksEncrypted =
                  incomingScheme == 'v1' &&
                  existingMsg != null &&
                  (existingMsg == incomingEncryptedPreview ||
                      looksLikeEncryptedPreview(existingMsg));
              if (sameMessageAsIncoming &&
                  (incomingMsg == null || incomingMsg.isEmpty) &&
                  existingMsg != null &&
                  existingMsg.isNotEmpty &&
                  !existingLooksEncrypted) {
                incoming['last_message'] = existingMsg;
              }

              // Track the last message's `edited_at`. The server reports it
              // (get_user_recent_chats.last_message_edited_at); keep the cached
              // value when a sync cannot supply one so the marker comparison
              // below stays meaningful across syncs.
              final incomingEditedAt = normalizeEditMarker(
                incoming['last_message_edited_at'],
              );
              if (incomingEditedAt != null) {
                incoming['last_message_edited_at'] = incomingEditedAt;
              } else if (existingEntry['last_message_edited_at'] != null) {
                incoming['last_message_edited_at'] =
                    existingEntry['last_message_edited_at'];
              }

              // Only preserve cached last_message_translated if it's for the same
              // message AND was made for the message's current content (to avoid
              // flicker when showing preview).
              var incomingTranslated =
                  incoming['last_message_translated'] as String?;
              final existingTranslated =
                  existingEntry['last_message_translated'] as String?;

              // A preview that is still raw ciphertext must never reach the
              // cache: get_user_recent_chats exposes
              // content_translated_encrypted in this column, and any sync whose
              // Phase 3 decryption could not run (chat key not loaded yet, peer
              // key unavailable, or a "#pending#" translation claim holding the
              // row) would otherwise persist a blob that ChatListItem paints
              // verbatim. Dropping it lets the decrypt path — or the last known
              // good plaintext below — fill in instead.
              final existingIsBlob = looksLikeEncryptedPreview(
                existingTranslated,
              );
              if (looksLikeEncryptedPreview(incomingTranslated)) {
                incoming['last_message_translated'] = null;
                incomingTranslated = null;
              }

              if ((incomingTranslated == null || incomingTranslated.isEmpty) &&
                  existingTranslated != null &&
                  existingTranslated.isNotEmpty &&
                  !existingIsBlob &&
                  incomingLastId != null &&
                  existingLastId != null &&
                  incomingLastId == existingLastId &&
                  translationEditMarkersMatch(
                    existingEntry['last_message_translated_edited_at']
                        ?.toString(),
                    incomingEditedAt ??
                        existingEntry['last_message_edited_at']?.toString(),
                  )) {
                incoming['last_message_translated'] = existingTranslated;
                final existingTranslatedMarker =
                    existingEntry['last_message_translated_edited_at'];
                if (existingTranslatedMarker != null) {
                  incoming['last_message_translated_edited_at'] =
                      existingTranslatedMarker;
                }
                // The target language is part of the cached translation's
                // validity contract (previewTranslationIsCurrent rejects a
                // translation whose target no longer matches the UI language),
                // so it must survive with the text it belongs to.
                final incomingTargetLang =
                    incoming['last_message_target_language']?.toString();
                final existingTargetLang =
                    existingEntry['last_message_target_language']?.toString();
                if ((incomingTargetLang == null ||
                        incomingTargetLang.isEmpty) &&
                    existingTargetLang != null &&
                    existingTargetLang.isNotEmpty) {
                  incoming['last_message_target_language'] = existingTargetLang;
                }
              } else if (incomingTranslated == null ||
                  incomingTranslated.isEmpty) {
                // Nothing usable in this sync. Drop any inherited marker so a
                // translation cached for a previous version of this message is
                // never re-adopted on the next sync — the edit changed the
                // content while keeping the id, so the id alone cannot catch it.
                incoming.remove('last_message_translated_edited_at');
              }
            }
          }

          // Archived chats must not fall off the list just because the server
          // page is limited: get_user_recent_chats returns the N most
          // recently active chats, and an archived chat stops receiving
          // activity by definition, so once archived it would drop out of
          // every subsequent sync page and vanish from the Archived view.
          // Keep cached archived rows that this (necessarily limited) page
          // did not include; when the server does include them again, its
          // authoritative archived_at row replaces the cached copy above.
          final incomingIds = <String>{
            for (final c in chats) c['match_id']?.toString() ?? '',
          };
          for (final cached in existingByMatch.values) {
            final mid = cached['match_id']?.toString() ?? '';
            if (mid.isEmpty || incomingIds.contains(mid)) continue;
            final archivedAt = cached['archived_at'];
            if (archivedAt != null &&
                archivedAt.toString().isNotEmpty &&
                archivedAt.toString() != 'null') {
              chats.add(cached);
            }
          }
        } catch (_) {
          // If merge fails for any reason, fall back to overwriting cache
        }
      }

      if (kIsWeb) {
        // print('🔍 [WEB] saveChats - Storing ${chats.length} chats to local DB key: $key');
        for (final _ in chats) {
          // print('🔍 [WEB] Storing Chat: match_id=${_['match_id']}, unread_count=${_['unread_count']}, other_user_name="${_['other_user_name']}", last_message="${_['last_message']}"');
        }
      }

      // Only write if the cache actually changed to avoid emitting duplicate
      // Hive watch events that cause the UI to rebuild unnecessarily.
      // Strip server-side metadata fields that can change without semantic
      // difference (e.g. updated_at from a database trigger) so that the
      // comparison only reflects meaningful user-visible data changes.
      List<Map<String, dynamic>> stripMeta(List<Map<String, dynamic>> rows) {
        return rows
            .map((r) => Map<String, dynamic>.from(r)..remove('updated_at'))
            .toList();
      }

      final newValue = jsonEncode(stripMeta(chats));
      final raw = box.get(key);
      final String currentValue = () {
        if (raw is String) {
          try {
            final decoded = jsonDecode(raw);
            if (decoded is List) {
              final parsed = decoded
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
              return jsonEncode(stripMeta(parsed));
            }
          } catch (_) {}
          return raw;
        }
        return '';
      }();
      if (currentValue == newValue) {
        if (kIsWeb) {
          // No-op: identical cache, skip write
        }
      } else {
        // Re-serialize with metadata for storage (so the cached copy is complete)
        await box.put(key, jsonEncode(chats));
      }

      if (kIsWeb) {
        // print('🔍 [WEB] saveChats - Successfully stored ${chats.length} chats');
      }
    } catch (e) {
      // print('LocalDb.saveChats failed: $e');
      if (kIsWeb) {
        // print('🔍 [WEB] saveChats - FAILED: $e');
        final box = await _getChatsBox();
        final key = 'recent_chats_$userId';
        final newValue = jsonEncode(chats);
        final currentValue = box.get(key);
        if (currentValue is String && currentValue == newValue) {
          if (kIsWeb) {
            // print('🔍 [WEB] saveChats - Skipping identical cache write for $key');
          }
        } else {
          await box.put(key, newValue);
        }
        try {
          final box = await _getChatsBox();
          final key = 'recent_chats_$userId';
          // Skip the merge logic and just save directly
          await box.put(key, jsonEncode(chats));
          // print('🔍 [WEB] saveChats - Recovered with simple save');
        } catch (recoveryError) {
          // print('🔍 [WEB] saveChats - Recovery also failed: $recoveryError');
        }
      }
      rethrow;
    }
  }

  /// Clear unread_count for a specific match in the cached recent chats for [userId].
  /// This is used to optimistically clear badges locally when a user enters a chat.
  Future<void> clearUnreadForMatch(String userId, String matchId) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;
    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List)
          .cast<Map<String, dynamic>>();
      bool changed = false;
      final updated = parsed.map((c) {
        if ((c['match_id']?.toString() ?? '') == matchId) {
          if ((c['unread_count'] ?? 0) != 0) {
            changed = true;
            final copy = Map<String, dynamic>.from(c);
            copy['unread_count'] = 0;
            return copy;
          }
        }
        return c;
      }).toList();
      if (changed) {
        await box.put(key, jsonEncode(updated));
      }
    } catch (_) {
      // ignore parse errors
    }
  }

  /// Mark that a 'translations auto-disabled' notification is pending for this match.
  /// Stored on the per-user recent chats entry if [userId] is provided, and on the global cache.
  Future<void> markTranslationNotificationPending(
    String matchId, {
    String? userId,
  }) async {
    final box = await _getChatsBox();

    // Global list
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List)
            .cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < chats.length; i++) {
          if (chats[i]['match_id'] == matchId) {
            if (chats[i]['translation_auto_disabled_unread'] != true) {
              chats[i]['translation_auto_disabled_unread'] = true;
              changed = true;
            }
          }
        }
        if (changed) await box.put(globalKey, jsonEncode(chats));
      } catch (_) {}
    }

    // Per-user key
    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List)
              .cast<Map<String, dynamic>>();
          var changed = false;
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId) {
              if (chats[i]['translation_auto_disabled_unread'] != true) {
                chats[i]['translation_auto_disabled_unread'] = true;
                changed = true;
              }
            }
          }
          if (changed) await box.put(userKey, jsonEncode(chats));
        } catch (_) {}
      }
    }
  }

  /// Check whether a 'translations auto-disabled' notification is pending for this match.
  Future<bool> isTranslationNotificationPending(
    String matchId, {
    String? userId,
  }) async {
    final box = await _getChatsBox();

    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List)
              .cast<Map<String, dynamic>>();
          for (final c in chats) {
            if ((c['match_id']?.toString() ?? '') == matchId) {
              if (c['translation_auto_disabled_unread'] == true) return true;
            }
          }
        } catch (_) {}
      }
    }

    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List)
            .cast<Map<String, dynamic>>();
        for (final c in chats) {
          if ((c['match_id']?.toString() ?? '') == matchId) {
            if (c['translation_auto_disabled_unread'] == true) return true;
          }
        }
      } catch (_) {}
    }

    return false;
  }

  /// Clear the 'translations auto-disabled' pending notification flag for this match.
  Future<void> clearTranslationNotificationPending(
    String matchId, {
    String? userId,
  }) async {
    final box = await _getChatsBox();

    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List)
            .cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < chats.length; i++) {
          if (chats[i]['match_id'] == matchId &&
              chats[i]['translation_auto_disabled_unread'] == true) {
            chats[i].remove('translation_auto_disabled_unread');
            changed = true;
          }
        }
        if (changed) await box.put(globalKey, jsonEncode(chats));
      } catch (_) {}
    }

    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List)
              .cast<Map<String, dynamic>>();
          var changed = false;
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId &&
                chats[i]['translation_auto_disabled_unread'] == true) {
              chats[i].remove('translation_auto_disabled_unread');
              changed = true;
            }
          }
          if (changed) await box.put(userKey, jsonEncode(chats));
        } catch (_) {}
      }
    }
  }

  /// Update translation flags for a specific match in the cached recent chats for [userId].
  Future<void> updateChatTranslation(
    String userId,
    String matchId,
    bool enabled,
    String? language,
  ) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;
    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List)
          .cast<Map<String, dynamic>>();
      bool changed = false;
      final updated = parsed.map((c) {
        if ((c['match_id']?.toString() ?? '') == matchId) {
          final copy = Map<String, dynamic>.from(c);
          final prevEnabled = (copy['translation_enabled'] ?? false) as bool;
          final prevLang = copy['translation_language'] as String?;
          if (prevEnabled != enabled || prevLang != language) {
            changed = true;
            copy['translation_enabled'] = enabled;
            copy['translation_language'] = language;
          }
          return copy;
        }
        return c;
      }).toList();
      if (changed) {
        await box.put(key, jsonEncode(updated));
      }
    } catch (_) {
      // Ignore errors - best-effort local cache update
    }
  }

  /// Check if translation is enabled for a specific match.
  Future<bool> isTranslationEnabled(String matchId, {String? userId}) async {
    final box = await _getChatsBox();
    // Try user-specific key first if userId provided
    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List)
              .cast<Map<String, dynamic>>();
          final chat = chats.firstWhere(
            (c) => (c['match_id']?.toString() ?? '') == matchId,
            orElse: () => <String, dynamic>{},
          );
          if (chat.isNotEmpty) {
            return (chat['translation_enabled'] ?? false) == true;
          }
        } catch (_) {}
      }
    }

    // Fallback to global key (legacy)
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List)
            .cast<Map<String, dynamic>>();
        final chat = chats.firstWhere(
          (c) => (c['match_id']?.toString() ?? '') == matchId,
          orElse: () => <String, dynamic>{},
        );
        if (chat.isNotEmpty) {
          return (chat['translation_enabled'] ?? false) == true;
        }
      } catch (_) {}
    }

    return false;
  }

  /// Whether the cached chat row for [matchId] is currently marked archived.
  /// Used by the chats realtime handler to skip no-op echoes of archive
  /// writes made on this device (best-effort: uncached rows report false).
  Future<bool> isChatCachedArchived(String userId, String matchId) async {
    try {
      final box = await _getChatsBox();
      final raw = box.get('recent_chats_$userId');
      if (raw == null) return false;
      final chats = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final c in chats) {
        if (c['match_id']?.toString() == matchId) {
          final v = c['archived_at']?.toString() ?? '';
          return v.isNotEmpty && v != 'null';
        }
      }
    } catch (_) {}
    return false;
  }

  /// Optimistically set the archived flag on cached chat rows for [userId]
  /// while the server write is in flight (see ChatArchiveService). Writing the
  /// cache fires the Hive watch that [watchChats] streams, so the chats list
  /// updates immediately; the next sync reconciles with the server's
  /// authoritative archived_at.
  Future<void> setChatsArchived(
    String userId,
    Set<String> matchIds,
    bool archived,
  ) async {
    if (matchIds.isEmpty) return;
    try {
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final raw = box.get(key);
      if (raw == null) return;
      final chats = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final stamp = archived ? DateTime.now().toUtc().toIso8601String() : null;
      var changed = false;
      final updated = chats.map((c) {
        final mid = c['match_id']?.toString() ?? '';
        if (!matchIds.contains(mid)) return c;
        final copy = Map<String, dynamic>.from(c);
        if ((copy['archived_at']?.toString() ?? '') != (stamp ?? '')) {
          copy['archived_at'] = stamp;
          changed = true;
        }
        return copy;
      }).toList();
      if (changed) {
        await box.put(key, jsonEncode(updated));
      }
    } catch (_) {
      // Best-effort local cache update — the server call and next sync
      // reconcile the state either way.
    }
  }

  Stream<List<Map<String, dynamic>>> watchChats(String userId) async* {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);

    List<Map<String, dynamic>> decodeChats(dynamic value) {
      try {
        if (value is! String) return const [];
        final decoded = jsonDecode(value);
        if (decoded is! List) return const [];
        return decoded
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      } catch (error) {
        debugPrint(
          '[LocalDb] Could not decode cached chats for $userId: $error',
        );
        return const [];
      }
    }

    if (kIsWeb) {
      // print('🔍 [WEB] watchChats - Watching key: $key');
    }

    if (currentChats != null) {
      final chats = decodeChats(currentChats);
      if (kIsWeb) {
        // print('🔍 [WEB] watchChats - Initial yield: ${chats.length} chats');
        for (final _ in chats) {
          // print('🔍 [WEB] Initial Chat: match_id=${_['match_id']}, unread_count=${_['unread_count']}, other_user_name="${_['other_user_name']}"');
        }
      }
      yield chats;
    } else {
      if (kIsWeb) {
        // print('🔍 [WEB] watchChats - Initial yield: no chats found');
      }
      yield [];
    }
    yield* box.watch(key: key).map((event) {
      final chats = event.value != null && !event.deleted
          ? decodeChats(event.value)
          : <Map<String, dynamic>>[];

      if (kIsWeb) {
        // print('🔍 [WEB] watchChats - Stream update: ${chats.length} chats');
        for (final _ in chats) {
          // print('🔍 [WEB] Stream Chat: match_id=${_['match_id']}, unread_count=${_['unread_count']}, other_user_name="${_['other_user_name']}"');
        }
      }

      return chats;
    });
  }

  // --- Chat Message Methods ---

  /// Tail of the serialized write chain per match.
  ///
  /// Every write to the messages box is a read-modify-write cycle: the whole
  /// conversation blob is decoded, mutated and written back. Two of those
  /// running at the same time (a realtime insert while the background prefetch
  /// appends a page, Phase 2 persisting decrypted text while a full sync
  /// replaces the blob, a reaction while the opening sync runs) interleave at
  /// their awaits: both read the same rows, and whichever writes last wins.
  /// The rows only the other cycle added are then silently lost — which is how
  /// a conversation could end up holding nothing but its newest message.
  /// Chaining the cycles per match makes each one atomic with respect to the
  /// others.
  final Map<String, Future<void>> _messagesWriteChains = {};

  /// Runs [action] after every previously queued write for [matchId].
  Future<T> _withMessagesWrite<T>(String matchId, Future<T> Function() action) {
    final previous = _messagesWriteChains[matchId] ?? Future<void>.value();
    final gate = Completer<void>();
    _messagesWriteChains[matchId] = gate.future;
    return previous.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
      if (identical(_messagesWriteChains[matchId], gate.future)) {
        _messagesWriteChains.remove(matchId);
      }
    });
  }

  Future<List<Map<String, dynamic>>> getMessages(String matchId) async {
    final box = await _getMessagesBox();
    final currentMessages = box.get(matchId);
    if (currentMessages != null) {
      try {
        final messages = (jsonDecode(currentMessages) as List)
            .cast<Map<String, dynamic>>();
        // Normalize ID fields to strings to prevent alignment bugs when
        // Supabase returns them as numbers (common on web) — the chat UI
        // compares senderId == currentUserId and a numeric type would
        // make the comparison fail, showing the message on the wrong side.
        for (final msg in messages) {
          if (msg['id'] != null && msg['id'] is! String) {
            msg['id'] = msg['id'].toString();
          }
          if (msg['sender_id'] != null && msg['sender_id'] is! String) {
            msg['sender_id'] = msg['sender_id'].toString();
          }
          if (msg['match_id'] != null && msg['match_id'] is! String) {
            msg['match_id'] = msg['match_id'].toString();
          }
        }
        // NOTE: We intentionally do NOT decrypt `content_*_encrypted_cache`
        // here. Decrypting every cached message is a sequential AES-GCM loop
        // (~ms per message, all on the single Dart isolate), so a chat with
        // 100+ cached messages would block this Future for 10+ seconds and
        // leave the chat UI stuck on its loading spinner until it returns.
        // The chat-key provider (chatKeyProvider) is the source of truth for
        // decryption; the chat provider's Phase 2 loop decrypts messages
        // in parallel via Future.wait and persists the result through
        // `mergeMessages`. The cache itself remains in the row for the
        // locked-user fallback (no chat key available) — Phase 2's
        // `if (decryptedOriginal == null) { decryptFromCache(...) }` block
        // reads it directly.
        return messages;
      } catch (_) {
        return [];
      }
    }
    return [];
  }

  /// Decoded-row cache used by [getMessagesSnapshot]: per matchId, the raw
  /// Hive string is held alongside its decoded rows so the cache can be
  /// validated against the current raw value (any write produces a different
  /// string → cache miss → re-decode; a stale entry can never be served).
  final Map<String, (String, List<Map<String, dynamic>>)> _messagesDecodeCache =
      {};

  /// Cached-decode counterpart of [getMessages].
  ///
  /// Every chat entry re-reads the whole conversation blob once per message
  /// that needs a translation resolution (translationFamilyProvider) and a
  /// handful of bookkeeping lookups — and each of those calls used to repeat
  /// the full `jsonDecode` of the chat history on the UI isolate. With one
  /// read per bubble this was O(N) full-blob decodes of the same list, and
  /// the decode cost showed up on screen as previously received messages
  /// rendering visibly later than the outgoing ones when the chat is
  /// re-entered.
  ///
  /// Callers get fresh top-level row copies (mirroring getMessages' own
  /// normalization mutation) so shared cached state is never mutated.
  Future<List<Map<String, dynamic>>> getMessagesSnapshot(String matchId) async {
    final box = await _getMessagesBox();
    final raw = box.get(matchId);
    if (raw == null) return const [];
    final cached = _messagesDecodeCache[matchId];
    if (cached != null && cached.$1 == raw) {
      return cached.$2.map((m) => Map<String, dynamic>.from(m)).toList();
    }
    final List<Map<String, dynamic>> decoded;
    try {
      decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
    for (final msg in decoded) {
      if (msg['id'] != null && msg['id'] is! String) {
        msg['id'] = msg['id'].toString();
      }
      if (msg['sender_id'] != null && msg['sender_id'] is! String) {
        msg['sender_id'] = msg['sender_id'].toString();
      }
      if (msg['match_id'] != null && msg['match_id'] is! String) {
        msg['match_id'] = msg['match_id'].toString();
      }
    }
    _messagesDecodeCache[matchId] = (raw, decoded);
    return decoded.map((m) => Map<String, dynamic>.from(m)).toList();
  }

  /// Full-text search across cached message bodies.
  ///
  /// Runs entirely on-device. Messages are end-to-end encrypted, so the server
  /// holds only ciphertext and *cannot* search them — shipping a trigram index
  /// or plaintext search would mean handing the server every message, which
  /// would undo the product's core privacy property. Searching locally is not
  /// a compromise here; it is the only design that keeps the promise.
  ///
  /// Scope is the messages cached for [matchIds], i.e. chats this device has
  /// already synced. Anything never fetched cannot be decrypted here, so it is
  /// not searchable — that limit is inherent to the encryption, not a shortcut.
  ///
  /// Yielding to the event loop between chats keeps the UI responsive; the
  /// per-chat decode of a large history is not free.
  Future<List<MessageSearchHit>> searchCachedMessages(
    String query, {
    required List<String> matchIds,
    int maxMessagesPerChat = 400,
    int maxHits = 200,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty || matchIds.isEmpty) return const [];

    final box = await _getMessagesBox();
    final hits = <MessageSearchHit>[];

    for (final matchId in matchIds) {
      if (hits.length >= maxHits) break;
      final raw = box.get(matchId);
      if (raw == null) continue;

      final List<Map<String, dynamic>> messages;
      try {
        messages = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        continue;
      }

      // Newest first: the most recent thing said is what people usually mean.
      final start = messages.length > maxMessagesPerChat
          ? messages.length - maxMessagesPerChat
          : 0;

      for (var i = messages.length - 1; i >= start; i--) {
        if (hits.length >= maxHits) break;
        final msg = messages[i];
        final id = msg['id']?.toString() ?? '';

        var matched = false;
        for (final field in const [
          ('content_original', 'original'),
          ('content_translated', 'translated'),
          ('translated_text', 'translated'),
          ('reply_to_content', 'reply'),
          ('reply_to_content_translated', 'reply'),
        ]) {
          final text = msg[field.$1]?.toString();
          if (text == null || text.isEmpty) continue;
          if (!text.toLowerCase().contains(needle)) continue;

          hits.add(
            MessageSearchHit(
              matchId: matchId,
              messageId: id,
              field: field.$2,
              senderId: msg['sender_id']?.toString() ?? '',
              createdAt: msg['created_at']?.toString() ?? '',
              snippet: _searchSnippet(text, needle),
            ),
          );
          // One hit per message keeps the result list readable; the first
          // field that matches wins.
          matched = true;
          break;
        }
        if (matched) continue;

        // Same field coverage as the in-chat search, but for end-to-end
        // encrypted rows the server returns null plaintext: the decrypted
        // text lives only in the local DCK-encrypted backup. Decrypt it
        // lazily (only when plaintext didn't match) so encrypted chats are
        // searchable exactly like open chats.
        for (final field in const [
          ('content_original_encrypted_cache', 'original'),
          ('content_translated_encrypted_cache', 'translated'),
        ]) {
          final cached = msg[field.$1]?.toString();
          if (cached == null || cached.isEmpty) continue;
          String? text;
          try {
            text = await EncryptedCacheService.instance.decryptFromCache(
              cached,
            );
          } catch (_) {
            text = null;
          }
          if (text == null || text.isEmpty) continue;
          if (!text.toLowerCase().contains(needle)) continue;
          hits.add(
            MessageSearchHit(
              matchId: matchId,
              messageId: id,
              field: field.$2,
              senderId: msg['sender_id']?.toString() ?? '',
              createdAt: msg['created_at']?.toString() ?? '',
              snippet: _searchSnippet(text, needle),
            ),
          );
          break;
        }

        // Keep the UI responsive while walking large encrypted histories:
        // the decrypt above is sequential local AES, so yield periodically.
        if ((messages.length - 1 - i) % 25 == 24) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      // Give the event loop a turn so a large search cannot jank the list.
      await Future<void>.delayed(Duration.zero);
    }

    return hits;
  }

  /// A window of [text] around the first case-insensitive [needle].
  static String _searchSnippet(String text, String needle, {int radius = 42}) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final index = flat.toLowerCase().indexOf(needle);
    if (index < 0) return flat;
    if (flat.length <= radius * 2) return flat;

    var start = index - radius;
    if (start < 0) start = 0;
    var end = index + needle.length + radius;
    if (end > flat.length) end = flat.length;

    final prefix = start > 0 ? '…' : '';
    final suffix = end < flat.length ? '…' : '';
    return '$prefix${flat.substring(start, end)}$suffix';
  }

  Future<String?> getLatestMessageTimestamp(String matchId) async {
    final messages = await getMessages(matchId);
    if (messages.isEmpty) {
      return null;
    }
    messages.sort((a, b) {
      final aDate = DateTime.tryParse(a['created_at'] ?? '');
      final bDate = DateTime.tryParse(b['created_at'] ?? '');
      if (aDate == null) return -1;
      if (bDate == null) return 1;
      return bDate.compareTo(aDate);
    });
    return messages.first['created_at'] as String?;
  }

  /// Prefix of the settings key that records when a conversation was last
  /// downloaded *in full* from the server.
  static const String messagesSyncedAtKeyPrefix = 'messages_synced_at_';

  /// Records that the local cache for [matchId] is a complete copy of the
  /// server-side conversation.
  ///
  /// The background prefetch downloads every conversation right after sign-in
  /// so the user never has to wait when opening a chat. This marker lets the
  /// chat screen know that the copy it is about to show is already the full
  /// conversation, so it does not have to download the whole history again.
  ///
  /// [messageCount] is the number of messages that download produced. It is
  /// stored alongside the time so a later reader can verify that the cache
  /// still holds at least that many rows: a cache that shrank (a lost write, a
  /// cleared box) is no longer trusted and is downloaded again in full instead
  /// of spending another incremental pass on top of a truncated history. Pass
  /// `null` to keep the previously recorded count.
  Future<void> markMessagesSynced(
    String matchId, {
    DateTime? at,
    int? messageCount,
  }) async {
    if (matchId.isEmpty) return;
    try {
      final box = await _getSettingsBox();
      final key = '$messagesSyncedAtKeyPrefix$matchId';
      final count =
          messageCount ?? _parseMessagesSyncState(box.get(key))?.count ?? 0;
      await box.put(
        key,
        jsonEncode({
          'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
          'count': count,
        }),
      );
    } catch (_) {
      // Best effort: a missing marker only costs one extra download.
    }
  }

  /// When the conversation for [matchId] was last downloaded in full, or
  /// `null` when it is unknown (or was cleared).
  Future<DateTime?> getMessagesSyncedAt(String matchId) async =>
      (await getMessagesSyncState(matchId))?.at;

  /// The completeness marker of the local cache for [matchId]: when it was
  /// last downloaded in full and how many messages that download produced.
  Future<({DateTime at, int count})?> getMessagesSyncState(
    String matchId,
  ) async {
    if (matchId.isEmpty) return null;
    try {
      final box = await _getSettingsBox();
      return _parseMessagesSyncState(
        box.get('$messagesSyncedAtKeyPrefix$matchId'),
      );
    } catch (_) {
      return null;
    }
  }

  static ({DateTime at, int count})? _parseMessagesSyncState(dynamic raw) {
    if (raw == null) return null;
    final text = raw.toString();
    if (text.isEmpty || text == 'null') return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final at = DateTime.tryParse(decoded['at']?.toString() ?? '');
        if (at == null) return null;
        final countRaw = decoded['count'];
        final count = countRaw is int
            ? countRaw
            : int.tryParse(countRaw?.toString() ?? '') ?? 0;
        return (at: at.toUtc(), count: count);
      }
    } catch (_) {
      // Older markers stored the timestamp on its own.
    }
    final at = DateTime.tryParse(text);
    return at == null ? null : (at: at.toUtc(), count: 0);
  }

  Future<Map<String, dynamic>?> getMessageById(
    String matchId,
    String messageId,
  ) async {
    final messages = await getMessages(matchId);
    try {
      return messages.firstWhere((m) => m['id'].toString() == messageId);
    } catch (e) {
      return null;
    }
  }

  /// Get a locally cached profile (if any) for a user id.
  Future<Map<String, dynamic>?> getLocalProfile(String userId) async {
    final box = await _getProfileBox();
    final stored = box.get(userId);
    if (stored == null) return null;
    try {
      return jsonDecode(stored) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Local cache helpers for reactors per-message. Reactors are stored inside the message
  /// object under a key `reactors` which is a map from reaction string -> List<Map>
  /// Each reactor map shape: { user_id, display_name?, photo? }
  Future<List<Map<String, dynamic>>> getCachedReactors(
    String matchId,
    String messageId,
    String reaction,
  ) async {
    final msg = await getMessageById(matchId, messageId);
    if (msg == null) return [];
    final reactorsContainer = msg['reactors'];
    if (reactorsContainer is Map) {
      final list = reactorsContainer[reaction];
      if (list is List) {
        try {
          return list.cast<Map<String, dynamic>>();
        } catch (_) {
          // fallback: attempt to coerce
          return list
              .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();
        }
      }
    }
    return [];
  }

  Future<void> saveCachedReactors(
    String matchId,
    String messageId,
    String reaction,
    List<Map<String, dynamic>> reactors,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _saveCachedReactorsUnlocked(matchId, messageId, reaction, reactors),
    );
  }

  Future<void> _saveCachedReactorsUnlocked(
    String matchId,
    String messageId,
    String reaction,
    List<Map<String, dynamic>> reactors,
  ) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);
    final index = messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (index == -1) return;
    final msg = Map<String, dynamic>.from(messages[index]);
    final reactorsContainer = (msg['reactors'] is Map)
        ? Map<String, dynamic>.from(msg['reactors'])
        : <String, dynamic>{};

    // Deduplicate reactors by user_id before saving
    final seenUserIds = <String>{};
    final deduplicatedReactors = reactors.where((r) {
      final userId = r['user_id'] as String?;
      if (userId == null || seenUserIds.contains(userId)) {
        return false;
      }
      seenUserIds.add(userId);
      return true;
    }).toList();

    reactorsContainer[reaction] = deduplicatedReactors;
    msg['reactors'] = reactorsContainer;
    messages[index] = msg;
    await box.put(matchId, jsonEncode(messages));
  }

  Future<void> clearMessageReactorCache(String matchId, String messageId) {
    return _withMessagesWrite(
      matchId,
      () => _clearMessageReactorCacheUnlocked(matchId, messageId),
    );
  }

  Future<void> _clearMessageReactorCacheUnlocked(
    String matchId,
    String messageId,
  ) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);
    final index = messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (index == -1) return;
    final msg = Map<String, dynamic>.from(messages[index]);
    if (msg.containsKey('reactors')) {
      msg.remove('reactors');
      messages[index] = msg;
      await box.put(matchId, jsonEncode(messages));
    }
  }

  /// Adds new messages to local cache and marks them as delivered locally.
  /// Returns list of message IDs that should have their delivery status synced to the server.
  Future<List<String>> addMessages(
    String matchId,
    List<Map<String, dynamic>> newMessages, {
    String? currentUserId,
  }) {
    return _withMessagesWrite(
      matchId,
      () => _addMessagesUnlocked(
        matchId,
        newMessages,
        currentUserId: currentUserId,
      ),
    );
  }

  Future<List<String>> _addMessagesUnlocked(
    String matchId,
    List<Map<String, dynamic>> newMessages, {
    String? currentUserId,
  }) async {
    if (newMessages.isEmpty) {
      return [];
    }
    final box = await _getMessagesBox();
    final oldMessages = await getMessages(matchId);
    final existingIds = <dynamic>{};
    final oldById = <String, Map<String, dynamic>>{};
    for (final m in oldMessages) {
      final id = m['id']?.toString();
      if (id != null) {
        existingIds.add(id);
        oldById[id] = m;
      }
    }
    final uniqueNewMessages = <Map<String, dynamic>>[];
    final mergeUpdates = <Map<String, dynamic>>[];
    for (final m in newMessages) {
      final id = m['id']?.toString();
      if (id != null && existingIds.contains(id)) {
        // The sender's own optimistic message can be echoed back from the
        // realtime subscription with the same id.  In that case we need to
        // clear `isPending` (the server doesn't carry that field) so the
        // bubble flips from the clock icon to the single checkmark the
        // moment Supabase confirms the row.  Without this, the optimistic
        // row is never updated and the bubble stays stuck on the clock
        // until the next full sync.
        final old = oldById[id];
        if (old != null && old['isPending'] == true) {
          print(
            '✅ [addMessages] Server echo for own optimistic msg=$id — clearing isPending',
          );
          mergeUpdates.add({'id': id, 'isPending': false});
        }
      } else {
        uniqueNewMessages.add(m);
      }
    }

    if (uniqueNewMessages.isEmpty && mergeUpdates.isEmpty) {
      return [];
    }

    if (uniqueNewMessages.isNotEmpty) {
      print('✅ [addMessages] Adding ${uniqueNewMessages.length} new messages');
    }
    if (mergeUpdates.isNotEmpty) {
      print(
        '✅ [addMessages] Merging status for ${mergeUpdates.length} existing message(s) (isPending=false)',
      );
    }

    final messagesToMarkDelivered = <String>[];

    // Do NOT mark new messages as delivered locally
    // The actual server sync will happen via RPC calls in the background
    for (final msg in uniqueNewMessages) {
      final msgId = msg['id'];
      final senderId = msg['sender_id'];
      final _ = msg['delivered_at'];
      // print('📥 addMessages: Processing message $msgId (delivered_at=$_, sender=$senderId)');

      // IMPORTANT: Do NOT mark incoming messages as delivered locally!
      // Only queue them for RPC marking. The server will update delivered_at.
      // When messages are re-synced, they'll have the actual server delivered_at value.
      if (currentUserId != null &&
          senderId != null &&
          senderId != currentUserId &&
          (msg['delivered_at'] == null || msg['delivered_at'] == '')) {
        messagesToMarkDelivered.add(msgId.toString());
        // print('📤 addMessages: Queued $msgId for RPC delivery marking (from other user)');
      }
    }

    // Apply the isPending=false merge updates on the existing rows.
    Map<String, Map<String, dynamic>> workingById = {
      for (final m in oldMessages)
        (m['id']?.toString() ?? ''): Map<String, dynamic>.from(m),
    };
    for (final upd in mergeUpdates) {
      final id = upd['id']?.toString();
      if (id != null && workingById.containsKey(id)) {
        workingById[id]!.addAll(upd);
      }
    }
    final working = workingById.values.toList();
    final combinedMessages = [...working, ...uniqueNewMessages];
    await box.put(matchId, jsonEncode(combinedMessages));
    print('✅ [addMessages] Total: ${combinedMessages.length} messages');

    return messagesToMarkDelivered;
  }

  Future<void> replaceMessage(
    String matchId,
    String tempId,
    Map<String, dynamic> realMessage,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _replaceMessageUnlocked(matchId, tempId, realMessage),
    );
  }

  Future<void> _replaceMessageUnlocked(
    String matchId,
    String tempId,
    Map<String, dynamic> realMessage,
  ) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);

    final index = messages.indexWhere((m) => m['id'] == tempId);

    if (index != -1) {
      messages[index] = realMessage;
      await box.put(matchId, jsonEncode(messages));
    } else {
      // Ignore returned delivery messages for replaceMessage
      await _addMessagesUnlocked(matchId, [realMessage]);
    }
  }

  /// Lightweight, status-only update for a single message.
  ///
  /// Updates only the status fields passed in (read_at / delivered_at /
  /// reaction_summary / my_reaction / edited_at / content_original) for the
  /// matching message and writes the list back to the messages box.  No full
  /// re-query or re-decrypt is performed — this is the path used when a
  /// realtime event reports that only the delivery/read/react state of a
  /// message changed, so the chat UI updates the checkmark/double-check
  /// instantly without triggering a multi-second re-sync.
  ///
  /// Any parameter left as `null` is left untouched.  Pass
  /// [clearMyReaction] = true to explicitly remove the local `my_reaction`
  /// marker.
  Future<void> mergeMessageStatus(
    String matchId,
    String messageId, {
    String? deliveredAt,
    String? readAt,
    Map? reactionSummary,
    String? myReaction,
    bool clearMyReaction = false,
    String? editedAt,
    String? contentOriginal,
  }) {
    return _withMessagesWrite(
      matchId,
      () => _mergeMessageStatusUnlocked(
        matchId,
        messageId,
        deliveredAt: deliveredAt,
        readAt: readAt,
        reactionSummary: reactionSummary,
        myReaction: myReaction,
        clearMyReaction: clearMyReaction,
        editedAt: editedAt,
        contentOriginal: contentOriginal,
      ),
    );
  }

  Future<void> _mergeMessageStatusUnlocked(
    String matchId,
    String messageId, {
    String? deliveredAt,
    String? readAt,
    Map? reactionSummary,
    String? myReaction,
    bool clearMyReaction = false,
    String? editedAt,
    String? contentOriginal,
  }) async {
    if (matchId.isEmpty || messageId.isEmpty) return;
    try {
      final box = await _getMessagesBox();
      final messages = await getMessages(matchId);
      final index = messages.indexWhere(
        (m) => m['id']?.toString() == messageId,
      );
      if (index == -1) return;
      final msg = Map<String, dynamic>.from(messages[index]);
      var changed = false;
      if (deliveredAt != null && msg['delivered_at'] != deliveredAt) {
        msg['delivered_at'] = deliveredAt;
        changed = true;
      }
      if (readAt != null && msg['read_at'] != readAt) {
        msg['read_at'] = readAt;
        changed = true;
      }
      if (reactionSummary != null) {
        // Normalize keys/values to match mergeMessages so equality works.
        // Accepts `Map<dynamic, dynamic>` shapes from realtime payloads and
        // coerces to `Map<String, int>` for the local cache.
        final cleaned = <String, int>{};
        reactionSummary.forEach((k, v) {
          final key = k.toString().trim();
          if (key.isEmpty) return;
          final intVal = v is int
              ? v
              : (v is num ? v.toInt() : (int.tryParse(v.toString()) ?? 0));
          if (intVal > 0) cleaned[key] = intVal;
        });
        final existing = msg['reaction_summary'];
        final isSame =
            existing is Map &&
            existing.length == cleaned.length &&
            cleaned.entries.every((e) => existing[e.key] == e.value);
        if (!isSame) {
          msg['reaction_summary'] = cleaned;
          changed = true;
        }
      }
      if (clearMyReaction) {
        if (msg.containsKey('my_reaction')) {
          msg.remove('my_reaction');
          changed = true;
        }
      } else if (myReaction != null && msg['my_reaction'] != myReaction) {
        msg['my_reaction'] = myReaction;
        changed = true;
      }
      if (editedAt != null && msg['edited_at'] != editedAt) {
        msg['edited_at'] = editedAt;
        changed = true;
      }
      if (contentOriginal != null &&
          msg['content_original'] != contentOriginal) {
        msg['content_original'] = contentOriginal;
        changed = true;
      }
      if (!changed) return;
      messages[index] = msg;
      await box.put(matchId, jsonEncode(messages));
    } catch (_) {
      // Best-effort: a status-only merge failure must not break the chat UI.
    }
  }

  Future<void> mergeMessageStatuses(
    String matchId,
    List<Map<String, dynamic>> statuses,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _mergeMessageStatusesUnlocked(matchId, statuses),
    );
  }

  Future<void> _mergeMessageStatusesUnlocked(
    String matchId,
    List<Map<String, dynamic>> statuses,
  ) async {
    if (matchId.isEmpty || statuses.isEmpty) return;
    try {
      final box = await _getMessagesBox();
      final messages = await getMessages(matchId);
      if (messages.isEmpty) return;

      final indexById = <String, int>{
        for (var i = 0; i < messages.length; i++)
          if (messages[i]['id'] != null) messages[i]['id'].toString(): i,
      };

      DateTime? parseInstant(dynamic value) {
        final text = value?.toString();
        if (text == null || text.isEmpty) return null;
        return DateTime.tryParse(text)?.toUtc();
      }

      var changed = false;
      for (final status in statuses) {
        final id = status['id']?.toString();
        if (id == null || id.isEmpty) continue;
        final index = indexById[id];
        if (index == null) continue;

        final msg = Map<String, dynamic>.from(messages[index]);
        final serverDelivered = parseInstant(status['delivered_at']);
        final serverRead = parseInstant(status['read_at']);

        final localDeliveredInstant = parseInstant(msg['delivered_at']);
        if (serverDelivered != null &&
            (localDeliveredInstant == null ||
                serverDelivered.isAfter(localDeliveredInstant))) {
          msg['delivered_at'] = status['delivered_at'].toString();
          changed = true;
        }

        final localReadInstant = parseInstant(msg['read_at']);
        if (serverRead != null &&
            (localReadInstant == null ||
                serverRead.isAfter(localReadInstant))) {
          msg['read_at'] = status['read_at'].toString();
          changed = true;
        }

        if (changed) messages[index] = msg;
      }

      if (!changed) return;
      final newData = jsonEncode(messages);
      if (newData != box.get(matchId)) {
        await box.put(matchId, newData);
      }
    } catch (_) {
      // Best-effort reconciliation; the next full sync covers any failure.
    }
  }

  Future<void> mergeMessages(
    String matchId,
    List<Map<String, dynamic>> incomingMessages,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _mergeMessagesUnlocked(matchId, incomingMessages),
    );
  }

  Future<void> _mergeMessagesUnlocked(
    String matchId,
    List<Map<String, dynamic>> incomingMessages,
  ) async {
    final box = await _getMessagesBox();
    final oldMessages = await getMessages(matchId);

    final Map<String, Map<String, dynamic>> messageMap = {
      for (var msg in oldMessages) msg['id'].toString(): msg,
    };

    for (var incomingMsg in incomingMessages) {
      final oldMsg = messageMap[incomingMsg['id'].toString()];
      final oldTranslation = oldMsg?['translated_text'] as String?;
      final oldTranslationLang = oldMsg?['translated_lang'] as String?;
      final oldReactionSummary = oldMsg?['reaction_summary'];
      final oldMyReaction = oldMsg?['my_reaction'] as String?;

      // Detect an edit: the original content (plaintext or ciphertext) or
      // edited_at changed. In that case any cached translation of the OLD
      // content is stale and must be dropped instead of preserved — the
      // message needs to be retranslated for the current UI language.
      bool originalContentChanged = false;
      bool contentChanged = false;
      if (oldMsg != null) {
        final oldOriginal = oldMsg['content_original']?.toString();
        final hasNewOriginal = incomingMsg.containsKey('content_original');
        final newOriginal = hasNewOriginal
            ? incomingMsg['content_original']?.toString()
            : null;
        if (hasNewOriginal &&
            newOriginal != null &&
            newOriginal.isNotEmpty &&
            newOriginal != 'null' &&
            oldOriginal != null &&
            oldOriginal.isNotEmpty &&
            oldOriginal != 'null' &&
            newOriginal != oldOriginal) {
          contentChanged = true;
          originalContentChanged = true;
        }
        final hasNewEnc = incomingMsg.containsKey('content_original_encrypted');
        final newEnc = hasNewEnc
            ? incomingMsg['content_original_encrypted']?.toString()
            : null;
        final oldEnc = oldMsg['content_original_encrypted']?.toString();
        if (hasNewEnc &&
            newEnc != null &&
            newEnc.isNotEmpty &&
            oldEnc != null &&
            oldEnc.isNotEmpty &&
            newEnc != oldEnc) {
          contentChanged = true;
          originalContentChanged = true;
        }
        final hasNewEdited = incomingMsg.containsKey('edited_at');
        final newEdited = hasNewEdited
            ? incomingMsg['edited_at']?.toString()
            : null;
        final oldEdited = oldMsg['edited_at']?.toString();
        if (hasNewEdited &&
            newEdited != null &&
            newEdited.isNotEmpty &&
            newEdited != oldEdited) {
          contentChanged = true;
          originalContentChanged = true;
        }
        // Server clears the encrypted translation payload on edit
        // (edit_chat_message sets content_translated_encrypted = NULL).
        // If the incoming row drops a previously-present encrypted
        // translation without supplying fresh plaintext, treat it as an
        // edit so the stale local plaintext is not kept.
        if (incomingMsg.containsKey('content_translated_encrypted') &&
            incomingMsg['content_translated_encrypted'] == null &&
            oldMsg['content_translated_encrypted'] != null) {
          final freshPlain = incomingMsg['content_translated']?.toString();
          if (freshPlain == null || freshPlain.isEmpty) {
            contentChanged = true;
          }
        }
      }

      // Prefer incoming server-side values when present (e.g., updated reaction_summary)
      // Fall back to old local values only when incoming doesn't provide them.
      // Normalize reaction_summary keys: remove empty keys and coerce values to int
      Map<String, int>? normalizeReactionSummary(dynamic rs) {
        if (rs == null) return null;
        if (rs is Map) {
          final out = <String, int>{};
          rs.forEach((k, v) {
            final key = (k?.toString() ?? '').trim();
            if (key.isEmpty) return; // drop empty keys
            final intVal = (v is num)
                ? v.toInt()
                : int.tryParse(v?.toString() ?? '') ?? 0;
            if (intVal > 0) out[key] = intVal;
          });
          return out;
        }
        return null;
      }

      final mergedReactionSummary =
          normalizeReactionSummary(incomingMsg['reaction_summary']) ??
          normalizeReactionSummary(oldReactionSummary);
      final mergedMyReaction = (incomingMsg['my_reaction'] == ''
          ? null
          : (incomingMsg['my_reaction'] ?? oldMyReaction));

      // Use server translation if available, otherwise fall back to local cache
      // This ensures new translations from translate-proxy aren't overwritten.
      // When the message content was edited, the old cached translation is
      // stale and must NOT be preserved — the message needs retranslation.
      final incomingTranslation = incomingMsg['content_translated'] as String?;
      final incomingTranslationLang =
          incomingMsg['translated_target_language'] as String?;

      final mergedTranslation = contentChanged
          ? ((incomingTranslation != null && incomingTranslation.isNotEmpty)
                ? incomingTranslation
                : null)
          : ((incomingTranslation != null && incomingTranslation.isNotEmpty)
                ? incomingTranslation
                : oldTranslation);
      final mergedTranslationLang = contentChanged
          ? ((incomingTranslationLang != null &&
                    incomingTranslationLang.isNotEmpty)
                ? incomingTranslationLang
                : null)
          : ((incomingTranslationLang != null &&
                    incomingTranslationLang.isNotEmpty)
                ? incomingTranslationLang
                : oldTranslationLang);

      final mergedRow = {
        ...?oldMsg,
        ...incomingMsg,
        'translated_text': mergedTranslation,
        'translated_lang': mergedTranslationLang,
        'reaction_summary': mergedReactionSummary,
        'my_reaction': mergedMyReaction,
      };

      if (!originalContentChanged) {
        // Preserve locally decrypted content_original and encrypted cache
        // when server / realtime updates (e.g. read_at, delivery receipts, reactions)
        // return rows without decrypted plaintext.
        if (oldMsg != null) {
          final incomingOrig = incomingMsg['content_original']?.toString();
          if (incomingOrig == null ||
              incomingOrig.isEmpty ||
              incomingOrig == 'null') {
            final oldOrig = oldMsg['content_original']?.toString();
            if (oldOrig != null && oldOrig.isNotEmpty && oldOrig != 'null') {
              mergedRow['content_original'] = oldOrig;
            }
          }
          final incomingTrans = incomingMsg['content_translated']?.toString();
          if (incomingTrans == null ||
              incomingTrans.isEmpty ||
              incomingTrans == 'null') {
            final oldTrans = oldMsg['content_translated']?.toString();
            if (oldTrans != null && oldTrans.isNotEmpty && oldTrans != 'null') {
              mergedRow['content_translated'] = oldTrans;
            }
          }
          if (mergedRow['content_original_encrypted_cache'] == null &&
              oldMsg['content_original_encrypted_cache'] != null) {
            mergedRow['content_original_encrypted_cache'] =
                oldMsg['content_original_encrypted_cache'];
          }
          if (mergedRow['content_translated_encrypted_cache'] == null &&
              oldMsg['content_translated_encrypted_cache'] != null) {
            mergedRow['content_translated_encrypted_cache'] =
                oldMsg['content_translated_encrypted_cache'];
          }
        }
      }

      // If content_original is still empty but we have an encrypted cache backup,
      // recover the plaintext immediately so the UI is never stuck on "Loading...".
      if ((mergedRow['content_original'] == null ||
              mergedRow['content_original'].toString().isEmpty ||
              mergedRow['content_original'] == 'null') &&
          mergedRow['content_original_encrypted_cache'] != null) {
        final cached = mergedRow['content_original_encrypted_cache'].toString();
        if (cached.isNotEmpty) {
          try {
            final restored = await EncryptedCacheService.instance
                .decryptFromCache(cached);
            if (restored != null && restored.isNotEmpty) {
              mergedRow['content_original'] = restored;
            }
          } catch (_) {}
        }
      }

      if (!contentChanged) {
        final incomingReplyTrans =
            incomingMsg['reply_to_content_translated'] as String?;
        if ((incomingReplyTrans == null || incomingReplyTrans.isEmpty) &&
            oldMsg != null) {
          final oldReplyTrans =
              oldMsg['reply_to_content_translated'] as String?;
          if (oldReplyTrans != null && oldReplyTrans.isNotEmpty) {
            mergedRow['reply_to_content_translated'] = oldReplyTrans;
          }
        }
        // Preserve locally resolved reply originals/senders + offline
        // fallbacks that the server never sends (only reply_to_message_id).
        if (oldMsg != null) {
          final incomingReplyContent = incomingMsg['reply_to_content']
              ?.toString();
          if ((incomingReplyContent == null || incomingReplyContent.isEmpty)) {
            final oldReplyContent = oldMsg['reply_to_content']?.toString();
            if (oldReplyContent != null && oldReplyContent.isNotEmpty) {
              mergedRow['reply_to_content'] = oldReplyContent;
              final oldReplySender = oldMsg['reply_to_sender_id'];
              if (oldReplySender != null) {
                mergedRow['reply_to_sender_id'] = oldReplySender;
              }
            }
          }
          if (mergedRow['reactors'] == null && oldMsg['reactors'] is Map) {
            mergedRow['reactors'] = oldMsg['reactors'];
          }
        }
      }
      if (contentChanged) {
        // Drop stale local plaintext translation caches when the content
        // changed and no fresh translation was supplied. Otherwise the
        // spread above would keep the old translation and the UI would
        // show it as if it were for the new content.
        final freshTranslated = incomingMsg['content_translated']?.toString();
        if (freshTranslated == null || freshTranslated.isEmpty) {
          mergedRow.remove('content_translated');
          mergedRow.remove('content_translated_encrypted_cache');
        }
        final freshTarget = incomingMsg['translated_target_language']
            ?.toString();
        if (freshTarget == null || freshTarget.isEmpty) {
          mergedRow.remove('translated_target_language');
        }
        if (mergedTranslation == null) {
          mergedRow.remove('translated_text');
        }
        if (mergedTranslationLang == null) {
          mergedRow.remove('translated_lang');
        }
        // When the ciphertext changed but no fresh decrypted plaintext was
        // supplied (the typical realtime edit payload carries only encrypted
        // columns), drop the stale decrypted original so Phase 2 re-decrypts
        // the new ciphertext instead of reusing the old text.
        // ONLY drop when the original ciphertext or edited_at genuinely changed!
        if (originalContentChanged) {
          final freshOriginal = incomingMsg['content_original']?.toString();
          final hasNewEncForOriginal = incomingMsg.containsKey(
            'content_original_encrypted',
          );
          if ((freshOriginal == null ||
                  freshOriginal.isEmpty ||
                  freshOriginal == 'null') &&
              hasNewEncForOriginal) {
            mergedRow.remove('content_original');
            mergedRow.remove('content_original_encrypted_cache');
          }
        }
      }
      messageMap[incomingMsg['id'].toString()] = mergedRow;
    }

    final combinedList = messageMap.values.toList();

    combinedList.sort((a, b) {
      final aDate =
          DateTime.tryParse(a['created_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bDate =
          DateTime.tryParse(b['created_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return aDate.compareTo(bDate);
    });

    // Normalize any reaction_summary in the combined list before persisting to avoid
    // storing empty-string keys or non-integer counts.
    for (final msg in combinedList) {
      final rs = msg['reaction_summary'];
      if (rs is Map) {
        final cleaned = <String, int>{};
        rs.forEach((k, v) {
          final key = (k?.toString() ?? '').trim();
          if (key.isEmpty) return;
          final intVal = (v is num)
              ? v.toInt()
              : int.tryParse(v?.toString() ?? '') ?? 0;
          if (intVal > 0) cleaned[key] = intVal;
        });
        msg['reaction_summary'] = cleaned;
      }
    }

    // Memory + local storage: backfill the DCK-encrypted backup for any newly
    // decrypted plaintext merged here (e.g. Phase 2 writes via mergeMessages).
    // Without this, the backup only exists after saveMessages, so a restart
    // before the next full sync would lose the offline-decrypt fallback.
    try {
      final cacheService = EncryptedCacheService.instance;
      if (cacheService.currentDck != null) {
        for (final msg in combinedList) {
          final scheme = msg['encryption_scheme'] as String?;
          if (scheme == 'v1' || scheme == null) {
            final original = msg['content_original'] as String?;
            if (original != null &&
                original.isNotEmpty &&
                msg['content_original_encrypted'] != null &&
                msg['content_original_encrypted_cache'] == null) {
              msg['content_original_encrypted_cache'] = await cacheService
                  .encryptForCache(original);
            }
            final translated = msg['content_translated'] as String?;
            if (translated != null &&
                translated.isNotEmpty &&
                msg['content_translated_encrypted'] != null &&
                msg['content_translated_encrypted_cache'] == null) {
              msg['content_translated_encrypted_cache'] = await cacheService
                  .encryptForCache(translated);
            }
          }
        }
      }
    } catch (_) {}

    // Only write if the data actually changed to prevent infinite watch loops
    final newData = jsonEncode(combinedList);
    final oldData = box.get(matchId);
    if (newData != oldData) {
      await box.put(matchId, newData);
    }
    // Removed logging to reduce spam
  }

  Future<void> saveMessages(
    String matchId,
    List<Map<String, dynamic>> messages,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _saveMessagesUnlocked(matchId, messages),
    );
  }

  Future<void> _saveMessagesUnlocked(
    String matchId,
    List<Map<String, dynamic>> messages,
  ) async {
    final box = await _getMessagesBox();

    // Get existing messages to preserve local translations and pending messages
    final existingMessages = await getMessages(matchId);
    final existingTranslations = <String, Map<String, dynamic>>{};
    final pendingMessages = <Map<String, dynamic>>[];

    // Build a map of existing translations by message ID and collect pending messages
    // Memory + local storage: preserve translations, reply previews (original
    // + translated), encrypted-cache backups and reactors so a full
    // saveMessages replace (e.g. syncMessages) never drops locally resolved
    // data that Supabase rows don't carry. This keeps replies/translations
    // visible immediately on restart with no connectivity.
    for (final existingMsg in existingMessages) {
      final msgId = existingMsg['id']?.toString();

      if (existingMsg['isPending'] == true) {
        pendingMessages.add(existingMsg);
      }

      final translatedText = existingMsg['translated_text'];
      if (msgId != null && translatedText != null) {
        existingTranslations[msgId] = {
          'translated_text': translatedText,
          'translated_lang': existingMsg['translated_lang'],
        };
      }

      final replyTrans = existingMsg['reply_to_content_translated'];
      if (msgId != null &&
          replyTrans != null &&
          replyTrans.toString().isNotEmpty) {
        existingTranslations[msgId] = {
          ...?existingTranslations[msgId],
          'reply_to_content_translated': replyTrans,
        };
      }
      // Persisted reply previews for incoming messages: the server only
      // sends reply_to_message_id, so the resolved original/translation must
      // be carried over or quotes go blank after every sync/restart.
      final replyContent = existingMsg['reply_to_content'];
      if (msgId != null &&
          replyContent != null &&
          replyContent.toString().isNotEmpty) {
        existingTranslations[msgId] = {
          ...?existingTranslations[msgId],
          'reply_to_content': replyContent,
          'reply_to_sender_id': existingMsg['reply_to_sender_id'],
        };
      }
      // Encrypted-cache backups (DCK layer) for offline decrypt without keys.
      final origCache = existingMsg['content_original_encrypted_cache'];
      if (msgId != null &&
          origCache != null &&
          origCache.toString().isNotEmpty) {
        existingTranslations[msgId] = {
          ...?existingTranslations[msgId],
          'content_original_encrypted_cache': origCache,
        };
      }
      final transCache = existingMsg['content_translated_encrypted_cache'];
      if (msgId != null &&
          transCache != null &&
          transCache.toString().isNotEmpty) {
        existingTranslations[msgId] = {
          ...?existingTranslations[msgId],
          'content_translated_encrypted_cache': transCache,
        };
      }
      // Inline reactors map (per-message reaction user lists).
      final reactors = existingMsg['reactors'];
      if (msgId != null && reactors is Map && reactors.isNotEmpty) {
        existingTranslations[msgId] = {
          ...?existingTranslations[msgId],
          'reactors': reactors,
        };
      }
    }

    // Create a mutable copy of the incoming messages
    final allMessages = List<Map<String, dynamic>>.from(messages);

    // Merge translations and reactions into the new messages from Supabase
    for (final message in allMessages) {
      final msgId = message['id']?.toString();
      final existingMsgForEditCheck = existingMessages.firstWhere(
        (m) => m['id']?.toString() == msgId,
        orElse: () => {},
      );
      // Detect an edit: original ciphertext or edited_at changed. When the
      // content changed, cached translations of the OLD content are stale
      // and must be dropped so the message is retranslated immediately.
      bool isEdited = false;
      if (msgId != null && existingMsgForEditCheck.isNotEmpty) {
        final oldEnc = existingMsgForEditCheck['content_original_encrypted']
            ?.toString();
        final newEnc = message['content_original_encrypted']?.toString();
        if (oldEnc != null &&
            oldEnc.isNotEmpty &&
            newEnc != null &&
            newEnc.isNotEmpty &&
            oldEnc != newEnc) {
          isEdited = true;
        }
        final oldEdited = existingMsgForEditCheck['edited_at']?.toString();
        final newEdited = message['edited_at']?.toString();
        if (newEdited != null &&
            newEdited.isNotEmpty &&
            newEdited != oldEdited) {
          isEdited = true;
        }
        // Server clears the encrypted translation payload on edit. If the
        // incoming row drops a previously-present encrypted translation,
        // the old plaintext translation is stale.
        final oldTransEnc =
            existingMsgForEditCheck['content_translated_encrypted']?.toString();
        final newTransEnc = message['content_translated_encrypted']?.toString();
        if (oldTransEnc != null &&
            oldTransEnc.isNotEmpty &&
            (newTransEnc == null || newTransEnc.isEmpty)) {
          isEdited = true;
        }
      }
      if (msgId != null &&
          !isEdited &&
          existingTranslations.containsKey(msgId)) {
        message['translated_text'] =
            existingTranslations[msgId]!['translated_text'];
        message['translated_lang'] =
            existingTranslations[msgId]!['translated_lang'];
        final replyTrans =
            existingTranslations[msgId]!['reply_to_content_translated'];
        if (replyTrans != null && replyTrans.toString().isNotEmpty) {
          message['reply_to_content_translated'] = replyTrans;
        }
        // Restore locally resolved reply previews + offline fallbacks when
        // the server row doesn't carry them.
        final preservedReplyContent =
            existingTranslations[msgId]!['reply_to_content'];
        if (preservedReplyContent != null &&
            preservedReplyContent.toString().isNotEmpty &&
            (message['reply_to_content'] == null ||
                message['reply_to_content'].toString().isEmpty)) {
          message['reply_to_content'] = preservedReplyContent;
          final preservedReplySender =
              existingTranslations[msgId]!['reply_to_sender_id'];
          if (preservedReplySender != null) {
            message['reply_to_sender_id'] = preservedReplySender;
          }
        }
        final preservedOrigCache =
            existingTranslations[msgId]!['content_original_encrypted_cache'];
        if (preservedOrigCache != null &&
            preservedOrigCache.toString().isNotEmpty &&
            message['content_original_encrypted_cache'] == null) {
          message['content_original_encrypted_cache'] = preservedOrigCache;
        }
        final preservedTransCache =
            existingTranslations[msgId]!['content_translated_encrypted_cache'];
        if (preservedTransCache != null &&
            preservedTransCache.toString().isNotEmpty &&
            message['content_translated_encrypted_cache'] == null) {
          message['content_translated_encrypted_cache'] = preservedTransCache;
        }
        final preservedReactors = existingTranslations[msgId]!['reactors'];
        if (preservedReactors != null && message['reactors'] == null) {
          message['reactors'] = preservedReactors;
        }
      }

      // Preserve server-key translations from existing cache when incoming data
      // does not have them (e.g. translation not yet generated on server, or
      // decrypted locally).  This mirrors the content_original guard below.
      final existingMsg = existingMessages.firstWhere(
        (m) => m['id']?.toString() == msgId,
        orElse: () => {},
      );
      if (existingMsg.isNotEmpty) {
        if ((message['content_translated'] == null ||
                (message['content_translated'] is String &&
                    (message['content_translated'] as String).isEmpty)) &&
            (existingMsg['encryption_scheme']?.toString() ?? 'v1') ==
                (message['encryption_scheme']?.toString() ?? 'v1') &&
            existingMsg['content_translated_encrypted']?.toString() ==
                message['content_translated_encrypted']?.toString()) {
          String? preserved = existingMsg['content_translated'] as String?;
          // Mirror the content_original fallback: if the local plaintext
          // column is empty (because getMessages no longer decrypts the
          // cache inline), try the encrypted cache before giving up.
          if (preserved == null || preserved.isEmpty) {
            final cached =
                existingMsg['content_translated_encrypted_cache'] as String?;
            if (cached != null && cached.isNotEmpty) {
              try {
                preserved = await EncryptedCacheService.instance
                    .decryptFromCache(cached);
              } catch (_) {}
            }
          }
          if (preserved != null && preserved.isNotEmpty) {
            message['content_translated'] = preserved;
          }
        }
        if (!isEdited &&
            (message['translated_target_language'] == null ||
                (message['translated_target_language'] is String &&
                    (message['translated_target_language'] as String)
                        .isEmpty)) &&
            existingMsg['translated_target_language'] != null &&
            (existingMsg['translated_target_language'] is String &&
                (existingMsg['translated_target_language'] as String)
                    .isNotEmpty)) {
          // Only preserve the cached target language when the original
          // content is unchanged. After an edit the old target is stale:
          // keeping it would make the message look already-translated for
          // the current UI language and skip immediate retranslation.
          final oldOrigEnc = existingMsg['content_original_encrypted']
              ?.toString();
          final newOrigEnc = message['content_original_encrypted']?.toString();
          final origUnchanged =
              oldOrigEnc == null ||
              oldOrigEnc.isEmpty ||
              newOrigEnc == null ||
              newOrigEnc.isEmpty ||
              oldOrigEnc == newOrigEnc;
          if (origUnchanged) {
            message['translated_target_language'] =
                existingMsg['translated_target_language'];
          }
        }
        // Server reaction_summary is the source of truth; only fall back to
        // local cache when the server value is empty (no reactions yet).
        final serverSummary = message['reaction_summary'];
        final serverEmpty =
            serverSummary == null ||
            (serverSummary is Map && serverSummary.isEmpty);
        if (serverEmpty && existingMsg.containsKey('reaction_summary')) {
          message['reaction_summary'] = existingMsg['reaction_summary'];
        }
        if (existingMsg.containsKey('my_reaction')) {
          message['my_reaction'] = existingMsg['my_reaction'];
        }
        // Preserve locally-decrypted content_original for encrypted messages.
        // The server returns content_original=null for v1 encrypted rows, but the
        // local decryption loop may have already resolved the decrypted content via
        // mergeMessages.  Without this guard every syncMessages call would
        // overwrite the decrypted content with null, causing a visible flicker
        // and making the chat-list last-message preview disappear.
        // IMPORTANT: Only preserve when the encrypted content is unchanged.
        // When a message is edited (encrypted content differs), the old decrypted
        // text must NOT be preserved — Phase 2 must re-decrypt the new ciphertext.
        if (message['content_original_encrypted'] != null &&
            (message['content_original'] == null ||
                (message['content_original'] is String &&
                    (message['content_original'] as String).isEmpty)) &&
            (existingMsg['encryption_scheme']?.toString() ?? 'v1') ==
                (message['encryption_scheme']?.toString() ?? 'v1') &&
            existingMsg['content_original_encrypted']?.toString() ==
                message['content_original_encrypted']?.toString()) {
          String? preserved = existingMsg['content_original'] as String?;
          // The plaintext column may be empty even though the encrypted cache
          // (content_original_encrypted_cache) still holds the decrypted value,
          // because getMessages no longer decrypts the cache inline.  Fall back
          // to it so a syncMessages call right after the chat opens does not
          // wipe the previously-decrypted text.
          if (preserved == null || preserved.isEmpty) {
            final cached =
                existingMsg['content_original_encrypted_cache'] as String?;
            if (cached != null && cached.isNotEmpty) {
              try {
                preserved = await EncryptedCacheService.instance
                    .decryptFromCache(cached);
              } catch (_) {}
            }
          }
          if (preserved != null && preserved.isNotEmpty) {
            message['content_original'] = preserved;
          }
        }
      }

      // IMPORTANT: Do NOT mark received messages as delivered locally!
      // The delivered_at field should only be set by the server when confirmed.
      // The RPC call mark_message_delivered will update the server, and when
      // messages are re-synced, they'll have the actual server delivered_at value.
    }

    // Append pending messages that are not in the new list
    final newIds = <String>{};
    for (final m in allMessages) {
      final id = m['id']?.toString();
      if (id != null) newIds.add(id);
    }
    for (final pending in pendingMessages) {
      if (!newIds.contains(pending['id']?.toString())) {
        allMessages.add(pending);
      }
    }

    // Sort by created_at
    allMessages.sort((a, b) {
      final aDate =
          DateTime.tryParse(a['created_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bDate =
          DateTime.tryParse(b['created_at'] ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return aDate.compareTo(bDate);
    });

    // Encrypt decrypted content for cache if EncryptedCacheService is initialized.
    // The encrypted cache is stored alongside the decrypted content so that messages always
    // remain visible even if re-decryption via the chat key fails (e.g. network
    // contention during startup).  The decrypted fields are NOT cleared here;
    // the chat-messages provider is responsible for preferring the cached layer.
    try {
      final cacheService = EncryptedCacheService.instance;
      if (cacheService.currentDck != null) {
        for (final msg in allMessages) {
          final scheme = msg['encryption_scheme'] as String?;
          if (scheme == 'v1' || scheme == null) {
            final original = msg['content_original'] as String?;
            if (original != null &&
                original.isNotEmpty &&
                msg['content_original_encrypted'] != null) {
              final encrypted = await cacheService.encryptForCache(original);
              msg['content_original_encrypted_cache'] = encrypted;
            }
            final translated = msg['content_translated'] as String?;
            if (translated != null &&
                translated.isNotEmpty &&
                msg['content_translated_encrypted'] != null) {
              final encrypted = await cacheService.encryptForCache(translated);
              msg['content_translated_encrypted_cache'] = encrypted;
            }
          }
        }
      }
    } catch (_) {}

    await box.put(matchId, jsonEncode(allMessages));
  }

  Future<void> saveTranslation(
    String matchId,
    String messageId,
    String translation,
    String targetLang,
  ) {
    return _withMessagesWrite(
      matchId,
      () =>
          _saveTranslationUnlocked(matchId, messageId, translation, targetLang),
    );
  }

  Future<void> _saveTranslationUnlocked(
    String matchId,
    String messageId,
    String translation,
    String targetLang,
  ) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);

    final index = messages.indexWhere((m) => m['id'].toString() == messageId);

    if (index != -1) {
      messages[index]['translated_text'] = translation;
      messages[index]['translated_lang'] = targetLang;
      // Keep the current-schema plaintext cache in sync so offline
      // cold-start (which reads content_translated + target language)
      // renders the same translation without Supabase.
      messages[index]['content_translated'] = translation;
      messages[index]['translated_target_language'] = targetLang;
      try {
        final cacheService = EncryptedCacheService.instance;
        if (cacheService.currentDck != null &&
            translation.isNotEmpty &&
            messages[index]['content_translated_encrypted'] != null) {
          messages[index]['content_translated_encrypted_cache'] =
              await cacheService.encryptForCache(translation);
        }
      } catch (_) {}
      await box.put(matchId, jsonEncode(messages));
    }
  }

  /// Persist a translated reply-quote preview for offline display.
  /// Stored on the quoting message's row so the quote renders translated
  /// immediately on restart with no connectivity.
  Future<void> saveReplyTranslation(
    String matchId,
    String quotingMessageId,
    String translatedPreview,
  ) {
    return _withMessagesWrite(
      matchId,
      () => _saveReplyTranslationUnlocked(
        matchId,
        quotingMessageId,
        translatedPreview,
      ),
    );
  }

  Future<void> _saveReplyTranslationUnlocked(
    String matchId,
    String quotingMessageId,
    String translatedPreview,
  ) async {
    if (translatedPreview.isEmpty) return;
    try {
      final box = await _getMessagesBox();
      final messages = await getMessages(matchId);
      final index = messages.indexWhere(
        (m) => m['id']?.toString() == quotingMessageId,
      );
      if (index == -1) return;
      final current =
          messages[index]['reply_to_content_translated']?.toString() ?? '';
      if (current == translatedPreview) return;
      messages[index]['reply_to_content_translated'] = translatedPreview;
      await box.put(matchId, jsonEncode(messages));
    } catch (_) {}
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String matchId) async* {
    try {
      final box = await _getMessagesBox();
      // The snapshot variant reuses the decoded rows when the stored blob did
      // not change, so re-entering a chat does not pay a full jsonDecode of
      // the whole conversation again.
      final initialMessages = await getMessagesSnapshot(matchId);
      yield initialMessages;

      yield* box.watch(key: matchId).asyncMap((event) async {
        try {
          if (event.value != null && !event.deleted) {
            final messages = (jsonDecode(event.value) as List)
                .cast<Map<String, dynamic>>();
            return messages;
          }
          return <Map<String, dynamic>>[];
        } catch (e) {
          print('❌ [watchMessages] Error processing change event: $e');
          return <Map<String, dynamic>>[];
        }
      });
    } catch (e) {
      print('❌ [watchMessages] Error setting up watch: $e');
      yield <Map<String, dynamic>>[];
      await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
        yield <Map<String, dynamic>>[];
      }
    }
  }

  // --- Outbox Methods ---
  Future<void> saveMessageToOutbox(Map<String, dynamic> messagePayload) async {
    final box = await _getOutboxBox();
    final key = DateTime.now().toIso8601String();
    await box.put(key, jsonEncode(messagePayload));
  }

  Stream<Map<dynamic, String>> watchOutbox() async* {
    final box = await _getOutboxBox();
    yield box.toMap().cast<dynamic, String>();
    yield* box.watch().map((event) {
      return box.toMap().cast<dynamic, String>();
    });
  }

  Future<void> removeMessageFromOutbox(dynamic key) async {
    final box = await _getOutboxBox();
    await box.delete(key);
  }

  // --- Encrypted Chat Outbox Methods ---
  Future<void> saveEncryptedOutboxDraft(
    String userId,
    String draftId,
    Map<String, dynamic> draftPayload,
  ) async {
    final box = await _getChatOutboxBox();
    final key = 'chat_outbox:$userId:$draftId';
    await box.put(key, jsonEncode(draftPayload));
  }

  Future<Map<String, dynamic>?> getEncryptedOutboxDraft(
    String userId,
    String draftId,
  ) async {
    final box = await _getChatOutboxBox();
    final key = 'chat_outbox:$userId:$draftId';
    final value = box.get(key);
    if (value == null) return null;
    return jsonDecode(value) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getEncryptedOutboxDrafts(
    String userId,
  ) async {
    final box = await _getChatOutboxBox();
    final prefix = 'chat_outbox:$userId:';
    final drafts = <Map<String, dynamic>>[];
    for (final key in box.keys) {
      if (key.toString().startsWith(prefix)) {
        final value = box.get(key);
        if (value != null) {
          drafts.add(jsonDecode(value) as Map<String, dynamic>);
        }
      }
    }
    drafts.sort((a, b) {
      final aDate = DateTime.tryParse(a['created_at'] as String? ?? '');
      final bDate = DateTime.tryParse(b['created_at'] as String? ?? '');
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return -1;
      if (bDate == null) return 1;
      return aDate.compareTo(bDate);
    });
    return drafts;
  }

  Future<void> removeEncryptedOutboxDraft(String userId, String draftId) async {
    final box = await _getChatOutboxBox();
    final key = 'chat_outbox:$userId:$draftId';
    await box.delete(key);
  }

  Future<void> clearEncryptedOutboxDrafts(String userId) async {
    final box = await _getChatOutboxBox();
    final prefix = 'chat_outbox:$userId:';
    for (final key in box.keys) {
      if (key.toString().startsWith(prefix)) {
        await box.delete(key);
      }
    }
  }

  // --- Profile Outbox Methods ---
  Future<void> saveProfileUpdateToOutbox(
    String userId,
    Map<String, dynamic> updatePayload,
  ) async {
    final box = await _getProfileOutboxBox();
    final key = '${userId}_${DateTime.now().toIso8601String()}';
    await box.put(key, jsonEncode(updatePayload));
  }

  Stream<Map<dynamic, String>> watchProfileOutbox() async* {
    final box = await _getProfileOutboxBox();
    yield box.toMap().cast<dynamic, String>();
    yield* box.watch().map((event) {
      return box.toMap().cast<dynamic, String>();
    });
  }

  Future<void> removeProfileUpdateFromOutbox(dynamic key) async {
    final box = await _getProfileOutboxBox();
    await box.delete(key);
  }

  // --- Visibility Outbox Methods ---
  Future<void> saveVisibilityUpdateToOutbox(
    String userId,
    bool isVisible,
  ) async {
    final box = await _getVisibilityOutboxBox();
    final key = '${userId}_visibility_${DateTime.now().toIso8601String()}';
    final payload = {
      'userId': userId,
      'isVisible': isVisible,
      'timestamp': DateTime.now().toIso8601String(),
    };
    await box.put(key, jsonEncode(payload));
  }

  Stream<Map<dynamic, String>> watchVisibilityOutbox() async* {
    final box = await _getVisibilityOutboxBox();
    yield box.toMap().cast<dynamic, String>();
    yield* box.watch().map((event) {
      return box.toMap().cast<dynamic, String>();
    });
  }

  Future<void> removeVisibilityUpdateFromOutbox(dynamic key) async {
    final box = await _getVisibilityOutboxBox();
    await box.delete(key);
  }

  Future<bool> hasPendingVisibilityUpdate(String userId) async {
    final box = await _getVisibilityOutboxBox();
    final prefix = '${userId}_visibility_';
    return box.keys.any((key) => key.toString().startsWith(prefix));
  }

  // --- Invisibility Rules Outbox Methods ---
  Future<void> saveInvisibilityRulesUpdateToOutbox(
    String userId,
    String rulesJson,
  ) async {
    final box = await _getInvisibilityRulesOutboxBox();
    final key = '${userId}_rules_${DateTime.now().toIso8601String()}';
    final payload = {
      'userId': userId,
      'rulesData': rulesJson,
      'timestamp': DateTime.now().toIso8601String(),
    };
    await box.put(key, jsonEncode(payload));
  }

  Stream<Map<dynamic, String>> watchInvisibilityRulesOutbox() async* {
    final box = await _getInvisibilityRulesOutboxBox();
    yield box.toMap().cast<dynamic, String>();
    yield* box.watch().map((event) {
      return box.toMap().cast<dynamic, String>();
    });
  }

  Future<void> removeInvisibilityRulesUpdateFromOutbox(dynamic key) async {
    final box = await _getInvisibilityRulesOutboxBox();
    await box.delete(key);
  }

  // --- Clear Database ---
  /// Full wipe (account deletion / explicit "erase all"). Clears EVERY box,
  /// including chat outbox, offline trail, options, and mutation queue.
  /// Callers must also clear sensitive SharedPreferences, SecureStorage temp
  /// keys, and image disk cache (see SecureLogoutService pattern in
  /// OfflineCacheManager.clearAllOfflineCache).
  Future<void> clearDatabase() async {
    final profileBox = await _getProfileBox();
    final matchesBox = await _getMatchesBox();
    final chatsBox = await _getChatsBox();
    final messagesBox = await _getMessagesBox();
    final outboxBox = await _getOutboxBox();
    final profileOutboxBox = await _getProfileOutboxBox();
    final visibilityOutboxBox = await _getVisibilityOutboxBox();
    final invisibilityRulesOutboxBox = await _getInvisibilityRulesOutboxBox();
    final eventsBox = await _getEventsBox();
    final settingsBox = await _getSettingsBox();
    final translationsBox = await _getTranslationsBox();

    await profileBox.clear();
    await matchesBox.clear();
    await chatsBox.clear();
    await messagesBox.clear();
    await outboxBox.clear();
    await profileOutboxBox.clear();
    await visibilityOutboxBox.clear();
    await invisibilityRulesOutboxBox.clear();
    await eventsBox.clear();
    await settingsBox.clear();
    await translationsBox.clear();
    try {
      final trailBox = await _getOfflineTrailBox();
      await trailBox.clear();
    } catch (_) {}
    // Previously missed boxes (privacy fix): chat outbox, options, emoji
    // usage, and offline mutation queue must not survive a full wipe.
    try {
      final chatOutboxBox = await _getChatOutboxBox();
      await chatOutboxBox.clear();
    } catch (_) {}
    try {
      final optionsBox = await _getOptionsBox();
      await optionsBox.clear();
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('emoji_usage')) {
        try {
          await Hive.box<int>('emoji_usage').clear();
        } catch (_) {
          await Hive.box('emoji_usage').clear();
        }
      }
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('offline_mutations')) {
        try {
          await Hive.box<Map<dynamic, dynamic>>('offline_mutations').clear();
        } catch (_) {
          await Hive.box('offline_mutations').clear();
        }
      } else {
        final q = await HiveEncryptionService.instance.openEncryptedBox(
          'offline_mutations',
        );
        await q.clear();
      }
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('chatOutboxBox')) {
        await Hive.box('chatOutboxBox').clear();
      }
    } catch (_) {}
  }

  /// Explicit-logout wipe for ONE user.
  ///
  /// Data keyed by matchId or another user's id cannot safely be assigned to
  /// one account after the fact. Remove those shared profile/message caches
  /// as well as this user's own lists so no account data remains visible after
  /// sign-out. The next account repopulates its own cache from Supabase.
  Future<void> clearUserData(String userId) async {
    final trimmedId = userId.trim();
    // Pending offline mutations must not be replayed under the next session.
    await (await _getOutboxBox()).clear();
    await (await _getChatOutboxBox()).clear();
    await (await _getProfileOutboxBox()).clear();
    await (await _getVisibilityOutboxBox()).clear();
    await (await _getInvisibilityRulesOutboxBox()).clear();

    final chatsBox = await _getChatsBox();
    final matchesBox = await _getMatchesBox();
    final messagesBox = await _getMessagesBox();
    await chatsBox.delete('recent_chats');
    if (trimmedId.isEmpty) {
      await messagesBox.clear();
      return;
    }

    final profileBox = await _getProfileBox();
    await profileBox.delete(trimmedId);
    await profileBox.delete('${trimmedId}_location');
    await clearOfflineTrail(trimmedId);
    await (await _getEventsBox()).delete(trimmedId);

    final settingsBox = await _getSettingsBox();
    for (final key in settingsBox.keys.toList()) {
      final value = key.toString();
      if (value.endsWith('_$trimmedId') ||
          value.startsWith('${trimmedId}_') ||
          value.startsWith('match_minimap_') ||
          value.startsWith(LocalDbService.messagesSyncedAtKeyPrefix)) {
        await settingsBox.delete(key);
      }
    }
    // Device-pending state with no owner column: never carry it over to the
    // next account on this device.
    await settingsBox.delete('pending_referral_code');

    await chatsBox.delete('recent_chats_$trimmedId');
    await matchesBox.delete('recent_matches_$trimmedId');

    // Profile caches are keyed by the profile owner, not by the signed-in
    // viewer. There is no safe way to attribute every cached profile to one
    // viewer, so drop them all and repopulate for the next session.
    for (final key in profileBox.keys.toList()) {
      final value = key.toString();
      if (value.startsWith('other_user_') ||
          value.startsWith('profile_translation_')) {
        await profileBox.delete(key);
      }
    }

    // Messages are keyed only by matchId; leftovers cannot be reliably
    // attributed to the outgoing account, so never retain them across logout.
    await messagesBox.clear();

    // Per-device activity that is not keyed by user but still belongs to the
    // outgoing session: emoji usage history and queued offline mutations must
    // not survive logout (clearDatabase wipes the same boxes on deletion).
    try {
      if (Hive.isBoxOpen('emoji_usage')) {
        try {
          await Hive.box<int>('emoji_usage').clear();
        } catch (_) {
          await Hive.box('emoji_usage').clear();
        }
      } else {
        final emojiBox = await HiveEncryptionService.instance
            .openEncryptedBox<int>('emoji_usage');
        await emojiBox.clear();
      }
    } catch (_) {}
    try {
      if (Hive.isBoxOpen('offline_mutations')) {
        try {
          await Hive.box<Map<dynamic, dynamic>>('offline_mutations').clear();
        } catch (_) {
          await Hive.box('offline_mutations').clear();
        }
      } else {
        final mutationBox = await HiveEncryptionService.instance
            .openEncryptedBox('offline_mutations');
        await mutationBox.clear();
      }
    } catch (_) {}
  }

  /// Encrypted verification-status snapshot (is_verified, AI analysis,
  /// similarity score, rejection metadata, verification photo path).
  ///
  /// Kept in the encrypted settings box rather than SharedPreferences so the
  /// AI analysis and rejection details are not left in plaintext on disk.
  Future<void> saveVerificationStatus(
    String userId,
    Map<String, dynamic> data,
  ) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty || data.isEmpty) return;
    final box = await _getSettingsBox();
    await box.put(
      'verification_status_$trimmedId',
      jsonEncode({
        'user_id': trimmedId,
        'data': data,
        'cached_at': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<Map<String, dynamic>?> getVerificationStatus(String userId) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty) return null;
    try {
      final box = await _getSettingsBox();
      final raw = box.get('verification_status_$trimmedId');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['user_id'] != trimmedId) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      return Map<String, dynamic>.from(data);
    } catch (error) {
      debugPrint('[LocalDb] Could not decode verification status: $error');
      return null;
    }
  }

  Future<void> saveNotificationInbox(
    String userId,
    List<Map<String, dynamic>> notifications,
  ) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty) return;
    final box = await _getSettingsBox();
    await box.put(
      'notification_inbox_$trimmedId',
      jsonEncode({
        'user_id': trimmedId,
        'notifications': notifications,
        'cached_at': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<List<Map<String, dynamic>>?> getNotificationInbox(
    String userId,
  ) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty) return null;
    try {
      final box = await _getSettingsBox();
      final raw = box.get('notification_inbox_$trimmedId');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['user_id'] != trimmedId) return null;
      final notifications = decoded['notifications'];
      if (notifications is! List) return null;
      return notifications
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (error) {
      debugPrint('[LocalDb] Could not decode notification inbox: $error');
      return null;
    }
  }

  Future<void> saveNearbyMapCells(
    String userId,
    String queryKey,
    List<Map<String, dynamic>> cells,
  ) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty || queryKey.isEmpty) return;
    final box = await _getSettingsBox();
    await box.put(
      'nearby_map_cells_${queryKey}_$trimmedId',
      jsonEncode({
        'cells': cells,
        'cached_at': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<List<Map<String, dynamic>>?> getNearbyMapCells(
    String userId,
    String queryKey,
  ) async {
    final trimmedId = userId.trim();
    if (trimmedId.isEmpty || queryKey.isEmpty) return null;
    try {
      final box = await _getSettingsBox();
      final raw = box.get('nearby_map_cells_${queryKey}_$trimmedId');
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['cells'] is! List) return null;
      return (decoded['cells'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (error) {
      debugPrint('[LocalDb] Could not decode nearby-map cache: $error');
      return null;
    }
  }

  /// Save localized country names for a language code (e.g. "en", "he")
  Future<void> saveLocalizedCountryNames(
    String langCode,
    Map<String, String> names,
  ) async {
    final box = await _getSettingsBox();
    await box.put('countryNames_$langCode', jsonEncode(names));
  }

  /// Load cached localized country names for a language code
  Future<Map<String, String>?> getCachedLocalizedCountryNames(
    String langCode,
  ) async {
    final box = await _getSettingsBox();
    final json = box.get('countryNames_$langCode');
    if (json == null) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return null;
    }
  }

  /// Clear cached country names for all languages
  Future<void> clearLocalizedCountryNames() async {
    final box = await _getSettingsBox();
    final keys = box.keys.where(
      (k) => k.toString().startsWith('countryNames_'),
    );
    for (final key in keys) {
      await box.delete(key);
    }
  }

  /// Save individual event details to local cache
  Future<void> saveEventDetails(
    String eventId,
    Map<String, dynamic> eventData,
  ) async {
    try {
      final box = await _getEventsBox();
      final key = 'event_$eventId';
      final dataToCache = {
        ...eventData,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, jsonEncode(dataToCache));

      if (kIsWeb) {
        // print('🔍 [WEB] saveEventDetails - Cached event: $eventId');
      }
    } catch (e) {
      // print('LocalDb.saveEventDetails failed: $e');
      if (kIsWeb) {
        // print('🔍 [WEB] saveEventDetails - FAILED: $e');
      }
    }
  }

  /// Get cached event details (returns null if expired or missing)
  Future<Map<String, dynamic>?> getEventDetails(String eventId) async {
    try {
      final box = await _getEventsBox();
      final key = 'event_$eventId';
      final jsonString = box.get(key);

      if (jsonString == null) {
        if (kIsWeb) {
          // print('🔍 [WEB] getEventDetails - No cached data for event: $eventId');
        }
        return null;
      }

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cached_at']);

      // Cache for 30 minutes (events don't change often)
      final cacheDuration = await appConfigService.getDuration(
        'cache.events_duration_seconds',
        defaultValue: const Duration(minutes: 30),
      );
      if (DateTime.now().difference(cachedAt) > cacheDuration) {
        if (kIsWeb) {
          // print('🔍 [WEB] getEventDetails - Cache expired for event: $eventId');
        }
        return null; // Expired
      }

      // Remove cache metadata before returning
      final cleanData = Map<String, dynamic>.from(data)..remove('cached_at');

      if (kIsWeb) {
        // print('🔍 [WEB] getEventDetails - Returning cached event: $eventId');
      }

      return cleanData;
    } catch (e) {
      // print('LocalDb.getEventDetails failed: $e');
      return null;
    }
  }

  /// Save other user profile to local cache
  Future<void> saveOtherUserProfile(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    try {
      final box = await _getProfileBox();
      final key = 'other_user_$userId';
      final dataToCache = {
        ...profileData,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, dataToCache);

      if (kIsWeb) {
        // print('🔍 [WEB] saveOtherUserProfile - Cached profile for user: $userId');
      }
    } catch (e) {
      // print('LocalDb.saveOtherUserProfile failed: $e');
      if (kIsWeb) {
        // print('🔍 [WEB] saveOtherUserProfile - FAILED: $e');
      }
    }
  }

  /// Returns a cached translation only when it matches the current source text,
  /// target language AND gender context.
  /// Entries written before the single-text dedupe fix (v1, no version marker)
  /// are ignored so a poisoned occupation entry holding the bio translation
  /// is re-translated instead of being served forever.
  /// v6 evicts entries steered by the old LLM-style `context` sentences
  /// ("The speaker is a woman..."), which DeepL documents as unreliable and
  /// proved so in production (masculine output despite feminine instruction).
  /// Current steering uses natural pronoun-clue sentences per DeepL's
  /// documented effective pattern; affected entries retranslate once.
  static const int _profileTranslationCacheVersion = 6;

  Future<String?> getCachedProfileTranslation({
    required String userId,
    required String field,
    required String sourceText,
    required String targetLanguage,
    String genderKey = '',
  }) async {
    try {
      final box = await _getProfileBox();
      final key = 'profile_translation_$userId';
      final data = box.get(key);
      if (data is! Map) return null;

      final entry = data[field];
      if (entry is! Map ||
          entry['v'] != _profileTranslationCacheVersion ||
          entry['source']?.toString() != sourceText ||
          entry['target_language']?.toString() != targetLanguage ||
          (entry['gender_key']?.toString() ?? '') != genderKey) {
        return null;
      }

      final translated = entry['translated']?.toString();
      return translated == null || translated.trim().isEmpty
          ? null
          : translated;
    } catch (_) {
      return null;
    }
  }

  /// Stores a matched user's translated profile text locally by field.
  Future<void> saveCachedProfileTranslation({
    required String userId,
    required String field,
    required String sourceText,
    required String targetLanguage,
    required String translatedText,
    String genderKey = '',
  }) async {
    try {
      final box = await _getProfileBox();
      final key = 'profile_translation_$userId';
      final existing = box.get(key);
      final data = existing is Map
          ? Map<String, dynamic>.from(existing)
          : <String, dynamic>{};
      data[field] = {
        'v': _profileTranslationCacheVersion,
        'source': sourceText,
        'target_language': targetLanguage,
        'gender_key': genderKey,
        'translated': translatedText,
      };
      await box.put(key, data);
    } catch (_) {
      // Translation caching must not affect profile rendering.
    }
  }

  /// Get cached other user profile (returns null if expired or missing)
  Future<Map<String, dynamic>?> getOtherUserProfile(String userId) async {
    try {
      final box = await _getProfileBox();
      final key = 'other_user_$userId';
      final data = box.get(key);

      if (data == null) {
        if (kIsWeb) {
          // print('🔍 [WEB] getOtherUserProfile - No cached profile for user: $userId');
        }
        return null;
      }

      final cachedAt = DateTime.parse(data['cached_at']);

      final cacheDuration = await appConfigService.getDuration(
        'cache.profile_duration_seconds',
        defaultValue: const Duration(minutes: 5),
      );
      if (DateTime.now().difference(cachedAt) > cacheDuration) {
        if (kIsWeb) {
          // print('🔍 [WEB] getOtherUserProfile - Cache expired for user: $userId');
        }
        return null; // Expired
      }

      // Remove cache metadata before returning
      final cleanData = Map<String, dynamic>.from(data)..remove('cached_at');

      if (kIsWeb) {
        // print('🔍 [WEB] getOtherUserProfile - Returning cached profile for user: $userId');
      }

      return cleanData;
    } catch (e) {
      // print('LocalDb.getOtherUserProfile failed: $e');
      return null;
    }
  }

  /// Save event attendees list to local cache
  Future<void> saveEventAttendees(
    String eventId,
    List<Map<String, dynamic>> attendees,
  ) async {
    try {
      final box = await _getEventsBox();
      final key = 'attendees_$eventId';
      final dataToCache = {
        'attendees': attendees,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, jsonEncode(dataToCache));

      if (kIsWeb) {
        // print('🔍 [WEB] saveEventAttendees - Cached ${attendees.length} attendees for event: $eventId');
      }
    } catch (e) {
      // print('LocalDb.saveEventAttendees failed: $e');
      if (kIsWeb) {
        // print('🔍 [WEB] saveEventAttendees - FAILED: $e');
      }
    }
  }

  /// Get cached event attendees. [allowStale] keeps previously displayed data
  /// available offline after the normal refresh window has elapsed.
  Future<List<Map<String, dynamic>>?> getEventAttendees(
    String eventId, {
    bool allowStale = false,
  }) async {
    try {
      final box = await _getEventsBox();
      final key = 'attendees_$eventId';
      final jsonString = box.get(key);

      if (jsonString == null) {
        if (kIsWeb) {
          // print('🔍 [WEB] getEventAttendees - No cached attendees for event: $eventId');
        }
        return null;
      }

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cached_at']);

      if (!allowStale) {
        // Cache for 15 minutes (attendee lists change more frequently).
        final cacheDuration = await appConfigService.getDuration(
          'cache.events_duration_seconds',
          defaultValue: const Duration(minutes: 15),
        );
        if (DateTime.now().difference(cachedAt) > cacheDuration) {
          if (kIsWeb) {
            // print('🔍 [WEB] getEventAttendees - Cache expired for event: $eventId');
          }
          return null;
        }
      }

      final attendees = (data['attendees'] as List<dynamic>?)
          ?.map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      if (kIsWeb) {
        // print('🔍 [WEB] getEventAttendees - Returning ${attendees?.length ?? 0} cached attendees for event: $eventId');
      }

      return attendees;
    } catch (e) {
      // print('LocalDb.getEventAttendees failed: $e');
      return null;
    }
  }

  /// Drop all cached event-attendees (matched attendees) entries. Called
  /// when attendance or matches may have changed server-side (realtime
  /// change or the periodic refresh): this user's realtime subscription
  /// only fires for their own attendance rows, so it can't see other
  /// users joining — without invalidation a cached list would hide
  /// brand-new matches for up to the cache TTL.
  Future<void> clearEventAttendeesCache() async {
    try {
      final box = await _getEventsBox();
      final keys = box.keys
          .whereType<String>()
          .where((key) => key.startsWith('attendees_'))
          .toList();
      if (keys.isNotEmpty) {
        await box.deleteAll(keys);
      }
    } catch (_) {}
  }

  /// Save the hierarchical options map (intents + interest categories) to local Hive cache.
  Future<void> saveOptionHierarchy(Map<String, dynamic> hierarchy) async {
    final box = await _getOptionsBox();
    // store under fixed key 'hierarchy'
    await box.put('hierarchy', jsonEncode(hierarchy));
  }

  Future<void> saveCachedAppIntents(List<Map<String, dynamic>> intents) async {
    final box = await _getOptionsBox();
    await box.put(
      'cached_app_intents',
      jsonEncode({
        'items': intents,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<List<Map<String, dynamic>>> getCachedAppIntents() async {
    final box = await _getOptionsBox();
    final stored = box.get('cached_app_intents');
    if (stored == null) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      final items = decoded['items'] as List<dynamic>? ?? const [];
      return items
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> saveCachedAppInterests(
    List<Map<String, dynamic>> interests,
  ) async {
    final box = await _getOptionsBox();
    await box.put(
      'cached_app_interests',
      jsonEncode({
        'items': interests,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<List<Map<String, dynamic>>> getCachedAppInterests() async {
    final box = await _getOptionsBox();
    final stored = box.get('cached_app_interests');
    if (stored == null) return <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      final items = decoded['items'] as List<dynamic>? ?? const [];
      return items
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> saveCachedGenderOptions(
    List<Map<String, String>> genderOptions,
  ) async {
    final box = await _getOptionsBox();
    await box.put(
      'cached_gender_options',
      jsonEncode({
        'items': genderOptions,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<List<Map<String, String>>> getCachedGenderOptions() async {
    final box = await _getOptionsBox();
    final stored = box.get('cached_gender_options');
    if (stored == null) return <Map<String, String>>[];
    try {
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      final items = decoded['items'] as List<dynamic>? ?? const [];
      return items
          .map(
            (item) => Map<String, String>.from(
              (item as Map).map(
                (key, value) =>
                    MapEntry(key.toString(), value?.toString() ?? ''),
              ),
            ),
          )
          .toList();
    } catch (_) {
      return <Map<String, String>>[];
    }
  }

  Future<Box> _getOptionsBox() async {
    if (_optionsBox == null) {
      await init();
      _optionsBox ??= await HiveEncryptionService.instance
          .openEncryptedBoxDynamic(_kOptionsBox);
    }
    return _optionsBox!;
  }

  /// Cache profile option rows (app_profile_options) for offline-first startup.
  /// Memory layer lives in the Riverpod providers; this is the local-storage
  /// layer. Stored with a timestamp so providers can stale-while-revalidate.
  Future<void> saveCachedProfileOptions(
    List<Map<String, dynamic>> options,
  ) async {
    try {
      final box = await _getOptionsBox();
      await box.put(
        'cached_profile_options',
        jsonEncode({
          'items': options,
          'timestamp': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> getCachedProfileOptions() async {
    try {
      final box = await _getOptionsBox();
      final stored = box.get('cached_profile_options');
      if (stored == null) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      final items = decoded['items'] as List<dynamic>? ?? const [];
      return items
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// Cache intent-specific profile snapshot (bio + sub-intents + interests)
  /// per user+intent so MatchProfileScreen renders instantly from disk.
  Future<void> saveCachedSpecificProfile(
    String userId,
    String intentType,
    Map<String, dynamic> data,
  ) async {
    try {
      final id = userId.trim();
      final intent = intentType.trim();
      if (id.isEmpty || intent.isEmpty) return;
      final box = await _getOptionsBox();
      await box.put(
        'specific_profile_${id}_$intent',
        jsonEncode({...data, 'cached_at': DateTime.now().toIso8601String()}),
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> getCachedSpecificProfile(
    String userId,
    String intentType,
  ) async {
    try {
      final id = userId.trim();
      final intent = intentType.trim();
      if (id.isEmpty || intent.isEmpty) return null;
      final box = await _getOptionsBox();
      final stored = box.get('specific_profile_${id}_$intent');
      if (stored == null) return null;
      final decoded = jsonDecode(stored) as Map<String, dynamic>;
      return Map<String, dynamic>.from(decoded)..remove('cached_at');
    } catch (_) {
      return null;
    }
  }

  /// Get the cached option hierarchy, or null if none.
  Future<Map<String, dynamic>?> getOptionHierarchy() async {
    final box = await _getOptionsBox();
    final stored = box.get('hierarchy');
    if (stored == null) return null;
    try {
      final decoded = jsonDecode(stored);
      return Map<String, dynamic>.from(decoded as Map);
    } catch (_) {
      return null;
    }
  }

  /// Watch the option hierarchy for changes (useful if other code updates it)
  Stream<Map<String, dynamic>?> watchOptionHierarchy() async* {
    final box = await _getOptionsBox();
    final current = box.get('hierarchy');
    if (current != null) {
      try {
        yield Map<String, dynamic>.from(jsonDecode(current) as Map);
      } catch (_) {
        yield null;
      }
    } else {
      yield null;
    }
    yield* box.watch(key: 'hierarchy').map((event) {
      if (event.value != null) {
        try {
          return Map<String, dynamic>.from(jsonDecode(event.value) as Map);
        } catch (_) {
          return null;
        }
      }
      return null;
    });
  }

  // --- NEW: helpers to support option_node_provider fallbacks ---

  /// Return a list of "intent root" nodes from cached hierarchy that match the given intentKey.
  /// Shape returned: List of Maps with keys similar to RPC: id, node_key, node_type, display_key, sort_order
  Future<List<Map<String, dynamic>>> getIntentRoots(String intentKey) async {
    final cached = await getOptionHierarchy();
    if (cached == null) return [];
    final intents =
        (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        [];
    final matched = intents.where((i) {
      final key = (i['intent_key'] ?? '').toString();
      final display = (i['display_name_key'] ?? '').toString();
      return key.toLowerCase() == intentKey.toLowerCase() ||
          display.toLowerCase() == intentKey.toLowerCase();
    }).toList();

    if (matched.isEmpty) return [];

    return matched.map((i) {
      return <String, dynamic>{
        'id': '', // no local UUID available in the flattened cache
        'node_key': i['intent_key'] ?? '',
        'node_type': 'intent',
        'display_key': i['display_name_key'] ?? i['intent_key'] ?? '',
        'sort_order': i['sort_order'] ?? 0,
      };
    }).toList();
  }

  /// Return immediate children for a given cached parentId.
  /// For cached hierarchy we support:
  /// - parentId that equals an intent node_key -> returns sub_intent_keys if present
  /// - parentId like 'interest_category_(categoryKey)' -> returns interest items under that category
  Future<List<Map<String, dynamic>>> getOptionChildren(String parentId) async {
    final cached = await getOptionHierarchy();
    if (cached == null) return [];

    // If parentId looks like our category node_key: 'interest_category_<categoryKey>'
    const prefix = 'interest_category_';
    if (parentId.startsWith(prefix)) {
      final catKey = parentId.substring(prefix.length);
      final categories =
          (cached['interests'] as List<dynamic>?)
              ?.cast<Map<String, dynamic>>() ??
          [];
      final match = categories.firstWhere(
        (c) =>
            (c['categoryKey']?.toString() ?? '') == catKey ||
            (c['categoryDisplayKey']?.toString() ?? '') == catKey,
        orElse: () => <String, dynamic>{},
      );
      if (match.isEmpty) return [];
      final items =
          (match['items'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
          [];
      return items.map((it) {
        return <String, dynamic>{
          'id': '',
          'node_key': it['interest_key'] ?? it['interestKey'] ?? '',
          'node_type': 'interest',
          'display_key':
              it['interest_display_key'] ?? it['interestDisplayKey'] ?? '',
          'sort_order':
              it['interest_sort_order'] ?? it['interestSortOrder'] ?? 0,
        };
      }).toList();
    }

    // If parentId equals an intent key (node_key), return subIntentKeys when available in cache
    final intents =
        (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        [];
    final matchIntent = intents.firstWhere(
      (i) =>
          (i['intent_key']?.toString() ?? '') == parentId ||
          (i['display_name_key']?.toString() ?? '') == parentId,
      orElse: () => <String, dynamic>{},
    );
    if (matchIntent.isNotEmpty) {
      final subkeys = <String>[];
      final raw = matchIntent['sub_intent_keys'] as List<dynamic>?;
      if (raw != null) {
        for (final e in raw) {
          subkeys.add(e.toString());
        }
      }
      final result = <Map<String, dynamic>>[];
      for (final sk in subkeys) {
        result.add(<String, dynamic>{
          'id': '',
          'node_key': sk,
          'node_type': 'subintent',
          'display_key': sk,
          'sort_order': 0,
        });
      }
      return result;
    }

    // No matching cached children
    return [];
  }

  /// Search cached options (intents + categories + interest items) for a query.
  /// Returns a list of maps with keys similar to the server RPC:
  /// { interest_key, interest_display, category_key, category_display }
  Future<List<Map<String, dynamic>>> searchOptions(
    String query, {
    int limit = 50,
    String lang = 'en',
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final cached = await getOptionHierarchy();
    if (cached == null) return [];

    final List<Map<String, dynamic>> results = [];

    // Search interest categories/items
    final categories =
        (cached['interests'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        [];
    for (var cat in categories) {
      final catKey = (cat['categoryKey'] ?? '').toString();
      final catDisplayKey = (cat['categoryDisplayKey'] ?? '').toString();
      final items =
          (cat['items'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      for (var item in items) {
        final interestKey = (item['interest_key'] ?? item['interestKey'] ?? '')
            .toString();
        final interestDisplayKey =
            (item['interest_display_key'] ?? item['interestDisplayKey'] ?? '')
                .toString();

        // Match on keys or display keys (these are translation keys; UI will resolve translations)
        final matchCandidates = [
          interestKey.toLowerCase(),
          interestDisplayKey.toLowerCase(),
          catKey.toLowerCase(),
          catDisplayKey.toLowerCase(),
        ];
        if (matchCandidates.any((c) => c.contains(q))) {
          results.add({
            'interest_key': interestKey,
            'interest_display': interestDisplayKey,
            'category_key': catKey,
            'category_display': catDisplayKey,
          });
          if (results.length >= limit) return results;
        }
      }
    }

    // Also search intents by key/display_key
    final intents =
        (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
        [];
    for (var intent in intents) {
      final intentKey = (intent['intent_key'] ?? '').toString();
      final intentDisplay = (intent['display_name_key'] ?? '').toString();
      if ([
        intentKey.toLowerCase(),
        intentDisplay.toLowerCase(),
      ].any((c) => c.contains(q))) {
        // Represent an intent match as a pseudo-result (no category)
        results.add({
          'interest_key': intentKey,
          'interest_display': intentDisplay,
          'category_key': '',
          'category_display': '',
        });
        if (results.length >= limit) return results;
      }
    }

    return results;
  }

  // --- Location Storage ---

  /// Save the current location for a user
  Future<void> saveCurrentLocation(
    String userId,
    double latitude,
    double longitude, {
    double? speed,
    double? heading,
    DateTime? timestamp,
  }) async {
    final box = await _getProfileBox();
    final locationData = {
      'latitude': latitude,
      'longitude': longitude,
      'speed': speed,
      'heading': heading,
      'timestamp': (timestamp ?? DateTime.now()).toIso8601String(),
    };
    await box.put('${userId}_location', jsonEncode(locationData));
  }

  /// Get the saved current location for a user
  Future<Map<String, dynamic>?> getCurrentLocation(String userId) async {
    final box = await _getProfileBox();
    final data = box.get('${userId}_location');
    if (data == null) return null;
    try {
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // --- Offline trail (places recorded while offline, for retroactive matching) ---
  // Stored per user, pruned by the user's own chosen retention. Wiped on upload
  // ack, on feature disable, on "delete now", and on logout.

  /// Append one offline place. Applies stationary dedup (skip if <10m within 60s
  /// of last point) and caps the box at [_kOfflineTrailMaxPoints] (drops oldest).
  Future<void> appendOfflineTrailPoint(
    String userId,
    double latitude,
    double longitude, {
    double? accuracy,
    double? speed,
    double? heading,
    DateTime? recordedAt,
  }) async {
    final box = await _getOfflineTrailBox();
    final now = (recordedAt ?? DateTime.now()).toUtc();
    final prefix = '${userId}_';
    try {
      // Dedup against latest point for this user
      String? latestKey;
      for (final k in box.keys) {
        if (k is String && k.startsWith(prefix)) {
          if (latestKey == null || k.compareTo(latestKey) > 0) latestKey = k;
        }
      }
      if (latestKey != null) {
        try {
          final prev = jsonDecode(box.get(latestKey)!) as Map<String, dynamic>;
          final pLat = (prev['lat'] as num?)?.toDouble();
          final pLng = (prev['lng'] as num?)?.toDouble();
          final pTs = DateTime.tryParse(prev['recorded_at']?.toString() ?? '');
          if (pLat != null && pLng != null && pTs != null) {
            final dt = now.difference(pTs.toUtc()).abs();
            if (dt < const Duration(seconds: 60)) {
              // Rough equirectangular distance (no extra imports)
              const mPerDegLat = 111320.0;
              final dLat = (latitude - pLat) * mPerDegLat;
              final dLng = (longitude - pLng) * 111320.0 * 0.8;
              if ((dLat * dLat + dLng * dLng) < 100.0) return; // <10m
            }
          }
        } catch (_) {}
      }
      final key = '$prefix${now.millisecondsSinceEpoch}';
      await box.put(
        key,
        jsonEncode({
          'lat': latitude,
          'lng': longitude,
          'recorded_at': now.toIso8601String(),
          'accuracy': accuracy,
          'speed': speed,
          'heading': heading,
        }),
      );
      // Cap: drop oldest beyond max
      final userKeys =
          box.keys
              .whereType<String>()
              .where((k) => k.startsWith(prefix))
              .toList()
            ..sort();
      if (userKeys.length > _kOfflineTrailMaxPoints) {
        final overflow = userKeys.length - _kOfflineTrailMaxPoints;
        for (var i = 0; i < overflow; i++) {
          await box.delete(userKeys[i]);
        }
      }
    } catch (_) {}
  }

  /// All kept points for [userId], oldest first.
  Future<List<Map<String, dynamic>>> getOfflineTrail(String userId) async {
    try {
      final box = await _getOfflineTrailBox();
      final prefix = '${userId}_';
      final keys =
          box.keys
              .whereType<String>()
              .where((k) => k.startsWith(prefix))
              .toList()
            ..sort();
      final out = <Map<String, dynamic>>[];
      for (final k in keys) {
        try {
          out.add(jsonDecode(box.get(k)!) as Map<String, dynamic>);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  Future<int> getOfflineTrailCount(String userId) async {
    try {
      final box = await _getOfflineTrailBox();
      final prefix = '${userId}_';
      var n = 0;
      for (final k in box.keys) {
        if (k is String && k.startsWith(prefix)) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// Drop points older than [retention] (used when the chosen time is lowered).
  Future<void> pruneOfflineTrail(String userId, Duration retention) async {
    try {
      final box = await _getOfflineTrailBox();
      final prefix = '${userId}_';
      final cutoff = DateTime.now().toUtc().subtract(retention);
      final keys = box.keys
          .whereType<String>()
          .where((k) => k.startsWith(prefix))
          .toList();
      for (final k in keys) {
        try {
          final m = jsonDecode(box.get(k)!) as Map<String, dynamic>;
          final ts = DateTime.tryParse(m['recorded_at']?.toString() ?? '');
          if (ts == null || ts.toUtc().isBefore(cutoff)) await box.delete(k);
        } catch (_) {
          await box.delete(k);
        }
      }
    } catch (_) {}
  }

  Future<void> clearOfflineTrail(String userId) async {
    final box = await _getOfflineTrailBox();
    final prefix = '${userId}_';
    final keys = box.keys
        .whereType<String>()
        .where((key) => key.startsWith(prefix))
        .toList();
    for (final key in keys) {
      await box.delete(key);
    }
  }

  // --- Events Caching ---

  /// Save user events to local cache with timestamp
  Future<void> saveUserEvents(
    String userId,
    List<Map<String, dynamic>> events,
  ) async {
    final box = await _getEventsBox();
    final cacheData = {
      'events': events,
      'timestamp': DateTime.now().toIso8601String(),
      'userId': userId,
    };
    await box.put(userId, jsonEncode(cacheData));
  }

  /// Get cached user events.
  /// When [maxAge] is null, returns the latest cached events regardless of age.
  Future<List<Map<String, dynamic>>?> getCachedUserEvents(
    String userId, {
    Duration? maxAge,
  }) async {
    final box = await _getEventsBox();
    final data = box.get(userId);
    if (data == null) return null;

    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final timestamp = DateTime.parse(cacheData['timestamp'] as String);
      final cachedUserId = cacheData['userId'] as String;

      final isExpired =
          maxAge != null && DateTime.now().difference(timestamp) > maxAge;

      if (cachedUserId != userId || isExpired) {
        return null;
      }

      return (cacheData['events'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  /// Watch cached user events
  Stream<List<Map<String, dynamic>>?> watchUserEvents(String userId) async* {
    final box = await _getEventsBox();
    final currentData = box.get(userId);
    if (currentData != null) {
      try {
        final cacheData = jsonDecode(currentData) as Map<String, dynamic>;
        final events = (cacheData['events'] as List)
            .cast<Map<String, dynamic>>();
        yield events;
      } catch (_) {
        yield null;
      }
    } else {
      yield null;
    }

    yield* box.watch(key: userId).map((event) {
      if (event.value != null) {
        try {
          final cacheData = jsonDecode(event.value) as Map<String, dynamic>;
          return (cacheData['events'] as List).cast<Map<String, dynamic>>();
        } catch (_) {
          return null;
        }
      }
      return null;
    });
  }

  // --- Settings Caching ---

  /// Save user settings to local cache
  Future<void> saveUserSettings(
    String userId,
    Map<String, dynamic> settings,
  ) async {
    final box = await _getSettingsBox();
    final cacheData = {
      'settings': settings,
      'timestamp': DateTime.now().toIso8601String(),
      'userId': userId,
    };
    await box.put(userId, jsonEncode(cacheData));
  }

  /// Get cached user settings
  Future<Map<String, dynamic>?> getCachedUserSettings(String userId) async {
    final box = await _getSettingsBox();
    final data = box.get(userId);
    if (data == null) return null;

    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final cachedUserId = cacheData['userId'] as String;
      if (cachedUserId != userId) return null;

      return cacheData['settings'] as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Save subscription queue history for offline subscription screens.
  Future<void> saveSubscriptionQueueHistory(
    String userId,
    List<Map<String, dynamic>> entries,
  ) async {
    final box = await _getSettingsBox();
    final cacheData = {
      'userId': userId,
      'timestamp': DateTime.now().toIso8601String(),
      'entries': entries,
    };
    await box.put('subscription_queue_history_$userId', jsonEncode(cacheData));
  }

  /// Get cached subscription queue history for a user.
  Future<List<Map<String, dynamic>>?> getSubscriptionQueueHistory(
    String userId,
  ) async {
    final box = await _getSettingsBox();
    final data = box.get('subscription_queue_history_$userId');
    if (data == null) return null;

    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final cachedUserId = cacheData['userId'] as String?;
      if (cachedUserId != userId) return null;

      final entries = cacheData['entries'];
      if (entries is! List) return null;

      return entries
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Save subscription tiers for offline paywall screen.
  /// Tiers are global (not per-user) so we cache them under a fixed key.
  Future<void> saveSubscriptionTiers(List<Map<String, dynamic>> tiers) async {
    final box = await _getSettingsBox();
    final cacheData = {
      'timestamp': DateTime.now().toIso8601String(),
      'tiers': tiers,
    };
    await box.put(_kSubscriptionTiersKey, jsonEncode(cacheData));
  }

  /// Get cached subscription tiers. Returns null if no cache exists.
  Future<List<Map<String, dynamic>>?> getSubscriptionTiers() async {
    final box = await _getSettingsBox();
    final data = box.get(_kSubscriptionTiersKey);
    if (data == null) return null;
    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final tiers = cacheData['tiers'];
      if (tiers is! List) return null;
      return tiers
          .whereType<Map>()
          .map((tier) => Map<String, dynamic>.from(tier))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Watch cached subscription tiers. Emits the current cached value
  /// immediately (if any), then re-emits whenever the underlying box entry
  /// is updated. Emits `null` if no cached value exists yet.
  Stream<List<Map<String, dynamic>>?> watchSubscriptionTiers() async* {
    final box = await _getSettingsBox();
    final current = box.get(_kSubscriptionTiersKey);
    if (current == null) {
      yield null;
    } else {
      try {
        final cacheData = jsonDecode(current) as Map<String, dynamic>;
        final tiers = cacheData['tiers'];
        if (tiers is List) {
          yield tiers
              .whereType<Map>()
              .map((tier) => Map<String, dynamic>.from(tier))
              .toList();
        } else {
          yield null;
        }
      } catch (_) {
        yield null;
      }
    }
    yield* box.watch(key: _kSubscriptionTiersKey).map((event) {
      if (event.deleted || event.value == null) return null;
      try {
        final cacheData =
            jsonDecode(event.value as String) as Map<String, dynamic>;
        final tiers = cacheData['tiers'];
        if (tiers is! List) return null;
        return tiers
            .whereType<Map>()
            .map((tier) => Map<String, dynamic>.from(tier))
            .toList();
      } catch (_) {
        return null;
      }
    });
  }

  /// Watch cached subscription queue history for a user. Emits the current
  /// cached value immediately (if any), then re-emits whenever the underlying
  /// box entry is updated. Emits `null` if no cached value exists yet.
  Stream<List<Map<String, dynamic>>?> watchSubscriptionQueueHistory(
    String userId,
  ) async* {
    final box = await _getSettingsBox();
    final key = 'subscription_queue_history_$userId';
    final current = box.get(key);
    if (current == null) {
      yield null;
    } else {
      try {
        final cacheData = jsonDecode(current) as Map<String, dynamic>;
        final cachedUserId = cacheData['userId'] as String?;
        if (cachedUserId != userId) {
          yield null;
        } else {
          final entries = cacheData['entries'];
          if (entries is List) {
            yield entries
                .whereType<Map>()
                .map((entry) => Map<String, dynamic>.from(entry))
                .toList();
          } else {
            yield null;
          }
        }
      } catch (_) {
        yield null;
      }
    }
    yield* box.watch(key: key).map((event) {
      if (event.deleted || event.value == null) return null;
      try {
        final cacheData = jsonDecode(event.value) as Map<String, dynamic>;
        final cachedUserId = cacheData['userId'] as String?;
        if (cachedUserId != userId) return null;
        final entries = cacheData['entries'];
        if (entries is! List) return null;
        return entries
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
      } catch (_) {
        return null;
      }
    });
  }

  // --- Translations Caching ---

  /// Save translations for a language to local cache
  Future<void> saveTranslations(
    String languageCode,
    Map<String, String> translations,
  ) async {
    final box = await _getTranslationsBox();
    final cacheData = {
      'translations': translations,
      'timestamp': DateTime.now().toIso8601String(),
      'languageCode': languageCode,
    };
    await box.put(languageCode, jsonEncode(cacheData));
  }

  /// Get cached translations for a language
  Future<Map<String, String>?> getCachedTranslations(
    String languageCode,
  ) async {
    final box = await _getTranslationsBox();
    final data = box.get(languageCode);
    if (data == null) return null;

    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final cachedLang = cacheData['languageCode'] as String;
      if (cachedLang != languageCode) return null;

      return (cacheData['translations'] as Map).cast<String, String>();
    } catch (_) {
      return null;
    }
  }

  /// Clear translation settings for a specific chat (when chat is deleted)
  Future<void> clearChatTranslationSettings(
    String userId,
    String matchId,
  ) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;

    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List)
          .cast<Map<String, dynamic>>();
      final updated = parsed.where((c) {
        return (c['match_id']?.toString() ?? '') != matchId;
      }).toList();

      if (updated.length != parsed.length) {
        // Chat was removed - save the updated list
        await box.put(key, jsonEncode(updated));
        // print('🗑️ Cleared chat translation settings for $matchId');
      }
    } catch (e) {
      // print('🗑️ Error clearing chat translation settings: $e');
    }
  }

  /// Clear all chat data from local storage when clearing app data
  Future<void> clearAllChats(String userId) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    await box.delete(key);
    // print('🗑️ Cleared all chats for user $userId');
  }

  /// Clear all messages for a specific chat
  Future<void> clearChatMessages(String matchId) {
    return _withMessagesWrite(matchId, () async {
      final box = await _getMessagesBox();
      await box.delete(matchId);
      // print('??? Cleared all messages for chat $matchId');
    });
  }

  /// Reset translation settings for a chat to defaults when syncing from server
  /// This ensures local cache matches database state
  Future<void> syncChatTranslationSettings(
    String userId,
    String matchId,
    bool translationEnabled,
    String? translationLanguage,
  ) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;

    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List)
          .cast<Map<String, dynamic>>();
      final updated = parsed.map((c) {
        if ((c['match_id']?.toString() ?? '') == matchId) {
          final copy = Map<String, dynamic>.from(c);
          copy['translation_enabled'] = translationEnabled;
          copy['translation_language'] = translationLanguage;
          return copy;
        }
        return c;
      }).toList();

      await box.put(key, jsonEncode(updated));
    } catch (e) {
      // print('🔄 Error syncing translation settings: $e');
    }
  }

  /// Recompute the chat's last message preview from the current list of messages for the match.
  /// This updates the chat entry with the latest message's content, ID, and timestamp.
  Future<void> recomputeChatLastMessagePreviewFromMessages(
    String userId,
    String matchId,
  ) async {
    try {
      // Get all messages for this match
      final messages = await getMessages(matchId);
      if (messages.isEmpty) {
        // No messages left — delete the chat entry so it disappears from
        // Recent Chats / Chats screen immediately (not just blank).
        await deleteChat(matchId, userId: userId);
        return;
      }

      // Find the latest message by created_at
      messages.sort((a, b) {
        final aDate =
            DateTime.tryParse(a['created_at'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final bDate =
            DateTime.tryParse(b['created_at'] ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return bDate.compareTo(aDate);
      });

      final latestMessage = messages.first;
      final latestId = latestMessage['id']?.toString();
      final latestContent = latestMessage['content_original']?.toString() ?? '';
      final latestTranslated =
          looksLikeEncryptedBlob(
            latestMessage['content_translated']?.toString() ??
                latestMessage['translated_text']?.toString(),
          )
          ? ''
          : (latestMessage['content_translated']?.toString() ??
                latestMessage['translated_text']?.toString() ??
                '');
      final latestSourceLang = latestMessage['detected_source_language']
          ?.toString();
      final latestSenderId = latestMessage['sender_id']?.toString();
      final latestCreatedAt = latestMessage['created_at']?.toString();
      // The content version this preview describes. Everything cached "for the
      // last message" has to be re-checked against it, because an edit keeps
      // `last_message_id` unchanged.
      final latestEditedAt = normalizeEditMarker(latestMessage['edited_at']);

      // Return early only if we have no message ID and no content at all
      if (latestId == null) {
        return;
      }

      // We still proceed even if latestContent is empty because we might have translated content
      // to update (e.g., after decryption of encrypted messages)

      // Update the chat entry with the latest message info
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final current = box.get(key);
      if (current == null) return;

      try {
        final List<Map<String, dynamic>> chats = (jsonDecode(current) as List)
            .cast<Map<String, dynamic>>();
        bool updated = false;

        for (int i = 0; i < chats.length; i++) {
          if ((chats[i]['match_id']?.toString() ?? '') == matchId) {
            final previousLastId = chats[i]['last_message_id']?.toString();
            final previousLastTranslated = chats[i]['last_message_translated']
                ?.toString();
            final previousTranslatedMarker =
                chats[i]['last_message_translated_edited_at']?.toString();
            chats[i]['last_message_id'] = latestId;
            chats[i]['last_message'] = latestContent;
            if (latestSenderId != null && latestSenderId.isNotEmpty) {
              chats[i]['last_message_sender_id'] = latestSenderId;
            }
            // Set source language for translation decision logic
            if (latestSourceLang != null && latestSourceLang.isNotEmpty) {
              chats[i]['last_message_source_language'] = latestSourceLang;
            }
            if (latestEditedAt != null) {
              chats[i]['last_message_edited_at'] = latestEditedAt;
            }

            // Sync translation settings
            chats[i]['translation_enabled'] =
                latestMessage['translation_enabled'] ??
                chats[i]['translation_enabled'] ??
                false;
            chats[i]['translation_language'] =
                latestMessage['translation_language'] ??
                chats[i]['translation_language'];

            // Set translated preview from the latest message if available
            if (latestTranslated.isNotEmpty) {
              chats[i]['last_message_translated'] = latestTranslated;
              // Same content version the cached text describes.
              if (latestEditedAt != null) {
                chats[i]['last_message_translated_edited_at'] = latestEditedAt;
              } else {
                chats[i].remove('last_message_translated_edited_at');
              }
            } else if (previousLastTranslated != null &&
                previousLastTranslated.isNotEmpty &&
                previousLastId == latestId &&
                translationEditMarkersMatch(
                  previousTranslatedMarker,
                  latestEditedAt,
                )) {
              // Preserve existing translation: same message and made for the
              // content it currently has. An edit sets `edited_at`, which
              // mismatches the marker and falls through to the removal below —
              // without this check a pre-edit translation outlived every sync
              // and kept rendering in the Recent Chats row.
              chats[i]['last_message_translated'] = previousLastTranslated;
              if (previousTranslatedMarker != null) {
                chats[i]['last_message_translated_edited_at'] =
                    previousTranslatedMarker;
              }
            } else {
              // New message without translation - remove stale translation
              chats[i].remove('last_message_translated');
              chats[i].remove('last_message_target_language');
              chats[i].remove('last_message_translated_edited_at');
            }
            if (latestCreatedAt != null) {
              chats[i]['last_message_at'] = latestCreatedAt;
            }
            updated = true;
            break;
          }
        }

        if (updated) {
          await box.put(key, jsonEncode(chats));
          // print('✅ Recomputed chat preview for $matchId: message_id=$latestId');
        }
      } catch (e) {
        // print('❌ Error recomputing chat preview: $e');
      }
    } catch (e) {
      // print('❌ recomputeChatLastMessagePreviewFromMessages failed: $e');
    }
  }

  /// Recalculate unread count for a chat based on messages in local DB
  /// This counts messages from the other user where read_at IS NULL
  Future<void> recomputeChatUnreadCountFromMessages(
    String userId,
    String matchId,
  ) async {
    try {
      // Get all messages for this match
      final messages = await getMessages(matchId);

      // Count unread messages from the other user
      // (messages where read_at IS NULL and sender_id != userId)
      int unreadCount = 0;
      for (final msg in messages) {
        final senderId = msg['sender_id']?.toString();
        final readAt = msg['read_at'];

        // Count messages from other user that are unread
        if (senderId != null &&
            senderId != userId &&
            (readAt == null || readAt.isEmpty)) {
          unreadCount++;
        }
      }

      // Update the chat entry with the recalculated unread count
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final current = box.get(key);
      if (current == null) return;

      try {
        final List<Map<String, dynamic>> chats = (jsonDecode(current) as List)
            .cast<Map<String, dynamic>>();
        bool updated = false;

        for (int i = 0; i < chats.length; i++) {
          if ((chats[i]['match_id']?.toString() ?? '') == matchId) {
            final _ = chats[i]['unread_count'] ?? 0;
            chats[i]['unread_count'] = unreadCount;
            // print('🔄 Recomputed unread_count for $matchId: $_ → $unreadCount');
            updated = true;
            break;
          }
        }

        if (updated) {
          await box.put(key, jsonEncode(chats));
        }
      } catch (e) {
        // print('❌ Error recomputing unread count: $e');
      }
    } catch (e) {
      // print('❌ recomputeChatUnreadCountFromMessages failed: $e');
    }
  }

  /// Get other user profile with cache metadata (includes cached_at timestamp)
  Future<Map<String, dynamic>?> getOtherUserProfileWithCacheMeta(
    String userId,
  ) async {
    try {
      final box = await _getProfileBox();
      final key = 'other_user_$userId';
      final data = box.get(key);
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    } catch (e) {
      // print('LocalDb.getOtherUserProfileWithCacheMeta failed: $e');
      return null;
    }
  }

  /// Save profile wizard draft data
  Future<void> saveProfileWizardDraft(
    String userId,
    Map<String, dynamic> draftData,
  ) async {
    try {
      final box = await _getSettingsBox();
      final key = 'profile_wizard_draft_$userId';
      await box.put(key, jsonEncode(draftData));
      // Force pending writes to disk so a force-killed app does not lose the
      // wizard draft (e.g. the user shuts down the app mid-wizard).
      await box.flush();
    } catch (e) {
      // print('LocalDb.saveProfileWizardDraft failed: $e');
    }
  }

  /// Load profile wizard draft data
  Future<Map<String, dynamic>?> loadProfileWizardDraft(String userId) async {
    try {
      final box = await _getSettingsBox();
      final key = 'profile_wizard_draft_$userId';
      final data = box.get(key);
      if (data == null) return null;
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (e) {
      // print('LocalDb.loadProfileWizardDraft failed: $e');
      return null;
    }
  }

  /// Clear profile wizard draft data
  Future<void> clearProfileWizardDraft(String userId) async {
    try {
      final box = await _getSettingsBox();
      final key = 'profile_wizard_draft_$userId';
      await box.delete(key);
    } catch (e) {
      // print('LocalDb.clearProfileWizardDraft failed: $e');
    }
  }

  /// Save pending referral code from deep link
  Future<void> savePendingReferralCode(String code) async {
    try {
      final box = await _getSettingsBox();
      await box.put('pending_referral_code', code);
    } catch (e) {
      // print('LocalDb.savePendingReferralCode failed: $e');
    }
  }

  /// Get pending referral code
  Future<String?> getPendingReferralCode() async {
    try {
      final box = await _getSettingsBox();
      final code = box.get('pending_referral_code');
      return code is String ? code : null;
    } catch (e) {
      // print('LocalDb.getPendingReferralCode failed: $e');
      return null;
    }
  }

  /// Clear pending referral code after processing
  Future<void> clearPendingReferralCode() async {
    try {
      final box = await _getSettingsBox();
      await box.delete('pending_referral_code');
    } catch (e) {
      // print('LocalDb.clearPendingReferralCode failed: $e');
    }
  }

  Future<void> saveCachedReferralCode(String userId, String code) async {
    try {
      final trimmedUserId = userId.trim();
      final trimmedCode = code.trim();
      if (trimmedUserId.isEmpty || trimmedCode.isEmpty) return;
      final box = await _getSettingsBox();
      await box.put('referral_code_$trimmedUserId', trimmedCode);
    } catch (e) {
      // print('LocalDb.saveCachedReferralCode failed: $e');
    }
  }

  Future<String?> getCachedReferralCode(String userId) async {
    try {
      final trimmedUserId = userId.trim();
      if (trimmedUserId.isEmpty) return null;
      final box = await _getSettingsBox();
      final code = box.get('referral_code_$trimmedUserId');
      if (code is! String) return null;
      final trimmedCode = code.trim();
      return trimmedCode.isEmpty ? null : trimmedCode;
    } catch (e) {
      // print('LocalDb.getCachedReferralCode failed: $e');
      return null;
    }
  }

  // --- Offline Cache Support Methods (for OfflineCacheManager) ---

  /// Load user profile for offline display
  Future<Map<String, dynamic>?> loadProfile(String userId) async {
    return getLocalProfile(userId);
  }

  /// Save user profile for offline display
  Future<void> saveProfile(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    return saveLocalProfile(userId, profileData);
  }

  /// Load cached chats for a user
  Future<List<Map<String, dynamic>>?> loadChats(String userId) async {
    try {
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final data = box.get(key);
      if (data == null) return null;
      return (jsonDecode(data) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      // print('LocalDb.loadChats failed: $e');
      return null;
    }
  }

  /// Load cached messages for a match
  Future<List<Map<String, dynamic>>?> loadMessages(String matchId) async {
    try {
      return await getMessages(matchId);
    } catch (e) {
      // print('LocalDb.loadMessages failed: $e');
      return null;
    }
  }

  /// Save cached user events for offline use
  Future<void> saveCachedUserEvents(
    String userId,
    List<Map<String, dynamic>> events,
  ) async {
    try {
      final box = await _getEventsBox();
      final cacheData = {
        'events': events,
        'timestamp': DateTime.now().toIso8601String(),
        'userId': userId,
      };
      await box.put(userId, jsonEncode(cacheData));
      // print('📦 [CACHE] Saved ${events.length} events for user $userId');
    } catch (e) {
      // print('LocalDb.saveCachedUserEvents failed: $e');
    }
  }

  /// Get the last known online count (for offline status display)
  Future<int?> getLastKnownOnlineCount() async {
    try {
      final box = await _getSettingsBox();
      final data = box.get('last_known_online_count');
      if (data == null) return null;
      return int.tryParse(data.toString());
    } catch (e) {
      // print('LocalDb.getLastKnownOnlineCount failed: $e');
      return null;
    }
  }

  /// Save the last known online count for offline use
  Future<void> saveLastKnownOnlineCount(int count) async {
    try {
      final box = await _getSettingsBox();
      await box.put('last_known_online_count', count.toString());
      // print('📊 [CACHE] Saved online count: $count');
    } catch (e) {
      // print('LocalDb.saveLastKnownOnlineCount failed: $e');
    }
  }

  // ── Rating cache helpers ──────────────────────────────────────────────

  /// Save a user's rating summary for offline use.
  Future<void> saveRatingSummary(
    String userId,
    Map<String, dynamic> summary,
  ) async {
    try {
      final box = await _getSettingsBox();
      final data = {...summary, 'cached_at': DateTime.now().toIso8601String()};
      await box.put('rating_summary_$userId', jsonEncode(data));
    } catch (_) {}
  }

  /// Read the cached rating summary for a user. Returns null when absent or expired.
  Future<Map<String, dynamic>?> getCachedRatingSummary(String userId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('rating_summary_$userId');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = data['cached_at'] as String?;
      if (cachedAt == null) return null;
      final cacheDuration = await appConfigService.getDuration(
        'cache.rating_duration_seconds',
        defaultValue: const Duration(days: 1),
      );
      if (DateTime.now().difference(DateTime.parse(cachedAt)) > cacheDuration) {
        return null;
      }
      return Map<String, dynamic>.from(data)..remove('cached_at');
    } catch (_) {
      return null;
    }
  }

  /// Read the cached rating summary even when expired (stale-while-revalidate).
  ///
  /// Used for instant UI startup: the stale value is displayed immediately
  /// from local storage while a background Supabase refresh updates it.
  /// Returns null only when nothing was ever cached.
  Future<Map<String, dynamic>?> getCachedRatingSummaryAllowExpired(
    String userId,
  ) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('rating_summary_$userId');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (!data.containsKey('rated_by_count') &&
          !data.containsKey('overall_avg')) {
        return null;
      }
      return Map<String, dynamic>.from(data)..remove('cached_at');
    } catch (_) {
      return null;
    }
  }

  /// When was the rating summary for [userId] cached? Null when never cached.
  Future<DateTime?> getRatingSummaryCachedAt(String userId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('rating_summary_$userId');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final cachedAt = data['cached_at'] as String?;
      if (cachedAt == null) return null;
      return DateTime.tryParse(cachedAt);
    } catch (_) {
      return null;
    }
  }

  /// Cache whether the current user has rated a specific match.
  Future<void> saveHasRatedMatch(String matchId, bool rated) async {
    try {
      final box = await _getSettingsBox();
      await box.put('has_rated_$matchId', rated ? '1' : '0');
    } catch (_) {}
  }

  /// Read the cached hasRatedMatch value. Returns null when not cached.
  Future<bool?> getCachedHasRatedMatch(String matchId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('has_rated_$matchId');
      if (raw == null) return null;
      return raw == '1';
    } catch (_) {
      return null;
    }
  }

  /// Cache my overall rating for a match (persists across restarts).
  Future<void> saveMyMatchRating(String matchId, double avg) async {
    try {
      final box = await _getSettingsBox();
      await box.put('my_match_rating_$matchId', avg.toStringAsFixed(4));
    } catch (_) {}
  }

  /// Read the cached my-overall-rating for a match. Returns null when not cached.
  Future<double?> getCachedMyMatchRating(String matchId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('my_match_rating_$matchId');
      if (raw == null) return null;
      return double.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Cache the rating questions config for offline use.
  Future<void> saveRatingQuestions(List<Map<String, dynamic>> questions) async {
    try {
      final box = await _getSettingsBox();
      final data = {
        'questions': questions,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put('rating_questions_config', jsonEncode(data));
    } catch (_) {}
  }

  /// Read the cached rating questions. Returns null when absent.
  Future<List<Map<String, dynamic>>?> getCachedRatingQuestions() async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('rating_questions_config');
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = data['questions'] as List?;
      if (list == null) return null;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return null;
    }
  }

  /// Cache whether a rating prompt is pending for a match (memory+Hive layer
  /// for the per-match prompt flag). Displayed instantly, refreshed in bg.
  Future<void> savePendingRatingPrompt(String matchId, bool pending) async {
    try {
      final box = await _getSettingsBox();
      await box.put('pending_prompt_$matchId', pending ? '1' : '0');
    } catch (_) {}
  }

  /// Read the cached pending-prompt flag. Null when never cached.
  Future<bool?> getCachedPendingRatingPrompt(String matchId) async {
    try {
      final box = await _getSettingsBox();
      final raw = box.get('pending_prompt_$matchId');
      if (raw == null) return null;
      return raw == '1';
    } catch (_) {
      return null;
    }
  }
}

// Global provider
final localDbProvider = Provider<LocalDbService>((ref) {
  return LocalDbService.shared;
});
