import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/app_recovery_banner.dart';

void main() {
  testWidgets('recovery banner announces the error and exposes retry', (
    tester,
  ) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppRecoveryBanner(
            title: 'Save failed',
            message: 'Your progress is still here.',
            retryLabel: 'Retry',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Save failed'), findsOneWidget);
    expect(find.text('Your progress is still here.'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(AppRecoveryBanner));
    expect(semantics.label, contains('Save failed'));
    expect(semantics.label, contains('Your progress is still here.'));
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('recovery banner disables retry while loading', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppRecoveryBanner(
            message: 'Try again.',
            retryLabel: 'Retry',
            isLoading: true,
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    await tester.tap(find.byType(FilledButton));
    expect(retried, isFalse);
  });
}
