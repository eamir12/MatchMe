// lib/utils/event_import_classifier.dart
//
// Single source of truth for deciding whether a calendar event may be
// imported into MatchMe. Imported events become public and visible to
// matches, so anything private, personal, or lacking a public context
// must be blocked in the pickers (greyed out, not selectable) and, for
// calendar-native privacy flags, also rejected at save time.
//
// The classifier is intentionally local-only (no network calls): the
// save-time AI classification in `get-event-metadata` remains the final
// backstop via `Event.addEventWithResult`.

import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/web_calendar_service.dart';

/// Why an event cannot be imported. Ordered from strongest signal to
/// weakest so `classify...` can short-circuit.
enum EventImportBlockReason {
  /// The event may be imported.
  none,

  /// The source calendar explicitly marks the event private/non-busy
  /// (Google visibility/transparency, Outlook sensitivity/showAs,
  /// device availability, Apple ICS CLASS).
  markedPrivate,

  /// The title looks like a personal appointment (doctor visit, work
  /// meeting, kid pickup, ...) rather than a public gathering.
  looksPrivate,

  /// No usable public link and no physical venue — nothing for other
  /// users to attend.
  noPublicContext,
}

extension EventImportBlockReasonX on EventImportBlockReason {
  bool get importable => this == EventImportBlockReason.none;

  /// Localization keys for the badge, inline hint, and tap snackbar shown
  /// in the import pickers.
  String get badgeKey => switch (this) {
    EventImportBlockReason.none => '',
    EventImportBlockReason.markedPrivate =>
      'calendarSyncCannotImportPrivateBadge',
    EventImportBlockReason.looksPrivate =>
      'calendarSyncCannotImportPersonalBadge',
    EventImportBlockReason.noPublicContext => 'calendarSyncCannotImportBadge',
  };

  String get hintKey => switch (this) {
    EventImportBlockReason.none => '',
    EventImportBlockReason.markedPrivate =>
      'calendarSyncCannotImportPrivateHint',
    EventImportBlockReason.looksPrivate =>
      'calendarSyncCannotImportPersonalHint',
    EventImportBlockReason.noPublicContext =>
      'calendarSyncMissingLocationOrLinkHint',
  };
}

/// Link hosts that point back at the user's own calendar rather than a
/// public event page; never usable as the event's public link.
bool _isProviderCalendarLink(Uri uri, String normalizedProvider) {
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();
  final isGoogleCalendarLink =
      host.contains('calendar.google.') ||
      (host.contains('google.') && path.contains('calendar'));
  final isOutlookCalendarLink =
      host.contains('outlook.') ||
      host.contains('office.') ||
      host.contains('live.') ||
      (host.contains('microsoft.') && path.contains('calendar'));
  final isAppleCalendarLink = host.contains('icloud.') || path.endsWith('.ics');
  return isGoogleCalendarLink ||
      isOutlookCalendarLink ||
      isAppleCalendarLink ||
      (normalizedProvider == 'google' && isGoogleCalendarLink) ||
      (normalizedProvider == 'outlook' && isOutlookCalendarLink) ||
      (normalizedProvider == 'apple' && isAppleCalendarLink);
}

/// Returns the event's public link, or '' when the link is missing,
/// malformed, or just a pointer back into the source calendar. A link is
/// only worth something if other users could actually open it.
String usableImportLink(String? rawLink, {String? provider}) {
  final trimmed = rawLink?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '';
  }
  final uri = Uri.tryParse(trimmed);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    return '';
  }
  final normalizedProvider = provider?.trim().toLowerCase() ?? '';
  if (_isProviderCalendarLink(uri, normalizedProvider)) {
    return '';
  }
  return trimmed;
}

/// Locations that mean "you have to be on a call", not "come to this
/// place" — they don't make an event joinable in person.
bool isVirtualMeetingLocation(String? raw) {
  final s = raw?.toLowerCase().trim() ?? '';
  if (s.isEmpty) {
    return false;
  }
  if (s == 'online' || s == 'virtual') {
    return true;
  }
  if (s.contains('http://') || s.contains('https://')) {
    return true;
  }
  if (s.contains('zoom') ||
      s.contains('meet.google.com') ||
      s.contains('google meet') ||
      s.contains('teams.microsoft.com') ||
      s.contains('microsoft teams') ||
      s.contains('ms teams') ||
      s.contains('webex') ||
      s.contains('gotomeeting') ||
      s.contains('go to meeting') ||
      s.contains('skype') ||
      s.contains('hangouts') ||
      s.contains('discord.gg') ||
      s.contains('discord.com')) {
    return true;
  }
  if (s.contains('online meeting') ||
      s.contains('virtual meeting') ||
      s.contains('video call') ||
      s.contains('conference call')) {
    return true;
  }
  return false;
}

