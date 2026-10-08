// lib/screens/settings/settings_screen.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/app_config_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/user_preferences_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/screens/settings/app_display_settings_screen.dart';
import 'package:matchme/screens/settings/matching_settings_screen.dart';
import 'package:matchme/screens/settings/account_management_screen.dart';
import 'package:matchme/screens/settings/invisibility_rules_screen.dart';
import 'package:matchme/screens/settings/match_preferences_screen.dart';
import 'package:matchme/screens/onboarding/onboarding_intro_screen.dart';
import 'package:matchme/screens/paywall/paywall_screen.dart';
import 'package:matchme/screens/referral/invite_friends_screen.dart';
import 'package:matchme/screens/legal/legal_document_screen.dart';
import 'package:matchme/screens/profile/verification_screen.dart';
import 'package:matchme/screens/subscription/billing_screen.dart';
import 'package:matchme/utils/resume_route_restore.dart';
import 'package:matchme/utils/settings_search_utils.dart';
import 'package:matchme/widgets/pending_mutations_indicator.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/utils/directional_icons.dart';
import 'package:matchme/utils/string_extensions.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.scrollToInvisibilityRules = false});

  final bool scrollToInvisibilityRules;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with WidgetsBindingObserver {
  late String _currentUserId;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _invisibilityRulesKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUserId = Supabase.instance.client.auth.currentUser!.id;

    // Validate Background Matching Mode permission when settings screen is opened
    if (!kIsWeb && Platform.isAndroid) {
      Future.microtask(() async {
        try {
          await ref
              .read(userPreferencesProvider.notifier)
              .syncBackgroundMatchingPermissionState();
        } catch (e) {
          print('Failed to validate Background Matching Mode permission: $e');
        }
      });
    }
    Future.microtask(() async {
      // Refresh from server so an admin verification reset is reflected
      // immediately instead of leaving a stale cached `isVerified`/`pending`
      // value that would block resubmission.
      try {
        await ref
            .read(profileSyncProvider)
            .syncProfile(_currentUserId, source: 'settings-screen-open');
      } catch (_) {}
      await ref
          .read(profileEditProvider(_currentUserId).notifier)
          .loadInitialProfile();
      if (widget.scrollToInvisibilityRules) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final context = _invisibilityRulesKey.currentContext;
          if (context != null) {
            Scrollable.ensureVisible(
              context,
              duration: const Duration(milliseconds: 500),
              alignment: 0.1,
            );
          }
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Validate permission when app resumes from background
    if (state == AppLifecycleState.resumed && !kIsWeb && Platform.isAndroid) {
      Future.microtask(() async {
        try {
          await ref
              .read(userPreferencesProvider.notifier)
              .syncBackgroundMatchingPermissionState();
        } catch (e) {
          print('Failed to validate Background Matching Mode permission: $e');
        }
      });
    }
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _showSettingsSearch(LocalizationState l10n) async {
    final queryController = TextEditingController();
    final parentContext = context;
    final destinations =
        <
          ({
            String label,
            String group,
            String description,
            IconData icon,
            VoidCallback onTap,
          })
        >[
          (
            label: l10n.getString('settingsAppDisplay'),
            group: l10n.getString('settingsSectionGeneral'),
            description: l10n.getString('settingsAppDisplayDesc'),
            icon: Icons.settings_display,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(
                builder: (_) => const AppDisplaySettingsScreen(),
              ),
            ),
          ),
          (
            label: l10n.getString('settingsMatching'),
            group: l10n.getString('settingsSectionMatching'),
            description: l10n.getString('settingsMatchingDesc'),
            icon: Icons.favorite_border,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(builder: (_) => const MatchingSettingsScreen()),
            ),
          ),
          (
            label: l10n.getString('settingsMatchPreferences'),
            group: l10n.getString('settingsSectionMatching'),
            description: l10n.getString('settingsMatchPreferencesDesc'),
            icon: Icons.people_alt_outlined,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(builder: (_) => const MatchPreferencesScreen()),
            ),
          ),
          (
            label: l10n.getString('settingsInvisibilityRules'),
            group: l10n.getString('settingsSectionMatching'),
            description: l10n.getString('settingsInvisibilityRulesDesc'),
            icon: Icons.visibility_off,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(
                builder: (_) => const InvisibilityRulesScreen(),
              ),
            ),
          ),
          (
            label: l10n.getString('settingsNotifications'),
            group: l10n.getString('settingsNotifications'),
            description: l10n.getString('settingsNotificationsSettingsDesc'),
            icon: Icons.notifications_outlined,
            onTap: () => Navigator.of(
              parentContext,
            ).pushNamed(ResumeRouteRestore.notificationsSettingsRoute),
          ),
          (
            label: l10n.getString('inboxTitle'),
            group: l10n.getString('settingsNotifications'),
            description: l10n.getString('inboxEntryDesc'),
            icon: Icons.mark_email_unread_outlined,
            onTap: () => Navigator.of(
              parentContext,
            ).pushNamed(ResumeRouteRestore.notificationInboxRoute),
          ),
          (
            label: l10n.getString('paywallTitle'),
            group: l10n.getString('settingsSectionPremium'),
            description: l10n.getString('paywallFeaturesTitle'),
            icon: Icons.workspace_premium_outlined,
            onTap: () => Navigator.of(
              parentContext,
            ).push(MaterialPageRoute(builder: (_) => const PaywallScreen())),
          ),
          (
            label: l10n.getString('billingTitle'),
            group: l10n.getString('settingsSectionPremium'),
            description: l10n.getString('billingSettingsDescription'),
            icon: Icons.receipt_long_outlined,
            onTap: () => Navigator.of(
              parentContext,
            ).push(MaterialPageRoute(builder: (_) => const BillingScreen())),
          ),
          (
            label: l10n.getString('inviteFriendsTitle'),
            group: l10n.getString('settingsSectionPremium'),
            description: l10n.getString('inviteFriendsDescription'),
            icon: Icons.card_giftcard,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(builder: (_) => const InviteFriendsScreen()),
            ),
          ),
          (
            label: l10n.getString('profileVerification'),
            group: l10n.getString('settingsSectionAccount'),
            description: l10n.getString('getVerifiedToBuildTrust'),
            icon: Icons.verified_outlined,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(builder: (_) => const VerificationScreen()),
            ),
          ),
          (
            label: l10n.getString('securitySignInHubTitle'),
            group: l10n.getString('settingsSectionAccount'),
            description: l10n.getString('securitySignInHubDescription'),
            icon: Icons.security,
            onTap: () => Navigator.of(
              parentContext,
            ).pushNamed(ResumeRouteRestore.securityCenterRoute),
          ),
          (
            label: l10n.getString('settingsAccountManagement'),
            group: l10n.getString('settingsSectionAccount'),
            description: l10n.getString('settingsAccountManagementDesc'),
            icon: Icons.person_outline,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(
                builder: (_) => const AccountManagementScreen(),
              ),
            ),
          ),
          // The legal documents used to be reachable only from the paywall,
          // which is not an acceptable place to be the sole route to a privacy
          // policy or terms of service.
          (
            label: l10n.getString('settingsLegalTerms'),
            group: l10n.getString('settingsSectionGeneral'),
            description: l10n.getString('settingsLegalTermsDesc'),
            icon: Icons.gavel_outlined,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(
                builder: (_) => const LegalDocumentScreen(
                  document: LegalDocument.termsOfService,
                ),
              ),
            ),
          ),
          (
            label: l10n.getString('settingsLegalPrivacy'),
            group: l10n.getString('settingsSectionGeneral'),
            description: l10n.getString('settingsLegalPrivacyDesc'),
            icon: Icons.privacy_tip_outlined,
            onTap: () => Navigator.of(parentContext).push(
              MaterialPageRoute(
                builder: (_) => const LegalDocumentScreen(
                  document: LegalDocument.privacyPolicy,
                ),
              ),
            ),
          ),
        ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final query = queryController.text;
            final queryIsEmpty = query.trim().isEmpty;
            final queryIsRtl =
                !queryIsEmpty && query.trimLeft().isRtlByFirstStrongChar();
            final filtered = destinations
                .where(
                  (destination) => matchesSettingsSearch(
                    query: query,
                    label: destination.label,
                    description: destination.description,
                    group: destination.group,
                  ),
                )
                .toList();
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                MediaQuery.viewInsetsOf(context).bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: queryController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    textDirection: queryIsEmpty
                        ? Directionality.of(context)
                        : (queryIsRtl
                              ? TextDirection.rtl
                              : TextDirection.ltr),
                    textAlign: queryIsEmpty
                        ? TextAlign.start
                        : (queryIsRtl ? TextAlign.right : TextAlign.left),
                    decoration: InputDecoration(
                      hintText: l10n.getString('settingsSearchHint'),
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.getString('settingsSearchNoResults'),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final destination = filtered[index];
                          return ListTile(
                            leading: Icon(destination.icon),
                            title: Text(destination.label),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  destination.group,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color:
                                        Theme.of(
                                          sheetContext,
                                        ).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  destination.description,
                                  maxLines: 2,
                                  overflow: TextOverflow.visible,
                                ),
                              ],
                            ),
                            trailing: Icon(directionalChevron(sheetContext)),
                            onTap: () {
                              Navigator.of(sheetContext).pop();
                              destination.onTap();
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
    queryController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    final profileEditState = ref.watch(profileEditProvider(_currentUserId));
    final isOnline = ref.watch(
      connectivityProvider.select((state) => state.value ?? true),
    );

    // Theme-aware helpers
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.getString('settingsTitle')),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: l10n.getString('settingsSearch'),
            onPressed: () => _showSettingsSearch(l10n),
          ),
          if (!isOnline)
            Container(
              margin: const EdgeInsets.only(right: 8.0),
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 4.0,
              ),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.wifi_off,
                    size: 14,
                    color: colors.onPrimaryContainer,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    l10n.getString('generalOffline'),
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          const PendingMutationsIndicator(showDetails: true),
          Expanded(
            child: SafeArea(
              child: profileEditState.when(
                data: (profile) {
                  if (profile == null) {
                    return AppEmptyState(
                      icon: Icons.person_off_outlined,
                      title: l10n.getString('settingsProfileUnavailableTitle'),
                      message: l10n.getString(
                        'settingsProfileUnavailableMessage',
                      ),
                      actionLabel: l10n.getString('generalRetry'),
                      onAction: () => ref
                          .read(profileEditProvider(_currentUserId).notifier)
                          .loadInitialProfile(),
                    );
                  }

                  return ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16.0),
                    children: [
                      // App tour — replay the guided onboarding introduction.
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                fullscreenDialog: true,
                                builder: (context) =>
                                    const OnboardingIntroScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.school_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString('settingsAppTour'),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString('settingsAppTourDesc'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // App Display Section - Navigate to dedicated screen
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const AppDisplaySettingsScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.settings_display,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString('settingsAppDisplay'),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'settingsAppDisplayDesc',
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      _buildSectionHeader(
                        context,
                        l10n.getString('settingsSectionMatching'),
                      ),
                      // Matching Section - Navigate to dedicated screen
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const MatchingSettingsScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.favorite_border,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString('settingsMatching'),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString('settingsMatchingDesc'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Gender and Age Preferences Section - Navigate to dedicated screen
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const MatchPreferencesScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.people_alt_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString(
                                          'settingsMatchPreferences',
                                        ),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'settingsMatchPreferencesDesc',
                                        ),
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 16,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Invisibility Rules Section - Navigate to dedicated screen
                      Container(
                        key: _invisibilityRulesKey,
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const InvisibilityRulesScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.visibility_off,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString(
                                          'settingsInvisibilityRules',
                                        ),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'settingsInvisibilityRulesDesc',
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      _buildSectionHeader(
                        context,
                        l10n.getString('settingsNotifications'),
                      ),
                      // Notifications Settings Section - Navigate to dedicated screen
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).pushNamed(
                              ResumeRouteRestore.notificationsSettingsRoute,
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.notifications_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString('settingsNotifications'),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'settingsNotificationsSettingsDesc',
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Notification inbox: persistent, re-readable record of
                      // every notification the user has been sent.
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.of(context).pushNamed(
                              ResumeRouteRestore.notificationInboxRoute,
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.mark_email_unread_outlined,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString('inboxTitle'),
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString('inboxEntryDesc'),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      _buildSectionHeader(
                        context,
                        l10n.getString('settingsSectionPremium'),
                      ),
                      Builder(
                        builder: (context) {
                          final config = ref.watch(appConfigProvider);
                          final showSubscription =
                              (config['subscription.enabled']?.toLowerCase() ??
                                  'true') ==
                              'true';
                          final showInviteFriends =
                              (config['referral.enabled']?.toLowerCase() ??
                                  'true') ==
                              'true';

                          return Column(
                            children: [
                              if (showSubscription)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const PaywallScreen(),
                                        ),
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Theme.of(context)
                                                .colorScheme
                                                .tertiary
                                                .withValues(alpha: 0.12),
                                            Theme.of(context)
                                                .colorScheme
                                                .tertiary
                                                .withValues(alpha: 0.06),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .tertiary
                                              .withValues(alpha: 0.25),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .tertiary
                                                  .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              Icons.workspace_premium_outlined,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.tertiary,
                                              size: 28,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  l10n.getString(
                                                    'paywallTitle',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.tertiary,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  l10n.getString(
                                                    'paywallFeaturesTitle',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.7),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Icon(
                                            directionalForwardIos(context),
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.tertiary,
                                            size: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (showSubscription)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const BillingScreen(),
                                        ),
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Theme.of(context)
                                                .colorScheme
                                                .secondary
                                                .withValues(alpha: 0.12),
                                            Theme.of(context)
                                                .colorScheme
                                                .secondary
                                                .withValues(alpha: 0.06),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.25),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .secondary
                                                  .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              Icons.receipt_long_outlined,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.secondary,
                                              size: 28,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  l10n.getString(
                                                    'billingTitle',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.secondary,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  l10n.getString(
                                                    'billingSettingsDescription',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.7),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Icon(
                                            directionalForwardIos(context),
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.secondary,
                                            size: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (showInviteFriends)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const InviteFriendsScreen(),
                                        ),
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(16),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.1),
                                            Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.05),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.2),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withValues(alpha: 0.1),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Icon(
                                              Icons.card_giftcard,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              size: 28,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  l10n.getString(
                                                    'inviteFriendsTitle',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.bold,
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  l10n.getString(
                                                    'inviteFriendsDescription',
                                                  ),
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurface
                                                        .withValues(alpha: 0.7),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Icon(
                                            directionalForwardIos(context),
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            size: 20,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),

                      _buildSectionHeader(
                        context,
                        l10n.getString('settingsSectionAccount'),
                      ),
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          // Tapping opens the verification screen for unverified/rejected/pending users.
                          // For already-verified users the tile is non-interactive — there is nothing
                          // left to do, and the check-circle icon already signals that clearly.
                          onTap: profile.isVerified
                              ? null
                              : () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          const VerificationScreen(),
                                    ),
                                  );
                                },
                          borderRadius: BorderRadius.circular(16),
                          child: Opacity(
                            opacity: profile.isVerified ? 0.8 : 1,
                            child: Builder(
                              builder: (context) {
                                final status = profile.isVerified
                                    ? 'approved'
                                    : profile.verificationStatus;

                                Color accentColor;
                                IconData leadingIcon;
                                String title;
                                String subtitle;

                                switch (status) {
                                  case 'approved':
                                    accentColor = Colors.green;
                                    leadingIcon = Icons.verified;
                                    title = l10n.getString('verified');
                                    subtitle = l10n.getString(
                                      'verifiedDescription',
                                    );
                                    break;
                                  case 'pending':
                                    accentColor = Colors.orange;
                                    leadingIcon = Icons.pending;
                                    title = l10n.getString('underReview');
                                    subtitle = l10n.getString(
                                      'underReviewDescription',
                                    );
                                    break;
                                  case 'analyzing':
                                    accentColor = Colors.blue;
                                    leadingIcon = Icons.hourglass_top;
                                    title = l10n.getString('analyzingPhotos');
                                    subtitle = l10n.getString(
                                      'analyzingPhotosDescription',
                                    );
                                    break;
                                  case 'rejected':
                                    accentColor = colors.error;
                                    leadingIcon = Icons.error;
                                    title = l10n.getString(
                                      'verificationRejected',
                                    );
                                    subtitle = l10n.getString(
                                      'verificationNotApproved',
                                    );
                                    break;
                                  default:
                                    accentColor = Theme.of(
                                      context,
                                    ).colorScheme.primary;
                                    leadingIcon = Icons.verified_outlined;
                                    title = l10n.getString(
                                      'profileVerification',
                                    );
                                    subtitle =
                                        profile.verificationSubmittedAt == null
                                        ? l10n.getString(
                                            'getVerifiedToBuildTrust',
                                          )
                                        : l10n.getString(
                                            'notVerifiedDescription',
                                          );
                                }

                                return Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        accentColor.withValues(alpha: 0.1),
                                        accentColor.withValues(alpha: 0.05),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: accentColor.withValues(alpha: 0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: accentColor.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          leadingIcon,
                                          color: accentColor,
                                          size: 28,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title,
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                color: accentColor,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              subtitle,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.7),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Icon(
                                        profile.isVerified
                                            ? Icons.check_circle
                                            : directionalForwardIos(context),
                                        color: accentColor,
                                        size: 20,
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      ),

                      // Security & Sign-In Hub Button
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.of(
                              context,
                            ).pushNamed(ResumeRouteRestore.securityCenterRoute);
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.security,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString(
                                          'securitySignInHubTitle',
                                        ),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'securitySignInHubDescription',
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Account Management Section - Navigate to dedicated screen
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const AccountManagementScreen(),
                              ),
                            );
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.1),
                                  Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: 0.05),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.person,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    size: 28,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.getString(
                                          'settingsAccountManagement',
                                        ),
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        l10n.getString(
                                          'settingsAccountManagementDesc',
                                        ),
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.7),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Icon(
                                  directionalForwardIos(context),
                                  color: Theme.of(context).colorScheme.primary,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
                loading: () => SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: AppSkeletonList(
                      itemCount: 5,
                      itemHeight: 72,
                      semanticLabel: l10n.getString('generalLoading'),
                    ),
                  ),
                ),
                error: (e, s) => AppEmptyState(
                  icon: Icons.cloud_off,
                  title: l10n.getString('settingsLoadErrorTitle'),
                  message: l10n.getString('settingsLoadErrorMessage'),
                  actionLabel: l10n.getString('generalRetry'),
                  onAction: () => ref
                      .read(profileEditProvider(_currentUserId).notifier)
                      .loadInitialProfile(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
