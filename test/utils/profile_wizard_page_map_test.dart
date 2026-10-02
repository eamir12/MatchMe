import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/profile_wizard_page_map.dart';

void main() {
  test('maps the basic page sequence when no intents are selected', () {
    final pageMap = ProfileWizardPageMap(
      selectedIntentCount: 0,
      hasSocial: false,
      hasBusiness: false,
      hasRomantic: false,
      hasFriendship: false,
      hasReview: true,
    );

    expect(pageMap.indexFor(ProfileWizardSection.mainIntents), 0);
    expect(pageMap.indexFor(ProfileWizardSection.basics), 1);
    expect(pageMap.indexFor(ProfileWizardSection.details), 2);
    expect(pageMap.indexFor(ProfileWizardSection.photos), 3);
    expect(pageMap.indexFor(ProfileWizardSection.review), 6);
  });

  test('shifts fixed pages after dynamic sub-intent pages', () {
    final pageMap = ProfileWizardPageMap(
      selectedIntentCount: 1,
      hasSocial: true,
      hasBusiness: false,
      hasRomantic: false,
      hasFriendship: false,
      hasReview: false,
    );

    expect(pageMap.indexFor(ProfileWizardSection.subIntents), 1);
    expect(pageMap.indexFor(ProfileWizardSection.basics), 2);
    expect(pageMap.indexFor(ProfileWizardSection.details), 3);
    expect(pageMap.indexFor(ProfileWizardSection.photos), 4);
    expect(pageMap.indexFor(ProfileWizardSection.personalInterests), 5);
    expect(pageMap.indexFor(ProfileWizardSection.lifestyle), 6);
    expect(pageMap.indexFor(ProfileWizardSection.matchPreferences), 7);
    expect(pageMap.indexFor(ProfileWizardSection.socialLinks), 8);
  });

  test('accounts for every optional page', () {
    final pageMap = ProfileWizardPageMap(
      selectedIntentCount: 3,
      hasSocial: true,
      hasBusiness: true,
      hasRomantic: true,
      hasFriendship: true,
      hasReview: true,
    );

    expect(
      pageMap.indexFor(ProfileWizardSection.subIntents, subIntentIndex: 2),
      3,
    );
    expect(pageMap.indexFor(ProfileWizardSection.basics), 4);
    expect(pageMap.indexFor(ProfileWizardSection.personalInterests), 7);
    expect(pageMap.indexFor(ProfileWizardSection.businessInterests), 8);
    expect(pageMap.indexFor(ProfileWizardSection.lifestyle), 9);
    expect(pageMap.indexFor(ProfileWizardSection.family), 10);
    expect(pageMap.indexFor(ProfileWizardSection.religion), 11);
    expect(pageMap.indexFor(ProfileWizardSection.matchPreferences), 12);
    expect(pageMap.indexFor(ProfileWizardSection.socialLinks), 13);
    expect(pageMap.indexFor(ProfileWizardSection.review), 14);
    expect(pageMap.pageCount, 15);
  });

  test('resolves page announcements from the same dynamic map', () {
    final pageMap = ProfileWizardPageMap(
      selectedIntentCount: 2,
      hasSocial: true,
      hasBusiness: true,
      hasRomantic: true,
      hasFriendship: false,
      hasReview: true,
    );

    expect(pageMap.sectionForPage(0), ProfileWizardSection.mainIntents);
    expect(pageMap.sectionForPage(1), ProfileWizardSection.subIntents);
    expect(pageMap.sectionForPage(2), ProfileWizardSection.subIntents);
    expect(pageMap.sectionForPage(3), ProfileWizardSection.basics);
    expect(pageMap.sectionForPage(6), ProfileWizardSection.personalInterests);
    expect(pageMap.sectionForPage(7), ProfileWizardSection.businessInterests);
    expect(pageMap.sectionForPage(10), ProfileWizardSection.religion);
    expect(pageMap.sectionForPage(13), ProfileWizardSection.review);
    expect(pageMap.subIntentIndexForPage(2), 1);
    expect(pageMap.subIntentIndexForPage(3), isNull);
  });

  test('returns a negative index for omitted optional pages', () {
    final pageMap = ProfileWizardPageMap(
      selectedIntentCount: 0,
      hasSocial: false,
      hasBusiness: false,
      hasRomantic: false,
      hasFriendship: false,
      hasReview: false,
    );

    expect(pageMap.indexFor(ProfileWizardSection.personalInterests), -1);
    expect(pageMap.indexFor(ProfileWizardSection.businessInterests), -1);
    expect(pageMap.indexFor(ProfileWizardSection.family), -1);
    expect(pageMap.indexFor(ProfileWizardSection.review), -1);
  });
}
