import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/web_notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/utils/offline_utils.dart';

/// Service for handling admin broadcast messages
class AdminBroadcastService {
  /// Lazily resolves the Supabase client so class-load / background-isolate
  /// access never caches a stale instance across re-init/dispose.
  static SupabaseClient get _supabase => Supabase.instance.client;
  static FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  /// True when `Supabase.initialize()` has completed in this isolate.
  ///
  /// The FCM background isolate only calls `Firebase.initializeApp()` —
  /// Supabase is never initialized there — so `Supabase.instance.client`
  /// throws `LateInitializationError: Field 'client' has not been
  /// initialized.` (release) or `AssertionError` (debug). The same can
  /// happen in the UI isolate if a push arrives before bootstrap finishes
  /// or after init failed/timed out (offline-first startup). Callers must
  /// check this before touching [_supabase] and silently skip when false.
  static bool _isSupabaseReady() {
    try {
      return Supabase.instance.isInitialized;
    } catch (_) {
      // Debug builds throw AssertionError from `Supabase.instance` itself
      // when not initialized; release builds would throw
      // LateInitializationError on `.client` — either way: not ready.
      return false;
    }
  }

  /// True for the expected "Supabase not usable in this isolate/state"
  /// errors that must stay silent (background isolate, pre-init push,
  /// failed init, tests) instead of spamming
  /// `📢 Error tracking delivery: LateInitializationError...`.
  static bool _isSupabaseNotReadyError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains("field 'client' has not been initialized") ||
        s.contains('field "client" has not been initialized') ||
        s.contains('lateinitializationerror') ||
        s.contains('you must initialize the supabase instance') ||
        s.contains('supabase.instance');
  }

  static ProviderContainer? _container;
  // Kept for API compat (lifecycle still calls setAppInForeground); OS
  // notifications now fire in foreground AND background/killed by design.
  // ignore: unused_field
  static bool _appInForeground = false;
  static DateTime? _lastReplayAt;
  static const String _prefsBlueShownBroadcastIdsKey =
      'admin_broadcast_blue_shown_ids';

  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  static void setAppInForeground(bool isForeground) {
    _appInForeground = isForeground;
  }

  /// Initialize broadcast message handling
  static void initializeBroadcastHandling() {
    // Handle foreground messages
    FirebaseMessaging.onMessage.listen(_handleBroadcastMessage);

    // Handle background messages (when app is in background but not terminated)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleBroadcastMessageOpened);

    // Handle terminated state messages (when app was completely closed)
    _messaging.getInitialMessage().then((message) {
      if (message != null) {
        _handleBroadcastMessage(message);
      }
    });
  }

  /// Public wrapper for handling broadcast messages.
  ///
  /// [fromBackground] MUST be true when called from the FCM background isolate
  /// (`_firebaseMessagingBackgroundHandler`). In that state Android/FCM has
  /// already drawn the tray entry from the message's `notification` block, so
  /// posting it again from Dart would show the SAME broadcast twice.
  static void handleBroadcastMessage(
    RemoteMessage message, {
    bool fromBackground = false,
  }) {
    _handleBroadcastMessage(message, fromBackground: fromBackground);
  }

  /// Public wrapper for handling broadcast message opens
  static void handleBroadcastMessageOpened(RemoteMessage message) {
    _handleBroadcastMessageOpened(message);
  }

  /// Handle incoming broadcast messages
  static void _handleBroadcastMessage(
    RemoteMessage message, {
    bool fromBackground = false,
  }) {
    final data = message.data;

    // Check if this is an admin broadcast (server uses `type`, be liberal
    // and also accept `kind` so queue + FCM path both match in any UI state).
    final kind = ((data['type'] ?? data['kind']) as Object?)
        ?.toString()
        .trim()
        .toLowerCase();
    if (kind == 'admin_broadcast') {
      print('📢 Received admin broadcast');

      // Extract broadcast details
      final broadcastId = (data['broadcast_id'] ?? data['broadcastId'] ?? '')
          .toString();
      if (broadcastId.trim().isEmpty) return;
      final title =
          (message.notification?.title?.trim().isNotEmpty == true
                  ? message.notification!.title!.trim()
                  : (data['title']?.toString().trim().isNotEmpty == true
                        ? data['title'].toString().trim()
                        : 'Admin Message'))
              .trim();
      final body =
          (message.notification?.body ?? data['body'] ?? data['message'] ?? '')
              .toString();
      final actionUrl = data['action_url']?.toString();
      final actionUrlText = (data['action_url_text'] ?? 'Learn More')
          .toString();

      // Show the broadcast notification to the user
      unawaited(
        _showBroadcastNotification(
          broadcastId: broadcastId,
          title: title,
          body: body,
          actionUrl: actionUrl,
          actionUrlText: actionUrlText,
          shouldShowOsNotification: shouldShowOsNotification(
            message,
            fromBackground: fromBackground,
          ),
        ),
      );

      // Track that we received this broadcast. The FCM background isolate
      // never initializes Supabase (Firebase only), so delivery tracking
      // from there would always throw LateInitializationError — skip it and
      // let the foreground path track when the user opens the app.
      if (!fromBackground) {
        _trackBroadcastDelivery(broadcastId);
      }
    }
  }

  /// Handle when user taps on a broadcast notification
  static void _handleBroadcastMessageOpened(RemoteMessage message) {
    final data = message.data;

    final kind = ((data['type'] ?? data['kind']) as Object?)
        ?.toString()
        .trim()
        .toLowerCase();
    if (kind == 'admin_broadcast') {
      final actionUrl = data['action_url'];

      // If there's an action URL, open it
      if (actionUrl != null && actionUrl.isNotEmpty) {
        _openActionUrl(actionUrl);
      }

      // Track the interaction
      _trackBroadcastInteraction(data['broadcast_id']);
    }
  }

  /// Show broadcast notification to user (can be customized)
  static Future<void> _showBroadcastNotification({
    required String broadcastId,
    required String title,
    required String body,
    String? actionUrl,
    String? actionUrlText,
    required bool shouldShowOsNotification,
  }) async {
    // This is where you would show the notification to the user
    // For now, we'll just log it and you can integrate with your existing notification system
    print('📢 Admin Broadcast: $title - $body');

    if (actionUrl != null) {
      print('📢 Action URL: $actionUrl');
    }

    final container = _container;
    if (container != null) {
      final notifs = container.read(userPreferencesProvider).notifications;
      if (!notifs.isPausedNow &&
          notifs.isMethodEnabled(
            NotificationType.adminAnnouncements,
            NotificationMethod.inApp,
          )) {
        container
            .read(systemNotificationProvider.notifier)
            .notify(
              SystemNotification(
                text: '$title: $body',
                isPersistent: true,
                notificationType: 'admin_broadcast',
                actionUrl: actionUrl,
                actionText: actionUrlText,
              ),
            );
      }
      await _markBlueShown(broadcastId);
    }

    // Only show OS notification if admin notifications are enabled
    if (shouldShowOsNotification && _shouldShowAdminNotification()) {
      await _showOsNotification(
        broadcastId: broadcastId,
        title: title,
        body: body,
        actionUrl: actionUrl,
        actionUrlText: actionUrlText,
      );
    } else if (shouldShowOsNotification) {
      print(
        '📢 Admin notifications disabled - skipping OS notification for broadcast: $broadcastId',
      );
    }
  }

  /// Whether this isolate should post its own tray entry for [message].
  ///
  /// Exposed for tests: `fromBackground` must be set by callers running inside
  /// the FCM background isolate — see `_firebaseMessagingBackgroundHandler`.
  @visibleForTesting
  static bool shouldShowOsNotification(
    RemoteMessage message, {
    bool fromBackground = false,
  }) {
    if (kIsWeb) return true;
    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!isMobile) return false;
    // Foreground (UI isolate): FCM never draws a banner itself, so Dart must
    // post the tray entry — the old `message.notification == null` gate wrongly
    // suppressed these.
    //
    // Background/killed (background isolate): the Android/FCM SDK ALREADY
    // displayed the message's `notification` block (every admin push is
    // notification+data), so posting it a second time from Dart is a duplicate:
    // the OS entry carries `tag=admin_<broadcast_id>` while
    // flutter_local_notifications posts under `broadcastId.hashCode()` with no
    // tag, so Android cannot collapse them and the user sees the same
    // broadcast twice. Only data-only pushes need a Dart-side post here.
    if (fromBackground && message.notification != null) return false;
    return true;
  }

  static Future<void> _showOsNotification({
    required String broadcastId,
    required String title,
    required String body,
    String? actionUrl,
    String? actionUrlText,
  }) async {
    try {
      if (kIsWeb) {
        await WebNotificationService.showAdminBroadcastNotification(
          title: title,
          message: body,
          notificationId: broadcastId,
        );
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        await MobileLocalNotificationService.showAdminBroadcastNotification(
          broadcastId: broadcastId,
          title: title,
          body: body,
          actionUrl: actionUrl,
          actionUrlText: actionUrlText,
        );
      }
    } catch (_) {}
  }

  static Future<void> replayPendingBlueNotifications({int limit = 10}) async {
    final now = DateTime.now();
    final last = _lastReplayAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastReplayAt = now;

    final container = _container;
    if (container == null) return;

    // Background isolate / pre-init / failed-init: Supabase has no client
    // here — accessing it throws LateInitializationError. Silently skip;
    // the next foreground launch replays pending broadcasts.
    if (!_isSupabaseReady()) return;
    String? userId;
    try {
      userId = _supabase.auth.currentUser?.id;
    } catch (e) {
      if (_isSupabaseNotReadyError(e)) return;
      rethrow;
    }
    if (userId == null || userId.trim().isEmpty) return;

    Set<String> shown = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      shown =
          (prefs.getStringList(_prefsBlueShownBroadcastIdsKey) ??
                  const <String>[])
              .where((e) => e.trim().isNotEmpty)
              .toSet();
    } catch (_) {}

    final recent = await getRecentBroadcasts(limit: limit);
    BroadcastMessage? candidate;
    for (final b in recent) {
      if (!shown.contains(b.broadcastId)) {
        candidate = b;
        break;
      }
    }
    if (candidate == null) return;

    final notifs = container.read(userPreferencesProvider).notifications;
    if (!notifs.isPausedNow &&
        notifs.isMethodEnabled(
          NotificationType.adminAnnouncements,
          NotificationMethod.inApp,
        )) {
      container
          .read(systemNotificationProvider.notifier)
          .notify(
            SystemNotification(
              text: '${candidate.title}: ${candidate.message}',
              isPersistent: true,
              notificationType: 'admin_broadcast',
              actionUrl: candidate.actionUrl,
              actionText: candidate.actionUrlText,
            ),
          );
    }
    await _markBlueShown(candidate.broadcastId);
  }

  static Future<void> _markBlueShown(String broadcastId) async {
    final trimmed = broadcastId.trim();
    if (trimmed.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final existing =
          prefs.getStringList(_prefsBlueShownBroadcastIdsKey) ?? <String>[];
      final next = <String>[trimmed, ...existing.where((e) => e != trimmed)];
      final capped = next.length > 200 ? next.sublist(0, 200) : next;
      await prefs.setStringList(_prefsBlueShownBroadcastIdsKey, capped);
    } catch (_) {}
  }

  /// Open action URL from broadcast
  static Future<void> _openActionUrl(String url) async {
    try {
      final uri = Uri.parse(url);

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        print('📢 Opened action URL: $url');
      } else {
        print('📢 Could not launch URL: $url');
      }
    } catch (e) {
      print('📢 Error opening URL: $e');
    }
  }

  /// Track broadcast delivery in database
  static Future<void> _trackBroadcastDelivery(String? broadcastId) async {
    if (broadcastId == null) return;

    if (shouldSkipSupabaseCalls()) return;

    // Supabase is never initialized in the FCM background isolate and may
    // not be ready yet (or at all, after a failed/timed-out init) in the
    // UI isolate. Touching `.client` then throws
    // `LateInitializationError: Field 'client' has not been initialized.`
    if (!_isSupabaseReady()) return;

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      // Mark this broadcast as delivered for this user
      await _supabase
          .from('admin_broadcast_deliveries')
          .update({
            'delivery_status': 'delivered',
            'delivered_at': DateTime.now().toIso8601String(),
          })
          .eq('broadcast_id', broadcastId)
          .eq('user_id', userId);

      print('📢 Tracked delivery for broadcast: $broadcastId');
    } catch (e) {
      // Expected when Supabase isn't usable in this isolate/state
      // (background isolate, pre-init push, disposed client, tests) —
      // stay silent instead of spamming the log.
      if (_isSupabaseNotReadyError(e)) return;
      print('📢 Error tracking delivery: $e');
    }
  }

  /// Track user interaction with broadcast
  static Future<void> _trackBroadcastInteraction(String? broadcastId) async {
    if (broadcastId == null) return;

    try {
      // You can add additional tracking here if needed
      print('📢 Tracked interaction for broadcast: $broadcastId');
    } catch (e) {
      print('📢 Error tracking interaction: $e');
    }
  }

  /// Check if admin notifications should be shown
  static bool _shouldShowAdminNotification() {
    final container = _container;
    if (container == null) return true; // Default to enabled if no container
    try {
      final prefs = container.read(userPreferencesProvider);
      final notifs = prefs.notifications;
      if (notifs.isPausedNow) return false;
      return notifs.isMethodEnabled(
        NotificationType.adminAnnouncements,
        NotificationMethod.push,
      );
    } catch (_) {
      return true; // Default to enabled on error
    }
  }

  /// Get recent broadcasts for the current user
  static Future<List<BroadcastMessage>> getRecentBroadcasts({
    int limit = 10,
    Set<String> deliveryStatuses = const {'sent', 'delivered'},
  }) async {
    if (shouldSkipSupabaseCalls()) return [];
    if (!_isSupabaseReady()) return [];

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return [];

      final response = await _supabase
          .from('admin_broadcast_deliveries')
          .select('''
            broadcast_id,
            delivered_at,
            delivery_status,
            admin_broadcasts!inner(
              title,
              message,
              message_type,
              action_url,
              action_url_text,
              sent_at
            )
          ''')
          .eq('user_id', userId)
          .inFilter('delivery_status', deliveryStatuses.toList())
          .order('created_at', ascending: false)
          .limit(limit);

      final result = <BroadcastMessage>[];
      for (final json in response) {
        result.add(BroadcastMessage.fromJson(json));
      }
      return result;
    } catch (e) {
      // Auth/RLS failures (dead refresh token, 42501) are expected when the
      // session is revoked — fall back to [] silently instead of spamming
      // logs on every rebuild. See refresh_token_already_used storm.
      // Same for uninitialized Supabase (background isolate / pre-init race).
      if (_isSupabaseNotReadyError(e)) return [];
      if (!isExpectedOfflineFailure(e) && !isAuthRateLimitFailure(e)) {
        print('📢 Error getting recent broadcasts: $e');
      }
      return [];
    }
  }
}

