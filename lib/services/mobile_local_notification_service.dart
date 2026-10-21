import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_badge_service.dart';
import 'package:matchme/utils/notification_channels.dart';
import 'package:matchme/utils/notification_limits.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class MobileLocalNotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;
  static ProviderContainer? _container;

  static String? _currentViewingChatId;
  static final Map<String, List<String>> _messageHistory = {};
  static final Map<String, int> _lastNotifiedChatIds = {};
  static final RegExp _rtlScriptRegex = RegExp(r'[\u0590-\u08FF]');

  // Strong LTR scripts (Latin, Latin Extended, etc.). Used together with
  // _rtlScriptRegex to find the first strong character and decide the
  // paragraph direction for mixed LTR/RTL notification text.
  static final RegExp _strongLtrRegex =
      RegExp(r'[A-Za-z\u00C0-\u024F\u1E00-\u1EFF\u0370-\u03FF\u0400-\u04FF]');

  // Bidi control characters that mean the text's directionality has already
  // been explicitly handled (isolate / embedding / override marks and their
  // terminators). If any are present, do not add another outer wrap.
  static final RegExp _bidiHandledRegex =
      RegExp(r'[\u2066\u2067\u2068\u2069\u202A\u202B\u202C\u202D\u202E]');

  /// Set the ProviderContainer to access preferences
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  static String _chatNotificationTitle({
    required String senderName,
    required String messageContent,
  }) {
    final rtl =
        _rtlScriptRegex.hasMatch(senderName) ||
        _rtlScriptRegex.hasMatch(messageContent);
    // Isolate the sender name so a name in the opposite direction of the
    // template (e.g. an English name in the Hebrew title) doesn't scramble
    // the surrounding sentence.
    final isolatedName = _bidiIsolate(senderName);
    if (rtl) {
      return '💬 הודעה חדשה מ-$isolatedName';
    }
    return '💬 New message from $isolatedName';
  }

  /// Wrap [value] in Unicode bidi isolation marks (FSI/PDI) so an embedded
  /// name/label of opposite directionality does not scramble the surrounding
  /// sentence. Mirrors the server-side `bidiIsolate` helper.
  static String _bidiIsolate(String value) {
    final s = value;
    if (s.isEmpty) return s;
    return '\u2068$s\u2069';
  }

  static String _wrapRtlIfNeeded(String text) {
    final s = text;
    if (s.isEmpty) return s;
    // If the text already carries explicit bidi handling (e.g. server-side
    // FSI/PDI isolation around an embedded RTL name), leave it untouched so we
    // don't override the isolation with a paragraph-level wrap.
    if (_bidiHandledRegex.hasMatch(s)) return s;
    if (!_rtlScriptRegex.hasMatch(s)) return s;
    // Decide the paragraph direction from the FIRST strong character, not from
    // the mere presence of RTL characters. An English/Spanish template with an
    // embedded Hebrew name must stay LTR; only a notification that genuinely
    // starts with an RTL script (e.g. a fully Hebrew notification) gets wrapped
    // in RLI so Android renders it right-to-left.
    final firstStrong = _firstStrongCharacter(s);
    if (firstStrong == null) return s;
    if (_rtlScriptRegex.hasMatch(firstStrong)) {
      return '\u2067$s\u2069';
    }
    return s;
  }

  /// Returns the first character of [s] that is a strong LTR or RTL character,
  /// or `null` if the string has no strong characters (only neutrals/numbers).
  static String? _firstStrongCharacter(String s) {
    for (final rune in s.runes) {
      final ch = String.fromCharCode(rune);
      if (_rtlScriptRegex.hasMatch(ch) || _strongLtrRegex.hasMatch(ch)) {
        return ch;
      }
    }
    return null;
  }

  static Future<void> initialize() async {
    if (kIsWeb) return;
    await ensureInitialized();
  }

  /// iOS only: true when a delivered notification whose threadIdentifier (or
  /// identifier) equals [threadKey] is still in Notification Center. The
  /// server sets `thread-id`/`apns-collapse-id` to the event tag
  /// (push-message, cron-jobs), so this detects "the server card for this
  /// event is already sitting there" — the iOS analog of the tray checks the
  /// Android background service performs natively. Plugin-created local
  /// cards never carry a thread identifier, so they can't false-positive.
  static Future<bool> hasDeliveredServerNotification(String threadKey) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return false;
    final key = threadKey.trim();
    if (key.isEmpty) return false;
    try {
      await ensureInitialized();
      final active = await _notificationsPlugin.getActiveNotifications();
      return active.any((n) => n.groupKey == key);
    } catch (_) {
      return false;
    }
  }

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (kIsWeb) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_matchme');

    const DarwinInitializationSettings iosSettings =
        DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: true,
          requestSoundPermission: true,
        );

    // Windows (flutter_local_notifications_windows): the plugin registers
    // this AUMID + COM activator GUID in the registry on init, so toasts
    // work from an unpackaged (non-MSIX) desktop build too. In the MSIX
    // build the AUMID must equal the package's Application User Model ID —
    // <Package/Identity/Name>!<AppId> from Partner Center (EAmir.MatchMeApp
    // !App) — or local toasts fail to attribute to the package. cancel() and
    // getActiveNotifications() stay no-ops without MSIX, which is fine —
    // the tray checks those APIs gate on are already iOS/Android-only.
    const WindowsInitializationSettings windowsSettings =
        WindowsInitializationSettings(
          appName: 'matchme',
          appUserModelId: 'EAmir.MatchMeApp!App',
          guid: 'b2f7c1a4-8e3d-4c6b-9f2a-7d5e8b1c3a90',
        );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
      windows: windowsSettings,
    );

    await _notificationsPlugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _requestPermissions();

    // Pre-create every channel the server can target with HIGH importance.
    // FCM system-tray pushes (killed/off/reboot) reference channelId directly;
    // if the channel doesn't exist yet Android falls back to default
    // importance and heads-up is lost. Matches server channelIdForType +
    // push-message channel mapping.
    try {
      final android = _notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        for (final c in const [
          (
            'chat_messages',
            'Chat Messages',
            'Notifications for new chat messages and matches',
          ),
          (
            'match_expiry_alerts',
            'Match Expiry Alerts',
            'Notifications for expiring matches',
          ),
          (
            'location_sharing',
            'Location Sharing',
            'Live location sharing notifications',
          ),
        ]) {
          try {
            await android.createNotificationChannel(
              AndroidNotificationChannel(
                c.$1,
                c.$2,
                description: c.$3,
                importance: Importance.high,
              ),
            );
          } catch (_) {}
        }

        // One admin-broadcast channel per alert-preference combination: the
        // server picks the channel from the user's stored preference and FCM
        // passes the id straight through, so each id must already exist here —
        // otherwise Android falls back to default importance/alerting.
        for (final id in AdminBroadcastChannels.all) {
          try {
            await android.createNotificationChannel(
              AndroidNotificationChannel(
                id,
                AdminBroadcastChannels.name(id),
                description: AdminBroadcastChannels.description(id),
                importance: AdminBroadcastChannels.isSilent(id)
                    ? Importance.defaultImportance
                    : Importance.high,
                playSound: AdminBroadcastChannels.playsSound(id),
                enableVibration: AdminBroadcastChannels.vibrates(id),
              ),
            );
          } catch (_) {}
        }
      }
    } catch (_) {}

    _initialized = true;
  }

  /// Match ids already tray-buzzed this process lifetime (foreground FCM
  /// and any other caller share this entry point). A match buzzes at most
  /// once here — redeliveries and realtime+FCM doubles for the same match
  /// are dropped. Native persisted dedup covers restarts; extensions and
  /// expiry use separate methods/ids and are unaffected.
  static final Set<String> _shownNewMatchIds = <String>{};

  /// New-match OS notification on the chat channel (server uses
  /// `chat_messages` for `kind=match`, so foreground must match the tray).
  static Future<void> showNewMatchNotification({
    required String matchId,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();
    if (!_shouldShowNewMatchNotification()) return;
    final id = matchId.trim();
    if (id.isNotEmpty) {
      if (_shownNewMatchIds.contains(id)) return;
      if (_shownNewMatchIds.length >= 200) {
        _shownNewMatchIds.remove(_shownNewMatchIds.first);
      }
      _shownNewMatchIds.add(id);
      // Cross-path dedupe (mirrors the Android native contract): the match
      // may already have been alerted by another path — the prefs mirror, a
      // server banner delivered while the app was killed (iOS). Either way
      // this card must stay silent.
      SharedPreferences? dedupePrefs;
      try {
        dedupePrefs = await SharedPreferences.getInstance();
      } catch (_) {}
      if (dedupePrefs?.getString('flutter.last_notified_match_id') == id) {
        return;
      }
      if (await hasDeliveredServerNotification('new_match_$id')) {
        try {
          await dedupePrefs?.setString('flutter.last_notified_match_id', id);
          await dedupePrefs?.setString(
            'flutter.worker_last_notified_key',
            'match:$id',
          );
        } catch (_) {}
        return;
      }
    }
    final soundEnabled = _isSoundEnabledForType(NotificationType.newMatch);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.newMatch,
    );
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages and matches',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        playSound: soundEnabled,
        enableVibration: vibrationEnabled,
        // Publishes the current unread count on the card itself. This is a
        // supplement to the app-icon badge (the carrier notification and the
        // OEM launcher APIs own that), for launchers that read the number off
        // the newest notification.
        number: _badgeNumber(),
        // Same tag the server push and the native background-service dedup
        // key on: the Kotlin poller checks the tray for "new_match_<id>"
        // before posting its own fallback card, so this foreground card must
        // carry the tag too or the poller would stack a duplicate after the
        // app is backgrounded with the match still unread.
        tag: 'new_match_$matchId',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: soundEnabled),
    );
    final enforced = enforceTitleBody(title, body);
    await _notificationsPlugin.show(
      id: 'new_match_$matchId'.hashCode,
      title: _wrapRtlIfNeeded(enforced.title),
      body: _wrapRtlIfNeeded(enforced.body),
      notificationDetails: details,
      payload: matchId,
    );
    // Best-effort: share the native one-buzz-per-match key so the background
    // service and the WorkManager fallback stay quiet for this match even
    // after the tray card is dismissed. Non-sensitive key → plain prefs,
    // which is exactly where the Kotlin side reads it.
    if (id.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('flutter.last_notified_match_id', id);
        await prefs.setString('flutter.worker_last_notified_key', 'match:$id');
      } catch (_) {}
    }
  }

  static bool _shouldShowNewMatchNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.newMatch,
      NotificationMethod.push,
    );
  }

  /// OS notification for "the other person extended this match".
  ///
  /// Shares the chat channel (same as new-match) because it is a match-lifecycle
  /// event, but is gated on its own NotificationType so users can turn it off
  /// without silencing new matches. Uses a distinct id and tag so an extension
  /// never overwrites (or is overwritten by) the new-match card for the same
  /// match — a user can be mid-banner when the extension lands.
  static Future<void> showMatchExtendedNotification({
    required String matchId,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();
    final notifs = _getNotifs();
    if (notifs != null && notifs.isPausedNow) return;
    if (notifs != null &&
        !notifs.isMethodEnabled(
          NotificationType.matchExtended,
          NotificationMethod.push,
        )) {
      return;
    }
    final soundEnabled = notifs == null
        ? true
        : notifs.isMethodEnabled(
            NotificationType.matchExtended,
            NotificationMethod.sound,
          );
    final vibrationEnabled = notifs == null
        ? true
        : notifs.isMethodEnabled(
            NotificationType.matchExtended,
            NotificationMethod.vibrate,
          );
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages and matches',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        playSound: soundEnabled,
        enableVibration: vibrationEnabled,
        number: _badgeNumber(),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: soundEnabled),
    );
    final enforced = enforceTitleBody(title, body);
    await _notificationsPlugin.show(
      id: 'match_extended_$matchId'.hashCode,
      title: _wrapRtlIfNeeded(enforced.title),
      body: _wrapRtlIfNeeded(enforced.body),
      notificationDetails: details,
      payload: matchId,
    );
  }

  static Future<void> _requestPermissions() async {
    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static void _onNotificationTapped(NotificationResponse response) {
    final payload = (response.payload ?? '').trim();
    if (payload.isEmpty) return;

    final lower = payload.toLowerCase();
    final isHttpUrl =
        lower.startsWith('https://') || lower.startsWith('http://');
    if (!isHttpUrl) return;

    final uri = Uri.tryParse(payload);
    if (uri == null) return;

    unawaited(() async {
      try {
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      } catch (_) {}
    }());
  }

  static Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String messageContent,
    required String matchId,
    String? messageId,
    bool alreadyAggregated = false,
    bool? shouldAlertOverride,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    // Check if chat notifications are enabled
    if (!_shouldShowChatNotification()) {
      debugPrint('Chat notifications disabled - skipping notification');
      return;
    }

    // Cross-path dedupe (mirrors the Android native contract): the message
    // may already have surfaced on this device — the server push's banner is
    // still delivered (iOS) after a killed-app delivery, or this exact
    // message already produced a local card before a restart. Either way the
    // local card must stay silent.
    final trimmedMessageId = messageId?.trim() ?? '';
    SharedPreferences? dedupePrefs;
    if (trimmedMessageId.isNotEmpty) {
      try {
        dedupePrefs = await SharedPreferences.getInstance();
      } catch (_) {}
      if (dedupePrefs?.getString('flutter.last_notified_message_id') ==
          trimmedMessageId) {
        return;
      }
      if (await hasDeliveredServerNotification('match_$chatId')) {
        try {
          await dedupePrefs?.setString(
            'flutter.last_notified_message_id',
            trimmedMessageId,
          );
          await dedupePrefs?.setString(
            'flutter.worker_last_notified_key',
            'msg:$trimmedMessageId',
          );
        } catch (_) {}
        return;
      }
    }

    // Foreground (including iOS resumed / Android maximized) still shows a
    // tray notification unless the user is actively viewing this chat.
    // The old code dropped ALL iOS foreground chat notifications.
    final isViewingChat = _currentViewingChatId == chatId;

    final history = _messageHistory.putIfAbsent(chatId, () => []);
    if (!alreadyAggregated) {
      if (messageContent.trim().isNotEmpty &&
          (history.isEmpty || history.last != messageContent)) {
        history.add(messageContent);
      }
      if (history.length > 5) history.removeAt(0);
    }

    if (isViewingChat) {
      debugPrint('Skipping local notification - currently viewing chat');
      return;
    }

    final shouldAlert = shouldAlertOverride ?? (_lastNotifiedChatIds[chatId] == null);
    final soundEnabled = _isSoundEnabledForType(NotificationType.chatMessages);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.chatMessages,
    );

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages',
        importance: shouldAlert ? Importance.high : Importance.low,
        priority: shouldAlert ? Priority.high : Priority.low,
        showWhen: true,
        playSound: shouldAlert && soundEnabled,
        enableVibration: shouldAlert && vibrationEnabled,
        number: _badgeNumber(),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: shouldAlert,
        presentBadge: true,
        presentSound: shouldAlert && soundEnabled,
        sound: (shouldAlert && soundEnabled) ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: shouldAlert && soundEnabled),
    );

    // Transport/display guard: truncate history to byte budget so 5 long
    // user messages can't overflow the tray (FCM 4096B, display ~800B).
    var joined = alreadyAggregated ? messageContent : history.join('\n');
    final capped = truncateUtf8Bytes(joined, NotifLimits.chatHistoryMaxBytes);
    joined = capped.text;
    final safeSender = maskFullName(senderName);
    final enforced = enforceTitleBody(
      _chatNotificationTitle(senderName: safeSender, messageContent: joined),
      joined,
    );
    final title = _wrapRtlIfNeeded(enforced.title);
    final body = _wrapRtlIfNeeded(enforced.body);

    await _notificationsPlugin.show(
      id: chatId.hashCode,
      title: title,
      body: body,
      notificationDetails: details,
      payload: chatId,
    );

    if (shouldAlert) {
      _lastNotifiedChatIds[chatId] = 1;
    }
    // Share the Android-native one-buzz-per-message keys so a restart (or
    // the native poll, where present) never re-buzzes this exact message.
    if (dedupePrefs != null && trimmedMessageId.isNotEmpty) {
      try {
        await dedupePrefs.setString(
          'flutter.last_notified_message_id',
          trimmedMessageId,
        );
        await dedupePrefs.setString(
          'flutter.worker_last_notified_key',
          'msg:$trimmedMessageId',
        );
      } catch (_) {}
    }
    debugPrint('Local notification shown (alert=$shouldAlert)');
  }

  static void setViewingChat(String chatId) {
    _currentViewingChatId = chatId;
    debugPrint('Local notification: Set viewing chat');
    // Persist so the FCM background isolate and the native
    // MatchMeBackgroundService (post-reboot/killed) can suppress
    // notifications for the open chat without UI state.
    unawaited(_persistViewingChatId(chatId));
  }

  static void clearViewingChat() {
    _currentViewingChatId = null;
    debugPrint('Local notification: Cleared viewing chat');
    unawaited(_persistViewingChatId(null));
  }

  /// SharedPreferences mirror of the open chat, readable from the
  /// background isolate, native service, and boot receiver.
  static Future<void> _persistViewingChatId(String? chatId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (chatId == null || chatId.isEmpty) {
        await prefs.remove('flutter.viewing_chat_id');
        await prefs.remove('viewing_chat_id');
      } else {
        await prefs.setString('flutter.viewing_chat_id', chatId);
        await prefs.setString('viewing_chat_id', chatId);
      }
    } catch (_) {}
  }

  /// Read by the background isolate when in-memory state is unavailable.
  static Future<String?> readPersistedViewingChatId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('flutter.viewing_chat_id');
      if (v != null && v.trim().isNotEmpty) return v.trim();
      final legacy = prefs.getString('viewing_chat_id');
      return (legacy == null || legacy.trim().isEmpty) ? null : legacy.trim();
    } catch (_) {
      return null;
    }
  }

  /// Entering a chat makes its tray entry stale: cancel the tray card and
  /// drop history so follow-ups start fresh. Global badge is left to the
  /// server (next push overwrites APNs badge); local clear would wipe other
  /// chats' counts.
  static void resetChatNotification(String chatId) {
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId);
    debugPrint('Local notification: Reset state for chat');
    if (!kIsWeb) {
      unawaited(_notificationsPlugin.cancel(id: chatId.hashCode));
    }
  }

  static Future<void> dismissChatNotification(String chatId) async {
    if (kIsWeb) return;
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId);
    try {
      await _notificationsPlugin.cancel(id: chatId.hashCode);
      debugPrint('Local notification: Dismissed notification');
    } catch (e) {
      debugPrint('Local notification: Failed to dismiss notification: $e');
    }
  }

  /// Clear every tray entry + icon badge (logout / inbox zero).
  static Future<void> cancelAll() async {
    if (kIsWeb) return;
    _lastNotifiedChatIds.clear();
    _messageHistory.clear();
    try {
      await _notificationsPlugin.cancelAll();
    } catch (_) {}
    try {
      await AppBadgeService.clear();
    } catch (_) {}
  }

  static String? get currentViewingChatId => _currentViewingChatId;

  static NotificationPreferencesState? _getNotifs() {
    final container = _container;
    if (container == null) return null;
    try {
      final prefs = container.read(userPreferencesProvider);
      return prefs.notifications;
    } catch (_) {
      return null;
    }
  }

  /// Unread count published on the notification itself.
  ///
  /// `null` leaves the number to the launcher (its default is the number of
  /// active notifications). Whenever the inbox has reported a count, the card
  /// carries the same value the app-icon badge uses, so a launcher that reads
  /// the number off the newest notification cannot disagree with the badge.
  static int? _badgeNumber() {
    final count = AppBadgeService.currentCount;
    return count > 0 ? count : null;
  }

  /// Check if chat notifications should be shown
  static bool _shouldShowChatNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.chatMessages,
      NotificationMethod.push,
    );
  }

  /// Check if match expiry notifications should be shown
  static bool _shouldShowMatchExpiryNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.expiringMatch,
      NotificationMethod.push,
    );
  }

  /// Check if admin notifications should be shown
  static bool _shouldShowAdminNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.adminAnnouncements,
      NotificationMethod.push,
    );
  }

  static bool _isSoundEnabledForType(NotificationType type) {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(type, NotificationMethod.sound);
  }

  static bool _isVibrationEnabledForType(NotificationType type) {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(type, NotificationMethod.vibrate);
  }

  /// Windows has no channels/vibration — sound on/off is the only per-type
  /// preference that maps. Silent when the user turned sound off so toasts
  /// respect the same settings as the other platforms.
  static WindowsNotificationDetails _windowsDetails({
    required bool soundEnabled,
  }) {
    return WindowsNotificationDetails(
      audio: soundEnabled
          ? WindowsNotificationAudio.preset(
              sound: WindowsNotificationSound.im,
            )
          : WindowsNotificationAudio.silent(),
    );
  }

  static Future<void> showMatchExpiryNotification({
    required String matchId,
    required String title,
    required String body,
    String? notificationKey,
    String? serverTag,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    // Check if match expiry notifications are enabled
    if (!_shouldShowMatchExpiryNotification()) {
      print(
        'Match expiry notifications disabled - skipping notification for match: $matchId',
      );
      return;
    }

    // The server push for this exact warning may already be delivered (e.g.
    // drawn while the app was killed) — that card IS the notification.
    if (serverTag != null && await hasDeliveredServerNotification(serverTag)) {
      return;
    }

    final soundEnabled = _isSoundEnabledForType(NotificationType.expiringMatch);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.expiringMatch,
    );

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'match_expiry_alerts',
        'Match Expiry Alerts',
        channelDescription: 'Notifications for expiring matches',
        importance: Importance.high,
        priority: Priority.high,
        showWhen: true,
        playSound: soundEnabled,
        enableVibration: vibrationEnabled,
        number: _badgeNumber(),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: soundEnabled),
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);

    await _notificationsPlugin.show(
      id: (notificationKey == null ? matchId : '$matchId:$notificationKey')
          .hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      payload: matchId,
    );
  }

  static Future<void> showAdminBroadcastNotification({
    required String broadcastId,
    required String title,
    required String body,
    String? actionUrl,
    String? actionUrlText,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    // Check if admin notifications are enabled
    if (!_shouldShowAdminNotification()) {
      print('Admin notifications disabled - skipping broadcast: $broadcastId');
      return;
    }

    final soundEnabled = _isSoundEnabledForType(
      NotificationType.adminAnnouncements,
    );
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.adminAnnouncements,
    );
    // Android 8+ ignores the per-notification playSound/enableVibration flags
    // and uses the channel's settings, so the channel must match the pref.
    final channelId = AdminBroadcastChannels.idFor(
      soundEnabled: soundEnabled,
      vibrateEnabled: vibrationEnabled,
    );
    final isSilentChannel = AdminBroadcastChannels.isSilent(channelId);

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        AdminBroadcastChannels.name(channelId),
        channelDescription: AdminBroadcastChannels.description(channelId),
        importance: isSilentChannel
            ? Importance.defaultImportance
            : Importance.high,
        priority: isSilentChannel ? Priority.defaultPriority : Priority.high,
        showWhen: true,
        playSound: soundEnabled,
        enableVibration: vibrationEnabled,
        number: _badgeNumber(),
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: soundEnabled),
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);

    await _notificationsPlugin.show(
      id: broadcastId.hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      payload: actionUrl?.trim().isEmpty == false ? actionUrl : broadcastId,
    );
  }

  static Future<void> showLocationShareNotification({
    required String notificationId,
    required String title,
    required String body,
    bool silent = false,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    if (!_shouldShowLocationShareNotification()) {
      return;
    }

    final soundEnabled =
        !silent && _isSoundEnabledForType(NotificationType.locationSharing);
    final vibrationEnabled =
        !silent && _isVibrationEnabledForType(NotificationType.locationSharing);

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'location_sharing',
        'Location Sharing',
        channelDescription: 'Live location sharing notifications',
        importance: silent ? Importance.defaultImportance : Importance.high,
        priority: silent ? Priority.defaultPriority : Priority.high,
        showWhen: true,
        playSound: soundEnabled,
        enableVibration: vibrationEnabled,
        // The live countdown re-posts this notification every second.
        // Without this, Android replays the channel's sound/vibration on
        // every update; with it, only the first post alerts.
        onlyAlertOnce: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: !silent,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
      windows: _windowsDetails(soundEnabled: soundEnabled),
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);

    await _notificationsPlugin.show(
      id: notificationId.hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      payload: notificationId,
    );
  }

  /// Removes the location share OS notification with the given id.
  static Future<void> cancelLocationShareNotification({
    required String notificationId,
  }) async {
    if (kIsWeb) return;
    try {
      await ensureInitialized();
      await _notificationsPlugin.cancel(id: notificationId.hashCode);
    } catch (_) {}
  }

  /// Whether a location share notification with this id is currently visible
  /// in the tray. Used by the per-second live-countdown updater to detect
  /// that the user cleared the notification, so it stops re-posting it.
  ///
  /// Returns true if the check can't be performed (unsupported platform or
  /// error), which keeps the previous update behavior.
  static Future<bool> isLocationShareNotificationActive({
    required String notificationId,
  }) async {
    if (kIsWeb) return true;
    try {
      await ensureInitialized();
      final activeNotifications = await _notificationsPlugin
          .getActiveNotifications();
      return activeNotifications.any((n) => n.id == notificationId.hashCode);
    } catch (_) {
      return true;
    }
  }

  static bool _shouldShowLocationShareNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.locationSharing,
      NotificationMethod.push,
    );
  }
}
