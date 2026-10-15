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

  group('emoji font fallback', () {
    // Regression: with a null fontFamily, dart:ui promotes the first
    // fontFamilyFallback entry to the preferred font. That entry is an emoji
    // font, and Apple Color Emoji (iOS) has a very wide space glyph, which
    // rendered chat text with 2-3x wider word gaps on iOS only.
    test('never leaves the preferred font family unset', () {
      final style = withEmojiFallback(const TextStyle());
      expect(style.fontFamily, kAppDefaultTextFontFamily);
      expect(style.fontFamilyFallback, isNotEmpty);
      expect(style.fontFamilyFallback!.first, isNot(style.fontFamily));
    });

    test('keeps an explicitly provided font family', () {
      final style = withEmojiFallback(
        const TextStyle(fontFamily: 'Noto Sans Hebrew'),
      );
      expect(style.fontFamily, 'Noto Sans Hebrew');
    });
  });
}
