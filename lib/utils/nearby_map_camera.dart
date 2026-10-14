import 'dart:math' as math;

import 'package:flutter/widgets.dart';

const double nearbyMapMaxZoom = 24;

/// Fraction of the smaller map dimension occupied by the matching-radius
/// circle, leaving 10% of the map visible around it on every side.
const double nearbyMapRadiusFillRatio = 0.80;

/// Chooses a zoom where the matching-radius circle (measured as its diameter)
/// occupies [nearbyMapRadiusFillRatio] of the smaller map dimension, leaving
/// room for map controls and preventing clipping.
double nearbyMapZoomForRadius({
  required double radiusMeters,
  required double latitude,
  required Size viewportSize,
}) {
  if (!radiusMeters.isFinite || radiusMeters <= 0) return 3;
  if (!viewportSize.width.isFinite ||
      !viewportSize.height.isFinite ||
      viewportSize.width <= 0 ||
      viewportSize.height <= 0) {
    return 3;
  }

  const earthCircumferenceMeters = 2 * math.pi * 6378137;
  const tileSize = 256.0;
  final targetRadiusPixels =
      math.min(viewportSize.width, viewportSize.height) *
      nearbyMapRadiusFillRatio /
      2;
  final latitudeScale = math
      .cos(latitude * math.pi / 180)
      .abs()
      .clamp(0.05, 1.0);
  final zoom =
      math.log(
        targetRadiusPixels *
            latitudeScale *
            earthCircumferenceMeters /
            (radiusMeters * tileSize),
      ) /
      math.ln2;

  return zoom.clamp(1.0, nearbyMapMaxZoom);
}
