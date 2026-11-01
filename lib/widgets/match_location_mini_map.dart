import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:intl/intl.dart';
import 'package:matchme/models/match_model.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/theme/app_theme_tokens.dart';
import 'package:matchme/utils/map_theme_utils.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/widgets/safe_text.dart';

class MatchLocationMiniMap extends ConsumerWidget {
  final MatchLocation location;
  final String? title;
  final double height;
  final bool showTitle;
  // When false (single match — only one location exists), the header shows
  // just "Location" with no occurrence number. When true (rematches), it
  // shows "Location #1", "Location #2", etc.
  final bool showOccurrenceNumber;

  const MatchLocationMiniMap({
    super.key,
    required this.location,
    this.title,
    this.height = 140,
    this.showTitle = true,
    this.showOccurrenceNumber = true,
  });

  /// Singular header ("Location", no number) for a single match.
  /// Prefers the `matchLocationSingle` translation when available; otherwise
  /// derives it by stripping the number from the occurrence string
  /// ("Location #1" -> "Location") so every locale degrades gracefully.
  String _singleLocationTitle(LocalizationState l10n) {
    try {
      if (l10n.containsKey('matchLocationSingle')) {
        final v = l10n.getString('matchLocationSingle');
        if (v.trim().isNotEmpty && v != 'matchLocationSingle') return v;
      }
    } catch (_) {}
    final numbered = l10n.getString(
      'matchLocationOccurrence',
      params: {'count': '${location.occurrence}'},
    );
    var s = numbered
        .replaceAll(RegExp(r'\s*#\s*\d+'), '')
        .replaceAll(RegExp(r'\s*\d+\s*$'), '')
        .trim();
    s = s.replaceAll(RegExp(r'\s*[•\-:]\s*$'), '').trim();
    return s.isNotEmpty ? s : numbered;
  }

  // Areas (center/zoom pairs) already queued for tile pre-warming in this
  // session, so build() can fire-and-forget without re-fetching on rebuild.
  static final Set<String> _warmedAreas = {};

  /// Pre-fetches the tiles around [center]/[zoom] into the disk cache so the
  /// minimap renders from local storage the next time the device is offline.
  void _warmTilesForOffline(LatLng center, double zoom) {
    if (shouldSkipSupabaseCalls()) {
      // Offline: pre-warming can only produce DNS failures; tiles already on
      // disk are served to the TileLayer directly.
      return;
    }
    final key = '${center.latitude},${center.longitude},$zoom';
    if (_warmedAreas.contains(key)) return;
    _warmedAreas.add(key);
    if (kDebugMode) {
      print('[MapTiles] minimap warm request: $key');
    }
    unawaited(
      MapTileCacheService.instance.warmArea(
        centerLat: center.latitude,
        centerLng: center.longitude,
        zoom: zoom,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final effectiveTitle =
        title ??
        (showOccurrenceNumber
            ? l10n.getString(
                'matchLocationOccurrence',
                params: {'count': '${location.occurrence}'},
              )
            : _singleLocationTitle(l10n));

    // Offline-first: map TILES are served from the encrypted Hive tile cache
    // (MapTileCacheService) and fall back to the network when a tile is not
    // cached yet; the location DATA is cached in local storage (matches box +
    // per-match minimap snapshot). Tiles for the displayed area are
    // pre-warmed on every online view so the map renders offline later. The
    // match profile AppBar already shows the "You are offline" chip.

    // Privacy-coarse map: the server stores only a 2-decimal-rounded midpoint
    // (~1.1 km cell) plus a distance bucket — never an exact spot.
    // displayView() turns those into a viewport guaranteed to contain the real
    // match area (the coverage circle below always fits inside the frame).
    // No pin or dot is ever drawn: we must not imply an exact location.
    // Legacy rows carrying only exact coordinates are coarsened client-side.
    final view = location.displayView(viewportHeightPx: height);
    if (view != null) {
      final center = LatLng(view.centerLat, view.centerLng);
      final zoom = view.zoom;
      _warmTilesForOffline(center, zoom);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showTitle)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              // Single-line header: short title truncates if ever needed, but the
              // date+time always shows in full on the same line (never wrapped).
              child: Row(
                children: [
                  Icon(
                    Icons.location_on,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      effectiveTitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.visible,
                    ),
                  ),
                  if (location.createdAt != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '• ${_formatDateTime(context, ref, location.createdAt!, l10n)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      softWrap: true,
                    ),
                  ],
                ],
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: Stack(
                children: [
                  FlutterMap(
                    options: MapOptions(
                      initialCenter: center,
                      initialZoom: zoom,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.none,
                      ),
                      onTap: (_, _) => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => MatchLocationFullMapScreen(
                            location: location,
                            showOccurrenceNumber: showOccurrenceNumber,
                          ),
                        ),
                      ), // ignore: unnecessary_underscores
                    ),
                    children: [
                      const _OfflineMapBackgroundPattern(),
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'matchme.app',
                        tileBuilder: darkMapTileBuilderFor(
                          Theme.of(context).brightness,
                        ),
                        tileProvider: CachedMapTileProvider(),
                      ),
                      RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution('OpenStreetMap contributors'),
                        ],
                      ),
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: center,
                            radius: view.coverageRadiusMeters,
                            useRadiusInMeter: true,
                            color: Colors.blueAccent.withValues(alpha: 0.12),
                            borderColor: Colors.blueAccent.withValues(
                              alpha: 0.35,
                            ),
                            borderStrokeWidth: 2,
                          ),
                        ],
                      ),
                      // Intentionally no MarkerLayer: the minimap must never
                      // pinpoint a spot — only the approximate area above.
                    ],
                  ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => MatchLocationFullMapScreen(
                              location: location,
                              showOccurrenceNumber: showOccurrenceNumber,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.open_in_full,
                          size: 14,
                          color: Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // No displayable location (old matches) -> hide per requirement
    return const SizedBox.shrink();
  }

  String _formatDate(DateTime dt, LocalizationState l10n) {
    try {
      final local = dt.toLocal();
      return '${local.day}/${local.month}/${local.year}';
    } catch (_) {
      return '';
    }
  }

  /// Date + time on ONE line, same formatting as everywhere else in the app:
  /// locale long date + user's time-format setting (12h/24h/system).
  String _formatDateTime(
    BuildContext context,
    WidgetRef ref,
    DateTime dt,
    LocalizationState l10n,
  ) {
    try {
      final local = dt.toLocal();
      final datePart = DateFormat(
        'MMMM d, yyyy',
        l10n.currentLocale.languageCode,
      ).format(local);
      final timePart = formatTimeOfDateTimeWithPrefs(context, ref, l10n, local);
      final connector = l10n.getString('at');
      final at = (connector == 'at' || connector.isEmpty) ? 'at' : connector;
      return '$datePart, $at $timePart';
    } catch (_) {
      return _formatDate(dt, l10n);
    }
  }
}

