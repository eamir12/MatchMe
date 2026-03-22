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
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:matchme/services/battery_service.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/app_config_service.dart';
// Import web-specific functionality stub
import '../web_imports.dart' as html;

part 'visibility_provider.g.dart';

// Provides the boolean state (true = visible) and manages the service
@riverpod
class IsVisible extends _$IsVisible {
   LocationService? _locationService;
    bool _initialStartAttempted = false; // Flag to attempt start only once initially
    static const String _manualPrefsKey = 'manual_visibility';
    static const String _effectivePrefsKey = 'effective_visibility';
    bool? _manualVisibility;
    String? _lastRestoredUserId;
  late Future<void> _initializationFuture;
  bool? _lastConnectivityOnline;

  // Debouncing for app active/inactive events
    DateTime? _lastAppStateChange;
    static const Duration _debounceDuration = Duration(milliseconds: 500);

    // Smart throttling state
    final List<Position> _recentPositions = [];
    int _maxRecentPositions = 5; // Will be loaded from config
    double _similarityThresholdMeters = 10.0; // Will be loaded from config
    double _movementThresholdMeters = 10.0; // Will be loaded from config
    
    // Prevent rapid throttling changes that cause restart loops
    DateTime? _lastThrottlingChange;
    Duration _throttlingDebounce = const Duration(seconds: 3); // Will be loaded from config
    int? _currentAppliedInterval; // Track what interval is actually running

    // Battery-based throttling
    bool _isBatteryThrottled = false;
    StreamSubscription<BatteryInfo>? _batterySubscription; // listens to battery changes
    int _batteryThrottleInterval = 60; // Will be loaded from config
    int _batteryLowThreshold = 15; // Will be loaded from config
    int _stationaryThrottleInterval = 60; // Will be loaded from config
    RealtimeChannel? _visibilityRealtimeChannel;
    String? _visibilityRealtimeUserId;
    String _systemVisibilityStatus = 'visible';

