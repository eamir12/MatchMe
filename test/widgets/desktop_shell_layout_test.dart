// test/widgets/desktop_shell_layout_test.dart
//
// Regression coverage for the desktop shell layout.
//
// The rail used to be wrapped in a `Flexible`, whose default `FlexFit.loose`
// still hands NavigationRail its flex share as a *maxWidth*. NavigationRail's
// internal Align then stretched the destinations' background across that whole
// width, so on a 1920px window the icons landed in the middle and ~450px on the
// left rendered empty while the content was squeezed to half the window.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/widgets/custom_app_bar.dart';

/// Mirrors the rail/content structure in `MainNavigationScreen.build`.
Widget _shell({
  required Widget rail,
  required Widget content,
  bool useRail = true,
}) {
  return Scaffold(
    body: Row(
      children: [
        if (useRail)
          SizedBox(width: 88, child: SafeArea(right: false, child: rail))
        else
          const SizedBox.shrink(),
        Expanded(child: content),
      ],
    ),
  );
}

NavigationRail _buildRail() {
  return NavigationRail(
    selectedIndex: 0,
    labelType: NavigationRailLabelType.all,
    // Mirrors `_MainNavRail`: top-aligned so Home starts at the top.
    groupAlignment: -1.0,
    minWidth: 88,
    destinations: [
      NavigationRailDestination(
        icon: Icon(Icons.home_outlined),
        label: Text('Home'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.people_outline),
        label: Text('Matches'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.chat_bubble_outline),
        label: Text('Chats'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.calendar_today_outlined),
        label: Text('Events'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.person_outline),
        label: Text('Profile'),
      ),
    ],
  );
}

