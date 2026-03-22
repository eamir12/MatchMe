// lib/providers/theme_provider.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(() => ThemeModeNotifier());

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _prefsKey = 'theme_mode';
  RealtimeChannel? _themeSubscription;
  String? _themeSubscriptionUserId;
  StreamSubscription<AuthState>? _authStateSubscription;

  @override
  ThemeMode build() {
    final defaultMode = ThemeMode.system;
    ref.onDispose(() {
      _clearRealtimeSubscription();
      _authStateSubscription?.cancel();
      _authStateSubscription = null;
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
    _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((_) {
      _ensureRealtimeSubscription();
      unawaited(_syncFromRemote());
    });
    _ensureRealtimeSubscription();
    unawaited(_syncFromRemote());

    return defaultMode;
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
          debugPrint('Failed to sync theme mode to Supabase: $e');
        }
      }
    } catch (_) {}
  }

  Future<void> setDark(bool enabled) async => setThemeMode(enabled ? ThemeMode.dark : ThemeMode.light);

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
    final channel = _themeSubscription;
    if (channel != null) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
    _themeSubscription = null;
    _themeSubscriptionUserId = null;
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
    _themeSubscription = Supabase.instance.client
        .channel('user_theme_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: userId),
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
            unawaited(_syncFromRemote());
          }
        });
    _themeSubscriptionUserId = userId;
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
}
