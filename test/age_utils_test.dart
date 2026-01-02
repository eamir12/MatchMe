import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/time_format_utils.dart';

void main() {
  test('calculateAgeFromDate handles birthday before reference date', () {
    final birth = DateTime(2007, 12, 1);
    final refDate = DateTime(2026, 1, 1);
    final age = calculateAgeFromDate(birth, now: refDate);
    expect(age, 18);
  });

  test('calculateAgeFromDate handles birthday on same day', () {
    final birth = DateTime(2000, 6, 15);
    final refDate = DateTime(2025, 6, 15);
    final age = calculateAgeFromDate(birth, now: refDate);
    expect(age, 25);
  });

  test('calculateAgeFromDate handles birthday after reference date', () {
    final birth = DateTime(1990, 11, 30);
    final refDate = DateTime(2025, 11, 29);
    final age = calculateAgeFromDate(birth, now: refDate);
    expect(age, 34);
  });
}
