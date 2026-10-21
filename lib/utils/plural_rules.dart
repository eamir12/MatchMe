// lib/utils/plural_rules.dart
//
// CLDR cardinal plural categories.
//
// The app renders a number next to a countable noun in a lot of places
// ("1 minute left", "3 unread messages", "2 hours"). Which noun form is
// correct depends on the language, not on the number alone:
//
//   * English  -> singular only for exactly 1 ("1 minute" / "2 minutes").
//   * Spanish  -> same as English for integers ("1 minuto" / "2 minutos").
//   * Hebrew   -> has a dual: 1 is singular, 2 is dual ("שתי דקות") and
//                 everything else is plural.
//
// The categories follow the Unicode CLDR cardinal rules (CLDR 43+), which is
// the same rule set ICU MessageFormat and the `intl` package use:
//
//   en: one   -> i = 1 and v = 0
//       other -> everything else
//
//   es: one   -> n = 1
//       many  -> e = 0 and i != 0 and i % 1000000 = 0 and v = 0
//       other -> everything else
//
//   he: one   -> i = 1 and v = 0  or  i = 0 and v != 0
//       two   -> i = 2 and v = 0
//       other -> everything else
//
// Only `en`, `es` and `he` are translated by the app today, but the resolver
// falls back to the English rule set for any other locale so a partially
// translated UI still says "1 minute" rather than "1 minutes".

/// The CLDR cardinal plural categories.
enum PluralCategory {
  zero,
  one,
  two,
  few,
  many,
  other;

  /// The suffix used to build a category specific translation key,
  /// e.g. `matchExpiryTitle_one`.
  String get keySuffix => name;

  /// Parses a category name coming from a translation key suffix.
  ///
  /// Returns null for anything that is not a known category, so callers can
  /// treat "not a plural suffix" and "unknown plural suffix" the same way.
  static PluralCategory? tryParse(String? raw) {
    if (raw == null) return null;
    for (final category in PluralCategory.values) {
      if (category.name == raw) return category;
    }
    return null;
  }
}

/// The locale used when the UI language has no specific rule set.
const String kFallbackPluralLocale = 'en';

/// Resolves the CLDR cardinal plural category of [count] in [languageCode].
///
/// [languageCode] is a bare ISO 639-1 code ("en", "he", "es"). Region and
/// script subtags are ignored ("he-IL" behaves like "he").
///
/// Fractional counts are supported: the rules look at the integer part (`i`),
/// the number of visible fraction digits (`v`) and the exponent (`e`) exactly
/// like CLDR does, so 1.0 is singular in English while 1.00 is not.
PluralCategory pluralCategoryFor({
  required String languageCode,
  required num count,
}) {
  final locale = _baseLanguageCode(languageCode);
  switch (locale) {
    case 'he':
      return _hebrewCategory(count);
    case 'es':
      return _spanishCategory(count);
    case 'en':
    default:
      return _englishCategory(count);
  }
}

/// Strips region/script subtags and normalises the legacy Hebrew code.
String _baseLanguageCode(String languageCode) {
  var code = languageCode.trim().toLowerCase().replaceAll('_', '-');
  if (code.isEmpty) return kFallbackPluralLocale;
  final base = code.split('-').first;
  if (base == 'iw') return 'he';
  return base;
}

/// `i` (integer digits), `v` (visible fraction digits) and `e` (exponent) as
/// defined by CLDR.
class _CldrOperands {
  final int i;
  final int v;
  final int e;

  const _CldrOperands(this.i, this.v, this.e);

  factory _CldrOperands.of(num count) {
    if (count is int) {
      return _CldrOperands(count, 0, 0);
    }

    var text = count.toString();
    var negative = false;
    if (text.startsWith('-')) {
      negative = true;
      text = text.substring(1);
    }

    var exponent = 0;
    final eIndex = text.indexOf(RegExp('[eE]'));
    if (eIndex >= 0) {
      exponent = int.tryParse(text.substring(eIndex + 1)) ?? 0;
      text = text.substring(0, eIndex);
    }

    var integerPart = text;
    var fractionPart = '';
    final dotIndex = text.indexOf('.');
    if (dotIndex >= 0) {
      integerPart = text.substring(0, dotIndex);
      fractionPart = text.substring(dotIndex + 1);
    }

    var integerDigits = int.tryParse(
      integerPart.isEmpty ? '0' : integerPart,
    ) ?? 0;
    var fractionDigits = fractionPart.length;

    if (exponent > 0) {
      integerDigits *= _pow10(exponent);
    } else if (exponent < 0) {
      fractionDigits += -exponent;
    }

    // A value without a fractional part is displayed as an integer, so it has
    // no visible fraction digits: 1.0 is the same as 1 and takes the singular
    // form, exactly like the `intl` package does.
    if (fractionDigits > 0 && _isAllZeroes(fractionPart)) {
      fractionDigits = 0;
    }

    return _CldrOperands(
      negative ? -integerDigits : integerDigits,
      fractionDigits,
      exponent,
    );
  }
}

bool _isAllZeroes(String digits) {
  for (final unit in digits.codeUnits) {
    if (unit != 0x30) return false; // '0'
  }
  return true;
}

int _pow10(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}

/// English: singular for exactly 1 (an integer), plural otherwise.
PluralCategory _englishCategory(num count) {
  final operands = _CldrOperands.of(count);
  if (operands.i == 1 && operands.v == 0) return PluralCategory.one;
  return PluralCategory.other;
}

/// Spanish: singular for exactly 1, plural otherwise.
///
/// Spanish has a `many` category for exact multiples of a million
/// ("2 millones"); the app never counts that high, but the rule is kept so
/// the category matches CLDR exactly.
PluralCategory _spanishCategory(num count) {
  final operands = _CldrOperands.of(count);
  if (count == 1) return PluralCategory.one;
  if (operands.e == 0 &&
      operands.i != 0 &&
      operands.i % 1000000 == 0 &&
      operands.v == 0) {
    return PluralCategory.many;
  }
  return PluralCategory.other;
}

/// Hebrew: singular for 1, dual for 2, plural for everything else.
PluralCategory _hebrewCategory(num count) {
  final operands = _CldrOperands.of(count);
  if ((operands.i == 1 && operands.v == 0) ||
      (operands.i == 0 && operands.v != 0)) {
    return PluralCategory.one;
  }
  if (operands.i == 2 && operands.v == 0) return PluralCategory.two;
  return PluralCategory.other;
}
