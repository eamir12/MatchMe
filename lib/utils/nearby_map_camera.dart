import 'dart:math' as math;

import 'package:flutter/widgets.dart';

const double nearbyMapMaxZoom = 24;

/// Chooses a zoom where the matching-radius circle nearly fills the smaller
/// map dimension, leaving room for map controls and preventing clipping.
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
  const fillRatio = 0.84;
  final targetDiameterPixels =
      math.min(viewportSize.width, viewportSize.height) * fillRatio;
  final latitudeScale = math.cos(latitude * math.pi / 180).abs().clamp(
    0.05,
    1.0,
  );
  final zoom = math.log(
        targetDiameterPixels *
            latitudeScale *
            earthCircumferenceMeters /
            (radiusMeters * tileSize),
      ) /
      math.ln2;

  return zoom.clamp(1.0, nearbyMapMaxZoom);
}
