// test/widgets/desktop_calendar_oauth_routing_test.dart
//
// Regression coverage for which calendar-import OAuth path each platform takes.
//
// The failure this guards against is subtle and was present in production: the
// non-web branches assumed "not web" meant "Android/iOS", so on Windows the
// Google path called GoogleSignIn.authenticate() (no Windows implementation ->
// UnimplementedError) and the Outlook path built an MSAL client from
// AndroidConfig. Both threw. See the platform predicates on CalendarSyncService.

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        debugDefaultTargetPlatformOverride,
        kIsWeb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirrors CalendarSyncService._useLoopbackGoogleOAuth / _useLoopbackOutlookOAuth.
  bool useLoopbackGoogle() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  bool useLoopbackOutlook() {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  setUp(() => debugDefaultTargetPlatformOverride = null);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('Google calendar import routing', () {
    test('uses the loopback flow on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(useLoopbackGoogle(), isTrue);
    });

    test('uses the loopback flow on Linux', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(useLoopbackGoogle(), isTrue);
    });

    test('keeps the native Google SDK on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(useLoopbackGoogle(), isFalse);
    });

    test('keeps the native Google SDK on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(useLoopbackGoogle(), isFalse);
    });

    test('keeps the native Google SDK on macOS', () {
      // google_sign_in has a real macOS implementation, so macOS must not be
      // routed to the loopback flow.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(useLoopbackGoogle(), isFalse);
    });
  });

  group('Outlook calendar import routing', () {
    test('uses the loopback flow on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(useLoopbackOutlook(), isTrue);
    });

    test('uses the loopback flow on Linux', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(useLoopbackOutlook(), isTrue);
    });

    test('uses the loopback flow on macOS', () {
      // The MSAL path is hardcoded to AndroidConfig, so it cannot run on macOS
      // either - it must go through the loopback flow like Windows.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(useLoopbackOutlook(), isTrue);
    });

    test('keeps the native MSAL path on Android only', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(useLoopbackOutlook(), isFalse);
    });

    test('keeps the native MSAL path on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(useLoopbackOutlook(), isFalse);
    });
  });
}
