// lib/providers/profile_provider.dart
// Full provider implementation with robust syncProfile which tolerates missing columns
// on the users table by retrying the select after removing reported missing columns.
// Also ensures local cache is updated immediately after user photos changes so UI changes
// are not reverted by subsequent background syncs. Evicts signed-url cache when appropriate.

import 'dart:async';
import 'dart:convert';


import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/profile_request_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/utils/resume_diagnostics.dart';

part 'profile_provider.g.dart';

final supabase = Supabase.instance.client;

/// Helper: convert many incoming shapes into List&lt;String&gt;
List<String> _toStringList(dynamic value) {
  if (value == null) return <String>[];
  if (value is List) {
    return value.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty && s != '0').toList();
  }
  if (value is Iterable) {
    return value.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty && s != '0').toList();
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty && s != '0').toList();
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
    return [value].where((s) => s.isNotEmpty && s != '0').toList();
  }
  try {
    final decoded = jsonDecode(value.toString());
    if (decoded is List) {
      return decoded.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty && s != '0').toList();
    }
  } catch (_) {
    // Ignore JSON parsing errors
  }
  return <String>[];
}

/// Helper: convert many incoming shapes into `List<double>`
List<double> _toDoubleList(dynamic value) {
  if (value == null) return <double>[];
  if (value is List) {
    return value.map((e) {
      if (e is num) return e.toDouble();
      if (e is String) return double.tryParse(e) ?? 0.0;
      return 0.0;
    }).toList();
  }
  if (value is Iterable) {
    return value.map((e) {
      if (e is num) return e.toDouble();
      if (e is String) return double.tryParse(e) ?? 0.0;
      return 0.0;
    }).toList();
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded.map((e) {
          if (e is num) return e.toDouble();
          if (e is String) return double.tryParse(e) ?? 0.0;
          return 0.0;
        }).toList();
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
  }
  try {
    final decoded = jsonDecode(value.toString());
    if (decoded is List) {
      return decoded.map((e) {
        if (e is num) return e.toDouble();
        if (e is String) return double.tryParse(e) ?? 0.0;
        return 0.0;
      }).toList();
    }
  } catch (_) {
    // Ignore JSON parsing errors
  }
  return <double>[];
}

/// Helper: ensure map of list of strings
Map<String, List<String>> _mapOfLists(dynamic value) {
  if (value == null) return <String, List<String>>{};
  if (value is Map<String, dynamic>) {
    final Map<String, List<String>> out = {};
    value.forEach((k, v) {
      if (k != '0' && k.isNotEmpty) {
        out[k] = _toStringList(v);
      }
    });
    return out;
  }
  if (value is Map) {
    final Map<String, List<String>> out = {};
    value.forEach((k, v) {
      final keyStr = k.toString();
      if (keyStr != '0' && keyStr.isNotEmpty) {
        out[keyStr] = _toStringList(v);
      }
    });
    return out;
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final Map<String, List<String>> out = {};
        decoded.forEach((k, v) {
          final keyStr = k.toString();
          if (keyStr != '0' && keyStr.isNotEmpty) {
            out[keyStr] = _toStringList(v);
          }
        });
        return out;
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
  }
  return <String, List<String>>{};
}

/// Helper: ensure map of list of doubles
Map<String, List<double>> _mapOfDoubleLists(dynamic value) {
  if (value == null) return <String, List<double>>{};
  if (value is Map<String, dynamic>) {
    final Map<String, List<double>> out = {};
    value.forEach((k, v) {
      if (k != '0' && k.isNotEmpty) {
        out[k] = _toDoubleList(v);
      }
    });
    return out;
  }
  if (value is Map) {
    final Map<String, List<double>> out = {};
    value.forEach((k, v) {
      final keyStr = k.toString();
      if (keyStr != '0' && keyStr.isNotEmpty) {
        out[keyStr] = _toDoubleList(v);
      }
    });
    return out;
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        final Map<String, List<double>> out = {};
        decoded.forEach((k, v) {
          final keyStr = k.toString();
          if (keyStr != '0' && keyStr.isNotEmpty) {
            out[keyStr] = _toDoubleList(v);
          }
        });
        return out;
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
  }
  return <String, List<double>>{};
}

String _normalizeKey(String? value) => (value ?? '').trim().toLowerCase();

/// Mask full names to First L. to avoid storing full last names
String maskName(String? fullName) {
  if (fullName == null || fullName.trim().isEmpty) return 'Unknown User';
  final parts = fullName.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return 'Unknown User';
  final first = parts.first;
  String suffix = '';
  if (parts.length > 1) {
    final last = parts.last;
    if (last.isNotEmpty && last != first) {
      suffix = ' ${last.substring(0,1)}.';
    }
  }
  return '$first$suffix';
}

/// ---------------------------------------------------------------------------
/// UserProfile model
/// ---------------------------------------------------------------------------
class UserProfile {
  final String id;
  final String name;
  final String? firstName;
  final String? lastName;
  final DateTime? dateOfBirth;
  final String? gender;
  final String preferredLanguage;
  final List<String> activeModes;
  final Map<String, List<String>> subIntents;
  final Map<String, List<String>> interests;
  final Map<String, List<String>> languagesKnown;
  final String subscriptionTier;
  final bool isProfileComplete;
  final int matchRadiusDefault;
  final int gpsIntervalDefault;
  final bool smartGpsThrottlingEnabled;
  final bool sharedEventMatchingEnabled;
  final bool sharedMovementMatchingEnabled;
  final List<String> editableProfileFields;

  // Gender and Age Preferences
  final Map<String, List<String>> genderPreferences; // intent key -> list of preferred gender keys
  final Map<String, List<double>> agePreferences; // intent key -> [min_age, max_age]
  final bool strictGenderAgeEnforcement;

  // NEW
  final String? bio; // short free-text bio (global)
  final List<String> photos; // ordered list of object paths or URLs (min 1, max 5)

  UserProfile({
    required this.id,
    required this.name,
    this.firstName,
    this.lastName,
    this.dateOfBirth,
    this.gender,
    required this.preferredLanguage,
    required this.activeModes,
    required this.subIntents,
    required this.interests,
    required this.languagesKnown,
    required this.subscriptionTier,
    required this.isProfileComplete,
    required this.matchRadiusDefault,
    required this.gpsIntervalDefault,
    required this.smartGpsThrottlingEnabled,
    required this.sharedEventMatchingEnabled,
    required this.sharedMovementMatchingEnabled,
    required this.editableProfileFields,
    required this.genderPreferences,
    required this.agePreferences,
    required this.strictGenderAgeEnforcement,
    this.bio,
    required this.photos,
  });

