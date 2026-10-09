import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression test for the native-invisible pin bug.
///
/// The legacy SharedPreferences Dart API prepends 'flutter.' to every key
/// argument, so pre-migration builds (whose constants were already
/// 'flutter.'-prefixed) stored the pin under double-prefixed RAW keys
/// ('flutter.flutter.…') that native Android/iOS never read. The gate now
/// uses unprefixed constants (raw single-prefixed keys, exactly what native
/// reads) and migrates legacy rows on first read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  int futureMs() =>
      DateTime.now().toUtc().millisecondsSinceEpoch +
      const Duration(days: 7).inMilliseconds;

  test(
    'legacy double-prefixed pin is adopted and re-stored natively visible',
    () async {
      // Simulate the exact on-disk layout of a pre-migration build: raw keys
      // carry the double prefix (setMockInitialValues seeds the raw store).
      SharedPreferences.setMockInitialValues({
        'flutter.flutter.pinned_location_active': true,
        'flutter.flutter.pinned_location_expires_at_ms': futureMs(),
        'flutter.flutter.pinned_location_label': 'Home',
      });

      // Migration adopts the legacy pin.
      expect(await PinnedLocationGate.isActive(), isTrue);

      // The pin is now stored under raw single-prefixed keys — precisely what
      // native Android (FlutterSharedPreferences XML) and iOS (UserDefaults)
      // read. Read here with UNPREFIXED args, which resolve to those raw keys.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('pinned_location_active'), isTrue);
      expect(prefs.getInt('pinned_location_expires_at_ms'), isNotNull);
      expect(prefs.getString('pinned_location_label'), 'Home');

      // Legacy rows are gone and can never resurrect the pin.
      expect(prefs.getBool('flutter.pinned_location_active'), isNot(true));
      expect(await PinnedLocationGate.isActive(), isTrue);

      // Clearing removes the pin from every layout.
      await PinnedLocationGate.clearPinCache();
      expect(await PinnedLocationGate.isActive(), isFalse);
      expect(prefs.getBool('pinned_location_active'), isNot(true));
    },
  );

  test('fresh pin round-trips and expiry self-clears', () async {
    await PinnedLocationGate.writePinCache(
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      label: 'Base',
    );
    expect(await PinnedLocationGate.isActive(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('pinned_location_active'), isTrue);
    expect(prefs.getString('pinned_location_label'), 'Base');

    await PinnedLocationGate.writePinCache(
      expiresAt: DateTime.now().toUtc().subtract(const Duration(seconds: 1)),
    );
    expect(await PinnedLocationGate.isActive(), isFalse);
    expect(prefs.getBool('pinned_location_active'), isNot(true));
  });

  test(
    'offline pin intent persists for its owning user and can be cleared',
    () async {
      SharedPreferences.setMockInitialValues({});
      final expiry = DateTime.now().toUtc().add(const Duration(days: 7));

      await PinnedLocationGate.writePendingPin(
        userId: 'user-1',
        expiresAt: expiry,
        label: 'Home',
      );

      final pending = await PinnedLocationGate.readPendingPin();
      expect(pending?.userId, 'user-1');
      expect(pending?.label, 'Home');
      expect(pending?.expiresAt, expiry);

      await PinnedLocationGate.clearPendingPin();
      expect(await PinnedLocationGate.readPendingPin(), isNull);
    },
  );

  test('extending a pending offline pin keeps it as a pin request', () async {
    SharedPreferences.setMockInitialValues({});
    final originalExpiry = DateTime.now().toUtc().add(const Duration(days: 3));
    final extendedExpiry = originalExpiry.add(const Duration(days: 7));

    await PinnedLocationGate.writePendingPin(
      userId: 'user-1',
      expiresAt: originalExpiry,
      label: 'Home',
    );
    await PinnedLocationGate.writePendingExtension(
      userId: 'user-1',
      expiresAt: extendedExpiry,
      extra: const Duration(days: 7),
      label: 'Home',
    );

    final pending = await PinnedLocationGate.readPendingPin();
    expect(pending?.action, 'pin');
    expect(pending?.expiresAt, extendedExpiry);
  });

  test('offline duration change persists as an idempotent extension target',
      () async {
    SharedPreferences.setMockInitialValues({});
    final initialExpiry = DateTime.now().toUtc().add(const Duration(days: 3));
    final targetExpiry = initialExpiry.add(const Duration(days: 7));

    await PinnedLocationGate.writePendingExtension(
      userId: 'user-1',
      expiresAt: targetExpiry,
      extra: const Duration(days: 7),
      label: 'Home',
    );

    final pending = await PinnedLocationGate.readPendingPin();
    expect(pending?.action, 'extend');
    expect(pending?.userId, 'user-1');
    expect(pending?.expiresAt, targetExpiry);
    expect(pending?.extraSeconds, const Duration(days: 7).inSeconds);
    expect(pending?.label, 'Home');

    await PinnedLocationGate.writePendingExtension(
      userId: 'user-1',
      expiresAt: targetExpiry.add(const Duration(days: 3)),
      extra: const Duration(days: 3),
      label: 'Home',
    );
    final updated = await PinnedLocationGate.readPendingPin();
    expect(updated?.extraSeconds, const Duration(days: 10).inSeconds);
    expect(
      updated?.expiresAt,
      targetExpiry.add(const Duration(days: 3)),
    );
  });
}
