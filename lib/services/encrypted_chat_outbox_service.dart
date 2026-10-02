import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:matchme/config/security_constants.dart';
import 'package:matchme/services/crypto_service.dart';
import 'package:matchme/services/encrypted_cache_service.dart';
import 'package:matchme/services/hive_encryption_service.dart';
import 'package:uuid/uuid.dart';

class EncryptedChatOutboxService {
  EncryptedChatOutboxService._();
  static final EncryptedChatOutboxService instance =
      EncryptedChatOutboxService._();

  static const _outboxBoxName = 'chatOutboxBox';
  final CryptoService _crypto = CryptoService.instance;
  final EncryptedCacheService _cacheService = EncryptedCacheService.instance;
  final Uuid _uuid = Uuid();

  Box<String>? _outboxBox;
  Timer? _retryTimer;
  int _attemptCount = 0;
  bool _processing = false;
  String? _currentUserId;

  Future<Box<String>> _getBox() async {
    _outboxBox ??= await HiveEncryptionService.instance
        .openEncryptedBox<String>(_outboxBoxName);
    return _outboxBox!;
  }

  Future<String> _draftKey(String userId, String draftId) async {
    return 'chat_outbox:$userId:$draftId';
  }

  Future<void> saveDraft({
    required String userId,
    required String messageId,
    required String matchId,
    required String senderId,
    required String recipientId,
    required String plaintext,
    required bool translationEnabled,
    String? originalRecipientKeyId,
  }) async {
    final box = await _getBox();
    final draftId = _uuid.v4();
    final nonce = _crypto.generateNonce();
    final aad = Uint8List.fromList(utf8.encode('matchme-chat-outbox-v1'));
    final dck = _cacheService.currentDck;
    if (dck == null) return;

    final encryptedPlaintext = await _crypto.aesGcmEncrypt(
      plaintext: Uint8List.fromList(utf8.encode(plaintext)),
      key: dck,
      nonce: nonce,
      aad: aad,
    );

    final draft = {
      'draft_id': draftId,
      'message_id': messageId,
      'match_id': matchId,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'plaintext_encrypted': base64Encode(encryptedPlaintext),
      'plaintext_nonce': base64Encode(nonce),
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'attempt_count': 0,
      'last_error_code': null,
      'last_error_at': null,
      'intended_translation_enabled': translationEnabled,
      'original_recipient_key_id': originalRecipientKeyId,
      'original_recipient_key_checked_at': null,
    };

    final key = await _draftKey(userId, draftId);
    await box.put(key, jsonEncode(draft));
  }

  Future<List<Map<String, dynamic>>> getPendingDrafts(String userId) async {
    final box = await _getBox();
    final prefix = 'chat_outbox:$userId:';
    final drafts = <Map<String, dynamic>>[];

    for (final key in box.keys) {
      if (key.toString().startsWith(prefix)) {
        final value = box.get(key);
        if (value != null) {
          final draft = jsonDecode(value) as Map<String, dynamic>;
          drafts.add(draft);
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

  Future<void> updateDraft(
    String userId,
    String draftId,
    Map<String, dynamic> updates,
  ) async {
    final box = await _getBox();
    final key = await _draftKey(userId, draftId);
    final existing = box.get(key);
    if (existing == null) return;

    final draft = jsonDecode(existing) as Map<String, dynamic>;
    draft.addAll(updates);
    draft['updated_at'] = DateTime.now().toIso8601String();
    await box.put(key, jsonEncode(draft));
  }

  Future<void> removeDraft(String userId, String draftId) async {
    final box = await _getBox();
    final key = await _draftKey(userId, draftId);
    await box.delete(key);
  }

  Future<int> clearAllDrafts(String userId) async {
    final box = await _getBox();
    final prefix = 'chat_outbox:$userId:';
    int count = 0;
    for (final key in box.keys) {
      if (key.toString().startsWith(prefix)) {
        await box.delete(key);
        count++;
      }
    }
    return count;
  }

  Future<void> startProcessing(String userId) async {
    _currentUserId = userId;
    _processing = true;
    _attemptCount = 0;
    _processNext();
  }

  void stopProcessing() {
    _processing = false;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _processNext() async {
    if (!_processing || _currentUserId == null) return;

    final userId = _currentUserId!;
    final drafts = await getPendingDrafts(userId);

    if (drafts.isEmpty) {
      _processing = false;
      return;
    }

    for (final draft in drafts) {
      if (!_processing) break;
      _attemptCount = (draft['attempt_count'] as int?) ?? 0;
      try {
        await _processDraft(userId, draft);
      } catch (_) {
        if (!_processing) break;
        _scheduleRetry(userId);
        return;
      }
    }

    _processing = false;
  }

  Future<void> _processDraft(String userId, Map<String, dynamic> draft) async {
    final draftId = draft['draft_id'] as String;
    final attemptCount = (draft['attempt_count'] as int?) ?? 0;

    if (attemptCount >= SecurityConstants.outboxRetryDelays.length + 1) {
      await updateDraft(userId, draftId, {
        'last_error_code': 'max_retries_exceeded',
        'last_error_at': DateTime.now().toIso8601String(),
      });
      return;
    }

    await updateDraft(userId, draftId, {
      'attempt_count': attemptCount + 1,
      'last_error_code': null,
      'last_error_at': DateTime.now().toIso8601String(),
    });

    await removeDraft(userId, draftId);

    if (_processing) {
      _scheduleRetry(userId);
    }
  }

  void _scheduleRetry(String userId) {
    _retryTimer?.cancel();
    if (_attemptCount >= SecurityConstants.outboxRetryDelays.length) {
      _processing = false;
      return;
    }
    final delay = SecurityConstants.outboxRetryDelays[_attemptCount];
    _retryTimer = Timer(delay, () => _processNext());
  }
}
