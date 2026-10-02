import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Unit tests for the translation version-marker invariant that guarantees
/// each (text, target language) goes to DeepL exactly once:
/// a stored translation is reused only when the marker recorded at
/// translation time still matches the row's current `edited_at`.
///
/// The same invariant guards the Recent Chats preview cache
/// (`previewTranslationIsCurrent`), which is what a peer edit invalidates when
/// the message is also the chat's last one.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      debug: false,
    );
  });

  group('translationEditMarkersMatch', () {
    test('treats never-edited rows as current', () {
      expect(translationEditMarkersMatch(null, null), isTrue);
      expect(translationEditMarkersMatch('', ''), isTrue);
      expect(translationEditMarkersMatch('null', null), isTrue);
    });

    test('detects edits, including pre-migration backlog rows', () {
      // Translation stored with no marker, row edited since.
      expect(
        translationEditMarkersMatch(null, '2026-09-27T18:12:09.196523+00:00'),
        isFalse,
      );
      // Marker stamped at translation time, row edited afterwards.
      expect(
        translationEditMarkersMatch(
          '2026-09-27T17:51:03.094124+00:00',
          '2026-09-27T18:12:09.196523+00:00',
        ),
        isFalse,
      );
    });

    test('accepts equal instants despite formatting drift', () {
      expect(
        translationEditMarkersMatch(
          '2026-09-27T18:12:09.196523+00:00',
          '2026-09-27T18:12:09.196523+00:00',
        ),
        isTrue,
      );
      expect(
        translationEditMarkersMatch(
          '2026-09-27T18:12:09.196523+00:00',
          '2026-09-27T18:12:09.196523Z',
        ),
        isTrue,
      );
    });

    test('fails safe on garbage (retranslate, never serve stale)', () {
      expect(
        translationEditMarkersMatch(
          'not-a-date',
          '2026-09-27T18:12:09.196523+00:00',
        ),
        isFalse,
      );
      expect(
        translationEditMarkersMatch(
          '2026-09-27T18:12:09.196523+00:00',
          'also-not-a-date',
        ),
        isFalse,
      );
    });
  });

  group('normalizeEditMarker', () {
    test('collapses every spelling of "never edited" to null', () {
      expect(normalizeEditMarker(null), isNull);
      expect(normalizeEditMarker(''), isNull);
      expect(normalizeEditMarker('   '), isNull);
      expect(normalizeEditMarker('null'), isNull);
    });

    test('passes timestamps through from either transport', () {
      // Hive round trips give a string; PostgREST gives a DateTime.
      expect(
        normalizeEditMarker('2026-09-27T18:12:09.196523+00:00'),
        '2026-09-27T18:12:09.196523+00:00',
      );
      final dt = DateTime.utc(2026, 9, 27, 18, 12, 9, 196, 523);
      expect(normalizeEditMarker(dt), dt.toIso8601String());
    });
  });

  group('previewTranslationIsCurrent', () {
    String normalize(String code) => code.toLowerCase().split('-').first;

    const translated = 'Hola, ¿cómo estás?';
    const beforeEdit = '2026-09-27T17:51:03.094124+00:00';
    const afterEdit = '2026-09-27T18:12:09.196523+00:00';

    bool check({
      String? text = translated,
      String? target = 'es',
      String? cachedMarker,
      String? messageMarker,
    }) {
      return previewTranslationIsCurrent(
        cachedText: text,
        cachedTargetLanguage: target,
        cachedEditedAt: cachedMarker,
        messageEditedAt: messageMarker,
        uiLanguage: 'es',
        normalizeLanguage: normalize,
      );
    }

    test('reuses a cached preview for an unedited message', () {
      expect(check(), isTrue);
    });

    test('reuses it after an edit once it was retranslated', () {
      // The translation was produced *after* the edit, so the marker recorded
      // at translation time is the row's current edited_at.
      expect(check(cachedMarker: afterEdit, messageMarker: afterEdit), isTrue);
    });

    test('rejects a preview translated before the message was edited', () {
      // This is the reported bug: the message id is unchanged by an edit, so
      // without the marker a pre-edit translation looked perfectly valid and
      // kept rendering in the Recent Chats row.
      expect(
        check(cachedMarker: beforeEdit, messageMarker: afterEdit),
        isFalse,
      );
    });

    test('rejects a preview with no marker once the message is edited', () {
      expect(check(cachedMarker: null, messageMarker: afterEdit), isFalse);
    });

    test('rejects a preview for another UI language', () {
      expect(
        check(target: 'he', cachedMarker: null, messageMarker: null),
        isFalse,
      );
    });

    test('rejects a missing or empty preview', () {
      expect(check(text: null), isFalse);
      expect(check(text: ''), isFalse);
      expect(check(text: 'null'), isFalse);
    });

    test('normalizes language case and region subtags', () {
      expect(check(target: 'ES'), isTrue);
      expect(check(target: 'es-ES'), isTrue);
    });
  });
}
