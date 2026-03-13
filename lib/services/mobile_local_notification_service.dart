import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
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

  /// Set the ProviderContainer to access preferences
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  static String _chatNotificationTitle({
    required String senderName,
    required String messageContent,
  }) {
    final rtl = _rtlScriptRegex.hasMatch(senderName) || _rtlScriptRegex.hasMatch(messageContent);
    if (rtl) {
      return '💬 הודעה חדשה מ-$senderName';
    }
    return '💬 New message from $senderName';
  }

  static String _wrapRtlIfNeeded(String text) {
    final s = text;
    if (s.isEmpty) return s;
    if (!_rtlScriptRegex.hasMatch(s)) return s;
    if (s.contains('\u2067') || s.contains('\u2066') || s.contains('\u202B')) {
      return s;
    }
    return '\u2067$s\u2069';
  }

  static Future<void> initialize() async {
    if (kIsWeb) return;
    await ensureInitialized();
  }

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    if (kIsWeb) return;

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notificationsPlugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    await _requestPermissions();

    _initialized = true;
  }

  static Future<void> _requestPermissions() async {
    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
  }

  static void _onNotificationTapped(NotificationResponse response) {
    final payload = (response.payload ?? '').trim();
    if (payload.isEmpty) return;

    final lower = payload.toLowerCase();
    final isHttpUrl = lower.startsWith('https://') || lower.startsWith('http://');
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
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    if (defaultTargetPlatform == TargetPlatform.iOS &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      debugPrint('Skipping iOS foreground local notification for chat: $chatId');
      return;
    }

    // Check if chat notifications are enabled
    if (!_shouldShowChatNotification()) {
      debugPrint('Chat notifications disabled - skipping notification for chat: $chatId');
      return;
    }

    final isViewingChat = _currentViewingChatId == chatId;

    final history = _messageHistory.putIfAbsent(chatId, () => []);
    history.add(messageContent);
    if (history.length > 5) history.removeAt(0);

    if (isViewingChat) {
      debugPrint('Skipping local notification - currently viewing chat: $chatId');
      return;
    }

    final shouldAlert = _lastNotifiedChatIds[chatId] == null;
    final soundEnabled = _isSoundEnabledForType(NotificationType.chatMessages);
    final vibrationEnabled = _isVibrationEnabledForType(NotificationType.chatMessages);

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
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: shouldAlert && soundEnabled,
        sound: (shouldAlert && soundEnabled) ? 'default' : null,
      ),
    );

    final title = _wrapRtlIfNeeded(
      _chatNotificationTitle(senderName: senderName, messageContent: messageContent),
    );
    final body = _wrapRtlIfNeeded(history.join('\n'));

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
    debugPrint('Local notification shown for chat: $chatId (alert=$shouldAlert)');
  }

  static void setViewingChat(String chatId) {
    _currentViewingChatId = chatId;
    debugPrint('Local notification: Set viewing chat to $chatId');
  }

  static void clearViewingChat() {
    _currentViewingChatId = null;
    debugPrint('Local notification: Cleared viewing chat');
  }

  static void resetChatNotification(String chatId) {
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId);
    debugPrint('Local notification: Reset state for chat $chatId');
  }

  static Future<void> dismissChatNotification(String chatId) async {
    if (kIsWeb) return;
    try {
      await _notificationsPlugin.cancel(id: chatId.hashCode);
      debugPrint('Local notification: Dismissed notification for chat $chatId');
    } catch (e) {
      debugPrint('Local notification: Failed to dismiss notification for chat $chatId: $e');
    }
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
    return notifs.isMethodEnabled(NotificationType.chatMessages, NotificationMethod.push);
  }

  /// Check if match expiry notifications should be shown
  static bool _shouldShowMatchExpiryNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(NotificationType.expiringMatch, NotificationMethod.push);
  }

  /// Check if admin notifications should be shown
  static bool _shouldShowAdminNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.push);
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

  static Future<void> showMatchExpiryNotification({
    required String matchId,
    required String title,
    required String body,
    String? notificationKey,
  }) async {
    if (kIsWeb) return;
    await ensureInitialized();

    // Check if match expiry notifications are enabled
    if (!_shouldShowMatchExpiryNotification()) {
      debugPrint('Match expiry notifications disabled - skipping notification for match: $matchId');
      return;
    }

    final soundEnabled = _isSoundEnabledForType(NotificationType.expiringMatch);
    final vibrationEnabled = _isVibrationEnabledForType(NotificationType.expiringMatch);

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
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
        sound: soundEnabled ? 'default' : null,
      ),
    );

    final finalTitle = _wrapRtlIfNeeded(title);
    final finalBody = _wrapRtlIfNeeded(body);

    await _notificationsPlugin.show(
      id: (notificationKey == null ? matchId : '$matchId:$notificationKey').hashCode,
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
      debugPrint('Admin notifications disabled - skipping broadcast: $broadcastId');
      return;
    }

    final soundEnabled = _isSoundEnabledForType(NotificationType.adminAnnouncements);
    final vibrationEnabled = _isVibrationEnabledForType(NotificationType.adminAnnouncements);

    final NotificationDetails details = NotificationDetails(
      android: AndroidNotificationDetails(
        'admin_broadcasts',
        'Admin Broadcasts',
        channelDescription: 'Admin broadcast announcements',
        importance: Importance.high,
        priority: Priority.high,
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
    );

    final finalTitle = _wrapRtlIfNeeded(title);
    final finalBody = _wrapRtlIfNeeded(body);

    await _notificationsPlugin.show(
      id: broadcastId.hashCode,
      title: finalTitle,
      body: finalBody,
      notificationDetails: details,
      payload: actionUrl?.trim().isEmpty == false ? actionUrl : broadcastId,
    );
  }
}
