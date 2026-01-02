// lib/services/platform/web_translation_service.dart
//
// This is the WEB implementation.
// It uses Supabase Edge Function proxy to call DeepL (avoids CORS issues).

import 'dart:developer' as developer;
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/text_formatter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// This function is called by translation_service.dart for web platform
TranslationService getWebTranslationService() => WebTranslationService();

// Also provide the unified interface for conditional import
TranslationService getPlatformTranslationService() => getWebTranslationService();

class WebTranslationService implements TranslationService {
  final _supabase = Supabase.instance.client;

  @override
  Future<String> identifyLanguage(String text) async {
    // For web, we'll let the proxy function handle auto-detection
    return 'auto';
  }

  @override
  Future<String> translateText(String text, String sourceLang, String targetLang, {String? recipientGender}) async {
    developer.log('WebTranslationService: translateText called with text="$text", source="$sourceLang", target="$targetLang", gender="$recipientGender"');

    if (text.trim().isEmpty) {
      developer.log('WebTranslationService: Text is empty, returning as-is');
      return text;
    }

    try {
      developer.log('WebTranslationService: Calling Supabase Edge Function with DeepL');

      // For now, don't add gender prefixes to avoid confusing DeepL's language detection
      // We'll handle gender-specific translations differently in the future
      String textToTranslate = text;

      // Call our Supabase Edge Function that proxies to DeepL
      final response = await _supabase.functions.invoke(
        'translate-proxy', // The Edge Function that calls DeepL
        body: {
          'text': textToTranslate,
          'target_lang': targetLang,
          'source_lang': sourceLang != 'und' ? sourceLang : 'auto',
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
        final errorMessage = response.data?['error']?.toString() ?? 'Failed to parse translation. Data was null or missing "translatedText".';
        throw Exception(errorMessage);
      }
    } catch (e) {
      developer.log('WebTranslationService: Translation failed: $e');
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
