// lib/services/ad_platform_support.dart
//
// Single source of truth for "which ad platform is this?" and "can we actually
// render an ad here?".
//
// Two separate concerns were previously conflated and duplicated across the ad
// widgets:
//
//  1. The platform key sent to `get_external_ad_for_placement`. Two widgets
//     hardcoded 'web' behind a literal `// TODO: Implement platform detection`,
//     so interstitials and rewarded ads requested the *web* placement even on
//     Android and iOS.
//
//  2. Whether an ad SDK exists at all. `google_mobile_ads` ships Android, iOS
//     and web implementations only - there is no Windows, macOS or Linux
//     implementation, so it is absent from those platforms' plugin registrants.
//     The banner widget used to discover this at runtime: `BannerAd.load()`
//     failed, `errorCode == 0` flipped a static "ad service unavailable" flag,
//     and the slot silently rendered nothing. Meanwhile the provider kept
//     fetching, because the backend's `ads.external.allowed_platforms`
//     (default `["android","ios","web"]`) happily accepted the 'web' key the
//     desktop fallback produced - so desktop paid for RPCs and cache churn to
//     retrieve creatives it could never show.

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;

/// The ad platform key sent to the backend.
///
/// `desktop` is deliberately distinct from `web`: no ad SDK exists for Windows,
/// macOS or Linux, so those platforms must not be served web creatives. The
/// backend's allow-list does not contain `desktop`, so it returns nothing -
/// which is the correct outcome. Do not add `desktop` to
/// `ads.external.allowed_platforms`.
String adPlatformKey() {
  if (kIsWeb) return 'web';
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'android';
    case TargetPlatform.iOS:
      return 'ios';
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return 'desktop';
  }
}

/// Whether an ad SDK is registered for this platform.
///
/// False on Windows, macOS and Linux: `google_mobile_ads` has no implementation
/// there, so any attempt to load a creative fails. Callers should skip both the
/// fetch and the render rather than discovering the absence at runtime.
bool get isAdRenderSupported {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

bool _loggedUnsupported = false;

/// Logs, once per run, that ads are being skipped and why. Without this the
/// behaviour is indistinguishable from "ads are broken" - the failure mode that
/// made the missing desktop SDK so hard to spot.
void logAdPlatformSupportOnce() {
  if (_loggedUnsupported || isAdRenderSupported) return;
  _loggedUnsupported = true;
  debugPrint(
    '[Ads] No ad SDK for ${defaultTargetPlatform.name}: google_mobile_ads '
    'implements Android, iOS and web only. Skipping ad fetch and render. '
    'Monetising desktop needs a different network (e.g. Microsoft Monetize), '
    'which has no Flutter SDK.',
  );
}

/// Test seam: forget that the unsupported-platform notice was already logged.
void resetAdPlatformSupportLogForTesting() {
  _loggedUnsupported = false;
}
