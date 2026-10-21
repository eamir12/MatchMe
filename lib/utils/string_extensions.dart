// lib/utils/string_extensions.dart

import 'dart:ui' show TextAlign, TextDirection;

/// Left-to-right mark (U+200E).
///
/// A strong LTR character. Wrapping a name in it keeps the name's trailing
/// period ("First L.") glued to the initial even when the name is shown
/// inside a right-to-left paragraph.
const String lrm = '\u200E';

/// Right-to-left mark (U+200F) — the RTL counterpart of [lrm].
const String rlm = '\u200F';

/// Every explicit bidi control the app may have added around a name: the
/// marks, the embeddings/overrides and the isolates.
final RegExp bidiControls = RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]');

/// A masked display name at the very end of a string: a word, a space, then a
/// single-letter initial with its period ("First L." / "דוד ל.").
///
/// The server builds notification bodies by gluing a masked name onto a
/// sentence ("You matched with First L."), and the trailing period of that
/// name is a neutral character — inside a right-to-left paragraph it resolves
/// to the paragraph direction and lands on the wrong side of the name.
final RegExp _trailingDisplayName = RegExp(r'([^\s]+)\s+([^\s])\.$');

extension StringExtension on String {
  /// Capitalizes the first letter of the string and lowercases the rest.
  String capitalize() {
    if (isEmpty) {
      return "";
    }
    return "${this[0].toUpperCase()}${substring(1).toLowerCase()}";
  }

  /// Detects if a string contains Right-to-Left characters (e.g., Hebrew, Arabic)
  /// Returns true if the string contains any RTL characters, regardless of other characters
  bool isRtl() {
    if (isEmpty) return false;
    final rtlRegex = RegExp(r'[\u0590-\u05FF\u0600-\u06FF]');
    return rtlRegex.hasMatch(this);
  }

  /// First-strong-character direction detection, mirroring the chat composer.
  ///
  /// Scans from the start, skipping neutral characters (digits, spaces,
  /// punctuation, emoji): the first Latin letter wins LTR, the first
  /// Hebrew/Arabic character wins RTL. Empty or neutral-only text returns
  /// false (LTR). Use this for input fields that must auto-align while the
  /// user types, so Hebrew aligns right and English/Spanish aligns left.
  bool isRtlByFirstStrongChar() {
    if (isEmpty) return false;
    final rtlRegex = RegExp(r'[\u0590-\u05FF\u0600-\u06FF]');
    final ltrRegex = RegExp(r'[a-zA-Z]');
    for (var i = 0; i < length; i++) {
      final char = this[i];
      if (ltrRegex.hasMatch(char)) return false;
      if (rtlRegex.hasMatch(char)) return true;
    }
    return false;
  }

  /// Capitalizes a person's name, handling multiple first/last names
  /// (e.g. Spanish "ana maria hernandez martinez"), hyphenated names
  /// ("jean-pierre"), and apostrophes ("o'brien" -> "O'Brien").
  /// Common particles (de, del, la, y, van, von, ...) stay lowercase unless
  /// they are the first word.
  String capitalizeName() {
    final cleaned = replaceAll(bidiControls, '').trim();
    if (cleaned.isEmpty) return '';
    final parts = cleaned
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    return parts
        .asMap()
        .entries
        .map((e) {
          final index = e.key;
          final word = e.value;
          if (index != 0 && _nameParticles.contains(word.toLowerCase())) {
            return word.toLowerCase();
          }
          return _capitalizeNameWord(word);
        })
        .join(' ');
  }

  /// Formats a full name as "First LastInitial." (e.g., "John Doe" -> "John D.")
  /// For Latin American names with multiple names, returns all first names
  /// plus the initial of the last name. Example: "Ana Maria Hernandez Martinez"
  /// -> "Ana Maria H."
  /// Capitalizes every displayed name part regardless of how the user typed it:
  /// "jOHN dOE" -> "John D.", "ana maria hernandez martinez" -> "Ana Maria H."
  ///
  /// The result carries the directional mark of the name's own script, so the
  /// trailing period stays glued to the initial wherever the name is shown —
  /// on its own or inside a sentence, in a Hebrew or an English UI.
  String formatAsFirstNameLastInitial() {
    final cleaned = replaceAll(bidiControls, '').trim();
    if (cleaned.isEmpty) return this;
    final parts = cleaned
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return this;

    String capFirstName(String word, bool isFirst) {
      if (!isFirst && _nameParticles.contains(word.toLowerCase())) {
        return word.toLowerCase();
      }
      return _capitalizeNameWord(word);
    }

    if (parts.length == 1) {
      // Single word name, capitalize it
      return _capitalizeNameWord(parts[0]).withDirectionalMarks();
    } else if (parts.length == 2) {
      // Simple case: "John Doe" -> "John D."
      final first = capFirstName(parts[0], true);
      final initial = parts[1].isNotEmpty ? parts[1][0].toUpperCase() : '';
      if (initial.isEmpty) return first.withDirectionalMarks();
      return '$first $initial.'.withDirectionalMarks();
    } else {
      // Multiple names: "Ana Maria Hernandez Martinez" -> "Ana Maria H."
      // First names = all words except the last one
      final firstNames = parts
          .sublist(0, parts.length - 1)
          .asMap()
          .entries
          .map((e) {
            return capFirstName(e.value, e.key == 0);
          })
          .join(' ');
      final lastInitial = parts.last.isNotEmpty
          ? parts.last[0].toUpperCase()
          : '';
      if (lastInitial.isEmpty) return firstNames.withDirectionalMarks();
      return '$firstNames $lastInitial.'.withDirectionalMarks();
    }
  }

