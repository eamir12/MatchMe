import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/models/invisibility_rules.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/current_location_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/auth_provider.dart';

class InvisibilityRulesNotifier extends Notifier<InvisibilityRules> {
  final supabase = Supabase.instance.client;
  late Future<void> _initializationFuture;
  RealtimeChannel? _rulesSubscription;
  String? _rulesSubscriptionUserId;
  Timer? _rulesResubscribeTimer;

  @override
  InvisibilityRules build() {
    _initializationFuture = _loadRules();
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (previous, next) {
      final authState = next.asData?.value;
      if (authState == null) return;
      final event = authState.event;
      if (event == AuthChangeEvent.signedOut) {
        _clearRealtimeSubscription();
        return;
      }
      if (event == AuthChangeEvent.initialSession || event == AuthChangeEvent.signedIn || event == AuthChangeEvent.tokenRefreshed) {
        _ensureRealtimeSubscription();
        unawaited(syncFromSupabase());
      }
    });
    _ensureRealtimeSubscription();
    ref.onDispose(() {
      _rulesResubscribeTimer?.cancel();
      _rulesResubscribeTimer = null;
      _clearRealtimeSubscription();
    });
    return InvisibilityRules(isLoaded: false);
  }

  InvisibilityRules? _rulesFromRecordValue(dynamic value) {
    dynamic decoded = value;
    if (decoded == null) return null;
    if (decoded is String) {
      final trimmed = decoded.trim();
      if (trimmed.isEmpty) return null;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return null;
      }
      if (decoded is String) {
        final nested = decoded.trim();
        if (nested.isEmpty) return null;
        try {
          decoded = jsonDecode(nested);
        } catch (_) {
          return null;
        }
      }
    }
    if (decoded is! Map) return null;
    final raw = Map<String, dynamic>.from(decoded);
    final normalized = <String, dynamic>{
      'locationRules': _normalizeRuleList(raw['locationRules'] ?? raw['location_rules']),
      'dateRangeRules': _normalizeRuleList(raw['dateRangeRules'] ?? raw['date_range_rules']),
      'timeRangeRules': _normalizeRuleList(raw['timeRangeRules'] ?? raw['time_range_rules']),
      'dayOfWeekRules': _normalizeRuleList(raw['dayOfWeekRules'] ?? raw['day_of_week_rules']),
      'dateTimeRangeRules': _normalizeRuleList(raw['dateTimeRangeRules'] ?? raw['date_time_range_rules']),
      'dayTimeRangeRules': _normalizeRuleList(raw['dayTimeRangeRules'] ?? raw['day_time_range_rules']),
      'isLoaded': true,
    };
    try {
      return InvisibilityRules.fromJson(normalized).copyWith(isLoaded: true);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _normalizeRuleList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final normalized = <String, dynamic>{};
      map.forEach((key, rawValue) {
        final normalizedKey = _normalizeRuleKey(key.toString());
        normalized[normalizedKey] = _normalizeRuleValue(normalizedKey, rawValue);
      });
      result.add(normalized);
    }
    return result;
  }

  String _normalizeRuleKey(String key) {
    switch (key) {
      case 'days_of_week':
        return 'daysOfWeek';
      case 'start_time':
        return 'startTime';
      case 'end_time':
        return 'endTime';
      case 'start_date':
        return 'startDate';
      case 'end_date':
        return 'endDate';
      case 'start_date_time':
        return 'startDateTime';
      case 'end_date_time':
        return 'endDateTime';
      case 'radius_meters':
        return 'radiusMeters';
      case 'is_enabled':
      case 'isEnabled':
        return 'enabled';
      default:
        return key;
    }
  }

  dynamic _normalizeRuleValue(String key, dynamic value) {
    if (key == 'daysOfWeek' && value is List) {
      return value
          .map((e) => e is num ? e.toInt() : int.tryParse(e.toString()) ?? 0)
          .where((e) => e >= 1 && e <= 7)
          .toList();
    }
    if (key == 'latitude' || key == 'longitude' || key == 'radiusMeters') {
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString()) ?? 0.0;
    }
    if (key == 'enabled') {
      if (value is bool) return value;
      final text = value.toString().toLowerCase().trim();
      return text == 'true' || text == '1';
    }
    if (key == 'id' || key == 'name' || key == 'startTime' || key == 'endTime' || key == 'startDate' || key == 'endDate' || key == 'startDateTime' || key == 'endDateTime') {
      return value.toString();
    }
    return value;
  }

  void _clearRealtimeSubscription() {
    final channel = _rulesSubscription;
    if (channel != null) {
      try {
        supabase.removeChannel(channel);
      } catch (_) {}
    }
    _rulesSubscription = null;
    _rulesSubscriptionUserId = null;
  }

  void _scheduleRealtimeResubscribe() {
    if (_rulesResubscribeTimer?.isActive ?? false) return;
    _rulesResubscribeTimer = Timer(const Duration(seconds: 1), () {
      if (!ref.mounted) return;
      _clearRealtimeSubscription();
      _ensureRealtimeSubscription();
      unawaited(syncFromSupabase());
    });
  }

  void _ensureRealtimeSubscription() {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      _clearRealtimeSubscription();
      return;
    }
    if (_rulesSubscription != null && _rulesSubscriptionUserId == userId) return;

    _clearRealtimeSubscription();
    _rulesSubscription = supabase
        .channel('user_invisibility_rules_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'user_invisibility_rules',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
          callback: (payload) {
            unawaited(() async {
              try {
                await syncFromSupabase();
              } catch (e) {
                debugPrint('Failed to apply realtime invisibility rules update: $e');
              }
            }());
          },
        )
        .subscribe((status, err) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            unawaited(syncFromSupabase());
            return;
          }
          if (status == RealtimeSubscribeStatus.channelError || status == RealtimeSubscribeStatus.timedOut || status == RealtimeSubscribeStatus.closed) {
            _scheduleRealtimeResubscribe();
            unawaited(syncFromSupabase());
          }
        });
    _rulesSubscriptionUserId = userId;
  }

  Future<void> waitForInitialization() => _initializationFuture;

  Future<void> _loadRules() async {
    try {
      _ensureRealtimeSubscription();
      final user = supabase.auth.currentUser;
      if (user != null) {
        // Try to load from Supabase first
        final response = await supabase
            .from('user_invisibility_rules')
            .select('rules_data')
            .eq('user_id', user.id)
            .maybeSingle();

        if (response != null && response['rules_data'] != null) {
          final rules = _rulesFromRecordValue(response['rules_data']);
          if (rules == null) {
            return;
          }
          final normalizedRules = _pruneExpiredRules(rules).copyWith(isLoaded: true);
          final normalizedRulesJson = jsonEncode(normalizedRules.toJson());
          state = normalizedRules;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('invisibility_rules', normalizedRulesJson);
          await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
          return;
        }
      }

      // Fallback to SharedPreferences if no Supabase data or not logged in
      final prefs = await SharedPreferences.getInstance();
      final rulesJson = prefs.getString('invisibility_rules');
      if (rulesJson != null) {
        final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
        final normalizedRules = _pruneExpiredRules(rules).copyWith(isLoaded: true);
        final normalizedRulesJson = jsonEncode(normalizedRules.toJson());
        state = normalizedRules;
        if (normalizedRulesJson != rulesJson) {
          await prefs.setString('invisibility_rules', normalizedRulesJson);
          await _syncRulesToSupabase(normalizedRulesJson);
        }
        await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
      }
    } catch (e) {
      // Fallback to SharedPreferences
      try {
        final prefs = await SharedPreferences.getInstance();
        final rulesJson = prefs.getString('invisibility_rules');
        if (rulesJson != null) {
          final rules = InvisibilityRules.fromJson(jsonDecode(rulesJson));
          final normalizedRules = _pruneExpiredRules(rules).copyWith(isLoaded: true);
          final normalizedRulesJson = jsonEncode(normalizedRules.toJson());
          state = normalizedRules;
          if (normalizedRulesJson != rulesJson) {
            await prefs.setString('invisibility_rules', normalizedRulesJson);
            await _syncRulesToSupabase(normalizedRulesJson);
          }
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
    _ensureRealtimeSubscription();
    final normalizedRules = _pruneExpiredRules(rules);
    final rulesJson = jsonEncode(normalizedRules.toJson());

    // Update state immediately
    state = normalizedRules;

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

  InvisibilityRules _pruneExpiredRules(InvisibilityRules rules) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final prunedDateRangeRules = rules.dateRangeRules.where((rule) {
      final endDate = DateTime(rule.endDate.year, rule.endDate.month, rule.endDate.day);
      return !today.isAfter(endDate);
    }).toList();
    final prunedDateTimeRangeRules = rules.dateTimeRangeRules.where((rule) {
      return !rule.endDateTime.isBefore(now);
    }).toList();
    return rules.copyWith(
      dateRangeRules: prunedDateRangeRules,
      dateTimeRangeRules: prunedDateTimeRangeRules,
    );
  }

  Future<void> _syncRulesToSupabase(String rulesJson) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

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
      _ensureRealtimeSubscription();
      final user = supabase.auth.currentUser;
      if (user != null) {
        final response = await supabase
            .from('user_invisibility_rules')
            .select('rules_data')
            .eq('user_id', user.id)
            .maybeSingle();

        if (response == null || response['rules_data'] == null) {
          final emptyRules = InvisibilityRules(isLoaded: true);
          state = emptyRules;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('invisibility_rules', jsonEncode(emptyRules.toJson()));
          await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
          return;
        }

        final rules = _rulesFromRecordValue(response['rules_data']);
        if (rules == null) {
          return;
        }
        final normalizedRules = _pruneExpiredRules(rules).copyWith(isLoaded: true);
        final normalizedRulesJson = jsonEncode(normalizedRules.toJson());
        state = normalizedRules;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('invisibility_rules', normalizedRulesJson);
        await ref.read(isVisibleProvider.notifier).updateEffectiveVisibility();
        return;
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
  // Don't compute reasons if rules aren't loaded yet
  final rules = ref.watch(invisibilityRulesProvider);
  if (!rules.isLoaded) {
    return [];
  }
  
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
  // Don't compute active rules if rules aren't loaded yet
  final rules = ref.watch(invisibilityRulesProvider);
  if (!rules.isLoaded) {
    return {};
  }
  
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
// NOTE: This provider watches the underlying providers directly instead of
// currentInvisibilityReasonsProvider to avoid Riverpod subscription issues
// that can occur with chained providers during widget rebuilds.
final currentInvisibilityReasonProvider = Provider<String?>((ref) {
  // Watch the underlying providers directly
  final rules = ref.watch(invisibilityRulesProvider);
  final currentLocation = ref.watch(currentLocationProvider);
  final l10n = ref.watch(localizationProvider);

  // Don't compute reasons if rules aren't loaded yet
  if (!rules.isLoaded) {
    return null;
  }

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
      final effectiveRadius = rule.radiusMeters < 5.0 ? 5.0 : rule.radiusMeters;
      if (distance <= effectiveRadius) {
        reasons.add('location');
        break;
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
      reasons.add('date');
      break;
    }
  }

  // Check time range rules
  for (final rule in rules.timeRangeRules) {
    if (!rule.enabled) continue;
    final currentTime = TimeOfDay.fromDateTime(now);
    if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
      reasons.add('time');
      break;
    }
  }

  // Check day of week rules
  for (final rule in rules.dayOfWeekRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      reasons.add('day');
      break;
    }
  }

  // Check date time range rules
  for (final rule in rules.dateTimeRangeRules) {
    if (!rule.enabled) continue;
    if (now.isAfter(rule.startDateTime) && now.isBefore(rule.endDateTime)) {
      reasons.add('datetime');
      break;
    }
  }

  // Check day time range rules
  for (final rule in rules.dayTimeRangeRules) {
    if (!rule.enabled) continue;
    if (rule.daysOfWeek.contains(now.weekday)) {
      final currentTime = TimeOfDay.fromDateTime(now);
      if (_isTimeInRange(currentTime, rule.startTime, rule.endTime)) {
        reasons.add('daytime');
        break;
      }
    }
  }

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

  // Determine user's gender (if available) to choose the correct localized phrasing
  final currentUserId = Supabase.instance.client.auth.currentUser?.id;
  final currentUserGender = currentUserId != null ? ref.watch(userProfileProvider(currentUserId)).asData?.value?.gender : null;

  if (reasonTexts.length == 1) {
    return '${l10n.getString('invisibleDueTo', gender: currentUserGender)} ${reasonTexts[0].toLowerCase()}';
  } else if (reasonTexts.length == 2) {
    return '${l10n.getString('invisibleDueTo', gender: currentUserGender)} ${reasonTexts[0].toLowerCase()} ${l10n.getString('and').toLowerCase()} ${reasonTexts[1].toLowerCase()}';
  } else {
    final last = reasonTexts.removeLast();
    final joined = reasonTexts.join(', ').toLowerCase();
    return '${l10n.getString('invisibleDueTo', gender: currentUserGender)} $joined ${l10n.getString('and').toLowerCase()} $last'.toLowerCase();
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
