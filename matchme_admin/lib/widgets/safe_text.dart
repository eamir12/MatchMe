// matchme_admin/lib/widgets/safe_text.dart
//
// NO-TRUNCATION POLICY (mirrors lib/widgets/safe_text.dart in the main app):
// no user-visible text in MatchMe Admin may be silently truncated.
// AppBar applies `softWrap: false` + `TextOverflow.ellipsis` to its title,
// so a plain Text there can render as "Edit pho..." on narrow widths.
// Use [ShrinkText] for AppBar titles / fixed chrome and [SafeText] for
// flowing content instead.

import 'package:flutter/material.dart';

/// Flowing text that always shows 100% of its content (wraps, never clips).
class SafeText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;

  const SafeText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      data,
      style: style,
      textAlign: textAlign,
      textDirection: textDirection,
      softWrap: true,
      overflow: TextOverflow.visible,
      maxLines: maxLines,
    );
  }
}

/// Fixed chrome that shrinks (via FittedBox scale-down) instead of
/// truncating — the whole string is always painted, just smaller.
class ShrinkText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int maxLines;

  const ShrinkText(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      // Center: under tight constraints (chart axis slots, segmented
      // buttons) a scaled-down label must stay visually centred, and
      // under loose constraints the box hugs the child anyway.
      alignment: AlignmentDirectional.center,
      clipBehavior: Clip.none,
      child: Text(
        data,
        style: style,
        textAlign: textAlign,
        textDirection: textDirection,
        maxLines: maxLines,
        softWrap: false,
        overflow: TextOverflow.visible,
      ),
    );
  }
}
