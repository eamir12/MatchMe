import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';

UserProfile _profile({Map<String, dynamic>? religion}) {
  return UserProfile(
    id: 'test-user',
    name: 'Test User',
    preferredLanguage: 'en',
    activeModes: const ['romantic'],
    subIntents: const {},
    personalInterests: const {},
    businessInterests: const {},
    languagesKnown: const {},
    subscriptionTier: 'free',
    isProfileComplete: true,
    matchRadiusDefault: 10,
    gpsIntervalDefault: 60,
    smartGpsThrottlingEnabled: false,
    sharedEventMatchingEnabled: false,
    sharedMovementMatchingEnabled: false,
    editableProfileFields: const [],
    genderPreferences: const {},
    agePreferences: const {},
    lifestyleFilters: const {},
    familyFilters: const {},
    religionFilters: const {},
    heightPreferences: const {},
    photos: const [],
    religion: religion,
  );
}

AppProfileOption _option({
  required String fieldKey,
  required String optionKey,
  required String profileValue,
  required String displayKey,
  int sortOrder = 0,
}) {
  return AppProfileOption(
    fieldKey: fieldKey,
    optionKey: optionKey,
    profileValue: profileValue,
    filterValue: profileValue.toLowerCase(),
    profileDisplayKey: displayKey,
    filterDisplayKey: displayKey,
    profileSortOrder: sortOrder,
    filterSortOrder: sortOrder,
  );
}

LocalizationState _l10n() {
  return LocalizationState(
    currentLocale: const Locale('en'),
    textDirection: TextDirection.ltr,
    strings: const {},
    supportedLanguages: const [],
  );
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required UserProfile profile,
  required List<AppProfileOption> options,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [profileOptionsProvider.overrideWith((ref) async => options)],
      child: MaterialApp(
        home: Scaffold(
          body: ReligionWizardPage(
            profile: profile,
            l10n: _l10n(),
            isRtl: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The chip keys of a field, in the order they are rendered.
List<String> _chipValues(WidgetTester tester, String fieldKey) {
  final keys = <String>[];
  for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
    final key = chip.key;
    if (key is! ValueKey<String>) continue;
    if (!key.value.startsWith('${fieldKey}_')) continue;
    keys.add(key.value.substring(fieldKey.length + 1));
  }
  return keys;
}

void main() {
  testWidgets('"Other" is always the last religion option', (tester) async {
    final options = [
      // The catch-all is deliberately stored before the other religions.
      _option(
        fieldKey: 'religion',
        optionKey: 'other',
        profileValue: 'Other',
        displayKey: 'religionOther',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'christianity',
        profileValue: 'Christianity',
        displayKey: 'religionChristianity',
        sortOrder: 2,
      ),
      _option(
        fieldKey: 'religion',
        optionKey: 'islam',
        profileValue: 'Islam',
        displayKey: 'religionIslam',
        sortOrder: 3,
      ),
    ];

    await _pumpPage(tester, profile: _profile(), options: options);

    expect(_chipValues(tester, 'profileReligion'), [
      'Christianity',
      'Islam',
      'Other',
    ]);
  });

  testWidgets('the "other" branch is the last denomination option', (
    tester,
  ) async {
    final options = [
      _option(
        fieldKey: 'religion',
        optionKey: 'christianity',
        profileValue: 'Christianity',
        displayKey: 'religionChristianity',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'denomination',
        optionKey: 'christianity__other',
        profileValue: 'christianity__other',
        displayKey: 'denominationChristianityOther',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'denomination',
        optionKey: 'christianity__catholic',
        profileValue: 'christianity__catholic',
        displayKey: 'denominationChristianityCatholic',
        sortOrder: 2,
      ),
    ];

    await _pumpPage(
      tester,
      profile: _profile(religion: const {'religion': 'Christianity'}),
      options: options,
    );

    expect(_chipValues(tester, 'profileDenomination'), [
      'christianity__catholic',
      'christianity__other',
    ]);
  });

  testWidgets('practice options run from least often to most often', (
    tester,
  ) async {
    final options = [
      _option(
        fieldKey: 'religion',
        optionKey: 'christianity',
        profileValue: 'Christianity',
        displayKey: 'religionChristianity',
        sortOrder: 1,
      ),
      // Stored most often first, as the options table ships them.
      _option(
        fieldKey: 'practice',
        optionKey: 'daily',
        profileValue: 'daily',
        displayKey: 'practiceDaily',
        sortOrder: 1,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'weekly',
        profileValue: 'weekly',
        displayKey: 'practiceWeekly',
        sortOrder: 2,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'monthly',
        profileValue: 'monthly',
        displayKey: 'practiceMonthly',
        sortOrder: 3,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'few_times_a_year',
        profileValue: 'few_times_a_year',
        displayKey: 'practiceFewTimesAYear',
        sortOrder: 4,
      ),
      _option(
        fieldKey: 'practice',
        optionKey: 'rarely_or_never',
        profileValue: 'rarely_or_never',
        displayKey: 'practiceRarelyOrNever',
        sortOrder: 5,
      ),
    ];

    await _pumpPage(
      tester,
      profile: _profile(religion: const {'religion': 'Christianity'}),
      options: options,
    );

    expect(_chipValues(tester, 'profileReligiousPractice'), [
      'rarely_or_never',
      'few_times_a_year',
      'monthly',
      'weekly',
      'daily',
    ]);
  });
}
