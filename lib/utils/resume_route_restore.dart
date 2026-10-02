import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResumeRouteRestore {
  ResumeRouteRestore._();

  static const String settingsRoute = '/settings';
  static const String notificationsSettingsRoute = '/settings/notifications';
  static const String notificationInboxRoute = '/notifications/inbox';
  static const String securityCenterRoute = '/settings/security';

  static const String _pendingRouteKey = 'resume_restore.pending_route_name';
  static const String _pendingRouteSavedAtKey =
      'resume_restore.pending_route_saved_at_ms';
  static const String _lastMainTabIndexKey =
      'resume_restore.last_main_tab_index';
  static const Duration _maxPendingAge = Duration(minutes: 10);

  static Future<void> persistPendingRouteForContext(
    BuildContext context, {
    String? fallbackRouteName,
  }) async {
    final routeName =
        ModalRoute.of(context)?.settings.name ?? fallbackRouteName;
    if (routeName == null || routeName.isEmpty) return;
    await persistPendingRouteName(routeName);
  }

  static Future<void> persistPendingRouteName(String routeName) async {
    if (routeName.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingRouteKey, routeName);
    await prefs.setInt(
      _pendingRouteSavedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<String?> peekPendingRouteName() async {
    final prefs = await SharedPreferences.getInstance();
    return _readValidatedPendingRouteName(prefs);
  }

  static Future<String?> consumePendingRouteName() async {
    final prefs = await SharedPreferences.getInstance();
    final routeName = _readValidatedPendingRouteName(prefs);

    await clearPendingRoute();

    return routeName;
  }

  static Future<void> clearPendingRoute() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingRouteKey);
    await prefs.remove(_pendingRouteSavedAtKey);
  }

  static Future<void> saveLastMainTabIndex(int index) async {
    if (index < 0 || index > 4) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastMainTabIndexKey, index);
  }

  static Future<int?> readLastMainTabIndex() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_lastMainTabIndexKey);
    if (index == null || index < 0 || index > 4) return null;
    return index;
  }

  static String? _readValidatedPendingRouteName(SharedPreferences prefs) {
    final routeName = prefs.getString(_pendingRouteKey);
    final savedAtMs = prefs.getInt(_pendingRouteSavedAtKey);

    if (routeName == null || routeName.isEmpty) return null;
    if (savedAtMs == null) return routeName;

    final savedAt = DateTime.fromMillisecondsSinceEpoch(savedAtMs);
    if (DateTime.now().difference(savedAt) > _maxPendingAge) {
      return null;
    }

    return routeName;
  }
}
