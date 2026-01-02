// lib/providers/visibility_provider.dart
// Updated to make smart GPS throttling work regardless of app state (active/inactive)
// while still tracking app state for future use
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/services/location_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/invisibility_rules_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
// Import web-specific functionality stub
import '../web_imports.dart' as html;

part 'visibility_provider.g.dart';

// Provides the boolean state (true = visible) and manages the service
@riverpod
class IsVisible extends _$IsVisible {
   LocationService? _locationService;
    bool _initialStartAttempted = false; // Flag to attempt start only once initially
    static const String _manualPrefsKey = 'manual_visibility';
    bool? _manualVisibility;

    // Debouncing for app active/inactive events
    DateTime? _lastAppStateChange;
    static const Duration _debounceDuration = Duration(milliseconds: 500);

    // Smart throttling state
    final List<Position> _recentPositions = [];
    static const int _maxRecentPositions = 5;
    static const double _similarityThresholdMeters = 10.0;
    static const double _movementThresholdMeters = 10.0;
    
    // Prevent rapid throttling changes that cause restart loops
    DateTime? _lastThrottlingChange;
    static const Duration _throttlingDebounce = Duration(seconds: 3);
    int? _currentAppliedInterval; // Track what interval is actually running

   @override
   bool build() {
    _locationService ??= ref.watch(locationServiceProvider);
    _locationService!.setLocationUpdateCallback((p) { _handleLocationChange(p); });
     _locationService!.setVisibility(_manualVisibility ?? false);
     _manualVisibility = null;

     // On app start, fetch both local and remote (DB) visibility, prefer DB if mismatch
     Future.microtask(() async {
       final userId = Supabase.instance.client.auth.currentUser?.id;
       bool dbVisibilityLoaded = false;

       // First try to load from DB (source of truth)
       if (userId != null) {
         try {
           final response = await Supabase.instance.client
               .from('users')
               .select('user_visibility_setting, system_visibility_status')
               .eq('id', userId)
               .maybeSingle();
           if (response != null && response['user_visibility_setting'] != null) {
             final dbVisible = response['user_visibility_setting'] == true;
             final systemVisibility = (response['system_visibility_status'] as String?) ?? 'visible';
             debugPrint('🟢 [IsVisible] Loaded DB visibility: $dbVisible (system: $systemVisibility)');
             _manualVisibility = dbVisible;
             await _saveManualVisibility(dbVisible);
             await _updateEffectiveVisibility();
             dbVisibilityLoaded = true;
           }
         } catch (e) {
           debugPrint('🔴 [IsVisible] Error fetching user_visibility_setting from DB: $e');
         }
       }

       // Only load from local storage if DB load failed
       if (!dbVisibilityLoaded) {
         await loadManualVisibility();
         await _updateEffectiveVisibility();
       }
       // Ensure LocationService knows whether smart throttling is enabled for the current user
       final enabled = await _isSmartThrottlingEnabled();
        try {
         _locationService?.setSmartThrottlingEnabled(enabled);
       } catch (e) {
         // Ignore
       }
     });

     // Listen to location changes to update effective visibility for location-based rules
     ref.listen(currentLocationProvider, (previous, next) {
       _updateEffectiveVisibility();
       _handleLocationChange(next);
     });

     // Add browser focus/blur detection for web
     if (kIsWeb) {
       _setupBrowserFocusDetection();
     }

     return _manualVisibility ?? false;
   }

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

