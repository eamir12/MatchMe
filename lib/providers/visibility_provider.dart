// lib/providers/visibility_provider.dart
// Updated to make smart GPS throttling work regardless of app state (active/inactive)
// while still tracking app state for future use
import 'dart:async';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:matchme/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:matchme/services/battery_service.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/location_share_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/pinned_location_gate.dart';
// Import web-specific functionality stub
import '../web_imports.dart' as html;
import 'package:matchme/services/offline_trail_service.dart';

part 'visibility_provider.g.dart';

// Provides the boolean state (true = visible) and manages the service
@riverpod
class IsVisible extends _$IsVisible {
  LocationService? _locationService;
  bool _initialStartAttempted =
      false; // Flag to attempt start only once initially
  static const String _manualPrefsKey = 'manual_visibility';
  static const String _effectivePrefsKey = 'effective_visibility';
  static const String _gpsIntervalPrefsKey = 'flutter.gps_interval';
  static const String _smartThrottlingPrefsKey =
      'flutter.smart_throttling_enabled';
  static const String _backgroundMatchingPrefsKey =
      'flutter.background_matching_mode';
  // Backs up the user's original Background Matching preference before we temporarily
  // disable it for invisibility. The native service also writes false to the
  // _backgroundMatchingPrefsKey, so we need this separate key for accurate restoration.
  static const String _backgroundMatchingBackupPrefsKey =
      'flutter.background_matching_backup';
  static bool?
  _cachedManualVisibility; // survives provider rebuilds for sync access
  bool? _manualVisibility;
  String? _lastRestoredUserId;
  late Future<void> _initializationFuture;
  bool? _lastConnectivityOnline;
  bool _lifecycleObserverAdded = false;
  WidgetsBindingObserver? _lifecycleObserver;

  // Debouncing for app active/inactive events
  DateTime? _lastAppStateChange;
  Duration _appStateDebounce = const Duration(milliseconds: 500);

  // Smart throttling state
  final List<Position> _recentPositions = [];
  int _maxRecentPositions = 5; // Will be loaded from config
  double _similarityThresholdMeters = 10.0; // Will be loaded from config
  double _movementThresholdMeters = 10.0; // Will be loaded from config
  int _consecutiveMovementCount = 0; // hysteresis: require N consecutive moves
  static const int _requiredConsecutiveMoves = 2;

  // Prevent rapid throttling changes that cause restart loops
  DateTime? _lastThrottlingChange;
  Duration _throttlingDebounce = const Duration(
    seconds: 3,
  ); // Will be loaded from config
  int? _currentAppliedInterval; // Track what interval is actually running

  // Debounce rapid repeated updateLocationStreamInterval calls at startup
  DateTime? _lastIntervalUpdateCall;

  // Periodic visibility poll timer (fallback when Realtime is unreliable, e.g. app backgrounded)
  Timer? _visibilityPollTimer;
  static const Duration _visibilityPollInterval = Duration(seconds: 30);

  // Battery-based throttling
  bool _isBatteryThrottled = false;
  StreamSubscription<BatteryInfo>?
  _batterySubscription; // listens to battery changes
  int _batteryThrottleInterval = 60; // Will be loaded from config
  int _batteryLowThreshold = 15; // Will be loaded from config
  int _stationaryThrottleInterval = 60; // Will be loaded from config
  // Serializes Background Matching Mode changes to prevent race conditions between
  // _disableBackgroundMatchingForInvisibility() and _restoreBackgroundMatchingMode()
  // writing to SharedPreferences concurrently.
  bool _backgroundMatchingChangeInProgress = false;
  RealtimeChannel? _visibilityRealtimeChannel;
  String? _visibilityRealtimeUserId;
  String _systemVisibilityStatus = 'visible';
  dynamic
  _webVisibilityListener; // Web visibility listener for minimized window support

  @override
  bool build() {
    // Keep this provider alive even if not listened to, as it manages
    // background visibility/location state which must persist.
    ref.keepAlive();
    if (kDebugMode) {
      debugPrint(
        '[${DateTime.now().toIso8601String()}] 👁️ [IsVisible] build: manual=$_manualVisibility kIsWeb=$kIsWeb',
      );
    }

    _locationService ??= ref.watch(locationServiceProvider);
    _locationService!.setLocationUpdateCallback((p) {
      _handleLocationChange(p);
      // Keep the app-wide current location state in sync with the LocationService.
      // This avoids starting any separate continuous GPS streams that would keep
      // Android's location indicator on.
      if (p is Position) {
        ref.read(currentLocationProvider.notifier).updateFromService(p);
      }
    });
    // Do not clear _manualVisibility here; it will be loaded from local storage first
    _locationService!.setVisibility(_manualVisibility ?? true);
    if (!_lifecycleObserverAdded) {
      _lifecycleObserverAdded = true;
      _lifecycleObserver = _VisibilityLifecycleObserver((state) {
        if (state == AppLifecycleState.resumed) {
          unawaited(_syncAndPropagateVisibility());
          unawaited(_syncLocationShareOnVisible());
          unawaited(ensureServiceStarted());
        } else if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) {
          unawaited(_pauseForegroundLocationStream());
          unawaited(_syncAndPropagateVisibility());
        } else if (state == AppLifecycleState.inactive) {
          unawaited(_syncAndPropagateVisibility());
        }
      });
      WidgetsBinding.instance.addObserver(_lifecycleObserver!);
    }
    ref.onDispose(() {
      _stopVisibilityPollTimer();
      _clearVisibilityRealtimeSubscription();
      _detachWebVisibilityListener();
      if (_lifecycleObserverAdded && _lifecycleObserver != null) {
        WidgetsBinding.instance.removeObserver(_lifecycleObserver!);
        _lifecycleObserverAdded = false;
        _lifecycleObserver = null;
      }
    });
    _ensureVisibilityRealtimeSubscription();
    _attachWebVisibilityListener();

    // Load config values asynchronously
    Future.microtask(() async {
      try {
        _maxRecentPositions = await appConfigService.getInt(
          'gps.stationary_max_positions',
          defaultValue: 5,
        );
        _similarityThresholdMeters = await appConfigService.getDouble(
          'gps.stationary_similarity_threshold_meters',
          defaultValue: 10.0,
        );
        _movementThresholdMeters = await appConfigService.getDouble(
          'gps.stationary_movement_threshold_meters',
          defaultValue: 10.0,
        );
        _throttlingDebounce = await appConfigService.getDuration(
          'ui.throttling_debounce_seconds',
          defaultValue: const Duration(seconds: 3),
        );
        _batteryThrottleInterval = await appConfigService.getInt(
          'gps.battery_throttle_interval_seconds',
          defaultValue: 60,
        );
        _batteryLowThreshold = await appConfigService.getInt(
          'gps.battery_low_threshold_percent',
          defaultValue: 15,
        );
        _stationaryThrottleInterval = await appConfigService.getInt(
          'gps.stationary_throttle_interval_seconds',
          defaultValue: 60,
        );
        _appStateDebounce = await appConfigService.getDuration(
          'ui.app_state_debounce_ms',
          defaultValue: const Duration(milliseconds: 500),
        );
        if (kDebugMode) {
          debugPrint(
            '📋 [IsVisible] Loaded config: maxPos=$_maxRecentPositions, simThresh=$_similarityThresholdMeters, batteryThresh=$_batteryLowThreshold, stationaryInterval=$_stationaryThrottleInterval',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '⚠️ [IsVisible] Failed to load config, using defaults: $e',
          );
        }
      }
    });

