import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/utils/string_extensions.dart';

enum ProfileWizardSection {
  mainIntents,
  subIntents,
  basics,
  details,
  photos,
  personalInterests,
  businessInterests,
  lifestyle,
  family,
  religion,
  matchPreferences,
  socialLinks,
  review,
}

class ProfileWizardPageMap {
  final int selectedIntentCount;
  final bool hasSocial;
  final bool hasBusiness;
  final bool hasRomantic;
  final bool hasFriendship;
  final bool hasReview;

  late final int mainIntentsIndex;
  late final int subIntentStart;
  late final int subIntentEnd;
  late final int basicsIndex;
  late final int detailsIndex;
  late final int photosIndex;
  late final int personalInterestsIndex;
  late final int businessInterestsIndex;
  late final int lifestyleIndex;
  late final int familyIndex;
  late final int religionIndex;
  late final int matchPreferencesIndex;
  late final int socialLinksIndex;
  late final int reviewIndex;

  ProfileWizardPageMap({
    required this.selectedIntentCount,
    required this.hasSocial,
    required this.hasBusiness,
    required this.hasRomantic,
    required this.hasFriendship,
    required this.hasReview,
  }) {
    mainIntentsIndex = 0;
    subIntentStart = 1;
    subIntentEnd = subIntentStart + selectedIntentCount;
    basicsIndex = subIntentEnd;
    detailsIndex = basicsIndex + 1;
    photosIndex = detailsIndex + 1;

    var nextIndex = photosIndex + 1;
    personalInterestsIndex = hasSocial ? nextIndex++ : -1;
    businessInterestsIndex = hasBusiness ? nextIndex++ : -1;
    lifestyleIndex = hasSocial ? nextIndex++ : -1;
    familyIndex = hasRomantic ? nextIndex++ : -1;
    religionIndex = hasRomantic || hasFriendship ? nextIndex++ : -1;
    matchPreferencesIndex = nextIndex++;
    socialLinksIndex = nextIndex++;
    reviewIndex = hasReview ? nextIndex : -1;
  }

  int indexFor(ProfileWizardSection section, {int? subIntentIndex}) {
    return switch (section) {
      ProfileWizardSection.mainIntents => mainIntentsIndex,
      ProfileWizardSection.subIntents =>
        subIntentIndex == null
            ? subIntentStart
            : subIntentStart + subIntentIndex,
      ProfileWizardSection.basics => basicsIndex,
      ProfileWizardSection.details => detailsIndex,
      ProfileWizardSection.photos => photosIndex,
      ProfileWizardSection.personalInterests => personalInterestsIndex,
      ProfileWizardSection.businessInterests => businessInterestsIndex,
      ProfileWizardSection.lifestyle => lifestyleIndex,
      ProfileWizardSection.family => familyIndex,
      ProfileWizardSection.religion => religionIndex,
      ProfileWizardSection.matchPreferences => matchPreferencesIndex,
      ProfileWizardSection.socialLinks => socialLinksIndex,
      ProfileWizardSection.review => reviewIndex,
    };
  }

  ProfileWizardSection? sectionForPage(int pageIndex) {
    if (pageIndex == mainIntentsIndex) return ProfileWizardSection.mainIntents;
    if (pageIndex >= subIntentStart && pageIndex < subIntentEnd) {
      return ProfileWizardSection.subIntents;
    }
    if (pageIndex == basicsIndex) return ProfileWizardSection.basics;
    if (pageIndex == detailsIndex) return ProfileWizardSection.details;
    if (pageIndex == photosIndex) return ProfileWizardSection.photos;
    if (pageIndex == personalInterestsIndex) {
      return ProfileWizardSection.personalInterests;
    }
    if (pageIndex == businessInterestsIndex) {
      return ProfileWizardSection.businessInterests;
    }
    if (pageIndex == lifestyleIndex) return ProfileWizardSection.lifestyle;
    if (pageIndex == familyIndex) return ProfileWizardSection.family;
    if (pageIndex == religionIndex) return ProfileWizardSection.religion;
    if (pageIndex == matchPreferencesIndex) {
      return ProfileWizardSection.matchPreferences;
    }
    if (pageIndex == socialLinksIndex) return ProfileWizardSection.socialLinks;
    if (pageIndex == reviewIndex) return ProfileWizardSection.review;
    return null;
  }

  int? subIntentIndexForPage(int pageIndex) {
    if (pageIndex < subIntentStart || pageIndex >= subIntentEnd) return null;
    return pageIndex - subIntentStart;
  }

  int get pageCount {
    if (reviewIndex >= 0) return reviewIndex + 1;
    return socialLinksIndex + 1;
  }
}

String _normalizedIntentKey(String k) => k
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

/// Returns the first critical gap in [profile] — a required field or photo
/// the profile wizard itself enforces before a profile can be saved — or
/// null when nothing critical is missing. Sections are checked in wizard
/// page order so the result can be handed to [ProfileWizardScreen] as the
/// page to open directly (completeness routing at app startup/resume).
///
/// Deliberately mirrors the checks in the wizard's submit validation plus
/// the photo requirement; softer rules (bio, languages, match prefs) do not
/// bounce a completed user out of the app.
ProfileWizardSection? profileCriticalGapSection(UserProfile profile) {
  final hasBusiness = profile.activeModes.any(
    (m) => _normalizedIntentKey(m) == 'business_networking',
  );
  final hasSocial = profile.activeModes.any(
    (m) => _normalizedIntentKey(m) != 'business_networking',
  );

  // [0] Main intents.
  if (profile.activeModes.isEmpty) {
    return ProfileWizardSection.mainIntents;
  }

  // [1..n] Sub-intents: every selected intent needs at least one sub-intent.
  for (final mode in profile.activeModes) {
    final modeKey = mode.trim().toLowerCase();
    final hasSub = profile.subIntents.entries.any(
      (e) =>
          e.key.trim().toLowerCase() == modeKey &&
          e.value.isNotEmpty,
    );
    if (!hasSub) return ProfileWizardSection.subIntents;
  }

  // Basics: name and date of birth. A single-word name is a critical gap:
  // the product has no display format for it, so the wizard must collect the
  // missing first or last name before the profile can be used.
  if (profile.name.trim().isEmpty) return ProfileWizardSection.basics;
  if (!profile.name.hasFirstAndLastName) return ProfileWizardSection.basics;
  if (profile.dateOfBirth == null) return ProfileWizardSection.basics;

  // Details: occupation/education are mandatory for Business/Networking.
  if (hasBusiness) {
    if ((profile.occupation ?? '').trim().isEmpty) {
      return ProfileWizardSection.details;
    }
    if ((profile.education ?? '').trim().isEmpty) {
      return ProfileWizardSection.details;
    }
  }

  // Photos: at least one photo must exist. (AI approval of the primary is
  // enforced at save time — see saveProfile — and cannot be judged from a
  // profile snapshot here.)
  if (profile.photos.isEmpty) return ProfileWizardSection.photos;

  // Interests: each intent bucket needs at least one non-empty interest.
  final hasPersonalInterest = profile.personalInterests.values.any(
    (v) => v.isNotEmpty,
  );
  final hasBusinessInterest = profile.businessInterests.values.any(
    (v) => v.isNotEmpty,
  );
  if (hasSocial && !hasPersonalInterest) {
    return ProfileWizardSection.personalInterests;
  }
  if (hasBusiness && !hasBusinessInterest) {
    return ProfileWizardSection.businessInterests;
  }

  return null;
}
