// lib/services/platform/mobile_translation_service.dart
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import '../translation_service.dart'; // Import the abstract class

// --- This function is exported to the provider ---
TranslationService getMobileTranslationService() {
  return MobileTranslationService();
}

// This is the real implementation for Android/iOS
class MobileTranslationService implements TranslationService {
  final _languageIdentifier = LanguageIdentifier(confidenceThreshold: 0.5);
  final Map<String, OnDeviceTranslator> _translators = {};

  TranslateLanguage? _getTranslateLanguage(String langCode) {
    // Try to find the language by BCP-47 code
    try {
      // In newer versions, we might need to use a different approach
      // For now, let's try to map common language codes
      switch (langCode.toLowerCase()) {
        case 'en':
          return TranslateLanguage.english;
        case 'es':
          return TranslateLanguage.spanish;
        case 'fr':
          return TranslateLanguage.french;
        case 'de':
          return TranslateLanguage.german;
        case 'it':
          return TranslateLanguage.italian;
        case 'pt':
          return TranslateLanguage.portuguese;
        case 'ru':
          return TranslateLanguage.russian;
        case 'ja':
          return TranslateLanguage.japanese;
        case 'ko':
          return TranslateLanguage.korean;
        case 'zh':
          return TranslateLanguage.chinese;
        case 'ar':
          return TranslateLanguage.arabic;
        case 'hi':
          return TranslateLanguage.hindi;
        case 'he':
          return TranslateLanguage.hebrew;
        default:
          // For unsupported languages, return null
          return null;
      }
    } catch (e) {
      return null;
    }
  }

  OnDeviceTranslator _getTranslator(String sourceLang, String targetLang) {
    final key = '$sourceLang-$targetLang';
    if (_translators.containsKey(key)) {
      return _translators[key]!;
    }

    final TranslateLanguage? source = _getTranslateLanguage(sourceLang);
    final TranslateLanguage? target = _getTranslateLanguage(targetLang);

    if (source == null) throw Exception('Invalid source language code: $sourceLang');
    if (target == null) throw Exception('Invalid target language code: $targetLang');

    final translator = OnDeviceTranslator(
      sourceLanguage: source,
      targetLanguage: target,
    );
    _translators[key] = translator;
    return translator;
  }

  @override
  Future<String> identifyLanguage(String text) async {
    try {
      final langCode = await _languageIdentifier.identifyLanguage(text);
      return langCode;
    } catch (e) {
      return 'und';
    }
  }

  @override
  Future<bool> isModelDownloaded(String langCode) async {
    try {
      final modelManager = OnDeviceTranslatorModelManager();
      return await modelManager.isModelDownloaded(langCode);
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> downloadModel(String langCode) async {
    try {
      final modelManager = OnDeviceTranslatorModelManager();
      await modelManager.downloadModel(langCode, isWifiRequired: true);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<String> translateText(String text, String sourceLang, String targetLang, {String? recipientGender}) async {
    try {
      // Prepare the text for translation
      String textToTranslate = text;
      bool hasGenderPrefix = false;
      
      // Add gender context hint if provided to help with gender-specific translations
      if (recipientGender != null && recipientGender.isNotEmpty) {
        final genderLower = recipientGender.toLowerCase();
        if (genderLower == 'male' || genderLower == 'female') {
          // For Hebrew, use the actual pronoun to ensure singular form
          if (targetLang.toLowerCase() == 'he') {
            if (genderLower == 'male') {
              textToTranslate = 'אתה $text'; // "You (male)" in Hebrew
            } else {
              textToTranslate = 'את $text'; // "You (female)" in Hebrew
            }
          } else {
            // For other languages, Google ML Kit might handle context better, but we can still add a hint
            textToTranslate = '[Speaking to a $genderLower] $text';
          }
          hasGenderPrefix = true;
        }
      }
      
      final translator = _getTranslator(sourceLang, targetLang);
      final isSourceDownloaded = await isModelDownloaded(sourceLang);
      if (!isSourceDownloaded) {
        final success = await downloadModel(sourceLang);
        if (!success) return 'Error: Source language pack unavailable.';
      }
      final isTargetDownloaded = await isModelDownloaded(targetLang);
      if (!isTargetDownloaded) {
        final success = await downloadModel(targetLang);
        if (!success) return 'Error: Target language pack unavailable.';
      }
      final translatedText = await translator.translateText(textToTranslate);
      
      // Remove gender prefix if we added one
      String result = translatedText;
      if (hasGenderPrefix) {
        result = _removeGenderPrefix(result);
      }
      
      return result;
    } catch (e) {
      return text; // Return original text on error
    }
  }

  @override
  void dispose() {
    _languageIdentifier.close();
    for (final translator in _translators.values) {
      translator.close();
    }
    _translators.clear();
  }
}

/// Remove gender prefix from translated text (best effort)
String _removeGenderPrefix(String translated) {
  // Remove common translated prefixes like "[Speaking to a male]", "[Hablando con un hombre]", etc.
  final patterns = [
    RegExp(r'^\[.*?\]\s*', caseSensitive: false), // Remove anything in brackets at start
    RegExp(r'^.*?(male|female|hombre|mujer|homme|femme|mann|frau|איש|אישה).*?\]\s*', caseSensitive: false),
    // Remove Hebrew pronouns at the start
    RegExp(r'^(אתה|את)\s+', caseSensitive: false), // Remove "אתה " or "את " at start
  ];
  
  String result = translated;
  for (final pattern in patterns) {
    result = result.replaceFirst(pattern, '');
  }
  
  return result.trim();
}
