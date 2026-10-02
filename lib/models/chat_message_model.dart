// lib/models/chat_message_model.dart
import 'dart:convert';

/// Sentinel distinguishing "copyWith param omitted" from "explicitly null".
const Object _copyWithSentinel = Object();

class ChatMessageModel {
  final String id;
  final String matchId;
  final String senderId;
  final String contentOriginal;
  final String? contentTranslated;
  final String? translatedText; // Local DB cache translation
  final String? translatedLang; // Local DB cache translation language
  final Map<String, int>? reactionSummary; // e.g., {"👍": 3, "❤": 2}
  final String? myReaction; // current user's reaction, if any
  final DateTime createdAt;
  final DateTime? deliveredAt; // When message reached recipient's device
  final DateTime? readAt;
  final DateTime? editedAt; // When a message was edited
  final bool isPending; // <-- NEW: For optimistic UI
  final String?
  replyToMessageId; // ID of the message this message replies to (nullable)
  final String?
  replyToSenderId; // Sender id of the replied-to message (if provided via nested select)
  final String?
  replyToContent; // Original content of the replied-to message (for preview)
  final String?
  replyToContentTranslated; // Translated preview of the replied-to message (when available)

  // Encrypted message fields
  final String encryptionScheme;
  final String? senderKeyId;
  final String? recipientKeyId;
  final String? recipientId;
  final String? contentOriginalEncrypted;
  final String? contentOriginalNonce;
  final String? contentTranslatedEncrypted;
  final String? contentTranslatedNonce;
  final Map<String, dynamic>? wrappedKeys;
  final bool translationCapable;
  final String? detectedSourceLanguage;
  final String? translatedTargetLanguage;

  ChatMessageModel({
    required this.id,
    required this.matchId,
    required this.senderId,
    required this.contentOriginal,
    this.contentTranslated,
    this.translatedText,
    this.translatedLang,
    this.reactionSummary,
    this.myReaction,
    required this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.editedAt,
    this.isPending = false,
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyToContent,
    this.replyToContentTranslated,
    this.encryptionScheme = 'v1',
    this.senderKeyId,
    this.recipientKeyId,
    this.recipientId,
    this.contentOriginalEncrypted,
    this.contentOriginalNonce,
    this.contentTranslatedEncrypted,
    this.contentTranslatedNonce,
    this.wrappedKeys,
    this.translationCapable = false,
    this.detectedSourceLanguage,
    this.translatedTargetLanguage,
  });

