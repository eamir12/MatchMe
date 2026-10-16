// lib/providers/theme_provider.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/web_imports.dart' as html;

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(
  () => ThemeModeNotifier(),
);

/// True-black (AMOLED) dark mode toggle.
///
/// Device-local display preference: persisted to SharedPreferences only,
/// never synced to the backend, so it can diverge per device.
final amoledThemeProvider = NotifierProvider<AmoledThemeNotifier, bool>(
  () => AmoledThemeNotifier(),
);

class AmoledThemeNotifier extends Notifier<bool> {
  static const prefsKey = 'amoled_black_enabled';
  bool _changedByUser = false;

  @override
  bool build() {
    Future.microtask(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        // A stored value must not clobber a toggle that happened while the
        // preferences were still loading.
        if (_changedByUser) return;
        state = prefs.getBool(prefsKey) ?? false;
      } catch (_) {}
    });
    return false;
  }

  Future<void> setEnabled(bool enabled) async {
    _changedByUser = true;
    if (state != enabled) {
      state = enabled;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, enabled);
    } catch (_) {}
  }
}

class ThemeModeNotifier extends Notifier<ThemeMode>
    with WidgetsBindingObserver {
  static const _prefsKey = 'theme_mode';
  RealtimeChannel? _themeSubscription;
  String? _themeSubscriptionUserId;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _lifecycleObserverAttached = false;
  dynamic _webVisibilityListener;

  @override
  ThemeMode build() {
    final defaultMode = ThemeMode.system;
    ref.onDispose(() {
      _clearRealtimeSubscription();
      _authStateSubscription?.cancel();
      _authStateSubscription = null;
      _detachLifecycleObserver();
      _detachWebVisibilityListener();
    });

    Future.microtask(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(_prefsKey);
        if (saved != null) {
          state = _stringToMode(saved);
        } else {
          state = defaultMode;
        }
      } catch (_) {
        state = defaultMode;
      }
    });
    _authStateSubscription?.cancel();
    _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange
        .listen(
          (event) {
            switch (event.event) {
              case AuthChangeEvent.signedOut:
                _clearRealtimeSubscription();
                break;
              case AuthChangeEvent.initialSession:
              case AuthChangeEvent.signedIn:
              case AuthChangeEvent.userUpdated:
                _ensureRealtimeSubscription();
                unawaited(_syncFromRemote());
                break;
              default:
                break;
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[THEME] Auth stream error: $error');
          },
        );
    _ensureRealtimeSubscription();
    _attachLifecycleObserver();
    _attachWebVisibilityListener();
    unawaited(_syncFromRemote());

    return defaultMode;
  }

  Future<void> refreshFromRemote() async {
    await _syncFromRemote();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _modeToString(mode));

      // Sync to Supabase if user is logged in
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        try {
          await Supabase.instance.client
              .from('users')
              .update({'theme_mode': _modeToString(mode)})
              .eq('id', userId);
        } catch (e) {
          print('Failed to sync theme mode to Supabase: $e');
        }
      }
    } catch (_) {}
  }

  Future<void> setDark(bool enabled) async =>
      setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light);

  Future<void> setSystem() async => setThemeMode(ThemeMode.system);

  static String _modeToString(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      default:
        return 'system';
    }
  }

  static ThemeMode _stringToMode(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  void _clearRealtimeSubscription() {
    final userId = _themeSubscriptionUserId;
    _themeSubscription = null;
    _themeSubscriptionUserId = null;
    if (userId != null) {
      SupabaseRealtimeManager.instance.unregister('user_theme_$userId');
    }
  }

  void _ensureRealtimeSubscription() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _clearRealtimeSubscription();
      return;
    }
    if (_themeSubscription != null && _themeSubscriptionUserId == userId) {
      return;
    }
    _clearRealtimeSubscription();

    final channelName = 'user_theme_$userId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      _themeSubscription = Supabase.instance.client
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
              final remoteTheme = newRecord['theme_mode'] as String?;
              if (remoteTheme == null || remoteTheme.isEmpty) return;
              final remoteMode = _stringToMode(remoteTheme);
              if (state == remoteMode) return;
              state = remoteMode;
              unawaited(_persistThemeToPrefs(remoteMode));
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
              unawaited(_syncFromRemote());
            }
          });
      _themeSubscriptionUserId = userId;
      return _themeSubscription!;
    });
  }

  Future<void> _syncFromRemote() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('theme_mode')
          .eq('id', userId)
          .maybeSingle();
      final remoteTheme = response?['theme_mode'] as String?;
      if (remoteTheme == null || remoteTheme.isEmpty) return;
      final remoteMode = _stringToMode(remoteTheme);
      if (state != remoteMode) {
        state = remoteMode;
      }
      await _persistThemeToPrefs(remoteMode);
    } catch (_) {}
  }

  Future<void> _persistThemeToPrefs(ThemeMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _modeToString(mode));
    } catch (_) {}
  }

  void _attachLifecycleObserver() {
    if (_lifecycleObserverAttached) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverAttached = true;
    } catch (_) {}
  }

  void _detachLifecycleObserver() {
    if (!_lifecycleObserverAttached) return;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _lifecycleObserverAttached = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-establish realtime subscription when app resumes
      _ensureRealtimeSubscription();
      unawaited(_syncFromRemote());
    }
  }

  void _attachWebVisibilityListener() {
    if (!kIsWeb) return;
    try {
      _webVisibilityListener = (_) {
        try {
          if (html.document.visibilityState == 'visible' &&
              html.document.hidden != true) {
            // Tab became visible - re-establish subscription
            _ensureRealtimeSubscription();
            unawaited(_syncFromRemote());
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
}