/// Mirrors `_CompactRail` in `main_navigation_screen.dart`: labeled buttons
/// sharing the body height exactly (Expanded) so all five fit with no sliding.
Widget _buildCompactRail({ValueChanged<String>? onTap}) {
  const entries = [
    (Icons.home_outlined, 'Home'),
    (Icons.people_outline, 'Matches'),
    (Icons.chat_bubble_outline, 'Chats'),
    (Icons.calendar_today_outlined, 'Events'),
    (Icons.person_outline, 'Profile'),
  ];
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (icon, label) in entries)
        Expanded(
          child: Tooltip(
            message: label,
            // InkWell mirrors `_CompactRail`: it requires a Material
            // ancestor, which is exactly what regressed when the rail moved
            // outside the Scaffold.
            child: InkWell(
              onTap: () => onTap?.call(label),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, size: 20),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, height: 1.1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('rail keeps its fixed width and content takes the rest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const contentKey = ValueKey('content');
    await tester.pumpWidget(
      MaterialApp(
        home: _shell(
          rail: _buildRail(),
          content: const ColoredBox(key: contentKey, color: Colors.white),
        ),
      ),
    );

    final railRect = tester.getRect(find.byType(NavigationRail));
    final contentRect = tester.getRect(find.byKey(contentKey));

    expect(railRect.width, 88);
    expect(contentRect.left, 88);
    expect(contentRect.width, 1920 - 88);
    // The bug: the rail's painted background ballooned to half the window, so
    // the destinations sat nowhere near the leading edge.
    expect(railRect.left, 0);
  });

  testWidgets('content stays mounted when switching orientation layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var count = 0;
    Widget content() => StatefulBuilder(
      builder: (context, setState) => TextButton(
        onPressed: () => setState(() => count++),
        child: Text('content $count'),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: _shell(rail: _buildRail(), content: content(), useRail: false),
      ),
    );
    await tester.tap(find.text('content 0'));
    await tester.pump();
    expect(find.text('content 1'), findsOneWidget);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpWidget(
      MaterialApp(
        home: _shell(rail: _buildRail(), content: content()),
      ),
    );
    await tester.pump();
    expect(find.text('content 1'), findsOneWidget);

    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(
      MaterialApp(
        home: _shell(rail: _buildRail(), content: content(), useRail: false),
      ),
    );
    await tester.pump();
    expect(find.text('content 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rail does not inflate to its flex share (loose Flexible bug)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // This is the old structure, kept here to document the failure mode: the
    // loose Flexible still gives NavigationRail maxWidth 960, and the rail
    // stretches to fill it.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Flexible(child: _buildRail()),
              const Expanded(child: ColoredBox(color: Colors.white)),
            ],
          ),
        ),
      ),
    );

    expect(tester.getRect(find.byType(NavigationRail)).width, greaterThan(88));
  });

  testWidgets('all five rail destinations stay inside the rail width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: _shell(rail: _buildRail(), content: const SizedBox.shrink()),
      ),
    );

    final railRect = tester.getRect(find.byType(NavigationRail));
    for (final label in ['Home', 'Matches', 'Chats', 'Events', 'Profile']) {
      final rect = tester.getRect(find.text(label));
      expect(
        rect.left,
        greaterThanOrEqualTo(railRect.left - 0.5),
        reason: '$label overflows left',
      );
      expect(
        rect.right,
        lessThanOrEqualTo(railRect.right + 0.5),
        reason: '$label overflows right',
      );
    }
  });

  group('landscape rail (short viewport)', () {
    /// Mirrors the rail pane in `MainNavigationScreen.build`: fixed 88px
    /// width, own Material (it is a sibling of the content Scaffold, not its
    /// child), SafeArea, then either the compact labeled rail (heights under
    /// 520px, sharing the height exactly) or the full labeled rail with a
    /// scroll safety net (tall bodies).
    Widget adaptiveRail() {
      return SizedBox(
        width: 88,
        child: Material(
          child: SafeArea(
            right: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final bodyHeight = constraints.maxHeight;
                if (bodyHeight < 520) return _buildCompactRail();
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: bodyHeight),
                    child: IntrinsicHeight(child: _buildRail()),
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    testWidgets('compact rail works as a Scaffold sibling (has Material)', (
      tester,
    ) async {
      // Regression test: moving the rail out of the Scaffold body removed its
      // Material ancestor and every InkWell threw on first build. The rail
      // pane must bring its own Material, verified here by tapping.
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var tapped = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              SizedBox(
                width: 88,
                child: Material(
                  child: _buildCompactRail(onTap: (label) => tapped = label),
                ),
              ),
              const Expanded(
                child: Scaffold(body: SizedBox.shrink()),
              ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Home'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tapped, 'Home');
    });

    testWidgets('compact rail shows all five names with no sliding', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(
            rail: adaptiveRail(),
            content: const SizedBox.shrink(),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      // Compact rail keeps every icon AND name visible at once.
      for (final label in ['Home', 'Matches', 'Chats', 'Events', 'Profile']) {
        expect(find.text(label), findsOneWidget);
      }
      // Nothing may hang outside the 360px-tall viewport: the last button
      // must end inside it, so no sliding is needed to see anything.
      final profileRect = tester.getRect(find.text('Profile'));
      expect(profileRect.bottom, lessThanOrEqualTo(360));
      expect(profileRect.top, greaterThanOrEqualTo(0));
      // And the first button starts at the top, right below where the app-bar
      // logo would be - no block of white space above Home.
      final homeRect = tester.getRect(find.text('Home'));
      expect(homeRect.top, lessThan(100));
    });

    testWidgets('compact rail fits a landscape phone viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(
            rail: adaptiveRail(),
            content: const SizedBox.shrink(),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      for (final label in ['Home', 'Matches', 'Chats', 'Events', 'Profile']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(
        tester.getRect(find.text('Profile')).bottom,
        lessThanOrEqualTo(360),
      );
    });

    testWidgets('full rail is top-aligned, not centred', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: _shell(rail: _buildRail(), content: const SizedBox.shrink()),
        ),
      );

      // Top-aligned: Home sits near the top, not pushed down by centring.
      expect(tester.getRect(find.text('Home')).top, lessThan(150));
    });
  });

  group('app bar centre strip', () {
    Future<void> pumpAppBar(
      WidgetTester tester, {
      required double leadingInset,
      required double bannerWidth,
    }) async {
      const bannerKey = ValueKey('banner');
      await tester.pumpWidget(
        MaterialApp(
          home: _AppBarHost(
            leadingInset: leadingInset,
            bannerKey: bannerKey,
            bannerWidth: bannerWidth,
          ),
        ),
      );
    }

    testWidgets('is centred on the content column, not the window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpAppBar(tester, leadingInset: 88, bannerWidth: 200);

      // Content column runs 88..1920, so its centre is (88 + 1920) / 2 = 1004.
      // The window centre is 960 - the 44px misalignment the inset exists to fix.
      expect(
        tester.getRect(find.byKey(const ValueKey('banner'))).center.dx,
        closeTo(1004, 1),
      );
    });

    testWidgets('centres on the window when there is no rail', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpAppBar(tester, leadingInset: 0, bannerWidth: 200);

      expect(
        tester.getRect(find.byKey(const ValueKey('banner'))).center.dx,
        closeTo(960, 1),
      );
    });

    testWidgets('does not overflow a narrow window', (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpAppBar(tester, leadingInset: 88, bannerWidth: 120);

      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byKey(const ValueKey('banner'))).width, 120);
    });
  });
}

class _AppBarHost extends StatelessWidget {
  const _AppBarHost({
    required this.leadingInset,
    required this.bannerKey,
    required this.bannerWidth,
  });

  final double leadingInset;
  final Key bannerKey;
  final double bannerWidth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildCustomAppBar(
        context,
        _l10n(),
        'Home',
        const [],
        onHomePressed: () {},
        centerStripLeadingInset: leadingInset,
        centerWidget: SizedBox(key: bannerKey, width: bannerWidth, height: 24),
      ),
      body: const SizedBox.shrink(),
    );
  }
}

LocalizationState _l10n() => LocalizationState(
  currentLocale: const Locale('en'),
  textDirection: TextDirection.ltr,
  strings: const {},
  supportedLanguages: const [],
);
