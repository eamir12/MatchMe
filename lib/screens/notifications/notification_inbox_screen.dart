// lib/screens/notifications/notification_inbox_screen.dart
//
// The user's notification inbox: an email-style, persistent list of every
// notification the system has sent them — admin broadcasts, match expirations,
// new matches, extensions, chat messages, live-location-share alerts, etc.
// Each row shows subject (title), body preview and received date/time. Rows
// can be re-read (tap for the full view), marked read and deleted; the app-bar
// offers mark-all-read and delete-all.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/app_empty_state.dart';

class NotificationInboxScreen extends ConsumerStatefulWidget {
  const NotificationInboxScreen({super.key});

  @override
  ConsumerState<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState
    extends ConsumerState<NotificationInboxScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      ref.read(notificationInboxProvider.notifier).loadMore();
    }
  }

  Future<void> _openDetail(NotificationInboxItem item) async {
    ref.read(notificationInboxProvider.notifier).markRead(item.id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _InboxDetailSheet(item: item),
    );
  }

  Future<void> _confirmDeleteAll() async {
    final l10n = ref.read(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.getString('inboxDeleteAll')),
        content: Text(l10n.getString('inboxDeleteAllConfirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.getString('cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.getString('inboxDelete')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      ref.read(notificationInboxProvider.notifier).deleteAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final inbox = ref.watch(notificationInboxProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.getString('inboxTitle')),
            if (inbox.unreadCount > 0)
              Text(
                l10n.getString(
                  'inboxUnreadCount',
                  params: {'count': inbox.unreadCount.toString()},
                ),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: colors.primary,
                ),
              ),
          ],
        ),
        backgroundColor: theme.appBarTheme.backgroundColor ?? colors.surface,
        foregroundColor: theme.appBarTheme.foregroundColor ?? colors.onSurface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all),
            tooltip: l10n.getString('inboxMarkAllRead'),
            onPressed: inbox.unreadCount > 0
                ? () =>
                    ref.read(notificationInboxProvider.notifier).markAllRead()
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: l10n.getString('inboxDeleteAll'),
            onPressed: inbox.items.isNotEmpty ? _confirmDeleteAll : null,
          ),
        ],
      ),
      body: inbox.isLoading && inbox.items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : inbox.items.isEmpty
              ? RefreshIndicator(
                  onRefresh: () => ref
                      .read(notificationInboxProvider.notifier)
                      .refresh(),
                  child: ListView(
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.6,
                        child: AppEmptyState(
                          icon: Icons.notifications_none,
                          title: l10n.getString('inboxEmptyTitle'),
                          message: l10n.getString('inboxEmptyMessage'),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => ref
                      .read(notificationInboxProvider.notifier)
                      .refresh(),
                  child: ListView.separated(
                    controller: _scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    itemCount: inbox.items.length + (inbox.hasMore ? 1 : 0),
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      thickness: 0.5,
                      color: colors.outlineVariant.withValues(alpha: 0.5),
                    ),
                    itemBuilder: (context, index) {
                      if (index >= inbox.items.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: inbox.isLoadingMore
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        );
                      }
                      final item = inbox.items[index];
                      return _InboxRow(
                        item: item,
                        onTap: () => _openDetail(item),
                        onDelete: () => ref
                            .read(notificationInboxProvider.notifier)
                            .delete(item.id),
                      );
                    },
                  ),
                ),
    );
  }
}

