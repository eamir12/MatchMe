import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:matchme/models/location_share_session.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/screens/location_share/location_share_duration_dialog.dart';
import 'package:matchme/utils/map_theme_utils.dart';
import 'package:matchme/utils/lat_lng_smoother.dart';
import 'package:matchme/utils/localized_duration.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/widgets/safe_text.dart';

class LocationShareMapScreen extends ConsumerStatefulWidget {
  const LocationShareMapScreen({super.key});

  @override
  ConsumerState<LocationShareMapScreen> createState() =>
      _LocationShareMapScreenState();
}

class _LocationShareMapScreenState extends ConsumerState<LocationShareMapScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final MapController _mapController = MapController();
  Timer? _uiTimer;
  bool _initialBothCentered = false;
  LocationShareNotifier? _shareNotifier;
  late final LatLngSmoother _myPositionSmoother;
  LatLng? _displayMyPosition;
  LatLng? _lastRawMyPosition;

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
    WidgetsBinding.instance.addObserver(this);
    _myPositionSmoother = LatLngSmoother(
      vsync: this,
      onChanged: (position) {
        if (!mounted) return;
        setState(() => _displayMyPosition = position);
      },
    );
    // Cache the notifier so dispose() can unsubscribe without using ref,
    // which is unsafe when the widget is being unmounted.
    _shareNotifier = ref.read(locationShareProvider.notifier);
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    // Trigger one-shot location acquisition for the receiver's self-marker
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(currentLocationProvider.notifier).refreshLocation();
        ref.read(locationShareProvider.notifier).subscribeToLocationUpdates();
        _markShareSeen();
      }
    });
  }

  /// The map is the item a live-location alert points at, so a share that is
  /// displayed here counts as seen: mark its inbox rows read so the bell, the
  /// Matches badge and the OS icon clear without touching the inbox first.
  ///
  /// Runs on open, whenever the share changes and whenever the inbox changes
  /// (the row can land after the map is already showing, e.g. a cold start
  /// from the OS notification). Marking is idempotent: once the rows are read
  /// this is a no-op.
  void _markShareSeen() {
    if (!mounted) return;
    final matchId = ref.read(locationShareProvider)?.matchId.trim() ?? '';
    if (matchId.isEmpty) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // Deferred like the meet-up surface registry: provider listeners can fire
    // while the tree is building, where a synchronous provider mutation trips
    // Riverpod's modify-during-build assert.
    unawaited(
      Future.microtask(() {
        if (!mounted) return;
        ref.read(notificationInboxProvider.notifier).markMatchKindsRead(
          matchId,
          const {'location_share'},
        );
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (!mounted) return;
    if (lifecycleState == AppLifecycleState.paused ||
        lifecycleState == AppLifecycleState.inactive ||
        lifecycleState == AppLifecycleState.detached) {
      // Hand off to native background service instead of unsubscribing
      ref.read(locationShareProvider.notifier).handoffToNativeService();
    } else if (lifecycleState == AppLifecycleState.resumed) {
      // Take back from native service and resume Flutter GPS
      ref.read(locationShareProvider.notifier).takeoverFromNativeService();
      // Also re-subscribe to position updates for receiving
      ref.read(locationShareProvider.notifier).subscribeToLocationUpdates();
      _markShareSeen();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _uiTimer?.cancel();
    // Keep the position channel alive while a share session is active: the
    // session outlives the map screen (banner, chat) and the app-level
    // lifecycle observer now owns handoff/takeover. Unsubscribing here used
    // to silence an active sender and starve receivers until the map was
    // reopened. Channels are torn down by the provider on stop/cleanup.
    try {
      if (_shareNotifier != null) {
        final session = ref.read(locationShareProvider);
        if (session == null) {
          _shareNotifier!.unsubscribeFromLocationUpdates();
        }
      }
    } catch (_) {}
    _myPositionSmoother.dispose();
    super.dispose();
  }

  Future<void> _handleShareFromMap(LocationShareSession session) async {
    // Check location permissions before starting sharing back
    final locationService = ref.read(locationServiceProvider);
    final hasPermission = await locationService.handleLocationPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref
                  .read(localizationProvider)
                  .getString('locationPermissionDenied'),
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    final duration = await showDialog<Duration?>(
      context: context,
      builder: (context) =>
          LocationShareDurationDialog(otherUserName: session.otherUserName),
    );

    if (duration == null || !mounted) return;

    await ref
        .read(locationShareProvider.notifier)
        .startSharingBack(duration: duration);
  }

  void _fitCameraToBounds(LatLng pointA, LatLng pointB) {
    final distance = const Distance().as(LengthUnit.Meter, pointA, pointB);

    // When users are close together (< 50m), use a fixed high zoom
    // instead of fitting a degenerate bounds (zero-area) which causes
    // the map to zoom out unpredictably. GPS noise can make two people
    // at the same spot appear 5-15m apart.
    if (distance < 50) {
      final zoom = distance < 20 ? 19.0 : 18.0;
      _mapController.move(
        LatLng(
          (pointA.latitude + pointB.latitude) / 2,
          (pointA.longitude + pointB.longitude) / 2,
        ),
        zoom,
      );
      return;
    }

    final bounds = LatLngBounds.fromPoints([pointA, pointB]);
    _mapController.fitCamera(
      CameraFit.insideBounds(
        bounds: bounds,
        padding: const EdgeInsets.all(60),
        maxZoom: 18,
      ),
    );
  }

  void _centerOnBothUsers(LocationShareSession session) {
    final myPos = session.myPosition;
    final otherPos = session.otherPosition;

    if (myPos != null && otherPos != null) {
      _fitCameraToBounds(myPos, otherPos);
    } else if (myPos != null) {
      _mapController.move(myPos, 19);
    } else if (otherPos != null) {
      _mapController.move(otherPos, 19);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(locationShareProvider);
    final l10n = ref.watch(localizationProvider);

    // A share that starts (or replaces another) while this map is open is
    // displayed the moment it lands, so it is seen here too.
    ref.listen<LocationShareSession?>(locationShareProvider, (_, _) {
      _markShareSeen();
    });
    // The inbox can load after the map is already showing the share; every
    // inbox change is another chance to mark it seen (a no-op once read).
    ref.listen<NotificationInboxState>(notificationInboxProvider, (_, _) {
      _markShareSeen();
    });

    if (session == null) {
      return Scaffold(
        appBar: AppBar(
          title: ShrinkText(l10n.getString('locationShareMapTitle')),
        ),
        body: Center(child: Text(l10n.getString('locationShareExpired'))),
      );
    }

    final currentPosition = ref.watch(currentLocationProvider);
    final rawMyPos =
        session.myPosition ??
        (currentPosition != null
            ? LatLng(currentPosition.latitude, currentPosition.longitude)
            : null);
    final otherPos = session.otherPosition;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (rawMyPos != null && _lastRawMyPosition != rawMyPos) {
      _lastRawMyPosition = rawMyPos;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _lastRawMyPosition != rawMyPos) return;
        _myPositionSmoother.update(rawMyPos, immediate: reduceMotion);
      });
    }
    final displayMyPos = rawMyPos == null
        ? null
        : (_displayMyPosition ?? rawMyPos);

    final center = rawMyPos ?? otherPos;
    if (center == null) {
      return Scaffold(
        appBar: AppBar(
          title: ShrinkText(l10n.getString('locationShareMapTitle')),
        ),
        body: Center(child: Text(l10n.getString('locationShareWaiting'))),
      );
    }

    final markers = <Marker>[];
    final otherIsSharing = session.otherStatus == ShareStatus.sharing;
    final samePosition =
        rawMyPos != null &&
        otherPos != null &&
        rawMyPos.latitude == otherPos.latitude &&
        rawMyPos.longitude == otherPos.longitude;

    if (samePosition) {
      // Combined marker: show both users side-by-side so neither hides the other
      markers.add(
        _buildCombinedMarker(
          position: displayMyPos ?? rawMyPos,
          myPhoto: session.myUserPhoto,
          otherPhoto: session.otherUserPhoto,
          otherStatus: session.otherStatus,
        ),
      );
    } else {
      // Separate markers: self on top (rendered last)
      if (otherPos != null && otherIsSharing) {
        markers.add(
          _buildOtherMarker(
            otherPos,
            session.otherUserPhoto,
            session.otherStatus,
          ),
        );
      }
      if (displayMyPos != null) {
        markers.add(
          _buildSelfMarker(displayMyPos, photoUrl: session.myUserPhoto),
        );
      }
    }

    // Compute initial zoom based on distance between users.
    // Zoom 19 is the max useful OSM zoom (tiles available) and shows
    // ~20m on the scale bar — the tightest view that still looks clear.
    // Use generous thresholds: GPS noise alone can make two people at the
    // same spot appear 5-15m apart, so anything under 50m means "together".
    // When only one position is known (the common case on first render),
    // default to zoom 19 — on a location-sharing map the users are nearby.
    double initialZoom = 19;
    if (rawMyPos != null && otherPos != null) {
      final distance = const Distance().as(
        LengthUnit.Meter,
        rawMyPos,
        otherPos,
      );
      if (distance < 50) {
        initialZoom = 19;
      } else if (distance < 200) {
        initialZoom = 18;
      } else if (distance < 500) {
        initialZoom = 16;
      } else if (distance < 2000) {
        initialZoom = 14;
      } else {
        initialZoom = 13;
      }
    }

    final useImperial = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    String? distanceText;
    if (rawMyPos != null && otherPos != null) {
      final distance = const Distance().as(
        LengthUnit.Meter,
        rawMyPos,
        otherPos,
      );
      distanceText = formatDistanceWithImperial(distance, useImperial, l10n);
    }

    // When the second position first becomes available (e.g. otherPos was
    // null on initial render), re-center the map after a short delay so
    // FlutterMap has time to finish its initial layout.
    if (rawMyPos != null && otherPos != null && !_initialBothCentered) {
      _initialBothCentered = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _centerOnBothUsers(session);
      });
    }

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: initialZoom,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
              interactionOptions: _interaction,
              cameraConstraint: const CameraConstraint.containLatitude(85, -85),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.matchme.app',
                // Disk-cached tiles: repeat views paint instantly instead of
                // re-downloading every tile from the throttled public server.
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
              MarkerLayer(markers: markers),
            ],
          ),
          _buildTopBar(context, session, l10n),
          _buildTimerBar(session, l10n),
          _buildDistanceCounter(distanceText),
          _buildLegend(session, l10n),
          Positioned(
            right: 12,
            bottom: 100,
            child: _MapZoomControls(
              controller: _mapController,
              minZoom: 1,
              maxZoom: 20,
            ),
          ),
          _buildScaleBar(),
          _buildBottomControls(session, l10n),
          if (session.otherStatus == ShareStatus.stopped)
            _buildStoppedOverlay(session, l10n),
          if (session.otherStatus == ShareStatus.unknown)
            _buildStaleOverlay(session, l10n),
        ],
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.getString('locationShareMapTitle'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _statusText(session, l10n),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusBadge(session),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _timeSuffix(LocationShareSession session, LocalizationState l10n) {
    if (session.expiresAt == null) {
      return '(${l10n.getString('locationShareUntilOff')})';
    }
    final remaining = session.timeRemaining;
    if (remaining == null || remaining.inSeconds <= 0) return '';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes % 60;
    final seconds = remaining.inSeconds % 60;
    // Each unit is translated on its own so it picks the right plural form
    // ("1 hour", not "1 hours").
    final duration = hours > 0
        ? formatDurationParts(l10n.getString, hours: hours, minutes: minutes)
        : formatDurationParts(
            l10n.getString,
            minutes: minutes,
            seconds: seconds,
          );
    if (duration.isEmpty) return '';
    final remainingText = l10n.getString(
      'locationShareCountdownRemaining',
      params: {'duration': duration},
    );
    return '($remainingText)';
  }

  String _statusText(LocationShareSession session, LocalizationState l10n) {
    if (session.otherStatus == ShareStatus.stopped) {
      try {
        return l10n
            .getString('locationShareOtherStopped')
            .replaceAll('{name}', session.otherUserName);
      } catch (_) {
        return '${session.otherUserName} stopped sharing their location';
      }
    }
    final timeSuffix = _timeSuffix(session, l10n);
    if (session.myStatus == ShareStatus.sharing &&
        session.otherStatus == ShareStatus.sharing) {
      return '${l10n.getString('locationShareActive')} $timeSuffix';
    } else if (session.myStatus == ShareStatus.paused) {
      return l10n.getString('locationSharePause');
    } else if (session.otherStatus == ShareStatus.unknown) {
      return '${session.otherUserName} - ${l10n.getString('locationShareStale')}';
    } else if (session.otherStatus == ShareStatus.sharing) {
      return '${l10n.getString('locationShareOtherSharing').replaceAll('{name}', session.otherUserName)} $timeSuffix';
    }
    return '${session.otherUserName} $timeSuffix';
  }

  Widget _buildStatusBadge(LocationShareSession session) {
    if (session.myStatus == ShareStatus.stopped) return const SizedBox.shrink();

    Color color;
    String text;

    switch (session.myStatus) {
      case ShareStatus.sharing:
        color = Colors.green;
        text = 'LIVE';
        break;
      case ShareStatus.paused:
        color = Colors.orange;
        text = 'PAUSED';
        break;
      case ShareStatus.stopped:
        color = Colors.red;
        text = 'STOPPED';
        break;
      case ShareStatus.unknown:
        color = Colors.grey;
        text = '?';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTimerBar(LocationShareSession session, LocalizationState l10n) {
    if (session.otherStatus == ShareStatus.stopped) {
      return const SizedBox.shrink();
    }
    if (session.expiresAt == null) {
      return Positioned(
        top: MediaQuery.of(context).padding.top + 60,
        left: 16,
        right: 16,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.all_inclusive, color: Colors.green, size: 14),
              const SizedBox(width: 6),
              Text(
                l10n.getString('locationShareUntilOff'),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final remaining = session.timeRemaining;
    if (remaining == null) return const SizedBox.shrink();

    final total = session.expiresAt!.difference(session.startedAt);
    final progress = total.inSeconds > 0
        ? remaining.inSeconds / total.inSeconds
        : 0.0;

    final timeSuffix = _timeSuffix(session, l10n);

    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              timeSuffix,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.3),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
              minHeight: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend(LocationShareSession session, LocalizationState l10n) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 100,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
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
                const SizedBox(width: 6),
                Text(
                  l10n.getString('locationShareYou'),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
            if (session.otherStatus == ShareStatus.sharing) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent,
                      border: Border.all(width: 2, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    session.otherUserName,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDistanceCounter(String? distanceText) {
    if (distanceText == null) return const SizedBox.shrink();
    return Positioned(
      top: MediaQuery.of(context).padding.top + 92,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.straighten, color: Colors.white70, size: 14),
              const SizedBox(width: 8),
              Text(
                distanceText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScaleBar() {
    const double barWidth = 80;
    double zoom;
    double latitude;
    try {
      final camera = _mapController.camera;
      zoom = camera.zoom;
      latitude = camera.center.latitude;
    } catch (_) {
      return const SizedBox.shrink();
    }

    final metersPerPixel = _metersPerPixel(latitude, zoom);
    final rawDistance = metersPerPixel * barWidth;

    final (double displayDistance, String label) = _roundDistance(
      rawDistance,
      ref.watch(localizationProvider),
    );

    return Positioned(
      left: 16,
      bottom: 80,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: barWidth * (displayDistance / rawDistance).clamp(0.0, 1.0),
              height: 3,
              color: Colors.white70,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  double _metersPerPixel(double latitude, double zoom) {
    return 156543.03 * cos(latitude * pi / 180) / (1 << zoom.toInt());
  }

  (double, String) _roundDistance(double meters, LocalizationState l10n) {
    String km(int count) => l10n.getPluralString('distanceInKilometers', count);
    String m(int count) => l10n.getPluralString('distanceInMeters', count);
    if (meters < 10) return (10, m(10));
    if (meters < 20) return (20, m(20));
    if (meters < 50) return (50, m(50));
    if (meters < 100) return (100, m(100));
    if (meters < 200) return (200, m(200));
    if (meters < 500) return (500, m(500));
    if (meters < 1000) return (1000, km(1));
    if (meters < 2000) return (2000, km(2));
    if (meters < 5000) return (5000, km(5));
    return (10000, km(10));
  }

  Widget _buildBottomControls(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    final bool showShareButton = session.myStatus != ShareStatus.sharing;
    final bool isSharingActive =
        session.myStatus == ShareStatus.sharing ||
        session.myStatus == ShareStatus.paused;

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black.withValues(alpha: 0.6), Colors.transparent],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showShareButton)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: _buildShareFromMapButton(session, l10n),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  showShareButton ? 4 : 16,
                  16,
                  16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (isSharingActive)
                      _buildControlButton(
                        icon: session.myStatus == ShareStatus.sharing
                            ? Icons.pause_circle
                            : Icons.play_circle,
                        label: session.myStatus == ShareStatus.sharing
                            ? l10n.getString('locationSharePause')
                            : l10n.getString('locationShareResume'),
                        onTap: () {
                          if (session.myStatus == ShareStatus.sharing) {
                            ref
                                .read(locationShareProvider.notifier)
                                .pauseSharing();
                          } else {
                            ref
                                .read(locationShareProvider.notifier)
                                .resumeSharing();
                          }
                        },
                      ),
                    if (isSharingActive)
                      _buildControlButton(
                        icon: Icons.stop_circle,
                        label: l10n.getString('locationShareStop'),
                        color: Colors.red,
                        onTap: () async {
                          await ref
                              .read(locationShareProvider.notifier)
                              .stopSharing();
                          // Only pop if the session was fully destroyed
                          // (peer also stopped). If we transitioned to
                          // receiver mode, stay on the map.
                          if (context.mounted &&
                              ref.read(locationShareProvider) == null) {
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    _buildControlButton(
                      icon: Icons.my_location,
                      label: l10n.getString('locationShareCenter'),
                      onTap: () => _centerOnBothUsers(session),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShareFromMapButton(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    return GestureDetector(
      onTap: () => _handleShareFromMap(session),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.green.shade500, Colors.green.shade600],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.green.withValues(alpha: 0.3),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.share_location, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              l10n.getString('locationShareStart'),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlButton({
    required IconData icon,
    required String label,
    Color? color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color ?? Colors.white, size: 40),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(color: color ?? Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoCircle(String? photoUrl) {
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(width: 2, color: Colors.white),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6),
        ],
      ),
      child: hasPhoto
          ? ClipOval(
              child: SignedImage(
                source: photoUrl,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                placeholder: Container(
                  width: 40,
                  height: 40,
                  color: Colors.grey[300],
                  child: Icon(Icons.person, size: 20, color: Colors.grey[600]),
                ),
                errorWidget: Container(
                  width: 40,
                  height: 40,
                  color: Colors.grey[300],
                  child: Icon(Icons.person, size: 20, color: Colors.grey[600]),
                ),
              ),
            )
          : Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.grey[300],
                border: Border.all(width: 2, color: Colors.white),
              ),
              child: Icon(Icons.person, size: 20, color: Colors.grey[600]),
            ),
    );
  }

  Widget _buildDot(Color color) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(width: 3, color: Colors.white),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );
  }

  Marker _buildSelfMarker(LatLng position, {String? photoUrl}) {
    return Marker(
      point: position,
      width: 70,
      height: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPhotoCircle(photoUrl),
          const SizedBox(height: 2),
          _buildDot(Colors.blueAccent),
        ],
      ),
    );
  }

  Marker _buildOtherMarker(
    LatLng position,
    String? photoUrl,
    ShareStatus status,
  ) {
    final isActive = status == ShareStatus.sharing;
    final color = isActive ? Colors.greenAccent : Colors.grey;

    return Marker(
      point: position,
      width: 70,
      height: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPhotoCircle(photoUrl),
          const SizedBox(height: 2),
          _buildDot(color),
        ],
      ),
    );
  }

  Marker _buildCombinedMarker({
    required LatLng position,
    required String? myPhoto,
    required String? otherPhoto,
    required ShareStatus otherStatus,
  }) {
    final isActive = otherStatus == ShareStatus.sharing;
    final otherColor = isActive ? Colors.greenAccent : Colors.grey;

    return Marker(
      point: position,
      width: 120,
      height: 80,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPhotoCircle(myPhoto),
              const SizedBox(height: 2),
              _buildDot(Colors.blueAccent),
            ],
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPhotoCircle(otherPhoto),
              const SizedBox(height: 2),
              _buildDot(otherColor),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStaleOverlay(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    return Positioned(
      bottom: 220,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.access_time, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text(
              '${session.otherUserName} - ${l10n.getString('locationShareStale')}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoppedOverlay(
    LocationShareSession session,
    LocalizationState l10n,
  ) {
    String text;
    try {
      text = l10n
          .getString('locationShareOtherStopped')
          .replaceAll('{name}', session.otherUserName);
    } catch (_) {
      text = '${session.otherUserName} stopped sharing their location';
    }

    return Positioned(
      bottom: 220,
      left: 16,
      right: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_off, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
