import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/nearby_map_counts.dart';

void main() {
  group('nearbyUsersPlottedOnMap', () {
    test('sums the users in every plotted cell', () {
      final cells = [
        const NearbyMapCell(lat: 32.1, lng: 34.8, count: 3),
        const NearbyMapCell(lat: 32.2, lng: 34.9, count: 1),
        const NearbyMapCell(lat: 32.3, lng: 35.0, count: 12),
      ];

      expect(nearbyUsersPlottedOnMap(cells), 16);
    });

    test('is zero when the map plots nothing', () {
      expect(nearbyUsersPlottedOnMap(const <NearbyMapCell>[]), 0);
    });

    test('counts a single user cell as one user', () {
      const cells = [NearbyMapCell(lat: 32.1, lng: 34.8, count: 1)];

      expect(nearbyUsersPlottedOnMap(cells), 1);
    });
  });

  test('the "Showing about N users" pill states the number of plotted users', () {
    final l10n = LocalizationState.loading();
    const cells = [
      NearbyMapCell(lat: 32.1, lng: 34.8, count: 1),
      NearbyMapCell(lat: 32.2, lng: 34.9, count: 2),
    ];

    final pill = l10n.getString(
      'mapShowingApproxUsers',
      params: {'count': nearbyUsersPlottedOnMap(cells).toString()},
    );

    expect(pill, 'Showing about 3 users');
  });
}
