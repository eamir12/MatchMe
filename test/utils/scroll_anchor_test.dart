import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/scroll_anchor.dart';

/// The same shape as the Home screen: the block that can appear/disappear
/// lives in a sliver ahead of the lazy list, not inside the list itself.
///
/// A sliver before the list is laid out on every frame, so its height stays
/// accurate wherever the list is scrolled to.
Widget buildList({
  required ScrollController controller,
  required bool showBlock,
  required GlobalKey anchorKey,
  double blockHeight = 100,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        controller: controller,
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(key: ValueKey('header'), height: 100),
                if (showBlock)
                  SizedBox(
                    key: const ValueKey('block'),
                    height: blockHeight,
                  ),
              ],
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              SizedBox(key: anchorKey, height: 100),
              for (int i = 0; i < 40; i++)
                SizedBox(key: ValueKey('item$i'), height: 100),
            ]),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets(
    'keeps the visible rows in place when the block above the viewport is removed',
    (tester) async {
      final controller = ScrollController();
      final anchor = ScrollAnchor();
      final anchorKey = GlobalKey();

      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: true,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();
      anchor.setBlockHeight(100);

      // Put the anchor row inside the viewport.
      controller.jumpTo(150);
      await tester.pumpAndSettle();
      final topBefore = tester.getTopLeft(find.byKey(anchorKey)).dy;

      anchor.anchor(
        controller: controller,
        wasPresent: true,
        willBePresent: false,
      );
      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: false,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(anchorKey)).dy,
        moreOrLessEquals(topBefore, epsilon: 0.5),
      );
    },
  );

  testWidgets(
    'keeps the visible rows in place when the block above the viewport is added',
    (tester) async {
      final controller = ScrollController();
      final anchor = ScrollAnchor();
      final anchorKey = GlobalKey();

      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: false,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();
      anchor.setBlockHeight(100);

      controller.jumpTo(150);
      await tester.pumpAndSettle();
      final topBefore = tester.getTopLeft(find.byKey(anchorKey)).dy;

      anchor.anchor(
        controller: controller,
        wasPresent: false,
        willBePresent: true,
      );
      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: true,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(anchorKey)).dy,
        moreOrLessEquals(topBefore, epsilon: 0.5),
      );
    },
  );

  testWidgets(
    'compensates a block that is far above the materialised range',
    (tester) async {
      final controller = ScrollController();
      final anchor = ScrollAnchor();
      final anchorKey = GlobalKey();

      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: true,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();
      anchor.setBlockHeight(100);

      // Scroll far enough that the block above the viewport is no longer
      // laid out (outside the cache extent). This is the case that a plain
      // ListView child can never compensate, because the list keeps the
      // stored offset of its materialised children.
      controller.jumpTo(1500);
      await tester.pumpAndSettle();
      final visible = find.byKey(const ValueKey('item15'));
      final topBefore = tester.getTopLeft(visible).dy;

      anchor.anchor(
        controller: controller,
        wasPresent: true,
        willBePresent: false,
      );
      await tester.pumpWidget(
        buildList(
          controller: controller,
          showBlock: false,
          anchorKey: anchorKey,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(visible).dy,
        moreOrLessEquals(topBefore, epsilon: 0.5),
      );
      expect(controller.offset, moreOrLessEquals(1400, epsilon: 0.5));
    },
  );

  testWidgets('the offset is corrected even when the list is at its very end', (
    tester,
  ) async {
    final controller = ScrollController();
    final anchor = ScrollAnchor();
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      buildList(controller: controller, showBlock: false, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();
    anchor.setBlockHeight(100);

    // Sit at the very end of the list: the new offset is outside the
    // current scroll range and can only be applied after the next layout.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final offsetBefore = controller.offset;

    anchor.anchor(
      controller: controller,
      wasPresent: false,
      willBePresent: true,
    );
    await tester.pumpWidget(
      buildList(controller: controller, showBlock: true, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      moreOrLessEquals(offsetBefore + 100, epsilon: 0.5),
    );
  });

  testWidgets('a failed prediction is reconciled after the rebuild', (
    tester,
  ) async {
    final controller = ScrollController();
    final anchor = ScrollAnchor();
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      buildList(controller: controller, showBlock: false, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();
    anchor.setBlockHeight(100);

    controller.jumpTo(150);
    await tester.pumpAndSettle();
    final topBefore = tester.getTopLeft(find.byKey(anchorKey)).dy;

    // The block was predicted to appear, but the change was overruled and
    // the list was rebuilt without it.
    anchor.anchor(
      controller: controller,
      wasPresent: false,
      willBePresent: true,
    );
    anchor.reconcile(
      controller: controller,
      wasPresent: true,
      willBePresent: false,
    );
    await tester.pumpWidget(
      buildList(controller: controller, showBlock: false, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(anchorKey)).dy,
      moreOrLessEquals(topBefore, epsilon: 0.5),
    );
  });

  testWidgets('without a measured height the offset is left alone', (
    tester,
  ) async {
    final controller = ScrollController();
    final anchor = ScrollAnchor();
    final anchorKey = GlobalKey();

    await tester.pumpWidget(
      buildList(controller: controller, showBlock: false, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();

    controller.jumpTo(150);
    await tester.pumpAndSettle();
    final offsetBefore = controller.offset;

    anchor.anchor(
      controller: controller,
      wasPresent: false,
      willBePresent: true,
    );
    await tester.pumpWidget(
      buildList(controller: controller, showBlock: true, anchorKey: anchorKey),
    );
    await tester.pumpAndSettle();

    expect(controller.offset, offsetBefore);
  });
}
