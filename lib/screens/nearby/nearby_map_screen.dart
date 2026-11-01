import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:proj4dart/proj4dart.dart' as proj4;
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/pinned_location_provider.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/location_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
import 'package:matchme/services/session_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/map_tile_cache_service.dart';
import 'package:matchme/services/user_activity_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/country_localized_names.dart';
import 'package:matchme/utils/map_theme_utils.dart';
import 'package:matchme/utils/lat_lng_smoother.dart';
import 'package:matchme/utils/unit_utils.dart';
import 'package:matchme/utils/nearby_map_camera.dart';
import 'package:matchme/utils/nearby_map_counts.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/widgets/pinned_location_sheet.dart';
import 'package:matchme/widgets/pinned_map_status_banner.dart';
import 'package:matchme/widgets/onboarding_section_prompt.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/widgets/safe_text.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

String _ts() => DateTime.now().toIso8601String();

/// 1-2-5 sequence (meters) usable for scale bar distances, from close zoom
/// up to world view on wide screens.
const List<double> _scaleMagnitudes = <double>[
  1,
  2,
  5,
  10,
  20,
  50,
  100,
  200,
  500,
  1000,
  2000,
  5000,
  10000,
  20000,
  50000,
  100000,
  200000,
  500000,
  1000000,
  2000000,
  5000000,
  10000000,
];

/// Maximum rendered width of the scale bar's distance line, in logical px.
const double _scaleBarMaxWidth = 110.0;

