// Exterior landmark suggestions for the in-person meet-up flow.
//
// The lookup is intentionally one-shot: the caller passes a current position,
// this service returns public places, and nothing is stored. The position is
// coarsened to four decimal places (~11 m) before it leaves the device.
//
// Only structural, named, publicly accessible places are returned. Opening
// hours are deliberately irrelevant: meeting outside a supermarket or a fuel
// station does not depend on the business being open. Businesses that require
// being open (cafes, restaurants) are not suggested at all.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:matchme/models/meetup_models.dart';
import 'package:matchme/services/vector_tile_landmark_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LandmarkSuggestionException implements Exception {
  final String code;

  const LandmarkSuggestionException(this.code);

  @override
  String toString() => 'LandmarkSuggestionException($code)';
}

/// The outcome of a lookup, carrying which provider answered.
///
/// Attribution depends on this: Places content must be shown with Google Maps
/// attribution, and the OpenStreetMap path with its own, so the UI cannot pick
/// a fixed line.
class LandmarkSuggestionResult {
  /// The page the picker shows now.
  final List<MeetupPlaceSuggestion> places;

  /// Ranked places beyond [places] from the same lookup. "Show other places"
  /// pages through this in memory, so it never triggers another provider call.
  final List<MeetupPlaceSuggestion> pool;

  final String source;

  const LandmarkSuggestionResult({
    required this.places,
    this.pool = const [],
    required this.source,
  });

  bool get isGoogle => source == LandmarkSuggestionService.googleProvider;

  bool get hasMore => pool.isNotEmpty;
}

class LandmarkSuggestionService {
  LandmarkSuggestionService({
    http.Client? client,
    List<String>? endpoints,
    VectorTileLandmarkService? tileFallback,
    SupabaseClient? supabaseClient,
    String provider = googleProvider,
    String languageCode = 'en',
    Duration overpassBudget = const Duration(seconds: 3),
    math.Random? random,
  }) : _client = client ?? http.Client(),
       _endpoints = _mergeEndpoints(endpoints),
       _tileFallback = tileFallback ?? VectorTileLandmarkService(),
       _supabaseClient = supabaseClient,
       _provider = provider.trim().toLowerCase(),
       _languageCode = languageCode,
       _overpassBudget = overpassBudget,
       _random = random ?? math.Random();

  /// The provider that answers first. Anything other than this value uses the
  /// keyless Overpass path, which is also the fallback when Google fails.
  static const String googleProvider = 'google';

