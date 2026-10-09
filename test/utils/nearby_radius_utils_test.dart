import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/nearby_radius_utils.dart';

void main() {
  test('uses the selected profile radius instead of the app default', () {
    const configuredRadiusMeters = 100;
    const selectedRadiusMeters = 5;

    final resolvedMeters = resolveNearbyRadiusMeters(
      configuredRadiusMeters,
      selectedRadiusMeters,
    );

    expect(resolvedMeters, selectedRadiusMeters);
    expect(nearbyRadiusKilometers(resolvedMeters), 0.005);
  });

  test(
    'falls back to configured radius when profile radius is unavailable',
    () {
      expect(resolveNearbyRadiusMeters(100, null), 100);
      expect(resolveNearbyRadiusMeters(100, '5'), 100);
    },
  );

  test('supports numeric radius values returned by the API', () {
    expect(resolveNearbyRadiusMeters(100, 5.0), 5);
  });
}
