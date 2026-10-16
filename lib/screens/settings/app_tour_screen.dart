// Settings → App tour hub.
//
// Lists the replayable guided tours: the short "basics" tour that auto-runs
// once after profile completion, plus one tour per app section (also offered
// contextually on first visit). Tapping any entry plays it in the standard
// narrated player (OnboardingIntroScreen); nothing here is ever marked as
// unseen again — replays never re-arm the automatic offers.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/screens/onboarding/onboarding_content.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/widgets/safe_text.dart';

class AppTourScreen extends ConsumerWidget {
  const AppTourScreen({super.key});

  void _play(BuildContext context, OnboardingTour tour) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingIntroScreen(tour: tour),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = ref.watch(localizationProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: ShrinkText(l10n.getString('settingsAppTour'))),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _TourCard(
            icon: Icons.auto_awesome_outlined,
            title: l10n.getString('onboardingTourBasics'),
            subtitle: l10n.getString('onboardingTourBasicsDesc'),
            onTap: () => _play(context, kOnboardingCoreTour),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Text(
              l10n.getString('onboardingTourSections'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          for (final tour in kOnboardingSectionTours)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TourCard(
                icon: _sectionIcon(tour.id),
                title: l10n.getString(tour.titleKey),
                onTap: () => _play(context, tour),
              ),
            ),
        ],
      ),
    );
  }

  IconData _sectionIcon(String sectionId) {
    switch (sectionId) {
      case 'home':
        return Icons.home_outlined;
      case 'matches':
        return Icons.favorite_border;
      case 'chats':
        return Icons.chat_bubble_outline;
      case 'nearby':
        return Icons.explore_outlined;
      case 'worldmap':
        return Icons.public;
      case 'events':
        return Icons.event_outlined;
      case 'profile':
        return Icons.person_outline;
      case 'settings':
        return Icons.settings_outlined;
      default:
        return Icons.school_outlined;
    }
  }
}

class _TourCard extends StatelessWidget {
  const _TourCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: theme.shadowColor.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ShrinkText(
                      title,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.play_circle_outline, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}
