// Fallback landmark lookup built on the same map stack as the in-app maps.
//
// Raster tiles cannot be queried, but OpenStreetMap vector tiles carry the POI
// features themselves. A z14 tile covers roughly 2 km at this latitude, so the
// 900 m / 1.6 km / 2.6 km rings cost at most nine tiles and are filtered
// locally. The anchor is coarsened to four decimals before any request and
// nothing is persisted.
//
// Only unambiguous categories are mapped. OpenMapTiles' generic `attraction`
// class includes driving schools and venues, and `library/books` is a
// bookstore, so both are deliberately excluded.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:vector_tile/vector_tile.dart';

class VectorTileLandmarkException implements Exception {
  final String code;

  const VectorTileLandmarkException(this.code);

  @override
  String toString() => 'VectorTileLandmarkException($code)';
}

class VectorTileLandmarkService {
  VectorTileLandmarkService({
    http.Client? client,
    Uri? tileJsonUri,
    Duration tileTimeout = const Duration(seconds: 4),
  }) : _client = client ?? http.Client(),
       _tileJsonUri = tileJsonUri ?? defaultTileJsonUri,
       _tileTimeout = tileTimeout;

  static final Uri defaultTileJsonUri = Uri.parse(
    'https://tiles.openfreemap.org/planet',
  );

  static const int _zoom = 14;
  static const List<int> _radiiMeters = [900, 1600, 2600];

  /// Default page size when a caller does not ask for a larger pool. Callers
  /// pass a larger [suggest] limit to fill "show other places", and the ring
  /// search keeps widening until that limit is met or the rings run out.
  static const int _maxResults = 3;
  static const Duration _tileJsonTtl = Duration(hours: 12);

  // Static so the TileJSON lookup runs once per app process even though a
  // fresh service is created for every meet-up suggestion request.
  static String? _cachedTileTemplate;
  static DateTime? _cachedTemplateAt;

  final http.Client _client;
  final Uri _tileJsonUri;
  final Duration _tileTimeout;

  Future<List<MeetupPlaceSuggestion>> suggest({
    required double latitude,
    required double longitude,
    int limit = _maxResults,
  }) async {
    final anchor = LatLng(
      double.parse(latitude.toStringAsFixed(4)),
      double.parse(longitude.toStringAsFixed(4)),
    );
    final template = await _resolveTileTemplate();

    final placesByTile = <String, List<_RawPlace>>{};
    final loadedTiles = <String>{};
    var anyTileSucceeded = false;

    for (final radius in _radiiMeters) {
      final missing = _tilesFor(anchor, radius)
          .where((tile) => !loadedTiles.contains(tile.key))
          .toList(growable: false);
      if (missing.isNotEmpty) {
        final results = await Future.wait(
          missing.map((tile) => _loadTile(template, tile, anchor)),
        );
        for (final result in results) {
          loadedTiles.add(result.tileKey);
          anyTileSucceeded = anyTileSucceeded || result.succeeded;
          placesByTile[result.tileKey] = result.places;
        }
      }

      // No tile in the closest ring answered: the tile host is unreachable and
      // wider rings would only repeat the same failing requests.
      if (!anyTileSucceeded && radius == _radiiMeters.first) {
        throw const VectorTileLandmarkException('meetup_landmarks_unavailable');
      }

      final picked = _pick(
        placesByTile.values.expand((list) => list),
        radius,
        limit,
      );
      if (picked.length >= limit) return picked;
    }

    if (!anyTileSucceeded) {
      throw const VectorTileLandmarkException('meetup_landmarks_unavailable');
    }
    return _pick(
      placesByTile.values.expand((list) => list),
      _radiiMeters.last,
      limit,
    );
  }

  Future<String> _resolveTileTemplate() async {
    final cached = _cachedTileTemplate;
    final cachedAt = _cachedTemplateAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _tileJsonTtl) {
      return cached;
    }

