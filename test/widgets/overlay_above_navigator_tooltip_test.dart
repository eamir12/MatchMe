// Widgets mounted in the MaterialApp `builder` Stack (lib/main.dart) sit above
// the Navigator, so their subtree has no Overlay ancestor. A Tooltip there —
// including the `tooltip:` argument of an IconButton — throws "No Overlay
// widget found" and replaces the whole screen with the debug error widget, and
// these banners are exactly the surfaces that appear on top of every screen.
// The label belongs on `Icon.semanticLabel` instead.
//
// 1. Widget test — mounts the meet-up bar the way the app does and requires a
//    clean build with an alert visible.
// 2. Source scan — keeps a tooltip out of any banner mounted above the
//    Navigator, and fails if that Stack's contents change so the list below
//    has to be re-read.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/widgets/meetup_alert_overlay.dart';
import 'package:matchme/widgets/system_notification_overlay.dart';

/// Every banner the app builder paints over the Navigator.
const _overlaysAboveNavigator = <String, String>{
  'MeetupAlertOverlay': 'lib/widgets/meetup_alert_overlay.dart',
  'SystemNotificationOverlay': 'lib/widgets/system_notification_overlay.dart',
  'BirthdayOverlay': 'lib/widgets/birthday_overlay.dart',
};

LocalizationState _l10n() => LocalizationState(
  currentLocale: const Locale('en'),
  textDirection: TextDirection.ltr,
  strings: const {
    'systemNotificationDismiss': 'Dismiss',
    'generalClose': 'Close',
    'meetupOpen': 'Open',
    'meetupGestureIncomingBody': 'Open the chat to see where to look.',
  },
  supportedLanguages: const [],
);

class _SeededAlerts extends MeetupAlertsNotifier {
  @override
  MeetupAlertsState build() => MeetupAlertsState(
    alerts: [
      MeetupAlert(
        id: 'alert-1',
        // Empty, so the bar keeps its inbox title instead of reaching for the
        // chat list, which would need an initialised Supabase client.
        matchId: '',
        senderId: 'partner-1',
        kind: kMeetupAlertSignal,
        gesture: 'arms_wide',
        title: 'First L. has both arms up to find you',
        body: '',
        createdAt: DateTime(2026, 11, 1, 15, 27),
        expiresAt: DateTime(2026, 11, 1, 15, 28),
      ),
    ],
    now: DateTime(2026, 11, 1, 15, 27, 30),
  );
}

class _SeededPinnedBanner extends SystemNotificationNotifier {
  @override
  SystemNotification? build() => SystemNotification(
    text: 'Your pinned base is about to expire',
    notificationType: 'pinned_location',
    actionUrl: 'https://example.invalid',
    actionText: 'Manage',
  );
}

void main() {
  testWidgets('meet-up bar renders above the Navigator without an Overlay', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(_l10n()),
          meetupAlertsProvider.overrideWith(_SeededAlerts.new),
        ],
        child: MaterialApp(
          builder: (context, child) => Stack(
            children: [
              child!,
              const Positioned(
                left: 8,
                right: 8,
                top: 4,
                child: MeetupAlertOverlay(),
              ),
            ],
          ),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('First L. has both arms up to find you'), findsOneWidget);

    final close = tester.widget<Icon>(find.byIcon(Icons.close));
    expect(close.semanticLabel, 'Dismiss');
    expect(
      find.byWidgetPredicate((w) => w is Tooltip),
      findsNothing,
      reason: 'A Tooltip above the Navigator throws and reddens the screen.',
    );
  });

  testWidgets('a banner action that needs an Overlay is a no-op, not a crash', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(_l10n()),
          systemNotificationProvider.overrideWith(_SeededPinnedBanner.new),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              Stack(children: [child!, const SystemNotificationOverlay()]),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The fixture has to mirror production: this subtree sits above the
    // Navigator, so anything that resolves an Overlay or Navigator from it
    // throws. `navigatorKey` is deliberately unset, as it is before the first
    // route exists.
    expect(
      Overlay.maybeOf(
        tester.element(find.text('Your pinned base is about to expire')),
      ),
      isNull,
    );

    await tester.tap(find.text('Manage'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.takeException(),
      isNull,
      reason:
          'The Manage action used to pass this subtree context to a modal '
          'sheet, which threw "No Overlay widget found" and reddened the app.',
    );
  });

  testWidgets('the meet-up bar dismiss control needs no Overlay', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(_l10n()),
          meetupAlertsProvider.overrideWith(_SeededAlerts.new),
        ],
        child: MaterialApp(
          builder: (context, child) => Stack(
            children: [
              child!,
              const Positioned(
                left: 8,
                right: 8,
                top: 4,
                child: MeetupAlertOverlay(),
              ),
            ],
          ),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final close = find.descendant(
      of: find.byType(MeetupAlertOverlay),
      matching: find.byIcon(Icons.close),
    );
    expect(Overlay.maybeOf(tester.element(close)), isNull);

    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  group('source scan: no Tooltip in a banner above the Navigator', () {
    late String builderRegion;

    setUpAll(() {
      final main = File('lib/main.dart').readAsStringSync();
      final start = main.indexOf('builder: (context, child)');
      final end = main.indexOf('theme: AppThemeTokens', start);
      expect(
        start,
        greaterThan(-1),
        reason: 'builder region moved in main.dart',
      );
      expect(
        end,
        greaterThan(start),
        reason: 'builder region end moved in main.dart',
      );
      builderRegion = main.substring(start, end);
    });

    test('the Stack still mounts exactly the listed banners', () {
      for (final entry in _overlaysAboveNavigator.entries) {
        expect(
          builderRegion,
          contains(entry.key),
          reason:
              '$entry.key is no longer mounted above the Navigator; '
              're-read this guard before changing the list.',
        );
      }
    });

    test('none of them builds a Tooltip', () {
      final offenders = <String>[];

      for (final path in _overlaysAboveNavigator.values) {
        final lines = File(path).readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (RegExp(r'(?<!\w)Tooltip\(').hasMatch(line) ||
              RegExp(r'(?<![A-Za-z])tooltip:').hasMatch(line)) {
            offenders.add('$path:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
