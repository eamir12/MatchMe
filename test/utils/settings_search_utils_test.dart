import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/settings_search_utils.dart';

void main() {
  test('empty settings queries match a destination', () {
    expect(
      matchesSettingsSearch(
        query: '   ',
        label: 'App display',
        description:
            'Adjust language, currency, units, time format, and theme.',
      ),
      isTrue,
    );
  });

  test('settings search matches labels case-insensitively', () {
    expect(
      matchesSettingsSearch(
        query: 'APP DISPLAY',
        label: 'App display',
        description:
            'Adjust language, currency, units, time format, and theme.',
      ),
      isTrue,
    );
  });

  test('settings search matches destination descriptions', () {
    expect(
      matchesSettingsSearch(
        query: 'password',
        label: 'Account management',
        description:
            'Change your password, update your email, or delete your account.',
      ),
      isTrue,
    );
    expect(
      matchesSettingsSearch(
        query: 'theme',
        label: 'App display',
        description:
            'Adjust language, currency, units, time format, and theme.',
      ),
      isTrue,
    );
  });

  test('settings search rejects unrelated queries', () {
    expect(
      matchesSettingsSearch(
        query: 'spaceship',
        label: 'App display',
        description:
            'Adjust language, currency, units, time format, and theme.',
      ),
      isFalse,
    );
  });
}
