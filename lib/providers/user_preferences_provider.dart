// lib/providers/user_preferences_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/utils/permission_coordinator.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';

enum UnitSystemPreference { system, metric, imperial }

enum TimeFormatPreference { system, h24, h12 }

enum NotificationType {
  chatMessages,
  newMatch,
  expiringMatch,
  matchExtended,
  adminAnnouncements,
  locationSharing,
}

enum NotificationMethod { push, inApp, sound, vibrate }

String _notificationTypeKey(NotificationType t) {
  return switch (t) {
    NotificationType.chatMessages => 'chat_messages',
    NotificationType.newMatch => 'new_match',
    NotificationType.expiringMatch => 'expiring_match',
    NotificationType.matchExtended => 'match_extended',
    NotificationType.adminAnnouncements => 'admin_announcements',
    NotificationType.locationSharing => 'location_sharing',
  };
}

NotificationType? _notificationTypeFromKey(String? key) {
  if (key == null) return null;
  final k = key.trim().toLowerCase();
  return switch (k) {
    'chat_messages' => NotificationType.chatMessages,
    'new_match' => NotificationType.newMatch,
    'expiring_match' => NotificationType.expiringMatch,
    'match_extended' => NotificationType.matchExtended,
    'admin_announcements' => NotificationType.adminAnnouncements,
    'location_sharing' => NotificationType.locationSharing,
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

  static const Map<NotificationType, Map<NotificationMethod, bool>>
  _defaultMatrix = {
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
    NotificationType.matchExtended: {
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
    NotificationType.locationSharing: {
      NotificationMethod.push: true,
      NotificationMethod.inApp: true,
      NotificationMethod.sound: true,
      NotificationMethod.vibrate: true,
    },
  };

  factory NotificationPreferencesState.defaults() =>
      const NotificationPreferencesState();

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

  bool get enableChatNotifications =>
      isMethodEnabled(NotificationType.chatMessages, NotificationMethod.push);
  bool get enableNewMatchNotifications =>
      isMethodEnabled(NotificationType.newMatch, NotificationMethod.push);
  bool get enableMatchExpiryNotifications =>
      isMethodEnabled(NotificationType.expiringMatch, NotificationMethod.push);
  bool get enableAdminNotifications => isMethodEnabled(
    NotificationType.adminAnnouncements,
    NotificationMethod.push,
  );

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
  final bool backgroundMatchingMode;
  final NotificationPreferencesState notifications;
  final String? preferredCurrency;
  final List<String> recentCurrencies;

  const UserPreferencesState({
    required this.unitSystem,
    required this.timeFormat,
    this.backgroundMatchingMode = true,
    required this.notifications,
    this.preferredCurrency,
    this.recentCurrencies = const [],
  });

  factory UserPreferencesState.defaults() => UserPreferencesState(
    unitSystem: UnitSystemPreference.system,
    timeFormat: TimeFormatPreference.system,
    backgroundMatchingMode: true,
    notifications: NotificationPreferencesState.defaults(),
    preferredCurrency: null,
    recentCurrencies: const [],
  );

  UserPreferencesState copyWith({
    UnitSystemPreference? unitSystem,
    TimeFormatPreference? timeFormat,
    bool? backgroundMatchingMode,
    NotificationPreferencesState? notifications,
    Object? preferredCurrency = NotificationPreferencesState._unset,
    List<String>? recentCurrencies,
  }) {
    return UserPreferencesState(
      unitSystem: unitSystem ?? this.unitSystem,
      timeFormat: timeFormat ?? this.timeFormat,
      backgroundMatchingMode:
          backgroundMatchingMode ?? this.backgroundMatchingMode,
      notifications: notifications ?? this.notifications,
      preferredCurrency:
          identical(preferredCurrency, NotificationPreferencesState._unset)
          ? this.preferredCurrency
          : preferredCurrency as String?,
      recentCurrencies: recentCurrencies ?? this.recentCurrencies,
    );
  }
}

class UserPreferencesNotifier extends Notifier<UserPreferencesState>
    with WidgetsBindingObserver {
  static const _prefsUnitSystemKey = 'unit_system_override';
  static const _prefsTimeFormatKey = 'time_format_override';
  static const _prefsBackgroundMatchingKey = 'flutter.background_matching_mode';
  static const _prefsLegacyHighAccuracyKey = 'flutter.high_accuracy_mode';
  static const _prefsPendingBackgroundMatchingEnableKey =
      'flutter.background_matching_mode_pending_enable';
  static const _prefsLegacyPendingHighAccuracyEnableKey =
      'flutter.high_accuracy_mode_pending_enable';
  static const _prefsChatNotificationsKey = 'notifications_chat';
  static const _prefsNewMatchNotificationsKey = 'notifications_new_match';
  static const _prefsMatchExpiryNotificationsKey = 'notifications_match_expiry';
  static const _prefsMatchExtendedNotificationsKey =
      'notifications_match_extended';
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
  static const _prefsPausedDurationSecondsKey =
      'notifications_paused_duration_seconds';
  static const _prefsPausedIndefinitelyKey =
      'notifications_paused_indefinitely';
  static const _prefsPreferredCurrencyKey = 'preferred_currency_override';
  static const _prefsRecentCurrenciesKey = 'recent_currencies_v1';

  final supabase = Supabase.instance.client;
  Timer? _notificationUnpauseTimer;
  RealtimeChannel? _settingsSubscription;
  String? _settingsSubscriptionUserId;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _lifecycleObserverAttached = false;
  DateTime? _lastPausedAt;
  DateTime? _lastFullSyncAt;
  Future<void>? _loadSyncInFlight;
  static const Duration _resumeFullSyncThreshold = Duration(minutes: 2);

  @override
  UserPreferencesState build() {
    ref.onDispose(() {
      _notificationUnpauseTimer?.cancel();
      _notificationUnpauseTimer = null;
      _clearRealtimeSubscription();
      _authStateSubscription?.cancel();
      _authStateSubscription = null;
      _detachLifecycleObserver();
    });
    _listenAuthStateChanges();
    unawaited(_loadFromLocalAndSync());
    _ensureRealtimeSubscription();
    _attachLifecycleObserver();
    return UserPreferencesState.defaults();
  }

  Future<void> refresh() async {
    await _loadFromLocalAndSync();
  }

  void _clearRealtimeSubscription() {
    final userId = _settingsSubscriptionUserId;
    _settingsSubscription = null;
    _settingsSubscriptionUserId = null;
    if (userId != null) {
      SupabaseRealtimeManager.instance.unregister('user_settings_$userId');
    }
  }

  void _listenAuthStateChanges() {
    _authStateSubscription?.cancel();
    _authStateSubscription = supabase.auth.onAuthStateChange.listen(
      (event) {
        final authEvent = event.event;
        switch (authEvent) {
          case AuthChangeEvent.signedOut:
            _clearRealtimeSubscription();
            return;
          case AuthChangeEvent.initialSession:
          case AuthChangeEvent.signedIn:
          case AuthChangeEvent.userUpdated:
            _ensureRealtimeSubscription();
            unawaited(_loadFromLocalAndSync());
            return;
          default:
            return;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[PREFS] Auth stream error: $error');
      },
    );
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
    final inFlight = _loadSyncInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final completer = Completer<void>();
    _loadSyncInFlight = completer.future;
    _ensureRealtimeSubscription();
    ResumeDiagnostics.logThrottled(
      'User preferences: starting local+remote sync',
      category: 'prefs-sync-start',
      minIntervalMs: 500,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      final unitStr = prefs.getString(_prefsUnitSystemKey);
      final timeStr = prefs.getString(_prefsTimeFormatKey);
      // Migrate legacy SharedPreferences key if present.
      // Default true for new users (matches DB default + native service).
      final highAccuracy =
          prefs.getBool(_prefsBackgroundMatchingKey) ??
          (prefs.containsKey(_prefsLegacyHighAccuracyKey)
              ? prefs.getBool(_prefsLegacyHighAccuracyKey)!
              : true);
      if (prefs.containsKey(_prefsLegacyHighAccuracyKey)) {
        await prefs.setBool(_prefsBackgroundMatchingKey, highAccuracy);
        await prefs.remove(_prefsLegacyHighAccuracyKey);
      } else if (!prefs.containsKey(_prefsBackgroundMatchingKey)) {
        await prefs.setBool(_prefsBackgroundMatchingKey, highAccuracy);
      }

      // Load notification preferences
      final chatNotifs = prefs.getBool(_prefsChatNotificationsKey) ?? true;
      final newMatchNotifs =
          prefs.getBool(_prefsNewMatchNotificationsKey) ?? true;
      final matchExpiryNotifs =
          prefs.getBool(_prefsMatchExpiryNotificationsKey) ?? true;
      final adminNotifs = prefs.getBool(_prefsAdminNotificationsKey) ?? true;
      final sound = prefs.getBool(_prefsSoundKey) ?? true;
      final vibration = prefs.getBool(_prefsVibrationKey) ?? true;
      final inApp = prefs.getBool(_prefsInAppNotificationsKey) ?? true;
      final storedGlobalPush = prefs.getBool(_prefsGlobalPushKey);
      final storedGlobalInApp = prefs.getBool(_prefsGlobalInAppKey);
      final storedGlobalSound = prefs.getBool(_prefsGlobalSoundKey);
      final storedGlobalVibration = prefs.getBool(_prefsGlobalVibrationKey);
      final pausedUntilMsUtc = prefs.getInt(_prefsPausedUntilKey);
      final pausedDurationSeconds = prefs.getInt(
        _prefsPausedDurationSecondsKey,
      );
      final pausedIndefinitely =
          prefs.getBool(_prefsPausedIndefinitelyKey) ?? false;
      final localPreferredCurrency = _normalizeCurrencyCode(
        prefs.getString(_prefsPreferredCurrencyKey),
      );
      final localRecentCurrencies = _sanitizeCurrencyCodeList(
        prefs.getStringList(_prefsRecentCurrenciesKey),
      );

      Map<NotificationType, Map<NotificationMethod, bool>> localMatrix =
          _buildMatrixFromLegacy(
            chatNotifs: chatNotifs,
            newMatchNotifs: newMatchNotifs,
            matchExpiryNotifs: matchExpiryNotifs,
            matchExtendedNotifs:
                prefs.getBool(_prefsMatchExtendedNotificationsKey) ?? true,
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
        NotificationMethod.push:
            storedGlobalPush ?? inferGlobalFromMatrix(NotificationMethod.push),
        NotificationMethod.inApp:
            storedGlobalInApp ??
            inferGlobalFromMatrix(NotificationMethod.inApp),
        NotificationMethod.sound:
            storedGlobalSound ??
            inferGlobalFromMatrix(NotificationMethod.sound),
        NotificationMethod.vibrate:
            storedGlobalVibration ??
            inferGlobalFromMatrix(NotificationMethod.vibrate),
      };

      // Cache-first: apply the local snapshot IMMEDIATELY (memory + disk)
      // so UI renders instantly on startup, then refresh from Supabase in
      // background below.
      try {
        state = state.copyWith(
          unitSystem: _parseUnitSystem(unitStr) ?? state.unitSystem,
          timeFormat: _parseTimeFormat(timeStr) ?? state.timeFormat,
          backgroundMatchingMode: highAccuracy,
          notifications: NotificationPreferencesState(
            matrix: localMatrix,
            globalMethods: localGlobalMethods,
            pausedUntilEpochMsUtc: pausedUntilMsUtc,
            pausedDurationSeconds: pausedDurationSeconds,
            pausedIndefinitely: pausedIndefinitely,
          ),
          preferredCurrency: localPreferredCurrency,
          recentCurrencies: localRecentCurrencies,
        );
        _syncNotificationMuteTimer();
      } catch (_) {}

      // Also try to load from Supabase if user is logged in
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        try {
          final userData = await supabase
              .from('users')
              .select(
                'unit_system, time_format, theme_mode, background_matching_mode, notification_preferences, preferred_currency, recent_currencies',
              )
              .eq('id', userId)
              .maybeSingle();

          if (userData != null) {
            final remoteUnitStr = userData['unit_system'] as String?;
            final remoteTimeStr = userData['time_format'] as String?;
            final remoteThemeStr = userData['theme_mode'] as String?;
            final remoteHighAccuracy =
                userData['background_matching_mode'] as bool?;
            final remoteNotifPrefs =
                userData['notification_preferences'] as Map<String, dynamic>?;
            final remotePreferredCurrency = _normalizeCurrencyCode(
              userData['preferred_currency'] as String?,
            );
            final remoteRecentCurrencies = _sanitizeCurrencyCodeList(
              userData['recent_currencies'],
            );

            // Parse remote notification preferences if available
            bool remoChatNotifs = chatNotifs;
            bool remoteNewMatchNotifs = newMatchNotifs;
            bool remoteMatchExpiryNotifs = matchExpiryNotifs;
            bool remoteAdminNotifs = adminNotifs;
            bool remoteSound = sound;
            bool remoteVibration = vibration;
            bool remoteInApp = inApp;
            Map<NotificationMethod, bool> remoteGlobalMethods =
                localGlobalMethods;
            int? remotePausedUntilMsUtc = pausedUntilMsUtc;
            int? remotePausedDurationSeconds = pausedDurationSeconds;
            bool remotePausedIndefinitely = pausedIndefinitely;
            Map<NotificationType, Map<NotificationMethod, bool>> remoteMatrix =
                localMatrix;

            if (remoteNotifPrefs != null) {
              remoChatNotifs =
                  remoteNotifPrefs['enable_chat_notifications'] as bool? ??
                  chatNotifs;
              remoteNewMatchNotifs =
                  remoteNotifPrefs['enable_new_match_notifications'] as bool? ??
                  newMatchNotifs;
              remoteMatchExpiryNotifs =
                  remoteNotifPrefs['enable_match_expiry_notifications']
                      as bool? ??
                  matchExpiryNotifs;
              remoteAdminNotifs =
                  remoteNotifPrefs['enable_admin_notifications'] as bool? ??
                  adminNotifs;
              remoteSound = remoteNotifPrefs['enable_sound'] as bool? ?? sound;
              remoteVibration =
                  remoteNotifPrefs['enable_vibration'] as bool? ?? vibration;
              remoteInApp =
                  remoteNotifPrefs['enable_in_app_notifications'] as bool? ??
                  inApp;

              remotePausedUntilMsUtc =
                  (remoteNotifPrefs['paused_until_ms_utc'] as num?)?.toInt() ??
                  remotePausedUntilMsUtc;
              remotePausedDurationSeconds =
                  (remoteNotifPrefs['paused_duration_seconds'] as num?)
                      ?.toInt() ??
                  remotePausedDurationSeconds;
              remotePausedIndefinitely =
                  remoteNotifPrefs['paused_indefinitely'] as bool? ??
                  remotePausedIndefinitely;

              final parsedMatrix = _parseMatrix(remoteNotifPrefs['matrix']);
              if (parsedMatrix != null) {
                remoteMatrix = parsedMatrix;
              } else {
                remoteMatrix = _buildMatrixFromLegacy(
                  chatNotifs: remoChatNotifs,
                  newMatchNotifs: remoteNewMatchNotifs,
                  matchExpiryNotifs: remoteMatchExpiryNotifs,
                  matchExtendedNotifs:
                      remoteNotifPrefs[
                          'enable_match_extended_notifications'] as bool? ??
                      true,
                  adminNotifs: remoteAdminNotifs,
                  sound: remoteSound,
                  vibration: remoteVibration,
                  inApp: remoteInApp,
                );
              }

              bool inferRemoteGlobalFromMatrix(NotificationMethod method) {
                return remoteMatrix.values.any(
                  (m) => (m[method] ?? true) == true,
                );
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
                  NotificationMethod.vibrate:
                      globalMethodsRaw['vibrate'] is bool
                      ? globalMethodsRaw['vibrate'] as bool
                      : inferRemoteGlobalFromMatrix(NotificationMethod.vibrate),
                };
              } else {
                remoteGlobalMethods = {
                  NotificationMethod.push: inferRemoteGlobalFromMatrix(
                    NotificationMethod.push,
                  ),
                  NotificationMethod.inApp: inferRemoteGlobalFromMatrix(
                    NotificationMethod.inApp,
                  ),
                  NotificationMethod.sound: inferRemoteGlobalFromMatrix(
                    NotificationMethod.sound,
                  ),
                  NotificationMethod.vibrate: inferRemoteGlobalFromMatrix(
                    NotificationMethod.vibrate,
                  ),
                };
              }
            }

            state = state.copyWith(
              unitSystem: _parseUnitSystem(remoteUnitStr) ?? state.unitSystem,
              timeFormat: _parseTimeFormat(remoteTimeStr) ?? state.timeFormat,
              backgroundMatchingMode: remoteHighAccuracy ?? highAccuracy,
              notifications: NotificationPreferencesState(
                matrix: remoteMatrix,
                globalMethods: remoteGlobalMethods,
                pausedUntilEpochMsUtc: remotePausedUntilMsUtc,
                pausedDurationSeconds: remotePausedDurationSeconds,
                pausedIndefinitely: remotePausedIndefinitely,
              ),
              preferredCurrency:
                  remotePreferredCurrency ?? localPreferredCurrency,
              recentCurrencies: remoteRecentCurrencies.isNotEmpty
                  ? remoteRecentCurrencies
                  : localRecentCurrencies,
            );
            _syncNotificationMuteTimer();

            // Update local storage with remote values
            if (remoteUnitStr != null) {
              await prefs.setString(_prefsUnitSystemKey, remoteUnitStr);
            }
            if (remoteTimeStr != null) {
              await prefs.setString(_prefsTimeFormatKey, remoteTimeStr);
            }
            if (remoteThemeStr != null) {
              await prefs.setString('theme_mode', remoteThemeStr);
            }
            if (remoteHighAccuracy != null) {
              await prefs.setBool(
                _prefsBackgroundMatchingKey,
                remoteHighAccuracy,
              );
            }
            if (remotePreferredCurrency != null) {
              await prefs.setString(
                _prefsPreferredCurrencyKey,
                remotePreferredCurrency,
              );
            } else {
              await prefs.remove(_prefsPreferredCurrencyKey);
            }
            await prefs.setStringList(
              _prefsRecentCurrenciesKey,
              remoteRecentCurrencies.isNotEmpty
                  ? remoteRecentCurrencies
                  : localRecentCurrencies,
            );
            if (remoteNotifPrefs != null) {
              await prefs.setBool(_prefsChatNotificationsKey, remoChatNotifs);
              await prefs.setBool(
                _prefsNewMatchNotificationsKey,
                remoteNewMatchNotifs,
              );
              await prefs.setBool(
                _prefsMatchExpiryNotificationsKey,
                remoteMatchExpiryNotifs,
              );
              await prefs.setBool(
                _prefsAdminNotificationsKey,
                remoteAdminNotifs,
              );
              await prefs.setBool(_prefsSoundKey, remoteSound);
              await prefs.setBool(_prefsVibrationKey, remoteVibration);
              await prefs.setBool(_prefsInAppNotificationsKey, remoteInApp);
              await prefs.setBool(
                _prefsGlobalPushKey,
                remoteGlobalMethods[NotificationMethod.push] ?? true,
              );
              await prefs.setBool(
                _prefsGlobalInAppKey,
                remoteGlobalMethods[NotificationMethod.inApp] ?? true,
              );
              await prefs.setBool(
                _prefsGlobalSoundKey,
                remoteGlobalMethods[NotificationMethod.sound] ?? true,
              );
              await prefs.setBool(
                _prefsGlobalVibrationKey,
                remoteGlobalMethods[NotificationMethod.vibrate] ?? true,
              );
              if (remotePausedUntilMsUtc != null) {
                await prefs.setInt(
                  _prefsPausedUntilKey,
                  remotePausedUntilMsUtc,
                );
              } else {
                await prefs.remove(_prefsPausedUntilKey);
              }
              if (remotePausedDurationSeconds != null) {
                await prefs.setInt(
                  _prefsPausedDurationSecondsKey,
                  remotePausedDurationSeconds,
                );
              } else {
                await prefs.remove(_prefsPausedDurationSecondsKey);
              }
              await prefs.setBool(
                _prefsPausedIndefinitelyKey,
                remotePausedIndefinitely,
              );
              await prefs.setString(
                _prefsMatrixKey,
                jsonEncode(_matrixToJson(remoteMatrix)),
              );
            }

            _lastFullSyncAt = DateTime.now();
            ResumeDiagnostics.log('User preferences: remote sync completed');
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
        backgroundMatchingMode: highAccuracy,
        notifications: NotificationPreferencesState(
          matrix: localMatrix,
          globalMethods: localGlobalMethods,
          pausedUntilEpochMsUtc: pausedUntilMsUtc,
          pausedDurationSeconds: pausedDurationSeconds,
          pausedIndefinitely: pausedIndefinitely,
        ),
        preferredCurrency: localPreferredCurrency,
        recentCurrencies: localRecentCurrencies,
      );
      _syncNotificationMuteTimer();
      _lastFullSyncAt = DateTime.now();
      ResumeDiagnostics.log('User preferences: local snapshot applied');
    } catch (_) {
      // ignore
    } finally {
      if (!completer.isCompleted) {
        completer.complete();
      }
      _loadSyncInFlight = null;
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
            'userId': userId,
            'updates': {'unit_system': value.name},
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
            'userId': userId,
            'updates': {'time_format': value.name},
          });
        }
      }
    } catch (_) {}
  }

  Future<void> setPreferredCurrency(String code) async {
    final normalized = _normalizeCurrencyCode(code);
    if (normalized == null) return;

    final nextRecent = _buildRecentCurrencyList(
      normalized,
      state.recentCurrencies,
    );
    state = state.copyWith(
      preferredCurrency: normalized,
      recentCurrencies: nextRecent,
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsPreferredCurrencyKey, normalized);
      await prefs.setStringList(_prefsRecentCurrenciesKey, nextRecent);

      final userId = supabase.auth.currentUser?.id;
      if (userId != null && !shouldSkipSupabaseCalls()) {
        try {
          await supabase
              .from('users')
              .update({
                'preferred_currency': normalized,
                'recent_currencies': nextRecent,
              })
              .eq('id', userId);
        } catch (e) {
          final localDb = ref.read(localDbProvider);
          await localDb.saveProfileUpdateToOutbox(userId, {
            'userId': userId,
            'updates': {
              'preferred_currency': normalized,
              'recent_currencies': nextRecent,
            },
          });
        }
      }
    } catch (_) {}
  }

  Future<void> setBackgroundMatchingMode(bool value) async {
    state = state.copyWith(backgroundMatchingMode: value);

    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setBool(_prefsBackgroundMatchingKey, value);
      if (value) {
        await prefs.remove(_prefsPendingBackgroundMatchingEnableKey);
      } else {
        await prefs.setBool(_prefsPendingBackgroundMatchingEnableKey, false);
      }
      // Clean up legacy key if present
      if (prefs.containsKey(_prefsLegacyHighAccuracyKey)) {
        await prefs.remove(_prefsLegacyHighAccuracyKey);
      }
      if (prefs.containsKey(_prefsLegacyPendingHighAccuracyEnableKey)) {
        await prefs.remove(_prefsLegacyPendingHighAccuracyEnableKey);
      }
    } catch (e) {
      print('Failed to persist Background Matching Mode preference: $e');
      state = state.copyWith(backgroundMatchingMode: !value);
      rethrow;
    }

    try {
      await BackgroundService.updateBackgroundMatchingMode(value);
    } catch (e) {
      print('Failed to update native Background Matching Mode: $e');
    }

    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId != null) {
        await supabase
            .from('users')
            .update({'background_matching_mode': value})
            .eq('id', userId);
      }
    } catch (e) {
      print('Failed to sync background_matching_mode to Supabase: $e');
    }
  }

  Future<void> setPendingBackgroundMatchingEnable(bool value) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (value) {
        await prefs.setBool(_prefsPendingBackgroundMatchingEnableKey, true);
      } else {
        await prefs.remove(_prefsPendingBackgroundMatchingEnableKey);
      }
    } catch (e) {
      print('Failed to persist pending Background Matching Mode intent: $e');
    }
  }

  Future<void> syncBackgroundMatchingPermissionState() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final pendingEnable =
          prefs.getBool(_prefsPendingBackgroundMatchingEnableKey) ?? false;

      if (pendingEnable) {
        final hasBackgroundLocation =
            await PermissionCoordinator.hasBackgroundLocationPermission();
        if (hasBackgroundLocation) {
          print(
            'Background location permission granted after Settings, enabling Background Matching Mode',
          );
          ResumeDiagnostics.log(
            'User preferences: enabling Background Matching Mode after Settings return',
          );
          await setBackgroundMatchingMode(true);
        } else {
          await prefs.remove(_prefsPendingBackgroundMatchingEnableKey);
          ResumeDiagnostics.log(
            'User preferences: cleared pending Background Matching enable after Settings return without permission',
          );
        }
        return;
      }

      await validateBackgroundMatchingPermission();
    } catch (e) {
      print('Error syncing Background Matching Mode permission state: $e');
    }
  }

  bool _shouldRunFullSyncOnResume() {
    final lastFullSyncAt = _lastFullSyncAt;
    if (lastFullSyncAt == null) {
      return true;
    }

    final pausedAt = _lastPausedAt;
    if (pausedAt == null) {
      return false;
    }

    return DateTime.now().difference(pausedAt) >= _resumeFullSyncThreshold;
  }

  Future<void> validateBackgroundMatchingPermission() async {
    if (kIsWeb || !state.backgroundMatchingMode || !Platform.isAndroid) return;

    try {
      final hasBackgroundLocation =
          await PermissionCoordinator.hasBackgroundLocationPermission();
      if (!hasBackgroundLocation) {
        print(
          'Background location permission revoked, disabling Background Matching Mode',
        );
        await setBackgroundMatchingMode(false);
      }
    } catch (e) {
      print('Error validating Background Matching Mode permission: $e');
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
    await setNotificationTypeEnabled(
      NotificationType.adminAnnouncements,
      value,
    );
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
    final untilMsUtc = DateTime.now()
        .toUtc()
        .add(duration)
        .millisecondsSinceEpoch;
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
    state = state.copyWith(
      notifications: state.notifications.copyWith(matrix: next),
    );
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationMethodForAll(
    NotificationMethod method,
    bool value,
  ) async {
    var next = state.notifications.matrix;
    for (final type in NotificationType.values) {
      next = _setMatrixValue(next, type: type, method: method, value: value);
    }
    state = state.copyWith(
      notifications: state.notifications.copyWith(matrix: next),
    );
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
    state = state.copyWith(
      notifications: state.notifications.copyWith(matrix: next),
    );
    await _saveNotificationPreferences();
  }

  Future<void> setGlobalNotificationMethodEnabled(
    NotificationMethod method,
    bool enabled,
  ) async {
    final next = {...state.notifications.globalMethods, method: enabled};
    state = state.copyWith(
      notifications: state.notifications.copyWith(globalMethods: next),
    );
    await _saveNotificationPreferences();
  }

  Future<void> setNotificationTypeEnabled(
    NotificationType type,
    bool enabled,
  ) async {
    bool globalEnabledForMethod(NotificationMethod method) {
      return state.notifications.isGlobalMethodEnabled(method);
    }

    final next = <NotificationType, Map<NotificationMethod, bool>>{
      ...state.notifications.matrix,
      type: {
        for (final m in NotificationMethod.values)
          m: enabled ? globalEnabledForMethod(m) : false,
      },
    };
    state = state.copyWith(
      notifications: state.notifications.copyWith(matrix: next),
    );
    await _saveNotificationPreferences();
  }

  Future<void> _saveNotificationPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final notifs = state.notifications;

      await prefs.setBool(
        _prefsChatNotificationsKey,
        notifs.enableChatNotifications,
      );
      await prefs.setBool(
        _prefsNewMatchNotificationsKey,
        notifs.enableNewMatchNotifications,
      );
      await prefs.setBool(
        _prefsMatchExpiryNotificationsKey,
        notifs.enableMatchExpiryNotifications,
      );
      await prefs.setBool(
        _prefsAdminNotificationsKey,
        notifs.enableAdminNotifications,
      );
      await prefs.setBool(_prefsSoundKey, notifs.enableSound);
      await prefs.setBool(_prefsVibrationKey, notifs.enableVibration);
      await prefs.setBool(
        _prefsInAppNotificationsKey,
        notifs.enableInAppNotifications,
      );
      await prefs.setBool(_prefsGlobalPushKey, notifs.enablePushNotifications);
      await prefs.setBool(
        _prefsGlobalInAppKey,
        notifs.enableInAppNotifications,
      );
      await prefs.setBool(_prefsGlobalSoundKey, notifs.enableSound);
      await prefs.setBool(_prefsGlobalVibrationKey, notifs.enableVibration);
      if (notifs.pausedUntilEpochMsUtc != null) {
        await prefs.setInt(_prefsPausedUntilKey, notifs.pausedUntilEpochMsUtc!);
      } else {
        await prefs.remove(_prefsPausedUntilKey);
      }
      if (notifs.pausedDurationSeconds != null) {
        await prefs.setInt(
          _prefsPausedDurationSecondsKey,
          notifs.pausedDurationSeconds!,
        );
      } else {
        await prefs.remove(_prefsPausedDurationSecondsKey);
      }
      await prefs.setBool(
        _prefsPausedIndefinitelyKey,
        notifs.pausedIndefinitely,
      );
      await prefs.setString(
        _prefsMatrixKey,
        jsonEncode(_matrixToJson(notifs.matrix)),
      );

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
                  'enable_new_match_notifications':
                      notifs.enableNewMatchNotifications,
                  'enable_match_expiry_notifications':
                      notifs.enableMatchExpiryNotifications,
                  'enable_match_extended_notifications':
                      notifs.isMethodEnabled(
                        NotificationType.matchExtended,
                        NotificationMethod.push,
                      ),
                  'enable_admin_notifications': notifs.enableAdminNotifications,
                  'enable_sound': notifs.enableSound,
                  'enable_vibration': notifs.enableVibration,
                  'enable_in_app_notifications':
                      notifs.enableInAppNotifications,
                },
              })
              .eq('id', userId);
        } catch (e) {
          // If sync fails, we've already updated local state
          print('Failed to sync notification preferences: $e');
        }
      }
    } catch (_) {}
  }

  void _ensureRealtimeSubscription() {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) {
      _clearRealtimeSubscription();
      return;
    }
    if (_settingsSubscription != null &&
        _settingsSubscriptionUserId == userId) {
      return;
    }
    _clearRealtimeSubscription();

    final channelName = 'user_settings_$userId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      _settingsSubscription = supabase
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
              final newData = payload.newRecord as Map<String, dynamic>?;
              if (newData == null) return;

              final updatedState = _mergeRealtimeUpdate(newData);
              if (updatedState != state) {
                state = updatedState;
              }
            },
          )
          .subscribe();
      _settingsSubscriptionUserId = userId;
      return _settingsSubscription!;
    });
  }

  UserPreferencesState _mergeRealtimeUpdate(Map<String, dynamic> remoteData) {
    final currentPrefs = state;

    // Extract settings from remote data
    final remoteUnitStr = remoteData['unit_system'] as String?;
    final remoteTimeStr = remoteData['time_format'] as String?;
    final remoteHighAccuracy = remoteData['background_matching_mode'] as bool?;
    final remoteNotifPrefs =
        remoteData['notification_preferences'] as Map<String, dynamic>?;
    final remotePreferredCurrency = _normalizeCurrencyCode(
      remoteData['preferred_currency'] as String?,
    );
    final remoteRecentCurrencies = _sanitizeCurrencyCodeList(
      remoteData['recent_currencies'],
    );

    // Parse notification preferences
    NotificationPreferencesState notifications = currentPrefs.notifications;
    if (remoteNotifPrefs != null) {
      final parsedNotifs = _parseNotificationPreferences(remoteNotifPrefs);
      if (parsedNotifs != null) {
        notifications = parsedNotifs;
      }
    }

    return UserPreferencesState(
      unitSystem: remoteUnitStr != null
          ? _parseUnitSystem(remoteUnitStr) ?? currentPrefs.unitSystem
          : currentPrefs.unitSystem,
      timeFormat: remoteTimeStr != null
          ? _parseTimeFormat(remoteTimeStr) ?? currentPrefs.timeFormat
          : currentPrefs.timeFormat,
      backgroundMatchingMode:
          remoteHighAccuracy ?? currentPrefs.backgroundMatchingMode,
      notifications: notifications,
      preferredCurrency:
          remotePreferredCurrency ?? currentPrefs.preferredCurrency,
      recentCurrencies: remoteRecentCurrencies.isNotEmpty
          ? remoteRecentCurrencies
          : currentPrefs.recentCurrencies,
    );
  }

  static String? _normalizeCurrencyCode(String? value) {
    final code = value?.trim().toUpperCase() ?? '';
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) return null;
    return code;
  }

  static List<String> _sanitizeCurrencyCodeList(dynamic raw) {
    final source = <String>[];
    if (raw is List) {
      for (final item in raw) {
        source.add(item.toString());
      }
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            source.add(item.toString());
          }
        }
      } catch (_) {}
    }

    final out = <String>[];
    for (final item in source) {
      final normalized = _normalizeCurrencyCode(item);
      if (normalized == null || out.contains(normalized)) continue;
      out.add(normalized);
      if (out.length >= 6) break;
    }
    return out;
  }

  static List<String> _buildRecentCurrencyList(
    String selected,
    List<String> existing,
  ) {
    final next = <String>[selected];
    for (final item in existing) {
      final normalized = _normalizeCurrencyCode(item);
      if (normalized == null || next.contains(normalized)) continue;
      next.add(normalized);
      if (next.length >= 6) break;
    }
    return next;
  }

  NotificationPreferencesState? _parseNotificationPreferences(
    Map<String, dynamic> data,
  ) {
    try {
      final matrix = _parseMatrix(data['matrix']);
      final globalMethods = data['global_methods'] as Map<String, dynamic>?;
      final pausedUntilMsUtc = (data['paused_until_ms_utc'] as num?)?.toInt();
      final pausedDurationSeconds = (data['paused_duration_seconds'] as num?)
          ?.toInt();
      final pausedIndefinitely = data['paused_indefinitely'] as bool? ?? false;

      Map<NotificationMethod, bool> parsedGlobalMethods =
          NotificationPreferencesState._defaultGlobalMethods;
      if (globalMethods != null) {
        parsedGlobalMethods = {
          NotificationMethod.push: globalMethods['push'] is bool
              ? globalMethods['push'] as bool
              : true,
          NotificationMethod.inApp: globalMethods['in_app'] is bool
              ? globalMethods['in_app'] as bool
              : true,
          NotificationMethod.sound: globalMethods['sound'] is bool
              ? globalMethods['sound'] as bool
              : true,
          NotificationMethod.vibrate: globalMethods['vibrate'] is bool
              ? globalMethods['vibrate'] as bool
              : true,
        };
      }

      return NotificationPreferencesState(
        matrix: matrix ?? NotificationPreferencesState._defaultMatrix,
        globalMethods: parsedGlobalMethods,
        pausedUntilEpochMsUtc: pausedUntilMsUtc,
        pausedDurationSeconds: pausedDurationSeconds,
        pausedIndefinitely: pausedIndefinitely,
      );
    } catch (_) {
      return null;
    }
  }

  static Map<NotificationType, Map<NotificationMethod, bool>>
  _buildMatrixFromLegacy({
    required bool chatNotifs,
    required bool newMatchNotifs,
    required bool matchExpiryNotifs,
    required bool matchExtendedNotifs,
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
      NotificationType.matchExtended: {
        NotificationMethod.push: matchExtendedNotifs,
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

  static Map<String, dynamic> _matrixToJson(
    Map<NotificationType, Map<NotificationMethod, bool>> matrix,
  ) {
    final out = <String, dynamic>{};
    for (final entry in matrix.entries) {
      out[_notificationTypeKey(entry.key)] = {
        for (final methodEntry in entry.value.entries)
          _notificationMethodKey(methodEntry.key): methodEntry.value,
      };
    }
    return out;
  }

  static Map<NotificationType, Map<NotificationMethod, bool>>? _parseMatrix(
    dynamic raw,
  ) {
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
      final base =
          NotificationPreferencesState._defaultMatrix[type] ??
          const <NotificationMethod, bool>{};
      final override = out[type];
      merged[type] = {...base, ...?override};
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
      type: {...currentType, method: value},
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
    if (state == AppLifecycleState.paused) {
      _lastPausedAt = DateTime.now();
      ResumeDiagnostics.logThrottled(
        'User preferences: app paused',
        category: 'prefs-paused',
        minIntervalMs: 500,
      );
      return;
    }

    if (state == AppLifecycleState.resumed) {
      unawaited(() async {
        final shouldRunFullSync = _shouldRunFullSyncOnResume();
        ResumeDiagnostics.log(
          'User preferences: app resumed, full sync ${shouldRunFullSync ? 'scheduled' : 'skipped'}',
        );

        // Re-establish realtime subscription and reconcile local permission-driven state.
        _ensureRealtimeSubscription();
        await syncBackgroundMatchingPermissionState();
        if (shouldRunFullSync) {
          await _loadFromLocalAndSync();
        }
      }());
    }
  }
}

final userPreferencesProvider =
    NotifierProvider<UserPreferencesNotifier, UserPreferencesState>(
      () => UserPreferencesNotifier(),
    );

/// Provider that exposes only the unit system preference to avoid unnecessary rebuilds
final userUnitSystemProvider = Provider<UnitSystemPreference>(
  (ref) =>
      ref.watch(userPreferencesProvider.select((state) => state.unitSystem)),
);

final userPreferredCurrencyProvider = Provider<String?>(
  (ref) => ref.watch(
    userPreferencesProvider.select((state) => state.preferredCurrency),
  ),
);

final userRecentCurrenciesProvider = Provider<List<String>>(
  (ref) => ref.watch(
    userPreferencesProvider.select((state) => state.recentCurrencies),
  ),
);
