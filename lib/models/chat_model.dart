// lib/models/chat_model.dart

import 'package:flutter/foundation.dart' show listEquals;
import 'package:matchme/utils/encrypted_text_guard.dart';
import 'package:matchme/utils/string_extensions.dart';

class ChatModel {
  final String matchId;
  final String otherUserId;
  final String otherUserName;
  final List<String> otherUserPhotos;
  final String lastMessage;
  final String? lastMessageTranslated; // Translated version of last message
  final String? lastMessageTranslatedTargetLanguage;
  final String lastMessageId; // <-- [FIX 2] ADD THIS
  final String? lastMessageSenderId; // ID of user who sent the last message
  final DateTime lastMessageAt;
  final int unreadCount;
  final String? eventId;
  final String? eventName;
  final String? eventLink;
  final bool translationEnabled;
  final String? translationLanguage;
  final String?
  lastMessageSourceLanguage; // Source language of the last message (for translation decisions)
  final String? matchedIntent; // Intent that created the underlying match

  /// The underlying match's type, as reported by `get_user_recent_chats`.
  ///
  /// Used to filter the chat list by match basis (proximity / event). Defaults
  /// to empty when the server predates the column, which makes the match-type
  /// filter degrade to "no match type information" rather than misclassify.
  final String matchType;

  /// `edited_at` of the message behind the preview, as reported by
  /// `get_user_recent_chats` / the local message cache.
  final String? lastMessageEditedAt;

  /// The `edited_at` the cached [lastMessageTranslated] was produced for.
  ///
  /// These two together are what makes a preview translation safe to reuse
  /// across an edit: they only still describe the same content while they
  /// match. See `previewTranslationIsCurrent` in the local DB service.
  final String? lastMessageTranslatedEditedAt;

  /// ISO timestamp of when this user archived the chat, as reported by
  /// `get_user_recent_chats` / the local message cache. Null means the chat
  /// is active. Archiving is per-user and display-only: the chat still
  /// receives notifications and its row keeps updating.
  final String? archivedAt;

  bool get isArchived => archivedAt != null;

  ChatModel({
    required this.matchId,
    required this.otherUserId,
    required this.otherUserName,
    this.otherUserPhotos = const [],
    required this.lastMessage,
    this.lastMessageTranslated,
    this.lastMessageTranslatedTargetLanguage,
    required this.lastMessageId, // <-- [FIX 2] ADD THIS
    this.lastMessageSenderId,
    required this.lastMessageAt,
    required this.unreadCount,
    this.eventId,
    this.eventName,
    this.eventLink,
    this.translationEnabled = false,
    this.translationLanguage,
    this.lastMessageSourceLanguage,
    this.matchedIntent,
    this.lastMessageEditedAt,
    this.lastMessageTranslatedEditedAt,
    this.matchType = '',
    this.archivedAt,
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
    messageTime ??= (json['match_created_at'] != null
        ? DateTime.parse(json['match_created_at'])
        : DateTime.now());

    String capWord(String word) {
      if (word.isEmpty) return word;
      final hyphenParts = word.split('-');
      return hyphenParts
          .map((h) {
            if (h.isEmpty) return h;
            return h
                .split("'")
                .map((s) {
                  if (s.isEmpty) return s;
                  final lower = s.toLowerCase();
                  return '${lower[0].toUpperCase()}${lower.substring(1)}';
                })
                .join("'");
          })
          .join('-');
    }

    String maskNameLocal(dynamic raw) {
      final s = (raw?.toString() ?? '').replaceAll(bidiControls, '');
      if (s.trim().isEmpty) return 'Unknown User';
      final parts = s
          .trim()
          .split(RegExp(r'\s+'))
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length > 1 &&
          parts.last.toLowerCase() != parts.first.toLowerCase()) {
        return '${capWord(parts.first)} ${parts.last.substring(0, 1).toUpperCase()}.'
            .withDirectionalMarks();
      }
      return capWord(parts.first).withDirectionalMarks();
    }

    // Accept preview/preview field from new RPC, legacy `last_message_content`, or local DB `last_message`
    final rawLastMessage =
        json['last_message_content'] ?? json['last_message'] ?? '';
    final rawLastMessageTranslated = json['last_message_translated'] as String?;

    return ChatModel(
      matchId: json['match_id'] ?? '',
      otherUserId: json['other_user_id'] ?? '',
      // Accept either server-side name column (`other_name`) or the legacy `other_user_name`
      otherUserName: maskNameLocal(
        json['other_user_name'] ?? json['other_name'] ?? 'Unknown User',
      ),
      otherUserPhotos: json['other_user_photos'] is List
          ? (json['other_user_photos'] as List)
                .map((photo) => photo.toString().trim())
                .where((photo) => photo.isNotEmpty)
                .toList(growable: false)
          : const [],
      // These two fields mirror columns that, for v1 end-to-end encrypted
      // messages, hold `content_original_encrypted` / `content_translated_encrypted`
      // whenever decryption did not run. Never let a raw AES-GCM blob become
      // the model that ChatListItem paints — treat it as "not available yet"
      // so the caller shows its loading state instead.
      lastMessage: looksLikeEncryptedBlob(rawLastMessage) ? '' : rawLastMessage,
      lastMessageTranslated: looksLikeEncryptedBlob(rawLastMessageTranslated)
          ? null
          : rawLastMessageTranslated,
      lastMessageTranslatedTargetLanguage: json['last_message_target_language']
          ?.toString(),
      lastMessageId: json['last_message_id'] ?? '', // <-- [FIX 2] ADD THIS
      lastMessageSenderId: json['last_message_sender_id'] as String?,
      lastMessageAt: messageTime,
      unreadCount: json['unread_count'] ?? 0,
      eventId: json['event_id'],
      eventName: json['event_name'],
      eventLink: json['event_link'],
      translationEnabled: json['translation_enabled'] ?? false,
      translationLanguage: json['translation_language'] as String?,
      lastMessageSourceLanguage:
          json['last_message_source_language'] as String?,
      matchedIntent: json['matched_intent'] as String?,
      matchType: (json['match_type'] as String?) ?? '',
      lastMessageEditedAt: _normalizeMarker(json['last_message_edited_at']),
      lastMessageTranslatedEditedAt: _normalizeMarker(
        json['last_message_translated_edited_at'],
      ),
      archivedAt: _normalizeMarker(json['archived_at']),
    );
  }

