// lib/widgets/safe_text.dart
//
// NO-TRUNCATION POLICY — read before touching this file.
//
// Rule: no user-visible text in MatchMe may be silently truncated.
// That means: no `TextOverflow.ellipsis`, no `TextOverflow.clip`,
// no `TextOverflow.fade`, and no `maxLines: 1 + softWrap:false`
// without an explicit shrink-or-wrap fallback.
//
// Two widgets cover every case:
//
// * [SafeText] — flowing content (titles, bodies, labels, errors,
//   dialog text, list subtitles). Wraps to as many lines as needed,
//   never shows "...". Parent MUST allow vertical growth (Column,
//   ListView, SingleChildScrollView, Flexible/Expanded in a vertical
//   axis, or a Wrap). Do NOT place in a fixed-height box.
// * [ShrinkText] — fixed chrome that must stay on 1-2 lines
//   (AppBar titles, badges/counts, tab labels, pill buttons, chips).
//   Shrinks the font down to [minFontSize] instead of truncating,
//   so the full string is always painted. Backed by `auto_size_text`,
//   which is already a dependency (pubspec.yaml).
//
// If neither fits (e.g. a one-line design that cannot shrink and
// cannot grow), the design is wrong — change the design to scroll,
// wrap, or shrink. Do not reintroduce ellipsis.
//
// ONE DOCUMENTED EXCEPTION: a chat preview (the last message of a
// conversation, shown as a teaser under the name) is clipped at a word
// boundary with an ellipsis — see [WordClippedText] in
// `word_clipped_text.dart`. A preview is not an identifier: clipping it
// is what every chat app does, and it is the only way to keep a long
// message from spilling over the row below it. Identities — names,
// titles, labels, ages — are never clipped.

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';

/// Flowing text that always shows 100% of its content.
///
/// Defaults: `softWrap: true`, `overflow: TextOverflow.visible`,
/// no `maxLines` cap. Pass [maxLines] only as a *generous* ceiling
/// (e.g. 5-10) for extreme cases — never as `1` to force single-line.
class SafeText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;
  final double? textHeightBehaviorLeading;
  final int? semanticsMaxLines;

  const SafeText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.textHeightBehaviorLeading,
  }) : semanticsMaxLines = null;

  @override
  Widget build(BuildContext context) {
    return Text(
      data,
      style: style,
      textAlign: textAlign,
      textDirection: textDirection,
      // Never truncate: wrap and paint everything.
      softWrap: true,
      overflow: TextOverflow.visible,
      maxLines: maxLines,
    );
  }
}

/// Single/double-line chrome that shrinks instead of truncating.
///
/// Use for: AppBar titles, unread-count badges, navigation labels,
/// pill/status chips, buttons with fixed height, map pins.
/// The font scales down (never below [minFontSize]) so the whole
/// string stays visible even at 1.35x system scale + long es/he text.
class ShrinkText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int maxLines;
  final double minFontSize;
  final double maxFontSizeScale;

  const ShrinkText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines = 1,
    this.minFontSize = 8,
    this.maxFontSizeScale = 1.0,
  });

  static const double _step = 0.5;

  @override
  Widget build(BuildContext context) {
    final baseSize = style?.fontSize;
    // AutoSizeText asserts the cap is a whole multiple of stepGranularity;
    // typography sizes such as 9.2 or 10.2 are not, so snap down to a step.
    final maxFontSize = baseSize == null
        ? double.infinity
        : (baseSize * maxFontSizeScale / _step).floorToDouble() * _step;
    return AutoSizeText(
      data,
      style: style,
      textAlign: textAlign,
      textDirection: textDirection,
      maxLines: maxLines,
      // Visible (not ellipsis/clip): AutoSizeText shrinks to fit,
      // so overflow should not occur; visible is the safe fallback.
      overflow: TextOverflow.visible,
      wrapWords: true,
      softWrap: true,
      minFontSize: minFontSize,
      // Cap the resolved size so ambient text-scale cannot blow up
      // fixed chrome even before the global clamp (belt and braces).
      maxFontSize: maxFontSize,
      stepGranularity: _step,
    );
  }
}

/// Icon + label row that can never clip the label or the icon.
///
/// The label wraps ([SafeText]) or shrinks ([ShrinkText] when
/// [singleLine] is true). The icon keeps a fixed visual size but the
/// row allows the text side to take all remaining width via [Flexible].
class SafeIconLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final TextStyle? style;
  final double iconSize;
  final Color? iconColor;
  final double spacing;
  final bool singleLine;
  final TextAlign? textAlign;

  const SafeIconLabel({
    super.key,
    required this.icon,
    required this.label,
    this.style,
    this.iconSize = 16,
    this.iconColor,
    this.spacing = 4,
    this.singleLine = false,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: iconSize, color: iconColor),
        SizedBox(width: spacing),
        Flexible(
          child: singleLine
              ? ShrinkText(
                  label,
                  style: style,
                  textAlign: textAlign ?? TextAlign.start,
                )
              : SafeText(
                  label,
                  style: style,
                  textAlign: textAlign ?? TextAlign.start,
                ),
        ),
      ],
    );
  }
}
