// lib/utils/match_map_view.dart
//
// Shared viewport math for the match-profile minimap and its full-screen map.
//
// Privacy model (see PRIVACY_PRESERVING_DESIGN_CONSTRAINTS.md):
//   * The matching SQL stores the pair's midpoint rounded to 2 decimals —
//     `ROUND((latA + latB) / 2, 2)` — so the stored center can be up to
//     ±0.005° (~556 m) away from the true midpoint. That rounding is the
//     privacy guarantee and must not be tightened.
//   * `matches.map_zoom` is a *distance bucket* written by the matching
//     functions (16 = pair < 300 m, 15.5 = < 600 m, 15 = < 1 km,
//     14.5 = < 2 km, 13.5 = < 5 km, 12.5 = < 10 km, 11 = ≥ 10 km).
//     It is NOT a display zoom — never write display zooms into that column.
//
// This module combines the two into a viewport that is guaranteed to contain
// the whole real match area (the rounding cell plus each user's side of the
// pair) while never rendering a precise spot — no pin, no dot.

import 'dart:math' as math;

/// Nominal minimap viewport height (logical px) used when the caller does not
/// know its real height (full-screen map, offline tile pre-warming).
const double kMatchMapNominalViewportHeightPx = 140.0;

/// Upper bound for the initial zoom so a near-equator close match cannot
/// render block-level detail. Lowering zoom only ever makes the frame wider,
/// so the cap can never break the coverage guarantee.
const double kMatchMapMaxZoom = 13.5;

/// ±0.005° of latitude for a 2-decimal rounded coordinate is ~556 m; rounded
/// up for safety. Half-width of the guaranteed area.
const double kMatchMapCenterUncertaintyMeters = 560.0;

/// The frame is sized with X% more room than the guaranteed area so the
/// region never touches the viewport edge.
const double kMatchMapFrameSafety = 1.15;

/// Ground resolution (m/px) of one Web Mercator tile row at zoom 0 / 256 px.
const double _metersPerPixelZoom0 = 156543.03392;

/// A privacy-coarse map viewport: where to center, how far to zoom, and how
/// large the "approximate area" circle should be.
class MatchMapView {
  final double centerLat;
  final double centerLng;
  final double zoom;

  /// Radius (meters) of the translucent circle: the guaranteed area that
  /// contains the true match location. Always fits inside the viewport.
  final double coverageRadiusMeters;

  const MatchMapView({
    required this.centerLat,
    required this.centerLng,
    required this.zoom,
    required this.coverageRadiusMeters,
  });
}

/// Rounds a coordinate the same way the matching SQL does
/// (`ROUND(x::numeric, 2)`), for legacy rows that only carry exact
/// coordinates and need a coarse center derived client-side.
double roundCoarseCoordinate(double value) =>
    (value * 100).roundToDouble() / 100;

/// Great-circle distance in meters.
double haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadius = 6371000.0;
  final phi1 = lat1 * math.pi / 180;
  final phi2 = lat2 * math.pi / 180;
  final dPhi = (lat2 - lat1) * math.pi / 180;
  final dLambda = (lng2 - lng1) * math.pi / 180;
  final a =
      math.sin(dPhi / 2) * math.sin(dPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(dLambda / 2) *
          math.sin(dLambda / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Half of the pair separation in meters — how far each user can be from the
/// stored midpoint — inferred from the exact distance when available,
/// otherwise from the stored `map_zoom` distance bucket.
///
/// Values that are not one of the SQL buckets (nulls defaulted client-side,
/// one-off dev rows, future changes) fall back to a moderate 500 m instead of
/// a guess in either extreme.
double matchMapPairHalfMeters({
  double? storedZoom,
  double? pairDistanceMeters,
}) {
  if (pairDistanceMeters != null &&
      pairDistanceMeters.isFinite &&
      pairDistanceMeters >= 0) {
    return pairDistanceMeters / 2;
  }
  final z = storedZoom;
  if (z == null) return 500;
  if ((z - 16).abs() < 0.25) return 150; // pair < 0.3 km
  if ((z - 15.5).abs() < 0.25) return 300; // pair < 0.6 km
  if ((z - 15).abs() < 0.25) return 500; // pair < 1.0 km
  if ((z - 14.5).abs() < 0.25) return 1000; // pair < 2.0 km
  if ((z - 13.5).abs() < 0.25) return 2500; // pair < 5.0 km
  if ((z - 12.5).abs() < 0.25) return 5000; // pair < 10 km
  if ((z - 11).abs() < 0.25) return 10000; // pair >= 10 km
  return 500; // unknown value: moderate default, still covers the cell
}

/// Builds the viewport for a coarse match center.
///
/// The returned zoom guarantees that a [viewportHeightPx]-tall frame centered
/// on [centerLat]/[centerLng] contains a circle of
/// `kMatchMapCenterUncertaintyMeters + pairHalfMeters` — i.e. every point the
/// match could have actually happened at — at any latitude.
MatchMapView buildMatchMapView({
  required double centerLat,
  required double centerLng,
  required double pairHalfMeters,
  double viewportHeightPx = kMatchMapNominalViewportHeightPx,
}) {
  final coverage =
      kMatchMapCenterUncertaintyMeters + math.max(0, pairHalfMeters);
  final requiredHalfMeters = coverage * kMatchMapFrameSafety;
  final cosLat = math.cos(centerLat.abs() * math.pi / 180);
  // Max ground resolution (m/px) the frame may have while still spanning
  // requiredHalfMeters above and below the center.
  final maxMetersPerPixel = requiredHalfMeters / (viewportHeightPx / 2);
  final zoom =
      (math.log(_metersPerPixelZoom0 * cosLat / maxMetersPerPixel) / math.ln2)
          .clamp(1.0, kMatchMapMaxZoom)
          .toDouble();
  return MatchMapView(
    centerLat: centerLat,
    centerLng: centerLng,
    zoom: zoom,
    coverageRadiusMeters: coverage,
  );
}
