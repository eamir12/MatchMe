import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/match_profile_navigation_cue.dart';

void main() {
  testWidgets('match cue points toward the profile in LTR', (tester) async {
    final label = LocalizationState.loading().getString('viewMatch');
    expect(label, 'View Match');

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.ltr,
          child: Scaffold(
            body: MatchProfileNavigationCue(
              textDirection: TextDirection.ltr,
              label: label,
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byTooltip(label), findsOneWidget);
    expect(find.bySemanticsLabel(label), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('match cue uses auto-mirroring glyph in RTL (paints left)', (
    tester,
  ) async {
    final label = LocalizationState.loading().getString('viewMatch');
    expect(label, 'View Match');

    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: MatchProfileNavigationCue(
              textDirection: TextDirection.rtl,
              label: label,
            ),
          ),
        ),
      ),
    );

    // The widget always uses chevron_right_rounded: the glyph carries
    // `matchTextDirection: true`, so `Icon` mirrors it to point left in RTL.
    // Asserting chevron_left_rounded here would encode the old double-mirror
    // bug (manual swap + framework mirror = points right in Hebrew).
    expect(Icons.chevron_right_rounded.matchTextDirection, isTrue);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byTooltip(label), findsOneWidget);
  });
}
