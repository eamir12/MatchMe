// Compact, dismissible offer to watch a section's guided tour.
//
// Shown once per section per account on first visit (see
// OnboardingTour.promptOnFirstVisit): a small in-context card instead of an
// auto-opening full-screen tour, so guidance never interrupts the goal the
// user came to the section to do. Either action — watching or dismissing —
// permanently consumes the offer for that account (device-local + synced via
// OnboardingIntroService); the tour itself stays replayable from
// Settings → App tour.
//
// The widget renders nothing until the seen-state check resolves, and
// nothing ever when the tour is not a first-visit offer.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/services/onboarding_intro_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class OnboardingSectionPrompt extends ConsumerStatefulWidget {
  const OnboardingSectionPrompt({super.key, required this.tour});

  /// The section tour to offer; ignored when [OnboardingTour.promptOnFirstVisit]
  /// is false.
  final OnboardingTour tour;

  @override
  ConsumerState<OnboardingSectionPrompt> createState() =>
      _OnboardingSectionPromptState();
}

class _OnboardingSectionPromptState
    extends ConsumerState<OnboardingSectionPrompt> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _maybeShow();
  }

  String? _currentUserId() {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<void> _maybeShow() async {
    if (!widget.tour.promptOnFirstVisit) return;
    final seen = await OnboardingIntroService.instance.hasSeenSection(
      widget.tour.id,
      userId: _currentUserId(),
    );
    if (!mounted || seen) return;
    setState(() => _visible = true);
  }

  Future<void> _consumeOffer() async {
    await OnboardingIntroService.instance.markSectionSeen(
      widget.tour.id,
      userId: _currentUserId(),
    );
    if (mounted) setState(() => _visible = false);
  }

  Future<void> _startTour() async {
    final tour = widget.tour;
    await _consumeOffer();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingIntroScreen(tour: tour),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final l10n = ref.watch(localizationProvider);
    final colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        decoration: BoxDecoration(
          color: colors.primaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.school_outlined, size: 20, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.getString('onboardingSectionPromptBody'),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: colors.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _consumeOffer,
                  child: Text(l10n.getString('onboardingSectionPromptDismiss')),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: _startTour,
                  child: Text(l10n.getString('onboardingSectionPromptStart')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
