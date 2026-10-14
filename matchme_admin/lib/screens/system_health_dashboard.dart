// matchme_admin/lib/screens/system_health_dashboard.dart
//
// Live Supabase / system health dashboard for admins.
//
// Renders the shared [systemHealthProvider] snapshot produced by
// [SystemHealthMonitor]: overall status banner plus per-area cards for the
// database (health_check RPC latency), the Realtime WebSocket + tick
// heartbeat, the admin session, and the notification queue. Everything
// updates continuously from the monitor's probes and realtime channel —
// this screen never probes on its own.
//
// Read-only: no mutations. Offline-aware via AdminOfflineCacheManager.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/services/system_health_monitor.dart';
import 'package:matchme_admin/widgets/system_health_pill.dart';

typedef AdminHealthTextLookup =
    String Function(String key, {Map<String, String>? params});

class AdminSystemHealthDashboard extends ConsumerStatefulWidget {
  const AdminSystemHealthDashboard({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminHealthTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  ConsumerState<AdminSystemHealthDashboard> createState() =>
      _AdminSystemHealthDashboardState();
}

class _AdminSystemHealthDashboardState
    extends ConsumerState<AdminSystemHealthDashboard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String t(String key, {Map<String, String>? params}) {
    var value = widget.t(key, params: params);
    params?.forEach((paramKey, paramValue) {
      value = value.replaceAll('{$paramKey}', paramValue);
    });
    return value;
  }

  String _fmtClock(DateTime dt) {
    final local = dt.toLocal();
    try {
      return DateFormat.yMMMd(widget.localeCode).add_jm().format(local);
    } catch (_) {
      return DateFormat.yMMMd().add_jm().format(local);
    }
  }

  String _age(Duration d) => systemHealthAgeLabel(d);

  String _agoLabel(DateTime? dt) {
    if (dt == null) return '—';
    return _age(DateTime.now().difference(dt));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final health = ref.watch(systemHealthProvider);
    final snapshot = health.value ?? systemHealthMonitor.current;
    final isOffline = adminOfflineCacheManager.shouldUseCachedData();

    return Directionality(
      textDirection: widget.textDirection,
      child: RefreshIndicator(
        onRefresh: () async {},
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t('adminNavSystemHealth'),
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                Text(
                  t('adminHealthUpdatedAgo', params: {
                    'age': _agoLabel(snapshot.updatedAt),
                  }),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              t('adminHealthSubtitle'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (isOffline) ...[
              _noticeCard(
                theme,
                icon: Icons.cloud_off,
                color: Colors.red,
                text: t('adminHealthStaleData'),
              ),
              const SizedBox(height: 12),
            ],
            _overallBanner(theme, snapshot),
            const SizedBox(height: 12),
            _databaseCard(theme, snapshot),
            const SizedBox(height: 12),
            _realtimeCard(theme, snapshot),
            const SizedBox(height: 12),
            _sessionCard(theme, snapshot),
            const SizedBox(height: 12),
            _queueCard(theme, snapshot),
          ],
        ),
      ),
    );
  }

  // ── Overall banner ────────────────────────────────────────────────

  Widget _overallBanner(ThemeData theme, SystemHealthSnapshot s) {
    final color = systemHealthStatusColor(s.overall);
    final label = systemHealthStatusLabel(s.overall, t);
    final detail = _overallDetail(s);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          if (s.overall == SystemHealthStatus.healthy ||
              s.overall == SystemHealthStatus.checking)
            SystemHealthPulseDot(color: color, size: 12)
          else
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          Icon(Icons.monitor_heart, color: color),
        ],
      ),
    );
  }

  String? _overallDetail(SystemHealthSnapshot s) {
    if (s.dbConsecutiveFailures >= 1) {
      return t('adminHealthDbError', params: {
        'error': s.dbError ?? t('adminHealthStatusDown'),
      });
    }
    if (s.socketEverConnected && s.socketState != 'open') {
      return t('adminHealthSocketState', params: {'state': s.socketState});
    }
    final tick = s.lastTickAt;
    if (tick != null &&
        DateTime.now().difference(tick) > const Duration(minutes: 3)) {
      return t('adminHealthLastTick', params: {'age': _agoLabel(tick)});
    }
    if (s.queueHealth?['alert'] == true) {
      return t('adminHealthQueueAlertDetail');
    }
    if (s.sessionExpiringSoon) {
      return t('adminHealthSessionExpiringSoon');
    }
    return null;
  }

  // ── Database card ─────────────────────────────────────────────────

  Widget _databaseCard(ThemeData theme, SystemHealthSnapshot s) {
    final status = !s.dbOk
        ? (s.dbConsecutiveFailures >= 2
              ? SystemHealthStatus.down
              : SystemHealthStatus.degraded)
        : (s.dbLatencyMs != null &&
              s.dbLatencyMs! > 1500 &&
              s.dbConsecutiveFailures == 0
              ? SystemHealthStatus.degraded
              : SystemHealthStatus.healthy);

    return _card(
      theme,
      titleKey: 'adminHealthDatabase',
      icon: Icons.storage_outlined,
      status: status,
      children: [
        _kv(
          theme,
          t('adminHealthLatency'),
          s.dbLatencyMs == null ? '—' : t('adminHealthLatencyMs', params: {
            'ms': '${s.dbLatencyMs}',
          }),
        ),
        if (s.dbLatencyHistory.isNotEmpty) ...[
          const SizedBox(height: 8),
          _latencyBars(theme, s.dbLatencyHistory),
        ],
        _kv(theme, t('adminHealthLastChecked'), _agoLabel(s.dbLastCheckedAt)),
        _kv(theme, t('adminHealthLastOk'), _agoLabel(s.dbLastOkAt)),
        if (s.dbConsecutiveFailures > 0)
          _kv(
            theme,
            t('adminHealthConsecutiveFailures'),
            '${s.dbConsecutiveFailures}',
          ),
        if (s.dbError != null) ...[
          const SizedBox(height: 8),
          Text(
            t('adminHealthDbError', params: {'error': s.dbError!}),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _latencyBars(ThemeData theme, List<int> history) {
    const maxBars = 24;
    final values = history.length <= maxBars
        ? history
        : history.sublist(history.length - maxBars);
    final peak = values.fold<int>(1, (m, v) => v > m ? v : m);

    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  height: (4 + (v / peak) * 24).clamp(4.0, 28.0),
                  decoration: BoxDecoration(
                    color: v > 1500
                        ? Colors.orange
                        : theme.colorScheme.primary.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Realtime card ─────────────────────────────────────────────────

  Widget _realtimeCard(ThemeData theme, SystemHealthSnapshot s) {
    SystemHealthStatus status;
    if (s.socketState == 'open') {
      final tick = s.lastTickAt;
      final stale =
          tick != null &&
          DateTime.now().difference(tick) > const Duration(minutes: 3);
      status = stale
          ? SystemHealthStatus.degraded
          : SystemHealthStatus.healthy;
    } else if (s.socketState == 'connecting') {
      status = SystemHealthStatus.checking;
    } else {
      status = s.socketEverConnected
          ? SystemHealthStatus.degraded
          : SystemHealthStatus.checking;
    }

    return _card(
      theme,
      titleKey: 'adminHealthRealtime',
      icon: Icons.bolt_outlined,
      status: status,
      children: [
        _kv(theme, t('adminHealthSocketLabel'), s.socketState),
        _kv(
          theme,
          t('adminHealthLastTickLabel'),
          s.lastTickAt == null
              ? t('adminHealthNoTicksYet')
              : t('adminHealthLastTick', params: {'age': _agoLabel(s.lastTickAt)}),
        ),
      ],
    );
  }

  // ── Session card ──────────────────────────────────────────────────

  Widget _sessionCard(ThemeData theme, SystemHealthSnapshot s) {
    final status = !s.sessionActive
        ? SystemHealthStatus.degraded
        : (s.sessionExpiringSoon
              ? SystemHealthStatus.degraded
              : SystemHealthStatus.healthy);

    final left = s.sessionTimeLeft;

    return _card(
      theme,
      titleKey: 'adminHealthSession',
      icon: Icons.person_outline,
      status: status,
      children: [
        _kv(
          theme,
          t('adminHealthSessionActive'),
          s.sessionActive
              ? t('adminHealthStatusHealthy')
              : t('adminHealthStatusDown'),
        ),
        if (s.sessionExpiresAt != null)
          _kv(
            theme,
            t('adminHealthSessionExpires'),
            _fmtClock(s.sessionExpiresAt!),
          ),
        if (left != null)
          _kv(theme, t('adminHealthSessionTimeLeft'), _age(left)),
        if (s.sessionExpiringSoon) ...[
          const SizedBox(height: 8),
          Text(
            t('adminHealthSessionExpiringSoon'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.orange,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  // ── Notification queue card ───────────────────────────────────────

  Widget _queueCard(ThemeData theme, SystemHealthSnapshot s) {
    final q = s.queueHealth;
    final status = q == null
        ? SystemHealthStatus.checking
        : (q['alert'] == true
              ? SystemHealthStatus.degraded
              : SystemHealthStatus.healthy);

    int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

    return _card(
      theme,
      titleKey: 'adminHealthQueue',
      icon: Icons.notifications_active_outlined,
      status: status,
      trailing: q == null
          ? null
          : Text(
              t('adminHealthQueueCheckedAgo', params: {
                'age': _agoLabel(s.queueCheckedAt),
              }),
              style: theme.textTheme.labelSmall,
            ),
      children: [
        if (q == null)
          Text(t('adminHealthStatusChecking'), style: theme.textTheme.bodySmall)
        else ...[
          _kv(theme, t('adminHealthQueuePending'), '${asInt(q['pending'])}'),
          _kv(
            theme,
            t('adminHealthQueueProcessing'),
            '${asInt(q['processing'])}',
          ),
          _kv(
            theme,
            t('adminHealthQueueFailedHour'),
            '${asInt(q['failed_last_hour'])}',
          ),
          _kv(
            theme,
            t('adminHealthQueueOldestPending'),
            systemHealthAgeLabel(
              Duration(seconds: asInt(q['oldest_pending_age_sec'])),
            ),
          ),
          if (q['alert'] == true) ...[
            const SizedBox(height: 8),
            Text(
              t('adminHealthQueueAlertDetail'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ],
    );
  }

  // ── Shared building blocks ────────────────────────────────────────

  Widget _noticeCard(
    ThemeData theme, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _card(
    ThemeData theme, {
    required String titleKey,
    required IconData icon,
    required SystemHealthStatus status,
    required List<Widget> children,
    Widget? trailing,
  }) {
    final color = systemHealthStatusColor(status);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t(titleKey),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                ?trailing,
                const SizedBox(width: 8),
                _statusChip(theme, status),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _statusChip(ThemeData theme, SystemHealthStatus status) {
    final color = systemHealthStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        systemHealthStatusLabel(status, t),
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
