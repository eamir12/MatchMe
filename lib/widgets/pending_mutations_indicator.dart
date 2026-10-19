import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/offline_mutation_queue.dart';

/// Widget that shows pending mutations count badge
class PendingMutationsBadge extends StatelessWidget {
  final Color? badgeColor;
  final Color? textColor;
  final double? badgeSize;

  const PendingMutationsBadge({
    super.key,
    this.badgeColor,
    this.textColor,
    this.badgeSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<OfflineMutation>>(
      stream: OfflineMutationQueue.instance.queueChanged,
      initialData: const [],
      builder: (context, snapshot) {
        final mutations = snapshot.data ?? [];
        if (mutations.isEmpty) {
          return const SizedBox.shrink();
        }

        return Positioned(
          right: 0,
          top: 0,
          child: Container(
            width: badgeSize,
            height: badgeSize,
            decoration: BoxDecoration(
              color: badgeColor ?? Colors.red,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                mutations.length > 99 ? "99+" : "${mutations.length}",
                style: TextStyle(
                  color: textColor ?? Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Widget that shows pending mutations indicator with details
class PendingMutationsIndicator extends ConsumerWidget {
  final MainAxisAlignment alignment;
  final bool showDetails;

  const PendingMutationsIndicator({
    super.key,
    this.alignment = MainAxisAlignment.center,
    this.showDetails = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localization = ref.watch(localizationProvider);

    return StreamBuilder<List<OfflineMutation>>(
      stream: OfflineMutationQueue.instance.queueChanged,
      initialData: const [],
      builder: (context, snapshot) {
        final mutations = snapshot.data ?? [];
        if (mutations.isEmpty) {
          return const SizedBox.shrink();
        }

        final count = mutations.length;
        final syncingText = localization.getString(
          'offlineSyncingChanges',
          params: {
            'count': count.toString(),
            'plural': count == 1
                ? ''
                : localization.getString('offlineSyncingChangesPlural'),
          },
        );
        final detailsText = localization.getString('offlineViewDetails');

        return Semantics(
          container: true,
          liveRegion: true,
          label: '$syncingText. $detailsText',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              border: Border.all(color: Colors.orange.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: alignment,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.orange.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    syncingText,
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (showDetails && mutations.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: TextButton(
                      onPressed: () =>
                          _showMutationDetails(context, mutations, ref),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        minimumSize: const Size(48, 48),
                      ),
                      child: Text(
                        detailsText,
                        style: TextStyle(
                          color: Colors.orange.shade700,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMutationDetails(
    BuildContext context,
    List<OfflineMutation> mutations,
    WidgetRef ref,
  ) {
    final localization = ref.read(localizationProvider);
    final pendingChangesTitle = localization.getString('offlinePendingChanges');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.75,
        child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pendingChangesTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  itemCount: mutations.length,
                  itemBuilder: (context, index) {
                    final mutation = mutations[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "${mutation.type.toUpperCase()} ${mutation.table}",
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            localization.getString(
                              'offlineMutationId',
                              params: {
                                'id': '${mutation.id.substring(0, 8)}...',
                              },
                            ),
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (mutation.retryCount > 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                localization.getString(
                                  'offlineMutationRetries',
                                  params: {'count': '${mutation.retryCount}'},
                                ),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.orange,
                                ),
                              ),
                            ),
                          if (mutation.errorMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                localization.getString(
                                  'offlineMutationError',
                                  params: {'error': '${mutation.errorMessage}'},
                                ),
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.red,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.visible,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog to show when trying to delete pending mutations
void showPendingMutationsDialog(
  BuildContext context, {
  required int count,
  VoidCallback? onConfirm,
  required WidgetRef ref,
}) {
  final localization = ref.read(localizationProvider);
  final title = localization.getString('offlinePendingChanges');
  final plural = count == 1
      ? ''
      : localization.getString('offlinePendingChangesPlural');
  final message = localization.getString(
    'offlinePendingChangesDescription',
    params: {'count': count.toString(), 'plural': plural},
  );
  final okButton = localization.getString('offlineOkButton');
  final detailsButton = localization.getString('offlineViewPendingDetails');

  if (!context.mounted) return;

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(okButton),
        ),
        if (onConfirm != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onConfirm();
            },
            child: Text(detailsButton),
          ),
      ],
    ),
  );
}
