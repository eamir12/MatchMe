// lib/providers/user_preferences_provider.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/background_service.dart';

enum UnitSystemPreference { system, metric, imperial }
enum TimeFormatPreference { system, h24, h12 }

enum NotificationType { chatMessages, newMatch, expiringMatch, adminAnnouncements }
enum NotificationMethod { push, inApp, sound, vibrate }

String _notificationTypeKey(NotificationType t) {
  return switch (t) {
    NotificationType.chatMessages => 'chat_messages',
    NotificationType.newMatch => 'new_match',
    NotificationType.expiringMatch => 'expiring_match',
    NotificationType.adminAnnouncements => 'admin_announcements',
  };
}

NotificationType? _notificationTypeFromKey(String? key) {
  if (key == null) return null;
  final k = key.trim().toLowerCase();
  return switch (k) {
    'chat_messages' => NotificationType.chatMessages,
    'new_match' => NotificationType.newMatch,
    'expiring_match' => NotificationType.expiringMatch,
    'admin_announcements' => NotificationType.adminAnnouncements,
    _ => null,
  };
}

String _notificationMethodKey(NotificationMethod m) {
  return switch (m) {
    NotificationMethod.push => 'push',
    NotificationMethod.inApp => 'in_app',
    NotificationMethod.sound => 'sound',
    NotificationMethod.vibrate => 'vibrate',
  };
}

NotificationMethod? _notificationMethodFromKey(String? key) {
  if (key == null) return null;
  final k = key.trim().toLowerCase();
  return switch (k) {
    'push' => NotificationMethod.push,
    'in_app' => NotificationMethod.inApp,
    'sound' => NotificationMethod.sound,
    'vibrate' => NotificationMethod.vibrate,
    _ => null,
  };
}

class NotificationPreferencesState {
  final Map<NotificationType, Map<NotificationMethod, bool>> matrix;
  final Map<NotificationMethod, bool> globalMethods;
  final int? pausedUntilEpochMsUtc;
  final int? pausedDurationSeconds;
  final bool pausedIndefinitely;
  static const Object _unset = Object();

  const NotificationPreferencesState({
    this.matrix = _defaultMatrix,
    this.globalMethods = _defaultGlobalMethods,
    this.pausedUntilEpochMsUtc,
    this.pausedDurationSeconds,
    this.pausedIndefinitely = false,
  });

  static const Map<NotificationMethod, bool> _defaultGlobalMethods = {
    NotificationMethod.push: true,
    NotificationMethod.inApp: true,
    NotificationMethod.sound: true,
    NotificationMethod.vibrate: true,
  };

  static const Map<NotificationType, Map<NotificationMethod, bool>> _defaultMatrix = {
    NotificationType.chatMessages: {
      NotificationMethod.push: true,
      NotificationMethod.inApp: true,
      NotificationMethod.sound: true,
      NotificationMethod.vibrate: true,
    },
    NotificationType.newMatch: {
      NotificationMethod.push: true,
      NotificationMethod.inApp: true,
      NotificationMethod.sound: true,
      NotificationMethod.vibrate: true,
    },
    NotificationType.expiringMatch: {
      NotificationMethod.push: true,
      NotificationMethod.inApp: true,
      NotificationMethod.sound: true,
      NotificationMethod.vibrate: true,
    },
    NotificationType.adminAnnouncements: {
      NotificationMethod.push: true,
      NotificationMethod.inApp: true,
      NotificationMethod.sound: true,
      NotificationMethod.vibrate: true,
    },
  };

  factory NotificationPreferencesState.defaults() => const NotificationPreferencesState();

  bool get isPausedNow {
    if (pausedIndefinitely) return true;
    final untilMs = pausedUntilEpochMsUtc;
    if (untilMs == null) return false;
    return untilMs > DateTime.now().toUtc().millisecondsSinceEpoch;
  }

