import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/events/add_event_screen.dart';
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

  testWidgets('new event form explains public-event matching disclosure', (
    tester,
  ) async {
    final l10n = LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [localizationProvider.overrideWithValue(l10n)],
        child: const MaterialApp(home: AddEventScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter details manually'));
    await tester.pumpAndSettle();

    expect(find.text('Public event details'), findsOneWidget);
    expect(
      find.textContaining('public event name, date, venue, and link'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextFormField).first, 'Public meetup');
    await tester.ensureVisible(find.text('Save event'));
    await tester.tap(find.text('Save event'));
    await tester.pumpAndSettle();

    expect(find.text('Save this public event?'), findsOneWidget);
    expect(
      find.textContaining('available for shared-event matching'),
      findsOneWidget,
    );
  });
}
