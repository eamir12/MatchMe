import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/utils/match_map_view.dart';

/// Half-height in meters of what a minimap of [viewportHeightPx] pixels
/// actually renders at [zoom] over [latitude].
double frameHalfHeightMeters(
  double zoom,
  double latitude, {
  double viewportHeightPx = kMatchMapNominalViewportHeightPx,
}) {
  final mpp =
      156543.03392 *
      math.cos(latitude.abs() * math.pi / 180) /
      math.pow(2, zoom);
  return mpp * viewportHeightPx / 2;
}

void main() {
  group('matchMapPairHalfMeters', () {
    test('maps every stored distance bucket written by the SQL', () {
      expect(matchMapPairHalfMeters(storedZoom: 16), 150);
      expect(matchMapPairHalfMeters(storedZoom: 15.5), 300);
      expect(matchMapPairHalfMeters(storedZoom: 15), 500);
      expect(matchMapPairHalfMeters(storedZoom: 14.5), 1000);
      expect(matchMapPairHalfMeters(storedZoom: 13.5), 2500);
      expect(matchMapPairHalfMeters(storedZoom: 12.5), 5000);
      expect(matchMapPairHalfMeters(storedZoom: 11), 10000);
    });

    test('prefers the exact pair distance when available', () {
      expect(
        matchMapPairHalfMeters(storedZoom: 16, pairDistanceMeters: 2400),
        1200,
      );
    });

    test('unknown/null zoom falls back to a safe close-match default', () {
      expect(matchMapPairHalfMeters(storedZoom: null), 500);
      expect(matchMapPairHalfMeters(storedZoom: 12), 500);
    });
  });

  group('buildMatchMapView coverage guarantee', () {
    // Stored zoom -> pair half-distance (meters) for each SQL bucket.
    final buckets = <double, double>{
      16: 150,
      15.5: 300,
      15: 500,
      14.5: 1000,
      13.5: 2500,
      12.5: 5000,
      11: 10000,
    };
    const latitudes = <double>[0.0, 16.4, 45.0, 60.0];

    for (final latitude in latitudes) {
      for (final bucket in buckets.entries) {
        test(
          'stored ${bucket.key} at lat $latitude contains the real location',
          () {
            final pairHalf = matchMapPairHalfMeters(storedZoom: bucket.key);
            expect(pairHalf, bucket.value);

            final view = buildMatchMapView(
              centerLat: latitude,
              centerLng: 0,
              pairHalfMeters: pairHalf,
            );
            final coverage = kMatchMapCenterUncertaintyMeters + bucket.value;
            final halfHeight = frameHalfHeightMeters(view.zoom, latitude);

            // The frame must contain the guaranteed area, which contains the
            // true midpoint (±556 m rounding) and each user's position.
            expect(
              halfHeight,
              greaterThanOrEqualTo(coverage),
              reason:
                  'lat $latitude zoom ${bucket.key}: frame half-height '
                  '$halfHeight m < coverage $coverage m',
            );
            // The circle must fit inside the frame.
            expect(view.coverageRadiusMeters, lessThan(halfHeight));
            expect(view.zoom, lessThanOrEqualTo(kMatchMapMaxZoom));
            expect(view.zoom, greaterThanOrEqualTo(1.0));
          },
        );
      }
    }

    test('covers at a smaller viewport (120 px list variant)', () {
      final view = buildMatchMapView(
        centerLat: 45,
        centerLng: 0,
        pairHalfMeters: 150,
        viewportHeightPx: 120,
      );
      final coverage = kMatchMapCenterUncertaintyMeters + 150;
      expect(
        frameHalfHeightMeters(view.zoom, 45, viewportHeightPx: 120),
        greaterThanOrEqualTo(coverage),
      );
    });
  });

  group('MatchLocation.displayView', () {
    test('coarse row centers on the stored rounded center', () {
      final loc = MatchLocation(
        occurrence: 1,
        mapCenterLat: -16.41,
        mapCenterLng: -71.54,
        mapZoom: 16,
      );
      final view = loc.displayView()!;
      expect(view.centerLat, -16.41);
      expect(view.centerLng, -71.54);
      // Old rendering showed stored(16)+1.5 clamped to 16 — far too tight for
      // a center that is only accurate to ~556 m.
      expect(view.zoom, lessThan(16));
      expect(view.zoom, lessThanOrEqualTo(kMatchMapMaxZoom));
      expect(
        frameHalfHeightMeters(view.zoom, view.centerLat),
        greaterThanOrEqualTo(kMatchMapCenterUncertaintyMeters + 150),
      );
    });

    test('legacy exact-only row is coarsened to a 2-decimal midpoint', () {
      const u1Lat = -16.404, u1Lng = -71.537;
      const u2Lat = -16.406, u2Lng = -71.539;
      final loc = MatchLocation(
        occurrence: 1,
        user1Lat: u1Lat,
        user1Lng: u1Lng,
        user2Lat: u2Lat,
        user2Lng: u2Lng,
      );
      final view = loc.displayView()!;
      final midLat = (u1Lat + u2Lat) / 2;
      final midLng = (u1Lng + u2Lng) / 2;
      // The rendered center is quantized to 2 decimals (the privacy cell)
      // and is never the raw midpoint.
      expect(
        (view.centerLat * 100 - (view.centerLat * 100).round()).abs(),
        lessThan(1e-6),
      );
      expect(
        (view.centerLng * 100 - (view.centerLng * 100).round()).abs(),
        lessThan(1e-6),
      );
      expect(view.centerLat, isNot(midLat));
      expect((view.centerLat - midLat).abs(), lessThan(0.0051));
      expect((view.centerLng - midLng).abs(), lessThan(0.0051));
      // Frame must cover the rounding cell plus each user's side (~155 m).
      expect(
        frameHalfHeightMeters(view.zoom, view.centerLat),
        greaterThanOrEqualTo(
          kMatchMapCenterUncertaintyMeters +
              haversineMeters(u1Lat, u1Lng, u2Lat, u2Lng) / 2,
        ),
      );
    });

    test('returns null when there is nothing displayable', () {
      expect(const MatchLocation(occurrence: 1).displayView(), isNull);
    });
  });
}
