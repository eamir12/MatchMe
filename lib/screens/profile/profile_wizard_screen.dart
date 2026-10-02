import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:extended_image/extended_image.dart';

import 'package:matchme/models/hierarchy_models.dart';
import 'package:matchme/models/photo_moderation_rejection.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/home_providers.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';
import 'package:matchme/utils/zodiac.dart';
import 'package:matchme/screens/profile/request_change_dialog.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/photo_service.dart';
import 'package:matchme/services/error_localization_service.dart';
import 'package:matchme/services/global_sync_manager.dart';
import 'package:matchme/services/session_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/voice_guidance_service.dart';
import 'package:matchme/providers/voice_guidance_provider.dart';
import 'package:matchme/widgets/voice_guidance_mute_button.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/birthdate_wheel_picker_dialog.dart';
import 'package:matchme/widgets/photo_editor_widget.dart';
import 'package:matchme/widgets/please_wait_dialog.dart';
import 'package:matchme/widgets/photo_rejection_dialog.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:auto_size_text/auto_size_text.dart';

String _normalizeKey(String s) {
  final trimmed = s.trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

// Suffix appended to voluntary field labels so users can tell at a glance
// which fields can be skipped.
String _optionalFieldLabel(LocalizationState l10n, String key) =>
    '${l10n.getString(key)} (${l10n.getString('profileFieldOptional')})';

// Per-page legend shown under the page subtitle: either the required-fields
// legend or the all-optional hint, so expectations are explicit before the
// user starts filling the page in.
class _WizardFieldLegend extends StatelessWidget {
  final LocalizationState l10n;
  final bool allOptional;

  const _WizardFieldLegend({required this.l10n, this.allOptional = false});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700);
    if (allOptional) {
      return Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child: Text(l10n.getString('profileWizardAllOptionalHint'), style: style),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4.0),
      child: Row(
        children: [
          Text(
            '* ',
            style: style?.copyWith(
              color: Colors.red,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(l10n.getString('profileWizardRequiredLegend'), style: style),
          ),
        ],
      ),
    );
  }
}

