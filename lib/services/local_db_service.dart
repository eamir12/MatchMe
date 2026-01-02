// lib/services/local_db_service.dart
// Local DB service (Hive) with added option-hierarchy cache helpers.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert'; // For jsonEncode/Decode
import 'package:matchme/utils/resume_diagnostics.dart';

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
    final duration = DateTime.now().difference(start).inMilliseconds;
    ResumeDiagnostics.log('LocalDb.init completed in ${duration}ms');
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
        chats[i]['last_message_translated'] = translatedText;
        await box.put(key, jsonEncode(chats));
        break;
      }
    }
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
            // If the server-provided chat has no translation but we have one cached
            // for the same last_message_id, preserve it to avoid flicker.
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

    await box.put(key, jsonEncode(chats));
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
      // Ignore errors to avoid disrupting UX
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

  Stream<List<Map<String, dynamic>>> watchChats(String userId) async* {
    final box = await _getChatsBox();
    final key = 'recent_chats_$userId';
    final currentChats = box.get(key);
    if (currentChats != null) {
      yield (jsonDecode(currentChats) as List).cast<Map<String, dynamic>>();
    } else {
      yield [];
    }
    yield* box.watch(key: key).map((event) {
      if (event.value != null && !event.deleted) {
        return (jsonDecode(event.value) as List).cast<Map<String, dynamic>>();
      }
      return [];
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

  Future<void> addMessages(String matchId, List<Map<String, dynamic>> newMessages) async {
    if (newMessages.isEmpty) {
      return;
    }
    final box = await _getMessagesBox();
    final oldMessages = await getMessages(matchId);
    final existingIds = oldMessages.map((m) => m['id']).toSet();
    final uniqueNewMessages = newMessages.where((m) => !existingIds.contains(m['id'])).toList();

    if (uniqueNewMessages.isEmpty) {
      return;
    }

    final combinedMessages = [...oldMessages, ...uniqueNewMessages];
    await box.put(matchId, jsonEncode(combinedMessages));
  }

  Future<void> replaceMessage(String matchId, String tempId, Map<String, dynamic> realMessage) async {
    final box = await _getMessagesBox();
    final messages = await getMessages(matchId);

    final index = messages.indexWhere((m) => m['id'] == tempId);

    if (index != -1) {
      messages[index] = realMessage;
      await box.put(matchId, jsonEncode(messages));
    } else {
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

      messageMap[incomingMsg['id'].toString()] = {
        ...incomingMsg,
        'translated_text': oldTranslation,
        'translated_lang': oldTranslationLang,
        'reaction_summary': oldReactionSummary ?? incomingMsg['reaction_summary'],
        'my_reaction': oldMyReaction ?? incomingMsg['my_reaction'],
      };
    }

    final combinedList = messageMap.values.toList();

    combinedList.sort((a, b) {
      final aDate = DateTime.tryParse(a['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = DateTime.tryParse(b['created_at'] ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
      return aDate.compareTo(bDate);
    });

    await box.put(matchId, jsonEncode(combinedList));
  }

  Future<void> saveMessages(String matchId, List<Map<String, dynamic>> messages) async {
    final box = await _getMessagesBox();
    
    // Get existing messages to preserve local translations
    final existingMessages = await getMessages(matchId);
    final existingTranslations = <String, Map<String, dynamic>>{};
    
    // Build a map of existing translations by message ID
    for (final existingMsg in existingMessages) {
      final msgId = existingMsg['id']?.toString();
      final translatedText = existingMsg['translated_text'];
      if (msgId != null && translatedText != null) {
        existingTranslations[msgId] = {
          'translated_text': translatedText,
          'translated_lang': existingMsg['translated_lang'],
        };
      }
    }
    
    // Merge translations and reactions into the new messages from Supabase
    for (final message in messages) {
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
    }
    
    await box.put(matchId, jsonEncode(messages));
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
    final box = await _getMessagesBox();
    final initialMessages = await getMessages(matchId);
    yield initialMessages;
    yield* box.watch(key: matchId).asyncMap((event) async {
      if (event.value != null && !event.deleted) {
        final messages = (jsonDecode(event.value) as List).cast<Map<String, dynamic>>();
        return messages;
      }
      return [];
    });
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
}

// Global provider
final localDbProvider = Provider<LocalDbService>((ref) {
  return LocalDbService();
});
