import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/widgets/pinned_location_sheet.dart';

void main() {
  test('extension choices stay within the 14-day cumulative maximum', () {
    final createdAt = DateTime.utc(2026, 1, 1);
    final pin = PinnedLocationState(
      isActive: true,
      createdAt: createdAt,
      expiresAt: createdAt.add(const Duration(days: 10)),
    );

    expect(pinnedExtensionDurations(pin), const [
      Duration(hours: 24),
      Duration(days: 3),
    ]);
  });

  test('no extension choices remain once total duration reaches 14 days', () {
    final createdAt = DateTime.utc(2026, 1, 1);
    final pin = PinnedLocationState(
      isActive: true,
      createdAt: createdAt,
      expiresAt: createdAt.add(const Duration(days: 14)),
    );

    expect(pinnedExtensionDurations(pin), isEmpty);
  });

  test('unknown pin creation time does not allow unbounded extension', () {
    final pin = PinnedLocationState(
      isActive: true,
      expiresAt: DateTime.utc(2026, 1, 10),
    );

    expect(pinnedExtensionDurations(pin), isEmpty);
  });
}
