import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:matchme/utils/nearby_map_camera.dart';

void main() {
  const viewport = Size(390, 700);
  const latitude = 37.5;

  double renderedRadiusPixels(double radiusMeters, double zoom) {
    const earthCircumferenceMeters = 2 * math.pi * 6378137;
    final latitudeScale = math.cos(latitude * math.pi / 180);
    return radiusMeters *
        256 *
        math.pow(2, zoom) /
        (earthCircumferenceMeters * latitudeScale);
  }

  for (final testCase in [
    (name: '15 feet', radiusMeters: 15 * 0.3048),
    (name: '3 miles', radiusMeters: 3 * 1609.344),
  ]) {
    test('fits the ${testCase.name} matching radius to the map viewport', () {
      final zoom = nearbyMapZoomForRadius(
        radiusMeters: testCase.radiusMeters,
        latitude: latitude,
        viewportSize: viewport,
      );
      final diameter = 2 * renderedRadiusPixels(testCase.radiusMeters, zoom);
      final targetDiameter =
          math.min(viewport.width, viewport.height) * nearbyMapRadiusFillRatio;
      expect(diameter, closeTo(targetDiameter, targetDiameter * 0.01));
      expect(zoom, inInclusiveRange(1, nearbyMapMaxZoom));
    });
  }

  test('clamps invalid and unrepresentably large radius inputs safely', () {
    expect(
      nearbyMapZoomForRadius(
        radiusMeters: 0,
        latitude: 0,
        viewportSize: viewport,
      ),
      3,
    );
    expect(
      nearbyMapZoomForRadius(
        radiusMeters: 1e12,
        latitude: 0,
        viewportSize: viewport,
      ),
      1,
    );
  });
}
