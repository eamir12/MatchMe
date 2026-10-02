import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';

class DueRatingPromptDialog extends ConsumerWidget {
  final String matchId;
  final String otherUserId;
  final String otherName;

  const DueRatingPromptDialog({
    super.key,
    required this.matchId,
    required this.otherUserId,
    required this.otherName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actionsAlignment: MainAxisAlignment.end,
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actionsOverflowButtonSpacing: 8,
      actionsOverflowDirection: VerticalDirection.down,
      title: Text(l10n.getString('ratingPromptTitle')),
      content: Text(
        l10n.getString('ratingPromptBody').replaceAll('{name}', otherName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('later'),
          child: Text(l10n.getString('ratingPromptLater')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop('no'),
          child: Text(l10n.getString('ratingPromptNo')),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop('yes'),
          child: Text(l10n.getString('ratingPromptYes')),
        ),
      ],
    );
  }
}