  /// Timestamps reach the client as a Dart [DateTime] (PostgREST) or a raw ISO
  /// string (Hive round trip), and "absent" shows up as `null`, `''` or the
  /// literal string `'null'`. Collapse all of those to `null` so a marker
  /// comparison is a plain equality check.
  static String? _normalizeMarker(dynamic raw) {
    if (raw == null) return null;
    final text = raw is DateTime ? raw.toIso8601String() : raw.toString();
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    return trimmed;
  }

  // --- NEW: Helper to format name as "First L." ---
  String getFormattedName() {
    if (otherUserName.isEmpty || otherUserName == 'Unknown User') {
      return 'User...';
    }

    final cleaned = otherUserName.replaceAll(bidiControls, '').trim();
    final parts = cleaned
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'User...';
    String capWord(String word) {
      if (word.isEmpty) return word;
      final hyphenParts = word.split('-');
      return hyphenParts
          .map((h) {
            if (h.isEmpty) return h;
            return h
                .split("'")
                .map((s) {
                  if (s.isEmpty) return s;
                  final lower = s.toLowerCase();
                  return '${lower[0].toUpperCase()}${lower.substring(1)}';
                })
                .join("'");
          })
          .join('-');
    }

    if (parts.length > 1 && parts.last.isNotEmpty) {
      return '${capWord(parts.first)} ${parts.last[0].toUpperCase()}.'
          .withDirectionalMarks();
    }
    return capWord(parts[0]).withDirectionalMarks();
  }
  // --- END NEW ---

  /// Sentinel letting [copyWith] tell "argument omitted" apart from
  /// "explicitly set this field to null".
  ///
  /// This matters for the translation fields: `recentChatsProvider` builds a
  /// chat from the local cache and then calls
  /// `copyWith(lastMessageTranslated: translatedPreview)` on every code path.
  /// With a plain `??` fallback, passing an explicit `null` (meaning "no
  /// translation is available for the UI language — show the loading state")
  /// silently kept whatever the cache had, which for end-to-end encrypted
  /// chats is the raw `content_translated_encrypted` blob. The unreadable
  /// ciphertext was then rendered in the chat list.
  static const Object _unset = Object();