  factory UserProfile.fromMap(Map<String, dynamic> data) {
    DateTime? dob;
    if (data['dateOfBirth'] != null) {
      try {
        dob = DateTime.tryParse(data['dateOfBirth'].toString());
        // Normalize to date-only to avoid timezone offsets affecting the day
        if (dob != null) {
          dob = DateTime(dob.year, dob.month, dob.day);
        }
      } catch (_) {
        // Ignore invalid date format
      }
    }
    if (dob == null && data['date_of_birth'] != null) {
      try {
        dob = DateTime.tryParse(data['date_of_birth'].toString());
        if (dob != null) {
          dob = DateTime(dob.year, dob.month, dob.day);
        }
      } catch (_) {
        // Ignore invalid date format
      }
    }

    List<String> listFromDynamic(dynamic v) => _toStringList(v);

    // languages_known is now stored as JSONB object
    Map<String, List<String>> languagesKnown = {};
    final langData = data['languagesKnown'] ?? data['languages_known'];
    if (langData is Map<String, dynamic>) {
      languagesKnown = _mapOfLists(langData);
    } else if (langData is List) {
      // Backward compatibility: if still array, treat as list of codes
      languagesKnown['languages'] = _toStringList(langData);
    } else {
      languagesKnown = <String, List<String>>{};
    }

    // photos and bio are expected on users table (photos: List<String>, bio: String)
    List<String> photos = [];
    try {
      final p = data['photos'] ?? data['photo_urls'] ?? data['photoUrls'];
      photos = _toStringList(p);
    } catch (_) {
      // Ignore invalid photo data
      photos = [];
    }

    final String? bioField = (data['bio'] ?? data['profile_bio'] ?? data['about'])?.toString();

    return UserProfile(
      id: data['id']?.toString() ?? '',
      name: data['name']?.toString() ?? 'Unnamed',
      dateOfBirth: dob,
      gender: data['gender']?.toString(),
      preferredLanguage: (data['preferredLanguage'] ?? data['preferred_language'] ?? 'en').toString(),
      activeModes: listFromDynamic(data['activeModes'] ?? data['active_modes']),
      subIntents: _mapOfLists(data['subIntents'] ?? data['sub_intents']),
      interests: _mapOfLists(data['interests'] ?? data['profile_data']?['interests']),
      languagesKnown: languagesKnown,
      subscriptionTier: (data['subscription_tier'] ?? 'free').toString(),
      // FIXED: normalize multiple possible keys for isProfileComplete
      isProfileComplete: (() {
        final raw = data['isProfileComplete'] ??
            data['isProfile_complete'] ??
            data['is_profile_complete'] ??
            false;
        if (raw is bool) return raw;
        return raw.toString().toLowerCase() == 'true';
      })(),
      matchRadiusDefault: (data['match_radius_default'] ?? 50) is int
          ? (data['match_radius_default'] ?? 50) as int
          : int.tryParse((data['match_radius_default'] ?? '50').toString()) ?? 50,
      gpsIntervalDefault: (data['gps_interval_default'] ?? 5) is int
          ? (data['gps_interval_default'] ?? 5) as int
          : int.tryParse((data['gps_interval_default'] ?? '5').toString()) ?? 5,
      smartGpsThrottlingEnabled: (data['smart_gps_throttling_enabled'] ?? false) is bool
          ? (data['smart_gps_throttling_enabled'] ?? false) as bool
          : (data['smart_gps_throttling_enabled'] ?? false).toString().toLowerCase() == 'true',
      sharedEventMatchingEnabled: (data['shared_event_matching_enabled'] ?? false) is bool
          ? (data['shared_event_matching_enabled'] ?? false) as bool
          : (data['shared_event_matching_enabled'] ?? false).toString().toLowerCase() == 'true',
      sharedMovementMatchingEnabled: (data['shared_movement_matching_enabled'] ?? false) is bool
          ? (data['shared_movement_matching_enabled'] ?? false) as bool
          : (data['shared_movement_matching_enabled'] ?? false).toString().toLowerCase() == 'true',
      editableProfileFields: listFromDynamic(data['editableProfileFields'] ?? data['editable_profile_fields']),
      genderPreferences: _mapOfLists(data['gender_preferences'] ?? {}),
      agePreferences: _mapOfDoubleLists(data['age_preferences'] ?? {}),
      strictGenderAgeEnforcement: (data['strict_gender_age_enforcement'] ?? false) is bool
          ? (data['strict_gender_age_enforcement'] ?? false) as bool
          : (data['strict_gender_age_enforcement'] ?? false).toString().toLowerCase() == 'true',
      bio: bioField,
      photos: photos,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'dateOfBirth': dateOfBirth?.toIso8601String(),
      'gender': gender,
      'preferredLanguage': preferredLanguage,
      'activeModes': activeModes,
      'subIntents': subIntents,
      'interests': interests,
      'languagesKnown': languagesKnown,
      'subscription_tier': subscriptionTier,
      'isProfileComplete': isProfileComplete,
      'match_radius_default': matchRadiusDefault,
      'gps_interval_default': gpsIntervalDefault,
      'smart_gps_throttling_enabled': smartGpsThrottlingEnabled,
      'shared_event_matching_enabled': sharedEventMatchingEnabled,
      'shared_movement_matching_enabled': sharedMovementMatchingEnabled,
      'editableProfileFields': editableProfileFields,
      'gender_preferences': genderPreferences,
      'age_preferences': agePreferences,
      'strict_gender_age_enforcement': strictGenderAgeEnforcement,
      'bio': bio,
      'photos': photos,
    };
  }

  Map<String, dynamic> toJsonForUserTableSave() {
    return {
      'name': name,
      'date_of_birth': dateOfBirth?.toIso8601String().split('T').first,
      'gender': gender,
      'preferred_language': preferredLanguage,
      'active_modes': activeModes,
      // Persist languages as JSON object with codes and skills
      'languages_known': languagesKnown.isNotEmpty ? languagesKnown : null,
      'match_radius_default': matchRadiusDefault,
      'gps_interval_default': gpsIntervalDefault,
      'smart_gps_throttling_enabled': smartGpsThrottlingEnabled,
      'shared_event_matching_enabled': sharedEventMatchingEnabled,
      'shared_movement_matching_enabled': sharedMovementMatchingEnabled,
      'gender_preferences': genderPreferences.isNotEmpty ? genderPreferences : null,
      'age_preferences': agePreferences.isNotEmpty ? agePreferences : null,
      'strict_gender_age_enforcement': strictGenderAgeEnforcement,
      'bio': bio,
      'photos': photos, // persist ordered object paths (recommended)
    };
  }

