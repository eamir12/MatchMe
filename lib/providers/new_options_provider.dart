// lib/providers/new_options_provider.dart
// [FIXED] Corrected typo in 'dart:convert' import.
// [RESTORED] Restored try/catch block in allIntentsProvider.
// [ADDED] Added nonSharedInterestCategoriesProvider.

import 'dart:convert'; // Import for jsonDecode
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

// --- MODELS ---

class AppIntent {
  final int id;
  final String key;
  final String translationKey;
  final int? parentId;
  final int sortOrder;
  final bool isSocial;
  final bool isBusiness;

  AppIntent({
    required this.id,
    required this.key,
    required this.translationKey,
    this.parentId,
    required this.sortOrder,
    this.isSocial = false,
    this.isBusiness = false,
  });

  factory AppIntent.fromMap(Map<String, dynamic> map) {
    int coerceToInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      try {
        return int.parse(v.toString());
      } catch (_) {
        return 0;
      }
    }
    int? coerceToNullableInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      try {
        return int.parse(v.toString());
      } catch (_) {
        return null;
      }
    }
    bool coerceToBool(dynamic v) {
      if (v == null) return false;
      if (v is bool) return v;
      if (v is int) return v == 1;
      if (v is String) return v.toLowerCase() == 'yes' || v == '1' || v == 'true';
      return false;
    }
    return AppIntent(
      id: coerceToInt(map['id']),
      key: (map['key'] ?? '').toString(),
      translationKey: (map['translation_key'] ?? '').toString(),
      parentId: coerceToNullableInt(map['parent_id']),
      sortOrder: coerceToInt(map['sort_order']),
      isSocial: coerceToBool(map['is_social']),
      isBusiness: coerceToBool(map['is_business']),
    );
  }
}

class AppInterest {
  final int id;
  final String key;
  final String translationKey;
  final int? parentId;
  final int sortOrder;
  final bool isSocial;
  final bool isBusiness;

  AppInterest({
    required this.id,
    required this.key,
    required this.translationKey,
    this.parentId,
    required this.sortOrder,
    required this.isSocial,
    required this.isBusiness,
  });

  factory AppInterest.fromMap(Map<String, dynamic> map) {
    int? coerceToNullableInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      try {
        return int.parse(v.toString());
      } catch (_) {
        return null;
      }
    }
    int coerceToInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      try {
        return int.parse(v.toString());
      } catch (_) {
        return 0;
      }
    }
    bool coerceToBool(dynamic v) {
      if (v == null) return false;
      if (v is bool) return v;
      if (v is int) return v == 1;
      if (v is String) return v.toLowerCase() == 'yes' || v == '1' || v == 'true';
      return false;
    }
    return AppInterest(
      id: coerceToInt(map['id']),
      key: (map['key'] ?? '').toString(),
      translationKey: (map['translation_key'] ?? '').toString(),
      parentId: coerceToNullableInt(map['parent_id']),
      sortOrder: coerceToInt(map['sort_order']),
      isSocial: coerceToBool(map['is_social']),
      isBusiness: coerceToBool(map['is_business']),
    );
  }
}

// --- BASE PROVIDERS ---

/// Fetches ALL rows from the `intents` table (both main and sub-intents).
final allIntentsProvider = FutureProvider<List<AppIntent>>((ref) async {
  try {
    final data = await supabase
        .from('intents')
        .select('id, key, translation_key, parent_id, sort_order, is_social, is_business')
        .order('sort_order', ascending: true);
    try {
      final list = data.map((item) => AppIntent.fromMap(item)).toList();
      return list;
    } catch (e) {
      return [];
    }
  } catch (e) {
    return [];
  }
});