/// Model for broadcast messages
class BroadcastMessage {
  final String broadcastId;
  final String title;
  final String message;
  final String messageType;
  final DateTime sentAt;
  final DateTime? deliveredAt;
  final String? actionUrl;
  final String? actionUrlText;
  final String deliveryStatus;

  BroadcastMessage({
    required this.broadcastId,
    required this.title,
    required this.message,
    required this.messageType,
    required this.sentAt,
    this.deliveredAt,
    this.actionUrl,
    this.actionUrlText,
    required this.deliveryStatus,
  });

  factory BroadcastMessage.fromJson(Map<String, dynamic> json) {
    final broadcast = json['admin_broadcasts'] as Map<String, dynamic>;

    return BroadcastMessage(
      broadcastId: json['broadcast_id'] ?? '',
      title: broadcast['title'] ?? '',
      message: broadcast['message'] ?? '',
      messageType: broadcast['message_type'] ?? 'info',
      sentAt: DateTime.parse(
        broadcast['sent_at'] ?? DateTime.now().toIso8601String(),
      ),
      deliveredAt: json['delivered_at'] != null
          ? DateTime.parse(json['delivered_at'])
          : null,
      actionUrl: broadcast['action_url'],
      actionUrlText: broadcast['action_url_text'],
      deliveryStatus: json['delivery_status'] ?? 'unknown',
    );
  }
}
