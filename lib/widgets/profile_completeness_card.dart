// lib/widgets/profile_completeness_card.dart
//
// Owner-facing completeness surfaces that need navigation side effects:
//   * openProfileWizardAt  — opens the wizard at an optional section.
//   * ProfileCompletenessCard   — card for the own-profile screen.
//   * ProfileCompletenessBanner — dismissible nudge for the home feed.
//
// Public badges live in profile_completeness_summary.dart; scoring rules in
// lib/utils/profile_completeness.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:matchme/utils/profile_completeness.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';
import 'package:matchme/widgets/profile_completeness_summary.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Opens the profile wizard for the signed-in user, optionally jumping
/// straight to [section]. The wizard honors [section] even in
/// edit-after-complete mode.
Future<void> openProfileWizardAt(
  BuildContext context, {
  ProfileWizardSection? section,
}) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProfileWizardScreen(
        user: user,
        isEditing: true,
        initialSection: section,
      ),
    ),
  );
}

/// Completeness card for the own-profile screen. Tapping a "next step" opens
/// the wizard at that section (unless [onSectionTap] overrides).
class ProfileCompletenessCard extends ConsumerWidget {
  const ProfileCompletenessCard({
    super.key,
    required this.profile,
    this.onSectionTap,
    this.margin,
  });

  final UserProfile profile;
  final void Function(ProfileWizardSection section)? onSectionTap;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final score = ProfileCompleteness.score(profile);
    final isFull = score >= ProfileCompleteness.fullScore;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: margin ?? const EdgeInsets.fromLTRB(16, 4, 16, 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isFull
              ? Colors.green.withValues(alpha: 0.45)
              : colorScheme.outlineVariant,
        ),
      ),
      child: ProfileCompletenessSummary(
        profile: profile,
        onSectionTap:
            onSectionTap ??
            (section) => openProfileWizardAt(context, section: section),
      ),
    );
  }
}

/// Dismissible home-feed nudge. Hidden at 100% and hidden again after the
/// user dismisses it at the current score — but a later score change makes it
/// re-appear (dismissal is per user and per score, stored locally).
class ProfileCompletenessBanner extends ConsumerStatefulWidget {
  const ProfileCompletenessBanner({super.key, required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<ProfileCompletenessBanner> createState() =>
      _ProfileCompletenessBannerState();
}

class _ProfileCompletenessBannerState
    extends ConsumerState<ProfileCompletenessBanner> {
  bool _prefsLoaded = false;
  int? _dismissedScore;

  String get _prefsKey =>
      'profile_completeness_banner_dismissed_${widget.profile.id}';

  @override
  void initState() {
    super.initState();
    _loadDismissedScore();
  }

  Future<void> _loadDismissedScore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getInt(_prefsKey);
      if (!mounted) return;
      setState(() {
        _dismissedScore = raw;
        _prefsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _prefsLoaded = true);
    }
  }

  Future<void> _dismiss(int score) async {
    setState(() => _dismissedScore = score);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsKey, score);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    // Local (not server-cached) score so wizard edits reflect immediately.
    final score = ProfileCompleteness.score(widget.profile);
    if (!_prefsLoaded || score >= ProfileCompleteness.fullScore) {
      return const SizedBox.shrink();
    }
    if (_dismissedScore == score) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final subtleColor = colorScheme.onSurface.withValues(alpha: 0.65);
    final remaining = ProfileCompleteness.remainingItems(widget.profile);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.workspace_premium_rounded,
                size: 22,
                color: Colors.amber.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString('profileCompletionBannerTitle'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: subtleColor,
                tooltip: l10n.getString('profileCompletionDismiss'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _dismiss(score),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.getString(
                    'profileCompletionBannerMessage',
                    params: {'percent': '$score'},
                  ),
                  style: TextStyle(fontSize: 12.5, color: subtleColor),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: score / 100,
                    minHeight: 6,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '$score%',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () {
                        final section = remaining.isEmpty
                            ? null
                            : remaining.first.section;
                        openProfileWizardAt(context, section: section);
                      },
                      child: Text(
                        l10n.getString('profileCompletionImprove'),
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
