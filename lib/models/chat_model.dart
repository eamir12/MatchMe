// lib/models/chat_model.dart

class ChatModel {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final String lastMessage;
  final String lastMessageId; // <-- [FIX 2] ADD THIS
  final DateTime lastMessageAt;
  final int unreadCount;
  final String? eventId;
  final String? eventName;
  final String? eventLink;
  final bool translationEnabled;
  final String? translationLanguage;

  ChatModel({
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    required this.lastMessage,
    required this.lastMessageId, // <-- [FIX 2] ADD THIS
    required this.lastMessageAt,
    required this.unreadCount,
    this.eventId,
    this.eventName,
    this.eventLink,
    this.translationEnabled = false,
    this.translationLanguage,
  });

  factory ChatModel.fromJsonRpc(Map<String, dynamic> json) {
    DateTime? messageTime;

    if (json['last_message_at'] != null) {
      try {
        messageTime = DateTime.parse(json['last_message_at']);
      } catch (_) {
        // Parse error
      }
    }
    messageTime ??=
        (json['match_created_at'] != null
            ? DateTime.parse(json['match_created_at'])
            : DateTime.now());

    String maskNameLocal(dynamic raw) {
      final s = raw?.toString() ?? '';
      if (s.trim().isEmpty) return 'Unknown User';
      final parts = s.trim().split(RegExp(r'\s+'));
      if (parts.length > 1 && parts.last != parts.first) {
        return '${parts.first} ${parts.last.substring(0,1).toUpperCase()}.';
      }
      return parts.first;
    }

    return ChatModel(
      matchId: json['match_id'] ?? '',
      otherUserId: json['other_user_id'] ?? '',
      // Accept either server-side name column (`other_name`) or the legacy `other_user_name`
      otherUserName: maskNameLocal(json['other_user_name'] ?? json['other_name'] ?? 'Unknown User'),
      // Accept preview/preview field from new RPC or legacy `last_message_content`
      lastMessage: json['last_message_content'] ?? json['last_message_preview'] ?? '',
      lastMessageId: json['last_message_id'] ?? '', // <-- [FIX 2] ADD THIS
      lastMessageAt: messageTime,
      unreadCount: json['unread_count'] ?? 0,
      eventId: json['event_id'],
      eventName: json['event_name'],
      eventLink: json['event_link'],
      translationEnabled: json['translation_enabled'] ?? false,
      translationLanguage: json['translation_language'] as String?,
    );
  }

  // --- NEW: Helper to format name as "First L." ---
  String getFormattedName() {
    if (otherUserName.isEmpty || otherUserName == 'Unknown User') {
      return 'User...';
    }

    final parts = otherUserName.trim().split(' ');
    if (parts.length > 1 && parts[1].isNotEmpty) {
      return '\u200E${parts[0]} ${parts[1][0].toUpperCase()}.\u200E';
    }
    return '\u200E${parts[0]}\u200E';
  }
  // --- END NEW ---

  // --- NEW: copyWith to allow swapping lastMessage (e.g., with a cached translation)
  ChatModel copyWith({
    String? matchId,
    String? otherUserId,
    String? otherUserName,
    String? lastMessage,
    String? lastMessageId,
    DateTime? lastMessageAt,
    int? unreadCount,
    String? eventId,
    String? eventName,
    String? eventLink,
    bool? translationEnabled,
    String? translationLanguage,
  }) {
    return ChatModel(
      matchId: matchId ?? this.matchId,
      otherUserId: otherUserId ?? this.otherUserId,
      otherUserName: otherUserName ?? this.otherUserName,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageId: lastMessageId ?? this.lastMessageId,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      eventId: eventId ?? this.eventId,
      eventName: eventName ?? this.eventName,
      eventLink: eventLink ?? this.eventLink,
      translationEnabled: translationEnabled ?? this.translationEnabled,
      translationLanguage: translationLanguage ?? this.translationLanguage,
    );
  }

  // --- END copyWith ---
}