  // --- This function filters interests for the specific intent ---
  Map<String, dynamic> toJsonForProfileTableSave(String intentType) {
    final normalizedIntent = _normalizeKey(intentType);
    final filteredInterests = <String, List<String>>{};

    interests.forEach((categoryKey, interestKeysList) {
      final key = categoryKey.toString();
      final parts = key.split('::');
      if (parts.length == 2) {
        final storedIntent = _normalizeKey(parts[0]);
        if (storedIntent == normalizedIntent) {
          final unprefixedCategory = parts[1];
          filteredInterests[unprefixedCategory] = interestKeysList;
        }
      } else {
        // Keep global categories as-is
        filteredInterests[key] = interestKeysList;
      }
    });

    return {
      'bio': 'My ${intentType.toLowerCase()} bio...', // Placeholder for intent-specific bio if needed
      'sub_intent': subIntents[intentType] ?? [],
      'interests': filteredInterests,
    };
  }

  UserProfile copyWith({
    String? id,
    String? name,
    DateTime? dateOfBirth,
    String? gender,
    String? preferredLanguage,
    List<String>? activeModes,
    Map<String, List<String>>? subIntents,
    Map<String, List<String>>? interests,
    Map<String, List<String>>? languagesKnown,
    String? subscriptionTier,
    bool? isProfileComplete,
    int? matchRadiusDefault,
    int? gpsIntervalDefault,
    bool? smartGpsThrottlingEnabled,
    bool? sharedEventMatchingEnabled,
    bool? sharedMovementMatchingEnabled,
    List<String>? editableProfileFields,
    Map<String, List<String>>? genderPreferences,
    Map<String, List<double>>? agePreferences,
    bool? strictGenderAgeEnforcement,
    String? bio,
    List<String>? photos,
  }) {
    Map<String, List<String>> cloneMap(Map<String, List<String>> src) =>
        Map<String, List<String>>.from(src.map((k, v) => MapEntry(k, List<String>.from(v))));

    Map<String, List<double>> cloneDoubleMap(Map<String, List<double>> src) =>
        Map<String, List<double>>.from(src.map((k, v) => MapEntry(k, List<double>.from(v))));

    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      gender: gender ?? this.gender,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      activeModes: activeModes != null ? List<String>.from(activeModes) : List<String>.from(this.activeModes),
      subIntents: subIntents != null ? cloneMap(subIntents) : cloneMap(this.subIntents),
      interests: interests != null ? cloneMap(interests) : cloneMap(this.interests),
      languagesKnown: languagesKnown != null ? cloneMap(languagesKnown) : cloneMap(this.languagesKnown),
      subscriptionTier: subscriptionTier ?? this.subscriptionTier,
      isProfileComplete: isProfileComplete ?? this.isProfileComplete,
      matchRadiusDefault: matchRadiusDefault ?? this.matchRadiusDefault,
      gpsIntervalDefault: gpsIntervalDefault ?? this.gpsIntervalDefault,
      smartGpsThrottlingEnabled: smartGpsThrottlingEnabled ?? this.smartGpsThrottlingEnabled,
      sharedEventMatchingEnabled: sharedEventMatchingEnabled ?? this.sharedEventMatchingEnabled,
      sharedMovementMatchingEnabled: sharedMovementMatchingEnabled ?? this.sharedMovementMatchingEnabled,
      editableProfileFields:
          editableProfileFields != null ? List<String>.from(editableProfileFields) : List<String>.from(this.editableProfileFields),
      genderPreferences: genderPreferences != null ? cloneMap(genderPreferences) : cloneMap(this.genderPreferences),
      agePreferences: agePreferences != null ? cloneDoubleMap(agePreferences) : cloneDoubleMap(this.agePreferences),
      strictGenderAgeEnforcement: strictGenderAgeEnforcement ?? this.strictGenderAgeEnforcement,
      bio: bio ?? this.bio,
      photos: photos != null ? List<String>.from(photos) : List<String>.from(this.photos),
    );
  }
}

/// Intent-specific profile data used in match / profile screens
class IntentProfileData {
  final String bio;
  final List<String> subIntents;
  final Map<String, List<String>> interests;

  IntentProfileData({
    required this.bio,
    required this.subIntents,
    required this.interests,
  });

  factory IntentProfileData.fromJson(Map<String, dynamic>? data) {
    if (data == null) {
      return IntentProfileData(bio: 'No bio provided.', subIntents: [], interests: {});
    }

    final Map<String, List<String>> interestsMap = {};
    final rawInterests = data['interests'];
    if (rawInterests is Map) {
      rawInterests.forEach((k, v) {
        interestsMap[k.toString()] = _toStringList(v);
      });
    }

    return IntentProfileData(
      bio: data['bio']?.toString() ?? 'No bio provided.',
      subIntents: _toStringList(data['sub_intent']),
      interests: interestsMap,
    );
  }
}

/// ---------------------------------------------------------------------------
/// ProfileSyncService
/// ---------------------------------------------------------------------------
class ProfileSyncService {
  final Ref ref;
  ProfileSyncService(this.ref);

  /// Fetch the user row from 'users' table, retrying if columns are missing.
  ///
  /// This is defensive against schema drift where new columns exist in code
  /// but not yet in the database.
  Future<Map<String, dynamic>?> _fetchUserRowWithFallback(String userId) async {
    // Columns we ideally want
    final baseColumns = <String>[
      'id',
      'name',
      'date_of_birth',
      'gender',
      'preferred_language',
      'active_modes',
      'languages_known',
      'subscription_tier',
      'is_profile_complete',
      'match_radius_default',
      'gps_interval_default',
      'smart_gps_throttling_enabled',
      'shared_event_matching_enabled',
      'shared_movement_matching_enabled',
      'editable_profile_fields',
      'bio',
      'photos',
    ];

    var columnsToTry = List<String>.from(baseColumns);
    final triedSignatures = <String>{};

    while (columnsToTry.isNotEmpty) {
      final signature = columnsToTry.join(',');
      if (triedSignatures.contains(signature)) break;
      triedSignatures.add(signature);

      try {
        final query = supabase.from('users').select(columnsToTry.join(',')).eq('id', userId).maybeSingle();
        final result = await query;
        if (result == null) return null;
        return Map<String, dynamic>.from(result as Map);
      } catch (e) {
        if (e is PostgrestException) {
          final msg = e.message;
          // Detect missing column error and remove the column, then retry.
          final missingColumnRegex = RegExp(r'column\s+"?(\w+)"?\s+does not exist', caseSensitive: false);
          final match = missingColumnRegex.firstMatch(msg);
          final missing = match?.group(1);
          if (missing != null && columnsToTry.contains(missing)) {
            columnsToTry.remove(missing);
            continue;
          }
        }
        rethrow;
      }
    }

    return null;
  }

  Future<void> syncProfile(String userId) async {
    if (userId.isEmpty) return;

    ResumeDiagnostics.log('ProfileSyncService.syncProfile START for user=$userId');

    // Avoid attempting sync when device is offline.
    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      ResumeDiagnostics.log('ProfileSyncService.syncProfile SKIP offline for user=$userId');
      return;
    }

    final startAll = DateTime.now();