  DateTime? get resumesAtLocal {
    if (pausedIndefinitely) return null;
    final untilMs = pausedUntilEpochMsUtc;
    if (untilMs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(untilMs, isUtc: true).toLocal();
  }

  bool isGlobalMethodEnabled(NotificationMethod method) {
    return globalMethods[method] ?? true;
  }

  bool isMethodEnabled(NotificationType type, NotificationMethod method) {
    if (!isGlobalMethodEnabled(method)) return false;
    return matrix[type]?[method] ?? true;
  }

  bool isTypeEnabled(NotificationType type) {
    final methods = matrix[type];
    if (methods == null || methods.isEmpty) return true;
    return NotificationMethod.values.any((m) => isMethodEnabled(type, m));
  }

  bool get enableChatNotifications => isMethodEnabled(NotificationType.chatMessages, NotificationMethod.push);
  bool get enableNewMatchNotifications => isMethodEnabled(NotificationType.newMatch, NotificationMethod.push);
  bool get enableMatchExpiryNotifications => isMethodEnabled(NotificationType.expiringMatch, NotificationMethod.push);
  bool get enableAdminNotifications => isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.push);

  bool get enableSound {
    return isGlobalMethodEnabled(NotificationMethod.sound);
  }

  bool get enableVibration {
    return isGlobalMethodEnabled(NotificationMethod.vibrate);
  }

  bool get enableInAppNotifications {
    return isGlobalMethodEnabled(NotificationMethod.inApp);
  }

  bool get enablePushNotifications {
    return isGlobalMethodEnabled(NotificationMethod.push);
  }

  NotificationPreferencesState copyWith({
    Map<NotificationType, Map<NotificationMethod, bool>>? matrix,
    Map<NotificationMethod, bool>? globalMethods,
    Object? pausedUntilEpochMsUtc = _unset,
    Object? pausedDurationSeconds = _unset,
    bool? pausedIndefinitely,
  }) {
    return NotificationPreferencesState(
      matrix: matrix ?? this.matrix,
      globalMethods: globalMethods ?? this.globalMethods,
      pausedUntilEpochMsUtc: identical(pausedUntilEpochMsUtc, _unset)
          ? this.pausedUntilEpochMsUtc
          : pausedUntilEpochMsUtc as int?,
      pausedDurationSeconds: identical(pausedDurationSeconds, _unset)
          ? this.pausedDurationSeconds
          : pausedDurationSeconds as int?,
      pausedIndefinitely: pausedIndefinitely ?? this.pausedIndefinitely,
    );
  }
}

class UserPreferencesState {
  final UnitSystemPreference unitSystem;
  final TimeFormatPreference timeFormat;
  final bool highAccuracyMode;
  final NotificationPreferencesState notifications;

  const UserPreferencesState({
    required this.unitSystem,
    required this.timeFormat,
    this.highAccuracyMode = false,
    required this.notifications,
  });

  factory UserPreferencesState.defaults() => UserPreferencesState(
        unitSystem: UnitSystemPreference.system,
        timeFormat: TimeFormatPreference.system,
        highAccuracyMode: false,
        notifications: NotificationPreferencesState.defaults(),
      );

  UserPreferencesState copyWith({
    UnitSystemPreference? unitSystem,
    TimeFormatPreference? timeFormat,
    bool? highAccuracyMode,
    NotificationPreferencesState? notifications,
  }) {
    return UserPreferencesState(
      unitSystem: unitSystem ?? this.unitSystem,
      timeFormat: timeFormat ?? this.timeFormat,
      highAccuracyMode: highAccuracyMode ?? this.highAccuracyMode,
      notifications: notifications ?? this.notifications,
    );
  }
}

