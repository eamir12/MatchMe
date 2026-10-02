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

  Future<List<Map<String, dynamic>>> fetchGenderOptions() async {
    final payload = await _invoke('gender_options');
    final rows =
        payload['gender_options'] as List<dynamic>? ?? const <dynamic>[];
    return rows
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }
}

final publicReferenceDataService = PublicReferenceDataService.instance;
