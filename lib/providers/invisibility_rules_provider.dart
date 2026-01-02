import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/invisibility_rules.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/visibility_provider.dart';

class InvisibilityRulesNotifier extends Notifier<InvisibilityRules> {
  final supabase = Supabase.instance.client;

  @override
  InvisibilityRules build() {
    _loadRules();
    return InvisibilityRules(isLoaded: false);
  }

  Future<void> _loadRules() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Try to load from Supabase first
        final response = await supabase
            .from('user_invisibility_rules')
            .select('rules_data')
            .eq('user_id', user.id)
            .maybeSingle();

        if (response != null && response['rules_data'] != null) {
          final rulesJson = response['rules_data'] as String;
          final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
          state = rules.copyWith(isLoaded: true);

          // Also save to SharedPreferences as backup
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('invisibility_rules', rulesJson);
          await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
          return;
        }
      }

      // Fallback to SharedPreferences if no Supabase data or not logged in
      final prefs = await SharedPreferences.getInstance();
      final rulesJson = prefs.getString('invisibility_rules');
      if (rulesJson != null) {
        final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
        state = rules.copyWith(isLoaded: true);
        await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
      }
    } catch (e) {
      // Fallback to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        final rulesJson = prefs.getString('invisibility_rules');
        if (rulesJson != null) {
          final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
          state = rules.copyWith(isLoaded: true);
        }
      } catch (e2) {
        await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
      }
    }

    // If no rules were loaded, mark as loaded with empty rules
    if (!state.isLoaded) {
      state = InvisibilityRules(isLoaded: true);
    }
  }

  Future<void> _saveRules(InvisibilityRules rules) async {
    final rulesJson = jsonEncode(rules.toJson());

    // Update state immediately
    state = rules;

    // Save to SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('invisibility_rules', rulesJson);
    } catch (e) {
      // Ignore
    }

    // Sync to Supabase or outbox
    await _syncRulesToSupabase(rulesJson);

    // Update effective visibility based on new rules
    await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
  }

  Future<void> _syncRulesToSupabase(String rulesJson) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final isOnline = ref.read(connectivityProvider).value ?? false;

    if (isOnline) {
      // Try to sync immediately
      try {
        await supabase.from('user_invisibility_rules').upsert(
          {
            'user_id': user.id,
            'rules_data': rulesJson,
          },
          onConflict: 'user_id',
        );
      } catch (e) {
        await ref.read(localDbProvider).saveInvisibilityRulesUpdateToOutbox(user.id, rulesJson);
      }
    } else {
      // Save to outbox for later sync
      await ref.read(localDbProvider).saveInvisibilityRulesUpdateToOutbox(user.id, rulesJson);
    }
  }

  Future<void> addLocationRule(LocationRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: [...state.locationRules, rule],
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeLocationRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules.where((r) => r.id != ruleId).toList(),
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateLocationRule(LocationRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> addDateRangeRule(DateRangeRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: [...state.dateRangeRules, rule],
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeDateRangeRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules.where((r) => r.id != ruleId).toList(),
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateDateRangeRule(DateRangeRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> addTimeRangeRule(TimeRangeRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: [...state.timeRangeRules, rule],
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeTimeRangeRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules.where((r) => r.id != ruleId).toList(),
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateTimeRangeRule(TimeRangeRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> addDayOfWeekRule(DayOfWeekRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: [...state.dayOfWeekRules, rule],
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeDayOfWeekRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules.where((r) => r.id != ruleId).toList(),
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }


  Future<void> addDateTimeRangeRule(DateTimeRangeRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: [...state.dateTimeRangeRules, rule],
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeDateTimeRangeRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules.where((r) => r.id != ruleId).toList(),
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateDateTimeRangeRule(DateTimeRangeRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> addDayTimeRangeRule(DayTimeRangeRule rule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: [...state.dayTimeRangeRules, rule],
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> removeDayTimeRangeRule(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules.where((r) => r.id != ruleId).toList(),
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateDayOfWeekRule(DayOfWeekRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> updateDayTimeRangeRule(DayTimeRangeRule updatedRule) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules.map((r) => r.id == updatedRule.id ? updatedRule : r).toList(),
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleLocationRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleDateRangeRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleTimeRangeRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleDayOfWeekRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleDateTimeRangeRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      dayTimeRangeRules: state.dayTimeRangeRules,
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> toggleDayTimeRangeRuleEnabled(String ruleId) async {
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules,
      dateRangeRules: state.dateRangeRules,
      timeRangeRules: state.timeRangeRules,
      dayOfWeekRules: state.dayOfWeekRules,
      dateTimeRangeRules: state.dateTimeRangeRules,
      dayTimeRangeRules: state.dayTimeRangeRules.map((r) => r.id == ruleId ? r.copyWith(enabled: !r.enabled) : r).toList(),
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  Future<void> syncFromSupabase() async {
    try {
      final user = supabase.auth.currentUser;
      if (user != null) {
        final response = await supabase
            .from('user_invisibility_rules')
            .select('rules_data')
            .eq('user_id', user.id)
            .maybeSingle();

        if (response != null && response['rules_data'] != null) {
          final rulesJson = response['rules_data'] as String;
          final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
          state = rules.copyWith(isLoaded: true);
 
            // Also save to SharedPreferences as backup
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('invisibility_rules', rulesJson);
            await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
            return;
        }
      }
    } catch (e) {
      // Ignore
    }
  }

  Future<void> toggleAllRulesEnabled() async {
    final allEnabled = _areAllRulesEnabled();
    final updatedRules = InvisibilityRules(
      locationRules: state.locationRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      dateRangeRules: state.dateRangeRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      timeRangeRules: state.timeRangeRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      dayOfWeekRules: state.dayOfWeekRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      dateTimeRangeRules: state.dateTimeRangeRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      dayTimeRangeRules: state.dayTimeRangeRules.map((r) => r.copyWith(enabled: !allEnabled)).toList(),
      isLoaded: state.isLoaded,
    );
    await _saveRules(updatedRules);
  }

  bool _areAllRulesEnabled() {
    return state.locationRules.every((r) => r.enabled) &&
           state.dateRangeRules.every((r) => r.enabled) &&
           state.timeRangeRules.every((r) => r.enabled) &&
           state.dayOfWeekRules.every((r) => r.enabled) &&
           state.dateTimeRangeRules.every((r) => r.enabled) &&
           state.dayTimeRangeRules.every((r) => r.enabled);
  }
}

final invisibilityRulesProvider = NotifierProvider<InvisibilityRulesNotifier, InvisibilityRules>(() {
  return InvisibilityRulesNotifier();
});

// Provider to determine current invisibility reasons
final currentInvisibilityReasonsProvider = Provider<List<String>>((ref) {
  final rules = ref.watch(invisibilityRulesProvider);
  final currentLocation = ref.watch(currentLocationProvider);
  final now = DateTime.now();
  final reasons = <String>[];

  // Check location rules - only if currently active
  if (currentLocation?.latitude != null && currentLocation?.longitude != null) {
    for (final rule in rules.locationRules) {
      if (!rule.enabled) continue;
      final distance = rules.calculateDistance(
        currentLocation!.latitude,
        currentLocation.longitude,
        rule.latitude,
        rule.longitude,
      );
      final effectiveRadius = rule.radiusMeters < 5.0 ? 5.0 : rule.radiusMeters; // Minimum 5m radius to account for minor location changes
      if (distance <= effectiveRadius) {
        reasons.add('location');
        break; // Only add once per type
      }
    }
  }

  // Check date range rules - only if currently active
  for (final rule in rules.dateRangeRules) {
    if (!rule.enabled) continue;
    final currentDate = DateTime(now.year, now.month, now.day);
    final startDate = DateTime(rule.startDate.year, rule.startDate.month, rule.startDate.day);
    final endDate = DateTime(rule.endDate.year, rule.endDate.month, rule.endDate.day);

    if (currentDate.isAfter(startDate.subtract(const Duration(days: 1))) &&
        currentDate.isBefore(endDate.add(const Duration(days: 1)))) {
      reasons.add('date');
      break; // Only add once per type
    }
  }

  // Check time range rules - only if currently active
  for (final rule in rules.timeRangeRules) {
    if (!rule.enabled) continue;
    final currentTime = TimeOfDay.fromDateTime(now);
    if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
      reasons.add('time');
      break; // Only add once per type
    }
  }

  // Check day of week rules - only if currently active
  for (final rule in rules.dayOfWeekRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      reasons.add('day');
      break; // Only add once per type
    }
  }

  // Check date time range rules - only if currently active
  for (final rule in rules.dateTimeRangeRules) {
    if (!rule.enabled) continue;
    if (now.isAfter(rule.startDateTime) && now.isBefore(rule.endDateTime)) {
      reasons.add('datetime');
      break; // Only add once per type
    }
  }

  // Check day time range rules - only if currently active
  for (final rule in rules.dayTimeRangeRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      final currentTime = TimeOfDay.fromDateTime(now);
      if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
        reasons.add('daytime');
        break; // Only add once per type
      }
    }
  }

  return reasons;
});

// Provider to track active rule IDs with their types
final activeRuleIdsProvider = Provider<Map<String, String>>((ref) {
  final rules = ref.watch(invisibilityRulesProvider);
  final currentLocation = ref.watch(currentLocationProvider);
  final now = DateTime.now();
  final activeRules = <String, String>{}; // Maps ruleId to type

  // Check location rules
  if (currentLocation?.latitude != null && currentLocation?.longitude != null) {
    for (final rule in rules.locationRules) {
      if (!rule.enabled) continue;
      final distance = rules.calculateDistance(
        currentLocation!.latitude,
        currentLocation.longitude,
        rule.latitude,
        rule.longitude,
      );
      final effectiveRadius = rule.radiusMeters < 5.0 ? 5.0 : rule.radiusMeters; // Minimum 5m radius to account for minor location changes
      if (distance <= effectiveRadius) {
        activeRules[rule.id] = 'location';
      }
    }
  }

  // Check date range rules
  for (final rule in rules.dateRangeRules) {
    if (!rule.enabled) continue;
    final currentDate = DateTime(now.year, now.month, now.day);
    final startDate = DateTime(rule.startDate.year, rule.startDate.month, rule.startDate.day);
    final endDate = DateTime(rule.endDate.year, rule.endDate.month, rule.endDate.day);

    if (currentDate.isAfter(startDate.subtract(const Duration(days: 1))) &&
        currentDate.isBefore(endDate.add(const Duration(days: 1)))) {
      activeRules[rule.id] = 'dateRange';
    }
  }

  // Check time range rules
  for (final rule in rules.timeRangeRules) {
    if (!rule.enabled) continue;
    final currentTime = TimeOfDay.fromDateTime(now);
    if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
      activeRules[rule.id] = 'timeRange';
    }
  }

  // Check day of week rules
  for (final rule in rules.dayOfWeekRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      activeRules[rule.id] = 'dayOfWeek';
    }
  }

  // Check date time range rules
  for (final rule in rules.dateTimeRangeRules) {
    if (!rule.enabled) continue;
    if (now.isAfter(rule.startDateTime) && now.isBefore(rule.endDateTime)) {
      activeRules[rule.id] = 'dateTimeRange';
    }
  }

  // Check day time range rules
  for (final rule in rules.dayTimeRangeRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      final currentTime = TimeOfDay.fromDateTime(now);
      if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
        activeRules[rule.id] = 'dayTimeRange';
      }
    }
  }

  return activeRules;
});

// Provider to format the invisibility reason text
final currentInvisibilityReasonProvider = Provider<String?>((ref) {
  final reasons = ref.watch(currentInvisibilityReasonsProvider);
  final l10n = ref.watch(localizationProvider);

  if (reasons.isEmpty) return null;

  final reasonTexts = reasons.map((reason) {
    switch (reason) {
      case 'location': return l10n.getString('settingsLocationRules');
      case 'date': return l10n.getString('settingsDateRangeRules');
      case 'time': return l10n.getString('settingsTimeRangeRules');
      case 'day': return l10n.getString('settingsDayOfWeekRules');
      case 'datetime': return l10n.getString('settingsDateTimeRange');
      case 'daytime': return l10n.getString('settingsDayTimeRange');
      default: return reason;
    }
  }).toList();

  if (reasonTexts.length == 1) {
    return '${l10n.getString('invisibleDueTo')} ${reasonTexts[0].toLowerCase()}';
  } else if (reasonTexts.length == 2) {
    return '${l10n.getString('invisibleDueTo')} ${reasonTexts[0].toLowerCase()} ${l10n.getString('and').toLowerCase()} ${reasonTexts[1].toLowerCase()}';
  } else {
    final last = reasonTexts.removeLast();
    final joined = reasonTexts.join(', ').toLowerCase();
    return '${l10n.getString('invisibleDueTo')} $joined ${l10n.getString('and').toLowerCase()} $last'.toLowerCase();
  }
});

bool _isTimeInRange(TimeOfDay current, TimeOfDay start, TimeOfDay end) {
  final currentMinutes = current.hour * 60 + current.minute;
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;

  if (startMinutes <= endMinutes) {
    return currentMinutes >= startMinutes && currentMinutes <= endMinutes;
  } else {
    // Overnight range
    return currentMinutes >= startMinutes || currentMinutes <= endMinutes;
  }
}
