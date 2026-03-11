// lib/screens/settings/notifications_settings_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/utils/time_format_utils.dart';

class NotificationsSettingsScreen extends ConsumerWidget {
  const NotificationsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final prefs = ref.watch(userPreferencesProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final notifs = prefs.notifications;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsNotifications')),
        backgroundColor: theme.appBarTheme.backgroundColor ?? colors.surface,
        foregroundColor: theme.appBarTheme.foregroundColor ?? colors.onSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Header card with description
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.primary.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.notifications, color: colors.primary, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.getString('settingsNotificationsTitle'),
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.getString('settingsNotificationsDesc'),
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          _pauseNotificationsCard(context, ref, l10n, theme, colors, notifs),
          const SizedBox(height: 8),
          _notificationMatrixCard(context, ref, l10n, theme, colors, notifs),

          // Info Section
          Container(
            margin: const EdgeInsets.only(top: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.tertiary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: colors.tertiary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.getString('settingsNotificationsInfo'),
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _pauseNotificationsCard(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  ThemeData theme,
  ColorScheme colors,
  NotificationPreferencesState notifs,
) {
  final isPaused = notifs.isPausedNow;
  final resumesAt = notifs.resumesAtLocal;
  final dropdownValue = !isPaused
      ? 'off'
      : (notifs.pausedIndefinitely
          ? 'until_off'
          : (notifs.pausedDurationSeconds != null ? 'dur:${notifs.pausedDurationSeconds}' : null));
  final statusText = () {
    if (!isPaused) return l10n.getString('settingsNotificationsMuteAllOff');
    if (notifs.pausedIndefinitely) return l10n.getString('settingsNotificationsMutedForever');
    if (resumesAt != null) {
      final ts = formatDateAndTimeOfDateTimeWithPrefs(context, ref, l10n, resumesAt);
      return l10n.getString('settingsNotificationsMutedUntilValue', params: {'value': ts});
    }
    return l10n.getString('settingsNotificationsMutedInfo');
  }();

  final notifier = ref.read(userPreferencesProvider.notifier);

  final quickDurationsFuture = appConfigService.getDurationList(
    'notification.mute_quick_durations_seconds',
    defaultValue: const [
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(minutes: 30),
      Duration(hours: 1),
      Duration(hours: 8),
    ],
  );

  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: theme.shadowColor.withValues(alpha: 0.05),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.tertiary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.pause_circle_outline, color: colors.tertiary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.getString('settingsNotificationsMuteAll'),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
            ),
            if (isPaused)
              TextButton(
                onPressed: () => notifier.resumeNotifications(),
                child: Text(l10n.getString('settingsNotificationsMuteAllOff')),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          statusText,
          style: TextStyle(
            fontSize: 13,
            color: colors.onSurface.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Duration>>(
          future: quickDurationsFuture,
          builder: (context, snapshot) {
            final quickDurations = (snapshot.data ?? const <Duration>[])
                .where((d) => d > Duration.zero)
                .toSet()
                .toList()
              ..sort((a, b) => a.inSeconds.compareTo(b.inSeconds));

            final itemValues = <String>{
              'off',
              'until_off',
              for (final d in quickDurations) 'dur:${d.inSeconds}',
            };
            final initialValue = (dropdownValue != null && itemValues.contains(dropdownValue)) ? dropdownValue : null;

            return DropdownButtonFormField<String>(
              key: ValueKey<String>(dropdownValue ?? '__none__'),
              initialValue: initialValue,
              hint: Text(l10n.getString('settingsNotificationsMuteUntil')),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.4),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              items: [
                DropdownMenuItem(
                  value: 'off',
                  child: Text(l10n.getString('settingsNotificationsMuteAllOff')),
                ),
                for (final d in quickDurations)
                  DropdownMenuItem(
                    value: 'dur:${d.inSeconds}',
                    child: Text(_muteQuickDurationLabel(l10n, d)),
                  ),
                DropdownMenuItem(
                  value: 'until_off',
                  child: Text(l10n.getString('settingsNotificationsMuteForever')),
                ),
              ],
              onChanged: (value) {
                final v = value ?? 'off';
                if (v == 'off') {
                  notifier.resumeNotifications();
                  return;
                }
                if (v == 'until_off') {
                  notifier.pauseNotificationsIndefinitely();
                  return;
                }
                if (v.startsWith('dur:')) {
                  final seconds = int.tryParse(v.substring('dur:'.length));
                  if (seconds == null || seconds <= 0) return;
                  notifier.pauseNotificationsFor(Duration(seconds: seconds));
                }
              },
            );
          },
        ),
      ],
    ),
  );
}

Widget _notificationMatrixCard(
  BuildContext context,
  WidgetRef ref,
  LocalizationState l10n,
  ThemeData theme,
  ColorScheme colors,
  NotificationPreferencesState notifs,
) {
  final notifier = ref.read(userPreferencesProvider.notifier);

  final types = [
    NotificationType.chatMessages,
    NotificationType.newMatch,
    NotificationType.expiringMatch,
    NotificationType.adminAnnouncements,
  ];
  final methods = _methodsForPlatform();

  bool isMethodEnabledForAllEnabledTypes(NotificationMethod method) {
    return notifs.isGlobalMethodEnabled(method);
  }

  int crossAxisCountForWidth(double width) {
    if (width >= 600) return 4;
    return 2;
  }

  double methodTileAspectRatio(int crossAxisCount) {
    if (crossAxisCount >= 4) return 3.6;
    return 2.35;
  }

  return Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.surface,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: theme.shadowColor.withValues(alpha: 0.05),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.grid_on, color: colors.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              l10n.getString('settingsNotificationsMatrixTitle'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final crossAxisCount = crossAxisCountForWidth(constraints.maxWidth);
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: methodTileAspectRatio(crossAxisCount),
              children: [
                for (final method in methods)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.5)),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _showMethodInfoDialog(context, l10n, method),
                      child: Row(
                        children: [
                          Icon(_methodIcon(method), size: 18, color: colors.onSurface.withValues(alpha: 0.85)),
                          const SizedBox(width: 8),
                          Expanded(
                          child: LayoutBuilder(
                            builder: (context, c) {
                              final showDesc = c.maxHeight >= 56;
                              return Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _methodLabel(l10n, method),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w700),
                                  ),
                                  if (showDesc) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      _methodDescription(l10n, method),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.onSurface.withValues(alpha: 0.72),
                                        fontSize: 11,
                                        height: 1.05,
                                      ),
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                          ),
                          Switch(
                            value: isMethodEnabledForAllEnabledTypes(method),
                            onChanged: notifs.isPausedNow
                                ? null
                                : (value) => notifier.setGlobalNotificationMethodEnabled(method, value),
                            activeThumbColor: colors.secondary,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        ExpansionPanelList.radio(
          expandedHeaderPadding: EdgeInsets.zero,
          elevation: 0,
          children: [
            for (final type in types)
              ExpansionPanelRadio(
                value: type.name,
                backgroundColor: colors.surfaceContainerHighest.withValues(alpha: 0.18),
                canTapOnHeader: true,
                headerBuilder: (context, isExpanded) {
                  return ListTile(
                    dense: true,
                    title: Text(
                      _typeLabel(l10n, type),
                      style: TextStyle(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    trailing: Switch(
                      value: notifs.isTypeEnabled(type),
                      onChanged: notifs.isPausedNow ? null : (value) => notifier.setNotificationTypeEnabled(type, value),
                      activeThumbColor: colors.primary,
                    ),
                  );
                },
                body: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = crossAxisCountForWidth(constraints.maxWidth);
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: methodTileAspectRatio(crossAxisCount),
                        children: [
                          for (final method in methods)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: colors.outlineVariant.withValues(alpha: 0.55)),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _showMethodInfoDialog(context, l10n, method),
                                child: Row(
                                  children: [
                                    Icon(_methodIcon(method), size: 18, color: colors.onSurface.withValues(alpha: 0.75)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: LayoutBuilder(
                                        builder: (context, c) {
                                          final showDesc = c.maxHeight >= 56;
                                          return Column(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                _methodLabel(l10n, method),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(color: colors.onSurface, fontWeight: FontWeight.w600),
                                              ),
                                              if (showDesc) ...[
                                                const SizedBox(height: 2),
                                                Text(
                                                  _methodDescription(l10n, method),
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: colors.onSurface.withValues(alpha: 0.7),
                                                    fontSize: 11,
                                                    height: 1.05,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                    Switch(
                                      value: notifs.isMethodEnabled(type, method),
                                      onChanged: notifs.isPausedNow ||
                                              !notifs.isTypeEnabled(type) ||
                                              !notifs.isGlobalMethodEnabled(method)
                                          ? null
                                          : (value) => notifier.setNotificationMethodForType(type, method, value),
                                      activeThumbColor: colors.tertiary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
        if (notifs.isPausedNow) ...[
          const SizedBox(height: 10),
          Text(
            l10n.getString('settingsNotificationsMutedInfo'),
            style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.65)),
          ),
        ],
      ],
    ),
  );
}

String _muteQuickDurationLabel(LocalizationState l10n, Duration duration) {
  if (duration == const Duration(hours: 1)) return l10n.getString('settingsNotificationsMuteQuick1h');
  if (duration == const Duration(hours: 8)) return l10n.getString('settingsNotificationsMuteQuick8h');
  if (duration == const Duration(hours: 24)) return l10n.getString('settingsNotificationsMuteQuick24h');
  return formatDurationWords(l10n, duration);
}

List<NotificationMethod> _methodsForPlatform() {
  if (kIsWeb) {
    return const [
      NotificationMethod.push,
      NotificationMethod.inApp,
    ];
  }

  final platform = defaultTargetPlatform;
  final isMobile = platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  if (isMobile) {
    return const [
      NotificationMethod.push,
      NotificationMethod.inApp,
      NotificationMethod.sound,
      NotificationMethod.vibrate,
    ];
  }

  return const [
    NotificationMethod.inApp,
  ];
}

String _typeLabel(LocalizationState l10n, NotificationType type) {
  return switch (type) {
    NotificationType.chatMessages => l10n.getString('settingsNotificationsChatMessages'),
    NotificationType.newMatch => l10n.getString('settingsNotificationsNewMatches'),
    NotificationType.expiringMatch => l10n.getString('settingsNotificationsMatchExpiry'),
    NotificationType.adminAnnouncements => l10n.getString('settingsNotificationsAdmin'),
  };
}

String _methodLabel(LocalizationState l10n, NotificationMethod method) {
  return switch (method) {
    NotificationMethod.push => l10n.getString(kIsWeb ? 'settingsNotificationsMethodBrowser' : 'settingsNotificationsMethodPush'),
    NotificationMethod.inApp => l10n.getString('settingsNotificationsMethodInApp'),
    NotificationMethod.sound => l10n.getString('settingsNotificationsSound'),
    NotificationMethod.vibrate => l10n.getString('settingsNotificationsVibration'),
  };
}

String _methodDescription(LocalizationState l10n, NotificationMethod method) {
  final key = switch (method) {
    NotificationMethod.push => kIsWeb ? 'settingsNotificationsMethodBrowserDesc' : 'settingsNotificationsMethodPushDesc',
    NotificationMethod.inApp => 'settingsNotificationsMethodInAppDesc',
    NotificationMethod.sound => 'settingsNotificationsMethodSoundDesc',
    NotificationMethod.vibrate => 'settingsNotificationsMethodVibrationDesc',
  };
  return l10n.getString(key);
}

Future<void> _showMethodInfoDialog(
  BuildContext context,
  LocalizationState l10n,
  NotificationMethod method,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(_methodLabel(l10n, method)),
        content: Text(_methodDescription(l10n, method)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.getString('generalClose')),
          ),
        ],
      );
    },
  );
}

IconData _methodIcon(NotificationMethod method) {
  return switch (method) {
    NotificationMethod.push => kIsWeb ? Icons.language : Icons.notifications,
    NotificationMethod.inApp => Icons.phone_iphone,
    NotificationMethod.sound => Icons.volume_up,
    NotificationMethod.vibrate => Icons.vibration,
  };
}