final Crs _noWrap3857Crs = () {
  final max = pi * SphericalMercator.r;
  const tileSize = 256.0;
  final scaleFactor = 0.5 / (pi * SphericalMercator.r);
  final scales = List<double>.generate(
    25,
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

class NearbyMapScreen extends ConsumerStatefulWidget {
  const NearbyMapScreen({super.key});

  @override
  ConsumerState<NearbyMapScreen> createState() => _NearbyMapScreenState();
}

class _NearbyMapScreenState extends ConsumerState<NearbyMapScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  final MapController _mapController = MapController();
  final Distance _distance = const Distance();
  Timer? _debounce;
  Timer? _pollTimer;
  ProviderSubscription<AsyncValue<bool>>? _connectivitySub;
  RealtimeChannel? _activityChannel;
  RealtimeChannel? _locationChannel;
  RealtimeChannel? _presenceTickChannel;
  Timer? _presenceTickDebounce;
  Timer? _throttledRefreshTimer;
  Timer? _visibilityFollowUpTimer;
  LatLng? _lastUserCenter;
  double? _lastDefaultRadiusKm;
  LatLng? _lastCameraCenter;
  // Camera-follow state: the map's initialCenter applies only to the first
  // build, so every later fix must be pushed via MapController.move.
  LatLng? _lastAppliedCenter;
  LatLng? _lastKnownUserCenter;
  bool _mapReady = false;

  bool _loading = false;
  // True once a cell query has resolved at least once. Distinguishes
  // "there are genuinely no nearby users" (loaded, empty -> count 0) from
  // "we do not know yet" (never loaded -> no count is claimed).
  bool _cellsLoaded = false;
  List<NearbyMapCell> _cells = const [];
  NearbyMapCell? _selectedCell;
  DateTime? _lastActivityCommitTimestamp;
  DateTime? _lastTriggerRefreshAt;
  bool _usesImperial = false;
  final ValueNotifier<double> _cameraZoom = ValueNotifier(16);
  final ValueNotifier<LatLng?> _cameraCenter = ValueNotifier(null);
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  bool _reduceMotion = false;
  bool _motionInitialized = false;
  bool _locationLoading = true;
  final AppConfigService _appConfigService = AppConfigService();
  late final Future<List<int>> _matchRadiusOptionsFuture = _appConfigService
      .getIntList(
        'profile.match_radius_options_meters',
        defaultValue: [5, 10, 20, 50, 100],
      );

  // Live follow mode: while the gates allow it (visible + online + no pin),
  // a continuous position stream runs for this screen so the map follows
  // movement in realtime. The stream is owned by MobileLocationService and
  // transmitted only at the user's configured GPS interval (best-of-both:
  // realtime UI, interval-cadence uploads).
  DateTime? _lastUserPanAt;
  static const Duration _followResumeDelay = Duration(seconds: 8);

  // Animated camera follow: instead of jumping the camera to every new GPS
  // fix, ease it toward the target so movement at driving speed looks
  // continuous (Google-Maps-like) rather than a discrete hop per fix. A new
  // fix mid-flight re-anchors the animation from the camera's current
  // position, so successive fixes chain smoothly.
  Ticker? _followTicker;
  LatLng? _followAnimFrom;
  LatLng? _followAnimTarget;
  static const Duration _followAnimDuration = Duration(milliseconds: 900);
  late final LatLngSmoother _userLatLngSmoother;
  final ValueNotifier<LatLng?> _displayUserLatLng = ValueNotifier<LatLng?>(
    null,
  );
  LatLng? _lastRawUserLatLng;

  /// Starts/stops the service-owned live stream according to the current
  /// gates. Both directions are idempotent, so it is safe to call from any
  /// gate change (visibility, pin, connectivity) without tracking local
  /// state — the service knows whether the stream is actually running.
  Future<void> _updateLiveStreamForGates() async {
    if (kIsWeb) return;
    bool shouldRun;
    try {
      shouldRun =
          ref.read(isVisibleProvider) &&
          !ref.read(pinnedLocationProvider).isActive &&
          !await PinnedLocationGate.isActive();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final service = ref.read(locationServiceProvider);
    try {
      if (shouldRun) {
        await service.startMapLiveStream();
      } else {
        service.stopMapLiveStream();
      }
    } catch (_) {}
  }

  bool _dedupActivityEvent(DateTime? commitTimestamp) {
    if (commitTimestamp == null ||
        commitTimestamp == _lastActivityCommitTimestamp) {
      return true;
    }
    _lastActivityCommitTimestamp = commitTimestamp;
    return false;
  }

  @override
  void initState() {
    super.initState();
    print('[${_ts()}] 🗺️ NearbyMapScreen: initState');
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _userLatLngSmoother = LatLngSmoother(
      vsync: this,
      onChanged: (position) => _displayUserLatLng.value = position,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeOut));
    Future.microtask(() async {
      print('[${_ts()}] 🗺️ NearbyMapScreen: refreshLocation start');
      await _refreshLocationForMap();
      print('[${_ts()}] 🗺️ NearbyMapScreen: refreshLocation done');
      // Live follow mode: start the continuous stream if the gates allow.
      await _updateLiveStreamForGates();
    });
    _loadUnitPreference();

    _connectivitySub = ref.listenManual<AsyncValue<bool>>(
      connectivityProvider,
      (previous, next) {
        final isOnline = next.value ?? false;
        if (!isOnline) return;
        // Re-evaluate the live stream: a dead stream (e.g. killed by a full
        // stop while offline) resumes when connectivity returns.
        unawaited(_updateLiveStreamForGates());
        final center = _lastUserCenter;
        final radiusKm = _lastDefaultRadiusKm;
        if (center == null || radiusKm == null) return;
        _scheduleFetch(userCenter: center, defaultRadiusKm: radiusKm);
      },
    );

    // Gate changes must start/stop the live stream: pinning parks GPS
    // entirely, invisibility stops all GPS.
    ref.listenManual<PinnedLocationState>(pinnedLocationProvider, (
      previous,
      next,
    ) {
      unawaited(_updateLiveStreamForGates());
    });
    ref.listenManual<bool>(isVisibleProvider, (previous, next) {
      unawaited(_updateLiveStreamForGates());
    });
    WidgetsBinding.instance.addObserver(this);

    // Setup realtime subscriptions for immediate updates
    _setupRealtimeSubscriptions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_motionInitialized && _reduceMotion == reduceMotion) return;
    _motionInitialized = true;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _pulseController.stop();
      _pulseController.value = 1;
    } else {
      _pulseController.repeat();
    }
  }

  Future<void> _loadUnitPreference() async {
    final imperial = await ref.read(unitSystemProvider.future);
    if (mounted) {
      setState(() {
        _usesImperial = imperial;
      });
    }
  }

  Future<void> _refreshLocationForMap() async {
    if (!mounted) return;
    setState(() {
      _locationLoading = true;
    });
    try {
      final pin = ref.read(pinnedLocationProvider);
      final pinActive = pin.isActive || await PinnedLocationGate.isActive();
      if (pinActive) return;
      await ref.read(currentLocationProvider.notifier).refreshLocation();
      // Re-evaluate the live stream too: the retry may have followed the
      // user granting location permission in system settings.
      await _updateLiveStreamForGates();
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _locationLoading = false;
        });
      }
    }
  }

  Widget _buildLocationState(
    BuildContext context,
    LocalizationState l10n, {
    required bool isOnline,
  }) {
    if (_locationLoading) {
      return Center(
        child: Semantics(
          container: true,
          label: l10n.getString('nearbyLocationLoading'),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: double.infinity,
              height: 180,
              child: AppSkeletonBox(height: 180, borderRadius: 24),
            ),
          ),
        ),
      );
    }

    final offline = !isOnline;
    final title = offline
        ? l10n.getString('generalOffline')
        : l10n.getString('nearbyLocationUnavailableTitle');
    final message = offline
        ? l10n.getString('nearbyLocationOfflineMessage')
        : l10n.getString('nearbyLocationUnavailableMessage');
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Semantics(
            container: true,
            label: '$title. $message',
            child: Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      offline
                          ? Icons.wifi_off_rounded
                          : Icons.location_off_rounded,
                      size: 48,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => unawaited(_refreshLocationForMap()),
                      icon: const Icon(Icons.refresh),
                      label: Text(l10n.getString('generalRetry')),
                    ),
                    if (!offline && !kIsWeb) ...[
                      const SizedBox(height: 4),
                      TextButton.icon(
                        onPressed: () => unawaited(openAppSettings()),
                        icon: const Icon(Icons.settings_outlined),
                        label: Text(l10n.getString('permActionOpenSettings')),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setupRealtimeSubscriptions() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    // Subscribe to user_activity table for online status changes
    _activityChannel = Supabase.instance.client
        .channel('nearby_map_activity_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'user_activity',
          callback: (payload) {
            // Dedup by commit timestamp (handles duplicate events from Postgres)
            if (_dedupActivityEvent(payload.commitTimestamp)) return;

            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final changedUserId = newRecord?['user_id'] as String?;
            if (changedUserId == null || changedUserId == userId) return;

            // Refresh on any user_activity change (online/offline)
            print(
              '[${_ts()}] 🗺️ NearbyMapScreen: User activity changed, refreshing nearby cells',
            );
            _triggerRefresh();
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_activity',
          callback: (payload) {
            // Dedup by commit timestamp (handles duplicate events from Postgres)
            if (_dedupActivityEvent(payload.commitTimestamp)) return;

            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final oldRecord = payload.oldRecord as Map<String, dynamic>?;
            final changedUserId =
                (newRecord?['user_id'] ?? oldRecord?['user_id']) as String?;
            if (changedUserId == null || changedUserId == userId) return;

            // Refresh on any user_activity UPDATE (online/offline changes)
            print(
              '[${_ts()}] 🗺️ NearbyMapScreen: User activity updated, refreshing nearby cells',
            );
            _triggerRefresh();
          },
        )
        .subscribe((status, err) {
          print(
            '[${_ts()}] 🗺️ NearbyMapScreen: Activity channel status: $status, error: $err',
          );
        });

    // Subscribe to user_locations table for location changes
    _locationChannel = Supabase.instance.client
        .channel('nearby_map_location_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'user_locations',
          callback: (payload) {
            final newRecord = payload.newRecord as Map<String, dynamic>?;
            final oldRecord = payload.oldRecord as Map<String, dynamic>?;
            final changedUserId =
                (newRecord?['user_id'] ?? oldRecord?['user_id']) as String?;
            if (changedUserId == null || changedUserId == userId) return;

            print(
              '[${_ts()}] 🗺️ NearbyMapScreen: User location changed, refreshing nearby cells',
            );
            _triggerRefresh();
          },
        )
        .subscribe((status, err) {
          print(
            '[${_ts()}] 🗺️ NearbyMapScreen: Location channel status: $status, error: $err',
          );
        });

    // The users/user_activity channels above only deliver rows this user may
    // SELECT under RLS, so visibility toggles of the (mostly unmatched) users
    // this map aggregates never arrive through them. presence_tick is the
    // readable-by-all signal: DB triggers touch it on every visibility flip
    // (and login/logout/pin change), so the map re-queries the aggregated
    // cells RPC immediately instead of waiting for the 30s fallback poll.
    _presenceTickChannel = Supabase.instance.client
        .channel('nearby_map_presence_tick_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'presence_tick',
          callback: (payload) {
            if (!mounted) return;
            print(
              '[${_ts()}] 🗺️ NearbyMapScreen: presence_tick received, refreshing nearby cells',
            );
            _presenceTickDebounce?.cancel();
            _presenceTickDebounce = Timer(
              const Duration(milliseconds: 500),
              () {
                if (!mounted) return;
                // Bypass the throttle: a visibility flip must reach the map
                // right away. The 350ms fetch debounce inside _scheduleFetch
                // still coalesces tick bursts (the DB fires two ticks per
                // manual toggle).
                _triggerRefresh(bypassThrottle: true);
                // A user turning visible may not have a fresh location /
                // heartbeat yet (GPS restarts on the visible transition), so
                // refresh once more shortly after to let them appear.
                _scheduleVisibilityFollowUpRefresh();
              },
            );
          },
        )
        .subscribe((status, err) {
          print(
            '[${_ts()}] 🗺️ NearbyMapScreen: Presence tick channel status: $status, error: $err',
          );
        });
  }

  void _triggerRefresh({bool bypassThrottle = false}) {
    if (!mounted) return;
    final isOnline = ref.read(connectivityProvider).value ?? false;
    if (!isOnline) return;
    final center = _lastUserCenter;
    final radiusKm = _lastDefaultRadiusKm;
    if (center == null || radiusKm == null) return;
    // Throttle realtime-triggered refreshes to at most once every 10 seconds
    // to avoid flooding _fetchCells when many user_activity changes arrive.
    // Coalesce instead of dropping: a trailing refresh is scheduled at the
    // end of the throttle window so the map still converges to the latest
    // server state (a plain drop would only be caught by the 30s poll).
    final now = DateTime.now();
    if (!bypassThrottle &&
        _lastTriggerRefreshAt != null &&
        now.difference(_lastTriggerRefreshAt!) < const Duration(seconds: 10)) {
      _throttledRefreshTimer ??= Timer(
        const Duration(seconds: 10) - now.difference(_lastTriggerRefreshAt!),
        () {
          _throttledRefreshTimer = null;
          _triggerRefresh();
        },
      );
      return;
    }
    _throttledRefreshTimer?.cancel();
    _throttledRefreshTimer = null;
    _lastTriggerRefreshAt = now;
    _scheduleFetch(userCenter: center, defaultRadiusKm: radiusKm);
  }

  /// Re-queries once more a few seconds after a presence tick: a user who just
  /// turned visible sends their first GPS fix / heartbeat a moment later, so
  /// the immediate refresh can be too early to see them.
  void _scheduleVisibilityFollowUpRefresh() {
    _visibilityFollowUpTimer?.cancel();
    _visibilityFollowUpTimer = Timer(const Duration(seconds: 3), () {
      _visibilityFollowUpTimer = null;
      if (!mounted) return;
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) return;
      final center = _lastUserCenter;
      final radiusKm = _lastDefaultRadiusKm;
      if (center == null || radiusKm == null) return;
      _scheduleFetch(userCenter: center, defaultRadiusKm: radiusKm);
    });
  }

  @override
  void dispose() {
    print('[${_ts()}] 🗺️ NearbyMapScreen: dispose');
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _pollTimer?.cancel();
    _connectivitySub?.close();
    _activityChannel?.unsubscribe();
    _locationChannel?.unsubscribe();
    _presenceTickChannel?.unsubscribe();
    _presenceTickDebounce?.cancel();
    _throttledRefreshTimer?.cancel();
    _visibilityFollowUpTimer?.cancel();
    // Leaving the map hands GPS back to the interval timer's one-shot mode.
    try {
      ref.read(locationServiceProvider).stopMapLiveStream();
    } catch (_) {}
    _cameraZoom.dispose();
    _cameraCenter.dispose();
    _userLatLngSmoother.dispose();
    _displayUserLatLng.dispose();
    _stopFollowAnimation();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // While backgrounded, the native service owns location; the map's live
    // stream must not keep the GPS chip powered (or double up with it).
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      try {
        ref.read(locationServiceProvider).stopMapLiveStream();
      } catch (_) {}
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_updateLiveStreamForGates());
    }
  }

  int _cellMetersForRadiusKm(double radiusKm) {
    // Size cells as a small fraction of the match radius so the cell centers
    // (where markers are drawn) stay visually inside the drawn radius circle.
    // The grid is still fixed per radius, so markers don't move when zooming.
    final radiusMeters = (radiusKm * 1000.0).round();
    return (radiusMeters ~/ 4).clamp(11, 5000);
  }

  double _zoomForRadiusKm(double radiusKm, LatLng center, Size viewportSize) {
    return nearbyMapZoomForRadius(
      radiusMeters: radiusKm * 1000,
      latitude: center.latitude,
      viewportSize: viewportSize,
    );
  }

  void _scheduleFetch({
    required LatLng userCenter,
    required double defaultRadiusKm,
  }) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        _fetchCells(userCenter: userCenter, defaultRadiusKm: defaultRadiusKm),
      );
    });
  }

  /// Moves the camera to [center] when it changed since the last applied
  /// center, so the map always stays centered around the user's last
  /// obtained location. No-op before the map is ready (onMapReady performs
  /// the pending move) and cheap when nothing changed. The move itself is
  /// animated (see [_startFollowAnimation]) unless reduced motion is on.
  void _syncCameraToUserCenter(LatLng center) {
    if (_lastAppliedCenter == center) return;
    _lastAppliedCenter = center;
    if (!_mapReady) return;
    if (_reduceMotion) {
      _stopFollowAnimation();
      try {
        _mapController.move(center, _cameraZoom.value);
      } catch (_) {}
      return;
    }
    _startFollowAnimation(center);
  }

  Future<void> _updateMatchRadius({
    required int radiusMeters,
    required String userId,
    required LatLng? center,
    required LocalizationState l10n,
  }) async {
    try {
      await ref
          .read(profileEditProvider(userId).notifier)
          .updateRadius(radiusMeters);
      if (!mounted) return;

      final radiusKm = radiusMeters / 1000.0;
      if (center != null) {
        _lastDefaultRadiusKm = radiusKm;
        _lastUserPanAt = null;
        _stopFollowAnimation();
        if (_mapReady) {
          try {
            _mapController.move(
              center,
              _zoomForRadiusKm(radiusKm, center, _mapController.camera.size),
            );
            _lastAppliedCenter = center;
          } catch (error) {
            debugPrint(
              '[NearbyMap] Failed to refocus after radius change: $error',
            );
          }
        }
        setState(() => _selectedCell = null);
        _scheduleFetch(userCenter: center, defaultRadiusKm: radiusKm);
      }
    } catch (error) {
      debugPrint('[NearbyMap] Failed to update match radius: $error');
      if (!mounted) return;
      final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.getString('settingsRadiusUpdateFailed')}: '
            '${l10n.getString(errorKey)}',
          ),
        ),
      );
    }
  }

  void _startFollowAnimation(LatLng target) {
    LatLng? from;
    try {
      from = _mapController.camera.center;
    } catch (_) {
      return;
    }
    _followAnimFrom = from;
    _followAnimTarget = target;
    // Restart (not reuse) a running ticker so each new fix animates for the
    // full duration from the camera's current position — chaining fixes
    // produces continuous motion instead of an ever-shortening tail.
    final ticker = _followTicker;
    if (ticker != null) {
      if (ticker.isActive) ticker.stop();
      ticker.start();
    } else {
      _followTicker = createTicker(_onFollowTick)..start();
    }
  }

  void _onFollowTick(Duration elapsed) {
    final from = _followAnimFrom;
    final target = _followAnimTarget;
    if (!_mapReady || from == null || target == null) {
      _stopFollowAnimation();
      return;
    }
    final t = (elapsed.inMicroseconds / _followAnimDuration.inMicroseconds)
        .clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(t);
    final next = LatLng(
      from.latitude + (target.latitude - from.latitude) * eased,
      from.longitude + (target.longitude - from.longitude) * eased,
    );
    try {
      _mapController.move(next, _cameraZoom.value);
    } catch (_) {}
    if (t >= 1.0) {
      _stopFollowAnimation();
    }
  }

  void _stopFollowAnimation() {
    _followTicker?.stop();
    _followTicker?.dispose();
    _followTicker = null;
    _followAnimFrom = null;
    _followAnimTarget = null;
  }

  void _ensurePolling({
    required LatLng userCenter,
    required double defaultRadiusKm,
  }) {
    _lastUserCenter = userCenter;
    _lastDefaultRadiusKm = defaultRadiusKm;

    _pollTimer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      // Self-heal the live stream: covers gates that changed without a
      // listener firing (e.g. a pin expiring while the map is open).
      unawaited(_updateLiveStreamForGates());
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

  LatLng _jitteredCellPoint(
    String requestingUserId,
    NearbyMapCell cell,
    double maxMeters,
  ) {
    final seed = _stableHash32(
      'cell|$requestingUserId|${cell.lat.toStringAsFixed(6)}|${cell.lng.toStringAsFixed(6)}',
    );
    final rng = Random(seed);

    // Jitter magnitude is capped at 30m and scaled with the cell size so
    // markers stay near their cell center (and inside the drawn radius circle).
    // It remains deterministic per user+cell, so markers don't move when zooming.
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
    // Use a single color (deepPurple) to match the legend
    // Previously used a palette of different colors which was inconsistent with the legend
    return Colors.deepPurple.withValues(alpha: 0.78);
  }

  Future<void> _fetchCells({
    required LatLng userCenter,
    required double defaultRadiusKm,
  }) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    // Always query using the user's location and match radius.
    // The server-side haversine filter ensures only users within the
    // match radius are returned, regardless of zoom level.
    final LatLng queryCenter = userCenter;
    final double queryRadiusKm = defaultRadiusKm;

    final cellMeters = _cellMetersForRadiusKm(queryRadiusKm);
    final queryKey =
        '${queryCenter.latitude.toStringAsFixed(6)}_'
                '${queryCenter.longitude.toStringAsFixed(6)}_'
                '${queryRadiusKm.toStringAsFixed(6)}_$cellMeters'
            .replaceAll('.', '_')
            .replaceAll('-', 'm');
    LocalDbService? localDb;
    List<Map<String, dynamic>>? cachedRows;
    try {
      localDb = await LocalDbService.instance;
      cachedRows = await localDb.getNearbyMapCells(userId, queryKey);
    } catch (error) {
      debugPrint('Nearby map cache read failed: $error');
    }

    List<NearbyMapCell> decodeCells(List<Map<String, dynamic>> rows) {
      final parsed = <NearbyMapCell>[];
      for (final row in rows) {
        final lat = (row['cell_center_lat'] as num?)?.toDouble();
        final lng = (row['cell_center_lng'] as num?)?.toDouble();
        final count = (row['user_count'] as num?)?.toInt();
        if (lat == null || lng == null || count == null || count <= 0) {
          continue;
        }
        parsed.add(NearbyMapCell(lat: lat, lng: lng, count: count));
      }
      return parsed;
    }

    if (shouldSkipSupabaseCalls()) {
      if (!mounted) return;
      setState(() {
        _cells = cachedRows == null ? const [] : decodeCells(cachedRows);
        _cellsLoaded = true;
        _selectedCell = null;
        _loading = false;
      });
      return;
    }

    final pin = ref.read(pinnedLocationProvider);
    final locationSource = pin.isActive ? 'pinned' : 'live';
    print(
      '[${_ts()}] NearbyMapScreen: _fetchCells start '
      '(locationSource=$locationSource, '
      'defaultRadiusKm=${defaultRadiusKm.toStringAsFixed(2)}, '
      'queryRadiusKm=${queryRadiusKm.toStringAsFixed(2)}, cellMeters=$cellMeters)',
    );

    setState(() {
      _loading = true;
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
      final cacheRows = rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final parsed = decodeCells(cacheRows);

      var totalUsers = 0;
      for (final c in parsed) {
        totalUsers += c.count;
      }
      print(
        '[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells rpc ok (rows=${rows.length}, cells=${parsed.length}, totalUsers=$totalUsers)',
      );

      try {
        localDb ??= await LocalDbService.instance;
        await localDb.saveNearbyMapCells(userId, queryKey, cacheRows);
      } catch (error) {
        debugPrint('Nearby map cache write failed: $error');
      }

      if (!mounted) return;
      setState(() {
        _cells = parsed;
        _cellsLoaded = true;
        if (_selectedCell != null) {
          final stillExists = parsed.any(
            (c) => c.lat == _selectedCell!.lat && c.lng == _selectedCell!.lng,
          );
          if (!stillExists) _selectedCell = null;
        }
      });
    } catch (e) {
      print('[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells error: $e');
      if (!mounted) return;
      final errorTranslationKey =
          ErrorLocalizationService.getMapErrorTranslationKey(e);
      final isNetworkError = errorTranslationKey.startsWith('networkError');
      if (cachedRows != null) {
        setState(() {
          _cells = decodeCells(cachedRows!);
          _cellsLoaded = true;
          _selectedCell = null;
        });
        return;
      }
      if (!isNetworkError) {
        setState(() {
          _cells = const [];
          _cellsLoaded = true;
          _selectedCell = null;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      print('[${_ts()}] 🗺️ NearbyMapScreen: _fetchCells done');
    }
  }

  List<Marker> _buildCellMarkers(
    BuildContext context, {
    required String requestingUserId,
    required double radiusKm,
  }) {
    final l10n = ref.read(localizationProvider);
    final cellMeters = _cellMetersForRadiusKm(radiusKm).toDouble();
    final maxJitterMeters = min(30.0, cellMeters / 4.0);
    final markers = <Marker>[];
    for (final c in _cells) {
      final isSelected =
          _selectedCell != null &&
          _selectedCell!.lat == c.lat &&
          _selectedCell!.lng == c.lng;
      final size = (18.0 + (log(c.count + 1) / ln2) * 4.0).clamp(16.0, 44.0);
      final label = c.count >= 100 ? '99+' : c.count.toString();
      final point = _jitteredCellPoint(requestingUserId, c, maxJitterMeters);
      final baseColor = _cellColor(requestingUserId, c);

      markers.add(
        Marker(
          point: point,
          width: size + 10,
          height: size + 10,
          child: Center(
            child: Semantics(
              button: true,
              label: l10n.getString(
                'mapApproxUsersHere',
                params: {'count': c.count.toString()},
              ),
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
                    color: (isSelected ? Colors.orange : baseColor).withValues(
                      alpha: 0.78,
                    ),
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
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                          textAlign: TextAlign.center,
                        ),
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
    final l10n = ref.read(localizationProvider);
    return Marker(
      point: userLatLng,
      width: 54,
      height: 54,
      child: Semantics(
        label: l10n.getString('mapLegendYou'),
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
    // Same transient-null guard as home/profile: the raw auth client can be
    // empty for a few hundred ms while the recovery ladder re-seeds it, and
    // the auth provider still holds the session throughout that window.
    final userId = Supabase.instance.client.auth.currentUser?.id ??
        ref.watch(authStateProvider).value?.session?.user.id;
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    // The "Showing ~N users" pill must state exactly what the map plots, so
    // it is derived from the SAME query as the markers below.
    //
    // _fetchCells queries the server with the device's live position (or the
    // active pin) and the selected match radius, and the RPC buckets the
    // matching users into cells whose counts sum to the number of distinct
    // users in range. Summing them therefore yields exactly the number of
    // users plotted.
    //
    // The shared dashboard stats used to drive this pill, but
    // get_nearby_users_count() anchors its query on the server's own copy of
    // the requesting user's position (user_locations) while the cell query
    // is anchored on the device's position. Whenever those two anchors were
    // out of sync (missing/stale server-side row, invisible user whose
    // location row was reaped by cleanup_old_user_locations) the pill read
    // 0 while a real user was plotted right next to the "You" marker.
    final displayedNearbyCount = _cellsLoaded
        ? nearbyUsersPlottedOnMap(_cells)
        : null;

    if (userId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final profileAsync = ref.watch(userProfileProvider(userId));
    final pin = ref.watch(pinnedLocationProvider);
    // Always watch the GPS position (even while pinned) so the map can fall
    // back to the last obtained location when the pin carries no coords.
    final position = ref.watch(currentLocationProvider);

    return profileAsync.when(
      data: (profile) {
        final defaultRadiusMeters = (profile?.matchRadiusDefault ?? 50)
            .toDouble();
        final defaultRadiusKm = defaultRadiusMeters / 1000.0;
        final pinLabel = pin.label?.trim();
        final pinnedLocationLabel = pinLabel == null || pinLabel.isEmpty
            ? ''
            : ' ${l10n.getString('homeNearbyMapPinnedToLabel')} $pinLabel';
        final pinnedLocationText = l10n.getString(
          'homeNearbyMapPinnedLocation',
          params: {'label': pinnedLocationLabel},
        );

        final pinnedLatLng = pin.latitude != null && pin.longitude != null
            ? LatLng(pin.latitude!, pin.longitude!)
            : null;
        final gpsLatLng = position != null
            ? LatLng(position.latitude, position.longitude)
            : null;
        // Effective center, newest source first: live pin coords, then the
        // last obtained GPS fix, then the last center this screen applied
        // (covers pin-active-without-coords right after a cold start).
        final userLatLng = pin.isActive
            ? (pinnedLatLng ?? gpsLatLng ?? _lastKnownUserCenter)
            : (gpsLatLng ?? _lastKnownUserCenter);
        if (userLatLng != null) {
          final rawUserLatLng = userLatLng;
          if (_lastRawUserLatLng != rawUserLatLng) {
            _lastRawUserLatLng = rawUserLatLng;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || _lastRawUserLatLng != rawUserLatLng) return;
              _userLatLngSmoother.update(
                rawUserLatLng,
                immediate: pin.isActive || _reduceMotion,
              );
            });
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (gpsLatLng != null) _lastKnownUserCenter = gpsLatLng;
            _ensurePolling(
              userCenter: userLatLng,
              defaultRadiusKm: defaultRadiusKm,
            );
            // Keep the camera centered on the last obtained location: the
            // map's initialCenter applies only to the first build, so later
            // fixes (cached load, GPS ticks) must move the camera.
            // Follow suppression: while live streaming (~1Hz fixes), a
            // recent user pan would be snapped back almost immediately,
            // making panning impossible. Pause follow for a short window
            // after a gesture; the next fix after it expires re-centers.
            final pannedAt = _lastUserPanAt;
            final isFollowing =
                pannedAt == null ||
                DateTime.now().difference(pannedAt) >= _followResumeDelay;
            if (isFollowing) {
              _syncCameraToUserCenter(userLatLng);
            }
          });
        }

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 144,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.getString('homeNearbyMap'),
                  overflow: TextOverflow.visible,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.getString('homeNearbyMapDesc'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                ),
                const SizedBox(height: 2),
                FutureBuilder<List<int>>(
                  future: _matchRadiusOptionsFuture,
                  builder: (context, snapshot) {
                    final availableRadii = {
                      ...(snapshot.data ?? const [5, 10, 20, 50, 100]),
                      defaultRadiusMeters.round(),
                    }.toList()..sort();
                    return PopupMenuButton<int>(
                      tooltip: l10n.getString('settingsRadius'),
                      onSelected: (radius) => unawaited(
                        _updateMatchRadius(
                          radiusMeters: radius,
                          userId: userId,
                          center: userLatLng,
                          l10n: l10n,
                        ),
                      ),
                      itemBuilder: (context) => [
                        for (final radius in availableRadii)
                          PopupMenuItem<int>(
                            value: radius,
                            child: Text(
                              formatDistanceWithImperial(
                                radius.toDouble(),
                                _usesImperial,
                                l10n,
                              ),
                            ),
                          ),
                      ],
                      child: Semantics(
                        button: true,
                        label: l10n.getString(
                          'homeNearbyMapRadius',
                          params: {
                            'radius': formatDistanceWithImperial(
                              defaultRadiusMeters,
                              _usesImperial,
                              l10n,
                            ),
                          },
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            l10n.getString(
                              'homeNearbyMapRadius',
                              params: {
                                'radius': formatDistanceWithImperial(
                                  defaultRadiusMeters,
                                  _usesImperial,
                                  l10n,
                                ),
                              },
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w500,
                                ),
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Semantics(
                  button: true,
                  label: pin.isActive
                      ? pinnedLocationText
                      : l10n.getString('homeNearbyMapPinAction'),
                  child: TextButton.icon(
                    onPressed: () => showPinnedLocationSheet(
                      context,
                      ref,
                      // Already on this screen — no map shortcut needed.
                      showMapShortcut: false,
                    ),
                    icon: const Icon(Icons.push_pin_outlined, size: 18),
                    label: ShrinkText(
                      pin.isActive
                          ? pinnedLocationText
                          : l10n.getString('homeNearbyMapPinAction'),
                    ),
                    style: TextButton.styleFrom(
                      alignment: AlignmentDirectional.centerStart,
                      foregroundColor: Theme.of(context).colorScheme.primary,
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.padded,
                      shape: const StadiumBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          body: userLatLng == null
              ? Column(
                  children: [
                    if (pin.isActive)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: PinnedMapStatusBanner(pin: pin, l10n: l10n),
                      ),
                    Expanded(
                      child: _buildLocationState(
                        context,
                        l10n,
                        isOnline: isOnline,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    OnboardingSectionPrompt(tour: kOnboardingNearbySectionTour),
                    Expanded(
                      child: Stack(
                        children: [
                          if (pin.isActive)
                            Positioned(
                              top: 12,
                              left: 12,
                              right: 150,
                              child: PinnedMapStatusBanner(
                                pin: pin,
                                l10n: l10n,
                              ),
                            ),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final viewportSize = constraints.biggest;
                              return FlutterMap(
                                mapController: _mapController,
                                options: MapOptions(
                                  crs: _noWrap3857Crs,
                                  initialCenter: userLatLng,
                                  initialZoom: _zoomForRadiusKm(
                                    defaultRadiusKm,
                                    userLatLng,
                                    viewportSize,
                                  ),
                                  minZoom: 1,
                                  maxZoom: nearbyMapMaxZoom,
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  cameraConstraint: CameraConstraint.contain(
                                    bounds: _worldBounds,
                                  ),
                                  interactionOptions: _interaction,
                                  onPositionChanged: (camera, hasGesture) {
                                    _cameraZoom.value = camera.zoom;
                                    _cameraCenter.value = camera.center;
                                    if (!hasGesture) return;
                                    // User panned: pause camera-follow so realtime
                                    // fixes don't snap the view back mid-gesture.
                                    _stopFollowAnimation();
                                    _lastUserPanAt = DateTime.now();
                                    // Only refetch when the center position changes significantly (panning), not when just zooming
                                    // This prevents markers from disappearing/reappearing when zooming
                                    final currentCenter = camera.center;
                                    final lastCenter = _lastCameraCenter;
                                    if (lastCenter != null) {
                                      final distance = _distance(
                                        lastCenter,
                                        currentCenter,
                                      );
                                      // Only refetch if panned more than 100 meters
                                      if (distance < 100) return;
                                    }
                                    _lastCameraCenter = currentCenter;
                                    _scheduleFetch(
                                      userCenter: userLatLng,
                                      defaultRadiusKm: defaultRadiusKm,
                                    );
                                  },
                                  onMapReady: () {
                                    _mapReady = true;
                                    // onPositionChanged never fires for the initial
                                    // camera, so seed the scale bar listeners here.
                                    final camera = _mapController.camera;
                                    _cameraZoom.value = camera.zoom;
                                    _cameraCenter.value = camera.center;
                                    // Apply any center that arrived before the map was
                                    // ready (first cached fix racing map creation).
                                    final pending = _lastAppliedCenter;
                                    if (pending != null) {
                                      try {
                                        _mapController.move(
                                          pending,
                                          _cameraZoom.value,
                                        );
                                      } catch (_) {}
                                    }
                                    _scheduleFetch(
                                      userCenter: userLatLng,
                                      defaultRadiusKm: defaultRadiusKm,
                                    );
                                  },
                                  onTap: (tapPosition, point) {
                                    if (_selectedCell == null) return;
                                    setState(() {
                                      _selectedCell = null;
                                    });
                                  },
                                ),
                                children: [
                                  // Always mounted: cached tiles paint instantly even
                                  // when connectivity flutters, and stay available
                                  // offline. Missing tiles fail gracefully per-tile.
                                  TileLayer(
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                    userAgentPackageName: 'matchme.app',
                                    tileProvider: CachedMapTileProvider(),
                                    tileBounds: _worldBounds,
                                    maxNativeZoom: 19,
                                    tileBuilder: darkMapTileBuilderFor(
                                      Theme.of(context).brightness,
                                    ),
                                  ),
                                  RichAttributionWidget(
                                    attributions: [
                                      TextSourceAttribution(
                                        'OpenStreetMap contributors',
                                      ),
                                    ],
                                  ),
                                  AnimatedBuilder(
                                    animation: Listenable.merge([
                                      _pulseAnimation,
                                      _displayUserLatLng,
                                    ]),
                                    builder: (context, _) {
                                      final t = _pulseAnimation.value;
                                      final center =
                                          _displayUserLatLng.value ??
                                          userLatLng;
                                      final fullRadius =
                                          defaultRadiusKm * 1000.0;
                                      return CircleLayer(
                                        circles: [
                                          // Static faint fill at full radius
                                          CircleMarker(
                                            point: center,
                                            radius: fullRadius,
                                            useRadiusInMeter: true,
                                            color: Colors.blueAccent.withValues(
                                              alpha: 0.08,
                                            ),
                                            borderColor: Colors.blueAccent
                                                .withValues(alpha: 0.25),
                                            borderStrokeWidth: 1.5,
                                          ),
                                          // Expanding ring from center to full radius
                                          CircleMarker(
                                            point: center,
                                            radius: fullRadius * t,
                                            useRadiusInMeter: true,
                                            color: Colors.blueAccent.withValues(
                                              alpha: 0.12 * (1.0 - t),
                                            ),
                                            borderColor: Colors.blueAccent
                                                .withValues(
                                                  alpha: 0.5 * (1.0 - t),
                                                ),
                                            borderStrokeWidth: 2.5 * (1.0 - t),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                  MarkerLayer(
                                    markers: _buildCellMarkers(
                                      context,
                                      requestingUserId: userId,
                                      radiusKm: defaultRadiusKm,
                                    ),
                                  ),
                                  AnimatedBuilder(
                                    animation: _displayUserLatLng,
                                    builder: (context, _) {
                                      final center =
                                          _displayUserLatLng.value ??
                                          userLatLng;
                                      return MarkerLayer(
                                        markers: [_buildUserMarker(center)],
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          ),
                          Positioned(
                            right: 12,
                            bottom: 110,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: FloatingActionButton.small(
                                heroTag: null,
                                tooltip: l10n.getString('locationShareCenter'),
                                onPressed: () {
                                  _mapController.move(
                                    userLatLng,
                                    _zoomForRadiusKm(
                                      defaultRadiusKm,
                                      userLatLng,
                                      _mapController.camera.size,
                                    ),
                                  );
                                  _lastUserPanAt = null;
                                  _lastAppliedCenter = userLatLng;
                                  _scheduleFetch(
                                    userCenter: userLatLng,
                                    defaultRadiusKm: defaultRadiusKm,
                                  );
                                },
                                child: const Icon(Icons.my_location),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            bottom: 12,
                            child: _MapZoomControls(
                              controller: _mapController,
                              minZoom: 1,
                              maxZoom: nearbyMapMaxZoom,
                              l10n: l10n,
                            ),
                          ),
                          if (_loading)
                            const Positioned(
                              top: 12,
                              left: 12,
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          Positioned(
                            top: 12,
                            right: 12,
                            child: _legend(context, l10n),
                          ),
                          if (displayedNearbyCount != null)
                            Positioned(
                              top: 12,
                              left: 44,
                              child: Material(
                                elevation: 0,
                                borderRadius: BorderRadius.circular(999),
                                color: Theme.of(
                                  context,
                                ).colorScheme.surface.withValues(alpha: 0.92),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    l10n.getString(
                                      'mapShowingApproxUsers',
                                      params: {
                                        'count': displayedNearbyCount.toString(),
                                      },
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelMedium,
                                  ),
                                ),
                              ),
                            ),
                          if (_selectedCell != null)
                            Positioned(
                              bottom: 120,
                              left: 12,
                              right: 12,
                              child: Material(
                                elevation: 2,
                                borderRadius: BorderRadius.circular(12),
                                color: Theme.of(
                                  context,
                                ).colorScheme.surface.withValues(alpha: 0.95),
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        l10n.getString(
                                          'mapApproxUsersHere',
                                          params: {
                                            'count': _selectedCell!.count
                                                .toString(),
                                          },
                                        ),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          setState(() {
                                            _selectedCell = null;
                                          });
                                        },
                                        child: Text(
                                          l10n.getString('generalClose'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (!isOnline)
                            Positioned(
                              top: 12,
                              left: 12,
                              right: 12,
                              child: Material(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    l10n.getString('generalOffline'),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            bottom: 12,
                            left: 12,
                            child: ValueListenableBuilder<double>(
                              valueListenable: _cameraZoom,
                              builder: (context, zoom, _) {
                                return ValueListenableBuilder<LatLng?>(
                                  valueListenable: _cameraCenter,
                                  builder: (context, center, _) {
                                    return _buildScaleIndicator(
                                      context,
                                      zoom,
                                      center,
                                      userLatLng,
                                      _usesImperial,
                                      l10n,
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
      loading: () => const Scaffold(
        body: Center(
          child: SizedBox(
            width: 240,
            height: 180,
            child: AppSkeletonBox(height: 180, borderRadius: 24),
          ),
        ),
      ),
      error: (e, s) => Scaffold(
        body: AppEmptyState(
          icon: Icons.person_off_outlined,
          title: l10n.getString('generalError'),
          message: l10n.getString('nearbyProfileErrorMessage'),
          actionLabel: l10n.getString('generalRetry'),
          onAction: () => ref.invalidate(userProfileProvider(userId)),
        ),
      ),
    );
  }
}

class OnlineWorldMapScreen extends ConsumerStatefulWidget {
  const OnlineWorldMapScreen({super.key});

  @override
  ConsumerState<OnlineWorldMapScreen> createState() =>
      _OnlineWorldMapScreenState();
}

class _OnlineWorldMapScreenState extends ConsumerState<OnlineWorldMapScreen>
    with WidgetsBindingObserver {
  static final LatLngBounds _worldBounds = LatLngBounds(
    const LatLng(-85, -180),
    const LatLng(85, 180),
  );
  static final CameraFit _initialWorldCameraFit = CameraFit.insideBounds(
    bounds: _worldBounds,
    minZoom: 1,
    maxZoom: 18,
  );

  static const InteractionOptions _interaction = InteractionOptions(
    flags:
        InteractiveFlag.drag |
        InteractiveFlag.flingAnimation |
        InteractiveFlag.pinchMove |
        InteractiveFlag.pinchZoom |
        InteractiveFlag.doubleTapZoom |
        InteractiveFlag.scrollWheelZoom,
  );

  final MapController _mapController = MapController();

  bool _loading = false;
  List<_CountryCount> _counts = const [];
  final Map<String, LatLng> _countryCenters = {};
  final Map<String, String> _countryNames = {};
  String? _lastLanguageCode;
  Timer? _refreshTimer;
  int _lastOnlineCount = -1;
  bool _isFetchingLocation = false;
  RealtimeChannel? _sessionChannel;
  RealtimeChannel? _presenceTickChannel;
  Timer? _presenceTickDebounce;
  bool _pendingTickRefresh = false;
  static bool _hasFetchedInitialLocation = false;
  static String? _presenceRunForUserId;

  _OnlineWorldMapScreenState() {
    print('[CRITICAL] 🗺️ _OnlineWorldMapScreenState constructor called');
  }

  @override
  void initState() {
    super.initState();
    print(
      '[CRITICAL] 🗺️ OnlineWorldMapScreen.initState() called - screen is being created',
    );
    print('[${_ts()}] 🗺️ OnlineWorldMapScreen: initState called');
    WidgetsBinding.instance.addObserver(this);
    // Load cached localized country names if available (pre-fetched at startup).
    _loadCachedCountryNames();
    // Call _refresh immediately instead of in a microtask to avoid delay
    _refresh();
    // Set up periodic refresh to keep country breakdown current while screen is open
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_loading) {
        unawaited(_refresh());
      }
    });
    // Subscribe to user_session changes so the map refreshes as soon as
    // any user's session (and thus country) is registered/updated.
    // This catches the case where registerSession completes slightly after
    // update_user_activity fires the realtime event to other users.
    // Own session changes are ignored: they already trigger a refresh via
    // the presence cycle, so reacting to them here would be redundant churn.
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null) {
      _sessionChannel = Supabase.instance.client
          .channel('online_map_session_$userId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'user_session',
            callback: (payload) {
              if (!mounted || _loading) return;
              final Map<String, dynamic> record = payload.newRecord.isNotEmpty
                  ? payload.newRecord
                  : payload.oldRecord;
              final changedUserId = record['user_id']?.toString();
              if (changedUserId == userId) return;
              unawaited(_refresh());
            },
          )
          .subscribe((status, err) {
            if (err != null) {
              print(
                '[${_ts()}] 🗺️ OnlineWorldMapScreen: Session channel status: $status, error: $err',
              );
            }
          });
    }
    // Subscribe to the shared presence tick: a single-row table touched by DB
    // triggers whenever any user's presence flips (login, explicit logout, or
    // the stale-online cleanup after heartbeats stop). The raw user_session
    // channel above only delivers rows this user can read under RLS; the tick
    // table is readable by every authenticated user, so logon/logoff always
    // refreshes the country markers immediately. The counts themselves still
    // come from the SECURITY DEFINER RPC — the tick carries no user data.
    _presenceTickChannel = Supabase.instance.client
        .channel('online_map_presence_tick_${userId ?? 'anon'}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'presence_tick',
          callback: (payload) {
            if (!mounted) return;
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: presence_tick event received: $payload',
            );
            if (_loading) {
              // A refresh is already in flight; re-run it right after so the
              // change that produced this tick is never dropped.
              _pendingTickRefresh = true;
              return;
            }
            _presenceTickDebounce?.cancel();
            _presenceTickDebounce = Timer(
              const Duration(milliseconds: 500),
              () {
                if (!mounted || _loading) return;
                unawaited(_refresh());
              },
            );
          },
        )
        .subscribe((status, err) {
          if (err != null) {
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: Presence tick channel status: $status, error: $err',
            );
          }
        });
  }

  /// Loads cached localized country names from local storage (pre-fetched at
  /// startup) so they are available immediately. Falls back to English defaults.
  void _loadCachedCountryNames() {
    try {
      final langCode = ref
          .read(localizationProvider)
          .currentLocale
          .languageCode;
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Loading cached country names for lang=$langCode',
      );
      LocalDbService.shared.getCachedLocalizedCountryNames(langCode).then((
        names,
      ) {
        if (names != null && names.isNotEmpty && mounted) {
          print(
            '[${_ts()}] 🗺️ OnlineWorldMapScreen: Loaded ${names.length} cached country names for lang=$langCode',
          );
          setState(() {
            _countryNames.addAll(names);
          });
        } else {
          print(
            '[${_ts()}] 🗺️ OnlineWorldMapScreen: No cached country names found for lang=$langCode',
          );
        }
      });
    } catch (e) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Error loading cached country names: $e',
      );
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _presenceTickDebounce?.cancel();
    if (_sessionChannel != null) {
      Supabase.instance.client.removeChannel(_sessionChannel!);
      _sessionChannel = null;
    }
    if (_presenceTickChannel != null) {
      Supabase.instance.client.removeChannel(_presenceTickChannel!);
      _presenceTickChannel = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_loading) {
      final isOnline = ref.read(connectivityProvider).value ?? true;
      if (isOnline) {
        unawaited(_refresh());
      }
    }
  }

  static String _lastKnownCountryKey(String userId) =>
      'last_known_country_$userId';

  /// Returns this user's country from the latest non-revoked session that
  /// actually has one. Several sessions can exist per user (multi-device, or
  /// a cold-start registration without GPS followed by a map registration
  /// with GPS); the newest row alone may have a NULL country while an older
  /// row has the valid one, so all recent rows are scanned and the first
  /// non-empty country wins. Returns null when no session has a country.
  Future<String?> _fetchOwnCountryFromSession(String userId) async {
    try {
      final rows = await Supabase.instance.client
          .from('user_session')
          .select('country, last_active_at')
          .eq('user_id', userId)
          .eq('revoked', false)
          .order('last_active_at', ascending: false)
          .limit(5);
      final list = (rows as List).cast<Map<String, dynamic>>();
      for (final row in list) {
        final code = (row['country'] as String?)?.trim().toUpperCase();
        if (code != null && code.isNotEmpty) return code;
      }
      return null;
    } catch (e) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Failed to fetch own country from session: $e',
      );
      return null;
    }
  }

  Future<String?> _readLastKnownCountry(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString(_lastKnownCountryKey(userId));
      if (code == null || code.isEmpty) return null;
      return code.toUpperCase();
    } catch (e) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Failed to read cached country: $e',
      );
      return null;
    }
  }

  Future<void> _cacheLastKnownCountry(String userId, String countryCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastKnownCountryKey(userId), countryCode);
    } catch (e) {
      print('[${_ts()}] 🗺️ OnlineWorldMapScreen: Failed to cache country: $e');
    }
  }

  Future<void> _refreshPresence() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refreshPresence - no user ID',
      );
      return;
    }

    final platformText = kIsWeb
        ? 'web'
        : defaultTargetPlatform == TargetPlatform.android
        ? 'android'
        : defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : defaultTargetPlatform == TargetPlatform.macOS
        ? 'macos'
        : defaultTargetPlatform == TargetPlatform.windows
        ? 'windows'
        : defaultTargetPlatform == TargetPlatform.linux
        ? 'linux'
        : 'unknown';

    print(
      '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refreshPresence start platform=$platformText',
    );
    final pinState = ref.read(pinnedLocationProvider);
    final pinActive = pinState.isActive || await PinnedLocationGate.isActive();
    final locationSource = pinActive ? 'pinned' : 'live';

    final isVisible = ref.read(isVisibleProvider);
    final shouldSkipLocation = !isVisible && _hasFetchedInitialLocation;

    if (!shouldSkipLocation) {
      if (_isFetchingLocation) {
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: Skipping location refresh (already in progress)',
        );
      } else {
        _isFetchingLocation = true;
        try {
          print('[${_ts()}] 🗺️ OnlineWorldMapScreen: Refreshing location...');
          // Pinned home-base: keep showing the pin, never refresh live GPS.
          if (pinActive) {
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: Pinned location active, skipping live refresh',
            );
            _hasFetchedInitialLocation = true;
          } else {
            await ref.read(currentLocationProvider.notifier).refreshLocation();
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: Location refreshed successfully',
            );
            _hasFetchedInitialLocation = true;
          }
        } catch (e) {
          print(
            '[${_ts()}] ⚠️ OnlineWorldMapScreen: Location refresh failed: $e',
          );
        } finally {
          _isFetchingLocation = false;
        }
      }
    } else {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Skipping location refresh (user invisible, already fetched initial location)',
      );
    }

    if (!mounted) return;
    final position = pinActive ? null : ref.read(currentLocationProvider);
    print('[${_ts()}] OnlineWorldMapScreen: locationSource=$locationSource');

    // Update location if available (skipped while a pin is active: the
    // server RPC would ignore it anyway, and we must not send live GPS).
    if (position != null && !pinActive) {
      try {
        print('[${_ts()}] 🗺️ OnlineWorldMapScreen: Updating user location...');
        await Supabase.instance.client.rpc(
          'update_user_location',
          params: <String, dynamic>{
            'p_user_id': userId,
            'p_latitude': position.latitude,
            'p_longitude': position.longitude,
            'p_speed': position.speed,
            'p_heading': position.heading,
          },
        );
        print(
          '[${_ts()}] ✅ OnlineWorldMapScreen: User location updated successfully',
        );
      } catch (e) {
        print(
          '[${_ts()}] ❌ OnlineWorldMapScreen: Failed to update user location: $e',
        );
      }
    } else {
      print(
        '[${_ts()}] ⚠️ OnlineWorldMapScreen: No position available, skipping location update',
      );
    }

    // Register session FIRST so country is set before marking as online.
    // This prevents a race where other users see this user as "online" (from user_activity)
    // but the map's get_online_dashboard_stats RPC can't find their country
    // (neither user_locations.country_code nor user_session.country set yet).
    // bypassCooldown is required: the cold-start bootstrap registration (no
    // GPS) may have run seconds earlier and started the 60s per-user
    // cooldown. Without bypass, this GPS-backed registration would be
    // skipped and the earlier country-less session would leave this user
    // permanently "online, but not on map".
    var sessionRegistered = false;
    try {
      print('[${_ts()}] 🗺️ OnlineWorldMapScreen: Registering session...');
      final cachedCountry = pinActive
          ? await _readLastKnownCountry(userId)
          : null;
      sessionRegistered = await SessionService.registerSession(
        userId,
        platform: platformText,
        countryOverride: cachedCountry,
        latitude: pinActive ? null : position?.latitude,
        longitude: pinActive ? null : position?.longitude,
        bypassCooldown: true,
      );
      print(
        '[${_ts()}] ✅ OnlineWorldMapScreen: Session registered successfully',
      );
    } catch (e) {
      print(
        '[${_ts()}] ⚠️ OnlineWorldMapScreen: Failed to register session: $e',
      );
    }

    if (sessionRegistered) {
      // Run after registration so the server can safely mark this user online.
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Updating user activity (marking as online)...',
      );
      await UserActivityService.instance.pingIfDue(
        userId,
        source: 'nearby-map',
      );
      print(
        '[${_ts()}] ✅ OnlineWorldMapScreen: User activity updated - user marked as ONLINE',
      );
    } else {
      print(
        '[${_ts()}] ⚠️ OnlineWorldMapScreen: Skipping activity update because session registration failed',
      );
    }

    // Cache the caller's country (set by registerSession) so the next map open
    // can render the caller's own marker instantly, without waiting for GPS.
    // Scan recent sessions for the first non-empty country: the single newest
    // row may be country-less while an older row has the valid country.
    try {
      final country = await _fetchOwnCountryFromSession(userId);
      if (country != null && country.isNotEmpty) {
        await _cacheLastKnownCountry(userId, country);
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: Cached own country: $country',
        );
      }
    } catch (e) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: Failed to cache own country: $e',
      );
    }

    // Refresh the map now that this user is online so their country appears as
    // soon as GPS/session registration completes. The per-user presence guard
    // in _refresh() prevents this from re-running another presence cycle.
    if (mounted && !_loading) {
      unawaited(_refresh());
    }

    print('[${_ts()}] 🗺️ OnlineWorldMapScreen: _refreshPresence complete');
  }

  Future<void> _moveToUserCountry() async {
    if (!mounted) return;

    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _moveToUserCountry - offline, skipping',
      );
      return;
    }

    setState(() => _loading = true);
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null || !mounted) return;

      // Prefer the newest session WITH a country (same shadowing concern as
      // the map counts: the single newest row may be country-less).
      final countryCode = await _fetchOwnCountryFromSession(userId);
      if (countryCode == null || countryCode.isEmpty) return;

      if (!_countryCenters.containsKey(countryCode)) {
        final l10n = ref.read(localizationProvider);
        await _ensureCountryCenters([
          countryCode,
        ], l10n.currentLocale.languageCode);
      }

      final center = _countryCenters[countryCode];
      if (center != null) {
        _mapController.move(center, 5.0);
      }
    } catch (e) {
      print('Error moving to user country: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    print('[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() called');
    if (!mounted) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - widget not mounted, returning',
      );
      return;
    }

    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - offline, skipping network call',
      );
      return;
    }

    print(
      '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - setting loading state',
    );
    setState(() {
      _loading = true;
    });

    final l10n = ref.read(localizationProvider);
    final languageCode = l10n.currentLocale.languageCode;

    // Clear cache if language changed to get localized country names
    if (_lastLanguageCode != null && _lastLanguageCode != languageCode) {
      _countryCenters.clear();
      _countryNames.clear();
      _loadCachedCountryNames(); // Load cached names for the new language
    }
    _lastLanguageCode = languageCode;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;

      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - calling get_online_dashboard_stats RPC',
      );

      // One round trip: per-country counts (excluding self), self country and
      // self online state from the same server snapshot. No users query, no
      // session query — the server derives country from coordinates
      // (user_locations.country_code, 20262110).
      final rpcResult = await Supabase.instance.client.rpc(
        'get_online_dashboard_stats',
        params: <String, dynamic>{'p_user_id': userId},
      );

      print('[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - RPC completed');

      final statsMap = (rpcResult as Map?)?.cast<String, dynamic>() ?? const {};
      final list =
          (statsMap['countries'] as List<dynamic>?) ?? const <dynamic>[];
      final parsed = <_CountryCount>[];
      for (final row in list) {
        if (row is! Map) continue;
        final code = (row['country'] ?? '').toString().trim().toUpperCase();
        final count = (row['user_count'] as num?)?.toInt();
        if (code.isEmpty || count == null || count <= 0) continue;
        parsed.add(_CountryCount(countryCode: code, count: count));
      }

      // Add the caller's own country from the same snapshot so it shows up
      // instantly, before the presence flow marks them online server-side.
      // Self is only added when their own profile is complete — the RPC
      // excludes incomplete profiles, so an account that has not finished
      // onboarding must not sneak back in here.
      final selfCountsOnline =
          statsMap['self_online'] == true &&
          statsMap['self_is_complete'] == true;
      String? myCountry;
      if (userId != null) {
        myCountry = (statsMap['self_country'] as String?)?.trim();
        if (myCountry != null && myCountry.isEmpty) myCountry = null;
        if (selfCountsOnline && myCountry != null && myCountry.isNotEmpty) {
          final idx = parsed.indexWhere((e) => e.countryCode == myCountry);
          if (idx >= 0) {
            parsed[idx] = _CountryCount(
              countryCode: myCountry,
              count: parsed[idx].count + 1,
            );
          } else {
            parsed.add(_CountryCount(countryCode: myCountry, count: 1));
          }
        } else if (myCountry == null || myCountry.isEmpty) {
          print(
            '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - own country still unknown (no location/session country on server yet)',
          );
        }
      }

      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - parsed ${parsed.length} countries with online users',
      );
      final codes = parsed
          .map((e) => e.countryCode)
          .toSet()
          .toList(growable: false);

      // Seed centers from static defaults immediately, then update UI
      // so markers appear right away (no wait for Nominatim).
      _ensureCountryCenters(codes, l10n.currentLocale.languageCode);
      if (!mounted) return;
      setState(() {
        _counts = parsed;
      });
      print(
        '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - success, updated UI with ${parsed.length} countries',
      );

      // Run the presence cycle (GPS + register session + mark online) once per
      // user per app launch. Subsequent refreshes only re-query the country
      // counts; re-registering the session on every refresh/timer tick would
      // be unnecessary churn. Self liveness is maintained by the global
      // heartbeat and user_location by the global location service.
      // Exception: when our own country is still unknown we must retry the
      // presence cycle — otherwise a first run with GPS-not-ready would leave
      // this user permanently "online, but not on map" until app restart.
      final needsPresenceRetry = myCountry == null || myCountry.isEmpty;
      if (_presenceRunForUserId != userId ||
          (userId != null && needsPresenceRetry)) {
        _presenceRunForUserId = userId;
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - running presence cycle',
        );
        unawaited(_refreshPresence());
      } else {
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - skipping presence (already ran for this user)',
        );
      }
    } catch (e) {
      print('[${_ts()}] ❌ OnlineWorldMapScreen: _refresh() - ERROR: $e');
      if (!mounted) return;
      final errorTranslationKey =
          ErrorLocalizationService.getMapErrorTranslationKey(e);
      final isNetworkError = errorTranslationKey.startsWith('networkError');
      if (!isNetworkError) {
        setState(() {
          _counts = const [];
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
        print('[${_ts()}] 🗺️ OnlineWorldMapScreen: _refresh() - complete');
        // A presence tick arrived while this refresh was in flight: run one
        // more pass so the counters land on the newest server state.
        if (_pendingTickRefresh) {
          _pendingTickRefresh = false;
          _presenceTickDebounce?.cancel();
          _presenceTickDebounce = Timer(const Duration(milliseconds: 200), () {
            if (!mounted || _loading) return;
            unawaited(_refresh());
          });
        }
      }
    }
  }

  // Approximate country centers (lat, lng) for instant marker display.
  // Nominatim fallback is used only for countries not in this map.
  static const _countryCenterDefaults = <String, LatLng>{
    'AD': LatLng(42.5, 1.6),
    'AE': LatLng(23.4, 53.8),
    'AF': LatLng(33.9, 67.7),
    'AG': LatLng(17.1, -61.8),
    'AI': LatLng(18.2, -63.1),
    'AL': LatLng(41.2, 20.2),
    'AM': LatLng(40.1, 45.0),
    'AO': LatLng(-11.2, 17.9),
    'AQ': LatLng(-75.0, 0.0),
    'AR': LatLng(-38.4, -63.6),
    'AS': LatLng(-14.3, -170.1),
    'AT': LatLng(47.5, 14.6),
    'AU': LatLng(-25.3, 133.8),
    'AW': LatLng(12.5, -70.0),
    'AX': LatLng(60.2, 20.0),
    'AZ': LatLng(40.3, 47.6),
    'BA': LatLng(44.2, 17.7),
    'BB': LatLng(13.2, -59.5),
    'BD': LatLng(23.7, 90.4),
    'BE': LatLng(50.7, 4.6),
    'BF': LatLng(12.3, -1.7),
    'BG': LatLng(42.7, 25.5),
    'BH': LatLng(26.0, 50.6),
    'BI': LatLng(-3.4, 29.9),
    'BJ': LatLng(9.3, 2.3),
    'BL': LatLng(17.9, -62.8),
    'BM': LatLng(32.3, -64.8),
    'BN': LatLng(4.5, 114.7),
    'BO': LatLng(-16.7, -64.7),
    'BQ': LatLng(12.2, -68.3),
    'BR': LatLng(-14.2, -51.9),
    'BS': LatLng(24.9, -77.4),
    'BT': LatLng(27.5, 90.4),
    'BV': LatLng(-54.4, 3.4),
    'BW': LatLng(-22.3, 24.7),
    'BY': LatLng(53.7, 27.9),
    'BZ': LatLng(17.2, -88.5),
    'CA': LatLng(56.1, -106.3),
    'CC': LatLng(-12.2, 96.9),
    'CD': LatLng(-4.0, 21.8),
    'CF': LatLng(6.6, 20.5),
    'CG': LatLng(-0.2, 15.8),
    'CH': LatLng(46.8, 8.2),
    'CI': LatLng(7.5, -5.7),
    'CK': LatLng(-21.2, -159.8),
    'CL': LatLng(-35.7, -71.5),
    'CM': LatLng(5.3, 12.3),
    'CN': LatLng(35.9, 104.2),
    'CO': LatLng(4.6, -74.1),
    'CR': LatLng(9.9, -84.2),
    'CU': LatLng(21.6, -77.8),
    'CV': LatLng(16.0, -24.0),
    'CW': LatLng(12.2, -68.9),
    'CX': LatLng(-10.5, 105.7),
    'CY': LatLng(35.1, 33.3),
    'CZ': LatLng(49.7, 15.3),
    'DE': LatLng(51.2, 10.4),
    'DJ': LatLng(11.8, 42.6),
    'DK': LatLng(56.0, 10.0),
    'DM': LatLng(15.4, -61.4),
    'DO': LatLng(18.7, -70.2),
    'DZ': LatLng(28.0, 2.6),
    'EC': LatLng(-1.3, -78.0),
    'EE': LatLng(58.6, 25.0),
    'EG': LatLng(26.8, 30.8),
    'EH': LatLng(24.5, -12.9),
    'ER': LatLng(15.2, 38.9),
    'ES': LatLng(40.2, -3.2),
    'ET': LatLng(8.6, 39.7),
    'FI': LatLng(64.5, 26.2),
    'FJ': LatLng(-17.2, 178.0),
    'FK': LatLng(-51.8, -59.0),
    'FM': LatLng(7.4, 150.3),
    'FO': LatLng(61.9, -6.9),
    'FR': LatLng(46.6, 2.2),
    'GA': LatLng(-0.5, 11.6),
    'GB': LatLng(55.4, -3.4),
    'GD': LatLng(12.3, -61.7),
    'GE': LatLng(42.3, 43.4),
    'GF': LatLng(3.9, -53.0),
    'GG': LatLng(49.5, -2.6),
    'GH': LatLng(7.9, -1.0),
    'GI': LatLng(36.1, -5.4),
    'GL': LatLng(71.7, -42.6),
    'GM': LatLng(13.4, -15.3),
    'GN': LatLng(9.9, -10.6),
    'GP': LatLng(16.2, -61.5),
    'GQ': LatLng(1.5, 10.5),
    'GR': LatLng(39.1, 22.0),
    'GS': LatLng(-54.4, -36.6),
    'GT': LatLng(15.8, -90.2),
    'GU': LatLng(13.4, 144.8),
    'GW': LatLng(12.0, -14.9),
    'GY': LatLng(4.9, -58.9),
    'HK': LatLng(22.3, 114.2),
    'HM': LatLng(-53.0, 73.5),
    'HN': LatLng(14.8, -86.8),
    'HR': LatLng(45.1, 15.5),
    'HT': LatLng(19.0, -72.3),
    'HU': LatLng(47.2, 19.5),
    'ID': LatLng(-0.8, 117.0),
    'IE': LatLng(53.2, -7.6),
    'IL': LatLng(31.0, 34.9),
    'IM': LatLng(54.2, -4.5),
    'IN': LatLng(20.6, 78.9),
    'IO': LatLng(-6.0, 71.5),
    'IQ': LatLng(33.0, 43.7),
    'IR': LatLng(32.4, 54.7),
    'IS': LatLng(64.9, -18.8),
    'IT': LatLng(41.9, 12.1),
    'JE': LatLng(49.2, -2.1),
    'JM': LatLng(18.2, -77.3),
    'JO': LatLng(31.2, 36.8),
    'JP': LatLng(36.3, 138.5),
    'KE': LatLng(-0.1, 37.9),
    'KG': LatLng(41.5, 74.5),
    'KH': LatLng(12.6, 104.6),
    'KI': LatLng(1.5, 173.0),
    'KM': LatLng(-11.9, 43.4),
    'KN': LatLng(17.3, -62.7),
    'KP': LatLng(40.0, 127.0),
    'KR': LatLng(36.5, 127.8),
    'KW': LatLng(29.3, 47.6),
    'KY': LatLng(19.3, -81.2),
    'KZ': LatLng(48.0, 66.0),
    'LA': LatLng(20.0, 103.0),
    'LB': LatLng(33.9, 35.8),
    'LC': LatLng(13.9, -60.9),
    'LI': LatLng(47.2, 9.5),
    'LK': LatLng(7.6, 80.7),
    'LR': LatLng(6.4, -9.4),
    'LS': LatLng(-29.5, 28.2),
    'LT': LatLng(55.3, 23.9),
    'LU': LatLng(49.8, 6.1),
    'LV': LatLng(56.9, 24.8),
    'LY': LatLng(26.3, 17.6),
    'MA': LatLng(31.7, -7.1),
    'MC': LatLng(43.7, 7.4),
    'MD': LatLng(47.4, 28.5),
    'ME': LatLng(42.7, 19.2),
    'MF': LatLng(18.1, -63.1),
    'MG': LatLng(-19.3, 46.7),
    'MH': LatLng(10.0, 169.0),
    'MK': LatLng(41.6, 21.8),
    'ML': LatLng(17.6, -2.0),
    'MM': LatLng(22.0, 96.0),
    'MN': LatLng(46.8, 103.0),
    'MO': LatLng(22.2, 113.5),
    'MP': LatLng(15.1, 145.7),
    'MQ': LatLng(14.7, -61.0),
    'MR': LatLng(21.0, -10.9),
    'MS': LatLng(16.7, -62.2),
    'MT': LatLng(35.9, 14.4),
    'MU': LatLng(-20.3, 57.6),
    'MV': LatLng(3.2, 73.5),
    'MW': LatLng(-13.3, 34.3),
    'MX': LatLng(23.6, -102.5),
    'MY': LatLng(3.9, 109.7),
    'MZ': LatLng(-18.7, 35.5),
    'NA': LatLng(-22.1, 17.3),
    'NC': LatLng(-21.0, 165.5),
    'NE': LatLng(17.5, 8.1),
    'NF': LatLng(-29.0, 167.9),
    'NG': LatLng(9.1, 8.7),
    'NI': LatLng(12.9, -85.0),
    'NL': LatLng(52.2, 5.3),
    'NO': LatLng(64.6, 14.7),
    'NP': LatLng(28.4, 84.1),
    'NR': LatLng(-0.5, 166.9),
    'NU': LatLng(-19.0, -169.9),
    'NZ': LatLng(-41.4, 173.0),
    'OM': LatLng(21.5, 56.0),
    'PA': LatLng(8.5, -80.1),
    'PE': LatLng(-9.2, -74.8),
    'PF': LatLng(-17.7, -149.4),
    'PG': LatLng(-6.3, 146.0),
    'PH': LatLng(12.4, 123.0),
    'PK': LatLng(30.0, 69.3),
    'PL': LatLng(52.1, 19.4),
    'PM': LatLng(46.9, -56.3),
    'PN': LatLng(-24.3, -130.1),
    'PR': LatLng(18.2, -66.5),
    'PS': LatLng(31.9, 35.2),
    'PT': LatLng(39.5, -7.8),
    'PW': LatLng(7.5, 134.5),
    'PY': LatLng(-23.4, -58.3),
    'QA': LatLng(25.3, 51.2),
    'RE': LatLng(-21.1, 55.5),
    'RO': LatLng(45.9, 24.8),
    'RS': LatLng(44.2, 21.0),
    'RU': LatLng(63.0, 100.0),
    'RW': LatLng(-2.0, 29.9),
    'SA': LatLng(24.0, 45.0),
    'SB': LatLng(-9.5, 161.0),
    'SC': LatLng(-4.7, 55.5),
    'SD': LatLng(15.5, 30.2),
    'SE': LatLng(62.0, 16.0),
    'SG': LatLng(1.3, 103.8),
    'SH': LatLng(-24.1, -9.7),
    'SI': LatLng(46.1, 14.9),
    'SJ': LatLng(78.0, 20.0),
    'SK': LatLng(48.7, 19.5),
    'SL': LatLng(8.5, -11.9),
    'SM': LatLng(43.9, 12.5),
    'SN': LatLng(14.4, -14.5),
    'SO': LatLng(5.2, 46.2),
    'SR': LatLng(4.0, -56.0),
    'SS': LatLng(8.0, 31.0),
    'ST': LatLng(0.3, 6.6),
    'SV': LatLng(13.8, -88.9),
    'SX': LatLng(18.0, -63.0),
    'SY': LatLng(34.8, 38.9),
    'SZ': LatLng(-26.3, 31.4),
    'TC': LatLng(21.8, -71.8),
    'TD': LatLng(15.7, 18.7),
    'TF': LatLng(-43.0, 69.0),
    'TG': LatLng(8.5, 1.0),
    'TH': LatLng(14.0, 101.0),
    'TJ': LatLng(38.5, 71.2),
    'TK': LatLng(-8.9, -171.9),
    'TL': LatLng(-8.8, 126.0),
    'TM': LatLng(38.9, 59.5),
    'TN': LatLng(33.9, 9.5),
    'TO': LatLng(-21.2, -175.2),
    'TR': LatLng(39.0, 35.5),
    'TT': LatLng(10.5, -61.3),
    'TV': LatLng(-8.5, 179.0),
    'TW': LatLng(23.7, 120.9),
    'TZ': LatLng(-6.3, 35.0),
    'UA': LatLng(48.4, 31.3),
    'UG': LatLng(1.3, 32.5),
    'UM': LatLng(19.3, 166.6),
    'US': LatLng(39.8, -98.6),
    'UY': LatLng(-32.5, -55.2),
    'UZ': LatLng(41.8, 64.0),
    'VA': LatLng(41.9, 12.5),
    'VC': LatLng(13.2, -61.2),
    'VE': LatLng(7.1, -65.8),
    'VG': LatLng(18.4, -64.5),
    'VI': LatLng(18.3, -64.9),
    'VN': LatLng(16.5, 107.5),
    'VU': LatLng(-16.0, 167.0),
    'WF': LatLng(-13.3, -176.2),
    'WS': LatLng(-13.7, -172.1),
    'XK': LatLng(42.6, 20.9),
    'YE': LatLng(15.6, 48.0),
    'YT': LatLng(-12.8, 45.2),
    'ZA': LatLng(-28.5, 24.7),
    'ZM': LatLng(-13.5, 27.7),
    'ZW': LatLng(-19.0, 29.5),
  };

  static const _countryNameDefaults = <String, String>{
    'AD': 'Andorra',
    'AE': 'United Arab Emirates',
    'AF': 'Afghanistan',
    'AG': 'Antigua and Barbuda',
    'AI': 'Anguilla',
    'AL': 'Albania',
    'AM': 'Armenia',
    'AO': 'Angola',
    'AQ': 'Antarctica',
    'AR': 'Argentina',
    'AS': 'American Samoa',
    'AT': 'Austria',
    'AU': 'Australia',
    'AW': 'Aruba',
    'AX': 'Åland Islands',
    'AZ': 'Azerbaijan',
    'BA': 'Bosnia and Herzegovina',
    'BB': 'Barbados',
    'BD': 'Bangladesh',
    'BE': 'Belgium',
    'BF': 'Burkina Faso',
    'BG': 'Bulgaria',
    'BH': 'Bahrain',
    'BI': 'Burundi',
    'BJ': 'Benin',
    'BL': 'Saint Barthélemy',
    'BM': 'Bermuda',
    'BN': 'Brunei',
    'BO': 'Bolivia',
    'BQ': 'Caribbean Netherlands',
    'BR': 'Brazil',
    'BS': 'Bahamas',
    'BT': 'Bhutan',
    'BV': 'Bouvet Island',
    'BW': 'Botswana',
    'BY': 'Belarus',
    'BZ': 'Belize',
    'CA': 'Canada',
    'CC': 'Cocos Islands',
    'CD': 'Democratic Republic of the Congo',
    'CF': 'Central African Republic',
    'CG': 'Congo',
    'CH': 'Switzerland',
    'CI': 'Ivory Coast',
    'CK': 'Cook Islands',
    'CL': 'Chile',
    'CM': 'Cameroon',
    'CN': 'China',
    'CO': 'Colombia',
    'CR': 'Costa Rica',
    'CU': 'Cuba',
    'CV': 'Cape Verde',
    'CW': 'Curaçao',
    'CX': 'Christmas Island',
    'CY': 'Cyprus',
    'CZ': 'Czech Republic',
    'DE': 'Germany',
    'DJ': 'Djibouti',
    'DK': 'Denmark',
    'DM': 'Dominica',
    'DO': 'Dominican Republic',
    'DZ': 'Algeria',
    'EC': 'Ecuador',
    'EE': 'Estonia',
    'EG': 'Egypt',
    'EH': 'Western Sahara',
    'ER': 'Eritrea',
    'ES': 'Spain',
    'ET': 'Ethiopia',
    'FI': 'Finland',
    'FJ': 'Fiji',
    'FK': 'Falkland Islands',
    'FM': 'Micronesia',
    'FO': 'Faroe Islands',
    'FR': 'France',
    'GA': 'Gabon',
    'GB': 'United Kingdom',
    'GD': 'Grenada',
    'GE': 'Georgia',
    'GF': 'French Guiana',
    'GG': 'Guernsey',
    'GH': 'Ghana',
    'GI': 'Gibraltar',
    'GL': 'Greenland',
    'GM': 'Gambia',
    'GN': 'Guinea',
    'GP': 'Guadeloupe',
    'GQ': 'Equatorial Guinea',
    'GR': 'Greece',
    'GS': 'South Georgia',
    'GT': 'Guatemala',
    'GU': 'Guam',
    'GW': 'Guinea-Bissau',
    'GY': 'Guyana',
    'HK': 'Hong Kong',
    'HM': 'Heard Island',
    'HN': 'Honduras',
    'HR': 'Croatia',
    'HT': 'Haiti',
    'HU': 'Hungary',
    'ID': 'Indonesia',
    'IE': 'Ireland',
    'IL': 'Israel',
    'IM': 'Isle of Man',
    'IN': 'India',
    'IO': 'British Indian Ocean Territory',
    'IQ': 'Iraq',
    'IR': 'Iran',
    'IS': 'Iceland',
    'IT': 'Italy',
    'JE': 'Jersey',
    'JM': 'Jamaica',
    'JO': 'Jordan',
    'JP': 'Japan',
    'KE': 'Kenya',
    'KG': 'Kyrgyzstan',
    'KH': 'Cambodia',
    'KI': 'Kiribati',
    'KM': 'Comoros',
    'KN': 'Saint Kitts and Nevis',
    'KP': 'North Korea',
    'KR': 'South Korea',
    'KW': 'Kuwait',
    'KY': 'Cayman Islands',
    'KZ': 'Kazakhstan',
    'LA': 'Laos',
    'LB': 'Lebanon',
    'LC': 'Saint Lucia',
    'LI': 'Liechtenstein',
    'LK': 'Sri Lanka',
    'LR': 'Liberia',
    'LS': 'Lesotho',
    'LT': 'Lithuania',
    'LU': 'Luxembourg',
    'LV': 'Latvia',
    'LY': 'Libya',
    'MA': 'Morocco',
    'MC': 'Monaco',
    'MD': 'Moldova',
    'ME': 'Montenegro',
    'MF': 'Saint Martin',
    'MG': 'Madagascar',
    'MH': 'Marshall Islands',
    'MK': 'North Macedonia',
    'ML': 'Mali',
    'MM': 'Myanmar',
    'MN': 'Mongolia',
    'MO': 'Macau',
    'MP': 'Northern Mariana Islands',
    'MQ': 'Martinique',
    'MR': 'Mauritania',
    'MS': 'Montserrat',
    'MT': 'Malta',
    'MU': 'Mauritius',
    'MV': 'Maldives',
    'MW': 'Malawi',
    'MX': 'Mexico',
    'MY': 'Malaysia',
    'MZ': 'Mozambique',
    'NA': 'Namibia',
    'NC': 'New Caledonia',
    'NE': 'Niger',
    'NF': 'Norfolk Island',
    'NG': 'Nigeria',
    'NI': 'Nicaragua',
    'NL': 'Netherlands',
    'NO': 'Norway',
    'NP': 'Nepal',
    'NR': 'Nauru',
    'NU': 'Niue',
    'NZ': 'New Zealand',
    'OM': 'Oman',
    'PA': 'Panama',
    'PE': 'Peru',
    'PF': 'French Polynesia',
    'PG': 'Papua New Guinea',
    'PH': 'Philippines',
    'PK': 'Pakistan',
    'PL': 'Poland',
    'PM': 'Saint Pierre and Miquelon',
    'PN': 'Pitcairn Islands',
    'PR': 'Puerto Rico',
    'PS': 'Palestine',
    'PT': 'Portugal',
    'PW': 'Palau',
    'PY': 'Paraguay',
    'QA': 'Qatar',
    'RE': 'Réunion',
    'RO': 'Romania',
    'RS': 'Serbia',
    'RU': 'Russia',
    'RW': 'Rwanda',
    'SA': 'Saudi Arabia',
    'SB': 'Solomon Islands',
    'SC': 'Seychelles',
    'SD': 'Sudan',
    'SE': 'Sweden',
    'SG': 'Singapore',
    'SH': 'Saint Helena',
    'SI': 'Slovenia',
    'SJ': 'Svalbard and Jan Mayen',
    'SK': 'Slovakia',
    'SL': 'Sierra Leone',
    'SM': 'San Marino',
    'SN': 'Senegal',
    'SO': 'Somalia',
    'SR': 'Suriname',
    'SS': 'South Sudan',
    'ST': 'São Tomé and Príncipe',
    'SV': 'El Salvador',
    'SX': 'Sint Maarten',
    'SY': 'Syria',
    'SZ': 'Eswatini',
    'TC': 'Turks and Caicos Islands',
    'TD': 'Chad',
    'TF': 'French Southern Territories',
    'TG': 'Togo',
    'TH': 'Thailand',
    'TJ': 'Tajikistan',
    'TK': 'Tokelau',
    'TL': 'East Timor',
    'TM': 'Turkmenistan',
    'TN': 'Tunisia',
    'TO': 'Tonga',
    'TR': 'Turkey',
    'TT': 'Trinidad and Tobago',
    'TV': 'Tuvalu',
    'TW': 'Taiwan',
    'TZ': 'Tanzania',
    'UA': 'Ukraine',
    'UG': 'Uganda',
    'UM': 'U.S. Minor Outlying Islands',
    'US': 'United States',
    'UY': 'Uruguay',
    'UZ': 'Uzbekistan',
    'VA': 'Vatican City',
    'VC': 'Saint Vincent and the Grenadines',
    'VE': 'Venezuela',
    'VG': 'British Virgin Islands',
    'VI': 'U.S. Virgin Islands',
    'VN': 'Vietnam',
    'VU': 'Vanuatu',
    'WF': 'Wallis and Futuna',
    'WS': 'Samoa',
    'XK': 'Kosovo',
    'YE': 'Yemen',
    'YT': 'Mayotte',
    'ZA': 'South Africa',
    'ZM': 'Zambia',
    'ZW': 'Zimbabwe',
  };

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

  Future<void> _ensureCountryCenters(
    List<String> codes,
    String languageCode,
  ) async {
    // Seed from static defaults first so markers appear immediately.
    // Priority: Hive cache > bundled localized map > English defaults
    for (final code in codes) {
      if (!_countryCenters.containsKey(code) &&
          _countryCenterDefaults.containsKey(code)) {
        _countryCenters[code] = _countryCenterDefaults[code]!;
      }
      // Bundled localized names (no network needed)
      if (!_countryNames.containsKey(code)) {
        final bundledLangMap = localizedCountryNames[languageCode];
        if (bundledLangMap != null) {
          if (bundledLangMap.containsKey(code)) {
            _countryNames[code] = bundledLangMap[code]!;
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: bundled map seeded $code → "${bundledLangMap[code]}" (lang=$languageCode)',
            );
          } else {
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: bundled map missing $code (lang=$languageCode)',
            );
          }
        } else {
          print(
            '[${_ts()}] 🗺️ OnlineWorldMapScreen: no bundled map for lang=$languageCode',
          );
        }
      }
      // English static defaults as final fallback
      if (!_countryNames.containsKey(code) &&
          _countryNameDefaults.containsKey(code)) {
        _countryNames[code] = _countryNameDefaults[code]!;
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: english fallback seeded $code → "${_countryNameDefaults[code]}"',
        );
      }
    }

    final supportedLangCode = _getSupportedLanguageCode(languageCode);
    final missing = codes
        .where((c) => !_countryCenters.containsKey(c))
        .toList(growable: false);

    // Resolve centers for any countries not in static defaults (sequential, rare)
    for (final code in missing) {
      try {
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
            'countrycodes': code.toLowerCase(),
          },
        );

        final resp = await http
            .get(uri, headers: {'User-Agent': 'MatchMe/1.0'})
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode < 200 || resp.statusCode >= 300) continue;

        final decoded = jsonDecode(resp.body);
        if (decoded is! List || decoded.isEmpty) continue;

        final first = decoded[0];
        if (first is! Map) continue;

        final lat = double.tryParse(first['lat'] as String? ?? '');
        final lon = double.tryParse(first['lon'] as String? ?? '');
        if (lat == null || lon == null) continue;

        _countryCenters[code] = LatLng(lat, lon);
      } catch (_) {}
    }

    if (missing.isNotEmpty && mounted) {
      setState(() {}); // Rebuild markers with any new centers resolved
    }

    // Skip Nominatim if bundled map already seeded all names (no network needed).
    final allNamesSeeded = codes.every((c) => _countryNames.containsKey(c));
    if (!allNamesSeeded) {
      _resolveLocalizedNames(codes, supportedLangCode);
    }
  }

  /// Fetches localized country names from Nominatim concurrently in the background.
  /// Each successful response updates [_countryNames] and triggers a rebuild.
  void _resolveLocalizedNames(List<String> codes, String langCode) {
    for (final code in codes) {
      try {
        final countryName = _getCountryNameForCode(code);
        final uri = Uri.https(
          'nominatim.openstreetmap.org',
          '/search',
          <String, String>{
            'q': countryName,
            'format': 'json',
            'accept-language': langCode,
            'limit': '1',
            'addressdetails': '0',
            'countrycodes': code.toLowerCase(),
          },
        );

        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames fetching for $code (lang=$langCode)',
        );
        http
            .get(uri, headers: {'User-Agent': 'MatchMe/1.0'})
            .timeout(const Duration(seconds: 8))
            .then((resp) {
              if (!mounted || resp.statusCode < 200 || resp.statusCode >= 300) {
                print(
                  '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames $code failed status=${resp.statusCode}',
                );
                return;
              }
              final decoded = jsonDecode(resp.body);
              if (decoded is! List || decoded.isEmpty) {
                print(
                  '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames $code empty response',
                );
                return;
              }
              final first = decoded[0];
              if (first is! Map) return;
              final name = first['name'] as String?;
              if (name == null || name.isEmpty) return;

              print(
                '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames $code → "$name" (lang=$langCode)',
              );
              _countryNames[code] = name;
              if (mounted) setState(() {});
            })
            .catchError((e) {
              print(
                '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames $code error: $e',
              );
            });
      } catch (e) {
        print(
          '[${_ts()}] 🗺️ OnlineWorldMapScreen: _resolveLocalizedNames $code exception: $e',
        );
      }
    }
  }

  List<Marker> _buildMarkers(BuildContext context) {
    final markers = <Marker>[];
    final l10n = ref.read(localizationProvider);
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.visible,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 2),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.9),
                      width: 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      l10n.formatCount(entry.count),
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
    final pin = ref.watch(pinnedLocationProvider);
    final isOnline = ref.watch(connectivityProvider).value ?? true;
    // Use dashboardStatsProvider for real-time total (same as home screen)
    // while _counts provides the per-country breakdown for map markers
    final dashboardStats = ref.watch(dashboardStatsProvider);

    // Reset initial-location flag when user becomes visible again
    ref.listen(isVisibleProvider, (prev, next) {
      if (next == true && prev == false) {
        _hasFetchedInitialLocation = false;
      }
    });

    // Listen to online count changes to refresh country markers in real-time
    ref.listen(dashboardStatsProvider, (previous, next) {
      next.when(
        data: (stats) {
          final currentOnline = stats['online'];
          if (currentOnline == null) return;
          if (_lastOnlineCount != -1 && _lastOnlineCount != currentOnline) {
            print(
              '[${_ts()}] 🗺️ OnlineWorldMapScreen: Online count changed ($_lastOnlineCount -> $currentOnline), refreshing country breakdown',
            );
            if (mounted &&
                !_loading &&
                (ref.read(connectivityProvider).value ?? true)) {
              unawaited(_refresh());
            }
          }
          _lastOnlineCount = currentOnline;
        },
        loading: () {},
        error: (_, e) {},
      );
    });

    final displayedOnlineCount = dashboardStats.when<int?>(
      data: (stats) => stats['online'],
      loading: () => null,
      error: (_, e) => null,
    );

    final mapBackground = Theme.of(context).colorScheme.surfaceContainerHighest;

    return Scaffold(
      backgroundColor: mapBackground,
      appBar: AppBar(
        title: ShrinkText(l10n.getString('homeOnline')),
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.34,
                    ),
                    child: Text(
                      l10n.getString(
                        'onlineMapTotalOnline',
                        params: {
                          'count': displayedOnlineCount?.toString() ?? '...',
                        },
                      ),
                      style: Theme.of(context).textTheme.labelLarge,
                      maxLines: 2,
                      overflow: TextOverflow.visible,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          OnboardingSectionPrompt(tour: kOnboardingWorldMapSectionTour),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: mapBackground),
                if (pin.isActive)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: PinnedMapStatusBanner(pin: pin, l10n: l10n),
                  ),
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(20, 0),
                    initialZoom: 1.6,
                    initialCameraFit: _initialWorldCameraFit,
                    minZoom: 1,
                    maxZoom: 18,
                    backgroundColor: mapBackground,
                    cameraConstraint: const CameraConstraint.containLatitude(
                      85,
                      -85,
                    ),
                    interactionOptions: _interaction,
                  ),
                  children: [
                    if (isOnline)
                      TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'matchme.app',
                        tileBuilder: darkMapTileBuilderFor(
                          Theme.of(context).brightness,
                        ),
                      ),
                    if (isOnline)
                      RichAttributionWidget(
                        attributions: [
                          TextSourceAttribution('OpenStreetMap contributors'),
                        ],
                      ),
                    MarkerLayer(markers: _buildMarkers(context)),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 110,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: FloatingActionButton.small(
                      heroTag: null,
                      tooltip: l10n.getString('locationShareCenter'),
                      onPressed: _loading ? null : _moveToUserCountry,
                      child: const Icon(Icons.my_location),
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _MapZoomControls(
                    controller: _mapController,
                    minZoom: 1,
                    maxZoom: 18,
                    l10n: l10n,
                  ),
                ),
                if (!isOnline)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Material(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Text(
                          l10n.getString('generalOffline'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
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

Widget _buildScaleIndicator(
  BuildContext context,
  double zoom,
  LatLng? cameraCenter,
  LatLng? userLatLng,
  bool usesImperial,
  LocalizationState l10n,
) {
  final center = cameraCenter ?? userLatLng;
  if (center == null) return const SizedBox.shrink();

  final safeZoom = zoom.isFinite ? zoom.clamp(1.0, 18.0).toDouble() : 16.0;
  final mpp = 156543.03392 * cos(center.latitude * pi / 180) / pow(2, safeZoom);
  if (mpp <= 0 || mpp.isNaN || mpp.isInfinite) return const SizedBox.shrink();

  final niceMeters = _niceScaleDistance(mpp);
  final barWidth = niceMeters / mpp;
  final label = formatDistanceWithImperial(niceMeters, usesImperial, l10n);

  final color = Theme.of(context).colorScheme.onSurface;
  final textScaler = MediaQuery.textScalerOf(context);
  final labelPainter = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(fontSize: 12, color: color),
    ),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout();

  return Material(
    elevation: 2,
    borderRadius: BorderRadius.circular(4),
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
    child: SizedBox(
      width: max(barWidth, labelPainter.width + 12),
      height: max(28.0, labelPainter.height + 18),
      child: CustomPaint(
        painter: _ScaleBarPainter(
          barWidth: barWidth,
          label: label,
          color: color,
          textScaler: textScaler,
        ),
      ),
    ),
  );
}

/// Largest 1-2-5 distance whose bar fits within [_scaleBarMaxWidth], so the
/// widget can never exceed its cap regardless of zoom, screen, or locale.
double _niceScaleDistance(double mpp) {
  var best = _scaleMagnitudes.first;
  for (final m in _scaleMagnitudes) {
    if (m / mpp <= _scaleBarMaxWidth) best = m;
  }
  return best;
}

class _ScaleBarPainter extends CustomPainter {
  final double barWidth;
  final String label;
  final Color color;
  final TextScaler textScaler;

  _ScaleBarPainter({
    required this.barWidth,
    required this.label,
    required this.color,
    this.textScaler = TextScaler.noScaling,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final barY = size.height / 2;
    final barLeft = 4.0;
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
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout();
    tp.paint(canvas, Offset(barLeft, barY - 14));
  }

  @override
  bool shouldRepaint(_ScaleBarPainter old) =>
      old.barWidth != barWidth ||
      old.label != label ||
      old.color != color ||
      old.textScaler != textScaler;
}

class _MapZoomControls extends StatelessWidget {
  final MapController controller;
  final double minZoom;
  final double maxZoom;
  final LocalizationState l10n;

  const _MapZoomControls({
    required this.controller,
    required this.minZoom,
    required this.maxZoom,
    required this.l10n,
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
          Padding(
            padding: const EdgeInsets.all(4),
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: l10n.getString('mapZoomIn'),
              onPressed: () => _zoom(1),
              child: const Icon(Icons.add),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.all(4),
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: l10n.getString('mapZoomOut'),
              onPressed: () => _zoom(-1),
              child: const Icon(Icons.remove),
            ),
          ),
        ],
      ),
    );
  }
}
