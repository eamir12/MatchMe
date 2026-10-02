// lib/services/platform/web_translation_service.dart
//
// This is the WEB implementation.
// It uses Supabase Edge Function proxy to call DeepL (avoids CORS issues).

import 'package:matchme/services/text_formatter.dart';
import 'package:matchme/services/translation_service.dart';

// This function is called by translation_service.dart for web platform
TranslationService getWebTranslationService() => WebTranslationService();

// Also provide the unified interface for conditional import
TranslationService getPlatformTranslationService() =>
    getWebTranslationService();

class WebTranslationService implements TranslationService {
  @override
  Future<String> identifyLanguage(String text) async {
    return normalizeLanguageCode(guessLanguageCode(text));
  }

  // Helper: map app language codes to DeepL language codes
  String _mapToDeepLLanguage(String appLangCode) {
    const langMap = {
      'iw': 'he', // Hebrew
      'he': 'he', // Hebrew
      'in': 'id', // Indonesian
      'id': 'id', // Indonesian
      'zh': 'zh', // Chinese
      'zh-cn': 'zh', // Chinese Simplified
      'zh-tw': 'zh', // Chinese Traditional
    };

    final lowerCode = appLangCode.toLowerCase();
    return langMap[lowerCode] ?? appLangCode;
  }

  @override
  Future<String> translateText(
    String text,
    String sourceLang,
    String targetLang, {
    String? recipientGender,
    String? speakerGender,
  }) async {
    // Map target language to DeepL format
    final deepLTargetLang = _mapToDeepLLanguage(targetLang);

    if (text.trim().isEmpty) {
      return text;
    }

    try {
      // Gender steering is built server-side (single source of truth): send
      // raw genders and let the edge render DeepL `context` in the
      // documented natural-clue style. Never render instructions client-side.
      String textToTranslate = text;

      // Call our Supabase Edge Function that proxies to DeepL
      final response = await TranslationProxy.invoke(
        body: {
          'text': textToTranslate,
          'target_lang': deepLTargetLang, // Already mapped to DeepL format
          'source_lang': sourceLang != 'und' ? sourceLang : 'auto',
          'speaker_gender': ?speakerGender,
          'addressee_gender': ?recipientGender,
        },
      );

      // The Edge Function returns 'translatedText'
      if (response.data != null && response.data['translatedText'] != null) {
        String translated = response.data['translatedText'] as String;

        // Apply language-specific formatting
        translated = TextFormatter.formatForLanguage(translated, targetLang);

        return translated;
      } else {
        // Better error logging
        final errorMessage =
            response.data?['error']?.toString() ??
            'Failed to parse translation. Data was null or missing "translatedText".';
        throw Exception(errorMessage);
      }
    } catch (e) {
      // Return original text on error
      return text;
    }
  }

  @override
  Future<bool> isModelDownloaded(String langCode) async {
    // DeepL doesn't require local model downloads - always return true
    return true;
  }

  @override
  Future<bool> downloadModel(String langCode) async {
    // DeepL doesn't require local model downloads - always return true
    return true;
  }

  @override
  void dispose() {
    // Nothing to dispose
  }
}