  /// This string without the explicit bidi controls the app adds around names.
  String get withoutBidiControls => replaceAll(bidiControls, '');

  /// Wraps this string in the directional mark of its own script.
  ///
  /// A masked display name ends in a period ("First L."). That period is a
  /// neutral character: in a right-to-left paragraph it resolves to the
  /// paragraph direction and lands on the wrong side of the name — the name
  /// reads "L First." instead of "First L.". Marking the name with its own
  /// direction keeps the period glued to the initial wherever it is shown: as
  /// a heading, as a notification title, or inside a sentence.
  String withDirectionalMarks() {
    final cleaned = withoutBidiControls.trim();
    if (cleaned.isEmpty) return this;
    final mark = cleaned.isRtlByFirstStrongChar() ? rlm : lrm;
    return '$mark$cleaned$mark';
  }

  /// Marks a masked display name that ends this string ("First L.") with the
  /// directional mark of the name's own script.
  ///
  /// Notification bodies embed the masked name in a sentence ("You matched
  /// with First L."). The name arrives as plain text, so its trailing period
  /// is swallowed by the surrounding paragraph direction. Marking just that
  /// name keeps the period with the initial while the rest of the sentence
  /// keeps its own direction.
  String isolateTrailingDisplayName() {
    final match = _trailingDisplayName.firstMatch(this);
    if (match == null) return this;
    final name = match.group(0)!;
    final marked = name.withDirectionalMarks();
    if (marked == name) return this;
    return replaceRange(match.start, match.end, marked);
  }

  /// Base direction for showing this string as its own block of text.
  ///
  /// The direction follows the first strong character of the string: Latin
  /// letters win LTR, Hebrew/Arabic wins RTL, anything else falls back to
  /// LTR — the same rule the matched profile screen has always used for
  /// its title. It matters because a name formatted as "First L." ends in a
  /// period: laid out against the surrounding UI direction the period ends up
  /// on the wrong side of the name (a Hebrew name in an English UI grows a
  /// stray dot on its right), while laying the name out in its own script
  /// keeps the dot glued to the initial where readers expect it.
  ///
  /// Only the *first* strong character decides: a sentence that starts in
  /// Hebrew and mentions an English name ("יש לך התאמה עם First L.") stays
  /// right-to-left, while a name that starts with a Latin letter stays
  /// left-to-right.
  TextDirection displayTextDirection() {
    if (isRtlByFirstStrongChar()) return TextDirection.rtl;
    return TextDirection.ltr;
  }

  /// [displayTextDirection] plus the edge the text block should sit against.
  ///
  /// The direction follows the name, but the alignment stays pinned to the
  /// UI direction ([uiDirection]): a Hebrew name in an English UI must keep
  /// starting on the left instead of jumping to the right edge the moment its
  /// paragraph direction flips.
  ({TextDirection textDirection, TextAlign textAlign}) displayTextLayout(
    TextDirection uiDirection,
  ) => (
    textDirection: displayTextDirection(),
    textAlign: uiDirection == TextDirection.rtl
        ? TextAlign.right
        : TextAlign.left,
  );
}

/// Particles across Spanish and other languages that stay lowercase when they
/// are not the first word of a name (e.g. "Maria de los Angeles", "Jan van Dyck").
const Set<String> _nameParticles = {
  'de',
  'del',
  'la',
  'las',
  'los',
  'el',
  'y',
  'e',
  'da',
  'do',
  'das',
  'dos',
  'van',
  'von',
  'der',
  'den',
  'di',
  'du',
  'le',
  'les',
  'al',
};

/// Capitalizes a single name word, handling hyphens ("jean-pierre" ->
/// "Jean-Pierre") and apostrophes ("o'brien" -> "O'Brien").
String _capitalizeNameWord(String word) {
  if (word.isEmpty) return word;
  // Hyphenated parts are each capitalized: "jean-pierre" -> "Jean-Pierre".
  final hyphenParts = word.split('-');
  final capitalized = hyphenParts
      .map((hyphenPart) {
        if (hyphenPart.isEmpty) return hyphenPart;
        // Apostrophe parts are each capitalized: "o'brien" -> "O'Brien".
        final apostropheParts = hyphenPart.split("'");
        final capApostrophe = apostropheParts
            .map((segment) {
              if (segment.isEmpty) return segment;
              final lower = segment.toLowerCase();
              return '${lower[0].toUpperCase()}${lower.substring(1)}';
            })
            .join("'");
        return capApostrophe;
      })
      .join('-');
  return capitalized;
}