    try {
      final response = await _client.get(_tileJsonUri).timeout(_tileTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['tiles'] is List) {
          for (final item in decoded['tiles'] as List) {
            if (item is! String || !item.contains('{z}')) continue;
            _cachedTileTemplate = item;
            _cachedTemplateAt = DateTime.now();
            return item;
          }
        }
      }
    } catch (_) {
      // Fall through to the cached template, if any.
    }

    if (cached != null) return cached;
    throw const VectorTileLandmarkException('meetup_landmarks_unavailable');
  }

  Future<_TileResult> _loadTile(
    String template,
    _TileRef tile,
    LatLng anchor,
  ) async {
    try {
      final url = template
          .replaceAll('{z}', '$_zoom')
          .replaceAll('{x}', '${tile.x}')
          .replaceAll('{y}', '${tile.y}');
      final response = await _client.get(Uri.parse(url)).timeout(_tileTimeout);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.isEmpty) {
        return _TileResult(tile.key, succeeded: false, places: const []);
      }

      final vectorTile = VectorTile.fromBytes(bytes: response.bodyBytes);
      final places = <_RawPlace>[];
      for (final layer in vectorTile.layers) {
        if (layer.name != 'poi' && layer.name != 'park') continue;
        for (final feature in layer.features) {
          final properties = feature.decodeProperties();
          final label = _nameFor(properties);
          if (label == null) continue;
          final category = _categoryFor(layer.name, properties);
          if (category == null) continue;
          final geometry = feature.decodeGeometry<Geometry>();
          if (geometry == null) continue;
          final location = _closestPoint(geometry, layer.extent, tile, anchor);
          if (location == null) continue;
          places.add(
            _RawPlace(
              label: label,
              category: category,
              latitude: location.point.latitude,
              longitude: location.point.longitude,
              distanceMeters: location.distanceMeters,
            ),
          );
        }
      }
      return _TileResult(tile.key, succeeded: true, places: places);
    } catch (_) {
      return _TileResult(tile.key, succeeded: false, places: const []);
    }
  }

  List<_TileRef> _tilesFor(LatLng anchor, int radiusMeters) {
    final latDelta = radiusMeters / 111320.0;
    final lonDelta =
        radiusMeters / (111320.0 * math.cos(anchor.latitude * math.pi / 180));
    final minX = _lonToTileX(anchor.longitude - lonDelta);
    final maxX = _lonToTileX(anchor.longitude + lonDelta);
    final minY = _latToTileY(anchor.latitude + latDelta);
    final maxY = _latToTileY(anchor.latitude - latDelta);

    return [
      for (var x = minX; x <= maxX; x++)
        for (var y = minY; y <= maxY; y++) _TileRef(x, y),
    ];
  }

  int _lonToTileX(double longitude) {
    final n = 1 << _zoom;
    return ((longitude + 180) / 360 * n).floor();
  }

  int _latToTileY(double latitude) {
    final n = 1 << _zoom;
    final clamped = latitude.clamp(-85.05112878, 85.05112878);
    final radians = clamped * math.pi / 180;
    return ((1 -
                math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
            2 *
            n)
        .floor();
  }

  _LocatedPoint? _closestPoint(
    Geometry geometry,
    int extent,
    _TileRef tile,
    LatLng anchor,
  ) {
    LatLng? closest;
    var bestDistance = double.infinity;
    final n = 1 << _zoom;

    for (final point in _pointsOf(geometry)) {
      final longitude = (tile.x + point[0] / extent) / n * 360 - 180;
      final y = tile.y + point[1] / extent;
      final latitude =
          180 /
          math.pi *
          math.atan(
            0.5 *
                (math.exp(math.pi - 2 * math.pi * y / n) -
                    math.exp(-(math.pi - 2 * math.pi * y / n))),
          );
      final candidate = LatLng(latitude, longitude);
      final distance = const Distance().as(LengthUnit.Meter, anchor, candidate);
      if (distance < bestDistance) {
        bestDistance = distance;
        closest = candidate;
      }
    }

    if (closest == null) return null;
    return _LocatedPoint(closest, bestDistance.round());
  }

  Iterable<List<double>> _pointsOf(Geometry geometry) sync* {
    if (geometry is GeometryPoint) {
      yield geometry.coordinates;
    } else if (geometry is GeometryMultiPoint) {
      yield* geometry.coordinates;
    } else if (geometry is GeometryLineString) {
      yield* geometry.coordinates;
    } else if (geometry is GeometryMultiLineString) {
      for (final line in geometry.coordinates) {
        yield* line;
      }
    } else if (geometry is GeometryPolygon) {
      for (final ring in geometry.coordinates) {
        yield* ring;
      }
    } else if (geometry is GeometryMultiPolygon) {
      for (final polygon
          in geometry.coordinates ?? const <List<List<List<double>>>>[]) {
        for (final ring in polygon) {
          yield* ring;
        }
      }
    }
  }

  String? _nameFor(Map<String, VectorTileValue> properties) {
    for (final key in const ['name', 'name:en', 'name:he']) {
      final value = properties[key]?.value.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  String? _categoryFor(
    String layerName,
    Map<String, VectorTileValue> properties,
  ) {
    final className = properties['class']?.value.toString();
    final subclass = properties['subclass']?.value.toString();

    if (layerName == 'park') {
      return const {
            'national_park',
            'park',
            'garden',
            'nature_reserve',
          }.contains(className)
          ? 'park'
          : null;
    }

    switch (className) {
      case 'park':
        return 'park';
      case 'grocery':
        return subclass == 'supermarket' ? 'supermarket' : null;
      case 'shop':
        if (subclass == 'supermarket') return 'supermarket';
        if (subclass == 'mall' || subclass == 'department_store') return 'mall';
        return null;
      case 'fuel':
        return 'fuel';
      case 'pharmacy':
        return 'pharmacy';
      case 'library':
        // `books` is a bookstore, not a public library.
        return subclass == 'library' ? 'library' : null;
      case 'town_hall':
        return 'library';
      case 'railway':
        return const {'station', 'halt', 'subway_entrance'}.contains(subclass)
            ? 'transit'
            : null;
      case 'bus':
        return subclass == 'bus_station' ? 'transit' : null;
      case 'museum':
        return 'attraction';
      case 'attraction':
        return subclass == 'viewpoint' ? 'attraction' : null;
      case 'marketplace':
        return 'square';
      default:
        return null;
    }
  }

  List<MeetupPlaceSuggestion> _pick(
    Iterable<_RawPlace> places,
    int radiusMeters,
    int limit,
  ) {
    final sorted =
        places.where((place) => place.distanceMeters <= radiusMeters).toList()
          ..sort((a, b) {
            final score = b.score.compareTo(a.score);
            if (score != 0) return score;
            return a.distanceMeters.compareTo(b.distanceMeters);
          });

    final result = <MeetupPlaceSuggestion>[];
    final usedCategories = <String>{};
    final usedNames = <String>{};
    for (final place in sorted) {
      if (usedCategories.contains(place.category)) continue;
      usedCategories.add(place.category);
      usedNames.add(place.normalizedName);
      result.add(place.toSuggestion());
      if (result.length >= limit) return result;
    }

    // Sparse areas may only have one category; fill with the closest distinct
    // places rather than returning fewer options than necessary.
    for (final place in sorted) {
      if (usedNames.contains(place.normalizedName)) continue;
      usedNames.add(place.normalizedName);
      result.add(place.toSuggestion());
      if (result.length >= limit) break;
    }

    return result;
  }
}

class _TileRef {
  final int x;
  final int y;

  const _TileRef(this.x, this.y);

  String get key => '$x/$y';
}

class _TileResult {
  final String tileKey;
  final bool succeeded;
  final List<_RawPlace> places;

  const _TileResult(
    this.tileKey, {
    required this.succeeded,
    required this.places,
  });
}

class _LocatedPoint {
  final LatLng point;
  final int distanceMeters;

  const _LocatedPoint(this.point, this.distanceMeters);
}

class _RawPlace {
  final String label;
  final String category;
  final double latitude;
  final double longitude;
  final int distanceMeters;

  const _RawPlace({
    required this.label,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
  });

  String get normalizedName => label
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  int get _categoryWeight {
    switch (category) {
      case 'park':
        return 10;
      case 'square':
        return 9;
      case 'landmark':
        return 9;
      case 'attraction':
        return 8;
      case 'supermarket':
        return 8;
      case 'library':
        return 8;
      case 'mall':
        return 7;
      case 'transit':
        return 7;
      case 'pharmacy':
        return 7;
      case 'fuel':
        return 6;
      default:
        return 5;
    }
  }

  int get score => _categoryWeight * 100 - (distanceMeters / 5).round();

  MeetupPlaceSuggestion toSuggestion() => MeetupPlaceSuggestion(
    label: label,
    category: category,
    latitude: latitude,
    longitude: longitude,
    distanceMeters: math.max(0, distanceMeters),
  );
}