class UserPreferencesNotifier extends Notifier<UserPreferencesState> {
  static const _prefsUnitSystemKey = 'unit_system_override';
  static const _prefsTimeFormatKey = 'time_format_override';
  static const _prefsHighAccuracyKey = 'flutter.high_accuracy_mode';
  static const _prefsChatNotificationsKey = 'notifications_chat';
  static const _prefsNewMatchNotificationsKey = 'notifications_new_match';
  static const _prefsMatchExpiryNotificationsKey = 'notifications_match_expiry';
  static const _prefsAdminNotificationsKey = 'notifications_admin';
  static const _prefsSoundKey = 'notifications_sound';
  static const _prefsVibrationKey = 'notifications_vibration';
  static const _prefsInAppNotificationsKey = 'notifications_in_app';
  static const _prefsMatrixKey = 'notifications_matrix_v1';
  static const _prefsGlobalPushKey = 'notifications_global_push_v1';
  static const _prefsGlobalInAppKey = 'notifications_global_in_app_v1';
  static const _prefsGlobalSoundKey = 'notifications_global_sound_v1';
  static const _prefsGlobalVibrationKey = 'notifications_global_vibration_v1';
  static const _prefsPausedUntilKey = 'notifications_paused_until_ms_utc';
  static const _prefsPausedDurationSecondsKey = 'notifications_paused_duration_seconds';
  static const _prefsPausedIndefinitelyKey = 'notifications_paused_indefinitely';

  final supabase = Supabase.instance.client;
  Timer? _notificationUnpauseTimer;

  @override
  UserPreferencesState build() {
    // Start with defaults, then hydrate from local storage and sync
    ref.onDispose(() {
      _notificationUnpauseTimer?.cancel();
      _notificationUnpauseTimer = null;
    });
    _loadFromLocalAndSync();
    return UserPreferencesState.defaults();
  }

  void _syncNotificationMuteTimer() {
    _notificationUnpauseTimer?.cancel();
    _notificationUnpauseTimer = null;

    final notifs = state.notifications;
    if (notifs.pausedIndefinitely) return;

    final untilMsUtc = notifs.pausedUntilEpochMsUtc;
    if (untilMsUtc == null) return;

    final nowMsUtc = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (untilMsUtc <= nowMsUtc) {
      state = state.copyWith(
        notifications: notifs.copyWith(
          pausedUntilEpochMsUtc: null,
          pausedDurationSeconds: null,
          pausedIndefinitely: false,
        ),
      );
      unawaited(_saveNotificationPreferences());
      return;
    }

    final delayMs = untilMsUtc - nowMsUtc;
    _notificationUnpauseTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!ref.mounted) return;
      final currentNotifs = state.notifications;
      if (currentNotifs.pausedIndefinitely) return;
      final currentUntil = currentNotifs.pausedUntilEpochMsUtc;
      if (currentUntil == null) return;
      final currentNow = DateTime.now().toUtc().millisecondsSinceEpoch;
      if (currentUntil > currentNow) return;

