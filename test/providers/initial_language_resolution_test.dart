import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/locale_provider.dart';

/// The initial UI language must be the device's UI language whenever the app
/// ships it, and English otherwise — resolved from the device alone, never
/// from stored preferences or the account (those are resolved by callers).
///
/// The bugs this pins:
///  * a Hebrew device reported under the legacy `iw` tag looked unsupported
///    and started in English;
///  * anything other than a clean `languageCode` comparison (case, region,
///    script) silently fell back to English instead of the device language.
void main() {
  const supported = ['en', 'es', 'he'];

  group('resolveDeviceLanguageCode', () {
    test('uses the device language when the app ships it', () {
      expect(resolveDeviceLanguageCode(supported, const Locale('en')), 'en');
      expect(resolveDeviceLanguageCode(supported, const Locale('es')), 'es');
      expect(resolveDeviceLanguageCode(supported, const Locale('he')), 'he');
    });

    test('keeps the device language despite region tags', () {
      expect(
        resolveDeviceLanguageCode(supported, const Locale('es', 'MX')),
        'es',
      );
      expect(
        resolveDeviceLanguageCode(supported, const Locale('he', 'IL')),
        'he',
      );
    });

    test('normalises legacy and malformed platform codes', () {
      // Java/Android-style legacy Hebrew tag.
      expect(resolveDeviceLanguageCode(supported, const Locale('iw')), 'he');
      // Legacy Hebrew tag with a region attached.
      expect(resolveDeviceLanguageCode(supported, const Locale('iw-IL')), 'he');
      // Legacy Indonesian tag (id may or may not be shipped by the caller).
      expect(
        resolveDeviceLanguageCode(const ['en', 'id'], const Locale('in')),
        'id',
      );
      // Case and separator variants.
      expect(resolveDeviceLanguageCode(supported, const Locale('HE')), 'he');
      expect(resolveDeviceLanguageCode(supported, const Locale('ES_mx')), 'es');
    });

    test('falls back to English for unsupported device languages', () {
      expect(resolveDeviceLanguageCode(supported, const Locale('fr')), 'en');
      expect(
        resolveDeviceLanguageCode(supported, const Locale('de', 'DE')),
        'en',
      );
    });

    test('falls back to English when the device locale is unavailable', () {
      expect(resolveDeviceLanguageCode(supported, null), 'en');
      expect(
        resolveDeviceLanguageCode(const <String>[], const Locale('he')),
        'en',
      );
    });

    test('matches supported codes case-insensitively', () {
      expect(
        resolveDeviceLanguageCode(const ['EN', 'ES'], const Locale('es')),
        'es',
      );
    });
  });

  group('kLegacyLanguageCodeAliases', () {
    test('maps legacy tags onto the shipped codes', () {
      expect(kLegacyLanguageCodeAliases['iw'], 'he');
      expect(kLegacyLanguageCodeAliases['in'], 'id');
    });
  });
}
