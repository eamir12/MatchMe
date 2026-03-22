// lib/providers/profile_provider.dart
// Full provider implementation with robust syncProfile which tolerates missing columns
// on the users table by retrying the select after removing reported missing columns.
// Also ensures local cache is updated immediately after user photos changes so UI changes
// are not reverted by subsequent background syncs. Evicts signed-url cache when appropriate.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/profile_request_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/referral_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:uuid/uuid.dart';

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
  final DateTime? subscriptionExpiresAt;
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

  // Verification fields
  final bool isVerified;
  final String verificationStatus;
  final DateTime? verificationSubmittedAt;
  final DateTime? verificationReviewedAt;
  final String? referralCode;
  final int credits;

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
    this.subscriptionExpiresAt,
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
    this.isVerified = false,
    this.verificationStatus = 'unverified',
    this.verificationSubmittedAt,
    this.verificationReviewedAt,
    this.referralCode,
    this.credits = 0,
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

    // Parse verification fields
    final bool isVerified = (data['is_verified'] ?? false) is bool
        ? (data['is_verified'] ?? false) as bool
        : (data['is_verified'] ?? false).toString().toLowerCase() == 'true';

    final String verificationStatus = (data['verification_status'] ?? 'unverified').toString();

    DateTime? verificationSubmittedAt;
    if (data['verification_submitted_at'] != null) {
      try {
        verificationSubmittedAt = DateTime.tryParse(data['verification_submitted_at'].toString());
      } catch (_) {
        // Ignore invalid date
      }
    }

    DateTime? verificationReviewedAt;
    if (data['verification_reviewed_at'] != null) {
      try {
        verificationReviewedAt = DateTime.tryParse(data['verification_reviewed_at'].toString());
      } catch (_) {
        // Ignore invalid date
      }
    }

    DateTime? parseOptionalDateTime(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      final raw = v.toString().trim();
      if (raw.isEmpty) return null;

      DateTime? tryParse(String s) => DateTime.tryParse(s);

      final direct = tryParse(raw);
      if (direct != null) return direct;

      var s = raw;
      if (s.contains(' ') && !s.contains('T')) {
        s = s.replaceFirst(' ', 'T');
      }

      final tzShort = RegExp(r'([+-]\d{2})$');
      final tzNoColon = RegExp(r'([+-]\d{2})(\d{2})$');
      if (tzNoColon.hasMatch(s)) {
        s = s.replaceFirstMapped(tzNoColon, (m) => '${m.group(1)}:${m.group(2)}');
      } else if (tzShort.hasMatch(s)) {
        s = s.replaceFirstMapped(tzShort, (m) => '${m.group(1)}:00');
      }

      return tryParse(s);
    }

    final subscriptionExpiresAt = parseOptionalDateTime(
      data['subscription_expires_at'] ?? data['subscriptionExpiresAt'],
    );

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
      subscriptionExpiresAt: subscriptionExpiresAt,
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
      isVerified: isVerified,
      verificationStatus: verificationStatus,
      verificationSubmittedAt: verificationSubmittedAt,
      verificationReviewedAt: verificationReviewedAt,
      referralCode: data['referral_code']?.toString(),
      credits: (data['credits'] is int) ? data['credits'] : int.tryParse(data['credits']?.toString() ?? '0') ?? 0,
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
      'subscription_expires_at': subscriptionExpiresAt?.toIso8601String(),
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
      'is_verified': isVerified,
      'verification_status': verificationStatus,
      'verification_submitted_at': verificationSubmittedAt?.toIso8601String(),
      'verification_reviewed_at': verificationReviewedAt?.toIso8601String(),
      'referral_code': referralCode,
      'credits': credits,
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
      'referral_code': referralCode,
      'credits': credits,
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
    DateTime? subscriptionExpiresAt,
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
    bool? isVerified,
    String? verificationStatus,
    DateTime? verificationSubmittedAt,
    DateTime? verificationReviewedAt,
    String? referralCode,
    int? credits,
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
      subscriptionExpiresAt: subscriptionExpiresAt ?? this.subscriptionExpiresAt,
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
      isVerified: isVerified ?? this.isVerified,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verificationSubmittedAt: verificationSubmittedAt ?? this.verificationSubmittedAt,
      verificationReviewedAt: verificationReviewedAt ?? this.verificationReviewedAt,
      referralCode: referralCode ?? this.referralCode,
      credits: credits ?? this.credits,
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
      'created_at',
      'name',
      'date_of_birth',
      'gender',
      'preferred_language',
      'active_modes',
      'languages_known',
      'subscription_tier',
      'subscription_expires_at',
      'is_profile_complete',
      'match_radius_default',
      'gps_interval_default',
      'smart_gps_throttling_enabled',
      'shared_event_matching_enabled',
      'shared_movement_matching_enabled',
      'editable_profile_fields',
      'gender_preferences',
      'age_preferences',
      'strict_gender_age_enforcement',
      'bio',
      'photos',
      'approved_primary_photos',
      'is_verified',
      'verification_status',
      'verification_submitted_at',
      'verification_reviewed_at',
      'referral_code',
      'credits',
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
    final session = supabase.auth.currentSession;
    if (session == null) {
      return;
    }

    debugPrint('ProfileSyncService.syncProfile START for user=$userId');

    // Avoid attempting sync when device is offline.
    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      debugPrint('ProfileSyncService.syncProfile SKIP offline for user=$userId');
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

          // --- Trial Period Logic ---
          if (userData != null && userData['created_at'] != null) {
            debugPrint('🔍 [ProfileProvider] syncProfile fetched tier: ${userData['subscription_tier']}');
            try {
              final createdAt = DateTime.tryParse(userData['created_at'].toString());
              if (createdAt != null) {
                final appConfig = AppConfigService();
                final trialDuration = await appConfig.getInt('subscription.trial_duration_hours', defaultValue: 0);
                
                if (trialDuration > 0) {
                  final trialTier = await appConfig.getString('subscription.trial_tier_id', defaultValue: '');
                  if (trialTier.isNotEmpty) {
                    final trialEndUtc = createdAt.toUtc().add(Duration(hours: trialDuration));
                    final nowUtc = DateTime.now().toUtc();
                    if (nowUtc.isBefore(trialEndUtc)) {
                      final currentTierId = (userData['subscription_tier'] ?? 'free').toString();

                      int getSortOrder(String tierId) {
                        if (tierId == 'free' || tierId.isEmpty) return 0;
                        try {
                          final tier = SubscriptionTier.fallbacks.firstWhere((t) => t.id == tierId);
                          return tier.sortOrder;
                        } catch (_) {
                          return 0;
                        }
                      }

                      final currentSort = getSortOrder(currentTierId);
                      final trialSort = getSortOrder(trialTier);

                      DateTime? currentExpiresAtUtc;
                      final expRaw = userData['subscription_expires_at'];
                      if (expRaw is DateTime) {
                        currentExpiresAtUtc = expRaw.toUtc();
                      } else if (expRaw != null) {
                        final raw = expRaw.toString().trim();
                        if (raw.isNotEmpty) {
                          var s = raw;
                          if (s.contains(' ') && !s.contains('T')) {
                            s = s.replaceFirst(' ', 'T');
                          }
                          final tzShort = RegExp(r'([+-]\d{2})$');
                          final tzNoColon = RegExp(r'([+-]\d{2})(\d{2})$');
                          if (tzNoColon.hasMatch(s)) {
                            s = s.replaceFirstMapped(tzNoColon, (m) => '${m.group(1)}:${m.group(2)}');
                          } else if (tzShort.hasMatch(s)) {
                            s = s.replaceFirstMapped(tzShort, (m) => '${m.group(1)}:00');
                          }
                          currentExpiresAtUtc = DateTime.tryParse(s)?.toUtc();
                        }
                      }
                      final shouldPersistTrial = (trialSort > currentSort) ||
                          (currentTierId == trialTier && currentExpiresAtUtc == null);

                      if (shouldPersistTrial) {
                        try {
                          final dynamic rpcResult = await supabase.rpc(
                            'apply_revenuecat_subscription',
                            params: {
                              'p_tier': trialTier,
                              'p_expires_at': trialEndUtc.toIso8601String(),
                            },
                          );

                          Map<String, dynamic>? result;
                          if (rpcResult is Map) {
                            result = Map<String, dynamic>.from(rpcResult);
                          } else if (rpcResult is List && rpcResult.isNotEmpty && rpcResult.first is Map) {
                            result = Map<String, dynamic>.from(rpcResult.first as Map);
                          }

                          if (result != null) {
                            userData['subscription_tier'] = (result['subscription_tier'] ?? trialTier).toString();
                            userData['subscription_expires_at'] = result['subscription_expires_at'];
                          }
                        } catch (e) {
                          debugPrint('⚠️ [ProfileProvider] Trial persist failed: $e');
                        }
                      }
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint('⚠️ [ProfileProvider] Error checking trial status: $e');
            }
          }
          debugPrint('🔍 [ProfileProvider] Final tier to save: ${userData?['subscription_tier']}');
          // --------------------------

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

          DateTime? parseOptionalDateTime(dynamic v) {
            if (v == null) return null;
            if (v is DateTime) return v;
            final raw = v.toString().trim();
            if (raw.isEmpty) return null;

            DateTime? tryParse(String s) => DateTime.tryParse(s);

            final direct = tryParse(raw);
            if (direct != null) return direct;

            var s = raw;
            if (s.contains(' ') && !s.contains('T')) {
              s = s.replaceFirst(' ', 'T');
            }

            final tzShort = RegExp(r'([+-]\d{2})$');
            final tzNoColon = RegExp(r'([+-]\d{2})(\d{2})$');
            if (tzNoColon.hasMatch(s)) {
              s = s.replaceFirstMapped(
                tzNoColon,
                (m) => '${m.group(1)}:${m.group(2)}',
              );
            } else if (tzShort.hasMatch(s)) {
              s = s.replaceFirstMapped(tzShort, (m) => '${m.group(1)}:00');
            }

            return tryParse(s);
          }

          final profile = UserProfile(
            id: userData['id']?.toString() ?? '',
            name: userData['name']?.toString() ?? 'Unnamed',
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
            subscriptionExpiresAt: parseOptionalDateTime(userData['subscription_expires_at']),
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
            isVerified: (userData['is_verified'] ?? false) is bool
                ? (userData['is_verified'] ?? false) as bool
                : (userData['is_verified'] ?? false).toString().toLowerCase() == 'true',
            verificationStatus: (userData['verification_status'] ?? 'unverified').toString(),
            verificationSubmittedAt: userData['verification_submitted_at'] != null
                ? DateTime.tryParse(userData['verification_submitted_at'].toString())
                : null,
            verificationReviewedAt: userData['verification_reviewed_at'] != null
                ? DateTime.tryParse(userData['verification_reviewed_at'].toString())
                : null,
            photos: _toStringList(userData['photos']),
          );

          final localDb = ref.read(localDbProvider);
          final approvedPrimaryPhotos = _toStringList(userData['approved_primary_photos']).toSet();
          await localDb.setApprovedPrimaryPhotos(userId, approvedPrimaryPhotos);
          final previousMap = await localDb.getLocalProfile(userId);
          final previousPhotos = previousMap != null ? _toStringList(previousMap['photos']) : <String>[];
          final newPhotos = profile.photos;
          if (!listEquals(previousPhotos, newPhotos)) {
            final allPhotos = <String>{...previousPhotos, ...newPhotos};
            for (final path in allPhotos) {
              if (path.isEmpty) continue;
              StorageHelper.evictImageCache(path);
            }
          }
          final localMap = profile.toMap();
          localMap['_cached_at'] = DateTime.now().toIso8601String();
          await localDb.saveLocalProfile(userId, localMap);

          // Success — exit retry loop
          final totalDuration = DateTime.now().difference(startAll).inMilliseconds;
          debugPrint('ProfileSyncService.syncProfile SUCCESS for user=$userId total=${totalDuration}ms');
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

class BasicFieldAdminReview {
  final String id;
  final String status;
  final String reviewerNote;
  final DateTime? reviewedAt;
  final DateTime? updatedAt;
  final DateTime? userSeenAt;

  const BasicFieldAdminReview({
    required this.id,
    required this.status,
    required this.reviewerNote,
    required this.reviewedAt,
    required this.updatedAt,
    required this.userSeenAt,
  });

  static DateTime? _tryDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  factory BasicFieldAdminReview.fromMap(Map<String, dynamic> row) {
    return BasicFieldAdminReview(
      id: (row['id'] ?? '').toString(),
      status: (row['status'] ?? 'pending').toString(),
      reviewerNote: (row['reviewer_note'] ?? '').toString(),
      reviewedAt: _tryDate(row['reviewed_at']),
      updatedAt: _tryDate(row['updated_at']),
      userSeenAt: _tryDate(row['user_seen_at']),
    );
  }
}

final basicFieldAdminReviewsProvider =
    StreamProvider.family<Map<String, BasicFieldAdminReview>, String>((ref, userId) {
  List<String> toStringList(dynamic v) {
    if (v == null) return const [];
    if (v is List) return v.map((e) => e.toString()).where((s) => s.trim().isNotEmpty).toList(growable: false);
    return const [];
  }

  final stream = supabase
      .from('profile_edit_requests')
      .stream(primaryKey: const ['id'])
      .eq('user_id', userId)
      .order('updated_at', ascending: false);

  return stream.map((rows) {
    final keys = const ['name', 'date_of_birth', 'gender'];
    final out = <String, BasicFieldAdminReview>{};
    final latestAt = <String, DateTime>{};

    for (final raw in rows) {
      final row = Map<String, dynamic>.from(raw);
      final requested = toStringList(row['requested_fields']);
      if (requested.isEmpty) continue;
      final review = BasicFieldAdminReview.fromMap(row);
      if (review.status != 'pending' && review.status != 'approved' && review.status != 'rejected') continue;
      final when = review.updatedAt ?? review.reviewedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      for (final k in keys) {
        if (!requested.contains(k)) continue;
        final prev = latestAt[k];
        if (prev == null || when.isAfter(prev)) {
          latestAt[k] = when;
          out[k] = review;
        }
      }
    }

    return out;
  });
});

/// --- userProfileProvider ---------------------------------------------------
final Map<String, DateTime> _profileSyncAttemptAt = {};
final Map<String, DateTime> _otherUserProfileRefreshAttemptAt = {};

bool _shouldAttemptProfileSync(String userId, Duration minInterval) {
  final now = DateTime.now();
  final last = _profileSyncAttemptAt[userId];
  if (last != null && now.difference(last) < minInterval) return false;
  _profileSyncAttemptAt[userId] = now;
  return true;
}

bool _shouldAttemptOtherUserProfileRefresh(String userId, Duration minInterval) {
  final now = DateTime.now();
  final last = _otherUserProfileRefreshAttemptAt[userId];
  if (last != null && now.difference(last) < minInterval) return false;
  _otherUserProfileRefreshAttemptAt[userId] = now;
  return true;
}

final userProfileProvider = StreamProvider.family<UserProfile?, String>((ref, userId) {
  final localDb = ref.watch(localDbProvider);

  try {
    ResumeDiagnostics.log('userProfileProvider created for user=$userId');
    ref.onDispose(() => ResumeDiagnostics.log('userProfileProvider disposed for user=$userId'));
  } catch (_) {}

  // Set up realtime subscription for profile changes
  final subscription = supabase
      .channel('user_profile_$userId')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'users',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: userId),
        callback: (payload) {
          final newRecord = payload.newRecord as Map<String, dynamic>?;
          if (newRecord != null && (
            newRecord.containsKey('preferred_language') ||
            newRecord.containsKey('match_radius_default') ||
            newRecord.containsKey('gps_interval_default') ||
            newRecord.containsKey('smart_gps_throttling_enabled') ||
            newRecord.containsKey('shared_event_matching_enabled') ||
            newRecord.containsKey('shared_movement_matching_enabled') ||
            newRecord.containsKey('gender_preferences') ||
            newRecord.containsKey('age_preferences') ||
            newRecord.containsKey('strict_gender_age_enforcement') ||
            newRecord.containsKey('bio') ||
            newRecord.containsKey('photos') ||
            newRecord.containsKey('gender') ||
            newRecord.containsKey('date_of_birth') ||
            newRecord.containsKey('name') ||
            newRecord.containsKey('active_modes') ||
            newRecord.containsKey('languages_known') ||
            newRecord.containsKey('subscription_tier') ||
            newRecord.containsKey('subscription_expires_at') ||
            newRecord.containsKey('is_verified') ||
            newRecord.containsKey('verification_status')
          )) {
            unawaited(ref.read(profileSyncProvider).syncProfile(userId));
          }
        },
      )
      .subscribe();

  ref.onDispose(() => subscription.unsubscribe());

  final localStream = localDb.watchLocalProfile(userId);
  return localStream.map((localProfileMap) {
    if (localProfileMap == null) {
      unawaited(() {
        debugPrint('[ProfileProvider] userProfileProvider triggered syncProfile for user=$userId');
        return ref.read(profileSyncProvider).syncProfile(userId);
      }());
      return null;
    }
    debugPrint('[ProfileProvider] userProfileProvider has local data for user=$userId');

    final hasSubscriptionExpiryFields = localProfileMap.containsKey('subscription_expires_at') ||
        localProfileMap.containsKey('subscriptionExpiresAt');
    if (!hasSubscriptionExpiryFields) {
      unawaited(() {
        debugPrint('[ProfileProvider] userProfileProvider missing subscription expiry fields; syncing for user=$userId');
        return ref.read(profileSyncProvider).syncProfile(userId);
      }());
    }

    final currentUserId = supabase.auth.currentUser?.id;
    final isOtherUser = currentUserId != null && currentUserId.isNotEmpty && currentUserId != userId;
    if (isOtherUser) {
      DateTime? cachedAt;
      final rawCachedAt = localProfileMap['_cached_at'] ?? localProfileMap['cached_at'];
      if (rawCachedAt != null) {
        cachedAt = DateTime.tryParse(rawCachedAt.toString());
      }
      final isStale = cachedAt == null || DateTime.now().difference(cachedAt) > const Duration(minutes: 1);
      if (isStale && _shouldAttemptProfileSync(userId, const Duration(seconds: 30))) {
        unawaited(() {
          debugPrint('[ProfileProvider] userProfileProvider stale other-user cache; syncing for user=$userId');
          return ref.read(profileSyncProvider).syncProfile(userId);
        }());
      }
    }

    return UserProfile.fromMap(localProfileMap);
  });
});

/// --- otherUserProfileProvider ----------------------------------------------
/// Fetches and caches other users' profiles for better performance
final otherUserProfileProvider = FutureProvider.family<UserProfile?, String>((ref, userId) async {
  if (userId.isEmpty) return null;

  final localDb = ref.read(localDbProvider);

  try {
    // Try cached profile first
    final cachedProfileWithMeta = await localDb.getOtherUserProfileWithCacheMeta(userId);
    if (cachedProfileWithMeta != null) {
      if (kIsWeb) {
        debugPrint('🔍 [WEB] otherUserProfileProvider - Using cached profile for: $userId');
      }
      DateTime? cachedAt;
      final rawCachedAt = cachedProfileWithMeta['cached_at'];
      if (rawCachedAt != null) {
        cachedAt = DateTime.tryParse(rawCachedAt.toString());
      }

      final clean = Map<String, dynamic>.from(cachedProfileWithMeta)..remove('cached_at');
      final cached = UserProfile.fromMap(clean);

      final isStale = cachedAt == null || DateTime.now().difference(cachedAt) > const Duration(minutes: 1);
      if (isStale && _shouldAttemptOtherUserProfileRefresh(userId, const Duration(seconds: 30))) {
        unawaited(() async {
          try {
            final profileResponses = await supabase
                .from('user_profiles')
                .select('*')
                .eq('user_id', userId)
                .order('created_at', ascending: false)
                .limit(1);

            Map<String, dynamic> profileRow = {};
            if (profileResponses.isNotEmpty) {
              profileRow = Map<String, dynamic>.from(profileResponses.first as Map);
            }

            final userRow = await supabase
                .from('users')
                .select('id,name,date_of_birth,gender,preferred_language,active_modes,languages_known,subscription_tier,subscription_expires_at,is_profile_complete,match_radius_default,gps_interval_default,smart_gps_throttling_enabled,shared_event_matching_enabled,shared_movement_matching_enabled,editable_profile_fields,gender_preferences,age_preferences,strict_gender_age_enforcement,bio,photos,approved_primary_photos,is_verified,verification_status,verification_submitted_at,verification_reviewed_at,referral_code,credits')
                .eq('id', userId)
                .maybeSingle();
            if (userRow == null) return;

            final response = <String, dynamic>{...userRow, ...profileRow};
            await localDb.saveOtherUserProfile(userId, response);
            if (ref.mounted) {
              ref.invalidateSelf();
            }
          } catch (_) {}
        }());
      }

      return cached;
    }

    if (kIsWeb) {
      debugPrint('🔍 [WEB] otherUserProfileProvider - Fetching fresh profile for: $userId');
    }

    // Fetch from Supabase - get both profile and user data
    // Handle case where there might be multiple profiles for a user (take the most recent)
    final profileResponses = await supabase
        .from('user_profiles')
        .select('*')
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(1);

    if (profileResponses.isEmpty) {
      // No aggregated profile row found; attempt to fetch the user record directly
      final userResponseOnly = await supabase
          .from('users')
          .select('id, name, photos')
          .eq('id', userId)
          .maybeSingle();

      if (userResponseOnly == null) {
        throw Exception('No profile or user found for user $userId');
      }

      // Build a minimal response so UserProfile.fromMap can construct a usable object
      final minimalResponse = {
        'profile_data': {},
        'users': userResponseOnly,
      };

      final userProfile = UserProfile.fromMap(minimalResponse);
      await localDb.saveOtherUserProfile(userId, minimalResponse);
      return userProfile;
    }

    final profileResponse = profileResponses.first;

    final userResponse = await supabase
        .from('users')
        .select('id, name, photos')
        .eq('id', userId)
        .single();

    // Combine the data
    // Merge the user row fields at top-level so UserProfile.fromMap can find photos, name, languages etc.
    final response = {
      ...profileResponse,
      ...Map<String, dynamic>.from(userResponse),
      // Keep the original user_profiles' profile_data nested so intent-specific interests remain available
    };

    // Debug: log available keys to help diagnose missing fields in the UI
    try {
      debugPrint('🔍 otherUserProfileProvider response keys for $userId: ${response.keys.toList()}');
    } catch (_) {}

    // Convert to UserProfile format and cache
    final userProfile = UserProfile.fromMap(response);
    await localDb.saveOtherUserProfile(userId, response);

    return userProfile;
  } catch (e) {
    debugPrint('Error fetching other user profile for $userId: $e');
    return null;
  }
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
  final Set<String> _wizardUploadedPhotoPaths = <String>{};

  @override
  AsyncValue<UserProfile?> build(String userId) {
    state = const AsyncLoading();
    ref.listen<AsyncValue<UserProfile?>>(userProfileProvider(userId), (previous, next) {
      final remoteProfile = next.asData?.value;
      if (remoteProfile == null) return;
      UserProfile? currentProfile;
      try {
        currentProfile = state.value;
      } catch (_) {
        currentProfile = null;
      }
      if (currentProfile == null) {
        state = AsyncData(remoteProfile.copyWith());
        return;
      }

      final shouldApplyRealtimeSettings =
          currentProfile.matchRadiusDefault != remoteProfile.matchRadiusDefault ||
          currentProfile.gpsIntervalDefault != remoteProfile.gpsIntervalDefault ||
          currentProfile.smartGpsThrottlingEnabled != remoteProfile.smartGpsThrottlingEnabled ||
          currentProfile.sharedEventMatchingEnabled != remoteProfile.sharedEventMatchingEnabled ||
          currentProfile.sharedMovementMatchingEnabled != remoteProfile.sharedMovementMatchingEnabled;
      if (!shouldApplyRealtimeSettings) return;

      state = AsyncData(
        currentProfile.copyWith(
          matchRadiusDefault: remoteProfile.matchRadiusDefault,
          gpsIntervalDefault: remoteProfile.gpsIntervalDefault,
          smartGpsThrottlingEnabled: remoteProfile.smartGpsThrottlingEnabled,
          sharedEventMatchingEnabled: remoteProfile.sharedEventMatchingEnabled,
          sharedMovementMatchingEnabled: remoteProfile.sharedMovementMatchingEnabled,
        ),
      );
    }, fireImmediately: true);
    return state;
  }

  Future<void> _cleanupWizardUploadedPhotosNotIn(Set<String> keep) async {
    final toDelete = _wizardUploadedPhotoPaths.where((p) => p.isNotEmpty && !keep.contains(p)).toList();
    for (final path in toDelete) {
      try {
        await _deleteStorageObject(path);
      } catch (_) {}
      StorageHelper.evict(path);
      _wizardUploadedPhotoPaths.remove(path);
    }
  }

  Future<Set<String>> _fetchApprovedPrimaryPhotosFromSupabase() async {
    try {
      final resp = await supabase
          .from('users')
          .select('approved_primary_photos')
          .eq('id', userId)
          .maybeSingle();
      if (resp == null) return <String>{};
      return _toStringList(resp['approved_primary_photos']).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<String> _sanitizePrimaryPhoto({
    required String photoPath,
    required Map<String, dynamic> faceBox,
    required List<Map<String, dynamic>> textBoxes,
  }) async {
    String? signed;
    try {
      signed = await StorageHelper.getSignedUrl(photoPath, ttlSeconds: 600);
    } catch (_) {
      signed = null;
    }
    if (signed == null || signed.isEmpty) {
      throw Exception('Failed to download photo.');
    }

    final resp = await http.get(Uri.parse(signed));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Failed to download photo.');
    }
    final bytes = resp.bodyBytes;

    var decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw Exception('Failed to decode photo.');
    }
    decoded = img.bakeOrientation(decoded);

    double toD(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    final fx = toD(faceBox['x']).clamp(0, 1);
    final fy = toD(faceBox['y']).clamp(0, 1);
    final fw = toD(faceBox['w']).clamp(0, 1);
    final fh = toD(faceBox['h']).clamp(0, 1);

    final wPx = decoded.width.toDouble();
    final hPx = decoded.height.toDouble();
    final faceW = fw * wPx;
    final faceH = fh * hPx;
    final cx = (fx * wPx) + faceW / 2;
    final cy = (fy * hPx) + faceH / 2;

    final target = math.max(faceW, faceH) * 2.0;
    final minTarget = math.min(wPx, hPx) * 0.45;
    final cropSize = math.max(target, minTarget);

    var cropLeft = (cx - cropSize / 2).round();
    var cropTop = (cy - cropSize / 2).round();
    var cropW = cropSize.round();
    var cropH = cropSize.round();

    if (cropW > decoded.width) cropW = decoded.width;
    if (cropH > decoded.height) cropH = decoded.height;
    if (cropLeft < 0) cropLeft = 0;
    if (cropTop < 0) cropTop = 0;
    if (cropLeft + cropW > decoded.width) cropLeft = decoded.width - cropW;
    if (cropTop + cropH > decoded.height) cropTop = decoded.height - cropH;

    var cropped = img.copyCrop(
      decoded,
      x: cropLeft,
      y: cropTop,
      width: cropW,
      height: cropH,
    );

    for (final tb in textBoxes) {
      final tx = toD(tb['x']).clamp(0, 1);
      final ty = toD(tb['y']).clamp(0, 1);
      final tw = toD(tb['w']).clamp(0, 1);
      final th = toD(tb['h']).clamp(0, 1);
      if (tw <= 0 || th <= 0) continue;

      final left = (tx * wPx).round();
      final top = (ty * hPx).round();
      final width = (tw * wPx).round();
      final height = (th * hPx).round();

      final interLeft = math.max(left, cropLeft);
      final interTop = math.max(top, cropTop);
      final interRight = math.min(left + width, cropLeft + cropW);
      final interBottom = math.min(top + height, cropTop + cropH);
      final interW = interRight - interLeft;
      final interH = interBottom - interTop;
      if (interW <= 2 || interH <= 2) continue;

      final rx = interLeft - cropLeft;
      final ry = interTop - cropTop;
      final rw = interW;
      final rh = interH;

      final region = img.copyCrop(cropped, x: rx, y: ry, width: rw, height: rh);
      final downW = math.max(1, (rw / 10).round());
      final downH = math.max(1, (rh / 10).round());
      final down = img.copyResize(
        region,
        width: downW,
        height: downH,
        interpolation: img.Interpolation.average,
      );
      final up = img.copyResize(
        down,
        width: rw,
        height: rh,
        interpolation: img.Interpolation.nearest,
      );
      img.compositeImage(cropped, up, dstX: rx, dstY: ry, blend: img.BlendMode.direct);
    }

    final outBytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 90));

    final uploader = ref.read(profileEditRequestServiceProvider);
    final uuid = const Uuid().v4();
    final newPath = '$userId/${DateTime.now().millisecondsSinceEpoch}_clean_$uuid.jpg';
    final uploaded = await uploader.uploadBytesToStorage(newPath, outBytes, public: false);
    if (uploaded == null || uploaded.isEmpty) {
      throw Exception('Photo upload failed.');
    }

    try {
      await _deleteStorageObject(photoPath);
    } catch (_) {}

    _wizardUploadedPhotoPaths.remove(photoPath);
    _wizardUploadedPhotoPaths.add(uploaded);

    StorageHelper.evict(photoPath);
    StorageHelper.evict(uploaded);
    return uploaded;
  }

  Future<String> _ensurePrimaryPhotoAllowed(String photoPath, {int sanitizePass = 0}) async {
    try {
      final localDb = ref.read(localDbProvider);
      var approved = await localDb.loadApprovedPrimaryPhotos(userId);
      if (!approved.contains(photoPath)) {
        final remoteApproved = await _fetchApprovedPrimaryPhotosFromSupabase();
        if (remoteApproved.isNotEmpty) {
          approved = {...approved, ...remoteApproved};
          await localDb.setApprovedPrimaryPhotos(userId, approved);
        }
      }
      if (approved.contains(photoPath)) return photoPath;

      final resp = await Supabase.instance.client.functions.invoke(
        'validate-primary-photo',
        body: {'photoPath': photoPath},
      );

      if (resp.status != 200) {
        final locale = ref.read(localizationProvider);
        throw Exception(locale.getString('primaryPhotoVerificationErrorSystem'));
      }

      dynamic data = resp.data;
      if (data is String && data.trim().isNotEmpty) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      final allow = data is Map && data['allow'] == true;
      final reasonCode = data is Map && data['reasonCode'] is String ? data['reasonCode'] as String : null;
      final action = data is Map && data['action'] is String ? (data['action'] as String) : null;

      if (action == 'SANITIZE' && !allow) {
        if (sanitizePass >= 1) {
          final locale = ref.read(localizationProvider);
          throw Exception(locale.getString('primaryPhotoVerificationErrorBadContent'));
        }

        final faceBox = data is Map && data['faceBox'] is Map ? Map<String, dynamic>.from(data['faceBox'] as Map) : null;
        final textBoxes = data is Map && data['textBoxes'] is List
            ? (data['textBoxes'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];

        if (faceBox == null || faceBox.isEmpty) {
          final locale = ref.read(localizationProvider);
          throw Exception(locale.getString('primaryPhotoVerificationErrorGeneral'));
        }

        String sanitizedPath;
        try {
          sanitizedPath = await _sanitizePrimaryPhoto(
            photoPath: photoPath,
            faceBox: faceBox,
            textBoxes: textBoxes,
          );
        } catch (_) {
          final locale = ref.read(localizationProvider);
          throw Exception(locale.getString('primaryPhotoVerificationErrorSystem'));
        }

        return await _ensurePrimaryPhotoAllowed(sanitizedPath, sanitizePass: sanitizePass + 1);
      }
      
      if (!allow) {
        final locale = ref.read(localizationProvider);
        String errorMessage;
        
        switch (reasonCode) {
          case 'NO_PERSON':
            errorMessage = locale.getString('primaryPhotoVerificationErrorNoPerson');
            break;
          case 'FACE_NOT_VISIBLE':
            errorMessage = locale.getString('primaryPhotoVerificationErrorFaceNotVisible');
            break;
          case 'BAD_CONTENT':
            errorMessage = locale.getString('primaryPhotoVerificationErrorBadContent');
            break;
          case 'MULTIPLE_PEOPLE':
            errorMessage = locale.getString('primaryPhotoVerificationErrorMultipleFaces');
            break;
          case 'BODY_SHOT':
            errorMessage = locale.getString('primaryPhotoVerificationErrorBodyNotAllowed');
            break;
          case 'GENERAL_ERROR':
          default:
             // If we have a message from backend, we could use it, but user wants localized.
             // If reasonCode is missing (old backend), fall back to general error.
             errorMessage = locale.getString('primaryPhotoVerificationErrorGeneral');
             break;
        }
        
        // If the key was missing in translations, locale.getString returns the key or default.
        // We should ensure these keys have defaults in LocaleProvider or in the DB.
        
        throw Exception(errorMessage);
      }
      approved.add(photoPath);
      await localDb.setApprovedPrimaryPhotos(userId, approved);
      return photoPath;
    } catch (e) {
      if (e is Exception) rethrow;
      final locale = ref.read(localizationProvider);
      throw Exception(locale.getString('primaryPhotoVerificationErrorSystem'));
    }
  }

  Future<void> ensurePrimaryPhotoAllowedForWizard(String photoPath) async {
    final finalPath = await _ensurePrimaryPhotoAllowed(photoPath);
    if (finalPath == photoPath) return;
    final current = state.value;
    if (current == null) return;
    final photos = List<String>.from(current.photos);
    final idx = photos.indexOf(photoPath);
    if (idx < 0) return;
    photos[idx] = finalPath;
    state = AsyncData(current.copyWith(photos: photos));
    await saveWizardDraft();
  }

  Future<void> loadInitialProfile({bool applyWizardDraft = false}) async {
    try {
      // Always reload fresh data to ensure we have the latest from server
      state = const AsyncLoading();
      final initialProfile = await ref.read(userProfileProvider(userId).future);
      if (initialProfile != null) {
        state = AsyncData(initialProfile.copyWith());
        if (applyWizardDraft) {
          await _applyWizardDraftIfPresent();
        }
        final p = state.value;
        if (p != null) {
          unawaited(_prewarmSignedUrls(p.photos));
        }
      } else {
        await ref.read(profileSyncProvider).syncProfile(userId);
        final reloaded = await ref.read(userProfileProvider(userId).future);
        if (reloaded != null) {
          state = AsyncData(reloaded.copyWith());
          if (applyWizardDraft) {
            await _applyWizardDraftIfPresent();
          }
          final p = state.value;
          if (p != null) {
            unawaited(_prewarmSignedUrls(p.photos));
          }
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

  Future<void> saveWizardDraft() async {
    final p = state.value;
    if (p == null) return;
    final localDb = ref.read(localDbProvider);
    final draftData = p.toMap();
    draftData['_wizard_uploaded_photo_paths'] = _wizardUploadedPhotoPaths.toList();
    await localDb.saveProfileWizardDraft(userId, draftData);
  }

  Future<void> clearWizardDraft() async {
    final localDb = ref.read(localDbProvider);
    final current = state.value;
    final keep = current == null ? const <String>{} : current.photos.toSet();
    final toDelete = _wizardUploadedPhotoPaths.where((p) => p.isNotEmpty && !keep.contains(p)).toList();
    for (final path in toDelete) {
      try {
        await _deleteStorageObject(path);
      } catch (_) {}
      StorageHelper.evict(path);
      _wizardUploadedPhotoPaths.remove(path);
    }
    _wizardUploadedPhotoPaths.clear();
    await localDb.clearProfileWizardDraft(userId);
  }

  Future<void> _applyWizardDraftIfPresent() async {
    final localDb = ref.read(localDbProvider);
    final draft = await localDb.loadProfileWizardDraft(userId);
    if (draft == null) return;
    final normalized = Map<String, dynamic>.from(draft);
    normalized['id'] = userId;
    _wizardUploadedPhotoPaths
      ..clear()
      ..addAll(_toStringList(draft['_wizard_uploaded_photo_paths']));
    final draftProfile = UserProfile.fromMap(normalized);
    final base = state.value;
    if (base == null) {
      state = AsyncData(draftProfile.copyWith());
      return;
    }

    String photoId(String src) => StorageHelper.cacheKeyForSource(src);

    final baseIds = base.photos.map(photoId).where((s) => s.isNotEmpty).toList();
    final draftIds = draftProfile.photos.map(photoId).where((s) => s.isNotEmpty).toList();

    final baseIdSet = baseIds.toSet();
    final draftIdSet = draftIds.toSet();

    final keptBase = <String>[];
    for (final p in base.photos) {
      final id = photoId(p);
      if (id.isEmpty) continue;
      if (draftIdSet.contains(id)) {
        keptBase.add(p);
      }
    }

    final draftOnly = <String>[];
    final seenDraftOnly = <String>{};
    for (final p in draftProfile.photos) {
      final id = photoId(p);
      if (id.isEmpty) continue;
      if (!baseIdSet.contains(id) && !seenDraftOnly.contains(id)) {
        seenDraftOnly.add(id);
        draftOnly.add(p);
      }
    }

    final mergedPhotos = [...keptBase, ...draftOnly];

    final merged = base.copyWith(
      name: draftProfile.name,
      dateOfBirth: draftProfile.dateOfBirth,
      gender: draftProfile.gender,
      preferredLanguage: draftProfile.preferredLanguage,
      activeModes: draftProfile.activeModes,
      subIntents: draftProfile.subIntents,
      interests: draftProfile.interests,
      languagesKnown: draftProfile.languagesKnown,
      matchRadiusDefault: draftProfile.matchRadiusDefault,
      gpsIntervalDefault: draftProfile.gpsIntervalDefault,
      smartGpsThrottlingEnabled: draftProfile.smartGpsThrottlingEnabled,
      sharedEventMatchingEnabled: draftProfile.sharedEventMatchingEnabled,
      sharedMovementMatchingEnabled: draftProfile.sharedMovementMatchingEnabled,
      genderPreferences: draftProfile.genderPreferences,
      agePreferences: draftProfile.agePreferences,
      strictGenderAgeEnforcement: draftProfile.strictGenderAgeEnforcement,
      bio: draftProfile.bio,
      photos: mergedPhotos,
    );

    state = AsyncData(merged);
  }

  Future<void> _prewarmSignedUrls(List<String> photos) async {
    try {
      for (final src in photos) {
        if (src.isEmpty) continue;
        try {
          await StorageHelper.getSignedUrl(src);
        } catch (_) {}
      }
    } catch (_) {}
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
    state = AsyncData(state.value!.copyWith(name: name));
  }

  void updateDob(DateTime dob) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(dateOfBirth: dob));
  }

  void updateGender(String? gender) {
    if (!state.hasValue || state.value == null) return;
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
    final normalizedAgePreferences = <String, List<double>>{};
    for (final entry in agePreferences.entries) {
      final values = entry.value;
      if (values.isEmpty) continue;
      var minAge = values.first.round();
      var maxAge = (values.length > 1 ? values[1] : values.first).round();
      minAge = minAge.clamp(18, 100);
      maxAge = maxAge.clamp(18, 100);
      if (minAge > maxAge) {
        final tmp = minAge;
        minAge = maxAge;
        maxAge = tmp;
      }
      normalizedAgePreferences[entry.key] = [minAge.toDouble(), maxAge.toDouble()];
    }
    final updatedProfile = state.value!.copyWith(
      genderPreferences: genderPreferences,
      agePreferences: normalizedAgePreferences,
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
        'age_preferences': normalizedAgePreferences.isNotEmpty ? normalizedAgePreferences : null,
        'strict_gender_age_enforcement': strictEnforcement,
      }).eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {
          'gender_preferences': genderPreferences.isNotEmpty ? genderPreferences : null,
          'age_preferences': normalizedAgePreferences.isNotEmpty ? normalizedAgePreferences : null,
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
  Future<void> addPhotoFromBytesDraft(Uint8List bytes) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (before.photos.length >= 5) {
      throw Exception('Maximum 5 photos allowed.');
    }

    final uploader = ref.read(profileEditRequestServiceProvider);
    final fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final uploadedObjectPath = await uploader.uploadBytesToStorage(fileName, bytes, public: false);
    if (uploadedObjectPath == null) {
      throw Exception('Photo upload failed.');
    }
    var uploadedPath = uploadedObjectPath;
    _wizardUploadedPhotoPaths.add(uploadedPath);

    if (before.photos.isEmpty) {
      try {
        uploadedPath = await _ensurePrimaryPhotoAllowed(uploadedPath);
      } catch (e) {
        await _cleanupWizardUploadedPhotosNotIn(before.photos.toSet());
        rethrow;
      }
    }

    final newPhotos = List<String>.from(before.photos)..add(uploadedPath);
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);
    await saveWizardDraft();
    StorageHelper.evict(uploadedPath);
  }

  Future<void> removePhotoAtDraft(int index) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (index < 0 || index >= before.photos.length) return;

    final removedPath = before.photos[index];
    final newPhotos = List<String>.from(before.photos)..removeAt(index);
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = newPhotos.isNotEmpty ? newPhotos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        final verifiedPrimary = await _ensurePrimaryPhotoAllowed(newPrimary);
        if (verifiedPrimary != newPrimary && newPhotos.isNotEmpty) {
          newPhotos[0] = verifiedPrimary;
          state = AsyncData(before.copyWith(photos: newPhotos));
        }
      } catch (e) {
        state = AsyncData(before);
        rethrow;
      }
    }

    await saveWizardDraft();
    if (_wizardUploadedPhotoPaths.contains(removedPath)) {
      try {
        await _deleteStorageObject(removedPath);
      } catch (_) {}
      StorageHelper.evict(removedPath);
      _wizardUploadedPhotoPaths.remove(removedPath);
      await saveWizardDraft();
    }
  }

  Future<void> replacePhotoAtIndexDraft(int index, {Uint8List? bytes, String? url}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (index < 0 || index >= before.photos.length) return;

    final newPhotos = List<String>.from(before.photos);
    final oldPath = newPhotos[index];
    String? newObjectPath = url;
    final shouldDeleteNewOnFailure = bytes != null;
    if (bytes != null) {
      final uploader = ref.read(profileEditRequestServiceProvider);
      final fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final uploadedObjectPath = await uploader.uploadBytesToStorage(fileName, bytes, public: false);
      if (uploadedObjectPath == null) {
        throw Exception('Photo upload failed.');
      }
      newObjectPath = uploadedObjectPath;
      _wizardUploadedPhotoPaths.add(uploadedObjectPath);
    }

    final initialNewPath = newObjectPath;
    if (initialNewPath == null) return;
    var newPath = initialNewPath;

    if (index == 0) {
      final localDb = ref.read(localDbProvider);
      var approved = await localDb.loadApprovedPrimaryPhotos(userId);
      if (!approved.contains(oldPath)) {
        final remoteApproved = await _fetchApprovedPrimaryPhotosFromSupabase();
        if (remoteApproved.isNotEmpty) {
          approved = {...approved, ...remoteApproved};
          await localDb.setApprovedPrimaryPhotos(userId, approved);
        }
      }

      final oldWasApproved = approved.contains(oldPath);
      try {
        final verifiedPath = await _ensurePrimaryPhotoAllowed(newPath);
        if (verifiedPath != newPath && shouldDeleteNewOnFailure) {
          try {
            await _deleteStorageObject(newPath);
          } catch (_) {}
          _wizardUploadedPhotoPaths.remove(newPath);
        }
        newPath = verifiedPath;
        if (oldWasApproved) {
          approved.remove(oldPath);
        }
        approved.add(newPath);
        await localDb.setApprovedPrimaryPhotos(userId, approved);
      } catch (e) {
        if (shouldDeleteNewOnFailure) {
          await _cleanupWizardUploadedPhotosNotIn(before.photos.toSet());
        }
        rethrow;
      }
    }

    newPhotos[index] = newPath;
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);
    await saveWizardDraft();

    if (!newPath.startsWith('http://') && !newPath.startsWith('https://')) {
      StorageHelper.evict(newPath);
    }

    if (_wizardUploadedPhotoPaths.contains(oldPath) && oldPath != newPath) {
      try {
        await _deleteStorageObject(oldPath);
      } catch (_) {}
      StorageHelper.evict(oldPath);
      _wizardUploadedPhotoPaths.remove(oldPath);
      await saveWizardDraft();
    }
  }

  Future<void> reorderPhotosDraft(int oldIndex, int newIndex) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    final photos = List<String>.from(before.photos);
    if (oldIndex < 0 || oldIndex >= photos.length || newIndex < 0 || newIndex >= photos.length) return;
    final item = photos.removeAt(oldIndex);
    photos.insert(newIndex, item);
    var updated = before.copyWith(photos: photos);
    state = AsyncData(updated);

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = photos.isNotEmpty ? photos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        final verifiedPrimary = await _ensurePrimaryPhotoAllowed(newPrimary);
        if (verifiedPrimary != newPrimary && photos.isNotEmpty) {
          photos[0] = verifiedPrimary;
          updated = before.copyWith(photos: photos);
          state = AsyncData(updated);
        }
      } catch (e) {
        state = AsyncData(before);
        rethrow;
      }
    }

    await saveWizardDraft();
  }

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
    var uploadedPath = uploadedObjectPath;

    if (before.photos.isEmpty) {
      try {
        uploadedPath = await _ensurePrimaryPhotoAllowed(uploadedPath);
      } catch (e) {
        try {
          await _deleteStorageObject(uploadedPath);
        } catch (_) {}
        rethrow;
      }
    }

    final newPhotos = List<String>.from(before.photos)..add(uploadedPath);
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
        StorageHelper.evict(uploadedPath);
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
        await localDb.removeApprovedPrimaryPhoto(userId, removedPath);
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
      await localDb.removeApprovedPrimaryPhoto(userId, removedPath);
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
    final shouldDeleteNewOnFailure = bytes != null;
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

    final initialNewPath = newObjectPath;
    if (initialNewPath == null) return;
    var newPath = initialNewPath;

    if (index == 0) {
      final localDb = ref.read(localDbProvider);
      var approved = await localDb.loadApprovedPrimaryPhotos(userId);
      if (!approved.contains(oldPath)) {
        final remoteApproved = await _fetchApprovedPrimaryPhotosFromSupabase();
        if (remoteApproved.isNotEmpty) {
          approved = {...approved, ...remoteApproved};
          await localDb.setApprovedPrimaryPhotos(userId, approved);
        }
      }

      try {
        final verifiedPath = await _ensurePrimaryPhotoAllowed(newPath);
        if (verifiedPath != newPath && shouldDeleteNewOnFailure) {
          try {
            await _deleteStorageObject(newPath);
          } catch (_) {}
        }
        newPath = verifiedPath;
        approved.remove(oldPath);
        approved.add(newPath);
        await localDb.setApprovedPrimaryPhotos(userId, approved);
      } catch (e) {
        if (shouldDeleteNewOnFailure) {
          try {
            await _deleteStorageObject(newPath);
          } catch (_) {}
        }
        rethrow;
      }
    }

    newPhotos[index] = newPath;
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        await supabase.from('users').update({'photos': newPhotos}).eq('id', userId);
        // Delete the old storage object from Supabase storage
        await _deleteStorageObject(oldPath);
        await localDb.removeApprovedPrimaryPhoto(userId, oldPath);
        await localDb.saveLocalProfile(userId, updated.toMap());
        // Evict old + new cache so SignedImage regenerates signed URLs
        if (!oldPath.startsWith('http://') && !oldPath.startsWith('https://')) {
          StorageHelper.evict(oldPath);
        }
        if (!newPath.startsWith('http://') && !newPath.startsWith('https://')) {
          StorageHelper.evict(newPath);
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
        await localDb.removeApprovedPrimaryPhoto(userId, oldPath);
        if (!oldPath.startsWith('http://') && !oldPath.startsWith('https://')) {
          StorageHelper.evict(oldPath);
        }
        if (!newPath.startsWith('http://') && !newPath.startsWith('https://')) {
          StorageHelper.evict(newPath);
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

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = photos.isNotEmpty ? photos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        final verifiedPrimary = await _ensurePrimaryPhotoAllowed(newPrimary);
        if (verifiedPrimary != newPrimary && photos.isNotEmpty) {
          photos[0] = verifiedPrimary;
          state = AsyncData(before.copyWith(photos: photos));
        }
      } catch (e) {
        state = AsyncData(before);
        rethrow;
      }
    }

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
      var localProfile = currentState.copyWith(
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

      try {
        final updatedRow = await supabase.from('users').select('editable_profile_fields').eq('id', userId).maybeSingle();
        if (updatedRow != null) {
          final fields = _toStringList(updatedRow['editable_profile_fields']);
          localProfile = localProfile.copyWith(editableProfileFields: fields);
          await localDb.saveLocalProfile(userId, localProfile.toMap());
          ref.invalidate(userProfileProvider(userId));
        }
      } catch (_) {}

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

      // Check referral completion
      if (markComplete) {
        unawaited(ref.read(referralServiceProvider).completeReferral(userId));
      }

      if (ref.mounted) {
        state = AsyncData(localProfile);
      }
      return true;
    } catch (e, st) {
      if (ref.mounted) {
        if (e is PostgrestException) {
          final msg = e.message.toLowerCase();
          if (msg.contains('basic_details_update_not_allowed')) {
            final locale = ref.read(localizationProvider);
            state = AsyncError(locale.getString('profileEditBasicDetailsLocked'), st);
            return false;
          }
        }
        state = AsyncError(e, st);
      }
      return false;
    }
  }
}