    // Normalize possible JS interop objects into a `Position` instance
    Position? normalized;
    try {
      if (newPosition is Position) {
        normalized = newPosition;
      } else {
        // Attempt to extract common fields from JS Position or coords object
        final dyn = newPosition;
        double? lat;
        double? lon;
        double? acc;
        double? spd;
        double? hdg;
        DateTime? ts;
        try {
          final coords = (dyn.coords != null) ? dyn.coords : dyn;
          lat = (coords.latitude ?? coords.lat) is num ? (coords.latitude ?? coords.lat).toDouble() : null;
          lon = (coords.longitude ?? coords.lng) is num ? (coords.longitude ?? coords.lng).toDouble() : null;
          acc = (coords.accuracy) is num ? (coords.accuracy).toDouble() : null;
          spd = (coords.speed) is num ? (coords.speed).toDouble() : null;
          hdg = (coords.heading) is num ? (coords.heading).toDouble() : null;
          final rawTs = dyn.timestamp ?? coords.timestamp;
          if (rawTs is num) {
            ts = DateTime.fromMillisecondsSinceEpoch(rawTs.toInt());
          } else if (rawTs is String) {
            ts = DateTime.tryParse(rawTs);
          }
        } catch (_) {}

        if (lat != null && lon != null) {
          normalized = Position(
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
        }
      }
    } catch (e) {
      // If normalization fails, ignore this update
      return;
    }

    if (normalized == null) return;
    final Position newPos = normalized;

    // Debounce: Skip if we just changed throttling state within last 3 seconds
    if (_lastThrottlingChange != null &&
        DateTime.now().difference(_lastThrottlingChange!) < _throttlingDebounce) {
      // Still track position for history, but don't trigger throttling logic
      _recentPositions.add(newPosition);
      if (_recentPositions.length > _maxRecentPositions) {
        _recentPositions.removeAt(0);
      }
      return;
    }

    final throttlingEnabled = await _isSmartThrottlingEnabled();
    
    // If throttling is OFF, we never need to check movement or adjust intervals
    if (!throttlingEnabled) {
      // Just add to history for tracking purposes, but don't act on it
      _recentPositions.add(newPosition);
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
    if (_manualVisibility == null) {
      debugPrint('🟡 [IsVisible] _updateEffectiveVisibility: manualVisibility not loaded yet');
      return;
    }
    final rules = ref.read(invisibilityRulesProvider);
    if (!rules.isLoaded) return;
    final currentLocation = ref.read(currentLocationProvider);
    final shouldBeInvisible = rules.shouldBeInvisible(
      currentLatitude: currentLocation?.latitude,
      currentLongitude: currentLocation?.longitude,
      currentDateTime: DateTime.now(),
    );
    final effective = _manualVisibility! && !shouldBeInvisible;
    if (effective != state) {
      final wasVisible = state;
      state = effective;
      debugPrint('🔴 Visibility changed: $wasVisible → $effective');
      _locationService?.setVisibility(effective);

      // Update background service visibility
      try {
        await BackgroundService.updateVisibility(effective);
      } catch (e) {
        debugPrint('Failed to update background service visibility: $e');
      }

      await _syncVisibilityChange(effective);
      if (effective && !wasVisible) {
        // User became visible - always restart GPS tracking
        debugPrint('🔴 Starting GPS tracking (user became visible)');
        if (!_initialStartAttempted) {
          _initialStartAttempted = true;
        }
        final gpsInterval = await _getGpsInterval();
        debugPrint('🔴 GPS interval: ${gpsInterval}s');
        await _locationService?.startLocationStream(gpsInterval);
      } else if (!effective && wasVisible) {
        // User became invisible - stop GPS tracking
        debugPrint('🔴 Stopping GPS tracking (user became invisible)');
        _locationService?.stopLocationStream();
      }
    }
  }

  Future<void> updateEffectiveVisibility() => _updateEffectiveVisibility();

  Future<void> _syncVisibilityChange(bool isVisible) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final isOnline = ref.read(connectivityProvider).value ?? false;

    if (isOnline) {
      // Try to sync immediately
      try {
        await Supabase.instance.client.from('users').update({'user_visibility_setting': isVisible}).eq('id', userId);
      } catch (e) {
        await ref.read(localDbProvider).saveVisibilityUpdateToOutbox(userId, isVisible);
      }
    } else {
      // Save to outbox for later sync
      await ref.read(localDbProvider).saveVisibilityUpdateToOutbox(userId, isVisible);
    }
  }

