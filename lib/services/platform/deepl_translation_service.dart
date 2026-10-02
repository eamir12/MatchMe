import 'package:flutter/foundation.dart';

import '../text_formatter.dart';
import '../translation_service.dart';

// This function is called by translation_service.dart for mobile platform
TranslationService getMobileTranslationService() => DeepLTranslationService();

// Also provide the unified interface for conditional import
TranslationService getPlatformTranslationService() =>
    getMobileTranslationService();

class DeepLTranslationService implements TranslationService {
  @override
  Future<String> identifyLanguage(String text) async {
    return normalizeLanguageCode(guessLanguageCode(text));
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
    final deepLTargetLang = _mapToDeepLLanguage(targetLang);

    if (text.trim().isEmpty) {
      return text;
    }

    final translated = await _translateViaEdgeFunction(
      text,
      sourceLang,
      deepLTargetLang,
      speakerGender: speakerGender,
      recipientGender: recipientGender,
    );
    return TextFormatter.formatForLanguage(translated, targetLang);
  }

  Future<String> _translateViaEdgeFunction(
    String text,
    String sourceLang,
    String targetLang, {
    String? speakerGender,
    String? recipientGender,
  }) async {
    try {
      // Gender steering is built server-side (single source of truth): send
      // raw genders and let the edge render DeepL `context` in the
      // documented natural-clue style. Never render instructions client-side.
      final response = await TranslationProxy.invoke(
        body: {
          'text': text,
          'target_lang': targetLang, // Already mapped to DeepL format
          'source_lang': sourceLang != 'und' ? sourceLang : 'auto',
          'speaker_gender': ?speakerGender,
          'addressee_gender': ?recipientGender,
        },
      );

      if (response.data != null && response.data['translatedText'] != null) {
        return response.data['translatedText'] as String;
      }
      debugPrint(
        '[DeepL] translate response missing translatedText '
        '(target=$targetLang, length=${text.length})',
      );
    } catch (e) {
      // Graceful degradation for callers: return the original text, but log
      // so silent-English symptoms (e.g. photo rejections) are diagnosable.
      debugPrint('[DeepL] translate failed (target=$targetLang): $e');
      return text;
    }
    return text;
  }

  @override
  void dispose() {
    // No resources to dispose for DeepL service
  }
}
