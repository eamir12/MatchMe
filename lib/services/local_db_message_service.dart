// lib/services/local_db_message_service.dart
// Message-specific local database operations

import 'package:hive_flutter/hive_flutter.dart';
import 'dart:convert';

class LocalDbMessageService {
  static const String _kChatMessagesBox = 'chatMessagesBox';
  static const String _kOutboxBox = 'outboxBox';

  Box<String>? _messagesBox;
  Box<String>? _outboxBox;
  bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    _messagesBox ??= await Hive.openBox<String>(_kChatMessagesBox);
    _outboxBox ??= await Hive.openBox<String>(_kOutboxBox);
    _initialized = true;
  }

  Future<Box<String>> _getMessagesBox() async {
    await _init();
    return _messagesBox!;
  }

  Future<Box<String>> _getOutboxBox() async {
    await _init();
    return _outboxBox!;
  }

  // --- Chat Message Methods ---
  Future<List<Map<String, dynamic>>> getMessages(String matchId) async {
    final box = await _getMessagesBox();
    final currentMessages = box.get(matchId);
    if (currentMessages != null) {
      try {
        final decoded = jsonDecode(currentMessages);
        if (decoded is List) {
          return decoded.cast<Map<String, dynamic>>();
        }
        return [];
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

      messageMap[incomingMsg['id'].toString()] = {
        ...incomingMsg,
        'translated_text': oldTranslation,
        'translated_lang': oldTranslationLang,
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

  Future<void> deleteMessages(String matchId) async {
    final box = await _getMessagesBox();
    await box.delete(matchId);
  }

  Stream<List<Map<String, dynamic>>> watchMessages(String matchId) async* {
    final box = await _getMessagesBox();
    yield await getMessages(matchId);
    yield* box.watch(key: matchId).asyncMap((event) async {
      if (event.value != null && !event.deleted) {
        try {
          final decoded = jsonDecode(event.value!);
          if (decoded is List) {
            return decoded.cast<Map<String, dynamic>>();
          }
        } catch (_) {
          // Ignore parsing errors
        }
        return [];
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
}