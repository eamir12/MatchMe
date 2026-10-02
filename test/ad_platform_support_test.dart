// test/ad_platform_support_test.dart
//
// Two ad bugs met here:
//
//  1. interstitial_ad_widget and rewarded_ad_widget hardcoded
//     `return 'web';` behind a literal `// TODO: Implement platform detection`,
//     so they requested the *web* ad placement even on Android and iOS.
//
//  2. The banner widget discovered at runtime that no ad SDK exists on desktop:
//     BannerAd.load() failed, errorCode == 0 flipped a static "ad service
//     unavailable" flag, and the slot silently rendered nothing - while the
//     provider kept fetching, because the backend's allowed_platforms default
//     includes 'web' and the old desktop fallback produced exactly that key.

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/ad_platform_support.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    resetAdPlatformSupportLogForTesting();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('adPlatformKey', () {
    test('reports android on Android - the interstitials/rewarded bug', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(adPlatformKey(), 'android');
    });

    test('reports ios on iOS - the interstitials/rewarded bug', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(adPlatformKey(), 'ios');
    });

    test('never claims web for a desktop platform', () {
      // The old fallback returned 'web' here, so desktop fetched web creatives
      // it could not render.
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          adPlatformKey(),
          'desktop',
          reason: '${platform.name} must not request the web placement',
        );
      }
    });
  });

  group('isAdRenderSupported', () {
    test('is true on the platforms google_mobile_ads implements', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          isAdRenderSupported,
          isTrue,
          reason: 'google_mobile_ads implements ${platform.name}',
        );
      }
    });

    test('is false on desktop, where the plugin is not registered', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          isAdRenderSupported,
          isFalse,
          reason: 'no google_mobile_ads implementation for ${platform.name}',
        );
      }
    });
  });

  test('platforms without an SDK are also not fetchable', () {
    // The fetch gate and the render gate must agree, otherwise the app keeps
    // paying for creatives it will never show.
    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(isAdRenderSupported, isFalse);
      expect(adPlatformKey(), 'desktop');
    }
  });
}
