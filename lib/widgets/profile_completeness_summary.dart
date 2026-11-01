// lib/widgets/profile_completeness_summary.dart
//
// Display-only completeness widgets:
//   * ProfileCompletenessSummary — owner-facing ring + "next steps" checklist.
//     Deliberately free of wizard/navigation imports so it can be embedded in
//     both the owner profile card and the wizard's final review page.
//   * ProfileCompletePill — the public 100% badge shown to OTHER users.
//     Reads "Profile Complete" and is styled like the verified / new-here
//     chips so all three status markers look like one set.
//     Incomplete profiles get no public indicator: the nudge is private, the
//     badge is a positive signal only.
//
// Scoring rules live in lib/utils/profile_completeness.dart (mirror of the
// SQL function public.profile_completeness_score).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/theme/semantic_colors.dart';
import 'package:matchme/utils/profile_completeness.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';
import 'package:matchme/widgets/safe_text.dart';

/// Amber "Profile Complete" badge for profiles at 100%. Never render a raw
/// percentage for other users — only this badge when the profile is full.
///
/// Styled like its siblings ([VerifiedBadge] / [NewUserBadge]): same chip
/// size, same font, same shape — only the colour differs. The three status
/// chips are meant to be read as one set wherever they appear together.
class ProfileCompletePill extends StatelessWidget {
  const ProfileCompletePill({
    super.key,
    required this.l10n,
    this.size = 18.0,
  });

  final LocalizationState l10n;

  /// Icon size; also drives the chip's corner radius, exactly like the
  /// verified / new-here chips.
  final double size;

  /// Solid amber fill. White text keeps the same contrast story as the
  /// primary (verified) and green (new here) chips.
  static const Color fillColor = Color(0xFF92400E);

  @override
  Widget build(BuildContext context) {
    final raw = l10n.getString('profileCompletionBadge');
    final label = (raw.isEmpty || raw.startsWith('['))
        ? 'Profile Complete'
        : raw;
    return Tooltip(
      message: l10n.getString('profileCompletionBadgeTooltip'),
      child: Semantics(
        label: label,
        container: true,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10.0,
              vertical: 4.0,
            ),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(size * 0.6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: Directionality.of(context),
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.workspace_premium_rounded,
                  color: Colors.white,
                  size: size,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: ShrinkText(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Owner-facing completeness block: score ring, motivating copy and the list
/// of unfinished items with their point values. Rendered inside a card shell
/// by the caller (ProfileCompletenessCard on the profile screen, a Card in the
/// wizard's final review).
class ProfileCompletenessSummary extends ConsumerWidget {
  const ProfileCompletenessSummary({
    super.key,
    required this.profile,
    this.onSectionTap,
    this.maxItems = 4,
    this.showRing = true,
  });

  final UserProfile profile;

  /// Called with the wizard section for an unfinished item. When null the
  /// checklist is display-only (no chevrons, no taps).
  final void Function(ProfileWizardSection section)? onSectionTap;

  /// Cap on checklist rows so the card stays compact.
  final int maxItems;

  final bool showRing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final scheme = Theme.of(context).colorScheme;
    final semantic = SemanticColors.of(context);
    final isDark = scheme.brightness == Brightness.dark;
    final amberInk = isDark ? Colors.amber.shade400 : const Color(0xFF92400E);
    // Always compute locally so edits show immediately (the server-cached
    // value can lag behind during the post-save sync hold window). The Dart
    // rules mirror the SQL trigger, so the two agree once synced.
    final score = ProfileCompleteness.score(profile);
    final isFull = score >= ProfileCompleteness.fullScore;
    final remaining = ProfileCompleteness.remainingItems(profile);
    final subtleColor = scheme.onSurfaceVariant;

    if (isFull) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: 26,
            color: amberInk,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.getString('profileCompletionFullTitle'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.getString('profileCompletionFullMessage'),
                  style: TextStyle(fontSize: 12.5, color: subtleColor),
                ),
              ],
            ),
          ),
          Icon(Icons.check_circle, size: 22, color: semantic.success),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (showRing) ...[
              _scoreRing(context, score),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.getString('profileCompletionTitle'),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    score >= 90
                        ? l10n.getString('profileCompletionAlmostThere')
                        : l10n.getString('profileCompletionSubtitle'),
                    style: TextStyle(fontSize: 12.5, color: subtleColor),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (remaining.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            l10n.getString('profileCompletionNextSteps'),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          for (final item in remaining.take(maxItems))
            _itemRow(context, l10n, item),
          if (remaining.length > maxItems)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 4, start: 2),
              child: Text(
                l10n.getString(
                  'profileCompletionMoreItems',
                  params: {'count': '${remaining.length - maxItems}'},
                ),
                style: TextStyle(fontSize: 12, color: subtleColor),
              ),
            ),
        ],
      ],
    );
  }

  Widget _scoreRing(BuildContext context, int score) {
    final scheme = Theme.of(context).colorScheme;
    final color = score >= 90
        ? SemanticColors.of(context).success
        : scheme.primary;
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 54,
            height: 54,
            child: CircularProgressIndicator(
              value: score / 100,
              strokeWidth: 5,
              backgroundColor: scheme.surfaceContainerHighest,
              color: color,
              strokeCap: StrokeCap.round,
            ),
          ),
          Text(
            '$score%',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(
    BuildContext context,
    LocalizationState l10n,
    ProfileCompletenessItem item,
  ) {
    final subtleColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      child: Row(
        children: [
          Icon(Icons.radio_button_unchecked, size: 15, color: subtleColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.getString(item.labelKey),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Text(
            '+${item.remainingPoints}%',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          if (onSectionTap != null)
            Icon(Icons.chevron_right, size: 16, color: subtleColor),
        ],
      ),
    );
    if (onSectionTap == null) return row;
    return InkWell(
      onTap: () => onSectionTap!(item.section),
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}
