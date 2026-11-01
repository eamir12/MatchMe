import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/map_utils.dart';

void main() {
  group('googleMapsPlaceUri', () {
    test('uses the place id so maps opens the named place card', () {
      final uri = googleMapsPlaceUri(
        label: 'Yisgav Pharmacy',
        placeId: 'ChIJz7-mM5FJHRURZ4WNlfRb6bA',
        latitude: 32.1098437,
        longitude: 34.8331752,
      );
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/maps/search/');
      expect(uri.queryParameters['api'], '1');
      expect(uri.queryParameters['query'], 'Yisgav Pharmacy');
      expect(
        uri.queryParameters['query_place_id'],
        'ChIJz7-mM5FJHRURZ4WNlfRb6bA',
      );
    });

    test('falls back to a name search anchored at the coordinates', () {
      final uri = googleMapsPlaceUri(
        label: 'גן טל',
        latitude: 32.1,
        longitude: 34.8,
      );
      expect(uri.queryParameters['query'], 'גן טל 32.1,34.8');
      expect(uri.queryParameters.containsKey('query_place_id'), isFalse);
    });

    test('does not invent coordinates for a name-only label', () {
      final uri = googleMapsPlaceUri(label: 'By the fountain');
      expect(uri.queryParameters['query'], 'By the fountain');
    });
  });
}
