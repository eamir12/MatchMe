import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/offline_utils.dart';

const String _appConfigCacheKey = 'cached_app_config';

// Global cache variable for synchronous access
Map<String, String> _cachedAppConfig = {};

/// Initialize app config cache from persistent storage (call at app startup)
/// This function is exported to be called from main.dart during app initialization
Future<void> initializeAppConfigCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_appConfigCacheKey);
    if (configJson != null) {
      final Map<String, dynamic> cacheData = jsonDecode(configJson);
      _cachedAppConfig = cacheData.map(
        (key, value) => MapEntry(key, value.toString()),
      );
      if (kDebugMode) {
        debugPrint(
          '[AppConfig] Initialized cache with ${_cachedAppConfig.length} config values',
        );
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[AppConfig] Error initializing config cache: $e');
    }
  }
}

/// Save app config to persistent storage
Future<void> _saveAppConfigCache(Map<String, String> config) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appConfigCacheKey, jsonEncode(config));
    _cachedAppConfig = config;
    if (kDebugMode) {
      debugPrint('[AppConfig] Saved ${config.length} config values to cache');
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[AppConfig] Error saving config cache: $e');
    }
  }
}

/// Convert a list of app_config rows into a string map
Map<String, String> _configRowsToMap(List<Map<String, dynamic>> rows) {
  final config = <String, String>{};
  for (final row in rows) {
    config[row['config_key'] as String] = row['config_value'].toString();
  }
  return config;
}

/// Provider to fetch all app configuration with realtime updates
final appConfigProvider =
    NotifierProvider<AppConfigNotifier, Map<String, String>>(() {
      return AppConfigNotifier();
    });

/// Provider to check if external ads are enabled (with realtime updates)
final externalAdsEnabledProvider = Provider<bool>((ref) {
  final config = ref.watch(appConfigProvider);
  final value = config['ads.external.enabled']?.toLowerCase() ?? 'false';
  return value == 'true';
});

/// Provider to check if internal ads are enabled (with realtime updates)
final internalAdsEnabledProvider = Provider<bool>((ref) {
  final config = ref.watch(appConfigProvider);
  // Default false to match the serving RPC (app_config_bool
  // 'ads.internal.enabled', false).
  final value = config['ads.internal.enabled']?.toLowerCase() ?? 'false';
  return value == 'true';
});

/// Provider to check display order when both ad systems are enabled
/// 'external_first' (default) or 'internal_first'
final adDisplayOrderProvider = Provider<String>((ref) {
  final config = ref.watch(appConfigProvider);
  final value = config['ads.display_order']?.toLowerCase() ?? 'external_first';
  return value == 'internal_first' ? 'internal_first' : 'external_first';
});

