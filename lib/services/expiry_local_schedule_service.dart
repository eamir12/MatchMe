import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// OS-scheduled match-expiry countdown.
///
/// The in-app timer (`home_providers`) and server FCM cover foreground and
/// most background cases, but a *killed* app with a stale FCM token (or a
/// Doze-deferred data push) can still miss the live countdown. These
/// `zonedSchedule` alarms are registered with the OS, so they fire even when
/// the Dart isolate is dead — no network, no token, no cron tick required.
///
/// One alarm per (match, threshold, exact expiry). The expiry timestamp is
/// part of the key so an extension cancels stale alarms and re-arms the new
/// window. Alarms are cancelled when the chat starts or the match expires.
class ExpiryLocalScheduleService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _tzInit = false;

  static const String _keyPrefix = 'expiry_sched_';

  static Future<void> _ensureTimezones() async {
    if (_tzInit) return;
    try {
      tz_data.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        final name = info.identifier.trim();
        if (name.isNotEmpty) {
          tz.setLocalLocation(tz.getLocation(name));
        }
      } catch (_) {}
      _tzInit = true;
    } catch (_) {}
  }

  static int _alarmId(String matchId, int thresholdSec, int expiryMs) {
    return '$matchId:$thresholdSec:$expiryMs:expiry'.hashCode;
  }

  /// Schedule future threshold alarms for [matchId] expiring at [expiryAt].
  /// Thresholds whose fire time already passed are skipped (the immediate
  /// in-app/FCM path already handled them). Stale alarms from a previous
  /// expiry window are cancelled.
  static Future<void> syncMatchExpiry({
    required String matchId,
    required DateTime expiryAt,
    required List<Duration> thresholds,
    required String Function(int minutesLeft) titleFor,
    required String Function(int minutesLeft) bodyFor,
  }) async {
    if (kIsWeb) return;
    final id = matchId.trim();
    if (id.isEmpty) return;
    try {
      await _ensureTimezones();
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final expiryMs = expiryAt.millisecondsSinceEpoch;
      final wanted = <String, ({int alarmId, int thresholdSec})>{};
      for (final t in thresholds) {
        if (t <= Duration.zero) continue;
        final fireAt = expiryAt.subtract(t);
        if (!fireAt.isAfter(now.add(const Duration(seconds: 60)))) continue;
        final key = '$_keyPrefix${id}_${t.inSeconds}_$expiryMs';
        wanted[key] = (
          alarmId: _alarmId(id, t.inSeconds, expiryMs),
          thresholdSec: t.inSeconds,
        );
      }
      // Cancel stale alarms for this match (old expiry window / removed
      // thresholds) that are not in the wanted set.
      try {
        final stale = prefs
            .getKeys()
            .where(
              (k) =>
                  k.startsWith('$_keyPrefix${id}_') && !wanted.containsKey(k),
            )
            .toList();
        for (final k in stale) {
          try {
            final oldId = prefs.getInt(k);
            if (oldId != null) {
              await _plugin.cancel(id: oldId);
            }
          } catch (_) {}
          try {
            await prefs.remove(k);
          } catch (_) {}
        }
      } catch (_) {}
      // Schedule wanted alarms not already stored.
      for (final entry in wanted.entries) {
        try {
          if (prefs.containsKey(entry.key)) continue;
          final thrSec = entry.value.thresholdSec;
          final minutesLeft = thrSec <= 0
              ? 1
              : ((thrSec / 60).ceil().clamp(1, 100000));
          final fireAt = expiryAt.subtract(Duration(seconds: thrSec));
          final details = const NotificationDetails(
            android: AndroidNotificationDetails(
              'match_expiry_alerts',
              'Match Expiry Alerts',
              channelDescription: 'Notifications for expiring matches',
              importance: Importance.high,
              priority: Priority.high,
              showWhen: true,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          );
          await _plugin.zonedSchedule(
            id: entry.value.alarmId,
            title: titleFor(minutesLeft),
            body: bodyFor(minutesLeft),
            scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
            notificationDetails: details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            payload: id,
          );
          await prefs.setInt(entry.key, entry.value.alarmId);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Cancel every scheduled alarm for [matchId] (chat started / expired).
  static Future<void> cancelForMatch(String matchId) async {
    if (kIsWeb) return;
    final id = matchId.trim();
    if (id.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs
          .getKeys()
          .where((k) => k.startsWith('$_keyPrefix${id}_'))
          .toList();
      for (final k in keys) {
        try {
          final alarmId = prefs.getInt(k);
          if (alarmId != null) {
            await _plugin.cancel(id: alarmId);
          }
        } catch (_) {}
        try {
          await prefs.remove(k);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