bool _hasPhysicalImportLocation(String? rawLocation) {
  final location = rawLocation?.trim();
  return location != null &&
      location.isNotEmpty &&
      !isVirtualMeetingLocation(location);
}

/// True when the source calendar itself flags the event as private or
/// non-busy. These are the user's own privacy choices, so they win over
/// any heuristic.
bool isMarkedPrivateInSourceCalendar({
  String? availability,
  String? transparency,
  String? visibility,
  String? sensitivity,
}) {
  String? norm(String? raw) => raw?.trim().toLowerCase();
  final v = norm(visibility);
  if (v == 'private' || v == 'confidential') {
    return true;
  }
  // Google: "transparent" = shown as free (typically personal reminders).
  if (norm(transparency) == 'transparent') {
    return true;
  }
  final s = norm(sensitivity);
  if (s == 'private' || s == 'personal' || s == 'confidential') {
    return true;
  }
  final a = norm(availability);
  // Device: free/unavailable; Outlook showAs: free/oof/workingElsewhere.
  if (a == 'free' ||
      a == 'unavailable' ||
      a == 'oof' ||
      a == 'workingelsewhere') {
    return true;
  }
  return false;
}

// --- Local "looks private" keyword heuristic -------------------------------
//
// Conservative on purpose: only clearly personal items are matched, in
// English, Hebrew, and Spanish. Single words match on word boundaries
// (punctuation is normalized to spaces first), phrases match as
// substrings. The save-time AI classifier remains the backstop for
// anything these lists miss.

const List<String> _privatePhrases = [
  // English
  'meeting with',
  'lunch with',
  'dinner with',
  'coffee with',
  'catch up with',
  'day camp',
  'daycamp',
  'school pickup',
  'pick up the kid',
  'take the kid',
  'kids pickup',
  'parent-teacher',
  'performance review',
  'one-on-one',
  'one on one',
  'job interview',
  '1:1',
  // Hebrew
  'פגישה עם',
  'פגישת עבודה',
  'ישיבת צוות',
  'ארוחה עם',
  'קפה עם',
  'ראיון עבודה',
  'צהרון',
  'פעוטון',
  'מעון ילדים',
  'איסוף הילדים',
  'איסוף מהגן',
  'לקחת את',
  'יום כיף',
  'בדיקת דם',
  'רופא שיניים',
  'רופאת שיניים',
  // Spanish
  'reunión con',
  'comida con',
  'cena con',
  'café con',
  'entrevista de trabajo',
  'guardería',
  'recoger a los niño',
];

const Set<String> _privateWords = {
  // English
  'doctor',
  'doctors',
  'dentist',
  'therapist',
  'therapy',
  'psychologist',
  'psychiatrist',
  'gynecologist',
  'appointment',
  'checkup',
  'vaccination',
  'vaccine',
  'babysitter',
  'haircut',
  // Hebrew
  'רופא',
  'רופאה',
  'טיפול',
  'פסיכולוג',
  'פסיכיאטר',
  'תור',
  'חיסון',
  'בדיקה',
  'אישי',
  'פרטי',
  // Spanish
  'médico',
  'dentista',
  'terapia',
  'psicólogo',
  'psiquiatra',
  'cita',
  'consulta',
  'vacuna',
  'chequeo',
};

bool _looksPrivateByTitle(String? rawTitle) {
  final title = rawTitle?.trim().toLowerCase() ?? '';
  if (title.isEmpty) {
    return false;
  }
  for (final phrase in _privatePhrases) {
    if (title.contains(phrase)) {
      return true;
    }
  }
  // Normalize punctuation to spaces so single words match on word
  // boundaries (avoids 'cita' matching inside 'solicitado', etc.).
  final padded =
      ' ${title.replaceAll(RegExp(r'[,.;:!?"()\[\]/\\{}…»«\-_—]'), ' ').replaceAll(RegExp(r'\s+'), ' ')} ';
  for (final word in _privateWords) {
    if (padded.contains(' $word ')) {
      return true;
    }
  }
  return false;
}

String? _normalizeEmail(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || !value.contains('@')) {
    return null;
  }
  return value;
}

