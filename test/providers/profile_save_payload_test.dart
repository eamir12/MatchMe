import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';

UserProfile _profile({
  Map<String, dynamic>? religion,
  Map<String, dynamic>? lifestyle,
  Map<String, dynamic>? family,
  String? bio,
  int? height,
  String? occupation,
  String? education,
}) {
  return UserProfile(
    id: 'user-1',
    name: 'Dana Levi',
    preferredLanguage: 'en',
    activeModes: const ['romantic'],
    subIntents: const {},
    personalInterests: const {},
    businessInterests: const {},
    languagesKnown: const {},
    subscriptionTier: 'free',
    isProfileComplete: true,
    matchRadiusDefault: 50,
    gpsIntervalDefault: 5,
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
    photos: const ['photos/user-1/primary.jpg'],
    religion: religion,
    lifestyle: lifestyle,
    family: family,
    bio: bio,
    height: height,
    occupation: occupation,
    education: education,
  );
}

void main() {
  group('UserProfile.toJsonForProfileTableSave', () {
    test('keeps cleared optional fields as explicit nulls', () {
      final payload = _profile().toJsonForProfileTableSave();

      // An omitted key means "leave unchanged" in a PostgREST upsert. The
      // wizard relies on explicit nulls to persist removals.
      for (final key in const [
        'religion',
        'lifestyle',
        'family',
        'bio',
        'height',
        'occupation',
        'education',
        'languages_known',
        'personal_interests',
        'business_interests',
        'instagram_url',
        'linkedin_url',
        'facebook_url',
      ]) {
        expect(
          payload.containsKey(key),
          isTrue,
          reason: '$key must be present so clearing it reaches the server',
        );
        expect(payload[key], isNull, reason: '$key should be null');
      }

      expect(payload['intent_preferences'], isEmpty);
    });

    test('keeps set values unchanged', () {
      final payload = _profile(
        religion: const {'religion': 'Christianity'},
        lifestyle: const {'smoking': 'never'},
        family: const {'wants_children': 'yes'},
        bio: 'Hello',
        height: 180,
        occupation: 'Engineer',
        education: 'BSc',
      ).toJsonForProfileTableSave();

      expect(payload['religion'], const {'religion': 'Christianity'});
      expect(payload['lifestyle'], const {'smoking': 'never'});
      expect(payload['family'], const {'wants_children': 'yes'});
      expect(payload['bio'], 'Hello');
      expect(payload['height'], 180);
      expect(payload['occupation'], 'Engineer');
      expect(payload['education'], 'BSc');
    });

    test('never rewrites approved_primary_photos', () {
      final payload = _profile().toJsonForProfileTableSave();
      expect(payload.containsKey('approved_primary_photos'), isFalse);
    });
  });
}
