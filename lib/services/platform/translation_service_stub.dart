// lib/services/platform/translation_service_stub.dart
//
// This is a stub implementation used when conditional imports fail
// It should never actually be used in practice

import '../translation_service.dart';

// This function is called by translation_service.dart when conditional imports fail
TranslationService getPlatformTranslationService() {
  throw UnsupportedError('No platform-specific translation service available');
}
