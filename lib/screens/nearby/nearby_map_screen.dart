import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _ts() => DateTime.now().toIso8601String();

final Crs _noWrap3857Crs = () {
  final max = pi * SphericalMercator.r;
  const tileSize = 256.0;
  final scaleFactor = 0.5 / (pi * SphericalMercator.r);
  final scales = List<double>.generate(
    19,
    (z) => tileSize * pow(2, z).toDouble() * scaleFactor,
    growable: false,
  );

  return Proj4Crs.fromFactory(
    code: 'EPSG:3857',
    proj4Projection: proj4.Projection.GOOGLE,
    origins: [Point<double>(-max, max)],
    bounds: Rect.fromLTRB(-max, -max, max, max),
    scales: scales,
  );
}();

class NearbyMapCell {
  final double lat;
  final double lng;
  final int count;

  const NearbyMapCell({
    required this.lat,
    required this.lng,
    required this.count,
  });
}

class NearbyMapScreen extends ConsumerStatefulWidget {
  const NearbyMapScreen({super.key});

  @override
  ConsumerState<NearbyMapScreen> createState() => _NearbyMapScreenState();
}

class _NearbyMapScreenState extends ConsumerState<NearbyMapScreen> {
  static final LatLngBounds _worldBounds = LatLngBounds(
    const LatLng(-85, -180),
    const LatLng(85, 180),
  );

  static const InteractionOptions _interaction = InteractionOptions(
    flags: InteractiveFlag.drag |
        InteractiveFlag.flingAnimation |
        InteractiveFlag.pinchMove |
        InteractiveFlag.pinchZoom |
        InteractiveFlag.doubleTapZoom |
        InteractiveFlag.scrollWheelZoom,
  );

  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  Timer? _debounce;
  Timer? _pollTimer;
  ProviderSubscription<AsyncValue<bool>>? _connectivitySub;
  LatLng? _lastUserCenter;
  double? _lastDefaultRadiusKm;

  bool _loading = false;
  String? _error;
  List<NearbyMapCell> _cells = const [];
  NearbyMapCell? _selectedCell;
  int _lastCellMeters = 2000;

  @override
  void initState() {
    super.initState();
    debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: initState');
    Future.microtask(() async {
      debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: refreshLocation start');
      await ref.read(currentLocationProvider.notifier).refreshLocation();
      debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: refreshLocation done');
    });

    _connectivitySub = ref.listenManual<AsyncValue<bool>>(connectivityProvider, (previous, next) {
      final isOnline = next.value ?? false;
      if (!isOnline) return;
      final center = _lastUserCenter;
      final radiusKm = _lastDefaultRadiusKm;
      if (center == null || radiusKm == null) return;
      _scheduleFetch(userCenter: center, defaultRadiusKm: radiusKm);
    });
  }

  @override
  void dispose() {
    debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: dispose');
    _debounce?.cancel();
    _pollTimer?.cancel();
    _connectivitySub?.close();
    super.dispose();
  }

  int _cellMetersForRadiusKm(double radiusKm) {
    if (radiusKm <= 2) return 800;
    if (radiusKm <= 10) return 1500;
    if (radiusKm <= 30) return 2500;
    if (radiusKm <= 100) return 6000;
    return 15000;
  }

  double _initialZoomForRadiusKm(double radiusKm) {
    if (radiusKm <= 1) return 14;
    if (radiusKm <= 3) return 13;
    if (radiusKm <= 8) return 12;
    if (radiusKm <= 20) return 11;
    if (radiusKm <= 50) return 10;
    if (radiusKm <= 120) return 9;
    return 3;
  }

  double _currentViewRadiusKm({required double fallbackKm}) {
    try {
      final camera = _mapController.camera;
      final bounds = camera.visibleBounds;
      final center = camera.center;
      final northPoint = LatLng(bounds.north, center.longitude);
      final meters = _distance(center, northPoint);
      if (meters.isFinite && meters > 0) return meters / 1000.0;
      return fallbackKm;
    } catch (_) {
      return fallbackKm;
    }
  }

