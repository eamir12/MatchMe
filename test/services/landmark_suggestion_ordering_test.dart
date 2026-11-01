import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/services/landmark_suggestion_service.dart';

MeetupPlaceSuggestion _place(String label, int distanceMeters) =>
    MeetupPlaceSuggestion(
      label: label,
      category: 'park',
      latitude: 32.0,
      longitude: 34.0,
      distanceMeters: distanceMeters,
    );

List<MeetupPlaceSuggestion> _pool() => [
  for (var i = 0; i < 9; i++) _place('place $i', 50 + i * 50),
];

void main() {
  group('weighted suggestion ordering', () {
    test('keeps every place exactly once', () {
      final places = _pool();
      final ordered = LandmarkSuggestionService.weightedOrder(
        places,
        math.Random(7),
      );

      expect(ordered.length, places.length);
      expect(
        ordered.map((place) => place.label).toSet(),
        places.map((place) => place.label).toSet(),
      );
    });

    test('offers nearer places first more often than far ones', () {
      final places = _pool();
      final random = math.Random(7);
      final firstPageCounts = List<int>.filled(places.length, 0);
      const runs = 500;
      for (var run = 0; run < runs; run++) {
        final ordered = LandmarkSuggestionService.weightedOrder(places, random);
        for (final place in ordered.take(LandmarkSuggestionService.pageSize)) {
          firstPageCounts[int.parse(place.label.split(' ').last)]++;
        }
      }

      expect(firstPageCounts.first, greaterThan(firstPageCounts.last));
      expect(firstPageCounts.first, greaterThan(runs ~/ 4));
    });

    test('coarsens the provider anchor to four decimals', () {
      final anchor = LandmarkSuggestionService.coarsen(32.114331, 34.835678);

      expect(anchor.latitude, 32.1143);
      expect(anchor.longitude, 34.8357);
    });
  });
}
