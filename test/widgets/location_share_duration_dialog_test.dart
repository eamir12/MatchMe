import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/location_share/location_share_duration_dialog.dart';

void main() {
  LocalizationState buildLocalization() {
    return LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: const {},
      supportedLanguages: const [],
    );
  }

  testWidgets(
    'duration dialog identifies the recipient and protects indefinite sharing',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localizationProvider.overrideWithValue(buildLocalization()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LocationShareDurationDialog(
                otherUserName: 'Alex',
                durationOptions: [900],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('You’re sharing your live location with Alex.'),
        findsOneWidget,
      );
      expect(find.text('Until turned off'), findsOneWidget);

      await tester.tap(find.text('Until turned off'));
      await tester.pump();
      await tester.tap(find.text('Share Your Location'));
      await tester.pumpAndSettle();

      expect(find.text('Share until turned off?'), findsOneWidget);
      expect(
        find.text(
          'You’re choosing to share your live location with Alex until you turn it off. You can stop sharing at any time.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('Share for how long?'), findsOneWidget);
    },
  );

  testWidgets('duration change dialog uses save language', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(buildLocalization()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: LocationShareDurationDialog(
              otherUserName: 'Alex',
              isChangingDuration: true,
              durationOptions: [900],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Change sharing duration'), findsOneWidget);
    expect(find.text('Save duration'), findsOneWidget);
    expect(
      find.text('You’re sharing your live location with Alex.'),
      findsOneWidget,
    );
  });
}
