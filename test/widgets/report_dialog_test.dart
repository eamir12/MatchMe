import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/chats/report_dialog.dart';

void main() {
  testWidgets('report dialog uses localized copy and validates a reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(LocalizationState.loading()),
        ],
        child: MaterialApp(
          home: Scaffold(body: ReportDialogContent(otherUserName: 'Alex M.')),
        ),
      ),
    );

    expect(find.text('Report Alex M.'), findsOneWidget);
    expect(find.text('What happened?'), findsOneWidget);
    expect(find.text('Tell us what happened'), findsOneWidget);
    expect(find.text('Submit report'), findsOneWidget);
    expect(find.textContaining('key'), findsNothing);

    await tester.tap(find.text('Submit report'));
    await tester.pump();

    expect(find.text('Tell us what happened'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
