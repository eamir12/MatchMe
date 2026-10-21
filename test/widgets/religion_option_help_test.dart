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
}) {
  return AppProfileOption(
    fieldKey: fieldKey,
    optionKey: optionKey,
    profileValue: profileValue,
    filterValue: profileValue.toLowerCase(),
    profileDisplayKey: displayKey,
    filterDisplayKey: displayKey,
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
      overrides: [
        profileOptionsProvider.overrideWith((ref) async => options),
      ],
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

void main() {
  final options = [
    _option(
      fieldKey: 'religion',
      optionKey: 'christianity',
      profileValue: 'Christianity',
      displayKey: 'religionChristianity',
    ),
    _option(
      fieldKey: 'religion',
      optionKey: 'atheist',
      profileValue: 'Atheist',
      displayKey: 'religionAtheist',
    ),
    _option(
      fieldKey: 'denomination',
      optionKey: 'christianity__catholic',
      profileValue: 'christianity__catholic',
      displayKey: 'denominationChristianityCatholic',
    ),
    _option(
      fieldKey: 'denomination',
      optionKey: 'christianity__protestant',
      profileValue: 'christianity__protestant',
      displayKey: 'denominationChristianityProtestant',
    ),
    _option(
      fieldKey: 'practice',
      optionKey: 'weekly',
      profileValue: 'weekly',
      displayKey: 'practiceWeekly',
    ),
  ];

  testWidgets('religion help sheet shows option explanations', (tester) async {
    await _pumpPage(
      tester,
      profile: _profile(
        religion: const {
          'religion': 'Christianity',
          'practice': 'weekly',
        },
      ),
      options: options,
    );

    expect(find.text('What do these mean?'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('profileReligion_help')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'A monotheistic faith centered on Jesus Christ and his teachings, '
        'with many traditions and denominations.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('A person who does not believe in God or gods.'),
      findsOneWidget,
    );

    Navigator.of(tester.element(find.text('What do these mean?').first)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('profileDenomination_help')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The largest Christian tradition, led by the Pope and emphasizing '
        'sacraments, tradition, and apostolic succession.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('practice is hidden for non-practising beliefs', (tester) async {
    await _pumpPage(
      tester,
      profile: _profile(
        religion: const {'religion': 'Atheist', 'practice': 'weekly'},
      ),
      options: options,
    );

    expect(
      find.text('How often do you engage in religious or spiritual practices?'),
      findsNothing,
    );
  });
}
