// Regression tests for the word-boundary clipping of message previews
// (lib/widgets/word_clipped_text.dart):
//
// A chat preview shows the last message. When it is longer than the two
// lines the row allows, it must be cut at a word boundary and marked with
// an ellipsis — never spill over the row below it, and never end in the
// middle of a word.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/widgets/word_clipped_text.dart';

const _longMessage =
    'one two three four five six seven eight nine ten eleven twelve thirteen';

TextSpan _span(String text) =>
    TextSpan(text: text, style: const TextStyle(fontSize: 14));

String _plain(List<InlineSpan> spans) =>
    spans.map((s) => s is TextSpan ? (s.text ?? '') : '').join();

void main() {
  group('clipSpansAtWordBoundary', () {
    test('leaves text that already fits untouched', () {
      final clipped = clipSpansAtWordBoundary(
        [_span('short message')],
        style: const TextStyle(fontSize: 14),
        maxWidth: 400,
        maxLines: 2,
        textDirection: TextDirection.ltr,
      );
      expect(_plain(clipped), 'short message');
      expect(_plain(clipped), isNot(contains('…')));
    });

    test('cuts a long text at a word boundary and marks it with an ellipsis', () {
      final clipped = clipSpansAtWordBoundary(
        [_span(_longMessage)],
        style: const TextStyle(fontSize: 14),
        maxWidth: 120,
        maxLines: 2,
        textDirection: TextDirection.ltr,
      );

      final plain = _plain(clipped);
      expect(plain, endsWith('…'));
      expect(plain.length, lessThan(_longMessage.length));

      // Whole words only: what is kept is a prefix of the message and the
      // cut lands on a space, never inside a word.
      final kept = plain.replaceAll('…', '').trim();
      expect(_longMessage.startsWith(kept), isTrue);
      if (kept.length < _longMessage.length) {
        expect(_longMessage[kept.length], ' ');
      }
    });

    test('keeps the styling of the spans it kept', () {
      const bold = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);
      final clipped = clipSpansAtWordBoundary(
        [
          TextSpan(text: 'plain ', style: const TextStyle(fontSize: 14)),
          TextSpan(text: _longMessage, style: bold),
        ],
        style: const TextStyle(fontSize: 14),
        maxWidth: 120,
        maxLines: 2,
        textDirection: TextDirection.ltr,
      );
      expect(
        clipped.whereType<TextSpan>().any((s) => s.style?.fontWeight == FontWeight.bold),
        isTrue,
      );
    });
  });

  group('WordClippedText', () {
    Future<double> heightOf(
      WidgetTester tester,
      String text, {
      double width = 200,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: WordClippedText(
                spans: [_span(text)],
                style: const TextStyle(fontSize: 14),
                maxLines: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(RichText)).height;
    }

    testWidgets('a long preview never spills past its two lines', (
      tester,
    ) async {
      final singleLine = await heightOf(tester, 'x');
      final twoLines = await heightOf(
        tester,
        'one two three four five six seven eight nine ten eleven twelve',
      );
      expect(twoLines, greaterThan(singleLine));

      final clippedHeight = await heightOf(tester, _longMessage);
      expect(
        clippedHeight,
        lessThanOrEqualTo(singleLine * 2 + 0.5),
        reason: 'the preview must stay inside its two lines',
      );
    });

    testWidgets('a long preview ends with an ellipsis and no half word', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: WordClippedText(
                spans: [_span(_longMessage)],
                style: const TextStyle(fontSize: 14),
                maxLines: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final richText = tester.widget<RichText>(find.byType(RichText));
      final plain = richText.text.toPlainText();
      expect(plain, endsWith('…'));

      final kept = plain.replaceAll('…', '').trim();
      expect(_longMessage.startsWith(kept), isTrue);
      if (kept.length < _longMessage.length) {
        expect(_longMessage[kept.length], ' ');
      }
      expect(tester.takeException(), isNull);
    });
  });
}
