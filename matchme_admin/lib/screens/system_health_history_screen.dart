// matchme_admin/lib/screens/system_health_history_screen.dart
//
// 7-day history of the System Health feature, fed by the
// `admin_health_snapshots` table through the admin_get_health_history RPC
// (sampled every ~5 minutes by the cron-jobs health_sampler task; socket
// transitions recorded by the live monitor while an admin app is open).
//
// Two views for a selected date/time range:
//  - Charts: per-metric fl_chart line charts (db latency, queue pending,
//    disk %, API-request rate, sign-ins, auth errors), exact failure
//    counts computed live from the source tables, a Supabase status
//    indicator strip, and Realtime socket transition markers.
//  - Replay: the familiar System Health cards rendered as-of the chosen
//    moment (nearest stored sample per source) via the same
//    SystemHealthCards widgets the live screen uses.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:matchme_admin/services/system_health_monitor.dart';
import 'package:matchme_admin/widgets/system_health_cards.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _SeriesSample {
  const _SeriesSample(this.at, this.payload);
  final DateTime at;
  final Map<String, dynamic> payload;
}

class SystemHealthHistoryScreen extends StatefulWidget {
  const SystemHealthHistoryScreen({
    super.key,
    required this.t,
    required this.localeCode,
    required this.textDirection,
  });

  final AdminHealthTextLookup t;
  final String localeCode;
  final TextDirection textDirection;

  @override
  State<SystemHealthHistoryScreen> createState() =>
      _SystemHealthHistoryScreenState();
}

class _SystemHealthHistoryScreenState extends State<SystemHealthHistoryScreen> {
  late DateTime _from;
  late DateTime _to;

  Map<String, List<_SeriesSample>> _series = {};
  Map<String, dynamic>? _errors;
  DateTime? _dataFrom;

  bool _loading = false;
  String? _error;
  bool _isReplay = false;
  DateTime? _replayAt;

  @override
  void initState() {
    super.initState();
    _to = DateTime.now();
    _from = _to.subtract(const Duration(hours: 24));
    _fetch();
  }

  String t(String key, {Map<String, String>? params}) {
    var value = widget.t(key, params: params);
    params?.forEach((paramKey, paramValue) {
      value = value.replaceAll('{$paramKey}', paramValue);
    });
    return value;
  }

  String _fmtTime(DateTime dt) {
    try {
      return DateFormat('MMM d, y · HH:mm', widget.localeCode).format(
        dt.toLocal(),
      );
    } catch (_) {
      return DateFormat('MMM d, y · HH:mm').format(dt.toLocal());
    }
  }

  String _fmtClock(DateTime dt) {
    try {
      return DateFormat('HH:mm', widget.localeCode).format(dt.toLocal());
    } catch (_) {
      return DateFormat('HH:mm').format(dt.toLocal());
    }
  }

