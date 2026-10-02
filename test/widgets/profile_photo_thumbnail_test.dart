import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/profile_photo_thumbnail.dart';

void main() {
  testWidgets('photo thumbnail exposes a localized label and tap action', (
    tester,
  ) async {
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePhotoThumbnail(
            label: 'Photo 2',
            onTap: () => tapped = true,
            child: const SizedBox(
              width: 100,
              height: 100,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );

    final semantics = tester.getSemantics(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == 'Photo 2',
      ),
    );
    expect(semantics.label, 'Photo 2');
    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, 'Photo 2');
    expect(tooltip.excludeFromSemantics, isTrue);

    await tester.tap(find.byType(GestureDetector));
    expect(tapped, isTrue);
  });

  testWidgets('photo thumbnail exposes its explanation on long press', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfilePhotoThumbnail(
            label: 'Photo 1',
            onTap: () {},
            child: const SizedBox(
              width: 100,
              height: 100,
              child: ColoredBox(color: Colors.green),
            ),
          ),
        ),
      ),
    );

    await tester.longPress(find.byType(GestureDetector));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Photo 1'), findsOneWidget);
  });
}