   @override
  bool build() {
    // Keep this provider alive even if not listened to, as it manages
    // background visibility/location state which must persist.
    ref.keepAlive();
    debugPrint('[${DateTime.now().toIso8601String()}] 👁️ [IsVisible] build: manual=$_manualVisibility userId=${Supabase.instance.client.auth.currentUser?.id} kIsWeb=$kIsWeb');

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
    ref.onDispose(() {
      _clearVisibilityRealtimeSubscription();
    });
    _ensureVisibilityRealtimeSubscription();

     // Load config values asynchronously
     Future.microtask(() async {
       try {
         _maxRecentPositions = await appConfigService.getInt('gps.stationary_max_positions', defaultValue: 5);
         _similarityThresholdMeters = await appConfigService.getDouble('gps.stationary_similarity_threshold_meters', defaultValue: 10.0);
         _movementThresholdMeters = await appConfigService.getDouble('gps.stationary_movement_threshold_meters', defaultValue: 10.0);
         _throttlingDebounce = await appConfigService.getDuration('ui.throttling_debounce_seconds', defaultValue: const Duration(seconds: 3));
         _batteryThrottleInterval = await appConfigService.getInt('gps.battery_throttle_interval_seconds', defaultValue: 60);
         _batteryLowThreshold = await appConfigService.getInt('gps.battery_low_threshold_percent', defaultValue: 15);
         _stationaryThrottleInterval = await appConfigService.getInt('gps.stationary_throttle_interval_seconds', defaultValue: 60);
         debugPrint('📋 [IsVisible] Loaded config: maxPos=$_maxRecentPositions, simThresh=$_similarityThresholdMeters, batteryThresh=$_batteryLowThreshold, stationaryInterval=$_stationaryThrottleInterval');
       } catch (e) {
         debugPrint('⚠️ [IsVisible] Failed to load config, using defaults: $e');
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
          debugPrint('🔴 [IsVisible] Failed to update background service from local: $e');
        }
        debugPrint('🔵 [IsVisible] Loaded from local storage: effective=$effectiveFromLocal, manual=$_manualVisibility, display=$displayValue');
      } catch (e) {
        debugPrint('🔴 [IsVisible] Error loading from local storage: $e');
        state = _manualVisibility ?? true;
      }

      // 2. Then fetch from Supabase and sync (DB is source of truth when online)
      if (userId != null) {
        try {
          await _syncVisibilityFromRemote(userId: userId);
        } catch (e) {
          debugPrint('🔴 [IsVisible] Error fetching user_visibility_setting from DB: $e');
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
        debugPrint('⚠️ [IsVisible] Error waiting for rules: $e');
      }
       
       // Ensure LocationService knows whether smart throttling is enabled for the current user
       final enabled = await _isSmartThrottlingEnabled();
        try {
         _locationService?.setSmartThrottlingEnabled(enabled);
       } catch (e) {
         // Ignore
       }

       // Subscribe to battery changes so we can enforce battery-based throttling
       try {
         final batteryService = ref.watch(batteryServiceProvider);
         _batterySubscription ??= batteryService.stream.listen((info) async {
           // Skip battery throttling logic when user is invisible (GPS is not running)
           if (!state) return;
           
           // Skip battery throttling logic when offline (GPS is not running)
           final isOnline = ref.read(connectivityProvider).value ?? false;
           if (!isOnline) return;
           
           // Only enforce battery-based throttling when Smart GPS is enabled for the user
           final throttlingEnabled = await _isSmartThrottlingEnabled();
           final batteryLowNotCharging = (info.level <= _batteryLowThreshold) && (info.state != BatteryState.charging && info.state != BatteryState.full);

           if (throttlingEnabled) {
             if (batteryLowNotCharging && !_isBatteryThrottled) {
               _isBatteryThrottled = true;
               _currentAppliedInterval = null; // force restart
               // Show persistent notification only when user is visible
               if (state) {
                 try {
                   final l10n = ref.read(localizationProvider);
                   final msg = l10n.getString('gpsThrottledLowBattery')
                     .replaceAll('{interval}', _batteryThrottleInterval.toString())
                     .replaceAll('{threshold}', _batteryLowThreshold.toString());
                   ref.read(systemNotificationProvider.notifier).notify(
                     SystemNotification(text: msg, isPersistent: true, notificationType: 'battery_throttle')
                   );
                 } catch (_) {}
               }
               await updateLocationStreamInterval();
             } else if (!batteryLowNotCharging && _isBatteryThrottled) {
               _isBatteryThrottled = false;
               _currentAppliedInterval = null; // force restart
               // Clear battery throttle notification
               ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
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

     // Listen for connectivity changes to stop/start GPS appropriately
     ref.listen<AsyncValue<bool>>(connectivityProvider, (previous, next) async {
       try {
        final isOnline = next.value ?? false;
        if (_lastConnectivityOnline == isOnline) return;
        _lastConnectivityOnline = isOnline;
         if (!isOnline) {
           debugPrint('🟠 Connectivity lost - stopping location stream to avoid GPS while offline');
           _locationService?.stopLocationStream();
           _currentAppliedInterval = null;
           // Clear all throttle notifications when going offline
           ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
           ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
          final userId = Supabase.instance.client.auth.currentUser?.id;
          if (userId != null) {
            try {
              await Supabase.instance.client.rpc('set_user_offline', params: {'p_user_id': userId});
            } catch (e) {
              debugPrint('set_user_offline RPC failed: $e');
            }
          }
         } else {
           debugPrint('🟢 Connectivity restored - re-evaluating location stream');
          final userId = Supabase.instance.client.auth.currentUser?.id;
          if (userId != null) {
            try {
              await Supabase.instance.client.rpc('update_user_activity', params: {'p_user_id': userId});
            } catch (e) {
              debugPrint('update_user_activity RPC failed: $e');
            }
          }
           // Re-evaluate interval now that we're online again
           if (state && _initialStartAttempted) {
             // Reset battery throttled flag so updateLocationStreamInterval will re-check and show notification if needed
             _isBatteryThrottled = false;
             updateLocationStreamInterval();
           }
         }
       } catch (_) {}
     });

     ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) async {
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
         _lastThrottlingChange = null;
         _currentAppliedInterval = null;
         _isBatteryThrottled = false;
         ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
         ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
         try {
           await BackgroundService.stop();
         } catch (_) {}
         return;
       }

       if (event != AuthChangeEvent.initialSession && event != AuthChangeEvent.signedIn) {
         return;
       }

       final userId = authState.session?.user.id ?? Supabase.instance.client.auth.currentUser?.id;
       if (userId == null) return;
      _ensureVisibilityRealtimeSubscription();
       if (_lastRestoredUserId == userId && event == AuthChangeEvent.initialSession) return;
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

         state = displayValue;
         _locationService?.setVisibility(displayValue);
         _initialStartAttempted = false;
         _recentPositions.clear();
         _lastThrottlingChange = null;
         _currentAppliedInterval = null;
         _isBatteryThrottled = false;
         ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
         ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');

         try {
          await _syncVisibilityFromRemote(userId: userId);
          final rulesNotifier = ref.read(invisibilityRulesProvider.notifier);
          await rulesNotifier.syncFromSupabase();
          final syncedRules = ref.read(invisibilityRulesProvider);
          if (syncedRules.locationRules.any((rule) => rule.enabled)) {
            try {
              await ref.read(currentLocationProvider.notifier).refreshLocation();
            } catch (_) {}
          }
         } catch (_) {}
       });
     });

     // Add browser focus/blur detection for web
     if (kIsWeb) {
      _setupBrowserFocusDetection();
    }

    // Default to true (visible) when uninitialized to avoid flash of Invisible;
    // local storage is loaded first in the microtask and will update state immediately
    debugPrint('[${DateTime.now().toIso8601String()}] 👁️ [IsVisible] build returning: ${_manualVisibility ?? true}');
    return _manualVisibility ?? true;
  }

  Future<void> waitForInitialization() => _initializationFuture;

  Future<int> _getGpsInterval() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return 5; // default 5 seconds
      
      // Try to get from profileEditProvider first (has immediate updates)
      try {
        final editState = ref.read(profileEditProvider(userId));
        if (editState.hasValue && editState.value != null) {
          return editState.value!.gpsIntervalDefault;
        }
      } catch (e) {
        // Fall through to userProfileProvider
      }
      
      // Fall back to userProfileProvider
      final profileAsync = await ref.read(userProfileProvider(userId).future);
      // Return seconds directly (profile now stores seconds)
      return profileAsync?.gpsIntervalDefault ?? 5;
    } catch (e) {
      return 5; // default 5 seconds
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
          return editState.value!.smartGpsThrottlingEnabled;
        }
      } catch (e) {
        // Fall through to userProfileProvider
      }
      
