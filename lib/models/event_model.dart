// lib/models/event_model.dart
class EventModel {
  final String id;
  final String eventName;
  final String? eventVenue;
  final DateTime startTime;
  final DateTime endTime;
  final String? eventLink;
  final String? notes; // Personal notes for the current user
  final int? attendeeCount;
  final String?
  externalCalendarId; // ID of the external calendar this event came from
  final String? externalEventId; // ID of the event in the external calendar
  final String? externalProvider; // Provider name (google, outlook, apple)
  final bool isAllDay; // Whether this is an all-day event
  final String? description; // Event description

  /// True when the source calendar explicitly marked this event private
  /// or non-busy (Google visibility/transparency, Outlook
  /// sensitivity/showAs, device availability, Apple ICS CLASS). Used to
  /// block imports of calendar-native private events even when they carry
  /// a link; never persisted to the events table.
  final bool markedPrivateInSource;

  /// Pre-computed import-block reason for calendar-sourced events
  /// (an [EventImportBlockReason.name]: 'markedPrivate', 'looksPrivate',
  /// 'noPublicContext'; null when importable or unknown). Persisted in the
  /// connected-accounts cache so signals that need provider data the model
  /// doesn't hold (attendees, recurrence, organizer) survive restarts.
  final String? importBlockReason;

  EventModel({
    required this.id,
    required this.eventName,
    this.eventVenue,
    required this.startTime,
    required this.endTime,
    this.eventLink,
    this.notes,
    this.attendeeCount,
    this.externalCalendarId,
    this.externalEventId,
    this.externalProvider,
    this.isAllDay = false,
    this.description,
    this.markedPrivateInSource = false,
    this.importBlockReason,
  });

  factory EventModel.fromJson(Map<String, dynamic> json) {
    final rawAttendeeCount = json['attendee_count'];
    final attendeeCount = rawAttendeeCount is num
        ? rawAttendeeCount.toInt()
        : int.tryParse('${rawAttendeeCount ?? ''}');
    return EventModel(
      id: json['id'],
      eventName: json['event_name'],
      eventVenue: json['event_venue'],
      startTime: DateTime.parse(json['start_time']),
      endTime: DateTime.parse(json['end_time']),
      eventLink: json['event_link'],
      notes: json['notes'], // From event_attendees join
      attendeeCount: attendeeCount,
      externalCalendarId: json['external_calendar_id'],
      externalEventId: json['external_event_id'],
      externalProvider: json['external_provider'],
      isAllDay: json['is_all_day'] ?? false,
      description: json['description'],
      markedPrivateInSource: json['marked_private_in_source'] == true,
      importBlockReason: json['import_block_reason'] as String?,
    );
  }

  Map<String, dynamic> toJsonForSave() {
    return {
      'event_name': eventName,
      'event_venue': eventVenue,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'event_link': eventLink,
      'external_calendar_id': externalCalendarId,
      'external_event_id': externalEventId,
      'external_provider': externalProvider,
      'is_all_day': isAllDay,
      'description': description,
    };
  }
}
