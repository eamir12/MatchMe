// lib/utils/emoji_presentation_utils.dart
//
// Some emoji (e.g. ⛱ U+26F1 UMBRELLA ON GROUND) default to *text*
// presentation (monochrome outline) per Unicode TR51. They only render
// in color when followed by VS16 (U+FE0F): ⛱️ = U+26F1 + U+FE0F.
//
// System keyboards / pickers show a color preview but often insert the
// bare base character. Flutter then faithfully renders the text variant,
// which looks like a "black and white emoji" bug in the composer and in
// sent bubbles (while other emoji that default to emoji presentation
// stay colorful).
//
// This helper appends a missing VS16 to single-codepoint emoji that
// default to text, both for newly typed/sent text and for rendering
// historic messages stored without the selector.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const int _vs16 = 0xFE0F;
const int _vs15 = 0xFE0E; // explicitly requests text presentation; respect it.

/// Single-codepoint emoji with `Emoji_Presentation=No` that accept VS16
/// to request emoji presentation (subset of Unicode Emoji data, excluding
/// `#`, `*`, `0-9` to avoid touching keycap bases / plain numbers).
const Set<int> _textDefaultEmoji = {
  0x00A9, // ©
  0x00AE, // ®
  0x203C, // ‼
  0x2049, // ⁉
  0x2122, // ™
  0x2139, // ℹ
  0x2194, 0x2195, 0x2196, 0x2197, 0x2198, 0x2199, // ↔ ↕ ↖ ↗ ↘ ↙
  0x21A9, 0x21AA, // ↩ ↪
  0x231A, 0x231B, // ⌚ ⌛
  0x2328, // ⌨
  0x2388, // ⎈
  0x23CF, // ⏏
  0x23E9, 0x23EA, 0x23EB, 0x23EC, 0x23ED, 0x23EE, 0x23EF,
  0x23F0, 0x23F1, 0x23F2, 0x23F3,
  0x23F8, 0x23F9, 0x23FA,
  0x24C2, // Ⓜ
  0x25AA, 0x25AB, 0x25B6, 0x25C0, // ▪ ▫ ▶ ◀
  0x25FB, 0x25FC, 0x25FD, 0x25FE, // ◻ ◼ ◽ ◾
  0x2600, 0x2601, 0x2602, 0x2603, 0x2604, // ☀ ☁ ☂ ☃ ☄
  0x260E, // ☎
  0x2611, // ☑
  0x2614, 0x2615, // ☔ ☕
  0x2618, // ☘
  0x2620, // ☠
  0x2622, 0x2623, // ☢ ☣
  0x2626, // ☦
  0x262A, // ☪
  0x2630, 0x2631, // ☰ ☱
  0x2638, 0x2639, 0x263A, // ☸ ☹ ☺
  0x2640, // ♀
  0x2642, // ♂
  0x265F, // ♟
  0x2660, // ♠
  0x2663, // ♣
  0x2665, 0x2666, // ♥ ♦
  0x2668, // ♨
  0x267B, // ♻
  0x267E, 0x267F, // ♾ ♿
  0x2690, 0x2691, // ⚐ ⚑
  0x2693, 0x2694, // ⚓ ⚔
  0x2696, 0x2697, // ⚖ ⚗
  0x2699, // ⚙
  0x26A0, 0x26A1, // ⚠ ⚡
  0x26A7, // ⚧
  0x26AA, 0x26AB, // ⚪ ⚫
  0x26B0, 0x26B1, // ⚰ ⚱
  0x26BD, 0x26BE, // ⚽ ⚾
  0x26C4, 0x26C5, // ⛄ ⛅
  0x26CE, // ⛎
  0x26D4, // ⛔
  0x26EA, // ⛪
  0x26F1, // ⛱ umbrella on ground (reported issue)
  0x26F2, 0x26F3, 0x26F5, // ⛲ ⛳ ⛵
  0x26FA, // ⛺
  0x26FD, // ⛽
  0x2702, // ✂
  0x2705, // ✅
  0x2708, 0x2709, 0x270A, 0x270B, 0x270C, 0x270D, 0x270F, // ✈ ✉ ✊ ✋ ✌ ✍ ✏
  0x2712, // ✒
  0x2714, // ✔
  0x2716, // ✖
  0x271D, // ✝
  0x2721, // ✡
  0x2728, // ✨
  0x2733, 0x2734, // ✳ ✴
  0x2744, // ❄
  0x2747, // ❇
  0x274C, // ❌
  0x274E, // ❎
  0x2753, 0x2754, 0x2755, // ❓ ❔ ❕
  0x2757, // ❗
  0x2763, 0x2764, // ❣ ❤
  0x2795, 0x2796, 0x2797, // ➕ ➖ ➗
  0x27A1, // ➡
  0x27B0, // ➰
  0x27BF, // ➿
  0x2934, 0x2935, // ⤴ ⤵
  0x2B05, 0x2B06, 0x2B07, // ⬅ ⬆ ⬇
  0x2B1B, 0x2B1C, // ⬛ ⬜
  0x2B50, // ⭐
  0x2B55, // ⭕
  0x3030, // 〰
  0x303D, // 〽
  0x3297, // ㊗
  0x3299, // ㊙
};

