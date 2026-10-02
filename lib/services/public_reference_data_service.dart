import 'package:supabase_flutter/supabase_flutter.dart';

class PublicReferenceDataService {
  PublicReferenceDataService._();

  static final PublicReferenceDataService instance =
      PublicReferenceDataService._();

  final SupabaseClient _supabase = Supabase.instance.client;

  Future<Map<String, dynamic>> _invoke(
    String resource, {
    Map<String, dynamic>? params,
  }) async {
    final response = await _supabase.functions.invoke(
      'public-reference-data',
      body: <String, dynamic>{'resource': resource, ...?params},
    );

    if (response.status < 200 || response.status >= 300) {
      throw Exception(
        'public-reference-data failed for $resource: ${response.status}',
      );
    }

    final payload = response.data;
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    throw Exception('Unexpected public-reference-data payload for $resource');
  }

  Future<List<Map<String, dynamic>>> fetchAppConfigRows() async {
    final payload = await _invoke('app_config');
    final rows = payload['config'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchSupportedLanguages() async {
    final payload = await _invoke('supported_languages');
    final rows = payload['languages'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<Map<String, String>> fetchTranslations(String locale) async {
    final payload = await _invoke(
      'translations',
      params: <String, dynamic>{'locale': locale},
    );
    final rows = payload['translations'] as List<dynamic>? ?? const <dynamic>[];
    final translations = <String, String>{};
    for (final item in rows) {
      final row = Map<String, dynamic>.from(item as Map);
      final key = (row['key'] ?? '').toString();
      if (key.isEmpty) continue;
      translations[key] = (row['value'] ?? '').toString();
    }
    return translations;
  }

  Future<String?> fetchTranslationValue(
    String key,
    String locale, {
    String fallbackLocale = 'en',
  }) async {
    final primary = await fetchTranslations(locale);
    final direct = primary[key];
    if (direct != null && direct.isNotEmpty) {
      return direct;
    }

    final normalizedFallback = fallbackLocale.trim().toLowerCase();
    final normalizedLocale = locale.trim().toLowerCase();
    if (normalizedFallback == normalizedLocale) {
      return null;
    }

    final fallback = await fetchTranslations(normalizedFallback);
    final fallbackValue = fallback[key];
    if (fallbackValue != null && fallbackValue.isNotEmpty) {
      return fallbackValue;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> fetchIntents() async {
    final payload = await _invoke('intents');
    final rows = payload['intents'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchInterests() async {
    final payload = await _invoke('interests');
    final rows = payload['interests'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchGenderOptions() async {
    final payload = await _invoke('gender_options');
    final rows =
        payload['gender_options'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> fetchCurrencyRates({
    String baseCurrency = 'USD',
  }) async {
    final payload = await _invoke(
      'currency_rates',
      params: <String, dynamic>{'base_currency': baseCurrency},
    );
    final rows = payload['rates'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }
}

final publicReferenceDataService = PublicReferenceDataService.instance;
