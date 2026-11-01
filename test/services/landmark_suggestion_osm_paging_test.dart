import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/services/landmark_suggestion_service.dart';

Map<String, dynamic> _node(
  int id,
  String name,
  int metersNorth,
  Map<String, String> tags,
) => {
  'type': 'node',
  'id': id,
  'lat': 32.0 + metersNorth / 111195.0,
  'lon': 34.0,
  'tags': {'name': name, ...tags},
};

List<Map<String, dynamic>> _ring(int radius, int baseMeters) => [
  _node(radius + 1, 'Park $radius', baseMeters, {'leisure': 'park'}),
  _node(radius + 2, 'Square $radius', baseMeters + 100, {'place': 'square'}),
  _node(radius + 3, 'Market $radius', baseMeters + 200, {
    'shop': 'supermarket',
  }),
];

void main() {
  group('OSM suggestion widening', () {
    test('keeps widening until the full nine-place pool is available', () async {
      var successfulQueries = 0;
      final client = MockClient((request) async {
        if (request.url.host != 'fake.test') {
          throw http.ClientException('offline');
        }
        successfulQueries++;
        final decoded = Uri.decodeComponent(request.body);
        final radius = int.parse(
          RegExp(r'around:(\d+),').firstMatch(decoded)!.group(1)!,
        );
        final elements = switch (radius) {
          900 => _ring(900, 100),
          1600 => _ring(1600, 500),
          _ => _ring(2600, 800),
        };
        return http.Response(jsonEncode({'elements': elements}), 200);
      });

      final service = LandmarkSuggestionService(
        client: client,
        endpoints: const ['https://fake.test/overpass'],
        provider: 'osm',
      );
      final result = await service.suggest(latitude: 32.0, longitude: 34.0);

      expect(successfulQueries, 3);
      expect(result.source, 'osm');
      expect(result.places.length, 3);
      expect(result.pool.length, 6);
      final labels = {
        ...result.places.map((place) => place.label),
        ...result.pool.map((place) => place.label),
      };
      expect(labels.length, 9);
      expect(
        labels,
        containsAll(['Park 900', 'Square 1600', 'Market 2600']),
      );
    });
  });
}