/// Fetches ALL rows from the `interests` table (categories, items, and drilldowns).
final allInterestsProvider = FutureProvider<List<AppInterest>>((ref) async {
  try {
    final data = await supabase
        .from('interests')
        .select('id, key, translation_key, parent_id, sort_order, is_social, is_business')
        .order('sort_order', ascending: true);
    try {
      final list = data.map((item) => AppInterest.fromMap(item)).toList();
      // intent_interests mapping removed from data model; no longer fetched

      // If mapping exists, skip metadata enrichment (metadata removed)
      if (list.isNotEmpty) {
        // No longer enrich from interest_categories; all metadata should be in 'interests' table now.
        return list;
      }

      // Fallback: some projects use separate tables `interest_categories` and `interest_items`.
      // If `interests` returned nothing, try to read those tables and map into AppInterest objects.
      try {
        final cats = await supabase
            .from('interest_categories')
            .select('id, category_key, category_display_key, category_sort_order, metadata')
            .order('category_sort_order', ascending: true);

        final items = await supabase
            .from('interest_items')
            .select('id, interest_key, interest_display_key, interest_sort_order, category_key, metadata')
            .order('interest_sort_order', ascending: true);

        final catList = (cats as List<dynamic>).map((c) => Map<String, dynamic>.from(c as Map)).toList();
        final itemList = (items as List<dynamic>).map((i) => Map<String, dynamic>.from(i as Map)).toList();

        // Build a map from category_key -> category id
        final Map<String, dynamic> catByKey = {for (var c in catList) c['category_key'].toString(): c};

        final List<AppInterest> fallback = [];

        // Map categories to AppInterest entries
        for (var c in catList) {
          // Parse metadata whether it's returned as a Map or a JSON string
          Map<String, dynamic> parsedMeta = {};
          try {
            if (c['metadata'] is Map) {
              parsedMeta = Map<String, dynamic>.from(c['metadata'] as Map);
            } else if (c['metadata'] is String && (c['metadata'] as String).isNotEmpty) {
              try {
                final decoded = jsonDecode(c['metadata'] as String);
                if (decoded is Map) parsedMeta = Map<String, dynamic>.from(decoded);
              } catch (_) {
                parsedMeta = {};
              }
            }
          } catch (_) {
            parsedMeta = {};
          }

          // Ensure we preserve the is_social flag in metadata for UI filtering
          if (!parsedMeta.containsKey('is_social')) parsedMeta['is_social'] = c['is_social'] ?? false;

          final mapped = {
            'id': c['id'],
            'key': c['category_key'],
            'translation_key': c['category_display_key'] ?? c['category_key'],
            'parent_id': null,
            'sort_order': c['category_sort_order'] ?? 0,
            'is_social': parsedMeta['is_social'] ?? false,
            'is_business': parsedMeta['is_business'] ?? false,
            'metadata': parsedMeta,
          };

          fallback.add(AppInterest.fromMap(mapped));
        }

        // Map items and attach parent_id from category id when possible
        for (var it in itemList) {
          final catKey = it['category_key']?.toString();
          final parent = catByKey[catKey];
          final parentId = parent != null ? parent['id'] : null;
          final mapped = {
            'id': it['id'],
            'key': it['interest_key'],
            'translation_key': it['interest_display_key'] ?? it['interest_key'],
            'parent_id': parentId,
            'sort_order': it['interest_sort_order'] ?? 0,
            'is_social': false, // default
            'is_business': false, // default
            'metadata': it['metadata'] ?? {},
          };
          fallback.add(AppInterest.fromMap(mapped));
        }

        return fallback;
      } catch (e) {
        return list; // empty
      }
    } catch (e) {
      return [];
    }
  } catch (e) {
    return [];
  }
});


/// Fetches gender options.
final genderOptionsProvider = FutureProvider<List<Map<String, String>>>((ref) async {
  try {
    final data = await supabase
        .from('app_gender_options')
        .select('gender_key, display_name_key')
        .order('sort_order');
    return (data as List<dynamic>)
        .map((item) => {
          'key': (item['gender_key'] ?? '').toString().trim().toLowerCase(),
          'displayKey': (item['display_name_key'] ?? '').toString(),
        })
        .toList();
  } catch (_) {
    return [];
  }
});

/// Provides top-level interest categories for a specific intent key (robust to missing numeric IDs).
final nonSharedInterestCategoriesByKeyProvider = Provider.family<List<AppInterest>, String>((ref, intentKey) {
  if (intentKey.trim().isEmpty) return [];
  final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
  final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];

  final intent = allIntents.firstWhere(
    (i) => i.key.trim().toLowerCase() == intentKey.trim().toLowerCase(),
    orElse: () => AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
  );

  if (intent.id == 0) return [];

  final matched = allInterests.where((interest) {
    return (interest.parentId == null || interest.parentId == 0) &&
           ((intent.isSocial && interest.isSocial) || (intent.isBusiness && interest.isBusiness));
  }).toList();
  return matched;
});

// --- LOOKUP MAP PROVIDERS ---

/// Provides a Map to get a display key from an interest key.
final interestDisplayMapProvider = Provider<Map<String, String>>((ref) {
  final interests = ref.watch(allInterestsProvider).asData?.value ?? [];
  return {for (var item in interests) item.key: item.translationKey};
});

/// Provides a Map to get a display key from a category key.
final categoryDisplayMapProvider = Provider<Map<String, String>>((ref) {
  final categories = ref.watch(allInterestsProvider).asData?.value
      .where((i) => i.parentId == null || i.parentId == 0)
      .toList() ?? [];
  return {for (var item in categories) item.id.toString(): item.translationKey};
});
