import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/background_service.dart';
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionCoordinator {
  PermissionCoordinator._();

  static bool _promptInProgress = false;
  static DateTime? _lastPromptAt;
  static const Duration _minPromptInterval = Duration(seconds: 15);
  static final Set<String> _suppressedIssueCodesThisRun = <String>{};

  static Future<void> syncNativePermissionStrings(WidgetRef ref) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final l10n = ref.read(localizationProvider);

    // Store localized strings for native notifications after reboot.
    await BackgroundService.setNativePermissionStrings({
      'perm_location_always_title': l10n.getString('permLocationAlwaysTitle'),
      'perm_location_always_body': l10n.getString('permLocationAlwaysBody'),
      'perm_notifications_title': l10n.getString('permNotificationsTitle'),
      'perm_notifications_body': l10n.getString('permNotificationsBody'),
      'perm_battery_title': l10n.getString('permBatteryTitle'),
      'perm_battery_body': l10n.getString('permBatteryBody'),
      'perm_action_open_settings': l10n.getString('permActionOpenSettings'),
      'perm_action_not_now': l10n.getString('permActionNotNow'),
    });
  }

  /// Proactive audit (used at onboarding/profile completion). This may prompt even if the
  /// app hasn't yet encountered a failure.
  static Future<void> checkAndPromptIfNeeded(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (!context.mounted) return;
    if (_promptInProgress) return;
    if (_lastPromptAt != null &&
        DateTime.now().difference(_lastPromptAt!) < _minPromptInterval) {
      return;
    }

    _promptInProgress = true;
    _lastPromptAt = DateTime.now();

    try {
      // If native side recorded a permission issue (e.g. after reboot), prioritize it.
      await handleOnResume(context, ref);

      // 1) Background location (Android). Needed for post-reboot GPS updates.
      if (!kIsWeb && Platform.isAndroid) {
        // Ensure basic location is granted first.
        final locStatus = await Permission.location.status;
        if (!context.mounted) return;
        var hasForegroundLocation = locStatus.isGranted;
        if (!hasForegroundLocation) {
          final requested = await Permission.location.request();
          if (!context.mounted) return;
          hasForegroundLocation = requested.isGranted;
          if (!hasForegroundLocation) {
            if (!context.mounted) return;
            await _showDialog(
              context,
              ref,
              titleKey: 'permLocationAlwaysTitle',
              bodyKey: 'permLocationWhileInUseBody',
              onPrimary: () => openAppSettings(),
            );
          }
        }

        if (hasForegroundLocation) {
          final alwaysStatus = await Permission.locationAlways.status;
          if (!context.mounted) return;
          if (!alwaysStatus.isGranted) {
            final requested = await Permission.locationAlways.request();
            if (!context.mounted) return;
            if (!requested.isGranted) {
              if (!context.mounted) return;
              await _showDialog(
                context,
                ref,
                titleKey: 'permLocationAlwaysTitle',
                bodyKey: 'permLocationAlwaysBody',
                onPrimary: () => openAppSettings(),
              );
            }
          }
        }

        // 2) Notifications (Android 13+). Important for "always on" UX.
        final notifStatus = await Permission.notification.status;
        if (!context.mounted) return;
        if (!notifStatus.isGranted) {
          final requested = await Permission.notification.request();
          if (!context.mounted) return;
          if (!requested.isGranted) {
            if (!context.mounted) return;
            await _showDialog(
              context,
              ref,
              titleKey: 'permNotificationsTitle',
              bodyKey: 'permNotificationsBody',
              onPrimary: () => openAppSettings(),
            );
          }
        }

        // 3) Battery optimizations (Android). Highly recommended for boot/always-on reliability.
        final ignoring =
            await BackgroundService.isIgnoringBatteryOptimizations();
        if (!context.mounted) return;
        if (!ignoring) {
          if (!context.mounted) return;
          await _showDialog(
            context,
            ref,
            titleKey: 'permBatteryTitle',
            bodyKey: 'permBatteryBody',
            onPrimary: () =>
                BackgroundService.requestIgnoreBatteryOptimizations(),
          );
        }
      }
    } finally {
      _promptInProgress = false;
    }
  }

  /// Failure-driven handler. Call this on app resume to surface permission issues recorded
  /// by the native background service. This will NOT proactively audit all permissions.
  static Future<void> handleOnResume(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (!context.mounted) return;
    if (_promptInProgress) return;

    final nativeIssue =
        await BackgroundService.consumeNativePermissionIssueCode();
    if (!context.mounted) return;
    if (nativeIssue == null || nativeIssue.isEmpty) return;

    await notifyIssueNow(context, ref, nativeIssue);

    // Also validate Background Matching Mode permission - if revoked, disable the mode
    try {
      await ref
          .read(userPreferencesProvider.notifier)
          .validateBackgroundMatchingPermission();
    } catch (e) {
      // Ignore validation errors
    }
  }

  /// Check if background location permission is granted (needed for Android 14+ foreground service)
  static Future<bool> hasBackgroundLocationPermission() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    final alwaysStatus = await Permission.locationAlways.status;
    return alwaysStatus.isGranted;
  }

  /// Request background location permission proactively (needed for Android 14+ foreground service in background)
  /// Returns true if permission is granted, false otherwise
  static Future<bool> requestBackgroundLocationPermission(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (kIsWeb || !Platform.isAndroid) return true;
    if (!context.mounted) return false;

    // Ensure basic location is granted first
    final locStatus = await Permission.location.status;
    if (!context.mounted) return false;
    var hasForegroundLocation = locStatus.isGranted;
    if (!hasForegroundLocation) {
      final requested = await Permission.location.request();
      if (!context.mounted) return false;
      hasForegroundLocation = requested.isGranted;
      if (!hasForegroundLocation) {
        if (!context.mounted) return false;
        await ref
            .read(userPreferencesProvider.notifier)
            .setPendingBackgroundMatchingEnable(true);
        if (!context.mounted) return false;
        await _showDialog(
          context,
          ref,
          titleKey: 'permLocationAlwaysTitle',
          bodyKey: 'permLocationWhileInUseBody',
          onPrimary: () => openAppSettings(),
        );
        return false;
      }
    }

    // Now request background location
    if (hasForegroundLocation) {
      final alwaysStatus = await Permission.locationAlways.status;
      if (!context.mounted) return false;
      if (!alwaysStatus.isGranted) {
        await Permission.locationAlways.request();
        if (!context.mounted) return false;

        // After permission dialog, re-check the actual status
        // (user might have granted it in system settings)
        await Future.delayed(const Duration(milliseconds: 200));
        final finalStatus = await Permission.locationAlways.status;
        if (!context.mounted) return false;

        if (!finalStatus.isGranted) {
          if (!context.mounted) return false;
          // Show dialog to open settings
          await ref
              .read(userPreferencesProvider.notifier)
              .setPendingBackgroundMatchingEnable(true);
          if (!context.mounted) return false;
          await _showDialog(
            context,
            ref,
            titleKey: 'permLocationAlwaysTitle',
            bodyKey: 'permLocationAlwaysBody',
            onPrimary: () => openAppSettings(),
          );

          // After user closes the settings dialog, check permission again
          if (!context.mounted) return false;
          await Future.delayed(const Duration(milliseconds: 200));
          final settingsStatus = await Permission.locationAlways.status;
          if (!context.mounted) return false;

          return settingsStatus.isGranted;
        }
        await ref
            .read(userPreferencesProvider.notifier)
            .setPendingBackgroundMatchingEnable(false);
        return true;
      }
    }

    return true;
  }

  /// Failure-driven: show the specific permission dialog once per app run per issue code.
  static Future<void> notifyIssueNow(
    BuildContext context,
    WidgetRef ref,
    String code,
  ) async {
    if (!context.mounted) return;
    if (_promptInProgress) return;
    if (_suppressedIssueCodesThisRun.contains(code)) return;
    if (_lastPromptAt != null &&
        DateTime.now().difference(_lastPromptAt!) < _minPromptInterval) {
      return;
    }

    _promptInProgress = true;
    _lastPromptAt = DateTime.now();
    _suppressedIssueCodesThisRun.add(code);

    try {
      await _promptForIssue(context, ref, code);
    } finally {
      _promptInProgress = false;
    }
  }

  static Future<void> _promptForIssue(
    BuildContext context,
    WidgetRef ref,
    String code,
  ) async {
    switch (code) {
      case 'location_always':
        if (!context.mounted) return;
        await _showDialog(
          context,
          ref,
          titleKey: 'permLocationAlwaysTitle',
          bodyKey: 'permLocationAlwaysBody',
          onPrimary: () => openAppSettings(),
        );
        return;
      case 'FOREGROUND_SERVICE_LOCATION_DENIED':
        if (!context.mounted) return;
        await _showDialog(
          context,
          ref,
          titleKey: 'permLocationAlwaysTitle',
          bodyKey: 'permLocationAlwaysBody',
          onPrimary: () => openAppSettings(),
        );
        return;
      case 'notifications':
        if (!context.mounted) return;
        await _showDialog(
          context,
          ref,
          titleKey: 'permNotificationsTitle',
          bodyKey: 'permNotificationsBody',
          onPrimary: () async {
            if (!kIsWeb && Platform.isAndroid) {
              await BackgroundService.openAppNotificationSettings();
            } else {
              await openAppSettings();
            }
          },
        );
        return;
      case 'battery_optimizations':
        if (!context.mounted) return;
        await _showDialog(
          context,
          ref,
          titleKey: 'permBatteryTitle',
          bodyKey: 'permBatteryBody',
          onPrimary: () =>
              BackgroundService.requestIgnoreBatteryOptimizations(),
        );
        return;
      default:
        return;
    }
  }

  static Future<void> _showDialog(
    BuildContext context,
    WidgetRef ref, {
    required String titleKey,
    required String bodyKey,
    required Future<void> Function() onPrimary,
  }) async {
    final l10n = ref.read(localizationProvider);
    final title = l10n.getString(titleKey);
    final body = l10n.getString(bodyKey);
    final open = l10n.getString('permActionOpenSettings');
    final later = l10n.getString('permActionNotNow');

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actionsAlignment: MainAxisAlignment.end,
          actionsOverflowAlignment: OverflowBarAlignment.end,
          actionsOverflowButtonSpacing: 8,
          actionsOverflowDirection: VerticalDirection.down,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(later),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                await ResumeRouteRestore.persistPendingRouteForContext(context);
                await onPrimary();
              },
              child: Text(open),
            ),
          ],
        );
      },
    );
  }
}
