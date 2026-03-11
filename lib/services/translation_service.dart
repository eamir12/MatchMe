// lib/services/translation_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

// Import the appropriate service based on platform to avoid DDC conflicts
// This imports the correct platform-specific file and makes its function available
import 'platform/deepl_translation_service.dart' if (dart.library.html) 'platform/web_translation_service.dart';

String normalizeLanguageCode(String code) {
  final c = code.trim().toLowerCase();
  if (c == 'iw') return 'he';
  return c;
}

String guessLanguageCode(String text) {
  final t = text.trim();
  if (t.isEmpty) return 'und';

  final hasHebrew = RegExp(r'[\u0590-\u05FF]').hasMatch(t);
  if (hasHebrew) return 'he';

  final lower = t.toLowerCase();
  final hasSpanishMarks = lower.contains('¿') ||
      lower.contains('¡') ||
      lower.contains('ñ') ||
      lower.contains('á') ||
      lower.contains('é') ||
      lower.contains('í') ||
      lower.contains('ó') ||
      lower.contains('ú') ||
      lower.contains('ü');
  if (hasSpanishMarks) return 'es';

  final words = lower
      .replaceAll(RegExp(r"[^a-záéíóúüñ¿¡\s]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  if (words.isEmpty) return 'und';

  const spanishCommon = {
    'hola',
    'que',
    'cómo',
    'como',
    'estás',
    'estas',
    'gracias',
    'por',
    'favor',
    'vale',
    'bien',
    'buenos',
    'buenas',
    'donde',
    'dónde',
    'cuando',
    'cuándo',
    'porque',
    'porqué',
    'pero',
    'si',
    'sí',
    'no',
    'de',
    'la',
    'el',
    'y',
    'en',
    'para',
    'con',
    'una',
    'un',
    'yo',
    'tu',
    'tú',
    'te',
    'me',
  };

  const englishCommon = {
    'hi',
    'hello',
    'thanks',
    'thank',
    'you',
    'are',
    'is',
    'am',
    'to',
    'of',
    'in',
    'for',
    'on',
    'with',
    'and',
    'the',
    'a',
    'i',
    'we',
    'me',
    'my',
    'your',
    'ok',
    'yes',
    'no',
  };

  var esScore = 0;
  var enScore = 0;

  for (final w in words) {
    if (spanishCommon.contains(w)) esScore++;
    if (englishCommon.contains(w)) enScore++;
  }

  if (esScore >= 2 && esScore > enScore) return 'es';
  if (enScore >= 2 && enScore > esScore) return 'en';

  if (esScore == 1 && enScore == 0) return 'es';
  if (enScore == 1 && esScore == 0) return 'en';

  return 'en';
}

// 1. Define the abstract interface (the "contract")
abstract class TranslationService {
  Future<String> identifyLanguage(String text);
  Future<bool> isModelDownloaded(String langCode);
  Future<bool> downloadModel(String langCode);
  /// Translate text from source to target language.
  /// [recipientGender] can be 'male', 'female', 'nonbinary', etc. to help with gender-specific translations
  Future<String> translateText(String text, String sourceLang, String targetLang, {String? recipientGender});
  void dispose();
}

// 2. Create the provider
final translationServiceProvider = Provider<TranslationService>((ref) {
  // Use the imported platform-specific service
  final service = getPlatformTranslationService();

  if (kIsWeb) {
  } else {
  }

  ref.onDispose(() => service.dispose());
  return service;
});

// Platform-specific factory function - this gets resolved by the conditional import above
// The imported file provides getPlatformTranslationService() which internally calls the right platform-specific function
