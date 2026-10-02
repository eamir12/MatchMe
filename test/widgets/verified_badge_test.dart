import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/verified_badge.dart';

/// The verified badge deliberately carries no explanation.
///
/// The "Photo verification means MatchMe reviewed a verification selfie…"
/// copy was removed from the product on 2026-09-28, along with the
/// VerificationScopeNote widget. These tests exist to stop it creeping back:
/// the badge is a concise status mark, not a disclosure, and a long-press
/// Tooltip on every badge in a list is an accessibility and noise problem in
/// its own right.
void main() {
  final l10n = LocalizationState.loading();

  Widget wrap(Widget child) {
    return ProviderScope(
      overrides: [localizationProvider.overrideWithValue(l10n)],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('verified badge exposes a concise label and nothing else', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VerifiedBadge()));

    // No Tooltip anywhere: the explanation copy is gone.
    expect(find.byType(Tooltip), findsNothing);

    final semantics = tester.getSemantics(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == 'Verified',
      ),
    );
    expect(semantics.label, 'Verified');
    expect(semantics.hint, anyOf(isNull, isEmpty));
  });

  testWidgets('long press on the badge shows no explanation overlay', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VerifiedBadge()));

    await tester.longPress(find.byType(VerifiedBadge));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(Tooltip), findsNothing);
  });

  testWidgets('small verified badge matches the same semantics', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const VerifiedBadgeSmall()));

    expect(find.byType(Tooltip), findsNothing);
    final semantics = tester.getSemantics(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == 'Verified',
      ),
    );
    expect(semantics.label, 'Verified');
    expect(semantics.hint, anyOf(isNull, isEmpty));
  });

  testWidgets('badge with text still renders the label', (tester) async {
    await tester.pumpWidget(wrap(const VerifiedBadge(showText: true)));

    expect(find.text('Verified'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
  });
}
