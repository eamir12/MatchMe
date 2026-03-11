// lib/services/local_db_service.dart
// Local DB service (Hive) with added option-hierarchy cache helpers.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert'; // For jsonEncode/Decode
import 'dart:async';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/app_config_service.dart';

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

class LocalDbService {
  static LocalDbService? _instance;
  static Future<LocalDbService> get instance async {
    _instance ??= LocalDbService();
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
  Box? _optionsBox;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final start = DateTime.now();
    ResumeDiagnostics.log('LocalDb.init start');

    try {
      _profileBox ??= await Hive.openBox(_kProfileBox);
      _matchesBox ??= await Hive.openBox<String>(_kMatchesBox);
      _chatsBox ??= await Hive.openBox<String>(_kChatsBox);
      _messagesBox ??= await Hive.openBox<String>(_kChatMessagesBox);
      _outboxBox ??= await Hive.openBox<String>(_kOutboxBox);
      _profileOutboxBox ??= await Hive.openBox<String>(_kProfileOutboxBox);
      _visibilityOutboxBox ??= await Hive.openBox<String>(_kVisibilityOutboxBox);
      _invisibilityRulesOutboxBox ??= await Hive.openBox<String>(_kInvisibilityRulesOutboxBox);
      _eventsBox ??= await Hive.openBox<String>(_kEventsBox);
      _settingsBox ??= await Hive.openBox<String>(_kSettingsBox);
      _translationsBox ??= await Hive.openBox<String>(_kTranslationsBox);
      _optionsBox ??= await Hive.openBox(_kOptionsBox);
      _initialized = true;

      if (kIsWeb) {
        debugPrint('🔍 [WEB] LocalDb.init - All boxes opened successfully');
        // Perform a quick health check on web
        await _performWebStorageHealthCheck();
      }
    } catch (e) {
      ResumeDiagnostics.log('LocalDb.init failed: $e');
      if (kIsWeb) {
        debugPrint('🔍 [WEB] LocalDb.init - FAILED: $e');
        // Try recovery for web
        await _attemptWebStorageRecovery();
      }
      rethrow;
    }

    final duration = DateTime.now().difference(start).inMilliseconds;
    ResumeDiagnostics.log('LocalDb.init completed in ${duration}ms');
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
        debugPrint('🔍 [WEB] Storage health check: PASSED');
      } else {
        debugPrint('🔍 [WEB] Storage health check: FAILED - read/write test failed');
      }
    } catch (e) {
      debugPrint('🔍 [WEB] Storage health check: FAILED - $e');
      // Don't try recovery here as it might cause issues during init
    }
  }

  Future<void> _attemptWebStorageRecovery() async {
    debugPrint('🔍 [WEB] Attempting storage recovery...');

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

      debugPrint('🔍 [WEB] Cleared corrupted boxes, retrying initialization...');

      // Retry initialization
      await init();
      debugPrint('🔍 [WEB] Storage recovery: SUCCESS');
    } catch (e) {
      debugPrint('🔍 [WEB] Storage recovery: FAILED - $e');
      // If recovery fails, we'll let the error propagate
      rethrow;
    }
  }

  // --- Box Getters (Optimized) ---
  Future<Box> _getProfileBox() async {
    if (_profileBox == null) await init();
    return _profileBox!;
  }

  Future<Box<String>> _getMatchesBox() async {
    if (_matchesBox == null) await init();
    return _matchesBox!;
  }

  Future<Box<String>> _getChatsBox() async {
    if (_chatsBox == null) await init();
    return _chatsBox!;
  }

  Future<Box<String>> _getMessagesBox() async {
    if (_messagesBox == null) await init();
    return _messagesBox!;
  }

  Future<Box<String>> _getOutboxBox() async {
    if (_outboxBox == null) await init();
    return _outboxBox!;
  }

  Future<Box<String>> _getProfileOutboxBox() async {
    if (_profileOutboxBox == null) await init();
    return _profileOutboxBox!;
  }

  Future<Box<String>> _getVisibilityOutboxBox() async {
    if (_visibilityOutboxBox == null) await init();
    return _visibilityOutboxBox!;
  }

  Future<Box<String>> _getInvisibilityRulesOutboxBox() async {
    if (_invisibilityRulesOutboxBox == null) await init();
    return _invisibilityRulesOutboxBox!;
  }

  Future<Box<String>> _getEventsBox() async {
    if (_eventsBox == null) await init();
    return _eventsBox!;
  }

  Future<Box<String>> _getSettingsBox() async {
    if (_settingsBox == null) await init();
    return _settingsBox!;
  }

  Future<Box<String>> _getTranslationsBox() async {
    if (_translationsBox == null) await init();
    return _translationsBox!;
  }

  // --- Profile Methods ---
  Future<void> saveLocalProfile(String userId, Map<String, dynamic> profileData) async {
    final box = await _getProfileBox();
    await box.put(userId, jsonEncode(profileData));
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
        return decoded.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  Future<void> setApprovedPrimaryPhotos(String userId, Set<String> photos) async {
    final box = await _getSettingsBox();
    final cleaned = photos.where((e) => e.isNotEmpty).toSet();
    await box.put('approved_primary_photos_$userId', jsonEncode(cleaned.toList()));
  }

  Future<void> addApprovedPrimaryPhoto(String userId, String photoPath) async {
    if (photoPath.isEmpty) return;
    final current = await loadApprovedPrimaryPhotos(userId);
    if (current.contains(photoPath)) return;
    current.add(photoPath);
    final box = await _getSettingsBox();
    await box.put('approved_primary_photos_$userId', jsonEncode(current.toList()));
  }

  Future<void> removeApprovedPrimaryPhoto(String userId, String photoPath) async {
    if (photoPath.isEmpty) return;
    final current = await loadApprovedPrimaryPhotos(userId);
    if (!current.contains(photoPath)) return;
    current.remove(photoPath);
    final box = await _getSettingsBox();
    await box.put('approved_primary_photos_$userId', jsonEncode(current.toList()));
  }

  // --- Home Screen List Methods ---
  Future<void> saveMatches(List<Map<String, dynamic>> matches) async {
    final box = await _getMatchesBox();
    await box.put('recent_matches', jsonEncode(matches));
  }

  Future<void> addOrUpdateMatch(Map<String, dynamic> matchData) async {
    final box = await _getMatchesBox();
    final currentMatches = box.get('recent_matches');
    
    List<Map<String, dynamic>> matches = [];
    if (currentMatches != null) {
      matches = (jsonDecode(currentMatches) as List).cast<Map<String, dynamic>>();
    }
    
    // Create the match object with consistent keys
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
    };
    
    // Remove if already exists (update case)
    matches.removeWhere((m) => m['match_id'] == match['match_id']);
    
    // Add to the beginning
    matches.insert(0, match);

    await box.put('recent_matches', jsonEncode(matches));
  }

  Future<void> deleteMatch(String matchId) async {
    final box = await _getMatchesBox();
    final currentMatches = box.get('recent_matches');
    if (currentMatches != null) {
      final matches = (jsonDecode(currentMatches) as List).cast<Map<String, dynamic>>();
      final updatedMatches = matches.where((match) => match['match_id'] != matchId).toList();
      await box.put('recent_matches', jsonEncode(updatedMatches));
    }
  }

  Future<void> deleteChat(String matchId, {String? userId}) async {
    final box = await _getChatsBox();

    // Legacy/global key (kept for backward compatibility)
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
      final updatedChats = chats.where((chat) => chat['match_id'] != matchId).toList();
      await box.put(globalKey, jsonEncode(updatedChats));
    }

    // Per-user key (the one used by saveChats/watchChats)
    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
        final updatedChats = chats.where((chat) => chat['match_id'] != matchId).toList();
        await box.put(userKey, jsonEncode(updatedChats));
      }
    }

    // Also clear all associated data for this chat
    debugPrint('🗑️ deleteChat: Clearing all data for chat $matchId');
    await clearChatMessages(matchId);
    if (userId != null && userId.isNotEmpty) {
      await clearChatTranslationSettings(userId, matchId);
    }
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

  Future<void> updateChatLastMessageTranslation(String userId, String matchId, String lastMessageId, String? translatedText) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);
    if (currentChats == null) return;

    final chats = (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();

    // Find and update the chat with this matchId and lastMessageId
    for (int i = 0; i < chats.length; i++) {
      if (chats[i]['match_id'] == matchId && chats[i]['last_message_id'] == lastMessageId) {
        if (translatedText == null || translatedText.trim().isEmpty) {
          chats[i].remove('last_message_translated');
        } else {
          chats[i]['last_message_translated'] = translatedText;
        }
        await box.put(key, jsonEncode(chats));
        break;
      }
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

  /// Clear any cached translations for a given match (messages and recent chat entries).
  /// If [userId] is provided, it will also clear the per-user recent chats key (`recent_chats_$userId`).
  Future<void> clearCachedTranslationsForMatch(String matchId, {String? userId}) async {
    // 1) Clear message-level cached translations
    final messagesBox = await _getMessagesBox();
    final currentMessages = messagesBox.get(matchId);
    if (currentMessages != null) {
      try {
        final messages = (jsonDecode(currentMessages) as List).cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < messages.length; i++) {
          if (messages[i].containsKey('translated_text') || messages[i].containsKey('translated_lang')) {
            messages[i].remove('translated_text');
            messages[i].remove('translated_lang');
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
        final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < chats.length; i++) {
          if (chats[i]['match_id'] == matchId && chats[i].containsKey('last_message_translated')) {
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
          final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
          var changed = false;
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId && chats[i].containsKey('last_message_translated')) {
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

  Future<void> deleteMessages(String matchId) async {
    final box = await _getMessagesBox();
    await box.delete(matchId);
  }

  Future<void> deleteMessage(String matchId, String messageId) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);
    final updatedMessages = messages.where((m) => m['id'] != messageId).toList();
    await box.put(matchId, jsonEncode(updatedMessages));
  }

  Stream<List<Map<String, dynamic>>> watchMatches() async* {
    ResumeDiagnostics.log('LocalDb.watchMatches called');
    final box = await _getMatchesBox();
    final currentMatches = box.get('recent_matches');
    if (currentMatches != null) {
      ResumeDiagnostics.log('LocalDb.watchMatches yielding ${jsonDecode(currentMatches).length} items (initial)');
      yield (jsonDecode(currentMatches) as List).cast<Map<String, dynamic>>();
    } else {
      ResumeDiagnostics.log('LocalDb.watchMatches yielding 0 items (initial)');
      yield [];
    }
    yield* box.watch(key: 'recent_matches').map((event) {
      if (event.value != null && !event.deleted) {
        final parsed = (jsonDecode(event.value) as List).cast<Map<String, dynamic>>();
        // Throttle high-frequency events to avoid log spam
        ResumeDiagnostics.logThrottled('LocalDb.watchMatches event: ${parsed.length} items', category: 'watchMatches.event', minIntervalMs: 1000);
        return parsed;
      }
      ResumeDiagnostics.log('LocalDb.watchMatches event: empty or deleted');
      return [];
    });
  }

  Future<void> saveChats(String userId, List<Map<String, dynamic>> chats) async {
    try {
      final box = await _getChatsBox();

    // Merge with existing per-user cache to preserve cached translations
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);
    if (currentChats != null) {
      try {
        final existing = (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();
        final Map<String, Map<String, dynamic>> existingByMatch = {
          for (var c in existing) (c['match_id']?.toString() ?? ''): c,
        };

        for (int i = 0; i < chats.length; i++) {
          final incoming = chats[i];
          final matchId = incoming['match_id']?.toString() ?? '';
          if (matchId.isEmpty) continue;

          final existingEntry = existingByMatch[matchId];
          if (existingEntry != null) {
            // IMPORTANT: Always use server-provided translation_enabled and translation_language
            // Supabase is the source of truth. When a chat is deleted and recreated,
            // the client cache must reset to server values (default false).
            // Do NOT preserve cached translation settings.
            
            // Only preserve cached last_message_translated if it's for the same message
            // (to avoid flicker when showing preview).
            final incomingTranslated = incoming['last_message_translated'] as String?;
            final existingTranslated = existingEntry['last_message_translated'] as String?;
            final incomingLastId = incoming['last_message_id']?.toString();
            final existingLastId = existingEntry['last_message_id']?.toString();

            if ((incomingTranslated == null || incomingTranslated.isEmpty) &&
                existingTranslated != null && existingTranslated.isNotEmpty &&
                incomingLastId != null && existingLastId != null &&
                incomingLastId == existingLastId) {
              incoming['last_message_translated'] = existingTranslated;
            }
          }
        }
      } catch (_) {
        // If merge fails for any reason, fall back to overwriting cache
      }
    }

    if (kIsWeb) {
      debugPrint('🔍 [WEB] saveChats - Storing ${chats.length} chats to local DB key: $key');
      for (final chat in chats) {
        debugPrint('🔍 [WEB] Storing Chat: match_id=${chat['match_id']}, unread_count=${chat['unread_count']}, other_user_name="${chat['other_user_name']}", last_message="${chat['last_message']}"');
      }
    }

    await box.put(key, jsonEncode(chats));

    if (kIsWeb) {
      debugPrint('🔍 [WEB] saveChats - Successfully stored ${chats.length} chats');
    }
  } catch (e) {
    debugPrint('LocalDb.saveChats failed: $e');
    if (kIsWeb) {
      debugPrint('🔍 [WEB] saveChats - FAILED: $e');
      // On web, storage failures are more common. Try a simpler approach.
      try {
        final box = await _getChatsBox();
        final key = 'recent_chats_$userId';
        // Skip the merge logic and just save directly
        await box.put(key, jsonEncode(chats));
        debugPrint('🔍 [WEB] saveChats - Recovered with simple save');
      } catch (recoveryError) {
        debugPrint('🔍 [WEB] saveChats - Recovery also failed: $recoveryError');
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
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
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
  Future<void> markTranslationNotificationPending(String matchId, {String? userId}) async {
    final box = await _getChatsBox();

    // Global list
    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
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
          final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
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
  Future<bool> isTranslationNotificationPending(String matchId, {String? userId}) async {
    final box = await _getChatsBox();

    if (userId != null && userId.isNotEmpty) {
      final userKey = 'recent_chats_$userId';
      final userChats = box.get(userKey);
      if (userChats != null) {
        try {
          final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
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
        final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
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
  Future<void> clearTranslationNotificationPending(String matchId, {String? userId}) async {
    final box = await _getChatsBox();

    final globalKey = 'recent_chats';
    final globalChats = box.get(globalKey);
    if (globalChats != null) {
      try {
        final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
        var changed = false;
        for (int i = 0; i < chats.length; i++) {
          if (chats[i]['match_id'] == matchId && chats[i]['translation_auto_disabled_unread'] == true) {
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
          final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
          var changed = false;
          for (int i = 0; i < chats.length; i++) {
            if (chats[i]['match_id'] == matchId && chats[i]['translation_auto_disabled_unread'] == true) {
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
  Future<void> updateChatTranslation(String userId, String matchId, bool enabled, String? language) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;
    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
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
          final chats = (jsonDecode(userChats) as List).cast<Map<String, dynamic>>();
          final chat = chats.firstWhere(
            (c) => (c['match_id']?.toString() ?? '') == matchId, 
            orElse: () => <String, dynamic>{}
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
        final chats = (jsonDecode(globalChats) as List).cast<Map<String, dynamic>>();
        final chat = chats.firstWhere(
          (c) => (c['match_id']?.toString() ?? '') == matchId, 
          orElse: () => <String, dynamic>{}
        );
        if (chat.isNotEmpty) {
           return (chat['translation_enabled'] ?? false) == true;
        }
      } catch (_) {}
    }
    
    return false;
  }

  Stream<List<Map<String, dynamic>>> watchChats(String userId) async* {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);

    if (kIsWeb) {
      debugPrint('🔍 [WEB] watchChats - Watching key: $key');
    }

    if (currentChats != null) {
      final chats = (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();
      if (kIsWeb) {
        debugPrint('🔍 [WEB] watchChats - Initial yield: ${chats.length} chats');
        for (final chat in chats) {
          debugPrint('🔍 [WEB] Initial Chat: match_id=${chat['match_id']}, unread_count=${chat['unread_count']}, other_user_name="${chat['other_user_name']}"');
        }
      }
      yield chats;
    } else {
      if (kIsWeb) {
        debugPrint('🔍 [WEB] watchChats - Initial yield: no chats found');
      }
      yield [];
    }
    yield* box.watch(key: key).map((event) {
      final chats = event.value != null && !event.deleted
        ? (jsonDecode(event.value) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

      if (kIsWeb) {
        debugPrint('🔍 [WEB] watchChats - Stream update: ${chats.length} chats');
        for (final chat in chats) {
          debugPrint('🔍 [WEB] Stream Chat: match_id=${chat['match_id']}, unread_count=${chat['unread_count']}, other_user_name="${chat['other_user_name']}"');
        }
      }

      return chats;
    });
  }

  // --- Chat Message Methods ---
  Future<List<Map<String, dynamic>>> getMessages(String matchId) async {
    final box = await _getMessagesBox();
    final currentMessages = box.get(matchId);
    if (currentMessages != null) {
      try {
        return (jsonDecode(currentMessages) as List).cast<Map<String, dynamic>>();
      } catch (_) {
        return [];
      }
    }
    return [];
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

  Future<Map<String, dynamic>?> getMessageById(String matchId, String messageId) async {
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
  Future<List<Map<String, dynamic>>> getCachedReactors(String matchId, String messageId, String reaction) async {
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
          return list.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      }
    }
    return [];
  }

  Future<void> saveCachedReactors(String matchId, String messageId, String reaction, List<Map<String, dynamic>> reactors) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);
    final index = messages.indexWhere((m) => m['id']?.toString() == messageId);
    if (index == -1) return;
    final msg = Map<String, dynamic>.from(messages[index]);
    final reactorsContainer = (msg['reactors'] is Map) ? Map<String, dynamic>.from(msg['reactors']) : <String, dynamic>{};
    
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

  Future<void> clearMessageReactorCache(String matchId, String messageId) async {
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
  Future<List<String>> addMessages(String matchId, List<Map<String, dynamic>> newMessages, {String? currentUserId}) async {
    if (newMessages.isEmpty) {
      return [];
    }
    final box = await _getMessagesBox();
    final oldMessages = await getMessages(matchId);
    final existingIds = oldMessages.map((m) => m['id']).toSet();
    final uniqueNewMessages = newMessages.where((m) => !existingIds.contains(m['id'])).toList();

    if (uniqueNewMessages.isEmpty) {
      return [];
    }

    // Track which messages need RPC calls (from other user, not yet delivered)
    final messagesToMarkDelivered = <String>[];

    // Do NOT mark new messages as delivered locally
    // The actual server sync will happen via RPC calls in the background
    for (final msg in uniqueNewMessages) {
      final msgId = msg['id'];
      final senderId = msg['sender_id'];
      final currentDelivered = msg['delivered_at'];
      debugPrint('📥 addMessages: Processing message $msgId (delivered_at=$currentDelivered, sender=$senderId)');
      
      // IMPORTANT: Do NOT mark incoming messages as delivered locally!
      // Only queue them for RPC marking. The server will update delivered_at.
      // When messages are re-synced, they'll have the actual server delivered_at value.
      if (currentUserId != null && senderId != null && senderId != currentUserId && (msg['delivered_at'] == null || msg['delivered_at'] == '')) {
        messagesToMarkDelivered.add(msgId.toString());
        debugPrint('📤 addMessages: Queued $msgId for RPC delivery marking (from other user)');
      }
    }

    final combinedMessages = [...oldMessages, ...uniqueNewMessages];
    await box.put(matchId, jsonEncode(combinedMessages));
    
    return messagesToMarkDelivered;
  }

  Future<void> replaceMessage(String matchId, String tempId, Map<String, dynamic> realMessage) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);

    final index = messages.indexWhere((m) => m['id'] == tempId);

    if (index != -1) {
      messages[index] = realMessage;
      await box.put(matchId, jsonEncode(messages));
    } else {
      // Ignore returned delivery messages for replaceMessage
      await addMessages(matchId, [realMessage]);
    }
  }

  Future<void> mergeMessages(String matchId, List<Map<String, dynamic>> incomingMessages) async {
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

      // Prefer incoming server-side values when present (e.g., updated reaction_summary)
      // Fall back to old local values only when incoming doesn't provide them.
      // Normalize reaction_summary keys: remove empty keys and coerce values to int
      Map<String, int>? normalizeReactionSummary(dynamic rs) {
        if (rs == null) return null;
        if (rs is Map) {
          final out = <String,int>{};
          rs.forEach((k, v) {
            final key = (k?.toString() ?? '').trim();
            if (key.isEmpty) return; // drop empty keys
            final intVal = (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
            if (intVal > 0) out[key] = intVal;
          });
          return out;
        }
        return null;
      }

      final mergedReactionSummary = normalizeReactionSummary(incomingMsg['reaction_summary']) ?? normalizeReactionSummary(oldReactionSummary);
      final mergedMyReaction = (incomingMsg['my_reaction'] == '' ? null : (incomingMsg['my_reaction'] ?? oldMyReaction));

      // Use server translation if available, otherwise fall back to local cache
      // This ensures new translations from translate-proxy aren't overwritten
      final incomingTranslation = incomingMsg['content_translated'] as String?;
      final incomingTranslationLang = incomingMsg['translated_target_language'] as String?;
      
      final mergedTranslation = (incomingTranslation != null && incomingTranslation.isNotEmpty) 
          ? incomingTranslation 
          : oldTranslation;
      final mergedTranslationLang = (incomingTranslationLang != null && incomingTranslationLang.isNotEmpty) 
          ? incomingTranslationLang 
          : oldTranslationLang;

      messageMap[incomingMsg['id'].toString()] = {
        ...incomingMsg,
        'translated_text': mergedTranslation,
        'translated_lang': mergedTranslationLang,
        'reaction_summary': mergedReactionSummary,
        'my_reaction': mergedMyReaction,
      };
    }

    final combinedList = messageMap.values.toList();

    combinedList.sort((a, b) {
      final aDate = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aDate.compareTo(bDate);
    });

    // Normalize any reaction_summary in the combined list before persisting to avoid
    // storing empty-string keys or non-integer counts.
    for (final msg in combinedList) {
      final rs = msg['reaction_summary'];
      if (rs is Map) {
        final cleaned = <String,int>{};
        rs.forEach((k, v) {
          final key = (k?.toString() ?? '').trim();
          if (key.isEmpty) return;
          final intVal = (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
          if (intVal > 0) cleaned[key] = intVal;
        });
        msg['reaction_summary'] = cleaned;
      }
    }

    await box.put(matchId, jsonEncode(combinedList));
  }

  Future<void> saveMessages(String matchId, List<Map<String, dynamic>> messages) async {
    final box = await _getMessagesBox();
    
    // Get existing messages to preserve local translations and pending messages
    final existingMessages = await getMessages(matchId);
    final existingTranslations = <String, Map<String, dynamic>>{};
    final pendingMessages = <Map<String, dynamic>>[];
    
    // Build a map of existing translations by message ID and collect pending messages
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
    }
    
    // Create a mutable copy of the incoming messages
    final allMessages = List<Map<String, dynamic>>.from(messages);

    // Merge translations and reactions into the new messages from Supabase
    for (final message in allMessages) {
      final msgId = message['id']?.toString();
      if (msgId != null && existingTranslations.containsKey(msgId)) {
        message['translated_text'] = existingTranslations[msgId]!['translated_text'];
        message['translated_lang'] = existingTranslations[msgId]!['translated_lang'];
      }

      // preserve reactions from existing messages if present
      final existingMsg = existingMessages.firstWhere((m) => m['id']?.toString() == msgId, orElse: () => {});
      if (existingMsg.isNotEmpty) {
        if (existingMsg.containsKey('reaction_summary')) {
          message['reaction_summary'] = existingMsg['reaction_summary'];
        }
        if (existingMsg.containsKey('my_reaction')) {
          message['my_reaction'] = existingMsg['my_reaction'];
        }
      }
      
      // IMPORTANT: Do NOT mark received messages as delivered locally!
      // The delivered_at field should only be set by the server when confirmed.
      // The RPC call mark_message_delivered will update the server, and when
      // messages are re-synced, they'll have the actual server delivered_at value.
    }

    // Append pending messages that are not in the new list
    final newIds = allMessages.map((m) => m['id']?.toString()).toSet();
    for (final pending in pendingMessages) {
      if (!newIds.contains(pending['id']?.toString())) {
        allMessages.add(pending);
      }
    }

    // Sort by created_at
    allMessages.sort((a, b) {
      final aDate = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aDate.compareTo(bDate);
    });
    
    await box.put(matchId, jsonEncode(allMessages));
  }

  Future<void> saveTranslation(String matchId, String messageId, String translation, String targetLang) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);

    final index = messages.indexWhere((m) => m['id'].toString() == messageId);

    if (index != -1) {
      messages[index]['translated_text'] = translation;
      messages[index]['translated_lang'] = targetLang;
      await box.put(matchId, jsonEncode(messages));
    }
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String matchId) async* {
    try {
      // Attempt to open the box but fail fast if it takes too long (e.g., IndexedDB stuck on web)
      Box? box;
      try {
        box = await _getMessagesBox().timeout(const Duration(seconds: 2));
      } on TimeoutException catch (e, st) {
        debugPrint('watchMessages: _getMessagesBox timeout for $matchId: $e\n$st');
        box = null;
      } catch (e, st) {
        debugPrint('watchMessages: _getMessagesBox threw for $matchId: $e\n$st');
        box = null;
      }

      if (box == null) {
        debugPrint('watchMessages: falling back to empty stream for $matchId due to missing box');
        yield <Map<String, dynamic>>[];
        await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
          yield <Map<String, dynamic>>[];
        }
        return;
      }

      final initialMessages = await getMessages(matchId).timeout(const Duration(seconds: 2), onTimeout: () {
        debugPrint('watchMessages: getMessages timeout for $matchId - returning empty');
        return <Map<String, dynamic>>[];
      });

      yield initialMessages;
      yield* box.watch(key: matchId).asyncMap((event) async {
        try {
          if (event.value != null && !event.deleted) {
            final messages = (jsonDecode(event.value) as List).cast<Map<String, dynamic>>();
            return messages;
          }
          return <Map<String, dynamic>>[];
        } catch (e, st) {
          debugPrint('watchMessages asyncMap decode error for $matchId: $e\n$st');
          return <Map<String, dynamic>>[];
        }
      });
    } catch (e, st) {
      debugPrint('watchMessages failed to open box for $matchId: $e\n$st');
      // Fail gracefully and return an empty stream so UI can show empty state instead of loading forever
      yield <Map<String, dynamic>>[];
      await for (final _ in Stream<void>.periodic(const Duration(seconds: 5))) {
        // keep yielding empty list periodically in case box becomes available later
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

  // --- Profile Outbox Methods ---
  Future<void> saveProfileUpdateToOutbox(String userId, Map<String, dynamic> updatePayload) async {
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
  Future<void> saveVisibilityUpdateToOutbox(String userId, bool isVisible) async {
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

  // --- Invisibility Rules Outbox Methods ---
  Future<void> saveInvisibilityRulesUpdateToOutbox(String userId, String rulesJson) async {
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
  }

  // --- NEW OPTION HIERARCHY CACHE HELPERS ---

  /// Save dashboard statistics (online/nearby counts) to local cache
  Future<void> saveDashboardStats(int onlineCount, int nearbyCount) async {
    try {
      final box = await _getSettingsBox();
      final statsData = {
        'online_count': onlineCount,
        'nearby_count': nearbyCount,
        'last_updated': DateTime.now().toIso8601String(),
      };
      await box.put('dashboard_stats', jsonEncode(statsData));

      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveDashboardStats - Cached online: $onlineCount, nearby: $nearbyCount');
      }
    } catch (e) {
      debugPrint('LocalDb.saveDashboardStats failed: $e');
      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveDashboardStats - FAILED: $e');
      }
    }
  }

  /// Get cached dashboard statistics (returns null if expired or missing)
  Future<Map<String, int>?> getDashboardStats() async {
    try {
      final box = await _getSettingsBox();
      final jsonString = box.get('dashboard_stats');
      if (jsonString == null) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getDashboardStats - No cached stats found');
        }
        return null;
      }

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final lastUpdated = DateTime.parse(data['last_updated']);
      // Cache for 5 minutes
      final cacheDuration = await appConfigService.getDuration(
        'cache.profile_duration_seconds',
        defaultValue: const Duration(minutes: 5)
      );
      if (DateTime.now().difference(lastUpdated) > cacheDuration) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getDashboardStats - Cache expired');
        }
        return null; // Expired
      }

      final stats = <String, int>{
        'online': (data['online_count'] as int?) ?? 0,
        'nearby': (data['nearby_count'] as int?) ?? 0,
      };

      if (kIsWeb) {
        debugPrint('🔍 [WEB] getDashboardStats - Returning cached stats: $stats');
      }

      return stats;
    } catch (e) {
      debugPrint('LocalDb.getDashboardStats failed: $e');
      return null;
    }
  }

  /// Save individual event details to local cache
  Future<void> saveEventDetails(String eventId, Map<String, dynamic> eventData) async {
    try {
      final box = await _getEventsBox();
      final key = 'event_$eventId';
      final dataToCache = {
        ...eventData,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, jsonEncode(dataToCache));

      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveEventDetails - Cached event: $eventId');
      }
    } catch (e) {
      debugPrint('LocalDb.saveEventDetails failed: $e');
      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveEventDetails - FAILED: $e');
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
          debugPrint('🔍 [WEB] getEventDetails - No cached data for event: $eventId');
        }
        return null;
      }

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cached_at']);

      // Cache for 30 minutes (events don't change often)
      final cacheDuration = await appConfigService.getDuration(
        'cache.events_duration_seconds',
        defaultValue: const Duration(minutes: 30)
      );
      if (DateTime.now().difference(cachedAt) > cacheDuration) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getEventDetails - Cache expired for event: $eventId');
        }
        return null; // Expired
      }

      // Remove cache metadata before returning
      final cleanData = Map<String, dynamic>.from(data)..remove('cached_at');

      if (kIsWeb) {
        debugPrint('🔍 [WEB] getEventDetails - Returning cached event: $eventId');
      }

      return cleanData;
    } catch (e) {
      debugPrint('LocalDb.getEventDetails failed: $e');
      return null;
    }
  }

  /// Save other user profile to local cache
  Future<void> saveOtherUserProfile(String userId, Map<String, dynamic> profileData) async {
    try {
      final box = await _getProfileBox();
      final key = 'other_user_$userId';
      final dataToCache = {
        ...profileData,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, dataToCache);

      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveOtherUserProfile - Cached profile for user: $userId');
      }
    } catch (e) {
      debugPrint('LocalDb.saveOtherUserProfile failed: $e');
      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveOtherUserProfile - FAILED: $e');
      }
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
          debugPrint('🔍 [WEB] getOtherUserProfile - No cached profile for user: $userId');
        }
        return null;
      }

      final cachedAt = DateTime.parse(data['cached_at']);

      // Cache for 1 hour (profiles don't change very often)
      final cacheDuration = await appConfigService.getDuration(
        'cache.rules_duration_seconds',
        defaultValue: const Duration(hours: 1)
      );
      if (DateTime.now().difference(cachedAt) > cacheDuration) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getOtherUserProfile - Cache expired for user: $userId');
        }
        return null; // Expired
      }

      // Remove cache metadata before returning
      final cleanData = Map<String, dynamic>.from(data)..remove('cached_at');

      if (kIsWeb) {
        debugPrint('🔍 [WEB] getOtherUserProfile - Returning cached profile for user: $userId');
      }

      return cleanData;
    } catch (e) {
      debugPrint('LocalDb.getOtherUserProfile failed: $e');
      return null;
    }
  }

  /// Save event attendees list to local cache
  Future<void> saveEventAttendees(String eventId, List<Map<String, dynamic>> attendees) async {
    try {
      final box = await _getEventsBox();
      final key = 'attendees_$eventId';
      final dataToCache = {
        'attendees': attendees,
        'cached_at': DateTime.now().toIso8601String(),
      };
      await box.put(key, jsonEncode(dataToCache));

      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveEventAttendees - Cached ${attendees.length} attendees for event: $eventId');
      }
    } catch (e) {
      debugPrint('LocalDb.saveEventAttendees failed: $e');
      if (kIsWeb) {
        debugPrint('🔍 [WEB] saveEventAttendees - FAILED: $e');
      }
    }
  }

  /// Get cached event attendees (returns null if expired or missing)
  Future<List<Map<String, dynamic>>?> getEventAttendees(String eventId) async {
    try {
      final box = await _getEventsBox();
      final key = 'attendees_$eventId';
      final jsonString = box.get(key);

      if (jsonString == null) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getEventAttendees - No cached attendees for event: $eventId');
        }
        return null;
      }

      final data = jsonDecode(jsonString) as Map<String, dynamic>;
      final cachedAt = DateTime.parse(data['cached_at']);

      // Cache for 15 minutes (attendee lists change more frequently)
      final cacheDuration = await appConfigService.getDuration(
        'cache.events_duration_seconds',
        defaultValue: const Duration(minutes: 15)
      );
      if (DateTime.now().difference(cachedAt) > cacheDuration) {
        if (kIsWeb) {
          debugPrint('🔍 [WEB] getEventAttendees - Cache expired for event: $eventId');
        }
        return null; // Expired
      }

      final attendees = (data['attendees'] as List<dynamic>?)
          ?.map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

      if (kIsWeb) {
        debugPrint('🔍 [WEB] getEventAttendees - Returning ${attendees?.length ?? 0} cached attendees for event: $eventId');
      }

      return attendees;
    } catch (e) {
      debugPrint('LocalDb.getEventAttendees failed: $e');
      return null;
    }
  }

  /// Save the hierarchical options map (intents + interest categories) to local Hive cache.
  Future<void> saveOptionHierarchy(Map<String, dynamic> hierarchy) async {
    final box = await _getOptionsBox();
    // store under fixed key 'hierarchy'
    await box.put('hierarchy', jsonEncode(hierarchy));
  }

  Future<Box> _getOptionsBox() async {
    if (_optionsBox == null) await init();
    return _optionsBox!;
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
    final intents = (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final matched = intents.where((i) {
      final key = (i['intent_key'] ?? '').toString();
      final display = (i['display_name_key'] ?? '').toString();
      return key.toLowerCase() == intentKey.toLowerCase() || display.toLowerCase() == intentKey.toLowerCase();
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
      final categories = (cached['interests'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      final match = categories.firstWhere(
        (c) => (c['categoryKey']?.toString() ?? '') == catKey || (c['categoryDisplayKey']?.toString() ?? '') == catKey,
        orElse: () => <String, dynamic>{},
      );
      if (match.isEmpty) return [];
      final items = (match['items'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      return items.map((it) {
        return <String, dynamic>{
          'id': '',
          'node_key': it['interest_key'] ?? it['interestKey'] ?? '',
          'node_type': 'interest',
          'display_key': it['interest_display_key'] ?? it['interestDisplayKey'] ?? '',
          'sort_order': it['interest_sort_order'] ?? it['interestSortOrder'] ?? 0,
        };
      }).toList();
    }

    // If parentId equals an intent key (node_key), return subIntentKeys when available in cache
    final intents = (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final matchIntent = intents.firstWhere(
      (i) => (i['intent_key']?.toString() ?? '') == parentId || (i['display_name_key']?.toString() ?? '') == parentId,
      orElse: () => <String, dynamic>{},
    );
    if (matchIntent.isNotEmpty) {
      final subkeys = (matchIntent['sub_intent_keys'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
      return subkeys.map((sk) {
        return <String, dynamic>{
          'id': '',
          'node_key': sk,
          'node_type': 'subintent',
          'display_key': sk,
          'sort_order': 0,
        };
      }).toList();
    }

    // No matching cached children
    return [];
  }

  /// Search cached options (intents + categories + interest items) for a query.
  /// Returns a list of maps with keys similar to the server RPC:
  /// { interest_key, interest_display, category_key, category_display }
  Future<List<Map<String, dynamic>>> searchOptions(String query, {int limit = 50, String lang = 'en'}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final cached = await getOptionHierarchy();
    if (cached == null) return [];

    final List<Map<String, dynamic>> results = [];

    // Search interest categories/items
    final categories = (cached['interests'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    for (var cat in categories) {
      final catKey = (cat['categoryKey'] ?? '').toString();
      final catDisplayKey = (cat['categoryDisplayKey'] ?? '').toString();
      final items = (cat['items'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
      for (var item in items) {
        final interestKey = (item['interest_key'] ?? item['interestKey'] ?? '').toString();
        final interestDisplayKey = (item['interest_display_key'] ?? item['interestDisplayKey'] ?? '').toString();

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
    final intents = (cached['intents'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    for (var intent in intents) {
      final intentKey = (intent['intent_key'] ?? '').toString();
      final intentDisplay = (intent['display_name_key'] ?? '').toString();
      if ([intentKey.toLowerCase(), intentDisplay.toLowerCase()].any((c) => c.contains(q))) {
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
  Future<void> saveCurrentLocation(String userId, double latitude, double longitude, {double? speed, double? heading, DateTime? timestamp}) async {
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

  // --- Events Caching ---

  /// Save user events to local cache with timestamp
  Future<void> saveUserEvents(String userId, List<Map<String, dynamic>> events) async {
    final box = await _getEventsBox();
    final cacheData = {
      'events': events,
      'timestamp': DateTime.now().toIso8601String(),
      'userId': userId,
    };
    await box.put(userId, jsonEncode(cacheData));
  }

  /// Get cached user events if not stale (within 5 minutes)
  Future<List<Map<String, dynamic>>?> getCachedUserEvents(String userId, {Duration maxAge = const Duration(minutes: 5)}) async {
    final box = await _getEventsBox();
    final data = box.get(userId);
    if (data == null) return null;

    try {
      final cacheData = jsonDecode(data) as Map<String, dynamic>;
      final timestamp = DateTime.parse(cacheData['timestamp'] as String);
      final cachedUserId = cacheData['userId'] as String;

      // Check if cache is for the right user and not stale
      if (cachedUserId != userId || DateTime.now().difference(timestamp) > maxAge) {
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
        final events = (cacheData['events'] as List).cast<Map<String, dynamic>>();
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
  Future<void> saveUserSettings(String userId, Map<String, dynamic> settings) async {
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

  // --- Translations Caching ---

  /// Save translations for a language to local cache
  Future<void> saveTranslations(String languageCode, Map<String, String> translations) async {
    final box = await _getTranslationsBox();
    final cacheData = {
      'translations': translations,
      'timestamp': DateTime.now().toIso8601String(),
      'languageCode': languageCode,
    };
    await box.put(languageCode, jsonEncode(cacheData));
  }

  /// Get cached translations for a language
  Future<Map<String, String>?> getCachedTranslations(String languageCode) async {
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
  Future<void> clearChatTranslationSettings(String userId, String matchId) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;

    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
      final updated = parsed.where((c) {
        return (c['match_id']?.toString() ?? '') != matchId;
      }).toList();

      if (updated.length != parsed.length) {
        // Chat was removed - save the updated list
        await box.put(key, jsonEncode(updated));
        debugPrint('🗑️ Cleared chat translation settings for $matchId');
      }
    } catch (e) {
      debugPrint('🗑️ Error clearing chat translation settings: $e');
    }
  }

  /// Clear all chat data from local storage when clearing app data
  Future<void> clearAllChats(String userId) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    await box.delete(key);
    debugPrint('🗑️ Cleared all chats for user $userId');
  }

  /// Clear all messages for a specific chat
  Future<void> clearChatMessages(String matchId) async {
    final box = await _getMessagesBox();
    final key = 'chat_messages_$matchId';
    await box.delete(key);
    debugPrint('🗑️ Cleared all messages for chat $matchId');
  }

  /// Reset translation settings for a chat to defaults when syncing from server
  /// This ensures local cache matches database state
  Future<void> syncChatTranslationSettings(String userId, String matchId, bool translationEnabled, String? translationLanguage) async {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final current = box.get(key);
    if (current == null) return;

    try {
      final List<Map<String, dynamic>> parsed = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
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
      debugPrint('🔄 Error syncing translation settings: $e');
    }
  }

  /// Recompute the chat's last message preview from the current list of messages for the match.
  /// This updates the chat entry with the latest message's content, ID, and timestamp.
  Future<void> recomputeChatLastMessagePreviewFromMessages(String userId, String matchId) async {
    try {
      // Get all messages for this match
      final messages = await getMessages(matchId);
      if (messages.isEmpty) {
        // No messages, nothing to update
        return;
      }

      // Find the latest message by created_at
      messages.sort((a, b) {
        final aDate = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bDate = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bDate.compareTo(aDate);
      });

      final latestMessage = messages.first;
      final latestId = latestMessage['id']?.toString();
      final latestContent = latestMessage['content_original']?.toString() ?? '';
      final latestSenderId = latestMessage['sender_id']?.toString();
      final latestCreatedAt = latestMessage['created_at']?.toString();

      if (latestId == null || latestContent.isEmpty) {
        return;
      }

      // Update the chat entry with the latest message info
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final current = box.get(key);
      if (current == null) return;

      try {
        final List<Map<String, dynamic>> chats = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
        bool updated = false;

        for (int i = 0; i < chats.length; i++) {
          if ((chats[i]['match_id']?.toString() ?? '') == matchId) {
            final previousLastId = chats[i]['last_message_id']?.toString();
            final previousLastMessage = chats[i]['last_message']?.toString();
            chats[i]['last_message_id'] = latestId;
            chats[i]['last_message'] = latestContent;
            if (latestSenderId != null && latestSenderId.isNotEmpty) {
              chats[i]['last_message_sender_id'] = latestSenderId;
            }
            if ((previousLastId != latestId || previousLastMessage != latestContent) && chats[i].containsKey('last_message_translated')) {
              chats[i].remove('last_message_translated');
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
          debugPrint('✅ Recomputed chat preview for $matchId: message_id=$latestId');
        }
      } catch (e) {
        debugPrint('❌ Error recomputing chat preview: $e');
      }
    } catch (e) {
      debugPrint('❌ recomputeChatLastMessagePreviewFromMessages failed: $e');
    }
  }

  /// Recalculate unread count for a chat based on messages in local DB
  /// This counts messages from the other user where read_at IS NULL
  Future<void> recomputeChatUnreadCountFromMessages(String userId, String matchId) async {
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
        if (senderId != null && senderId != userId && (readAt == null || readAt.isEmpty)) {
          unreadCount++;
        }
      }

      // Update the chat entry with the recalculated unread count
      final box = await _getChatsBox();
      final key = 'recent_chats_$userId';
      final current = box.get(key);
      if (current == null) return;

      try {
        final List<Map<String, dynamic>> chats = (jsonDecode(current) as List).cast<Map<String, dynamic>>();
        bool updated = false;

        for (int i = 0; i < chats.length; i++) {
          if ((chats[i]['match_id']?.toString() ?? '') == matchId) {
            final oldUnreadCount = chats[i]['unread_count'] ?? 0;
            chats[i]['unread_count'] = unreadCount;
            debugPrint('🔄 Recomputed unread_count for $matchId: $oldUnreadCount → $unreadCount');
            updated = true;
            break;
          }
        }

        if (updated) {
          await box.put(key, jsonEncode(chats));
        }
      } catch (e) {
        debugPrint('❌ Error recomputing unread count: $e');
      }
    } catch (e) {
      debugPrint('❌ recomputeChatUnreadCountFromMessages failed: $e');
    }
  }


  /// Get other user profile with cache metadata (includes cached_at timestamp)
  Future<Map<String, dynamic>?> getOtherUserProfileWithCacheMeta(String userId) async {
    try {
      final box = await _getProfileBox();
      final key = 'other_user_$userId';
      final data = box.get(key);
      if (data == null) return null;
      return Map<String, dynamic>.from(data);
    } catch (e) {
      debugPrint('LocalDb.getOtherUserProfileWithCacheMeta failed: $e');
      return null;
    }
  }

  /// Save profile wizard draft data
  Future<void> saveProfileWizardDraft(String userId, Map<String, dynamic> draftData) async {
    try {
      final box = await _getSettingsBox();
      final key = 'profile_wizard_draft_$userId';
      await box.put(key, jsonEncode(draftData));
    } catch (e) {
      debugPrint('LocalDb.saveProfileWizardDraft failed: $e');
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
      debugPrint('LocalDb.loadProfileWizardDraft failed: $e');
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
      debugPrint('LocalDb.clearProfileWizardDraft failed: $e');
    }
  }

  /// Save pending referral code from deep link
  Future<void> savePendingReferralCode(String code) async {
    try {
      final box = await _getSettingsBox();
      await box.put('pending_referral_code', code);
    } catch (e) {
      debugPrint('LocalDb.savePendingReferralCode failed: $e');
    }
  }

  /// Get pending referral code
  Future<String?> getPendingReferralCode() async {
    try {
      final box = await _getSettingsBox();
      final code = box.get('pending_referral_code');
      return code is String ? code : null;
    } catch (e) {
      debugPrint('LocalDb.getPendingReferralCode failed: $e');
      return null;
    }
  }

  /// Clear pending referral code after processing
  Future<void> clearPendingReferralCode() async {
    try {
      final box = await _getSettingsBox();
      await box.delete('pending_referral_code');
    } catch (e) {
      debugPrint('LocalDb.clearPendingReferralCode failed: $e');
    }
  }
}

// Global provider
final localDbProvider = Provider<LocalDbService>((ref) {
  return LocalDbService();
});