  void _scheduleFetch({required LatLng userCenter, required double defaultRadiusKm}) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_fetchCells(userCenter: userCenter, defaultRadiusKm: defaultRadiusKm));
    });
  }

  void _ensurePolling({required LatLng userCenter, required double defaultRadiusKm}) {
    _lastUserCenter = userCenter;
    _lastDefaultRadiusKm = defaultRadiusKm;

    _pollTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (_loading) return;
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
      final center = _lastUserCenter;
      final radiusKm = _lastDefaultRadiusKm;
      if (center == null || radiusKm == null) return;
      unawaited(_fetchCells(userCenter: center, defaultRadiusKm: radiusKm));
    });
  }

  int _stableHash32(String input) {
    final bytes = utf8.encode(input);
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  LatLng _jitteredCellPoint(String requestingUserId, NearbyMapCell cell) {
    final seed = _stableHash32(
      'cell|$requestingUserId|${cell.lat.toStringAsFixed(6)}|${cell.lng.toStringAsFixed(6)}',
    );
    final rng = Random(seed);

    final maxMeters = max(25.0, _lastCellMeters * 0.35);
    final r = rng.nextDouble() * maxMeters;
    final theta = rng.nextDouble() * pi * 2;
    final dNorth = cos(theta) * r;
    final dEast = sin(theta) * r;

    final lat = cell.lat + (dNorth / 111000.0);
    final cosLat = cos(cell.lat * pi / 180.0).abs();
    final lon = cell.lng + (dEast / (111000.0 * max(cosLat, 0.15)));

    return LatLng(lat, lon);
  }

  Color _cellColor(String requestingUserId, NearbyMapCell cell) {
    const palette = <Color>[
      Colors.deepPurple,
      Colors.indigo,
      Colors.teal,
      Colors.pink,
      Colors.blueGrey,
    ];
    final seed = _stableHash32(
      'color|$requestingUserId|${cell.lat.toStringAsFixed(6)}|${cell.lng.toStringAsFixed(6)}',
    );
    return palette[seed % palette.length];
  }

  Future<void> _fetchCells({required LatLng userCenter, required double defaultRadiusKm}) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final viewRadiusKm = _currentViewRadiusKm(fallbackKm: defaultRadiusKm);

    LatLng queryCenter = userCenter;
    double queryRadiusKm = defaultRadiusKm;
    if (viewRadiusKm > defaultRadiusKm) {
      try {
        queryCenter = _mapController.camera.center;
        queryRadiusKm = viewRadiusKm;
      } catch (_) {
        queryCenter = userCenter;
        queryRadiusKm = defaultRadiusKm;
      }
    }

    final cellMeters = _cellMetersForRadiusKm(queryRadiusKm);

    debugPrint(
      '[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells start '
      '(viewRadiusKm=${viewRadiusKm.toStringAsFixed(2)}, defaultRadiusKm=${defaultRadiusKm.toStringAsFixed(2)}, '
      'queryCenter=${queryCenter.latitude.toStringAsFixed(6)},${queryCenter.longitude.toStringAsFixed(6)}, '
      'queryRadiusKm=${queryRadiusKm.toStringAsFixed(2)}, cellMeters=$cellMeters)',
    );

    setState(() {
      _loading = true;
      _error = null;
      _lastCellMeters = cellMeters;
    });

    try {
      final result = await Supabase.instance.client.rpc(
        'get_visible_online_user_map_cells',
        params: <String, dynamic>{
          'p_requesting_user_id': userId,
          'p_center_lat': queryCenter.latitude,
          'p_center_lng': queryCenter.longitude,
          'p_radius_km': queryRadiusKm,
          'p_cell_meters': cellMeters,
          'p_recent_minutes': 30,
        },
      );

      final rows = (result as List<dynamic>?) ?? const [];
      final parsed = <NearbyMapCell>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final lat = (row['cell_center_lat'] as num?)?.toDouble();
        final lng = (row['cell_center_lng'] as num?)?.toDouble();
        final count = (row['user_count'] as num?)?.toInt();
        if (lat == null || lng == null || count == null) continue;
        if (count <= 0) continue;
        parsed.add(NearbyMapCell(lat: lat, lng: lng, count: count));
      }

      var totalUsers = 0;
      for (final c in parsed) {
        totalUsers += c.count;
      }
      debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells rpc ok (rows=${rows.length}, cells=${parsed.length}, totalUsers=$totalUsers)');

      if (!mounted) return;
      setState(() {
        _cells = parsed;
        if (_selectedCell != null) {
          final stillExists = parsed.any((c) => c.lat == _selectedCell!.lat && c.lng == _selectedCell!.lng);
          if (!stillExists) _selectedCell = null;
        }
      });
    } catch (e) {
      debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells error: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _cells = const [];
        _selectedCell = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      debugPrint('[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells done');
    }
  }

  int _approxVisibleUsersInView() {
    var total = 0;
    for (final c in _cells) {
      total += c.count;
    }
    return total;
  }

  List<Marker> _buildCellMarkers(
    BuildContext context, {
    required String requestingUserId,
  }) {
    final markers = <Marker>[];
    for (final c in _cells) {
      final isSelected = _selectedCell != null && _selectedCell!.lat == c.lat && _selectedCell!.lng == c.lng;
      final size = (18.0 + (log(c.count + 1) / ln2) * 4.0).clamp(16.0, 44.0);
      final label = c.count >= 100 ? '99+' : c.count.toString();
      final point = _jitteredCellPoint(requestingUserId, c);
      final baseColor = _cellColor(requestingUserId, c);

      markers.add(
        Marker(
          point: point,
          width: size + 10,
          height: size + 10,
          child: Center(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _selectedCell = c;
                });
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isSelected ? Colors.orange : baseColor).withValues(alpha: 0.78),
                  border: Border.all(
                    width: isSelected ? 3 : 2,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: c.count == 1
                    ? Container(
                        width: max(5.0, size * 0.26),
                        height: max(5.0, size * 0.26),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.95),
                          shape: BoxShape.circle,
                        ),
                      )
                    : Text(
                        label,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                        textAlign: TextAlign.center,
                      ),
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  Marker _buildUserMarker(LatLng userLatLng) {
    return Marker(
      point: userLatLng,
      width: 54,
      height: 54,
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blueAccent.withValues(alpha: 0.18),
              ),
            ),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.blueAccent,
                border: Border.all(width: 3, color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, LocalizationState l10n) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.labelMedium ?? const TextStyle(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.blueAccent,
                      border: Border.all(width: 2, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.getString('mapLegendYou')),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.deepPurple.withValues(alpha: 0.78),
                      border: Border.all(width: 2, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.getString('mapLegendOnlineUsersApprox')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final userId = Supabase.instance.client.auth.currentUser?.id;

    if (userId == null) {
      return Scaffold(body: Center(child: Text(l10n.getString('generalError'))));
    }

    final profileAsync = ref.watch(userProfileProvider(userId));
    final position = ref.watch(currentLocationProvider);

    return profileAsync.when(
      data: (profile) {
        final defaultRadiusMeters = (profile?.matchRadiusDefault ?? 5000).toDouble();
        final defaultRadiusKm = max(defaultRadiusMeters / 1000.0, 0.5);

        final userLatLng = position != null
            ? LatLng(position.latitude, position.longitude)
            : null;
        if (userLatLng != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _ensurePolling(userCenter: userLatLng, defaultRadiusKm: defaultRadiusKm);
          });
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.getString('homeNearby')),
            actions: [
              IconButton(
                onPressed: userLatLng == null
                    ? null
                    : () {
                        _mapController.move(
                          userLatLng,
                          _initialZoomForRadiusKm(defaultRadiusKm),
                        );
                        _scheduleFetch(userCenter: userLatLng, defaultRadiusKm: defaultRadiusKm);
                      },
                icon: const Icon(Icons.my_location),
              ),
            ],
          ),
          body: userLatLng == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        crs: _noWrap3857Crs,
                        initialCenter: userLatLng,
                        initialZoom: _initialZoomForRadiusKm(defaultRadiusKm),
                        minZoom: 1,
                        maxZoom: 18,
                        cameraConstraint: CameraConstraint.contain(bounds: _worldBounds),
                        interactionOptions: _interaction,
                        onPositionChanged: (camera, hasGesture) {
                          if (!hasGesture) return;
                          _scheduleFetch(userCenter: userLatLng, defaultRadiusKm: defaultRadiusKm);
                        },
                        onMapReady: () {
                          _scheduleFetch(userCenter: userLatLng, defaultRadiusKm: defaultRadiusKm);
                        },
                        onTap: (tapPosition, point) {
                          if (_selectedCell == null) return;
                          setState(() {
                            _selectedCell = null;
                          });
                        },
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'matchme.app',
                          tileBounds: _worldBounds,
                        ),
                        CircleLayer(
                          circles: [
                            CircleMarker(
                              point: userLatLng,
                              radius: defaultRadiusKm * 1000.0,
                              useRadiusInMeter: true,
                              color: Colors.blueAccent.withValues(alpha: 0.12),
                              borderColor: Colors.blueAccent.withValues(alpha: 0.35),
                              borderStrokeWidth: 2,
                            ),
                          ],
                        ),
                        MarkerLayer(
                          markers: _buildCellMarkers(
                            context,
                            requestingUserId: userId,
                          ),
                        ),
                        MarkerLayer(markers: [_buildUserMarker(userLatLng)]),
                      ],
                    ),
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: _MapZoomControls(
                        controller: _mapController,
                        minZoom: 1,
                        maxZoom: 18,
                      ),
                    ),
                    if (_loading)
                      const Positioned(
                        top: 12,
                        left: 12,
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _legend(context, l10n),
                    ),
                    Positioned(
                      top: 12,
                      left: 44,
                      child: Material(
                        elevation: 0,
                        borderRadius: BorderRadius.circular(999),
                        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Text(
                            l10n.getString(
                              'mapShowingApproxUsers',
                              params: {'count': _approxVisibleUsersInView().toString()},
                            ),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        ),
                      ),
                    ),
                    if (_selectedCell != null)
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Material(
                          elevation: 2,
                          borderRadius: BorderRadius.circular(12),
                          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  l10n.getString(
                                    'mapApproxUsersHere',
                                    params: {'count': _selectedCell!.count.toString()},
                                  ),
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _selectedCell = null;
                                    });
                                  },
                                  child: Text(l10n.getString('generalClose')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_error != null)
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Material(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onErrorContainer,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, s) => Scaffold(body: Center(child: Text(e.toString()))),
    );
  }
}