  // ── Data ──────────────────────────────────────────────────────────

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final res = await client.rpc(
        'admin_get_health_history',
        params: {
          'p_from': _from.toUtc().toIso8601String(),
          'p_to': _to.toUtc().toIso8601String(),
        },
      );
      if (res is! Map) {
        throw Exception('unexpected response shape');
      }
      final series = <String, List<_SeriesSample>>{};
      final rawSeries = res['series'];
      if (rawSeries is Map) {
        for (final entry in rawSeries.entries) {
          final samples = <_SeriesSample>[];
          if (entry.value is List) {
            for (final e in entry.value as List) {
              if (e is! Map) continue;
              final at = DateTime.tryParse('${e['at']}');
              if (at == null) continue;
              final rawPayload = e['payload'];
              samples.add(
                _SeriesSample(
                  at,
                  rawPayload is Map
                      ? Map<String, dynamic>.from(rawPayload)
                      : <String, dynamic>{},
                ),
              );
            }
          }
          series['${entry.key}'] = samples;
        }
      }
      if (!mounted) return;
      setState(() {
        _series = series;
        _errors = res['errors'] is Map
            ? Map<String, dynamic>.from(res['errors'] as Map)
            : null;
        _dataFrom = DateTime.tryParse('${res['from']}');
        _replayAt ??= _latestSampleAt();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  DateTime? _latestSampleAt() {
    DateTime? latest;
    for (final samples in _series.values) {
      if (samples.isEmpty) continue;
      final at = samples.last.at;
      if (latest == null || at.isAfter(latest)) latest = at;
    }
    return latest;
  }

  bool get _hasAnySamples => _series.values.any((s) => s.isNotEmpty);

  // ── Range pickers ─────────────────────────────────────────────────

  Future<void> _pickFrom() async {
    final picked = await _pickDateTime(_from);
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _pickTo() async {
    final picked = await _pickDateTime(_to);
    if (picked != null) setState(() => _to = picked);
  }

  Future<DateTime?> _pickDateTime(DateTime initial) async {
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 7)),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return null;
    return DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
  }

  void _applyPreset(Duration d) {
    setState(() {
      _to = DateTime.now();
      _from = _to.subtract(d);
    });
    _fetch();
  }

  // ── Replay helpers ────────────────────────────────────────────────

  _SeriesSample? _nearest(String source, DateTime at) {
    final samples = _series[source];
    if (samples == null || samples.isEmpty) return null;
    _SeriesSample? candidate;
    for (final s in samples) {
      if (!s.at.isAfter(at)) candidate = s;
    }
    return candidate ?? samples.first;
  }

  SystemHealthSnapshot? _replaySnapshot() {
    final at = _replayAt;
    if (at == null || !_hasAnySamples) return null;
    return SystemHealthSnapshot.replay(
      at: at,
      db: _nearest('db', at)?.payload,
      queue: _nearest('queue', at)?.payload,
      errors: _nearest('errors', at)?.payload,
      auth: _nearest('auth', at)?.payload,
      usage: _nearest('usage', at)?.payload,
      statuspage: _nearest('statuspage', at)?.payload,
      socketState: _nearest('socket', at)?.payload['state']?.toString(),
    );
  }

  Future<void> _pickReplayAt() async {
    final current = _replayAt ?? _latestSampleAt() ?? DateTime.now();
    final picked = await _pickDateTime(current);
    if (picked != null && mounted) {
      setState(() => _replayAt = picked);
    }
  }

  // ── Chart helpers ─────────────────────────────────────────────────

  List<FlSpot> _spots(
    String source,
    num? Function(Map<String, dynamic> payload) valueOf,
  ) {
    final samples = _series[source] ?? const <_SeriesSample>[];
    final start = _dataFrom ?? (samples.isEmpty ? null : samples.first.at);
    if (start == null) return const [];
    final result = <FlSpot>[];
    for (final s in samples) {
      final v = valueOf(s.payload);
      if (v == null) continue;
      result.add(
        FlSpot(s.at.difference(start).inMinutes.toDouble(), v.toDouble()),
      );
    }
    return result;
  }

  /// Requests per sampling interval, from consecutive cumulative counter
  /// values (negative deltas = monthly counter reset, shown as 0).
  List<FlSpot> _apiRateSpots() {
    final samples = _series['usage'] ?? const <_SeriesSample>[];
    final start = _dataFrom ?? (samples.isEmpty ? null : samples.first.at);
    if (start == null) return const [];
    final result = <FlSpot>[];
    int? prev;
    for (final s in samples) {
      final raw = s.payload['api_requests_count'];
      final count = raw is num ? raw.toInt() : null;
      if (count == null) {
        prev = null;
        continue;
      }
      final delta = prev != null && count >= prev ? (count - prev) : 0;
      result.add(
        FlSpot(s.at.difference(start).inMinutes.toDouble(), delta.toDouble()),
      );
      prev = count;
    }
    return result;
  }

  List<FlSpot> _downsample(List<FlSpot> spots, {int maxPoints = 400}) {
    if (spots.length <= maxPoints) return spots;
    final stride = (spots.length / maxPoints).ceil();
    final out = <FlSpot>[];
    for (var i = 0; i < spots.length; i += stride) {
      out.add(spots[i]);
    }
    if (out.last != spots.last) out.add(spots.last);
    return out;
  }

  Widget _chart(
    ThemeData theme, {
    required String title,
    required List<FlSpot> spots,
    required Color color,
    String Function(double)? formatY,
  }) {
    final body = spots.isEmpty
        ? SizedBox(
            height: 60,
            child: Center(
              child: Text(
                t('adminHealthHistoryEmpty'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
        : SizedBox(
            height: 150,
            child: Padding(
              padding: const EdgeInsets.only(right: 8, top: 8),
              child: LineChart(
                _lineChartData(
                  theme,
                  _downsample(spots),
                  color,
                  formatY ?? (v) => v.toStringAsFixed(0),
                ),
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }

  LineChartData _lineChartData(
    ThemeData theme,
    List<FlSpot> spots,
    Color color,
    String Function(double) formatY,
  ) {
    final maxX = spots.last.x;
    final xInterval = (maxX / 4).clamp(1.0, double.infinity);
    final yValues = spots.map((s) => s.y);
    final maxY = yValues.reduce((a, b) => a > b ? a : b);
    final yInterval = (maxY / 3).clamp(1.0, double.infinity);
    final start = _dataFrom ?? DateTime.now();

    return LineChartData(
      minY: 0,
      maxY: maxY <= 0 ? 1 : maxY * 1.15,
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: yInterval,
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: xInterval,
            getTitlesWidget: (value, meta) {
              final dt = start.add(Duration(minutes: value.round()));
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _fmtClock(dt),
                  style: theme.textTheme.labelSmall,
                ),
              );
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            getTitlesWidget: (value, meta) => Text(
              formatY(value),
              style: theme.textTheme.labelSmall,
            ),
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (touchedSpots) => touchedSpots
              .map(
                (s) => LineTooltipItem(
                  formatY(s.y),
                  const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
              .toList(),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: color,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: color.withValues(alpha: 0.12),
          ),
        ),
      ],
    );
  }

  // ── Sections ──────────────────────────────────────────────────────

  Widget _chartsView(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chart(
          theme,
          title: '${t('adminHealthDatabase')} · ${t('adminHealthLatency')} (ms)',
          spots: _spots('db', (p) => p['latency_ms'] is num
              ? (p['latency_ms'] as num)
              : null),
          color: Colors.blue,
        ),
        _chart(
          theme,
          title: t('adminHealthHistoryChartQueue'),
          spots: _spots('queue', (p) =>
              p['pending'] is num ? (p['pending'] as num) : null),
          color: Colors.deepPurple,
        ),
        _chart(
          theme,
          title: '${t('adminHealthDiskUsage')} (%)',
          spots: _spots('usage', (p) {
            final used = p['disk_used_bytes'];
            final size = p['disk_size_bytes'];
            if (used is! num || size is! num || size <= 0) return null;
            return used / size * 100;
          }),
          color: Colors.teal,
        ),
        _chart(
          theme,
          title: t('adminHealthHistoryChartApiRate'),
          spots: _apiRateSpots(),
          color: Colors.indigo,
        ),
        _chart(
          theme,
          title: t('adminHealthSignIns15m'),
          spots: _spots('auth', (p) =>
              p['signins_15m'] is num ? (p['signins_15m'] as num) : null),
          color: Colors.blueGrey,
        ),
        _chart(
          theme,
          title: t('adminHealthAuthErrors15m'),
          spots: _spots('auth', (p) => p['auth_errors_15m'] is num
              ? (p['auth_errors_15m'] as num)
              : null),
          color: Colors.redAccent,
        ),
        _errorsInRangeCard(theme),
        const SizedBox(height: 8),
        _statuspageStripCard(theme),
        const SizedBox(height: 8),
        _socketEventsCard(theme),
      ],
    );
  }

  Widget _kvRow(ThemeData theme, String label, String value, {Color? color}) {
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
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorsInRangeCard(ThemeData theme) {
    final e = _errors;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined,
                    size: 20, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('adminHealthHistoryErrorsTitle'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (e == null)
              Text(t('adminHealthHistoryEmpty'), style: theme.textTheme.bodySmall)
            else ...[
              _kvRow(
                theme,
                t('adminHealthHistoryErrorsEdge'),
                '${e['edge_failed'] ?? 0}',
                color: (e['edge_failed'] is num && (e['edge_failed'] as num) > 0)
                    ? Colors.orange
                    : Colors.green,
              ),
              if ('${e['edge_last_error'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 2, bottom: 4),
                  child: Text(
                    '${e['edge_last_error']}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.orange,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              _kvRow(
                theme,
                t('adminHealthHistoryErrorsCron'),
                '${e['cron_failed_invocations'] ?? 0}',
                color: (e['cron_failed_invocations'] is num &&
                        (e['cron_failed_invocations'] as num) > 0)
                    ? Colors.orange
                    : Colors.green,
              ),
              if (e['cron_last_failed_tasks'] is List &&
                  (e['cron_last_failed_tasks'] as List).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 2, bottom: 4),
                  child: Text(
                    t('adminHealthErrorsFailedTasks', params: {
                      'tasks':
                          (e['cron_last_failed_tasks'] as List).join(', '),
                    }),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.orange,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              _kvRow(
                theme,
                t('adminHealthHistoryErrorsApp'),
                '${e['app_errors'] ?? 0}',
                color: (e['app_errors'] is num && (e['app_errors'] as num) > 0)
                    ? Colors.orange
                    : Colors.green,
              ),
              if ('${e['app_last_message'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 16, top: 2),
                  child: Text(
                    t('adminHealthErrorsAppLast', params: {
                      'source': '${e['app_last_source'] ?? '—'}',
                      'message': '${e['app_last_message']}',
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
        ),
      ),
    );
  }

  Color _indicatorColor(String? indicator) {
    return switch (indicator) {
      'none' => Colors.green,
      'minor' => Colors.orange,
      'major' || 'critical' => Colors.red,
      'maintenance' => Colors.blueGrey,
      _ => Colors.grey,
    };
  }

  Widget _statuspageStripCard(ThemeData theme) {
    final samples = _series['statuspage'] ?? const <_SeriesSample>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('adminHealthHistoryStatuspageTitle'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (samples.isEmpty)
              Text(t('adminHealthHistoryEmpty'), style: theme.textTheme.bodySmall)
            else ...[
              SizedBox(
                height: 14,
                child: Row(
                  children: [
                    for (final s in samples)
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: _indicatorColor(
                              s.payload['indicator']?.toString(),
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          margin: const EdgeInsets.symmetric(horizontal: 0.5),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _legendDot(Colors.green, t('adminHealthStatusHealthy')),
                  _legendDot(Colors.orange, 'minor'),
                  _legendDot(Colors.red, 'major/critical'),
                  _legendDot(Colors.blueGrey, 'maintenance'),
                ],
              ),
              if (samples.last.payload['description'] != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${samples.last.payload['description']}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _indicatorColor(
                      samples.last.payload['indicator']?.toString(),
                    ),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _socketEventsCard(ThemeData theme) {
    final samples = [
      ...?_series['socket'],
    ]..sort((a, b) => a.at.compareTo(b.at));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t('adminHealthHistorySocketTitle'),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (samples.isEmpty)
              Text(t('adminHealthHistoryEmpty'), style: theme.textTheme.bodySmall)
            else
              for (final s in samples)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: s.payload['state'] == 'open'
                            ? Colors.green
                            : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(_fmtTime(s.at), style: theme.textTheme.bodySmall),
                      const SizedBox(width: 12),
                      Text(
                        s.payload['state'] == 'open'
                            ? t('adminHealthHistorySocketOpen')
                            : t('adminHealthHistorySocketClosed'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: s.payload['state'] == 'open'
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _replayView(ThemeData theme) {
    final snapshot = _replaySnapshot();
    if (snapshot == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(t('adminHealthHistoryEmpty'), style: theme.textTheme.bodySmall),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.amber.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.amber.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              const Icon(Icons.history, color: Colors.amber, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('adminHealthHistoryReplayBanner', params: {
                    'time': _fmtTime(snapshot.updatedAt.toLocal()),
                  }),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SystemHealthCards.overallBanner(t: t, theme: theme, s: snapshot),
        const SizedBox(height: 12),
        SystemHealthCards.databaseCard(
          t: t,
          theme: theme,
          s: snapshot,
          localeCode: widget.localeCode,
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
    );
  }

  // ── Filter bar ────────────────────────────────────────────────────

  Widget _filterBar(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _rangeButton(theme, t('adminHealthHistoryRangeFrom'), _from, _pickFrom),
                _rangeButton(theme, t('adminHealthHistoryRangeTo'), _to, _pickTo),
                FilledButton.tonal(
                  onPressed: _loading ? null : () => _fetch(),
                  child: Text(t('adminHealthHistoryApply')),
                ),
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () => _applyPreset(const Duration(hours: 1)),
                  child: Text(t('adminHealthHistoryPreset1h')),
                ),
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () => _applyPreset(const Duration(hours: 6)),
                  child: Text(t('adminHealthHistoryPreset6h')),
                ),
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () => _applyPreset(const Duration(hours: 24)),
                  child: Text(t('adminHealthHistoryPreset24h')),
                ),
                OutlinedButton(
                  onPressed: _loading
                      ? null
                      : () => _applyPreset(const Duration(days: 7)),
                  child: Text(t('adminHealthHistoryPreset7d')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(t('adminHealthHistoryViewRange')),
                      icon: const Icon(Icons.show_chart),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(t('adminHealthHistoryViewReplay')),
                      icon: const Icon(Icons.replay),
                    ),
                  ],
                  selected: {_isReplay},
                  onSelectionChanged: (selection) {
                    setState(() => _isReplay = selection.first);
                  },
                ),
                if (_isReplay) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _pickReplayAt,
                    icon: const Icon(Icons.schedule),
                    label: Text(
                      _replayAt == null
                          ? t('adminHealthHistoryReplayAsOf')
                          : _fmtTime(_replayAt!),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t('adminHealthHistorySubtitle'),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeButton(
    ThemeData theme,
    String label,
    DateTime value,
    VoidCallback onTap,
  ) {
    return OutlinedButton(
      onPressed: onTap,
      child: Text('$label: ${_fmtTime(value)}'),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Widget body;
    if (_loading && _series.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(t('adminHealthHistoryLoading')),
          ],
        ),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SystemHealthCards.noticeCard(
              theme,
              icon: Icons.error_outline,
              color: Colors.red,
              text: t('adminHealthHistoryError', params: {'error': _error!}),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _fetch,
              child: Text(t('adminHealthHistoryApply')),
            ),
          ],
        ),
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _filterBar(theme),
          const SizedBox(height: 12),
          if (!_hasAnySamples)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t('adminHealthHistoryEmpty'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            )
          else if (_isReplay)
            _replayView(theme)
          else
            _chartsView(theme),
        ],
      );
    }

    return Directionality(
      textDirection: widget.textDirection,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t('adminHealthHistoryTitle')),
        ),
        body: RefreshIndicator(
          onRefresh: _fetch,
          child: body,
        ),
      ),
    );
  }
}