/// 1:1s and small self-organized meetings are the archetype of calendar
/// content that must never become a public MatchMe event. Fires only when
/// the organizer is the importing account itself and the guest list is
/// small; large attendee lists (classes, meetups) stay untouched.
bool _isSelfOrganizedSmallMeeting(
  int? attendeeCount,
  String? organizerEmail,
  String? ownerEmail,
) {
  final organizer = _normalizeEmail(organizerEmail);
  final owner = _normalizeEmail(ownerEmail);
  if (organizer == null || owner == null || organizer != owner) {
    return false;
  }
  final count = attendeeCount;
  return count != null && count >= 1 && count <= 5;
}

/// Routine recurrences without any public context ("Standup", "Nir,
/// 19:30") are personal rhythms, not gatherings other users can join.
/// Recurring events with a public link OR a physical venue stay
/// importable — classes and club nights with a venue are generally
/// public. Yearly recurrences are exempt too: annual public happenings
/// are common.
bool _isRoutineRecurrence(
  String? recurrenceRule, {
  required bool hasPublicContext,
}) {
  if (hasPublicContext) {
    return false;
  }
  final rule = recurrenceRule?.trim().toLowerCase();
  if (rule == null || rule.isEmpty) {
    return false;
  }
  final freqMatch = RegExp(
    r'FREQ=([A-Z]+)',
    caseSensitive: false,
  ).firstMatch(rule);
  final freq = freqMatch?.group(1)?.toLowerCase() ?? rule;
  return switch (freq) {
    'daily' ||
    'weekly' ||
    'monthly' ||
    'absolutemonthly' ||
    'relativemonthly' => true,
    _ => false,
  };
}

EventImportBlockReason classifyEventPrivacy({
  required bool markedPrivateInSource,
  required String? title,
  required String? location,
  required String? rawLink,
  String? provider,
  int? attendeeCount,
  String? organizerEmail,
  String? ownerEmail,
  String? recurrenceRule,
}) {
  if (markedPrivateInSource) {
    return EventImportBlockReason.markedPrivate;
  }
  if (_looksPrivateByTitle(title)) {
    return EventImportBlockReason.looksPrivate;
  }
  if (_isSelfOrganizedSmallMeeting(attendeeCount, organizerEmail, ownerEmail)) {
    return EventImportBlockReason.looksPrivate;
  }
  final hasLink = usableImportLink(rawLink, provider: provider).isNotEmpty;
  final hasVenue = _hasPhysicalImportLocation(location);
  if (_isRoutineRecurrence(
    recurrenceRule,
    hasPublicContext: hasLink || hasVenue,
  )) {
    return EventImportBlockReason.looksPrivate;
  }
  if (!hasLink && !hasVenue) {
    return EventImportBlockReason.noPublicContext;
  }
  return EventImportBlockReason.none;
}

/// Classify an event straight from a calendar provider.
EventImportBlockReason classifyExternalEventImport(
  ExternalEvent event, {
  String? provider,
  String? ownerEmail,
}) {
  return classifyEventPrivacy(
    markedPrivateInSource: isMarkedPrivateInSourceCalendar(
      availability: event.availability,
      transparency: event.transparency,
      visibility: event.visibility,
      sensitivity: event.sensitivity,
    ),
    title: event.title,
    location: event.location,
    rawLink: event.url?.toString(),
    provider: provider,
    attendeeCount: event.attendeeCount,
    organizerEmail: event.organizer,
    ownerEmail: ownerEmail,
    recurrenceRule: event.recurrenceRule,
  );
}

/// Classify an event that has already been collapsed into an [EventModel].
/// When the model carries a pre-computed [EventModel.importBlockReason]
/// (set when the event was fetched from its calendar), it is authoritative;
/// otherwise the local checks run on whatever fields the model has.
EventImportBlockReason classifyEventModelImport(EventModel event) {
  final stored = event.importBlockReason?.trim();
  if (stored != null && stored.isNotEmpty) {
    for (final reason in EventImportBlockReason.values) {
      if (reason.name == stored) {
        return reason;
      }
    }
  }
  return classifyEventPrivacy(
    markedPrivateInSource: event.markedPrivateInSource,
    title: event.eventName,
    location: event.eventVenue,
    rawLink: event.eventLink,
    provider: event.externalProvider,
  );
}
