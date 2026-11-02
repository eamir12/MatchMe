// The in-app notification banner is mounted above the Navigator (MaterialApp
// `builder` in lib/main.dart), so its subtree has no Overlay ancestor. A
// Tooltip there throws "No Overlay widget found" and replaces the screen with
// the debug error widget. This test mounts the overlay exactly like the app
// does and requires a clean build with the notification visible.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/widgets/system_notification_overlay.dart';

class _SeededNotifications extends SystemNotificationNotifier {
  @override
  SystemNotification? build() => SystemNotification(
    text: 'Pinned home base updated',
    notificationType: 'pinned_location',
    actionUrl: 'https://example.invalid',
    actionText: 'Manage',
  );
}

LocalizationState _l10n() => LocalizationState(
  currentLocale: const Locale('en'),
  textDirection: TextDirection.ltr,
  strings: const {'generalClose': 'Close', 'open': 'Open'},
  supportedLanguages: const [],
);

void main() {
  testWidgets('banner renders above the Navigator without an Overlay', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localizationProvider.overrideWithValue(_l10n()),
          systemNotificationProvider.overrideWith(_SeededNotifications.new),
        ],
        child: MaterialApp(
          builder: (context, child) =>
              Stack(children: [child!, const SystemNotificationOverlay()]),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Pinned home base updated'), findsOneWidget);

    final close = tester.widget<Icon>(find.byIcon(Icons.close));
    expect(close.semanticLabel, 'Close');
  });
}