/// Returns [text] with a missing VS16 appended after every text-default
/// emoji that isn't already followed by VS16 (emoji) or VS15 (text).
///
/// Idempotent and safe to run on display paths (fixes historic rows) and
/// on send paths (stores the qualified form so every device renders color).
String ensureEmojiPresentation(String text) {
  if (text.isEmpty) return text;
  // Fast path: no BMP symbol that could need VS16.
  bool maybeNeedsFix = false;
  for (final r in text.runes) {
    if (_textDefaultEmoji.contains(r)) {
      maybeNeedsFix = true;
      break;
    }
  }
  if (!maybeNeedsFix) return text;

  final runes = text.runes.toList(growable: false);
  final out = StringBuffer();
  for (int i = 0; i < runes.length; i++) {
    final r = runes[i];
    out.writeCharCode(r);
    if (_textDefaultEmoji.contains(r)) {
      final next = (i + 1 < runes.length) ? runes[i + 1] : -1;
      if (next != _vs16 && next != _vs15) {
        out.writeCharCode(_vs16);
      }
    }
  }
  return out.toString();
}

/// Color emoji fonts must be consulted before the bundled monochrome
/// `Noto Sans Symbols` fonts, otherwise even a qualified `⛱️` can fall
/// through to the outline glyph on some devices.
///
/// NOTE (Android): `fontFamilyFallback` from a *bundled* primary font to a
/// *system* font does not reliably trigger on Android (flutter/flutter#175653).
/// iOS therefore shows color while the same bare `⛱` stays B&W on Android.
/// Two mitigations are applied together:
///  1. Store/display the VS16-qualified form (`ensureEmojiPresentation`), so
///     the sequence only matches color fonts.
///  2. PREPEND (not append) color fonts and push bundled mono Symbols to the
///     end via [withEmojiFallback] below.
///
/// Includes OEM color fonts (Samsung etc.): on those devices the system emoji
/// file replaces `NotoColorEmoji.ttf`, but Flutter still resolves it when
/// named. If a device has none of these, the platform default fallback still
/// applies for non-qualified emoji.
const List<String> kColorEmojiFontFallback = [
  // Bundled first: bundled->bundled works on Android where bundled->system
  // does not. Twemoji COLR v0.7.0 covers ⛱️ etc. with modern flat design.
  'Twemoji Mozilla',
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'Noto Color Emoji',
  'Samsung Color Emoji',
  'SamsungOneColorEmoji',
  'SamsungOne',
  'EmojiOne Color',
];

/// True if [text] is only emoji (1-3 visible emoji, no letters/numbers).
/// Uses UAX #29 grapheme clusters via `characters` so ZWJ sequences, flags
/// (2x regional indicators), skin tones and keycaps count as single emoji.
/// 4+ returns false so long emoji rows keep a normal bubble (WhatsApp rule).
/// Display-only: historic rows qualify automatically, no DB migration.
bool isJumboEmoji(String text) {
  final n = jumboEmojiCount(text);
  return n >= 1 && n <= 3;
}

/// Number of visible emoji clusters (0 if mixed with text, >3 returns actual
/// count so callers can gate jumbo to 1-3 like WhatsApp/Messenger).
int jumboEmojiCount(String text) {
  final t = text.trim();
  if (t.isEmpty) return 0;
  final clusters = t.characters
      .where((c) => c.trim().isNotEmpty)
      .toList();
  if (clusters.isEmpty) return 0;
  for (final c in clusters) {
    if (!_isEmojiCluster(c)) return 0;
  }
  return clusters.length;
}

/// WhatsApp-style tiered sizing: 1 emoji largest, 3 smallest jumbo.
/// 4+ falls back to 16 with a normal bubble (never tiny/bubbleless).
double jumboFontSize(String text) {
  final n = jumboEmojiCount(text);
  switch (n) {
    case 1:
      return 48;
    case 2:
      return 40;
    case 3:
      return 36;
    default:
      return 16;
  }
}