class AppConfigNotifier extends Notifier<Map<String, String>>
    with WidgetsBindingObserver {
  final supabase = Supabase.instance.client;
  StreamSubscription<List<Map<String, dynamic>>>? _configStreamSub;
  StreamSubscription<AuthState>? _authSub;
  void Function()? _resumeDispose;

  // Debouncing to prevent multiple rapid config loads
  Timer? _loadConfigDebounceTimer;
  bool _loadConfigInProgress = false;
  DateTime? _lastLoadConfigCall;
  static const Duration _loadConfigCooldown = Duration(seconds: 30);

  @override
  Map<String, String> build() {
    _resumeDispose?.call();
    Future<void>(() async {
      await initializeAppConfigCache();
      if (ref.mounted && state.isEmpty && _cachedAppConfig.isNotEmpty) {
        state = Map<String, String>.from(_cachedAppConfig);
      }
    });
    _resumeDispose = onSupabaseResume(() {
      if (!ref.mounted) return;
      // A real offline tore down the realtime socket and the vendored client
      // does not rejoin stream channels on reconnect — the old subscription
      // would stay silently dead. Drop it so a fresh one is created below;
      // the REST refresh covers data in the meantime.
      _clearRealtimeSubscription();
      _loadConfig();
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!ref.mounted) return;
        _ensureRealtimeSubscription();
      });
    });

    Map<String, String> initialState = _cachedAppConfig;
    if (_cachedAppConfig.isNotEmpty) {
      debugPrint(
        '[AppConfig] Using cached config as initial state: ${_cachedAppConfig.length} keys',
      );
    } else {
      debugPrint(
        '[AppConfig] No cached config available, starting with empty state',
      );
    }

    if (!shouldSkipSupabaseCalls()) {
      debugPrint(
        '[AppConfig] Online - fetching fresh config from database (deferred 200ms)',
      );
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!ref.mounted) return;
        _loadConfig();
      });
    } else {
      debugPrint('[AppConfig] Offline - using cached config only');
    }

    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (!ref.mounted) return;
      _ensureRealtimeSubscription();
    });

    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);

    _authSub?.cancel();
    _authSub = supabase.auth.onAuthStateChange.listen((authState) {
      if (authState.event == AuthChangeEvent.signedOut) {
        _clearRealtimeSubscription();
      } else if (authState.event == AuthChangeEvent.initialSession ||
          authState.event == AuthChangeEvent.signedIn) {
        // The persisted session (or a fresh sign-in) often resolves AFTER the
        // first subscription attempt above, which bails when no session exists
        // yet. Attach the realtime stream now, and pull fresh config —
        // otherwise ad/config changes would not arrive in realtime until the
        // user happened to background and resume the app.
        _ensureRealtimeSubscription();
        unawaited(_loadConfig());
      }
    });

    ref.onDispose(() {
      _authSub?.cancel();
      WidgetsBinding.instance.removeObserver(this);
      _clearRealtimeSubscription();
      _loadConfigDebounceTimer?.cancel();
    });

    return initialState;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_configStreamSub != null) {
        return;
      }
      debugPrint(
        '[AppConfig] App resumed, ensuring realtime subscription is active',
      );
      _ensureRealtimeSubscription();
    }
  }

  Future<void> _loadConfig() async {
    if (_loadConfigInProgress) {
      if (kDebugMode) {
        debugPrint('[AppConfig] Skipping config load - already in progress');
      }
      return;
    }

    if (supabase.auth.currentSession == null) {
      debugPrint('[AppConfig] Skipping config load - no active session');
      return;
    }

    final now = DateTime.now();
    if (_lastLoadConfigCall != null) {
      final timeSinceLastCall = now.difference(_lastLoadConfigCall!);
      if (timeSinceLastCall < _loadConfigCooldown) {
        if (kDebugMode) {
          debugPrint(
            '[AppConfig] Skipping config load - cooldown active (${timeSinceLastCall.inSeconds}s < ${_loadConfigCooldown.inSeconds}s)',
          );
        }
        return;
      }
    }

    if (shouldSkipSupabaseCalls()) {
      return;
    }

    try {
      _loadConfigInProgress = true;
      _lastLoadConfigCall = now;

      debugPrint('[AppConfig] Loading config from database...');
      final results = await publicReferenceDataService.fetchAppConfigRows();

      final config = <String, String>{};
      for (final row in results) {
        config[row['config_key'] as String] = row['config_value'].toString();
      }

      debugPrint('[AppConfig] Loaded ${config.length} config entries');
      state = config;
      _saveAppConfigCache(config);
    } catch (e) {
      debugPrint('[AppConfig] Error loading config: $e');
      if (e.toString().contains('SocketException') ||
          e.toString().contains('Failed host lookup') ||
          e.toString().contains('network')) {
        debugPrint('[AppConfig] Network error - keeping current config state');
      } else {
        debugPrint('[AppConfig] Error - keeping current config state');
      }
    } finally {
      _loadConfigInProgress = false;
    }
  }

  void _ensureRealtimeSubscription() {
    if (supabase.auth.currentSession == null ||
        supabase.auth.currentUser == null) {
      return;
    }

    if (shouldSkipSupabaseCalls()) {
      if (kDebugMode) {
        debugPrint(
          '[AppConfig] Skipping realtime subscription setup - Supabase communication paused',
        );
      }
      return;
    }

    if (_configStreamSub != null) {
      return;
    }

    debugPrint('[AppConfig] Setting up realtime stream subscription...');

    try {
      _configStreamSub = supabase
          .from('app_config')
          .stream(primaryKey: const ['id'])
          .listen(
            (rows) {
              debugPrint(
                '[AppConfig] Realtime stream update received (${rows.length} rows)',
              );
              final config = _configRowsToMap(rows);
              state = config;
              _saveAppConfigCache(config);
            },
            onError: (error) {
              debugPrint('[AppConfig] Realtime stream error: $error');
              _configStreamSub?.cancel();
              _configStreamSub = null;
            },
            onDone: () {
              debugPrint('[AppConfig] Realtime stream closed');
              _configStreamSub = null;
            },
          );
    } catch (e) {
      debugPrint('[AppConfig] Error setting up realtime stream: $e');
    }

    SupabaseRealtimeManager.instance.register('app_config_stream', () {
      return supabase.channel('app_config_stream');
    });
  }

  void _clearRealtimeSubscription() {
    _configStreamSub?.cancel();
    _configStreamSub = null;
    SupabaseRealtimeManager.instance.unregister('app_config_stream');
  }

  /// Manually refresh config (e.g., after app comes to foreground)
  Future<void> refresh() async {
    debugPrint('[AppConfig] Manual refresh requested');
    await _loadConfig();
  }
}
