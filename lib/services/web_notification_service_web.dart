// lib/services/web_notification_service_web.dart
// Web-specific implementation using package:web

import 'dart:async';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/meetup_alerts_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/utils/chat_notification_copy.dart';
import 'package:matchme/utils/notification_copy_source.dart';
import 'package:matchme/utils/notification_limits.dart';

/// Web notification service that provides similar functionality to mobile notifications
/// Uses the browser's Notification API for web platforms
class WebNotificationService {
  static bool _isSupported = false;
  static ProviderContainer? _container;
  /// Handler for route payloads from clicked cards ('/meetup/<id>' and
  /// '/meetup/<id>/plan'). Installed by main.dart, which owns the navigator.
  static void Function(String route)? onOpenRoute;
  static String? _currentViewingChatId;
  static final Map<String, List<String>> _messageHistory = {};
  static final Map<String, int> _lastNotifiedChatIds = {};
  // The conversation's picture, once a caller has named it. Kept so a card that
  // arrives from a push - which knows the chat, not the photo - still shows the
  // face the member has already seen.
  static final Map<String, String> _avatarSources = {};
  static final Map<String, web.Notification> _activeChatNotifications = {};
  // Live-countdown location share notification state. Tracks the most recent
  // notification so per-second silent updates can replace it via the same
  // tag, and whether the user dismissed it (so updates don't resurrect it).
  static web.Notification? _lastLocationShareNotification;
  static bool _locationShareDismissed = false;
  static final Set<web.Notification> _expectedLocationShareCloses =
      <web.Notification>{};

  /// Set the ProviderContainer to access preferences
  static void setProviderContainer(ProviderContainer container) {
    _container = container;
  }

  /// Initialize web notifications
  static Future<void> initialize() async {
    if (!kIsWeb) return;

    try {
      // Accessing a static property to check existence/support
      web.Notification.permission;
      _isSupported = true;
    } catch (e) {
      _isSupported = false;
      return;
    }

    if (_isSupported) {
      // Check current permission status
      // Use JS interop comparison
      final currentPermission = web.Notification.permission;

      // Request permission if not already granted
      if (currentPermission != 'granted') {
        try {
          final permission = await web.Notification.requestPermission().toDart;
          _isSupported = permission.toDart == 'granted';
        } catch (_) {
          _isSupported = false;
        }
      }
    }
  }

  /// Check if web notifications are supported and permitted
  static bool get isSupported =>
      _isSupported && web.Notification.permission == 'granted';

  /// Force re-request permission (useful for debugging)
  static Future<String> requestPermission() async {
    if (!_isSupported) {
      return 'not_supported';
    }

    try {
      final permission = await web.Notification.requestPermission().toDart;
      _isSupported = permission.toDart == 'granted';
      return permission.toDart;
    } catch (e) {
      return 'error';
    }
  }