bool _isEmojiRune(int r) {
  return _textDefaultEmoji.contains(r) ||
      (r >= 0x1F300 && r <= 0x1FAFF) ||
      (r >= 0x2600 && r <= 0x27BF) ||
      (r >= 0x2B00 && r <= 0x2BFF) ||
      (r >= 0x1F1E6 && r <= 0x1F1FF) || // regional indicators (flags)
      r == 0x00A9 ||
      r == 0x00AE ||
      r == 0x203C ||
      r == 0x2049 ||
      r == 0x2122 ||
      r == 0x2139 ||
      r == 0x231A ||
      r == 0x231B ||
      r == 0x24C2 ||
      r == 0x3297 ||
      r == 0x3299;
}

/// UTS #51 cluster test: VS16/ZWJ/skin-tone/keycap aware. A cluster is emoji
/// if it contains an emoji base, regional indicator, or keycap sequence.
bool _isEmojiCluster(String cluster) {
  final runes = cluster.runes.toList();
  if (runes.isEmpty) return false;
  bool hasEmojiBase = false;
  bool hasRegional = false;
  for (final r in runes) {
    if (_isEmojiRune(r)) hasEmojiBase = true;
    if (r >= 0x1F1E6 && r <= 0x1F1FF) hasRegional = true;
    // Keycap: digit/#/* + optional VS16 + U+20E3.
    if (r == 0x20E3) return true;
  }
  if (hasRegional) return true;
  // ZWJ sequence with an emoji base (families, professions, ❤️‍🔥).
  if (runes.contains(0x200D) && hasEmojiBase) return true;
  return hasEmojiBase;
}

/// Splits [text] (already VS16-qualified) into emoji vs text runs using
/// grapheme clusters, merging consecutive same-type clusters. Emoji runs get
/// [emojiStyle], text runs keep [base]. Standards: UAX #29 clusters, UTS #51
/// ZWJ/flags/skin-tones preserved as single runs.
List<TextSpan> emojiAwareSpans(String text, TextStyle base) {
  text = normalizeChatDisplayWhitespace(text);
  base = base.copyWith(letterSpacing: 0, wordSpacing: 0);
  if (text.isEmpty) return [TextSpan(text: text, style: base)];
  final eStyle = emojiRunStyle(base);
  final out = <TextSpan>[];
  StringBuffer? buf;
  bool? bufIsEmoji;
  void flush() {
    if (buf == null || buf!.isEmpty) return;
    out.add(
      TextSpan(
        text: buf.toString(),
        style: (bufIsEmoji ?? false) ? eStyle : base,
      ),
    );
    buf = null;
  }

  for (final cluster in text.characters) {
    // Whitespace joins text runs (keeps word spacing in base font).
    if (cluster.trim().isEmpty) {
      if (bufIsEmoji == true) flush();
      bufIsEmoji = false;
      buf ??= StringBuffer();
      buf!.write(cluster);
      continue;
    }
    final isEmoji = _isEmojiCluster(cluster);
    if (bufIsEmoji == null) {
      bufIsEmoji = isEmoji;
      buf = StringBuffer(cluster);
    } else if (bufIsEmoji == isEmoji) {
      buf!.write(cluster);
    } else {
      flush();
      bufIsEmoji = isEmoji;
      buf = StringBuffer(cluster);
    }
  }
  flush();
  return out;
}

/// Collapses accidental repeated horizontal whitespace in displayed chat
/// content while preserving intentional line breaks.
String normalizeChatDisplayWhitespace(String text) {
  return text
      .replaceAll(
        RegExp(r'[ \t\f\v\u00A0\u1680\u2000-\u200A\u202F\u205F\u2800\u3000]+'),
        ' ',
      )
      .replaceAll(RegExp(r' *\r?\n *'), '\n');
}

/// Platform-aware color emoji order for best native experience.
///
/// 2026-modern rule: native latest first where native is maintained,
/// bundled Twemoji COLR (v0.7.0 / Twemoji 14, 2022) only as last-resort
/// fallback for old devices / CanvasKit, NOT as primary — otherwise iOS
/// loses newer Apple designs and Android loses newer Noto (GMS-updated)
/// designs.
///
/// - iOS/macOS: Apple first (OS-updated, Emoji 16/17).
/// - Android: system Noto/Samsung first (GMS-updated, Emoji 17). Bundled
///   Twemoji is fallback only; the #175653 bundled->system block is avoided
///   by giving emoji runs a *system* emoji primary (see [emojiRunStyle]).
/// - Windows: Segoe first (OS-updated), Twemoji fallback (Segoe is dated
///   but newer glyphs beat 2022 Twemoji).
/// - Web (Chrome/Edge/Safari/Firefox CanvasKit): bundled first (guaranteed
///   load), then system — CanvasKit blends bundled->system correctly.
List<String> getPlatformEmojiFallback() {
  if (kIsWeb) {
    return const [
      'Twemoji Mozilla',
      'Noto Color Emoji',
      'Apple Color Emoji',
      'Segoe UI Emoji',
      'Samsung Color Emoji',
      'EmojiOne Color',
    ];
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return const [
        'Apple Color Emoji',
        'Twemoji Mozilla',
        'Noto Color Emoji',
        'Segoe UI Emoji',
        'EmojiOne Color',
      ];
    case TargetPlatform.android:
      return const [
        'Noto Color Emoji',
        'Samsung Color Emoji',
        'SamsungOneColorEmoji',
        'SamsungOne',
        'Twemoji Mozilla',
        'Apple Color Emoji',
        'Segoe UI Emoji',
        'EmojiOne Color',
      ];
    case TargetPlatform.windows:
      return const [
        'Segoe UI Emoji',
        'Twemoji Mozilla',
        'Noto Color Emoji',
        'Apple Color Emoji',
        'EmojiOne Color',
      ];
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return const [
        'Noto Color Emoji',
        'Twemoji Mozilla',
        'Apple Color Emoji',
        'Segoe UI Emoji',
        'EmojiOne Color',
      ];
  }
}

