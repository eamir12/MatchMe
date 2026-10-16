// matchme_admin/lib/screens/event_import_feedback_dashboard.dart
//
// Review queue for calendar-import privacy feedback. Users who hit a
// "can't import" block can report "this event is actually public" (one
// report per user). Each row shows the blocked event's scrubbed snapshot;
// an admin can import the event into the reporter's MatchMe events (the
// SQL RPC mirrors the client's own import path, including dedupe against
// existing events) or dismiss the report.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme_admin/widgets/safe_text.dart';

class AdminEventImportFeedbackDashboard extends ConsumerStatefulWidget {
  const AdminEventImportFeedbackDashboard({
    super.key,
    required this.t,
    required this.localeCode,
  });

  final String Function(String key, {Map<String, String>? params}) t;
  final String localeCode;

  @override
  ConsumerState<AdminEventImportFeedbackDashboard> createState() =>
      _AdminEventImportFeedbackDashboardState();
}

class _AdminEventImportFeedbackDashboardState
    extends ConsumerState<AdminEventImportFeedbackDashboard> {
  static const List<String> _statusFilters = [
    'pending',
    'imported',
    'dismissed',
    'all',
  ];

  String _status = 'pending';
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  bool _isLoading = true;
  String? _errorKey;
  List<Map<String, dynamic>> _rows = const [];
  String? _busyRowId;
  RealtimeChannel? _realtimeChannel;
  Timer? _pollTimer;

  String t(String key, {Map<String, String>? params}) =>
      widget.t(key, params: params);

  @override
  void initState() {
    super.initState();
    unawaited(_load(force: true));
    _ensureRealtime();
    // Fallback for when realtime delivery is unavailable (e.g. publication
    // membership not enabled): the queue still self-updates, no refresh
    // button needed. Realtime makes it instant when it works.
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _busyRowId == null) {
        unawaited(_load());
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    _pollTimer?.cancel();
    final channel = _realtimeChannel;
    _realtimeChannel = null;
    if (channel != null) {
      try {
        Supabase.instance.client.removeChannel(channel);
      } catch (_) {}
    }
    super.dispose();
  }

  /// Instant updates: new feedback reports and status changes (own import /
  /// dismiss actions included) reload the queue without any manual refresh.
  /// Requires the admin SELECT policy on event_import_feedback and the
  /// table enabled in the supabase_realtime publication.
  void _ensureRealtime() {
    try {
      _realtimeChannel = Supabase.instance.client
          .channel('admin_event_import_feedback')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'event_import_feedback',
            callback: (_) {
              if (!mounted) return;
              unawaited(_load(force: true));
            },
          )
          .subscribe((status, error) {
            // SUBSCRIBED = live; CHANNEL_ERROR/TIMED_OUT = poll fallback
            // covers us. Logged so subscription problems are observable.
            debugPrint(
              '[EVENT_FEEDBACK_REALTIME] subscribe status=$status '
              'error=$error',
            );
          });
    } catch (_) {
      // Realtime is an enhancement; the 15s poll keeps the queue current.
      _realtimeChannel = null;
    }
  }

  Future<void> _load({bool force = false}) async {
    if (!force && _isLoading) return;
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorKey = null;
    });
    try {
      final queryTrimmed = _searchController.text.trim();
      final result = await Supabase.instance.client
          .rpc(
            'admin_list_event_import_feedback',
            params: {
              'p_status': _status,
              'p_query': queryTrimmed.isEmpty ? null : queryTrimmed,
              'p_limit': 200,
              'p_offset': 0,
            },
          )
          .timeout(const Duration(seconds: 12));
      final raw = (result as List<dynamic>)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _rows = raw;
        _isLoading = false;
        _errorKey = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorKey = 'adminEventFeedbackErrorGeneric';
      });
    }
  }

  Future<void> _review(Map<String, dynamic> row, String decision) async {
    final id = row['id'] as String?;
    if (id == null || _busyRowId != null) return;
    setState(() => _busyRowId = id);
    try {
      await Supabase.instance.client
          .rpc(
            'admin_review_event_import_feedback',
            params: {'p_feedback_id': id, 'p_decision': decision},
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              decision == 'imported'
                  ? 'adminEventFeedbackImportSuccess'
                  : 'adminEventFeedbackDismissSuccess',
            ),
          ),
        ),
      );
      await _load(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t(_errorKeyForException(e))),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busyRowId = null);
    }
  }

  String _errorKeyForException(Object e) {
    final message = e.toString().toLowerCase();
    if (message.contains('feedback_event_start_in_past')) {
      return 'adminEventFeedbackErrorStartInPast';
    }
    if (message.contains('feedback_already_reviewed')) {
      return 'adminEventFeedbackErrorAlreadyReviewed';
    }
    if (message.contains('feedback_missing_event_snapshot') ||
        message.contains('feedback_missing_event_name') ||
        message.contains('feedback_missing_start_time')) {
      return 'adminEventFeedbackErrorNoSnapshot';
    }
    if (message.contains('feedback_not_found')) {
      return 'adminEventFeedbackErrorNotFound';
    }
    return 'adminEventFeedbackErrorGeneric';
  }

  String _reasonLabel(String? raw) {
    return switch (raw) {
      'markedPrivate' => t('calendarSyncCannotImportPrivateBadge'),
      'looksPrivate' => t('calendarSyncCannotImportPersonalBadge'),
      'noPublicContext' => t('calendarSyncCannotImportBadge'),
      _ => raw ?? '',
    };
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return '';
    try {
      final locale = widget.localeCode.trim().isEmpty
          ? 'en'
          : widget.localeCode;
      return DateFormat.yMMMd(locale).add_Hm().format(value.toLocal());
    } catch (_) {
      return value.toIso8601String();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _buildToolbar(theme),
        const Divider(height: 1),
        Expanded(child: _buildBody(theme)),
      ],
    );
  }

  Widget _buildToolbar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<String>(
            // The default selected checkmark eats ~24px inside the segment,
            // which is exactly what makes "Pending" wrap onto a second row
            // on phone-width screens.
            showSelectedIcon: false,
            segments: [
              for (final status in _statusFilters)
                ButtonSegment(
                  value: status,
                  label: ShrinkText(
                    t('adminEventFeedbackFilter${_filterLabel(status)}'),
                    maxLines: 1,
                  ),
                ),
            ],
            selected: {_status},
            onSelectionChanged: (selection) {
              setState(() => _status = selection.first);
              unawaited(_load(force: true));
            },
          ),
          SizedBox(
            width: 280,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: t('adminEventFeedbackSearchHint'),
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => _scheduleSearch(),
              onSubmitted: (_) => unawaited(_load(force: true)),
            ),
          ),
        ],
      ),
    );
  }

  /// Live search: applies as the admin types, with a short debounce so we
  /// don't hit the RPC per keystroke. (There is no refresh button — the
  /// queue updates itself via realtime plus the polling fallback.)
  void _scheduleSearch() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        unawaited(_load(force: true));
      }
    });
  }

  String _filterLabel(String status) {
    return switch (status) {
      'pending' => 'Pending',
      'imported' => 'Imported',
      'dismissed' => 'Dismissed',
      _ => 'All',
    };
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading && _rows.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorKey != null && _rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            Text(t(_errorKey!)),
          ],
        ),
      );
    }
    if (_rows.isEmpty) {
      return Center(child: Text(t('adminEventFeedbackEmpty')));
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView.separated(
        itemCount: _rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemBuilder: (context, index) =>
            _buildRow(theme, _rows[index], index == 0),
      ),
    );
  }

  Widget _buildRow(ThemeData theme, Map<String, dynamic> row, bool first) {
    final id = row['id'] as String? ?? '';
    final status = row['status'] as String? ?? 'pending';
    final isPending = status == 'pending';
    final isBusy = _busyRowId == id;

    final rawSnapshot = row['event_snapshot'];
    final snapshot = rawSnapshot is Map
        ? Map<String, dynamic>.from(rawSnapshot)
        : null;
    final userName = row['user_name'] as String? ?? '';
    final createdAtRaw = row['created_at'];
    final createdAt = createdAtRaw is DateTime
        ? createdAtRaw
        : DateTime.tryParse('$createdAtRaw');
    final reviewedAtRaw = row['reviewed_at'];
    final reviewedAt = reviewedAtRaw is DateTime
        ? reviewedAtRaw
        : DateTime.tryParse('$reviewedAtRaw');
    final reviewerName = row['reviewer_name'] as String? ?? '';
    final startRaw = snapshot?['start_time'] as String?;
    final start = startRaw == null ? null : DateTime.tryParse(startRaw);

    final statusColor = switch (status) {
      'imported' => Colors.green.shade700,
      'dismissed' => theme.colorScheme.onSurfaceVariant,
      _ => Colors.orange.shade800,
    };

    // Rows reported before snapshot capture existed have no event data;
    // they can only be dismissed, so hide the import action instead of
    // failing on tap.
    final snapshotName = (snapshot?['event_name'] as String?)?.trim() ?? '';
    final canImport =
        snapshot != null &&
        snapshotName.isNotEmpty &&
        snapshot['start_time'] != null;
    final rawSnapshotLink = (snapshot?['event_link'] as String?)?.trim();
    final eventLink = rawSnapshotLink == null || rawSnapshotLink.isEmpty
        ? null
        : rawSnapshotLink;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row['event_title'] as String? ?? '',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    t('adminEventFeedbackFilter${_filterLabel(status)}'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t('adminEventFeedbackReportedBy', params: {'name': userName}),
              style: theme.textTheme.bodySmall,
            ),
            if (createdAt != null) ...[
              const SizedBox(height: 2),
              Text(
                _formatTimestamp(createdAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _chip(
                  theme,
                  t(
                    'adminEventFeedbackBlockReason',
                    params: {
                      'reason': _reasonLabel(row['block_reason'] as String?),
                    },
                  ),
                ),
                if ((row['provider'] as String?)?.isNotEmpty == true)
                  _chip(
                    theme,
                    t(
                      'adminEventFeedbackProvider',
                      params: {'provider': row['provider'] as String},
                    ),
                  ),
                if (start != null)
                  _chip(
                    theme,
                    t(
                      'adminEventFeedbackStart',
                      params: {'start': _formatTimestamp(start)},
                    ),
                  ),
              ],
            ),
            if (snapshot != null) ...[
              const SizedBox(height: 12),
              Text(
                t('adminEventFeedbackSnapshotTitle'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              _detailText(theme, snapshot['event_venue'] as String?),
              _detailText(theme, snapshot['event_description'] as String?),
              // The link is shown as a launchable button, not raw text —
              // full URLs wrap over many lines and snapshot links are
              // already filtered to usable public links client-side.
              if (eventLink != null && eventLink.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton.icon(
                      onPressed: () async {
                        final uri = Uri.tryParse(eventLink);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.link, size: 16),
                      label: Text(t('adminEventFeedbackOpenLink')),
                    ),
                  ),
                ),
            ],
            if (!isPending && reviewedAt != null) ...[
              const SizedBox(height: 10),
              Text(
                '${t('adminEventFeedbackReviewedBy', params: {'name': reviewerName})}'
                ' · ${_formatTimestamp(reviewedAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (isPending) ...[
              const SizedBox(height: 14),
              if (!canImport) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t('adminEventFeedbackErrorNoSnapshot'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  if (canImport) ...[
                    FilledButton.icon(
                      onPressed: isBusy
                          ? null
                          : () => unawaited(_review(row, 'imported')),
                      icon: isBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.event_available),
                      label: Text(t('adminEventFeedbackImportButton')),
                    ),
                    const SizedBox(width: 12),
                  ],
                  OutlinedButton(
                    onPressed: isBusy
                        ? null
                        : () => unawaited(_review(row, 'dismissed')),
                    child: Text(t('adminEventFeedbackDismissButton')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: theme.textTheme.labelSmall),
    );
  }

  Widget _detailText(ThemeData theme, String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SelectableText(
        trimmed,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
