import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/pending_mutations_indicator.dart';

void main() {
  testWidgets('pending mutations indicator is safe with an empty queue', (
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
        child: const MaterialApp(
          home: Scaffold(body: PendingMutationsIndicator(showDetails: true)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(PendingMutationsIndicator), findsOneWidget);
  });
}