/// System emoji primary per platform (no bundled sans involved, so Android
/// #175653 does not apply). Emoji runs use this as `fontFamily` so the 2026
/// native design wins; bundled Twemoji stays as fallback for old devices.
String? getEmojiFontFamily() {
  if (kIsWeb) return 'Twemoji Mozilla';
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return 'Apple Color Emoji';
    case TargetPlatform.android:
      return 'Noto Color Emoji';
    case TargetPlatform.windows:
      return 'Segoe UI Emoji';
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return 'Noto Color Emoji';
  }
}

/// Emoji-run style: system emoji primary + normal weight (bold makes Android
/// CBDT transparent) + platform fallback. Text runs keep Noto Sans.
TextStyle emojiRunStyle(TextStyle base) {
  final family = getEmojiFontFamily();
  final fallback = getPlatformEmojiFallback()
      .where((f) => f != family)
      .toList();
  return base.copyWith(
    fontFamily: family,
    fontFamilyFallback: [...fallback, 'Twemoji Mozilla'],
    fontWeight: FontWeight.normal,
  );
}

/// App default text family, matching the theme built in `main.dart`.
const String kAppDefaultTextFontFamily = 'Noto Sans';

/// Returns a copy of [style] with platform-best color emoji fonts first and
/// bundled monochrome symbol fonts last. Use for every chat text style so
/// `⛱️` cannot resolve to `Noto Sans Symbols` before the color font.
TextStyle withEmojiFallback(TextStyle style) {
  final platform = getPlatformEmojiFallback();
  final existing = style.fontFamilyFallback ?? const <String>[];
  // Drop mono symbols + any color fonts from their old positions; re-add
  // platform order first, mono last, to avoid duplicates.
  final platformSet = platform.toSet();
  final filtered = existing
      .where(
        (f) =>
            f != 'Noto Sans Symbols' &&
            f != 'Noto Sans Symbols2' &&
            f != 'Noto Sans' &&
            !platformSet.contains(f),
      )
      .toList();
  final primary = style.fontFamily ?? kAppDefaultTextFontFamily;
  return style.copyWith(
    // When `fontFamily` is null, dart:ui promotes the FIRST
    // `fontFamilyFallback` entry to the preferred font. That entry is an
    // emoji font, and Apple Color Emoji (iOS only) ships a very wide
    // U+0020 glyph, so chat text styled without a font family rendered
    // with 2-3x wider word gaps on iOS: letters fell through to the next
    // font that had them while only the space came from the emoji font.
    // Android's emoji fonts carry no space glyph, so it fell through to a
    // normal one there. A text font must always win the first slot.
    fontFamily: primary,
    fontFamilyFallback: [
      // A bundled TEXT font must come before the color emoji fonts. Every
      // emoji font's cmap maps the bare keycap bases (U+0030-0039, #, *) to
      // EMPTY glyphs - in the bundled Twemoji Mozilla they exist only as
      // components of the keycap sequences (u30-u39 have no outline and no
      // COLR layers, so they draw as blank spaces). A system primary that
      // fails to load (e.g. the Android chat composer's Roboto on devices
      // where the engine cannot match the family name, or Windows' Segoe UI
      // Emoji win) then swallows digits as invisible width. Bundled Noto
      // Sans has real digit/letter glyphs and zero emoji-claimable glyphs,
      // so it resolves text safely while emoji still prefer system fonts.
      if (primary != kAppDefaultTextFontFamily) kAppDefaultTextFontFamily,
      ...platform,
      ...filtered,
      'Noto Sans Symbols',
      'Noto Sans Symbols2',
    ],
  );
}