  // Global-data mirrors only. Regional instances (for example osm.ch) answer
  // quickly but return nothing outside their extract, which reads as "no
  // places nearby".
  static const List<String> defaultEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.private.coffee/api/interpreter',
  ];

  static const List<int> _radiiMeters = [900, 1600, 2600];

  /// Places shown per page. One lookup yields at most three pages: the first
  /// page plus two "show other places" rounds. The provider already returns
  /// more than three places, so paging costs no extra call or quota.
  static const int pageSize = 3;
  static const int _suggestionLimit = pageSize * 3;
  static const Duration _requestTimeout = Duration(seconds: 8);

  /// The proxy answers in well under a second when it is reachable. Keep this
  /// short so a stalled request still leaves room for the OSM path inside the
  /// caller's overall budget.
  static const Duration _googleTimeout = Duration(seconds: 5);

  /// Configured endpoints are tried first, then the built-in mirrors. This
  /// keeps a stale or unreachable config row from disabling the whole feature.
  static List<String> _mergeEndpoints(List<String>? endpoints) {
    final merged = <String>[];
    final seen = <String>{};
    for (final endpoint in [...?endpoints, ...defaultEndpoints]) {
      final trimmed = endpoint.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      merged.add(trimmed);
    }
    return merged;
  }

  final http.Client _client;
  final List<String> _endpoints;
  final VectorTileLandmarkService _tileFallback;
  final SupabaseClient? _supabaseClient;
  final String _provider;
  final String _languageCode;
  final Duration _overpassBudget;
  final math.Random _random;

  /// The anchor actually sent to a provider: four decimal places (~11 m) is
  /// enough to find the neighbourhood and not enough to pin a person. The
  /// in-memory suggestion cache compares against this same value, so a small
  /// move still restores the previous list.
  static LatLng coarsen(double latitude, double longitude) => LatLng(
    double.parse(latitude.toStringAsFixed(4)),
    double.parse(longitude.toStringAsFixed(4)),
  );

  /// Google Places is tried first when configured. Anything other than a
  /// successful, non-empty answer — an outage, a missing key, an exhausted
  /// quota, an undeployed function — falls through to the keyless OSM path
  /// below, so a Google problem degrades to the previous behavior rather than
  /// an empty picker.
  Future<LandmarkSuggestionResult> suggest({
    required double latitude,
    required double longitude,
  }) async {
    if (_provider == googleProvider) {
      try {
        final places = await _suggestGoogle(
          latitude: latitude,
          longitude: longitude,
        ).timeout(_googleTimeout);
        if (places.isNotEmpty) {
          return _paged(places, googleProvider);
        }
      } catch (error) {
        // Unreachable, unauthorized, rate-limited or not deployed: use OSM.
        // Silent by design, but a fallback must leave a trace in debug builds,
        // otherwise every failure mode looks identical to "Google unused".
        assert(() {
          debugPrint('[landmark] Google lookup failed: $error');
          return true;
        }());
      }
    }

    return _paged(
      await _suggestOsm(latitude: latitude, longitude: longitude),
      'osm',
    );
  }

  /// Splits a ranked list into the visible page and the in-memory pool.
  ///
  /// The order is reshuffled per lookup so the same neighbourhood does not
  /// keep offering the same three landmarks. Paging still walks one fixed
  /// order, so the three pages never repeat a place.
  LandmarkSuggestionResult _paged(
    List<MeetupPlaceSuggestion> ranked,
    String source,
  ) {
    if (ranked.length <= pageSize) {
      return LandmarkSuggestionResult(places: ranked, source: source);
    }
    final ordered = weightedOrder(ranked, _random);
    return LandmarkSuggestionResult(
      places: ordered.take(pageSize).toList(growable: false),
      pool: ordered.skip(pageSize).toList(growable: false),
      source: source,
    );
  }

  /// Orders a curated pool for display, biasing nearer places to the front.
  ///
  /// Every place still appears if the user pages far enough; the weighting
  /// only decides which combination is offered first.
  @visibleForTesting
  static List<MeetupPlaceSuggestion> weightedOrder(
    List<MeetupPlaceSuggestion> places,
    math.Random random,
  ) {
    if (places.length <= 1) return List.of(places);
    final remaining = List<MeetupPlaceSuggestion>.of(places);
    final weights = [
      for (final place in remaining) _distanceWeight(place.distanceMeters),
    ];
    final ordered = <MeetupPlaceSuggestion>[];
    while (remaining.isNotEmpty) {
      var total = 0.0;
      for (final weight in weights) {
        total += weight;
      }
      var roll = random.nextDouble() * total;
      var index = remaining.length - 1;
      for (var i = 0; i < remaining.length; i++) {
        roll -= weights[i];
        if (roll < 0) {
          index = i;
          break;
        }
      }
      ordered.add(remaining.removeAt(index));
      weights.removeAt(index);
    }
    return ordered;
  }

  /// Half-life of 300 m: a place 300 m away is about half as likely to be
  /// offered before one at the anchor, and 600 m about a quarter.
  static double _distanceWeight(int? distanceMeters) {
    final meters = distanceMeters ?? 0;
    if (meters <= 0) return 1;
    return math.pow(0.5, meters / 300).toDouble();
  }

  /// Places API (New) "Nearby Search", proxied by the `place-suggestions` edge
  /// function so the API key never reaches a client build. The function owns the
  /// by-type validation; this side only re-applies the app's own picker.
  Future<List<MeetupPlaceSuggestion>> _suggestGoogle({
    required double latitude,
    required double longitude,
  }) async {
    // Same coarsening as the Overpass path: enough to find the neighbourhood,
    // not enough to pin a person. The function measures distances from this
    // anchor, so its numbers match what the OSM path would report.
    final anchor = coarsen(latitude, longitude);

    final client = _supabaseClient ?? Supabase.instance.client;
    final response = await client.functions.invoke(
      'place-suggestions',
      body: {
        'latitude': anchor.latitude,
        'longitude': anchor.longitude,
        'language': _languageCode,
      },
    );

    if (response.status < 200 || response.status >= 300) {
      throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
    }

    final data = response.data;
    if (data is! Map || data['places'] is! List) {
      throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
    }

    final candidates = <String, _Candidate>{};
    for (final raw in (data['places'] as List).whereType<Map>()) {
      final candidate = _candidateFromGoogle(
        Map<String, dynamic>.from(raw),
        anchor,
      );
      if (candidate == null) continue;
      candidates.putIfAbsent(candidate.key, () => candidate);
    }

    return _pick(candidates.values);
  }

  _Candidate? _candidateFromGoogle(Map<String, dynamic> item, LatLng anchor) {
    final label = item['label']?.toString().trim() ?? '';
    if (label.length < 2) return null;

    final category = item['category']?.toString().trim() ?? '';
    if (category.isEmpty) return null;

    final lat = _toDouble(item['latitude']);
    final lng = _toDouble(item['longitude']);
    if (lat == null || lng == null) return null;

    final point = LatLng(lat, lng);
    final sentDistance = item['distance_m'];
    final distance = sentDistance is num
        ? sentDistance.round()
        : const Distance().as(LengthUnit.Meter, anchor, point).round();
    if (distance < 0 || distance > 2800) return null;

    final normalizedName = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    if (normalizedName.isEmpty) return null;

    final rawPlaceId = item['place_id']?.toString().trim();
    final placeId = (rawPlaceId == null || rawPlaceId.isEmpty)
        ? null
        : rawPlaceId;

    return _Candidate(
      label: label,
      category: category,
      latitude: lat,
      longitude: lng,
      distanceMeters: distance,
      key: '$normalizedName|${lat.toStringAsFixed(4)}|${lng.toStringAsFixed(4)}',
      placeId: placeId,
    );
  }

  /// Overpass gives the richest categories, but its public instances are often
  /// slow or down. Give it a short budget, then read the same OpenStreetMap
  /// data from vector tiles instead of making the user wait through timeouts.
  Future<List<MeetupPlaceSuggestion>> _suggestOsm({
    required double latitude,
    required double longitude,
  }) async {
    Object? overpassError;
    try {
      final places = await _suggestOverpass(
        latitude: latitude,
        longitude: longitude,
      ).timeout(_overpassBudget);
      if (places.isNotEmpty) return places;
    } catch (error) {
      overpassError = error;
    }

    List<MeetupPlaceSuggestion>? tilePlaces;
    try {
      tilePlaces = await _tileFallback.suggest(
        latitude: latitude,
        longitude: longitude,
        limit: _suggestionLimit,
      );
    } catch (_) {
      // Both sources failed; report the lookup as unavailable below.
    }

    if (tilePlaces != null) return tilePlaces;
    if (overpassError == null) return const [];
    throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
  }

  Future<List<MeetupPlaceSuggestion>> _suggestOverpass({
    required double latitude,
    required double longitude,
  }) async {
    // Coarsen the anchor: enough to find the same neighbourhood, not enough
    // to pin a person. The returned landmarks keep their real coordinates.
    final anchor = coarsen(latitude, longitude);

    final candidates = <String, _Candidate>{};

    // Race the mirrors for the closest radius. Waiting on each instance in
    // turn makes one dead mirror cost a full timeout; worse, a dead lookup
    // service would be retried at every wider radius. If every mirror fails
    // here, the service is unreachable and widening the search cannot help.
    final first = await _raceEndpoints(_endpoints, anchor, _radiiMeters.first);
    _collect(first.elements, anchor, candidates);

    var picked = _pick(candidates.values);
    // Keep widening until the full three-page pool is available. Dense areas
    // already fill it from the first ring; sparse areas need the wider rings
    // so "show other places" has a second and third page.
    if (picked.length >= _suggestionLimit) return picked;

    // Wider radii go to the mirror that just answered. Only if it fails do
    // the remaining mirrors get another chance.
    var preferredEndpoint = first.endpoint;
    for (final radius in _radiiMeters.skip(1)) {
      try {
        final elements = await _queryEndpoint(
          endpoint: preferredEndpoint,
          anchor: anchor,
          radiusMeters: radius,
        );
        _collect(elements, anchor, candidates);
      } catch (_) {
        try {
          final fallback = await _raceEndpoints(_endpoints, anchor, radius);
          preferredEndpoint = fallback.endpoint;
          _collect(fallback.elements, anchor, candidates);
        } catch (_) {
          continue;
        }
      }
      picked = _pick(candidates.values);
      if (picked.length >= _suggestionLimit) return picked;
    }

    return _pick(candidates.values);
  }

  void _collect(
    List<Map<String, dynamic>> elements,
    LatLng anchor,
    Map<String, _Candidate> candidates,
  ) {
    for (final element in elements) {
      final candidate = _candidateFromElement(element, anchor);
      if (candidate == null) continue;
      candidates.putIfAbsent(candidate.key, () => candidate);
    }
  }

  Future<_EndpointResponse> _raceEndpoints(
    List<String> endpoints,
    LatLng anchor,
    int radiusMeters,
  ) {
    final completer = Completer<_EndpointResponse>();
    var pending = endpoints.length;
    Object? lastError;

    if (pending == 0) {
      return Future.error(
        const LandmarkSuggestionException('meetup_landmarks_unavailable'),
      );
    }

    for (final endpoint in endpoints) {
      unawaited(() async {
        try {
          final elements = await _queryEndpoint(
            endpoint: endpoint,
            anchor: anchor,
            radiusMeters: radiusMeters,
          );
          if (!completer.isCompleted) {
            completer.complete(_EndpointResponse(endpoint, elements));
          }
        } catch (error) {
          lastError = error;
          pending--;
          if (pending == 0 && !completer.isCompleted) {
            completer.completeError(
              lastError ??
                  const LandmarkSuggestionException(
                    'meetup_landmarks_unavailable',
                  ),
            );
          }
        }
      }());
    }

    return completer.future;
  }

  Future<List<Map<String, dynamic>>> _queryEndpoint({
    required String endpoint,
    required LatLng anchor,
    required int radiusMeters,
  }) async {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
    }

    final query = _buildQuery(anchor, radiusMeters);
    final response = await _client
        .post(
          uri,
          headers: {
            'Accept': 'application/json',
            if (!kIsWeb)
              'User-Agent': 'MatchMe/1.0 (in-person meet-up landmarks)',
          },
          body: {'data': query},
        )
        .timeout(_requestTimeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['elements'] is! List) {
      throw const LandmarkSuggestionException('meetup_landmarks_unavailable');
    }

    return (decoded['elements'] as List)
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  String _buildQuery(LatLng anchor, int radiusMeters) {
    final around =
        'around:$radiusMeters,${anchor.latitude},${anchor.longitude}';
    // The regexes end in `$`, which Dart would read as interpolation in a
    // normal string, so the template is raw and the anchor is substituted.
    const template = r'''
[out:json][timeout:6];
(
  nwr["name"]["leisure"~"^(park|garden)$"](__AROUND__);
  nwr["name"]["place"="square"](__AROUND__);
  nwr["name"]["historic"~"^(monument|memorial|city_gate|archaeological_site)$"](__AROUND__);
  nwr["name"]["tourism"~"^(attraction|museum|viewpoint)$"](__AROUND__);
  nwr["name"]["shop"~"^(supermarket|mall|department_store)$"](__AROUND__);
  nwr["name"]["amenity"~"^(fuel|pharmacy|library|townhall|bus_station|marketplace)$"](__AROUND__);
  nwr["name"]["railway"~"^(station|subway_entrance)$"](__AROUND__);
  nwr["name"]["public_transport"="station"](__AROUND__);
);
out center tags 80;
''';
    return template.replaceAll('__AROUND__', around);
  }

  _Candidate? _candidateFromElement(
    Map<String, dynamic> element,
    LatLng anchor,
  ) {
    final tags = element['tags'];
    if (tags is! Map) return null;
    final normalizedTags = Map<String, dynamic>.from(tags);

    String? tag(String key) {
      final value = normalizedTags[key]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    final name = tag('name') ?? tag('name:en') ?? tag('name:he');
    if (name == null || name.length < 2) return null;

    final access = tag('access')?.toLowerCase();
    if (access == 'private' || access == 'no' || access == 'customers') {
      return null;
    }
    if (tag('disused') == 'yes' ||
        tag('abandoned') == 'yes' ||
        tag('construction') != null ||
        tag('shop') == 'vacant' ||
        tag('amenity') == 'parking') {
      return null;
    }

    final lat =
        _toDouble(element['lat']) ??
        _toDouble(
          element['center'] is Map ? (element['center'] as Map)['lat'] : null,
        );
    final lng =
        _toDouble(element['lon']) ??
        _toDouble(
          element['center'] is Map ? (element['center'] as Map)['lon'] : null,
        );
    if (lat == null || lng == null) return null;

    final category = _categoryFor(normalizedTags);
    final point = LatLng(lat, lng);
    final distance = const Distance()
        .as(LengthUnit.Meter, anchor, point)
        .round();
    if (distance < 0 || distance > 2800) return null;

    final normalizedName = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .trim();
    if (normalizedName.isEmpty) return null;

    return _Candidate(
      label: name,
      category: category,
      latitude: lat,
      longitude: lng,
      distanceMeters: distance,
      key:
          '$normalizedName|${lat.toStringAsFixed(4)}|${lng.toStringAsFixed(4)}',
    );
  }

  String _categoryFor(Map<String, dynamic> tags) {
    final leisure = tags['leisure']?.toString();
    if (leisure == 'park' || leisure == 'garden') return 'park';

    if (tags['place'] == 'square') return 'square';

    final historic = tags['historic']?.toString();
    if (historic == 'monument' ||
        historic == 'memorial' ||
        historic == 'city_gate' ||
        historic == 'archaeological_site') {
      return 'landmark';
    }

    final tourism = tags['tourism']?.toString();
    if (tourism == 'attraction' ||
        tourism == 'museum' ||
        tourism == 'viewpoint') {
      return 'attraction';
    }

    final shop = tags['shop']?.toString();
    if (shop == 'supermarket') return 'supermarket';
    if (shop == 'mall' || shop == 'department_store') return 'mall';

    final amenity = tags['amenity']?.toString();
    if (amenity == 'fuel') return 'fuel';
    if (amenity == 'pharmacy') return 'pharmacy';
    if (amenity == 'library' || amenity == 'townhall') return 'library';
    if (amenity == 'bus_station' || amenity == 'marketplace') {
      return amenity == 'marketplace' ? 'square' : 'transit';
    }

    final railway = tags['railway']?.toString();
    if (railway == 'station' || railway == 'subway_entrance') return 'transit';
    if (tags['public_transport'] == 'station') return 'transit';

    return 'other';
  }

  List<MeetupPlaceSuggestion> _pick(
    Iterable<_Candidate> candidates, {
    int limit = _suggestionLimit,
  }) {
    final sorted = candidates.toList()
      ..sort((a, b) {
        final score = b.score.compareTo(a.score);
        if (score != 0) return score;
        return a.distanceMeters.compareTo(b.distanceMeters);
      });

    final result = <MeetupPlaceSuggestion>[];
    final usedCategories = <String>{};
    for (final candidate in sorted) {
      if (usedCategories.contains(candidate.category)) continue;
      usedCategories.add(candidate.category);
      result.add(candidate.toSuggestion());
      if (result.length >= limit) return result;
    }

    // Remote areas may have only one category nearby. Fill the remaining
    // slots with the closest distinct places rather than returning fewer
    // options than necessary.
    for (final candidate in sorted) {
      if (result.any((item) => item.label == candidate.label)) continue;
      result.add(candidate.toSuggestion());
      if (result.length >= limit) break;
    }

    return result;
  }

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}');
  }
}

class _EndpointResponse {
  final String endpoint;
  final List<Map<String, dynamic>> elements;

  const _EndpointResponse(this.endpoint, this.elements);
}

class _Candidate {
  final String label;
  final String category;
  final double latitude;
  final double longitude;
  final int distanceMeters;
  final String key;
  final String? placeId;

  const _Candidate({
    required this.label,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    required this.key,
    this.placeId,
  });

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
    placeId: placeId,
  );
}