class MatchLocationMiniMapList extends ConsumerWidget {
  final List<MatchLocation> locations;
  final String? matchType;
  final double height;

  const MatchLocationMiniMapList({
    super.key,
    required this.locations,
    this.matchType,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isProximity =
        matchType == null ||
        matchType == 'proximity' ||
        matchType == 'co_motion' ||
        matchType == 'manual_test';
    if (!isProximity) return const SizedBox.shrink();
    final displayable = locations
        .where((l) => l.hasDisplayableLocation)
        .toList();
    if (displayable.isEmpty) return const SizedBox.shrink();
    final l10n = ref.watch(localizationProvider);
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final sorted = List<MatchLocation>.from(displayable)
      ..sort((a, b) => a.occurrence.compareTo(b.occurrence));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(
                Icons.map_outlined,
                size: 14,
                color: AppThemeTokens.accentInk(
                  Colors.blue.shade700,
                  brightness,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.getString('matchMiniMapTitle'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.getString('matchMiniMapDescProximity'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        ...sorted.map(
          (loc) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MatchLocationMiniMap(
              location: loc,
              height: height,
              // Single location -> no occurrence number, just "Location".
              showOccurrenceNumber: sorted.length > 1,
            ),
          ),
        ),
      ],
    );
  }
}

class MatchLocationFullMapScreen extends ConsumerStatefulWidget {
  final MatchLocation location;
  final bool showOccurrenceNumber;
  const MatchLocationFullMapScreen({
    super.key,
    required this.location,
    this.showOccurrenceNumber = true,
  });

  @override
  ConsumerState<MatchLocationFullMapScreen> createState() =>
      _MatchLocationFullMapScreenState();
}

class _MatchLocationFullMapScreenState
    extends ConsumerState<MatchLocationFullMapScreen> {
  final MapController _mapController = MapController();
  final ValueNotifier<double> _cameraZoom = ValueNotifier(13);
  final ValueNotifier<LatLng?> _cameraCenter = ValueNotifier(null);
  bool _usesImperial = false;

  static final LatLngBounds _worldBounds = LatLngBounds(
    const LatLng(-85, -180),
    const LatLng(85, 180),
  );

  static const InteractionOptions _interaction = InteractionOptions(
    flags:
        InteractiveFlag.drag |
        InteractiveFlag.pinchMove |
        InteractiveFlag.pinchZoom |
        InteractiveFlag.doubleTapZoom |
        InteractiveFlag.scrollWheelZoom,
  );

  @override
  void initState() {
    super.initState();
    // Seed camera notifiers with the true initial view so the scale bar is
    // correct on the very first frame (before any onPositionChanged fires).
    final initial = _initialView();
    _cameraZoom.value = initial.zoom;
    _cameraCenter.value = initial.center;
    Future.microtask(() async {
      try {
        final imperial = await ref.read(unitSystemProvider.future);
        if (mounted) setState(() => _usesImperial = imperial);
      } catch (_) {}
    });
  }

  /// Initial center/zoom for this location (same values passed to FlutterMap).
  /// Coverage-based: the view always contains the real match area, never a
  /// precise spot (see utils/match_map_view.dart).
  ({LatLng center, double zoom}) _initialView() {
    final view = widget.location.displayView();
    if (view != null) {
      return (center: LatLng(view.centerLat, view.centerLng), zoom: view.zoom);
    }
    return (center: const LatLng(20, 0), zoom: 2);
  }

  @override
  void dispose() {
    _cameraZoom.dispose();
    _cameraCenter.dispose();
    super.dispose();
  }

  /// Singular header ("Location", no number) — same logic as the minimap.
  String _singleLocationTitle(LocalizationState l10n) {
    try {
      if (l10n.containsKey('matchLocationSingle')) {
        final v = l10n.getString('matchLocationSingle');
        if (v.trim().isNotEmpty && v != 'matchLocationSingle') return v;
      }
    } catch (_) {}
    final numbered = l10n.getString(
      'matchLocationOccurrence',
      params: {'count': '${widget.location.occurrence}'},
    );
    var s = numbered
        .replaceAll(RegExp(r'\s*#\s*\d+'), '')
        .replaceAll(RegExp(r'\s*\d+\s*$'), '')
        .trim();
    s = s.replaceAll(RegExp(r'\s*[•\-:]\s*$'), '').trim();
    return s.isNotEmpty ? s : numbered;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final title = widget.showOccurrenceNumber
        ? l10n.getString(
            'matchLocationOccurrence',
            params: {'count': '${widget.location.occurrence}'},
          )
        : _singleLocationTitle(l10n);
    final loc = widget.location;

    final initial = _initialView();
    final LatLng center = initial.center;
    final double zoom = initial.zoom;
    // Approximate-area circle only: no markers/polylines — the full map must
    // never pinpoint an exact location either.
    final view = loc.displayView();
    List<CircleMarker> circles = [];
    if (view != null) {
      circles = [
        CircleMarker(
          point: center,
          radius: view.coverageRadiusMeters,
          useRadiusInMeter: true,
          color: Colors.blueAccent.withValues(alpha: 0.12),
          borderColor: Colors.blueAccent.withValues(alpha: 0.35),
          borderStrokeWidth: 2,
        ),
      ];
    }

    // Keep notifiers in sync for scale indicator
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cameraZoom.value = zoom;
      _cameraCenter.value = center;
    });

    return Scaffold(
      appBar: AppBar(title: ShrinkText(title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: zoom,
              minZoom: 1,
              maxZoom: 18,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              cameraConstraint: CameraConstraint.contain(bounds: _worldBounds),
              interactionOptions: _interaction,
              onPositionChanged: (camera, hasGesture) {
                _cameraZoom.value = camera.zoom;
                _cameraCenter.value = camera.center;
              },
            ),
            children: [
              const _OfflineMapBackgroundPattern(),
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'matchme.app',
                tileBounds: _worldBounds,
                tileProvider: CachedMapTileProvider(),
                tileBuilder: darkMapTileBuilderFor(
                  Theme.of(context).brightness,
                ),
              ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
              if (circles.isNotEmpty) CircleLayer(circles: circles),
            ],
          ),
          // Recenter on the match area (never a device-GPS "my location" dot)
          Positioned(
            right: 12,
            bottom: 110,
            child: FloatingActionButton.small(
              heroTag: null,
              onPressed: () => _mapController.move(center, zoom),
              child: const Icon(Icons.center_focus_strong),
            ),
          ),
          // Zoom controls
          Positioned(
            right: 12,
            bottom: 12,
            child: _MatchMapZoomControls(
              controller: _mapController,
              minZoom: 1,
              maxZoom: 18,
            ),
          ),
          // Scale indicator
          Positioned(
            bottom: 12,
            left: 12,
            child: ValueListenableBuilder<double>(
              valueListenable: _cameraZoom,
              builder: (context, z, _) => ValueListenableBuilder<LatLng?>(
                valueListenable: _cameraCenter,
                builder: (context, c, _) => _buildScaleIndicator(
                  context,
                  z,
                  c,
                  center,
                  _usesImperial,
                  l10n,
                ),
              ),
            ),
          ),
          // Info card - moved to top so it doesn't hide zoom/scale controls
          Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: Colors.blue.shade700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.getString('matchMiniMapDescProximity'),
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Date + time on ONE line, same formatting as everywhere else:
                  // locale date + user's time-format setting (12h/24h/system).
                  if (loc.createdAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      () {
                        final local = loc.createdAt!.toLocal();
                        final datePart = DateFormat(
                          'MMMM d, yyyy',
                          l10n.currentLocale.languageCode,
                        ).format(local);
                        final timePart = formatTimeOfDateTimeWithPrefs(
                          context,
                          ref,
                          l10n,
                          local,
                        );
                        final connector = l10n.getString('at');
                        final at = (connector == 'at' || connector.isEmpty)
                            ? 'at'
                            : connector;
                        return '$datePart, $at $timePart';
                      }(),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      softWrap: true,
                      overflow: TextOverflow.visible,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Gap-free nice number for the scale bar (old fixed list had gaps, e.g.
  /// ~32m/~320m fell through and defaulted to 100km = "62 mi" with a full-width bar).
  double _niceScaleMeters(double groundMeters) {
    if (groundMeters <= 0 || !groundMeters.isFinite) return 100;
    final exp = (log(groundMeters) / ln10).floor();
    final pow10 = pow(10, exp).toDouble();
    if (!pow10.isFinite || pow10 <= 0) return 100;
    final frac = groundMeters / pow10;
    final snap = frac >= 7.5
        ? 10.0
        : frac >= 3.5
        ? 5.0
        : frac >= 1.5
        ? 2.0
        : 1.0;
    return snap * pow10;
  }

  Widget _buildScaleIndicator(
    BuildContext context,
    double zoom,
    LatLng? cameraCenter,
    LatLng? fallback,
    bool usesImperial,
    LocalizationState l10n,
  ) {
    final center = cameraCenter ?? fallback;
    if (center == null) return const SizedBox.shrink();
    if (!zoom.isFinite) return const SizedBox.shrink();
    final mpp = 156543.03392 * cos(center.latitude * pi / 180) / pow(2, zoom);
    if (mpp <= 0 || mpp.isNaN || !mpp.isFinite) return const SizedBox.shrink();
    const refBarPixels = 80.0;
    final groundMeters = refBarPixels * mpp;
    final niceMeters = _niceScaleMeters(groundMeters);
    final barWidth = (niceMeters / mpp).clamp(40.0, 160.0);
    final label = _formatDistance(niceMeters, usesImperial, l10n);
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
      child: SizedBox(
        width: max(barWidth, 40.0),
        height: 28,
        child: CustomPaint(
          painter: _ScaleBarPainter(
            barWidth: barWidth,
            label: label,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  String _formatDistance(double meters, bool imperial, LocalizationState l10n) {
    // Reuse same logic as Nearby utils to avoid extra import
    if (imperial) {
      final miles = meters / 1609.344;
      if (miles >= 0.1) {
        return '${miles.toStringAsFixed(miles >= 10 ? 0 : 1)} ${l10n.getString('unitMiles')}';
      }
      final feet = meters * 3.28084;
      return '${feet.round()} ${l10n.getString('unitFeet')}';
    }
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(meters >= 10000 ? 0 : 1)} ${l10n.getString('unitKilometers')}';
    }
    return '${meters.round()} ${l10n.getString('unitMeters')}';
  }
}

class _ScaleBarPainter extends CustomPainter {
  final double barWidth;
  final String label;
  final Color color;
  _ScaleBarPainter({
    required this.barWidth,
    required this.label,
    required this.color,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final barY = size.height / 2;
    const barLeft = 4.0;
    final barRight = barLeft + min(barWidth, size.width - 8);
    canvas.drawLine(Offset(barLeft, barY), Offset(barRight, barY), paint);
    canvas.drawLine(
      Offset(barLeft, barY - 4),
      Offset(barLeft, barY + 4),
      paint,
    );
    canvas.drawLine(
      Offset(barRight, barY - 4),
      Offset(barRight, barY + 4),
      paint,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 12,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(barLeft, barY - 14));
  }

  @override
  bool shouldRepaint(_ScaleBarPainter old) =>
      old.barWidth != barWidth || old.label != label || old.color != color;
}

class _MatchMapZoomControls extends StatelessWidget {
  final MapController controller;
  final double minZoom;
  final double maxZoom;
  const _MatchMapZoomControls({
    required this.controller,
    required this.minZoom,
    required this.maxZoom,
  });
  void _zoom(double delta) {
    final next = (controller.camera.zoom + delta).clamp(minZoom, maxZoom);
    controller.move(controller.camera.center, next);
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

class _OfflineMapBackgroundPattern extends StatelessWidget {
  const _OfflineMapBackgroundPattern();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(
        painter: _OfflineMapBackgroundPainter(
          isDark: Theme.of(context).brightness == Brightness.dark,
        ),
      ),
    );
  }
}

class _OfflineMapBackgroundPainter extends CustomPainter {
  const _OfflineMapBackgroundPainter({required this.isDark});

  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // Warm cartographic land base in light mode; deep slate in dark mode so
    // the pattern matches the filtered tiles instead of glaring.
    final baseColor = isDark
        ? const Color(0xFF0B1322)
        : const Color(0xFFF4F0E8);
    final parkColor = isDark
        ? const Color(0xFF12251C)
        : const Color(0xFFE9EEDD);
    final minorRoadColor = isDark
        ? const Color(0xFF243149)
        : const Color(0xFFFFFFFF);
    final majorRoadBorderColor = isDark
        ? const Color(0xFF1A2436)
        : const Color(0xFFE5E0D4);

    final bgPaint = Paint()..color = baseColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    // Soft landscape patches
    final parkPaint = Paint()
      ..color = parkColor
      ..style = PaintingStyle.fill;
    final park1 = Path()
      ..moveTo(size.width * 0.05, size.height * 0.15)
      ..cubicTo(
        size.width * 0.25,
        size.height * 0.05,
        size.width * 0.35,
        size.height * 0.35,
        size.width * 0.2,
        size.height * 0.5,
      )
      ..cubicTo(
        size.width * 0.1,
        size.height * 0.6,
        size.width * 0.02,
        size.height * 0.4,
        size.width * 0.05,
        size.height * 0.15,
      );
    canvas.drawPath(park1, parkPaint);

    final park2 = Path()
      ..moveTo(size.width * 0.7, size.height * 0.6)
      ..cubicTo(
        size.width * 0.9,
        size.height * 0.45,
        size.width * 0.98,
        size.height * 0.8,
        size.width * 0.85,
        size.height * 0.95,
      )
      ..cubicTo(
        size.width * 0.75,
        size.height * 0.95,
        size.width * 0.65,
        size.height * 0.8,
        size.width * 0.7,
        size.height * 0.6,
      );
    canvas.drawPath(park2, parkPaint);

    // Subtle road grid lines
    final minorRoadPaint = Paint()
      ..color = minorRoadColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final majorRoadBorder = Paint()
      ..color = majorRoadBorderColor
      ..strokeWidth = 5.0
      ..style = PaintingStyle.stroke;
    final majorRoadPaint = Paint()
      ..color = minorRoadColor
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    // Arterial routes
    final mainRoute = Path()
      ..moveTo(0, size.height * 0.65)
      ..cubicTo(
        size.width * 0.35,
        size.height * 0.6,
        size.width * 0.65,
        size.height * 0.4,
        size.width,
        size.height * 0.35,
      );
    canvas.drawPath(mainRoute, majorRoadBorder);
    canvas.drawPath(mainRoute, majorRoadPaint);

    final crossRoute = Path()
      ..moveTo(size.width * 0.45, 0)
      ..cubicTo(
        size.width * 0.5,
        size.height * 0.4,
        size.width * 0.55,
        size.height * 0.7,
        size.width * 0.6,
        size.height,
      );
    canvas.drawPath(crossRoute, majorRoadBorder);
    canvas.drawPath(crossRoute, majorRoadPaint);

    // Grid of secondary streets
    final gridPath = Path();
    for (double x = 40; x < size.width; x += 60) {
      gridPath.moveTo(x, 0);
      gridPath.lineTo(x, size.height);
    }
    for (double y = 30; y < size.height; y += 45) {
      gridPath.moveTo(0, y);
      gridPath.lineTo(size.width, y);
    }
    canvas.drawPath(gridPath, minorRoadPaint);
  }

  @override
  bool shouldRepaint(covariant _OfflineMapBackgroundPainter oldDelegate) =>
      oldDelegate.isDark != isDark;
}
