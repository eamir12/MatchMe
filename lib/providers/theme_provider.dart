// lib/providers/theme_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final themeModeProvider = NotifierProvider<ThemeModeNotifier, ThemeMode>(() => ThemeModeNotifier());

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _prefsKey = 'theme_mode';

  @override
  ThemeMode build() {
    final defaultMode = ThemeMode.system;

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

    return defaultMode;
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _modeToString(mode));
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
}
