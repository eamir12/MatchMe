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
// Card widgets live in widgets/system_health_cards.dart so the history
// replay screen renders identical cards; the header's History button opens
// SystemHealthHistoryScreen (7-day snapshot charts + instant replay).
//
// Read-only: no mutations. Offline-aware via AdminOfflineCacheManager.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme_admin/screens/system_health_history_screen.dart';
import 'package:matchme_admin/services/admin_offline_cache_manager.dart';
import 'package:matchme_admin/services/system_health_monitor.dart';
import 'package:matchme_admin/widgets/system_health_cards.dart';

export 'package:matchme_admin/widgets/system_health_cards.dart'
    show AdminHealthTextLookup;

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

  String _agoLabel(DateTime? dt) => SystemHealthCards.agoLabel(dt);

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SystemHealthHistoryScreen(
          t: widget.t,
          localeCode: widget.localeCode,
          textDirection: widget.textDirection,
        ),
      ),
    );
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
                OutlinedButton.icon(
                  onPressed: _openHistory,
                  icon: const Icon(Icons.history, size: 18),
                  label: Text(t('adminHealthHistoryButton')),
                ),
                const SizedBox(width: 8),
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
              SystemHealthCards.noticeCard(
                theme,
                icon: Icons.cloud_off,
                color: Colors.red,
                text: t('adminHealthStaleData'),
              ),
              const SizedBox(height: 12),
            ],
            SystemHealthCards.overallBanner(t: t, theme: theme, s: snapshot),
            const SizedBox(height: 12),
            SystemHealthCards.officialStatusCard(
              t: t,
              theme: theme,
              s: snapshot,
            ),
            const SizedBox(height: 12),
            SystemHealthCards.databaseCard(
              t: t,
              theme: theme,
              s: snapshot,
              localeCode: widget.localeCode,
              selectedSample: _selectedSample,
              onSelectSample: (sample) {
                setState(() => _selectedSample = sample);
              },
            ),
            const SizedBox(height: 12),
            SystemHealthCards.realtimeCard(t: t, theme: theme, s: snapshot),
            const SizedBox(height: 12),
            SystemHealthCards.queueCard(t: t, theme: theme, s: snapshot),
            const SizedBox(height: 12),
            SystemHealthCards.projectErrorsCard(t: t, theme: theme, s: snapshot),
            const SizedBox(height: 12),
            SystemHealthCards.signInsCard(t: t, theme: theme, s: snapshot),
            const SizedBox(height: 12),
            SystemHealthCards.usageCard(t: t, theme: theme, s: snapshot),
          ],
        ),
      ),
    );
  }
}
