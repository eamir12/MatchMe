// lib/widgets/event_import_block_sheet.dart
//
// "Why can't I import this?" explainer for the calendar-import pickers.
// Shown instead of a transient snackbar when the user taps a greyed-out
// event. Includes a false-positive report action ("This event is actually
// public") — one report per user, with appropriate messaging once used —
// that logs the decision inputs (scrubbed title + event snapshot) for
// admin review and classifier tuning. Feedback is limited per event, not
// globally per user.

import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/event_import_feedback_service.dart';
import 'package:matchme/utils/event_import_classifier.dart';

/// Keys for the per-reason sheet title/body, kept next to the classifier
/// so a new [EventImportBlockReason] forces a decision here.
String _sheetTitleKey(EventImportBlockReason reason) => switch (reason) {
  EventImportBlockReason.none => '',
  EventImportBlockReason.markedPrivate => 'importBlockSheetTitlePrivate',
  EventImportBlockReason.looksPrivate => 'importBlockSheetTitlePersonal',
  EventImportBlockReason.noPublicContext => 'importBlockSheetTitleContext',
};

String _sheetBodyKey(EventImportBlockReason reason) => switch (reason) {
  EventImportBlockReason.none => '',
  EventImportBlockReason.markedPrivate => 'importBlockSheetBodyPrivate',
  EventImportBlockReason.looksPrivate => 'importBlockSheetBodyPersonal',
  EventImportBlockReason.noPublicContext => 'importBlockSheetBodyContext',
};

Future<void> showEventImportBlockSheet(
  BuildContext context,
  LocalizationState l10n,
  EventImportBlockReason reason, {
  String? eventTitle,
  String? provider,
  Map<String, dynamic>? eventSnapshot,
}) async {
  if (reason.importable) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: false,
    builder: (sheetContext) {
      final colors = Theme.of(sheetContext).colorScheme;
      final isRtl = [
        'ar',
        'he',
      ].contains(l10n.currentLocale.languageCode.toLowerCase());
      final messenger = ScaffoldMessenger.maybeOf(context);
      return Directionality(
        textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.lock_outline_rounded, color: colors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.getString(_sheetTitleKey(reason)),
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.getString(
                    _sheetBodyKey(reason),
                    params: eventTitle == null || eventTitle.trim().isEmpty
                        ? null
                        : {'title': eventTitle.trim()},
                  ),
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.getString('importBlockSheetWhatImportableTitle'),
                        style: Theme.of(sheetContext).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.getString('importBlockSheetWhatImportableBody'),
                        style: Theme.of(sheetContext).textTheme.bodySmall
                            ?.copyWith(color: colors.onSecondaryContainer),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _FeedbackAction(
                  l10n: l10n,
                  colors: colors,
                  messenger: messenger,
                  reason: reason,
                  eventTitle: eventTitle,
                  provider: provider,
                  eventSnapshot: eventSnapshot,
                  eventKey: EventImportFeedbackService.eventKey(
                    provider: provider,
                    eventTitle: eventTitle ?? '',
                    eventSnapshot: eventSnapshot,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _FeedbackAction extends StatelessWidget {
  const _FeedbackAction({
    required this.l10n,
    required this.colors,
    required this.messenger,
    required this.reason,
    required this.eventTitle,
    required this.provider,
    required this.eventSnapshot,
    required this.eventKey,
  });

  final LocalizationState l10n;
  final ColorScheme colors;
  final ScaffoldMessengerState? messenger;
  final EventImportBlockReason reason;
  final String? eventTitle;
  final String? provider;
  final Map<String, dynamic>? eventSnapshot;
  final String eventKey;

  Future<void> _onPressed() async {
    final status = await EventImportFeedbackService.reportFalsePositive(
      blockReason: reason.name,
      eventTitle: eventTitle ?? '',
      provider: provider,
      appLocale: l10n.currentLocale.toLanguageTag(),
      eventSnapshot: eventSnapshot,
    );
    final messageKey = switch (status) {
      EventImportFeedbackStatus.sent => 'importBlockSheetFeedbackThanks',
      EventImportFeedbackStatus.alreadyReported =>
        'importBlockSheetFeedbackAlreadyUsed',
      _ => null,
    };
    if (messageKey != null) {
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.getString(messageKey))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: EventImportFeedbackService.hasAlreadyReported(
        eventKey: eventKey,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const SizedBox(
            height: 44,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snapshot.data == true) {
          // One feedback per user: this user already used their report.
          return Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('importBlockSheetFeedbackAlreadyUsed'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          );
        }
        return OutlinedButton.icon(
          onPressed: _onPressed,
          icon: const Icon(Icons.flag_outlined),
          label: Text(l10n.getString('importBlockSheetFeedbackButton')),
        );
      },
    );
  }
}
