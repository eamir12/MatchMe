// lib/services/web_notification_service_stub.dart
// Stub implementation for non-web platforms

/// Web notification service stub - does nothing on non-web platforms
class WebNotificationService {
  static String? _currentViewingChatId;
  static final Map<String, List<String>> _messageHistory = {};
  static final Map<String, int> _lastNotifiedChatIds = {};

  /// Set the ProviderContainer to access preferences (no-op on non-web)
  static void setProviderContainer(_) {
    // No-op on non-web platforms
  }

  /// Initialize web notifications (no-op on non-web)
  static Future<void> initialize() async {
    // No-op on non-web platforms
  }

  /// Check if web notifications are supported (always false on non-web)
  static bool get isSupported => false;

  /// Show a notification (no-op on non-web)
  static Future<void> showMessageNotification({
    required String chatId,
    required String senderName,
    required String messageContent,
    required String matchId,
  }) async {
    // No-op on non-web platforms
  }

  static Future<void> showMatchNotification({
    required String matchId,
    required String matchName,
    required String matchPhotoUrl,
  }) async {
    // No-op on non-web platforms
  }

  static Future<void> showAdminBroadcastNotification({
    required String title,
    required String message,
    required String notificationId,
  }) async {
    // No-op on non-web platforms
  }

  /// Set which chat the user is currently viewing
  static void setViewingChat(String chatId) {
    _currentViewingChatId = chatId;
  }

  /// Clear the currently viewing chat
  static void clearViewingChat() {
    _currentViewingChatId = null;
  }

  /// Reset notification state for a chat
  static void resetChatNotification(String chatId) {
    _lastNotifiedChatIds.remove(chatId);
    _messageHistory.remove(chatId);
  }

  /// Get current viewing chat ID
  static String? get currentViewingChatId => _currentViewingChatId;

  /// Force re-request permission (stub implementation)
  static Future<String> requestPermission() async {
    return 'not_supported';
  }

  /// Test notification function (stub implementation)
  static Future<bool> testNotification() async {
    return false;
  }

  /// Direct browser API test (stub implementation)
  static Future<String> testBrowserAPI() async {
    return 'Not available on this platform';
  }

  /// Test the full real-time message processing pipeline (stub implementation)
  static Future<bool> testRealTimeMessagePipeline() async {
    return false;
  }

  /// Simulate a real message notification (stub implementation)
  static Future<bool> testRealMessageNotification() async {
    return false;
  }

  static void setServiceWorkerUserId(String userId) {
  }

  static void clearServiceWorkerUserId() {
  }

  /// Diagnostic function (stub implementation)
  static Map<String, dynamic> getDiagnostics() {
    return {
      'isSupported': false,
      'platform': 'non-web',
      'currentViewingChatId': _currentViewingChatId,
    };
  }
}
