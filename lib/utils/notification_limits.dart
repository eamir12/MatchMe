// lib/utils/notification_limits.dart
// Single source of truth for notification limits.
// Mirrors supabase/functions/_shared/notification_limits.ts and
// migration 20260916000000_add_notification_limits.sql.
// Truncation is UTF-8 byte based (FCM/APNs = 4096 bytes total).

import 'dart:convert';

import 'package:matchme/utils/string_extensions.dart';

class NotifLimits {
  static const int adminTitleMaxChars = 60;
  static const int adminTitleMaxBytes = 200;
  static const int adminBodyMaxChars = 180;
  static const int adminBodyMaxBytes = 1000;
  static const int actionTextMaxChars = 30;
  static const int actionUrlMaxChars = 2000;

  static const int queueTitleMaxBytes = 500;
  static const int queueBodyMaxBytes = 1500;
  static const int fcmDataMaxBytes = 2000;
  static const int fcmTotalMaxBytes = 3500;

  static const int senderNameMaxChars = 20;
  static const int broadcastMaxDeliveries = 20000;
  static const int targetUserIdsMax = 500;
  static const int chatHistoryMaxItems = 5;
  static const int chatHistoryMaxBytes = 800;
  // Mirrors CHAT_PREVIEW_LINE_MAX_BYTES: five lines plus JSON overhead have to
  // fit inside fcmDataMaxBytes, so an expanded card's line is capped far below
  // the 1500-byte budget a single-message card gets.
  static const int chatPreviewLineMaxBytes = 240;
  // Configurable server-side via app_config
  // notifications.admin_broadcast_max_per_day (default 10). Keep in sync.
  static const int adminMaxPerUserPerDay = 10;
}

int notifUtf8Bytes(String s) => utf8.encode(s).length;

/// Truncate to [maxBytes] UTF-8 without splitting multi-byte runes.
/// Appends … only when truncation happened and budget allows.
({String text, bool truncated}) truncateUtf8Bytes(String input, int maxBytes) {
  final bytes = notifUtf8Bytes(input);
  if (bytes <= maxBytes) return (text: input, truncated: false);
  const ellipsis = '…';
  final ellipsisBytes = notifUtf8Bytes(ellipsis);
  final budget = maxBytes - ellipsisBytes;
  if (budget <= 0) return (text: '', truncated: true);
  // Walk by runes so we never split surrogate pairs / combining marks.
  final buf = StringBuffer();
  var used = 0;
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final b = notifUtf8Bytes(ch);
    if (used + b > budget) break;
    buf.write(ch);
    used += b;
  }
  return (text: '${buf.toString()}$ellipsis', truncated: true);
}

/// The notification-copy face of the app's only name format, "John S.".
///
/// Delegates to [StringExtension.formatAsFirstNameLastInitial], so a bare
/// first name is never returned for a single-word name; such a name (and an
/// empty one) falls back to 'Someone', the notification template's neutral
/// placeholder. Idempotent: already-masked server titles pass through.
String maskFullName(String raw) =>
    raw.formatAsFirstNameLastInitial(fallback: 'Someone');

({String title, String body, bool truncated}) enforceTitleBody(
  String title,
  String body,
) {
  final t = truncateUtf8Bytes(title.trim(), NotifLimits.queueTitleMaxBytes);
  final b = truncateUtf8Bytes(body.trim(), NotifLimits.queueBodyMaxBytes);
  return (title: t.text, body: b.text, truncated: t.truncated || b.truncated);
}

/// Validate admin input. Returns list of human-readable issues (empty = OK).
List<String> adminInputViolations({
  required String title,
  required String body,
  String? actionUrl,
  String? actionText,
}) {
  final issues = <String>[];
  final t = title.trim();
  final b = body.trim();
  if (t.isEmpty) issues.add('Title is required');
  if (b.isEmpty) issues.add('Message is required');
  if (t.length > NotifLimits.adminTitleMaxChars) {
    issues.add('Title max ${NotifLimits.adminTitleMaxChars} chars');
  }
  if (notifUtf8Bytes(t) > NotifLimits.adminTitleMaxBytes) {
    issues.add('Title max ${NotifLimits.adminTitleMaxBytes} bytes');
  }
  if (b.length > NotifLimits.adminBodyMaxChars) {
    issues.add('Message max ${NotifLimits.adminBodyMaxChars} chars');
  }
  if (notifUtf8Bytes(b) > NotifLimits.adminBodyMaxBytes) {
    issues.add('Message max ${NotifLimits.adminBodyMaxBytes} bytes');
  }
  if (actionText != null &&
      actionText.length > NotifLimits.actionTextMaxChars) {
    issues.add('Action text max ${NotifLimits.actionTextMaxChars} chars');
  }
  final u = (actionUrl ?? '').trim();
  if (u.isNotEmpty) {
    if (u.length > NotifLimits.actionUrlMaxChars) {
      issues.add('Action URL too long');
    }
    // Strict to match DB check_notification_limits and TS helper.
    if (!RegExp(r'^https?://.+\..+').hasMatch(u)) {
      issues.add('Action URL must be http(s)');
    } else {
      final uri = Uri.tryParse(u);
      if (uri == null ||
          !(uri.isScheme('http') || uri.isScheme('https')) ||
          uri.host.isEmpty) {
        issues.add('Action URL must be http(s)');
      }
    }
  }
  return issues;
}

int fcmPayloadBytes(
  String title,
  String body, [
  Map<String, String> data = const {},
]) {
  return notifUtf8Bytes(
    jsonEncode({'title': title, 'body': body, 'data': data}),
  );
}