  // --- NEW: copyWith to allow swapping lastMessage (e.g., with a cached translation)
  ChatModel copyWith({
    String? matchId,
    String? otherUserId,
    String? otherUserName,
    List<String>? otherUserPhotos,
    String? lastMessage,
    Object? lastMessageTranslated = _unset,
    Object? lastMessageTranslatedTargetLanguage = _unset,
    String? lastMessageId,
    String? lastMessageSenderId,
    DateTime? lastMessageAt,
    int? unreadCount,
    String? eventId,
    String? eventName,
    String? eventLink,
    bool? translationEnabled,
    String? translationLanguage,
    Object? lastMessageSourceLanguage = _unset,
    String? matchedIntent,
    String? lastMessageEditedAt,
    Object? lastMessageTranslatedEditedAt = _unset,
    Object? archivedAt = _unset,
  }) {
    return ChatModel(
      matchId: matchId ?? this.matchId,
      otherUserId: otherUserId ?? this.otherUserId,
      otherUserName: otherUserName ?? this.otherUserName,
      otherUserPhotos: otherUserPhotos ?? this.otherUserPhotos,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTranslated: identical(lastMessageTranslated, _unset)
          ? this.lastMessageTranslated
          : lastMessageTranslated as String?,
      lastMessageTranslatedTargetLanguage:
          identical(lastMessageTranslatedTargetLanguage, _unset)
          ? this.lastMessageTranslatedTargetLanguage
          : lastMessageTranslatedTargetLanguage as String?,
      lastMessageId: lastMessageId ?? this.lastMessageId,
      lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      unreadCount: unreadCount ?? this.unreadCount,
      eventId: eventId ?? this.eventId,
      eventName: eventName ?? this.eventName,
      eventLink: eventLink ?? this.eventLink,
      translationEnabled: translationEnabled ?? this.translationEnabled,
      translationLanguage: translationLanguage ?? this.translationLanguage,
      lastMessageSourceLanguage: identical(lastMessageSourceLanguage, _unset)
          ? this.lastMessageSourceLanguage
          : lastMessageSourceLanguage as String?,
      matchedIntent: matchedIntent ?? this.matchedIntent,
      matchType: matchType.isEmpty ? matchType : matchType,
      lastMessageEditedAt: lastMessageEditedAt ?? this.lastMessageEditedAt,
      lastMessageTranslatedEditedAt:
          identical(lastMessageTranslatedEditedAt, _unset)
          ? this.lastMessageTranslatedEditedAt
          : lastMessageTranslatedEditedAt as String?,
      archivedAt: identical(archivedAt, _unset)
          ? this.archivedAt
          : archivedAt as String?,
    );
  }

  // --- END copyWith ---

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatModel &&
        other.matchId == matchId &&
        other.otherUserId == otherUserId &&
        other.otherUserName == otherUserName &&
        listEquals(other.otherUserPhotos, otherUserPhotos) &&
        other.lastMessage == lastMessage &&
        other.lastMessageTranslated == lastMessageTranslated &&
        other.lastMessageTranslatedTargetLanguage ==
            lastMessageTranslatedTargetLanguage &&
        other.lastMessageId == lastMessageId &&
        other.lastMessageSenderId == lastMessageSenderId &&
        other.lastMessageAt == lastMessageAt &&
        other.unreadCount == unreadCount &&
        other.eventId == eventId &&
        other.eventName == eventName &&
        other.eventLink == eventLink &&
        other.translationEnabled == translationEnabled &&
        other.translationLanguage == translationLanguage &&
        other.lastMessageSourceLanguage == lastMessageSourceLanguage &&
        other.matchedIntent == matchedIntent &&
        other.lastMessageEditedAt == lastMessageEditedAt &&
        other.lastMessageTranslatedEditedAt == lastMessageTranslatedEditedAt &&
        other.archivedAt == archivedAt;
  }

  @override
  int get hashCode => Object.hashAll([
    matchId,
    otherUserId,
    otherUserName,
    Object.hashAll(otherUserPhotos),
    lastMessage,
    lastMessageTranslated,
    lastMessageTranslatedTargetLanguage,
    lastMessageId,
    lastMessageSenderId,
    lastMessageAt,
    unreadCount,
    eventId,
    eventName,
    eventLink,
    translationEnabled,
    translationLanguage,
    lastMessageSourceLanguage,
    matchedIntent,
    lastMessageEditedAt,
    lastMessageTranslatedEditedAt,
    archivedAt,
  ]);

  @override
  String toString() {
    return 'ChatModel(matchId: $matchId, otherUserId: $otherUserId, otherUserName: $otherUserName, lastMessage: $lastMessage, lastMessageTranslated: $lastMessageTranslated, lastMessageTranslatedTargetLanguage: $lastMessageTranslatedTargetLanguage, lastMessageId: $lastMessageId, lastMessageSenderId: $lastMessageSenderId, lastMessageAt: $lastMessageAt, unreadCount: $unreadCount, eventId: $eventId, eventName: $eventName, eventLink: $eventLink, translationEnabled: $translationEnabled, translationLanguage: $translationLanguage, lastMessageSourceLanguage: $lastMessageSourceLanguage, matchedIntent: $matchedIntent, lastMessageEditedAt: $lastMessageEditedAt, lastMessageTranslatedEditedAt: $lastMessageTranslatedEditedAt, archivedAt: $archivedAt)';
  }
}
