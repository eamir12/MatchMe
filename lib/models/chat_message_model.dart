// lib/models/chat_message_model.dart
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
  final String? replyToMessageId; // ID of the message this message replies to (nullable)
  final String? replyToSenderId; // Sender id of the replied-to message (if provided via nested select)
  final String? replyToContent; // Original content of the replied-to message (for preview)

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
    this.isPending = false, // <-- NEW
    this.replyToMessageId,
    this.replyToSenderId,
    this.replyToContent,
  });

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
          return Map<String, int>.from((v).map((k, val) => MapEntry(k.toString(), (val is num ? val.toInt() : int.parse(val.toString())))));
        } catch (_) {
          return null;
        }
      }
      return null;
    }

    return ChatMessageModel(
      id: parseString(json['id']),
      matchId: parseString(json['match_id']),
      senderId: parseString(json['sender_id']),
      contentOriginal: parseString(json['content_original']),
      contentTranslated: json['content_translated'] != null ? parseString(json['content_translated']) : null,
      // Use content_translated for translatedText since that's what the server provides
      // The translated_text field is for client-side cached translations
      translatedText: json['content_translated'] != null ? parseString(json['content_translated']) : null,
      // Use translated_target_language for translatedLang
      translatedLang: json['translated_target_language'] != null ? parseString(json['translated_target_language']) : null,
      reactionSummary: parseReactionSummary(json['reaction_summary']),
      myReaction: json['my_reaction'] != null ? parseString(json['my_reaction']) : null,
      createdAt: parseDateTime(json['created_at']),
      deliveredAt: json['delivered_at'] != null ? parseDateTime(json['delivered_at']) : null,
      readAt: json['read_at'] != null ? parseDateTime(json['read_at']) : null,
      editedAt: json['edited_at'] != null ? parseDateTime(json['edited_at']) : null,
      isPending: json['isPending'] ?? false,
      replyToMessageId: json['reply_to_message_id'] != null ? parseString(json['reply_to_message_id']) : null,
      replyToSenderId: null,
      replyToContent: null,
    );
  }
  
  // --- NEW: Convert to JSON for saving to local cache ---
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'match_id': matchId,
      'sender_id': senderId,
      'content_original': contentOriginal,
      'content_translated': contentTranslated,
      // Also save to translated_text/translated_lang for UI consistency
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
    bool? isPending, // <-- NEW
    String? replyToMessageId,
    String? replyToSenderId,
    String? replyToContent,
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
      isPending: isPending ?? this.isPending, // <-- NEW
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      replyToSenderId: replyToSenderId ?? this.replyToSenderId,
      replyToContent: replyToContent ?? this.replyToContent,
    );
  }
}
