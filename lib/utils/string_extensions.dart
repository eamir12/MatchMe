// lib/utils/string_extensions.dart

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
    final cleaned = replaceAll(
      RegExp('[\u200E\u200F\u202A-\u202E]'),
      '',
    ).trim();
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
  String formatAsFirstNameLastInitial() {
    final cleaned = replaceAll(
      RegExp('[\u200E\u200F\u202A-\u202E]'),
      '',
    ).trim();
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
      return '\u200E${_capitalizeNameWord(parts[0])}\u200E';
    } else if (parts.length == 2) {
      // Simple case: "John Doe" -> "John D."
      final first = capFirstName(parts[0], true);
      final initial = parts[1].isNotEmpty ? parts[1][0].toUpperCase() : '';
      if (initial.isEmpty) return '\u200E$first\u200E';
      return '\u200E$first $initial.\u200E';
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
      if (lastInitial.isEmpty) return '\u200E$firstNames\u200E';
      return '\u200E$firstNames $lastInitial.\u200E';
    }
  }
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
