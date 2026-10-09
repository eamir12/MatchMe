import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/event_import_feedback_service.dart';

void main() {
  group('EventImportFeedbackService.eventKey', () {
    test('is stable for the same provider, calendar, and event identity', () {
      final snapshot = {
        'external_calendar_id': 'calendar-1',
        'external_event_id': 'event-1',
      };

      final first = EventImportFeedbackService.eventKey(
        provider: 'Google',
        eventTitle: 'Concert',
        eventSnapshot: snapshot,
      );
      final sameEvent = EventImportFeedbackService.eventKey(
        provider: 'google',
        eventTitle: 'Renamed event',
        eventSnapshot: snapshot,
      );

      expect(first, sameEvent);
      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('distinguishes different event IDs in the same calendar', () {
      String key(String eventId) => EventImportFeedbackService.eventKey(
        provider: 'google',
        eventTitle: 'Concert',
        eventSnapshot: {
          'external_calendar_id': 'calendar-1',
          'external_event_id': eventId,
        },
      );

      expect(key('event-1'), isNot(key('event-2')));
    });

    test('uses event details when a provider has no external event ID', () {
      String key(String start) => EventImportFeedbackService.eventKey(
        provider: 'device',
        eventTitle: 'Concert',
        eventSnapshot: {
          'start_time': start,
          'end_time': '2026-10-10T21:00:00.000',
          'event_venue': 'Main Hall',
        },
      );

      expect(
        key('2026-10-10T19:00:00.000'),
        isNot(key('2026-10-11T19:00:00.000')),
      );
    });
  });
}
