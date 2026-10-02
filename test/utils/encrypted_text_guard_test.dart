import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_model.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/utils/encrypted_text_guard.dart';

void main() {
  group('looksLikeEncryptedBlob', () {
    // Captured verbatim from a chat list that rendered a translated message in
    // its encrypted form. This is chat_messages.content_translated_encrypted.
    const leakedBlob =
        'cjFa3e0sBTRmfbIsI3+KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8=';

    test('detects the base64 AES-GCM blob that leaked into the chat list', () {
      expect(looksLikeEncryptedBlob(leakedBlob), isTrue);
    });

    test('detects blobs without a trailing = padding character', () {
      expect(
        looksLikeEncryptedBlob(
          'cjFa3e0sBTRmfbIsI3KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8',
        ),
        isTrue,
      );
    });

    test('detects a shorter wrapped-key sized blob', () {
      expect(
        looksLikeEncryptedBlob('8J7vQ2mB0kZsT4xLwPn9RaKdYfHcUgE6'),
        isTrue,
      );
    });

    test('does not flag ordinary chat text', () {
      const messages = [
        'Hola, ¿cómo estás?',
        'מה קורה?',
        'היי, 46 · מדריך אישה',
        'אני מבולד 😜',
        'See you at 8pm tomorrow, bring the tickets!',
        'https://example.com/invite/abc123def456',
        'Order #A1B2C3D4E5F6 was shipped',
        'Loading…',
        'null',
      ];
      for (final message in messages) {
        expect(
          looksLikeEncryptedBlob(message),
          isFalse,
          reason: 'false positive on readable text: "$message"',
        );
      }
    });

    test(
      'does not flag long single-token words (entropy, not length alone)',
      () {
        expect(
          looksLikeEncryptedBlob('helloworldthisisalongusername'),
          isFalse,
        );
        expect(
          looksLikeEncryptedBlob('internationalizationlocalization'),
          isFalse,
        );
      },
    );

    test('handles null and empty input', () {
      expect(looksLikeEncryptedBlob(null), isFalse);
      expect(looksLikeEncryptedBlob(''), isFalse);
      expect(looksLikeEncryptedBlob('   '), isFalse);
    });
  });

  group('displaySafeText', () {
    test('blanks ciphertext and keeps readable text', () {
      const leakedBlob =
          'cjFa3e0sBTRmfbIsI3+KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8=';
      expect(displaySafeText(leakedBlob), '');
      expect(displaySafeText('מה קורה?'), 'מה קורה?');
      expect(displaySafeText(null), '');
    });
  });

  group('#pending# claim marker', () {
    test(
      'normalizeLanguageCode treats a claimed target as the target language',
      () {
        // While translate-proxy owns the round trip the column reads
        // "<lang>#pending#<epochMs>". It must still compare equal to the UI
        // language, otherwise Case C is skipped and a readable cached
        // translation is thrown away.
        expect(normalizeLanguageCode('he#pending#1790414556436'), 'he');
        expect(normalizeLanguageCode('en#pending#1'), 'en');
        expect(normalizeLanguageCode('he'), 'he');
        expect(normalizeLanguageCode('HE'), 'he');
      },
    );

    test('stripPendingTranslationMarker handles edge cases', () {
      expect(stripPendingTranslationMarker('es#pending#1790414556436'), 'es');
      expect(stripPendingTranslationMarker('  He  '), 'he');
      expect(stripPendingTranslationMarker('#pending#123'), isNull);
      expect(stripPendingTranslationMarker(''), isNull);
      expect(stripPendingTranslationMarker(null), isNull);
    });

    test('hasPendingTranslationMarker detects an in-flight claim', () {
      expect(hasPendingTranslationMarker('he#pending#1'), isTrue);
      expect(hasPendingTranslationMarker('he'), isFalse);
      expect(hasPendingTranslationMarker(null), isFalse);
    });

    test('isValidLanguageCode still rejects genuinely bogus codes', () {
      expect(isValidLanguageCode('he#pending#1'), isTrue);
      expect(isValidLanguageCode('klingon'), isFalse);
    });
  });

  group('ChatModel never carries ciphertext', () {
    const leakedBlob =
        'cjFa3e0sBTRmfbIsI3+KQjIucTxiZilNIMLVbSdx3peeLUf04vAd6Krj3QcOa4PULKyKDxgFOoOBVN3HzXcIaZlHZ8=';

    test('fromJsonRpc drops an undecrypted translation preview', () {
      final chat = ChatModel.fromJsonRpc({
        'match_id': 'match-1',
        'other_user_id': 'other-1',
        'other_user_name': 'Bella V.',
        'last_message_id': 'msg-1',
        'last_message_at': DateTime(2026, 6, 28).toIso8601String(),
        'last_message': 'Hola!',
        'last_message_translated': leakedBlob,
        'last_message_source_language': 'es',
        'translation_enabled': true,
      });

      expect(chat.lastMessageTranslated, isNull);
      expect(chat.lastMessage, 'Hola!');
    });

    test('fromJsonRpc drops an undecrypted original preview', () {
      final chat = ChatModel.fromJsonRpc({
        'match_id': 'match-1',
        'other_user_id': 'other-1',
        'last_message_id': 'msg-1',
        'last_message_at': DateTime(2026, 6, 28).toIso8601String(),
        'last_message': leakedBlob,
      });

      expect(chat.lastMessage, '');
    });

    test('fromJsonRpc keeps a decrypted translation', () {
      final chat = ChatModel.fromJsonRpc({
        'match_id': 'match-1',
        'other_user_id': 'other-1',
        'last_message_id': 'msg-1',
        'last_message_at': DateTime(2026, 6, 28).toIso8601String(),
        'last_message': 'Hola!',
        'last_message_translated': 'מה שלומך?',
      });

      expect(chat.lastMessageTranslated, 'מה שלומך?');
    });

    test('copyWith can clear the translation (the actual leak)', () {
      // Regression: copyWith used `lastMessageTranslated ?? this.<field>`, so
      // `copyWith(lastMessageTranslated: null)` — the "no translation for the
      // UI language, show loading" signal from recentChatsProvider — silently
      // kept the cached ciphertext and the chat list rendered it verbatim.
      final chat = ChatModel(
        matchId: 'match-1',
        otherUserId: 'other-1',
        otherUserName: 'Bella V.',
        lastMessage: 'Hola!',
        lastMessageId: 'msg-1',
        lastMessageAt: DateTime(2026, 6, 28),
        unreadCount: 0,
        lastMessageTranslated: leakedBlob,
        lastMessageSourceLanguage: 'es',
      );

      final cleared = chat.copyWith(
        lastMessageTranslated: null,
        lastMessageSourceLanguage: 'es',
      );

      expect(cleared.lastMessageTranslated, isNull);
      expect(cleared.lastMessageSourceLanguage, 'es');
    });

    test('copyWith still preserves omitted fields', () {
      final chat = ChatModel(
        matchId: 'match-1',
        otherUserId: 'other-1',
        otherUserName: 'Bella V.',
        lastMessage: 'Hola!',
        lastMessageId: 'msg-1',
        lastMessageAt: DateTime(2026, 6, 28),
        unreadCount: 0,
        lastMessageTranslated: 'מה שלומך?',
        lastMessageSourceLanguage: 'es',
      );

      final updated = chat.copyWith(unreadCount: 4);

      expect(updated.lastMessageTranslated, 'מה שלומך?');
      expect(updated.lastMessageSourceLanguage, 'es');
      expect(updated.unreadCount, 4);
    });

    test('copyWith replaces a translation with a decrypted one', () {
      final chat = ChatModel(
        matchId: 'match-1',
        otherUserId: 'other-1',
        otherUserName: 'Bella V.',
        lastMessage: 'Hola!',
        lastMessageId: 'msg-1',
        lastMessageAt: DateTime(2026, 6, 28),
        unreadCount: 0,
        lastMessageTranslated: 'stale',
      );

      expect(
        chat.copyWith(lastMessageTranslated: 'מה שלומך?').lastMessageTranslated,
        'מה שלומך?',
      );
    });
  });
}
