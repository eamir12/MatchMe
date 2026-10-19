import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// OS-scheduled match-expiry countdown.
///
/// **Android / iOS**: the server expiry push owns the tray card. It is a
/// notification+data message, so the OS draws it even when the app is killed
/// — on Android with tag `match_expiry_<matchId>_<thr>` and id 0 (the FCM
/// SDK's identity), on iOS with `apns-collapse-id` (which becomes the
/// delivered notification's identifier/thread). A local alarm can never
/// share those identities (this plugin's scheduler keys pending alarms by id
/// alone), so scheduling one would guarantee a second, non-collapsible tray
/// entry for the same event. On these platforms the service therefore only
/// *cancels* alarms (legacy builds scheduled them) and never posts; the
/// in-app scan / foreground handler still show their card when they
/// legitimately win the shared dedupe gate, and they additionally verify the
/// server card isn't already delivered before posting.
///
/// **Desktop**: no OS-level collapse with the server push exists, so the
/// schedule fallback stays. The in-app timer (`home_providers`) and server
/// FCM cover foreground and most background cases, but a *killed* app with a
/// stale FCM token (or a Doze-deferred data push) can still miss the live
/// countdown. These `zonedSchedule` alarms are registered with the OS, so
/// they fire even when the Dart isolate is dead — no network, no token, no
/// cron tick required.
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

  /// Deterministic alarm id parsed back out of a stored `expiry_sched_` key
  /// (`<prefix><matchId>_<thresholdSec>_<expiryMs>`). Covers alarms that were
  /// registered but whose stored id entry is missing (crash between
  /// schedule and persist) — cancel(id:) also clears a posted card.
  static int? _alarmIdFromKey(String key, String matchId) {
    try {
      final rest = key.substring(_keyPrefix.length + matchId.length + 1);
      final parts = rest.split('_');
      if (parts.length != 2) return null;
      final thresholdSec = int.tryParse(parts[0]);
      final expiryMs = int.tryParse(parts[1]);
      if (thresholdSec == null || expiryMs == null) return null;
      return _alarmId(matchId, thresholdSec, expiryMs);
    } catch (_) {
      return null;
    }
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
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      // The server push owns expiry tray cards on mobile (see class doc):
      // never schedule, and actively cancel anything a previous build left
      // pending so it can't double the server card when it fires.
      await cancelForMatch(id);
      return;
    }
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
            final parsedId = _alarmIdFromKey(k, id);
            if (parsedId != null && parsedId != oldId) {
              await _plugin.cancel(id: parsedId);
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

  /// Server-side notification identity for an expiry event. cron-jobs and
  /// push-message build it as `<type>_<key>_<thresholdSeconds>` (key is the
  /// match id, or the user id for pinned-location expiry) and send it as the
  /// Android `tag`, the APNs `apns-collapse-id`/`thread-id`, and the web
  /// push `tag`. Client paths use it to detect / drop the server card for an
  /// event they already surfaced (or are about to).
  static String serverCardTag({
    required String kind,
    required String key,
    required int thresholdSeconds,
  }) => '${kind}_${key}_$thresholdSeconds';

  /// Dedupe key shared by every path that can surface a match-expiry
  /// warning (in-app scan, foreground FCM handler): exactly one notification
  /// per (match, threshold, exact expiry window) no matter which fired first.
  static String warnPrefsKey({
    required String matchId,
    required int thresholdSeconds,
    required int expiryMs,
    String templateVersion = 'match_expiry_minutes_v2',
  }) =>
      'match_chat_start_expiry_warned_'
      '${matchId}_${thresholdSeconds}_${expiryMs}_$templateVersion';

  /// Cancel only the alarm for one (match, threshold, expiry) — pending or
  /// already posted. Used when another path (server FCM push / in-app card)
  /// already surfaced that exact warning, so the OS alarm must not add a
  /// second tray entry for the same event.
  static Future<void> cancelThreshold({
    required String matchId,
    required int thresholdSeconds,
    required int expiryMs,
  }) async {
    if (kIsWeb) return;
    final id = matchId.trim();
    if (id.isEmpty) return;
    final deterministicId = _alarmId(id, thresholdSeconds, expiryMs);
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_keyPrefix${id}_${thresholdSeconds}_$expiryMs';
      final storedId = prefs.getInt(key);
      try {
        if (storedId != null) {
          await _plugin.cancel(id: storedId);
        }
      } catch (_) {}
      try {
        await prefs.remove(key);
      } catch (_) {}
      // Deterministic id covers alarms already fired (or re-synced) whose
      // stored entry was cleared: cancel() also removes a posted card.
      if (storedId != deterministicId) {
        try {
          await _plugin.cancel(id: deterministicId);
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
          final parsedId = _alarmIdFromKey(k, id);
          if (parsedId != null && parsedId != alarmId) {
            await _plugin.cancel(id: parsedId);
          }
        } catch (_) {}
        try {
          await prefs.remove(k);
        } catch (_) {}
      }
    } catch (_) {}
  }
}
