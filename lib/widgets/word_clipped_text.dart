// lib/widgets/word_clipped_text.dart
//
// WORD-BOUNDARY CLIPPING — the one documented exception to the
// no-truncation policy in `safe_text.dart`.
//
// A chat preview is a teaser, not an identifier: showing the last message
// cut at a word boundary with an ellipsis is what every chat app does, and
// it keeps a long message from spilling over the row below it.
//
// Identities are never clipped. A name, a title or a label that does not
// fit uses [SafeText] (wrap) or [ShrinkText] (shrink) instead — a clipped
// name is ambiguous, a clipped preview is not.

import 'package:flutter/material.dart';

/// Text that shows as many whole words as fit inside [maxLines] lines of
/// the available width, and then an ellipsis.
///
/// The cut is measured with the very styles the spans are painted with, so
/// the result always fits: it never spills over the row below it and it
/// never ends in the middle of a word.
class WordClippedText extends StatelessWidget {
  final List<InlineSpan> spans;
  final TextStyle style;
  final int maxLines;
  final TextAlign textAlign;
  final TextDirection? textDirection;
  final String ellipsis;

  const WordClippedText({
    super.key,
    required this.spans,
    required this.style,
    this.maxLines = 2,
    this.textAlign = TextAlign.start,
    this.textDirection,
    this.ellipsis = '…',
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The Text widget merges an inheriting style with the ambient
        // DefaultTextStyle before it paints. The measurement has to see the
        // very same style, otherwise the clipped text could be laid out
        // wider than the space it was measured for.
        final defaultTextStyle = DefaultTextStyle.of(context);
        final effectiveStyle = style.inherit
            ? defaultTextStyle.style.merge(style)
            : style;
        final clipped = clipSpansAtWordBoundary(
          spans,
          style: effectiveStyle,
          maxWidth: constraints.maxWidth,
          maxLines: maxLines,
          textDirection: textDirection ?? Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          ellipsis: ellipsis,
        );
        return Text.rich(
          TextSpan(style: effectiveStyle, children: clipped),
          style: effectiveStyle,
          textAlign: textAlign,
          textDirection: textDirection,
          maxLines: maxLines,
          overflow: TextOverflow.visible,
        );
      },
    );
  }
}

/// Cuts [spans] down to the longest run of whole words that fits inside
/// [maxLines] lines of [maxWidth], and appends [ellipsis] when anything was
/// cut off.
///
/// Returns [spans] untouched when the whole thing already fits.
List<InlineSpan> clipSpansAtWordBoundary(
  List<InlineSpan> spans, {
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  required TextDirection textDirection,
  TextScaler textScaler = TextScaler.noScaling,
  String ellipsis = '…',
}) {
  if (spans.isEmpty || maxWidth <= 0) return spans;

  bool fits(List<InlineSpan> candidate) {
    final painter = TextPainter(
      text: TextSpan(style: style, children: candidate),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: maxLines,
      ellipsis: ellipsis,
    )..layout(maxWidth: maxWidth);
    return !painter.didExceedMaxLines;
  }

  if (fits(spans)) return spans;

  // End offset of every word in the concatenated text.
  final plain = spans.map(_spanText).join();
  final wordEnds = <int>[];
  for (final match in RegExp(r'\S+').allMatches(plain)) {
    wordEnds.add(match.end);
  }
  if (wordEnds.isEmpty) {
    return [TextSpan(text: ellipsis, style: style)];
  }

  List<InlineSpan> candidateFor(int wordCount) => <InlineSpan>[
    ..._cutSpans(spans, wordEnds[wordCount - 1]),
    TextSpan(text: ellipsis, style: style),
  ];

  // The largest number of whole words that still fits is found by binary
  // search: "k words fit" is monotonic, and one layout pass per word would
  // be far too slow for a long message in a scrolling list.
  var low = 1;
  var high = wordEnds.length;
  var best = 0;
  while (low <= high) {
    final mid = (low + high) ~/ 2;
    if (fits(candidateFor(mid))) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  if (best == 0) {
    return [TextSpan(text: ellipsis, style: style)];
  }
  return candidateFor(best);
}

/// The plain text of a span. Only text carries characters; a placeholder
/// (an emoji widget) contributes nothing to the cut.
String _spanText(InlineSpan span) => span is TextSpan ? (span.text ?? '') : '';

/// The spans that carry the first [cut] characters of [spans].
List<InlineSpan> _cutSpans(List<InlineSpan> spans, int cut) {
  final out = <InlineSpan>[];
  var remaining = cut;
  for (final span in spans) {
    if (remaining <= 0) break;
    final text = _spanText(span);
    if (text.length <= remaining) {
      out.add(span);
      remaining -= text.length;
    } else {
      out.add(TextSpan(text: text.substring(0, remaining), style: span.style));
      remaining = 0;
    }
  }
  return out;
}
