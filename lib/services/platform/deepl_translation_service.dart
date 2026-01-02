// lib/services/platform/deepl_translation_service.dart
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../translation_service.dart';
import '../deepl_usage_service.dart';
import '../text_formatter.dart';

// This function is called by translation_service.dart for mobile platform
TranslationService getMobileTranslationService() => DeepLTranslationService();

// Also provide the unified interface for conditional import
TranslationService getPlatformTranslationService() => getMobileTranslationService();

class DeepLTranslationService implements TranslationService {
  static const String _deeplBaseUrl = 'https://api-free.deepl.com/v2';
  static const String _deeplAuthKey = 'DEEPL_API_KEY';

  final DeepLUsageService _usageService = DeepLUsageService();

  String? _getApiKey() {
    // Try dotenv first, then --dart-define
    try {
      final key = dotenv.env[_deeplAuthKey];
      if (key != null && key.isNotEmpty) {
        return key;
      }
    } catch (e) {
      // Ignore dotenv errors
    }
    return const String.fromEnvironment(_deeplAuthKey, defaultValue: '');
  }

  Map<String, String> _getHeaders() {
    final apiKey = _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('DeepL API key not configured. Please set $_deeplAuthKey in .env or --dart-define');
    }
    return {
      'Authorization': 'DeepL-Auth-Key $apiKey',
      'Content-Type': 'application/json',
    };
  }

  bool _hasValidApiKey() {
    final apiKey = _getApiKey();
    return apiKey != null && apiKey.isNotEmpty;
  }

  @override
  Future<String> identifyLanguage(String text) async {
    if (text.trim().isEmpty) return 'und';

    try {
      final response = await http.post(
        Uri.parse('$_deeplBaseUrl/detect'),
        headers: _getHeaders(),
        body: jsonEncode({'text': text}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['detections'] != null && data['detections'].isNotEmpty) {
          return data['detections'][0]['language']?.toString().toLowerCase() ?? 'und';
        }
      }
      return 'und';
    } catch (e) {
      return 'und';
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
  Future<String> translateText(String text, String sourceLang, String targetLang, {String? recipientGender}) async {
    developer.log('DeepLTranslationService: translateText called with text="$text", source="$sourceLang", target="$targetLang", gender="$recipientGender"');

    if (text.trim().isEmpty) {
      developer.log('DeepLTranslationService: Text is empty, returning as-is');
      return text;
    }

    developer.log('DeepLTranslationService: Starting translation process - prioritizing Edge Function for reliability');

    // Try Edge Function first (same as web), fall back to direct API if available
    try {
      developer.log('DeepLTranslationService: Trying Edge Function first');
      final result = await _translateViaEdgeFunction(text, sourceLang, targetLang);
      developer.log('DeepLTranslationService: Edge Function result: "$text" -> "$result"');
      return result;
    } catch (e) {
      developer.log('DeepLTranslationService: Edge Function failed: $e, trying direct API as fallback');

      // Check if API key is configured for direct API fallback
      final hasApiKey = _hasValidApiKey();
      final apiKeyValue = _getApiKey();
      final maskedKey = apiKeyValue != null && apiKeyValue.length > 8
          ? '${apiKeyValue.substring(0, 4)}...${apiKeyValue.substring(apiKeyValue.length - 4)}'
          : 'null';
      developer.log('DeepLTranslationService: Has valid API key: $hasApiKey, key preview: $maskedKey');

      if (!hasApiKey) {
        developer.log('DeepLTranslationService: No valid API key for direct API either, returning original text');
        return text;
      }

      developer.log('DeepLTranslationService: Using direct DeepL API as fallback');

      // Check if we can translate (usage limits)
      final canTranslate = await _usageService.canTranslate(text);
      if (!canTranslate) {
        throw Exception('DeepL usage limit exceeded. Please try again next month or contact support.');
      }

      try {
        developer.log('DeepLTranslationService: Calling DeepL API');

        // For now, don't add gender prefixes to avoid confusing DeepL's language detection
        // We'll handle gender-specific translations differently in the future
        String textToTranslate = text;

        final response = await http.post(
          Uri.parse('$_deeplBaseUrl/translate'),
          headers: _getHeaders(),
          body: jsonEncode({
            'text': [textToTranslate], // DeepL expects an array of strings
            'target_lang': targetLang.toUpperCase(),
            'source_lang': (sourceLang != 'und' && sourceLang.toUpperCase() != 'AUTO') ? sourceLang.toUpperCase() : null,
            'preserve_formatting': true,
          }),
        );

        developer.log('DeepLTranslationService: DeepL API response status: ${response.statusCode}');

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          developer.log('DeepLTranslationService: Direct API response: $data');

          if (data['translations'] != null && data['translations'].isNotEmpty) {
            String translatedText = data['translations'][0]['text'] ?? text;
            developer.log('DeepLTranslationService: Direct API result: "$text" -> "$translatedText"');

            // Apply language-specific formatting
            translatedText = TextFormatter.formatForLanguage(translatedText, targetLang);
            developer.log('DeepLTranslationService: Formatted translated text: "$translatedText"');

            // Record usage for successful translation
            await _usageService.recordUsage(text);

            return translatedText;
          } else {
            developer.log('DeepLTranslationService: No translations in response');
            return text;
          }
        } else {
          developer.log('DeepLTranslationService: Direct API failed: ${response.statusCode} - ${response.body}');
          return text;
        }

      } catch (e) {
        developer.log('DeepLTranslationService: Translation failed: $e');
        // Return original text on error
        return text;
      }
    }
  }

  Future<String> _translateViaEdgeFunction(String text, String sourceLang, String targetLang) async {
    try {
      developer.log('DeepLTranslationService: Trying Edge Function fallback for "$text" ($sourceLang -> $targetLang)');
      // Import supabase here to avoid circular imports
      final supabase = Supabase.instance.client;

      final response = await supabase.functions.invoke(
        'translate-proxy',
        body: {
          'text': text,
          'target_lang': targetLang,
          'source_lang': sourceLang != 'und' ? sourceLang : 'auto',
        },
      );

      developer.log('DeepLTranslationService: Edge Function response: ${response.data}');

      if (response.data != null && response.data['translatedText'] != null) {
        String translated = response.data['translatedText'] as String;
        developer.log('DeepLTranslationService: Edge Function fallback successful: "$text" -> "$translated"');
        return translated;
      } else {
        developer.log('DeepLTranslationService: Edge Function fallback failed: ${response.data}');
        return text;
      }
    } catch (e) {
      developer.log('DeepLTranslationService: Edge Function fallback error: $e');
      return text;
    }
  }

  @override
  void dispose() {
    // No resources to dispose for DeepL service
  }

}