  /// Show a notification for new messages.
  /// Foreground/maximized/minimized all funnel here: the service worker
  /// handles the hidden/minimized case, this handles the visible case.
  /// Every message updates the tray (history-merged) instead of dropping
  /// 2nd+ messages per chat — the old once-per-chat `return` made
  /// foreground web miss all follow-ups until the chat was re-entered.
  ///
  /// [card] is the copy the server computed for this recipient; when a push
  /// carried it, the card repeats the server. Otherwise the card is built from
  /// the lines this tab has collected, with the same two rules the server
  /// applies (count in the title, no quoted text once the backlog is more than
  /// one message).
  static Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String messageContent,
    required String matchId,
    bool alreadyAggregated = false,
    bool? shouldAlertOverride,
    ChatPushCardModel? card,
    int? unreadCount,
    String? photoSource,
  }) async {
    if (!isSupported) {
      return;
    }

    // Check if chat notifications are enabled
    if (!_shouldShowChatNotification()) {
      return;
    }

    // Check if user is viewing this chat (affects notification behavior)
    final isViewingChat = _currentViewingChatId == chatId;

    // Don't show notifications when viewing the chat AND the page is visible
    final isPageVisible = web.window.document.visibilityState == 'visible';
    if (isViewingChat && isPageVisible) {
      return;
    }

    // History-merge so minimized/maximized/foreground all show the latest
    // context (mirrors mobile MessagingStyle + SW 5-message merge).
    final history = _messageHistory.putIfAbsent(chatId, () => <String>[]);
    if (!alreadyAggregated && messageContent.trim().isNotEmpty) {
      final last = history.isNotEmpty ? history.last : null;
      if (last != messageContent) {
        history.add(messageContent);
        while (history.length > NotifLimits.chatHistoryMaxItems) {
          history.removeAt(0);
        }
      }
    }
    // Updates replace silently via the same tag so follow-ups never go
    // missing. Record first post per chat for badge/count parity with mobile.
    _lastNotifiedChatIds.putIfAbsent(chatId, () => chatId.hashCode);

    try {
      final previewsEnabled = card?.previewsEnabled ??
          messagePreviewsEnabled(_container);
      // Remember which picture belongs to which conversation: a card signalled
      // by a push knows the chat but not the photo, and the face belongs to the
      // conversation, not to the message that happened to arrive.
      final rememberedAvatar = _avatarSources[chatId];
      if (photoSource != null && photoSource.trim().isNotEmpty) {
        _avatarSources[chatId] = photoSource.trim();
      }
      // The server's total wins: it counts messages this tab never saw. A
      // locally-signalled message falls back to the lines this tab holds,
      // which is the same window the member can read in the chat list.
      final count = card?.unreadCount ??
          unreadCount ??
          (history.isEmpty ? 1 : history.length);
      final maskedName = maskFullName(senderName);
      // An aggregated push without a card of its own carries only its body —
      // that body already stands for the whole batch, so nothing is re-merged.
      final served = card ??
          (alreadyAggregated && messageContent.trim().isNotEmpty
              ? ChatPushCardModel(body: messageContent.trim())
              : null);
      final model = buildChatNotificationCard(
        unreadCount: count,
        previewsEnabled: previewsEnabled,
        candidateLines: history,
        forms: chatCardForms(_container, maskedName),
        payload: served,
      );
      // Close the previous notification with the same tag before posting the
      // merged update (some browsers stack instead of replacing).
      try {
        _activeChatNotifications[chatId]?.close();
      } catch (_) {}
      final options = web.NotificationOptions(
        body: model.body,
        icon: await _avatarIcon(
          (photoSource?.trim().isNotEmpty ?? false)
              ? photoSource
              : rememberedAvatar,
        ),
        tag: 'match_$chatId',
        renotify: shouldAlertOverride ?? false,
      );

      final notification = web.Notification(model.title, options);
      _activeChatNotifications[chatId] = notification;

      // Keep notification visible for 15 seconds to ensure user sees it
      final chatDelay = await (() async {
        try {
          final seconds = await appConfigService.getInt(
            'notification.web_delay_seconds',
            defaultValue: 15,
          );
          return Duration(seconds: seconds);
        } catch (e) {
          return const Duration(seconds: 15);
        }
      })();
      Future.delayed(chatDelay, () {
        try {
          notification.close();
          if (identical(_activeChatNotifications[chatId], notification)) {
            _activeChatNotifications.remove(chatId);
          }
        } catch (e) {
          // Notification might already be closed, ignore error
        }
      });

      // Handle click to focus/open chat
      notification.onclick = ((web.Event e) {
        web.window.focus();
        notification.close();
        if (identical(_activeChatNotifications[chatId], notification)) {
          _activeChatNotifications.remove(chatId);
        }
      }).toJS;

      // Update last notified to prevent duplicate notifications for this chat
      _lastNotifiedChatIds[chatId] = chatId.hashCode;
    } catch (e) {
      // Ignore notification errors
    }
  }

  /// Set which chat the user is currently viewing
  static void setViewingChat(String chatId) {
    _currentViewingChatId = chatId;
  }

  /// Clear the currently viewing chat
  static void clearViewingChat() {
    _currentViewingChatId = null;
  }

  /// Reset notification state for a chat (when user enters chat)
  static void resetChatNotification(String chatId) {
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId); // Clear history so new messages start fresh
    final active = _activeChatNotifications.remove(chatId);
    try {
      active?.close();
    } catch (_) {}
  }

  /// Get current viewing chat ID
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

  /// The picture every card falls back to when this conversation has no avatar
  /// this session can show.
  static const String _appIcon = '/icons/Icon-192.png';

  /// The sender's face in the slot a browser puts beside the title.
  ///
  /// `profile-photos` is private, so an object path means nothing to the
  /// notification API — it needs a signed URL, and the only one worth using is
  /// one this session already holds from painting the photo. A conversation
  /// whose picture was never opened posts the app icon instead: turning a tray
  /// card into a photo fetch would delay it and spend a request on a face the
  /// member has not looked at.
  static Future<String> _avatarIcon(String? photoSource) async {
    final source = (photoSource ?? '').trim();
    if (source.isEmpty) return _appIcon;
    final cached = StorageHelper.getCachedUrl(source);
    if (cached != null && cached.isNotEmpty) return cached;
    if (source.startsWith('http://') || source.startsWith('https://')) {
      return source;
    }
    return _appIcon;
  }

  /// Check if match expiry notifications should be shown
  static bool _shouldShowNewMatchNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.newMatch,
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

  /// Diagnostic function to help debug notification issues
  static Map<String, dynamic> getDiagnostics() {
    return {
      'isSupported': _isSupported,
      'permission': _isSupported ? web.Notification.permission : 'unknown',
      'currentViewingChatId': _currentViewingChatId,
      'lastNotifiedChatIds': Map.from(_lastNotifiedChatIds),
      'messageHistory': Map.from(
        _messageHistory.map((k, v) => MapEntry(k, List.from(v))),
      ),
      'userAgent': web.window.navigator.userAgent,
      'notificationCenterVisible': _checkNotificationCenter(),
    };
  }

  /// Check if browser notification center is accessible
  static bool _checkNotificationCenter() {
    try {
      // Try to create and immediately close a notification to test if it works
      if (isSupported) {
        final n = web.Notification('Test');
        n.close();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// Set service worker user ID for push notifications.
  /// Posts SET_USER_ID to the active service worker so
  /// `firebase-messaging-sw.js` can drop pushes for the wrong account
  /// (shared browser) and keep them for the right one after restart.
  /// Without this the SW `_currentUserId` stays empty and filtering is off.
  // ignore: unused_field
  static String? _serviceWorkerUserId;
  static void setServiceWorkerUserId(String userId) {
    final trimmed = userId.trim();
    _serviceWorkerUserId = trimmed.isEmpty ? null : trimmed;
    if (trimmed.isEmpty) return;
    try {
      _postToServiceWorker(<String, dynamic>{
        'type': 'SET_USER_ID',
        'userId': trimmed,
        'user_id': trimmed,
      });
    } catch (_) {}
  }

  /// Clear service worker user ID
  static void clearServiceWorkerUserId() {
    _serviceWorkerUserId = null;
    try {
      _postToServiceWorker(<String, dynamic>{'type': 'CLEAR_USER_ID'});
    } catch (_) {}
  }

  static void _postToServiceWorker(Map<String, dynamic> payload) {
    try {
      final nav = web.window.navigator;
      // `serviceWorker` is not in package:web's typed API on all versions;
      // reach it via JS interop so this compiles everywhere.
      final sw = (nav as dynamic).serviceWorker as dynamic;
      if (sw == null) return;
      final controller = sw.controller as dynamic;
      if (controller == null) {
        // SW not yet controlling this page (first load after install).
        // The SW will still get the id on next setServiceWorkerUserId call
        // (login + every foreground launch call it).
        return;
      }
      (controller.postMessage as dynamic)(payload.jsify() as JSAny);
    } catch (_) {}
  }

  /// Show match notification
  static Future<void> showMatchNotification({
    required String matchId,
    required String matchName,
    required String matchPhotoUrl,
    String? tag,
  }) async {
    if (!isSupported) {
      return;
    }

    // Check if match notifications are enabled
    if (!_shouldShowNewMatchNotification()) {
      return;
    }

    try {
      final enforced = enforceTitleBody(
        '💕 New match with ${maskFullName(matchName)}',
        'New match! Tap to start chatting',
      );
      final options = web.NotificationOptions(
        body: enforced.body,
        icon: await _avatarIcon(matchPhotoUrl),
        // Default matches the legacy local identity; callers pass the
        // server push tag (e.g. the expiry collapse tag) so an already
        // delivered server card is replaced instead of doubled.
        tag: tag ?? 'match_$matchId',
      );

      final notification = web.Notification(enforced.title, options);

      // Keep notification visible for 15 seconds
      final matchDelay = await (() async {
        try {
          final seconds = await appConfigService.getInt(
            'notification.web_delay_seconds',
            defaultValue: 15,
          );
          return Duration(seconds: seconds);
        } catch (e) {
          return const Duration(seconds: 15);
        }
      })();
      Future.delayed(matchDelay, () {
        try {
          notification.close();
        } catch (e) {
          // Ignore
        }
      });

      notification.onclick = ((web.Event e) {
        web.window.focus();
        notification.close();
      }).toJS;
    } catch (e) {
      // Ignore notification errors
    }
  }

  /// Show admin broadcast notification
  static Future<void> showAdminBroadcastNotification({
    required String title,
    required String message,
    required String notificationId,
  }) async {
    if (!isSupported) {
      return;
    }

    // Check if admin notifications are enabled
    if (!_shouldShowAdminNotification()) {
      return;
    }

    try {
      final enforced = enforceTitleBody('📢 $title', message);
      final options = web.NotificationOptions(
        body: enforced.body,
        icon: _appIcon,
        tag: 'admin_$notificationId',
      );

      final notification = web.Notification(enforced.title, options);

      // Keep notification visible for 20 seconds for important announcements
      final adminDelay = await (() async {
        try {
          final seconds = await appConfigService.getInt(
            'notification.web_delay_seconds',
            defaultValue: 20,
          );
          return Duration(seconds: seconds);
        } catch (e) {
          return const Duration(seconds: 20);
        }
      })();
      Future.delayed(adminDelay, () {
        try {
          notification.close();
        } catch (e) {
          // Ignore
        }
      });

      notification.onclick = ((web.Event e) {
        web.window.focus();
        notification.close();
      }).toJS;
    } catch (e) {
      // Ignore notification errors
    }
  }

  /// Check if location sharing notifications should be shown
  static bool _shouldShowLocationShareNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(
      NotificationType.locationSharing,
      NotificationMethod.push,
    );
  }

  /// Show location share notification
  static Future<void> showLocationShareNotification({
    required String title,
    required String body,
    bool silent = false,
  }) async {
    if (!isSupported) {
      return;
    }

    if (!_shouldShowLocationShareNotification()) {
      return;
    }

    // Per-second countdown updates must not resurrect a notification the
    // user dismissed or clicked away.
    if (silent && _locationShareDismissed) {
      return;
    }
    if (!silent) {
      _locationShareDismissed = false;
    }

    try {
      final previous = _lastLocationShareNotification;

      final options = web.NotificationOptions(
        body: body,
        icon: _appIcon,
        tag: 'location_share',
      );

      final notification = web.Notification('📍 $title', options);

      // Posting a new notification with the same tag closes the previous
      // one — that close event is not a user dismissal.
      if (previous != null) {
        _expectedLocationShareCloses.add(previous);
      }
      _lastLocationShareNotification = notification;

      notification.onclose = ((web.Event e) {
        if (!_expectedLocationShareCloses.remove(notification)) {
          // Closed by the user — stop re-posting it on subsequent updates.
          if (_lastLocationShareNotification == notification) {
            _lastLocationShareNotification = null;
          }
          _locationShareDismissed = true;
        }
      }).toJS;

      final locationDelay = await (() async {
        try {
          final seconds = await appConfigService.getInt(
            'notification.web_delay_seconds',
            defaultValue: 15,
          );
          return Duration(seconds: seconds);
        } catch (e) {
          return const Duration(seconds: 15);
        }
      })();
      Future.delayed(locationDelay, () {
        try {
          _expectedLocationShareCloses.add(notification);
          notification.close();
        } catch (e) {
          // Ignore
        }
      });

      notification.onclick = ((web.Event e) {
        web.window.focus();
        notification.close();
      }).toJS;
    } catch (e) {
      // Ignore notification errors
    }
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

  static Future<void> showMeetupNotification({
    required String notificationId,
    required String title,
    required String body,
    String? matchId,
    String? kind,
  }) async {
    if (!isSupported) return;
    if (!_shouldShowMeetupNotification()) return;

    try {
      final enforced = enforceTitleBody(title, body);
      final options = web.NotificationOptions(
        body: enforced.body,
        icon: _appIcon,
        tag: 'meetup_$notificationId',
      );
      final notification = web.Notification(enforced.title, options);

      final route = (matchId ?? '').trim();
      // Proposal and place-change cards open the planning screen, where the
      // accept/counter decision lives; every other kind opens the hub.
      final isDecision =
          kind == kMeetupAlertProposal || kind == kMeetupAlertPlaceChange;
      final openRoute = route.isEmpty
          ? null
          : (isDecision ? '/meetup/$route/plan' : '/meetup/$route');

      final delay = await (() async {
        try {
          final seconds = await appConfigService.getInt(
            'notification.web_delay_seconds',
            defaultValue: 15,
          );
          return Duration(seconds: seconds);
        } catch (e) {
          return const Duration(seconds: 15);
        }
      })();
      Future.delayed(delay, () {
        try {
          notification.close();
        } catch (e) {
          // Ignore
        }
      });

      notification.onclick = ((web.Event e) {
        web.window.focus();
        notification.close();
        if (openRoute != null) {
          try {
            onOpenRoute?.call(openRoute);
          } catch (_) {}
        }
      }).toJS;
    } catch (e) {
      // Ignore notification errors
    }
  }
}
