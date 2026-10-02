// lib/utils/directional_icons.dart
//
// Direction-aware "go deeper" affordances.
//
// Flutter's Material chevron / arrow_ios icons already carry
// `matchTextDirection: true`, so `Icon` mirrors them automatically in RTL:
// `chevron_right` paints as left-pointing in Hebrew/Arabic, `arrow_back`
// paints as right-pointing, and so on. Manually swapping to the `_left` /
// `_back` glyph in RTL therefore mirrors TWICE and points the wrong way
// (right in a Hebrew UI). Hence these helpers always return the LTR-forward
// glyph and let the framework do the mirroring — one helper, used everywhere,
// with no per-screen RTL branching to get wrong.

import 'package:flutter/material.dart';

/// "Go deeper" chevron. Always [Icons.chevron_right]; Flutter mirrors it to
/// point left in RTL.
IconData directionalChevron(BuildContext context) {
  return Icons.chevron_right;
}

/// Rounded variant of [directionalChevron].
IconData directionalChevronRounded(BuildContext context) {
  return Icons.chevron_right_rounded;
}

/// iOS-style "go deeper" arrow. Always [Icons.arrow_forward_ios]; Flutter
/// mirrors it in RTL.
IconData directionalForwardIos(BuildContext context) {
  return Icons.arrow_forward_ios;
}

/// True when the ambient direction is right-to-left.
bool isRtlContext(BuildContext context) =>
    Directionality.of(context) == TextDirection.rtl;