      state = state.copyWith(
        notifications: currentNotifs.copyWith(
          pausedUntilEpochMsUtc: null,
          pausedDurationSeconds: null,
          pausedIndefinitely: false,
        ),
      );
      unawaited(_saveNotificationPreferences());
    });
  }

  Future<void> _loadFromLocalAndSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final unitStr = prefs.getString(_prefsUnitSystemKey);
      final timeStr = prefs.getString(_prefsTimeFormatKey);
      final highAccuracy = prefs.getBool(_prefsHighAccuracyKey) ?? false;

      // Load notification preferences
      final chatNotifs = prefs.getBool(_prefsChatNotificationsKey) ?? true;
      final newMatchNotifs = prefs.getBool(_prefsNewMatchNotificationsKey) ?? true;
      final matchExpiryNotifs = prefs.getBool(_prefsMatchExpiryNotificationsKey) ?? true;
      final adminNotifs = prefs.getBool(_prefsAdminNotificationsKey) ?? true;
      final sound = prefs.getBool(_prefsSoundKey) ?? true;
      final vibration = prefs.getBool(_prefsVibrationKey) ?? true;
      final inApp = prefs.getBool(_prefsInAppNotificationsKey) ?? true;
      final storedGlobalPush = prefs.getBool(_prefsGlobalPushKey);
      final storedGlobalInApp = prefs.getBool(_prefsGlobalInAppKey);
      final storedGlobalSound = prefs.getBool(_prefsGlobalSoundKey);
      final storedGlobalVibration = prefs.getBool(_prefsGlobalVibrationKey);
      final pausedUntilMsUtc = prefs.getInt(_prefsPausedUntilKey);
      final pausedDurationSeconds = prefs.getInt(_prefsPausedDurationSecondsKey);
      final pausedIndefinitely = prefs.getBool(_prefsPausedIndefinitelyKey) ?? false;

      Map<NotificationType, Map<NotificationMethod, bool>> localMatrix = _buildMatrixFromLegacy(
        chatNotifs: chatNotifs,
        newMatchNotifs: newMatchNotifs,
        matchExpiryNotifs: matchExpiryNotifs,
        adminNotifs: adminNotifs,
        sound: sound,
        vibration: vibration,
        inApp: inApp,
      );

      final matrixJson = prefs.getString(_prefsMatrixKey);
      if (matrixJson != null && matrixJson.trim().isNotEmpty) {
        final decoded = jsonDecode(matrixJson);
        final parsed = _parseMatrix(decoded);
        if (parsed != null) {
          localMatrix = parsed;
        }
      }

      bool inferGlobalFromMatrix(NotificationMethod method) {
        return localMatrix.values.any((m) => (m[method] ?? true) == true);
      }

      final localGlobalMethods = <NotificationMethod, bool>{
        NotificationMethod.push: storedGlobalPush ?? inferGlobalFromMatrix(NotificationMethod.push),
        NotificationMethod.inApp: storedGlobalInApp ?? inferGlobalFromMatrix(NotificationMethod.inApp),
        NotificationMethod.sound: storedGlobalSound ?? inferGlobalFromMatrix(NotificationMethod.sound),
        NotificationMethod.vibrate: storedGlobalVibration ?? inferGlobalFromMatrix(NotificationMethod.vibrate),
      };

      // Also try to load from Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          final userData = await supabase
              .from('users')
              .select('unit_system, time_format, notification_preferences')
              .eq('id', userId)
              .maybeSingle();

          if (userData != null) {
            final remoteUnitStr = userData['unit_system'] as String?;
            final remoteTimeStr = userData['time_format'] as String?;
            final remoteNotifPrefs = userData['notification_preferences'] as Map<String, dynamic>?;

            // Parse remote notification preferences if available
            bool remoChatNotifs = chatNotifs;
            bool remoteNewMatchNotifs = newMatchNotifs;
            bool remoteMatchExpiryNotifs = matchExpiryNotifs;
            bool remoteAdminNotifs = adminNotifs;
            bool remoteSound = sound;
            bool remoteVibration = vibration;
            bool remoteInApp = inApp;
            Map<NotificationMethod, bool> remoteGlobalMethods = localGlobalMethods;
            int? remotePausedUntilMsUtc = pausedUntilMsUtc;
            int? remotePausedDurationSeconds = pausedDurationSeconds;
            bool remotePausedIndefinitely = pausedIndefinitely;
            Map<NotificationType, Map<NotificationMethod, bool>> remoteMatrix = localMatrix;

            if (remoteNotifPrefs != null) {
              remoChatNotifs = remoteNotifPrefs['enable_chat_notifications'] as bool? ?? chatNotifs;
              remoteNewMatchNotifs = remoteNotifPrefs['enable_new_match_notifications'] as bool? ?? newMatchNotifs;
              remoteMatchExpiryNotifs = remoteNotifPrefs['enable_match_expiry_notifications'] as bool? ?? matchExpiryNotifs;
              remoteAdminNotifs = remoteNotifPrefs['enable_admin_notifications'] as bool? ?? adminNotifs;
              remoteSound = remoteNotifPrefs['enable_sound'] as bool? ?? sound;
              remoteVibration = remoteNotifPrefs['enable_vibration'] as bool? ?? vibration;
              remoteInApp = remoteNotifPrefs['enable_in_app_notifications'] as bool? ?? inApp;

              remotePausedUntilMsUtc = (remoteNotifPrefs['paused_until_ms_utc'] as num?)?.toInt() ?? remotePausedUntilMsUtc;
              remotePausedDurationSeconds =
                  (remoteNotifPrefs['paused_duration_seconds'] as num?)?.toInt() ?? remotePausedDurationSeconds;
              remotePausedIndefinitely = remoteNotifPrefs['paused_indefinitely'] as bool? ?? remotePausedIndefinitely;

              final parsedMatrix = _parseMatrix(remoteNotifPrefs['matrix']);
              if (parsedMatrix != null) {
                remoteMatrix = parsedMatrix;
              } else {
                remoteMatrix = _buildMatrixFromLegacy(
                  chatNotifs: remoChatNotifs,
                  newMatchNotifs: remoteNewMatchNotifs,
                  matchExpiryNotifs: remoteMatchExpiryNotifs,
                  adminNotifs: remoteAdminNotifs,
                  sound: remoteSound,
                  vibration: remoteVibration,
                  inApp: remoteInApp,
                );
              }

              bool inferRemoteGlobalFromMatrix(NotificationMethod method) {
                return remoteMatrix.values.any((m) => (m[method] ?? true) == true);
              }

              final globalMethodsRaw = remoteNotifPrefs['global_methods'];
              if (globalMethodsRaw is Map) {
                remoteGlobalMethods = {
                  NotificationMethod.push: globalMethodsRaw['push'] is bool
                      ? globalMethodsRaw['push'] as bool
                      : inferRemoteGlobalFromMatrix(NotificationMethod.push),
                  NotificationMethod.inApp: globalMethodsRaw['in_app'] is bool
                      ? globalMethodsRaw['in_app'] as bool
                      : inferRemoteGlobalFromMatrix(NotificationMethod.inApp),
                  NotificationMethod.sound: globalMethodsRaw['sound'] is bool
                      ? globalMethodsRaw['sound'] as bool
                      : inferRemoteGlobalFromMatrix(NotificationMethod.sound),
                  NotificationMethod.vibrate: globalMethodsRaw['vibrate'] is bool
                      ? globalMethodsRaw['vibrate'] as bool
                      : inferRemoteGlobalFromMatrix(NotificationMethod.vibrate),
                };
              } else {
                remoteGlobalMethods = {
                  NotificationMethod.push: inferRemoteGlobalFromMatrix(NotificationMethod.push),
                  NotificationMethod.inApp: inferRemoteGlobalFromMatrix(NotificationMethod.inApp),
                  NotificationMethod.sound: inferRemoteGlobalFromMatrix(NotificationMethod.sound),
                  NotificationMethod.vibrate: inferRemoteGlobalFromMatrix(NotificationMethod.vibrate),
                };
              }
            }

            state = state.copyWith(
              unitSystem: _parseUnitSystem(remoteUnitStr) ?? state.unitSystem,
              timeFormat: _parseTimeFormat(remoteTimeStr) ?? state.timeFormat,
              highAccuracyMode: highAccuracy,
              notifications: NotificationPreferencesState(
                matrix: remoteMatrix,
                globalMethods: remoteGlobalMethods,
                pausedUntilEpochMsUtc: remotePausedUntilMsUtc,
                pausedDurationSeconds: remotePausedDurationSeconds,
                pausedIndefinitely: remotePausedIndefinitely,
              ),
            );
            _syncNotificationMuteTimer();

            // Update local storage with remote values
            if (remoteUnitStr != null) {
              await prefs.setString(_prefsUnitSystemKey, remoteUnitStr);
            }
            if (remoteTimeStr != null) {
              await prefs.setString(_prefsTimeFormatKey, remoteTimeStr);
            }
            if (remoteNotifPrefs != null) {
              await prefs.setBool(_prefsChatNotificationsKey, remoChatNotifs);
              await prefs.setBool(_prefsNewMatchNotificationsKey, remoteNewMatchNotifs);
              await prefs.setBool(_prefsMatchExpiryNotificationsKey, remoteMatchExpiryNotifs);
              await prefs.setBool(_prefsAdminNotificationsKey, remoteAdminNotifs);
              await prefs.setBool(_prefsSoundKey, remoteSound);
              await prefs.setBool(_prefsVibrationKey, remoteVibration);
              await prefs.setBool(_prefsInAppNotificationsKey, remoteInApp);
              await prefs.setBool(_prefsGlobalPushKey, remoteGlobalMethods[NotificationMethod.push] ?? true);
              await prefs.setBool(_prefsGlobalInAppKey, remoteGlobalMethods[NotificationMethod.inApp] ?? true);
              await prefs.setBool(_prefsGlobalSoundKey, remoteGlobalMethods[NotificationMethod.sound] ?? true);
              await prefs.setBool(_prefsGlobalVibrationKey, remoteGlobalMethods[NotificationMethod.vibrate] ?? true);
              if (remotePausedUntilMsUtc != null) {
                await prefs.setInt(_prefsPausedUntilKey, remotePausedUntilMsUtc);
              } else {
                await prefs.remove(_prefsPausedUntilKey);
              }
              if (remotePausedDurationSeconds != null) {
                await prefs.setInt(_prefsPausedDurationSecondsKey, remotePausedDurationSeconds);
              } else {
                await prefs.remove(_prefsPausedDurationSecondsKey);
              }
              await prefs.setBool(_prefsPausedIndefinitelyKey, remotePausedIndefinitely);
              await prefs.setString(_prefsMatrixKey, jsonEncode(_matrixToJson(remoteMatrix)));
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
        highAccuracyMode: highAccuracy,
        notifications: NotificationPreferencesState(
          matrix: localMatrix,
          globalMethods: localGlobalMethods,
          pausedUntilEpochMsUtc: pausedUntilMsUtc,
          pausedDurationSeconds: pausedDurationSeconds,
          pausedIndefinitely: pausedIndefinitely,
        ),
      );
      _syncNotificationMuteTimer();
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

  Future<void> setHighAccuracyMode(bool value) async {
    state = state.copyWith(highAccuracyMode: value);
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefsHighAccuracyKey, value);
    } catch (e) {
      debugPrint('Failed to persist High Accuracy Mode preference: $e');
    }
    try {
      await BackgroundService.updateHighAccuracyMode(value);
    } catch (e) {
      debugPrint('Failed to update native High Accuracy Mode: $e');
    }
  }

  Future<void> setChatNotifications(bool value) async {
    await setNotificationTypeEnabled(NotificationType.chatMessages, value);
  }

  Future<void> setNewMatchNotifications(bool value) async {
    await setNotificationTypeEnabled(NotificationType.newMatch, value);
  }

  Future<void> setMatchExpiryNotifications(bool value) async {
    await setNotificationTypeEnabled(NotificationType.expiringMatch, value);
  }

  Future<void> setAdminNotifications(bool value) async {
    await setNotificationTypeEnabled(NotificationType.adminAnnouncements, value);
  }

  Future<void> setNotificationSound(bool value) async {
    await setNotificationMethodForAll(NotificationMethod.sound, value);
  }

  Future<void> setNotificationVibration(bool value) async {
    await setNotificationMethodForAll(NotificationMethod.vibrate, value);
  }

  Future<void> setInAppNotifications(bool value) async {
    await setNotificationMethodForAll(NotificationMethod.inApp, value);
  }

  Future<void> pauseNotificationsFor(Duration duration) async {
    final untilMsUtc = DateTime.now().toUtc().add(duration).millisecondsSinceEpoch;
    state = state.copyWith(
      notifications: state.notifications.copyWith(
        pausedUntilEpochMsUtc: untilMsUtc,
        pausedDurationSeconds: duration.inSeconds,
        pausedIndefinitely: false,
      ),
    );
    _syncNotificationMuteTimer();
    await _saveNotificationPreferences();
  }

  Future<void> pauseNotificationsIndefinitely() async {
    state = state.copyWith(
      notifications: state.notifications.copyWith(
        pausedUntilEpochMsUtc: null,
        pausedDurationSeconds: null,
        pausedIndefinitely: true,
      ),
    );
    _syncNotificationMuteTimer();
    await _saveNotificationPreferences();
  }

  Future<void> resumeNotifications() async {
    state = state.copyWith(
      notifications: state.notifications.copyWith(
        pausedUntilEpochMsUtc: null,
        pausedDurationSeconds: null,
        pausedIndefinitely: false,
      ),
    );
    _syncNotificationMuteTimer();
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationMethodForType(
    NotificationType type,
    NotificationMethod method,
    bool value,
  ) async {
    final next = _setMatrixValue(
      state.notifications.matrix,
      type: type,
      method: method,
      value: value,
    );
    state = state.copyWith(notifications: state.notifications.copyWith(matrix: next));
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationMethodForAll(NotificationMethod method, bool value) async {
    var next = state.notifications.matrix;
    for (final type in NotificationType.values) {
      next = _setMatrixValue(next, type: type, method: method, value: value);
    }
    state = state.copyWith(notifications: state.notifications.copyWith(matrix: next));
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationMethodForTypes(
    Iterable<NotificationType> types,
    NotificationMethod method,
    bool value,
  ) async {
    var next = state.notifications.matrix;
    for (final type in types) {
      next = _setMatrixValue(next, type: type, method: method, value: value);
    }
    state = state.copyWith(notifications: state.notifications.copyWith(matrix: next));
    await _saveNotificationPreferences();
  }

  Future<void> setGlobalNotificationMethodEnabled(NotificationMethod method, bool enabled) async {
    final next = {
      ...state.notifications.globalMethods,
      method: enabled,
    };
    state = state.copyWith(notifications: state.notifications.copyWith(globalMethods: next));
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationTypeEnabled(NotificationType type, bool enabled) async {
    bool globalEnabledForMethod(NotificationMethod method) {
      return state.notifications.isGlobalMethodEnabled(method);
    }

    final next = <NotificationType, Map<NotificationMethod, bool>>{
      ...state.notifications.matrix,
      type: {
        for (final m in NotificationMethod.values) m: enabled ? globalEnabledForMethod(m) : false,
      },
    };
    state = state.copyWith(notifications: state.notifications.copyWith(matrix: next));
    await _saveNotificationPreferences();
  }

  Future<void> _saveNotificationPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notifs = state.notifications;

      await prefs.setBool(_prefsChatNotificationsKey, notifs.enableChatNotifications);
      await prefs.setBool(_prefsNewMatchNotificationsKey, notifs.enableNewMatchNotifications);
      await prefs.setBool(_prefsMatchExpiryNotificationsKey, notifs.enableMatchExpiryNotifications);
      await prefs.setBool(_prefsAdminNotificationsKey, notifs.enableAdminNotifications);
      await prefs.setBool(_prefsSoundKey, notifs.enableSound);
      await prefs.setBool(_prefsVibrationKey, notifs.enableVibration);
      await prefs.setBool(_prefsInAppNotificationsKey, notifs.enableInAppNotifications);
      await prefs.setBool(_prefsGlobalPushKey, notifs.enablePushNotifications);
      await prefs.setBool(_prefsGlobalInAppKey, notifs.enableInAppNotifications);
      await prefs.setBool(_prefsGlobalSoundKey, notifs.enableSound);
      await prefs.setBool(_prefsGlobalVibrationKey, notifs.enableVibration);
      if (notifs.pausedUntilEpochMsUtc != null) {
        await prefs.setInt(_prefsPausedUntilKey, notifs.pausedUntilEpochMsUtc!);
      } else {
        await prefs.remove(_prefsPausedUntilKey);
      }
      if (notifs.pausedDurationSeconds != null) {
        await prefs.setInt(_prefsPausedDurationSecondsKey, notifs.pausedDurationSeconds!);
      } else {
        await prefs.remove(_prefsPausedDurationSecondsKey);
      }
      await prefs.setBool(_prefsPausedIndefinitelyKey, notifs.pausedIndefinitely);
      await prefs.setString(_prefsMatrixKey, jsonEncode(_matrixToJson(notifs.matrix)));

      // Sync to Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          final matrixJson = _matrixToJson(notifs.matrix);
          await supabase
              .from('users')
              .update({
                'notification_preferences': {
                  'schema_version': 2,
                  'paused_until_ms_utc': notifs.pausedUntilEpochMsUtc,
                  'paused_duration_seconds': notifs.pausedDurationSeconds,
                  'paused_indefinitely': notifs.pausedIndefinitely,
                  'matrix': matrixJson,
                  'global_methods': {
                    'push': notifs.enablePushNotifications,
                    'in_app': notifs.enableInAppNotifications,
                    'sound': notifs.enableSound,
                    'vibrate': notifs.enableVibration,
                  },
                  'enable_chat_notifications': notifs.enableChatNotifications,
                  'enable_new_match_notifications': notifs.enableNewMatchNotifications,
                  'enable_match_expiry_notifications': notifs.enableMatchExpiryNotifications,
                  'enable_admin_notifications': notifs.enableAdminNotifications,
                  'enable_sound': notifs.enableSound,
                  'enable_vibration': notifs.enableVibration,
                  'enable_in_app_notifications': notifs.enableInAppNotifications,
                }
              })
              .eq('id', userId);
        } catch (e) {
          // If sync fails, we've already updated local state
          debugPrint('Failed to sync notification preferences: $e');
        }
      }
    } catch (_) {}
  }

  static Map<NotificationType, Map<NotificationMethod, bool>> _buildMatrixFromLegacy({
    required bool chatNotifs,
    required bool newMatchNotifs,
    required bool matchExpiryNotifs,
    required bool adminNotifs,
    required bool sound,
    required bool vibration,
    required bool inApp,
  }) {
    return {
      NotificationType.chatMessages: {
        NotificationMethod.push: chatNotifs,
        NotificationMethod.inApp: inApp,
        NotificationMethod.sound: sound,
        NotificationMethod.vibrate: vibration,
      },
      NotificationType.newMatch: {
        NotificationMethod.push: newMatchNotifs,
        NotificationMethod.inApp: inApp,
        NotificationMethod.sound: sound,
        NotificationMethod.vibrate: vibration,
      },
      NotificationType.expiringMatch: {
        NotificationMethod.push: matchExpiryNotifs,
        NotificationMethod.inApp: inApp,
        NotificationMethod.sound: sound,
        NotificationMethod.vibrate: vibration,
      },
      NotificationType.adminAnnouncements: {
        NotificationMethod.push: adminNotifs,
        NotificationMethod.inApp: inApp,
        NotificationMethod.sound: sound,
        NotificationMethod.vibrate: vibration,
      },
    };
  }

  static Map<String, dynamic> _matrixToJson(Map<NotificationType, Map<NotificationMethod, bool>> matrix) {
    final out = <String, dynamic>{};
    for (final entry in matrix.entries) {
      out[_notificationTypeKey(entry.key)] = {
        for (final methodEntry in entry.value.entries) _notificationMethodKey(methodEntry.key): methodEntry.value,
      };
    }
    return out;
  }

  static Map<NotificationType, Map<NotificationMethod, bool>>? _parseMatrix(dynamic raw) {
    if (raw is! Map) return null;
    final out = <NotificationType, Map<NotificationMethod, bool>>{};
    for (final entry in raw.entries) {
      final type = _notificationTypeFromKey(entry.key?.toString());
      if (type == null) continue;
      final v = entry.value;
      if (v is! Map) continue;
      final methods = <NotificationMethod, bool>{};
      for (final mEntry in v.entries) {
        final method = _notificationMethodFromKey(mEntry.key?.toString());
        if (method == null) continue;
        final enabled = mEntry.value is bool ? (mEntry.value as bool) : null;
        if (enabled == null) continue;
        methods[method] = enabled;
      }
      if (methods.isNotEmpty) {
        out[type] = methods;
      }
    }
    if (out.isEmpty) return null;
    final merged = <NotificationType, Map<NotificationMethod, bool>>{};
    for (final type in NotificationType.values) {
      final base = NotificationPreferencesState._defaultMatrix[type] ?? const <NotificationMethod, bool>{};
      final override = out[type];
      merged[type] = {
        ...base,
        if (override != null) ...override,
      };
    }
    return merged;
  }

  static Map<NotificationType, Map<NotificationMethod, bool>> _setMatrixValue(
    Map<NotificationType, Map<NotificationMethod, bool>> current, {
    required NotificationType type,
    required NotificationMethod method,
    required bool value,
  }) {
    final currentType = current[type] ?? const <NotificationMethod, bool>{};
    return {
      ...current,
      type: {
        ...currentType,
        method: value,
      },
    };
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
