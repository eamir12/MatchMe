import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/system_notification_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/location_share_countdown.dart';

class SystemNotificationOverlay extends ConsumerStatefulWidget {
  const SystemNotificationOverlay({super.key});

  @override
  ConsumerState<SystemNotificationOverlay> createState() =>
      _SystemNotificationOverlayState();
}

class _SystemNotificationOverlayState
    extends ConsumerState<SystemNotificationOverlay>
    with SingleTickerProviderStateMixin {
  AnimationController? _animationController;
  Animation<Offset>? _slideAnimation;
  Timer? _countdownTicker;
  DateTime? _tickingExpiresAt;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(parent: _animationController!, curve: Curves.easeOut),
        );
  }

  void _syncCountdownTicker(SystemNotification? n) {
    final expiresAt = n?.countdownExpiresAt;
    if (_countdownTicker != null && expiresAt == _tickingExpiresAt) return;

    _countdownTicker?.cancel();
    _countdownTicker = null;
    _tickingExpiresAt = null;
    if (!mounted || expiresAt == null) return;

    _tickingExpiresAt = expiresAt;
    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _countdownTicker?.cancel();
        _countdownTicker = null;
        return;
      }
      if (DateTime.now().isAfter(expiresAt)) {
        _countdownTicker?.cancel();
        _countdownTicker = null;
        // Clear only if this countdown notification is still the active one.
        if (ref.read(systemNotificationProvider)?.countdownExpiresAt ==
            expiresAt) {
          ref.read(systemNotificationProvider.notifier).clear();
        }
        return;
      }
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTicker?.cancel();
    _animationController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SystemNotification?>(systemNotificationProvider, (
      previous,
      next,
    ) {
      if (next != null) {
        _animationController?.forward();
      } else {
        _animationController?.reverse();
      }
    });

    final l10n = ref.watch(localizationProvider);
    final n = ref.watch(systemNotificationProvider);
    _syncCountdownTicker(n);
    if (n == null) return const SizedBox.shrink();

    if (n.notificationType == 'admin_broadcast') {
      final notifs = ref.watch(userPreferencesProvider).notifications;
      if (notifs.isPausedNow) return const SizedBox.shrink();
      if (!notifs.isMethodEnabled(
        NotificationType.adminAnnouncements,
        NotificationMethod.inApp,
      )) {
        return const SizedBox.shrink();
      }
    }

    if (n.notificationType == 'location_sharing') {
      final notifs = ref.watch(userPreferencesProvider).notifications;
      if (notifs.isPausedNow) return const SizedBox.shrink();
      if (!notifs.isMethodEnabled(
        NotificationType.locationSharing,
        NotificationMethod.inApp,
      )) {
        return const SizedBox.shrink();
      }
    }

    // Choose icon based on notification type
    IconData icon;
    switch (n.notificationType) {
      case 'battery_throttle':
        icon = Icons.battery_alert_outlined;
        break;
      case 'stationary_throttle':
        icon = Icons.my_location;
        break;
      case 'admin_broadcast':
        icon = Icons.campaign_outlined;
        break;
      case 'location_sharing':
        icon = Icons.share_location;
        break;
      default:
        icon = Icons.info_outline;
    }

    final actionUrl = (n.actionUrl ?? '').trim();
    final hasAction = actionUrl.isNotEmpty;

    String displayText = n.text;
    if (n.countdownExpiresAt != null) {
      displayText =
          '$displayText${buildLocationShareCountdownSuffix(expiresAt: n.countdownExpiresAt, now: DateTime.now(), getString: l10n.getString)}';
    }

    return Positioned(
      top: 110,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slideAnimation!,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Material(
            elevation: 9,
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.primary,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 12.0,
              ),
              child: Row(
                children: [
                  Icon(icon, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        if (hasAction) ...[
                          const SizedBox(height: 6),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 0),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () async {
                              try {
                                final uri = Uri.parse(actionUrl);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              } catch (_) {}
                            },
                            child: Text(
                              (n.actionText ?? l10n.getString('open'))
                                      .trim()
                                      .isEmpty
                                  ? l10n.getString('open')
                                  : (n.actionText ?? l10n.getString('open'))
                                        .trim(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () => ref
                        .read(systemNotificationProvider.notifier)
                        .dismissCurrent(),
                    tooltip: l10n.getString('dismiss'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
