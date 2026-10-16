// lib/utils/profile_completeness.dart
//
// Profile completeness scoring (Dart mirror).
//
// IMPORTANT: This file mirrors the SQL scoring rules in
//   supabase/migrations/20262117000000_profile_completeness_score.sql
//   (public.profile_completeness_score).
// Any change to weights, applicability or done-rules MUST be applied to both
// sides so the UI and the stored user_profiles.profile_completeness value
// never disagree.
//
// Design notes:
//   * Required fields earn partial credit (1-2 photos = 10/20) so every
//     completed profile starts with "endowed progress" (goal-gradient effect).
//   * Items that do not apply to a user's active intents are excluded from
//     BOTH the earned and the maximum, so 100% stays reachable for every
//     intent mix. Applicability mirrors the wizard's ProfileWizardPageMap
//     (lib/utils/profile_wizard_page_map.dart):
//       - personal interests, lifestyle: social intents (any non-business)
//       - business interests: business intent
//       - family, height: romantic intent
//       - religion: romantic or friendship intent
//   * Zodiac is deliberately NOT scored: it is auto-derived for display and
//     never persisted by the wizard.

import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';

class ProfileCompletenessItem {
  const ProfileCompletenessItem({
    required this.section,
    required this.labelKey,
    required this.maxPoints,
    required this.earnedPoints,
  });

  /// Wizard section a user should open to complete this item.
  final ProfileWizardSection section;

  /// Localization key for the checklist label.
  final String labelKey;

  final int maxPoints;
  final int earnedPoints;

  bool get done => earnedPoints >= maxPoints;

  /// Points still available for this item (0 when done).
  int get remainingPoints => done ? 0 : (maxPoints - earnedPoints);
}

class ProfileCompleteness {
  ProfileCompleteness._();

  static const int fullScore = 100;

  static String _normalizeKey(String k) => k
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  static bool _hasIntent(UserProfile p, bool Function(String norm) test) =>
      p.activeModes.any((m) => test(_normalizeKey(m)));

  static bool _hasAnyInterest(Map<String, List<String>> interests) =>
      interests.values.any((v) => v.isNotEmpty);

  static bool _isNonEmptyMap(Map<String, dynamic>? m) =>
      m != null && m.isNotEmpty;

  static bool _isNonEmptyText(String? t) => (t ?? '').trim().isNotEmpty;

  /// All scored items in wizard page order (the order the checklist renders).
  static List<ProfileCompletenessItem> items(UserProfile profile) {
    final hasSocial = _hasIntent(profile, (n) => n != 'business_networking');
    final hasBusiness = _hasIntent(profile, (n) => n == 'business_networking');
    final hasRomantic = _hasIntent(profile, (n) => n == 'romantic');
    final hasFriendship = _hasIntent(profile, (n) => n == 'friendship');

    final photoCount = profile.photos.length;
    final languageCount =
        profile.languagesKnown.values.where((v) => v.isNotEmpty).length;

    return [
      ProfileCompletenessItem(
        section: ProfileWizardSection.photos,
        labelKey: 'profileCompletionItemPhotos',
        maxPoints: 20,
        earnedPoints: photoCount >= 3 ? 20 : (photoCount >= 1 ? 10 : 0),
      ),
      ProfileCompletenessItem(
        section: ProfileWizardSection.details,
        labelKey: 'profileCompletionItemBio',
        maxPoints: 15,
        earnedPoints: _isNonEmptyText(profile.bio) ? 15 : 0,
      ),
      if (hasSocial)
        ProfileCompletenessItem(
          section: ProfileWizardSection.personalInterests,
          labelKey: 'profileCompletionItemPersonalInterests',
          maxPoints: 5,
          earnedPoints: _hasAnyInterest(profile.personalInterests) ? 5 : 0,
        ),
      if (hasBusiness)
        ProfileCompletenessItem(
          section: ProfileWizardSection.businessInterests,
          labelKey: 'profileCompletionItemBusinessInterests',
          maxPoints: 5,
          earnedPoints: _hasAnyInterest(profile.businessInterests) ? 5 : 0,
        ),
      if (hasSocial)
        ProfileCompletenessItem(
          section: ProfileWizardSection.lifestyle,
          labelKey: 'profileCompletionItemLifestyle',
          maxPoints: 10,
          earnedPoints: _isNonEmptyMap(profile.lifestyle) ? 10 : 0,
        ),
      if (hasRomantic)
        ProfileCompletenessItem(
          section: ProfileWizardSection.family,
          labelKey: 'profileCompletionItemFamily',
          maxPoints: 10,
          earnedPoints: _isNonEmptyMap(profile.family) ? 10 : 0,
        ),
      if (hasRomantic || hasFriendship)
        ProfileCompletenessItem(
          section: ProfileWizardSection.religion,
          labelKey: 'profileCompletionItemReligion',
          maxPoints: 10,
          earnedPoints: _isNonEmptyMap(profile.religion) ? 10 : 0,
        ),
      ProfileCompletenessItem(
        section: ProfileWizardSection.details,
        labelKey: 'profileCompletionItemOccupation',
        maxPoints: 5,
        earnedPoints: _isNonEmptyText(profile.occupation) ? 5 : 0,
      ),
      ProfileCompletenessItem(
        section: ProfileWizardSection.details,
        labelKey: 'profileCompletionItemEducation',
        maxPoints: 5,
        earnedPoints: _isNonEmptyText(profile.education) ? 5 : 0,
      ),
      if (hasRomantic)
        ProfileCompletenessItem(
          section: ProfileWizardSection.details,
          labelKey: 'profileCompletionItemHeight',
          maxPoints: 5,
          earnedPoints: profile.height != null ? 5 : 0,
        ),
      ProfileCompletenessItem(
        section: ProfileWizardSection.socialLinks,
        labelKey: 'profileCompletionItemSocial',
        maxPoints: 5,
        earnedPoints:
            (_isNonEmptyText(profile.instagramUrl) ||
                _isNonEmptyText(profile.linkedinUrl) ||
                _isNonEmptyText(profile.facebookUrl))
            ? 5
            : 0,
      ),
      ProfileCompletenessItem(
        section: ProfileWizardSection.socialLinks,
        labelKey: 'profileCompletionItemLanguages',
        maxPoints: 5,
        earnedPoints: languageCount >= 2 ? 5 : 0,
      ),
    ];
  }

  /// Maximum points the user can currently reach (intent-aware).
  static int applicableMax(UserProfile profile) =>
      items(profile).fold(0, (sum, i) => sum + i.maxPoints);

  static int earnedPoints(UserProfile profile) =>
      items(profile).fold(0, (sum, i) => sum + i.earnedPoints);

  /// Locally computed 0-100 score (mirror of the SQL function).
  static int score(UserProfile profile) {
    final max = applicableMax(profile);
    if (max <= 0) return 0;
    final raw = ((100 * earnedPoints(profile)) / max).round();
    if (raw < 0) return 0;
    if (raw > fullScore) return fullScore;
    return raw;
  }

  /// Server-cached score when available (user_profiles.profile_completeness),
  /// otherwise the locally computed mirror. The SQL trigger is the source of
  /// truth once the row has synced.
  static int effectiveScore(UserProfile profile) =>
      profile.profileCompleteness ?? score(profile);

  static bool isFull(UserProfile profile) =>
      effectiveScore(profile) >= fullScore;

  /// Unfinished items in wizard page order (what the checklist shows).
  static List<ProfileCompletenessItem> remainingItems(UserProfile profile) =>
      items(profile).where((i) => !i.done).toList(growable: false);
}