  bool get isEncrypted => encryptionScheme == 'v1';

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) {
    // Defensive parsing: backend and local DB may store different types (int, String, Map, List)
    String parseString(dynamic v) {
      if (v == null) return '';
      return v is String ? v : v.toString();
    }

    DateTime parseDateTime(dynamic v) {
      if (v == null) return DateTime.fromMillisecondsSinceEpoch(0);
      if (v is DateTime) return v;
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        // Fallback: try parsing as int epoch millis
        try {
          final ms = int.parse(v.toString());
          return DateTime.fromMillisecondsSinceEpoch(ms);
        } catch (_) {
          return DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
    }

    Map<String, int>? parseReactionSummary(dynamic v) {
      if (v == null) return null;
      if (v is Map) {
        try {
          return Map<String, int>.from(
            (v).map(
              (k, val) => MapEntry(
                k.toString(),
                (val is num ? val.toInt() : int.parse(val.toString())),
              ),
            ),
          );
        } catch (_) {
          return null;
        }
      }
      return null;
    }

    Map<String, dynamic>? parseWrappedKeys(dynamic v) {
      if (v == null) return null;
      if (v is Map) return Map<String, dynamic>.from(v);
      try {
        return Map<String, dynamic>.from(jsonDecode(v.toString()));
      } catch (_) {
        return null;
      }
    }

    final rawEncryptionScheme = parseString(json['encryption_scheme']);
    final encryptionScheme = rawEncryptionScheme.isEmpty
        ? 'v1'
        : rawEncryptionScheme;
    final contentOriginal = (() {
      final legacy = json['content_original'];
      if (legacy != null) return parseString(legacy);
      return '';
    })();

    return ChatMessageModel(
      id: parseString(json['id']),
      matchId: parseString(json['match_id']),
      senderId: parseString(json['sender_id']),
      contentOriginal: contentOriginal,
      contentTranslated: (() {
        final legacy = json['content_translated'] ?? json['translated_text'];
        if (legacy != null) return parseString(legacy);
        return null;
      })(),
      translatedText: (() {
        final legacy = json['content_translated'] ?? json['translated_text'];
        if (legacy != null) return parseString(legacy);
        return null;
      })(),
      translatedLang: json['translated_target_language'] != null
          ? parseString(json['translated_target_language'])
          : (json['translated_lang'] != null
                ? parseString(json['translated_lang'])
                : null),
      reactionSummary: parseReactionSummary(json['reaction_summary']),
      myReaction: json['my_reaction'] != null
          ? parseString(json['my_reaction'])
          : null,
      createdAt: parseDateTime(json['created_at']),
      deliveredAt: json['delivered_at'] != null
          ? parseDateTime(json['delivered_at'])
          : null,
      readAt: json['read_at'] != null ? parseDateTime(json['read_at']) : null,
      editedAt: json['edited_at'] != null
          ? parseDateTime(json['edited_at'])
          : null,
      isPending: json['isPending'] ?? false,
      replyToMessageId: json['reply_to_message_id'] != null
          ? parseString(json['reply_to_message_id'])
          : null,
      replyToSenderId: json['reply_to_sender_id'] != null
          ? parseString(json['reply_to_sender_id'])
          : null,
      replyToContent: json['reply_to_content'] != null
          ? parseString(json['reply_to_content'])
          : null,
      replyToContentTranslated: json['reply_to_content_translated'] != null
          ? parseString(json['reply_to_content_translated'])
          : null,
      encryptionScheme: encryptionScheme,
      senderKeyId: json['sender_key_id'] != null
          ? parseString(json['sender_key_id'])
          : null,
      recipientKeyId: json['recipient_key_id'] != null
          ? parseString(json['recipient_key_id'])
          : null,
      recipientId: json['recipient_id'] != null
          ? parseString(json['recipient_id'])
          : null,
      contentOriginalEncrypted: json['content_original_encrypted'] != null
          ? parseString(json['content_original_encrypted'])
          : null,
      contentOriginalNonce: json['content_original_nonce'] != null
          ? parseString(json['content_original_nonce'])
          : null,
      contentTranslatedEncrypted: json['content_translated_encrypted'] != null
          ? parseString(json['content_translated_encrypted'])
          : null,
      contentTranslatedNonce: json['content_translated_nonce'] != null
          ? parseString(json['content_translated_nonce'])
          : null,
      wrappedKeys: parseWrappedKeys(json['wrapped_keys']),
      translationCapable: json['translation_capable'] == true,
      detectedSourceLanguage: json['detected_source_language'] != null
          ? parseString(json['detected_source_language'])
          : null,
      translatedTargetLanguage: json['translated_target_language'] != null
          ? parseString(json['translated_target_language'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'match_id': matchId,
      'sender_id': senderId,
      'content_original': contentOriginal,
      'content_translated': contentTranslated,
      'translated_text': contentTranslated,
      'translated_lang': translatedLang,
      'reaction_summary': reactionSummary,
      'my_reaction': myReaction,
      'created_at': createdAt.toIso8601String(),
      'delivered_at': deliveredAt?.toIso8601String(),
      'read_at': readAt?.toIso8601String(),
      'edited_at': editedAt?.toIso8601String(),
      'isPending': isPending,
      'reply_to_message_id': replyToMessageId,
      'reply_to_sender_id': replyToSenderId,
      'reply_to_content': replyToContent,
      'reply_to_content_translated': replyToContentTranslated,
      'encryption_scheme': encryptionScheme,
      'sender_key_id': senderKeyId,
      'recipient_key_id': recipientKeyId,
      'recipient_id': recipientId,
      'content_original_encrypted': contentOriginalEncrypted,
      'content_original_nonce': contentOriginalNonce,
      'content_translated_encrypted': contentTranslatedEncrypted,
      'content_translated_nonce': contentTranslatedNonce,
      'wrapped_keys': wrappedKeys,
      'translation_capable': translationCapable,
      'detected_source_language': detectedSourceLanguage,
      'translated_target_language': translatedTargetLanguage,
    };
  }

  ChatMessageModel copyWith({
    String? id,
    String? matchId,
    String? senderId,
    String? contentOriginal,
    String? contentTranslated,
    String? translatedText,
    String? translatedLang,
    Map<String, int>? reactionSummary,
    String? myReaction,
    DateTime? createdAt,
    DateTime? deliveredAt,
    DateTime? readAt,
    DateTime? editedAt,
    bool? isPending,
    String? replyToMessageId,
    String? replyToSenderId,
    // Sentinel defaults so callers can explicitly clear a stale quoted
    // preview (e.g. translation no longer matches the current UI language)
    // by passing null. Omitting the param keeps the current value.
    Object? replyToContent = _copyWithSentinel,
    Object? replyToContentTranslated = _copyWithSentinel,
    String? encryptionScheme,
    String? senderKeyId,
    String? recipientKeyId,
    String? recipientId,
    String? contentOriginalEncrypted,
    String? contentOriginalNonce,
    String? contentTranslatedEncrypted,
    String? contentTranslatedNonce,
    Map<String, dynamic>? wrappedKeys,
    bool? translationCapable,
    String? detectedSourceLanguage,
    String? translatedTargetLanguage,
  }) {
    return ChatMessageModel(
      id: id ?? this.id,
      matchId: matchId ?? this.matchId,
      senderId: senderId ?? this.senderId,
      contentOriginal: contentOriginal ?? this.contentOriginal,
      contentTranslated: contentTranslated ?? this.contentTranslated,
      translatedText: translatedText ?? this.translatedText,
      translatedLang: translatedLang ?? this.translatedLang,
      reactionSummary: reactionSummary ?? this.reactionSummary,
      myReaction: myReaction ?? this.myReaction,
      createdAt: createdAt ?? this.createdAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      readAt: readAt ?? this.readAt,
      editedAt: editedAt ?? this.editedAt,
      isPending: isPending ?? this.isPending,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderId: replyToSenderId ?? this.replyToSenderId,
      replyToContent: identical(replyToContent, _copyWithSentinel)
          ? this.replyToContent
          : replyToContent as String?,
      replyToContentTranslated:
          identical(replyToContentTranslated, _copyWithSentinel)
          ? this.replyToContentTranslated
          : replyToContentTranslated as String?,
      encryptionScheme: encryptionScheme ?? this.encryptionScheme,
      senderKeyId: senderKeyId ?? this.senderKeyId,
      recipientKeyId: recipientKeyId ?? this.recipientKeyId,
      recipientId: recipientId ?? this.recipientId,
      contentOriginalEncrypted:
          contentOriginalEncrypted ?? this.contentOriginalEncrypted,
      contentOriginalNonce: contentOriginalNonce ?? this.contentOriginalNonce,
      contentTranslatedEncrypted:
          contentTranslatedEncrypted ?? this.contentTranslatedEncrypted,
      contentTranslatedNonce:
          contentTranslatedNonce ?? this.contentTranslatedNonce,
      wrappedKeys: wrappedKeys ?? this.wrappedKeys,
      translationCapable: translationCapable ?? this.translationCapable,
      detectedSourceLanguage:
          detectedSourceLanguage ?? this.detectedSourceLanguage,
      translatedTargetLanguage:
          translatedTargetLanguage ?? this.translatedTargetLanguage,
    );
  }
}
