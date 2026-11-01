// Spot me composer gate: a card needs a selfie or outfit values. A note is a
// clue attached to the card, so typing one must not enable Share on its own.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/meetup/meetup_spot_composer.dart';

LocalizationState _l10n() => LocalizationState(
  currentLocale: const Locale('en'),
  textDirection: TextDirection.ltr,
  strings: const {},
  supportedLanguages: const [],
  contentLanguageCode: 'en',
);

Finder _shareButton() => find.ancestor(
  of: find.text('Share card'),
  matching: find.bySubtype<FilledButton>(),
);

Future<void> _pumpComposer(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [localizationProvider.overrideWithValue(_l10n())],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MeetupSpotComposerSheet(
              matchId: 'match-1',
              otherUserName: 'Robin L.',
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a note alone cannot be shared', (tester) async {
    await _pumpComposer(tester);

    expect(tester.widget<FilledButton>(_shareButton()).onPressed, isNull);

    await tester.enterText(
      find.byType(TextField),
      'I am by the north entrance.',
    );
    await tester.pump();

    expect(tester.widget<FilledButton>(_shareButton()).onPressed, isNull);
    expect(
      find.text('Add a photo or outfit details to share.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an outfit value alone enables sharing', (tester) async {
    await _pumpComposer(tester);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Long sleeve').last);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(_shareButton()).onPressed, isNotNull);
    expect(find.text('Add a photo or outfit details to share.'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
