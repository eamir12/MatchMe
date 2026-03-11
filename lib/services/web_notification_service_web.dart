// lib/services/web_notification_service_web.dart
// Web-specific implementation using package:web

import 'dart:async';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/user_preferences_provider.dart';

/// Web notification service that provides similar functionality to mobile notifications
/// Uses the browser's Notification API for web platforms
class WebNotificationService {
  static bool _isSupported = false;
  static ProviderContainer? _container;
  static String? _currentViewingChatId;
  static final Map<String, List<String>> _messageHistory = {};
  static final Map<String, int> _lastNotifiedChatIds = {};
  static final Map<String, web.Notification> _activeChatNotifications = {};

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
  static bool get isSupported => _isSupported && web.Notification.permission == 'granted';

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

  /// Show a notification for new messages
  static Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String messageContent,
    required String matchId,
  }) async {
    if (!isSupported) {
      return;
    }

    // Check if chat notifications are enabled
    if (!_shouldShowChatNotification()) {
      debugPrint('Chat notifications disabled - skipping web notification for chat: $chatId');
      return;
    }

    // Check if user is viewing this chat (affects notification behavior)
    final isViewingChat = _currentViewingChatId == chatId;

    // Don't show notifications when viewing the chat AND the page is visible
    final isPageVisible = web.window.document.visibilityState == 'visible';
    if (isViewingChat && isPageVisible) {
      debugPrint('Web: Skipping notification - currently viewing chat and page is visible');
      return;
    }

    // Check if we should show notification alert (avoid spam - once per chat)
    // Only show if we haven't already notified for this chat in this session
    final shouldAlert = _lastNotifiedChatIds[chatId] == null;

    if (!shouldAlert) {
      return;
    }

    try {
      final options = web.NotificationOptions(
        body: messageContent,
        icon: '/icons/Icon-192.png',
        tag: chatId,
      );
      
      final notification = web.Notification('💬 New message from $senderName', options);
      _activeChatNotifications[chatId] = notification;

      // Keep notification visible for 15 seconds to ensure user sees it
      Future.delayed(const Duration(seconds: 15), () {
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
      debugPrint('Web: Notification shown for chat: $chatId');

    } catch (e) {
      debugPrint('Failed to show web notification: $e');
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
    return notifs.isMethodEnabled(NotificationType.chatMessages, NotificationMethod.push);
  }

  /// Check if match expiry notifications should be shown
  static bool _shouldShowNewMatchNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(NotificationType.newMatch, NotificationMethod.push);
  }

  /// Check if admin notifications should be shown
  static bool _shouldShowAdminNotification() {
    final notifs = _getNotifs();
    if (notifs == null) return true;
    if (notifs.isPausedNow) return false;
    return notifs.isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.push);
  }

  /// Diagnostic function to help debug notification issues
  static Map<String, dynamic> getDiagnostics() {
    return {
      'isSupported': _isSupported,
      'permission': _isSupported ? web.Notification.permission : 'unknown',
      'currentViewingChatId': _currentViewingChatId,
      'lastNotifiedChatIds': Map.from(_lastNotifiedChatIds),
      'messageHistory': Map.from(_messageHistory.map((k, v) => MapEntry(k, List.from(v)))),
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

  /// Set service worker user ID for push notifications
  // ignore: unused_field
  static String? _serviceWorkerUserId;
  static void setServiceWorkerUserId(String userId) {
    _serviceWorkerUserId = userId;
    // ignore: avoid_print
    debugPrint('Web: Service worker user ID set: $userId');
  }

  /// Clear service worker user ID
  static void clearServiceWorkerUserId() {
    _serviceWorkerUserId = null;
    // ignore: avoid_print
    debugPrint('Web: Service worker user ID cleared');
  }

  /// Show match notification
  static Future<void> showMatchNotification({
    required String matchId,
    required String matchName,
    required String matchPhotoUrl,
  }) async {
    if (!isSupported) {
      return;
    }

    // Check if match notifications are enabled
    if (!_shouldShowNewMatchNotification()) {
      debugPrint('Match notifications disabled - skipping web notification for match: $matchId');
      return;
    }

    try {
      final options = web.NotificationOptions(
        body: 'New match! Tap to start chatting',
        icon: matchPhotoUrl.isNotEmpty ? matchPhotoUrl : '/icons/Icon-192.png',
        tag: 'match_$matchId',
      );
      
      final notification = web.Notification('💕 New match with $matchName', options);

      // Keep notification visible for 15 seconds
      Future.delayed(const Duration(seconds: 15), () {
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

      debugPrint('Web: Match notification shown for match: $matchId');
    } catch (e) {
      debugPrint('Failed to show match notification: $e');
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
      debugPrint('Admin notifications disabled - skipping web notification');
      return;
    }

    try {
      final options = web.NotificationOptions(
        body: message,
        icon: '/icons/Icon-192.png',
        tag: 'admin_$notificationId',
      );
      
      final notification = web.Notification('📢 $title', options);

      // Keep notification visible for 20 seconds for important announcements
      Future.delayed(const Duration(seconds: 20), () {
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

      debugPrint('Web: Admin broadcast notification shown: $notificationId');
    } catch (e) {
      debugPrint('Failed to show admin broadcast notification: $e');
    }
  }
}