class OnlineWorldMapScreen extends ConsumerStatefulWidget {
  const OnlineWorldMapScreen({super.key});

  @override
  ConsumerState<OnlineWorldMapScreen> createState() => _OnlineWorldMapScreenState();
}

class _OnlineWorldMapScreenState extends ConsumerState<OnlineWorldMapScreen> {
  static final LatLngBounds _worldBounds = LatLngBounds(
    const LatLng(-85, -180),
    const LatLng(85, 180),
  );

  static const InteractionOptions _interaction = InteractionOptions(
    flags: InteractiveFlag.drag |
        InteractiveFlag.flingAnimation |
        InteractiveFlag.pinchMove |
        InteractiveFlag.pinchZoom |
        InteractiveFlag.doubleTapZoom |
        InteractiveFlag.scrollWheelZoom,
  );

  final MapController _mapController = MapController();

  bool _loading = false;
  String? _error;
  List<_CountryCount> _counts = const [];
  final Map<String, LatLng> _countryCenters = {};
  final Map<String, String> _countryNames = {};
  int? _totalOnline;
  String? _lastLanguageCode; // Track last used language to detect changes

  @override
  void initState() {
    super.initState();
    Future.microtask(_refresh);
  }

  Future<void> _moveToUserCountry() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      final res = await Supabase.instance.client
          .from('user_session')
          .select('country')
          .eq('user_id', userId)
          .order('last_active_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (res == null) return;
      final countryCode = (res['country'] as String?)?.toUpperCase();
      if (countryCode == null || countryCode.isEmpty) return;

      if (!_countryCenters.containsKey(countryCode)) {
        final l10n = ref.read(localizationProvider);
        await _ensureCountryCenters([countryCode], l10n.currentLocale.languageCode);
      }

      final center = _countryCenters[countryCode];
      if (center != null) {
        _mapController.move(center, 5.0);
      }
    } catch (e) {
      debugPrint('Error moving to user country: $e');
      if (mounted) {
        setState(() {
          _error = 'Could not find location: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final l10n = ref.read(localizationProvider);
    final languageCode = l10n.currentLocale.languageCode;

    // Clear cache if language changed to get localized country names
    if (_lastLanguageCode != null && _lastLanguageCode != languageCode) {
      _countryCenters.clear();
      _countryNames.clear();
    }
    _lastLanguageCode = languageCode;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final results = await Future.wait<dynamic>([
        Supabase.instance.client.rpc(
          'get_online_user_counts_by_country',
          params: <String, dynamic>{},
        ),
        if (userId != null)
          Supabase.instance.client.rpc(
            'get_online_users_count',
            params: <String, dynamic>{'p_user_id': userId},
          )
        else
          Future.value(null),
      ]);

      final rows = results[0];
      final totalOnlineRaw = results[1];

      final list = (rows as List<dynamic>?) ?? const [];
      final parsed = <_CountryCount>[];
      for (final row in list) {
        if (row is! Map) continue;
        final code = (row['country'] ?? '').toString().trim().toUpperCase();
        final count = (row['user_count'] as num?)?.toInt();
        if (code.isEmpty || count == null || count <= 0) continue;
        parsed.add(_CountryCount(countryCode: code, count: count));
      }

      final codes = parsed.map((e) => e.countryCode).toSet().toList(growable: false);
      await _ensureCountryCenters(codes, l10n.currentLocale.languageCode);

      if (!mounted) return;
      setState(() {
        _counts = parsed;
        _totalOnline = (totalOnlineRaw as num?)?.toInt();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _counts = const [];
        _totalOnline = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  // Map of ISO country codes to English names for Nominatim API
  // This is needed because Nominatim interprets ambiguous codes (like CO = Colombia vs Colorado)
  static const _countryCodeToName = {
    'CO': 'Colombia',
    'US': 'United States',
    'GB': 'United Kingdom',
    'AE': 'United Arab Emirates',
    // Add other common codes that might be ambiguous
  };

  String _getCountryNameForCode(String countryCode) {
    return _countryCodeToName[countryCode.toUpperCase()] ?? countryCode;
  }

  // Supported languages by Nominatim API (OpenStreetMap)
  // Nominatim supports all common languages including Hebrew
  static const _supportedLanguages = {'en', 'es', 'he', 'fr', 'de', 'ar', 'zh'};

  String _getSupportedLanguageCode(String languageCode) {
    // Return the requested language if supported, otherwise fall back to English
    return _supportedLanguages.contains(languageCode) ? languageCode : 'en';
  }

  Future<void> _ensureCountryCenters(List<String> codes, String languageCode) async {
    final supportedLangCode = _getSupportedLanguageCode(languageCode);
    final missing = codes.where((c) => !_countryCenters.containsKey(c)).toList(growable: false);
    if (missing.isEmpty) return;

    for (final code in missing) {
      try {
        // Use Nominatim (OpenStreetMap) API for geocoding with language support
        // This API supports Hebrew, English, Spanish and many other languages
        // Use country name instead of code to avoid ambiguity (e.g., CO = Colombia vs Colorado)
        final countryName = _getCountryNameForCode(code);
        final uri = Uri.https(
          'nominatim.openstreetmap.org',
          '/search',
          <String, String>{
            'q': countryName,
            'format': 'json',
            'accept-language': supportedLangCode,
            'limit': '1',
            'addressdetails': '0',
            'countrycodes': code.toLowerCase(), // Use country code filter to ensure we get the right country
          },
        );

        final resp = await http.get(uri, headers: {'User-Agent': 'MatchMe/1.0'}).timeout(const Duration(seconds: 8));
        if (resp.statusCode < 200 || resp.statusCode >= 300) continue;
        
        final decoded = jsonDecode(resp.body);
        if (decoded is! List || decoded.isEmpty) continue;
        
        final first = decoded[0];
        if (first is! Map) continue;
        
        final lat = double.tryParse(first['lat'] as String? ?? '');
        final lon = double.tryParse(first['lon'] as String? ?? '');
        final name = first['name'] as String?;
        
        if (lat == null || lon == null) continue;
        
        _countryCenters[code] = LatLng(lat, lon);
        if (name != null) _countryNames[code] = name;
      } catch (_) {}
    }
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }

  List<Marker> _buildMarkers(BuildContext context) {
    final markers = <Marker>[];
    for (final entry in _counts) {
      final center = _countryCenters[entry.countryCode];
      if (center == null) continue;
      
      final name = _countryNames[entry.countryCode] ?? entry.countryCode;

      markers.add(
        Marker(
          point: center,
          width: 140,
          height: 60,
          child: IgnorePointer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 2),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Text(
                      _formatCount(entry.count),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('homeOnline')),
        actions: [
          if (_totalOnline != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      l10n.getString(
                        'onlineMapTotalOnline',
                        params: {'count': _totalOnline.toString()},
                      ),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              crs: _noWrap3857Crs,
              initialCenter: const LatLng(20, 0),
              initialZoom: 1.6,
              minZoom: 1,
              maxZoom: 18,
              cameraConstraint: CameraConstraint.contain(bounds: _worldBounds),
              interactionOptions: _interaction,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'matchme.app',
                tileBounds: _worldBounds,
              ),
              MarkerLayer(markers: _buildMarkers(context)),
            ],
          ),
          Positioned(
            right: 12,
            bottom: 110,
            child: FloatingActionButton.small(
              heroTag: null,
              onPressed: _loading ? null : _moveToUserCountry,
              child: const Icon(Icons.my_location),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: _MapZoomControls(
              controller: _mapController,
              minZoom: 1,
              maxZoom: 18,
            ),
          ),
          if (_loading)
            const Positioned(
              top: 12,
              left: 12,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_error != null)
            Positioned(
              bottom: 12,
              left: 12,
              right: 12,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CountryCount {
  final String countryCode;
  final int count;

  const _CountryCount({required this.countryCode, required this.count});
}

class _MapZoomControls extends StatelessWidget {
  final MapController controller;
  final double minZoom;
  final double maxZoom;

  const _MapZoomControls({
    required this.controller,
    required this.minZoom,
    required this.maxZoom,
  });

  void _zoom(double delta) {
    final camera = controller.camera;
    final nextZoom = (camera.zoom + delta).clamp(minZoom, maxZoom);
    controller.move(camera.center, nextZoom);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: null,
            onPressed: () => _zoom(1),
            child: const Icon(Icons.add),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: null,
            onPressed: () => _zoom(-1),
            child: const Icon(Icons.remove),
          ),
        ],
      ),
    );
  }
}