  // Call this method when user reaches HomeScreen or explicitly enables visibility
  Future<void> ensureServiceStarted() async {
      if (state && !_initialStartAttempted) { // Only start if visible and not attempted yet
          _initialStartAttempted = true; // Mark as attempted
          // Set callback for location updates
          _locationService?.setLocationUpdateCallback((p) { _handleLocationChange(p); });
          
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
          await _locationService?.startLocationStream(gpsInterval);
      }
  }

  // Call this method to update the location stream interval when settings change
  // Throttling rules:
  // - When throttling OFF: Always use user's configured rate, regardless of movement
  // - When throttling ON: Use configured rate, switch to 60s only when 5 positions are within 10m
  Future<void> updateLocationStreamInterval({int? newGpsRate}) async {
    debugPrint('🟡 updateLocationStreamInterval called - state: $state, _initialStartAttempted: $_initialStartAttempted');
    if (state && _initialStartAttempted) { // Only update if service is running
      final throttlingEnabled = await _isSmartThrottlingEnabled();
      _locationService?.setSmartThrottlingEnabled(throttlingEnabled); // Update flag
      
      int interval;
      if (!throttlingEnabled) {
        // Throttling OFF: Always use user's configured rate
        interval = newGpsRate ?? await _getGpsInterval();
        debugPrint('📍 Throttling OFF - Using configured interval: ${interval}s');
      } else {
        // Throttling ON: Check if user is stationary (5 positions within adaptive threshold)
        final isStationary = _recentPositions.length >= _maxRecentPositions && 
                            _arePositionsSimilar(_recentPositions);
        interval = isStationary ? 60 : (newGpsRate ?? await _getGpsInterval());
        debugPrint('📍 Throttling ON - Stationary: $isStationary (positions: ${_recentPositions.length}/$_maxRecentPositions), Using interval: ${interval}s');
        if (_recentPositions.length >= 2) {
          final first = _recentPositions.first;
          final last = _recentPositions.last;
          final spread = Geolocator.distanceBetween(first.latitude, first.longitude, last.latitude, last.longitude);
          final avgAccuracy = _recentPositions.map((p) => p.accuracy).reduce((a, b) => a + b) / _recentPositions.length;
          final adaptiveThreshold = avgAccuracy > _similarityThresholdMeters ? avgAccuracy : _similarityThresholdMeters;
          debugPrint('📍   Position spread: ${spread.toStringAsFixed(1)}m, Avg accuracy: ${avgAccuracy.toStringAsFixed(0)}m, Threshold: ${adaptiveThreshold.toStringAsFixed(0)}m');
        }
      }

      // Skip restart if the calculated interval matches what's already running
      if (_currentAppliedInterval == interval) {
        debugPrint('📍 Interval unchanged (${interval}s), skipping restart');
        return;
      }

      debugPrint('📍 Restarting location service with interval: ${interval}s (was: $_currentAppliedInterval)');
      _locationService?.stopLocationStream();
      _currentAppliedInterval = interval; // Track what we're applying
      await _locationService?.startLocationStream(interval);
    }
  }


  Future<void> setVisibility(bool isVisible) async {
    _manualVisibility = isVisible;
    await _saveManualVisibility(isVisible);
    await _updateEffectiveVisibility();
    _locationService?.setVisibility(state);
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
    _manualVisibility = false;
    await _saveManualVisibility(false);
    state = false; // Set state to invisible on logout
    debugPrint('🔴 [IsVisible] onLogout: manualVisibility and state set to false');

    // Ensure background service and DB reflect offline state immediately
    try {
      await BackgroundService.updateVisibility(false);
    } catch (e) {
      debugPrint('onLogout: BackgroundService.updateVisibility failed: $e');
    }

    try {
      await BackgroundService.stop();
    } catch (e) {
      debugPrint('onLogout: BackgroundService.stop failed: $e');
    }

    // Also do a best-effort direct DB update in case other parts failed
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await Supabase.instance.client.from('users').update({'user_visibility_setting': false}).eq('id', userId);
        debugPrint('onLogout: set user_visibility_setting=false for user $userId');
      }
    } catch (e) {
      debugPrint('onLogout: direct DB update failed: $e');
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