// Helper to extract username from Instagram URL
String? _extractInstagramUsername(String? url) {
  if (url == null || url.isEmpty) return null;
  final patterns = [
    RegExp(r'https?://(?:www\.)?instagram\.com/([^/?]+)'),
    RegExp(r'instagram\.com/([^/?]+)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

// Helper to extract username from LinkedIn URL
String? _extractLinkedinUsername(String? url) {
  if (url == null || url.isEmpty) return null;
  final patterns = [
    RegExp(r'https?://(?:www\.)?linkedin\.com/in/([^/?]+)'),
    RegExp(r'linkedin\.com/in/([^/?]+)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

// Helper to construct full Instagram URL from username
String _constructInstagramUrl(String username) {
  final trimmed = username.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http')) return trimmed;
  if (trimmed.contains('instagram.com')) return trimmed;
  return 'https://instagram.com/$trimmed';
}

// Helper to construct full LinkedIn URL from username
String _constructLinkedinUrl(String username) {
  final trimmed = username.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http')) return trimmed;
  if (trimmed.contains('linkedin.com')) return trimmed;
  return 'https://linkedin.com/in/$trimmed';
}

// Helper to extract username from Facebook URL
String? _extractFacebookUsername(String? url) {
  if (url == null || url.isEmpty) return null;
  final patterns = [
    RegExp(r'https?://(?:www\.)?facebook\.com/([^/?]+)'),
    RegExp(r'facebook\.com/([^/?]+)'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(url);
    if (match != null) {
      return match.group(1);
    }
  }
  return null;
}

// Helper to construct full Facebook URL from username
String _constructFacebookUrl(String username) {
  final trimmed = username.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.startsWith('http')) return trimmed;
  if (trimmed.contains('facebook.com')) return trimmed;
  return 'https://facebook.com/$trimmed';
}

String? _normalizeBioTextForComparison(String? bio) {
  if (bio == null) return null;
  final normalized = bio
      .replaceAll('\u200B', '')
      .replaceAll('\u200C', '')
      .replaceAll('\u200D', '')
      .replaceAll('\uFEFF', '')
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return normalized.isEmpty ? null : normalized;
}

/// Session-level persistence for pill show/hide.
/// Maps userId → Set<"fieldKey:status"> combos that have been shown this session.
final _sessionDismissedPillKeys = <String, Set<String>>{};

class ProfileWizardScreen extends ConsumerStatefulWidget {
  final User user;
  final bool isEditing;

  /// When set (completeness routing at startup/resume), the wizard jumps
  /// straight to this section's page on load instead of restoring the
  /// draft's last page.
  final ProfileWizardSection? initialSection;
  const ProfileWizardScreen({
    super.key,
    required this.user,
    this.isEditing = false,
    this.initialSection,
  });
  @override
  ConsumerState<ProfileWizardScreen> createState() =>
      _ProfileWizardScreenState();
}

class _ProfileWizardValidationIssue {
  const _ProfileWizardValidationIssue(this.message, this.section);

  final String message;
  final ProfileWizardSection section;
}

class _ProfileWizardScreenState extends ConsumerState<ProfileWizardScreen> {
  /// True when the user has already completed their profile once and is now
  /// editing it (via "Edit" on the profile screen). In this mode the wizard
  /// must start at the beginning and allow saving from any step.
  static bool isEditAfterCompleteMode({
    required bool isEditing,
    required bool isProfileComplete,
  }) {
    return isEditing && isProfileComplete;
  }

  /// Helper to get the list of selected AppIntent objects from the profile's activeModes
  List<AppIntent> _getSelectedIntents(
    WidgetRef ref,
    UserProfile? profile,
    List<AppIntent> allIntents,
  ) {
    if (profile == null) return [];
    final selectedKeys = profile.activeModes
        .map((k) => k.trim().toLowerCase())
        .toSet();
    return allIntents
        .where(
          (intent) => selectedKeys.contains(intent.key.trim().toLowerCase()),
        )
        .toList();
  }

  final _pageController = PageController();
  final _nameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _dobController = TextEditingController();
  final _bioController = TextEditingController();
  final _searchIntentController = TextEditingController();
  final _searchInterestController = TextEditingController();
  final _searchBusinessInterestController = TextEditingController();
  String _personalInterestSearchQuery = '';
  String _businessInterestSearchQuery = '';
  final _heightController = TextEditingController();
  final _heightFeetController = TextEditingController();
  final _heightInchesController = TextEditingController();
  int _heightUnitMode = 0; // 0 = cm, 1 = feet/inches
  bool _heightUnitModeInitialized = false;
  final _occupationController = TextEditingController();
  final _educationController = TextEditingController();
  final _formKeyStep1 = GlobalKey<FormState>();
  bool _isLoading = false;
  int? _dropTargetIndex;
  // MD5 hashes of photos added during this wizard session, keyed by their
  // draft storage path. Used by the prescreen to block re-adding the exact
  // same photo; entries are released when the photo is removed or replaced.
  final Map<String, String> _sessionPhotoHashByPath = {};
  bool _isInitialized = false;
  bool _wizardProfileLoading = false;
  int _profileLoadRetries = 0;
  UserProfile? _lastGoodProfile;
  bool _userDeletedCheckPerformed = false;
  Timer? _draftDebounce;
  Timer? _primaryPhotoValidationDebounce;
  String? _pendingPrimaryPhotoPath;
  String? _primaryValidationPhotoPath;
  Future<void>? _primaryValidationFuture;
  String? _lastValidatedPrimaryPhotoPath;
  String? _lastDraftJson;
  bool _draftEnabled = false;
  bool _didPrefetchPhotos = false;
  final bool _isSaving = false;

  int _currentPageIndex = 0;

  // --- Voice guidance (spoken step coaching; can be muted from the app bar) ---
  bool _didSpeakInitialStep = false;

  // Programmatic page changes (Next / jump-to-error) optimistically set
  // _currentPageIndex to their target before the PageController animation
  // runs, so the first animation frames still round to the OLD page and the
  // page listener below used to announce the screen the user just left —
  // the announcement for the real destination was then dropped by the TTS
  // service's 2s gap guard, making the narration lag one screen behind.
  // While this target is pending, the listener only reacts to frames that
  // reach it; the destination itself is announced when the change starts.
  int? _programmaticNavTarget;
  DateTime _programmaticNavAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _programmaticNavTtl = Duration(milliseconds: 1200);

  Map<String, dynamic>? _originalSnapshot;
  final Set<String> _expandedInterestKeys = {};
  final Set<String> _markedProfileEditRequestSeenIds = {};
  final Set<String> _currentVisitPillCombos = {};
  final Set<String> _currentVisitRequestIds = {};
  String? _lastBioModeratedText;
  bool? _lastBioModerationAllowed;
  String?
  _originalBio; // Stores original bio to check if it was changed before moderating

  static const double _leadingWidth = 56.0;
  static const double _rowVerticalPadding = 12.0;
  static int _maxSocialMainInterests = 10;
  static int _maxBusinessMainInterests = 10;
  static int _maxBioLength = 300;
  static int _minSubIntents = 1;
  static int _maxSubIntents = 10;
  static int _minMainInterests = 1;
  static int _maxSubInterestsPer = 10;

  static Future<void> loadConfig() async {
    try {
      _maxBioLength = await AppConfigService().getInt(
        'profile.bio_max_length',
        defaultValue: 300,
      );
      _maxSocialMainInterests = await AppConfigService().getInt(
        'profile.max_main_interests',
        defaultValue: 10,
      );
      _maxBusinessMainInterests = await AppConfigService().getInt(
        'profile.max_main_interests',
        defaultValue: 10,
      );
      _minSubIntents = await AppConfigService().getInt(
        'profile.min_sub_intents',
        defaultValue: 1,
      );
      _maxSubIntents = await AppConfigService().getInt(
        'profile.max_sub_intents',
        defaultValue: 10,
      );
      _minMainInterests = await AppConfigService().getInt(
        'profile.min_main_interests',
        defaultValue: 1,
      );
      _maxSubInterestsPer = await AppConfigService().getInt(
        'profile.max_sub_interests_per',
        defaultValue: 10,
      );
    } catch (e) {
      _maxBioLength = 300;
    }
  }

  Future<void> _clearLoginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('was_logged_in');
      await prefs.remove('user_id');
      await prefs.remove('supabase_url');
      await prefs.remove('supabase_key');

      // Also clear the persisted session snapshot from SessionService
      // This is critical after offline→online→logout cycle to ensure clean state
      // for passkey authentication flow on next login
      await SessionService.clearPersistedSupabaseSessionSnapshot();
    } catch (e) {
      print('Error clearing login state from profile wizard: $e');
    }
  }

  Future<void> _verifyUserStillExists() async {
    if (!mounted) return;

    // POLICY: never auto-sign-out here. A missing `users` row 1s after
    // wizard init is expected for brand-new signups (row created async by
    // trigger/sync) and for transient offline/RLS states — not proof of
    // deletion. Only auth.forced_sign_out_days or an explicit UI logout
    // may sign out. Stay in the wizard so the profile can be created.
    try {
      final supabase = Supabase.instance.client;
      final userId = widget.user.id;

      // Check if user still exists in the database
      final userExists = await supabase
          .from('users')
          .select('id')
          .eq('id', userId)
          .maybeSingle();

      if (!mounted) return;

      if (userExists == null) {
        print(
          '[ProfileWizardScreen] users row missing — keeping session, NOT signing out',
        );
      }
    } catch (e) {
      print('[ProfileWizardScreen] Error verifying user existence: $e');
      // Don't redirect on error, just log it
    }
  }

  Future<void> _showOfflineLanguageUnavailableDialog() async {
    final l10n = ref.read(localizationProvider);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        icon: const Icon(
          Icons.cloud_off_rounded,
          size: 32,
          color: Colors.orange,
        ),
        title: Text(l10n.getString('offlineLanguageUnavailableTitle')),
        content: Text(l10n.getString('offlineLanguageUnavailableMessage')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.getString('offlineOkButton')),
          ),
        ],
      ),
    );
  }

  List<AppLanguage> _fallbackPickerLanguages(
    List<AppLanguage> supportedLanguages,
  ) {
    if (supportedLanguages.isNotEmpty) {
      return supportedLanguages;
    }

    return [
      AppLanguage(code: 'en', displayName: 'English'),
      AppLanguage(code: 'es', displayName: 'Español'),
      AppLanguage(code: 'fr', displayName: 'Français'),
      AppLanguage(code: 'de', displayName: 'Deutsch'),
      AppLanguage(code: 'it', displayName: 'Italiano'),
      AppLanguage(code: 'pt', displayName: 'Português'),
      AppLanguage(code: 'ru', displayName: 'Русский'),
      AppLanguage(code: 'ja', displayName: '日本語'),
      AppLanguage(code: 'ko', displayName: '한국어'),
      AppLanguage(code: 'zh', displayName: '中文'),
      AppLanguage(
        code: 'ar',
        displayName: 'العربية',
        direction: ui.TextDirection.rtl,
      ),
      AppLanguage(
        code: 'he',
        displayName: 'עברית',
        direction: ui.TextDirection.rtl,
      ),
      AppLanguage(code: 'hi', displayName: 'हिन्दी'),
      AppLanguage(code: 'tr', displayName: 'Türkçe'),
      AppLanguage(code: 'nl', displayName: 'Nederlands'),
      AppLanguage(code: 'pl', displayName: 'Polski'),
    ];
  }

  void _showLanguagePicker(
    BuildContext context,
    List<AppLanguage> supportedLanguages,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = ref.watch(localizationProvider);
        final languageOptionsAsync = ref.watch(languageOptionsProvider);
        final isOffline = !(ref.watch(connectivityProvider).value ?? true);
        final fallbackLanguages = _fallbackPickerLanguages(supportedLanguages);

        Widget buildFallbackList() {
          final currentLanguageCode = l10n.currentLocale.languageCode
              .toLowerCase();
          return ListView.builder(
            shrinkWrap: true,
            itemCount: fallbackLanguages.length,
            itemBuilder: (context, index) {
              final lang = fallbackLanguages[index];
              final canUseNow =
                  !isOffline ||
                  lang.code == currentLanguageCode ||
                  lang.code == 'en';
              final textColor = canUseNow ? null : Colors.grey.shade400;

              return ListTile(
                leading: Icon(
                  canUseNow ? Icons.language : Icons.lock_outline,
                  color: textColor,
                ),
                title: Text(
                  lang.displayName,
                  style: TextStyle(color: textColor),
                ),
                onTap: () async {
                  if (!canUseNow) {
                    Navigator.of(dialogContext).pop();
                    if (mounted) {
                      await _showOfflineLanguageUnavailableDialog();
                    }
                    return;
                  }

                  Navigator.of(dialogContext).pop();
                  await ref
                      .read(localizationProvider.notifier)
                      .setLocale(lang.code, fallbackLanguages);
                  ref
                      .read(profileEditProvider(widget.user.id).notifier)
                      .updatePreferredLanguage(lang.code);
                },
              );
            },
          );
        }

        return AlertDialog(
          title: Text(l10n.getString('authSelectLanguage')),
          content: SizedBox(
            width: double.maxFinite,
            child: languageOptionsAsync.when(
              data: (languages) => ListView.builder(
                shrinkWrap: true,
                itemCount: languages.length,
                itemBuilder: (context, index) {
                  final lang = languages[index];
                  final langCode = lang['code'] as String;
                  final display = lang['display'] as String;
                  final isCached = (lang['cached'] as bool?) ?? true;
                  final isAvailableOffline =
                      (lang['availableOffline'] as bool?) ?? isCached;
                  final isOffline = (lang['offline'] as bool?) ?? false;
                  final canUseNow = !isOffline || isAvailableOffline;
                  final textColor = canUseNow ? null : Colors.grey.shade400;

                  return ListTile(
                    leading: Icon(
                      canUseNow ? Icons.language : Icons.lock_outline,
                      color: textColor,
                    ),
                    title: Text(display, style: TextStyle(color: textColor)),
                    onTap: () async {
                      if (!canUseNow) {
                        Navigator.of(dialogContext).pop();
                        if (mounted) {
                          await _showOfflineLanguageUnavailableDialog();
                        }
                        return;
                      }

                      final selectedLanguage = supportedLanguages.firstWhere(
                        (language) => language.code == langCode,
                        orElse: () => supportedLanguages.firstWhere(
                          (language) =>
                              language.code == l10n.currentLocale.languageCode,
                          orElse: () => supportedLanguages.first,
                        ),
                      );

                      Navigator.of(dialogContext).pop();
                      await ref
                          .read(localizationProvider.notifier)
                          .setLocale(selectedLanguage.code, supportedLanguages);
                      ref
                          .read(profileEditProvider(widget.user.id).notifier)
                          .updatePreferredLanguage(selectedLanguage.code);
                    },
                  );
                },
              ),
              loading: buildFallbackList,
              error: (_, stackTrace) => buildFallbackList(),
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmLogoutFromWizard(LocalizationState l10n) async {
    final shouldLogout =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l10n.getString('profileWizardLogoutTitle')),
            content: Text(l10n.getString('profileWizardLogoutBody')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.getString('generalCancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.getString('authLogout')),
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldLogout || !mounted) return;

    try {
      await ref
          .read(profileEditProvider(widget.user.id).notifier)
          .saveWizardDraft();
    } catch (_) {}

    try {
      ref.read(globalSyncManagerProvider).dispose();
    } catch (_) {}
    clearInitialSyncKickedAt();

    await _clearLoginState();

    try {
      SessionService.markExplicitUserSignOut();
      await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    } catch (e) {
      if (!mounted) return;
      final l10n = ref.read(localizationProvider);
      final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.getString(errorKey))));
    }
  }

  void _showMaxMainInterestsSnack({required bool isSocial}) {
    final l10n = ref.read(localizationProvider);
    final limit = isSocial
        ? _maxSocialMainInterests
        : _maxBusinessMainInterests;
    final key = isSocial
        ? 'profileWizardInterestMaxCategoriesSocial'
        : 'profileWizardInterestMaxCategoriesBusiness';
    final text = l10n.getString(key, params: {'limit': '$limit'});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _toggleSubIntentWithMaxCheck(
    AppIntent intent,
    String subKey,
    bool currentlySelected,
  ) {
    if (currentlySelected) {
      ref
          .read(profileEditProvider(widget.user.id).notifier)
          .toggleSubIntent(intent.key, subKey, awaitPersist: false);
      return;
    }
    final profile = ref.read(profileEditProvider(widget.user.id)).asData?.value;
    if (profile == null) return;
    final subs = profile.subIntents[intent.key] ?? [];
    if (subs.length >= _maxSubIntents) {
      final l10n = ref.read(localizationProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.getString(
              'profileWizardSubIntentMax',
              params: {
                'intent': l10n.getString(intent.translationKey),
                'max': '$_maxSubIntents',
              },
            ),
          ),
        ),
      );
      return;
    }
    ref
        .read(profileEditProvider(widget.user.id).notifier)
        .toggleSubIntent(intent.key, subKey, awaitPersist: false);
  }

  /// Returns the set of selected personal interest category keys.
  Set<String> _selectedPersonalCategoryKeys(UserProfile profile) {
    return profile.personalInterests.keys.toSet();
  }

  /// Returns the set of selected business interest category keys.
  Set<String> _selectedBusinessCategoryKeys(UserProfile profile) {
    return profile.businessInterests.keys.toSet();
  }

  bool _isBusinessIntentKey(String intentKey) =>
      _normalizeKey(intentKey) == 'business_networking';

  // Helper methods for bio text direction and alignment
  ui.TextDirection _getBioTextDirection() {
    final text = _bioController.text;
    if (text.isEmpty) {
      // Empty field shows the hint text: follow the UI language direction so
      // the Hebrew (or other RTL) hint aligns right, LTR hints align left.
      return Directionality.of(context) == ui.TextDirection.rtl
          ? ui.TextDirection.rtl
          : ui.TextDirection.ltr;
    }
    return RegExp(r'[a-zA-Z]').hasMatch(text)
        ? ui.TextDirection.ltr
        : ui.TextDirection.rtl;
  }

  TextAlign _getBioTextAlign() {
    final text = _bioController.text;
    if (text.isEmpty) {
      return Directionality.of(context) == ui.TextDirection.rtl
          ? TextAlign.right
          : TextAlign.left;
    }
    return text.isRtl() ? TextAlign.right : TextAlign.left;
  }

  String? _bioClientDisqualifyReason(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final l10nBio = ref.read(localizationProvider);
    if (trimmed.length > _maxBioLength) {
      return l10nBio.getString('profileEditBioTooLong');
    }
    final inappropriateMessage = ref
        .read(localizationProvider)
        .getString('profileEditBioInappropriate');

    String foldLatin(String s) {
      var out = s;
      out = out.replaceAll(RegExp(r'[áàâäãåāăą]'), 'a');
      out = out.replaceAll(RegExp(r'[çćĉċč]'), 'c');
      out = out.replaceAll(RegExp(r'[ďđ]'), 'd');
      out = out.replaceAll(RegExp(r'[éèêëēĕėęě]'), 'e');
      out = out.replaceAll(RegExp(r'[íìîïĩīĭįı]'), 'i');
      out = out.replaceAll(RegExp(r'[ñńņň]'), 'n');
      out = out.replaceAll(RegExp(r'[óòôöõōŏő]'), 'o');
      out = out.replaceAll(RegExp(r'[śŝşš]'), 's');
      out = out.replaceAll(RegExp(r'[úùûüũūŭůűų]'), 'u');
      out = out.replaceAll(RegExp(r'[ýÿŷ]'), 'y');
      out = out.replaceAll(RegExp(r'[źżž]'), 'z');
      return out;
    }

    final lowerRaw = trimmed.toLowerCase();
    final lower = lowerRaw.replaceAll(
      RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]'),
      '',
    );
    final squashed = lower.replaceAll(RegExp(r'\s+'), ' ');
    final lettersOnly = lower.replaceAll(RegExp(r'[^a-z]+'), '');
    final latinLower = foldLatin(lower);
    final latinSquashed = latinLower.replaceAll(RegExp(r'\s+'), ' ');
    final latinLettersOnly = latinLower.replaceAll(RegExp(r'[^a-z]+'), '');
    final leetLettersOnly = lower
        .replaceAll('0', 'o')
        .replaceAll('1', 'i')
        .replaceAll('2', 'z')
        .replaceAll('3', 'e')
        .replaceAll('4', 'a')
        .replaceAll('5', 's')
        .replaceAll('7', 't')
        .replaceAll('8', 'b')
        .replaceAll('9', 'g')
        .replaceAll(RegExp(r'[^a-z]+'), '');
    final leetLatinLettersOnly = foldLatin(
      lower
          .replaceAll('0', 'o')
          .replaceAll('1', 'i')
          .replaceAll('2', 'z')
          .replaceAll('3', 'e')
          .replaceAll('4', 'a')
          .replaceAll('5', 's')
          .replaceAll('7', 't')
          .replaceAll('8', 'b')
          .replaceAll('9', 'g'),
    ).replaceAll(RegExp(r'[^a-z]+'), '');

    final cyrillicOnly = lower.replaceAll(RegExp(r'[^а-яё]+'), '');
    final hebrewNormalized = lower.replaceAll(RegExp(r'[\u0591-\u05C7]'), '');
    final hebrewOnly = hebrewNormalized.replaceAll(RegExp(r'[^א-ת]+'), '');
    final arabicNormalized = lower
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u06D6-\u06ED]'), '')
        .replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069]'), '');
    final arabicOnly = arabicNormalized.replaceAll(
      RegExp(r'[^\u0600-\u06FF]+'),
      '',
    );

    final hasUrl = RegExp(
      r'(https?:\/\/|www\.)',
      caseSensitive: false,
    ).hasMatch(lower);
    if (hasUrl) return l10nBio.getString('profileEditBioContainsLink');

    final hasEmail = RegExp(
      r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}',
      caseSensitive: false,
    ).hasMatch(lower);
    if (hasEmail) return l10nBio.getString('profileEditBioContainsEmail');

    final hasPhone = RegExp(r'(\+?\d[\d\s().-]{7,}\d)').hasMatch(lower);
    if (hasPhone) return l10nBio.getString('profileEditBioContainsPhone');

    final hasHandle = RegExp(
      r'(^|\s)@([a-z0-9_]{3,})\b',
      caseSensitive: false,
    ).hasMatch(squashed);
    if (hasHandle) return l10nBio.getString('profileEditBioContainsContact');

    final contactPhrases = <RegExp>[
      RegExp(r'\b(ig|insta|instagram)\b\s*[:=@]', caseSensitive: false),
      RegExp(r'\b(snap|snapchat|sc)\b\s*[:=@]', caseSensitive: false),
      RegExp(r'\b(tiktok)\b\s*[:=@]', caseSensitive: false),
      RegExp(r'\b(telegram|whatsapp)\b\s*[:=@]', caseSensitive: false),
      RegExp(r'(אינסטגרם|אינסטה|טיקטוק|טלגרם|וואטסאפ|ווצאפ|סנאפ)\s*[:=@]'),
      RegExp(r'(انستغرام|تيك\s*توك|تيكتوك|تلغرام|واتساب|سناب)\s*[:=@]'),
    ];
    for (final re in contactPhrases) {
      if (re.hasMatch(squashed) || re.hasMatch(latinSquashed)) {
        return l10nBio.getString('profileEditBioContainsContact');
      }
    }

    final spamWordPatterns = <RegExp>[
      RegExp(r'\bonlyfans\b', caseSensitive: false),
      RegExp(r'\bcashapp\b', caseSensitive: false),
      RegExp(r'\bvenmo\b', caseSensitive: false),
      RegExp(r'\bpaypal\b', caseSensitive: false),
      RegExp(r'\btelegram\b', caseSensitive: false),
      RegExp(r'\bwhatsapp\b', caseSensitive: false),
      RegExp(r'\bsnapchat\b', caseSensitive: false),
      RegExp(r'\bkik\b', caseSensitive: false),
      RegExp(r'\bescort\b', caseSensitive: false),
    ];
    for (final re in spamWordPatterns) {
      if (re.hasMatch(latinSquashed)) {
        return l10nBio.getString('profileEditBioSpamOrPromotion');
      }
    }

    final spamPhrases = <String>[
      'dm me',
      'message me',
      'hit me up',
      'add me',
      'follow me',
      'subscribe',
      'sugar daddy',
      'sugar baby',
    ];
    for (final p in spamPhrases) {
      if (latinSquashed.contains(p)) {
        return l10nBio.getString('profileEditBioSpamOrPromotion');
      }
    }

    final solicitationPatterns = <RegExp>[
      RegExp(r'\b(pm|dm)\s+me\b', caseSensitive: false),
      RegExp(r'\bcontact\s+me\b', caseSensitive: false),
      RegExp(r'\btext\s+me\b', caseSensitive: false),
      RegExp(r'\bmessage\s+me\b', caseSensitive: false),
      RegExp(r'\bwhatsapp\s+me\b', caseSensitive: false),
      RegExp(r'\btelegram\s+me\b', caseSensitive: false),
      RegExp(r'\bבוא(?:י)?\s+לפרטי\b'),
      RegExp(r'\bבפרטי\b'),
      RegExp(r'שלח(?:י)?\s+לי\s+הודעה'),
      RegExp(r'דבר(?:י)?\s+איתי'),
      RegExp(r'תכתבו?\s+לי'),
      RegExp(r'כתבו?\s+לי'),
      RegExp(r'פנו\s+אלי'),
      RegExp(r'צור(?:י)?\s+קשר'),
      RegExp(r'(راسلني|تواصل\s+معي|على\s+الخاص|بالخاص|خاص)'),
    ];
    for (final re in solicitationPatterns) {
      if (re.hasMatch(squashed) || re.hasMatch(latinSquashed)) {
        return l10nBio.getString('profileEditBioSpamOrPromotion');
      }
    }

    final disallowedPhrasePatterns = <RegExp>[
      RegExp(r'\bkill\s+yourself\b', caseSensitive: false),
      RegExp(r'\bkys\b', caseSensitive: false),
      RegExp(r'\bi\s+want\s+to\s+die\b', caseSensitive: false),
      RegExp(r'\bsend\s+nudes\b', caseSensitive: false),
      RegExp(r'\bnudes\b', caseSensitive: false),
    ];
    for (final re in disallowedPhrasePatterns) {
      if (re.hasMatch(latinSquashed)) return inappropriateMessage;
    }

    final disallowedWordPatterns = <RegExp>[
      RegExp(r'\bfuck(?:ing|er|ed)?\b', caseSensitive: false),
      RegExp(r'\bshit(?:ty|ting)?\b', caseSensitive: false),
      RegExp(r'\bbitch(?:es|y)?\b', caseSensitive: false),
      RegExp(r'\bcunt\b', caseSensitive: false),
      RegExp(r'\bwhore(?:s)?\b', caseSensitive: false),
      RegExp(r'\bslut(?:s)?\b', caseSensitive: false),
      RegExp(r'\bnigg(?:er|a|as|ers)\b', caseSensitive: false),
      RegExp(r'\bfagg(?:ot|ots)\b', caseSensitive: false),
      RegExp(r'\bretard(?:ed|s)?\b', caseSensitive: false),
      RegExp(r'\b(pussy|dick|cock|cum|porn)\b', caseSensitive: false),
      RegExp(r'\b(blowjob|handjob|anal|rape)\b', caseSensitive: false),
      RegExp(
        r'\b(puta|puto|putain|merde|salope|connard)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(coño|carajo|mierda|joder|pendejo|cabron|cabr[oó]n)\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\b(scheisse|schei[sß]e|hurensohn|fotze)\b',
        caseSensitive: false,
      ),
      RegExp(r'\b(cazzo|stronzo|troia)\b', caseSensitive: false),
      RegExp(r'\b(caralho|porra|foda)\b', caseSensitive: false),
    ];
    for (final re in disallowedWordPatterns) {
      if (re.hasMatch(latinSquashed)) return inappropriateMessage;
    }

    final disallowedRoots = <String>[
      'fuck',
      'shit',
      'bitch',
      'cunt',
      'whore',
      'slut',
      'nigger',
      'faggot',
      'retard',
      'pussy',
      'dick',
      'cock',
      'cum',
      'porn',
      'blowjob',
      'handjob',
      'anal',
      'rape',
      'puta',
      'putain',
      'merde',
      'salope',
      'connard',
      'cono',
      'carajo',
      'mierda',
      'joder',
      'pendejo',
      'cabron',
      'scheisse',
      'hurensohn',
      'fotze',
      'cazzo',
      'stronzo',
      'troia',
      'caralho',
      'porra',
      'foda',
    ];
    for (final w in disallowedRoots) {
      if (latinLettersOnly.contains(w) ||
          leetLatinLettersOnly.contains(w) ||
          lettersOnly.contains(w) ||
          leetLettersOnly.contains(w)) {
        return inappropriateMessage;
      }
    }

    final disallowedCyrillicRoots = <String>[
      'сука',
      'блять',
      'хуй',
      'пизда',
      'ебать',
      'уебок',
      'мудак',
    ];
    for (final w in disallowedCyrillicRoots) {
      if (cyrillicOnly.contains(w)) return inappropriateMessage;
    }

    final disallowedHebrewRoots = <String>[
      'זונה',
      'בןזונה',
      'כוסאמא',
      'כוסאמאשלך',
      'כוסאמאשלכם',
      'זין',
      'מזדיין',
      'שרמוטה',
      'מניאק',
      'מניאקית',
      'מפגר',
    ];
    for (final w in disallowedHebrewRoots) {
      if (hebrewOnly.contains(w)) return inappropriateMessage;
    }

    final disallowedArabicRoots = <String>[
      'كس',
      'كسمك',
      'كسم',
      'شرموطة',
      'خول',
      'احا',
      'زانية',
      'ابنكلب',
    ];
    for (final w in disallowedArabicRoots) {
      if (arabicOnly.contains(w)) return inappropriateMessage;
    }

    return null;
  }

  Future<({bool allow, String message})> _moderateBioWithGemini(
    String bio,
  ) async {
    final l10n = ref.read(localizationProvider);
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'moderate-bio',
        body: {'bio': bio},
      );

      if (resp.status != 200) {
        return (
          allow: false,
          message: l10n.getString('profileEditBioModerationUnavailable'),
        );
      }

      dynamic data = resp.data;
      if (data is String && data.trim().isNotEmpty) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      final allow = data is Map && data['allow'] == true;
      String message;
      if (data is Map &&
          data['message'] is String &&
          (data['message'] as String).trim().isNotEmpty) {
        message = (data['message'] as String).trim();
        final uiLang = l10n.currentLocale.languageCode;
        if (uiLang != 'en') {
          try {
            final translationService = ref.read(translationServiceProvider);
            message = await translationService
                .translateText(message, 'und', uiLang)
                .timeout(const Duration(seconds: 10));
          } catch (_) {}
        }
      } else {
        message = allow ? 'OK' : l10n.getString('profileEditBioRejected');
      }
      return (allow: allow, message: message);
    } catch (_) {
      return (
        allow: false,
        message: l10n.getString('profileEditBioModerationUnavailable'),
      );
    }
  }

  Future<String?> _checkBioDuplicateAcrossProfiles() async {
    final l10n = ref.read(localizationProvider);
    final bio = _bioController.text.trim();
    final normalizedBio = _normalizeBioTextForComparison(bio);
    if (normalizedBio == null) return null;

    if (_normalizeBioTextForComparison(_originalBio) == normalizedBio) {
      return null;
    }

    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      return l10n.getString('profileEditBioModerationUnavailable');
    }

    try {
      final result = await Supabase.instance.client.rpc(
        'check_profile_bio_uniqueness',
        params: {'p_user_id': widget.user.id, 'p_bio': bio},
      );

      if (result == false) {
        return l10n.getString('profileEditBioDuplicate');
      }
    } catch (_) {
      return l10n.getString('profileEditBioModerationUnavailable');
    }

    return null;
  }

  Future<bool> _ensureBioAllowedBeforeContinuing() async {
    final messenger = ScaffoldMessenger.of(context);
    final bio = _bioController.text.trim();
    final normalizedBio = _normalizeBioTextForComparison(bio);
    if (normalizedBio == null) return true;

    if (_normalizeBioTextForComparison(_originalBio) == normalizedBio) {
      return true;
    }

    final localReason = _bioClientDisqualifyReason(bio);
    if (localReason != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(localReason)));
      _revertBioToOriginal();
      return false;
    }

    if (!(_lastBioModeratedText == bio && _lastBioModerationAllowed == true)) {
      PleaseWaitDialog.show(context);
      final res = await _moderateBioWithGemini(bio);
      if (!mounted) {
        PleaseWaitDialog.hide(context);
        return false;
      }
      // Use the dialog's own hide (root-navigator safe) instead of a raw
      // rootNavigator.pop(): a system permission sheet granted mid-wizard
      // can sit on top of the stack, and a raw pop would dismiss the wrong
      // route and leave the wizard behind a stale modal barrier.
      PleaseWaitDialog.hide(context);

      _lastBioModeratedText = bio;
      _lastBioModerationAllowed = res.allow;

      if (!res.allow) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(res.message)));
        _revertBioToOriginal();
        return false;
      }
    }

    final duplicateMessage = await _checkBioDuplicateAcrossProfiles();
    if (!mounted) return false;
    if (duplicateMessage != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(duplicateMessage)));
      _revertBioToOriginal();
      return false;
    }

    return true;
  }

  void _revertBioToOriginal() {
    final original = _originalBio ?? '';
    _bioController.text = original;
    _lastBioModeratedText = null;
    _lastBioModerationAllowed = null;
    ref.read(profileEditProvider(widget.user.id).notifier).updateBio(original);
  }

  void _convertFeetInchesToCm() {
    final feetText = _heightFeetController.text.trim();
    final inchesText = _heightInchesController.text.trim();
    if (feetText.isEmpty || inchesText.isEmpty) {
      // Optional field: clearing either part clears the stored height
      ref.read(profileEditProvider(widget.user.id).notifier).updateHeight(null);
      if (mounted) setState(() {});
      return;
    }
    final feet = int.tryParse(feetText);
    final inches = int.tryParse(inchesText);
    if (feet != null && inches != null) {
      final totalCm = (feet * 30.48 + inches * 2.54).round();
      if (totalCm >= 100 && totalCm <= 250) {
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .updateHeight(totalCm);
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(loadConfig());
    _searchInterestController.addListener(_onPersonalInterestSearchChanged);
    _searchBusinessInterestController.addListener(
      _onBusinessInterestSearchChanged,
    );
    Future.microtask(
      () => ref
          .read(profileEditProvider(widget.user.id).notifier)
          .loadInitialProfile(applyWizardDraft: true),
    );

    _pageController.addListener(() {
      final newPage = _pageController.page?.round() ?? 0;
      if (_programmaticNavTarget != null) {
        if (DateTime.now().difference(_programmaticNavAt) <
            _programmaticNavTtl) {
          if (newPage != _programmaticNavTarget) {
            // Still mid-animation toward the target (frames round to the
            // page being left): keep the optimistic index, announce nothing.
            return;
          }
          // Arrived at the target; it was announced when the change started.
          _programmaticNavTarget = null;
        } else {
          // The navigation never settled (e.g. interrupted); stop filtering.
          _programmaticNavTarget = null;
        }
      }
      if (newPage != _currentPageIndex) {
        setState(() {
          _currentPageIndex = newPage;
        });
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .setWizardPageIndex(newPage);
        final currentP = ref.read(profileEditProvider(widget.user.id)).value;
        if (currentP != null && _draftEnabled) {
          _queueDraftSave(currentP);
        }
        // Announce the step the user just arrived at (covers Next, Back and
        // programmatic page changes; the initial entry is announced in the
        // profile-load path so a restored draft page is described too).
        _speakStepGuidance(newPage);
      }
    });

    ref.listenManual(profileEditProvider(widget.user.id), (prev, next) {
      if (next.isLoading) {
        // loadInitialProfile() is in flight (it re-emits AsyncLoading at the
        // start of every load). Any data seen before this point may be a
        // provisional seed of the raw cached profile WITHOUT the saved
        // wizard draft merged — e.g. when the profile provider was already
        // instantiated by startup code (visibility sync) before this screen
        // ran. Never initialize from that.
        _wizardProfileLoading = true;
        return;
      }
      final currentData = next.asData?.value;
      if (currentData != null) _lastGoodProfile = currentData;
      next.whenData((profile) {
        if (profile == null || !mounted) return;
        if (!_isInitialized) {
          if (!_wizardProfileLoading) {
            // Provisional seed data: the loadInitialProfile() call scheduled
            // in initState will re-emit AsyncLoading followed by the
            // draft-merged profile. Wait for it so the fields the user
            // already entered and the saved page index are restored.
            return;
          }
          _initializeFromProfile(profile);
        } else if (_draftEnabled) {
          _queueDraftSave(profile);
        }
      });
      if (!_isInitialized &&
          _wizardProfileLoading &&
          next.hasError &&
          mounted) {
        // The load failed (e.g. transient network issue on first run).
        // Retry a couple of times, then fall back to the last known data
        // rather than leaving the wizard stuck on a spinner.
        if (_profileLoadRetries < 2) {
          _profileLoadRetries++;
          unawaited(
            ref
                .read(profileEditProvider(widget.user.id).notifier)
                .loadInitialProfile(applyWizardDraft: true),
          );
          return;
        }
        final fallback = _lastGoodProfile ?? prev?.asData?.value;
        if (fallback != null) {
          _initializeFromProfile(fallback);
        }
      }
    }, fireImmediately: true);

    // Verify user still exists in database during profile creation
    Future.delayed(const Duration(seconds: 1), () {
      if (!_userDeletedCheckPerformed && mounted) {
        _userDeletedCheckPerformed = true;
        _verifyUserStillExists();
      }
    });
  }

  void _initializeFromProfile(UserProfile profile) {
    _isInitialized = true;
    final normalizedName = profile.name.trim();
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    final hasName =
        normalizedName.isNotEmpty &&
        normalizedName != 'Unnamed' &&
        !emailRegex.hasMatch(normalizedName);
    final hasDob = profile.dateOfBirth != null;
    final hasGender = (profile.gender ?? '').trim().isNotEmpty;
    final hasIntents = profile.activeModes.isNotEmpty;
    final hasSubIntents = profile.subIntents.values.any((v) => v.isNotEmpty);
    final hasInterests =
        profile.personalInterests.values.any((v) => v.isNotEmpty) ||
        profile.businessInterests.values.any((v) => v.isNotEmpty);
    final langs = profile.languagesKnown['languages'] ?? const <String>[];
    final hasLanguages = langs.isNotEmpty;
    final hasBio = (profile.bio ?? '').trim().isNotEmpty;
    final hasPhotos = profile.photos.isNotEmpty;

    final isEffectivelyEmptyAtStart =
        !hasName &&
        !hasDob &&
        !hasGender &&
        !hasIntents &&
        !hasSubIntents &&
        !hasInterests &&
        !hasLanguages &&
        !hasBio &&
        !hasPhotos;

    final isFirstWizardRun =
        !profile.isProfileComplete && isEffectivelyEmptyAtStart;
    final rawName = hasName ? normalizedName : '';

    if (isFirstWizardRun) {
      final notifier = ref.read(profileEditProvider(widget.user.id).notifier);
      _nameController.text = '';
      _firstNameController.text = '';
      _lastNameController.text = '';
      _dobController.text = '';
      _bioController.text = '';
      _heightController.text = '';
      _heightFeetController.text = '';
      _heightInchesController.text = '';
      _heightUnitMode = 0;
      _occupationController.text = '';
      _educationController.text = '';
      _instagramController.text = '';
      _linkedinController.text = '';
      _facebookController.text = '';
      if ((profile.bio ?? '').trim().isNotEmpty) {
        notifier.updateBio('');
      }
      if ((profile.gender ?? '').trim().isNotEmpty) {
        notifier.updateGender(null);
      }
    } else {
      _nameController.text = rawName;
      if (rawName.isEmpty) {
        _firstNameController.text = '';
        _lastNameController.text = '';
        // If the profile name was seeded from the user's email address by
        // the auth trigger, also clear it in the provider so that
        // validation and diff logic don't treat it as a real name.
        if (normalizedName.isNotEmpty && normalizedName != 'Unnamed') {
          ref.read(profileEditProvider(widget.user.id).notifier).updateName('');
        }
      } else {
        final parts = rawName.split(RegExp(r'\s+'));
        if (parts.isNotEmpty) _firstNameController.text = parts.first;
        if (parts.length > 1) {
          _lastNameController.text = parts.sublist(1).join(' ');
        }
      }
      if (profile.dateOfBirth != null) {
        _dobController.text = DateFormat(
          'yyyy-MM-dd',
        ).format(profile.dateOfBirth!);
      } else {
        _dobController.text = '';
      }
      _bioController.text = profile.bio?.trim() ?? '';
      _heightUnitModeInitialized = false;
      // Prefill with base URL, extract username if existing URL matches pattern
      final instagramUsername = _extractInstagramUsername(profile.instagramUrl);
      _instagramController.text = instagramUsername ?? '';
      final linkedinUsername = _extractLinkedinUsername(profile.linkedinUrl);
      _linkedinController.text = linkedinUsername ?? '';
      final facebookUsername = _extractFacebookUsername(profile.facebookUrl);
      _facebookController.text = facebookUsername ?? '';

      if (profile.height != null) {
        _heightController.text = profile.height!.toString();
        final totalInches = (profile.height! / 2.54).round();
        final feet = totalInches ~/ 12;
        final inches = totalInches % 12;
        _heightFeetController.text = feet.toString();
        _heightInchesController.text = inches.toString();
      } else {
        _heightController.text = '';
        _heightFeetController.text = '';
        _heightInchesController.text = '';
      }

      _occupationController.text = profile.occupation ?? '';
      _educationController.text = profile.education ?? '';
    }

    // Restore draft page index if set. Exception: after the profile has
    // been completed once, opening the wizard via "Edit" always starts at
    // the beginning so the user can review/update from the first screen.
    final editAfterComplete = _ProfileWizardScreenState.isEditAfterCompleteMode(
      isEditing: widget.isEditing,
      isProfileComplete: profile.isProfileComplete,
    );
    var restoredIndex = editAfterComplete
        ? 0
        : ref
              .read(profileEditProvider(widget.user.id).notifier)
              .wizardCurrentPageIndex;
    // Completeness routing: when the wizard was opened because the profile
    // has a critical gap (startup/resume check), jump straight to that
    // gap's page instead of the draft's last page.
    if (!editAfterComplete && widget.initialSection != null) {
      final gapIndex = _profileWizardPageMap(
        profile,
      ).indexFor(widget.initialSection!);
      if (gapIndex >= 0) {
        restoredIndex = gapIndex;
        try {
          ref
              .read(profileEditProvider(widget.user.id).notifier)
              .setWizardPageIndex(gapIndex);
        } catch (_) {}
      }
    }
    if (editAfterComplete) {
      _currentPageIndex = 0;
      try {
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .setWizardPageIndex(0);
      } catch (_) {}
    } else if (restoredIndex > 0) {
      _currentPageIndex = restoredIndex;
      _ensurePageRestored(restoredIndex);
    }

    // First announcement on entering the wizard: a short welcome for new
    // users, otherwise a description of the page they landed on (which may
    // be a restored draft page).
    if (!_didSpeakInitialStep) {
      _didSpeakInitialStep = true;
      if (!editAfterComplete && restoredIndex > 0) {
        _speakStepGuidance(restoredIndex);
      } else if (!widget.isEditing) {
        unawaited(
          VoiceGuidanceService.instance.speakKey('voiceGuidanceWizardWelcome'),
        );
      } else {
        _speakStepGuidance(0);
      }
    }

    // Keep original snapshot for diffing at final step
    _originalSnapshot = _snapshotFromProfile(profile);
    _originalBio = profile.bio?.trim();
    _lastDraftJson = jsonEncode(profile.toMap());
    _draftEnabled = true;
  }

  void _queueDraftSave(UserProfile profile) {
    final nextJson = jsonEncode(profile.toMap());
    if (nextJson == _lastDraftJson) return;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .saveWizardDraft()
            .then((_) {
              _lastDraftJson = nextJson;
            }),
      );
    });
  }

  void _schedulePrimaryPhotoValidation(String photoPath) {
    if (photoPath.isEmpty) return;
    if (_lastValidatedPrimaryPhotoPath == photoPath) return;
    _pendingPrimaryPhotoPath = photoPath;
    _primaryPhotoValidationDebounce?.cancel();
    _primaryPhotoValidationDebounce = Timer(
      const Duration(milliseconds: 450),
      () {
        final pending = _pendingPrimaryPhotoPath;
        if (pending == null || pending.isEmpty) return;
        unawaited(_validatePrimaryPhoto(pending, showLoading: false));
      },
    );
  }

  Future<void> _validatePrimaryPhoto(
    String photoPath, {
    required bool showLoading,
  }) async {
    if (!mounted) return;
    if (photoPath.isEmpty) return;
    if (_lastValidatedPrimaryPhotoPath == photoPath) return;

    final existing = _primaryValidationFuture;
    if (existing != null && _primaryValidationPhotoPath == photoPath) {
      try {
        await existing;
      } catch (_) {}
      return;
    }

    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);
    final future = () async {
      if (showLoading) {
        PleaseWaitDialog.show(context);
      }
      try {
        await notifier.ensurePrimaryPhotoAllowedForWizard(photoPath);
        _lastValidatedPrimaryPhotoPath = photoPath;
      } catch (e) {
        if (!mounted) return;
        if (!showLoading) {
          final l10n = ref.read(localizationProvider);
          final msg = e.toString();
          const geminiMarker = 'Exception: GEMINI_MSG:';
          final geminiIdx = msg.indexOf(geminiMarker);
          if (!context.mounted) return;
          String displayMsg;
          if (geminiIdx != -1) {
            displayMsg = msg.substring(geminiIdx + geminiMarker.length);
          } else {
            final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
            if (errorKey == 'authUnexpectedError') {
              displayMsg = msg.startsWith('Exception: ')
                  ? msg.substring('Exception: '.length)
                  : msg;
            } else {
              displayMsg = l10n.getString(errorKey);
            }
          }
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              content: Text(displayMsg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.getString('generalOk')),
                ),
              ],
            ),
          );
          unawaited(VoiceGuidanceService.instance.speakText(displayMsg));
          return;
        }
        rethrow;
      } finally {
        if (showLoading && mounted) {
          PleaseWaitDialog.hide(context);
        }
      }
    }();

    _primaryValidationFuture = future;
    _primaryValidationPhotoPath = photoPath;

    try {
      await future;
    } finally {
      if (identical(_primaryValidationFuture, future)) {
        _primaryValidationFuture = null;
        _primaryValidationPhotoPath = null;
      }
    }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _primaryPhotoValidationDebounce?.cancel();
    // Leaving the wizard silences any guidance mid-sentence.
    unawaited(VoiceGuidanceService.instance.stop());

    try {
      final p = ref.read(profileEditProvider(widget.user.id)).value;
      if (p != null) {
        unawaited(
          ref
              .read(profileEditProvider(widget.user.id).notifier)
              .saveWizardDraft(),
        );
      }
    } catch (_) {}

    _pageController.dispose();
    _nameController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _dobController.dispose();
    _bioController.dispose();
    _searchIntentController.dispose();
    _searchInterestController.removeListener(_onPersonalInterestSearchChanged);
    _searchInterestController.dispose();
    _searchBusinessInterestController.removeListener(
      _onBusinessInterestSearchChanged,
    );
    _searchBusinessInterestController.dispose();
    _heightController.dispose();
    _heightFeetController.dispose();
    _heightInchesController.dispose();
    _occupationController.dispose();
    _educationController.dispose();
    _linkedinController.dispose();
    _instagramController.dispose();
    _facebookController.dispose();

    if (_currentVisitRequestIds.isNotEmpty) {
      for (final id in _currentVisitRequestIds) {
        unawaited(_markProfileEditRequestSeen(id));
      }
    }
    if (_currentVisitPillCombos.isNotEmpty) {
      _sessionDismissedPillKeys
          .putIfAbsent(widget.user.id, () => {})
          .addAll(_currentVisitPillCombos);
    }
    super.dispose();
  }

  int _computeAge(DateTime birthDate) {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  bool _canEditBasicField(UserProfile profile, String fieldKey) {
    if (!profile.isProfileComplete) {
      return true;
    }
    if (!profile.editableProfileFields.contains(fieldKey)) {
      return false;
    }
    final reviews = ref
        .read(basicFieldAdminReviewsProvider(widget.user.id))
        .asData
        ?.value;
    final review = reviews?[fieldKey];
    if (review != null && review.status == 'rejected') {
      return false;
    }
    return true;
  }

  Future<void> _selectDate(BuildContext context) async {
    final l10n = ref.read(localizationProvider);
    final DateTime now = DateTime.now();
    final DateTime eighteenYearsAgo = now.subtract(
      const Duration(days: 18 * 365 + 4),
    );
    final currentProfile = ref.read(profileEditProvider(widget.user.id)).value;
    final DateTime initial =
        (currentProfile != null && currentProfile.isProfileComplete)
        ? (currentProfile.dateOfBirth ?? eighteenYearsAgo)
        : eighteenYearsAgo;
    final DateTime? picked = await BirthdateWheelPickerDialog.show(
      context,
      l10n: l10n,
      initialDate: initial,
      minYear: now.year - 100,
      formatDate: (date) => _formatDateWithL10n(date, l10n),
    );
    if (picked != null) {
      _dobController.text = DateFormat('yyyy-MM-dd').format(picked);
      try {
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .updateDob(picked);
      } catch (_) {
        // Ignore DOB update errors
      }
      setState(() {});
    }
  }

  Future<void> _openRequestDialogForField(
    BuildContext context,
    UserProfile profile,
    String fieldKey,
    String fieldLabel,
  ) async {
    final existing = ref
        .read(basicFieldAdminReviewsProvider(profile.id))
        .value?[fieldKey];
    if (existing?.status == 'pending') {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ref
                  .read(localizationProvider)
                  .getString('profileEditRequestAlreadyPendingBody'),
            ),
          ),
        );
      }
      return;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => RequestChangeDialog(
        userId: profile.id,
        fieldKey: fieldKey,
        fieldLabel: fieldLabel,
      ),
    );

    if (result == true && mounted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ref
                .read(localizationProvider)
                .getString('profileEditRequestSubmitted'),
          ),
        ),
      );
    }
  }

  ProfileWizardPageMap _profileWizardPageMap(UserProfile? profile) {
    if (profile == null) {
      return ProfileWizardPageMap(
        selectedIntentCount: 0,
        hasSocial: false,
        hasBusiness: false,
        hasRomantic: false,
        hasFriendship: false,
        hasReview: false,
      );
    }

    final selectedIntents = _getSelectedIntents(
      ref,
      profile,
      ref.read(mainIntentsProvider),
    );
    final normalizedKeys = profile.activeModes.map(_normalizeKey).toSet();
    return ProfileWizardPageMap(
      selectedIntentCount: selectedIntents.length,
      hasSocial: profile.activeModes.any((mode) => !_isBusinessIntentKey(mode)),
      hasBusiness: profile.activeModes.any(_isBusinessIntentKey),
      hasRomantic: normalizedKeys.contains('romantic'),
      hasFriendship: normalizedKeys.contains('friendship'),
      hasReview: false,
    );
  }

  int _firstInterestPageIndex(UserProfile? profileSnapshot) {
    final pageMap = _profileWizardPageMap(profileSnapshot);
    if (pageMap.personalInterestsIndex >= 0) {
      return pageMap.personalInterestsIndex;
    }
    if (pageMap.businessInterestsIndex >= 0) {
      return pageMap.businessInterestsIndex;
    }
    return pageMap.mainIntentsIndex;
  }

  int _firstErrorPageIndex({
    required UserProfile? profileSnapshot,
    required String? errorMessage,
    ProfileWizardSection? section,
  }) {
    final pageMap = _profileWizardPageMap(profileSnapshot);
    if (section != null) {
      final sectionIndex = pageMap.indexFor(section);
      return sectionIndex >= 0 ? sectionIndex : _currentPageIndex;
    }
    final msg = (errorMessage ?? '').toLowerCase();

    bool containsAny(String text, List<String> needles) =>
        needles.any(text.contains);

    if (containsAny(msg, [
      'photo',
      'face',
      'body',
      'gemini',
      'ai',
      'verify your photo',
      'primary photo',
      'validate-primary-photo',
    ])) {
      return pageMap.photosIndex;
    }
    if (containsAny(msg, ['dob', 'date of birth', 'birth', 'name'])) {
      return pageMap.basicsIndex;
    }
    if (containsAny(msg, ['sub-intent', 'sub intent', 'subintent'])) {
      return pageMap.subIntentStart;
    }
    if (containsAny(msg, ['intent'])) {
      return pageMap.mainIntentsIndex;
    }
    if (containsAny(msg, ['height'])) {
      return pageMap.detailsIndex;
    }
    if (containsAny(msg, ['language', 'skill', 'bio'])) {
      return pageMap.detailsIndex;
    }
    if (containsAny(msg, ['interest'])) {
      return _firstInterestPageIndex(profileSnapshot);
    }

    final p = profileSnapshot;
    if (p == null) return _currentPageIndex;

    if (p.name.trim().isEmpty) return pageMap.basicsIndex;
    if (p.dateOfBirth == null) return pageMap.basicsIndex;

    if (p.photos.isEmpty) return pageMap.photosIndex;
    final langs = p.languagesKnown['languages'] ?? const <String>[];
    if (langs.isEmpty) return pageMap.detailsIndex;
    for (final lang in langs) {
      final skills = p.languagesKnown[lang] ?? const <String>[];
      if (skills.isEmpty) return pageMap.detailsIndex;
    }

    if (p.activeModes.isEmpty) return pageMap.mainIntentsIndex;

    if (p.subIntents.values.every((list) => list.isEmpty)) {
      return pageMap.subIntentStart;
    }

    return _currentPageIndex;
  }

  _ProfileWizardValidationIssue? _validateProfileForSubmit() {
    final p = ref.read(profileEditProvider(widget.user.id)).value;
    if (p == null) return null;
    final l10n = ref.read(localizationProvider);
    final allIntentsList = ref.read(mainIntentsProvider);
    final selectedIntents = _getSelectedIntents(ref, p, allIntentsList);

    if (p.height != null && (p.height! < 100 || p.height! > 250)) {
      return _ProfileWizardValidationIssue(
        l10n.getString('profileEditHeightInvalid'),
        ProfileWizardSection.details,
      );
    }

    final hasBusinessIntent = p.activeModes.any((m) => _isBusinessIntentKey(m));
    if (hasBusinessIntent) {
      if ((p.occupation ?? '').trim().isEmpty) {
        return _ProfileWizardValidationIssue(
          l10n.getString('profileEditOccupationRequired'),
          ProfileWizardSection.details,
        );
      }
      if ((p.education ?? '').trim().isEmpty) {
        return _ProfileWizardValidationIssue(
          l10n.getString('profileEditEducationRequired'),
          ProfileWizardSection.details,
        );
      }
    }

    for (final intent in selectedIntents) {
      final subs = p.subIntents[intent.key] ?? [];
      final intentName = l10n.getString(intent.translationKey);
      if (subs.length < _minSubIntents) {
        return _ProfileWizardValidationIssue(
          l10n.getString(
            'profileWizardSubIntentMin',
            params: {'intent': intentName, 'min': '$_minSubIntents'},
          ),
          ProfileWizardSection.subIntents,
        );
      }
      if (subs.length > _maxSubIntents) {
        return _ProfileWizardValidationIssue(
          l10n.getString(
            'profileWizardSubIntentMax',
            params: {'intent': intentName, 'max': '$_maxSubIntents'},
          ),
          ProfileWizardSection.subIntents,
        );
      }
    }

    final hasSocialIntentForValidation = p.activeModes.any(
      (m) => !_isBusinessIntentKey(m),
    );
    final hasBusinessIntentForValidation = p.activeModes.any(
      (m) => _isBusinessIntentKey(m),
    );
    final hasPersonalInterest = p.personalInterests.entries.any(
      (e) => e.value.isNotEmpty,
    );
    final hasBusinessInterest = p.businessInterests.entries.any(
      (e) => e.value.isNotEmpty,
    );
    if (hasSocialIntentForValidation && !hasPersonalInterest) {
      return _ProfileWizardValidationIssue(
        l10n.getString('profileSelectAtLeastOneInterest'),
        ProfileWizardSection.personalInterests,
      );
    }
    if (hasBusinessIntentForValidation && !hasBusinessInterest) {
      return _ProfileWizardValidationIssue(
        l10n.getString('profileSelectAtLeastOneInterest'),
        ProfileWizardSection.businessInterests,
      );
    }
    if (!hasSocialIntentForValidation &&
        !hasBusinessIntentForValidation &&
        !hasPersonalInterest &&
        !hasBusinessInterest) {
      return _ProfileWizardValidationIssue(
        l10n.getString('profileSelectAtLeastOneInterest'),
        ProfileWizardSection.mainIntents,
      );
    }

    for (final entry in [
      ...p.personalInterests.entries,
      ...p.businessInterests.entries,
    ]) {
      final valueList = entry.value;
      if (valueList.length > _maxSubInterestsPer + 1) {
        return _ProfileWizardValidationIssue(
          l10n.getString(
            'profileWizardCategorySubInterestExceeded',
            params: {'category': entry.key, 'max': '$_maxSubInterestsPer'},
          ),
          p.personalInterests.containsKey(entry.key)
              ? ProfileWizardSection.personalInterests
              : ProfileWizardSection.businessInterests,
        );
      }
    }

    return null;
  }

  Future<void> _goToWizardPage(int index) async {
    if (!mounted) return;
    if (!_pageController.hasClients) {
      // PageView not attached yet (e.g. right after a permission resume
      // rebuild): remember the target so the post-frame restore applies it.
      final safeFallback = index < 0 ? 0 : index;
      _programmaticNavTarget = safeFallback;
      _programmaticNavAt = DateTime.now();
      _speakStepGuidance(safeFallback);
      if (mounted && safeFallback != _currentPageIndex) {
        setState(() => _currentPageIndex = safeFallback);
      }
      _ensurePageRestored(index < 0 ? 0 : index);
      return;
    }
    final safeIndex = index < 0 ? 0 : index;
    _programmaticNavTarget = safeIndex;
    _programmaticNavAt = DateTime.now();
    // Announce the destination up front — see _advancePage: with the
    // optimistic index below in place the page listener can only announce
    // the page being left.
    _speakStepGuidance(safeIndex);
    // Keep the bottom bar in sync even if the page listener fires late.
    if (mounted && safeIndex != _currentPageIndex) {
      setState(() => _currentPageIndex = safeIndex);
    }
    try {
      await _pageController.animateToPage(
        safeIndex,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
      );
    } catch (_) {
      try {
        _pageController.jumpToPage(safeIndex);
      } catch (_) {}
    }
  }

  void _retryProfileLoad() {
    if (!mounted) return;
    setState(() {
      _profileLoadRetries = 0;
      _wizardProfileLoading = true;
    });
    ref.invalidate(allIntentsProvider);
    ref.invalidate(allInterestsProvider);
    unawaited(
      ref
          .read(profileEditProvider(widget.user.id).notifier)
          .loadInitialProfile(applyWizardDraft: true),
    );
  }

  void _retryReferenceData({required bool intents, required bool interests}) {
    if (!mounted) return;
    if (intents) ref.invalidate(allIntentsProvider);
    if (interests) ref.invalidate(allInterestsProvider);
  }

  // ----------------------------
  // Robust _submit: guard against popping the only route (safe navigation)
  // ----------------------------
  Future<void> _submit() async {
    final l10n = ref.read(localizationProvider);
    if (!mounted) return;

    final bioAllowed = await _ensureBioAllowedBeforeContinuing();
    if (!bioAllowed) return;

    // Check if anything actually changed before saving
    final currentProfile = ref.read(profileEditProvider(widget.user.id)).value;
    if (currentProfile != null) {
      final diffs = _computeDiffs(_originalSnapshot, currentProfile);
      bool hasChanges = false;
      if (diffs['name'] != null) {
        final toName = ((diffs['name'] as Map)['to'] as String?)
            ?.trim()
            .toLowerCase();
        if (toName != null &&
            toName.isNotEmpty &&
            toName != 'unnamed' &&
            toName != 'unknown user') {
          hasChanges = true;
        }
      }
      if (diffs['dateOfBirth'] != null) {
        final toDob = (diffs['dateOfBirth'] as Map)['to'] as String?;
        if (toDob != null && toDob.isNotEmpty) hasChanges = true;
      }
      if (diffs['gender'] != null) {
        final toGender = ((diffs['gender'] as Map)['to'] as String?)?.trim();
        if (toGender != null && toGender.isNotEmpty) hasChanges = true;
      }
      if ((diffs['intentsAdded'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['intentsRemoved'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['languagesChanged'] as Map).isNotEmpty) hasChanges = true;
      if (diffs['bioChanged'] != null) {
        final toBio = (diffs['bioChanged'] as Map)['to']?.toString().trim();
        if (toBio != null && toBio.isNotEmpty) hasChanges = true;
      }
      if (diffs['photosChanged'] != null) {
        final m = diffs['photosChanged'] as Map;
        final fromPhotos = (m['from'] as List?)?.cast<String>() ?? [];
        final toPhotos = (m['to'] as List?)?.cast<String>() ?? [];
        if (toPhotos.where((p) => !fromPhotos.contains(p)).isNotEmpty ||
            fromPhotos.where((p) => !toPhotos.contains(p)).isNotEmpty) {
          hasChanges = true;
        }
      }
      if (diffs['instagramChanged'] != null) {
        final toVal = ((diffs['instagramChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['linkedinChanged'] != null) {
        final toVal = ((diffs['linkedinChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['facebookChanged'] != null) {
        final toVal = ((diffs['facebookChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['heightChanged'] != null) {
        final toVal = (diffs['heightChanged'] as Map)['to'] as int?;
        if (toVal != null) hasChanges = true;
      }
      if (diffs['heightUnitChanged'] != null) {
        final toVal = (diffs['heightUnitChanged'] as Map)['to']?.toString();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['occupationChanged'] != null) {
        final toVal = ((diffs['occupationChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['educationChanged'] != null) {
        final toVal = ((diffs['educationChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['lifestyleChanged'] != null) {
        final toVal = (diffs['lifestyleChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['familyChanged'] != null) {
        final toVal = (diffs['familyChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['religionChanged'] != null) {
        final toVal = (diffs['religionChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['genderPreferencesChanged'] != null) {
        final toVal = (diffs['genderPreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['agePreferencesChanged'] != null) {
        final toVal = (diffs['agePreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['lifestyleFiltersChanged'] != null) {
        final toVal = (diffs['lifestyleFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['familyFiltersChanged'] != null) {
        final toVal = (diffs['familyFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['religionFiltersChanged'] != null) {
        final toVal = (diffs['religionFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['heightPreferencesChanged'] != null) {
        final toVal = (diffs['heightPreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (!hasChanges) {
        // Nothing changed according to the diff. For edit-after-complete
        // this is a clean exit. For the initial wizard (new signup) a
        // silent return looks exactly like "Save does nothing" — e.g.
        // after a permission resume where the snapshot/draft already
        // match. Fall through and attempt a real save so the profile can
        // still complete; the validation/save path below gives feedback.
        if (widget.isEditing) {
          final n = ref.read(profileEditProvider(widget.user.id).notifier);
          await n.clearWizardDraft();
          if (mounted) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          }
          return;
        }
        // New-user wizard: continue to validation + save instead of
        // returning silently.
      }
    }

    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);

    final profileSnapshot = ref.read(profileEditProvider(widget.user.id)).value;
    if (profileSnapshot != null) {
      final canEditName = _canEditBasicField(profileSnapshot, 'name');
      final newName =
          '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'
              .trim();
      if (canEditName &&
          newName.isNotEmpty &&
          newName != profileSnapshot.name) {
        try {
          notifier.updateName(newName);
        } catch (_) {
          // Ignore profile update errors
        }
      }
    }

    // Validate sub-intents and interests before submitting
    if (!mounted) return;
    final validationIssue = _validateProfileForSubmit();
    if (validationIssue != null) {
      final targetPageIndex = _firstErrorPageIndex(
        profileSnapshot: profileSnapshot,
        errorMessage: validationIssue.message,
        section: validationIssue.section,
      );
      if (targetPageIndex != _currentPageIndex) {
        await _goToWizardPage(targetPageIndex);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(validationIssue.message),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Hard gate: no save/complete without a primary photo that passed the
    // prescreen and was approved by the AI validation. The photos step
    // enforces this on the way forward, but Save can also be reached via a
    // restored draft page or while editing — re-validate here so every
    // save path is covered. (saveProfile in the provider re-checks too.)
    final liveProfile = ref.read(profileEditProvider(widget.user.id)).value;
    if (liveProfile == null || liveProfile.photos.isEmpty) {
      final requiredMsg = l10n.getString('profileWizardUploadPhotoRequired');
      final targetPageIndex = _firstErrorPageIndex(
        profileSnapshot: liveProfile,
        errorMessage: requiredMsg,
      );
      if (targetPageIndex != _currentPageIndex) {
        await _goToWizardPage(targetPageIndex);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(requiredMsg),
          backgroundColor: Colors.red,
        ),
      );
      unawaited(VoiceGuidanceService.instance.speakText(requiredMsg));
      return;
    }
    try {
      await _validatePrimaryPhoto(
        liveProfile.photos.first,
        showLoading: true,
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      const geminiMarker = 'Exception: GEMINI_MSG:';
      final geminiIdx = msg.indexOf(geminiMarker);
      String displayMsg;
      if (geminiIdx != -1) {
        displayMsg = msg.substring(geminiIdx + geminiMarker.length);
      } else {
        final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
        if (errorKey == 'authUnexpectedError') {
          displayMsg = msg.startsWith('Exception: ')
              ? msg.substring('Exception: '.length)
              : msg;
        } else {
          displayMsg = l10n.getString(errorKey);
        }
      }
      final targetPageIndex = _firstErrorPageIndex(
        profileSnapshot: liveProfile,
        errorMessage: displayMsg,
      );
      if (targetPageIndex != _currentPageIndex) {
        await _goToWizardPage(targetPageIndex);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(displayMsg),
          backgroundColor: Colors.red,
        ),
      );
      unawaited(VoiceGuidanceService.instance.speakText(displayMsg));
      return;
    }

    try {
      setState(() => _isLoading = true);
      // ignore: use_build_context_synchronously
      PleaseWaitDialog.show(
        context,
        message: l10n.getString('profileWizardCompletingProfile'),
      );
      final success = await notifier.saveProfile(showLoading: false);
      if (!mounted) return;
      if (success) {
        await notifier.clearWizardDraft();
        if (!mounted) return;
        ref.read(navigationIndexProvider.notifier).setIndex(0);
        if (widget.isEditing) {
          PleaseWaitDialog.hide(context);
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
        // Initial wizard: ProfileCheckScreen switches to main navigation
        // and hides the please-wait dialog after the transition.
      } else {
        final state = ref.read(profileEditProvider(widget.user.id));
        String message = l10n.getString('profileEditSaveFailed');
        if (state is AsyncError) {
          final raw = state.error?.toString() ?? '';
          const geminiMarker = 'Exception: GEMINI_MSG:';
          final geminiIdx = raw.indexOf(geminiMarker);
          if (geminiIdx != -1) {
            message = raw.substring(geminiIdx + geminiMarker.length);
          } else if (raw.startsWith('Exception: ')) {
            message = raw.substring('Exception: '.length);
          } else {
            message = raw.isNotEmpty ? raw : message;
          }
        }
        final targetPageIndex = _firstErrorPageIndex(
          profileSnapshot:
              profileSnapshot ??
              ref.read(profileEditProvider(widget.user.id)).value,
          errorMessage: message,
        );
        if (targetPageIndex != _currentPageIndex) {
          await _goToWizardPage(targetPageIndex);
        }
        if (!mounted) return;
        PleaseWaitDialog.hide(context);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _handleNextPage(List<Widget> pages) async {
    final l10n = ref.read(localizationProvider);
    final currentPage = _currentPageIndex;
    if (currentPage >= pages.length) {
      return;
    }
    final notifier = ref.read(profileEditProvider(widget.user.id).notifier);
    final p = ref.read(profileEditProvider(widget.user.id)).value;
    final messenger = ScaffoldMessenger.of(context);

    final pageWidget = pages[currentPage];
    if (pageWidget is UnifiedMatchPreferencesWizardPage) {
      if (p != null) {
        for (final intent in pageWidget.selectedIntents) {
          final preferredGenders = p.genderPreferences[intent.key] ?? [];
          if (preferredGenders.isEmpty) {
            final intentName = l10n.getString(intent.translationKey);
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l10n
                      .getString('profileWizardGenderPreferenceRequired')
                      .replaceAll('{intent}', intentName),
                ),
              ),
            );
            return;
          }
        }
      }
    }

    // Compute dynamic page indices based on selected intents
    final allIntents = ref.read(mainIntentsProvider);
    final selectedIntents = _getSelectedIntents(ref, p, allIntents);
    final intentCount = selectedIntents.length;

    // [0] Main Intents
    // [1..intentCount] Sub-Intents
    // [intentCount+1] About You (Basics)
    // [intentCount+2] Details (bio, height, occupation, education, languages)
    // [intentCount+3] Photos
    // [intentCount+4 ..] Interests, My Profile, Match Prefs, Social Links, Review

    final subIntentStart = 1;
    final subIntentEnd = subIntentStart + intentCount;
    final basicsIndex = subIntentEnd;
    final detailsIndex = basicsIndex + 1;
    final photosIndex = detailsIndex + 1;
    final interestStart = photosIndex + 1;

    // Validate Main Intents page
    if (currentPage == 0) {
      if (p == null || p.activeModes.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.getString('profileEditSelectIntent'))),
        );
        return;
      }
      await _saveDraftBestEffort(notifier);
      _advancePage();
      return;
    }

    // Validate Sub-Intent pages
    if (currentPage >= subIntentStart && currentPage < subIntentEnd) {
      if (p != null) {
        final intentIndex = currentPage - subIntentStart;
        final intent = selectedIntents[intentIndex];
        final subs = p.subIntents[intent.key] ?? [];
        final intentName = l10n.getString(intent.translationKey);
        if (subs.length < _minSubIntents) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n.getString(
                  'profileWizardSubIntentMin',
                  params: {'intent': intentName, 'min': '$_minSubIntents'},
                ),
              ),
            ),
          );
          return;
        }
        if (subs.length > _maxSubIntents) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n.getString(
                  'profileWizardSubIntentMax',
                  params: {'intent': intentName, 'max': '$_maxSubIntents'},
                ),
              ),
            ),
          );
          return;
        }
      }
      await _saveDraftBestEffort(notifier);
      _advancePage();
      return;
    }

    // Validate About You (Basics) page
    if (currentPage == basicsIndex) {
      if (_formKeyStep1.currentState == null ||
          !_formKeyStep1.currentState!.validate()) {
        return;
      }
      if (_dobController.text.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.getString('profileEditDobRequired'))),
        );
        return;
      }
      if (_dobController.text.isNotEmpty) {
        try {
          final dob = DateFormat('yyyy-MM-dd').parse(_dobController.text);
          if (_computeAge(dob) < 18) {
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.getString('profileEditMustBe18'))),
            );
            return;
          }
        } catch (_) {
          // Ignore invalid date format
        }
      }
      await _saveDraftBestEffort(notifier);
      _advancePage();
      return;
    }

    // Validate Details page (bio, occupation/education for business, optional height for romantic)
    if (currentPage == detailsIndex) {
      if (p != null) {
        // Known languages are optional — only validate skills when languages exist
        final langs = p.languagesKnown['languages'] ?? const <String>[];
        if (langs.isNotEmpty) {
          for (final lang in langs) {
            final skills = p.languagesKnown[lang] ?? const <String>[];
            if (skills.isEmpty) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(l10n.getString('profileSelectAtLeastOneSkill')),
                ),
              );
              return;
            }
          }
        }
        final hasRomanticIntent = p.activeModes.any(
          (m) => _normalizeKey(m) == 'romantic',
        );
        final hasBusinessIntent = p.activeModes.any(
          (m) => _isBusinessIntentKey(m),
        );
        // Occupation and Education are mandatory for Business/Networking intent
        if (hasBusinessIntent) {
          if ((_occupationController.text.trim().isEmpty) &&
              ((p.occupation ?? '').trim().isEmpty)) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(l10n.getString('profileEditOccupationRequired')),
              ),
            );
            return;
          }
          final currentEducation = (p.education ?? '').trim();
          if (currentEducation.isEmpty) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(l10n.getString('profileEditEducationRequired')),
              ),
            );
            return;
          }
        }
        // Height is optional and only asked for Romantic intent — validate range if provided
        if (hasRomanticIntent) {
          String? heightErrorKey;
          bool heightValid = true;
          if (_heightUnitMode == 0) {
            final text = _heightController.text.trim();
            if (text.isEmpty) {
              notifier.updateHeight(null);
              heightValid = true;
            } else {
              final parsed = int.tryParse(text);
              if (parsed == null || parsed < 100 || parsed > 250) {
                heightErrorKey = 'profileEditHeightInvalid';
                heightValid = false;
              } else {
                if (p.height != parsed) {
                  notifier.updateHeight(parsed);
                }
                heightValid = true;
              }
            }
          } else {
            final feetText = _heightFeetController.text.trim();
            final inchesText = _heightInchesController.text.trim();
            if (feetText.isEmpty && inchesText.isEmpty) {
              notifier.updateHeight(null);
              heightValid = true;
            } else if (feetText.isEmpty || inchesText.isEmpty) {
              // Partial entry is treated as invalid input, not as empty
              heightErrorKey = 'profileEditHeightInvalidFeet';
              heightValid = false;
            } else {
              final feet = int.tryParse(feetText);
              final inches = int.tryParse(inchesText);
              if (feet == null ||
                  inches == null ||
                  inches < 0 ||
                  inches > 11 ||
                  feet < 0) {
                heightErrorKey = 'profileEditHeightInvalidFeet';
                heightValid = false;
              } else {
                final totalCm = (feet * 30.48 + inches * 2.54).round();
                if (totalCm < 100 || totalCm > 250) {
                  heightErrorKey = 'profileEditHeightInvalidFeet';
                  heightValid = false;
                } else {
                  if (p.height != totalCm) {
                    notifier.updateHeight(totalCm);
                  }
                  heightValid = true;
                }
              }
            }
          }
          if (!heightValid) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  l10n.getString(heightErrorKey ?? 'profileEditHeightInvalid'),
                ),
              ),
            );
            return;
          }
          // heightEmpty is allowed — no error
        }
        final ok = await _ensureBioAllowedBeforeContinuing();
        if (!ok) return;
      } else {
        final ok = await _ensureBioAllowedBeforeContinuing();
        if (!ok) return;
      }
      if (p != null) {
        final proceed = await _confirmSkipVoluntaryPage(p, l10n, currentPage);
        if (!proceed) return;
      }
      await _saveDraftBestEffort(notifier);
      _advancePage();
      return;
    }

    // Validate Photos page
    if (currentPage == photosIndex) {
      if (p == null || p.photos.isEmpty) {
        unawaited(
          VoiceGuidanceService.instance.speakKey(
            'voiceGuidancePhotoRequiredHint',
          ),
        );
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.getString('profileWizardUploadPhotoRequired')),
          ),
        );
        return;
      }
      try {
        _primaryPhotoValidationDebounce?.cancel();
        _pendingPrimaryPhotoPath = null;
        final validatingFresh =
            _lastValidatedPrimaryPhotoPath != p.photos.first;
        await _validatePrimaryPhoto(p.photos.first, showLoading: true);
        if (validatingFresh) {
          unawaited(
            VoiceGuidanceService.instance.speakKey(
              'voiceGuidancePrimaryPhotoOk',
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString();
        const geminiMarker = 'Exception: GEMINI_MSG:';
        final geminiIdx = msg.indexOf(geminiMarker);
        String displayMsg;
        if (geminiIdx != -1) {
          displayMsg = msg.substring(geminiIdx + geminiMarker.length);
        } else {
          final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
          if (errorKey == 'authUnexpectedError') {
            displayMsg = msg.startsWith('Exception: ')
                ? msg.substring('Exception: '.length)
                : msg;
          } else {
            displayMsg = l10n.getString(errorKey);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !context.mounted) return;
          unawaited(VoiceGuidanceService.instance.speakText(displayMsg));
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              content: Text(displayMsg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(l10n.getString('generalOk')),
                ),
              ],
            ),
          );
        });
        return;
      }
      await _saveDraftBestEffort(notifier);
      _advancePage();
      return;
    }

    // Validate Interest pages (dynamic indices after photos)
    if (currentPage >= interestStart) {
      if (p != null) {
        var pageIdx = interestStart;
        final hasSocialIntent = p.activeModes.any(
          (m) => !_isBusinessIntentKey(m),
        );
        if (hasSocialIntent) {
          if (currentPage == pageIdx) {
            final nonEmptyPersonalCount = p.personalInterests.entries
                .where((e) => e.value.isNotEmpty)
                .length;
            if (nonEmptyPersonalCount < _minMainInterests) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.getString('profileSelectAtLeastOneInterest'),
                  ),
                ),
              );
              return;
            }
          }
          pageIdx++;
        }
        final hasBusinessIntent = p.activeModes.any(
          (m) => _isBusinessIntentKey(m),
        );
        if (hasBusinessIntent) {
          if (currentPage == pageIdx) {
            final nonEmptyBusinessCount = p.businessInterests.entries
                .where((e) => e.value.isNotEmpty)
                .length;
            if (nonEmptyBusinessCount < _minMainInterests) {
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    l10n.getString('profileSelectAtLeastOneInterest'),
                  ),
                ),
              );
              return;
            }
          }
          pageIdx++;
        }
      }
    }

    if (p != null) {
      final proceed = await _confirmSkipVoluntaryPage(p, l10n, currentPage);
      if (!proceed) return;
    }
    await _saveDraftBestEffort(notifier);
    _advancePage();
  }

  /// If the current page is all-voluntary and the user left every field on it
  /// empty, confirm they really want to skip and tell them they can complete
  /// it later. Returns true to proceed to the next page, false to stay.
  Future<bool> _confirmSkipVoluntaryPage(
    UserProfile p,
    LocalizationState l10n,
    int currentPage,
  ) async {
    final pageMap = _profileWizardPageMap(p);
    switch (pageMap.sectionForPage(currentPage)) {
      case ProfileWizardSection.details:
        // With a business intent, occupation/education are mandatory and the
        // user was already blocked above — no skip confirmation applies.
        if (p.activeModes.any((m) => _isBusinessIntentKey(m))) return true;
        if ((p.bio ?? '').trim().isNotEmpty) return true;
        if (p.height != null) return true;
        if ((p.languagesKnown['languages'] ?? const <String>[]).isNotEmpty) {
          return true;
        }
        if ((p.occupation ?? '').trim().isNotEmpty) return true;
        if ((p.education ?? '').trim().isNotEmpty) return true;
        break;
      case ProfileWizardSection.lifestyle:
        final lf = p.lifestyle ?? const <String, dynamic>{};
        bool has(String key) =>
            lf[key] != null && lf[key].toString().trim().isNotEmpty;
        if (has('smoking') || has('drinking') || has('exercise') ||
            has('diet')) {
          return true;
        }
        break;
      case ProfileWizardSection.family:
        final f = p.family ?? const <String, dynamic>{};
        if (f['has_children'] != null) return true;
        final wants = f['wants_children'];
        if (wants != null && wants.toString().trim().isNotEmpty) return true;
        break;
      case ProfileWizardSection.religion:
        final r = p.religion ?? const <String, dynamic>{};
        if (r['religion'] != null &&
            r['religion'].toString().trim().isNotEmpty) {
          return true;
        }
        break;
      case ProfileWizardSection.socialLinks:
        if ((p.instagramUrl ?? '').trim().isNotEmpty) return true;
        if ((p.linkedinUrl ?? '').trim().isNotEmpty) return true;
        if ((p.facebookUrl ?? '').trim().isNotEmpty) return true;
        break;
      default:
        // Required pages and interest pages never trigger the skip confirm.
        return true;
    }

    if (!mounted) return true;
    final body = l10n.getString('profileWizardSkipConfirmBody');
    if (ref.read(voiceGuidanceEnabledProvider)) {
      unawaited(VoiceGuidanceService.instance.speakText(body));
    }
    final skip = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('profileWizardSkipConfirmTitle')),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.getString('profileWizardSkipConfirmFillNow')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.getString('profileWizardSkipConfirmSkip')),
          ),
        ],
      ),
    );
    return skip == true;
  }

  /// Best-effort draft persist that never blocks wizard navigation.
  /// A hanging local-DB write (e.g. right after a system permission
  /// resume) must not leave the wizard stuck on the current page.
  Future<void> _saveDraftBestEffort(dynamic notifier) async {
    try {
      await notifier
          .saveWizardDraft()
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void _advancePage() {
    final nextIndex = _currentPageIndex + 1;
    _programmaticNavTarget = nextIndex;
    _programmaticNavAt = DateTime.now();
    // Announce the destination up front: the optimistic index below already
    // matches it, so the page listener would only ever announce the page
    // being left (its first animation frames still round to the old page).
    _speakStepGuidance(nextIndex);
    try {
      ref
          .read(profileEditProvider(widget.user.id).notifier)
          .setWizardPageIndex(nextIndex);
    } catch (_) {}
    // Persist the draft in the background, but never let a slow/failed
    // draft write (e.g. right after a permission resume) block navigation.
    // A stuck await here was one way the wizard appeared frozen.
    unawaited(
      (() async {
        try {
          await ref
              .read(profileEditProvider(widget.user.id).notifier)
              .saveWizardDraft()
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      })(),
    );
    // Optimistically update the local index so the bottom bar (Save/Next)
    // never desyncs from the PageController if the animation callback is
    // delayed by a permission resume/rebuild.
    if (mounted) {
      setState(() => _currentPageIndex = nextIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        final pageCount = _pageController.positions.isNotEmpty
            ? (_pageController.page?.round() ?? nextIndex)
            : nextIndex;
        // Clamp defensively; the page list can shrink/grow across rebuilds.
        _pageController.animateToPage(
          nextIndex < 0 ? 0 : nextIndex,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
        );
        // pageCount referenced to avoid unused warning in some configs
        assert(() {
          debugPrint('wizard advance -> $nextIndex (was $pageCount)');
          return true;
        }());
      }
    });
  }

  /// Restores the wizard to the saved draft page. Retries each frame until the
  /// PageView is attached (intents/interests may still be loading on cold
  /// start), so the restore is never silently dropped.
  void _ensurePageRestored(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_pageController.hasClients) {
        final current = _pageController.page?.round() ?? 0;
        if (current != index) {
          _pageController.jumpToPage(index);
        }
      } else if (index > 0) {
        _ensurePageRestored(index);
      }
    });
  }

  void _handleBackPage(List<Widget> pages) {
    final currentPage = _currentPageIndex;
    if (currentPage >= pages.length || currentPage <= 0) {
      unawaited(
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .saveWizardDraft(),
      );
      Navigator.of(context).pop();
      return;
    }

    if (_pageController.hasClients) {
      unawaited(
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .saveWizardDraft(),
      );
      // Back has no optimistic index update — the listener announces the
      // arrived page itself once the animation crosses the midpoint.
      _programmaticNavTarget = null;
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      unawaited(
        ref
            .read(profileEditProvider(widget.user.id).notifier)
            .saveWizardDraft(),
      );
      Navigator.of(context).pop();
    }
  }

  /// Announces the guidance line for the wizard page at [pageIndex]. Mirrors
  /// the page order built in _buildWizardPages and the dynamic index math in
  /// _handleNextPage; fails silently when the structure can't be resolved.
  void _speakStepGuidance(int pageIndex) {
    if (!ref.read(voiceGuidanceEnabledProvider)) return;
    final step = _voiceStepKeyForPage(pageIndex);
    if (step == null) return;
    unawaited(VoiceGuidanceService.instance.speakKey(step.$1, params: step.$2));
  }

  (String, Map<String, String>?)? _voiceStepKeyForPage(int pageIndex) {
    try {
      final profile = ref.read(profileEditProvider(widget.user.id)).value;
      final pageMap = _profileWizardPageMap(profile);
      final section = pageMap.sectionForPage(pageIndex);
      if (section == null) return null;

      switch (section) {
        case ProfileWizardSection.mainIntents:
          return ('voiceGuidanceStepIntents', null);
        case ProfileWizardSection.subIntents:
          final selectedIntents = _getSelectedIntents(
            ref,
            profile,
            ref.read(mainIntentsProvider),
          );
          final intentIndex = pageMap.subIntentIndexForPage(pageIndex);
          if (intentIndex == null || intentIndex >= selectedIntents.length) {
            return null;
          }
          return (
            'voiceGuidanceStepSubIntents',
            {
              'intent': ref
                  .read(localizationProvider)
                  .getString(selectedIntents[intentIndex].translationKey),
            },
          );
        case ProfileWizardSection.basics:
          return ('voiceGuidanceStepAboutYou', null);
        case ProfileWizardSection.details:
          return ('voiceGuidanceStepDetails', null);
        case ProfileWizardSection.photos:
          return ('voiceGuidanceStepPhotos', null);
        case ProfileWizardSection.personalInterests:
        case ProfileWizardSection.businessInterests:
          return ('voiceGuidanceStepInterests', null);
        case ProfileWizardSection.lifestyle:
          return ('voiceGuidanceStepLifestyle', null);
        case ProfileWizardSection.family:
          return ('voiceGuidanceStepFamily', null);
        case ProfileWizardSection.religion:
          return ('voiceGuidanceStepReligion', null);
        case ProfileWizardSection.matchPreferences:
          return ('voiceGuidanceStepMatchPrefs', null);
        case ProfileWizardSection.socialLinks:
          return ('voiceGuidanceStepSocial', null);
        case ProfileWizardSection.review:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  String _extractLangCode(dynamic cur) {
    try {
      if (cur == null) return 'en';
      if (cur is Locale) return cur.languageCode;
      if (cur is String) return (cur.split(RegExp('[-_]')).first);
      return cur.toString().split(RegExp('[-_]')).first;
    } catch (_) {
      // Ignore invalid locale format
      return 'en';
    }
  }

  Map<String, dynamic> _snapshotFromProfile(UserProfile p) {
    final Map<String, dynamic> snapshot = {};

    snapshot['name'] = p.name;
    snapshot['dateOfBirth'] = p.dateOfBirth?.toIso8601String();
    snapshot['gender'] = p.gender;

    snapshot['activeModes'] = List<String>.from(p.activeModes);

    final Map<String, List<String>> subIntentsCopy = {};
    p.subIntents.forEach((k, v) {
      subIntentsCopy[k] = List<String>.from(v);
    });
    snapshot['subIntents'] = subIntentsCopy;

    final Map<String, List<String>> personalInterestsCopy = {};
    p.personalInterests.forEach((k, v) {
      personalInterestsCopy[k] = List<String>.from(v);
    });
    snapshot['personalInterests'] = personalInterestsCopy;

    final Map<String, List<String>> businessInterestsCopy = {};
    p.businessInterests.forEach((k, v) {
      businessInterestsCopy[k] = List<String>.from(v);
    });
    snapshot['businessInterests'] = businessInterestsCopy;

    final Map<String, List<String>> langsCopy = {};
    p.languagesKnown.forEach((k, v) {
      langsCopy[k] = List<String>.from(v);
    });
    snapshot['languagesKnown'] = langsCopy;

    snapshot['bio'] = p.bio;
    snapshot['photos'] = List<String>.from(p.photos);
    snapshot['linkedinUrl'] = p.linkedinUrl;
    snapshot['instagramUrl'] = p.instagramUrl;
    snapshot['facebookUrl'] = p.facebookUrl;
    snapshot['height'] = p.height;
    snapshot['heightUnit'] = p.heightUnit;
    snapshot['occupation'] = p.occupation;
    snapshot['education'] = p.education;
    snapshot['lifestyle'] = p.lifestyle != null
        ? Map<String, dynamic>.from(p.lifestyle!)
        : null;
    snapshot['family'] = p.family != null
        ? Map<String, dynamic>.from(p.family!)
        : null;
    snapshot['religion'] = p.religion != null
        ? Map<String, dynamic>.from(p.religion!)
        : null;

    final Map<String, List<String>> genderPrefsCopy = {};
    p.genderPreferences.forEach((k, v) {
      genderPrefsCopy[k] = List<String>.from(v);
    });
    snapshot['genderPreferences'] = genderPrefsCopy;

    final Map<String, List<double>> agePrefsCopy = {};
    p.agePreferences.forEach((k, v) {
      agePrefsCopy[k] = List<double>.from(v);
    });
    snapshot['agePreferences'] = agePrefsCopy;

    // Filter/deep equality maps (used in _computeDiffs — must be deeply cloned)
    final Map<String, Map<String, dynamic>> lfCopy = {};
    p.lifestyleFilters.forEach((k, v) {
      lfCopy[k] = Map<String, dynamic>.from(v);
    });
    snapshot['lifestyleFilters'] = lfCopy;
    final Map<String, Map<String, dynamic>> ffCopy = {};
    p.familyFilters.forEach((k, v) {
      ffCopy[k] = Map<String, dynamic>.from(v);
    });
    snapshot['familyFilters'] = ffCopy;
    final Map<String, Map<String, dynamic>> rfCopy = {};
    p.religionFilters.forEach((k, v) {
      rfCopy[k] = Map<String, dynamic>.from(v);
    });
    snapshot['religionFilters'] = rfCopy;
    final Map<String, Map<String, dynamic>> hpCopy = {};
    p.heightPreferences.forEach((k, v) {
      hpCopy[k] = Map<String, dynamic>.from(v);
    });
    snapshot['heightPreferences'] = hpCopy;

    return snapshot;
  }

  Map<String, dynamic> _computeDiffs(
    Map<String, dynamic>? orig,
    UserProfile current,
  ) {
    final diffs = <String, dynamic>{
      'name': null,
      'dateOfBirth': null,
      'gender': null,
      'intentsAdded': <String>[],
      'intentsRemoved': <String>[],
      'subIntentsAdded': <String, List<String>>{},
      'subIntentsRemoved': <String, List<String>>{},
      'interestsAdded': <String, List<String>>{},
      'interestsRemoved': <String, List<String>>{},
      'languagesChanged': <String, Map<String, List<String>>>{},
      'bioChanged': null,
      'photosChanged': null,
      'linkedinChanged': null,
      'instagramChanged': null,
      'facebookChanged': null,
      'heightChanged': null,
      'heightUnitChanged': null,
      'occupationChanged': null,
      'educationChanged': null,
      'lifestyleChanged': null,
      'familyChanged': null,
      'religionChanged': null,
      'genderPreferencesChanged': null,
      'agePreferencesChanged': null,
      'lifestyleFiltersChanged': null,
      'familyFiltersChanged': null,
      'religionFiltersChanged': null,
      'heightPreferencesChanged': null,
    };

    if (orig == null) {
      diffs['name'] = {'from': null, 'to': current.name};
      diffs['dateOfBirth'] = {
        'from': orig?['dateOfBirth'],
        'to': current.dateOfBirth?.toIso8601String(),
      };
      diffs['gender'] = {'from': orig?['gender'], 'to': current.gender};
      diffs['intentsAdded'] = List<String>.from(current.activeModes);
      for (final intent in current.subIntents.keys) {
        (diffs['subIntentsAdded'] as Map)[intent] = List<String>.from(
          current.subIntents[intent]!,
        );
      }
      current.personalInterests.forEach((k, v) {
        (diffs['interestsAdded'] as Map)[k] = List<String>.from(v);
      });
      current.businessInterests.forEach((k, v) {
        (diffs['interestsAdded'] as Map)[k] = List<String>.from(v);
      });
      current.languagesKnown.forEach((k, v) {
        if (k != 'languages') {
          (diffs['languagesChanged'] as Map)[k] = {
            'added': List<String>.from(v),
            'removed': <String>[],
          };
        }
      });
      diffs['bioChanged'] = {'from': null, 'to': current.bio};
      diffs['photosChanged'] = {'from': [], 'to': current.photos};
      diffs['linkedinChanged'] = {'from': null, 'to': current.linkedinUrl};
      diffs['instagramChanged'] = {'from': null, 'to': current.instagramUrl};
      diffs['facebookChanged'] = {'from': null, 'to': current.facebookUrl};
      diffs['heightChanged'] = {'from': null, 'to': current.height};
      diffs['heightUnitChanged'] = {'from': null, 'to': current.heightUnit};
      diffs['occupationChanged'] = {'from': null, 'to': current.occupation};
      diffs['educationChanged'] = {'from': null, 'to': current.education};
      diffs['lifestyleChanged'] = {'from': null, 'to': current.lifestyle};
      diffs['familyChanged'] = {'from': null, 'to': current.family};
      diffs['religionChanged'] = {'from': null, 'to': current.religion};
      diffs['genderPreferencesChanged'] = {
        'from': null,
        'to': current.genderPreferences,
      };
      diffs['agePreferencesChanged'] = {
        'from': null,
        'to': current.agePreferences,
      };
      diffs['lifestyleFiltersChanged'] = {
        'from': null,
        'to': current.lifestyleFilters,
      };
      diffs['familyFiltersChanged'] = {
        'from': null,
        'to': current.familyFilters,
      };
      diffs['religionFiltersChanged'] = {
        'from': null,
        'to': current.religionFilters,
      };
      diffs['heightPreferencesChanged'] = {
        'from': null,
        'to': current.heightPreferences,
      };
      return diffs;
    }

    if (orig['name'] != current.name) {
      diffs['name'] = {'from': orig['name'], 'to': current.name};
    }
    final origDob = orig['dateOfBirth'] as String?;
    final currDob = current.dateOfBirth?.toIso8601String();
    if (origDob != currDob) {
      diffs['dateOfBirth'] = {'from': origDob, 'to': currDob};
    }
    if (orig['gender'] != current.gender) {
      diffs['gender'] = {'from': orig['gender'], 'to': current.gender};
    }

    final List<String> origIntents = List<String>.from(
      orig['activeModes'] ?? <String>[],
    );
    final List<String> currIntents = List<String>.from(current.activeModes);
    final origSet = Set<String>.from(origIntents);
    final currSet = Set<String>.from(currIntents);
    final addedIntents = currSet.difference(origSet).toList();
    final removedIntents = origSet.difference(currSet).toList();
    diffs['intentsAdded'] = addedIntents;
    diffs['intentsRemoved'] = removedIntents;

    final Map<String, List<String>> origSubs = Map<String, List<String>>.from(
      (orig['subIntents'] as Map?)?.map(
            (k, v) => MapEntry(k, List<String>.from(v ?? <String>[])),
          ) ??
          {},
    );
    final Map<String, List<String>> currSubs = current.subIntents.map(
      (k, v) => MapEntry(k, List<String>.from(v)),
    );
    final allIntentKeys = {...origSubs.keys, ...currSubs.keys};
    for (final intent in allIntentKeys) {
      final o = Set<String>.from(origSubs[intent] ?? []);
      final c = Set<String>.from(currSubs[intent] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty) (diffs['subIntentsAdded'] as Map)[intent] = added;
      if (removed.isNotEmpty) {
        (diffs['subIntentsRemoved'] as Map)[intent] = removed;
      }
    }

    final Map<String, List<String>> origPersonalInterests =
        Map<String, List<String>>.from(
          (orig['personalInterests'] as Map?)?.map(
                (k, v) => MapEntry(k, List<String>.from(v ?? <String>[])),
              ) ??
              {},
        );
    final Map<String, List<String>> currPersonalInterests = current
        .personalInterests
        .map((k, v) => MapEntry(k, List<String>.from(v)));
    final allPersonalInterestKeys = {
      ...origPersonalInterests.keys,
      ...currPersonalInterests.keys,
    };
    for (final k in allPersonalInterestKeys) {
      final o = Set<String>.from(origPersonalInterests[k] ?? []);
      final c = Set<String>.from(currPersonalInterests[k] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty) (diffs['interestsAdded'] as Map)[k] = added;
      if (removed.isNotEmpty) (diffs['interestsRemoved'] as Map)[k] = removed;
    }

    final Map<String, List<String>> origBusinessInterests =
        Map<String, List<String>>.from(
          (orig['businessInterests'] as Map?)?.map(
                (k, v) => MapEntry(k, List<String>.from(v ?? <String>[])),
              ) ??
              {},
        );
    final Map<String, List<String>> currBusinessInterests = current
        .businessInterests
        .map((k, v) => MapEntry(k, List<String>.from(v)));
    final allBusinessInterestKeys = {
      ...origBusinessInterests.keys,
      ...currBusinessInterests.keys,
    };
    for (final k in allBusinessInterestKeys) {
      final o = Set<String>.from(origBusinessInterests[k] ?? []);
      final c = Set<String>.from(currBusinessInterests[k] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty) (diffs['interestsAdded'] as Map)[k] = added;
      if (removed.isNotEmpty) (diffs['interestsRemoved'] as Map)[k] = removed;
    }

    final Map<String, List<String>> origLangs = Map<String, List<String>>.from(
      (orig['languagesKnown'] as Map?)?.map(
            (k, v) => MapEntry(k, List<String>.from(v ?? <String>[])),
          ) ??
          {},
    );
    final Map<String, List<String>> currLangs = current.languagesKnown.map(
      (k, v) => MapEntry(k, List<String>.from(v)),
    );
    final allLangKeys = {
      ...origLangs.keys,
      ...currLangs.keys,
    }.where((k) => k != 'languages').toList();
    for (final lang in allLangKeys) {
      final o = Set<String>.from(origLangs[lang] ?? []);
      final c = Set<String>.from(currLangs[lang] ?? []);
      final added = c.difference(o).toList();
      final removed = o.difference(c).toList();
      if (added.isNotEmpty || removed.isNotEmpty) {
        (diffs['languagesChanged'] as Map)[lang] = {
          'added': added,
          'removed': removed,
        };
      }
    }

    final origBio = orig['bio']?.toString() ?? '';
    final currBio = current.bio?.toString() ?? '';
    if (origBio != currBio) {
      diffs['bioChanged'] = {'from': origBio, 'to': currBio};
    }

    final List<String> origPhotos =
        (orig['photos'] as List?)?.map((e) => e.toString()).toList() ?? [];
    final List<String> currPhotos = current.photos;
    if (origPhotos.toSet() != currPhotos.toSet()) {
      diffs['photosChanged'] = {'from': origPhotos, 'to': currPhotos};
    }

    final origLinkedin = orig['linkedinUrl']?.toString() ?? '';
    final currLinkedin = current.linkedinUrl?.toString() ?? '';
    if (origLinkedin != currLinkedin) {
      diffs['linkedinChanged'] = {'from': origLinkedin, 'to': currLinkedin};
    }

    final origInstagram = orig['instagramUrl']?.toString() ?? '';
    final currInstagram = current.instagramUrl?.toString() ?? '';
    if (origInstagram != currInstagram) {
      diffs['instagramChanged'] = {'from': origInstagram, 'to': currInstagram};
    }

    final origFacebook = orig['facebookUrl']?.toString() ?? '';
    final currFacebook = current.facebookUrl?.toString() ?? '';
    if (origFacebook != currFacebook) {
      diffs['facebookChanged'] = {'from': origFacebook, 'to': currFacebook};
    }

    final origHeight = orig['height'] as int?;
    final currHeight = current.height;
    if (origHeight != currHeight) {
      diffs['heightChanged'] = {'from': origHeight, 'to': currHeight};
    }
    final origHeightUnit = orig['heightUnit']?.toString() ?? 'cm';
    final currHeightUnit = current.heightUnit;
    if (origHeightUnit != currHeightUnit) {
      diffs['heightUnitChanged'] = {
        'from': origHeightUnit,
        'to': currHeightUnit,
      };
    }

    final origOccupation = orig['occupation']?.toString() ?? '';
    final currOccupation = current.occupation?.toString() ?? '';
    if (origOccupation != currOccupation) {
      diffs['occupationChanged'] = {
        'from': origOccupation,
        'to': currOccupation,
      };
    }

    final origEducation = orig['education']?.toString() ?? '';
    final currEducation = current.education?.toString() ?? '';
    if (origEducation != currEducation) {
      diffs['educationChanged'] = {'from': origEducation, 'to': currEducation};
    }

    if (!const DeepCollectionEquality().equals(
      orig['lifestyle'],
      current.lifestyle,
    )) {
      diffs['lifestyleChanged'] = {
        'from': orig['lifestyle'],
        'to': current.lifestyle,
      };
    }

    if (!const DeepCollectionEquality().equals(
      orig['family'],
      current.family,
    )) {
      diffs['familyChanged'] = {'from': orig['family'], 'to': current.family};
    }

    if (!const DeepCollectionEquality().equals(
      orig['religion'],
      current.religion,
    )) {
      diffs['religionChanged'] = {
        'from': orig['religion'],
        'to': current.religion,
      };
    }

    final Map<String, List<String>> origGenderPrefs =
        Map<String, List<String>>.from(
          (orig['genderPreferences'] as Map?)?.map(
                (k, v) => MapEntry(k, List<String>.from(v ?? <String>[])),
              ) ??
              {},
        );
    final Map<String, List<String>> currGenderPrefs = current.genderPreferences
        .map((k, v) => MapEntry(k, List<String>.from(v)));
    if (!const DeepCollectionEquality().equals(
      origGenderPrefs,
      currGenderPrefs,
    )) {
      diffs['genderPreferencesChanged'] = {
        'from': origGenderPrefs,
        'to': currGenderPrefs,
      };
    }

    final Map<String, List<double>> origAgePrefs =
        Map<String, List<double>>.from(
          (orig['agePreferences'] as Map?)?.map(
                (k, v) => MapEntry(k, List<double>.from(v ?? <double>[])),
              ) ??
              {},
        );
    final Map<String, List<double>> currAgePrefs = current.agePreferences.map(
      (k, v) => MapEntry(k, List<double>.from(v)),
    );
    if (!const DeepCollectionEquality().equals(origAgePrefs, currAgePrefs)) {
      diffs['agePreferencesChanged'] = {
        'from': origAgePrefs,
        'to': currAgePrefs,
      };
    }

    // Filter diffs (for match preferences)
    if (!const DeepCollectionEquality().equals(
      orig['lifestyleFilters'],
      current.lifestyleFilters,
    )) {
      diffs['lifestyleFiltersChanged'] = {
        'from': orig['lifestyleFilters'],
        'to': current.lifestyleFilters,
      };
    }
    if (!const DeepCollectionEquality().equals(
      orig['familyFilters'],
      current.familyFilters,
    )) {
      diffs['familyFiltersChanged'] = {
        'from': orig['familyFilters'],
        'to': current.familyFilters,
      };
    }
    if (!const DeepCollectionEquality().equals(
      orig['religionFilters'],
      current.religionFilters,
    )) {
      diffs['religionFiltersChanged'] = {
        'from': orig['religionFilters'],
        'to': current.religionFilters,
      };
    }
    if (!const DeepCollectionEquality().equals(
      orig['heightPreferences'],
      current.heightPreferences,
    )) {
      diffs['heightPreferencesChanged'] = {
        'from': orig['heightPreferences'],
        'to': current.heightPreferences,
      };
    }

    return diffs;
  }

  String _humanizeKey(String key) {
    var s = key;
    s = s.replaceAll(
      RegExp(
        r'^(interest_category_|interest_|category_|subIntent|intent|profileEdit)',
      ),
      '',
    );
    s = s.replaceAll('_', ' ');
    s = s.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    final words = s
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final human = words
        .map((w) {
          if (w.length <= 1) return w.toUpperCase();
          return w[0].toUpperCase() + w.substring(1);
        })
        .join(' ');

    final result = human.isEmpty ? key : human;
    return result;
  }

  String _localizedLifestyleValue(
    LocalizationState l10n,
    String category,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: category, context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final prefix =
        'lifestyle${category[0].toUpperCase()}${category.substring(1)}';
    final key = '$prefix$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedReligionValue(LocalizationState l10n, String value) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'religion', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final key = 'religion$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedFamilyWantsChildrenValue(
    LocalizationState l10n,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((
                fieldKey: 'wants_children',
                context: 'profile',
              )),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final direct = _tryGetString(l10n, value);
    if (direct != null) return direct;
    return _humanizeKey(value);
  }

  bool _looksLikeTranslationKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    return RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(normalized);
  }

  String _resolveDisplayLabel(
    LocalizationState l10n,
    String keyOrDisplay, {
    Map<String, String>? interestKeyToDisplayKey,
    Map<String, String>? categoryKeyToDisplayKey,
    Map<String, String>? allIntentsMap,
  }) {
    if (keyOrDisplay.trim().isEmpty) return '';

    // First, try to resolve the full key directly (works for both simple and composite keys)
    if (allIntentsMap != null && allIntentsMap.containsKey(keyOrDisplay)) {
      final mapped = allIntentsMap[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
    }

    // NOTE: composite interest keys like "dancing::salsa" have their own
    // dedicated translation ("interest.dancing.salsa" -> "Salsa"). Prefer that
    // single label over the "Parent — Child" split below, since the parent
    // category is already shown as the section header above the chips.
    if (keyOrDisplay.contains('::')) {
      String? fullMapped;
      if (interestKeyToDisplayKey != null) {
        fullMapped = interestKeyToDisplayKey[keyOrDisplay];
        if ((fullMapped == null || fullMapped.isEmpty)) {
          final norm = _normalizeKey(keyOrDisplay);
          for (final e in interestKeyToDisplayKey.entries) {
            if (_normalizeKey(e.key) == norm) {
              fullMapped = e.value;
              break;
            }
          }
        }
        if (fullMapped != null && fullMapped.isNotEmpty) {
          final loc = _tryGetString(l10n, fullMapped);
          if (loc != null) return loc;
        }
      }
      if (categoryKeyToDisplayKey != null) {
        String? fullCat = categoryKeyToDisplayKey[keyOrDisplay];
        if ((fullCat == null || fullCat.isEmpty)) {
          final norm = _normalizeKey(keyOrDisplay);
          for (final e in categoryKeyToDisplayKey.entries) {
            if (_normalizeKey(e.key) == norm) {
              fullCat = e.value;
              break;
            }
          }
        }
        if (fullCat != null && fullCat.isNotEmpty) {
          final loc = _tryGetString(l10n, fullCat);
          if (loc != null) return loc;
        }
      }
    }

    if (keyOrDisplay.contains('::')) {
      final parts = keyOrDisplay.split('::');

      if (parts.first == 'shared' && parts.length >= 2) {
        final catKey = parts[1];
        final catLabel = categoryKeyToDisplayKey?[catKey] ?? catKey;
        return _tryGetString(l10n, catLabel) ?? _humanizeKey(catKey);
      }

      if (parts.length >= 2) {
        final left = parts[0];
        final right = parts.sublist(1).join('::');

        final leftLocalized =
            _tryGetString(l10n, allIntentsMap?[left] ?? left) ??
            _humanizeKey(left);
        String? rightLocalized;

        // First try allIntentsMap for the right part (it might be a sub-intent)
        if (allIntentsMap != null) {
          final mappedIntent = allIntentsMap[right];
          if (mappedIntent != null && mappedIntent.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mappedIntent);
          }
        }

        // Then try interest maps if not found
        if ((rightLocalized == null || rightLocalized.trim().isEmpty) &&
            interestKeyToDisplayKey != null) {
          final mapped = interestKeyToDisplayKey[right];
          if (mapped != null && mapped.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mapped);
          }
        }

        if ((rightLocalized == null || rightLocalized.trim().isEmpty) &&
            categoryKeyToDisplayKey != null) {
          final mappedCat = categoryKeyToDisplayKey[right];
          if (mappedCat != null && mappedCat.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mappedCat);
          }
        }

        rightLocalized = rightLocalized ?? _humanizeKey(right);
        return '$leftLocalized — $rightLocalized';
      }
    }

    if (allIntentsMap != null && allIntentsMap.containsKey(keyOrDisplay)) {
      final mapped = allIntentsMap[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
      return _humanizeKey(keyOrDisplay);
    }

    if (interestKeyToDisplayKey != null &&
        interestKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = interestKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
      return _humanizeKey(keyOrDisplay);
    }

    if (categoryKeyToDisplayKey != null &&
        categoryKeyToDisplayKey.containsKey(keyOrDisplay)) {
      final mapped = categoryKeyToDisplayKey[keyOrDisplay]!;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) return mappedLoc;
      return _humanizeKey(keyOrDisplay);
    }

    final direct = _tryGetString(l10n, keyOrDisplay);
    if (direct != null) return direct;

    // Handle race condition: if maps are empty during initialization,
    // try common prefixes before falling back to humanization
    if (!keyOrDisplay.contains('.') && !keyOrDisplay.contains('::')) {
      const prefixes = ['interest.', 'intent.activity.', 'intent.'];
      for (final prefix in prefixes) {
        final attempt = _tryGetString(l10n, '$prefix$keyOrDisplay');
        if (attempt != null) return attempt;
      }
    }

    return _humanizeKey(keyOrDisplay);
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    if (!_looksLikeTranslationKey(key)) return null;
    if (!l10n.containsKey(key)) return null;
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key || val.endsWith('...')) return null;
      return val;
    } catch (_) {
      return null;
    }
  }

  String _normalizeGenderDisplayKey(String raw) {
    final normalized = raw.trim().toLowerCase().replaceAll('-', '_');
    if (normalized.isEmpty) return normalized;
    if (normalized.startsWith('gender_')) return normalized;
    if (normalized == 'male' ||
        normalized == 'female' ||
        normalized == 'non_binary' ||
        normalized == 'nonbinary') {
      return normalized == 'nonbinary'
          ? 'gender_non_binary'
          : 'gender_$normalized';
    }
    return raw.trim();
  }

  void _toggleInterestExpanded(String interestKey) {
    setState(() {
      if (_expandedInterestKeys.contains(interestKey)) {
        _expandedInterestKeys.remove(interestKey);
      } else {
        _expandedInterestKeys.add(interestKey);
      }
    });
  }

  void _onPersonalInterestSearchChanged() {
    final next = _searchInterestController.text.trim().toLowerCase();
    if (next != _personalInterestSearchQuery && mounted) {
      setState(() {
        _personalInterestSearchQuery = next;
      });
    }
  }

  void _onBusinessInterestSearchChanged() {
    final next = _searchBusinessInterestController.text.trim().toLowerCase();
    if (next != _businessInterestSearchQuery && mounted) {
      setState(() {
        _businessInterestSearchQuery = next;
      });
    }
  }

  void _clearPersonalInterestSearch() {
    if (_searchInterestController.text.isNotEmpty) {
      _searchInterestController.clear();
    } else if (_personalInterestSearchQuery.isNotEmpty && mounted) {
      setState(() {
        _personalInterestSearchQuery = '';
      });
    }
  }

  void _clearBusinessInterestSearch() {
    if (_searchBusinessInterestController.text.isNotEmpty) {
      _searchBusinessInterestController.clear();
    } else if (_businessInterestSearchQuery.isNotEmpty && mounted) {
      setState(() {
        _businessInterestSearchQuery = '';
      });
    }
  }

  bool _matchesInterestQuery({
    required String displayLabel,
    required String interestKey,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (displayLabel.toLowerCase().contains(q)) return true;
    if (interestKey.toLowerCase().contains(q)) return true;
    if (_humanizeKey(interestKey).toLowerCase().contains(q)) return true;
    return false;
  }

  bool _interestOrDescendantMatches(
    AppInterest interest,
    String query,
    String Function(String translationKey) resolveLabel,
    List<AppInterest> allInterests,
  ) {
    if (query.trim().isEmpty) return true;
    final label = resolveLabel(interest.translationKey);
    if (_matchesInterestQuery(
      displayLabel: label,
      interestKey: interest.key,
      query: query,
    )) {
      return true;
    }
    final children = allInterests
        .where((i) => i.parentId == interest.id)
        .toList();
    for (final child in children) {
      if (_interestOrDescendantMatches(
        child,
        query,
        resolveLabel,
        allInterests,
      )) {
        return true;
      }
    }
    return false;
  }

  Widget _buildInterestSearchField({
    required TextEditingController controller,
    required LocalizationState l10n,
    required VoidCallback onClear,
  }) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final rawText = value.text;
        final isEmpty = rawText.trim().isEmpty;
        final isRtl =
            !isEmpty && rawText.trimLeft().isRtlByFirstStrongChar();
        return TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          textDirection: isEmpty
              ? Directionality.of(context)
              : (isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr),
          textAlign: isEmpty
              ? TextAlign.start
              : (isRtl ? TextAlign.right : TextAlign.left),
          decoration: InputDecoration(
            hintText: l10n.getString('profileWizardSearchInterestsHint'),
            prefixIcon: const Icon(Icons.search),
            suffixIcon: rawText.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: l10n.getString('generalClear'),
                    onPressed: onClear,
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12.0),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12.0),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12.0),
              borderSide:
                  BorderSide(color: Theme.of(context).colorScheme.primary),
            ),
            filled: true,
            fillColor: Theme.of(context).colorScheme.surface,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 12.0,
            ),
          ),
        );
      },
    );
  }

  void _deselectAllDescendants(
    WidgetRef refLocal,
    String categoryKey,
    String parentKey, {
    required bool isBusiness,
  }) {
    final profile = refLocal
        .read(profileEditProvider(widget.user.id))
        .asData
        ?.value;
    if (profile == null) return;
    final allInterests =
        refLocal.read(allInterestsProvider).asData?.value ?? [];
    final parent = allInterests.where((i) => i.key == parentKey).firstOrNull;
    if (parent == null) return;
    final children = allInterests
        .where((i) => i.parentId == parent.id)
        .toList();
    if (children.isEmpty) return;
    final notifier = refLocal.read(
      profileEditProvider(widget.user.id).notifier,
    );
    for (final child in children) {
      final source = isBusiness
          ? profile.businessInterests
          : profile.personalInterests;
      if (source[categoryKey]?.contains(child.key) == true) {
        notifier.toggleInterest(
          categoryKey,
          child.key,
          awaitPersist: false,
          isBusiness: isBusiness,
        );
      }
      _deselectAllDescendants(
        refLocal,
        categoryKey,
        child.key,
        isBusiness: isBusiness,
      );
    }
  }

  Widget _leadingCheckbox({
    required bool loading,
    required bool value,
    required ValueChanged<bool?>? onChanged,
  }) {
    const double width = 44.0;
    if (loading) {
      return SizedBox(
        width: width,
        height: width,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      height: width,
      child: Center(
        child: Checkbox(
          value: value,
          onChanged: onChanged,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          activeColor: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _alignedLockedCard({
    required LocalizationState l10n,
    required Widget leadingIcon,
    required String title,
    required String subtitle,
    required VoidCallback onTapPadlock,
    Widget? statusIndicator,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      margin: const EdgeInsets.only(bottom: 14.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTapPadlock,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
          child: Row(
            children: [
              const SizedBox(width: 4),
              SizedBox(
                width: _leadingWidth,
                child: Center(child: leadingIcon),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: _rowVerticalPadding,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (statusIndicator != null) ...[
                const SizedBox(width: 8),
                statusIndicator,
              ],
              IconButton(
                icon: const Icon(Icons.lock_outline),
                onPressed: onTapPadlock,
                tooltip: l10n.getString('profileEditLockedTooltip'),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBasicFieldStatusPill(
    LocalizationState l10n,
    BasicFieldAdminReview review, {
    required bool canEdit,
  }) {
    final scheme = Theme.of(context).colorScheme;

    final (
      bg,
      border,
      fg,
      icon,
      labelKey,
      tooltipText,
    ) = switch (review.status) {
      'pending' => (
        Colors.blue.shade50,
        Colors.blue.shade200,
        Colors.blue.shade800,
        Icons.schedule,
        'profileEditStatusUnderReview',
        l10n.getString('profileEditRequestSubmittedBody'),
      ),
      'approved' => (
        Colors.green.shade50,
        Colors.green.shade200,
        Colors.green.shade800,
        Icons.check_circle,
        'profileEditAdminDecisionApproved',
        canEdit
            ? l10n.getString('profileEditAdminDecisionApprovedOnceHint')
            : '',
      ),
      'rejected' => (
        Colors.red.shade50,
        Colors.red.shade200,
        Colors.red.shade800,
        Icons.cancel,
        'profileEditAdminDecisionRejected',
        l10n.getString(
          'profileEditAdminDecisionReasonPrefix',
          params: {
            'reason': review.reviewerNote.trim().isNotEmpty
                ? review.reviewerNote.trim()
                : l10n.getString('profileEditAdminDecisionNoReason'),
          },
        ),
      ),
      _ => (
        scheme.surface,
        Theme.of(context).dividerColor,
        scheme.onSurface,
        Icons.info_outline,
        '',
        '',
      ),
    };

    if (labelKey.isEmpty) {
      debugPrint(
        '[Wizard] ❌ _buildBasicFieldStatusPill: labelKey is empty for status=${review.status}',
      );
      return const SizedBox.shrink();
    }

    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              l10n.getString(labelKey),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );

    if (tooltipText.trim().isEmpty) return pill;
    return Tooltip(
      message: tooltipText,
      textStyle: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: Colors.white),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: pill,
    );
  }

  Future<void> _markProfileEditRequestSeen(String requestId) async {
    final id = requestId.trim();
    if (id.isEmpty) return;
    if (_markedProfileEditRequestSeenIds.contains(id)) return;
    _markedProfileEditRequestSeenIds.add(id);
    try {
      await Supabase.instance.client
          .from('profile_edit_requests')
          .update({'user_seen_at': DateTime.now().toIso8601String()})
          .eq('id', id);
    } catch (_) {}
  }

  Future<void> _applyInterestToSelectedIntents(
    WidgetRef refLocal,
    String categoryKey,
    String interestKey, {
    required bool select,
    required bool isBusiness,
  }) async {
    final profile = refLocal
        .read(profileEditProvider(widget.user.id))
        .asData
        ?.value;
    if (profile == null) return;

    if (select) {
      final selectedCategories = isBusiness
          ? _selectedBusinessCategoryKeys(profile)
          : _selectedPersonalCategoryKeys(profile);
      final wouldAddCategory = !selectedCategories.contains(categoryKey);
      final maxLimit = isBusiness
          ? _maxBusinessMainInterests
          : _maxSocialMainInterests;
      if (wouldAddCategory && selectedCategories.length >= maxLimit) {
        _showMaxMainInterestsSnack(isSocial: !isBusiness);
        return;
      }
    }

    // Enforce max sub-interests per category when selecting a sub-interest
    if (select && interestKey != categoryKey) {
      final l10n = refLocal.read(localizationProvider);
      final source = isBusiness
          ? profile.businessInterests
          : profile.personalInterests;
      final currentSubs =
          source[categoryKey]?.where((k) => k != categoryKey).length ?? 0;
      if (currentSubs >= _maxSubInterestsPer) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10n.getString(
                'profileWizardInterestMaxPerCategory',
                params: {'max': '$_maxSubInterestsPer'},
              ),
            ),
          ),
        );
        return;
      }
    }

    refLocal
        .read(profileEditProvider(widget.user.id).notifier)
        .toggleInterest(
          categoryKey,
          interestKey,
          awaitPersist: false,
          isBusiness: isBusiness,
        );

    // If deselecting a parent category, also deselect all descendants
    if (!select && interestKey == categoryKey) {
      final allInterests =
          refLocal.read(allInterestsProvider).asData?.value ?? [];
      final parent = allInterests
          .where((i) => i.key == categoryKey)
          .firstOrNull;
      if (parent != null) {
        _deselectDescendants(
          refLocal,
          categoryKey,
          parent,
          isBusiness: isBusiness,
        );
      }
    }
  }

  void _deselectDescendants(
    WidgetRef refLocal,
    String categoryKey,
    AppInterest parent, {
    required bool isBusiness,
  }) {
    final profile = refLocal
        .read(profileEditProvider(widget.user.id))
        .asData
        ?.value;
    if (profile == null) return;
    final allInterests =
        refLocal.read(allInterestsProvider).asData?.value ?? [];
    final children = allInterests
        .where((i) => i.parentId == parent.id)
        .toList();
    if (children.isEmpty) return;
    final notifier = refLocal.read(
      profileEditProvider(widget.user.id).notifier,
    );
    for (final child in children) {
      final source = isBusiness
          ? profile.businessInterests
          : profile.personalInterests;
      if (source[categoryKey]?.contains(child.key) == true) {
        notifier.toggleInterest(
          categoryKey,
          child.key,
          awaitPersist: false,
          isBusiness: isBusiness,
        );
      }
      _deselectDescendants(
        refLocal,
        categoryKey,
        child,
        isBusiness: isBusiness,
      );
    }
  }

  Widget _buildInterestTree(
    BuildContext context,
    WidgetRef ref,
    List<AppInterest> interests,
    String categoryKey,
    UserProfile profile,
    LocalizationState l10n,
    Set<String> excludedKeys, {
    required bool isBusiness,
    String searchQuery = '',
  }) {
    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);

    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    final source = isBusiness
        ? profile.businessInterests
        : profile.personalInterests;
    final allInterestsFlat = ref.read(allInterestsProvider).asData?.value ?? [];
    final trimmedQuery = searchQuery.trim().toLowerCase();
    final isSearching = trimmedQuery.isNotEmpty;

    return Column(
      children: () {
        final baseFiltered = interests
            .where(
              (item) =>
                  item.key != categoryKey && !excludedKeys.contains(item.key),
            )
            .toList();
        final List<AppInterest> filtered;
        if (!isSearching) {
          filtered = baseFiltered..sort((a, b) => a.key.compareTo(b.key));
        } else {
          filtered =
              baseFiltered
                  .where(
                    (item) => _interestOrDescendantMatches(
                      item,
                      trimmedQuery,
                      localResolve,
                      allInterestsFlat,
                    ),
                  )
                  .toList()
                ..sort((a, b) => a.key.compareTo(b.key));
          if (filtered.isEmpty) {
            return <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  l10n.getString('profileWizardSearchNoResults'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                ),
              ),
            ];
          }
        }
        return filtered.map<Widget>((item) {
          final interestKey = item.key;
          final label = localResolve(item.translationKey);

          bool isSelected = source[categoryKey]?.contains(interestKey) ?? false;

          final children = ref.watch(interestChildrenProvider(item.id));
          final hasChildren = children.isNotEmpty;
          final bool selfMatches =
              !isSearching ||
              _matchesInterestQuery(
                displayLabel: label,
                interestKey: interestKey,
                query: trimmedQuery,
              );
          // When searching, auto-expand so matching sub-interests are visible
          // without requiring an extra tap. Otherwise respect manual expand.
          final isExpanded = isSearching
              ? hasChildren
              : _expandedInterestKeys.contains(interestKey);
          // If this item itself matches, show its full subtree so users can
          // pick sub-interests under a matching parent. Otherwise only show
          // the matching descendant branch.
          final String childQuery = isSearching && selfMatches
              ? ''
              : trimmedQuery;

          void handleToggle() {
            final bool willSelect = !isSelected;
            // Enforce max limits
            if (willSelect) {
              final selectedCategories = isBusiness
                  ? _selectedBusinessCategoryKeys(profile)
                  : _selectedPersonalCategoryKeys(profile);
              final maxLimit = isBusiness
                  ? _maxBusinessMainInterests
                  : _maxSocialMainInterests;
              final categorySelected = selectedCategories.contains(categoryKey);
              if (!categorySelected && selectedCategories.length >= maxLimit) {
                _showMaxMainInterestsSnack(isSocial: !isBusiness);
                return;
              }
            }
            // Enforce max sub-interests per parent
            if (willSelect && interestKey != categoryKey) {
              final currentSubs =
                  source[categoryKey]?.where((k) => k != categoryKey).length ??
                  0;
              if (currentSubs >= _maxSubInterestsPer) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      l10n.getString(
                        'profileWizardInterestMaxPerCategory',
                        params: {'max': '$_maxSubInterestsPer'},
                      ),
                    ),
                  ),
                );
                return;
              }
            }
            // Deselect all descendants when deselecting a parent
            if (!willSelect && hasChildren) {
              _deselectAllDescendants(
                ref,
                categoryKey,
                interestKey,
                isBusiness: isBusiness,
              );
            }
            ref
                .read(profileEditProvider(widget.user.id).notifier)
                .toggleInterest(
                  categoryKey,
                  interestKey,
                  awaitPersist: false,
                  isBusiness: isBusiness,
                );
            // If selecting a sub-interest, also select the category
            if (willSelect && interestKey != categoryKey) {
              final categorySelected =
                  source[categoryKey]?.contains(categoryKey) ?? false;
              if (!categorySelected) {
                ref
                    .read(profileEditProvider(widget.user.id).notifier)
                    .toggleInterest(
                      categoryKey,
                      categoryKey,
                      awaitPersist: false,
                      isBusiness: isBusiness,
                    );
              }
            }
            if (hasChildren) {
              setState(() {
                if (willSelect) {
                  _expandedInterestKeys.add(interestKey);
                } else {
                  _expandedInterestKeys.remove(interestKey);
                }
              });
            }
          }

          return Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.0),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            margin: const EdgeInsets.only(bottom: 8.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: _leadingCheckbox(
                    loading: false,
                    value: isSelected,
                    onChanged: null,
                  ),
                  title: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.visible,
                  ),
                  onTap: () => handleToggle(),
                  trailing: hasChildren
                      ? IconButton(
                          icon: Icon(
                            isExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                          ),
                          onPressed: () => _toggleInterestExpanded(interestKey),
                        )
                      : null,
                ),
                if (hasChildren && isExpanded)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 24.0,
                      end: 8.0,
                      bottom: 8.0,
                    ),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer
                            .withValues(alpha: 0.06),
                        border: BorderDirectional(
                          start: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .secondaryContainer
                                .withValues(alpha: 0.4),
                            width: 3.0,
                          ),
                        ),
                        borderRadius: const BorderRadiusDirectional.only(
                          topEnd: Radius.circular(8.0),
                          bottomEnd: Radius.circular(8.0),
                        ),
                      ),
                      padding: const EdgeInsetsDirectional.only(
                        start: 12.0,
                        top: 8.0,
                      ),
                      child: _buildInterestTree(
                        context,
                        ref,
                        children,
                        categoryKey,
                        profile,
                        l10n,
                        const <String>{},
                        isBusiness: isBusiness,
                        searchQuery: childQuery,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }).toList();
      }(),
    );
  }

  Widget _buildPersonalInterestsPage(
    BuildContext ctx,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
  ) {
    final allMainIntents = ref.watch(mainIntentsProvider);

    // Find any social intent to use for loading categories
    AppIntent? socialIntent;
    try {
      socialIntent = allMainIntents.firstWhere(
        (i) =>
            profile.activeModes.contains(i.key) && !_isBusinessIntentKey(i.key),
      );
    } catch (e) {
      socialIntent = null;
    }

    if (socialIntent == null) {
      return Padding(
        padding: const EdgeInsets.all(20.0),
        child: Center(child: Text(l10n.getString('profileNotFound'))),
      );
    }

    List<AppInterest> categories = ref.watch(
      nonSharedInterestCategoriesByKeyProvider(socialIntent.key),
    );

    final Set<String> seenCategoryKeys = {};
    final List<AppInterest> uniqueCategories = categories.where((cat) {
      if (seenCategoryKeys.contains(cat.key)) return false;
      seenCategoryKeys.add(cat.key);
      return true;
    }).toList();

    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 20.0,
          ).copyWith(top: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.getString('profileInterests'),
                      style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.teal.shade50,
                    child: const Icon(Icons.favorite, color: Colors.teal),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.getString('profileInterestsHelper'),
                style: Theme.of(
                  ctx,
                ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
              ),
              _WizardFieldLegend(l10n: l10n),
              const SizedBox(height: 8),
              Builder(
                builder: (_) {
                  final selectedCount = profile.personalInterests.length;
                  final atMax = selectedCount >= _maxSocialMainInterests;
                  return Text(
                    l10n.getString(
                      'profileCounterSelected',
                      params: {
                        'count': '$selectedCount',
                        'max': '$_maxSocialMainInterests',
                      },
                    ),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: atMax ? Colors.orange.shade700 : Colors.green,
                      fontWeight: atMax ? FontWeight.bold : FontWeight.normal,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildInterestSearchField(
                controller: _searchInterestController,
                l10n: l10n,
                onClear: _clearPersonalInterestSearch,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            children: [
              ...() {
                final trimmedQuery = _personalInterestSearchQuery.trim();
                final isSearching = trimmedQuery.isNotEmpty;
                final allInterestsFlat =
                    ref.read(allInterestsProvider).asData?.value ?? [];
                final sortedUniqueCats = List<AppInterest>.from(
                  uniqueCategories,
                )..sort((a, b) => a.key.compareTo(b.key));
                final List<AppInterest> visibleCats = isSearching
                    ? sortedUniqueCats
                          .where(
                            (cat) => _interestOrDescendantMatches(
                              cat,
                              trimmedQuery,
                              localResolve,
                              allInterestsFlat,
                            ),
                          )
                          .toList()
                    : sortedUniqueCats;
                if (isSearching && visibleCats.isEmpty) {
                  return <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: Text(
                        l10n.getString('profileWizardSearchNoResults'),
                        style: Theme.of(
                          ctx,
                        ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                      ),
                    ),
                  ];
                }
                return <Widget>[
                  ...visibleCats.map<Widget>((cat) {
                    final categoryKey = cat.key;
                    final prefLabel = cat.translationKey;
                    final displayLabel = localResolve(prefLabel);
                    final children = ref.watch(
                      interestChildrenProvider(cat.id),
                    );
                    final hasChildren = children.isNotEmpty;
                    final bool categorySelfMatches =
                        !isSearching ||
                        _matchesInterestQuery(
                          displayLabel: displayLabel,
                          interestKey: categoryKey,
                          query: trimmedQuery,
                        );
                    // When searching, auto-expand matches so sub-interests are
                    // visible and clickable without an extra tap.
                    final bool isExpanded = isSearching
                        ? hasChildren
                        : _expandedInterestKeys.contains(categoryKey);
                    // If the category itself matches, show all its
                    // sub-interests; otherwise only show the matching branch.
                    final String childQuery = isSearching && categorySelfMatches
                        ? ''
                        : trimmedQuery;

                    bool isCategorySelected = profile.personalInterests
                        .containsKey(categoryKey);

                    void toggleCategory() {
                      final willSelect = !isCategorySelected;
                      if (willSelect) {
                        final selectedCount = profile.personalInterests.length;
                        if (selectedCount >= _maxSocialMainInterests) {
                          _showMaxMainInterestsSnack(isSocial: true);
                          return;
                        }
                      }
                      _applyInterestToSelectedIntents(
                        ref,
                        categoryKey,
                        categoryKey,
                        select: willSelect,
                        isBusiness: false,
                      );
                      if (hasChildren) {
                        setState(() {
                          if (willSelect) {
                            _expandedInterestKeys.add(categoryKey);
                          } else {
                            _expandedInterestKeys.remove(categoryKey);
                          }
                        });
                      }
                    }

                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12.0),
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12.0),
                        side: BorderSide(color: Colors.grey.shade200, width: 1),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: _leadingCheckbox(
                              loading: false,
                              value: isCategorySelected,
                              onChanged: (_) => toggleCategory(),
                            ),
                            title: Text(
                              displayLabel,
                              style: Theme.of(ctx).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            onTap: () => toggleCategory(),
                            trailing: hasChildren
                                ? IconButton(
                                    icon: Icon(
                                      isExpanded
                                          ? Icons.expand_less_rounded
                                          : Icons.expand_more_rounded,
                                    ),
                                    onPressed: () =>
                                        _toggleInterestExpanded(categoryKey),
                                  )
                                : null,
                          ),
                          if (hasChildren && isExpanded)
                            Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16.0,
                                    8.0,
                                    16.0,
                                    4.0,
                                  ),
                                  child: Builder(
                                    builder: (_) {
                                      final subCount =
                                          profile.personalInterests[categoryKey]
                                              ?.where((k) => k != categoryKey)
                                              .length ??
                                          0;
                                      final atMax =
                                          subCount >= _maxSubInterestsPer;
                                      return Text(
                                        l10n.getString(
                                          'profileCounterSelected',
                                          params: {
                                            'count': '$subCount',
                                            'max': '$_maxSubInterestsPer',
                                          },
                                        ),
                                        style: Theme.of(ctx).textTheme.bodySmall
                                            ?.copyWith(
                                              color: atMax
                                                  ? Colors.orange.shade700
                                                  : Colors.green,
                                              fontWeight: atMax
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                      );
                                    },
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16.0,
                                    0,
                                    16.0,
                                    8.0,
                                  ),
                                  child: _buildInterestTree(
                                    ctx,
                                    ref,
                                    children,
                                    categoryKey,
                                    profile,
                                    l10n,
                                    seenCategoryKeys,
                                    isBusiness: false,
                                    searchQuery: childQuery,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    );
                  }),
                ];
              }(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBasicsPage(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile? profile,
  ) {
    if (profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final canEditName = _canEditBasicField(profile, 'name');
    final canEditGender = _canEditBasicField(profile, 'gender');
    final canEditDob = _canEditBasicField(profile, 'date_of_birth');

    final genderOptionsAsync = ref.watch(genderOptionsProvider);
    final helperText = l10n.getString('profileBasicsHelper');
    final adminReviewsAsync = ref.watch(
      basicFieldAdminReviewsProvider(widget.user.id),
    );

    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    bool canEditForFieldKey(String fieldKey) {
      switch (fieldKey) {
        case 'name':
          return canEditName;
        case 'date_of_birth':
          return canEditDob;
        case 'gender':
          return canEditGender;
        default:
          return false;
      }
    }

    void markApprovedSeenOnEdit(String fieldKey) {
      final reviews = ref
          .read(basicFieldAdminReviewsProvider(widget.user.id))
          .asData
          ?.value;
      final review = reviews?[fieldKey];
      if (review == null) return;
      if (review.status != 'approved') return;
      if (review.userSeenAt != null) return;
      if (_markedProfileEditRequestSeenIds.contains(review.id)) return;
      _currentVisitPillCombos.add('$fieldKey:${review.status}');
      _currentVisitRequestIds.add(review.id);
    }

    Widget statusPillForField(String fieldKey) {
      return adminReviewsAsync.when(
        data: (reviews) {
          final review = reviews[fieldKey];
          if (review == null) return const SizedBox.shrink();
          if (review.status == 'pending') {
            return _buildBasicFieldStatusPill(
              l10n,
              review,
              canEdit: canEditForFieldKey(fieldKey),
            );
          }
          final userId = widget.user.id;
          final combo = '$fieldKey:${review.status}';
          final userPillKeys = _sessionDismissedPillKeys.putIfAbsent(
            userId,
            () => {},
          );
          for (final s in ['approved', 'rejected']) {
            if (s != review.status) userPillKeys.remove('$fieldKey:$s');
          }
          if (userPillKeys.contains(combo)) return const SizedBox.shrink();
          if (review.userSeenAt != null) {
            userPillKeys.add(combo);
            return const SizedBox.shrink();
          }
          _currentVisitPillCombos.add(combo);
          _currentVisitRequestIds.add(review.id);
          final canEdit = canEditForFieldKey(fieldKey);
          return _buildBasicFieldStatusPill(l10n, review, canEdit: canEdit);
        },
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileEditBasics'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                child: Icon(
                  Icons.person,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            helperText,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n),
          const SizedBox(height: 20),

          Form(
            key: _formKeyStep1,
            child: Column(
              children: [
                if (canEditName)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 6.0,
                      ),
                      child: TextFormField(
                        controller: _firstNameController,
                        enabled: true,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(fontFeatures: const []),
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: '${l10n.getString('profileFirstName')} *',
                          prefixIcon: const Icon(Icons.person_outline),
                          border: InputBorder.none,
                          suffixIconConstraints: const BoxConstraints(
                            minHeight: 0,
                            minWidth: 0,
                          ),
                          suffixIcon: Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: IgnorePointer(
                              child: statusPillForField('name'),
                            ),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? l10n.getString('profileEditFirstNameRequired')
                            : null,
                        onChanged: (v) {
                          final fullName =
                              ("${_firstNameController.text.trim()} ${_lastNameController.text.trim()}")
                                  .trim();
                          try {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateName(fullName);
                          } catch (_) {
                            // Ignore profile update errors
                          }
                          markApprovedSeenOnEdit('name');
                        },
                      ),
                    ),
                  ),
                if (canEditName)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 6.0,
                      ),
                      child: TextFormField(
                        controller: _lastNameController,
                        enabled: true,
                        style: Theme.of(
                          context,
                        ).textTheme.bodyLarge?.copyWith(fontFeatures: const []),
                        textInputAction: TextInputAction.next,
                        textAlign: isRtl ? TextAlign.right : TextAlign.left,
                        decoration: InputDecoration(
                          labelText: '${l10n.getString('profileLastName')} *',
                          prefixIcon: const Icon(Icons.person_outline),
                          border: InputBorder.none,
                          helperText: l10n.getString(
                            'profileLastNameNotDisplayed',
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minHeight: 0,
                            minWidth: 0,
                          ),
                          suffixIcon: Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: IgnorePointer(
                              child: statusPillForField('name'),
                            ),
                          ),
                        ),
                        validator: (v) => (v == null || v.isEmpty)
                            ? l10n.getString('profileEditLastNameRequired')
                            : null,
                        onChanged: (v) {
                          final fullName =
                              ("${_firstNameController.text.trim()} ${_lastNameController.text.trim()}")
                                  .trim();
                          try {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateName(fullName);
                          } catch (_) {
                            // Ignore profile update errors
                          }
                          markApprovedSeenOnEdit('name');
                        },
                      ),
                    ),
                  )
                else
                  _alignedLockedCard(
                    l10n: l10n,
                    leadingIcon: const Icon(Icons.person_outline, size: 22),
                    title: l10n.getString('profileName'),
                    subtitle: profile.name.isNotEmpty
                        ? profile.name
                        : l10n.getString('profileNotSet'),
                    onTapPadlock: () => _openRequestDialogForField(
                      context,
                      profile,
                      'name',
                      l10n.getString('profileName'),
                    ),
                    statusIndicator: IgnorePointer(
                      child: statusPillForField('name'),
                    ),
                  ),

                if (!canEditName) ...[
                  Builder(
                    builder: (ctx) {
                      final parts = profile.name
                          .trim()
                          .split(RegExp(r'\s+'))
                          .where((p) => p.trim().isNotEmpty)
                          .toList(growable: false);
                      final hasLastName = parts.length >= 2;
                      if (!hasLastName) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 12.0 + _leadingWidth + 8.0,
                          bottom: 12.0,
                        ),
                        child: Align(
                          alignment: isRtl
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Text(
                            l10n.getString('profileLastNameNotDisplayed'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey.shade600),
                          ),
                        ),
                      );
                    },
                  ),
                ],

                if (canEditDob)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: ListTile(
                      leading: const Icon(Icons.cake_outlined),
                      title: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(l10n.getString('profileBirthday')),
                          ),
                          const Text(
                            ' *',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Builder(
                        builder: (context) {
                          if (_dobController.text.isEmpty) {
                            return Text(l10n.getString('profileNotSet'));
                          }
                          try {
                            final dt = DateFormat(
                              'yyyy-MM-dd',
                            ).parse(_dobController.text);
                            return Text(_formatDateWithL10n(dt, l10n));
                          } catch (_) {
                            // Ignore invalid date format
                            return Text(_dobController.text);
                          }
                        },
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IgnorePointer(
                            child: statusPillForField('date_of_birth'),
                          ),
                          const SizedBox(width: 10),
                          const Icon(Icons.calendar_today_outlined),
                        ],
                      ),
                      onTap: () async {
                        final before = _dobController.text;
                        await _selectDate(context);
                        if (_dobController.text != before) {
                          markApprovedSeenOnEdit('date_of_birth');
                        }
                      },
                    ),
                  )
                else
                  _alignedLockedCard(
                    l10n: l10n,
                    leadingIcon: const Icon(Icons.cake_outlined, size: 22),
                    title: l10n.getString('profileBirthday'),
                    subtitle: profile.dateOfBirth != null
                        ? _formatDateWithL10n(profile.dateOfBirth!, l10n)
                        : l10n.getString('profileNotSet'),
                    onTapPadlock: () => _openRequestDialogForField(
                      context,
                      profile,
                      'date_of_birth',
                      l10n.getString('profileBirthday'),
                    ),
                    statusIndicator: IgnorePointer(
                      child: statusPillForField('date_of_birth'),
                    ),
                  ),

                Builder(
                  builder: (ctx) {
                    DateTime? resolvedDob;
                    if (profile.dateOfBirth != null) {
                      resolvedDob = profile.dateOfBirth;
                    } else if (_dobController.text.isNotEmpty) {
                      try {
                        resolvedDob = DateFormat(
                          'yyyy-MM-dd',
                        ).parse(_dobController.text);
                      } catch (_) {
                        // Ignore invalid date format
                        resolvedDob = null;
                      }
                    } else {
                      resolvedDob = null;
                    }

                    if (resolvedDob != null) {
                      final ageLabel = _ageLabelFor(l10n);
                      final age = _computeAge(resolvedDob);
                      final zodiacSign = calculateZodiacSign(resolvedDob);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsetsDirectional.only(
                              start: 12.0 + _leadingWidth + 8.0,
                              top: 8.0,
                            ),
                            child: Align(
                              alignment: isRtl
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Text(
                                '$ageLabel: $age',
                                style: TextStyle(color: Colors.green.shade700),
                              ),
                            ),
                          ),
                          if (zodiacSign != null)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 12.0 + _leadingWidth + 8.0,
                                top: 4.0,
                              ),
                              child: Align(
                                alignment: isRtl
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: Text(
                                  '${l10n.getString('profileZodiacSign')}: ${zodiacIcon(zodiacSign)} ${l10n.getString('zodiac${zodiacSign.capitalize()}')}',
                                  style: TextStyle(
                                    color: Colors.purple.shade500,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),

                const SizedBox(height: 12),

                if (canEditGender)
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                      side: BorderSide(color: Colors.grey.shade200),
                    ),
                    margin: const EdgeInsets.only(bottom: 14.0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 6.0,
                      ),
                      child: genderOptionsAsync.when(
                        data: (options) => DropdownButtonFormField<String>(
                          key: ValueKey('gender_${profile.gender}'),
                          initialValue: profile.gender?.isNotEmpty == true
                              ? profile.gender
                              : null,
                          decoration: InputDecoration(
                            labelText: '${l10n.getString('profileGender')} *',
                            prefixIcon: const Icon(Icons.wc_outlined),
                            border: InputBorder.none,
                            suffixIconConstraints: const BoxConstraints(
                              minHeight: 0,
                              minWidth: 0,
                            ),
                            suffixIcon: Padding(
                              padding: const EdgeInsetsDirectional.only(end: 8),
                              child: IgnorePointer(
                                child: statusPillForField('gender'),
                              ),
                            ),
                          ),
                          items:
                              (options
                                      .where(
                                        (g) => g['key'] != 'prefer_not_to_say',
                                      )
                                      .toList()
                                    ..sort((a, b) {
                                      final order = [
                                        'male',
                                        'female',
                                        'non_binary',
                                      ];
                                      final aKey = a['key']!;
                                      final bKey = b['key']!;
                                      final aIndex = order.indexOf(aKey);
                                      final bIndex = order.indexOf(bKey);
                                      if (aIndex == -1) return 1;
                                      if (bIndex == -1) return -1;
                                      return aIndex.compareTo(bIndex);
                                    }))
                                  .map((g) {
                                    final gKey = g['key']!;
                                    final displayKey = g['displayKey']!;
                                    return DropdownMenuItem<String>(
                                      value: gKey,
                                      child: Text(
                                        localResolve(displayKey),
                                        maxLines: 2,
                                        overflow: TextOverflow.visible,
                                      ),
                                    );
                                  })
                                  .toList(),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? l10n.getString('profileEditGenderRequired')
                              : null,
                          onChanged: (value) {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateGender(value);
                            markApprovedSeenOnEdit('gender');
                          },
                        ),
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (e, s) => Text(l10n.getString('generalError')),
                      ),
                    ),
                  )
                else
                  _alignedLockedCard(
                    l10n: l10n,
                    leadingIcon: const Icon(Icons.wc_outlined, size: 22),
                    title: l10n.getString('profileGender'),
                    subtitle: _genderLabelFor(profile.gender, l10n),
                    onTapPadlock: () => _openRequestDialogForField(
                      context,
                      profile,
                      'gender',
                      l10n.getString('profileGender'),
                    ),
                    statusIndicator: IgnorePointer(
                      child: statusPillForField('gender'),
                    ),
                  ),

                // Informational note placed below the Gender field; sourced from Supabase translations with code fallback.
                if (!canEditName || !canEditGender || !canEditDob)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0, bottom: 12.0),
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12.0),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(
                          l10n.getString('profileBasicsLockedNoteTitle'),
                        ),
                        subtitle: Text(
                          l10n.getString('profileBasicsLockedNoteBody'),
                        ),
                        onTap: () {
                          showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(
                                l10n.getString('profileBasicsLockedNoteTitle'),
                              ),
                              content: Text(
                                l10n.getString('profileBasicsLockedNoteBody'),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(),
                                  child: Text(l10n.getString('generalClose')),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Text(
            l10n.getString('profileAgeRequirementNote'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),

          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildDetailsPage(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile? profile,
  ) {
    if (profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final usesImperialUnits = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final hasRomanticIntent = profile.activeModes.any(
      (m) => _normalizeKey(m) == 'romantic',
    );
    final hasBusinessIntent = profile.activeModes.any(
      (m) => _isBusinessIntentKey(m),
    );
    if (!_heightUnitModeInitialized) {
      _heightUnitMode = usesImperialUnits ? 1 : 0;
      _heightUnitModeInitialized = true;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileWizardDetailsTitle'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.shade50,
                child: const Icon(Icons.info, color: Colors.blue),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileWizardDetailsSubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n),
          const SizedBox(height: 20),

          // Bio editor
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.0),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _optionalFieldLabel(l10n, 'profileEditShortBio'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _bioController,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                    maxLength: 300,
                    maxLines: 4,
                    textDirection: _getBioTextDirection(),
                    textAlign: _getBioTextAlign(),
                    decoration: InputDecoration(
                      hintText: l10n.getString('profileEditShortBioHint'),
                    ),
                    onChanged: (val) {
                      ref
                          .read(profileEditProvider(widget.user.id).notifier)
                          .updateBio(val.trim());
                      // Update text direction and alignment based on new text
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),

          // Height field — only for Romantic intent, optional
          if (hasRomanticIntent)
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
                side: BorderSide(color: Colors.grey.shade200),
              ),
              margin: const EdgeInsets.only(bottom: 14.0),
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _optionalFieldLabel(l10n, 'profileEditHeight'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.getString('profileWizardHeightOptionalNote'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        SegmentedButton<int>(
                          segments: [
                            ButtonSegment(
                              value: 0,
                              label: Text(
                                l10n.getString('profileHeightUnitCm'),
                              ),
                            ),
                            ButtonSegment(
                              value: 1,
                              label: Text(
                                l10n.getString('profileHeightUnitFeet'),
                              ),
                            ),
                          ],
                          selected: {_heightUnitMode},
                          onSelectionChanged: (Set<int> newSelection) {
                            final nextMode = newSelection.first;
                            setState(() {
                              _heightUnitMode = nextMode;
                            });
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateHeightUnit(nextMode == 1 ? 'ft' : 'cm');
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_heightUnitMode == 0)
                      TextFormField(
                        controller: _heightController,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [],
                        ),
                        keyboardType: TextInputType.number,
                        maxLength: 3,
                        decoration: InputDecoration(
                          hintText: l10n.getString('profileEditHeightHint'),
                          suffixText: l10n.getString('profileHeightCm'),
                        ),
                        onChanged: (val) {
                          final trimmed = val.trim();
                          if (trimmed.isEmpty) {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateHeight(null);
                            setState(() {});
                            return;
                          }
                          final parsed = int.tryParse(trimmed);
                          if (parsed != null &&
                              parsed >= 100 &&
                              parsed <= 250) {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateHeight(parsed);
                          }
                          setState(() {});
                        },
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _heightFeetController,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFeatures: const []),
                              keyboardType: TextInputType.number,
                              maxLength: 2,
                              decoration: InputDecoration(
                                hintText: l10n.getString('profileHeightFeet'),
                                suffixText: l10n.getString(
                                  'profileHeightUnitFeet',
                                ),
                              ),
                              onChanged: (val) {
                                _convertFeetInchesToCm();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _heightInchesController,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontFeatures: const []),
                              keyboardType: TextInputType.number,
                              maxLength: 2,
                              decoration: InputDecoration(
                                hintText: l10n.getString('profileHeightInches'),
                                suffixText: l10n.getString(
                                  'profileHeightUnitInches',
                                ),
                              ),
                              onChanged: (val) {
                                _convertFeetInchesToCm();
                              },
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

          // Occupation field — mandatory for Business/Networking intent
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.0),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        hasBusinessIntent
                            ? l10n.getString('profileEditOccupation')
                            : _optionalFieldLabel(l10n, 'profileEditOccupation'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (hasBusinessIntent)
                        const Text(
                          ' *',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _occupationController,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontFeatures: const []),
                    decoration: InputDecoration(
                      hintText: l10n.getString('profileEditOccupationHint'),
                    ),
                    onChanged: (val) {
                      ref
                          .read(profileEditProvider(widget.user.id).notifier)
                          .updateOccupation(val.trim());
                    },
                  ),
                ],
              ),
            ),
          ),

          // Education dropdown — mandatory for Business/Networking intent
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.0),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        hasBusinessIntent
                            ? l10n.getString('profileEditEducation')
                            : _optionalFieldLabel(l10n, 'profileEditEducation'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (hasBusinessIntent)
                        const Text(
                          ' *',
                          style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Consumer(
                    builder: (context, ref, _) {
                      final currentEducation = ref
                          .watch(profileEditProvider(widget.user.id))
                          .value
                          ?.education;
                      final normalizedEducation = switch (currentEducation) {
                        'Associate' => 'Associate Degree',
                        'Bachelor' => "Bachelor's Degree",
                        'Master' => "Master's Degree",
                        'PhD' => 'Doctorate (PhD)',
                        _ => currentEducation,
                      };
                      final educationOptions =
                          ref
                              .watch(
                                fieldOptionsProvider((
                                  fieldKey: 'education',
                                  context: 'profile',
                                )),
                              )
                              .asData
                              ?.value ??
                          const [];
                      return DropdownButtonFormField<String>(
                        initialValue: normalizedEducation,
                        decoration: InputDecoration(
                          hintText: l10n.getString('profileEditEducationHint'),
                        ),
                        items: educationOptions
                            .map(
                              (option) => DropdownMenuItem<String>(
                                value: option.profileValue ?? '',
                                child: Text(
                                  _tryGetString(
                                        l10n,
                                        option.profileDisplayKey,
                                      ) ??
                                      option.profileValue ??
                                      '',
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (val) {
                          ref
                              .read(
                                profileEditProvider(widget.user.id).notifier,
                              )
                              .updateEducation(val);
                          setState(() {});
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          ),

          // Languages known section
          _buildLanguagesEditorSection(profile, l10n),

          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildPhotosPage(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileWizardPhotosTitle'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.pink.shade50,
                child: const Icon(
                  Icons.photo_camera_outlined,
                  color: Colors.pink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileWizardDetailsSubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          Text(
            l10n.getString('profileWizardPhotosRequiredNote'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 20),
          _buildPhotoEditorSection(profile),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  final _linkedinController = TextEditingController();
  final _instagramController = TextEditingController();
  final _facebookController = TextEditingController();

  Widget _buildSocialLinksSection(UserProfile profile, LocalizationState l10n) {
    final hasBusinessIntent = profile.activeModes.any(
      (m) => _normalizeKey(m) == 'business_networking',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Instagram - for all users
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          margin: const EdgeInsets.only(bottom: 14.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _optionalFieldLabel(l10n, 'profileInstagramUrl'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Directionality(
                  textDirection: ui.TextDirection.ltr,
                  child: Row(
                    children: [
                      Text(
                        'https://instagram.com/',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey.shade500,
                          fontFeatures: const [],
                        ),
                      ),
                      Expanded(
                        child: TextFormField(
                          controller: _instagramController,
                          textDirection: ui.TextDirection.ltr,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontFeatures: const []),
                          keyboardType: TextInputType.text,
                          decoration: InputDecoration(
                            hintText: 'yourusername',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateInstagramUrl(
                                  _constructInstagramUrl(val),
                                );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // Facebook - for all users
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12.0),
            side: BorderSide(color: Colors.grey.shade200),
          ),
          margin: const EdgeInsets.only(bottom: 14.0),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _optionalFieldLabel(l10n, 'profileFacebookUrl'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Directionality(
                  textDirection: ui.TextDirection.ltr,
                  child: Row(
                    children: [
                      Text(
                        'https://facebook.com/',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey.shade500,
                          fontFeatures: const [],
                        ),
                      ),
                      Expanded(
                        child: TextFormField(
                          controller: _facebookController,
                          textDirection: ui.TextDirection.ltr,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontFeatures: const []),
                          keyboardType: TextInputType.text,
                          decoration: InputDecoration(
                            hintText: 'yourusername',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            ref
                                .read(
                                  profileEditProvider(widget.user.id).notifier,
                                )
                                .updateFacebookUrl(_constructFacebookUrl(val));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        // LinkedIn - only for business/networking intent
        if (hasBusinessIntent)
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12.0),
              side: BorderSide(color: Colors.grey.shade200),
            ),
            margin: const EdgeInsets.only(bottom: 14.0),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _optionalFieldLabel(l10n, 'profileLinkedinUrl'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Directionality(
                    textDirection: ui.TextDirection.ltr,
                    child: Row(
                      children: [
                        Text(
                          'https://linkedin.com/in/',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Colors.grey.shade500,
                                fontFeatures: const [],
                              ),
                        ),
                        Expanded(
                          child: TextFormField(
                            controller: _linkedinController,
                            textDirection: ui.TextDirection.ltr,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontFeatures: const []),
                            keyboardType: TextInputType.text,
                            decoration: InputDecoration(
                              hintText: 'yourprofile',
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              isDense: true,
                            ),
                            onChanged: (val) {
                              ref
                                  .read(
                                    profileEditProvider(
                                      widget.user.id,
                                    ).notifier,
                                  )
                                  .updateLinkedinUrl(
                                    _constructLinkedinUrl(val),
                                  );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSocialLinksPage(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileSocialLinks'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.shade50,
                child: const Icon(Icons.link, color: Colors.blue),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileSocialLinksSubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n, allOptional: true),
          const SizedBox(height: 20),
          _buildSocialLinksSection(profile, l10n),
          const SizedBox(height: 60),
        ],
      ),
    );
  }

  IconData _getIconForIntent(String intentKey) {
    switch (_normalizeKey(intentKey)) {
      case 'romantic':
        return Icons.favorite_border;
      case 'friendship':
        return Icons.people_outline;
      case 'activity_partner':
        return Icons.fitness_center;
      case 'business_networking':
        return Icons.business_center_outlined;
      default:
        return Icons.explore_outlined;
    }
  }

  Widget _buildMainIntentsPage(
    BuildContext ctx,
    UserProfile profile,
    LocalizationState l10n,
    bool isRtl,
  ) {
    final allIntentsAsync = ref.watch(allIntentsProvider);
    final intents = ref.watch(mainIntentsProvider);

    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileEditIntentsTitle'),
                  style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.pink.shade50,
                child: const Icon(Icons.star, color: Colors.pink),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.getString('profileEditIntentsSubtitle'),
            style: Theme.of(
              ctx,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n),
          const SizedBox(height: 20),
          if (allIntentsAsync.isLoading)
            const Center(child: CircularProgressIndicator()),
          if (!allIntentsAsync.isLoading && intents.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24.0),
              child: Center(
                child: Text(l10n.getString('profileWizardNoIntents')),
              ),
            ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: intents.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 1,
              mainAxisExtent: 92,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemBuilder: (context, index) {
              final intent = intents[index];
              final key = intent.key;
              final displayKey = intent.translationKey;
              final bool selected = profile.activeModes.any(
                (m) => _normalizeKey(m) == _normalizeKey(key),
              );
              final icon = _getIconForIntent(key);
              return GestureDetector(
                onTap: () => ref
                    .read(profileEditProvider(widget.user.id).notifier)
                    .toggleIntent(key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  decoration: BoxDecoration(
                    color: selected
                        ? Theme.of(
                            ctx,
                          ).colorScheme.primary.withValues(alpha: 0.14)
                        : Theme.of(ctx).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12.0),
                    border: Border.all(
                      color: selected
                          ? Theme.of(ctx).colorScheme.primary
                          : Colors.grey.shade200,
                      width: selected ? 2 : 1,
                    ),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: Theme.of(
                                ctx,
                              ).colorScheme.primary.withValues(alpha: 0.06),
                              blurRadius: 8.0,
                            ),
                          ]
                        : null,
                  ),
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: selected
                            ? Theme.of(
                                ctx,
                              ).colorScheme.primary.withValues(alpha: 0.18)
                            : Colors.grey.shade100,
                        child: Icon(
                          icon,
                          color: selected
                              ? Theme.of(ctx).colorScheme.primary
                              : Colors.grey.shade700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AutoSizeText(
                          localResolve(displayKey),
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            fontSize: 14,
                          ),
                          minFontSize: 10,
                          maxLines: 2,
                          wrapWords: false,
                        ),
                      ),
                      Checkbox(
                        value: selected,
                        onChanged: (_) => ref
                            .read(profileEditProvider(widget.user.id).notifier)
                            .toggleIntent(key),
                        activeColor: Theme.of(ctx).colorScheme.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  List<Widget> _buildWizardPages(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
    List<AppIntent> allIntents,
    List<AppInterest> allInterests,
  ) {
    // Only show main intents on the main intent selection page
    final mainIntents = ref.watch(mainIntentsProvider);
    final selectedMainIntents = _getSelectedIntents(ref, profile, mainIntents);
    final pages = <Widget>[];

    // ── Step 1: Main Intents (why you're here) ──
    pages.add(_buildMainIntentsPage(context, profile, l10n, isRtl));

    // For each selected main intent, add a sub-intent selection page
    for (final intent in selectedMainIntents) {
      pages.add(_buildSubIntentsPage(context, intent, profile, l10n, isRtl));
    }

    // ── Step 2: About You (basic identity) ──
    pages.add(_buildBasicsPage(context, l10n, isRtl, profile));

    // ── Step 3: Details (bio, height, occupation, education, languages) ──
    pages.add(_buildDetailsPage(context, l10n, isRtl, profile));

    // ── Step 4: Photos ──
    pages.add(_buildPhotosPage(context, l10n, isRtl, profile));

    // ── Step 5: Interests ──
    // Add personal interests page if any social intent is selected
    final hasSocialIntent = profile.activeModes.any(
      (m) => !_isBusinessIntentKey(m),
    );
    if (hasSocialIntent) {
      pages.add(_buildPersonalInterestsPage(context, l10n, isRtl, profile));
    }

    // Add business interests page if business/networking intent is selected
    final hasBusinessIntent = profile.activeModes.any(
      (m) => _isBusinessIntentKey(m),
    );
    if (hasBusinessIntent) {
      pages.add(
        _buildInterestPageForIntent(
          context,
          selectedMainIntents.firstWhere((i) => _isBusinessIntentKey(i.key)),
          profile,
          l10n,
          isRtl,
        ),
      );
    }

    // ── Step 6: My Profile ──
    final hasRomanticIntent = profile.activeModes.any(
      (m) => _normalizeKey(m) == 'romantic',
    );

    // Lifestyle page — shown if any social intent is selected
    if (hasSocialIntent) {
      pages.add(
        LifestyleWizardPage(profile: profile, l10n: l10n, isRtl: isRtl),
      );
    }

    // Family page — shown only if romantic intent is selected
    if (hasRomanticIntent) {
      pages.add(FamilyWizardPage(profile: profile, l10n: l10n, isRtl: isRtl));
    }

    // Religion page — shown if romantic or friendship intent is selected
    final hasReligionIntent = profile.activeModes.any((m) {
      final key = _normalizeKey(m);
      return key == 'romantic' || key == 'friendship';
    });
    if (hasReligionIntent) {
      pages.add(ReligionWizardPage(profile: profile, l10n: l10n, isRtl: isRtl));
    }

    // ── Step 7: Match Preferences (what I want in a match) ──
    pages.add(
      UnifiedMatchPreferencesWizardPage(
        profile: profile,
        selectedIntents: selectedMainIntents,
        l10n: l10n,
        isRtl: isRtl,
      ),
    );

    // ── Step 8: Social Links ──
    pages.add(_buildSocialLinksPage(context, l10n, isRtl, profile));

    // Compute diffs and check for changes
    final diffs = _computeDiffs(_originalSnapshot, profile);
    bool hasChanges =
        _isSaving; // Force hasChanges during save to prevent page list changes
    if (!hasChanges) {
      // Only count a basic-field diff if the "to" value is meaningful
      if (diffs['name'] != null) {
        final toName = ((diffs['name'] as Map)['to'] as String?)
            ?.trim()
            .toLowerCase();
        if (toName != null &&
            toName.isNotEmpty &&
            toName != 'unnamed' &&
            toName != 'unknown user') {
          hasChanges = true;
        }
      }
      if (diffs['dateOfBirth'] != null) {
        final toDob = (diffs['dateOfBirth'] as Map)['to'] as String?;
        if (toDob != null && toDob.isNotEmpty) {
          hasChanges = true;
        }
      }
      if (diffs['gender'] != null) {
        final toGender = ((diffs['gender'] as Map)['to'] as String?)?.trim();
        if (toGender != null && toGender.isNotEmpty) {
          hasChanges = true;
        }
      }
      if ((diffs['intentsAdded'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['intentsRemoved'] as List).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['subIntentsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsAdded'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['interestsRemoved'] as Map).isNotEmpty) hasChanges = true;
      if ((diffs['languagesChanged'] as Map).isNotEmpty) hasChanges = true;
      if (diffs['bioChanged'] != null) {
        final toBio = (diffs['bioChanged'] as Map)['to']?.toString().trim();
        if (toBio != null && toBio.isNotEmpty) {
          hasChanges = true;
        }
      }
      if (diffs['photosChanged'] != null) {
        final m = diffs['photosChanged'] as Map;
        final fromPhotos = (m['from'] as List?)?.cast<String>() ?? [];
        final toPhotos = (m['to'] as List?)?.cast<String>() ?? [];
        if (toPhotos.where((p) => !fromPhotos.contains(p)).isNotEmpty ||
            fromPhotos.where((p) => !toPhotos.contains(p)).isNotEmpty) {
          hasChanges = true;
        }
      }
      if (diffs['instagramChanged'] != null) {
        final toVal = ((diffs['instagramChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['linkedinChanged'] != null) {
        final toVal = ((diffs['linkedinChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['facebookChanged'] != null) {
        final toVal = ((diffs['facebookChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['heightChanged'] != null) {
        final toVal = (diffs['heightChanged'] as Map)['to'] as int?;
        if (toVal != null) hasChanges = true;
      }
      if (diffs['heightUnitChanged'] != null) {
        final toVal = (diffs['heightUnitChanged'] as Map)['to']?.toString();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['occupationChanged'] != null) {
        final toVal = ((diffs['occupationChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['educationChanged'] != null) {
        final toVal = ((diffs['educationChanged'] as Map)['to'] as String?)
            ?.trim();
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['lifestyleChanged'] != null) {
        final toVal = (diffs['lifestyleChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['familyChanged'] != null) {
        final toVal = (diffs['familyChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['religionChanged'] != null) {
        final toVal = (diffs['religionChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['genderPreferencesChanged'] != null) {
        final toVal = (diffs['genderPreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['agePreferencesChanged'] != null) {
        final toVal = (diffs['agePreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['lifestyleFiltersChanged'] != null) {
        final toVal = (diffs['lifestyleFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['familyFiltersChanged'] != null) {
        final toVal = (diffs['familyFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['religionFiltersChanged'] != null) {
        final toVal = (diffs['religionFiltersChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
      if (diffs['heightPreferencesChanged'] != null) {
        final toVal = (diffs['heightPreferencesChanged'] as Map)['to'] as Map?;
        if (toVal != null && toVal.isNotEmpty) hasChanges = true;
      }
    }

    // Add a final page for submission only if there are changes.
    // For the initial (new-signup) wizard the page list must stay stable:
    // toggling the review page on/off flips the social page between
    // last/second-last (Save vs Next) and desyncs _currentPageIndex from
    // the PageController after a permission pause/resume — the reported
    // "stuck on social accounts, Save does nothing" state. New users
    // therefore always get the review page; edits keep the conditional.
    final bool stableReviewForNewUser = !widget.isEditing;
    if (hasChanges || stableReviewForNewUser) {
      final allIntentsMap = <String, String>{
        for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
          i.key: i.translationKey,
      };
      final interestKeyToDisplayKey = ref.read(interestDisplayMapProvider);
      final categoryKeyToDisplayKey = ref.read(categoryDisplayMapProvider);
      pages.add(
        _buildFinalReview(
          context,
          ref,
          [],
          profile,
          l10n,
          isRtl,
          allIntentsMap,
          interestKeyToDisplayKey,
          categoryKeyToDisplayKey,
        ),
      );
    }

    return pages;
  }

  Widget _buildSubIntentsPage(
    BuildContext ctx,
    AppIntent intent,
    UserProfile profile,
    LocalizationState l10n,
    bool isRtl,
  ) {
    final subIntents = ref.watch(subIntentsProvider(intent.id));

    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    return Column(
      children: [
        // Sticky header section
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 20.0,
          ).copyWith(top: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      localResolve(intent.translationKey),
                      style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: Colors.grey.shade100,
                    child: Icon(_getIconForIntent(intent.key)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                l10n.getString(
                  'profileSelectSubIntentsMinMax',
                  params: {'min': '$_minSubIntents', 'max': '$_maxSubIntents'},
                ),
                style: Theme.of(
                  ctx,
                ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (_) {
                  final selectedCount =
                      profile.subIntents[intent.key]?.length ?? 0;
                  final atMax = selectedCount >= _maxSubIntents;
                  return Text(
                    l10n.getString(
                      'profileCounterSelected',
                      params: {
                        'count': '$selectedCount',
                        'max': '$_maxSubIntents',
                      },
                    ),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: atMax ? Colors.orange.shade700 : Colors.green,
                      fontWeight: atMax ? FontWeight.bold : FontWeight.normal,
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        // Scrollable content
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            children: [
              if (subIntents.isEmpty)
                Text(
                  localResolve('profileEditNoSubIntents'),
                  style: Theme.of(
                    ctx,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                ),
              ...subIntents.map((sub) {
                final selected =
                    profile.subIntents[intent.key]?.contains(sub.key) ?? false;
                final label = localResolve(sub.translationKey);
                return Card(
                  elevation: selected ? 2 : 0,
                  shape: selected
                      ? RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.0),
                          side: BorderSide(
                            color: Theme.of(ctx).colorScheme.primary,
                            width: 2,
                          ),
                        )
                      : RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.0),
                          side: BorderSide(color: Colors.grey.shade200),
                        ),
                  margin: const EdgeInsets.only(bottom: 12.0),
                  child: ListTile(
                    leading: _leadingCheckbox(
                      loading: false,
                      value: selected,
                      onChanged: (_) => _toggleSubIntentWithMaxCheck(
                        intent,
                        sub.key,
                        selected,
                      ),
                    ),
                    title: AutoSizeText(
                      label,
                      minFontSize: 10,
                      maxLines: 2,
                      wrapWords: false,
                    ),
                    selected: selected,
                    onTap: () =>
                        _toggleSubIntentWithMaxCheck(intent, sub.key, selected),
                  ),
                );
              }),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInterestPageForIntent(
    BuildContext ctx,
    AppIntent intent,
    UserProfile profile,
    LocalizationState l10n,
    bool isRtl,
  ) {
    final categories = ref.watch(
      nonSharedInterestCategoriesByKeyProvider('business_networking'),
    );

    final allIntentsMap = <String, String>{
      for (var i in ref.read(allIntentsProvider).asData?.value ?? [])
        i.key: i.translationKey,
    };
    final interestDisplayMap = ref.read(interestDisplayMapProvider);
    final categoryDisplayMap = ref.read(categoryDisplayMapProvider);
    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestDisplayMap,
      categoryKeyToDisplayKey: categoryDisplayMap,
    );

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Column(
        children: [
          // Sticky header section
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20.0,
            ).copyWith(top: 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.getString('profileInterests'),
                        style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Colors.teal.shade50,
                      child: const Icon(
                        Icons.business_center,
                        color: Colors.teal,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.getString('profileInterestsHelper'),
                  style: Theme.of(
                    ctx,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                ),
                _WizardFieldLegend(l10n: l10n),
                const SizedBox(height: 8),
                Builder(
                  builder: (_) {
                    final selectedCount = profile.businessInterests.length;
                    final atMax = selectedCount >= _maxBusinessMainInterests;
                    return Text(
                      l10n.getString(
                        'profileCounterSelected',
                        params: {
                          'count': '$selectedCount',
                          'max': '$_maxBusinessMainInterests',
                        },
                      ),
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: atMax ? Colors.orange.shade700 : Colors.green,
                        fontWeight: atMax ? FontWeight.bold : FontWeight.normal,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                _buildInterestSearchField(
                  controller: _searchBusinessInterestController,
                  l10n: l10n,
                  onClear: _clearBusinessInterestSearch,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          // Scrollable content
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              children: [
                if (categories.isEmpty &&
                    _businessInterestSearchQuery.trim().isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16.0),
                    child: Text(
                      localResolve('profileEditNoInterests'),
                      style: Theme.of(
                        ctx,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                    ),
                  ),

                ...() {
                  final trimmedQuery = _businessInterestSearchQuery.trim();
                  final isSearching = trimmedQuery.isNotEmpty;
                  final allInterestsFlat =
                      ref.read(allInterestsProvider).asData?.value ?? [];
                  final sortedCats = List<AppInterest>.from(categories)
                    ..sort((a, b) => a.key.compareTo(b.key));
                  final List<AppInterest> visibleCats = isSearching
                      ? sortedCats
                            .where(
                              (cat) => _interestOrDescendantMatches(
                                cat,
                                trimmedQuery,
                                localResolve,
                                allInterestsFlat,
                              ),
                            )
                            .toList()
                      : sortedCats;
                  if (isSearching && visibleCats.isEmpty) {
                    return <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 16.0),
                        child: Text(
                          l10n.getString('profileWizardSearchNoResults'),
                          style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                            color: Colors.black54,
                          ),
                        ),
                      ),
                    ];
                  }
                  return <Widget>[
                    ...visibleCats.map<Widget>((cat) {
                      final categoryKey = cat.key;
                      final prefLabel = localResolve(cat.translationKey);
                      final children = ref.watch(
                        interestChildrenProvider(cat.id),
                      );
                      final hasChildren = children.isNotEmpty;
                      final bool categorySelfMatches =
                          !isSearching ||
                          _matchesInterestQuery(
                            displayLabel: prefLabel,
                            interestKey: categoryKey,
                            query: trimmedQuery,
                          );
                      final bool isExpanded = isSearching
                          ? hasChildren
                          : _expandedInterestKeys.contains(categoryKey);
                      final String childQuery =
                          isSearching && categorySelfMatches
                          ? ''
                          : trimmedQuery;

                      // Check if category is selected
                      final isCategorySelected = profile.businessInterests
                          .containsKey(categoryKey);

                      void toggleCategory() {
                        final willSelect = !isCategorySelected;
                        if (willSelect) {
                          final selectedCount =
                              profile.businessInterests.length;
                          if (selectedCount >= _maxBusinessMainInterests) {
                            _showMaxMainInterestsSnack(isSocial: false);
                            return;
                          }
                        }
                        if (!willSelect && hasChildren) {
                          _deselectAllDescendants(
                            ref,
                            categoryKey,
                            categoryKey,
                            isBusiness: true,
                          );
                        }
                        ref
                            .read(profileEditProvider(widget.user.id).notifier)
                            .toggleInterest(
                              categoryKey,
                              categoryKey,
                              awaitPersist: false,
                              isBusiness: true,
                            );
                        if (hasChildren) {
                          setState(() {
                            if (willSelect) {
                              _expandedInterestKeys.add(categoryKey);
                            } else {
                              _expandedInterestKeys.remove(categoryKey);
                            }
                          });
                        }
                      }

                      return Card(
                        elevation: 0,
                        margin: const EdgeInsets.only(bottom: 12.0),
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12.0),
                          side: BorderSide(
                            color: Colors.grey.shade200,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: _leadingCheckbox(
                                loading: false,
                                value: isCategorySelected,
                                onChanged: (_) => toggleCategory(),
                              ),
                              title: Text(
                                prefLabel,
                                style: Theme.of(ctx).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              onTap: () => toggleCategory(),
                              trailing: hasChildren
                                  ? IconButton(
                                      icon: Icon(
                                        isExpanded
                                            ? Icons.expand_less_rounded
                                            : Icons.expand_more_rounded,
                                      ),
                                      onPressed: () =>
                                          _toggleInterestExpanded(categoryKey),
                                    )
                                  : null,
                            ),
                            if (hasChildren && isExpanded)
                              Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16.0,
                                      8.0,
                                      16.0,
                                      4.0,
                                    ),
                                    child: Builder(
                                      builder: (_) {
                                        final subCount =
                                            profile
                                                .businessInterests[categoryKey]
                                                ?.where((k) => k != categoryKey)
                                                .length ??
                                            0;
                                        final atMax =
                                            subCount >= _maxSubInterestsPer;
                                        return Text(
                                          l10n.getString(
                                            'profileCounterSelected',
                                            params: {
                                              'count': '$subCount',
                                              'max': '$_maxSubInterestsPer',
                                            },
                                          ),
                                          style: Theme.of(ctx)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: atMax
                                                    ? Colors.orange.shade700
                                                    : Colors.green,
                                                fontWeight: atMax
                                                    ? FontWeight.bold
                                                    : FontWeight.normal,
                                              ),
                                        );
                                      },
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16.0,
                                      0,
                                      16.0,
                                      8.0,
                                    ),
                                    child: _buildInterestTree(
                                      ctx,
                                      ref,
                                      children,
                                      categoryKey,
                                      profile,
                                      l10n,
                                      const <String>{},
                                      isBusiness: true,
                                      searchQuery: childQuery,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      );
                    }),
                  ];
                }(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _photoUploadFailureMessage(LocalizationState l10n, Object error) {
    final msg = error.toString();
    const geminiMarker = 'Exception: GEMINI_MSG:';
    final geminiIdx = msg.indexOf(geminiMarker);
    if (geminiIdx != -1) {
      return msg.substring(geminiIdx + geminiMarker.length);
    }
    if (msg.startsWith('Exception: secondaryPhotoVerificationError')) {
      return l10n.getString(msg.substring('Exception: '.length));
    }
    final errorKey = ErrorLocalizationService.getErrorTranslationKey(error);
    if (errorKey == 'authUnexpectedError') {
      return msg.startsWith('Exception: ')
          ? msg.substring('Exception: '.length)
          : msg;
    }
    return l10n.getString(errorKey);
  }

  /// Shows what went wrong with a rejected photo: when the error carries the
  /// structured moderation result and the photo bytes are available, a rich
  /// dialog with the photo, highlighted problem regions, and the AI's message;
  /// otherwise the plain text-only dialog.
  void _showPhotoRejection(Object error, {Uint8List? photoBytes}) {
    if (!mounted || !context.mounted) return;
    final l10n = ref.read(localizationProvider);
    if (error is PhotoModerationRejection &&
        photoBytes != null &&
        photoBytes.isNotEmpty) {
      unawaited(
        showPhotoRejectionDialog(
          context: context,
          rejection: error,
          l10n: l10n,
          photoBytes: photoBytes,
        ),
      );
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Text(_photoUploadFailureMessage(l10n, error)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.getString('generalOk')),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAddPhoto() async {
    final l10n = ref.read(localizationProvider);

    // Voice guidance + early exit when the photo limit is already reached.
    final photosAtEntry =
        ref
            .read(profileEditProvider(widget.user.id))
            .asData
            ?.value
            ?.photos
            .length ??
        0;
    if (photosAtEntry >= 5) {
      unawaited(
        VoiceGuidanceService.instance.speakKey('voiceGuidancePhotosMaxReached'),
      );
      return;
    }

    final ImageSource? source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(l10n.getString('profileWizardAddPhotoFromGallery')),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: Text(l10n.getString('profileWizardAddPhotoFromCamera')),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(l10n.getString('generalCancel')),
                onTap: () => Navigator.pop(context, null),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (!mounted) return;

    if (source == null) {
      return;
    }

    setState(() => _isLoading = true);

    Uint8List? bytes;
    try {
      // Determine if this is a primary photo (first photo or currently marked as primary)
      final profile = ref
          .read(profileEditProvider(widget.user.id))
          .asData
          ?.value;
      final currentPhotos = profile?.photos ?? [];
      final isPrimaryPhoto = currentPhotos.isEmpty; // First photo is primary

      bytes = await PhotoEditor.pickAndEdit(
        context: context,
        source: source,
        preparingMessage: l10n.getString('profileWizardPhotoPreparing'),
        isPrimaryPhoto: isPrimaryPhoto,
        ref: ref,
        existingHashes: _sessionPhotoHashByPath.values.toSet(),
      );
    } catch (e) {
      if (mounted) {
        if (!context.mounted) {
          setState(() => _isLoading = false);
          return;
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            content: Text('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.getString('generalOk')),
              ),
            ],
          ),
        );
      }
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (bytes == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    if (mounted) {
      PleaseWaitDialog.show(
        context,
        message: l10n.getString('profileWizardPhotoUploading'),
      );
      try {
        final photosBefore =
            ref
                .read(profileEditProvider(widget.user.id))
                .asData
                ?.value
                ?.photos
                .length ??
            0;
        await ref
            .read(profileEditProvider(widget.user.id).notifier)
            .addPhotoFromBytesDraft(bytes);
        final photosAfter = ref
            .read(profileEditProvider(widget.user.id))
            .asData
            ?.value
            ?.photos;
        if (photosAfter != null && photosAfter.length > photosBefore) {
          _sessionPhotoHashByPath[photosAfter.last] = md5
              .convert(bytes)
              .toString();
        }
        if (photosAfter != null && photosAfter.length > photosBefore) {
          unawaited(
            VoiceGuidanceService.instance.speakKey(
              photosAfter.length == 1
                  ? 'voiceGuidancePhotoPrimaryAdded'
                  : 'voiceGuidancePhotoAdded',
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isLoading = false);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !context.mounted) return;
          _showPhotoRejection(e, photoBytes: bytes);
        });
      } finally {
        if (mounted) {
          setState(() => _isLoading = false);
          PleaseWaitDialog.hide(context);
        }
      }
    }
  }

  Future<void> _handleEditPhoto(int index, String source) async {
    // Kept outside the try so the rejection dialog can overlay the boxes on
    // the exact bytes the user edited when moderation rejects them.
    Uint8List? editedBytes;
    try {
      setState(() => _isLoading = true);
      PleaseWaitDialog.show(context);

      String? imagePath = source;

      if (!source.startsWith('http://') && !source.startsWith('https://')) {
        imagePath = await StorageHelper.getSignedUrl(
          source,
          ttlSeconds: await (() async {
            try {
              return await AppConfigService().getInt(
                'profile.signed_url_short_ttl_seconds',
                defaultValue: 600,
              );
            } catch (e) {
              return 600;
            }
          })(),
        );
        if (imagePath == null) {
          throw Exception('Failed to create signed URL for editing.');
        }
      } else {
        final uri = Uri.tryParse(source);
        if (uri != null) {
          if (uri.queryParameters.containsKey('token') ||
              uri.query.contains('X-Amz-')) {
            imagePath = source;
          } else {
            final signed = await StorageHelper.getSignedUrl(
              source,
              ttlSeconds: await (() async {
                try {
                  return await AppConfigService().getInt(
                    'profile.signed_url_short_ttl_seconds',
                    defaultValue: 600,
                  );
                } catch (e) {
                  return 600;
                }
              })(),
            );
            if (signed != null && signed.isNotEmpty) {
              imagePath = signed;
            } else {
              imagePath = source;
            }
          }
        }
      }

      final photoService = ref.read(photoServiceProvider);
      final existing = await photoService.downloadImageBytes(imagePath);
      if (existing == null) {
        throw Exception('Failed to download image for editing.');
      }
      if (!context.mounted) return;
      final edited = await PhotoEditor.editWithPrescreen(
        context: context,
        bytes: existing,
        isPrimaryPhoto: index == 0,
        ref: ref,
      );
      if (edited == null) return;
      editedBytes = edited;
      await ref
          .read(profileEditProvider(widget.user.id).notifier)
          .replacePhotoAtIndexDraft(index, bytes: edited);
      _sessionPhotoHashByPath.remove(source);
      final photosAfter = ref
          .read(profileEditProvider(widget.user.id))
          .asData
          ?.value
          ?.photos;
      if (photosAfter != null && index < photosAfter.length) {
        _sessionPhotoHashByPath[photosAfter[index]] = md5
            .convert(edited)
            .toString();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !context.mounted) return;
        _showPhotoRejection(e, photoBytes: editedBytes);
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
        PleaseWaitDialog.hide(context);
      }
    }
  }

  Future<void> _handleRemovePhoto(int index) async {
    try {
      final photosBefore = ref
          .read(profileEditProvider(widget.user.id))
          .asData
          ?.value
          ?.photos;
      await ref
          .read(profileEditProvider(widget.user.id).notifier)
          .removePhotoAtDraft(index);
      if (photosBefore != null && index < photosBefore.length) {
        _sessionPhotoHashByPath.remove(photosBefore[index]);
        unawaited(
          VoiceGuidanceService.instance.speakKey('voiceGuidancePhotoRemoved'),
        );
      }
    } catch (e) {
      if (mounted && context.mounted) {
        final l10n = ref.read(localizationProvider);
        final msg = e.toString();
        const geminiMarker = 'Exception: GEMINI_MSG:';
        final geminiIdx = msg.indexOf(geminiMarker);
        String displayMsg;
        if (geminiIdx != -1) {
          displayMsg = msg.substring(geminiIdx + geminiMarker.length);
        } else {
          final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
          if (errorKey == 'authUnexpectedError') {
            displayMsg = msg.startsWith('Exception: ')
                ? msg.substring('Exception: '.length)
                : msg;
          } else {
            displayMsg =
                '${l10n.getString('profileWizardPhotoRemoveFailed')}: ${l10n.getString(errorKey)}';
          }
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            content: Text(displayMsg),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.getString('generalOk')),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _handleReorderPhotos(int oldIndex, int newIndex) async {
    PleaseWaitDialog.show(context);
    try {
      final notifier = ref.read(profileEditProvider(widget.user.id).notifier);
      await notifier.reorderPhotosDraft(oldIndex, newIndex);

      final p = ref.read(profileEditProvider(widget.user.id)).value;
      if (p != null &&
          p.photos.isNotEmpty &&
          (oldIndex == 0 || newIndex == 0)) {
        _schedulePrimaryPhotoValidation(p.photos.first);
      }
    } catch (e) {
      if (!mounted) return;
      // Defer the error dialog to the next frame so the PleaseWaitDialog
      // (closed in the finally block) is fully dismissed first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !context.mounted) return;
        final l10n = ref.read(localizationProvider);
        final msg = e.toString();
        const geminiMarker = 'Exception: GEMINI_MSG:';
        final geminiIdx = msg.indexOf(geminiMarker);
        String displayMsg;
        if (geminiIdx != -1) {
          displayMsg = msg.substring(geminiIdx + geminiMarker.length);
        } else {
          final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
          if (errorKey == 'authUnexpectedError') {
            displayMsg = msg.startsWith('Exception: ')
                ? msg.substring('Exception: '.length)
                : msg;
          } else {
            displayMsg =
                '${l10n.getString('profileWizardPhotoReorderFailed')}: ${l10n.getString(errorKey)}';
          }
        }
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            content: Text(displayMsg),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(l10n.getString('generalOk')),
              ),
            ],
          ),
        );
      });
    } finally {
      if (mounted) PleaseWaitDialog.hide(context);
    }
  }

  Widget _buildPhotoEditorSection(UserProfile profile) {
    final l10n = ref.read(localizationProvider);
    final photos = profile.photos;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.getString('profileWizardPhotosTitle'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(
                      l10n.getString('profileWizardPrimaryPhotoFaceOnlyTitle'),
                    ),
                    content: Text(
                      l10n.getString('profileWizardPrimaryPhotoFaceOnlyBody'),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(l10n.getString('generalClose')),
                      ),
                    ],
                  ),
                );
              },
              icon: const Icon(Icons.info_outline),
              tooltip: l10n.getString('profileWizardPrimaryPhotoFaceOnlyTitle'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildPhotoRulesCard(l10n, theme),
        const SizedBox(height: 12),
        _buildPhotoGrid(photos, l10n, theme),
        const SizedBox(height: 12),
        Text(
          l10n.getString('profileWizardPhotosTip'),
          style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
        ),
      ],
    );
  }

  /// Visual, icon-based photo requirements card (mirrors the verification
  /// screen's instructions style) so users see the rules before picking.
  Widget _buildPhotoRulesCard(LocalizationState l10n, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.rule_outlined,
                size: 22,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                l10n.getString('photoRulesTitle'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildPhotoRuleItem(
            Icons.face_retouching_natural,
            l10n.getString('photoRulePrimaryFace'),
            theme,
          ),
          const SizedBox(height: 8),
          _buildPhotoRuleItem(
            Icons.group_off_outlined,
            l10n.getString('photoRuleOnlyYou'),
            theme,
          ),
          const SizedBox(height: 8),
          _buildPhotoRuleItem(
            Icons.wb_sunny_outlined,
            l10n.getString('photoRuleClearPhoto'),
            theme,
          ),
          const SizedBox(height: 8),
          _buildPhotoRuleItem(
            Icons.phonelink_erase_outlined,
            l10n.getString('photoRuleRealPerson'),
            theme,
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoRuleItem(IconData icon, String text, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }

  Widget _buildPhotoGrid(
    List<String> photos,
    LocalizationState l10n,
    ThemeData theme,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final crossAxisCount = availableWidth > 560 ? 3 : 2;
        final gap = 12.0;
        final cardWidth =
            (availableWidth - gap * (crossAxisCount - 1)) / crossAxisCount;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (int i = 0; i < photos.length; i++)
              _buildPhotoCard(
                i: i,
                source: photos[i],
                cardWidth: cardWidth,
                l10n: l10n,
                theme: theme,
                photos: photos,
              ),
            if (photos.length < 5)
              _buildAddPhotoCard(cardWidth: cardWidth, l10n: l10n),
          ],
        );
      },
    );
  }

  Widget _buildPhotoCard({
    required int i,
    required String source,
    required double cardWidth,
    required LocalizationState l10n,
    required ThemeData theme,
    required List<String> photos,
  }) {
    return DragTarget<int>(
      key: ValueKey('target_$i'),
      onWillAcceptWithDetails: (details) {
        if (details.data != i) {
          setState(() => _dropTargetIndex = i);
          return true;
        }
        return false;
      },
      onLeave: (_) {
        if (_dropTargetIndex == i) setState(() => _dropTargetIndex = null);
      },
      onAcceptWithDetails: (details) {
        _handleReorderPhotos(details.data, i);
        setState(() => _dropTargetIndex = null);
      },
      builder: (context, candidateData, rejectedData) {
        final isTarget = _dropTargetIndex == i;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          transform: isTarget
              ? Matrix4.translationValues(0, -6, 0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: isTarget
                ? Border.all(color: theme.colorScheme.primary, width: 2.5)
                : null,
            boxShadow: isTarget
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withAlpha(60),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: LongPressDraggable<int>(
            data: i,
            delay: const Duration(milliseconds: 150),
            onDragEnd: (_) => setState(() => _dropTargetIndex = null),
            feedback: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: cardWidth,
                child: _buildPhotoCardBody(
                  i,
                  source,
                  cardWidth,
                  l10n,
                  theme,
                  photos,
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: SizedBox(
                width: cardWidth,
                child: _buildPhotoCardBody(
                  i,
                  source,
                  cardWidth,
                  l10n,
                  theme,
                  photos,
                ),
              ),
            ),
            child: SizedBox(
              width: cardWidth,
              child: _buildPhotoCardBody(
                i,
                source,
                cardWidth,
                l10n,
                theme,
                photos,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPhotoCardBody(
    int index,
    String source,
    double cardWidth,
    LocalizationState l10n,
    ThemeData theme,
    List<String> photos,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          explicitChildNodes: true,
          label: l10n.getString(
            'profilePhotoPreviewLabel',
            params: {'index': '${index + 1}'},
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                SignedImage(
                  source: source,
                  fit: BoxFit.cover,
                  width: cardWidth,
                  height: cardWidth * 1.15,
                  placeholder: Container(color: Colors.grey.shade100),
                  errorWidget: Container(
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.broken_image),
                  ),
                ),
                PositionedDirectional(
                  start: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Icon(
                      Icons.drag_indicator,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                ),
                if (index == 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      color: Colors.black54,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        l10n.getString('profileWizardPrimaryPhotoBadge'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                PositionedDirectional(
                  end: 6,
                  top: 6,
                  child: _buildIconCircle(
                    icon: Icons.edit_outlined,
                    size: 22,
                    color: Colors.white,
                    tooltip: l10n.getString('profileWizardEditPhotoAction'),
                    onTap: () => _handleEditPhoto(index, source),
                  ),
                ),
                PositionedDirectional(
                  // Bottom-end corner, lifted above the primary-photo badge
                  // on the first photo so the two never overlap.
                  end: 6,
                  bottom: index == 0 ? 30 : 6,
                  child: _buildIconCircle(
                    icon: Icons.delete_outline,
                    size: 22,
                    color: Colors.red.shade300,
                    tooltip: l10n.getString(
                      'profileWizardRemovePhotoAction',
                    ),
                    onTap: () => _confirmDeletePhoto(index, l10n),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildSmallActionButton(
              icon: Icons.chevron_left,
              label: l10n.getString('profileWizardMovePhotoEarlier'),
              onPressed: index > 0
                  ? () => _handleReorderPhotos(index, index - 1)
                  : null,
            ),
            const SizedBox(width: 4),
            _buildSmallActionButton(
              icon: Icons.chevron_right,
              label: l10n.getString('profileWizardMovePhotoLater'),
              onPressed: index < photos.length - 1
                  ? () => _handleReorderPhotos(index, index + 1)
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildIconCircle({
    required IconData icon,
    required double size,
    required Color color,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        padding: const EdgeInsets.all(10),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black45,
          foregroundColor: color,
          disabledForegroundColor: color.withValues(alpha: 0.4),
          shape: const CircleBorder(),
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(icon, size: size),
      ),
    );
  }

  Widget _buildSmallActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        padding: const EdgeInsets.all(12),
        style: IconButton.styleFrom(
          backgroundColor: Colors.grey.shade100,
          disabledBackgroundColor: Colors.grey.shade100.withValues(alpha: 0.3),
          foregroundColor: Colors.grey.shade700,
          disabledForegroundColor: Colors.grey.shade500,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(icon, size: 20),
      ),
    );
  }

  Widget _buildAddPhotoCard({
    required double cardWidth,
    required LocalizationState l10n,
  }) {
    final label = l10n.getString('profileWizardAddPhotoTooltip');
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: Material(
        color: Colors.grey.shade50,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade300, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _isLoading ? null : _handleAddPhoto,
          child: SizedBox(
            width: cardWidth,
            height: cardWidth * 1.15 + 30,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.add_a_photo_outlined,
                  size: 36,
                  color: Colors.grey.shade400,
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeletePhoto(int index, LocalizationState l10n) async {
    // A completed profile can never drop its last photo: removing it would
    // leave a photo-less profile behind as a draft (Back-out/exit persists
    // the draft unvalidated) and the user could then walk away from the
    // wizard entirely. Block the removal outright; the provider re-checks.
    final currentProfile = ref.read(profileEditProvider(widget.user.id)).value;
    if (currentProfile != null &&
        currentProfile.isProfileComplete &&
        currentProfile.photos.length <= 1) {
      final msg = l10n.getString('profileWizardLastPhotoRequired');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
      unawaited(VoiceGuidanceService.instance.speakText(msg));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.getString('profileWizardRemovePhotoTitle')),
        content: Text(l10n.getString('profileWizardRemovePhotoBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.getString('generalCancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.getString('profileWizardRemove'),
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _handleRemovePhoto(index);
    }
  }

  Widget _buildLanguagesEditorSection(
    UserProfile profile,
    LocalizationState l10n,
  ) {
    final available = ref.watch(languageOptionsProvider);
    final current = profile.languagesKnown;
    final filteredEntries = <MapEntry<String, List<String>>>[];
    final langs = current['languages'] ?? [];
    for (final lang in langs) {
      if (lang == 'languages') continue;
      final skills = current[lang] ?? [];
      filteredEntries.add(MapEntry(lang, skills));
    }
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _optionalFieldLabel(l10n, 'profileLanguagesKnown'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (filteredEntries.isEmpty)
              Text(
                l10n.getString('profileNoLanguages'),
                style: TextStyle(color: Colors.grey.shade600),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: filteredEntries.map((entry) {
                  final langCode = entry.key;
                  final skills = entry.value;
                  final name = l10n.getString('lang_$langCode');
                  // Format skills with capitalization
                  final skillsText = skills
                      .map((skill) {
                        final skillName = l10n.getString(skill);
                        return skillName;
                      })
                      .join(', ');

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: TextStyle(
                                fontSize: 15,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              children: [
                                TextSpan(
                                  text: '$name: ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(text: skillsText),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => ref
                              .read(
                                profileEditProvider(widget.user.id).notifier,
                              )
                              .removeLanguage(langCode),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: l10n.getString(
                            'profileWizardRemoveLanguageTooltip',
                          ),
                          color: Colors.grey.shade600,
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 12),
            available.when(
              data: (list) {
                return ElevatedButton.icon(
                  onPressed: () =>
                      _showLanguageSkillsDialog(context, list, current, l10n),
                  icon: const Icon(Icons.language),
                  label: Text(
                    l10n.getString('profileWizardSelectLanguagesAndSkills'),
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (_, _) =>
                  Text(l10n.getString('profileWizardErrorLoadingLanguages')),
            ),
          ],
        ),
      ),
    );
  }

  void _showLanguageSkillsDialog(
    BuildContext context,
    List<Map<String, dynamic>> availableLanguages,
    Map<String, List<String>> currentLanguages,
    LocalizationState l10n,
  ) {
    final selectedLanguages = Map<String, List<String>>.from(currentLanguages);
    selectedLanguages.remove('languages'); // Remove metadata key
    final availableSkills = ['read', 'understand', 'speak'];

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            // Check if all selected languages have at least one skill
            bool hasValidationErrors = false;
            String validationMessage = '';

            for (final langCode in selectedLanguages.keys) {
              final skills = selectedLanguages[langCode] ?? [];
              if (skills.isEmpty) {
                hasValidationErrors = true;
                validationMessage = l10n.getString(
                  'profileLanguageSkillsRequired',
                );
                break;
              }
            }

            return AlertDialog(
              title: Text(l10n.getString('profileLanguagesKnown')),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  children: [
                    if (hasValidationErrors)
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Colors.red.shade700,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                validationMessage,
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        children: availableLanguages.map((lang) {
                          final langCode = lang['code']!;
                          final langName = l10n.getString('lang_$langCode');
                          final isSelected = selectedLanguages.containsKey(
                            langCode,
                          );
                          final skills = selectedLanguages[langCode] ?? [];
                          final hasSkillsError = isSelected && skills.isEmpty;

                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            shape: hasSkillsError
                                ? RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    side: BorderSide(
                                      color: Colors.red.shade300,
                                      width: 2,
                                    ),
                                  )
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Checkbox(
                                        value: isSelected,
                                        onChanged: (value) {
                                          setState(() {
                                            if (value == true) {
                                              selectedLanguages[langCode] = [];
                                            } else {
                                              selectedLanguages.remove(
                                                langCode,
                                              );
                                            }
                                          });
                                        },
                                      ),
                                      Expanded(
                                        child: Text(
                                          langName,
                                          style: TextStyle(
                                            fontWeight: isSelected
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                            color: hasSkillsError
                                                ? Colors.red.shade700
                                                : null,
                                          ),
                                        ),
                                      ),
                                      if (hasSkillsError)
                                        Icon(
                                          Icons.warning,
                                          color: Colors.red.shade700,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                  if (isSelected) ...[
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          l10n.getString(
                                            'profileLanguageSkills',
                                          ),
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          '*',
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: availableSkills.map((skill) {
                                        final skillName = l10n.getString(skill);
                                        final isSkillSelected = skills.contains(
                                          skill,
                                        );
                                        return FilterChip(
                                          label: Text(skillName),
                                          selected: isSkillSelected,
                                          onSelected: (selected) {
                                            setState(() {
                                              if (selected) {
                                                skills.add(skill);
                                              } else {
                                                skills.remove(skill);
                                              }
                                            });
                                          },
                                          backgroundColor: isSkillSelected
                                              ? Theme.of(context)
                                                    .colorScheme
                                                    .primary
                                                    .withValues(alpha: 0.1)
                                              : null,
                                          selectedColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.2),
                                          checkmarkColor: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        );
                                      }).toList(),
                                    ),
                                    if (hasSkillsError)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(
                                          l10n.getString(
                                            'profileSelectAtLeastOneSkill',
                                          ),
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n.getString('generalCancel')),
                ),
                ElevatedButton(
                  onPressed: hasValidationErrors
                      ? null
                      : () async {
                          // Update the profile with selected languages and skills
                          final notifier = ref.read(
                            profileEditProvider(widget.user.id).notifier,
                          );
                          // Remove languages not in selected
                          final toRemove = currentLanguages.keys
                              .where(
                                (lang) =>
                                    !selectedLanguages.containsKey(lang) &&
                                    lang != 'languages',
                              )
                              .toList();
                          for (final lang in toRemove) {
                            notifier.removeLanguage(lang);
                          }
                          // Add or update selected languages with skills
                          selectedLanguages.forEach((langCode, skills) {
                            notifier.setLanguageSkills(langCode, skills);
                          });
                          await _saveDraftBestEffort(notifier);
                          Navigator.pop(
                            dialogContext,
                          ); // ignore: use_build_context_synchronously
                        },
                  child: Text(l10n.getString('generalSave')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildFinalReview(
    BuildContext ctx,
    WidgetRef ref,
    List<InterestCategory> categories,
    UserProfile? profile,
    LocalizationState l10n,
    bool isRtl,
    Map<String, String> allIntentsMap,
    Map<String, String> interestKeyToDisplayKey,
    Map<String, String> categoryKeyToDisplayKey,
  ) {
    if (profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final useImperialForReview = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);

    String localResolve(String key) => _resolveDisplayLabel(
      l10n,
      key,
      allIntentsMap: allIntentsMap,
      interestKeyToDisplayKey: interestKeyToDisplayKey,
      categoryKeyToDisplayKey: categoryKeyToDisplayKey,
    );

    final diffs = _computeDiffs(_originalSnapshot, profile);

    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12.0),
      side: BorderSide(color: Colors.grey.shade200, width: 1),
    );
    final cardMargin = const EdgeInsets.only(bottom: 14.0);
    const addIcon = Icon(Icons.add_circle_outline, color: Colors.green);
    const removeIcon = Icon(Icons.remove_circle_outline, color: Colors.red);
    const editIcon = Icon(Icons.edit_outlined, color: Colors.blue);

    final List<Widget> basicChanges = [];
    final List<Widget> goalChanges = [];
    final List<Widget> interestChanges = [];
    final List<Widget> languagesChanges = [];
    final List<Widget> socialChanges = [];

    if (diffs['name'] != null) {
      final m = diffs['name'] as Map;
      final toName = (m['to'] as String?)?.trim();
      final toNameLower = (toName ?? '').toLowerCase();
      final shouldShowName =
          toName != null &&
          toName.isNotEmpty &&
          toNameLower != 'unnamed' &&
          toNameLower != 'unknown user';
      if (shouldShowName) {
        basicChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(localResolve('profileName')),
            subtitle: Text(toName),
          ),
        );
      }
    }
    if (diffs['dateOfBirth'] != null) {
      final m = diffs['dateOfBirth'] as Map;
      String to = '-';
      try {
        to = m['to'] != null
            ? _formatDateWithL10n(DateTime.parse(m['to']), l10n)
            : '-';
      } catch (_) {
        // Ignore invalid date format
        to = m['to']?.toString() ?? '-';
      }
      if (to != '-') {
        basicChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(localResolve('profileBirthday')),
            subtitle: Text(to),
          ),
        );
      }
    }
    if (diffs['gender'] != null) {
      final m = diffs['gender'] as Map;
      final toGender = (m['to'] as String?)?.trim();
      if (toGender != null && toGender.isNotEmpty) {
        basicChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(localResolve('profileGender')),
            subtitle: Text(_genderLabelFor(toGender, l10n)),
          ),
        );
      }
    }

    if (diffs['photosChanged'] != null) {
      final m = diffs['photosChanged'] as Map;
      final fromPhotos = (m['from'] as List?)?.cast<String>() ?? [];
      final toPhotos = (m['to'] as List?)?.cast<String>() ?? [];
      final addedPhotos = toPhotos
          .where((photo) => !fromPhotos.contains(photo))
          .toList();
      final removedPhotos = fromPhotos
          .where((photo) => !toPhotos.contains(photo))
          .toList();
      final isReordered =
          const ListEquality<String>().equals(
            (fromPhotos.toSet().toList()..sort()),
            (toPhotos.toSet().toList()..sort()),
          ) &&
          !const ListEquality<String>().equals(fromPhotos, toPhotos);

      if (addedPhotos.isNotEmpty) {
        basicChanges.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: addIcon,
                title: Text(l10n.getString('profileWizardPhotosAdded')),
                subtitle: Text(
                  l10n
                      .getString('profileWizardNewPhotosAdded')
                      .replaceAll('{count}', '${addedPhotos.length}'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: addedPhotos.length,
                    itemBuilder: (ctx, idx) {
                      final source = addedPhotos[idx];
                      return Container(
                        width: 70,
                        margin: const EdgeInsets.only(right: 8),
                        child: SignedImage(
                          source: source,
                          fit: BoxFit.cover,
                          width: 70,
                          height: 80,
                          placeholder: Container(color: Colors.grey.shade100),
                          errorWidget: Container(
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.broken_image, size: 20),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }

      if (removedPhotos.isNotEmpty) {
        basicChanges.add(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                leading: removeIcon,
                title: Text(l10n.getString('profileWizardPhotosRemoved')),
                subtitle: Text(
                  l10n
                      .getString('profileWizardPhotosRemoved')
                      .replaceAll('{count}', '${removedPhotos.length}'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  height: 80,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: removedPhotos.length,
                    itemBuilder: (ctx, idx) {
                      final source = removedPhotos[idx];
                      return Container(
                        width: 70,
                        margin: const EdgeInsets.only(right: 8),
                        child: Stack(
                          children: [
                            SignedImage(
                              source: source,
                              fit: BoxFit.cover,
                              width: 70,
                              height: 80,
                              placeholder: Container(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                              ),
                              errorWidget: Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.8),
                                child: Icon(
                                  Icons.broken_image,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.onSurface
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: Container(
                                color: Colors.black.withValues(alpha: 0.5),
                                child: Center(
                                  child: Icon(
                                    Icons.delete_forever,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      }

      if (isReordered) {
        basicChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileWizardPhotoOrderChanged')),
            subtitle: Text(l10n.getString('profileWizardPhotoOrderDesc')),
          ),
        );
      }
    }

    if (diffs['instagramChanged'] != null) {
      final m = diffs['instagramChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        socialChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileInstagramUrl')),
            subtitle: Text(toVal),
          ),
        );
      }
    }

    if (diffs['linkedinChanged'] != null) {
      final m = diffs['linkedinChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        socialChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileLinkedinUrl')),
            subtitle: Text(toVal),
          ),
        );
      }
    }

    if (diffs['facebookChanged'] != null) {
      final m = diffs['facebookChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        socialChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileFacebookUrl')),
            subtitle: Text(toVal),
          ),
        );
      }
    }

    final Map<String, List<String>> intentToAddedSubs = {};
    final List<String> intentsAdded = List<String>.from(
      diffs['intentsAdded'] as List<dynamic>,
    );
    for (final intent in intentsAdded) {
      intentToAddedSubs[intent] = [];
    }
    final Map<String, List<String>> subsAdded = Map<String, List<String>>.from(
      diffs['subIntentsAdded'] as Map,
    );
    subsAdded.forEach((intent, subs) {
      if (!intentToAddedSubs.containsKey(intent)) {
        intentToAddedSubs[intent] = [];
      }
      // Filter out subs that match the parent intent and deduplicate
      final resolvedSubs = subs
          .where((s) => _normalizeKey(s) != _normalizeKey(intent))
          .map((s) {
            // Handle both cases: sub-intent with or without prefix
            // If the sub-intent already has a prefix (contains '::'), use it as-is
            // Otherwise, construct the full key by prepending the intent
            String fullKey;
            if (s.contains('::')) {
              fullKey = s; // Already has prefix: "romantic::casual"
            } else {
              fullKey =
                  '$intent::$s'; // Add prefix: "casual" -> "romantic::casual"
            }
            return _resolveDisplayLabel(
              l10n,
              fullKey,
              allIntentsMap: allIntentsMap,
            );
          })
          .toSet() // Remove duplicates
          .toList();
      intentToAddedSubs[intent]!.addAll(resolvedSubs);
    });
    for (final intent in intentToAddedSubs.keys) {
      final subs = intentToAddedSubs[intent]!;
      final title = subs.isNotEmpty
          ? '${_resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap)} - ${subs.join(', ')}'
          : _resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap);
      goalChanges.add(ListTile(leading: addIcon, title: Text(title)));
    }

    final Map<String, List<String>> intentToRemovedSubs = {};
    final List<String> intentsRemoved = List<String>.from(
      diffs['intentsRemoved'] as List<dynamic>,
    );
    for (final intent in intentsRemoved) {
      intentToRemovedSubs[intent] = [];
    }
    final Map<String, List<String>> subsRemoved =
        Map<String, List<String>>.from(diffs['subIntentsRemoved'] as Map);
    subsRemoved.forEach((intent, subs) {
      if (!intentToRemovedSubs.containsKey(intent)) {
        intentToRemovedSubs[intent] = [];
      }
      // Filter out subs that match the parent intent and deduplicate
      final resolvedSubs = subs
          .where((s) => _normalizeKey(s) != _normalizeKey(intent))
          .map((s) {
            // Handle both cases: sub-intent with or without prefix
            // If the sub-intent already has a prefix (contains '::'), use it as-is
            // Otherwise, construct the full key by prepending the intent
            String fullKey;
            if (s.contains('::')) {
              fullKey = s; // Already has prefix: "romantic::casual"
            } else {
              fullKey =
                  '$intent::$s'; // Add prefix: "casual" -> "romantic::casual"
            }
            return _resolveDisplayLabel(
              l10n,
              fullKey,
              allIntentsMap: allIntentsMap,
            );
          })
          .toSet() // Remove duplicates
          .toList();
      intentToRemovedSubs[intent]!.addAll(resolvedSubs);
    });
    for (final intent in intentToRemovedSubs.keys) {
      final subs = intentToRemovedSubs[intent]!;
      final title = subs.isNotEmpty
          ? '${_resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap)} - ${subs.join(', ')}'
          : _resolveDisplayLabel(l10n, intent, allIntentsMap: allIntentsMap);
      goalChanges.add(ListTile(leading: removeIcon, title: Text(title)));
    }

    // Process interests — keys are now simple category keys (no intent prefix)
    final Map<String, List<String>> interestsAdded =
        Map<String, List<String>>.from(diffs['interestsAdded'] as Map);
    final Map<String, List<String>> categoryToAddedSubs = {};
    final Set<String> categoriesAdded = {};

    interestsAdded.forEach((catKey, interests) {
      final categoryLabel = localResolve(
        categoryKeyToDisplayKey[catKey] ?? catKey,
      );
      final subs = interests
          .where((it) => _normalizeKey(it) != _normalizeKey(catKey))
          .map((it) => localResolve(interestKeyToDisplayKey[it] ?? it))
          .toSet()
          .toList();
      if (subs.isNotEmpty) {
        if (!categoryToAddedSubs.containsKey(categoryLabel)) {
          categoryToAddedSubs[categoryLabel] = [];
        }
        categoryToAddedSubs[categoryLabel] =
            (categoryToAddedSubs[categoryLabel]!.toSet()..addAll(subs))
                .toList();
      }
      if (interests.any((it) => _normalizeKey(it) == _normalizeKey(catKey))) {
        categoriesAdded.add(categoryLabel);
      }
    });

    final allAddedCategories = categoriesAdded.union(
      categoryToAddedSubs.keys.toSet(),
    );
    for (final category in allAddedCategories) {
      final subs = categoryToAddedSubs[category] ?? [];
      final title = subs.isNotEmpty
          ? '$category: ${subs.join(', ')}'
          : category;
      interestChanges.add(ListTile(leading: addIcon, title: Text(title)));
    }

    final Map<String, List<String>> interestsRemoved =
        Map<String, List<String>>.from(diffs['interestsRemoved'] as Map);
    final Map<String, List<String>> categoryToRemovedSubs = {};
    final Set<String> categoriesRemoved = {};

    interestsRemoved.forEach((catKey, interests) {
      final categoryLabel = localResolve(
        categoryKeyToDisplayKey[catKey] ?? catKey,
      );
      final subs = interests
          .where((it) => _normalizeKey(it) != _normalizeKey(catKey))
          .map((it) => localResolve(interestKeyToDisplayKey[it] ?? it))
          .toSet()
          .toList();
      if (subs.isNotEmpty) {
        if (!categoryToRemovedSubs.containsKey(categoryLabel)) {
          categoryToRemovedSubs[categoryLabel] = [];
        }
        categoryToRemovedSubs[categoryLabel] =
            (categoryToRemovedSubs[categoryLabel]!.toSet()..addAll(subs))
                .toList();
      }
      if (interests.any((it) => _normalizeKey(it) == _normalizeKey(catKey))) {
        categoriesRemoved.add(categoryLabel);
      }
    });

    final allRemovedCategories = categoriesRemoved.union(
      categoryToRemovedSubs.keys.toSet(),
    );
    for (final category in allRemovedCategories) {
      final subs = categoryToRemovedSubs[category] ?? [];
      final title = subs.isNotEmpty
          ? '$category: ${subs.join(', ')}'
          : category;
      interestChanges.add(ListTile(leading: removeIcon, title: Text(title)));
    }

    final Map<String, Map<String, List<String>>> languagesChanged =
        Map<String, Map<String, List<String>>>.from(
          diffs['languagesChanged'] as Map,
        );
    final Map<String, List<String>> addedPerLang = {};
    final Map<String, List<String>> removedPerLang = {};
    languagesChanged.forEach((lang, changes) {
      if (lang == 'languages') return;
      final added = changes['added'] as List<String>;
      final removed = changes['removed'] as List<String>;
      if (added.isNotEmpty) {
        addedPerLang[lang] = added;
      }
      if (removed.isNotEmpty) {
        removedPerLang[lang] = removed;
      }
    });

    final availableLangs =
        ref.watch(languageOptionsProvider).asData?.value ?? [];
    final langCodeToName = {
      for (var l in availableLangs) l['code']!: l['display']!,
    };
    String resolveLang(String code) {
      final key = 'lang_$code';
      try {
        final localized = l10n.getString(key);
        if (localized.isNotEmpty &&
            localized != key &&
            !localized.startsWith('lang_')) {
          return localized;
        }
      } catch (_) {}
      return langCodeToName[code] ?? _resolveDisplayLabel(l10n, key);
    }

    addedPerLang.forEach((lang, skills) {
      final langName = resolveLang(lang);
      final skillsText = _orderedLanguageSkills(
        skills,
      ).map((s) => l10n.getString(s)).join(', ');
      languagesChanges.add(
        ListTile(leading: addIcon, title: Text('$langName - $skillsText')),
      );
    });
    removedPerLang.forEach((lang, skills) {
      final langName = resolveLang(lang);
      final skillsText = _orderedLanguageSkills(
        skills,
      ).map((s) => l10n.getString(s)).join(', ');
      languagesChanges.add(
        ListTile(leading: removeIcon, title: Text('$langName - $skillsText')),
      );
    });

    // Profile details changes
    final List<Widget> detailChanges = [];

    if (diffs['heightChanged'] != null) {
      final m = diffs['heightChanged'] as Map;
      final toVal = m['to'] as int?;
      if (toVal != null) {
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileHeight')),
            subtitle: Text(
              _formatHeightForDisplay(l10n, toVal, useImperialForReview),
            ),
          ),
        );
      }
    }

    // Height unit changes (cm <-> ft) are detected by _computeDiffs and count
    // toward "hasChanges" (which is what adds this review page), so they must
    // render an entry here too — otherwise the review page shows only the
    // empty-state placeholder.
    if (diffs['heightUnitChanged'] != null) {
      final m = diffs['heightUnitChanged'] as Map;
      final fromUnit = m['from']?.toString() ?? 'cm';
      final toUnit = m['to']?.toString() ?? 'cm';
      String unitLabel(String u) => u.toLowerCase() == 'ft'
          ? l10n.getString('profileHeightUnitFeet')
          : l10n.getString('profileHeightUnitCm');
      detailChanges.add(
        ListTile(
          leading: editIcon,
          title: Text(l10n.getString('profileHeight')),
          subtitle: Text('${unitLabel(fromUnit)} → ${unitLabel(toUnit)}'),
        ),
      );
    }

    if (diffs['occupationChanged'] != null) {
      final m = diffs['occupationChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileOccupation')),
            subtitle: Text(toVal),
          ),
        );
      }
    }

    if (diffs['educationChanged'] != null) {
      final m = diffs['educationChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileEducation')),
            subtitle: Text(_educationLabel(toVal, l10n)),
          ),
        );
      }
    }

    if (diffs['bioChanged'] != null) {
      final m = diffs['bioChanged'] as Map;
      final toVal = (m['to'] as String?)?.trim();
      if (toVal != null && toVal.isNotEmpty) {
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileEditShortBio')),
            subtitle: Text(
              toVal.length > 100 ? '${toVal.substring(0, 100)}...' : toVal,
            ),
          ),
        );
      }
    }

    if (diffs['lifestyleChanged'] != null) {
      final m = diffs['lifestyleChanged'] as Map;
      final toVal = m['to'] as Map?;
      if (toVal != null && toVal.isNotEmpty) {
        final items = <Widget>[];
        if (toVal['smoking'] != null &&
            (toVal['smoking'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileLifestyleSmoking')}: ${_localizedLifestyleValue(l10n, 'smoking', toVal['smoking'] as String)}',
              ),
            ),
          );
        }
        if (toVal['drinking'] != null &&
            (toVal['drinking'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileLifestyleDrinking')}: ${_localizedLifestyleValue(l10n, 'drinking', toVal['drinking'] as String)}',
              ),
            ),
          );
        }
        if (toVal['exercise'] != null &&
            (toVal['exercise'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileLifestyleExercise')}: ${_localizedLifestyleValue(l10n, 'exercise', toVal['exercise'] as String)}',
              ),
            ),
          );
        }
        if (toVal['diet'] != null &&
            (toVal['diet'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileLifestyleDiet')}: ${_localizedLifestyleValue(l10n, 'diet', toVal['diet'] as String)}',
              ),
            ),
          );
        }
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileLifestyle')),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: items,
            ),
          ),
        );
      }
    }

    if (diffs['familyChanged'] != null) {
      final m = diffs['familyChanged'] as Map;
      final toVal = m['to'] as Map?;
      if (toVal != null && toVal.isNotEmpty) {
        final items = <Widget>[];
        if (toVal['has_children'] != null) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileFamilyHasChildren')}: ${toVal['has_children'] == true ? l10n.getString('profileYes') : l10n.getString('profileNo')}',
              ),
            ),
          );
        }
        if (toVal['wants_children'] != null &&
            (toVal['wants_children'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileFamilyWantsChildren')}: ${_localizedFamilyWantsChildrenValue(l10n, toVal['wants_children'] as String)}',
              ),
            ),
          );
        }
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileFamily')),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: items,
            ),
          ),
        );
      }
    }

    if (diffs['religionChanged'] != null) {
      final m = diffs['religionChanged'] as Map;
      final toVal = m['to'] as Map?;
      if (toVal != null && toVal.isNotEmpty) {
        final items = <Widget>[];
        if (toVal['religion'] != null &&
            (toVal['religion'] as String).trim().isNotEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                _localizedReligionValue(l10n, toVal['religion'] as String),
              ),
            ),
          );
        }
        detailChanges.add(
          ListTile(
            leading: editIcon,
            title: Text(l10n.getString('profileReligion')),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: items,
            ),
          ),
        );
      }
    }

    // Matching preferences changes
    final List<Widget> matchingChanges = [];
    final Map<String, List<Widget>> matchingItemsByIntent = {};

    void addMatchingItems(String intentKey, List<Widget> items) {
      if (items.isEmpty) return;
      matchingItemsByIntent.putIfAbsent(intentKey, () => []).addAll(items);
    }

    // Gender & age — only show intents that actually changed
    final Set<String> gaChanged = {};
    if (diffs['genderPreferencesChanged'] != null) {
      final m = diffs['genderPreferencesChanged'] as Map;
      final f = m['from'] as Map<String, List<String>>? ?? {};
      final t = m['to'] as Map<String, List<String>>? ?? {};
      for (final k in {...f.keys, ...t.keys}) {
        if (!const DeepCollectionEquality().equals(f[k] ?? [], t[k] ?? [])) {
          gaChanged.add(k);
        }
      }
    }
    if (diffs['agePreferencesChanged'] != null) {
      final m = diffs['agePreferencesChanged'] as Map;
      final f = m['from'] as Map<String, List<double>>? ?? {};
      final t = m['to'] as Map<String, List<double>>? ?? {};
      for (final k in {...f.keys, ...t.keys}) {
        if (!const DeepCollectionEquality().equals(f[k] ?? [], t[k] ?? [])) {
          gaChanged.add(k);
        }
      }
    }
    if (gaChanged.isNotEmpty) {
      final toGender =
          (diffs['genderPreferencesChanged'] as Map?)?['to']
              as Map<String, List<String>>?;
      final toAge =
          (diffs['agePreferencesChanged'] as Map?)?['to']
              as Map<String, List<double>>?;
      for (final intentKey in gaChanged) {
        final items = <Widget>[];
        final genders = toGender?[intentKey] ?? [];
        if (genders.isNotEmpty) {
          final genderLabels = genders
              .map((g) => _genderLabelFor(g, l10n))
              .join(', ');
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text('${l10n.getString('profileGender')}: $genderLabels'),
            ),
          );
        }
        final age = toAge?[intentKey];
        if (age != null && age.length >= 2) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('settingsPreferredAgeRange')}: ${age[0].toInt()}–${age[1].toInt()}',
              ),
            ),
          );
        }
        // The diff exists but both new values are empty (a pure removal, e.g.
        // the user cleared all genders or removed the intent). Without this,
        // the review page would be added (hasChanges == true) yet render no
        // entry, leaving only the "Not set" placeholder.
        if (items.isEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(
                '${l10n.getString('profileGender')}: ${l10n.getString('generalAny')}',
              ),
            ),
          );
        }
        addMatchingItems(intentKey, items);
      }
    }

    // Filter changes (lifestyle, family, religion, height) — grouped per intent
    String fvLabel(String category, String value) {
      final opts =
          ref
              .watch(
                fieldOptionsProvider((fieldKey: category, context: 'filter')),
              )
              .asData
              ?.value ??
          [];
      final m = opts.where((o) => o.filterValue == value).firstOrNull;
      if (m != null && m.filterDisplayKey.isNotEmpty) {
        final loc = _tryGetString(l10n, m.filterDisplayKey);
        if (loc != null) return loc;
      }
      final popts =
          ref
              .watch(
                fieldOptionsProvider((fieldKey: category, context: 'profile')),
              )
              .asData
              ?.value ??
          [];
      final pm = popts.where((o) => o.profileValue == value).firstOrNull;
      if (pm != null && pm.profileDisplayKey.isNotEmpty) {
        final loc = _tryGetString(l10n, pm.profileDisplayKey);
        if (loc != null) return loc;
      }
      final pk =
          'lifestyle${category[0].toUpperCase()}${category.substring(1)}$value';
      return _tryGetString(l10n, pk) ?? _humanizeKey(value);
    }

    String fmtList(String category, List<dynamic> vals) {
      if (vals.isEmpty || (vals.length == 1 && vals.first == 'any')) {
        return l10n.getString('generalAny');
      }
      return vals.map((v) => fvLabel(category, v.toString())).join(', ');
    }

    List<String> toStrList(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).toList();
      if (v is String && v.isNotEmpty) return [v];
      return [];
    }

    void appendIntentFilters(
      Map<String, dynamic> fromVal,
      Map<String, dynamic> toVal,
      String ik,
      List<(String fieldKey, String label, String category)> fields,
    ) {
      final items = <Widget>[];
      for (final (fk, lb, cat) in fields) {
        final f = toStrList(fromVal[fk]);
        final t = toStrList(toVal[fk]);
        if (const DeepCollectionEquality().equals(f, t)) continue;
        items.add(
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Text('$lb: ${fmtList(cat, t)}'),
          ),
        );
      }
      // height is stored as min/max, not a list
      final hf = fromVal['min'] as num?;
      final ht = toVal['min'] as num?;
      final hf2 = fromVal['max'] as num?;
      final ht2 = toVal['max'] as num?;
      if (hf != ht || hf2 != ht2) {
        final minVal = ht?.toInt() ?? 140;
        final maxVal = ht2?.toInt() ?? 220;
        items.add(
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: Text(
              '${l10n.getString('settingsHeightRange')}: ${_formatHeightForDisplay(l10n, minVal, useImperialForReview)}–${_formatHeightForDisplay(l10n, maxVal, useImperialForReview)}',
            ),
          ),
        );
      }
      addMatchingItems(ik, items);
    }

    if (diffs['lifestyleFiltersChanged'] != null) {
      final m = diffs['lifestyleFiltersChanged'] as Map;
      final fromLF = m['from'] as Map<String, dynamic>? ?? {};
      final toLF = m['to'] as Map<String, dynamic>? ?? {};
      for (final ik in toLF.keys) {
        final f = fromLF[ik] as Map<String, dynamic>? ?? {};
        final t = toLF[ik] as Map<String, dynamic>? ?? {};
        if (const DeepCollectionEquality().equals(f, t)) continue;
        appendIntentFilters(f, t, ik, [
          ('smoking', l10n.getString('settingsSmoking'), 'smoking'),
          ('drinking', l10n.getString('settingsDrinking'), 'drinking'),
          ('diets', l10n.getString('settingsDiet'), 'diet'),
          ('exercise', l10n.getString('settingsExercise'), 'exercise'),
        ]);
      }
    }

    if (diffs['familyFiltersChanged'] != null) {
      final m = diffs['familyFiltersChanged'] as Map;
      final fromFF = m['from'] as Map<String, dynamic>? ?? {};
      final toFF = m['to'] as Map<String, dynamic>? ?? {};
      for (final ik in toFF.keys) {
        final f = fromFF[ik] as Map<String, dynamic>? ?? {};
        final t = toFF[ik] as Map<String, dynamic>? ?? {};
        if (const DeepCollectionEquality().equals(f, t)) continue;
        appendIntentFilters(f, t, ik, [
          (
            'has_children',
            l10n.getString('settingsHasChildren'),
            'has_children',
          ),
          (
            'wants_children',
            l10n.getString('settingsWantsChildren'),
            'wants_children',
          ),
        ]);
      }
    }

    if (diffs['religionFiltersChanged'] != null) {
      final m = diffs['religionFiltersChanged'] as Map;
      final fromRF = m['from'] as Map<String, dynamic>? ?? {};
      final toRF = m['to'] as Map<String, dynamic>? ?? {};
      for (final ik in toRF.keys) {
        final f = fromRF[ik] as Map<String, dynamic>? ?? {};
        final t = toRF[ik] as Map<String, dynamic>? ?? {};
        if (const DeepCollectionEquality().equals(f, t)) continue;
        appendIntentFilters(f, t, ik, [
          ('religions', l10n.getString('settingsReligion'), 'religion'),
        ]);
      }
    }

    if (diffs['heightPreferencesChanged'] != null) {
      final m = diffs['heightPreferencesChanged'] as Map;
      final fromHP = m['from'] as Map<String, dynamic>? ?? {};
      final toHP = m['to'] as Map<String, dynamic>? ?? {};
      for (final ik in toHP.keys) {
        final f = fromHP[ik] as Map<String, dynamic>? ?? {};
        final t = toHP[ik] as Map<String, dynamic>? ?? {};
        if (const DeepCollectionEquality().equals(f, t)) continue;
        appendIntentFilters(f, t, ik, []);
      }
    }

    matchingItemsByIntent.forEach((intentKey, items) {
      matchingChanges.add(
        ListTile(
          leading: editIcon,
          title: Text(
            _resolveDisplayLabel(l10n, intentKey, allIntentsMap: allIntentsMap),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: items,
          ),
        ),
      );
    });

    final List<Widget> entries = [];
    if (basicChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_basics'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileEditBasics'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: basicChanges,
          ),
        ),
      );
    }

    if (goalChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_goals'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileEditIntentsTitle'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: goalChanges,
          ),
        ),
      );
    }

    if (interestChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_interests'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileInterests'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: interestChanges,
          ),
        ),
      );
    }

    if (languagesChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_languages'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileLanguagesKnown'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: languagesChanges,
          ),
        ),
      );
    }

    if (socialChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_social'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileSocialLinks'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: socialChanges,
          ),
        ),
      );
    }

    if (detailChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_details'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('profileEditBasics'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: detailChanges,
          ),
        ),
      );
    }

    if (matchingChanges.isNotEmpty) {
      entries.add(
        Card(
          elevation: 0,
          shape: cardShape,
          margin: cardMargin,
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: const PageStorageKey('review_matching'),
            initiallyExpanded: true,
            title: Text(
              l10n.getString('settingsMatchPreferences'),
              style: Theme.of(
                ctx,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            children: matchingChanges,
          ),
        ),
      );
    }

    return Directionality(
      textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 18.0),
        child: ListView(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.getString('profileEditReviewTitle'),
                    style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.blue.shade50,
                  child: const Icon(
                    Icons.check_circle_outline,
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (entries.isEmpty)
              Center(child: Text(l10n.getString('profileNotSet'))),
            ...entries,
            const SizedBox(height: 24),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(
    int totalSteps,
    int currentIndex,
    LocalizationState l10n,
  ) {
    final progress = (totalSteps <= 1)
        ? 0.0
        : (currentIndex / (totalSteps - 1)).clamp(0.0, 1.0);
    final stepLabel = l10n.getString(
      'onboardingStepOf',
      params: {'current': '${currentIndex + 1}', 'total': '$totalSteps'},
    );
    return Semantics(
      container: true,
      label: stepLabel,
      value: '${(progress * 100).round()}%',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20.0),
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(stepLabel, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNavBar(
    BuildContext context,
    LocalizationState l10n,
    List<Widget> pages, {
    bool allowSaveAtAnyStep = false,
  }) {
    final totalPages = pages.length;
    final bool isLastPage = _currentPageIndex == totalPages - 1;
    final bool isFirstPage = _currentPageIndex == 0;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 20.0,
        vertical: 14.0,
      ).copyWith(bottom: 22.0),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Colors.grey.shade200, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          if (!isFirstPage)
            TextButton.icon(
              onPressed: () => _handleBackPage(pages),
              icon: const Icon(Icons.arrow_back),
              label: Text(l10n.getString('generalBack')),
            )
          else
            Opacity(
              opacity: 0.0,
              child: TextButton.icon(
                onPressed: null,
                icon: Icon(Icons.arrow_back),
                label: Text(l10n.getString('generalBack')),
              ),
            ),
          const Spacer(),
          // After the profile was completed once, the user may save from
          // any step without clicking "Next" through the whole wizard.
          // _submit saves and pops back to the read-only profile screen.
          if (allowSaveAtAnyStep && !isLastPage)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12.0),
              child: TextButton.icon(
                onPressed: _isLoading ? null : _submit,
                icon: const Icon(Icons.check),
                label: Text(l10n.getString('generalSave')),
              ),
            ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 28.0,
                vertical: 12.0,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
            ),
            onPressed: isLastPage
                ? (_isLoading ? null : _submit)
                : (_isLoading
                      ? null
                      : () async => await _handleNextPage(pages)),
            child: isLastPage && _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : Text(
                    isLastPage
                        ? l10n.getString('generalSave')
                        : l10n.getString('generalNext'),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ref.watch(localizationProvider);
    String langCode = 'en';
    try {
      final cur = l10n.currentLocale;
      langCode = _extractLangCode(cur);
    } catch (_) {
      // Ignore invalid locale format
      langCode = 'en';
    }
    final isRtl = ['ar', 'he'].contains(langCode.toLowerCase());

    final profileEditState = ref.watch(profileEditProvider(widget.user.id));
    final allIntentsAsync = ref.watch(
      allIntentsProvider.select((state) => state),
    );
    final allInterestsAsync = ref.watch(
      allInterestsProvider.select((state) => state),
    );

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          try {
            unawaited(
              ref
                  .read(profileEditProvider(widget.user.id).notifier)
                  .saveWizardDraft(),
            );
          } catch (_) {}
        }
      },
      child: Directionality(
        textDirection: isRtl ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: Scaffold(
          appBar: AppBar(
            leading: widget.isEditing
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      if (Navigator.of(context).canPop()) {
                        Navigator.of(context).pop();
                      }
                    },
                  )
                : null,
            title: Text(l10n.getString('profileEditTitle')),
            automaticallyImplyLeading: false,
            elevation: 0,
            backgroundColor:
                Theme.of(context).appBarTheme.backgroundColor ??
                Theme.of(context).colorScheme.surface,
            foregroundColor:
                Theme.of(context).appBarTheme.foregroundColor ??
                Theme.of(context).colorScheme.onSurface,
            actions: [
              const VoiceGuidanceMuteButton(),
              if (!widget.isEditing && l10n.supportedLanguages.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.language),
                  tooltip: l10n.getString('authSelectLanguage'),
                  onPressed: () =>
                      _showLanguagePicker(context, l10n.supportedLanguages),
                ),
              if (!widget.isEditing)
                IconButton(
                  icon: const Icon(Icons.logout_rounded),
                  tooltip: l10n.getString('authLogout'),
                  onPressed: _isLoading
                      ? null
                      : () => _confirmLogoutFromWizard(l10n),
                ),
            ],
          ),
          body: profileEditState.when(
            data: (profile) {
              if (allIntentsAsync.isLoading || allInterestsAsync.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }
              if (allIntentsAsync.hasError) {
                return _buildReferenceDataError(
                  l10n,
                  titleKey: 'profileWizardErrorLoadingIntents',
                  retryIntents: true,
                  retryInterests: false,
                );
              }
              if (allInterestsAsync.hasError) {
                return _buildReferenceDataError(
                  l10n,
                  titleKey: 'profileWizardErrorLoadingInterests',
                  retryIntents: false,
                  retryInterests: true,
                );
              }
              if (profile == null) {
                return AppEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: l10n.getString('generalErrorLoadingProfile'),
                  message: l10n.getString('profileWizardRecoveryMessage'),
                  actionLabel: l10n.getString('generalRetry'),
                  onAction: _retryProfileLoad,
                );
              }

              return _buildWizardBody(
                context,
                l10n,
                isRtl,
                profile,
                allIntentsAsync,
                allInterestsAsync,
              );
            },
            loading: () => _buildWizardFallbackBody(
              context,
              l10n,
              isRtl,
              allIntentsAsync,
              allInterestsAsync,
              isLoading: true,
            ),
            error: (_, _) => _buildWizardFallbackBody(
              context,
              l10n,
              isRtl,
              allIntentsAsync,
              allInterestsAsync,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReferenceDataError(
    LocalizationState l10n, {
    required String titleKey,
    required bool retryIntents,
    required bool retryInterests,
  }) {
    return AppEmptyState(
      icon: Icons.tune_rounded,
      title: l10n.getString(titleKey),
      message: l10n.getString('profileWizardReferenceDataErrorMessage'),
      actionLabel: l10n.getString('generalRetry'),
      onAction: () =>
          _retryReferenceData(intents: retryIntents, interests: retryInterests),
    );
  }

  Widget _buildWizardFallbackBody(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    AsyncValue allIntentsAsync,
    AsyncValue allInterestsAsync, {
    bool isLoading = false,
  }) {
    if (allIntentsAsync.isLoading || allInterestsAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (allIntentsAsync.hasError) {
      return _buildReferenceDataError(
        l10n,
        titleKey: 'profileWizardErrorLoadingIntents',
        retryIntents: true,
        retryInterests: false,
      );
    }
    if (allInterestsAsync.hasError) {
      return _buildReferenceDataError(
        l10n,
        titleKey: 'profileWizardErrorLoadingInterests',
        retryIntents: false,
        retryInterests: true,
      );
    }
    if (!_isInitialized || _lastGoodProfile == null) {
      if (isLoading) return const Center(child: CircularProgressIndicator());
      return AppEmptyState(
        icon: Icons.cloud_off_rounded,
        title: l10n.getString('generalErrorLoadingProfile'),
        message: l10n.getString('profileWizardRecoveryMessage'),
        actionLabel: l10n.getString('generalRetry'),
        onAction: _retryProfileLoad,
      );
    }
    return _buildWizardBody(
      context,
      l10n,
      isRtl,
      _lastGoodProfile!,
      allIntentsAsync,
      allInterestsAsync,
    );
  }

  Widget _buildWizardBody(
    BuildContext context,
    LocalizationState l10n,
    bool isRtl,
    UserProfile profile,
    AsyncValue allIntentsAsync,
    AsyncValue allInterestsAsync,
  ) {
    final allIntentsData = allIntentsAsync.asData!.value;
    final allInterestsData = allInterestsAsync.asData!.value;

    final pages = _buildWizardPages(
      context,
      l10n,
      isRtl,
      profile,
      allIntentsData,
      allInterestsData,
    );

    if (_currentPageIndex >= pages.length) {
      // The page list shrank (e.g. intents changed or a permission
      // resume rebuilt with stale data). Sync both the local index and
      // the PageController so the bottom bar and visible page agree.
      final clamped = pages.length - 1 < 0 ? 0 : pages.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_currentPageIndex != clamped) {
          setState(() => _currentPageIndex = clamped);
        }
        if (_pageController.hasClients) {
          try {
            _pageController.jumpToPage(clamped);
          } catch (_) {}
        }
        try {
          ref
              .read(profileEditProvider(widget.user.id).notifier)
              .setWizardPageIndex(clamped);
        } catch (_) {}
      });
    }

    // Precache profile photos (UI side) so images render immediately.
    // This uses any cached signed URLs from StorageHelper (prewarmed in provider).
    if (!_didPrefetchPhotos) {
      _didPrefetchPhotos = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final src in profile.photos) {
          if (src.isEmpty) continue;
          StorageHelper.resolveImageRequest(src).then((request) {
            if (!mounted) return;
            if (!context.mounted) return;
            if (request == null || request.url.isEmpty) return;
            final cacheKey = StorageHelper.cacheKeyForSource(src);
            final provider = ExtendedNetworkImageProvider(
              request.url,
              headers: request.headers,
              cache: true,
              cacheKey: cacheKey.isNotEmpty ? cacheKey : request.url,
            );
            try {
              precacheImage(provider, context);
            } catch (_) {}
          });
        }
      });
    }

    return Column(
      children: [
        const SizedBox(height: 10),
        _buildProgressIndicator(pages.length, _currentPageIndex, l10n),
        const SizedBox(height: 10),
        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: pages,
          ),
        ),
        _buildBottomNavBar(
          context,
          l10n,
          pages,
          allowSaveAtAnyStep: _ProfileWizardScreenState.isEditAfterCompleteMode(
            isEditing: widget.isEditing,
            isProfileComplete: profile.isProfileComplete,
          ),
        ),
      ],
    );
  }

  String _genderLabelFor(String? storedKey, LocalizationState l10n) {
    if (storedKey == null || storedKey.trim().isEmpty) {
      return l10n.getString('profileNotSet');
    }

    final options = ref.read(genderOptionsProvider).asData?.value ?? [];

    final Map<String, String> found = options.firstWhere(
      (o) => (o['key'] ?? '') == storedKey,
      orElse: () => <String, String>{},
    );

    if (found.isNotEmpty) {
      final displayKey = found['displayKey'] ?? '';
      try {
        final localized =
            _tryGetString(l10n, _normalizeGenderDisplayKey(displayKey)) ??
            _tryGetString(l10n, _normalizeGenderDisplayKey(storedKey));
        if (localized != null) {
          return localized;
        }
      } catch (_) {}
    }

    // Try to translate the storedKey directly as a translation key
    try {
      final directTranslation = _tryGetString(
        l10n,
        _normalizeGenderDisplayKey(storedKey),
      );
      if (directTranslation != null) {
        return directTranslation;
      }
    } catch (_) {}

    // Final fallback to humanized key
    return _humanizeKey(storedKey);
  }

  String _ageLabelFor(LocalizationState l10n) {
    return l10n.getString('profileYourAge');
  }

  String _formatHeightForDisplay(
    LocalizationState l10n,
    int heightCm,
    bool useImperial,
  ) {
    if (!useImperial) {
      return '$heightCm ${l10n.getString('settingsHeightCm')}';
    }
    final totalInches = (heightCm / 2.54).round();
    return l10n
        .getString('profileHeightFeetInches')
        .replaceAll('{feet}', (totalInches ~/ 12).toString())
        .replaceAll('{inches}', (totalInches % 12).toString());
  }

  List<String> _orderedLanguageSkills(Iterable<String> skills) {
    const order = {'understand': 0, 'read': 1, 'speak': 2};
    final ordered = skills.toList();
    ordered.sort((a, b) {
      final aKey = a.trim().toLowerCase();
      final bKey = b.trim().toLowerCase();
      final aOrder = order[aKey] ?? order.length;
      final bOrder = order[bKey] ?? order.length;
      return aOrder == bOrder ? aKey.compareTo(bKey) : aOrder.compareTo(bOrder);
    });
    return ordered;
  }

  String _educationLabel(String level, LocalizationState l10n) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'education', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final trimmed = level.trim();
    final match = opts.where((o) => o.profileValue == trimmed).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    // Fallback: normalization-based fuzzy match against all profile values
    final normalized = trimmed
        .replaceAll(RegExp(r"[^A-Za-z]"), '')
        .toLowerCase();
    for (final o in opts) {
      final pv = (o.profileValue ?? '')
          .replaceAll(RegExp(r"[^A-Za-z]"), '')
          .toLowerCase();
      if (pv == normalized && o.profileDisplayKey.isNotEmpty) {
        final localized = _tryGetString(l10n, o.profileDisplayKey);
        if (localized != null) return localized;
      }
    }
    final direct = _tryGetString(l10n, trimmed);
    if (direct != null) return direct;
    return trimmed;
  }

  String _formatDateWithL10n(DateTime date, LocalizationState l10n) {
    try {
      final curLocale = l10n.currentLocale;
      final langCode = _extractLangCode(curLocale).toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(date);
        } catch (e) {
          // Hebrew DateFormat failed, fall back
        }
      }

      final monthKeys = [
        'month_january',
        'month_february',
        'month_march',
        'month_april',
        'month_may',
        'month_june',
        'month_july',
        'month_august',
        'month_september',
        'month_october',
        'month_november',
        'month_december',
      ];

      final monthKey = monthKeys[date.month - 1];
      final translatedMonth = _tryGetString(l10n, monthKey);
      final day = date.day;
      final year = date.year;

      if (translatedMonth != null) {
        return '$translatedMonth $day, $year';
      }

      try {
        final localeTag = curLocale.toLanguageTag();
        final df = DateFormat.yMMMMd(localeTag.isNotEmpty ? localeTag : null);
        return df.format(date);
      } catch (e) {
        // Intl DateFormat fallback failed
      }

      return DateFormat('MMMM d, yyyy').format(date);
    } catch (e) {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }
}

// ---------------------------------------------------------------------------
// LifestyleWizardPage — shown if any social intent is selected
// ---------------------------------------------------------------------------
class LifestyleWizardPage extends ConsumerStatefulWidget {
  final UserProfile profile;
  final LocalizationState l10n;
  final bool isRtl;

  const LifestyleWizardPage({
    super.key,
    required this.profile,
    required this.l10n,
    required this.isRtl,
  });

  @override
  ConsumerState<LifestyleWizardPage> createState() =>
      _LifestyleWizardPageState();
}

class _OptionDef {
  final String value;
  final String label;
  const _OptionDef(this.value, this.label);
}

class _LifestyleWizardPageState extends ConsumerState<LifestyleWizardPage> {
  String? _smoking;
  String? _drinking;
  String? _exercise;
  String? _diet;

  @override
  void initState() {
    super.initState();
    _syncWithProfile(widget.profile);
  }

  @override
  void didUpdateWidget(covariant LifestyleWizardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _syncWithProfile(widget.profile);
    }
  }

  void _syncWithProfile(UserProfile profile) {
    final lifestyle = profile.lifestyle;
    if (lifestyle != null) {
      _smoking = lifestyle['smoking'] as String?;
      _drinking = lifestyle['drinking'] as String?;
      _exercise = lifestyle['exercise'] as String?;
      _diet = lifestyle['diet'] as String?;
    }
  }

  void _updateParent() {
    final data = <String, dynamic>{};
    if (_smoking != null) data['smoking'] = _smoking;
    if (_drinking != null) data['drinking'] = _drinking;
    if (_exercise != null) data['exercise'] = _exercise;
    if (_diet != null) data['diet'] = _diet;
    ref
        .read(profileEditProvider(widget.profile.id).notifier)
        .updateLifestyle(data.isEmpty ? null : data);
  }

  List<_OptionDef> _profileOptions(LocalizationState l10n, String fieldKey) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: fieldKey, context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    return opts
        .map(
          (o) => _OptionDef(
            o.profileValue ?? '',
            l10n.getString(o.profileDisplayKey),
          ),
        )
        .toList();
  }

  Widget _buildChoiceChipRow({
    required String label,
    required List<_OptionDef> options,
    required String? selectedValue,
    required ValueChanged<String?> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((opt) {
            final isSelected = selectedValue == opt.value;
            return ChoiceChip(
              label: Text(opt.label),
              selected: isSelected,
              onSelected: (_) => onSelected(isSelected ? null : opt.value),
              selectedColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.15),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: StadiumBorder(
                side: BorderSide(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                ),
              ),
              labelStyle: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileWizardLifestyleTitle'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.green.shade50,
                child: const Icon(Icons.self_improvement, color: Colors.green),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileWizardLifestyleSubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n, allOptional: true),
          const SizedBox(height: 20),

          // Smoking
          _buildChoiceChipRow(
            label: _optionalFieldLabel(l10n, 'profileLifestyleSmoking'),
            options: _profileOptions(l10n, 'smoking'),
            selectedValue: _smoking,
            onSelected: (val) {
              setState(() => _smoking = val);
              _updateParent();
            },
          ),
          const SizedBox(height: 20),

          // Drinking
          _buildChoiceChipRow(
            label: _optionalFieldLabel(l10n, 'profileLifestyleDrinking'),
            options: _profileOptions(l10n, 'drinking'),
            selectedValue: _drinking,
            onSelected: (val) {
              setState(() => _drinking = val);
              _updateParent();
            },
          ),
          const SizedBox(height: 20),

          // Exercise
          _buildChoiceChipRow(
            label: _optionalFieldLabel(l10n, 'profileLifestyleExercise'),
            options: _profileOptions(l10n, 'exercise'),
            selectedValue: _exercise,
            onSelected: (val) {
              setState(() => _exercise = val);
              _updateParent();
            },
          ),
          const SizedBox(height: 20),

          // Diet
          _buildChoiceChipRow(
            label: _optionalFieldLabel(l10n, 'profileLifestyleDiet'),
            options: _profileOptions(l10n, 'diet'),
            selectedValue: _diet,
            onSelected: (val) {
              setState(() => _diet = val);
              _updateParent();
            },
          ),

          const SizedBox(height: 60),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FamilyWizardPage — shown only if romantic intent is selected
// ---------------------------------------------------------------------------
class FamilyWizardPage extends ConsumerStatefulWidget {
  final UserProfile profile;
  final LocalizationState l10n;
  final bool isRtl;

  const FamilyWizardPage({
    super.key,
    required this.profile,
    required this.l10n,
    required this.isRtl,
  });

  @override
  ConsumerState<FamilyWizardPage> createState() => _FamilyWizardPageState();
}

class _FamilyWizardPageState extends ConsumerState<FamilyWizardPage> {
  bool? _hasChildren;
  String? _wantsChildren;
  bool _initializedDefaults = false;

  @override
  void initState() {
    super.initState();
    _syncWithProfile(widget.profile);
  }

  @override
  void didUpdateWidget(covariant FamilyWizardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _syncWithProfile(widget.profile);
    }
  }

  void _syncWithProfile(UserProfile profile) {
    final family = profile.family;
    if (family != null) {
      _hasChildren = family['has_children'] as bool?;
      _wantsChildren = family['wants_children'] as String?;
    }
  }

  void _updateParent() {
    final data = <String, dynamic>{};
    if (_hasChildren != null) data['has_children'] = _hasChildren;
    if (_wantsChildren != null) data['wants_children'] = _wantsChildren;
    ref
        .read(profileEditProvider(widget.profile.id).notifier)
        .updateFamily(data.isEmpty ? null : data);
  }

  List<_OptionDef> _profileOptions(LocalizationState l10n, String fieldKey) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: fieldKey, context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    return opts
        .map(
          (o) => _OptionDef(
            o.profileValue ?? '',
            l10n.getString(o.profileDisplayKey),
          ),
        )
        .toList();
  }

  Widget _buildYesNoChoiceChipRow({
    required String label,
    required String yesLabel,
    required String noLabel,
    required String preferNotLabel,
    required bool? selectedValue,
    required ValueChanged<bool?> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildSingleChoiceChip(
              yesLabel,
              selectedValue == true,
              () => onSelected(true),
            ),
            _buildSingleChoiceChip(
              noLabel,
              selectedValue == false,
              () => onSelected(false),
            ),
            _buildSingleChoiceChip(
              preferNotLabel,
              selectedValue == null,
              () => onSelected(null),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSingleChoiceChip(
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.15),
      backgroundColor: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: StadiumBorder(
        side: BorderSide(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor,
        ),
      ),
      labelStyle: TextStyle(
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  Widget _buildWantsChildrenRow({
    required String label,
    required List<_OptionDef> options,
    required String? selectedValue,
    required ValueChanged<String?> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((opt) {
            final isSelected = selectedValue == opt.value;
            return ChoiceChip(
              label: Text(opt.label),
              selected: isSelected,
              onSelected: (_) => onSelected(isSelected ? null : opt.value),
              selectedColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.15),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: StadiumBorder(
                side: BorderSide(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                ),
              ),
              labelStyle: TextStyle(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;

    if (!_initializedDefaults) {
      _initializedDefaults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final family = widget.profile.family;
          if (family != null) {
            setState(() {
              _hasChildren = family['has_children'] as bool?;
              _wantsChildren = family['wants_children'] as String?;
            });
          }
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileWizardFamilyTitle'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.orange.shade50,
                child: const Icon(Icons.family_restroom, color: Colors.orange),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileWizardFamilySubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n, allOptional: true),
          const SizedBox(height: 20),

          // Has children
          _buildYesNoChoiceChipRow(
            label: _optionalFieldLabel(l10n, 'profileFamilyHasChildren'),
            yesLabel: l10n.getString('profileYes'),
            noLabel: l10n.getString('profileNo'),
            preferNotLabel: l10n.getString('familyPreferNotToSay'),
            selectedValue: _hasChildren,
            onSelected: (val) {
              setState(() => _hasChildren = val);
              _updateParent();
            },
          ),
          const SizedBox(height: 20),

          // Wants children — shown only if romantic
          _buildWantsChildrenRow(
            label: _optionalFieldLabel(l10n, 'profileFamilyWantsChildren'),
            options: _profileOptions(l10n, 'wants_children'),
            selectedValue: _wantsChildren,
            onSelected: (val) {
              setState(() => _wantsChildren = val);
              _updateParent();
            },
          ),

          const SizedBox(height: 60),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ReligionWizardPage — shown if romantic or friendship intent is selected
// ---------------------------------------------------------------------------
class ReligionWizardPage extends ConsumerStatefulWidget {
  final UserProfile profile;
  final LocalizationState l10n;
  final bool isRtl;

  const ReligionWizardPage({
    super.key,
    required this.profile,
    required this.l10n,
    required this.isRtl,
  });

  @override
  ConsumerState<ReligionWizardPage> createState() => _ReligionWizardPageState();
}

class _ReligionWizardPageState extends ConsumerState<ReligionWizardPage> {
  String? _religion;
  bool _initializedDefaults = false;

  @override
  void initState() {
    super.initState();
    _syncWithProfile(widget.profile);
  }

  @override
  void didUpdateWidget(covariant ReligionWizardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _syncWithProfile(widget.profile);
    }
  }

  void _syncWithProfile(UserProfile profile) {
    final religion = profile.religion;
    if (religion != null) {
      _religion = religion['religion'] as String?;
    }
  }

  void _updateParent() {
    final data = <String, dynamic>{};
    if (_religion != null) data['religion'] = _religion;
    ref
        .read(profileEditProvider(widget.profile.id).notifier)
        .updateReligion(data.isEmpty ? null : data);
  }

  List<_OptionDef> _religionOptions(LocalizationState l10n) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'religion', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    return opts
        .map(
          (o) => _OptionDef(
            o.profileValue ?? '',
            l10n.getString(o.profileDisplayKey),
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;

    if (!_initializedDefaults) {
      _initializedDefaults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final religion = widget.profile.religion;
          if (religion != null) {
            setState(() {
              _religion = religion['religion'] as String?;
            });
          }
        }
      });
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      child: ListView(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.getString('profileWizardReligionTitle'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.purple.shade50,
                child: const Icon(
                  Icons.self_improvement_outlined,
                  color: Colors.purple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.getString('profileWizardReligionSubtitle'),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
          ),
          _WizardFieldLegend(l10n: l10n, allOptional: true),
          const SizedBox(height: 20),

          // Religion choice chips
          _buildReligionChips(l10n),

          const SizedBox(height: 60),
        ],
      ),
    );
  }

  Widget _buildReligionChips(LocalizationState l10n) {
    final religionOptions = _religionOptions(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _optionalFieldLabel(l10n, 'profileReligion'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: Text(l10n.getString('settingsReligionAny')),
              selected: _religion == null,
              onSelected: (_) {
                setState(() => _religion = null);
                _updateParent();
              },
              selectedColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.15),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: StadiumBorder(
                side: BorderSide(
                  color: _religion == null
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                ),
              ),
            ),
            ...religionOptions.map((opt) {
              final isSelected = _religion == opt.value;
              return ChoiceChip(
                label: Text(opt.label),
                selected: isSelected,
                onSelected: (_) {
                  setState(() => _religion = isSelected ? null : opt.value);
                  _updateParent();
                },
                selectedColor: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.15),
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                shape: StadiumBorder(
                  side: BorderSide(
                    color: isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).dividerColor,
                  ),
                ),
              );
            }),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UnifiedMatchPreferencesWizardPage — per-intent match preferences
// ---------------------------------------------------------------------------
class UnifiedMatchPreferencesWizardPage extends ConsumerStatefulWidget {
  final UserProfile profile;
  final List<AppIntent> selectedIntents;
  final LocalizationState l10n;
  final bool isRtl;

  const UnifiedMatchPreferencesWizardPage({
    super.key,
    required this.profile,
    required this.selectedIntents,
    required this.l10n,
    required this.isRtl,
  });

  @override
  ConsumerState<UnifiedMatchPreferencesWizardPage> createState() =>
      _UnifiedMatchPreferencesWizardPageState();
}

class _UnifiedMatchPreferencesWizardPageState
    extends ConsumerState<UnifiedMatchPreferencesWizardPage> {
  late Map<String, List<String>> _genderPreferences;
  late Map<String, List<double>> _agePreferences;
  late Map<String, Map<String, dynamic>> _lifestyleFilters;
  late Map<String, Map<String, dynamic>> _familyFilters;
  late Map<String, Map<String, dynamic>> _religionFilters;
  late Map<String, Map<String, dynamic>> _heightPrefs;

  bool _initializedDefaults = false;

  @override
  void initState() {
    super.initState();
    _initFromProfile();
  }

  void _initFromProfile() {
    final p = widget.profile;
    _genderPreferences = Map<String, List<String>>.from(
      p.genderPreferences.map((k, v) => MapEntry(k, List<String>.from(v))),
    );
    _agePreferences = Map<String, List<double>>.from(
      p.agePreferences.map((k, v) => MapEntry(k, List<double>.from(v))),
    );
    _lifestyleFilters = _cloneDynamicMap(p.lifestyleFilters);
    _familyFilters = _cloneDynamicMap(p.familyFilters);
    _religionFilters = _cloneDynamicMap(p.religionFilters);
    _heightPrefs = _cloneDynamicMap(p.heightPreferences);
  }

  Map<String, Map<String, dynamic>> _cloneDynamicMap(
    Map<String, Map<String, dynamic>> value,
  ) {
    return Map<String, Map<String, dynamic>>.from(
      value.map(
        (key, featureMap) =>
            MapEntry(key, Map<String, dynamic>.from(featureMap)),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant UnifiedMatchPreferencesWizardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile != widget.profile) {
      _initFromProfile();
      _initializedDefaults = false;
    }
  }

  void _initializeMissingPreferences(List<Map<String, String>> genderOptions) {
    bool changed = false;
    for (final intent in widget.selectedIntents) {
      final ik = intent.key;
      final isRomantic = ik.toLowerCase().contains('romantic');

      if (!_genderPreferences.containsKey(ik)) {
        _genderPreferences[ik] = genderOptions.map((g) => g['key']!).toList();
        changed = true;
      }
      if (!_agePreferences.containsKey(ik)) {
        _agePreferences[ik] = [18.0, 100.0];
        changed = true;
      }
      if (isRomantic && !_heightPrefs.containsKey(ik)) {
        _heightPrefs[ik] = {'min': 140.0, 'max': 220.0};
        changed = true;
      }
      if (_intentLifestyle(ik) && !_lifestyleFilters.containsKey(ik)) {
        _lifestyleFilters[ik] = {
          'smoking': ['any'],
          'drinking': ['any'],
          'diets': ['any'],
          'exercise': ['any'],
        };
        changed = true;
      }
      if (isRomantic && !_familyFilters.containsKey(ik)) {
        _familyFilters[ik] = {
          'has_children': ['any'],
          'wants_children': ['any'],
        };
        changed = true;
      }
      if (_intentReligion(ik) && !_religionFilters.containsKey(ik)) {
        _religionFilters[ik] = {
          'religions': ['any'],
        };
        changed = true;
      }
    }
    if (changed) _updateParent();
  }

  bool _intentLifestyle(String ik) {
    final k = ik.toLowerCase();
    return k.contains('romantic') ||
        k.contains('friend') ||
        k.contains('activity');
  }

  bool _intentReligion(String ik) {
    final k = ik.toLowerCase();
    return k.contains('romantic') || k.contains('friend');
  }

  void _updateParent() {
    final pid = widget.profile.id;
    ref
        .read(profileEditProvider(pid).notifier)
        .updateGenderAgePreferencesDraft(
          genderPreferences: _genderPreferences,
          agePreferences: _agePreferences,
        );
    ref
        .read(profileEditProvider(pid).notifier)
        .updateLifestyleFiltersDraft(_lifestyleFilters);
    ref
        .read(profileEditProvider(pid).notifier)
        .updateFamilyFiltersDraft(_familyFilters);
    ref
        .read(profileEditProvider(pid).notifier)
        .updateReligionFiltersDraft(_religionFilters);
    ref
        .read(profileEditProvider(pid).notifier)
        .updateHeightPreferencesDraft(_heightPrefs);
  }

  IconData _getIntentIcon(String intentKey) {
    final k = intentKey.toLowerCase();
    if (k.contains('romantic')) return Icons.favorite_border;
    if (k.contains('friend')) return Icons.people_outline;
    if (k.contains('business') || k.contains('network')) {
      return Icons.business_center_outlined;
    }
    if (k.contains('activity')) return Icons.directions_run_outlined;
    return Icons.person_outline;
  }

  String _formatHeight(LocalizationState l10n, int heightCm, bool useImperial) {
    if (!useImperial) {
      return '$heightCm ${l10n.getString('settingsHeightCm')}';
    }
    final totalInches = (heightCm / 2.54).round();
    return l10n
        .getString('profileHeightFeetInches')
        .replaceAll('{feet}', (totalInches ~/ 12).toString())
        .replaceAll('{inches}', (totalInches % 12).toString());
  }

  @override
  Widget build(BuildContext context) {
    final genderOptionsAsync = ref.watch(genderOptionsProvider);
    final l10n = widget.l10n;

    return genderOptionsAsync.when(
      data: (genderOptions) {
        if (genderOptions.isNotEmpty && !_initializedDefaults) {
          _initializedDefaults = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initializeMissingPreferences(genderOptions);
          });
        }

        if (widget.selectedIntents.isEmpty) {
          return Center(
            child: Text(l10n.getString('settingsNoIntentsSelected')),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
          child: ListView(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.getString('settingsMatchPreferences'),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.blue.shade50,
                    child: Icon(Icons.tune, color: Colors.blue.shade400),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.getString('profileWizardGenderAgePreferencesSubtitle'),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.black54),
              ),
              _WizardFieldLegend(l10n: l10n),
              const SizedBox(height: 20),

              // Per-intent preference cards
              ...widget.selectedIntents.map(
                (intent) => _buildIntentCard(intent, genderOptions, l10n),
              ),

              const SizedBox(height: 60),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, s) => Center(child: Text(l10n.getString('generalError'))),
    );
  }

  Widget _buildIntentCard(
    AppIntent intent,
    List<Map<String, String>> genderOptions,
    LocalizationState l10n,
  ) {
    final ik = intent.key;
    final useImperialUnits = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final selectedGenders = _genderPreferences[ik] ?? [];
    final ageList = _agePreferences[ik] ?? [18.0, 100.0];
    final rawStart = ageList.isNotEmpty ? ageList[0] : 18.0;
    final rawEnd = ageList.length > 1 ? ageList[1] : 100.0;
    final roundedStart = rawStart.round().clamp(18, 100).toDouble();
    final roundedEnd = rawEnd.round().clamp(18, 100).toDouble();
    final ageRange = roundedStart <= roundedEnd
        ? RangeValues(roundedStart, roundedEnd)
        : RangeValues(roundedEnd, roundedStart);

    final intentHeightPrefs = _heightPrefs[ik] ?? {};
    final rawMin = (intentHeightPrefs['min'] as num?)?.toDouble() ?? 140.0;
    final rawMax = (intentHeightPrefs['max'] as num?)?.toDouble() ?? 220.0;
    final heightRange = RangeValues(
      rawMin.clamp(140, 220),
      rawMax.clamp(140, 220),
    );

    final intentLifestyle = _lifestyleFilters[ik] ?? {};
    final intentFamily = _familyFilters[ik] ?? {};
    final intentReligion = _religionFilters[ik] ?? {};

    final isRomantic = ik.toLowerCase().contains('romantic');
    final isActivity = ik.toLowerCase().contains('activity');

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).shadowColor.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Intent header
          Row(
            children: [
              Icon(
                _getIntentIcon(ik),
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.getString(intent.translationKey),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Gender ──
          Text(
            '${l10n.getString('settingsPreferredGenders')} *',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: genderOptions.map((g) {
              final sel = selectedGenders.contains(g['key']);
              return FilterChip(
                label: Text(l10n.getString(g['displayKey'] ?? g['key']!)),
                selected: sel,
                onSelected: (selected) {
                  setState(() {
                    final list = List<String>.from(
                      _genderPreferences[ik] ?? [],
                    );
                    if (selected) {
                      if (!list.contains(g['key'])) list.add(g['key']!);
                    } else {
                      list.remove(g['key']);
                    }
                    _genderPreferences[ik] = list;
                  });
                  _updateParent();
                },
                selectedColor: Theme.of(
                  context,
                ).colorScheme.secondary.withValues(alpha: 0.1),
                checkmarkColor: Theme.of(context).colorScheme.secondary,
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // ── Age Range ──
          Text(
            l10n.getString('settingsPreferredAgeRange'),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          RangeSlider(
            values: ageRange,
            min: 18,
            max: 100,
            divisions: 82,
            labels: RangeLabels(
              '${ageRange.start.round()}',
              '${ageRange.end.round()}',
            ),
            onChanged: (values) {
              setState(() {
                _agePreferences[ik] = [
                  values.start.roundToDouble(),
                  values.end.roundToDouble(),
                ];
              });
              _updateParent();
            },
            activeColor: Theme.of(context).colorScheme.secondary,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${ageRange.start.round()} ${l10n.getString('generalYearsOld')}',
              ),
              Text(
                '${ageRange.end.round()} ${l10n.getString('generalYearsOld')}',
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Filter sections — collapsed by default
          if (isRomantic) ...[
            _buildExpandableSection(
              title: l10n.getString('settingsHeightRange'),
              icon: Icons.straighten,
              children: [
                RangeSlider(
                  values: heightRange,
                  min: 140,
                  max: 220,
                  divisions: 80,
                  labels: RangeLabels(
                    _formatHeight(
                      l10n,
                      heightRange.start.round(),
                      useImperialUnits,
                    ),
                    _formatHeight(
                      l10n,
                      heightRange.end.round(),
                      useImperialUnits,
                    ),
                  ),
                  onChanged: (values) {
                    setState(() {
                      _heightPrefs[ik] = {
                        'min': values.start.roundToDouble(),
                        'max': values.end.roundToDouble(),
                        'strict': false,
                      };
                    });
                    _updateParent();
                  },
                  activeColor: Theme.of(context).colorScheme.secondary,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _formatHeight(
                        l10n,
                        heightRange.start.round(),
                        useImperialUnits,
                      ),
                    ),
                    Text(
                      _formatHeight(
                        l10n,
                        heightRange.end.round(),
                        useImperialUnits,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
          if (_intentLifestyle(ik)) ...[
            _buildExpandableSection(
              title: l10n.getString('settingsLifestyleFilters'),
              icon: Icons.spa_outlined,
              children: [
                _buildMultiFilterRow(
                  l10n.getString('settingsSmoking'),
                  _filterOptions(l10n, 'smoking'),
                  _getListField(intentLifestyle, 'smoking', 'smoking'),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _lifestyleFilters[ik] ?? {},
                    );
                    m['smoking'] = v;
                    _lifestyleFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
                const SizedBox(height: 12),
                _buildMultiFilterRow(
                  l10n.getString('settingsDrinking'),
                  _filterOptions(l10n, 'drinking'),
                  _getListField(intentLifestyle, 'drinking', 'drinking'),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _lifestyleFilters[ik] ?? {},
                    );
                    m['drinking'] = v;
                    _lifestyleFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
                const SizedBox(height: 12),
                _buildMultiFilterRow(
                  l10n.getString('settingsDiet'),
                  _filterOptions(l10n, 'diet'),
                  _getListField(intentLifestyle, 'diets', 'diet'),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _lifestyleFilters[ik] ?? {},
                    );
                    m['diets'] = v;
                    _lifestyleFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
                if (isActivity) ...[
                  const SizedBox(height: 12),
                  _buildMultiFilterRow(
                    l10n.getString('settingsExercise'),
                    _filterOptions(l10n, 'exercise'),
                    _getListField(intentLifestyle, 'exercise', 'exercise'),
                    (v) {
                      final m = Map<String, dynamic>.from(
                        _lifestyleFilters[ik] ?? {},
                      );
                      m['exercise'] = v;
                      _lifestyleFilters[ik] = m;
                      _updateParent();
                      setState(() {});
                    },
                    l10n,
                  ),
                ],
              ],
            ),
          ],
          if (isRomantic) ...[
            _buildExpandableSection(
              title: l10n.getString('settingsFamilyFilters'),
              icon: Icons.family_restroom,
              children: [
                _buildMultiFilterRow(
                  l10n.getString('settingsHasChildren'),
                  _filterOptions(l10n, 'has_children'),
                  _getListField(intentFamily, 'has_children', 'has_children'),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _familyFilters[ik] ?? {},
                    );
                    m['has_children'] = v;
                    _familyFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
                const SizedBox(height: 12),
                _buildMultiFilterRow(
                  l10n.getString('settingsWantsChildren'),
                  _filterOptions(l10n, 'wants_children'),
                  _getListField(
                    intentFamily,
                    'wants_children',
                    'wants_children',
                  ),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _familyFilters[ik] ?? {},
                    );
                    m['wants_children'] = v;
                    _familyFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
              ],
            ),
          ],
          if (_intentReligion(ik)) ...[
            _buildExpandableSection(
              title: l10n.getString('settingsBeliefs'),
              icon: Icons.auto_awesome_outlined,
              children: [
                _buildMultiFilterRow(
                  '',
                  _filterOptions(l10n, 'religion'),
                  _getListField(intentReligion, 'religions', 'religion'),
                  (v) {
                    final m = Map<String, dynamic>.from(
                      _religionFilters[ik] ?? {},
                    );
                    m['religions'] = v;
                    _religionFilters[ik] = m;
                    _updateParent();
                    setState(() {});
                  },
                  l10n,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String title, IconData icon) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildExpandableSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: _buildSectionLabel(title, icon),
          initiallyExpanded: false,
          children: [...children, const SizedBox(height: 12)],
        ),
      ),
    );
  }

  Widget _buildMultiFilterRow(
    String label,
    List<_ChipOption> options,
    List<String> selectedValues,
    void Function(List<String>) onChanged,
    LocalizationState l10n,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: options.map((opt) {
            final isSelected = selectedValues.contains(opt.value);
            return FilterChip(
              label: Text(opt.label),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) {
                  if (opt.value == 'any') {
                    onChanged(['any']);
                  } else {
                    final updated = List<String>.from(selectedValues);
                    updated.remove('any');
                    if (!updated.contains(opt.value)) updated.add(opt.value);
                    onChanged(updated);
                  }
                } else {
                  final updated = List<String>.from(selectedValues);
                  updated.remove(opt.value);
                  onChanged(updated.isEmpty ? ['any'] : updated);
                }
              },
              selectedColor: Theme.of(
                context,
              ).colorScheme.secondary.withValues(alpha: 0.1),
              checkmarkColor: Theme.of(context).colorScheme.secondary,
              labelStyle: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isSelected
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: StadiumBorder(
                side: BorderSide(
                  color: isSelected
                      ? Theme.of(context).colorScheme.secondary
                      : Theme.of(context).dividerColor,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  List<String> _getListField(
    Map<String, dynamic> map,
    String key,
    String legacyKey,
  ) {
    final raw = map[key];
    if (raw is List) return raw.cast<String>();
    final legacy = map[legacyKey] as String?;
    if (legacy != null && legacy.isNotEmpty) return [legacy];
    return [];
  }

  List<_ChipOption> _filterOptions(LocalizationState l10n, String fieldKey) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: fieldKey, context: 'filter')),
            )
            .asData
            ?.value ??
        [];
    return opts.map((o) {
      final key = o.filterDisplayKey.isNotEmpty
          ? o.filterDisplayKey
          : o.profileDisplayKey;
      final val = key.isEmpty ? '' : l10n.getString(key);
      final label = (val.isNotEmpty && val != key)
          ? val
          : _humanizeSimple(o.filterValue ?? '');
      return _chipOpt(o.filterValue ?? '', label);
    }).toList();
  }

  _ChipOption _chipOpt(String value, String label) => _ChipOption(value, label);

  String _humanizeSimple(String value) {
    if (value.isEmpty) return '';
    return value[0].toUpperCase() + value.substring(1);
  }
}

class _ChipOption {
  final String value;
  final String label;
  const _ChipOption(this.value, this.label);
}
