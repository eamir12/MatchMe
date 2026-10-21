import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/translation_text_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('TranslationTextCache', () {
    test('the key is stable across runs (content hash, not hashCode)', () {
      const text = 'The verification photo shows a different individual.';
      final first = TranslationTextCache.cacheKey(text, 'he');
      final second = TranslationTextCache.cacheKey(text, 'he');
      expect(first, second);
      // A different language is a different entry.
      expect(TranslationTextCache.cacheKey(text, 'es'), isNot(first));
      // A different text is a different entry.
      expect(TranslationTextCache.cacheKey('$text!', 'he'), isNot(first));
    });

    test('a translation is requested only once and then reused', () async {
      const text = 'The verification photo shows a different individual.';
      final cache = TranslationTextCache();
      var calls = 0;
      Future<String> translate() async {
        calls++;
        return 'התמונה שונה';
      }

      final first = await cache.translate(text, 'he', translate);
      final second = await cache.translate(text, 'he', translate);

      expect(first, 'התמונה שונה');
      expect(second, 'התמונה שונה');
      expect(calls, 1, reason: 'the text must not be sent to DeepL twice');
    });

    test('concurrent callers share one request', () async {
      const text = 'Eye shape does not match.';
      final cache = TranslationTextCache();
      var calls = 0;
      Future<String> translate() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'מבנה העיניים אינו תואם';
      }

      final results = await Future.wait([
        cache.translate(text, 'he', translate),
        cache.translate(text, 'he', translate),
        cache.translate(text, 'he', translate),
      ]);

      expect(results, everyElement('מבנה העיניים אינו תואם'));
      expect(calls, 1, reason: 'one text must not be sent to DeepL twice');
    });

    test('the translation survives a restart (it is stored on the device)', () async {
      const text = 'The nose bridge does not match.';
      var calls = 0;
      Future<String> translate() async {
        calls++;
        return 'גשר האף אינו תואם';
      }

      await TranslationTextCache().translate(text, 'he', translate);
      expect(calls, 1);

      // A fresh instance (as after an app restart) still finds the copy.
      final afterRestart = TranslationTextCache();
      final stored = await afterRestart.read(text, 'he');
      expect(stored, 'גשר האף אינו תואם');

      final again = await afterRestart.translate(text, 'he', translate);
      expect(again, 'גשר האף אינו תואם');
      expect(calls, 1, reason: 'a restart must not re-send the text');
    });

    test('a failed translation (the untranslated text) is not cached', () async {
      const text = 'The eye shape does not match.';
      final cache = TranslationTextCache();
      var calls = 0;
      Future<String> translate() async {
        calls++;
        // A failed request comes back as the source text.
        return text;
      }

      await cache.translate(
        text,
        'he',
        translate,
        shouldCache: (translated) => translated != text,
      );
      expect(await cache.read(text, 'he'), isNull);

      // The next attempt tries again instead of showing the cached failure.
      await cache.translate(
        text,
        'he',
        translate,
        shouldCache: (translated) => translated != text,
      );
      expect(calls, 2);
    });

    test('a legacy entry is adopted instead of being re-translated', () async {
      const text = 'The mouth shape does not match.';
      const legacyKey = 'gemini_reasoning_12345_he';
      SharedPreferences.setMockInitialValues({legacyKey: 'צורת הפה אינה תואמת'});

      var calls = 0;
      Future<String> translate() async {
        calls++;
        return 'should not be used';
      }

      final result = await TranslationTextCache().translate(
        text,
        'he',
        translate,
        legacyStorageKey: legacyKey,
      );

      expect(result, 'צורת הפה אינה תואמת');
      expect(calls, 0, reason: 'the legacy copy must be reused');
    });

    test('the stored entry is a plain string under a content-hash key', () async {
      const text = 'The cheekbone structure does not match.';
      await TranslationTextCache().translate(text, 'he', () async => 'מתורגם');

      final prefs = await SharedPreferences.getInstance();
      final key = TranslationTextCache.storageKey(text, 'he');
      expect(prefs.getString(key), 'מתורגם');
      // The key is derived from the content, so it survives an app restart.
      expect(key, contains(sha256.convert(utf8.encode(text)).toString()));
    });
  });
}