class _InboxRow extends ConsumerWidget {
  final NotificationInboxItem item;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _InboxRow({
    required this.item,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final unread = item.isUnread;
    final (icon, iconColor) = _typeVisual(item.type, colors);

    return Dismissible(
      key: ValueKey('inbox_${item.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsetsDirectional.only(end: 24),
        color: colors.error.withValues(alpha: 0.9),
        child: Icon(Icons.delete_outline, color: colors.onError),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: iconColor.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 20, color: iconColor),
                  ),
                  if (unread)
                    PositionedDirectional(
                      top: -2,
                      end: -2,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colors.surface,
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: unread
                                  ? colors.onSurface
                                  : colors.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatRowTimestamp(context, ref, l10n, item),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: unread
                                ? colors.primary
                                : colors.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: unread
                            ? colors.onSurface.withValues(alpha: 0.85)
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.getString(_typeLabelKey(item.type)),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: colors.onSurfaceVariant,
                ),
                tooltip: l10n.getString('inboxDelete'),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatRowTimestamp(
    BuildContext context,
    WidgetRef ref,
    LocalizationState l10n,
    NotificationInboxItem item,
  ) {
    final now = DateTime.now();
    final isToday =
        item.createdAt.year == now.year &&
        item.createdAt.month == now.month &&
        item.createdAt.day == now.day;
    if (isToday) {
      return formatTimeOfDateTimeWithPrefs(context, ref, l10n, item.createdAt);
    }
    final localeTag = l10n.currentLocale.toLanguageTag();
    final sameYear = item.createdAt.year == now.year;
    final dateStr = sameYear
        ? DateFormat.MMMd(localeTag).format(item.createdAt)
        : DateFormat.yMMMd(localeTag).format(item.createdAt);
    return dateStr;
  }
}

class _InboxDetailSheet extends ConsumerWidget {
  final NotificationInboxItem item;

  const _InboxDetailSheet({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, iconColor) = _typeVisual(item.type, colors);

    final matchId = (item.data['match_id'] ?? item.data['matchId'] ?? '')
        .toString()
        .trim();
    final canOpenChat = matchId.isNotEmpty &&
        (item.type == 'chat_message' ||
            item.type == 'match' ||
            item.type == 'new_match' ||
            item.type == 'match_extended');

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 22, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.getString(_typeLabelKey(item.type)),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: iconColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatDateAndTimeOfDateTimeWithPrefs(
                          context,
                          ref,
                          l10n,
                          item.createdAt,
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              item.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              item.body,
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: colors.onSurface.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (canOpenChat)
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: Text(l10n.getString('inboxOpenChat')),
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).pushNamed('/chat/$matchId');
                      },
                    ),
                  ),
                if (canOpenChat) const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(l10n.getString('inboxDelete')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.error,
                      side: BorderSide(
                        color: colors.error.withValues(alpha: 0.5),
                      ),
                    ),
                    onPressed: () {
                      Navigator.of(context).pop();
                      ref
                          .read(notificationInboxProvider.notifier)
                          .delete(item.id);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

(IconData, Color) _typeVisual(String type, ColorScheme colors) {
  switch (type) {
    case 'chat_message':
      return (Icons.chat_bubble_outline, colors.secondary);
    case 'new_match':
    case 'match':
      return (Icons.favorite_outline, colors.primary);
    case 'match_extended':
      return (Icons.update, colors.primary);
    case 'match_expiry':
    case 'pinned_expiry':
      return (Icons.timer_outlined, colors.error);
    case 'admin_broadcast':
      return (Icons.campaign_outlined, colors.primary);
    case 'location_share':
      return (Icons.location_on_outlined, colors.tertiary);
    case 'birthday':
      return (Icons.cake_outlined, colors.tertiary);
    case 'visibility_warning':
      return (Icons.visibility_off_outlined, colors.error);
    default:
      return (Icons.notifications_outlined, colors.onSurfaceVariant);
  }
}

String _typeLabelKey(String type) {
  switch (type) {
    case 'chat_message':
      return 'inboxTypeChatMessage';
    case 'new_match':
    case 'match':
      return 'inboxTypeNewMatch';
    case 'match_extended':
      return 'inboxTypeMatchExtended';
    case 'match_expiry':
    case 'pinned_expiry':
      return 'inboxTypeMatchExpiry';
    case 'admin_broadcast':
      return 'inboxTypeAdminBroadcast';
    case 'location_share':
      return 'inboxTypeLocationShare';
    case 'birthday':
      return 'inboxTypeBirthday';
    case 'visibility_warning':
      return 'inboxTypeVisibility';
    default:
      return 'inboxTypeGeneral';
  }
}
