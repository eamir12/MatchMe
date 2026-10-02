import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/models/chat_message_model.dart';
import 'package:matchme/screens/chats/chat_screen.dart';

ChatMessageModel _msg({
  String id = 'm1',
  String original = '',
  String? translated,
  String? replyOriginal,
  String? replyTranslated,
}) {
  return ChatMessageModel(
    id: id,
    matchId: 'match-1',
    senderId: 'other',
    contentOriginal: original,
    contentTranslated: translated,
    createdAt: DateTime(2026, 1, 1, 12),
    replyToContent: replyOriginal,
    replyToContentTranslated: replyTranslated,
  );
}

void main() {
  group('chatSearchMessageMatches', () {
    test('matches the original body case-insensitively', () {
      final m = _msg(original: 'Bouldering GYM tonight');
      expect(chatSearchMessageMatches(m, 'bouldering'), isTrue);
      expect(chatSearchMessageMatches(m, 'gym'), isTrue);
      expect(chatSearchMessageMatches(m, 'tomorrow'), isFalse);
    });

    test('matches the cached translation', () {
      final m = _msg(
        original: 'שלום, נתראה מחר',
        translated: 'Hi, see you tomorrow',
      );
      // English query finds the Hebrew message via its translation.
      expect(chatSearchMessageMatches(m, 'tomorrow'), isTrue);
      // Hebrew query finds it via the original.
      expect(chatSearchMessageMatches(m, 'מחר'), isTrue);
      expect(chatSearchMessageMatches(m, 'climbing'), isFalse);
    });

    test('matches quoted-reply previews', () {
      final m = _msg(
        original: 'Sounds good',
        replyOriginal: 'the climb is at six',
      );
      expect(chatSearchMessageMatches(m, 'climb'), isTrue);
    });

    test('empty needle never matches', () {
      final m = _msg(original: 'anything');
      expect(chatSearchMessageMatches(m, ''), isFalse);
    });
  });

  group('chatSearchMatchedField', () {
    test('reports original when the original contains the query', () {
      final m = _msg(
        original: 'the climb is at six',
        translated: 'הטיול מתחיל בשש',
      );
      expect(chatSearchMatchedField(m, 'climb'), 'original');
    });

    test('reports translated when only the translation contains it', () {
      final m = _msg(
        original: 'שלום, נתראה מחר',
        translated: 'Hi, see you tomorrow',
      );
      expect(chatSearchMatchedField(m, 'tomorrow'), 'translated');
    });
  });

  group('chatSearchSplitMatches', () {
    test('splits every occurrence for highlighting', () {
      final parts = chatSearchSplitMatches('Gym gym GYM', 'gym');
      final matched = parts.where((p) => p.$2).toList();
      expect(matched, hasLength(3));
      expect(parts.map((p) => p.$1).join(), 'Gym gym GYM');
    });

    test('returns the whole text unmatched for an empty query', () {
      expect(chatSearchSplitMatches('hello', '  '), [('hello', false)]);
    });
  });
}
