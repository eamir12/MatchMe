import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/services/web_calendar_service.dart';
import 'package:matchme/utils/event_import_classifier.dart';

void main() {
  ExternalEvent ext({
    String title = 'Some event',
    String? location,
    String? url,
    String? provider,
    String? availability,
    String? transparency,
    String? visibility,
    String? sensitivity,
    int? attendeeCount,
    String? organizer,
    String? recurrenceRule,
  }) {
    return ExternalEvent(
      calendarId: 'cal',
      id: 'e1',
      title: title,
      start: DateTime(2026, 11, 1, 10),
      end: DateTime(2026, 11, 1, 11),
      description: null,
      isAllDay: false,
      location: location,
      url: url == null ? null : Uri.tryParse(url),
      organizer: organizer,
      availability: availability,
      transparency: transparency,
      visibility: visibility,
      sensitivity: sensitivity,
      attendeeCount: attendeeCount,
      recurrenceRule: recurrenceRule,
    );
  }

  group('calendar-native privacy flags', () {
    test('google visibility private blocks', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Concert', visibility: 'private'),
        ),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('google transparency transparent blocks', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Reminder', transparency: 'transparent'),
        ),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('outlook sensitivity personal blocks', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Sync', sensitivity: 'personal'),
        ),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('outlook showAs oof blocks', () {
      expect(
        classifyExternalEventImport(ext(title: 'Trip', availability: 'oof')),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('device availability free blocks', () {
      expect(
        classifyExternalEventImport(ext(title: 'Errand', availability: 'free')),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('apple ics class private blocks', () {
      expect(
        classifyExternalEventImport(ext(title: 'X', visibility: 'PRIVATE')),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('normal busy/default public events do not block', () {
      expect(
        classifyExternalEventImport(
          ext(
            title: 'Jazz night',
            location: 'Yellow Submarine, Tel Aviv',
            availability: 'busy',
            visibility: 'default',
            transparency: 'opaque',
          ),
        ),
        EventImportBlockReason.none,
      );
    });
  });

  group('local keyword heuristic', () {
    test('english medical titles block', () {
      expect(
        classifyExternalEventImport(
          ext(title: "Doctor's appointment", location: 'Clalit Clinic'),
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('meeting with boss blocks even with a venue', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Meeting with the boss', location: 'Office 4B'),
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('day camp / kid pickup block', () {
      expect(
        classifyExternalEventImport(ext(title: 'Take the kid to day camp')),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('hebrew doctor appointment blocks', () {
      expect(
        classifyExternalEventImport(ext(title: 'תור לרופא שיניים 14:30')),
        EventImportBlockReason.looksPrivate,
      );
      expect(
        classifyExternalEventImport(ext(title: 'פגישה עם הבוס')),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('hebrew word-boundary: private word does not false-positive', () {
      // 'תור' must not match inside unrelated words like 'תורנות' is fine,
      // but 'מסיבת תום' etc. must stay importable.
      expect(
        classifyExternalEventImport(
          ext(title: 'מסיבה בפאב', location: 'Sputnik, Tel Aviv'),
        ),
        EventImportBlockReason.none,
      );
    });

    test('spanish cita blocks', () {
      expect(
        classifyExternalEventImport(ext(title: 'Cita con el médico')),
        EventImportBlockReason.looksPrivate,
      );
      // 'cita' should not match inside 'solicitado' / 'excita' style words.
      expect(
        classifyExternalEventImport(
          ext(title: 'Festival solicitado', location: 'Parque Central'),
        ),
        EventImportBlockReason.none,
      );
    });

    test('public titles pass', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Live jazz concert', location: 'Zappa Club'),
        ),
        EventImportBlockReason.none,
      );
    });
  });

  group('no public context', () {
    test('no venue, no link blocks as before', () {
      expect(
        classifyExternalEventImport(ext(title: 'Lunch')),
        EventImportBlockReason.noPublicContext,
      );
    });

    test('virtual meeting location is not a venue', () {
      expect(
        classifyExternalEventImport(
          ext(title: 'Sync', location: 'https://meet.google.com/abc'),
        ),
        EventImportBlockReason.noPublicContext,
      );
    });
  });

  group('usableImportLink', () {
    test('calendar provider links are not public links', () {
      expect(
        usableImportLink(
          'https://calendar.google.com/calendar/u/0/r/event/xyz',
          provider: 'google',
        ),
        '',
      );
      // A plain external link IS a usable public link.
      expect(
        usableImportLink('https://example.com/party'),
        'https://example.com/party',
      );
    });

    test('real links pass', () {
      expect(
        usableImportLink('https://www.zappa-club.co.il/show/123'),
        'https://www.zappa-club.co.il/show/123',
      );
    });
  });

  group('EventModel classification (collapsed metadata flag)', () {
    test('flagged model blocks even with a link', () {
      final event = EventModel(
        id: '',
        eventName: 'Concert',
        startTime: DateTime(2026, 11, 1, 10),
        endTime: DateTime(2026, 11, 1, 11),
        eventLink: 'https://example.com/tickets',
        markedPrivateInSource: true,
      );
      expect(
        classifyEventModelImport(event),
        EventImportBlockReason.markedPrivate,
      );
    });

    test('unflagged model with venue passes', () {
      final event = EventModel(
        id: '',
        eventName: 'Tech meetup',
        eventVenue: 'Google Tel Aviv',
        startTime: DateTime(2026, 11, 1, 10),
        endTime: DateTime(2026, 11, 1, 11),
      );
      expect(classifyEventModelImport(event), EventImportBlockReason.none);
    });

    test('stored importBlockReason is authoritative', () {
      // Attendee/recurrence-derived blocks can't be recomputed from the
      // model fields; the pre-computed reason must survive.
      final event = EventModel(
        id: '',
        eventName: 'Project Alpha review',
        eventVenue: 'Office 4B',
        startTime: DateTime(2026, 11, 1, 10),
        endTime: DateTime(2026, 11, 1, 11),
        markedPrivateInSource: true,
        importBlockReason: EventImportBlockReason.looksPrivate.name,
      );
      expect(
        classifyEventModelImport(event),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('unknown stored reason falls back to local checks', () {
      final event = EventModel(
        id: '',
        eventName: 'Tech meetup',
        eventVenue: 'Google Tel Aviv',
        startTime: DateTime(2026, 11, 1, 10),
        endTime: DateTime(2026, 11, 1, 11),
        importBlockReason: 'bogus',
      );
      expect(classifyEventModelImport(event), EventImportBlockReason.none);
    });
  });

  group('self-organized small meeting (attendee/organizer signal)', () {
    test('owner-organized 1:1 blocks as looksPrivate', () {
      expect(
        classifyExternalEventImport(
          ext(
            title: 'Sync',
            location: 'Office',
            organizer: 'me@gmail.com',
            availability: 'busy',
            attendeeCount: 1,
          ),
          ownerEmail: 'Me@Gmail.com',
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('owner-organized small guest list blocks as looksPrivate', () {
      // attendeeCount small + organizer == owner, no other privacy flags.
      final event = ExternalEvent(
        calendarId: 'cal',
        id: 'e2',
        title: 'Project review',
        start: DateTime(2026, 11, 1, 10),
        end: DateTime(2026, 11, 1, 11),
        description: null,
        isAllDay: false,
        location: 'Office 4B',
        url: null,
        organizer: 'me@gmail.com',
        availability: 'busy',
        attendeeCount: 3,
      );
      expect(
        classifyExternalEventImport(event, ownerEmail: 'me@gmail.com'),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('large attendee list does not block', () {
      final event = ExternalEvent(
        calendarId: 'cal',
        id: 'e3',
        title: 'Company all-hands',
        start: DateTime(2026, 11, 1, 10),
        end: DateTime(2026, 11, 1, 11),
        description: null,
        isAllDay: false,
        location: 'Main hall',
        url: null,
        organizer: 'me@gmail.com',
        availability: 'busy',
        attendeeCount: 120,
      );
      expect(
        classifyExternalEventImport(event, ownerEmail: 'me@gmail.com'),
        EventImportBlockReason.none,
      );
    });

    test('someone else\'s meeting does not block', () {
      final event = ExternalEvent(
        calendarId: 'cal',
        id: 'e4',
        title: 'Community planning',
        start: DateTime(2026, 11, 1, 10),
        end: DateTime(2026, 11, 1, 11),
        description: null,
        isAllDay: false,
        location: 'Community center',
        url: null,
        organizer: 'other@example.org',
        availability: 'busy',
        attendeeCount: 4,
      );
      expect(
        classifyExternalEventImport(event, ownerEmail: 'me@gmail.com'),
        EventImportBlockReason.none,
      );
    });

    test('no owner email known: signal disabled', () {
      final event = ExternalEvent(
        calendarId: 'cal',
        id: 'e5',
        title: 'Project review',
        start: DateTime(2026, 11, 1, 10),
        end: DateTime(2026, 11, 1, 11),
        description: null,
        isAllDay: false,
        location: 'Office 4B',
        url: null,
        organizer: 'me@gmail.com',
        availability: 'busy',
        attendeeCount: 3,
      );
      expect(classifyExternalEventImport(event), EventImportBlockReason.none);
    });
  });

  group('routine recurrence heuristic', () {
    test('weekly class with a venue stays importable (classes are public)', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Gym',
          location: 'Holmes Place',
          rawLink: null,
          recurrenceRule: 'FREQ=WEEKLY;BYDAY=MO,WE',
        ),
        EventImportBlockReason.none,
      );
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Salsa class',
          location: 'Studio 6, Tel Aviv',
          rawLink: null,
          recurrenceRule: 'FREQ=WEEKLY',
        ),
        EventImportBlockReason.none,
      );
    });

    test('weekly event with a public link stays importable', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Tuesday trivia night',
          location: 'Sputnik',
          rawLink: 'https://example.com/trivia',
          recurrenceRule: 'FREQ=WEEKLY',
        ),
        EventImportBlockReason.none,
      );
    });

    test('recurring with neither venue nor link blocks as looksPrivate', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Standup',
          location: null,
          rawLink: null,
          recurrenceRule: 'FREQ=WEEKLY',
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('yearly recurrence does not block', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Street festival',
          location: 'Rothschild Blvd',
          rawLink: null,
          recurrenceRule: 'FREQ=YEARLY',
        ),
        EventImportBlockReason.none,
      );
    });

    test('outlook pattern type string is recognized', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Sync notes',
          location: null,
          rawLink: null,
          recurrenceRule: 'relativeMonthly',
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('one-off events are unaffected', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Launch party',
          location: 'Hangar 21',
          rawLink: null,
          recurrenceRule: null,
        ),
        EventImportBlockReason.none,
      );
    });
  });

  group('manual-entry classification (item 2)', () {
    test('typed personal title triggers looksPrivate', () {
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Doctor appointment',
          location: '',
          rawLink: '',
        ),
        EventImportBlockReason.looksPrivate,
      );
    });

    test('noPublicContext does not block manual entries', () {
      // Manual entries without venue/link are allowed and left to the
      // save-time AI check; the classifier reports the reason but the
      // manual-entry screen only acts on looksPrivate.
      expect(
        classifyEventPrivacy(
          markedPrivateInSource: false,
          title: 'Some meetup somewhere',
          location: '',
          rawLink: '',
        ),
        EventImportBlockReason.noPublicContext,
      );
    });
  });
}
