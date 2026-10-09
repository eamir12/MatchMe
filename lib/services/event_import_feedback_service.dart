// lib/services/event_import_feedback_service.dart
//
// Telemetry + review pipeline for the calendar-import privacy classifier.
// When a user taps "This event is actually public" on a blocked import
// card we log the decision's inputs — scrubbed title and event snapshot,
// block reason, provider, locale — so an admin can later verify the event
// is public and import it into the user's MatchMe events.
//
// Each user can send at most one feedback report per external calendar event.
// The sheet checks the event fingerprint before offering the action and the
// database enforces it with a unique constraint (23505 handled here).
//
// Titles/venues/descriptions are scrubbed (emails and phone numbers
// stripped) before anything is stored.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum EventImportFeedbackStatus {
  /// Report stored successfully.
  sent,

  /// The user already reported this event.
  alreadyReported,

  /// The user is not signed in.
  notAuthenticated,

  /// Network/database failure.
  failed,
}

class EventImportFeedbackService {
  EventImportFeedbackService._();

  static final RegExp _emailPattern = RegExp(
    r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
    caseSensitive: false,
  );
  static final RegExp _phonePattern = RegExp(r'(\+?\d[\d\s().-]{6,}\d)');

  static String _scrubText(String raw, {int maxLength = 180}) {
    var s = raw.trim();
    s = s.replaceAll(_emailPattern, '');
    s = s.replaceAll(_phonePattern, '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length > maxLength) s = s.substring(0, maxLength).trim();
    return s;
  }

  static String? _scrubbedField(String? raw, {int maxLength = 180}) {
    if (raw == null || raw.trim().isEmpty) return null;
    final scrubbed = _scrubText(raw, maxLength: maxLength);
    return scrubbed.isEmpty ? null : scrubbed;
  }

  static String? _truncateLink(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.length > 600 ? trimmed.substring(0, 600) : trimmed;
  }

  /// Stable, privacy-preserving identity for one external calendar event.
  /// Provider IDs are hashed and never added to the feedback table as a key.
  static String eventKey({
    required String? provider,
    required String eventTitle,
    required Map<String, dynamic>? eventSnapshot,
  }) {
    final snapshot = eventSnapshot ?? const <String, dynamic>{};
    final normalizedProvider = (provider ?? '').trim().toLowerCase();
    final calendarId = (snapshot['external_calendar_id'] ?? '')
        .toString()
        .trim();
    final externalEventId = (snapshot['external_event_id'] ?? '')
        .toString()
        .trim();
    final identity = externalEventId.isNotEmpty
        ? [
            normalizedProvider,
            calendarId,
            externalEventId,
          ].join('|')
        : [
            normalizedProvider,
            eventTitle.trim().toLowerCase(),
            (snapshot['start_time'] ?? '').toString().trim(),
            (snapshot['end_time'] ?? '').toString().trim(),
            (snapshot['event_venue'] ?? '').toString().trim().toLowerCase(),
          ].join('|');
    return md5.convert(utf8.encode(identity)).toString();
  }

  /// True when the current user already reported this specific event.
  /// Best-effort: on any error we optimistically return false and let the
  /// insert (or its unique-violation) decide.
  static Future<bool> hasAlreadyReported({
    required String eventKey,
  }) async {
    try {
      if (Supabase.instance.client.auth.currentUser == null) {
        return false;
      }
      final result = await Supabase.instance.client
          .rpc(
            'event_import_feedback_has_reported',
            params: {'p_event_key': eventKey},
          )
          .timeout(const Duration(seconds: 6));
      return result == true;
    } catch (e) {
      debugPrint('[EVENT_IMPORT_FEEDBACK] hasAlreadyReported failed: $e');
      return false;
    }
  }

  /// Best-effort: never throws, never blocks the UI on failure. Returns
  /// the outcome so the caller can show the appropriate message.
  static Future<EventImportFeedbackStatus> reportFalsePositive({
    required String blockReason,
    required String eventTitle,
    String? provider,
    required String appLocale,
    Map<String, dynamic>? eventSnapshot,
  }) async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        return EventImportFeedbackStatus.notAuthenticated;
      }

      Map<String, dynamic>? snapshot;
      if (eventSnapshot != null) {
        snapshot = {
          'event_name': ?_scrubbedField(eventSnapshot['event_name'] as String?),
          'event_venue': ?_scrubbedField(
            eventSnapshot['event_venue'] as String?,
          ),
          'event_description': ?_scrubbedField(
            eventSnapshot['event_description'] as String?,
            maxLength: 2000,
          ),
          // Links are capped but not scrubbed: admins need the working URL.
          'event_link': ?_truncateLink(eventSnapshot['event_link'] as String?),
          'start_time': ?eventSnapshot['start_time'] as String?,
          'end_time': ?eventSnapshot['end_time'] as String?,
          'is_all_day': eventSnapshot['is_all_day'] == true,
          'external_provider': ?eventSnapshot['external_provider'] as String?,
          'external_calendar_id':
              ?eventSnapshot['external_calendar_id'] as String?,
          'external_event_id': ?eventSnapshot['external_event_id'] as String?,
        };
      }

      final normalizedProvider = provider?.trim();
      await client
          .from('event_import_feedback')
          .insert({
            'user_id': userId,
            'event_key': eventKey(
              provider: provider,
              eventTitle: eventTitle,
              eventSnapshot: eventSnapshot,
            ),
            'block_reason': blockReason,
            'event_title': _scrubText(eventTitle),
            'provider':
                ?(normalizedProvider == null || normalizedProvider.isEmpty
                ? null
                : normalizedProvider),
            'app_locale': appLocale,
            'event_snapshot': ?snapshot,
          })
          .timeout(const Duration(seconds: 8));
      return EventImportFeedbackStatus.sent;
    } catch (e) {
      if (e is PostgrestException && e.code == '23505') {
        // Unique constraint: the user already reported once.
        return EventImportFeedbackStatus.alreadyReported;
      }
      // Feedback is best-effort; a failure must never surface as an error.
      debugPrint('[EVENT_IMPORT_FEEDBACK] report failed: $e');
      return EventImportFeedbackStatus.failed;
    }
  }
}
