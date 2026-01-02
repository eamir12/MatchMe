// lib/services/translation_service.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter/foundation.dart';

// Import the appropriate service based on platform to avoid DDC conflicts
// This imports the correct platform-specific file and makes its function available
import 'platform/deepl_translation_service.dart' if (dart.library.html) 'platform/web_translation_service.dart';

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