      // Fall back to userProfileProvider
      final profileAsync = await ref.read(userProfileProvider(userId).future);
      return profileAsync?.smartGpsThrottlingEnabled ?? false;
    } catch (e) {
      return false;
    }
  }

  bool _arePositionsSimilar(List<Position> positions) {
    if (positions.length < _maxRecentPositions) return false;
    
    // Use accuracy-weighted similarity check
    // If GPS accuracy is poor, allow larger spread before considering it movement
    final avgAccuracy = positions.map((p) => p.accuracy).reduce((a, b) => a + b) / positions.length;
    
    // Adaptive threshold: use larger of static threshold or average accuracy
    // This prevents false movement detection when GPS is drifting due to poor accuracy
    final adaptiveThreshold = avgAccuracy > _similarityThresholdMeters 
        ? avgAccuracy 
        : _similarityThresholdMeters;
    
    final first = positions.first;
    for (final pos in positions) {
      final distance = Geolocator.distanceBetween(
        first.latitude, first.longitude,
        pos.latitude, pos.longitude,
      );
      if (distance > adaptiveThreshold) return false;
    }
    return true;
  }

  bool _hasUserMoved(Position newPosition) {
    if (_recentPositions.isEmpty) return false;
    final last = _recentPositions.last;
    final distance = Geolocator.distanceBetween(
      last.latitude, last.longitude,
      newPosition.latitude, newPosition.longitude,
    );
    return distance > _movementThresholdMeters;
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

      final lat = toDouble((() {
        try {
          return coords.latitude ?? coords.lat ?? dyn.latitude ?? dyn.lat;
        } catch (_) {
          return null;
        }
      })());

      final lon = toDouble((() {
        try {
          return coords.longitude ?? coords.lng ?? dyn.longitude ?? dyn.lng;
        } catch (_) {
          return null;
        }
      })());

      if (lat == null || lon == null) return;

      final acc = toDouble((() {
        try {
          return coords.accuracy ?? dyn.accuracy;
        } catch (_) {
          return null;
        }
      })());

      final spd = toDouble((() {
        try {
          return coords.speed ?? dyn.speed;
        } catch (_) {
          return null;
        }
      })());

      final hdg = toDouble((() {
        try {
          return coords.heading ?? dyn.heading;
        } catch (_) {
          return null;
        }
      })());

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
        DateTime.now().difference(_lastThrottlingChange!) < _throttlingDebounce) {
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
      // User moved >10m from last position - immediately resume normal rate
      _recentPositions.clear();
      _recentPositions.add(newPos);
      _lastThrottlingChange = DateTime.now(); // Record change to prevent rapid toggles
      await updateLocationStreamInterval();
      return;
    }

    // User hasn't moved significantly - add to history
    _recentPositions.add(newPos);
    if (_recentPositions.length > _maxRecentPositions) {
      _recentPositions.removeAt(0);
    }

    // Check if we now have 5 stationary positions to activate throttling
    if (_recentPositions.length >= _maxRecentPositions && _arePositionsSimilar(_recentPositions)) {
      _lastThrottlingChange = DateTime.now(); // Record change to prevent rapid toggles
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
      debugPrint('🔵 [IsVisible] _loadManualVisibility: _manualVisibility=$_manualVisibility');
    } catch (e) {
      _manualVisibility = true;
      debugPrint('🔴 [IsVisible] _loadManualVisibility error: $e');
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
      debugPrint('🟡 [IsVisible] _updateEffectiveVisibility: manualVisibility not loaded yet');
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
      final effective = _manualVisibility! && !shouldBeInvisible && systemAllowsVisibility;
      if (effective != state) {
        final wasVisible = state;
        state = effective;
        debugPrint('🔴 Visibility changed: $wasVisible → $effective');
        
        // Persist effective visibility so background service can start in correct state
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_effectivePrefsKey, effective);
        } catch (e) {
          debugPrint('Failed to persist effective visibility: $e');
        }

        _locationService?.setVisibility(effective);

        // Update background service visibility
        try {
          await BackgroundService.updateVisibility(effective);
        } catch (e) {
          debugPrint('Failed to update background service visibility: $e');
        }

        if (effective && !wasVisible) {
          // User became visible - restart GPS tracking and evaluate throttling
          debugPrint('🔴 Starting GPS tracking (user became visible)');
          if (!_initialStartAttempted) {
            _initialStartAttempted = true;
          }
          _recentPositions.clear();
          _lastThrottlingChange = null;
          _currentAppliedInterval = null;
          // Reset throttled flags to force re-evaluation
          _isBatteryThrottled = false;
          // Use updateLocationStreamInterval to properly evaluate throttling conditions
          await updateLocationStreamInterval();
        } else if (!effective && wasVisible) {
          // User became invisible - stop GPS tracking
          debugPrint('🔴 Stopping GPS tracking (user became invisible)');
          _locationService?.stopLocationStream();
          _currentAppliedInterval = null;
          _recentPositions.clear();
          _lastThrottlingChange = null;
          _isBatteryThrottled = false;
          ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
          ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
        }
      }
    } catch (e) {
      // If ref.read fails because provider is disposed, just log and exit gracefully
      debugPrint('⚠️ [IsVisible] _updateEffectiveVisibility aborted (provider likely disposed): $e');
    }
  }

  Future<void> updateEffectiveVisibility() => _updateEffectiveVisibility();

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
        params: {'p_user_id': userId}
      );
    } catch (e) {
      await ref.read(localDbProvider).saveVisibilityUpdateToOutbox(userId, isVisible);
    }
  }

  void _clearVisibilityRealtimeSubscription() {
    final channel = _visibilityRealtimeChannel;
    if (channel != null) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
    _visibilityRealtimeChannel = null;
    _visibilityRealtimeUserId = null;
  }

  void _ensureVisibilityRealtimeSubscription() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _clearVisibilityRealtimeSubscription();
      return;
    }
    if (_visibilityRealtimeChannel != null && _visibilityRealtimeUserId == userId) {
      return;
    }
    _clearVisibilityRealtimeSubscription();
    _visibilityRealtimeChannel = Supabase.instance.client
        .channel('user_visibility_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: userId),
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
            final remoteManual = (newRecord['user_visibility_setting'] ??
                    oldRecord['user_visibility_setting']) ==
                true;
            final remoteSystem =
                (newRecord['system_visibility_status'] ?? oldRecord['system_visibility_status'])
                    as String?;
            unawaited(
              _applyRemoteVisibilitySnapshot(
                manualVisible: remoteManual,
                systemVisibilityStatus: remoteSystem,
              ),
            );
          },
        )
        .subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut ||
              status == RealtimeSubscribeStatus.closed) {
            unawaited(_syncVisibilityFromRemote());
          }
        });
    _visibilityRealtimeUserId = userId;
  }

  Future<void> _syncVisibilityFromRemote({String? userId}) async {
    final resolvedUserId = userId ?? Supabase.instance.client.auth.currentUser?.id;
    if (resolvedUserId == null) return;
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('user_visibility_setting, system_visibility_status')
          .eq('id', resolvedUserId)
          .maybeSingle();
      if (response == null || response['user_visibility_setting'] == null) return;
      final remoteManual = response['user_visibility_setting'] == true;
      final remoteSystem = (response['system_visibility_status'] as String?) ?? 'visible';
      await _applyRemoteVisibilitySnapshot(
        manualVisible: remoteManual,
        systemVisibilityStatus: remoteSystem,
      );
    } catch (_) {}
  }

  Future<void> _applyRemoteVisibilitySnapshot({
    required bool manualVisible,
    String? systemVisibilityStatus,
  }) async {
    _manualVisibility = manualVisible;
    _systemVisibilityStatus =
        (systemVisibilityStatus == null || systemVisibilityStatus.isEmpty)
            ? 'visible'
            : systemVisibilityStatus;
    await _saveManualVisibility(manualVisible);
    await _updateEffectiveVisibility();
  }

  // Call this method when user reaches HomeScreen or explicitly enables visibility
  Future<void> ensureServiceStarted() async {
      debugPrint('[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted called: state=$state attempted=$_initialStartAttempted userId=${Supabase.instance.client.auth.currentUser?.id}');
      if (!state) {
        debugPrint('[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted no-op: user not visible');
        return;
      }
      if (_initialStartAttempted) {
        debugPrint('[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted no-op: already attempted');
        return;
      }
      if (state && !_initialStartAttempted) { // Only start if visible and not attempted yet
          _initialStartAttempted = true; // Mark as attempted
          // Set callback for location updates
          _locationService?.setLocationUpdateCallback((p) {
            _handleLocationChange(p);
            if (p is Position) {
              ref.read(currentLocationProvider.notifier).updateFromService(p);
            }
          });

          // Don't start GPS when offline
          final isOnline = ref.read(connectivityProvider).value ?? false;
          debugPrint('[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted: connectivity isOnline=$isOnline');
          if (!isOnline) {
            debugPrint('🟠 ensureServiceStarted: Device is offline - skipping starting location stream');
            return;
          }
          
          // IMMEDIATE ASSESSMENT: Get current location right after login
          try {
            await ref.read(currentLocationProvider.notifier).refreshLocation();
          } catch (e) {
            // Ignore
          }
          
          // Check visibility again after assessment - user may have become invisible
          if (!state) {
            return;
          }
          
          // Start with user's configured GPS rate
          final gpsInterval = await _getGpsInterval();
          debugPrint('[${DateTime.now().toIso8601String()}] 🟠 ensureServiceStarted: starting location stream interval=${gpsInterval}s');
          await _locationService?.startLocationStream(gpsInterval);
      }
  }

  // Call this method to update the location stream interval when settings change
  // Throttling rules:
  // - When throttling OFF: Always use user's configured rate, regardless of movement
  // - When throttling ON: Use configured rate, switch to 60s only when 5 positions are within 10m
  Future<void> updateLocationStreamInterval({int? newGpsRate}) async {
    debugPrint('🟡 updateLocationStreamInterval called - state: $state, _initialStartAttempted: $_initialStartAttempted');
    if (state && _initialStartAttempted) { // Only update _batteryLowThreshold service is running
      // If offline, stop GPS and return
      final isOnline = ref.read(connectivityProvider).value ?? false;
      if (!isOnline) {
        debugPrint('🟠 updateLocationStreamInterval: Offline - stopping location stream');
        _locationService?.stopLocationStream();
        _currentAppliedInterval = null;
        return;
      }

      final throttlingEnabled = await _isSmartThrottlingEnabled();
      _locationService?.setSmartThrottlingEnabled(throttlingEnabled); // Update flag
      
      // Check battery-based throttling first (only enforced when Smart GPS is enabled)
      final batteryInfo = await ref.read(batteryServiceProvider).getBatteryInfo();
      final batteryLowNotCharging = (batteryInfo.level <= _batteryLowThreshold) && (batteryInfo.state != BatteryState.charging && batteryInfo.state != BatteryState.full);
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
              final msg = l10n.getString('gpsThrottledLowBattery')
                .replaceAll('{interval}', _batteryThrottleInterval.toString())
                .replaceAll('{threshold}', _batteryLowThreshold.toString());
              ref.read(systemNotificationProvider.notifier).notify(
                SystemNotification(text: msg, isPersistent: true, notificationType: 'battery_throttle')
              );
            } catch (_) {}
          }
        }
        debugPrint('🔋 Battery low - enforcing ${interval}s GPS interval (smart GPS enabled)');
      } else {
        // Battery OK or Smart GPS disabled - clear battery throttled flag and notification
        if (_isBatteryThrottled) {
          _isBatteryThrottled = false;
          ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
          // Show temporary deactivation notification
          if (state) {
            try {
              final l10n = ref.read(localizationProvider);
              final msg = l10n.getString('gpsThrottleDeactivatedBattery');
              ref.read(systemNotificationProvider.notifier).notify(
                SystemNotification(text: msg, isPersistent: false, notificationType: 'throttle_deactivated')
              );
            } catch (_) {}
          }
        }

        if (!throttlingEnabled) {
          // Throttling OFF: Always use user's configured rate
          interval = newGpsRate ?? await _getGpsInterval();
          debugPrint('📍 Throttling OFF - Using configured interval: ${interval}s');
        } else {
          // Throttling ON: Check if user is stationary (5 positions within adaptive threshold)
          final isStationary = _recentPositions.length >= _maxRecentPositions && 
                              _arePositionsSimilar(_recentPositions);
          final wasStationary = _currentAppliedInterval == _stationaryThrottleInterval;
          interval = isStationary ? _stationaryThrottleInterval : (newGpsRate ?? await _getGpsInterval());
          debugPrint('📍 Throttling ON - Stationary: $isStationary (positions: ${_recentPositions.length}/$_maxRecentPositions), Using interval: ${interval}s');
          
          // Show/hide stationary notification based on state (only when visible)
          if (isStationary && state) {
            try {
              final l10n = ref.read(localizationProvider);
              final msg = l10n.getString('gpsThrottledStationary')
                .replaceAll('{interval}', _stationaryThrottleInterval.toString());
              ref.read(systemNotificationProvider.notifier).notify(
                SystemNotification(text: msg, isPersistent: true, notificationType: 'stationary_throttle')
              );
            } catch (_) {}
          } else {
            ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
            // Show deactivation notification if was previously stationary and now moving
            if (wasStationary && !isStationary && state) {
              try {
                final l10n = ref.read(localizationProvider);
                final msg = l10n.getString('gpsThrottleDeactivatedMoving');
                ref.read(systemNotificationProvider.notifier).notify(
                  SystemNotification(text: msg, isPersistent: false, notificationType: 'throttle_deactivated')
                );
              } catch (_) {}
            }
          }
          
          if (_recentPositions.length >= 2) {
            final first = _recentPositions.first;
            final last = _recentPositions.last;
            final spread = Geolocator.distanceBetween(first.latitude, first.longitude, last.latitude, last.longitude);
            final avgAccuracy = _recentPositions.map((p) => p.accuracy).reduce((a, b) => a + b) / _recentPositions.length;
            final adaptiveThreshold = avgAccuracy > _similarityThresholdMeters ? avgAccuracy : _similarityThresholdMeters;
            debugPrint('📍   Position spread: ${spread.toStringAsFixed(1)}m, Avg accuracy: ${avgAccuracy.toStringAsFixed(0)}m, Threshold: ${adaptiveThreshold.toStringAsFixed(0)}m');
          }
        }
      }

      // Skip restart if the calculated interval matches what's already running
      if (_currentAppliedInterval == interval) {
        debugPrint('📍 Interval unchanged (${interval}s), skipping restart');
        // Still update background service config just in case
        await BackgroundService.updateConfig(
          gpsInterval: newGpsRate ?? await _getGpsInterval(),
          smartThrottlingEnabled: throttlingEnabled,
        );
        return;
      }

      debugPrint('📍 Restarting location service with interval: ${interval}s (was: $_currentAppliedInterval)');
      _locationService?.stopLocationStream();
      _currentAppliedInterval = interval; // Track what we're applying
      await _locationService?.startLocationStream(interval);

      // Update background service config
      await BackgroundService.updateConfig(
        gpsInterval: newGpsRate ?? await _getGpsInterval(),
        smartThrottlingEnabled: throttlingEnabled,
      );
    }
  }


  Future<void> setVisibility(bool isVisible) async {
    _manualVisibility = isVisible;
    await _saveManualVisibility(isVisible);
    await _syncManualVisibilityChange(isVisible);
    await _updateEffectiveVisibility();
    _locationService?.setVisibility(state);
    
    // Clear all throttle notifications when going invisible
    if (!isVisible) {
      ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
      ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
    }
  }

  // Call this method when app becomes inactive (goes to background)
  // This tracks app state but doesn't change throttling behavior
  // Throttling is based only on stationarity for consistent cross-platform behavior
  Future<void> onAppInactive() async {
    // Debounce rapid successive calls
    if (_lastAppStateChange != null &&
        DateTime.now().difference(_lastAppStateChange!) < _debounceDuration) {
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
        DateTime.now().difference(_lastAppStateChange!) < _debounceDuration) {
      return;
    }
    _lastAppStateChange = DateTime.now();
  }

  Future<void> onLogout() async {
    _locationService?.stopLocationStream();
    state = false; // Set state to invisible on logout
    _locationService?.setVisibility(false);
    _initialStartAttempted = false;
    _recentPositions.clear();
    _lastThrottlingChange = null;
    _currentAppliedInterval = null;
    _isBatteryThrottled = false;
    ref.read(systemNotificationProvider.notifier).clearType('battery_throttle');
    ref.read(systemNotificationProvider.notifier).clearType('stationary_throttle');
    debugPrint('🔴 [IsVisible] onLogout: state set to false');

    // Ensure background service and DB reflect offline state immediately
    try {
      await BackgroundService.stop();
    } catch (e) {
      debugPrint('onLogout: BackgroundService.stop failed: $e');
    }

    // Immediately mark the user offline on the server (clear presence)
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await Supabase.instance.client.rpc('set_user_offline', params: {'p_user_id': userId});
        debugPrint('onLogout: set_user_offline RPC called for $userId');
      }
    } catch (e) {
      debugPrint('onLogout: set_user_offline RPC failed: $e');
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
}
