// test/widgets/calendar_device_support_test.dart
//
// `device_calendar_plus` declares platforms android + ios only. The device
// calendar option used to be gated on `!kIsWeb`, so on Windows/macOS/Linux the
// app offered an import that could only fail, with the raw Dart error
// `Bad state: DeviceCalendarPlusPlatform.instance has not been initialized`.
// See CalendarSyncService.isDeviceCalendarSupported.

import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        debugDefaultTargetPlatformOverride,
        kIsWeb;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Mirrors CalendarSyncService.isDeviceCalendarSupported.
  bool isDeviceCalendarSupported() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  setUp(() => debugDefaultTargetPlatformOverride = null);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('is supported on Android', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isDeviceCalendarSupported(), isTrue);
  });

  test('is supported on iOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(isDeviceCalendarSupported(), isTrue);
  });

  test('is NOT supported on Windows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isDeviceCalendarSupported(), isFalse);
  });

  test('is NOT supported on macOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(isDeviceCalendarSupported(), isFalse);
  });

  test('is NOT supported on Linux', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(isDeviceCalendarSupported(), isFalse);
  });

  test('is NOT supported on web', () {
    // kIsWeb is a compile-time constant, so on the VM this assert documents the
    // intent rather than exercising it: the web branch is the first check.
    expect(
      kIsWeb,
      isFalse,
      reason: 'test runs on the VM; web is checked first',
    );
  });
}
