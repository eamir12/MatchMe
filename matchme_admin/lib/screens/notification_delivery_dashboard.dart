// lib/screens/notification_delivery_dashboard.dart
// Admin delivery monitor for push notifications (FCM).
//
// Shows the `get_notification_queue_health()` signal (pending/processing,
// sent+failed in the last hour, oldest-pending age, alert flag) plus the 20
// most recent failed queue rows so on-call can see *why* sends fail
// (stale UNREGISTERED tokens, missing templates, etc.).
//
// Auto-refreshes every 30s while visible. Read-only: no queue mutations.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef AdminTextLookup =
    String Function(String key, {Map<String, String>? params});

class AdminNotificationDeliveryDashboard extends StatefulWidget {
  const AdminNotificationDeliveryDashboard({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  State<AdminNotificationDeliveryDashboard> createState() =>
      _AdminNotificationDeliveryDashboardState();
}

class _DeliveryFailureRow {
  final String id;
  final String title;
  final String reason;
  final String createdAt;
  final int attempts;

  const _DeliveryFailureRow({
    required this.id,
    required this.title,
    required this.reason,
    required this.createdAt,
    required this.attempts,
  });
}

class _AdminNotificationDeliveryDashboardState
    extends State<AdminNotificationDeliveryDashboard>
    with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _health;
  List<_DeliveryFailureRow> _failures = const [];
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) unawaited(_load(silent: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final client = Supabase.instance.client;
      Map<String, dynamic>? health;
      try {
        final res = await client.rpc('get_notification_queue_health');
        if (res is Map) {
          health = Map<String, dynamic>.from(res);
        }
      } catch (_) {}
      List<_DeliveryFailureRow> failures = const [];
      try {
        final rows = await client
            .from('notification_queue')
            .select('id,title,failure_reason,created_at,attempts')
            .eq('status', 'failed')
            .order('created_at', ascending: false)
            .limit(20);
        failures = (rows as List)
            .map(
              (r) => _DeliveryFailureRow(
                id: (r['id'] ?? '').toString(),
                title: (r['title'] ?? '').toString(),
                reason: (r['failure_reason'] ?? '').toString(),
                createdAt: (r['created_at'] ?? '').toString(),
                attempts: int.tryParse('${r['attempts'] ?? 0}') ?? 0,
              ),
            )
            .toList();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _health = health;
        _failures = failures;
        _loading = false;
        _error = health == null ? 'Health RPC unavailable' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  int _int(dynamic v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final health = _health;
    final alert = health?['alert'] == true;
    return Directionality(
      textDirection: widget.textDirection,
      child: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Push delivery',
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => unawaited(_load()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Auto-refreshes every 30s. Alert when pending > 1000, oldest pending > 10 min, or failed > 50/h.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_loading && health == null)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_error != null && health == null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Error: $_error'),
                ),
              )
            else ...[
              if (alert)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Queue alert: backlog growing or sender stuck. Check failures below and edge-function logs.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _stat(context, 'Pending', '${_int(health?['pending'])}'),
                  _stat(
                    context,
                    'Processing',
                    '${_int(health?['processing'])}',
                  ),
                  _stat(
                    context,
                    'Sent (1h)',
                    '${_int(health?['sent_last_hour'])}',
                  ),
                  _stat(
                    context,
                    'Failed (1h)',
                    '${_int(health?['failed_last_hour'])}',
                  ),
                  _stat(
                    context,
                    'Oldest pending',
                    _ageLabel(_int(health?['oldest_pending_age_sec'])),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Recent failures (${_failures.length})',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_failures.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No failed rows in the last page.'),
                  ),
                )
              else
                ..._failures.map(
                  (f) => Card(
                    child: ListTile(
                      title: Text(
                        f.title.isEmpty ? f.id : f.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${f.createdAt} · attempts ${f.attempts}\n${f.reason}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stat(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 160,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  String _ageLabel(int seconds) {
    if (seconds <= 0) return '—';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    return '${seconds ~/ 3600}h';
  }
}
