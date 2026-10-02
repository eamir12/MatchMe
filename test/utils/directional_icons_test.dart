import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/directional_icons.dart';

/// "Go deeper" affordances must point forward in every language.
///
/// Flutter's chevron / arrow_ios glyphs carry `matchTextDirection: true`, so
/// `Icon` mirrors `chevron_right` to point left automatically in RTL
/// (Hebrew/Arabic). Manually returning the `_left` / `_back` glyph in RTL
/// mirrors twice and points right in a Hebrew UI — the bug these helpers
/// exist to prevent. They therefore always return the LTR-forward glyph and
/// let the framework mirror at paint time.
void main() {
  Future<IconData> chevronFor(
    WidgetTester tester,
    TextDirection direction,
    IconData Function(BuildContext) resolve,
  ) async {
    late IconData result;
    await tester.pumpWidget(
      Directionality(
        textDirection: direction,
        child: Builder(
          builder: (context) {
            result = resolve(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  testWidgets('chevron points right in LTR', (tester) async {
    expect(
      await chevronFor(tester, TextDirection.ltr, directionalChevron),
      Icons.chevron_right,
    );
    expect(
      await chevronFor(tester, TextDirection.ltr, directionalChevronRounded),
      Icons.chevron_right_rounded,
    );
  });

  testWidgets('chevron returns the auto-mirroring glyph in RTL', (tester) async {
    // Returns chevron_right in RTL too: Icon mirrors it to point left.
    // Returning chevron_left here would double-mirror to point right.
    expect(Icons.chevron_right.matchTextDirection, isTrue);
    expect(Icons.chevron_right_rounded.matchTextDirection, isTrue);
    expect(
      await chevronFor(tester, TextDirection.rtl, directionalChevron),
      Icons.chevron_right,
    );
    expect(
      await chevronFor(tester, TextDirection.rtl, directionalChevronRounded),
      Icons.chevron_right_rounded,
    );
  });

  testWidgets('iOS arrow returns the auto-mirroring glyph in RTL', (tester) async {
    // Icons.arrow_forward_ios carries matchTextDirection, so it paints left
    // in RTL on its own; returning arrow_back_ios would double-mirror.
    expect(Icons.arrow_forward_ios.matchTextDirection, isTrue);
    expect(
      await chevronFor(tester, TextDirection.ltr, directionalForwardIos),
      Icons.arrow_forward_ios,
    );
    expect(
      await chevronFor(tester, TextDirection.rtl, directionalForwardIos),
      Icons.arrow_forward_ios,
    );
  });

  testWidgets('isRtlContext reports the ambient direction', (tester) async {
    Future<bool> read(TextDirection direction) async {
      late bool result;
      await tester.pumpWidget(
        Directionality(
          textDirection: direction,
          child: Builder(
            builder: (context) {
              result = isRtlContext(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return result;
    }

    expect(await read(TextDirection.ltr), isFalse);
    expect(await read(TextDirection.rtl), isTrue);
  });
}
