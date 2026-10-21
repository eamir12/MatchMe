// lib/providers/new_options_provider.dart
// [FIXED] Corrected typo in 'dart:convert' import.
// [RESTORED] Restored try/catch block in allIntentsProvider.
// [ADDED] Added nonSharedInterestCategoriesProvider.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/auth_provider.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

/// In-memory freshness for reference data (memory layer).
/// Local storage (Hive) survives restarts; these timestamps prevent a
/// cache-first provider from re-fetching on every rebuild (which would loop
/// via invalidateSelf). Reference data changes rarely: 1h freshness.
final Map<String, DateTime> _optionsMemoryFetchedAt = <String, DateTime>{};
const Duration _optionsMemoryFreshFor = Duration(hours: 1);

bool _isOptionsMemoryFresh(String key) {
  final at = _optionsMemoryFetchedAt[key];
  if (at == null) return false;
  return DateTime.now().difference(at) < _optionsMemoryFreshFor;
}

void _markOptionsMemoryFresh(String key) {
  _optionsMemoryFetchedAt[key] = DateTime.now();
}

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
      if (v is String) {
        return v.toLowerCase() == 'yes' || v == '1' || v == 'true';
      }
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
      if (v is String) {
        return v.toLowerCase() == 'yes' || v == '1' || v == 'true';
      }
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
/// Cache-first (memory + Hive): returns local cache instantly on UI startup,
/// refreshes from Supabase in background.
final allIntentsProvider = FutureProvider<List<AppIntent>>((ref) async {
  final localDb = ref.read(localDbProvider);

  List<AppIntent> fromMaps(List<Map<String, dynamic>> maps) {
    final list = <AppIntent>[];
    for (final item in maps) {
      try {
        list.add(AppIntent.fromMap(item));
      } catch (_) {}
    }
    return list;
  }

  Future<void> refreshInBackground() async {
    if (shouldSkipSupabaseCalls()) return;
    if (_isOptionsMemoryFresh('intents')) return;
    try {
      final data = await publicReferenceDataService.fetchIntents();
      final normalized = (data as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (normalized.isEmpty) return;
      final fresh = fromMaps(normalized);
      if (fresh.isEmpty) return;
      await localDb.saveCachedAppIntents(normalized);
      _markOptionsMemoryFresh('intents');
      // Fresh data saved to both layers; rebuild once so UI shows it.
      // Guarded by _isOptionsMemoryFresh above, so no invalidate loop.
      try {
        ref.invalidateSelf();
      } catch (_) {}
    } catch (_) {}
  }

  // 1) Local storage first — instant.
  try {
    final cached = await localDb.getCachedAppIntents();
    if (cached.isNotEmpty) {
      final list = fromMaps(cached);
      if (list.isNotEmpty) {
        if (!_isOptionsMemoryFresh('intents')) {
          unawaited(refreshInBackground());
        }
        return list;
      }
    }
  } catch (_) {}

  // 2) No cache: must fetch (first run), then save to BOTH layers.
  try {
    final data = await publicReferenceDataService.fetchIntents();
    try {
      final normalized = (data as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (normalized.isNotEmpty) {
        await localDb.saveCachedAppIntents(normalized);
      }
      _markOptionsMemoryFresh('intents');
      final list = <AppIntent>[];
      for (final item in normalized) {
        list.add(AppIntent.fromMap(item));
      }
      return list;
    } catch (_) {
      final cached = await localDb.getCachedAppIntents();
      final list = <AppIntent>[];
      for (final item in cached) {
        list.add(AppIntent.fromMap(item));
      }
      return list;
    }
  } catch (_) {
    final cached = await localDb.getCachedAppIntents();
    final list = <AppIntent>[];
    for (final item in cached) {
      list.add(AppIntent.fromMap(item));
    }
    return list;
  }
});

/// Fetches ALL rows from the `interests` table (categories, items, and drilldowns).
/// Cache-first (memory + Hive): returns local cache instantly on UI startup.
final allInterestsProvider = FutureProvider<List<AppInterest>>((ref) async {
  final localDb = ref.read(localDbProvider);

  List<AppInterest> fromMaps(List<Map<String, dynamic>> maps) {
    final result = <AppInterest>[];
    for (final item in maps) {
      try {
        result.add(AppInterest.fromMap(item));
      } catch (_) {}
    }
    return result;
  }

  Future<void> refreshInBackground() async {
    if (shouldSkipSupabaseCalls()) return;
    if (_isOptionsMemoryFresh('interests')) return;
    try {
      final data = await publicReferenceDataService.fetchInterests();
      final normalized = (data as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (normalized.isEmpty) return;
      await localDb.saveCachedAppInterests(normalized);
      _markOptionsMemoryFresh('interests');
      try {
        ref.invalidateSelf();
      } catch (_) {}
    } catch (_) {}
  }

  // 1) Local storage first — instant.
  try {
    final cached = await localDb.getCachedAppInterests();
    if (cached.isNotEmpty) {
      final list = fromMaps(cached);
      if (list.isNotEmpty) {
        if (!_isOptionsMemoryFresh('interests')) {
          unawaited(refreshInBackground());
        }
        return list;
      }
    }
  } catch (_) {}
  try {
    final data = await publicReferenceDataService.fetchInterests();
    try {
      final normalized = (data as List<dynamic>)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      if (normalized.isNotEmpty) {
        await localDb.saveCachedAppInterests(normalized);
      }
      _markOptionsMemoryFresh('interests');
      final list = <AppInterest>[];
      for (final item in normalized) {
        list.add(AppInterest.fromMap(item));
      }
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
            .select(
              'id, category_key, category_display_key, category_sort_order, metadata',
            )
            .order('category_sort_order', ascending: true);

        final items = await supabase
            .from('interest_items')
            .select(
              'id, interest_key, interest_display_key, interest_sort_order, category_key, metadata',
            )
            .order('interest_sort_order', ascending: true);

        final catList = <Map<String, dynamic>>[];
        for (final c in cats as List<dynamic>) {
          catList.add(Map<String, dynamic>.from(c as Map));
        }
        final itemList = <Map<String, dynamic>>[];
        for (final i in items as List<dynamic>) {
          itemList.add(Map<String, dynamic>.from(i as Map));
        }

        // Build a map from category_key -> category id
        final Map<String, dynamic> catByKey = {
          for (var c in catList) c['category_key'].toString(): c,
        };

        final List<AppInterest> fallback = [];

        // Map categories to AppInterest entries
        for (var c in catList) {
          // Parse metadata whether it's returned as a Map or a JSON string
          Map<String, dynamic> parsedMeta = {};
          try {
            if (c['metadata'] is Map) {
              parsedMeta = Map<String, dynamic>.from(c['metadata'] as Map);
            } else if (c['metadata'] is String &&
                (c['metadata'] as String).isNotEmpty) {
              try {
                final decoded = jsonDecode(c['metadata'] as String);
                if (decoded is Map) {
                  parsedMeta = Map<String, dynamic>.from(decoded);
                }
              } catch (_) {
                parsedMeta = {};
              }
            }
          } catch (_) {
            parsedMeta = {};
          }

          // Ensure we preserve the is_social flag in metadata for UI filtering
          if (!parsedMeta.containsKey('is_social')) {
            parsedMeta['is_social'] = c['is_social'] ?? false;
          }

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
        final cached = await localDb.getCachedAppInterests();
        final result = <AppInterest>[];
        if (cached.isNotEmpty) {
          for (final item in cached) {
            result.add(AppInterest.fromMap(item));
          }
          return result;
        }
        return list;
      }
    } catch (e) {
      final cached = await localDb.getCachedAppInterests();
      final result = <AppInterest>[];
      for (final item in cached) {
        result.add(AppInterest.fromMap(item));
      }
      return result;
    }
  } catch (e) {
    final cached = await localDb.getCachedAppInterests();
    final result = <AppInterest>[];
    for (final item in cached) {
      result.add(AppInterest.fromMap(item));
    }
    return result;
  }
});

/// Fetches gender options.
/// Cache-first (memory + Hive): returns local cache instantly on UI startup.
final genderOptionsProvider = FutureProvider<List<Map<String, String>>>((
  ref,
) async {
  final localDb = ref.read(localDbProvider);

  Future<void> refreshInBackground() async {
    if (shouldSkipSupabaseCalls()) return;
    if (_isOptionsMemoryFresh('gender')) return;
    try {
      final data = await publicReferenceDataService.fetchGenderOptions();
      final normalized = (data as List<dynamic>)
          .map(
            (item) => {
              'key': (item['gender_key'] ?? '').toString().trim().toLowerCase(),
              'displayKey': (item['display_name_key'] ?? '').toString(),
            },
          )
          .toList();
      if (normalized.isEmpty) return;
      await localDb.saveCachedGenderOptions(normalized);
      _markOptionsMemoryFresh('gender');
      try {
        ref.invalidateSelf();
      } catch (_) {}
    } catch (_) {}
  }

  // 1) Local storage first — instant.
  try {
    final cached = await localDb.getCachedGenderOptions();
    if (cached.isNotEmpty) {
      if (!_isOptionsMemoryFresh('gender')) {
        unawaited(refreshInBackground());
      }
      return cached;
    }
  } catch (_) {}

  // 2) No cache: fetch, then save to BOTH layers.
  try {
    final data = await publicReferenceDataService.fetchGenderOptions();
    final normalized = (data as List<dynamic>)
        .map(
          (item) => {
            'key': (item['gender_key'] ?? '').toString().trim().toLowerCase(),
            'displayKey': (item['display_name_key'] ?? '').toString(),
          },
        )
        .toList();
    if (normalized.isNotEmpty) {
      await localDb.saveCachedGenderOptions(normalized);
    }
    _markOptionsMemoryFresh('gender');
    return normalized;
  } catch (_) {
    return await localDb.getCachedGenderOptions();
  }
});

/// Provides top-level interest categories for a specific intent key (robust to missing numeric IDs).
final nonSharedInterestCategoriesByKeyProvider =
    Provider.family<List<AppInterest>, String>((ref, intentKey) {
      if (intentKey.trim().isEmpty) return [];
      final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
      final allIntents = ref.watch(allIntentsProvider).asData?.value ?? [];

      final intent = allIntents.firstWhere(
        (i) => i.key.trim().toLowerCase() == intentKey.trim().toLowerCase(),
        orElse: () =>
            AppIntent(id: 0, key: '', translationKey: '', sortOrder: 0),
      );

      if (intent.id == 0) return [];

      final matched = allInterests.where((interest) {
        return (interest.parentId == null || interest.parentId == 0) &&
            ((intent.isSocial && interest.isSocial) ||
                (intent.isBusiness && interest.isBusiness));
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
  final categories =
      ref
          .watch(allInterestsProvider)
          .asData
          ?.value
          .where((i) => i.parentId == null || i.parentId == 0)
          .toList() ??
      [];
  return {for (var item in categories) item.key: item.translationKey};
});

/// --- APP PROFILE OPTIONS (dynamic lifestyle/family/religion/education) -----

class AppProfileOption {
  final String fieldKey;
  final String optionKey;
  final String? profileValue;
  final String? filterValue;
  final String profileDisplayKey;
  final String filterDisplayKey;
  final int profileSortOrder;
  final int filterSortOrder;

  AppProfileOption({
    required this.fieldKey,
    required this.optionKey,
    this.profileValue,
    this.filterValue,
    this.profileDisplayKey = '',
    this.filterDisplayKey = '',
    this.profileSortOrder = 0,
    this.filterSortOrder = 0,
  });

  factory AppProfileOption.fromMap(Map<String, dynamic> map) {
    return AppProfileOption(
      fieldKey: map['field_key']?.toString() ?? '',
      optionKey: map['option_key']?.toString() ?? '',
      profileValue: map['profile_value']?.toString(),
      filterValue: map['filter_value']?.toString(),
      profileDisplayKey: map['profile_display_key']?.toString() ?? '',
      filterDisplayKey: map['filter_display_key']?.toString() ?? '',
      profileSortOrder: (map['profile_sort_order'] as int?) ?? 0,
      filterSortOrder: (map['filter_sort_order'] as int?) ?? 0,
    );
  }
}

/// Practice frequency options, ordered from least often to most often.
const List<String> kPracticeFrequencyOrder = <String>[
  'rarely_or_never',
  'few_times_a_year',
  'monthly',
  'weekly',
  'daily',
];

/// The belief fields whose options are ordered by [orderBeliefOptions].
bool isBeliefFieldKey(String fieldKey) =>
    fieldKey == 'religion' ||
    fieldKey == 'denomination' ||
    fieldKey == 'practice';

/// Orders the options of a belief field so the list always reads the same way,
/// in the profile wizard and in the religion filter screens alike:
///  * the catch-all "Other" option is always last, because it is the choice
///    for people who do not want any of the options listed above it;
///  * the practice frequency runs from least often to most often.
List<AppProfileOption> orderBeliefOptions(
  List<AppProfileOption> options, {
  required String fieldKey,
}) {
  if (!isBeliefFieldKey(fieldKey)) return options;

  final decorated = <(int, AppProfileOption)>[
    for (var i = 0; i < options.length; i++) (i, options[i]),
  ];
  decorated.sort((a, b) {
    if (fieldKey == 'practice') {
      final byFrequency = _comparePracticeFrequency(a.$2, b.$2);
      if (byFrequency != 0) return byFrequency;
    }
    final bySortOrder = a.$2.profileSortOrder.compareTo(b.$2.profileSortOrder);
    return bySortOrder != 0 ? bySortOrder : a.$1.compareTo(b.$1);
  });

  final regular = <AppProfileOption>[];
  final catchAll = <AppProfileOption>[];
  for (final entry in decorated) {
    (_isCatchAllOption(entry.$2) ? catchAll : regular).add(entry.$2);
  }
  return [...regular, ...catchAll];
}

/// "Other" is the catch-all option of a field (e.g. `other` for religion,
/// `christianity__other` for a denomination).
bool _isCatchAllOption(AppProfileOption option) {
  final key = option.optionKey.toLowerCase();
  if (key == 'other' || key.endsWith('__other')) return true;
  return option.profileDisplayKey.toLowerCase().endsWith('other');
}

/// Compares two practice options on the "least often → most often" scale.
/// Options that are not part of the known scale are listed after it.
int _comparePracticeFrequency(AppProfileOption a, AppProfileOption b) {
  final aIndex = _practiceFrequencyIndex(a);
  final bIndex = _practiceFrequencyIndex(b);
  if (aIndex < 0 && bIndex < 0) return 0;
  if (aIndex < 0) return 1;
  if (bIndex < 0) return -1;
  return aIndex.compareTo(bIndex);
}

int _practiceFrequencyIndex(AppProfileOption option) {
  final index = kPracticeFrequencyOrder.indexOf(option.optionKey.toLowerCase());
  if (index >= 0) return index;
  return kPracticeFrequencyOrder.indexOf(
    (option.profileValue ?? '').toLowerCase(),
  );
}

/// All profile option rows, fetched from app_profile_options table.
/// Cache-first (memory + Hive): returns local cache instantly on UI startup,
/// refreshes from Supabase in background.
final profileOptionsProvider = FutureProvider<List<AppProfileOption>>((
  ref,
) async {
  final localDb = ref.read(localDbProvider);

  List<AppProfileOption> fromMaps(List<Map<String, dynamic>> maps) {
    final out = <AppProfileOption>[];
    for (final row in maps) {
      try {
        out.add(AppProfileOption.fromMap(row));
      } catch (_) {}
    }
    return out;
  }

  Map<String, dynamic> toMap(AppProfileOption o) => <String, dynamic>{
    'field_key': o.fieldKey,
    'option_key': o.optionKey,
    'profile_value': o.profileValue,
    'filter_value': o.filterValue,
    'profile_display_key': o.profileDisplayKey,
    'filter_display_key': o.filterDisplayKey,
    'profile_sort_order': o.profileSortOrder,
    'filter_sort_order': o.filterSortOrder,
  };

  Future<void> refreshInBackground() async {
    if (shouldSkipSupabaseCalls()) return;
    if (_isOptionsMemoryFresh('profileOptions')) return;
    try {
      final data = await supabase
          .from('app_profile_options')
          .select('*')
          .eq('is_active', true)
          .order('field_key')
          .order('profile_sort_order');
      final list = (data as List<dynamic>)
          .map((row) => AppProfileOption.fromMap(row as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) return;
      await localDb.saveCachedProfileOptions(list.map(toMap).toList());
      _markOptionsMemoryFresh('profileOptions');
      try {
        ref.invalidateSelf();
      } catch (_) {}
    } catch (e) {
      developer.log(
        'profileOptionsProvider bg refresh: $e',
        name: 'ProfileOptions',
      );
    }
  }

  // 1) Local storage first — instant.
  try {
    final cached = await localDb.getCachedProfileOptions();
    if (cached.isNotEmpty) {
      final list = fromMaps(cached);
      if (list.isNotEmpty) {
        if (!_isOptionsMemoryFresh('profileOptions')) {
          unawaited(refreshInBackground());
        }
        return list;
      }
    }
  } catch (_) {}

  // 2) No cache: fetch, then save to BOTH layers.
  try {
    final data = await supabase
        .from('app_profile_options')
        .select('*')
        .eq('is_active', true)
        .order('field_key')
        .order('profile_sort_order');
    final list = (data as List<dynamic>)
        .map((row) => AppProfileOption.fromMap(row as Map<String, dynamic>))
        .toList();
    if (list.isNotEmpty) {
      try {
        await localDb.saveCachedProfileOptions(list.map(toMap).toList());
      } catch (_) {}
    }
    _markOptionsMemoryFresh('profileOptions');
    return list;
  } catch (e) {
    developer.log('profileOptionsProvider error: $e', name: 'ProfileOptions');
    try {
      final cached = await localDb.getCachedProfileOptions();
      return fromMaps(cached);
    } catch (_) {
      return [];
    }
  }
});

/// Options for a specific field, filtered by context ('profile' or 'filter').
final fieldOptionsProvider =
    FutureProvider.family<
      List<AppProfileOption>,
      ({String fieldKey, String context})
    >((ref, params) async {
      final all = await ref.watch(profileOptionsProvider.future);
      var filtered = all.where((o) => o.fieldKey == params.fieldKey);
      if (params.context == 'profile') {
        filtered = filtered.where((o) => o.profileValue != null);
      } else if (params.context == 'filter') {
        filtered = filtered.where(
          (o) => o.filterValue != null && o.filterDisplayKey.isNotEmpty,
        );
      }
      return filtered.toList();
    });

/// Lookup: given a field_key and filter_value, return all matching profile_values
final profileValuesForFilterProvider =
    Provider.family<List<String>, ({String fieldKey, String filterValue})>((
      ref,
      params,
    ) {
      final all = ref.watch(profileOptionsProvider).asData?.value ?? [];
      return all
          .where(
            (o) =>
                o.fieldKey == params.fieldKey &&
                o.filterValue == params.filterValue &&
                o.profileValue != null,
          )
          .map((o) => o.profileValue!)
          .toList();
    });

// --- REALTIME PROVIDERS ----------------------------------------------------
/// Watch intents/interests tables and invalidate the source providers so admin
/// changes (new options, renames) propagate instantly.

final intentsRealtimeProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  final hasSession = ref.watch(
    authStateProvider.select((auth) => auth.asData?.value.session != null),
  );
  if (!hasSession) {
    return const Stream.empty();
  }
  return supabase
      .from('intents')
      .stream(primaryKey: const ['id'])
      .map((rows) {
        developer.log(
          'Intents table changed, invalidating allIntentsProvider',
          name: 'IntentsRealtime',
        );
        ref.invalidate(allIntentsProvider);
        return rows;
      })
      .handleError((e) {
        developer.log(
          'intentsRealtimeProvider error: $e',
          name: 'IntentsRealtime',
        );
      });
});

final profileOptionsRealtimeProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  final hasSession = ref.watch(
    authStateProvider.select((auth) => auth.asData?.value.session != null),
  );
  if (!hasSession) {
    return const Stream.empty();
  }
  return supabase
      .from('app_profile_options')
      .stream(primaryKey: const ['id'])
      .map((rows) {
        developer.log(
          'app_profile_options table changed, invalidating profileOptionsProvider',
          name: 'ProfileOptionsRealtime',
        );
        ref.invalidate(profileOptionsProvider);
        return rows;
      })
      .handleError((e) {
        developer.log(
          'profileOptionsRealtimeProvider error: $e',
          name: 'ProfileOptionsRealtime',
        );
      });
});

final interestsRealtimeProvider = StreamProvider<List<Map<String, dynamic>>>((
  ref,
) {
  final hasSession = ref.watch(
    authStateProvider.select((auth) => auth.asData?.value.session != null),
  );
  if (!hasSession) {
    return const Stream.empty();
  }
  return supabase
      .from('interests')
      .stream(primaryKey: const ['id'])
      .map((rows) {
        developer.log(
          'Interests table changed, invalidating allInterestsProvider',
          name: 'InterestsRealtime',
        );
        ref.invalidate(allInterestsProvider);
        return rows;
      })
      .handleError((e) {
        developer.log(
          'interestsRealtimeProvider error: $e',
          name: 'InterestsRealtime',
        );
      });
});
