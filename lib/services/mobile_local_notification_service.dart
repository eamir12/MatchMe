import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_badge_service.dart';
import 'package:matchme/services/notification_avatar_service.dart';
import 'package:matchme/utils/chat_notification_copy.dart';
import 'package:matchme/utils/meetup_alert_card.dart';
import 'package:matchme/utils/notification_channels.dart';
import 'package:matchme/utils/notification_copy_source.dart';
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

  /// Handler for in-app route payloads ('/chat/<id>', '/meetup/<id>' and
  /// '/meetup/<id>/plan'). Installed by main.dart, which owns the navigator
  /// key.
  static void Function(String route)? onOpenRoute;
  static final RegExp _rtlScriptRegex = RegExp(r'[\u0590-\u08FF]');

  // Strong LTR scripts (Latin, Latin Extended, etc.). Used together with
  // _rtlScriptRegex to find the first strong character and decide the
  // paragraph direction for mixed LTR/RTL notification text.
  static final RegExp _strongLtrRegex = RegExp(
    r'[A-Za-z\u00C0-\u024F\u1E00-\u1EFF\u0370-\u03FF\u0400-\u04FF]',
  );

  // Bidi control characters that mean the text's directionality has already
  // been explicitly handled (isolate / embedding / override marks and their
  // terminators). If any are present, do not add another outer wrap.
  static final RegExp _bidiHandledRegex = RegExp(
    r'[\u2066\u2067\u2068\u2069\u202A\u202B\u202C\u202D\u202E]',
  );

  /// Set the ProviderContainer to access preferences
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
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

  /// True while the Android match card is still visible, whether its most
  /// recent renderer was the app or a legacy tagged FCM push.
  static Future<bool> isNewMatchNotificationActive(String matchId) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    final id = matchId.trim();
    if (id.isEmpty) return false;
    try {
      await ensureInitialized();
      final active = await _notificationsPlugin.getActiveNotifications();
      return active.any(
        (notification) =>
            notification.id == cardIdForPlatform(id) ||
            notification.tag == 'new_match_$id',
      );
    } catch (error) {
      debugPrint('Local notification: Could not inspect match card: $error');
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
      macOS: iosSettings,
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
          (
            'meetup_alerts',
            'Meet-up alerts',
            'Waves, beacons, Spot me cards and meeting-point updates',
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
    bool silent = false,
    bool dedupeAlreadyClaimed = false,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
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
      if (!dedupeAlreadyClaimed) {
        // Cross-path dedupe (mirrors the Android native contract): the match
        // may already have been alerted by another path — the prefs mirror, a
        // server banner delivered while the app was killed (iOS). Either way
        // this card must stay silent.
        SharedPreferences? dedupePrefs;
        try {
          dedupePrefs = await SharedPreferences.getInstance();
        } catch (_) {}
        final alreadyRecorded =
            dedupePrefs?.getString('flutter.last_notified_match_id') == id;
        final hasServerCard = await hasDeliveredServerNotification(
          'new_match_$id',
        );
        final hasActiveCard = await isNewMatchNotificationActive(id);
        if (alreadyRecorded || hasServerCard || hasActiveCard) {
          if (hasActiveCard) {
            silent = true;
          } else if (hasServerCard) {
            try {
              await dedupePrefs?.setString(
                'flutter.last_notified_match_id',
                id,
              );
              await dedupePrefs?.setString(
                'flutter.worker_last_notified_key',
                'match:$id',
              );
            } catch (_) {}
            return;
          } else {
            return;
          }
        }
      }
    }
    final soundEnabled = _isSoundEnabledForType(NotificationType.newMatch);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.newMatch,
    );
    final avatarPath = await _avatarPath(
      matchId,
      photoSource: avatarPhotoSource,
    );
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages and matches',
        importance: silent ? Importance.defaultImportance : Importance.high,
        priority: silent ? Priority.defaultPriority : Priority.high,
        showWhen: true,
        playSound: !silent && soundEnabled,
        enableVibration: !silent && vibrationEnabled,
        // Match cards can race the native poller; updates to their shared ID
        // must not produce a second banner or buzz.
        silent: silent,
        onlyAlertOnce: true,
        // Joins the conversation group whose summary carries the unread badge
        // (MatchMeBadgeController). Deliberately no `number` here: numeric
        // launchers *sum* the number of every active notification, so a card
        // that repeats the badge count doubles it.
        groupKey: NotificationGroups.chats,
        groupAlertBehavior: GroupAlertBehavior.children,
        largeIcon: _androidAvatar(avatarPath),
      ),
      iOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      macOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      windows: _windowsDetails(
        soundEnabled: soundEnabled,
        avatarPath: avatarPath,
      ),
    );
    final enforced = enforceTitleBody(title, body);
    await beforeShow?.call();
    await _notificationsPlugin.show(
      id: cardIdForPlatform(id),
      title: _wrapRtlIfNeeded(enforced.title),
      body: _wrapRtlIfNeeded(enforced.body),
      notificationDetails: details,
      payload: '/chat/$matchId',
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
    bool silent = false,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
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
    final avatarPath = await _avatarPath(
      matchId,
      photoSource: avatarPhotoSource,
    );
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages and matches',
        importance: silent ? Importance.defaultImportance : Importance.high,
        priority: silent ? Priority.defaultPriority : Priority.high,
        showWhen: true,
        playSound: !silent && soundEnabled,
        enableVibration: !silent && vibrationEnabled,
        // Replaces a card the system already announced — the face yes, a second
        // banner or buzz no.
        silent: silent,
        groupKey: NotificationGroups.chats,
        groupAlertBehavior: GroupAlertBehavior.children,
        largeIcon: _androidAvatar(avatarPath),
      ),
      iOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      macOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      windows: _windowsDetails(
        soundEnabled: soundEnabled,
        avatarPath: avatarPath,
      ),
    );
    final enforced = enforceTitleBody(title, body);
    await beforeShow?.call();
    await _notificationsPlugin.show(
      id: 'match_extended_$matchId'.hashCode,
      title: _wrapRtlIfNeeded(enforced.title),
      body: _wrapRtlIfNeeded(enforced.body),
      notificationDetails: details,
      payload: '/chat/$matchId',
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

    // In-app routes posted by this service (for example the meet-up tools'
    // foreground cards). main.dart owns the navigator, so it installs the
    // handler instead of this service importing the app entry point.
    if (payload.startsWith('/')) {
      try {
        onOpenRoute?.call(payload);
      } catch (_) {}
      return;
    }

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

  /// Show the conversation card iOS or Windows posts for itself.
  ///
  /// [card] is the copy the server computed for this recipient; when the push
  /// carried it, the card repeats the server. Otherwise it is built from the
  /// lines this device holds, with the server's two rules applied - unread total
  /// in the title, no quoted text once the backlog is more than one message -
  /// so an iOS banner, a Windows toast, a browser tray entry and the Android
  /// card say the same thing about the same conversation.
  ///
  /// Local notifications use the mirrored face where the platform supports
  /// attachments or local toast images. Remote notifications shown directly by
  /// APNs or WNS cannot read this app-local mirror; iOS needs a configured
  /// notification service extension, and WNS needs an image URI available to
  /// the toast renderer.
  ///
  /// [silent] is the Android background case: this card replaces one the system
  /// already drew and announced, so it joins the shade with the sender's face
  /// and adds neither a second banner nor a second buzz.
  static Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String messageContent,
    required String matchId,
    String? messageId,
    bool alreadyAggregated = false,
    bool? shouldAlertOverride,
    ChatPushCardModel? card,
    int? unreadCount,
    bool silent = false,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
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

    final shouldAlert =
        shouldAlertOverride ?? (_lastNotifiedChatIds[chatId] == null);
    final soundEnabled = _isSoundEnabledForType(NotificationType.chatMessages);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.chatMessages,
    );

    final safeSender = maskFullName(senderName);
    final previewsEnabled =
        card?.previewsEnabled ?? messagePreviewsEnabled(_container);
    // The server's total wins: it counts messages this device never saw. A
    // locally-signalled message counts the lines this device holds, which is
    // the same window the member reads in the chat list.
    final count =
        card?.unreadCount ??
        unreadCount ??
        (history.isEmpty ? 1 : history.length);
    // An aggregated push that carried no card of its own still carries its
    // body, and that body already stands for the whole batch.
    final served =
        card ??
        (alreadyAggregated && messageContent.trim().isNotEmpty
            ? ChatPushCardModel(body: messageContent.trim())
            : null);
    final model = buildChatNotificationCard(
      unreadCount: count,
      previewsEnabled: previewsEnabled,
      candidateLines: history,
      forms: chatCardForms(_container, safeSender),
      payload: served,
    );

    final avatarPath = await _avatarPath(
      matchId,
      photoSource: avatarPhotoSource,
    );
    // The expanded card is the same window the native service builds when it
    // owns this chat: the server's unread lines, newest tail, no repeats of the
    // body. One line is the body itself, so a style would only repeat it.
    final lines = model.previewLines;
    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'chat_messages',
        'Chat Messages',
        channelDescription: 'Notifications for new chat messages',
        // Three shapes of one card: a fresh event this card announces (banner
        // and buzz), a follow-up the server muted (shade only, the prominence
        // the native path has always given it), and a silent replacement of a
        // card the system already announced (shade only, at the same
        // prominence the system's own entry had).
        importance: shouldAlert && !silent
            ? Importance.high
            : silent
            ? Importance.defaultImportance
            : Importance.low,
        priority: shouldAlert && !silent
            ? Priority.high
            : silent
            ? Priority.defaultPriority
            : Priority.low,
        showWhen: true,
        playSound: shouldAlert && !silent && soundEnabled,
        enableVibration: shouldAlert && !silent && vibrationEnabled,
        // Same reasoning as the expiry card: when this post replaces a card
        // the system already announced, the tray entry must stay quiet. On
        // 31+ this is the only flag that overrides a sounding channel.
        silent: silent || !shouldAlert,
        groupKey: NotificationGroups.chats,
        groupAlertBehavior: GroupAlertBehavior.children,
        largeIcon: _androidAvatar(avatarPath),
        styleInformation: lines.length > 1
            ? InboxStyleInformation(lines, contentTitle: model.title)
            : null,
      ),
      iOS: _darwinDetails(
        soundEnabled: shouldAlert && soundEnabled,
        presentAlert: shouldAlert,
        avatarPath: avatarPath,
      ),
      macOS: _darwinDetails(
        soundEnabled: shouldAlert && soundEnabled,
        presentAlert: shouldAlert,
        avatarPath: avatarPath,
      ),
      windows: _windowsDetails(
        soundEnabled: shouldAlert && soundEnabled,
        avatarPath: avatarPath,
        altText: safeSender,
      ),
    );

    final title = _wrapRtlIfNeeded(model.title);
    final body = _wrapRtlIfNeeded(model.body);

    await beforeShow?.call();
    // Android ids are shared with `MatchMeBackgroundService` and the
    // WorkManager fallback, which both post this chat as
    // `chatId.hashCode()` in Java's space. A Dart-side hash would be a second
    // tray entry for the same conversation.
    await _notificationsPlugin.show(
      id: cardIdForPlatform(chatId),
      title: title,
      body: body,
      notificationDetails: details,
      // The route the SDK card's tap produced (`push-message` data → `/chat/…`
      // in `_applyNavigationFromPushData`), so tapping this card lands in the
      // same place a tap on the card it replaced did.
      payload: '/chat/$chatId',
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
      unawaited(_notificationsPlugin.cancel(id: cardIdForPlatform(chatId)));
    }
  }

  static Future<void> dismissChatNotification(String chatId) async {
    if (kIsWeb) return;
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId);
    try {
      await _notificationsPlugin.cancel(id: cardIdForPlatform(chatId));
      // The FCM SDK's card for this chat is a separate tray entry - id 0,
      // tagged with the push's collapse key - and the native dismiss path
      // drops that too, so entering a chat clears whichever card currently
      // represents it.
      if (defaultTargetPlatform == TargetPlatform.android) {
        await cancelServerCard(tag: 'match_$chatId');
      }
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
  ///
  /// [avatarPath] is a file this app already holds - see
  /// [NotificationAvatarService.resolvePath]. A toast resolves its own images
  /// from a URI and cannot be handed bytes, and an https URL only works in an
  /// MSIX-packaged build. No path, no face: the card posts without one.
  static WindowsNotificationDetails _windowsDetails({
    required bool soundEnabled,
    String? avatarPath,
    String? altText,
  }) {
    final audio = soundEnabled
        ? WindowsNotificationAudio.preset(sound: WindowsNotificationSound.im)
        : WindowsNotificationAudio.silent();
    final avatar = _windowsAvatar(avatarPath, altText: altText);
    return avatar == null
        ? WindowsNotificationDetails(audio: audio)
        : WindowsNotificationDetails(audio: audio, images: [avatar]);
  }

  static DarwinNotificationDetails _darwinDetails({
    required bool soundEnabled,
    bool presentAlert = true,
    String? avatarPath,
  }) {
    final path = (avatarPath ?? '').trim();
    return DarwinNotificationDetails(
      presentAlert: presentAlert,
      presentBadge: true,
      presentSound: soundEnabled,
      sound: soundEnabled ? 'default' : null,
      attachments: path.isEmpty
          ? null
          : [DarwinNotificationAttachment(path, hideThumbnail: false)],
    );
  }

  static WindowsImage? _windowsAvatar(String? path, {String? altText}) {
    final file = (path ?? '').trim();
    if (file.isEmpty) return null;
    final name = (altText ?? '').trim();
    return WindowsImage(
      Uri.file(file, windows: true),
      altText: name.isEmpty ? 'Profile photo' : name,
      placement: WindowsImagePlacement.appLogoOverride,
      crop: WindowsImageCrop.circle,
    );
  }

  /// The mirrored face of the conversation [matchId], or null when it has none.
  ///
  /// Android's `largeIcon` and a toast's image are both plain local files, so
  /// every card - chat, match, expiry, location, meet-up - draws the same face
  /// from the same one mirror, in the foreground or from the FCM background
  /// isolate, and no photo is ever published.
  static Future<String?> _avatarPath(
    String matchId, {
    String? photoSource,
  }) async {
    final source = (photoSource ?? '').trim();
    if (source.isNotEmpty) {
      await NotificationAvatarService.instance.mirrorFor(
        matchId: matchId,
        photoSource: source,
      );
    }
    return NotificationAvatarService.instance.resolvePath(matchId);
  }

  static AndroidBitmap<String>? _androidAvatar(String? path) =>
      path == null ? null : FilePathAndroidBitmap(path);

  /// Retire the card the FCM SDK drew for a push, addressed by the collapse tag
  /// the push carried - the only identity that card has.
  ///
  /// The SDK always posts it as `(id 0, tag <collapse key>)`, so the
  /// notification plugin can cancel it directly. That matters because the FCM
  /// background isolate registers real plugin classes only: our own
  /// `matchme/background_service` channel has no handler there, and a card
  /// posted from that isolate could never retire the SDK's duplicate.
  static Future<void> cancelServerCard({required String tag}) async {
    final trimmed = tag.trim();
    if (kIsWeb || trimmed.isEmpty) return;
    try {
      await ensureInitialized();
      await _notificationsPlugin.cancel(id: 0, tag: trimmed);
    } catch (_) {}
  }

  static Future<void> showMatchExpiryNotification({
    required String matchId,
    required String title,
    required String body,
    String? notificationKey,
    String? serverTag,
    bool silent = false,
    String? tapRoute,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
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

    final avatarPath = await _avatarPath(
      matchId,
      photoSource: avatarPhotoSource,
    );

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'match_expiry_alerts',
        'Match Expiry Alerts',
        channelDescription: 'Notifications for expiring matches',
        importance: silent ? Importance.defaultImportance : Importance.high,
        priority: silent ? Priority.defaultPriority : Priority.high,
        showWhen: true,
        playSound: !silent && soundEnabled,
        enableVibration: !silent && vibrationEnabled,
        // A replacement for a card the system already announced follows the
        // native service's convention for that case: no second banner, no
        // second buzz — the entry stays in the shade, which is where the face
        // is visible. `silent` is what carries that on 31+, where the channel's
        // own sound cannot be overridden any other way.
        silent: silent,
        largeIcon: _androidAvatar(avatarPath),
      ),
      iOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      macOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
      windows: _windowsDetails(
        soundEnabled: soundEnabled,
        avatarPath: avatarPath,
      ),
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);

    await beforeShow?.call();
    await _notificationsPlugin.show(
      id: (notificationKey == null ? matchId : '$matchId:$notificationKey')
          .hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      // A card that replaces the server's own carries the tap destination that
      // card had; a bare id leaves the app where it was, as before.
      payload: tapRoute ?? matchId,
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
    required String matchId,
    required String title,
    required String body,
    bool silent = false,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
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

    final avatarPath = await _avatarPath(
      matchId,
      photoSource: avatarPhotoSource,
    );

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
        // A replacement for the card the system already announced adds no
        // second banner and no second buzz; `silent` is what carries that on
        // 31+, where a sounding channel cannot be overridden any other way.
        silent: silent,
        largeIcon: _androidAvatar(avatarPath),
      ),
      iOS: _darwinDetails(
        soundEnabled: soundEnabled,
        presentAlert: !silent,
        avatarPath: avatarPath,
      ),
      macOS: _darwinDetails(
        soundEnabled: soundEnabled,
        presentAlert: !silent,
        avatarPath: avatarPath,
      ),
      windows: _windowsDetails(
        soundEnabled: soundEnabled,
        avatarPath: avatarPath,
      ),
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);

    await beforeShow?.call();
    await _notificationsPlugin.show(
      id: notificationId.hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      // Same destination the push this card replaces produced: the share lives
      // in the conversation, and the SDK card's tap landed there.
      payload: '/chat/$matchId',
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

  static Future<void> showMeetupNotification({
    required String notificationId,
    required String title,
    required String body,
    String? matchId,
    String? kind,
    Duration? expiresIn,
    bool silent = false,
    String? avatarPhotoSource,
    Future<void> Function()? beforeShow,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    if (!_shouldShowMeetupNotification()) return;

    final soundEnabled = _isSoundEnabledForType(NotificationType.meetupTools);
    final vibrationEnabled = _isVibrationEnabledForType(
      NotificationType.meetupTools,
    );

    final enforced = enforceTitleBody(title, body);
    final finalTitle = _wrapRtlIfNeeded(enforced.title);
    final finalBody = _wrapRtlIfNeeded(enforced.body);
    final route = (matchId ?? '').trim();
    // Proposal and place-change cards open the planning screen, where the
    // accept/counter decision lives; every other kind opens the hub.
    final isDecision =
        kind == kMeetupAlertProposal || kind == kMeetupAlertPlaceChange;
    final timeoutAfter = expiresIn != null && expiresIn.inMilliseconds > 0
        ? expiresIn.inMilliseconds
        : null;

    final avatarPath = await _avatarPath(
      matchId ?? '',
      photoSource: avatarPhotoSource,
    );
    await beforeShow?.call();

    Future<void> post({required bool withChime}) => _notificationsPlugin.show(
      id: notificationId.hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'meetup_alerts',
          'Meet-up alerts',
          channelDescription:
              'Waves, beacons, Spot me cards and meeting-point updates',
          importance: Importance.high,
          priority: Priority.high,
          showWhen: true,
          playSound: !silent && soundEnabled,
          enableVibration: !silent && vibrationEnabled,
          // Per-notification sound overrides the channel, so existing installs
          // get the distinct chime without a channel-id bump.
          sound: soundEnabled && withChime && !silent
              ? const RawResourceAndroidNotificationSound('meetup_chime')
              : null,
          // When this card replaces the one the system drew for the same
          // signal, it must not announce it again: on 31+ this is what
          // overrides a sounding channel. Unlike the quieter card types, this
          // one keeps its full banner — a wave or a beacon is read in seconds,
          // and the entry that carries the face should be the one on screen.
          silent: silent,
          // A tool the recipient never acted on stops being news once its live
          // window closes: the system drops the card at the TTL even when this
          // process is gone and no sweep can run.
          timeoutAfter: timeoutAfter,
          largeIcon: _androidAvatar(avatarPath),
        ),
        iOS: _darwinDetails(soundEnabled: soundEnabled, avatarPath: avatarPath),
        macOS: _darwinDetails(
          soundEnabled: soundEnabled,
          avatarPath: avatarPath,
        ),
        windows: _windowsDetails(
          soundEnabled: soundEnabled,
          avatarPath: avatarPath,
        ),
      ),
      payload: route.isEmpty
          ? notificationId
          : (isDecision ? '/meetup/$route/plan' : '/meetup/$route'),
    );

    try {
      await post(withChime: true);
    } catch (_) {
      // The chime is cosmetic, but a build that does not carry it makes the
      // plugin throw before the card is ever posted — which used to swallow
      // meet-up alerts whole. Losing the sound beats losing the alert.
      await post(withChime: false);
    }
  }

  /// Removes the meet-up tool card posted under [cardKey] — the same key
  /// `showMeetupNotification` used. Called when the event stops being news:
  /// the recipient opened the tool, or its live window closed.
  static Future<void> cancelMeetupCard({required String cardKey}) async {
    if (kIsWeb) return;
    try {
      await ensureInitialized();
      await _notificationsPlugin.cancel(id: cardKey.hashCode);
    } catch (_) {}
  }

  static bool _shouldShowMeetupNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.meetupTools,
      NotificationMethod.push,
    );
  }
}