    // On app start: load from local storage first (immediate display), then sync with Supabase
    _initializationFuture = Future.microtask(() async {
      final userId = Supabase.instance.client.auth.currentUser?.id;

      // 1. Load from local storage FIRST for immediate correct display (avoids flash of Invisible)
      await loadManualVisibility();
      try {
        final prefs = await SharedPreferences.getInstance();
        final effectiveFromLocal = prefs.getBool(_effectivePrefsKey);
        final displayValue = effectiveFromLocal ?? _manualVisibility ?? true;
        state = displayValue;
        _locationService?.setVisibility(displayValue);
        try {
          await BackgroundService.updateVisibility(displayValue);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '🔴 [IsVisible] Failed to update background service from local: $e',
            );
          }
        }

        // If the user is invisible on cold start, immediately disable Background
        // Matching Mode on the native side to prevent the persistent notification
        // from showing when/if the app gets backgrounded.
        if (!displayValue) {
          await _disableBackgroundMatchingForInvisibility();
        }

        if (kDebugMode) {
          debugPrint(
            '🔵 [IsVisible] Loaded from local storage: effective=$effectiveFromLocal, manual=$_manualVisibility, display=$displayValue',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('🔴 [IsVisible] Error loading from local storage: $e');
        }
        state = _manualVisibility ?? true;
      }

      // 2. Then fetch from Supabase and sync (DB is source of truth when online)
      if (userId != null) {
        try {
          await _syncVisibilityFromRemote(userId: userId);
        } catch (e) {
          if (kDebugMode) {
            debugPrint(
              '🔴 [IsVisible] Error fetching user_visibility_setting from DB: $e',
            );
          }
        }
      }

      // 3. Ensure rules are loaded and effective visibility is correct
      try {
        final rulesNotifier = ref.read(invisibilityRulesProvider.notifier);
        await rulesNotifier.waitForInitialization();
        await rulesNotifier.syncFromSupabase();
        final syncedRules = ref.read(invisibilityRulesProvider);
        if (syncedRules.locationRules.any((rule) => rule.enabled)) {
          try {
            await ref.read(currentLocationProvider.notifier).refreshLocation();
          } catch (_) {}
        }
        await _updateEffectiveVisibility();
      } catch (e) {
        print('⚠️ [IsVisible] Error waiting for rules: $e');
      }

      await _hydrateGpsConfigCache();

      // Ensure LocationService knows whether smart throttling is enabled for the current user
      final enabled = await _isSmartThrottlingEnabled();
      try {
        _locationService?.setSmartThrottlingEnabled(enabled);
      } catch (e) {
        // Ignore
      }

      // Start periodic visibility polling as a fallback when Realtime is unreliable
      _startVisibilityPollTimer();

      // Subscribe to battery changes so we can enforce battery-based throttling
      try {
        final batteryService = ref.watch(batteryServiceProvider);
        _batterySubscription ??= batteryService.stream.listen((info) async {
          // Skip battery throttling logic when user is invisible (GPS is not running)
          if (!state) return;

          // Skip battery throttling logic when offline (GPS is not running)
          final isOnline = ref.read(connectivityProvider).value != false;
          if (!isOnline) return;

          // Only enforce battery-based throttling when Smart GPS is enabled for the user
          final throttlingEnabled = await _isSmartThrottlingEnabled();
          final batteryLowNotCharging =
              (info.level <= _batteryLowThreshold) &&
              (info.state != BatteryState.charging &&
                  info.state != BatteryState.full);

          if (throttlingEnabled) {
            if (batteryLowNotCharging && !_isBatteryThrottled) {
              _isBatteryThrottled = true;
              _currentAppliedInterval = null; // force restart
              // Show persistent notification only when user is visible
              if (state) {
                try {
                  final l10n = ref.read(localizationProvider);
                  final msg = l10n
                      .getString('gpsThrottledLowBattery')
                      .replaceAll(
                        '{interval}',
                        _batteryThrottleInterval.toString(),
                      )
                      .replaceAll(
                        '{threshold}',
                        _batteryLowThreshold.toString(),
                      );
                  ref
                      .read(systemNotificationProvider.notifier)
                      .notify(
                        SystemNotification(
                          text: msg,
                          isPersistent: true,
                          notificationType: 'battery_throttle',
                        ),
                      );
                } catch (_) {}
              }
              await updateLocationStreamInterval();
            } else if (!batteryLowNotCharging && _isBatteryThrottled) {
              _isBatteryThrottled = false;
              _currentAppliedInterval = null; // force restart
              // Clear battery throttle notification
              ref
                  .read(systemNotificationProvider.notifier)
                  .clearType('battery_throttle');
              await updateLocationStreamInterval();
            }
          } else {
            // If Smart GPS got disabled, ensure battery-throttle state is cleared
            if (_isBatteryThrottled) {
              _isBatteryThrottled = false;
              _currentAppliedInterval = null; // force restart
              await updateLocationStreamInterval();
            }
          }
        });

        // Ensure we cancel subscription when provider is disposed
        ref.onDispose(() {
          _batterySubscription?.cancel();
          _batterySubscription = null;
        });
      } catch (e) {
        // ignore battery subscription failures
      }
    });

    // Listen to location changes to update effective visibility for location-based rules
    ref.listen(currentLocationProvider, (previous, next) {
      _updateEffectiveVisibility();
    });

    // Re-evaluate effective visibility whenever the live profile state
    // changes: the wizard keeps the profile incomplete while it is open
    // (suppressing the "MatchMe Active" notification) and flips it to
    // complete on submit, which must (de)activate the background service
    // accordingly.
    final profileListenUserId = Supabase.instance.client.auth.currentUser?.id;
    if (profileListenUserId != null) {
      ref.listen<AsyncValue<UserProfile?>>(
        profileEditProvider(profileListenUserId),
        (previous, next) {
          if (!ref.mounted) return;
          unawaited(_updateEffectiveVisibility());
        },
      );
    }

    // Listen for connectivity changes to stop/start GPS appropriately
    // Note: We do NOT change the user's online presence based on connectivity.
    // The user should remain online regardless of app state or temporary connectivity fluctuations.
    // The background service handles presence tracking independently.
    ref.listen<AsyncValue<bool>>(connectivityProvider, (previous, next) async {
      try {
        final isOnline = next.value;
        if (isOnline == null) return;
        if (_lastConnectivityOnline == isOnline) return;
        _lastConnectivityOnline = isOnline;
        if (!isOnline) {
          // Offline: keep GPS running only when the user opted into finding
          // people met without internet; otherwise stop to save battery.
          final keepForRetro = await OfflineTrailService.instance
              .isEnabledForCurrentUser();
          if (!keepForRetro) {
            print(
              '🟠 Connectivity lost - stopping location stream to avoid GPS while offline',
            );
            _locationService?.stopLocationStream();
            _currentAppliedInterval = null;
          } else {
            print(
              '🟠 Connectivity lost - keeping location stream for offline places (opted in)',
            );
            if (state) {
              final gpsInterval = await _getGpsInterval();
              await _locationService?.startLocationStream(gpsInterval);
              _currentAppliedInterval = gpsInterval;
            }
          }
          // Clear all throttle notifications when going offline
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('battery_throttle');
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('stationary_throttle');
        } else {
          print('🟢 Connectivity restored - re-evaluating location stream');
          // Upload places recorded while offline, then resume live stream.
          try {
            await OfflineTrailService.instance.uploadPendingTrail();
          } catch (_) {}
          // Re-evaluate interval now that we're online again
          if (state && _initialStartAttempted) {
            // Reset battery throttled flag so updateLocationStreamInterval will re-check and show notification if needed
            _isBatteryThrottled = false;
            updateLocationStreamInterval();
          }
        }
      } catch (_) {}
    });

    ref.listen<AsyncValue<AuthState>>(authStateProvider, (
      previous,
      next,
    ) async {
      final authState = next.asData?.value;
      if (authState == null) return;
      final event = authState.event;

      if (event == AuthChangeEvent.signedOut) {
        _clearVisibilityRealtimeSubscription();
        _lastRestoredUserId = null;
        _locationService?.stopLocationStream();
        _locationService?.setVisibility(false);
        state = false;
        _initialStartAttempted = false;
        _recentPositions.clear();
        _consecutiveMovementCount = 0;
        _lastThrottlingChange = null;
        _currentAppliedInterval = null;
        _isBatteryThrottled = false;
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('battery_throttle');
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('stationary_throttle');
        try {
          await BackgroundService.stop();
        } catch (_) {}
        return;
      }

      if (event != AuthChangeEvent.initialSession &&
          event != AuthChangeEvent.signedIn) {
        return;
      }

      final userId =
          authState.session?.user.id ??
          Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;
      _ensureVisibilityRealtimeSubscription();
      if (_lastRestoredUserId == userId &&
          event == AuthChangeEvent.initialSession) {
        return;
      }
      _lastRestoredUserId = userId;

      Future.microtask(() async {
        await loadManualVisibility();

        bool displayValue;
        try {
          final prefs = await SharedPreferences.getInstance();
          final effectiveFromLocal = prefs.getBool(_effectivePrefsKey);
          displayValue = effectiveFromLocal ?? _manualVisibility ?? true;
        } catch (_) {
          displayValue = _manualVisibility ?? true;
        }

        _initialStartAttempted = false;
        _recentPositions.clear();
        _consecutiveMovementCount = 0;
        _lastThrottlingChange = null;
        _currentAppliedInterval = null;
        _isBatteryThrottled = false;
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('battery_throttle');
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('stationary_throttle');

        bool remoteSynced = false;
        try {
          await _syncVisibilityFromRemote(userId: userId);
          remoteSynced = true;
          final rulesNotifier = ref.read(invisibilityRulesProvider.notifier);
          await rulesNotifier.syncFromSupabase();
          final syncedRules = ref.read(invisibilityRulesProvider);
          if (syncedRules.locationRules.any((rule) => rule.enabled)) {
            try {
              await ref
                  .read(currentLocationProvider.notifier)
                  .refreshLocation();
            } catch (_) {}
          }
        } catch (_) {}

        // Only fall back to local if remote sync didn't update the state
        if (!remoteSynced) {
          state = displayValue;
          _locationService?.setVisibility(displayValue);
        }
      });
    });

    // Add browser focus/blur detection for web
    if (kIsWeb) {
      _setupBrowserFocusDetection();
    }

    // Use cached value from previous load if available — avoids flash on login.
    // Falls back to true only for the very first app launch (no cache yet).
    if (_manualVisibility == null && _cachedManualVisibility != null) {
      _manualVisibility = _cachedManualVisibility;
    }
    final defaultVal = _manualVisibility ?? true;
    if (kDebugMode) {
      debugPrint(
        '[${DateTime.now().toIso8601String()}] 👁️ [IsVisible] build returning: $defaultVal',
      );
    }
    return defaultVal;
  }

  Future<void> waitForInitialization() => _initializationFuture;

  int? _parseGpsInterval(dynamic raw) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null || value <= 0) return null;
    return value;
  }

  bool? _parseBool(dynamic raw) {
    if (raw is bool) return raw;
    if (raw == null) return null;
    final normalized = raw.toString().trim().toLowerCase();
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
    return null;
  }

  Future<void> _persistGpsConfig({
    int? gpsInterval,
    bool? smartThrottlingEnabled,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (gpsInterval != null && gpsInterval > 0) {
        await prefs.setInt(_gpsIntervalPrefsKey, gpsInterval);
      }
      if (smartThrottlingEnabled != null) {
        await prefs.setBool(_smartThrottlingPrefsKey, smartThrottlingEnabled);
      }
    } catch (_) {}
  }

  Future<void> _hydrateGpsConfigCache() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    int? gpsInterval;
    bool? smartThrottlingEnabled;

    try {
      final editState = ref.read(profileEditProvider(userId));
      if (editState.hasValue && editState.value != null) {
        gpsInterval = editState.value!.gpsIntervalDefault;
        smartThrottlingEnabled = editState.value!.smartGpsThrottlingEnabled;
      }
    } catch (_) {}

    try {
      final localProfile = await ref
          .read(localDbProvider)
          .getLocalProfile(userId);
      gpsInterval ??= _parseGpsInterval(localProfile?['gps_interval_default']);
      smartThrottlingEnabled ??= _parseBool(
        localProfile?['smart_gps_throttling_enabled'],
      );
    } catch (_) {}

    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('gps_interval_default, smart_gps_throttling_enabled')
          .eq('id', userId)
          .maybeSingle();
      gpsInterval =
          _parseGpsInterval(row?['gps_interval_default']) ?? gpsInterval;
      smartThrottlingEnabled =
          _parseBool(row?['smart_gps_throttling_enabled']) ??
          smartThrottlingEnabled;
    } catch (_) {
      try {
        final profile = await ref.read(userProfileProvider(userId).future);
        gpsInterval ??= profile?.gpsIntervalDefault;
        smartThrottlingEnabled ??= profile?.smartGpsThrottlingEnabled;
      } catch (_) {}
    }

    await _persistGpsConfig(
      gpsInterval: gpsInterval,
      smartThrottlingEnabled: smartThrottlingEnabled,
    );
  }

  Future<int> _getGpsInterval() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final fallback = await appConfigService.getInt(
        'gps.interval_default_seconds',
        defaultValue: 5,
      );
      if (userId == null) {
        return fallback;
      }

      // Try to get from profileEditProvider first (has immediate updates)
      try {
        final editState = ref.read(profileEditProvider(userId));
        if (editState.hasValue && editState.value != null) {
          final value = editState.value!.gpsIntervalDefault;
          await _persistGpsConfig(gpsInterval: value);
          return value;
        }
      } catch (e) {
        // Fall through to persisted/local sources
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        final persisted = prefs.getInt(_gpsIntervalPrefsKey);
        if (persisted != null && persisted > 0) {
          return persisted;
        }
      } catch (_) {}

      try {
        final localProfile = await ref
            .read(localDbProvider)
            .getLocalProfile(userId);
        final localValue = _parseGpsInterval(
          localProfile?['gps_interval_default'],
        );
        if (localValue != null) {
          await _persistGpsConfig(gpsInterval: localValue);
          return localValue;
        }
      } catch (_) {
        // Fall through to userProfileProvider
      }

      // Fall back to userProfileProvider
      final profileAsync = await ref.read(userProfileProvider(userId).future);
      final resolved = profileAsync?.gpsIntervalDefault;
      if (resolved != null && resolved > 0) {
        await _persistGpsConfig(gpsInterval: resolved);
        return resolved;
      }
      return fallback;
    } catch (e) {
      return await appConfigService.getInt(
        'gps.interval_default_seconds',
        defaultValue: 5,
      );
    }
  }

  Future<bool> _isSmartThrottlingEnabled() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return false;

      // Try to get from profileEditProvider first (has immediate updates)
      try {
        final editState = ref.read(profileEditProvider(userId));
        if (editState.hasValue && editState.value != null) {
          final value = editState.value!.smartGpsThrottlingEnabled;
          await _persistGpsConfig(smartThrottlingEnabled: value);
          return value;
        }
      } catch (e) {
        // Fall through to persisted/local sources
      }

      try {
        final prefs = await SharedPreferences.getInstance();
        final persisted = prefs.getBool(_smartThrottlingPrefsKey);
        if (persisted != null) {
          return persisted;
        }
      } catch (_) {}

      try {
        final localProfile = await ref
            .read(localDbProvider)
            .getLocalProfile(userId);
        final localValue = _parseBool(
          localProfile?['smart_gps_throttling_enabled'],
        );
        if (localValue != null) {
          await _persistGpsConfig(smartThrottlingEnabled: localValue);
          return localValue;
        }
      } catch (_) {
        // Fall through to userProfileProvider
      }

      // Fall back to userProfileProvider
      final profileAsync = await ref.read(userProfileProvider(userId).future);
      final resolved = profileAsync?.smartGpsThrottlingEnabled;
      if (resolved != null) {
        await _persistGpsConfig(smartThrottlingEnabled: resolved);
        return resolved;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  bool _arePositionsSimilar(List<Position> positions) {
    if (positions.length < _maxRecentPositions) return false;

    // Use accuracy-weighted similarity check
    // If GPS accuracy is poor, allow larger spread before considering it movement
    double sumAccuracy = 0;
    for (final p in positions) {
      sumAccuracy += p.accuracy;
    }
    final avgAccuracy = sumAccuracy / positions.length;

    // Adaptive threshold: use larger of static threshold or average accuracy
    // This prevents false movement detection when GPS is drifting due to poor accuracy
    final adaptiveThreshold = avgAccuracy > _similarityThresholdMeters
        ? avgAccuracy
        : _similarityThresholdMeters;

    final first = positions.first;
    for (final pos in positions) {
      final distance = Geolocator.distanceBetween(
        first.latitude,
        first.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (distance > adaptiveThreshold) return false;
    }
    return true;
  }

  bool _hasUserMoved(Position newPosition) {
    if (_recentPositions.isEmpty) return false;
    final last = _recentPositions.last;
    final distance = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      newPosition.latitude,
      newPosition.longitude,
    );
    // Accuracy-aware threshold: GPS drift indistinguishable from movement
    // when distance < reported accuracy. Use max(configured threshold,
    // last accuracy, new accuracy) so a 14m jump with 32m accuracy
    // is NOT considered movement when phone is stationary indoors.
    double adaptiveThreshold = _movementThresholdMeters;
    if (last.accuracy.isFinite && last.accuracy > adaptiveThreshold) {
      adaptiveThreshold = last.accuracy;
    }
    if (newPosition.accuracy.isFinite &&
        newPosition.accuracy > adaptiveThreshold) {
      adaptiveThreshold = newPosition.accuracy;
    }
    return distance > adaptiveThreshold;
  }

  Future<void> _handleLocationChange(dynamic newPosition) async {
    if (newPosition == null) return;

    late final Position newPos;
    try {
      double? toDouble(dynamic v) => v is num ? v.toDouble() : null;

      final dyn = newPosition;
      final coords = (() {
        try {
          final c = dyn.coords;
          return c ?? dyn;
        } catch (_) {
          return dyn;
        }
      })();

      final lat = toDouble(
        (() {
          try {
            return coords.latitude ?? coords.lat ?? dyn.latitude ?? dyn.lat;
          } catch (_) {
            return null;
          }
        })(),
      );

      final lon = toDouble(
        (() {
          try {
            return coords.longitude ?? coords.lng ?? dyn.longitude ?? dyn.lng;
          } catch (_) {
            return null;
          }
        })(),
      );

      if (lat == null || lon == null) return;

      final acc = toDouble(
        (() {
          try {
            return coords.accuracy ?? dyn.accuracy;
          } catch (_) {
            return null;
          }
        })(),
      );

      final spd = toDouble(
        (() {
          try {
            return coords.speed ?? dyn.speed;
          } catch (_) {
            return null;
          }
        })(),
      );

      final hdg = toDouble(
        (() {
          try {
            return coords.heading ?? dyn.heading;
          } catch (_) {
            return null;
          }
        })(),
      );

      DateTime? ts;
      final rawTs = (() {
        try {
          return dyn.timestamp ?? coords.timestamp;
        } catch (_) {
          return null;
        }
      })();
      if (rawTs is num) {
        ts = DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
      } else if (rawTs is String) {
        ts = DateTime.tryParse(rawTs);
      }

      newPos = Position(
        latitude: lat,
        longitude: lon,
        timestamp: ts ?? DateTime.now(),
        accuracy: acc ?? double.infinity,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: hdg ?? 0.0,
        headingAccuracy: 0.0,
        speed: spd ?? 0.0,
        speedAccuracy: 0.0,
      );
    } catch (_) {
      return;
    }

    // Debounce: Skip if we just changed throttling state within last 3 seconds
    if (_lastThrottlingChange != null &&
        DateTime.now().difference(_lastThrottlingChange!) <
            _throttlingDebounce) {
      // Still track position for history, but don't trigger throttling logic
      _recentPositions.add(newPos);
      if (_recentPositions.length > _maxRecentPositions) {
        _recentPositions.removeAt(0);
      }
      return;
    }

    final throttlingEnabled = await _isSmartThrottlingEnabled();

    // If throttling is OFF, we never need to check movement or adjust intervals
    if (!throttlingEnabled) {
      // Just add to history for tracking purposes, but don't act on it
      _recentPositions.add(newPos);
      if (_recentPositions.length > _maxRecentPositions) {
        _recentPositions.removeAt(0);
      }
      return;
    }

    // Throttling is ON - check if user has moved significantly
    final hasMoved = _hasUserMoved(newPos);

    if (hasMoved) {
      _consecutiveMovementCount++;
      // Require consecutive movements to confirm real displacement.
      // A single GPS spike (common indoors with poor accuracy) is
      // treated as drift and added to the stationary window instead
      // of immediately flipping 60s -> 10s and creating ping-pong.
      if (_consecutiveMovementCount < _requiredConsecutiveMoves) {
        _recentPositions.add(newPos);
        if (_recentPositions.length > _maxRecentPositions) {
          _recentPositions.removeAt(0);
        }
        return;
      }
      // Confirmed real movement - resume normal rate
      _consecutiveMovementCount = 0;
      _recentPositions.clear();
      _recentPositions.add(newPos);
      _lastThrottlingChange =
          DateTime.now(); // Record change to prevent rapid toggles
      await updateLocationStreamInterval();
      return;
    } else {
      // No significant movement - reset hysteresis counter
      _consecutiveMovementCount = 0;
    }

    // User hasn't moved significantly - add to history
    _recentPositions.add(newPos);
    if (_recentPositions.length > _maxRecentPositions) {
      _recentPositions.removeAt(0);
    }

    // Check if we now have 5 stationary positions to activate throttling
    if (_recentPositions.length >= _maxRecentPositions &&
        _arePositionsSimilar(_recentPositions)) {
      _lastThrottlingChange =
          DateTime.now(); // Record change to prevent rapid toggles
      await updateLocationStreamInterval();
    }
  }

  Future<void> loadManualVisibility() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Check for old key first
      final oldSaved = prefs.getBool('user_visibility');
      if (oldSaved != null) {
        _manualVisibility = oldSaved;
        await _saveManualVisibility(oldSaved);
        await prefs.remove('user_visibility'); // Migrate
      } else {
        _manualVisibility = prefs.getBool(_manualPrefsKey) ?? true;
      }
      _cachedManualVisibility = _manualVisibility;
      print(
        '🔵 [IsVisible] _loadManualVisibility: _manualVisibility=$_manualVisibility',
      );
    } catch (e) {
      _manualVisibility = true;
      _cachedManualVisibility = true;
      print('🔴 [IsVisible] _loadManualVisibility error: $e');
    }
  }

  Future<void> _saveManualVisibility(bool manual) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_manualPrefsKey, manual);
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _updateEffectiveVisibility() async {
    // Check mounted state before proceeding with any provider reads
    // The provider might be disposed while awaiting async operations
    if (_manualVisibility == null) {
      print(
        '🟡 [IsVisible] _updateEffectiveVisibility: manualVisibility not loaded yet',
      );
      return;
    }

    try {
      // Use try-catch to safely handle potential provider disposal issues
      final rules = ref.read(invisibilityRulesProvider);

      // Additional safety check
      if (!rules.isLoaded) return;

      final currentLocation = ref.read(currentLocationProvider);
      final shouldBeInvisible = rules.shouldBeInvisible(
        currentLatitude: currentLocation?.latitude,
        currentLongitude: currentLocation?.longitude,
        currentDateTime: DateTime.now(),
      );
      final systemAllowsVisibility = _systemVisibilityStatus == 'visible';

      // Sync rules-based visibility to the server so the RPC
      // is_user_truly_visible() can filter invisible users from nearby
      // counts and the map. Only touch system_visibility_status when it
      // is in our domain ('visible' or 'hidden_by_rule') — never
      // overwrite an admin-set status like 'banned'.
      _syncRulesBasedVisibility(shouldBeInvisible);

      // A user whose profile is not complete yet (onboarding wizard still
      // open) is not part of the matching pool and has never made a
      // visibility choice. Treat them as invisible regardless of any
      // persisted setting — otherwise the background service shows the
      // "MatchMe Active" notification (and polls GPS) while the user is
      // still completing their profile.
      bool profileComplete = true;
      try {
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        if (currentUserId != null) {
          profileComplete = await _isProfileComplete(currentUserId);
        }
      } catch (_) {}

      final effective =
          _manualVisibility! &&
          !shouldBeInvisible &&
          systemAllowsVisibility &&
          profileComplete;
      if (effective != state) {
        final wasVisible = state;
        state = effective;
        print(
          '🔴 [IsVisible] Visibility changed: $wasVisible → $effective (manual=$_manualVisibility, rules=!$shouldBeInvisible, system=$systemAllowsVisibility)',
        );

        // Persist effective visibility so background service can start in correct state
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_effectivePrefsKey, effective);
        } catch (e) {
          print('🔴 [IsVisible] Failed to persist effective visibility: $e');
        }

        _locationService?.setVisibility(effective);

        // Update background service visibility
        try {
          await BackgroundService.updateVisibility(effective);
        } catch (e) {
          print(
            '🔴 [IsVisible] Failed to update background service visibility: $e',
          );
        }

        if (effective && !wasVisible) {
          // User became visible - restart GPS tracking and evaluate throttling
          // NOTE: no 200ms skip here — skipping the start leaves GPS stopped
          // with no retry (field bug: rapid false→true→false→true ended
          // visible with a dead timer). Churn during initial sync is cheaper
          // than a stuck-off stream; updateLocationStreamInterval already
          // coalesces rapid restarts via its own debounce.
          print('🔴 [IsVisible] Starting GPS tracking (user became visible)');
          _recentPositions.clear();
          _consecutiveMovementCount = 0;
          _lastThrottlingChange = null;
          _currentAppliedInterval = null;
          // Reset throttled flags to force re-evaluation
          _isBatteryThrottled = false;
          // Bypass the 3s updateLocationStreamInterval debounce — this is a
          // critical visibility transition, not startup spam. Without this,
          // a visible→invisible→visible flicker within 3s gets debounced
          // and the timer is never recreated.
          _lastIntervalUpdateCall = null;

          // Restore Background Matching Mode if it was disabled when going invisible
          await _restoreBackgroundMatchingMode();

          // Use ensureServiceStarted if we never attempted, otherwise updateLocationStreamInterval
          // This handles the case where the app went invisible before GPS ever started
          if (!_initialStartAttempted) {
            await ensureServiceStarted();
          } else {
            await updateLocationStreamInterval(force: true);
          }
        } else if (!effective && wasVisible) {
          // User became invisible - stop GPS tracking
          print('🔴 [IsVisible] Stopping GPS tracking (user became invisible)');
          _locationService?.stopLocationStream();
          _currentAppliedInterval = null;
          _recentPositions.clear();
          _consecutiveMovementCount = 0;
          _lastThrottlingChange = null;
          _isBatteryThrottled = false;
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('battery_throttle');
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('stationary_throttle');

          // Disable Background Matching Mode to prevent the persistent notification
          // when the app is backgrounded while invisible. The native Android
          // service shows a persistent notification for Background Matching Mode when
          // the app is backgrounded, which is undesirable when the user is invisible.
          await _disableBackgroundMatchingForInvisibility();
        }
      } else {
        // Even if effective state didn't change, ensure the location service has the correct flag.
        // This is important during initialization or after a hot restart.
        _locationService?.setVisibility(state);

        // If the user is invisible on cold start (e.g., app was killed while invisible),
        // the visible→invisible transition won't fire, so we need to ensure Background Matching
        // is disabled here to prevent the persistent notification from showing.
        if (!state) {
          // Also ensure the timer is actually stopped: manual setVisibility(false)
          // pre-sets state before this runs, so the transition branch above may
          // never fire and the timer would keep ticking silently (ticks with no
          // positions). Stopping an already-stopped stream is a no-op.
          _locationService?.stopLocationStream();
          _currentAppliedInterval = null;
          await _disableBackgroundMatchingForInvisibility();
        } else if (_currentAppliedInterval == null && _initialStartAttempted) {
          // A null interval while a pin is active is the intentional parked
          // state (slow heartbeat, no GPS) — not a stuck-off timer. Healing
          // it would spin up GPS against the pin and spam this log.
          bool parked = false;
          try {
            parked =
                PinnedLocationGate.isActiveCached ||
                await PinnedLocationGate.isActive();
          } catch (_) {}
          if (parked) return;
          // Self-heal: we are visibly ON but no interval is applied (e.g. an
          // in-flight position stopped the stream after we went invisible and
          // the subsequent visible transition was lost to a race/debounce).
          // Restart instead of staying dead with no timer.
          print(
            '🔴 [IsVisible] Self-heal: visible but no interval applied — restarting GPS',
          );
          _lastIntervalUpdateCall = null;
          await updateLocationStreamInterval(force: true);
        }
      }
    } catch (e) {
      // If ref.read fails because provider is disposed, just log and exit gracefully
      print(
        '⚠️ [IsVisible] _updateEffectiveVisibility aborted (provider likely disposed): $e',
      );
    }
  }

  Future<void> _disableBackgroundMatchingForInvisibility() async {
    if (_backgroundMatchingChangeInProgress) return;
    _backgroundMatchingChangeInProgress = true;
    try {
      if (kIsWeb) return;
      final prefs = await SharedPreferences.getInstance();

      final wasEnabled = prefs.getBool(_backgroundMatchingPrefsKey) ?? false;
      if (!wasEnabled) return;

      await prefs.setBool(_backgroundMatchingBackupPrefsKey, true);
      await prefs.setBool(_backgroundMatchingPrefsKey, false);
      print(
        '🔴 [IsVisible] Temporarily disabling Background Matching Mode (user is invisible)',
      );

      await BackgroundService.updateBackgroundMatchingMode(false);
    } catch (e) {
      print('🔴 [IsVisible] Failed to disable Background Matching Mode: $e');
    } finally {
      _backgroundMatchingChangeInProgress = false;
    }
  }

  Future<void> _restoreBackgroundMatchingMode() async {
    if (_backgroundMatchingChangeInProgress) return;
    _backgroundMatchingChangeInProgress = true;
    try {
      if (kIsWeb) return;
      final prefs = await SharedPreferences.getInstance();
      final wasOriginallyEnabled =
          prefs.getBool(_backgroundMatchingBackupPrefsKey) ?? false;
      if (!wasOriginallyEnabled) return;

      print(
        '🔴 [IsVisible] Restoring Background Matching Mode (user became visible)',
      );

      await prefs.setBool(_backgroundMatchingPrefsKey, true);

      await BackgroundService.updateBackgroundMatchingMode(true);

      await prefs.remove(_backgroundMatchingBackupPrefsKey);
    } catch (e) {
      print('🔴 [IsVisible] Failed to restore Background Matching Mode: $e');
    } finally {
      _backgroundMatchingChangeInProgress = false;
    }
  }

  Future<void> updateEffectiveVisibility() => _updateEffectiveVisibility();

  Future<void> refreshFromLocalAndRemote() async {
    try {
      await loadManualVisibility();
    } catch (_) {}
    if (!ref.mounted) return;

    try {
      await _syncVisibilityFromRemote();
    } catch (_) {}
    if (!ref.mounted) return;

    try {
      final rulesNotifier = ref.read(invisibilityRulesProvider.notifier);
      await rulesNotifier.waitForInitialization();
      await rulesNotifier.syncFromSupabase();
    } catch (_) {}
    if (!ref.mounted) return;

    try {
      await _updateEffectiveVisibility();
    } catch (_) {}
    if (!ref.mounted) return;

    try {
      await updateLocationStreamInterval();
    } catch (_) {}
  }

  Future<void> _syncManualVisibilityChange(bool isVisible) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    try {
      // First update the user's visibility setting in the users table
      await Supabase.instance.client
          .from('users')
          .update({'user_visibility_setting': isVisible})
          .eq('id', userId);

      // Then call the new RPC function to update visibility in user_activity
      await Supabase.instance.client.rpc(
        'update_user_visibility',
        params: {'p_user_id': userId},
      );
    } catch (e) {
      await ref
          .read(localDbProvider)
          .saveVisibilityUpdateToOutbox(userId, isVisible);
    }
  }

  /// Pushes the rules-based visibility status to the server so that
  /// `is_user_truly_visible()` in the SQL RPCs can filter invisible users
  /// from nearby counts and the map.
  ///
  /// Only writes when the current `system_visibility_status` is in our
  /// domain ('visible' or 'hidden_by_rule') — never overwrites an
  /// admin-set status such as 'banned' or 'hidden'.
  void _syncRulesBasedVisibility(bool shouldBeInvisible) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    // Only act when the status is in our domain
    if (_systemVisibilityStatus != 'visible' &&
        _systemVisibilityStatus != 'hidden_by_rule') {
      return;
    }
    final targetStatus = shouldBeInvisible ? 'hidden_by_rule' : 'visible';
    if (targetStatus == _systemVisibilityStatus) return;
    // Fire-and-forget: don't block the visibility computation
    Supabase.instance.client
        .from('users')
        .update({'system_visibility_status': targetStatus})
        .eq('id', userId)
        .then((_) {
          _systemVisibilityStatus = targetStatus;
          if (kDebugMode) {
            print(
              '🔵 [IsVisible] Synced rules-based visibility to server: $targetStatus',
            );
          }
        })
        .catchError((e) {
          if (kDebugMode) {
            print('⚠️ [IsVisible] Failed to sync rules-based visibility: $e');
          }
        });
  }

  void _clearVisibilityRealtimeSubscription() {
    final userId = _visibilityRealtimeUserId;
    _visibilityRealtimeChannel = null;
    _visibilityRealtimeUserId = null;
    if (userId != null) {
      SupabaseRealtimeManager.instance.unregister('user_visibility_$userId');
    }
  }

  void _ensureVisibilityRealtimeSubscription() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _clearVisibilityRealtimeSubscription();
      return;
    }
    if (_visibilityRealtimeChannel != null &&
        _visibilityRealtimeUserId == userId) {
      return;
    }
    _clearVisibilityRealtimeSubscription();

    final channelName = 'user_visibility_$userId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      _visibilityRealtimeChannel = Supabase.instance.client
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'users',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: userId,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              final oldRecord = payload.oldRecord;
              final hasUserVisibility =
                  newRecord.containsKey('user_visibility_setting') ||
                  oldRecord.containsKey('user_visibility_setting');
              final hasSystemVisibility =
                  newRecord.containsKey('system_visibility_status') ||
                  oldRecord.containsKey('system_visibility_status');
              if (!hasUserVisibility && !hasSystemVisibility) return;
              final remoteManual =
                  (newRecord['user_visibility_setting'] ??
                      oldRecord['user_visibility_setting']) ==
                  true;
              final remoteSystem =
                  (newRecord['system_visibility_status'] ??
                          oldRecord['system_visibility_status'])
                      as String?;
              unawaited(
                _applyRemoteVisibilitySnapshot(
                  manualVisible: remoteManual,
                  systemVisibilityStatus: remoteSystem,
                  fromRealtime: true,
                ),
              );
            },
          )
          .subscribe((status, err) {
            if (status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut ||
                status == RealtimeSubscribeStatus.closed) {
              if (err != null && isExpectedOfflineFailure(err)) {
                // Proactively pause to suppress errors from other
                // channels and avoid the race with the connectivity
                // provider's own pauseAll() call.
                SupabaseRealtimeManager.instance.pauseAll();
                return;
              }
              if (SupabaseRealtimeManager.instance.isPaused) return;
              unawaited(_syncVisibilityFromRemote());
            }
          });
      _visibilityRealtimeUserId = userId;
      return _visibilityRealtimeChannel!;
    });
  }

  Future<void> _syncVisibilityFromRemote({String? userId}) async {
    final resolvedUserId =
        userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (resolvedUserId == null) return;
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select(
            'user_visibility_setting, system_visibility_status, is_profile_complete',
          )
          .eq('id', resolvedUserId)
          .maybeSingle();
      if (response == null || response['user_visibility_setting'] == null) {
        // No visibility setting in DB. A user whose profile is not complete
        // yet (e.g. still in the onboarding wizard) has never made a
        // visibility choice and is not part of the matching pool — never
        // default them to visible, otherwise the background service shows
        // the "MatchMe Active" notification when the app is backgrounded.
        final profileComplete = await _resolveProfileComplete(
          serverValue: response?['is_profile_complete'],
          userId: resolvedUserId,
        );
        await _applyRemoteVisibilitySnapshot(
          manualVisible: profileComplete,
          systemVisibilityStatus: 'visible',
        );
        return;
      }
      final remoteManual = response['user_visibility_setting'] == true;
      final remoteSystem =
          (response['system_visibility_status'] as String?) ?? 'visible';
      await _applyRemoteVisibilitySnapshot(
        manualVisible: remoteManual,
        systemVisibilityStatus: remoteSystem,
      );
    } catch (_) {}
  }

  /// Resolves whether the user's profile is complete, preferring the server
  /// `is_profile_complete` value and falling back to the local cached profile.
  Future<bool> _resolveProfileComplete({
    required dynamic serverValue,
    required String userId,
  }) async {
    if (serverValue != null) {
      if (serverValue is bool) return serverValue;
      return serverValue.toString().toLowerCase() == 'true';
    }
    return _isProfileComplete(userId);
  }

  /// Reads the locally cached profile (the source of truth for this device's
  /// onboarding state). The wizard persists the profile locally as incomplete
  /// while it is open and only flips it once the user submits, so this is the
  /// reliable signal for "user is still completing their profile".
  ///
  /// The live `profileEditProvider` state is preferred: while the wizard is
  /// open it holds the draft-merged profile (incomplete) and is never
  /// re-seeded by background profile syncs, which may otherwise overwrite the
  /// local cache with a stale server-side "complete" value mid-onboarding.
  Future<bool> _isProfileComplete(String userId) async {
    try {
      final editState = ref.read(profileEditProvider(userId));
      if (editState.hasValue && editState.value != null) {
        return editState.value!.isProfileComplete;
      }
    } catch (_) {}
    try {
      final localProfile = await ref
          .read(localDbProvider)
          .getLocalProfile(userId);
      final raw =
          localProfile?['isProfileComplete'] ??
          localProfile?['is_profile_complete'];
      if (raw == null) return false;
      if (raw is bool) return raw;
      return raw.toString().toLowerCase() == 'true';
    } catch (_) {
      return false;
    }
  }

  Future<void> _applyRemoteVisibilitySnapshot({
    required bool manualVisible,
    String? systemVisibilityStatus,
    bool fromRealtime = false,
  }) async {
    // The local preference is the user's explicit choice on THIS device.
    // If it disagrees with the remote value AND the update did not come
    // from a Realtime change (i.e. another device), the local pref wins —
    // the polled/remote value is likely stale (the DB write from the
    // original toggle failed offline and was queued to the outbox).
    // Push the local value back to the DB to heal the stale record
    // instead of flipping the user's visibility against their will on
    // every resume.  Realtime updates from another device DO override.
    if (!fromRealtime &&
        _manualVisibility != null &&
        _manualVisibility != manualVisible) {
      if (kDebugMode) {
        print(
          '🔵 [IsVisible] Remote visibility ($manualVisible) overridden by '
          'local pref ($_manualVisibility) — pushing local to DB',
        );
      }
      unawaited(_syncManualVisibilityChange(_manualVisibility!));
      manualVisible = _manualVisibility!;
    }
    _manualVisibility = manualVisible;
    _systemVisibilityStatus =
        (systemVisibilityStatus == null || systemVisibilityStatus.isEmpty)
        ? 'visible'
        : systemVisibilityStatus;
    await _saveManualVisibility(manualVisible);
    await _updateEffectiveVisibility();
  }

  void _attachWebVisibilityListener() {
    if (!kIsWeb) return;
    // Prevent duplicate listeners on rebuilds
    if (_webVisibilityListener != null) return;
    // Track install time so the listener can ignore the spurious 'visible' event
    // the browser fires during initial page load. That first event re-runs the
    // cold-start sync (visibility re-sync + ensureServiceStarted) on top of the
    // bootstrap that just finished. Suppress for 30s; real tab-switches are fine.
    final listenerInstalledAt = DateTime.now();
    DateTime? lastHiddenAt;
    try {
      _webVisibilityListener = (_) {
        try {
          if (html.document.hidden == true ||
              html.document.visibilityState == 'hidden') {
            lastHiddenAt = DateTime.now();
            return;
          }
          if (html.document.visibilityState == 'visible' &&
              html.document.hidden != true) {
            if (DateTime.now().difference(listenerInstalledAt) <
                const Duration(seconds: 30)) {
              return;
            }
            // Skip rapid hidden->visible bounces (Alt-Tab, minimize/maximize):
            // nothing meaningful could have changed server-side in a couple
            // of seconds, and re-running the sync chain here rebuilds the
            // home stat cards (nearby/online appear/disappear) — visible
            // "twitching" on every focus switch.
            if (lastHiddenAt != null &&
                DateTime.now().difference(lastHiddenAt!) <
                    const Duration(seconds: 10)) {
              lastHiddenAt = null;
              return;
            }
            lastHiddenAt = null;
            debugPrint('🟢 [IsVisible] Web tab became visible - re-syncing');
            // Tab became visible - re-establish subscription and sync
            _ensureVisibilityRealtimeSubscription();
            unawaited(_syncVisibilityFromRemote());

            // Reset start flag so ensureServiceStarted() will actually try to start GPS
            // This handles the case where the app started minimized/getCurrentPosition failed
            _initialStartAttempted = false;

            // Also ensure the location service is started if it should be
            unawaited(ensureServiceStarted());

            // Re-sync location share state (broadcasts may have been missed
            // while the tab was hidden / WebSocket was disconnected).
            unawaited(_syncLocationShareOnVisible());
          }
        } catch (_) {}
      };
      html.document.addEventListener(
        'visibilitychange',
        _webVisibilityListener,
      );
    } catch (_) {}
  }

  void _detachWebVisibilityListener() {
    if (!kIsWeb || _webVisibilityListener == null) return;
    try {
      html.document.removeEventListener(
        'visibilitychange',
        _webVisibilityListener,
      );
      _webVisibilityListener = null;
    } catch (_) {}
  }

  // Call this method when user reaches HomeScreen or explicitly enables visibility
  Future<void> ensureServiceStarted() async {
    // Wait for initialization to complete so state is accurate
    await _initializationFuture;
    // Never start GPS without an authenticated user
    if (Supabase.instance.client.auth.currentUser == null) {
      if (kDebugMode) {
        debugPrint(
          '[${DateTime.now().toIso8601String()}] ❌ [IsVisible] ensureServiceStarted: no authenticated user, refusing to start GPS',
        );
      }
      return;
    }
    // When the user is not visible or we've already attempted, exit
    // quietly: the existing log spammed three+ times per cold start
    // (HomeScreen mount, web tab visible, post-frame callback) with no
    // actionable signal. Only log when something interesting happens.
    if (!state) {
      return;
    }
    if (_initialStartAttempted) {
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted called: state=$state attempted=$_initialStartAttempted',
      );
    }
    if (state && !_initialStartAttempted) {
      // Only start if visible and not attempted yet
      _initialStartAttempted = true; // Mark as attempted
      // Set callback for location updates
      _locationService?.setLocationUpdateCallback((p) {
        _handleLocationChange(p);
        if (p is Position) {
          ref.read(currentLocationProvider.notifier).updateFromService(p);
        }
      });

      // Don't start GPS when offline — unless the user opted into finding
      // people met without internet (offline places are recorded locally).
      final isOnline = ref.read(connectivityProvider).value != false;
      if (kDebugMode) {
        debugPrint(
          '[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted: connectivity isOnline=$isOnline',
        );
      }
      if (!isOnline) {
        final keepForRetro = await OfflineTrailService.instance
            .isEnabledForCurrentUser();
        if (!keepForRetro) {
          if (kDebugMode) {
            debugPrint(
              '🟠 ensureServiceStarted: Device is offline - skipping starting location stream',
            );
          }
          return;
        }
      }

      // REMOVED: fire-and-forget refreshLocation() here — it created a
      // second independent getCurrentPosition() call that ran parallel to
      // the one inside startLocationStream() → _sendLocationUpdate().
      // The stream's first position fires _locationUpdateCallback which
      // updates currentLocationProvider, so this is redundant.

      // Check visibility again after assessment - user may have become invisible
      if (!state) {
        return;
      }

      // Start with user's configured GPS rate
      final gpsInterval = await _getGpsInterval();
      print(
        '[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted: starting location stream interval=${gpsInterval}s',
      );
      await _locationService?.startLocationStream(gpsInterval);
      // Record what is ACTUALLY running, not what was requested: a parked
      // (pinned) or failed start runs no GPS timer, and recording the
      // interval anyway would make later updates skip the restart forever.
      _currentAppliedInterval =
          (_locationService?.isGpsTimerRunning ?? true) ? gpsInterval : null;
    }
  }

  // Call this method to update the location stream interval when settings change
  // Throttling rules:
  // - When throttling OFF: Always use user's configured rate, regardless of movement
  // - When throttling ON: Use configured rate, switch to 60s only when 5 positions are within 10m
  Future<void> updateLocationStreamInterval({
    int? newGpsRate,
    bool force = false,
  }) async {
    // Debounce: skip if called within 3 seconds of the last call. Prevents the
    // 5+ rapid repeated evaluations during startup (each seeing positions: 1/5)
    // and the stop+start cycle when the first position arrives after a restart.
    // `force=true` bypasses debounce - used for critical transitions like app->background
    // where we must guarantee the native service receives the user's exact Settings rate.
    final now = DateTime.now();
    if (!force &&
        _lastIntervalUpdateCall != null &&
        now.difference(_lastIntervalUpdateCall!) < const Duration(seconds: 3)) {
      print(
        '🟡 updateLocationStreamInterval debounced (${now.difference(_lastIntervalUpdateCall!).inMilliseconds}ms since last call)',
      );
      return;
    }
    if (!force) {
      _lastIntervalUpdateCall = now;
    } else {
      _lastIntervalUpdateCall = now;
    }

    print(
      '🟡 updateLocationStreamInterval called - state: $state, _initialStartAttempted: $_initialStartAttempted',
    );
    if (state && _initialStartAttempted) {
      // Pinned home-base parks GPS entirely (slow silent heartbeat
      // instead). Short-circuit before the interval bookkeeping below:
      // parking must not record a GPS interval, otherwise the skip-restart
      // check would mistake the parked state for a running GPS timer and
      // never restart it on unpin.
      try {
        if (PinnedLocationGate.isActiveCached ||
            await PinnedLocationGate.isActive()) {
          _currentAppliedInterval = null;
          int parkedInterval;
          try {
            parkedInterval = newGpsRate ?? await _getGpsInterval();
          } catch (_) {
            // Irrelevant while parked (no GPS timer runs); just needs to
            // be a valid positive int for the call contract.
            parkedInterval = 5;
          }
          await _locationService?.startLocationStream(parkedInterval);
          return;
        }
      } catch (_) {}

      // Only update _batteryLowThreshold service is running
      // If offline, keep GPS only for opted-in offline places; else stop.
      final isOnline = ref.read(connectivityProvider).value != false;
      if (!isOnline) {
        final keepForRetro = await OfflineTrailService.instance
            .isEnabledForCurrentUser();
        if (!keepForRetro) {
          print(
            '🟠 updateLocationStreamInterval: Offline - stopping location stream',
          );
          _locationService?.stopLocationStream();
          _currentAppliedInterval = null;
          return;
        }
        print(
          '🟠 updateLocationStreamInterval: Offline - keeping stream for offline places (opted in)',
        );
      }

      final throttlingEnabled = await _isSmartThrottlingEnabled();
      _locationService?.setSmartThrottlingEnabled(
        throttlingEnabled,
      ); // Update flag

      // Check battery-based throttling first (only enforced when Smart GPS is enabled)
      final batteryInfo = await ref
          .read(batteryServiceProvider)
          .getBatteryInfo();
      final batteryLowNotCharging =
          (batteryInfo.level <= _batteryLowThreshold) &&
          (batteryInfo.state != BatteryState.charging &&
              batteryInfo.state != BatteryState.full);
      int interval;

      if (throttlingEnabled && batteryLowNotCharging) {
        // Force 60s interval when battery low and not charging (only when Smart GPS enabled)
        interval = _batteryThrottleInterval;
        if (!_isBatteryThrottled) {
          _isBatteryThrottled = true;
          // Show persistent notification only when user is visible
          if (state) {
            try {
              final l10n = ref.read(localizationProvider);
              final msg = l10n
                  .getString('gpsThrottledLowBattery')
                  .replaceAll('{interval}', _batteryThrottleInterval.toString())
                  .replaceAll('{threshold}', _batteryLowThreshold.toString());
              ref
                  .read(systemNotificationProvider.notifier)
                  .notify(
                    SystemNotification(
                      text: msg,
                      isPersistent: true,
                      notificationType: 'battery_throttle',
                    ),
                  );
            } catch (_) {}
          }
        }
        print(
          '🔋 Battery low - enforcing ${interval}s GPS interval (smart GPS enabled)',
        );
      } else {
        // Battery OK or Smart GPS disabled - clear battery throttled flag and notification
        if (_isBatteryThrottled) {
          _isBatteryThrottled = false;
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('battery_throttle');
          // Show temporary deactivation notification
          if (state) {
            try {
              final l10n = ref.read(localizationProvider);
              final msg = l10n.getString('gpsThrottleDeactivatedBattery');
              ref
                  .read(systemNotificationProvider.notifier)
                  .notify(
                    SystemNotification(
                      text: msg,
                      isPersistent: false,
                      notificationType: 'throttle_deactivated',
                    ),
                  );
            } catch (_) {}
          }
        }

        if (!throttlingEnabled) {
          // Throttling OFF: Always use user's configured rate
          interval = newGpsRate ?? await _getGpsInterval();
          print('📍 Throttling OFF - Using configured interval: ${interval}s');
        } else {
          // Throttling ON: Check if user is stationary (5 positions within adaptive threshold)
          final isStationary =
              _recentPositions.length >= _maxRecentPositions &&
              _arePositionsSimilar(_recentPositions);
          final wasStationary =
              _currentAppliedInterval == _stationaryThrottleInterval;
          interval = isStationary
              ? _stationaryThrottleInterval
              : (newGpsRate ?? await _getGpsInterval());
          print(
            '📍 Throttling ON - Stationary: $isStationary (positions: ${_recentPositions.length}/$_maxRecentPositions), Using interval: ${interval}s',
          );

          // Show/hide stationary notification based on state (only when visible)
          if (isStationary && state) {
            try {
              final l10n = ref.read(localizationProvider);
              final msg = l10n
                  .getString('gpsThrottledStationary')
                  .replaceAll(
                    '{interval}',
                    _stationaryThrottleInterval.toString(),
                  );
              ref
                  .read(systemNotificationProvider.notifier)
                  .notify(
                    SystemNotification(
                      text: msg,
                      isPersistent: true,
                      notificationType: 'stationary_throttle',
                    ),
                  );
            } catch (_) {}
          } else {
            ref
                .read(systemNotificationProvider.notifier)
                .clearType('stationary_throttle');
            // Show deactivation notification if was previously stationary and now moving
            if (wasStationary && !isStationary && state) {
              try {
                final l10n = ref.read(localizationProvider);
                final msg = l10n.getString('gpsThrottleDeactivatedMoving');
                ref
                    .read(systemNotificationProvider.notifier)
                    .notify(
                      SystemNotification(
                        text: msg,
                        isPersistent: false,
                        notificationType: 'throttle_deactivated',
                      ),
                    );
              } catch (_) {}
            }
          }

          if (_recentPositions.length >= 2) {
            final first = _recentPositions.first;
            final last = _recentPositions.last;
            final spread = Geolocator.distanceBetween(
              first.latitude,
              first.longitude,
              last.latitude,
              last.longitude,
            );
            double sumAccuracy = 0;
            for (final p in _recentPositions) {
              sumAccuracy += p.accuracy;
            }
            final avgAccuracy = sumAccuracy / _recentPositions.length;
            final adaptiveThreshold = avgAccuracy > _similarityThresholdMeters
                ? avgAccuracy
                : _similarityThresholdMeters;
            print(
              '📍   Position spread: ${spread.toStringAsFixed(1)}m, Avg accuracy: ${avgAccuracy.toStringAsFixed(0)}m, Threshold: ${adaptiveThreshold.toStringAsFixed(0)}m',
            );
          }
        }
      }

      // Skip restart if the calculated interval matches what's already running
      // or is within 5 seconds of it (avoids thrashing for minor fluctuations).
      // The GPS timer must ALSO actually exist: a parked/failed start records
      // no interval, so without this check unpin would "skip" forever.
      final currentInterval = _currentAppliedInterval;
      final gpsTimerRunning = _locationService?.isGpsTimerRunning ?? true;
      // When force=true (e.g. app->background transition) we must always push config to native
      // even if we skip the Dart timer restart, otherwise native could stay at stale/60s rate.
      if ((currentInterval == interval ||
              (currentInterval != null &&
                  (currentInterval - interval).abs() < 5)) &&
          gpsTimerRunning) {
        print(
          '📍 Interval unchanged or close enough (${interval}s, was $_currentAppliedInterval), skipping restart',
        );
        _currentAppliedInterval = interval;
        // Still update background service config just in case - use force to bypass dedup
        await BackgroundService.updateConfig(
          gpsInterval: newGpsRate ?? await _getGpsInterval(),
          smartThrottlingEnabled: throttlingEnabled,
          force: force,
        );
        return;
      }

      print(
        '📍 Restarting location service with interval: ${interval}s (was: $_currentAppliedInterval)',
      );
      // keepLiveStream: the map's live stream is owned by the map screen and
      // must survive timer churn — only the timer restarts here.
      _locationService?.stopLocationStream(keepLiveStream: true);
      _currentAppliedInterval = interval; // Track what we're applying
      await _locationService?.startLocationStream(interval);
      // A pin (or failure) racing the start parks/fails it: record the
      // truth so the next evaluation restarts instead of skipping.
      if (!(_locationService?.isGpsTimerRunning ?? true)) {
        _currentAppliedInterval = null;
      }

      // Update background service config - force when this is a background transition
      await BackgroundService.updateConfig(
        gpsInterval: newGpsRate ?? await _getGpsInterval(),
        smartThrottlingEnabled: throttlingEnabled,
        force: force,
      );
    }
  }

  /// Called when the user finishes the onboarding wizard. While the profile
  /// was incomplete the user was held invisible (no "MatchMe Active"
  /// notification, no GPS); now that they are part of the matching pool,
  /// default them to visible unless they have an explicit setting.
  Future<void> onProfileCompleted() async {
    if (_manualVisibility == true) {
      await _updateEffectiveVisibility();
      return;
    }
    _manualVisibility = true;
    await _saveManualVisibility(true);
    try {
      await _syncManualVisibilityChange(true);
    } catch (_) {}
    await _updateEffectiveVisibility();
    _locationService?.setVisibility(state);
  }

  Future<void> setVisibility(bool isVisible) async {
    final wasVisible = state;
    _manualVisibility = isVisible;
    // Update state immediately for instant UI feedback
    state = isVisible;
    _locationService?.setVisibility(isVisible);
    // Run async operations in background without blocking UI
    unawaited(_saveManualVisibility(isVisible));
    unawaited(_syncManualVisibilityChange(isVisible));
    // NOTE: _updateEffectiveVisibility detects transitions via
    // `effective != state`. Since we pre-set state above, it will see no
    // change and skip GPS handling — so we must handle GPS here directly.
    // Previously only background-matching was handled here, which left the
    // timer running silently while invisible (ticks with no positions) and
    // dead while visible (no restart after an in-flight stop).
    if (!isVisible && wasVisible) {
      _locationService?.stopLocationStream();
      _currentAppliedInterval = null;
      _recentPositions.clear();
      _consecutiveMovementCount = 0;
      _lastThrottlingChange = null;
      _isBatteryThrottled = false;
      try {
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('battery_throttle');
        ref
            .read(systemNotificationProvider.notifier)
            .clearType('stationary_throttle');
      } catch (_) {}
      unawaited(_disableBackgroundMatchingForInvisibility());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_effectivePrefsKey, false);
      } catch (_) {}
      try {
        await BackgroundService.updateVisibility(false);
      } catch (_) {}
    } else if (isVisible && !wasVisible) {
      _recentPositions.clear();
      _consecutiveMovementCount = 0;
      _lastThrottlingChange = null;
      _currentAppliedInterval = null;
      _isBatteryThrottled = false;
      // Bypass updateLocationStreamInterval 3s debounce for this critical transition.
      _lastIntervalUpdateCall = null;
      unawaited(_restoreBackgroundMatchingMode());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_effectivePrefsKey, true);
      } catch (_) {}
      try {
        await BackgroundService.updateVisibility(true);
      } catch (_) {}
      if (!_initialStartAttempted) {
        unawaited(ensureServiceStarted());
      } else {
        unawaited(updateLocationStreamInterval(force: true));
      }
    } else {
      // No effective change — still keep background-matching in sync.
      if (!isVisible) {
        try {
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('battery_throttle');
          ref
              .read(systemNotificationProvider.notifier)
              .clearType('stationary_throttle');
        } catch (_) {}
        unawaited(_disableBackgroundMatchingForInvisibility());
      } else {
        unawaited(_restoreBackgroundMatchingMode());
      }
    }
    // Reconcile with rules/system/profile (may correct state if rules force invisible).
    unawaited(_updateEffectiveVisibility());
  }

  // Call this method when app becomes inactive (goes to background)
  // This tracks app state but doesn't change throttling behavior
  // Throttling is based only on stationarity for consistent cross-platform behavior
  Future<void> onAppInactive() async {
    // Debounce rapid successive calls
    if (_lastAppStateChange != null &&
        DateTime.now().difference(_lastAppStateChange!) < _appStateDebounce) {
      return;
    }
    _lastAppStateChange = DateTime.now();
  }

  // Call this method when app becomes active (comes to foreground)
  // This tracks app state but doesn't change throttling behavior
  // Throttling is based only on stationarity for consistent cross-platform behavior
  Future<void> onAppActive() async {
    // Debounce rapid successive calls
    if (_lastAppStateChange != null &&
        DateTime.now().difference(_lastAppStateChange!) < _appStateDebounce) {
      return;
    }
    _lastAppStateChange = DateTime.now();
  }

  Future<void> _clearPersistedVisibilityForLogout() async {
    _manualVisibility = true;
    _cachedManualVisibility = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('manual_visibility');
      await prefs.remove('effective_visibility');
      await prefs.remove('user_visibility');
      await prefs.setBool('manual_visibility', true);
      await prefs.setBool('effective_visibility', false);
      print(
        '🔴 [IsVisible] cleared persisted visibility for logout (next login defaults to visible); local prefs reset',
      );
    } catch (e) {
      print(
        '🔴 [IsVisible] failed to clear persisted visibility for logout: $e',
      );
    }
  }

  Future<void> onLogout() async {
    _locationService?.stopLocationStream();
    state = false; // Set state to invisible on logout
    _locationService?.setVisibility(false);
    _initialStartAttempted = false;
    _recentPositions.clear();
    _consecutiveMovementCount = 0;
    _lastThrottlingChange = null;
    _currentAppliedInterval = null;
    _isBatteryThrottled = false;
    ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
    ref
        .read(systemNotificationProvider.notifier)
        .clearType('stationary_throttle');
    await _clearPersistedVisibilityForLogout();
    print('🔴 [IsVisible] onLogout: state set to false');

    // Ensure background service and DB reflect offline state immediately
    try {
      await BackgroundService.stop();
    } catch (e) {
      print('onLogout: BackgroundService.stop failed: $e');
    }

    // Immediately mark the user offline on the server (clear presence).
    // p_clear_pinned: true drops any active home-base pin so a logged-out user
    // is not counted online via is_pinned_location_active() — critical on
    // shared devices where the next account replaces this one.
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await Supabase.instance.client.rpc(
          'set_user_offline',
          params: {'p_user_id': userId, 'p_clear_pinned': true},
        );
        print('onLogout: set_user_offline RPC called');
      }
    } catch (e) {
      print('onLogout: set_user_offline RPC failed: $e');
    }
  }

  void _setupBrowserFocusDetection() {
    if (!kIsWeb) return;

    // Listen for window focus/blur events to track app state on web
    html.window.addEventListener('focus', (event) {
      onAppActive();
    });

    html.window.addEventListener('blur', (event) {
      onAppInactive();
    });

    // Also listen for visibility change events
    html.document.addEventListener('visibilitychange', (event) {
      final isHidden = html.document.hidden;

      if (isHidden == true) {
        onAppInactive();
      } else {
        onAppActive();
      }
    });

    // Add pagehide/pageshow listeners
    html.window.addEventListener('pagehide', (event) {
      onAppInactive();
    });

    html.window.addEventListener('pageshow', (event) {
      onAppActive();
    });
  }

  Future<void> _syncAndPropagateVisibility() async {
    if (!ref.mounted) return;
    try {
      await _syncVisibilityFromRemote();
      await _updateEffectiveVisibility();
      await BackgroundService.updateVisibility(state);
    } catch (_) {}
  }

  Future<void> _syncLocationShareOnVisible() async {
    if (!ref.mounted) return;
    try {
      final notifier = ref.read(locationShareProvider.notifier);
      await notifier.syncOtherSignalFromDb();
      // Force immediate position broadcast so the peer sees our current
      // location right away after we return to foreground.
      if (ref.mounted) {
        notifier.forceBroadcastLocation();
      }
    } catch (_) {}
  }

  Future<void> _pauseForegroundLocationStream() async {
    if (kIsWeb) {
      return;
    }
    // When Background Matching is ON and the user is visible, the native
    // foreground service is expected to take over. However stopping the Dart
    // Timer unconditionally on every `paused`/`detached` created a gap where
    // no location was sent if the native service had not yet promoted to
    // foreground (permission / Doze / 5s ANR window) or was using the
    // Doze-throttled PendingIntent path. The Dart Timer is more reliable
    // for the first minutes after screen-off and the foreground service
    // keeps the Flutter process alive anyway, so keep it alive as a
    // backup when bgMatching is ON.
    try {
      final prefs = await SharedPreferences.getInstance();
      final bg = prefs.getBool(_backgroundMatchingPrefsKey) ?? false;
      if (bg && state) {
        // Refresh interval rather than stopping; native will run in parallel
        // until the OS kills the Flutter engine. Either path uploads to
        // `user_locations`, so duplication is harmless but loss is not.
        // Force=true ensures we bypass debounce/dedup and native definitely gets user's Settings rate
        // before the Flutter engine is throttled/killed in background.
        unawaited(updateLocationStreamInterval(force: true));
        return;
      }
    } catch (_) {}
    _locationService?.stopLocationStream();
    _currentAppliedInterval = null;
    _initialStartAttempted = false;
  }

  /// Periodic visibility polling to detect visibility changes from other devices
  /// when the Flutter-side Realtime WebSocket may have disconnected (e.g., app backgrounded).
  /// Polls the server every 30 seconds as a fallback.
  void _startVisibilityPollTimer() {
    _visibilityPollTimer?.cancel();
    _visibilityPollTimer = Timer.periodic(_visibilityPollInterval, (_) {
      if (!ref.mounted) return;
      unawaited(_syncVisibilityFromRemote());
    });
  }

  void _stopVisibilityPollTimer() {
    _visibilityPollTimer?.cancel();
    _visibilityPollTimer = null;
  }
}

// Internal lifecycle observer that delegates to a callback
class _VisibilityLifecycleObserver extends Object with WidgetsBindingObserver {
  final void Function(AppLifecycleState) _onChanged;
  _VisibilityLifecycleObserver(this._onChanged);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onChanged(state);
  }
}
