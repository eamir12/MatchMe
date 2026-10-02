import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/event_attendance_summary.dart';

void main() {
  testWidgets('attendance summary combines RSVP and aggregate count', (
    tester,
  ) async {
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventAttendanceSummary(attendeeCount: 4, l10n: l10n),
        ),
      ),
    );

    expect(find.text('You’re listed as attending on MatchMe'), findsOneWidget);
    expect(find.text('4 attending, including you'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(EventAttendanceSummary));
    expect(
      semantics.label,
      'You’re listed as attending on MatchMe. 4 attending, including you',
    );
  });

  testWidgets('attendance summary omits an unavailable count', (tester) async {
    final l10n = LocalizationState.loading();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventAttendanceSummary(attendeeCount: null, l10n: l10n),
        ),
      ),
    );

    expect(find.text('You’re listed as attending on MatchMe'), findsOneWidget);
    expect(find.textContaining('attending, including you'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('event model preserves an unavailable attendee count', () {
    final event = EventModel.fromJson({
      'id': 'event-1',
      'event_name': 'Rooftop Mixer',
      'start_time': '2026-08-01T18:00:00Z',
      'end_time': '2026-08-01T22:00:00Z',
    });

    expect(event.attendeeCount, isNull);
  });
}
