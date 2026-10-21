// matchme_admin/lib/widgets/system_health_pill.dart
//
// Compact Supabase health status pill shown in the admin Dashboard header.
// Watches the shared [systemHealthProvider] so it stays in sync with the
// System Health screen without duplicating probes. Tapping it opens the
// System Health section (via the caller-provided [onTap]).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme_admin/services/system_health_monitor.dart';

typedef SystemHealthTextLookup =
    String Function(String key, {Map<String, String>? params, String? pluralParam});

/// Pulsing dot used by both the pill and the System Health screen banner.
class SystemHealthPulseDot extends StatefulWidget {
  const SystemHealthPulseDot({super.key, required this.color, this.size = 10});

  final Color color;
  final double size;

  @override
  State<SystemHealthPulseDot> createState() => _SystemHealthPulseDotState();
}

class _SystemHealthPulseDotState extends State<SystemHealthPulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 1, end: 0.45).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

Color systemHealthStatusColor(SystemHealthStatus status) {
  return switch (status) {
    SystemHealthStatus.healthy => Colors.green,
    SystemHealthStatus.degraded => Colors.orange,
    SystemHealthStatus.down => Colors.red,
    SystemHealthStatus.checking => Colors.grey,
  };
}

String systemHealthStatusLabel(
  SystemHealthStatus status,
  SystemHealthTextLookup t,
) {
  return switch (status) {
    SystemHealthStatus.healthy => t('adminHealthStatusHealthy'),
    SystemHealthStatus.degraded => t('adminHealthStatusDegraded'),
    SystemHealthStatus.down => t('adminHealthStatusDown'),
    SystemHealthStatus.checking => t('adminHealthStatusChecking'),
  };
}

class SystemHealthPill extends ConsumerWidget {
  const SystemHealthPill({super.key, this.t, this.onTap});

  final SystemHealthTextLookup? t;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(systemHealthProvider);
    final snapshot = health.value ?? systemHealthMonitor.current;
    final tr = t ?? ((String key, {Map<String, String>? params, String? pluralParam}) => key);
    final status = snapshot.overall;
    final color = systemHealthStatusColor(status);
    final theme = Theme.of(context);

    final label = systemHealthStatusLabel(status, tr);

    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status == SystemHealthStatus.healthy ||
              status == SystemHealthStatus.checking)
            SystemHealthPulseDot(color: color, size: 8)
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return pill;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: pill,
    );
  }
}
