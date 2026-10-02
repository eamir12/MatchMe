import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matchme/models/event_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/events/attendees_screen.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('en');
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      debug: false,
    );
  });

  testWidgets('event matches empty state explains what is shown', (
    tester,
  ) async {
    final l10n = LocalizationState.loading();
    final event = EventModel(
      id: 'event-1',
      eventName: 'Rooftop Mixer',
      startTime: DateTime(2026, 8, 1, 18),
      endTime: DateTime(2026, 8, 1, 22),
      attendeeCount: 3,
      eventLink: 'https://example.com/event',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          eventMatchesProvider(event).overrideWith((ref) async => const []),
        ],
        child: MaterialApp(home: AttendeesScreen(event: event)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rooftop Mixer Matches'), findsOneWidget);
    final detailsButton = find.widgetWithText(TextButton, 'View event details');
    expect(detailsButton, findsOneWidget);
    expect(tester.getSize(detailsButton).height, greaterThanOrEqualTo(48));
    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('No matches were found for this event'), findsOneWidget);
    expect(
      find.text('Match with people who are attending the same events as you'),
      findsOneWidget,
    );
    expect(find.text('You’re listed as attending on MatchMe'), findsOneWidget);
    expect(find.text('3 attending, including you'), findsOneWidget);
    expect(
      find.text(
        'Only your event matches are shown—not the full attendee list.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('event matches title remains localized without an app bar', (
    tester,
  ) async {
    final l10n = LocalizationState.loading();
    final event = EventModel(
      id: 'event-2',
      eventName: 'Board Game Night',
      startTime: DateTime(2026, 8, 2, 18),
      endTime: DateTime(2026, 8, 2, 22),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(l10n),
          eventMatchesProvider(event).overrideWith((ref) async => const []),
        ],
        child: MaterialApp(
          home: AttendeesScreen(event: event, showAppBar: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Board Game Night Matches'), findsOneWidget);
  });
}
