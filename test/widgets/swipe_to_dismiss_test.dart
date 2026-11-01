import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/swipe_to_dismiss.dart';

Widget _host({required VoidCallback onDismissed}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 300,
          child: SwipeToDismiss(
            onDismissed: onDismissed,
            child: Container(height: 60, color: Colors.blue),
          ),
        ),
      ),
    ),
  );
}

Offset _translation(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find
        .descendant(
          of: find.byType(SwipeToDismiss),
          matching: find.byType(Transform),
        )
        .first,
  );
  final offset = transform.transform.getTranslation();
  return Offset(offset.x, offset.y);
}

void main() {
  testWidgets('sideways drag past the threshold clears the banner', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(_host(onDismissed: () => dismissed++));

    await tester.timedDrag(
      find.byType(SwipeToDismiss),
      const Offset(200, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(dismissed, 1);
  });

  testWidgets('short sideways drag springs back without clearing', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(_host(onDismissed: () => dismissed++));

    await tester.timedDrag(
      find.byType(SwipeToDismiss),
      const Offset(30, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();

    expect(dismissed, 0);
    expect(_translation(tester), Offset.zero);
  });

  testWidgets('upward drag past the threshold clears the banner', (
    tester,
  ) async {
    var dismissed = 0;
    await tester.pumpWidget(_host(onDismissed: () => dismissed++));

    await tester.timedDrag(
      find.byType(SwipeToDismiss),
      const Offset(0, -60),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(dismissed, 1);
  });
}
