// lib/screens/notifications/notification_inbox_screen.dart
//
// The user's notification inbox: an email-style, persistent list of every
// notification the system has sent them — admin broadcasts, match expirations,
// new matches, extensions, chat messages, live-location-share alerts, etc.
// Each row shows subject (title), body preview and received date/time. Rows
// can be re-read (tap for the full view), marked read/unread and deleted —
// individually (swipe, tap, detail sheet) or in bulk via multi-select
// (long-press a row to enter selection mode; see lib/widgets/multi_select.dart).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/notification_inbox_provider.dart';
import 'package:matchme/services/notification_inbox_service.dart';
import 'package:matchme/utils/time_format_utils.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/multi_select.dart';

class NotificationInboxScreen extends ConsumerStatefulWidget {
  const NotificationInboxScreen({super.key});

  @override
  ConsumerState<NotificationInboxScreen> createState() =>
      _NotificationInboxScreenState();
}

class _NotificationInboxScreenState
    extends ConsumerState<NotificationInboxScreen> {
  final ScrollController _scrollController = ScrollController();
  final SelectionController _selection = SelectionController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _selection.addListener(_onSelectionChanged);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _selection.removeListener(_onSelectionChanged);
    _selection.dispose();
    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) setState(() {});
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

  Future<void> _confirmDeleteSelected() async {
    final l10n = ref.read(localizationProvider);
    final colors = Theme.of(context).colorScheme;
    final count = _selection.count;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.getString('inboxDeleteSelected')),
        content: Text(
          l10n.getString(
            'inboxDeleteSelectedConfirm',
            params: {'count': count.toString()},
          ),
        ),
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
      final ids = _selection.selected.toSet();
      _selection.clear();
      ref.read(notificationInboxProvider.notifier).deleteMany(ids);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final inbox = ref.watch(notificationInboxProvider);
    final selecting = _selection.isActive;

    return Scaffold(
      appBar: selecting
          ? AppBar(
              backgroundColor:
                  theme.appBarTheme.backgroundColor ?? colors.surface,
              foregroundColor:
                  theme.appBarTheme.foregroundColor ?? colors.onSurface,
              elevation: 0,
              automaticallyImplyLeading: false,
              title: SelectionHeaderBar(
                controller: _selection,
                allIds: inbox.items.map((n) => n.id).toList(growable: false),
                selectedLabel: l10n.getString(
                  'inboxSelectedCount',
                  params: {'count': _selection.count.toString()},
                ),
                closeTooltip: l10n.getString('cancel'),
                selectAllTooltip: l10n.getString('inboxSelectAll'),
                deselectAllTooltip: l10n.getString('inboxDeselectAll'),
              ),
            )
          : AppBar(
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
              backgroundColor:
                  theme.appBarTheme.backgroundColor ?? colors.surface,
              foregroundColor:
                  theme.appBarTheme.foregroundColor ?? colors.onSurface,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: l10n.getString('inboxSelect'),
                  onPressed: inbox.items.isNotEmpty
                      ? () =>
                          _selection.selectAll(inbox.items.map((n) => n.id))
                      : null,
                ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            child: inbox.isLoading && inbox.items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : inbox.items.isEmpty
                    ? RefreshIndicator(
                        onRefresh: () => ref
                            .read(notificationInboxProvider.notifier)
                            .refresh(),
                        child: ListView(
                          children: [
                            SizedBox(
                              height:
                                  MediaQuery.of(context).size.height * 0.6,
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
                          itemCount: inbox.items.length +
                              (inbox.hasMore && !selecting ? 1 : 0),
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            thickness: 0.5,
                            color:
                                colors.outlineVariant.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (context, index) {
                            if (index >= inbox.items.length) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
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
                              selectionMode: selecting,
                              selected: _selection.isSelected(item.id),
                              onToggleSelect: () =>
                                  _selection.toggle(item.id),
                              onTap: () => _openDetail(item),
                              onDelete: () => ref
                                  .read(notificationInboxProvider.notifier)
                                  .delete(item.id),
                            );
                          },
                        ),
                      ),
          ),
          if (selecting)
            SelectionBottomBar(
              actions: [
                SelectionAction(
                  icon: Icons.mark_email_read_outlined,
                  label: l10n.getString('inboxMarkRead'),
                  onPressed: () {
                    final ids = _selection.selected.toSet();
                    _selection.clear();
                    ref
                        .read(notificationInboxProvider.notifier)
                        .markReadMany(ids);
                  },
                ),
                SelectionAction(
                  icon: Icons.mark_email_unread_outlined,
                  label: l10n.getString('inboxMarkUnread'),
                  onPressed: () {
                    final ids = _selection.selected.toSet();
                    _selection.clear();
                    ref
                        .read(notificationInboxProvider.notifier)
                        .markUnreadMany(ids);
                  },
                ),
                SelectionAction(
                  icon: Icons.delete_outline,
                  label: l10n.getString('inboxDelete'),
                  destructive: true,
                  onPressed: _confirmDeleteSelected,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _InboxRow extends ConsumerWidget {
  final NotificationInboxItem item;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _InboxRow({
    required this.item,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
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

    final Widget row = InkWell(
      onTap: selectionMode ? onToggleSelect : onTap,
      onLongPress: selectionMode ? null : onToggleSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: selectionMode
                  ? SelectionCheckCircle(
                      key: const ValueKey('check'),
                      selected: selected,
                    )
                  : _InboxTypeIcon(
                      key: const ValueKey('icon'),
                      icon: icon,
                      iconColor: iconColor,
                      unread: unread,
                      colors: colors,
                    ),
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
                            fontWeight:
                                unread ? FontWeight.w700 : FontWeight.w500,
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
                          fontWeight:
                              unread ? FontWeight.w600 : FontWeight.w400,
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
            if (!selectionMode)
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
    );

    // Swipe-to-delete is a single-row shortcut; it stays out of the way while
    // the user is composing a multi-row selection.
    if (selectionMode) {
      return ColoredBox(
        color: selected
            ? colors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: row,
      );
    }
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
      child: row,
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

/// The circular type icon shown at the leading edge of an inbox row, with the
/// unread dot overlay.
class _InboxTypeIcon extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final bool unread;
  final ColorScheme colors;

  const _InboxTypeIcon({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.unread,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
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
    );
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
