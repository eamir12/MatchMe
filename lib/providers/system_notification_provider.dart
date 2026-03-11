import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SystemNotification {
  final String text;
  final bool isPersistent; // If true, notification stays until explicitly cleared
  final String? notificationType; // e.g., 'battery_throttle', 'stationary_throttle'
  final String? actionUrl;
  final String? actionText;
  SystemNotification({
    required this.text,
    this.isPersistent = false,
    this.notificationType,
    this.actionUrl,
    this.actionText,
  });
}

class SystemNotificationNotifier extends Notifier<SystemNotification?> {
  Timer? _autoClearTimer;
  final Map<String, String> _dismissedPersistentTextByType = <String, String>{};
  
  @override
  SystemNotification? build() => null;

  String _typeKey(String? type) => type ?? '__default__';

  void notify(SystemNotification n) {
    final key = _typeKey(n.notificationType);
    final dismissedText = _dismissedPersistentTextByType[key];
    if (n.isPersistent && dismissedText != null && dismissedText == n.text) {
      return;
    }

    final current = state;
    if (current != null &&
        current.text == n.text &&
        current.isPersistent == n.isPersistent &&
        current.notificationType == n.notificationType &&
        current.actionUrl == n.actionUrl &&
        current.actionText == n.actionText) {
      return;
    }

    _autoClearTimer?.cancel();

    if (n.isPersistent) {
      _dismissedPersistentTextByType.remove(key);
    }

    state = n;
    
    // Only auto-clear if not persistent
    if (!n.isPersistent) {
      _autoClearTimer = Timer(const Duration(seconds: 6), () {
        if (ref.mounted) state = null;
      });
    }
  }

  void clear() {
    _autoClearTimer?.cancel();
    if (ref.mounted) state = null;
  }

  void dismissCurrent() {
    final current = state;
    if (current == null) return;
    if (current.isPersistent) {
      _dismissedPersistentTextByType[_typeKey(current.notificationType)] =
          current.text;
    }
    clear();
  }
  
  // Clear only if it matches a specific type
  void clearType(String type) {
    _dismissedPersistentTextByType.remove(_typeKey(type));
    if (state?.notificationType == type) {
      clear();
    }
  }
}

final systemNotificationProvider = NotifierProvider<SystemNotificationNotifier, SystemNotification?>(() {
  return SystemNotificationNotifier();
});
