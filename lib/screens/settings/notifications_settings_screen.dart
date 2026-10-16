// lib/screens/settings/notifications_settings_screen.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/encrypted_notification_preview_service.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/widgets/safe_text.dart';

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
        title: ShrinkText(l10n.getString('settingsNotifications')),
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
          const SizedBox(height: 8),
          _MessagePreviewToggle(colors: colors, theme: theme),

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
            : (notifs.pausedDurationSeconds != null
                  ? 'dur:${notifs.pausedDurationSeconds}'
                  : null));
  final statusText = () {
    if (!isPaused) return l10n.getString('settingsNotificationsMuteAllOff');
    if (notifs.pausedIndefinitely) {
      return l10n.getString('settingsNotificationsMutedForever');
    }
    if (resumesAt != null) {
      final ts = formatDateAndTimeOfDateTimeWithPrefs(
        context,
        ref,
        l10n,
        resumesAt,
      );
      return l10n.getString(
        'settingsNotificationsMutedUntilValue',
        params: {'value': ts},
      );
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
              child: Icon(
                Icons.pause_circle_outline,
                color: colors.tertiary,
                size: 20,
              ),
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
            final quickDurations =
                (snapshot.data ?? const <Duration>[])
                    .where((d) => d > Duration.zero)
                    .toSet()
                    .toList()
                  ..sort((a, b) => a.inSeconds.compareTo(b.inSeconds));

            final itemValues = <String>{
              'off',
              'until_off',
              for (final d in quickDurations) 'dur:${d.inSeconds}',
            };
            final initialValue =
                (dropdownValue != null && itemValues.contains(dropdownValue))
                ? dropdownValue
                : null;

            return DropdownButtonFormField<String>(
              key: ValueKey<String>(dropdownValue ?? '__none__'),
              initialValue: initialValue,
              hint: Text(l10n.getString('settingsNotificationsMuteUntil')),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              items: [
                DropdownMenuItem(
                  value: 'off',
                  child: Text(
                    l10n.getString('settingsNotificationsMuteAllOff'),
                  ),
                ),
                for (final d in quickDurations)
                  DropdownMenuItem(
                    value: 'dur:${d.inSeconds}',
                    child: Text(_muteQuickDurationLabel(l10n, d)),
                  ),
                DropdownMenuItem(
                  value: 'until_off',
                  child: Text(
                    l10n.getString('settingsNotificationsMuteForever'),
                  ),
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
    NotificationType.matchExtended,
    NotificationType.adminAnnouncements,
    NotificationType.locationSharing,
  ];
  final methods = _methodsForPlatform();

  bool isMethodEnabledForAllEnabledTypes(NotificationMethod method) {
    return notifs.isGlobalMethodEnabled(method);
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
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            children: [
              for (var i = 0; i < methods.length; i++) ...[
                _notificationMethodTile(
                  context: context,
                  l10n: l10n,
                  theme: theme,
                  colors: colors,
                  method: methods[i],
                  value: isMethodEnabledForAllEnabledTypes(methods[i]),
                  onChanged: notifs.isPausedNow
                      ? null
                      : (value) => notifier.setGlobalNotificationMethodEnabled(
                          methods[i],
                          value,
                        ),
                  accentColor: colors.secondary,
                ),
                if (i != methods.length - 1)
                  Divider(
                    height: 1,
                    indent: 68,
                    endIndent: 16,
                    color: colors.outlineVariant.withValues(alpha: 0.35),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < types.length; i++) ...[
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: PageStorageKey<String>(
                  'notifications_type_${types[i].name}',
                ),
                initiallyExpanded: i == 0,
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _typeIcon(types[i]),
                        color: colors.primary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _typeLabel(l10n, types[i]),
                        style: TextStyle(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: notifs.isTypeEnabled(types[i]),
                      onChanged: notifs.isPausedNow
                          ? null
                          : (value) => notifier.setNotificationTypeEnabled(
                              types[i],
                              value,
                            ),
                      activeThumbColor: colors.primary,
                    ),
                  ],
                ),
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        for (
                          var methodIndex = 0;
                          methodIndex < methods.length;
                          methodIndex++
                        ) ...[
                          _notificationMethodTile(
                            context: context,
                            l10n: l10n,
                            theme: theme,
                            colors: colors,
                            method: methods[methodIndex],
                            value: notifs.isMethodEnabled(
                              types[i],
                              methods[methodIndex],
                            ),
                            onChanged:
                                notifs.isPausedNow ||
                                    !notifs.isTypeEnabled(types[i]) ||
                                    !notifs.isGlobalMethodEnabled(
                                      methods[methodIndex],
                                    )
                                ? null
                                : (value) =>
                                      notifier.setNotificationMethodForType(
                                        types[i],
                                        methods[methodIndex],
                                        value,
                                      ),
                            accentColor: colors.tertiary,
                          ),
                          if (methodIndex != methods.length - 1)
                            Divider(
                              height: 1,
                              indent: 68,
                              endIndent: 16,
                              color: colors.outlineVariant.withValues(
                                alpha: 0.3,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (i != types.length - 1) const SizedBox(height: 10),
        ],
        if (notifs.isPausedNow) ...[
          const SizedBox(height: 10),
          Text(
            l10n.getString('settingsNotificationsMutedInfo'),
            style: TextStyle(
              fontSize: 12,
              color: colors.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ],
    ),
  );
}

Widget _notificationMethodTile({
  required BuildContext context,
  required LocalizationState l10n,
  required ThemeData theme,
  required ColorScheme colors,
  required NotificationMethod method,
  required bool value,
  required ValueChanged<bool>? onChanged,
  required Color accentColor,
}) {
  final isInteractive = onChanged != null;
  final titleColor = isInteractive
      ? colors.onSurface
      : colors.onSurface.withValues(alpha: 0.58);
  final descriptionColor = isInteractive
      ? colors.onSurface.withValues(alpha: 0.72)
      : colors.onSurface.withValues(alpha: 0.48);

  return AnimatedOpacity(
    duration: const Duration(milliseconds: 180),
    opacity: isInteractive ? 1 : 0.72,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showMethodInfoDialog(context, l10n, method),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(_methodIcon(method), size: 20, color: accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _methodLabel(l10n, method),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _methodDescription(l10n, method),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: descriptionColor,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Switch.adaptive(
                value: value,
                onChanged: onChanged,
                activeThumbColor: accentColor,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _muteQuickDurationLabel(LocalizationState l10n, Duration duration) {
  if (duration == const Duration(hours: 1)) {
    return l10n.getString('settingsNotificationsMuteQuick1h');
  }
  if (duration == const Duration(hours: 8)) {
    return l10n.getString('settingsNotificationsMuteQuick8h');
  }
  if (duration == const Duration(hours: 24)) {
    return l10n.getString('settingsNotificationsMuteQuick24h');
  }
  return formatDurationWords(l10n, duration);
}

List<NotificationMethod> _methodsForPlatform() {
  if (kIsWeb) {
    return const [NotificationMethod.push, NotificationMethod.inApp];
  }

  final platform = defaultTargetPlatform;
  final isMobile =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  if (isMobile) {
    return const [
      NotificationMethod.push,
      NotificationMethod.inApp,
      NotificationMethod.sound,
      NotificationMethod.vibrate,
    ];
  }

  return const [NotificationMethod.inApp];
}

String _typeLabel(LocalizationState l10n, NotificationType type) {
  return switch (type) {
    NotificationType.chatMessages => l10n.getString(
      'settingsNotificationsChatMessages',
    ),
    NotificationType.newMatch => l10n.getString(
      'settingsNotificationsNewMatches',
    ),
    NotificationType.expiringMatch => l10n.getString(
      'settingsNotificationsMatchExpiry',
    ),
    NotificationType.matchExtended => l10n.getString(
      'settingsNotificationsMatchExtended',
    ),
    NotificationType.adminAnnouncements => l10n.getString(
      'settingsNotificationsAdmin',
    ),
    NotificationType.locationSharing => l10n.getString(
      'settingsNotificationsLocationSharing',
    ),
  };
}

IconData _typeIcon(NotificationType type) {
  return switch (type) {
    NotificationType.chatMessages => Icons.chat_bubble_outline,
    NotificationType.newMatch => Icons.favorite_border,
    NotificationType.expiringMatch => Icons.schedule_outlined,
    NotificationType.matchExtended => Icons.more_time_outlined,
    NotificationType.adminAnnouncements => Icons.campaign_outlined,
    NotificationType.locationSharing => Icons.share_location,
  };
}

String _methodLabel(LocalizationState l10n, NotificationMethod method) {
  return switch (method) {
    NotificationMethod.push => l10n.getString(
      kIsWeb
          ? 'settingsNotificationsMethodBrowser'
          : 'settingsNotificationsMethodPush',
    ),
    NotificationMethod.inApp => l10n.getString(
      'settingsNotificationsMethodInApp',
    ),
    NotificationMethod.sound => l10n.getString('settingsNotificationsSound'),
    NotificationMethod.vibrate => l10n.getString(
      'settingsNotificationsVibration',
    ),
  };
}

String _methodDescription(LocalizationState l10n, NotificationMethod method) {
  final key = switch (method) {
    NotificationMethod.push =>
      kIsWeb
          ? 'settingsNotificationsMethodBrowserDesc'
          : 'settingsNotificationsMethodPushDesc',
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

class _MessagePreviewToggle extends ConsumerStatefulWidget {
  const _MessagePreviewToggle({required this.colors, required this.theme});
  final ColorScheme colors;
  final ThemeData theme;

  @override
  ConsumerState<_MessagePreviewToggle> createState() =>
      _MessagePreviewToggleState();
}

class _MessagePreviewToggleState extends ConsumerState<_MessagePreviewToggle> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final val = await EncryptedNotificationPreviewService.instance
        .isPreviewEnabled(userId);
    if (mounted) {
      setState(() {
        _enabled = val;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.theme.dividerColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: widget.colors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.message_outlined,
              color: widget.colors.primary,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.getString('settingsNotificationsPreviewTitle'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: widget.colors.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.getString('settingsNotificationsPreviewDesc'),
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.colors.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _loaded ? _enabled : false,
            onChanged: _loaded
                ? (value) async {
                    final userId =
                        Supabase.instance.client.auth.currentUser?.id;
                    if (userId == null) return;
                    await EncryptedNotificationPreviewService.instance
                        .setPreviewEnabled(userId, value);
                    if (mounted) {
                      setState(() => _enabled = value);
                    }
                  }
                : null,
            activeTrackColor: widget.colors.primary,
          ),
        ],
      ),
    );
  }
}
