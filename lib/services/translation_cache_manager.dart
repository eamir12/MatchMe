import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';

/// Manages translation caching and tracks which languages have local translations
class TranslationCacheManager {
  static final _instance = TranslationCacheManager._();
  factory TranslationCacheManager() => _instance;
  TranslationCacheManager._();

  // Preference keys
  static const String _prefixDownloadedLangs = 'translation_downloaded_langs_';

  /// Check if translations for a specific language are cached
  static Future<bool> isLanguageCached(String langCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('translations_$langCode');
      return cached != null && cached.isNotEmpty;
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error checking cache for $langCode: $e',
      );
      return false;
    }
  }

  /// Get list of languages that have been downloaded for a specific match
  /// This provides fast lookup without scanning all messages
  static Future<List<String>> getDownloadedLanguagesForMatch(
    String matchId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefixDownloadedLangs$matchId';
      final jsonStr = prefs.getString(key);

      if (jsonStr == null) return [];

      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return List<String>.from(decoded);
      }
      return [];
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error getting downloaded languages for match $matchId: $e',
      );
      return [];
    }
  }

  /// Mark a language as downloaded for a specific match
  static Future<void> markLanguageDownloadedForMatch(
    String matchId,
    String langCode,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefixDownloadedLangs$matchId';

      // Get existing list
      final existing = await getDownloadedLanguagesForMatch(matchId);

      // Add language if not already there
      if (!existing.contains(langCode)) {
        existing.add(langCode);
        final jsonStr = jsonEncode(existing);
        await prefs.setString(key, jsonStr);
        debugPrint(
          '[TranslationCacheManager] Marked $langCode as downloaded for match $matchId',
        );
      }
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error marking language as downloaded for match $matchId: $e',
      );
    }
  }

  /// Clear downloaded languages tracking for a match (used when clearing translations)
  static Future<void> clearDownloadedLanguagesForMatch(String matchId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefixDownloadedLangs$matchId';
      await prefs.remove(key);
      debugPrint(
        '[TranslationCacheManager] Cleared downloaded languages for match $matchId',
      );
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error clearing downloaded languages for match $matchId: $e',
      );
    }
  }

  /// Check if a specific language has any cached translations available (from local DB)
  /// This checks the local database for messages that have translations in the target language
  /// Returns true if at least one message has a translation cached for this language
  static Future<bool> hasTranslationsForLanguageInMatch(
    String langCode,
    List<Map<String, dynamic>> messages,
  ) async {
    try {
      for (final msg in messages) {
        final translatedText =
            (msg['content_translated'] ?? msg['translated_text']) as String?;
        final translatedLang =
            (msg['translated_target_language'] ?? msg['translated_lang'])
                as String?;

        // Check if this message has a translation for the requested language
        if (translatedText != null &&
            translatedText.isNotEmpty &&
            translatedText != 'null' &&
            translatedLang != null) {
          // Normalize language codes for comparison
          final normalized = translatedLang.trim().toLowerCase();
          if (normalized == langCode.trim().toLowerCase() ||
              (langCode == 'en' && normalized.startsWith('en')) ||
              (langCode == 'es' && normalized.startsWith('es')) ||
              (langCode == 'he' && normalized.startsWith('he'))) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error checking translations for language $langCode: $e',
      );
      return false;
    }
  }

  /// Get list of all languages that have cached translations
  static Future<List<String>> getCachedLanguages() async {
    try {
      // Check for translations for each language we support
      final supported = ['en', 'es', 'he'];
      final cached = <String>[];

      for (final langCode in supported) {
        if (await isLanguageCached(langCode)) {
          cached.add(langCode);
        }
      }

      return cached;
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error getting cached languages: $e',
      );
      return [];
    }
  }

  /// Cache translations for a language
  static Future<void> cacheTranslations({
    required String langCode,
    required Map<String, String> translations,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Convert map to JSON string and cache it
      final jsonString = _mapToJsonString(translations);
      await prefs.setString('translations_$langCode', jsonString);

      // Also cache the list of DB keys for translation tracking
      final dbKeys = translations.keys.toList();
      final keysJson = _listToJsonString(dbKeys);
      await prefs.setString('translations_${langCode}_dbkeys', keysJson);

      debugPrint(
        '[TranslationCacheManager] Cached ${translations.length} translations for $langCode',
      );
    } catch (e) {
      debugPrint(
        '[TranslationCacheManager] Error caching translations for $langCode: $e',
      );
    }
  }

  /// Get all supported languages with their cache status
  static Future<List<Map<String, dynamic>>>
  getSupportedLanguagesWithCacheStatus() async {
    final supported = <Map<String, dynamic>>[
      {'code': 'en', 'display': 'English'},
      {'code': 'es', 'display': 'Español'},
      {'code': 'he', 'display': 'עברית'},
    ];

    try {
      for (final lang in supported) {
        final isCached = await isLanguageCached(lang['code']! as String);
        lang['cached'] = isCached;
      }
    } catch (e) {
      debugPrint('[TranslationCacheManager] Error checking cache status: $e');
      // Mark all as cached so app still works
      for (final lang in supported) {
        lang['cached'] = true;
      }
    }

    return supported;
  }

  /// Helper: Convert map to JSON string
  static String _mapToJsonString(Map<String, String> map) {
    // Simple JSON encoding
    final entries = <String>[];
    for (final entry in map.entries) {
      final key = entry.key.replaceAll('"', '\\"').replaceAll('\n', '\\n');
      final value = entry.value.replaceAll('"', '\\"').replaceAll('\n', '\\n');
      entries.add('"$key":"$value"');
    }
    return '{${entries.join(",")}}';
  }

  /// Helper: Convert list to JSON string
  static String _listToJsonString(List<String> list) {
    final escaped = list.map((e) => '"${e.replaceAll('"', '\\"')}"').toList();
    return '[${escaped.join(",")}]';
  }
}
