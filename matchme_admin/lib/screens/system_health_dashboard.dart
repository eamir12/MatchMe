// matchme_admin/lib/screens/system_health_dashboard.dart
//
// Live Supabase / system health dashboard for admins.
//
// Renders the shared [systemHealthProvider] snapshot produced by
// [SystemHealthMonitor]. The first card is Supabase's official status from
// status.supabase.com (overall verdict, named components, affected regions,
// active incidents); below that are this project's own probes: database
// (health_check RPC latency), the Realtime WebSocket + tick heartbeat, the
// notification queue, recent project failures (edge/cron/app errors), and
// sign-ins + usage metrics from the project-logs-health function.
// Everything updates continuously from the monitor — this screen never
// probes on its own.
//
// Read-only: no mutations. Offline-aware via AdminOfflineCacheManager.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/services/system_health_monitor.dart';
import 'package:matchme_admin/utils/open_attachment.dart';
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

  /// Tap-selected latency bar (matched by timestamp across history shifts).
  SystemHealthLatencySample? _selectedSample;

  String t(String key, {Map<String, String>? params}) {
    var value = widget.t(key, params: params);
    params?.forEach((paramKey, paramValue) {
      value = value.replaceAll('{$paramKey}', paramValue);
    });
    return value;
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
            _officialStatusCard(theme, snapshot),
            const SizedBox(height: 12),
            _databaseCard(theme, snapshot),
            const SizedBox(height: 12),
            _realtimeCard(theme, snapshot),
            const SizedBox(height: 12),
            _queueCard(theme, snapshot),
            const SizedBox(height: 12),
            _projectErrorsCard(theme, snapshot),
            const SizedBox(height: 12),
            _signInsCard(theme, snapshot),
            const SizedBox(height: 12),
            _usageCard(theme, snapshot),
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
    // Supabase's own description of an ongoing incident is the most
    // authoritative explanation — show it first.
    final indicator = s.spIndicator;
    if (indicator != null && indicator != 'none' && s.spDescription != null) {
      return s.spDescription;
    }
    if (s.dbConsecutiveFailures >= 1) {
      return t('adminHealthDbError', params: {
        'error': s.dbError ?? t('adminHealthStatusDown'),
      });
    }
    if (s.socketEverConnected && s.socketState != 'open') {
      return t('adminHealthSocketState', params: {'state': s.socketState});
    }
    if (s.heartbeatStale) {
      return t('adminHealthLastTick', params: {'age': _agoLabel(s.lastTickAt)});
    }
    if (s.queueHealth?['alert'] == true) {
      return t('adminHealthQueueAlertDetail');
    }
    if (s.projectErrors?.alert == true) {
      return t('adminHealthErrorsAlertDetail');
    }
    final logs = s.projectLogs;
    if (logs != null && logs.alert) {
      if (logs.authAlert) {
        return t('adminHealthAuthAlertDetail', params: {
          'count': '${logs.authErrors15m ?? 0}',
        });
      }
      if (logs.diskAlert) {
        return t('adminHealthDiskAlertDetail', params: {
          'pct': (logs.diskUsedPercent ?? 0).round().toString(),
        });
      }
    }
    return null;
  }

  // ── Official Supabase status (status.supabase.com) ────────────────

  SystemHealthStatus _officialStatusOf(SystemHealthSnapshot s) {
    return switch (s.spIndicator) {
      null => SystemHealthStatus.checking,
      'none' => SystemHealthStatus.healthy,
      'maintenance' || 'minor' => SystemHealthStatus.degraded,
      'major' || 'critical' => SystemHealthStatus.down,
      _ => SystemHealthStatus.degraded,
    };
  }

  Color _componentColor(String status) {
    return switch (status) {
      'operational' => Colors.green,
      'maintenance' => Colors.blueGrey,
      'degraded_performance' => Colors.orange,
      'partial_outage' => Colors.deepOrange,
      'major_outage' => Colors.red,
      _ => Colors.grey,
    };
  }

  String _componentLabel(String status) {
    return switch (status) {
      'operational' => t('adminHealthComponentOperational'),
      'maintenance' => t('adminHealthComponentMaintenance'),
      'degraded_performance' => t('adminHealthComponentDegraded'),
      'partial_outage' => t('adminHealthComponentPartialOutage'),
      'major_outage' => t('adminHealthComponentMajorOutage'),
      _ => status,
    };
  }

  Widget _officialStatusCard(ThemeData theme, SystemHealthSnapshot s) {
    final status = _officialStatusOf(s);
    final color = systemHealthStatusColor(status);

    return _card(
      theme,
      titleKey: 'adminHealthSupabaseStatus',
      icon: Icons.cloud_outlined,
      status: status,
      children: [
        if (s.spCheckedAt != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              t('adminHealthSupabaseSource', params: {
                'age': _agoLabel(s.spCheckedAt),
              }),
              style: theme.textTheme.labelSmall,
            ),
          ),
        if (!s.spAvailable && s.spIndicator == null)
          Text(
            t('adminHealthSupabaseUnavailable'),
            style: theme.textTheme.bodySmall,
          )
        else ...[
          if (s.spDescription != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                s.spDescription!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          for (final c in s.spComponents)
            _componentRow(theme, c.name, _componentLabel(c.status),
                _componentColor(c.status)),
          if (s.spAffectedRegions.isEmpty && s.spRegionsTotal > 0)
            _componentRow(
              theme,
              t('adminHealthRegionsLabel'),
              t('adminHealthRegionsAllOk', params: {
                'total': '${s.spRegionsTotal}',
              }),
              Colors.green,
            )
          else if (s.spAffectedRegions.isNotEmpty) ...[
            _componentRow(
              theme,
              t('adminHealthRegionsLabel'),
              t('adminHealthRegionsAffected', params: {
                'count': '${s.spAffectedRegions.length}',
                'total': '${s.spRegionsTotal}',
              }),
              Colors.orange,
            ),
            for (final r in s.spAffectedRegions.take(8))
              _componentRow(
                theme,
                r.name,
                _componentLabel(r.status),
                _componentColor(r.status),
              ),
            if (s.spAffectedRegions.length > 8)
              Text(
                t('adminHealthRegionsMore', params: {
                  'count': '${s.spAffectedRegions.length - 8}',
                }),
                style: theme.textTheme.bodySmall,
              ),
          ],
          const SizedBox(height: 8),
          Text(
            t('adminHealthIncidents'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          if (s.spIncidents.isEmpty)
            Text(t('adminHealthNoIncidents'), style: theme.textTheme.bodySmall)
          else
            for (final incident in s.spIncidents) _incidentRow(theme, incident),
        ],
      ],
    );
  }

  Widget _componentRow(
    ThemeData theme,
    String name,
    String label,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(name, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _incidentRow(ThemeData theme, SupabaseIncidentStatus incident) {
    final impactColor = switch (incident.impact) {
      'critical' || 'major' => Colors.red,
      'minor' => Colors.orange,
      _ => Colors.blueGrey,
    };
    final shortlink = incident.shortlink;

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.report_outlined, size: 16, color: impactColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  incident.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                    t('adminHealthIncidentImpact', params: {
                      'impact': incident.impact,
                    }),
                    incident.status,
                    if (incident.updatedAt != null)
                      t('adminHealthIncidentUpdated', params: {
                        'age': _agoLabel(incident.updatedAt),
                      }),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: impactColor,
                  ),
                ),
              ],
            ),
          ),
          if (shortlink != null)
            Icon(Icons.open_in_new, size: 14, color: theme.hintColor),
        ],
      ),
    );

    if (shortlink == null) return content;
    return InkWell(
      onTap: () => unawaited(openUrlExternal(shortlink)),
      child: content,
    );
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
          const SizedBox(height: 6),
          Text(
            t('adminHealthLatencyCaption'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          if (_slowSampleCount(s.dbLatencyHistory) > 0) ...[
            const SizedBox(height: 2),
            Text(
              t('adminHealthLatencySlowCount', params: {
                'count': '${_slowSampleCount(s.dbLatencyHistory)}',
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.orange,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (_selectedSample != null &&
              s.dbLatencyHistory.any((x) => x.at == _selectedSample!.at)) ...[
            const SizedBox(height: 2),
            Text(
              t('adminHealthLatencySample', params: {
                'ms': '${_selectedSample!.ms}',
                'time': _fmtSampleTime(_selectedSample!.at),
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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

  Widget _latencyBars(ThemeData theme, List<SystemHealthLatencySample> all) {
    const maxBars = 24;
    final samples = all.length <= maxBars
        ? all
        : all.sublist(all.length - maxBars);
    final peak = samples.fold<int>(1, (m, x) => x.ms > m ? x.ms : m);
    final selectedAt = _selectedSample?.at;

    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final sample in samples)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() {
                    if (_selectedSample?.at == sample.at) {
                      _selectedSample = null;
                    } else {
                      _selectedSample = sample;
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 1,
                    vertical: 2,
                  ),
                  child: Container(
                    height: (4 + (sample.ms / peak) * 24).clamp(4.0, 28.0),
                    decoration: BoxDecoration(
                      color: sample.ms > 1500
                          ? Colors.orange
                          : (selectedAt == sample.at
                                ? theme.colorScheme.primary
                                : theme.colorScheme.primary.withValues(
                                    alpha: 0.55,
                                  )),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  int _slowSampleCount(List<SystemHealthLatencySample> samples) {
    return samples.where((x) => x.ms > 1500).length;
  }

  String _fmtSampleTime(DateTime dt) {
    try {
      return DateFormat('HH:mm:ss', widget.localeCode).format(dt.toLocal());
    } catch (_) {
      return DateFormat('HH:mm:ss').format(dt.toLocal());
    }
  }

  // ── Realtime card ─────────────────────────────────────────────────

  Widget _realtimeCard(ThemeData theme, SystemHealthSnapshot s) {
    SystemHealthStatus status;
    if (s.socketState == 'open') {
      status = s.heartbeatStale
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

  // ── Project errors card ───────────────────────────────────────────

  Widget _projectErrorsCard(ThemeData theme, SystemHealthSnapshot s) {
    final e = s.projectErrors;
    final status = e == null
        ? SystemHealthStatus.checking
        : (e.alert
            ? SystemHealthStatus.degraded
            : SystemHealthStatus.healthy);

    String rowValue(int count, DateTime? at) => count == 0
        ? t('adminHealthErrorsNone')
        : t('adminHealthErrorsValue', params: {
            'count': '$count',
            'age': _agoLabel(at),
          });
    Color rowColor(int count) => count == 0 ? Colors.green : Colors.orange;

    return _card(
      theme,
      titleKey: 'adminHealthErrorsTitle',
      icon: Icons.bug_report_outlined,
      status: status,
      trailing: e == null
          ? null
          : Text(
              t('adminHealthUpdatedAgo', params: {'age': _agoLabel(e.checkedAt)}),
              style: theme.textTheme.labelSmall,
            ),
      children: [
        if (e == null)
          Text(t('adminHealthStatusChecking'), style: theme.textTheme.bodySmall)
        else ...[
          _componentRow(
            theme,
            t('adminHealthErrorsEdge'),
            rowValue(e.edgeFailed15m, e.edgeLastFailedAt),
            rowColor(e.edgeFailed15m),
          ),
          _componentRow(
            theme,
            t('adminHealthErrorsCron'),
            rowValue(e.cronFailed1h, e.cronLastFailedAt),
            rowColor(e.cronFailed1h),
          ),
          if (e.cronLastFailedTasks.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 4),
              child: Text(
                t('adminHealthErrorsFailedTasks', params: {
                  'tasks': e.cronLastFailedTasks.join(', '),
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
              ),
            ),
          _componentRow(
            theme,
            t('adminHealthErrorsApp'),
            rowValue(e.appErrors15m, e.appLastErrorAt),
            rowColor(e.appErrors15m),
          ),
          if (e.appErrors15m > 0 &&
              e.appLastMessage != null &&
              e.appLastMessage!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                t('adminHealthErrorsAppLast', params: {
                  'source': e.appLastSource ?? '—',
                  'message': e.appLastMessage!,
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.orange,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }

  // ── Sign-ins card ─────────────────────────────────────────────────

  Widget _signInsCard(ThemeData theme, SystemHealthSnapshot s) {
    final l = s.projectLogs;
    final status = l == null || !l.configured
        ? SystemHealthStatus.checking
        : (l.authAlert
              ? SystemHealthStatus.degraded
              : SystemHealthStatus.healthy);
    final authWarnings = [
      if (l != null)
        for (final w in l.warnings)
          if (w.startsWith('signins_') || w.startsWith('auth_error')) w,
    ];

    return _card(
      theme,
      titleKey: 'adminHealthSignInsTitle',
      icon: Icons.login_outlined,
      status: status,
      trailing: l == null
          ? null
          : Text(
              t('adminHealthUpdatedAgo', params: {
                'age': _agoLabel(l.checkedAt),
              }),
              style: theme.textTheme.labelSmall,
            ),
      children: [
        if (l == null)
          Text(t('adminHealthStatusChecking'), style: theme.textTheme.bodySmall)
        else if (!l.configured)
          Text(t('adminHealthNotConfigured'), style: theme.textTheme.bodySmall)
        else ...[
          _componentRow(
            theme,
            t('adminHealthSignIns15m'),
            l.signins15m == null ? '—' : '${l.signins15m}',
            Colors.blueGrey,
          ),
          if (l.signins15m != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 4),
              child: Text(
                t('adminHealthSignInsLast', params: {
                  'age': _agoLabel(l.signinsLastAt),
                }),
                style: theme.textTheme.bodySmall,
              ),
            ),
          _componentRow(
            theme,
            t('adminHealthAuthErrors15m'),
            (l.authErrors15m ?? 0) == 0
                ? t('adminHealthErrorsNone')
                : t('adminHealthErrorsValue', params: {
                    'count': '${l.authErrors15m}',
                    'age': _agoLabel(l.authLastErrorAt),
                  }),
            (l.authErrors15m ?? 0) == 0
                ? Colors.green
                : ((l.authErrors15m ?? 0) >= kAuthFailureAlert
                      ? Colors.red
                      : Colors.orange),
          ),
          if ((l.authErrors15m ?? 0) > 0 &&
              (l.authLastErrorMessage?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2),
              child: Text(
                t('adminHealthAuthLastError', params: {
                  'action': l.authLastErrorAction ?? '—',
                  'message': l.authLastErrorMessage!,
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: (l.authErrors15m ?? 0) >= kAuthFailureAlert
                      ? Colors.red
                      : Colors.orange,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (authWarnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              t('adminHealthLogsWarnings', params: {
                'warnings': authWarnings.join(', '),
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ],
    );
  }

  // ── Project usage card ────────────────────────────────────────────

  Widget _usageCard(ThemeData theme, SystemHealthSnapshot s) {
    final l = s.projectLogs;
    final status = l == null || !l.configured
        ? SystemHealthStatus.checking
        : (l.diskAlert
              ? SystemHealthStatus.degraded
              : SystemHealthStatus.healthy);
    final usageWarnings = [
      if (l != null)
        for (final w in l.warnings)
          if (w.startsWith('disk_') || w.startsWith('api_')) w,
    ];

    return _card(
      theme,
      titleKey: 'adminHealthUsageTitle',
      icon: Icons.speed_outlined,
      status: status,
      trailing: l == null
          ? null
          : Text(
              t('adminHealthUpdatedAgo', params: {
                'age': _agoLabel(l.checkedAt),
              }),
              style: theme.textTheme.labelSmall,
            ),
      children: [
        if (l == null)
          Text(t('adminHealthStatusChecking'), style: theme.textTheme.bodySmall)
        else if (!l.configured)
          Text(t('adminHealthNotConfigured'), style: theme.textTheme.bodySmall)
        else ...[
          _kv(
            theme,
            t('adminHealthDiskUsage'),
            l.diskUsedBytes == null && l.diskSizeBytes == null
                ? '—'
                : t('adminHealthDiskUsageValue', params: {
                    'used': _gb(l.diskUsedBytes),
                    'size': _gb(l.diskSizeBytes),
                    'pct': l.diskUsedPercent == null
                        ? '—'
                        : '${l.diskUsedPercent!.round()}',
                  }),
          ),
          if (l.diskAlert)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t('adminHealthDiskAlertDetail', params: {
                  'pct': (l.diskUsedPercent ?? 0).round().toString(),
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          _kv(
            theme,
            t('adminHealthApiRequests'),
            l.apiRequestsCount == null ? '—' : '${l.apiRequestsCount}',
          ),
          if (usageWarnings.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              t('adminHealthLogsWarnings', params: {
                'warnings': usageWarnings.join(', '),
              }),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ],
    );
  }

  String _gb(int? bytes) {
    if (bytes == null) return '—';
    return (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
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