    try {
      const int maxAttempts = 3;
      int attempt = 0;

      while (true) {
        attempt++;
        try {
          final startAttempt = DateTime.now();
          // Fetch user row with fallback strategy
          final userFuture = _fetchUserRowWithFallback(userId);

          // Fetch user_profiles rows concurrently
          final profilesFuture = supabase
              .from('user_profiles')
              .select('intent_type, profile_data')
              .eq('user_id', userId);

          final List<dynamic> results = await Future.wait([userFuture, profilesFuture]);
          final userData = results[0] as Map<String, dynamic>?;
          final profileDataList = (results[1] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

          final attemptDuration = DateTime.now().difference(startAttempt).inMilliseconds;
          ResumeDiagnostics.log('ProfileSyncService.syncProfile attempt $attempt completed in ${attemptDuration}ms for user=$userId');

          if (userData == null) {
            // No user row found — nothing to sync
            final totalDuration = DateTime.now().difference(startAll).inMilliseconds;
            ResumeDiagnostics.log('ProfileSyncService.syncProfile END (no user) for user=$userId total=${totalDuration}ms');
            return;
          }

          Map<String, List<String>> processedSubIntents = {};
          Map<String, List<String>> processedInterests = {};
          for (var profile in profileDataList) {
            final intentType = profile['intent_type']?.toString() ?? '';
            final pdRaw = profile['profile_data'];
            Map<String, dynamic> pd = {};
            if (pdRaw is Map) {
              pd = Map<String, dynamic>.from(pdRaw);
            } else if (pdRaw is String) {
              try {
                final decoded = jsonDecode(pdRaw);
                if (decoded is Map) pd = Map<String, dynamic>.from(decoded);
              } catch (_) {
                // Ignore JSON parsing errors
              }
            }

            if (pd['sub_intent'] != null) {
              processedSubIntents[intentType] = _toStringList(pd['sub_intent']);
            }

            // Ensure we never keep or propagate full last names from profile_data
            if (pd['fullName'] != null) {
              try {
                pd['fullName'] = maskName(pd['fullName']?.toString());
              } catch (_) {
                pd['fullName'] = 'Unknown User';
              }
            }
            if (pd['interests'] is Map) {
              final interestMap = pd['interests'] as Map<String, dynamic>;
              interestMap.forEach((categoryKey, interestKeyList) {
                // Preserve intent prefix when merging multiple user_profiles so different
                // intents' categories do not collide into the same plain category key.
                String storedCategoryKey = categoryKey.toString();
                // If the stored category key is not already prefixed (no '::') and we have an intentType,
                // prefix it so it remains scoped to that intent in the merged map.
                if (!storedCategoryKey.contains('::') && intentType.isNotEmpty) {
                  storedCategoryKey = '$intentType::$storedCategoryKey';
                }
                processedInterests.putIfAbsent(storedCategoryKey, () => []);
                final stringKeys = _toStringList(interestKeyList);
                for (final k in stringKeys) {
                  if (!processedInterests[storedCategoryKey]!.contains(k)) {
                    processedInterests[storedCategoryKey]!.add(k);
                  }
                }
              });
            }
          }

          final editableFieldsDynamic = userData['editable_profile_fields'];
          final editableFields = _toStringList(editableFieldsDynamic);

          final profile = UserProfile(
            id: userData['id']?.toString() ?? '',
            // Mask name to prevent storing full last name locally
            name: maskName(userData['name']?.toString()),
            // Normalize DOB to date-only to avoid timezone shifts that can change the day
            dateOfBirth: (() {
              if (userData['date_of_birth'] == null) return null;
              try {
                final d = DateTime.tryParse(userData['date_of_birth'].toString());
                if (d == null) return null;
                return DateTime(d.year, d.month, d.day);
              } catch (_) { return null; }
            })(),
            gender: userData['gender']?.toString(),
            preferredLanguage: (userData['preferred_language'] ?? 'en').toString(),
            activeModes: _toStringList(userData['active_modes'] ?? userData['active_modes']),
            subIntents: processedSubIntents,
            interests: processedInterests,
            languagesKnown: _mapOfLists(userData['languages_known'] ?? userData['languages_known']),
            subscriptionTier: (userData['subscription_tier'] ?? 'free').toString(),
            isProfileComplete: (userData['is_profile_complete'] ?? false) is bool
                ? (userData['is_profile_complete'] ?? false) as bool
                : (userData['is_profile_complete'] ?? false).toString().toLowerCase() == 'true',
            matchRadiusDefault: (userData['match_radius_default'] ?? 50) is int
                ? (userData['match_radius_default'] ?? 50) as int
                : int.tryParse((userData['match_radius_default'] ?? '50').toString()) ?? 50,
            gpsIntervalDefault: (userData['gps_interval_default'] ?? 5) is int
                ? (userData['gps_interval_default'] ?? 5) as int
                : int.tryParse((userData['gps_interval_default'] ?? '5').toString()) ?? 5,
            smartGpsThrottlingEnabled: (userData['smart_gps_throttling_enabled'] ?? false) is bool
                ? (userData['smart_gps_throttling_enabled'] ?? false) as bool
                : (userData['smart_gps_throttling_enabled'] ?? false).toString().toLowerCase() == 'true',
            sharedEventMatchingEnabled: (userData['shared_event_matching_enabled'] ?? false) is bool
                ? (userData['shared_event_matching_enabled'] ?? false) as bool
                : (userData['shared_event_matching_enabled'] ?? false).toString().toLowerCase() == 'true',
            sharedMovementMatchingEnabled: (userData['shared_movement_matching_enabled'] ?? false) is bool
                ? (userData['shared_movement_matching_enabled'] ?? false) as bool
                : (userData['shared_movement_matching_enabled'] ?? false).toString().toLowerCase() == 'true',
            editableProfileFields: editableFields,
            genderPreferences: _mapOfLists(userData['gender_preferences'] ?? {}),
            agePreferences: _mapOfDoubleLists(userData['age_preferences'] ?? {}),
            strictGenderAgeEnforcement: (userData['strict_gender_age_enforcement'] ?? false) is bool
                ? (userData['strict_gender_age_enforcement'] ?? false) as bool
                : (userData['strict_gender_age_enforcement'] ?? false).toString().toLowerCase() == 'true',
            bio: userData['bio']?.toString(),
            photos: _toStringList(userData['photos']),
          );

          final localDb = ref.read(localDbProvider);
          await localDb.saveLocalProfile(userId, profile.toMap());

          // Success — exit retry loop
          final totalDuration = DateTime.now().difference(startAll).inMilliseconds;
          ResumeDiagnostics.log('ProfileSyncService.syncProfile SUCCESS for user=$userId total=${totalDuration}ms');
          break;
        } catch (e) {
          final msg = e.toString().toLowerCase();
          final isTransient = msg.contains('software caused connection abort') ||
              msg.contains('socketexception') ||
              msg.contains('connection reset') ||
              msg.contains('timed out') ||
              e is TimeoutException;

          if (!isTransient || attempt >= maxAttempts) {
            // Give up and surface the error to the outer catch which logs and swallows.
            rethrow;
          }

          // Exponential backoff before retrying
          final backoffMs = 200 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: backoffMs));
          // Retry
          continue;
        }
      }
    } catch (e) {
      // safe failure: swallow to avoid crashing sync loops
      debugPrint('Profile sync failed for user $userId: $e');
    }
  }
}

