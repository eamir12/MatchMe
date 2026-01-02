// lib/models/event_model.dart
class EventModel {
  final String id;
  final String eventName;
  final String? eventVenue;
  final DateTime startTime;
  final DateTime endTime;
  final String? eventLink;
  final String? notes; // Personal notes for the current user
  final int attendeeCount; // Number of users attending this event

  EventModel({
    required this.id,
    required this.eventName,
    this.eventVenue,
    required this.startTime,
    required this.endTime,
    this.eventLink,
    this.notes,
    this.attendeeCount = 1,
  });

  factory EventModel.fromJson(Map<String, dynamic> json) {
    return EventModel(
      id: json['id'],
      eventName: json['event_name'],
      eventVenue: json['event_venue'],
      startTime: DateTime.parse(json['start_time']),
      endTime: DateTime.parse(json['end_time']),
      eventLink: json['event_link'],
      notes: json['notes'], // From event_attendees join
      attendeeCount: json['attendee_count'] ?? 1,
    );
  }

  Map<String, dynamic> toJsonForSave() {
    return {
      'event_name': eventName,
      'event_venue': eventVenue,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime.toIso8601String(),
      'event_link': eventLink,
    };
  }
}
