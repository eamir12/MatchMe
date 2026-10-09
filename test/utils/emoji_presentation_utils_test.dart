import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/utils/emoji_presentation_utils.dart';

void main() {
  group('chat display whitespace', () {
    test('collapses repeated spaces, tabs, and non-breaking spaces', () {
      expect(
        normalizeChatDisplayWhitespace(
          'I    like\t\tto\u00a0\u00a0drink!\u2800fried',
        ),
        'I like to drink! fried',
      );
    });

    test('preserves intentional line breaks', () {
      expect(normalizeChatDisplayWhitespace('first   line \n  second'), 'first line\nsecond');
    });

    test('uses natural spacing for all emoji-aware text spans', () {
      final spans = emojiAwareSpans(
        'Hello     there 🌞',
        const TextStyle(letterSpacing: 2, wordSpacing: 5),
      );
      expect(spans.map((span) => (span).text).join(), 'Hello there 🌞');
      for (final span in spans.cast<TextSpan>()) {
        expect(span.style?.letterSpacing, 0);
        expect(span.style?.wordSpacing, 0);
      }
    });
  });
}
