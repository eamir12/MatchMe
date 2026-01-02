// lib/providers/user_preferences_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';

enum UnitSystemPreference { system, metric, imperial }
enum TimeFormatPreference { system, h24, h12 }

class UserPreferencesState {
  final UnitSystemPreference unitSystem;
  final TimeFormatPreference timeFormat;

  const UserPreferencesState({
    required this.unitSystem,
    required this.timeFormat,
  });

  factory UserPreferencesState.defaults() => const UserPreferencesState(
        unitSystem: UnitSystemPreference.system,
        timeFormat: TimeFormatPreference.system,
      );

  UserPreferencesState copyWith({
    UnitSystemPreference? unitSystem,
    TimeFormatPreference? timeFormat,
  }) {
    return UserPreferencesState(
      unitSystem: unitSystem ?? this.unitSystem,
      timeFormat: timeFormat ?? this.timeFormat,
    );
  }
}

class UserPreferencesNotifier extends Notifier<UserPreferencesState> {
  static const _prefsUnitSystemKey = 'unit_system_override';
  static const _prefsTimeFormatKey = 'time_format_override';

  final supabase = Supabase.instance.client;

  @override
  UserPreferencesState build() {
    // Start with defaults, then hydrate from local storage and sync
    _loadFromLocalAndSync();
    return UserPreferencesState.defaults();
  }

  Future<void> _loadFromLocalAndSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final unitStr = prefs.getString(_prefsUnitSystemKey);
      final timeStr = prefs.getString(_prefsTimeFormatKey);

      // Also try to load from Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          final userData = await supabase
              .from('users')
              .select('unit_system, time_format')
              .eq('id', userId)
              .maybeSingle();

          if (userData != null) {
            final remoteUnitStr = userData['unit_system'] as String?;
            final remoteTimeStr = userData['time_format'] as String?;

            // Use remote values if available, otherwise local
            final finalUnitStr = remoteUnitStr ?? unitStr;
            final finalTimeStr = remoteTimeStr ?? timeStr;

            state = state.copyWith(
              unitSystem: _parseUnitSystem(finalUnitStr) ?? state.unitSystem,
              timeFormat: _parseTimeFormat(finalTimeStr) ?? state.timeFormat,
            );

            // Update local storage with remote values
            if (remoteUnitStr != null) {
              await prefs.setString(_prefsUnitSystemKey, remoteUnitStr);
            }
            if (remoteTimeStr != null) {
              await prefs.setString(_prefsTimeFormatKey, remoteTimeStr);
            }

            return;
          }
        } catch (e) {
          // If Supabase fails, fall back to local
        }
      }

      // Fall back to local SharedPreferences
      state = state.copyWith(
        unitSystem: _parseUnitSystem(unitStr) ?? state.unitSystem,
        timeFormat: _parseTimeFormat(timeStr) ?? state.timeFormat,
      );
    } catch (_) {
      // ignore
    }
  }

  Future<void> setUnitSystem(UnitSystemPreference value) async {
    state = state.copyWith(unitSystem: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsUnitSystemKey, value.name);

      // Sync to Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          await supabase
              .from('users')
              .update({'unit_system': value.name})
              .eq('id', userId);
        } catch (e) {
          // If sync fails, store in outbox for later
          final localDb = ref.read(localDbProvider);
          await localDb.saveProfileUpdateToOutbox(userId, {
            'unit_system': value.name,
          });
        }
      }
    } catch (_) {}
  }

  Future<void> setTimeFormat(TimeFormatPreference value) async {
    state = state.copyWith(timeFormat: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsTimeFormatKey, value.name);

      // Sync to Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          await supabase
              .from('users')
              .update({'time_format': value.name})
              .eq('id', userId);
        } catch (e) {
          // If sync fails, store in outbox for later
          final localDb = ref.read(localDbProvider);
          await localDb.saveProfileUpdateToOutbox(userId, {
            'time_format': value.name,
          });
        }
      }
    } catch (_) {}
  }

  UnitSystemPreference? _parseUnitSystem(String? v) {
    if (v == null) return null;
    for (final e in UnitSystemPreference.values) {
      if (e.name == v) return e;
    }
    return null;
  }

  TimeFormatPreference? _parseTimeFormat(String? v) {
    if (v == null) return null;
    for (final e in TimeFormatPreference.values) {
      if (e.name == v) return e;
    }
    return null;
  }
}

final userPreferencesProvider =
    NotifierProvider<UserPreferencesNotifier, UserPreferencesState>(
  () => UserPreferencesNotifier(),
);

/// Provider that exposes only the unit system preference to avoid unnecessary rebuilds
final userUnitSystemProvider = Provider<UnitSystemPreference>(
  (ref) => ref.watch(userPreferencesProvider.select((state) => state.unitSystem)),
);



