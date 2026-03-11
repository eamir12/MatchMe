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

/// Service for handling admin broadcast messages
class AdminBroadcastService {
  static final _supabase = Supabase.instance.client;
  static final _messaging = FirebaseMessaging.instance;
  static ProviderContainer? _container;
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

  /// Public wrapper for handling broadcast messages
  static void handleBroadcastMessage(RemoteMessage message) {
    _handleBroadcastMessage(message);
  }

  /// Public wrapper for handling broadcast message opens
  static void handleBroadcastMessageOpened(RemoteMessage message) {
    _handleBroadcastMessageOpened(message);
  }
  
  /// Handle incoming broadcast messages
  static void _handleBroadcastMessage(RemoteMessage message) {
    final data = message.data;
    
    // Check if this is an admin broadcast
    if (data['type'] == 'admin_broadcast') {
      debugPrint('📢 Received admin broadcast: ${message.messageId}');
      
      // Extract broadcast details
      final broadcastId = (data['broadcast_id'] ?? '').toString();
      if (broadcastId.trim().isEmpty) return;
      final title = message.notification?.title ?? 'Admin Message';
      final body = message.notification?.body ?? '';
      final actionUrl = data['action_url']?.toString();
      final actionUrlText = (data['action_url_text'] ?? 'Learn More').toString();
      
      // Show the broadcast notification to the user
      unawaited(_showBroadcastNotification(
        broadcastId: broadcastId,
        title: title,
        body: body,
        actionUrl: actionUrl,
        actionUrlText: actionUrlText,
        shouldShowOsNotification: _shouldShowOsNotification(message),
      ));
      
      // Track that we received this broadcast
      _trackBroadcastDelivery(broadcastId);
    }
  }
  
  /// Handle when user taps on a broadcast notification
  static void _handleBroadcastMessageOpened(RemoteMessage message) {
    final data = message.data;
    
    if (data['type'] == 'admin_broadcast') {
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
    debugPrint('📢 Admin Broadcast: $title - $body');
    
    if (actionUrl != null) {
      debugPrint('📢 Action URL: $actionUrl');
    }

    final container = _container;
    if (container != null) {
      final notifs = container.read(userPreferencesProvider).notifications;
      if (!notifs.isPausedNow &&
          notifs.isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.inApp)) {
        container.read(systemNotificationProvider.notifier).notify(
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
      debugPrint('📢 Admin notifications disabled - skipping OS notification for broadcast: $broadcastId');
    }
  }

  static bool _shouldShowOsNotification(RemoteMessage message) {
    if (kIsWeb) return true;
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (!isMobile) return false;
    if (_appInForeground) return true;
    return message.notification == null;
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
    } catch (_) {
    }
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

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) return;

    Set<String> shown = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      shown = (prefs.getStringList(_prefsBlueShownBroadcastIdsKey) ?? const <String>[])
          .where((e) => e.trim().isNotEmpty)
          .toSet();
    } catch (_) {
    }

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
        notifs.isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.inApp)) {
      container.read(systemNotificationProvider.notifier).notify(
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
    } catch (_) {
    }
  }
  
  /// Open action URL from broadcast
  static Future<void> _openActionUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('📢 Opened action URL: $url');
      } else {
        debugPrint('📢 Could not launch URL: $url');
      }
    } catch (e) {
      debugPrint('📢 Error opening URL: $e');
    }
  }
  
  /// Track broadcast delivery in database
  static Future<void> _trackBroadcastDelivery(String? broadcastId) async {
    if (broadcastId == null) return;
    
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
          
      debugPrint('📢 Tracked delivery for broadcast: $broadcastId');
    } catch (e) {
      debugPrint('📢 Error tracking delivery: $e');
    }
  }
  
  /// Track user interaction with broadcast
  static Future<void> _trackBroadcastInteraction(String? broadcastId) async {
    if (broadcastId == null) return;
    
    try {
      // You can add additional tracking here if needed
      debugPrint('📢 Tracked interaction for broadcast: $broadcastId');
    } catch (e) {
      debugPrint('📢 Error tracking interaction: $e');
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
      return notifs.isMethodEnabled(NotificationType.adminAnnouncements, NotificationMethod.push);
    } catch (_) {
      return true; // Default to enabled on error
    }
  }
  
  /// Get recent broadcasts for the current user
  static Future<List<BroadcastMessage>> getRecentBroadcasts({
    int limit = 10,
    Set<String> deliveryStatuses = const {'sent', 'delivered'},
  }) async {
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
          
      return response.map((json) => BroadcastMessage.fromJson(json)).toList();
    } catch (e) {
      debugPrint('📢 Error getting recent broadcasts: $e');
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
      sentAt: DateTime.parse(broadcast['sent_at'] ?? DateTime.now().toIso8601String()),
      deliveredAt: json['delivered_at'] != null 
          ? DateTime.parse(json['delivered_at']) 
          : null,
      actionUrl: broadcast['action_url'],
      actionUrlText: broadcast['action_url_text'],
      deliveryStatus: json['delivery_status'] ?? 'unknown',
    );
  }
}
