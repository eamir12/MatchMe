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
  final DateTime? readAt;
  final bool isPending; // <-- NEW: For optimistic UI

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
    this.readAt,
    this.isPending = false, // <-- NEW
  });

  factory ChatMessageModel.fromJson(Map<String, dynamic> json) {
    return ChatMessageModel(
      id: json['id'],
      matchId: json['match_id'],
      senderId: json['sender_id'],
      contentOriginal: json['content_original'],
      contentTranslated: json['content_translated'],
      translatedText: json['translated_text'],
      translatedLang: json['translated_lang'],
      reactionSummary: json['reaction_summary'] != null ? Map<String, int>.from((json['reaction_summary'] as Map).map((k, v) => MapEntry(k.toString(), (v as num).toInt()))) : null,
      myReaction: json['my_reaction'] as String?,
      createdAt: DateTime.parse(json['created_at']),
      readAt: json['read_at'] != null ? DateTime.parse(json['read_at']) : null,
      isPending: json['isPending'] ?? false, // <-- NEW
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
      'translated_text': translatedText,
      'translated_lang': translatedLang,
      'reaction_summary': reactionSummary,
      'my_reaction': myReaction,
      'created_at': createdAt.toIso8601String(),
      'read_at': readAt?.toIso8601String(),
      'isPending': isPending,
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
    DateTime? readAt,
    bool? isPending, // <-- NEW
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
      readAt: readAt ?? this.readAt,
      isPending: isPending ?? this.isPending, // <-- NEW
    );
  }
}