final profileSyncProvider = Provider((ref) => ProfileSyncService(ref));

/// --- userProfileProvider ---------------------------------------------------
final userProfileProvider = StreamProvider.family<UserProfile?, String>((ref, userId) {
  final localDb = ref.watch(localDbProvider);

  try {
    ResumeDiagnostics.log('userProfileProvider created for user=$userId');
    ref.onDispose(() => ResumeDiagnostics.log('userProfileProvider disposed for user=$userId'));
  } catch (_) {}

  final localStream = localDb.watchLocalProfile(userId);
  return localStream.map((localProfileMap) {
    if (localProfileMap == null) {
      unawaited(() {
        ResumeDiagnostics.log('userProfileProvider triggered syncProfile for user=$userId');
        return ref.read(profileSyncProvider).syncProfile(userId);
      }());
      return null;
    }
    ResumeDiagnostics.log('userProfileProvider has local data for user=$userId');
    return UserProfile.fromMap(localProfileMap);
  });
});

/// --- specificProfileProvider ----------------------------------------------
/// Fetches a single intent-specific profile (bio, sub-intent + interests)
/// directly from the remote 'user_profiles' table.
final specificProfileProvider = FutureProvider.family<IntentProfileData?, Map<String, String>>((ref, params) async {
  final userId = params['userId'] ?? '';
  final intentType = params['intentType'] ?? '';
  if (userId.isEmpty || intentType.isEmpty) return null;

  final response = await supabase
      .from('user_profiles')
      .select('profile_data')
      .eq('user_id', userId)
      .eq('intent_type', intentType)
      .maybeSingle();

  if (response == null) return null;
  final profileData = response['profile_data'];
  if (profileData is Map<String, dynamic>) {
    // Mask fullName when present
    if (profileData['fullName'] != null) {
      profileData['fullName'] = maskName(profileData['fullName']?.toString());
    }
    return IntentProfileData.fromJson(profileData);
  } else if (profileData is String) {
    try {
      final decoded = jsonDecode(profileData);
      if (decoded is Map<String, dynamic>) {
        if (decoded['fullName'] != null) {
          decoded['fullName'] = maskName(decoded['fullName']?.toString());
        }
        return IntentProfileData.fromJson(decoded);
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
  }
  return null;
});

/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------
@riverpod
class ProfileEditNotifier extends _$ProfileEditNotifier {
  @override
  AsyncValue<UserProfile?> build(String userId) {
    return const AsyncLoading();
  }

  Future<void> loadInitialProfile() async {
    try {
      // Always reload fresh data to ensure we have the latest from server
      state = const AsyncLoading();
      final initialProfile = await ref.read(userProfileProvider(userId).future);
      if (initialProfile != null) {
        state = AsyncData(initialProfile.copyWith());
        // Pre-warm signed URLs cache for profile photos so image widgets
        // (SignedImage) can resolve cached signed URLs immediately and
        // begin loading images without waiting for per-widget signing calls.
        unawaited(Future.microtask(() async {
          try {
            for (final src in initialProfile.photos) {
              if (src.isEmpty) continue;
              // Request a signed URL (StorageHelper will cache the result).
              try {
                await StorageHelper.getSignedUrl(src);
              } catch (_) {
                // Ignore cache errors
              }
            }
          } catch (_) {
            // Ignore cache errors
          }
        }));
      } else {
        await ref.read(profileSyncProvider).syncProfile(userId);
        final reloaded = await ref.read(userProfileProvider(userId).future);
        if (reloaded != null) {
          state = AsyncData(reloaded.copyWith());
          // Pre-warm signed URLs cache for profile photos (from reloaded profile)
          unawaited(Future.microtask(() async {
            try {
              for (final src in reloaded.photos) {
                if (src.isEmpty) continue;
                try {
                  await StorageHelper.getSignedUrl(src);
                } catch (_) {}
              }
            } catch (_) {}
          }));
        } else {
          // Create default profile for new user
          final defaultProfile = UserProfile(
            id: userId,
            name: 'Unnamed',
            preferredLanguage: 'en',
            activeModes: [],
            subIntents: {},
            interests: {},
            languagesKnown: {},
            subscriptionTier: 'free',
            isProfileComplete: false,
            matchRadiusDefault: 50,
            gpsIntervalDefault: 5,
            smartGpsThrottlingEnabled: false,
            sharedEventMatchingEnabled: false,
            sharedMovementMatchingEnabled: false,
            editableProfileFields: ['name', 'date_of_birth', 'gender'],
            genderPreferences: {},
            agePreferences: {},
            strictGenderAgeEnforcement: false,
            photos: [],
          );
          if (ref.mounted) {
            state = AsyncData(defaultProfile);
          }
          // Save to local DB
          final localDb = ref.read(localDbProvider);
          await localDb.saveLocalProfile(userId, defaultProfile.toMap());
        }
      }
    } catch (e, st) {
      if (ref.mounted) {
        state = AsyncError(e, st);
      }
    }
  }

  bool _canEditField(String fieldKey) {
    final profile = state.value;
    if (profile == null) return false;
    return profile.editableProfileFields.contains(fieldKey) || !profile.isProfileComplete;
  }

  /// Helper method to delete storage objects from Supabase storage
  Future<void> _deleteStorageObject(String objectPath) async {
    try {
      // Use StorageHelper to normalize URLs/paths and perform deletion.
      await StorageHelper.deleteObject(objectPath);
    } catch (e) {
      // StorageHelper.deleteObject is best-effort and already swallows
      // errors internally; nothing more to do here.
    }
  }

  void updateName(String name) {
    if (!state.hasValue || state.value == null) return;
    if (!_canEditField('name')) {
      state = AsyncError("Name editing locked. Submit a request to admin to unlock.", StackTrace.current);
      return;
    }
    state = AsyncData(state.value!.copyWith(name: name));
  }

  void updateDob(DateTime dob) {
    if (!state.hasValue || state.value == null) return;
    if (!_canEditField('date_of_birth')) {
      state = AsyncError("DOB editing locked. Submit a request to admin to unlock.", StackTrace.current);
      return;
    }
    state = AsyncData(state.value!.copyWith(dateOfBirth: dob));
  }

  void updateGender(String? gender) {
    if (!state.hasValue || state.value == null) return;
    if (!_canEditField('gender')) {
      state = AsyncError("Gender editing locked. Submit a request to admin to unlock.", StackTrace.current);
      return;
    }
    state = AsyncData(state.value!.copyWith(gender: gender));
  }

  void updatePreferredLanguage(String lang) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(preferredLanguage: lang));
  }

  Future<void> updateRadius(int radius) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(matchRadiusDefault: radius);
    state = AsyncData(updatedProfile);

    // Save to local cache first
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Invalidate the userProfileProvider to ensure immediate update
    ref.invalidate(userProfileProvider(userId));
    // Invalidate the visibility provider to ensure the listener is set up with the correct userId
    ref.invalidate(isVisibleProvider);

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'match_radius_default': radius,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'match_radius_default': radius},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateGpsRate(int seconds) async {
    if (!state.hasValue || state.value == null) return;
    // Store seconds directly (no conversion needed)
    final updatedProfile = state.value!.copyWith(gpsIntervalDefault: seconds);
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());
    
    // Directly notify VisibilityNotifier with the new GPS rate value
    // This bypasses the database read which might return cached/stale data
    try {
      final visibilityNotifier = ref.read(isVisibleProvider.notifier);
      await visibilityNotifier.updateLocationStreamInterval(newGpsRate: seconds);
    } catch (e) {
      // Ignore
    }

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'gps_interval_default': seconds,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'gps_interval_default': seconds},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateSmartGpsThrottling(bool enabled) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(smartGpsThrottlingEnabled: enabled);
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Directly notify VisibilityNotifier to update throttling setting immediately
    try {
      final visibilityNotifier = ref.read(isVisibleProvider.notifier);
      await visibilityNotifier.updateLocationStreamInterval();
    } catch (e) {
      // Ignore
    }

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'smart_gps_throttling_enabled': enabled,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'smart_gps_throttling_enabled': enabled},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateSharedEventMatching(bool enabled) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(sharedEventMatchingEnabled: enabled);
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'shared_event_matching_enabled': enabled,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'shared_event_matching_enabled': enabled},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateSharedMovementMatching(bool enabled) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(sharedMovementMatchingEnabled: enabled);
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'shared_movement_matching_enabled': enabled,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'shared_movement_matching_enabled': enabled},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateGenderAgePreferences(
    Map<String, List<String>> genderPreferences,
    Map<String, List<double>> agePreferences,
    bool strictEnforcement,
  ) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(
      genderPreferences: genderPreferences,
      agePreferences: agePreferences,
      strictGenderAgeEnforcement: strictEnforcement,
    );
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Try to sync to backend
    try {
      await supabase.from('users').update({
        'gender_preferences': genderPreferences.isNotEmpty ? genderPreferences : null,
        'age_preferences': agePreferences.isNotEmpty ? agePreferences : null,
        'strict_gender_age_enforcement': strictEnforcement,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {
          'gender_preferences': genderPreferences.isNotEmpty ? genderPreferences : null,
          'age_preferences': agePreferences.isNotEmpty ? agePreferences : null,
          'strict_gender_age_enforcement': strictEnforcement,
        },
      });
      // Do not revert state, keep the local change
    }
  }

  void updateActiveModes(List<String> modes) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(activeModes: modes));
  }

  void toggleIntent(String intentKey) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final normalized = _normalizeKey(intentKey);
    final List<String> updatedModes = List<String>.from(current.activeModes);

    if (updatedModes.map(_normalizeKey).contains(normalized)) {
      updatedModes.removeWhere((m) => _normalizeKey(m) == normalized);

      // Also remove subIntents for this intent
      final newSubIntents = Map<String, List<String>>.from(current.subIntents);
      newSubIntents.remove(intentKey);

      // Also remove interests that are scoped to this intent (keys prefixed with "intent::")
      final newInterests = Map<String, List<String>>.from(current.interests);
      final keysToRemove = <String>[];
      newInterests.forEach((categoryKey, _) {
        final keyStr = categoryKey.toString();
        if (keyStr.startsWith('$intentKey::')) {
          keysToRemove.add(keyStr);
        }
      });
      for (final k in keysToRemove) {
        newInterests.remove(k);
      }

      // Check if no more social intents remain, remove all social interests
      final allIntents = ref.read(allIntentsProvider).asData?.value ?? [];
      final socialIntentKeys = allIntents.where((i) => i.isSocial).map((i) => _normalizeKey(i.key)).toSet();
      final hasSocialIntent = updatedModes.any((m) => socialIntentKeys.contains(_normalizeKey(m)));
      if (!hasSocialIntent) {
        final allInterests = ref.read(allInterestsProvider).asData?.value ?? [];
        final socialCategoryKeys = allInterests.where((i) => i.parentId == null && i.isSocial).map((i) => i.key).toSet();
        newInterests.removeWhere((categoryKey, _) => socialCategoryKeys.contains(categoryKey));
      }

      // Check if no more business intents remain, remove all business interests
      final businessIntentKeys = allIntents.where((i) => i.isBusiness).map((i) => _normalizeKey(i.key)).toSet();
      final hasBusinessIntent = updatedModes.any((m) => businessIntentKeys.contains(_normalizeKey(m)));
      if (!hasBusinessIntent) {
        final allInterests = ref.read(allInterestsProvider).asData?.value ?? [];
        final businessCategoryKeys = allInterests.where((i) => i.parentId == null && i.isBusiness).map((i) => i.key).toSet();
        newInterests.removeWhere((categoryKey, _) => businessCategoryKeys.contains(categoryKey));
      }

      state = AsyncData(current.copyWith(
        activeModes: updatedModes,
        subIntents: newSubIntents,
        interests: newInterests,
      ));
    } else {
      updatedModes.add(intentKey);
      state = AsyncData(current.copyWith(activeModes: updatedModes));
    }
  }

  void toggleSubIntent(String intentKey, String subIntentKey, {bool awaitPersist = false}) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final existing = Map<String, List<String>>.from(current.subIntents);
    final list = List<String>.from(existing[intentKey] ?? const []);
    if (list.contains(subIntentKey)) {
      list.remove(subIntentKey);
    } else {
      list.add(subIntentKey);
    }
    existing[intentKey] = list;
    state = AsyncData(current.copyWith(subIntents: existing));
  }

  void toggleInterest(String prefixedCategoryKey, String interestKey, {bool awaitPersist = false}) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final newInterests = Map<String, List<String>>.from(current.interests);
    var list = List<String>.from(newInterests[prefixedCategoryKey] ?? const []);
    list = list.toSet().toList(); // deduplicate
    if (list.contains(interestKey)) {
      list.remove(interestKey);
      if (list.isEmpty) {
        newInterests.remove(prefixedCategoryKey);
      } else {
        newInterests[prefixedCategoryKey] = list;
      }
    } else {
      list.add(interestKey);
      newInterests[prefixedCategoryKey] = list;
    }
    state = AsyncData(current.copyWith(interests: newInterests));
  }

  void toggleLanguageKnown(String langCode) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final languages = Map<String, List<String>>.from(current.languagesKnown);
    final baseList = List<String>.from(languages['languages'] ?? const []);
    if (baseList.contains(langCode)) {
      baseList.remove(langCode);
    } else {
      baseList.add(langCode);
    }
    languages['languages'] = baseList;
    state = AsyncData(current.copyWith(languagesKnown: languages));
  }

  void addLanguage(String langCode) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final languages = Map<String, List<String>>.from(current.languagesKnown);
    final baseList = List<String>.from(languages['languages'] ?? const []);
    if (!baseList.contains(langCode)) {
      baseList.add(langCode);
      languages['languages'] = baseList;
      state = AsyncData(current.copyWith(languagesKnown: languages));
    }
  }

  void removeLanguage(String langCode) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final languages = Map<String, List<String>>.from(current.languagesKnown);
    final baseList = List<String>.from(languages['languages'] ?? const []);
    baseList.remove(langCode);
    languages['languages'] = baseList;
    // Also remove the skills entry if it exists
    languages.remove(langCode);
    state = AsyncData(current.copyWith(languagesKnown: languages));
  }

  void setLanguageSkills(String langCode, List<String> skills) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final languages = Map<String, List<String>>.from(current.languagesKnown);
    languages[langCode] = List<String>.from(skills);
    // Ensure it's in the main list
    final baseList = List<String>.from(languages['languages'] ?? const []);
    if (!baseList.contains(langCode)) {
      baseList.add(langCode);
      languages['languages'] = baseList;
    }
    state = AsyncData(current.copyWith(languagesKnown: languages));
  }

  // --- Bio management ---
  void updateBio(String newBio) {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    state = AsyncData(p.copyWith(bio: newBio));
  }

  // --- Photos management ---
  Future<void> addPhotoFromBytes(Uint8List bytes, {bool awaitPersist = true}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (before.photos.length >= 5) {
      throw Exception('Maximum 5 photos allowed.');
    }

    final uploader = ref.read(profileEditRequestServiceProvider);
    final fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';

    // uploader returns the object path (e.g. "userId/163423432.jpg")
    final uploadedObjectPath = await uploader.uploadBytesToStorage(fileName, bytes, public: false);
    if (uploadedObjectPath == null) {
      throw Exception('Photo upload failed.');
    }

    final newPhotos = List<String>.from(before.photos)..add(uploadedObjectPath);
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        // Persist to backend
        await supabase.from('users').update({'photos': newPhotos, 'bio': updated.bio}).eq('id', userId);
        // Update local DB immediately to avoid sync reverting changes
        await localDb.saveLocalProfile(userId, updated.toMap());
        // Evict any cached signed url for the new path just to be safe
        StorageHelper.evict(uploadedObjectPath);
        // Ensure state reflects the persisted profile
        if (ref.mounted) {
          state = AsyncData(updated);
        }
      } catch (e) {
        // revert optimistic state
        if (ref.mounted) {
          state = AsyncData(before);
        }
        rethrow;
      }
    } else {
      // Fire-and-forget persist: update localDb immediately and let background sync fix inconsistencies
      await localDb.saveLocalProfile(userId, updated.toMap());
      unawaited(supabase.from('users').update({'photos': newPhotos, 'bio': updated.bio}).eq('id', userId).catchError((e) {
        unawaited(ref.read(profileSyncProvider).syncProfile(userId));
      }));
    }
  }

  Future<void> removePhotoAt(int index, {bool awaitPersist = true}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (index < 0 || index >= before.photos.length) return;

    final removedPath = before.photos[index];

    final newPhotos = List<String>.from(before.photos)..removeAt(index);
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        await supabase.from('users').update({'photos': newPhotos}).eq('id', userId);
        // Delete the storage object from Supabase storage
        await _deleteStorageObject(removedPath);
        // Ensure local cache reflects the removal immediately to avoid being reverted by sync
        await localDb.saveLocalProfile(userId, updated.toMap());
        // Evict cache for removed objectPath if it's not a full URL
        if (!removedPath.startsWith('http://') && !removedPath.startsWith('https://')) {
          StorageHelper.evict(removedPath);
        }
        if (ref.mounted) {
          state = AsyncData(updated);
        }
      } catch (e) {
        // revert optimistic state
        if (ref.mounted) {
          state = AsyncData(before);
        }
        rethrow;
      }
    } else {
      // fire-and-forget: update local cache now so UI updates
      await localDb.saveLocalProfile(userId, updated.toMap());
      unawaited(supabase.from('users').update({'photos': newPhotos}).eq('id', userId).catchError((e) {
        unawaited(ref.read(profileSyncProvider).syncProfile(userId));
      }).whenComplete(() async {
        // Delete the storage object from Supabase storage
        await _deleteStorageObject(removedPath);
        if (!removedPath.startsWith('http://') && !removedPath.startsWith('https://')) {
          StorageHelper.evict(removedPath);
        }
      }));
    }
  }

  Future<void> replacePhotoAtIndex(int index, {Uint8List? bytes, String? url, bool awaitPersist = true}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (index < 0 || index >= before.photos.length) return;
    final newPhotos = List<String>.from(before.photos);
    final oldPath = newPhotos[index];

    String? newObjectPath = url;
    if (bytes != null) {
      final uploader = ref.read(profileEditRequestServiceProvider);
      final fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';
      // returns objectPath
      final uploadedObjectPath = await uploader.uploadBytesToStorage(fileName, bytes, public: false);
      if (uploadedObjectPath == null) {
        throw Exception('Photo upload failed.');
      }
      newObjectPath = uploadedObjectPath;
    }

    if (newObjectPath == null) return;
    newPhotos[index] = newObjectPath;
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        await supabase.from('users').update({'photos': newPhotos}).eq('id', userId);
        // Delete the old storage object from Supabase storage
        await _deleteStorageObject(oldPath);
        await localDb.saveLocalProfile(userId, updated.toMap());
        // Evict old + new cache so SignedImage regenerates signed URLs
        if (!oldPath.startsWith('http://') && !oldPath.startsWith('https://')) {
          StorageHelper.evict(oldPath);
        }
        if (!newObjectPath.startsWith('http://') && !newObjectPath.startsWith('https://')) {
          StorageHelper.evict(newObjectPath);
        }
        if (ref.mounted) {
          state = AsyncData(updated);
        }
      } catch (e) {
        state = AsyncData(before);
        rethrow;
      }
    } else {
      await localDb.saveLocalProfile(userId, updated.toMap());
      unawaited(supabase.from('users').update({'photos': newPhotos}).eq('id', userId).catchError((e) {
        unawaited(ref.read(profileSyncProvider).syncProfile(userId));
      }).whenComplete(() async {
        // Delete the old storage object from Supabase storage
        await _deleteStorageObject(oldPath);
        if (!oldPath.startsWith('http://') && !oldPath.startsWith('https://')) {
          StorageHelper.evict(oldPath);
        }
        if (newObjectPath != null && !newObjectPath.startsWith('http://') && !newObjectPath.startsWith('https://')) {
          StorageHelper.evict(newObjectPath);
        }
      }));
    }
  }

  Future<void> reorderPhotos(int oldIndex, int newIndex, {bool awaitPersist = true}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    final photos = List<String>.from(before.photos);
    if (oldIndex < 0 || oldIndex >= photos.length || newIndex < 0 || newIndex >= photos.length) return;
    final item = photos.removeAt(oldIndex);
    photos.insert(newIndex, item);
    final updated = before.copyWith(photos: photos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        await supabase.from('users').update({'photos': photos}).eq('id', userId);
        await localDb.saveLocalProfile(userId, updated.toMap());
        if (ref.mounted) {
          state = AsyncData(updated);
        }
      } catch (e) {
        state = AsyncData(before);
        rethrow;
      }
    } else {
      await localDb.saveLocalProfile(userId, updated.toMap());
      unawaited(supabase.from('users').update({'photos': photos}).eq('id', userId).catchError((e) {
        unawaited(ref.read(profileSyncProvider).syncProfile(userId));
      }));
    }
  }

  Future<bool> saveProfile({bool showLoading = true, bool markComplete = true}) async {
    final currentState = state.value;
    if (currentState == null) return false;
    if (currentState.name.isEmpty || currentState.dateOfBirth == null) {
      state = AsyncError("Name and DOB required.", StackTrace.current);
      return false;
    }
    // Enforce min 1 photo only if profile is already complete
    if (currentState.photos.isEmpty && currentState.isProfileComplete) {
      state = AsyncError("At least 1 photo is required.", StackTrace.current);
      return false;
    }
    if (showLoading) state = const AsyncLoading();
    try {
      final userUpdatePayload = currentState.toJsonForUserTableSave();
      // Remove null-valued keys to avoid sending nulls to the REST endpoint
      final filteredPayload = Map<String, dynamic>.fromEntries(
        userUpdatePayload.entries.where((e) => e.value != null),
      );
      // Mark profile as complete when saving
      if (markComplete) {
        filteredPayload['is_profile_complete'] = true;
      }

      // Build the user_profiles upsert payload up-front so we can queue it when offline.
      final List<Map<String, dynamic>> profilesToUpsert = [
        for (final intentKey in currentState.activeModes)
          {
            'user_id': userId,
            'intent_type': intentKey,
            'profile_data': currentState.toJsonForProfileTableSave(intentKey),
          }
      ];

      // Update local state to reflect completion immediately (offline-first).
      final localProfile = currentState.copyWith(
        isProfileComplete: markComplete ? true : currentState.isProfileComplete,
      );

      // Persist to local DB first so user's progress is saved even if network fails
      final localDb = ref.read(localDbProvider);
      try {
        await localDb.saveLocalProfile(userId, localProfile.toMap());
        // Invalidate to ensure userProfileProvider updates with local data
        ref.invalidate(userProfileProvider(userId));
      } catch (e) {
        debugPrint('Local DB save before Supabase update failed: $e');
      }

      // If offline, queue the save and return success (will sync later).
      final isOnline = ref.read(connectivityProvider).value ?? true;
      if (!isOnline) {
        await localDb.saveProfileUpdateToOutbox(userId, {
          'type': 'full_profile_save',
          'userId': userId,
          'updates': filteredPayload,
          'profilesToUpsert': profilesToUpsert,
          'activeModes': currentState.activeModes,
          'timestamp': DateTime.now().toIso8601String(),
        });
        if (ref.mounted) {
          state = AsyncData(localProfile);
        }
        return true;
      }

      try {
        await supabase.from('users').update(filteredPayload).eq('id', userId);
      } catch (e) {
        debugPrint('Failed to update users for id=$userId with payload: $filteredPayload');
        debugPrint('Supabase update error: $e');
        // If we lost connectivity mid-save, queue it and return success.
        final nowOnline = ref.read(connectivityProvider).value ?? true;
        if (!nowOnline) {
          await localDb.saveProfileUpdateToOutbox(userId, {
            'type': 'full_profile_save',
            'userId': userId,
            'updates': filteredPayload,
            'profilesToUpsert': profilesToUpsert,
            'activeModes': currentState.activeModes,
            'timestamp': DateTime.now().toIso8601String(),
          });
          if (ref.mounted) {
            state = AsyncData(localProfile);
          }
          return true;
        }
        rethrow;
      }

      final activeIntentsNow = currentState.activeModes.map(_normalizeKey).toSet();
      final existingProfilesData = await supabase.from('user_profiles').select('intent_type').eq('user_id', userId);
      final existingIntentTypes = (existingProfilesData as List<dynamic>).map((p) => p['intent_type'] as String).toSet();

      final List<String> intentsToDelete = [];

      for (String existingIntent in existingIntentTypes) {
        if (!activeIntentsNow.contains(_normalizeKey(existingIntent))) {
          intentsToDelete.add(existingIntent);
        }
      }

      if (profilesToUpsert.isNotEmpty) {
        try {
          // Use onConflict without spaces so PostgREST receives the exact column list
          await supabase.from('user_profiles').upsert(profilesToUpsert, onConflict: 'user_id,intent_type');
        } on PostgrestException catch (e) {
          // If the DB doesn't support the ON CONFLICT target or we hit a primary-key conflict,
          // fall back to deleting existing rows for these intent types and inserting fresh rows.
          debugPrint('user_profiles upsert failed: ${e.message}');
          final problematicMsg = e.message.toLowerCase();
          if (problematicMsg.contains('pkey') || problematicMsg.contains('primary key') || problematicMsg.contains('no unique or exclusion constraint')) {
            try {
              // Some schemas use `user_id` as the primary key which prevents inserting
              // multiple rows for the same user. To ensure we can replace all intent
              // rows atomically, delete any existing rows for this user first, then
              // insert the fresh set of profiles.
              await supabase.from('user_profiles').delete().eq('user_id', userId);
              await supabase.from('user_profiles').insert(profilesToUpsert);
            } catch (inner) {
              debugPrint('Fallback replace of user_profiles failed: $inner');
              rethrow;
            }
          } else {
            rethrow;
          }
        }
      }
      if (intentsToDelete.isNotEmpty) {
        await supabase.from('user_profiles').delete().eq('user_id', userId).inFilter('intent_type', intentsToDelete);
      }

      if (ref.mounted) {
        state = AsyncData(localProfile);
      }
      return true;
    } catch (e, st) {
      if (ref.mounted) {
        state = AsyncError(e, st);
      }
      return false;
    }
  }
}
