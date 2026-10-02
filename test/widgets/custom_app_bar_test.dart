import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/custom_app_bar.dart';

class _CustomAppBarHarness extends StatelessWidget {
  final VoidCallback onHomePressed;

  const _CustomAppBarHarness({required this.onHomePressed});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildCustomAppBar(
        context,
        LocalizationState.loading(),
        'Home',
        const [],
        onHomePressed: onHomePressed,
      ),
      body: const SizedBox.shrink(),
    );
  }
}

void main() {
  testWidgets('home control has a clear label and accessible target', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var pressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: _CustomAppBarHarness(onHomePressed: () => pressed = true),
      ),
    );
    await tester.pump();

    final homeButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Home',
    );
    expect(homeButton, findsOneWidget);
    expect(tester.getSize(homeButton), const Size(48, 48));

    final semanticHome = find.bySemanticsLabel('Home').last;
    final semantics = tester.getSemantics(semanticHome);
    expect(semantics.label, 'Home');
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(homeButton);
    expect(pressed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
