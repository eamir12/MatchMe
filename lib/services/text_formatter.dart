// lib/services/text_formatter.dart
//
// Text formatting utilities to apply language-specific conventions
// to translated text (capitalization, punctuation, etc.)

class TextFormatter {
  static String formatForLanguage(String text, String targetLanguage) {
    if (text.isEmpty) return text;

    switch (targetLanguage.toLowerCase()) {
      case 'en':
        return _formatEnglish(text);
      case 'es':
        return _formatSpanish(text);
      case 'fr':
        return _formatFrench(text);
      case 'de':
        return _formatGerman(text);
      case 'it':
        return _formatItalian(text);
      case 'pt':
        return _formatPortuguese(text);
      case 'ru':
        return _formatRussian(text);
      case 'ja':
        return _formatJapanese(text);
      case 'ko':
        return _formatKorean(text);
      case 'zh':
        return _formatChinese(text);
      case 'ar':
        return _formatArabic(text);
      case 'he':
        return _formatHebrew(text);
      default:
        // For unsupported languages, apply basic English formatting
        return _formatEnglish(text);
    }
  }

  static String _formatEnglish(String text) {
    if (text.isEmpty) return text;

    // Handle multiple sentences
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final formattedSentences = sentences.map((sentence) {
      if (sentence.trim().isEmpty) return sentence;

      // Capitalize first letter of sentence
      final trimmed = sentence.trim();
      if (trimmed.isNotEmpty) {
        return trimmed[0].toUpperCase() + trimmed.substring(1);
      }
      return trimmed;
    });

    String result = formattedSentences.join(' ');

    // Handle common English capitalization rules
    result = _capitalizeAfterColons(result);
    result = _capitalizeDaysOfWeek(result);
    result = _capitalizeMonths(result);
    result = _capitalizeProperNouns(result);

    return result;
  }

  static String _formatSpanish(String text) {
    // Spanish has similar rules to English but with different proper nouns
    if (text.isEmpty) return text;

    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final formattedSentences = sentences.map((sentence) {
      final trimmed = sentence.trim();
      if (trimmed.isNotEmpty) {
        return trimmed[0].toUpperCase() + trimmed.substring(1);
      }
      return trimmed;
    });

    String result = formattedSentences.join(' ');
    result = _capitalizeAfterColons(result);

    return result;
  }

  static String _formatFrench(String text) {
    // French sentences start with capital letters
    if (text.isEmpty) return text;

    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final formattedSentences = sentences.map((sentence) {
      final trimmed = sentence.trim();
      if (trimmed.isNotEmpty) {
        return trimmed[0].toUpperCase() + trimmed.substring(1);
      }
      return trimmed;
    });

    return formattedSentences.join(' ');
  }

  static String _formatGerman(String text) {
    // German capitalizes all nouns, but for basic formatting we'll capitalize sentence starts
    if (text.isEmpty) return text;

    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final formattedSentences = sentences.map((sentence) {
      final trimmed = sentence.trim();
      if (trimmed.isNotEmpty) {
        return trimmed[0].toUpperCase() + trimmed.substring(1);
      }
      return trimmed;
    });

    return formattedSentences.join(' ');
  }

  static String _formatItalian(String text) {
    // Similar to other Romance languages
    return _formatSentenceCase(text);
  }

  static String _formatPortuguese(String text) {
    // Similar to other Romance languages
    return _formatSentenceCase(text);
  }

  static String _formatRussian(String text) {
    // Russian doesn't use sentence capitalization like English
    // But we can still ensure proper formatting
    return text;
  }

  static String _formatJapanese(String text) {
    // Japanese doesn't use capitalization
    return text;
  }

  static String _formatKorean(String text) {
    // Korean doesn't use capitalization
    return text;
  }

  static String _formatChinese(String text) {
    // Chinese doesn't use capitalization
    return text;
  }

  static String _formatArabic(String text) {
    // Arabic doesn't use capitalization
    return text;
  }

  static String _formatHebrew(String text) {
    // Hebrew doesn't use capitalization like English
    return text;
  }

  // Helper methods

  static String _formatSentenceCase(String text) {
    if (text.isEmpty) return text;

    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final formattedSentences = sentences.map((sentence) {
      final trimmed = sentence.trim();
      if (trimmed.isNotEmpty) {
        return trimmed[0].toUpperCase() + trimmed.substring(1);
      }
      return trimmed;
    });

    return formattedSentences.join(' ');
  }

  static String _capitalizeAfterColons(String text) {
    // Capitalize words after colons (common in English)
    return text.replaceAllMapped(
      RegExp(r':\s*([a-z])'),
      (match) => ': ${match.group(1)!.toUpperCase()}',
    );
  }

  static String _capitalizeDaysOfWeek(String text) {
    const daysOfWeek = [
      'monday',
      'tuesday',
      'wednesday',
      'thursday',
      'friday',
      'saturday',
      'sunday',
    ];

    String result = text;
    for (final day in daysOfWeek) {
      final capitalized = day[0].toUpperCase() + day.substring(1);
      result = result.replaceAll(
        RegExp(r'\b$day\b', caseSensitive: false),
        capitalized,
      );
    }

    return result;
  }

  static String _capitalizeMonths(String text) {
    const months = [
      'january',
      'february',
      'march',
      'april',
      'may',
      'june',
      'july',
      'august',
      'september',
      'october',
      'november',
      'december',
    ];

    String result = text;
    for (final month in months) {
      final capitalized = month[0].toUpperCase() + month.substring(1);
      result = result.replaceAll(
        RegExp(r'\b$month\b', caseSensitive: false),
        capitalized,
      );
    }

    return result;
  }

  static String _capitalizeProperNouns(String text) {
    // This is a basic implementation - in a real app, you'd want more sophisticated
    // proper noun detection, but this covers common cases

    // Capitalize words that appear to be proper nouns (start with capital letter
    // and are not at the beginning of sentences)
    final words = text.split(' ');
    final processedWords = <String>[];

    for (int i = 0; i < words.length; i++) {
      final word = words[i];
      if (word.isNotEmpty) {
        // If word looks like a proper noun (contains uppercase letters beyond first char)
        // or is a common proper noun pattern
        if (_looksLikeProperNoun(word)) {
          processedWords.add(_capitalizeWord(word));
        } else {
          processedWords.add(word);
        }
      }
    }

    return processedWords.join(' ');
  }

  static bool _looksLikeProperNoun(String word) {
    // Basic heuristics for proper nouns
    if (word.length <= 1) return false;

    // Words that are already properly capitalized
    if (word[0].toUpperCase() == word[0] &&
        word.substring(1).toLowerCase() == word.substring(1)) {
      return true;
    }

    // Words that contain apostrophes (like names: O'Connor, D'Angelo)
    if (word.contains("'")) return true;

    // Words that are all caps (acronyms)
    if (word == word.toUpperCase()) return true;

    return false;
  }

  static String _capitalizeWord(String word) {
    if (word.isEmpty) return word;
    return word[0].toUpperCase() + word.substring(1).toLowerCase();
  }
}
