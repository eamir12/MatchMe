// lib/utils/chat_notification_copy.dart
//
// The client twin of supabase/functions/_shared/chat_notification_copy.ts.
// The server computes this model once per chat event and puts it in the push
// payload; a card the app draws itself - web tray, iOS banner, Windows toast,
// or a push that arrived without a payload - has to reach the same result from
// the same inputs, so the rules live here rather than in three renderers.
//
// The two rules the member set, encoded once:
//
//  1. The unread total belongs in the TITLE ("3 messages from John S."), never
//     in the body. iOS has no per-conversation badge API, a browser tray has no
//     grouping field and a Windows toast has no badge at all, so the title is
//     the only slot every platform has in common.
//  2. A collapsed card shows NO message text when the conversation holds more
//     than one unread message. A single line cannot say whether it is the first,
//     last or some middle message of the batch, so the card states what opening
//     the app will do instead: "3 unread - open to read". There is deliberately
//     no "New message" string anywhere in this file.
//
// The sentences themselves are localized in LocalizationState (English defaults
// in lib/providers/locale_provider.dart, es/he in
// supabase/migrations/20262154000001_add_chat_notification_copy_translations.sql)
// and reach this module through [ChatCopyForms], so a card built before the
// translation table is loaded still says something true.

import 'dart:convert';

import 'package:matchme/utils/notification_limits.dart';

/// The chat card fields a push payload carries for this recipient.
///
/// FCM data values are strings, so `preview_lines` travels as a JSON array and
/// the counts as decimal text.
class ChatPushCardModel {
  const ChatPushCardModel({
    this.title,
    this.body,
    this.previewLines = const <String>[],
    this.unreadCount,
    this.previewsEnabled,
  });

  /// Reads the card out of an FCM / APNs / WNS data payload.
  ///
  /// Returns null when the payload carries no copy at all: that is a data-only
  /// push, and the client builds the card from what it has locally.
  static ChatPushCardModel? tryFromMap(Map<String, dynamic> data) {
    final title = (data['notification_title'] ?? '').toString().trim();
    final body = (data['notification_body'] ?? '').toString().trim();
    final rawLines = (data['preview_lines'] ?? '').toString().trim();
    final countRaw = (data['unread_count'] ?? '').toString().trim();
    final previewsRaw = data['previews_enabled']?.toString().trim();
    if (title.isEmpty && body.isEmpty && rawLines.isEmpty && countRaw.isEmpty) {
      return null;
    }

    final lines = <String>[];
    if (rawLines.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawLines);
        if (decoded is List) {
          for (final entry in decoded) {
            final line = entry.toString().trim();
            if (line.isNotEmpty) lines.add(line);
          }
        }
      } catch (_) {
        // A malformed preview_lines must not cost the member the card: the
        // title and body are still server-computed.
      }
    }

    return ChatPushCardModel(
      title: title.isEmpty ? null : title,
      body: body.isEmpty ? null : body,
      previewLines: lines,
      unreadCount: int.tryParse(countRaw),
      previewsEnabled: previewsRaw == 'true'
          ? true
          : previewsRaw == 'false'
          ? false
          : null,
    );
  }

  final String? title;
  final String? body;
  final List<String> previewLines;
  final int? unreadCount;
  final bool? previewsEnabled;
}

/// The two chat-card sentences, resolved for a given unread count.
///
/// Implemented by LocalizationState in the content language; the fallback form
/// is English so a renderer with no provider container yet still posts a card
/// that states the count.
class ChatCopyForms {
  const ChatCopyForms({required this.title, required this.openToReadBody});

  /// `"{count} messages from {masked name}"` - rule 1.
  final String Function(int count) title;

  /// `"{count} unread - open to read"` - rule 2.
  final String Function(int count) openToReadBody;

  /// English copy for a renderer whose localization container is not ready.
  /// A card must never be suppressed, or fall back to "New message", because a
  /// provider had not answered yet.
  static ChatCopyForms fallback(String maskedName) => ChatCopyForms(
    title: (count) => count == 1
        ? '1 message from $maskedName'
        : '$count messages from $maskedName',
    openToReadBody: (count) => '$count unread - open to read',
  );
}

/// The card a renderer draws: what the title says, what the body says, and the
/// lines a surface that can expand may show.
class ChatNotificationCard {
  const ChatNotificationCard({
    required this.title,
    required this.body,
    required this.previewLines,
    required this.unreadCount,
    required this.previewsEnabled,
  });

  final String title;
  final String body;

  /// Oldest-first displayable lines, capped to the preview window. Empty when
  /// previews are off - a card never carries text the member hid.
  final List<String> previewLines;
  final int unreadCount;
  final bool previewsEnabled;
}

/// Builds the card for one conversation notification.
///
/// [candidateLines] is every displayable unread line the caller holds, oldest
/// first. When the member turned previews off the caller may still pass them -
/// this function drops them, which is what keeps the rule in one place.
///
/// [payload] wins when it carries copy: the server already applied the model in
/// the recipient's language and after translation, so recomputing here could
/// only diverge.
ChatNotificationCard buildChatNotificationCard({
  required int unreadCount,
  required bool previewsEnabled,
  required List<String> candidateLines,
  required ChatCopyForms forms,
  ChatPushCardModel? payload,
}) {
  final count = unreadCount < 1 ? 1 : unreadCount;
  final supplied = (payload != null && payload.previewLines.isNotEmpty)
      ? payload.previewLines
      : candidateLines;
  final lines = previewsEnabled
      ? _displayableLines(supplied)
      : const <String>[];

  // Exactly one unread is unambiguous: that line can only be that message.
  final single = count == 1 && lines.length == 1 ? lines.first : '';
  final title = _firstNonEmpty(payload?.title, forms.title(count));
  final body = _firstNonEmpty(
    payload?.body,
    single.isNotEmpty ? single : forms.openToReadBody(count),
  );
  final enforced = enforceTitleBody(title, body);

  return ChatNotificationCard(
    title: enforced.title,
    body: enforced.body,
    previewLines: lines,
    unreadCount: count,
    previewsEnabled: previewsEnabled,
  );
}

String _firstNonEmpty(String? preferred, String fallback) {
  final value = preferred?.trim() ?? '';
  return value.isEmpty ? fallback : value;
}

/// Trims, byte-caps and clamps the unread lines to the preview window, keeping
/// the newest tail (oldest-first order preserved).
List<String> _displayableLines(List<String> lines) {
  final result = <String>[];
  for (final line in lines) {
    final text = line.trim();
    if (text.isEmpty) continue;
    result.add(
      truncateUtf8Bytes(text, NotifLimits.chatPreviewLineMaxBytes).text,
    );
  }
  if (result.length <= NotifLimits.chatHistoryMaxItems) return result;
  return result.sublist(result.length - NotifLimits.chatHistoryMaxItems);
}
