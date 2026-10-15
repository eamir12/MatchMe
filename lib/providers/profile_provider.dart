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
import 'package:flutter_riverpod/misc.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/profile_request_service.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/models/subscription_tier.dart';
import 'package:matchme/models/photo_moderation_rejection.dart';
import 'package:matchme/providers/visibility_provider.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/connectivity_provider.dart';
import 'package:matchme/providers/home_providers.dart'
    show dashboardStatsProvider, warmDashboardStatsForUser;
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/utils/profile_sync_result.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/services/referral_service.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/photo_prescreen_service.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

part 'profile_provider.g.dart';

final supabase = Supabase.instance.client;

/// Translates a profile bio into the viewer's current UI language when needed.
/// Gender-aware: [speakerGender] is the profile owner's gender (matters for
/// first-person inflection: "I am happy" → ES contento/contenta, HE שמח/שמחה),
/// [addresseeGender] the viewer's gender (matters for second-person forms).
/// Values 'male'/'female' (also 'gender_*'); anything else is omitted.
typedef ProfileTextTranslationRequest = ({
  String userId,
  String field,
  String text,
  String? speakerGender,
  String? addresseeGender,
});

/// Normalized gender-context key for the profile translation cache.
/// Binary genders only ('male'/'female'); unknown/non-binary collapse to '' so
/// `female|male`, `female|`, `|male`, `|` are the only shapes. Matches the
/// edge's DeepL `context` mapping — same combo always yields same translation.
String _profileGenderKey(String? speakerGender, String? addresseeGender) {
  String? norm(String? raw) {
    if (raw == null) return null;
    var g = raw.trim().toLowerCase().replaceAll('-', '_');
    if (g.startsWith('gender_')) g = g.substring('gender_'.length);
    if (g == 'male' || g == 'm') return 'male';
    if (g == 'female' || g == 'f') return 'female';
    return null;
  }

  return '${norm(speakerGender) ?? ''}|${norm(addresseeGender) ?? ''}';
}

final profileTextTranslationProvider = FutureProvider.autoDispose
    .family<String, ProfileTextTranslationRequest>((ref, request) async {
      final text = request.text.trim();
      if (text.isEmpty) {
        debugPrint(
          '[ProfileTranslate] EMPTY field=${request.field} user=${request.userId} '
          '(section should have skipped; provider evaluated with empty text)',
        );
        return request.text;
      }

      final targetLanguage = normalizeLanguageCode(
        ref.watch(localizationProvider).currentLocale.languageCode,
      );
      final genderKey = _profileGenderKey(
        request.speakerGender,
        request.addresseeGender,
      );
      final localDb = await LocalDbService.instance;
      final cached = await localDb.getCachedProfileTranslation(
        userId: request.userId,
        field: request.field,
        sourceText: text,
        targetLanguage: targetLanguage,
        genderKey: genderKey,
      );
      if (cached != null) {
        debugPrint(
          '[ProfileTranslate] cache HIT field=${request.field} user=${request.userId} '
          'target=$targetLanguage genderKey=$genderKey',
        );
        return cached;
      }
      debugPrint(
        '[ProfileTranslate] cache MISS field=${request.field} user=${request.userId} '
        'target=$targetLanguage genderKey=$genderKey '
        'speaker=${request.speakerGender} addressee=${request.addresseeGender}',
      );

      final translationService = ref.read(translationServiceProvider);
      final sourceLanguage = await translationService.identifyLanguage(text);
      if (!ref.mounted ||
          sourceLanguage == 'und' ||
          targetLanguage == 'und' ||
          sourceLanguage == targetLanguage) {
        debugPrint(
          '[ProfileTranslate] SKIP field=${request.field} source=$sourceLanguage '
          'target=$targetLanguage (no translation needed; showing stored text as-is)',
        );
        return request.text;
      }

      try {
        debugPrint(
          '[ProfileTranslate] REQUEST field=${request.field} source=$sourceLanguage '
          'target=$targetLanguage genderKey=$genderKey',
        );
        final translated = await translationService
            .translateText(
              text,
              sourceLanguage,
              targetLanguage,
              speakerGender: request.speakerGender,
              recipientGender: request.addresseeGender,
            )
            .timeout(const Duration(seconds: 10));
        if (translated.trim().isNotEmpty && translated.trim() != text) {
          await localDb.saveCachedProfileTranslation(
            userId: request.userId,
            field: request.field,
            sourceText: text,
            targetLanguage: targetLanguage,
            genderKey: genderKey,
            translatedText: translated,
          );
        }
        return translated;
      } catch (_) {
        return request.text;
      }
    });

final profileBioTranslationProvider = FutureProvider.autoDispose
    .family<String, String>((ref, bio) async {
      final text = bio.trim();
      if (text.isEmpty) return bio;

      final targetLanguage = normalizeLanguageCode(
        ref.watch(localizationProvider).currentLocale.languageCode,
      );
      final translationService = ref.read(translationServiceProvider);
      final sourceLanguage = await translationService.identifyLanguage(text);

      if (!ref.mounted ||
          sourceLanguage == 'und' ||
          targetLanguage == 'und' ||
          sourceLanguage == targetLanguage) {
        return bio;
      }

      try {
        return await translationService
            .translateText(text, sourceLanguage, targetLanguage)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        return bio;
      }
    });

/// Helper: convert many incoming shapes into List&lt;String&gt;
List<String> _toStringList(dynamic value) {
  if (value == null) return <String>[];
  if (value is List) {
    return value
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty && s != '0')
        .toList();
  }
  if (value is Iterable) {
    return value
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty && s != '0')
        .toList();
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded
            .map((e) => e?.toString() ?? '')
            .where((s) => s.isNotEmpty && s != '0')
            .toList();
      }
    } catch (_) {
      // Ignore JSON parsing errors
    }
    return [value].where((s) => s.isNotEmpty && s != '0').toList();
  }
  try {
    final decoded = jsonDecode(value.toString());
    if (decoded is List) {
      return decoded
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty && s != '0')
          .toList();
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

/// Helper: ensure map of map of bools for the per-intent / per-feature
/// enforcement structure: { "<intent>": { "gender": <bool>, "age": <bool> } }.
Map<String, Map<String, dynamic>> _mapOfMapOfDynamic(dynamic value) {
  if (value == null) return <String, Map<String, dynamic>>{};
  if (value is Map) {
    final out = <String, Map<String, dynamic>>{};
    value.forEach((k, v) {
      final intentKey = k.toString();
      if (intentKey.isEmpty || intentKey == '0') return;
      if (v is Map) {
        out[intentKey] = Map<String, dynamic>.from(v);
      }
    });
    return out;
  }
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return _mapOfMapOfDynamic(decoded);
      }
    } catch (_) {}
  }
  return <String, Map<String, dynamic>>{};
}

/// Robust intent-key normalization (same as wizard/profile screens):
/// lowercases and collapses any non-alphanumeric run into a single `_`,
/// so `Business Networking`, `business-networking` and `business_networking`
/// all compare equal.
String _normalizeIntentKey(String? value) {
  final trimmed = (value ?? '').trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

String maskName(String? fullName) {
  if (fullName == null || fullName.trim().isEmpty) return 'Unknown User';
  final parts = fullName
      .replaceAll(RegExp('[\u200E\u200F\u202A-\u202E]'), '')
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'Unknown User';
  final first = _capitalizeNameWordLocal(parts.first);
  String suffix = '';
  if (parts.length > 1) {
    final last = parts.last;
    if (last.isNotEmpty && last.toLowerCase() != parts.first.toLowerCase()) {
      suffix = ' ${last[0].toUpperCase()}.';
    }
  }
  return '$first$suffix';
}

String _capitalizeNameWordLocal(String word) {
  if (word.isEmpty) return word;
  final hyphenParts = word.split('-');
  return hyphenParts
      .map((hyphenPart) {
        if (hyphenPart.isEmpty) return hyphenPart;
        final apostropheParts = hyphenPart.split("'");
        return apostropheParts
            .map((segment) {
              if (segment.isEmpty) return segment;
              final lower = segment.toLowerCase();
              return '${lower[0].toUpperCase()}${lower.substring(1)}';
            })
            .join("'");
      })
      .join('-');
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
  final Map<String, List<String>> personalInterests;
  final Map<String, List<String>> businessInterests;
  final Map<String, List<String>> languagesKnown;
  final String subscriptionTier;
  final DateTime? subscriptionExpiresAt;
  final bool isProfileComplete;
  final int matchRadiusDefault;
  final int gpsIntervalDefault;
  final bool smartGpsThrottlingEnabled;
  final bool sharedEventMatchingEnabled;
  final bool sharedMovementMatchingEnabled;
  final bool retroMatchingEnabled;
  final int retroRetentionHours;
  final List<String> editableProfileFields;

  // Gender and Age Preferences (stored in user_profiles.intent_preferences)
  final Map<String, List<String>>
  genderPreferences; // intent key -> list of preferred gender keys
  final Map<String, List<double>>
  agePreferences; // intent key -> [min_age, max_age]

  // Lifestyle & Profile Details
  final int? height; // height in cm
  final String heightUnit; // cm or ft
  final String? occupation;
  final String? education;
  final String? zodiacSign;

  // JSONB compound profile data
  final Map<String, dynamic>?
  lifestyle; // { smoking, drinking, exercise, diet }
  final Map<String, dynamic>? family; // { has_children, wants_children }
  final Map<String, dynamic>? religion; // { religion, importance }

  // Per-intent filter preferences (combined value + strict)
  final Map<String, Map<String, dynamic>>
  lifestyleFilters; // intent -> { feature: value, feature_strict: bool }
  final Map<String, Map<String, dynamic>>
  familyFilters; // intent -> { feature: value, feature_strict: bool }
  final Map<String, Map<String, dynamic>>
  religionFilters; // intent -> { feature: value, feature_strict: bool }
  final Map<String, Map<String, dynamic>>
  heightPreferences; // intent -> { min: double, max: double, strict: bool }

  // NEW
  final String? bio; // short free-text bio (global)
  final List<String>
  photos; // ordered list of object paths or URLs (min 1, max 5)

  // Social URLs
  final String? instagramUrl;
  final String? linkedinUrl;
  final String? facebookUrl;

  // Timezone
  final String? userTimezone;

  // Timestamps
  final DateTime? createdAt;

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
    required this.personalInterests,
    required this.businessInterests,
    required this.languagesKnown,
    required this.subscriptionTier,
    this.subscriptionExpiresAt,
    required this.isProfileComplete,
    required this.matchRadiusDefault,
    required this.gpsIntervalDefault,
    required this.smartGpsThrottlingEnabled,
    required this.sharedEventMatchingEnabled,
    required this.sharedMovementMatchingEnabled,
    this.retroMatchingEnabled = false,
    this.retroRetentionHours = 24,
    required this.editableProfileFields,
    required this.genderPreferences,
    required this.agePreferences,
    this.height,
    this.heightUnit = 'cm',
    this.occupation,
    this.education,
    this.zodiacSign,
    this.lifestyle,
    this.family,
    this.religion,
    required this.lifestyleFilters,
    required this.familyFilters,
    required this.religionFilters,
    required this.heightPreferences,
    this.bio,
    required this.photos,
    this.instagramUrl,
    this.linkedinUrl,
    this.facebookUrl,
    this.userTimezone,
    this.createdAt,
    this.isVerified = false,
    this.verificationStatus = 'unverified',
    this.verificationSubmittedAt,
    this.verificationReviewedAt,
    this.referralCode,
    this.credits = 0,
  });

  Map<String, List<String>> get interests {
    final combined = <String, List<String>>{
      for (final entry in personalInterests.entries)
        entry.key: List<String>.from(entry.value),
    };
    for (final entry in businessInterests.entries) {
      final values = combined.putIfAbsent(entry.key, () => <String>[]);
      for (final value in entry.value) {
        if (!values.contains(value)) values.add(value);
      }
    }
    return combined;
  }

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

    final String? bioField =
        (data['bio'] ?? data['profile_bio'] ?? data['about'])?.toString();

    // Parse verification fields
    final bool isVerified = (data['is_verified'] ?? false) is bool
        ? (data['is_verified'] ?? false) as bool
        : (data['is_verified'] ?? false).toString().toLowerCase() == 'true';

    final String verificationStatus =
        (data['verification_status'] ?? 'unverified').toString();

    DateTime? createdAt;
    if (data['created_at'] != null) {
      try {
        createdAt = DateTime.tryParse(data['created_at'].toString());
      } catch (_) {
        // Ignore invalid date
      }
    }

    DateTime? verificationSubmittedAt;
    if (data['verification_submitted_at'] != null) {
      try {
        verificationSubmittedAt = DateTime.tryParse(
          data['verification_submitted_at'].toString(),
        );
      } catch (_) {
        // Ignore invalid date
      }
    }

    DateTime? verificationReviewedAt;
    if (data['verification_reviewed_at'] != null) {
      try {
        verificationReviewedAt = DateTime.tryParse(
          data['verification_reviewed_at'].toString(),
        );
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
        s = s.replaceFirstMapped(
          tzNoColon,
          (m) => '${m.group(1)}:${m.group(2)}',
        );
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
      preferredLanguage:
          (data['preferredLanguage'] ?? data['preferred_language'] ?? 'en')
              .toString(),
      activeModes: listFromDynamic(data['activeModes'] ?? data['active_modes']),
      subIntents: _mapOfLists(data['subIntents'] ?? data['sub_intents']),
      personalInterests: _mapOfLists(
        data['personalInterests'] ?? data['personal_interests'] ?? {},
      ),
      businessInterests: _mapOfLists(
        data['businessInterests'] ?? data['business_interests'] ?? {},
      ),
      languagesKnown: languagesKnown,
      subscriptionTier: (data['subscription_tier'] ?? 'free').toString(),
      subscriptionExpiresAt: subscriptionExpiresAt,
      // FIXED: normalize multiple possible keys for isProfileComplete
      isProfileComplete: (() {
        final raw =
            data['isProfileComplete'] ??
            data['isProfile_complete'] ??
            data['is_profile_complete'] ??
            false;
        if (raw is bool) return raw;
        return raw.toString().toLowerCase() == 'true';
      })(),
      matchRadiusDefault: (data['match_radius_default'] ?? 50) is int
          ? (data['match_radius_default'] ?? 50) as int
          : int.tryParse((data['match_radius_default'] ?? '50').toString()) ??
                50,
      gpsIntervalDefault: (data['gps_interval_default'] ?? 5) is int
          ? (data['gps_interval_default'] ?? 5) as int
          : int.tryParse((data['gps_interval_default'] ?? '5').toString()) ?? 5,
      smartGpsThrottlingEnabled:
          (data['smart_gps_throttling_enabled'] ?? false) is bool
          ? (data['smart_gps_throttling_enabled'] ?? false) as bool
          : (data['smart_gps_throttling_enabled'] ?? false)
                    .toString()
                    .toLowerCase() ==
                'true',
      sharedEventMatchingEnabled:
          (data['shared_event_matching_enabled'] ?? false) is bool
          ? (data['shared_event_matching_enabled'] ?? false) as bool
          : (data['shared_event_matching_enabled'] ?? false)
                    .toString()
                    .toLowerCase() ==
                'true',
      sharedMovementMatchingEnabled:
          (data['shared_movement_matching_enabled'] ?? false) is bool
          ? (data['shared_movement_matching_enabled'] ?? false) as bool
          : (data['shared_movement_matching_enabled'] ?? false)
                    .toString()
                    .toLowerCase() ==
                'true',
      retroMatchingEnabled: (data['retro_matching_enabled'] ?? false) is bool
          ? (data['retro_matching_enabled'] ?? false) as bool
          : (data['retro_matching_enabled'] ?? false)
                    .toString()
                    .toLowerCase() ==
                'true',
      retroRetentionHours: (data['retro_retention_hours'] ?? 24) is int
          ? ((data['retro_retention_hours'] ?? 24) as int).clamp(2, 72)
          : (int.tryParse((data['retro_retention_hours'] ?? '24').toString()) ??
                    24)
                .clamp(2, 72),
      editableProfileFields: listFromDynamic(
        data['editableProfileFields'] ?? data['editable_profile_fields'],
      ),
      genderPreferences: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['gender_preferences'] != null) {
          return _mapOfLists(ip['gender_preferences']);
        }
        return _mapOfLists(data['gender_preferences'] ?? {});
      })(),
      agePreferences: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['age_preferences'] != null) {
          return _mapOfDoubleLists(ip['age_preferences']);
        }
        return _mapOfDoubleLists(data['age_preferences'] ?? {});
      })(),
      height: (data['height'] is int)
          ? data['height'] as int
          : int.tryParse(data['height']?.toString() ?? ''),
      heightUnit: data['height_unit']?.toString() == 'ft' ? 'ft' : 'cm',
      occupation: data['occupation']?.toString(),
      education: data['education']?.toString(),
      zodiacSign: data['zodiac_sign']?.toString(),
      lifestyle: data['lifestyle'] is Map
          ? Map<String, dynamic>.from(data['lifestyle'] as Map)
          : null,
      family: data['family'] is Map
          ? Map<String, dynamic>.from(data['family'] as Map)
          : null,
      religion: data['religion'] is Map
          ? Map<String, dynamic>.from(data['religion'] as Map)
          : null,
      lifestyleFilters: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['lifestyle_filters'] != null) {
          return _mapOfMapOfDynamic(ip['lifestyle_filters']);
        }
        return _mapOfMapOfDynamic(data['lifestyle_filters']);
      })(),
      familyFilters: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['family_filters'] != null) {
          return _mapOfMapOfDynamic(ip['family_filters']);
        }
        return _mapOfMapOfDynamic(data['family_filters']);
      })(),
      religionFilters: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['religion_filters'] != null) {
          return _mapOfMapOfDynamic(ip['religion_filters']);
        }
        return _mapOfMapOfDynamic(data['religion_filters']);
      })(),
      heightPreferences: (() {
        final ip = data['intent_preferences'];
        if (ip is Map && ip['height_preferences'] != null) {
          return _mapOfMapOfDynamic(ip['height_preferences']);
        }
        return _mapOfMapOfDynamic(data['height_preferences']);
      })(),
      bio: bioField,
      photos: photos,
      isVerified: isVerified,
      verificationStatus: verificationStatus,
      verificationSubmittedAt: verificationSubmittedAt,
      verificationReviewedAt: verificationReviewedAt,
      referralCode: data['referral_code']?.toString(),
      credits: (data['credits'] is int)
          ? data['credits']
          : int.tryParse(data['credits']?.toString() ?? '0') ?? 0,
      instagramUrl: data['instagram_url']?.toString(),
      linkedinUrl: data['linkedin_url']?.toString(),
      facebookUrl: data['facebook_url']?.toString(),
      userTimezone: data['user_timezone']?.toString(),
      createdAt: createdAt,
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
      'personalInterests': personalInterests,
      'businessInterests': businessInterests,
      'languagesKnown': languagesKnown,
      'subscription_tier': subscriptionTier,
      'subscription_expires_at': subscriptionExpiresAt?.toIso8601String(),
      'isProfileComplete': isProfileComplete,
      'match_radius_default': matchRadiusDefault,
      'gps_interval_default': gpsIntervalDefault,
      'smart_gps_throttling_enabled': smartGpsThrottlingEnabled,
      'shared_event_matching_enabled': sharedEventMatchingEnabled,
      'shared_movement_matching_enabled': sharedMovementMatchingEnabled,
      'retro_matching_enabled': retroMatchingEnabled,
      'retro_retention_hours': retroRetentionHours,
      'editableProfileFields': editableProfileFields,
      'gender_preferences': genderPreferences,
      'age_preferences': agePreferences,
      'height': height,
      'height_unit': heightUnit,
      'occupation': occupation,
      'education': education,
      'zodiac_sign': zodiacSign,
      'lifestyle': lifestyle,
      'family': family,
      'religion': religion,
      'lifestyle_filters': lifestyleFilters.isNotEmpty
          ? lifestyleFilters
          : null,
      'family_filters': familyFilters.isNotEmpty ? familyFilters : null,
      'religion_filters': religionFilters.isNotEmpty ? religionFilters : null,
      'height_preferences': heightPreferences.isNotEmpty
          ? heightPreferences
          : null,
      'bio': bio,
      'photos': photos,
      'is_verified': isVerified,
      'verification_status': verificationStatus,
      'verification_submitted_at': verificationSubmittedAt?.toIso8601String(),
      'verification_reviewed_at': verificationReviewedAt?.toIso8601String(),
      'referral_code': referralCode,
      'credits': credits,
      'instagram_url': instagramUrl,
      'linkedin_url': linkedinUrl,
      'facebook_url': facebookUrl,
      'user_timezone': userTimezone,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  Map<String, dynamic> toJsonForUserTableSave() {
    return {
      'name': name,
      'date_of_birth': dateOfBirth?.toIso8601String().split('T').first,
      'gender': gender,
      // preferred_language deliberately omitted: the UI language is owned by
      // locale_provider (setLocale / syncLanguageAfterLogin). Writing the
      // parsed field here raced those writes with a stale value — typically
      // the column's 'en' default loaded before the device language had been
      // seeded — which flipped new users' UI back to English.
      'match_radius_default': matchRadiusDefault,
      'gps_interval_default': gpsIntervalDefault,
      'smart_gps_throttling_enabled': smartGpsThrottlingEnabled,
      'shared_event_matching_enabled': sharedEventMatchingEnabled,
      'shared_movement_matching_enabled': sharedMovementMatchingEnabled,
      'editable_profile_fields': editableProfileFields,
      'referral_code': referralCode,
      'credits': credits,
    };
  }

  Map<String, dynamic> toJsonForProfileTableSave() {
    // Strip phantom empty categories and category-as-sub echoes (e.g. {"fitness":["fitness"]}) to prevent ghost rows in inspector
    Map<String, List<String>> filterInterests(Map<String, List<String>> src) {
      return Map<String, List<String>>.fromEntries(
        src.entries
            .where((e) {
              final norm = e.key
                  .toLowerCase()
                  .replaceAll('_', ' ')
                  .replaceAll(' ', '')
                  .trim();
              final filtered = e.value
                  .where(
                    (s) =>
                        s
                                .toLowerCase()
                                .replaceAll('_', ' ')
                                .replaceAll(' ', '')
                                .trim() !=
                            norm &&
                        s.trim().isNotEmpty,
                  )
                  .toList();
              return filtered.isNotEmpty;
            })
            .map((e) {
              final norm = e.key
                  .toLowerCase()
                  .replaceAll('_', ' ')
                  .replaceAll(' ', '')
                  .trim();
              final filtered = e.value
                  .where(
                    (s) =>
                        s
                                .toLowerCase()
                                .replaceAll('_', ' ')
                                .replaceAll(' ', '')
                                .trim() !=
                            norm &&
                        s.trim().isNotEmpty,
                  )
                  .toList();
              return MapEntry(e.key, filtered);
            }),
      );
    }

    // Preserve all buckets on save (including intents currently inactive)
    // so deactivating then re-activating an intent restores its previous
    // sub-intents/interests as checked. Display layers filter by activeModes.
    final filteredPersonal = filterInterests(personalInterests);
    final filteredBusiness = filterInterests(businessInterests);
    return {
      'user_id': id,
      'bio': bio,
      'photos': photos,
      'approved_primary_photos': null, // managed separately
      'height': height,
      'height_unit': heightUnit,
      'occupation': occupation,
      'education': education,
      'zodiac_sign': zodiacSign,
      'lifestyle': lifestyle,
      'family': family,
      'religion': religion,
      'languages_known': languagesKnown.isNotEmpty ? languagesKnown : null,
      'instagram_url': instagramUrl,
      'linkedin_url': linkedinUrl,
      'facebook_url': facebookUrl,
      'active_modes': activeModes,
      'sub_intents': subIntents,
      'personal_interests': filteredPersonal.isNotEmpty
          ? filteredPersonal
          : null,
      'business_interests': filteredBusiness.isNotEmpty
          ? filteredBusiness
          : null,
      'intent_preferences': {
        if (genderPreferences.isNotEmpty)
          'gender_preferences': genderPreferences,
        if (agePreferences.isNotEmpty) 'age_preferences': agePreferences,
        if (lifestyleFilters.isNotEmpty) 'lifestyle_filters': lifestyleFilters,
        if (familyFilters.isNotEmpty) 'family_filters': familyFilters,
        if (religionFilters.isNotEmpty) 'religion_filters': religionFilters,
        if (heightPreferences.isNotEmpty)
          'height_preferences': heightPreferences,
      },
    };
  }

  static Future<void> loadMatchRadiusConfig() async {
    // Placeholder for match radius config loading from AppConfigService
    // Currently no-op; config is read on demand.
  }

  // Sentinel to distinguish "not provided" from explicit null for nullable fields
  static const _sentinel = Object();

  UserProfile copyWith({
    String? id,
    String? name,
    DateTime? dateOfBirth,
    String? gender,
    String? preferredLanguage,
    List<String>? activeModes,
    Map<String, List<String>>? subIntents,
    Map<String, List<String>>? personalInterests,
    Map<String, List<String>>? businessInterests,
    Map<String, List<String>>? languagesKnown,
    String? subscriptionTier,
    DateTime? subscriptionExpiresAt,
    bool? isProfileComplete,
    int? matchRadiusDefault,
    int? gpsIntervalDefault,
    bool? smartGpsThrottlingEnabled,
    bool? sharedEventMatchingEnabled,
    bool? sharedMovementMatchingEnabled,
    bool? retroMatchingEnabled,
    int? retroRetentionHours,
    List<String>? editableProfileFields,
    Map<String, List<String>>? genderPreferences,
    Map<String, List<double>>? agePreferences,
    Object? height = _sentinel,
    String? heightUnit,
    String? occupation,
    String? education,
    String? zodiacSign,
    Map<String, dynamic>? lifestyle,
    Map<String, dynamic>? family,
    Map<String, dynamic>? religion,
    Map<String, Map<String, dynamic>>? lifestyleFilters,
    Map<String, Map<String, dynamic>>? familyFilters,
    Map<String, Map<String, dynamic>>? religionFilters,
    Map<String, Map<String, dynamic>>? heightPreferences,
    String? bio,
    List<String>? photos,
    String? instagramUrl,
    String? linkedinUrl,
    String? facebookUrl,
    String? userTimezone,
    DateTime? createdAt,
    bool? isVerified,
    String? verificationStatus,
    DateTime? verificationSubmittedAt,
    DateTime? verificationReviewedAt,
    String? referralCode,
    int? credits,
  }) {
    Map<String, List<String>> cloneMap(Map<String, List<String>> src) =>
        Map<String, List<String>>.from(
          src.map((k, v) => MapEntry(k, List<String>.from(v))),
        );

    Map<String, List<double>> cloneDoubleMap(Map<String, List<double>> src) =>
        Map<String, List<double>>.from(
          src.map((k, v) => MapEntry(k, List<double>.from(v))),
        );

    Map<String, Map<String, dynamic>> cloneDynamicMap(
      Map<String, Map<String, dynamic>> src,
    ) => Map<String, Map<String, dynamic>>.from(
      src.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v))),
    );

    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      gender: gender ?? this.gender,
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      activeModes: activeModes != null
          ? List<String>.from(activeModes)
          : List<String>.from(this.activeModes),
      subIntents: subIntents != null
          ? cloneMap(subIntents)
          : cloneMap(this.subIntents),
      personalInterests: personalInterests != null
          ? cloneMap(personalInterests)
          : cloneMap(this.personalInterests),
      businessInterests: businessInterests != null
          ? cloneMap(businessInterests)
          : cloneMap(this.businessInterests),
      languagesKnown: languagesKnown != null
          ? cloneMap(languagesKnown)
          : cloneMap(this.languagesKnown),
      subscriptionTier: subscriptionTier ?? this.subscriptionTier,
      subscriptionExpiresAt:
          subscriptionExpiresAt ?? this.subscriptionExpiresAt,
      isProfileComplete: isProfileComplete ?? this.isProfileComplete,
      matchRadiusDefault: matchRadiusDefault ?? this.matchRadiusDefault,
      gpsIntervalDefault: gpsIntervalDefault ?? this.gpsIntervalDefault,
      smartGpsThrottlingEnabled:
          smartGpsThrottlingEnabled ?? this.smartGpsThrottlingEnabled,
      sharedEventMatchingEnabled:
          sharedEventMatchingEnabled ?? this.sharedEventMatchingEnabled,
      sharedMovementMatchingEnabled:
          sharedMovementMatchingEnabled ?? this.sharedMovementMatchingEnabled,
      retroMatchingEnabled: retroMatchingEnabled ?? this.retroMatchingEnabled,
      retroRetentionHours: retroRetentionHours ?? this.retroRetentionHours,
      editableProfileFields: editableProfileFields != null
          ? List<String>.from(editableProfileFields)
          : List<String>.from(this.editableProfileFields),
      genderPreferences: genderPreferences != null
          ? cloneMap(genderPreferences)
          : cloneMap(this.genderPreferences),
      agePreferences: agePreferences != null
          ? cloneDoubleMap(agePreferences)
          : cloneDoubleMap(this.agePreferences),
      height: height == _sentinel ? this.height : height as int?,
      heightUnit: heightUnit ?? this.heightUnit,
      occupation: occupation ?? this.occupation,
      education: education ?? this.education,
      zodiacSign: zodiacSign ?? this.zodiacSign,
      lifestyle: lifestyle ?? this.lifestyle,
      family: family ?? this.family,
      religion: religion ?? this.religion,
      lifestyleFilters: lifestyleFilters != null
          ? cloneDynamicMap(lifestyleFilters)
          : cloneDynamicMap(this.lifestyleFilters),
      familyFilters: familyFilters != null
          ? cloneDynamicMap(familyFilters)
          : cloneDynamicMap(this.familyFilters),
      religionFilters: religionFilters != null
          ? cloneDynamicMap(religionFilters)
          : cloneDynamicMap(this.religionFilters),
      heightPreferences: heightPreferences != null
          ? cloneDynamicMap(heightPreferences)
          : cloneDynamicMap(this.heightPreferences),
      bio: bio ?? this.bio,
      photos: photos != null
          ? List<String>.from(photos)
          : List<String>.from(this.photos),
      instagramUrl: instagramUrl ?? this.instagramUrl,
      linkedinUrl: linkedinUrl ?? this.linkedinUrl,
      facebookUrl: facebookUrl ?? this.facebookUrl,
      userTimezone: userTimezone ?? this.userTimezone,
      createdAt: createdAt ?? this.createdAt,
      isVerified: isVerified ?? this.isVerified,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verificationSubmittedAt:
          verificationSubmittedAt ?? this.verificationSubmittedAt,
      verificationReviewedAt:
          verificationReviewedAt ?? this.verificationReviewedAt,
      referralCode: referralCode ?? this.referralCode,
      credits: credits ?? this.credits,
    );
  }

  /// Check if [other]'s profile satisfies this user's filter preferences
  /// for the given [intentKey]. Uses [optionMapping] — a list of AppProfileOption
  /// rows — to resolve which profile_values each filter_value maps to.
  /// If [optionMapping] is empty, fall back to direct string comparison.
  bool isCompatibleWithFilters(
    UserProfile other,
    String intentKey, {
    List<AppProfileOption> optionMapping = const [],
  }) {
    bool anyFilterMatches(
      List<AppProfileOption> opts,
      String fieldKey,
      List<String> filterVals,
      String? candidateVal,
    ) {
      if (candidateVal == null) return false;
      final cv = candidateVal.toLowerCase();
      if (opts.isNotEmpty) {
        return opts.any(
          (o) =>
              o.fieldKey == fieldKey &&
              filterVals.contains(o.filterValue) &&
              o.profileValue != null &&
              o.profileValue!.toLowerCase() == cv,
        );
      }
      return filterVals.contains(cv);
    }

    bool checkFilter(
      Map<String, dynamic> map,
      String fieldKey,
      String? candidateVal, {
      String listKey = '',
      String legacyKey = '',
    }) {
      final list = _extractList(
        map,
        listKey.isNotEmpty ? listKey : fieldKey,
        legacyKey.isNotEmpty ? legacyKey : fieldKey,
      );
      if (list.isEmpty || list.contains('any')) return true;
      return candidateVal != null &&
          anyFilterMatches(optionMapping, fieldKey, list, candidateVal);
    }

    // Lifestyle
    final lf = lifestyleFilters[intentKey];
    if (lf != null) {
      final ol = other.lifestyle;
      if (!checkFilter(lf, 'smoking', ol?['smoking'] as String?)) return false;
      if (!checkFilter(lf, 'drinking', ol?['drinking'] as String?)) {
        return false;
      }
      if (!checkFilter(
        lf,
        'diet',
        ol?['diet'] as String?,
        listKey: 'diets',
        legacyKey: 'diet',
      )) {
        return false;
      }
      if (!checkFilter(lf, 'exercise', ol?['exercise'] as String?)) {
        return false;
      }
    }

    // Family
    final ff = familyFilters[intentKey];
    if (ff != null) {
      final of = other.family;
      final hcList = _extractList(ff, 'has_children', 'has_children');
      if (hcList.isNotEmpty && !hcList.contains('any')) {
        final otherHc = of != null
            ? ((of['has_children'] as bool?) == true ? 'yes' : 'no')
            : null;
        if (otherHc == null || !hcList.contains(otherHc)) return false;
      }
      if (!checkFilter(
        ff,
        'wants_children',
        of?['wants_children'] as String?,
        listKey: 'wants_children',
        legacyKey: 'wants_children',
      )) {
        return false;
      }
    }

    // Religion
    final rf = religionFilters[intentKey];
    if (rf != null) {
      final list = _extractList(rf, 'religions', 'religion');
      if (list.isNotEmpty && !list.contains('any')) {
        final otherR = other.religion?['religion'] as String?;
        if (otherR == null ||
            !anyFilterMatches(optionMapping, 'religion', list, otherR)) {
          return false;
        }
      }
    }

    // Height — Romantic intent only. Height is not collected for Friendship,
    // Activity Partner or Business/Networking, so it never affects those matches.
    if (_isRomanticIntentKey(intentKey)) {
      final hp = heightPreferences[intentKey];
      if (hp != null) {
        if (other.height == null) return false;
        final min = hp['min'] as num?;
        final max = hp['max'] as num?;
        if (min != null && other.height! < min) return false;
        if (max != null && other.height! > max) return false;
      }
    }

    return true;
  }

  static bool _isRomanticIntentKey(String intentKey) =>
      intentKey.toLowerCase().trim().split('::').first == 'romantic';

  static List<String> _extractList(
    Map<String, dynamic> map,
    String key,
    String legacyKey,
  ) {
    final raw = map[key];
    if (raw is List) return raw.cast<String>();
    final legacy = map[legacyKey] as String?;
    if (legacy != null && legacy.isNotEmpty) return [legacy];
    return [];
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
      return IntentProfileData(
        bio: 'No bio provided.',
        subIntents: [],
        interests: {},
      );
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

class ProfileSyncStateNotifier extends Notifier<ProfileSyncState> {
  ProfileSyncStateNotifier(this.userId);

  final String userId;

  @override
  ProfileSyncState build() => const ProfileSyncState();

  void started() {
    state = ProfileSyncState(isSyncing: true, result: state.result);
  }

  void completed(ProfileSyncResult result) {
    state = ProfileSyncState(result: result);
  }

  void reset() {
    state = const ProfileSyncState();
  }
}

final profileSyncStateProvider =
    NotifierProvider.family<ProfileSyncStateNotifier, ProfileSyncState, String>(
      ProfileSyncStateNotifier.new,
    );

/// ---------------------------------------------------------------------------
/// ProfileSyncService
/// ---------------------------------------------------------------------------
class ProfileSyncService {
  final Ref ref;
  ProfileSyncService(this.ref);

  final Map<String, int> _syncGenerations = <String, int>{};
  final Map<String, Future<ProfileSyncResult>> _inFlight = {};
  
  // Debounce: track last successful sync time PER USER to prevent rapid
  // redundant calls. Keyed by userId — a global timestamp made matched-user
  // warm-up syncs cancel each other (the first to finish stamped the single
  // shared timestamp, so the rest hit SKIP debounced and never refreshed).
  final Map<String, DateTime> _lastSuccessfulSyncAt = <String, DateTime>{};
  static const _debounceWindow = Duration(seconds: 5);
  // Sources that should bypass debounce (explicit user actions)
  static const _debounceBypassSources = {'manual-review-request', 'admin-review-change'};

  int _beginSync(String userId) {
    final generation = (_syncGenerations[userId] ?? 0) + 1;
    _syncGenerations[userId] = generation;
    return generation;
  }

  void invalidateUser(String userId) {
    _inFlight.remove(userId);
    _syncGenerations[userId] = (_syncGenerations[userId] ?? 0) + 1;
    _lastSuccessfulSyncAt.remove(userId);
  }

  void _publishStarted(String userId, int generation) {
    if (supabase.auth.currentUser?.id != userId) return;
    if (_syncGenerations[userId] != generation) return;
    try {
      ref.read(profileSyncStateProvider(userId).notifier).started();
    } catch (_) {}
  }

  Future<bool> _hasCachedProfile(String userId) async {
    if (userId.isEmpty) return false;
    try {
      return await ref.read(localDbProvider).getLocalProfile(userId) != null;
    } catch (_) {
      return false;
    }
  }

  Future<ProfileSyncResult> _finishSync(
    String userId,
    int generation,
    ProfileSyncStatus status, {
    bool? cacheAvailable,
    bool cacheUpdated = false,
    Object? error,
  }) async {
    final hasCachedProfile = cacheAvailable ?? await _hasCachedProfile(userId);
    final result = ProfileSyncResult(
      status: status,
      cacheAvailable: hasCachedProfile,
      cacheUpdated: cacheUpdated,
      completedAt: DateTime.now(),
      error: error,
    );
    if (supabase.auth.currentUser?.id == userId &&
        _syncGenerations[userId] == generation) {
      try {
        ref.read(profileSyncStateProvider(userId).notifier).completed(result);
      } catch (_) {}
    }
    return result;
  }

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
      'subscription_tier',
      'subscription_expires_at',
      'is_profile_complete',
      'match_radius_default',
      'gps_interval_default',
      'smart_gps_throttling_enabled',
      'shared_event_matching_enabled',
      'shared_movement_matching_enabled',
      'retro_matching_enabled',
      'retro_retention_hours',
      'editable_profile_fields',
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
        final query = supabase
            .from('users')
            .select(columnsToTry.join(','))
            .eq('id', userId)
            .maybeSingle();
        final result = await query;
        if (result == null) return null;
        return Map<String, dynamic>.from(result as Map);
      } catch (e) {
        if (e is PostgrestException) {
          final msg = e.message;
          // Detect missing column error and remove the column, then retry.
          final missingColumnRegex = RegExp(
            r'column\s+"?(\w+)"?\s+does not exist',
            caseSensitive: false,
          );
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

  static Future<void> loadConfig() async {
    // Placeholder for ProfileSyncService config loading from AppConfigService
    // Currently no-op; config is read on demand.
  }

  /// True when a sync for [userId] is currently running. Lets callers skip
  /// scheduling a duplicate instead of piling a second one onto the same user.
  bool isSyncInFlight(String userId) => _inFlight.containsKey(userId);

  Future<ProfileSyncResult> syncProfile(String userId, {String source = ''}) {
    final existing = _inFlight[userId];
    if (existing != null) return existing;

    // Debounce: skip if THIS user's sync succeeded within the last 5 seconds.
    // This prevents rapid redundant syncs from bootstrap + realtime + settings-open
    // etc. Scoped per userId so warm-up syncs for different matched users don't
    // cancel one another.
    final now = DateTime.now();
    final lastSyncAt = _lastSuccessfulSyncAt[userId];
    if (lastSyncAt != null &&
        now.difference(lastSyncAt) < _debounceWindow &&
        !_debounceBypassSources.contains(source)) {
      debugPrint('ProfileSyncService.syncProfile SKIP debounced source=$source');
      return Future.value(ProfileSyncResult(
        status: ProfileSyncStatus.skipped,
        cacheAvailable: false,
      ));
    }

    final future = _syncProfileInternal(userId, source: source);
    _inFlight[userId] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight[userId], future)) {
          _inFlight.remove(userId);
        }
        // Update last successful sync time for debounce (scoped to this user).
        // Note: We check the result asynchronously to avoid blocking
        future.then((result) {
          if (result.status == ProfileSyncStatus.synced) {
            _lastSuccessfulSyncAt[userId] = DateTime.now();
          }
        });
      }),
    );
    return future;
  }

  Future<ProfileSyncResult> _syncProfileInternal(
    String userId, {
    String source = '',
  }) async {
    final generation = _beginSync(userId);
    if (userId.isEmpty) {
      return _finishSync(
        userId,
        generation,
        ProfileSyncStatus.invalidUser,
        cacheAvailable: false,
      );
    }
    final session = supabase.auth.currentSession;
    if (session == null) {
      return _finishSync(userId, generation, ProfileSyncStatus.unauthenticated);
    }

    debugPrint('ProfileSyncService.syncProfile START source=$source');
    _publishStarted(userId, generation);

    // Avoid attempting sync when device is offline.
    final isOnline = ref.read(connectivityProvider).value ?? true;
    if (!isOnline) {
      debugPrint('ProfileSyncService.syncProfile SKIP offline');
      return _finishSync(userId, generation, ProfileSyncStatus.offline);
    }

    final startAll = DateTime.now();
    // Hard ceiling on the whole sync (all attempts + backoff). Without this a
    // slow-but-not-dead backend could stretch a single sync past 20s, blocking
    // callers that await it (e.g. the home-ready warm path).
    const overallTimeout = Duration(seconds: 20);

    try {
      const int maxAttempts = 3;
      int attempt = 0;

      while (true) {
        if (DateTime.now().difference(startAll) > overallTimeout) {
          throw TimeoutException(
            'syncProfile exceeded overall ${overallTimeout.inSeconds}s budget',
          );
        }
        attempt++;
        try {
          final startAttempt = DateTime.now();
          // Snapshot BEFORE the network fetch: if a wizard/local save lands
          // after this point, the fetched server data is stale and must not
          // overwrite the fresh local DB (otherwise the ProfileScreen would
          // revert to pre-wizard data right after saving).
          final fetchStartedAt = DateTime.now();
          // Fetch user row (identity + settings only)
          final userFuture = _fetchUserRowWithFallback(userId).timeout(
            const Duration(seconds: 10),
          );

          // Fetch single user_profiles row
          final profilesFuture = supabase
              .from('user_profiles')
              .select('*')
              .eq('user_id', userId)
              .maybeSingle()
              .timeout(const Duration(seconds: 10));

          final List<dynamic> results = await Future.wait([
            userFuture,
            profilesFuture,
          ]);
          final userData = results[0] as Map<String, dynamic>?;
          final profileRow = results[1] as Map<String, dynamic>?;
          if (_syncGenerations[userId] != generation) {
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.cancelled,
              cacheAvailable: false,
            );
          }

          // --- Trial Period Logic ---
          if (userData != null && userData['created_at'] != null) {
            debugPrint(
              '🔍 [ProfileProvider] syncProfile fetched tier: ${userData['subscription_tier']}',
            );
            try {
              final createdAt = DateTime.tryParse(
                userData['created_at'].toString(),
              );
              if (createdAt != null) {
                final appConfig = AppConfigService();
                final trialDuration = await appConfig.getInt(
                  'subscription.trial_duration_hours',
                  defaultValue: 0,
                );

                if (trialDuration > 0) {
                  final trialTier = await appConfig.getString(
                    'subscription.trial_tier_id',
                    defaultValue: '',
                  );
                  if (trialTier.isNotEmpty) {
                    final trialEndUtc = createdAt.toUtc().add(
                      Duration(hours: trialDuration),
                    );
                    final nowUtc = DateTime.now().toUtc();
                    if (nowUtc.isBefore(trialEndUtc)) {
                      final currentTierId =
                          (userData['subscription_tier'] ?? 'free').toString();

                      int getSortOrder(String tierId) {
                        if (tierId == 'free' || tierId.isEmpty) return 0;
                        try {
                          final tier = SubscriptionTier.fallbacks.firstWhere(
                            (t) => t.id == tierId,
                          );
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
                            s = s.replaceFirstMapped(
                              tzNoColon,
                              (m) => '${m.group(1)}:${m.group(2)}',
                            );
                          } else if (tzShort.hasMatch(s)) {
                            s = s.replaceFirstMapped(
                              tzShort,
                              (m) => '${m.group(1)}:00',
                            );
                          }
                          currentExpiresAtUtc = DateTime.tryParse(s)?.toUtc();
                        }
                      }
                      final shouldPersistTrial =
                          (trialSort > currentSort) ||
                          (currentTierId == trialTier &&
                              currentExpiresAtUtc == null);

                      if (shouldPersistTrial) {
                        try {
                          final dynamic rpcResult = await supabase.rpc(
                            'apply_revenuecat_subscription',
                            params: {
                              'p_tier': trialTier,
                              'p_expires_at': trialEndUtc.toIso8601String(),
                            },
                          ).timeout(const Duration(seconds: 10));

                          Map<String, dynamic>? result;
                          if (rpcResult is Map) {
                            result = Map<String, dynamic>.from(rpcResult);
                          } else if (rpcResult is List &&
                              rpcResult.isNotEmpty &&
                              rpcResult.first is Map) {
                            result = Map<String, dynamic>.from(
                              rpcResult.first as Map,
                            );
                          }

                          if (result != null) {
                            userData['subscription_tier'] =
                                (result['subscription_tier'] ?? trialTier)
                                    .toString();
                            userData['subscription_expires_at'] =
                                result['subscription_expires_at'];
                          }
                        } catch (e) {
                          debugPrint(
                            '⚠️ [ProfileProvider] Trial persist failed: $e',
                          );
                        }
                      }
                    }
                  }
                }
              }
            } catch (e) {
              debugPrint(
                '⚠️ [ProfileProvider] Error checking trial status: $e',
              );
            }
          }
          debugPrint(
            '🔍 [ProfileProvider] Final tier to save: ${userData?['subscription_tier']}',
          );
          // --------------------------

          final attemptDuration = DateTime.now()
              .difference(startAttempt)
              .inMilliseconds;
          ResumeDiagnostics.log(
            'ProfileSyncService.syncProfile attempt $attempt completed in ${attemptDuration}ms for user=$userId',
          );

          if (userData == null) {
            // No user row found — nothing to sync
            final totalDuration = DateTime.now()
                .difference(startAll)
                .inMilliseconds;
            ResumeDiagnostics.log(
              'ProfileSyncService.syncProfile END (no user) for user=$userId total=${totalDuration}ms',
            );
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.notFound,
            );
          }

          Map<String, List<String>> processedSubIntents = {};
          Map<String, dynamic> profileRowData = {};
          if (profileRow != null) {
            profileRowData = Map<String, dynamic>.from(profileRow);
            // sub_intents is now a JSONB map: { "Romantic": ["sub1"], ... }
            final subIntentsRaw = profileRowData['sub_intents'];
            if (subIntentsRaw is Map) {
              subIntentsRaw.forEach((k, v) {
                processedSubIntents[k.toString()] = _toStringList(v);
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
            dateOfBirth: (() {
              if (userData['date_of_birth'] == null) return null;
              try {
                final d = DateTime.tryParse(
                  userData['date_of_birth'].toString(),
                );
                if (d == null) return null;
                return DateTime(d.year, d.month, d.day);
              } catch (_) {
                return null;
              }
            })(),
            gender: userData['gender']?.toString(),
            preferredLanguage: (userData['preferred_language'] ?? 'en')
                .toString(),
            activeModes: _toStringList(profileRowData['active_modes'] ?? []),
            subIntents: processedSubIntents,
            personalInterests: _mapOfLists(
              profileRowData['personal_interests'] ?? {},
            ),
            businessInterests: _mapOfLists(
              profileRowData['business_interests'] ?? {},
            ),
            languagesKnown: (() {
              final langData = profileRowData['languages_known'];
              if (langData is Map<String, dynamic>) {
                return _mapOfLists(langData);
              }
              if (langData is List) {
                return <String, List<String>>{
                  'languages': _toStringList(langData),
                };
              }
              return <String, List<String>>{};
            })(),
            subscriptionTier: (userData['subscription_tier'] ?? 'free')
                .toString(),
            subscriptionExpiresAt: parseOptionalDateTime(
              userData['subscription_expires_at'],
            ),
            isProfileComplete:
                (userData['is_profile_complete'] ?? false) is bool
                ? (userData['is_profile_complete'] ?? false) as bool
                : (userData['is_profile_complete'] ?? false)
                          .toString()
                          .toLowerCase() ==
                      'true',
            matchRadiusDefault: (userData['match_radius_default'] ?? 50) is int
                ? (userData['match_radius_default'] ?? 50) as int
                : int.tryParse(
                        (userData['match_radius_default'] ?? '50').toString(),
                      ) ??
                      50,
            gpsIntervalDefault: (userData['gps_interval_default'] ?? 5) is int
                ? (userData['gps_interval_default'] ?? 5) as int
                : int.tryParse(
                        (userData['gps_interval_default'] ?? '5').toString(),
                      ) ??
                      5,
            smartGpsThrottlingEnabled:
                (userData['smart_gps_throttling_enabled'] ?? false) is bool
                ? (userData['smart_gps_throttling_enabled'] ?? false) as bool
                : (userData['smart_gps_throttling_enabled'] ?? false)
                          .toString()
                          .toLowerCase() ==
                      'true',
            sharedEventMatchingEnabled:
                (userData['shared_event_matching_enabled'] ?? false) is bool
                ? (userData['shared_event_matching_enabled'] ?? false) as bool
                : (userData['shared_event_matching_enabled'] ?? false)
                          .toString()
                          .toLowerCase() ==
                      'true',
            sharedMovementMatchingEnabled:
                (userData['shared_movement_matching_enabled'] ?? false) is bool
                ? (userData['shared_movement_matching_enabled'] ?? false)
                      as bool
                : (userData['shared_movement_matching_enabled'] ?? false)
                          .toString()
                          .toLowerCase() ==
                      'true',
            retroMatchingEnabled:
                (userData['retro_matching_enabled'] ?? false) is bool
                ? (userData['retro_matching_enabled'] ?? false) as bool
                : (userData['retro_matching_enabled'] ?? false)
                          .toString()
                          .toLowerCase() ==
                      'true',
            retroRetentionHours:
                (userData['retro_retention_hours'] ?? 24) is int
                ? ((userData['retro_retention_hours'] ?? 24) as int).clamp(
                    2,
                    72,
                  )
                : (int.tryParse(
                            (userData['retro_retention_hours'] ?? '24')
                                .toString(),
                          ) ??
                          24)
                      .clamp(2, 72),
            editableProfileFields: editableFields,
            genderPreferences: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['gender_preferences'] != null) {
                return _mapOfLists(ip['gender_preferences']);
              }
              return <String, List<String>>{};
            })(),
            agePreferences: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['age_preferences'] != null) {
                return _mapOfDoubleLists(ip['age_preferences']);
              }
              return <String, List<double>>{};
            })(),
            height: profileRowData['height'] is int
                ? profileRowData['height'] as int
                : int.tryParse(profileRowData['height']?.toString() ?? ''),
            heightUnit: profileRowData['height_unit']?.toString() == 'ft'
                ? 'ft'
                : 'cm',
            occupation: profileRowData['occupation']?.toString(),
            education: profileRowData['education']?.toString(),
            zodiacSign: profileRowData['zodiac_sign']?.toString(),
            lifestyle: profileRowData['lifestyle'] is Map
                ? Map<String, dynamic>.from(profileRowData['lifestyle'] as Map)
                : null,
            family: profileRowData['family'] is Map
                ? Map<String, dynamic>.from(profileRowData['family'] as Map)
                : null,
            religion: profileRowData['religion'] is Map
                ? Map<String, dynamic>.from(profileRowData['religion'] as Map)
                : null,
            lifestyleFilters: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['lifestyle_filters'] != null) {
                return _mapOfMapOfDynamic(ip['lifestyle_filters']);
              }
              return <String, Map<String, dynamic>>{};
            })(),
            familyFilters: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['family_filters'] != null) {
                return _mapOfMapOfDynamic(ip['family_filters']);
              }
              return <String, Map<String, dynamic>>{};
            })(),
            religionFilters: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['religion_filters'] != null) {
                return _mapOfMapOfDynamic(ip['religion_filters']);
              }
              return <String, Map<String, dynamic>>{};
            })(),
            heightPreferences: (() {
              final ip = profileRowData['intent_preferences'];
              if (ip is Map && ip['height_preferences'] != null) {
                return _mapOfMapOfDynamic(ip['height_preferences']);
              }
              return <String, Map<String, dynamic>>{};
            })(),
            bio: profileRowData['bio']?.toString(),
            isVerified: (userData['is_verified'] ?? false) is bool
                ? (userData['is_verified'] ?? false) as bool
                : (userData['is_verified'] ?? false).toString().toLowerCase() ==
                      'true',
            verificationStatus:
                (userData['verification_status'] ?? 'unverified').toString(),
            verificationSubmittedAt:
                userData['verification_submitted_at'] != null
                ? DateTime.tryParse(
                    userData['verification_submitted_at'].toString(),
                  )
                : null,
            verificationReviewedAt: userData['verification_reviewed_at'] != null
                ? DateTime.tryParse(
                    userData['verification_reviewed_at'].toString(),
                  )
                : null,
            photos: _toStringList(profileRowData['photos']),
            instagramUrl: profileRowData['instagram_url']?.toString(),
            linkedinUrl: profileRowData['linkedin_url']?.toString(),
            facebookUrl: profileRowData['facebook_url']?.toString(),
            userTimezone: userData['user_timezone']?.toString(),
            createdAt: (() {
              if (userData['created_at'] != null) {
                return DateTime.tryParse(userData['created_at'].toString());
              }
              return null;
            })(),
          );

          final localDb = ref.read(localDbProvider);
          final approvedPrimaryPhotos = _toStringList(
            profileRowData['approved_primary_photos'],
          ).toSet();
          if (approvedPrimaryPhotos.isNotEmpty) {
            await localDb.setApprovedPrimaryPhotos(
              userId,
              approvedPrimaryPhotos,
            );
          }
          final previousMap = await localDb.getLocalProfile(userId);
          final previousPhotos = previousMap != null
              ? _toStringList(previousMap['photos'])
              : <String>[];
          final newPhotos = profile.photos;
          if (!listEquals(previousPhotos, newPhotos)) {
            final allPhotos = <String>{...previousPhotos, ...newPhotos};
            for (final path in allPhotos) {
              if (path.isEmpty) continue;
              StorageHelper.evictImageCache(path);
            }
          }
          // Realtime guard: a wizard save that landed AFTER this fetch
          // started means the server snapshot is stale. Do NOT overwrite the
          // fresh local profile — otherwise the ProfileScreen would flash
          // back to pre-wizard data right after saving.
          if (_localSaveIsNewerThan(userId, fetchStartedAt)) {
            debugPrint(
              'ProfileSyncService.syncProfile SKIP overwrite (fresh local wizard save)',
            );
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.supersededByLocalSave,
              cacheAvailable: true,
            );
          }
          // Completion guard: this fetch raced with a local wizard save. A
          // pre-commit fetch (or lagging replica) reports
          // is_profile_complete=false right after the user completed the
          // profile locally; writing it would flip ProfileCheckScreen back
          // to the wizard, which then reopens on the review step with an
          // empty diff ("Not set"). During the recent-local-save window the
          // local completed profile is authoritative; a later sync after the
          // window re-reads the committed server row.
          final localSaysComplete =
              previousMap?['is_profile_complete']?.toString() == 'true' ||
              previousMap?['isProfileComplete']?.toString() == 'true';
          if (localSaysComplete &&
              !profile.isProfileComplete &&
              _hasVeryRecentLocalSave(userId, const Duration(minutes: 2))) {
            debugPrint(
              'ProfileSyncService.syncProfile SKIP overwrite (server row raced with local profile completion)',
            );
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.supersededByLocalSave,
              cacheAvailable: true,
            );
          }
          if (_syncGenerations[userId] != generation) {
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.cancelled,
              cacheAvailable: previousMap != null,
            );
          }
          // A local edit (radius, GPS rate, settings, …) landed very recently.
          // The server snapshot for this fetch may predate that edit (stale
          // replica or in-flight write), so do not let it overwrite the
          // local DB / state — otherwise the setting visibly reverts.
          if (_hasVeryRecentLocalSave(userId, const Duration(minutes: 2))) {
            debugPrint(
              'ProfileSyncService.syncProfile SKIP overwrite (very recent local save)',
            );
            return await _finishSync(
              userId,
              generation,
              ProfileSyncStatus.supersededByLocalSave,
              cacheAvailable: true,
            );
          }
          final localMap = profile.toMap();
          localMap['_cached_at'] = DateTime.now().toIso8601String();
          await localDb.saveLocalProfile(userId, localMap);
          // Mirror the Retro Matching opt-in + retention to local prefs.
          // The settings toggle shows the profile flag, but recording
          // (OfflineTrailService) and the native background service read
          // these prefs — without this mirror, the flag enabled on another
          // install leaves offline recording silently OFF while the toggle
          // shows ON.
          // Skipped when Supabase calls are paused (offline): the sync is
          // best-effort there, and we don't want a per-matched-user warm-up
          // burst to pay SharedPreferences write latency while offline.
          if (!shouldSkipSupabaseCalls()) {
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('flutter.retro_enabled', profile.retroMatchingEnabled);
              final retention = profile.retroRetentionHours.clamp(2, 72);
              await prefs.setInt('flutter.retro_retention_hours', retention);
            } catch (_) {}
          }

          // Success — exit retry loop
          final totalDuration = DateTime.now()
              .difference(startAll)
              .inMilliseconds;
          debugPrint(
            'ProfileSyncService.syncProfile SUCCESS total=${totalDuration}ms',
          );
          return await _finishSync(
            userId,
            generation,
            ProfileSyncStatus.synced,
            cacheAvailable: true,
            cacheUpdated: true,
          );
        } catch (e) {
          final msg = e.toString().toLowerCase();
          final isTransient =
              msg.contains('software caused connection abort') ||
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
      debugPrint('Profile sync failed: $e');
      return _finishSync(
        userId,
        generation,
        ProfileSyncStatus.failed,
        error: e,
      );
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

Map<String, Map<String, BasicFieldAdminReview>> _prevAdminReviews = {};
final basicFieldAdminReviewsProvider =
    StreamProvider.family<Map<String, BasicFieldAdminReview>, String>((
      ref,
      userId,
    ) {
      List<String> toStringList(dynamic v) {
        if (v == null) return const [];
        if (v is List) {
          return v
              .map((e) => e.toString())
              .where((s) => s.trim().isNotEmpty)
              .toList(growable: false);
        }
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
          if (review.status != 'pending' &&
              review.status != 'approved' &&
              review.status != 'rejected') {
            continue;
          }
          final when =
              review.updatedAt ??
              review.reviewedAt ??
              DateTime.fromMillisecondsSinceEpoch(0);
          for (final k in keys) {
            if (!requested.contains(k)) continue;
            final prev = latestAt[k];
            if (prev == null || when.isAfter(prev)) {
              latestAt[k] = when;
              out[k] = review;
            }
          }
        }

        debugPrint(
          '[ProfileProvider] 📋 basicFieldAdminReviewsProvider output: out=$out (${rows.length} rows)',
        );

        final prevForUser = _prevAdminReviews[userId];
        if (prevForUser != null) {
          bool anyStatusChanged = false;
          for (final entry in out.entries) {
            if (prevForUser[entry.key]?.status != entry.value.status) {
              anyStatusChanged = true;
              break;
            }
          }
          if (!anyStatusChanged) {
            for (final entry in prevForUser.entries) {
              if (out[entry.key]?.status != entry.value.status) {
                anyStatusChanged = true;
                break;
              }
            }
          }
          if (anyStatusChanged && userId == supabase.auth.currentUser?.id) {
            debugPrint(
              '[ProfileProvider] 📋 review status change detected! prev=$prevForUser current=$out',
            );
            unawaited(() async {
              try {
                await ref
                    .read(profileSyncProvider)
                    .syncProfile(userId, source: 'admin-review-change');
                debugPrint(
                  '[ProfileProvider] ✅ admin review syncProfile completed',
                );
                if (ref.mounted) {
                  ref.invalidate(userProfileProvider(userId));
                }
              } catch (e) {
                debugPrint(
                  '[ProfileProvider] admin review syncProfile failed: $e',
                );
              }
            }());
          } else if (anyStatusChanged) {
            debugPrint(
              '[ProfileProvider] ⏭️ review status changed but not current user',
            );
          } else {
            debugPrint(
              '[ProfileProvider] 🔍 admin reviews emitted, no status change. prevKeys=${prevForUser.keys} outKeys=${out.keys}',
            );
          }
        }
        _prevAdminReviews[userId] = out;

        return out;
      });
    });

/// --- userProfileProvider ---------------------------------------------------
final Map<String, DateTime> _profileSyncAttemptAt = {};
final Map<String, DateTime> _otherUserProfileRefreshAttemptAt = {};

/// Tracks the last time the wizard (or any local edit) wrote the profile to
/// the local DB. Realtime `users`-table events that fire mid-save must not
/// overwrite that fresh local data with a stale server fetch that started
/// before the save completed. See `saveProfile` (writes) and `syncProfile`
/// + `currentUserUsersTableProvider` (guarded reads).
final Map<String, DateTime> _lastProfileLocalSaveAt = {};

/// Resets sync throttles after an account session ends. Otherwise a fast
/// logout/login of the same account can be incorrectly treated as a duplicate
/// sync even though its local profile cache has just been wiped.
void clearUserScopedProfileMemoryCaches(String userId) {
  _profileSyncAttemptAt.remove(userId);
  _lastProfileLocalSaveAt.remove(userId);
  _otherUserProfileRefreshAttemptAt.clear();
}

void _markProfileLocalSave(String userId) {
  _lastProfileLocalSaveAt[userId] = DateTime.now();
}

/// True when a local save landed after [fetchStartedAt], meaning a server
/// fetch that began at [fetchStartedAt] is stale and must not overwrite
/// the local DB.
bool _localSaveIsNewerThan(String userId, DateTime fetchStartedAt) {
  final lastSave = _lastProfileLocalSaveAt[userId];
  return lastSave != null && lastSave.isAfter(fetchStartedAt);
}

/// True when a wizard/local save completed very recently — the local DB is
/// already authoritative and a realtime-triggered sync would only risk
/// fetching mid-write (stale) server state.
bool _hasVeryRecentLocalSave(String userId, Duration window) {
  final lastSave = _lastProfileLocalSaveAt[userId];
  if (lastSave == null) return false;
  return DateTime.now().difference(lastSave) < window;
}

bool _shouldAttemptProfileSync(String userId, Duration minInterval) {
  final now = DateTime.now();
  final last = _profileSyncAttemptAt[userId];
  if (last != null && now.difference(last) < minInterval) return false;
  _profileSyncAttemptAt[userId] = now;
  return true;
}

bool _shouldAttemptOtherUserProfileRefresh(
  String userId,
  Duration minInterval,
) {
  final now = DateTime.now();
  final last = _otherUserProfileRefreshAttemptAt[userId];
  if (last != null && now.difference(last) < minInterval) return false;
  _otherUserProfileRefreshAttemptAt[userId] = now;
  return true;
}

bool _hasCompleteOtherUserProfileForHome(UserProfile profile) {
  final name = profile.name.trim();
  final hasName =
      name.isNotEmpty &&
      name.toLowerCase() != 'unnamed' &&
      name.toLowerCase() != 'unknown user';
  final hasInterests = profile.interests.values.any(
    (interests) => interests.isNotEmpty,
  );
  return hasName && profile.photos.isNotEmpty && hasInterests;
}

Map<String, dynamic> _mergeOtherUserProfileData(
  Map<String, dynamic> cached,
  Map<String, dynamic> remote,
) {
  final merged = Map<String, dynamic>.from(cached)..remove('cached_at');
  for (final entry in remote.entries) {
    if (entry.value == null && merged.containsKey(entry.key)) continue;
    merged[entry.key] = entry.value;
  }
  return merged;
}

final localUserProfileProvider = StreamProvider.family<UserProfile?, String>((
  ref,
  userId,
) {
  final localDb = ref.watch(localDbProvider);
  return localDb.watchLocalProfile(userId).map((localProfileMap) {
    if (localProfileMap == null) return null;
    return UserProfile.fromMap(localProfileMap);
  });
});

final StreamProviderFamily<UserProfile?, String>
userProfileProvider = StreamProvider.family<UserProfile?, String>((
  ref,
  userId,
) {
  final localDb = ref.watch(localDbProvider);

  try {
    ResumeDiagnostics.log('userProfileProvider created for user=$userId');
    ref.onDispose(
      () => ResumeDiagnostics.log(
        'userProfileProvider disposed for user=$userId',
      ),
    );
  } catch (_) {}

  // Watch the realtime stream for the current user to keep the local database synchronized in realtime.
  final currentUserId = supabase.auth.currentUser?.id;
  final isCurrentUser =
      currentUserId != null &&
      currentUserId.isNotEmpty &&
      currentUserId == userId;
  if (isCurrentUser) {
    ref.watch(currentUserUsersTableProvider);
  }

  final localStream = localDb.watchLocalProfile(userId);
  return localStream.map((localProfileMap) {
    if (localProfileMap == null) {
      unawaited(() {
        debugPrint(
          '[ProfileProvider] userProfileProvider triggered syncProfile',
        );
        return ref.read(profileSyncProvider).syncProfile(userId);
      }());
      return null;
    }
    debugPrint('[ProfileProvider] userProfileProvider has local data');

    final hasSubscriptionExpiryFields =
        localProfileMap.containsKey('subscription_expires_at') ||
        localProfileMap.containsKey('subscriptionExpiresAt');
    if (!hasSubscriptionExpiryFields) {
      unawaited(() {
        debugPrint(
          '[ProfileProvider] userProfileProvider missing subscription expiry fields; syncing',
        );
        return ref.read(profileSyncProvider).syncProfile(userId);
      }());
    }

    final currentUserId = supabase.auth.currentUser?.id;
    final isOtherUser =
        currentUserId != null &&
        currentUserId.isNotEmpty &&
        currentUserId != userId;
    if (isOtherUser) {
      DateTime? cachedAt;
      final rawCachedAt =
          localProfileMap['_cached_at'] ?? localProfileMap['cached_at'];
      if (rawCachedAt != null) {
        cachedAt = DateTime.tryParse(rawCachedAt.toString());
      }
      final isStale =
          cachedAt == null ||
          DateTime.now().difference(cachedAt) > const Duration(minutes: 1);
      if (isStale &&
          _shouldAttemptProfileSync(userId, const Duration(seconds: 30))) {
        unawaited(() {
          debugPrint(
            '[ProfileProvider] userProfileProvider stale other-user cache; syncing',
          );
          return ref.read(profileSyncProvider).syncProfile(userId);
        }());
      }
    }

    return UserProfile.fromMap(localProfileMap);
  });
});

/// --- currentUserUsersTableProvider -----------------------------------------
/// Watches the current user's `users` table row via Supabase Realtime (.stream()).
/// When the row changes (admin edits profile, changes verification, etc.), it
/// triggers a syncProfile so local DB + userProfileProvider reflect the update.
final currentUserUsersTableProvider = StreamProvider<Map<String, dynamic>?>((
  ref,
) {
  final currentUserId = supabase.auth.currentUser?.id;
  if (currentUserId == null || currentUserId.isEmpty) return Stream.value(null);

  final stream = supabase
      .from('users')
      .stream(primaryKey: const ['id'])
      .eq('id', currentUserId);

  debugPrint('[ProfileProvider] 📡 currentUserUsersTableProvider created');
  return stream
      .asyncMap((rows) async {
        if (rows.isEmpty) {
          debugPrint('[ProfileProvider] 📡 users stream: empty rows');
          return null;
        }
        final row = rows.first;
        debugPrint(
          '[ProfileProvider] 📡 users stream: row id=${row['id']} editableFields=${row['editable_profile_fields']}',
        );
        // Realtime guarantee for wizard saves: the wizard writes the local
        // DB first and the server second. A realtime event caused by our own
        // save can arrive while user_profiles is still mid-write — syncing
        // now would fetch stale server data and overwrite the fresh local
        // profile (making the ProfileScreen look stale). Skip the sync when
        // a local save just landed; the local DB is already authoritative.
        if (_hasVeryRecentLocalSave(
          currentUserId,
          const Duration(seconds: 5),
        )) {
          debugPrint(
            '[ProfileProvider] ⏭️ users stream: skipping sync (recent wizard/local save)',
          );
          return row;
        }
        try {
          await ref
              .read(profileSyncProvider)
              .syncProfile(currentUserId, source: 'users-table-realtime');
          debugPrint('[ProfileProvider] ✅ users stream syncProfile completed');
        } catch (e) {
          debugPrint('[ProfileProvider] users table sync failed: $e');
        }
        if (ref.mounted) {
          ref.invalidate(userProfileProvider(currentUserId));
          debugPrint(
            '[ProfileProvider] ✅ users stream invalidated userProfileProvider',
          );
        }
        return row;
      })
      .handleError((e) {
        debugPrint('[ProfileProvider] users table stream error: $e');
      });
});

/// --- otherUserProfileProvider ----------------------------------------------
/// Fetches and caches other users' profiles for better performance
final otherUserProfileProvider = FutureProvider.family<UserProfile?, String>((
  ref,
  userId,
) async {
  if (userId.isEmpty) return null;

  final localDb = ref.read(localDbProvider);

  try {
    final isOnline = ref.read(connectivityProvider).value ?? true;
    // Try cached profile first
    final cachedProfileWithMeta = await localDb
        .getOtherUserProfileWithCacheMeta(userId);
    if (cachedProfileWithMeta != null) {
      if (kIsWeb) {
        debugPrint('🔍 [WEB] otherUserProfileProvider - Using cached profile');
      }
      DateTime? cachedAt;
      final rawCachedAt = cachedProfileWithMeta['cached_at'];
      if (rawCachedAt != null) {
        cachedAt = DateTime.tryParse(rawCachedAt.toString());
      }

      final clean = Map<String, dynamic>.from(cachedProfileWithMeta)
        ..remove('cached_at');
      final cached = UserProfile.fromMap(clean);

      final isStale =
          cachedAt == null ||
          DateTime.now().difference(cachedAt) > const Duration(minutes: 1);
      final isIncompleteForHome =
          !_hasCompleteOtherUserProfileForHome(cached);
      if (isOnline &&
          (isStale || isIncompleteForHome) &&
          _shouldAttemptOtherUserProfileRefresh(
            userId,
            const Duration(seconds: 30),
          )) {
        unawaited(() async {
          try {
            final userRow = await supabase
                .from('users')
                .select(
                  'id,name,date_of_birth,gender,preferred_language,subscription_tier,subscription_expires_at,is_profile_complete,match_radius_default,gps_interval_default,smart_gps_throttling_enabled,shared_event_matching_enabled,shared_movement_matching_enabled,editable_profile_fields,is_verified,verification_status,verification_submitted_at,verification_reviewed_at,referral_code,credits',
                )
                .eq('id', userId)
                .maybeSingle();
            if (userRow == null) return;

            final profileRow = await supabase
                .from('user_profiles')
                .select('*')
                .eq('user_id', userId)
                .maybeSingle();

            final response = <String, dynamic>{...userRow};
            if (profileRow != null) {
              response.addAll(Map<String, dynamic>.from(profileRow));
            }
            await localDb.saveOtherUserProfile(
              userId,
              _mergeOtherUserProfileData(clean, response),
            );
            if (ref.mounted) {
              ref.invalidateSelf();
            }
          } catch (_) {}
        }());
      }

      return cached;
    }

    if (!isOnline) return null;

    if (kIsWeb) {
      debugPrint('🔍 [WEB] otherUserProfileProvider - Fetching fresh profile');
    }

    // Fetch from Supabase - get both user and profile data
    final profileResponses = await supabase
        .from('user_profiles')
        .select('*')
        .eq('user_id', userId)
        .maybeSingle();

    final userResponse = await supabase
        .from('users')
        .select(
          'id,name,date_of_birth,gender,preferred_language,subscription_tier,subscription_expires_at,is_profile_complete,match_radius_default,gps_interval_default,smart_gps_throttling_enabled,shared_event_matching_enabled,shared_movement_matching_enabled,editable_profile_fields,is_verified,verification_status,verification_submitted_at,verification_reviewed_at,referral_code,credits',
        )
        .eq('id', userId)
        .maybeSingle();

    if (profileResponses == null && userResponse == null) {
      throw Exception('No profile or user found for user $userId');
    }

    final response = <String, dynamic>{};
    if (userResponse != null) {
      response.addAll(Map<String, dynamic>.from(userResponse));
    }
    if (profileResponses != null) {
      response.addAll(Map<String, dynamic>.from(profileResponses));
    }

    // Debug: log available keys to help diagnose missing fields in the UI
    try {
      debugPrint(
        '🔍 otherUserProfileProvider response keys: ${response.keys.toList()}',
      );
    } catch (_) {}

    // Convert to UserProfile format and cache
    final userProfile = UserProfile.fromMap(response);
    await localDb.saveOtherUserProfile(userId, response);

    return userProfile;
  } catch (e) {
    debugPrint('Error fetching other user profile: $e');
    return null;
  }
});

/// --- specificProfileProvider ----------------------------------------------
/// Intent-specific profile slice (bio, sub-intents + interests).
/// Cache-first (memory via provider + Hive local storage): returns cached
/// snapshot instantly on UI startup, refreshes from Supabase in background.
final specificProfileProvider =
    FutureProvider.family<IntentProfileData?, Map<String, String>>((
      ref,
      params,
    ) async {
      final userId = params['userId'] ?? '';
      final intentType = params['intentType'] ?? '';
      if (userId.isEmpty || intentType.isEmpty) return null;

      IntentProfileData? fromResponse(Map<String, dynamic> response) {
        final bio = response['bio']?.toString() ?? 'No bio provided.';

        // Extract sub_intents for this specific intent
        List<String> subIntentsList = [];
        final subIntentsRaw = response['sub_intents'];
        if (subIntentsRaw is Map && subIntentsRaw[intentType] != null) {
          subIntentsList = _toStringList(subIntentsRaw[intentType]);
        }

        // Interests are shared across intents (personal + business)
        final Map<String, List<String>> interestsMap = {};
        final personalInterests = response['personal_interests'];
        final businessInterests = response['business_interests'];
        if (personalInterests is Map) {
          personalInterests.forEach((k, v) {
            interestsMap[k.toString()] = _toStringList(v);
          });
        }
        if (businessInterests is Map) {
          businessInterests.forEach((k, v) {
            if (!interestsMap.containsKey(k.toString())) {
              interestsMap[k.toString()] = _toStringList(v);
            }
          });
        }

        return IntentProfileData(
          bio: bio,
          subIntents: subIntentsList,
          interests: interestsMap,
        );
      }

      Future<void> refreshInBackground() async {
        try {
          final localDb = ref.read(localDbProvider);
          // New schema: single-row user_profiles with sub_intents as JSONB map
          final response = await supabase
              .from('user_profiles')
              .select(
                'bio, sub_intents, personal_interests, business_interests',
              )
              .eq('user_id', userId)
              .maybeSingle();
          if (response == null) return;
          try {
            await localDb.saveCachedSpecificProfile(
              userId,
              intentType,
              Map<String, dynamic>.from(response as Map),
            );
          } catch (_) {}
          try {
            ref.invalidateSelf();
          } catch (_) {}
        } catch (_) {}
      }

      // 1) Local storage first — instant.
      try {
        final localDb = ref.read(localDbProvider);
        final cached = await localDb.getCachedSpecificProfile(
          userId,
          intentType,
        );
        if (cached != null && cached.isNotEmpty) {
          final parsed = fromResponse(cached);
          if (parsed != null) {
            unawaited(refreshInBackground());
            return parsed;
          }
        }
      } catch (_) {}

      // 2) No cache: fetch, then save to BOTH layers.
      // New schema: single-row user_profiles with sub_intents as JSONB map
      final response = await supabase
          .from('user_profiles')
          .select('bio, sub_intents, personal_interests, business_interests')
          .eq('user_id', userId)
          .maybeSingle();

      if (response == null) return null;

      try {
        final localDb = ref.read(localDbProvider);
        await localDb.saveCachedSpecificProfile(
          userId,
          intentType,
          Map<String, dynamic>.from(response as Map),
        );
      } catch (_) {}

      return fromResponse(Map<String, dynamic>.from(response as Map));
    });

/// ---------------------------------------------------------------------------
/// profileEditProvider + ProfileEditNotifier
/// ---------------------------------------------------------------------------
@riverpod
class ProfileEditNotifier extends _$ProfileEditNotifier {
  final Set<String> _wizardUploadedPhotoPaths = <String>{};
  DateTime? _lastBasicFieldEditAt;
  List<String>? _editableFieldsBeforeRecentEdit;
  int _profileLoadCount = 0;
  DateTime? _lastRadiusChangeAt;

  @override
  AsyncValue<UserProfile?> build(String userId) {
    state = const AsyncLoading();
    ref.listen<AsyncValue<UserProfile?>>(userProfileProvider(userId), (
      previous,
      next,
    ) {
      final remoteProfile = next.asData?.value;
      if (remoteProfile == null) return;
      UserProfile? currentProfile;
      try {
        currentProfile = state.value;
      } catch (_) {
        currentProfile = null;
      }
      if (currentProfile == null) {
        // Defer the seed until the microtask queue drains. Screens such as the
        // profile wizard call loadInitialProfile() immediately after reading
        // this notifier; a pending load merges the saved wizard draft into the
        // profile. Seeding synchronously here would apply the raw (draft-less)
        // cached profile first, so the wizard would initialize its fields and
        // page index from un-merged data — making everything the user entered
        // before an app restart appear lost.
        Future.microtask(() {
          if (!ref.mounted) return;
          if (_profileLoadCount > 0) return;
          if (state.value != null) return;
          state = AsyncData(remoteProfile.copyWith());
        });
        return;
      }

      final hasRecentRadiusChange =
          _lastRadiusChangeAt != null &&
          DateTime.now().difference(_lastRadiusChangeAt!) <
              const Duration(seconds: 10);
      final shouldApplyRealtimeSettings =
          (!hasRecentRadiusChange &&
                  currentProfile.matchRadiusDefault !=
                      remoteProfile.matchRadiusDefault) ||
          currentProfile.gpsIntervalDefault !=
              remoteProfile.gpsIntervalDefault ||
          currentProfile.smartGpsThrottlingEnabled !=
              remoteProfile.smartGpsThrottlingEnabled ||
          currentProfile.sharedEventMatchingEnabled !=
              remoteProfile.sharedEventMatchingEnabled ||
          currentProfile.sharedMovementMatchingEnabled !=
              remoteProfile.sharedMovementMatchingEnabled ||
          !listEquals(
            currentProfile.editableProfileFields,
            remoteProfile.editableProfileFields,
          ) ||
          // Verification changes are made server-side by admins (or by the
          // verification flow), never by this editor, so apply them in
          // realtime without risking user-edit conflicts.
          currentProfile.verificationStatus !=
              remoteProfile.verificationStatus ||
          currentProfile.isVerified != remoteProfile.isVerified ||
          currentProfile.verificationSubmittedAt !=
              remoteProfile.verificationSubmittedAt ||
          currentProfile.verificationReviewedAt !=
              remoteProfile.verificationReviewedAt;
      debugPrint(
        '[ProfileEditNotifier] 📋 userProfileProvider emit: shouldApply=$shouldApplyRealtimeSettings '
        'currentEditable=${currentProfile.editableProfileFields} '
        'remoteEditable=${remoteProfile.editableProfileFields}',
      );
      if (!shouldApplyRealtimeSettings) {
        debugPrint(
          '[ProfileEditNotifier] ⏭️ no relevant changes, skipping state update',
        );
        return;
      }

      final hasRecentBasicEdit =
          _lastBasicFieldEditAt != null &&
          DateTime.now().difference(_lastBasicFieldEditAt!) <
              const Duration(seconds: 10);
      final localFieldSet = currentProfile.editableProfileFields.toSet();
      final mergedEditable = hasRecentBasicEdit
          ? <String>[
              ...currentProfile.editableProfileFields,
              ...remoteProfile.editableProfileFields.where(
                (f) =>
                    !localFieldSet.contains(f) &&
                    !(_editableFieldsBeforeRecentEdit?.contains(f) ?? false),
              ),
            ]
          : remoteProfile.editableProfileFields;

      state = AsyncData(
        currentProfile.copyWith(
          matchRadiusDefault: hasRecentRadiusChange
              ? currentProfile.matchRadiusDefault
              : remoteProfile.matchRadiusDefault,
          gpsIntervalDefault: remoteProfile.gpsIntervalDefault,
          smartGpsThrottlingEnabled: remoteProfile.smartGpsThrottlingEnabled,
          sharedEventMatchingEnabled: remoteProfile.sharedEventMatchingEnabled,
          sharedMovementMatchingEnabled:
              remoteProfile.sharedMovementMatchingEnabled,
          editableProfileFields: mergedEditable,
          verificationStatus: remoteProfile.verificationStatus,
          isVerified: remoteProfile.isVerified,
          verificationSubmittedAt: remoteProfile.verificationSubmittedAt,
          verificationReviewedAt: remoteProfile.verificationReviewedAt,
        ),
      );
    }, fireImmediately: true);
    return state;
  }

  Future<void> _cleanupWizardUploadedPhotosNotIn(Set<String> keep) async {
    final toDelete = _wizardUploadedPhotoPaths
        .where((p) => p.isNotEmpty && !keep.contains(p))
        .toList();
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
          .from('user_profiles')
          .select('approved_primary_photos')
          .eq('user_id', userId)
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

    // Crop tightly to the face (face + 20% margin — a neck-up headshot), then
    // trim further to exclude text regions where the geometry allows; anything
    // still overlapping the crop is pixelated below. The old 2x-face rule kept
    // offending cards in frame on close-up selfies, where the face was already
    // so large that the "generous" crop equaled the whole image.
    final facePadX = faceW * 0.2;
    final facePadY = faceH * 0.2;
    final minCropSide = math.min(wPx, hPx) * 0.35;

    var left = math.max(0.0, (fx - facePadX) * wPx);
    var top = math.max(0.0, (fy - facePadY) * hPx);
    var right = math.min(wPx, (fx + fw + facePadX) * wPx);
    var bottom = math.min(hPx, (fy + fh + facePadY) * hPx);

    // Never let the crop get absurdly small if the face box was tiny.
    if (right - left < minCropSide) {
      final c = (fx + fw / 2) * wPx;
      left = math.max(0.0, c - minCropSide / 2);
      right = math.min(wPx, c + minCropSide / 2);
    }
    if (bottom - top < minCropSide) {
      final c = (fy + fh / 2) * hPx;
      top = math.max(0.0, c - minCropSide / 2);
      bottom = math.min(hPx, c + minCropSide / 2);
    }

    // Trim the crop to exclude text boxes, keeping the face fully inside.
    // Whatever cannot be excluded without cutting into the face stays in the
    // crop and is pixelated by the loop below.
    final xGap = 0.01 * wPx;
    final yGap = 0.01 * hPx;
    final faceMinPadY = faceH * 0.05;
    final faceTopPx = fy * hPx;
    final faceBottomPx = (fy + fh) * hPx;
    final faceLeftPx = fx * wPx;
    final faceRightPx = (fx + fw) * wPx;
    final faceCenterX = (fx + fw / 2) * wPx;
    final faceCenterY = (fy + fh / 2) * hPx;

    for (final tb in textBoxes) {
      final tx = toD(tb['x']).clamp(0, 1);
      final ty = toD(tb['y']).clamp(0, 1);
      final tw = toD(tb['w']).clamp(0, 1);
      final th = toD(tb['h']).clamp(0, 1);
      if (tw <= 0 || th <= 0) continue;

      final tLeft = tx * wPx;
      final tTop = ty * hPx;
      final tRight = tLeft + tw * wPx;
      final tBottom = tTop + th * hPx;
      if (tRight <= left || tLeft >= right || tBottom <= top || tTop >= bottom) {
        continue; // already outside the crop
      }

      if (tTop >= faceCenterY) {
        // Text below the face — pull the bottom edge up if the face still fits.
        final candidate = math.min(bottom, tTop - yGap);
        if (candidate >= faceBottomPx + faceMinPadY && candidate > top) {
          bottom = candidate;
        }
      } else if (tBottom <= faceCenterY) {
        // Text above the face — push the top edge down.
        final candidate = math.max(top, tBottom + yGap);
        if (candidate <= faceTopPx + 1 && candidate < bottom) {
          top = candidate;
        }
      } else if (tLeft >= faceCenterX) {
        // Text to the right of the face — pull the right edge in.
        final candidate = math.max(left, tRight + xGap);
        if (candidate <= faceLeftPx + 1 && candidate < right) {
          right = candidate;
        }
      } else if (tRight <= faceCenterX) {
        // Text to the left of the face — pull the left edge in.
        final candidate = math.min(right, tLeft - xGap);
        if (candidate >= faceRightPx - 1 && candidate > left) {
          right = candidate;
        }
      }
    }

    var cropLeft = left.round().clamp(0, decoded.width);
    var cropTop = top.round().clamp(0, decoded.height);
    var cropW = (right - left).round().clamp(1, decoded.width);
    var cropH = (bottom - top).round().clamp(1, decoded.height);
    if (cropLeft + cropW > decoded.width) cropW = decoded.width - cropLeft;
    if (cropTop + cropH > decoded.height) cropH = decoded.height - cropTop;

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
      img.compositeImage(
        cropped,
        up,
        dstX: rx,
        dstY: ry,
        blend: img.BlendMode.direct,
      );
    }

    final outBytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 90));

    final uploader = ref.read(profileEditRequestServiceProvider);
    final uuid = const Uuid().v4();
    final newPath =
        '$userId/${DateTime.now().millisecondsSinceEpoch}_clean_$uuid.jpg';
    final uploaded = await uploader.uploadBytesToStorage(
      newPath,
      outBytes,
      public: false,
    );
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

  /// Builds a structured photo rejection from a moderation edge-function
  /// response so the wizard can show the user exactly what was wrong with the
  /// photo: Gemini's explanation plus highlighted regions. The Gemini message
  /// is translated into the UI language (and cached) when needed; the fixed
  /// wording from [fallbackKey] (or the server-provided translationKey) is the
  /// guaranteed baseline.
  Future<PhotoModerationRejection> _buildPhotoModerationRejection({
    required dynamic data,
    required String? reasonCode,
    required String fallbackKey,
    bool includeFaceBox = true,
    String? photoPath,
  }) async {
    final locale = ref.read(localizationProvider);
    final serverKey = data is Map && data['translationKey'] is String
        ? data['translationKey'] as String
        : null;
    final fixedKey =
        serverKey != null && serverKey.isNotEmpty ? serverKey : fallbackKey;
    final fixedMessage = locale.getString(fixedKey);

    String displayMessage = fixedMessage;
    final geminiMessage = data is Map && data['message'] is String
        ? data['message'] as String
        : null;
    if (geminiMessage != null && geminiMessage.isNotEmpty) {
      displayMessage = geminiMessage;
      try {
        final l10n = ref.read(localizationProvider);
        final uiLang = l10n.currentLocale.languageCode;
        if (uiLang != 'en') {
          final translationService = ref.read(translationServiceProvider);
          // Gemini is prompted in English; treat detection failure as English
          // rather than skipping the translation entirely.
          String sourceLang = 'en';
          try {
            final detected = await translationService.identifyLanguage(
              geminiMessage,
            );
            if (detected.isNotEmpty && detected != 'und') sourceLang = detected;
          } catch (_) {}
          if (sourceLang != uiLang) {
            final cacheKey =
                'gemini_photo_msg_${geminiMessage.hashCode}_$uiLang';
            final prefs = await SharedPreferences.getInstance();
            final cached = prefs.getString(cacheKey);
            if (cached != null && cached.isNotEmpty) {
              displayMessage = cached;
            } else {
              try {
                final translated = await translationService
                    .translateText(geminiMessage, sourceLang, uiLang)
                    .timeout(const Duration(seconds: 20));
                // DeepL returns the original text when it fails silently;
                // treat that as a failed translation.
                if (translated.isNotEmpty && translated != geminiMessage) {
                  displayMessage = translated;
                  await prefs.setString(cacheKey, translated);
                } else {
                  debugPrint(
                    '[photoModeration] DeepL returned no translation for '
                    'gemini photo message (lang=$uiLang)',
                  );
                }
              } catch (e) {
                debugPrint(
                  '[photoModeration] DeepL translation failed for gemini '
                  'photo message (lang=$uiLang): $e',
                );
              }
            }
          }
          // Never show English text in a non-English UI: fall back to the
          // fixed, pre-translated wording from the translations table.
          if (displayMessage == geminiMessage) {
            displayMessage = fixedMessage;
          }
        }
      } catch (e) {
        debugPrint('[photoModeration] rejection message handling failed: $e');
      }
    }

    final sexualContent =
        data is Map && data['sexualContent'] is String
        ? data['sexualContent'] as String
        : 'none';
    final isContentRejection =
        reasonCode == 'BAD_CONTENT' ||
        sexualContent == 'suggestive' ||
        sexualContent == 'explicit';

    final issueBoxes = <PhotoIssueBox>[];
    if (!isContentRejection) {
      if (data is Map && data['issueBoxes'] is List) {
        for (final entry in data['issueBoxes'] as List) {
          final box = PhotoIssueBox.fromJson(entry, fallbackLabel: 'text');
          if (box != null) issueBoxes.add(box);
        }
      }
      if (data is Map && data['textBoxes'] is List) {
        for (final entry in data['textBoxes'] as List) {
          final box = PhotoIssueBox.fromJson(entry, fallbackLabel: 'text');
          if (box != null) issueBoxes.add(box);
        }
      }
      // The face box is drawn only when the face is what the rejection is
      // about, or when a reported issue region actually overlaps it (e.g.
      // text on the face). A pure document rejection with the card elsewhere
      // must not paint a perfectly fine face as if it were the problem.
      const faceSubjectReasons = {
        'NO_PERSON',
        'FACE_NOT_VISIBLE',
        'MULTIPLE_PEOPLE',
        'VERIFIED_SELFIE_MISMATCH',
      };
      final faceBox = includeFaceBox
          ? PhotoIssueBox.fromJson(
              data is Map ? data['faceBox'] : null,
              fallbackLabel: 'face',
            )
          : null;
      if (faceBox != null) {
        final faceInvolved =
            faceSubjectReasons.contains(reasonCode) ||
            issueBoxes.any((box) => _boxOverlapsFace(box, faceBox));
        if (faceInvolved) issueBoxes.add(faceBox);
      }
    }

    return PhotoModerationRejection(
      displayMessage: displayMessage,
      translationKey: fixedKey,
      reasonCode: reasonCode,
      issueBoxes: issueBoxes,
      photoPath: photoPath,
      fullImageIssue: isContentRejection,
    );
  }

  /// True when [box] overlaps enough of [face] to be "on the face" — either
  /// a quarter of the issue box, or a visible slice of the face itself.
  bool _boxOverlapsFace(PhotoIssueBox box, PhotoIssueBox face) {
    final ix =
        (box.x + box.w).clamp(0.0, face.x + face.w) -
        box.x.clamp(face.x, face.x + face.w);
    final iy =
        (box.y + box.h).clamp(0.0, face.y + face.h) -
        box.y.clamp(face.y, face.y + face.h);
    final intersection = (ix <= 0 || iy <= 0) ? 0.0 : ix * iy;
    final boxArea = box.w * box.h;
    final faceArea = face.w * face.h;
    if (boxArea <= 0 || faceArea <= 0) return false;
    return intersection / boxArea >= 0.25 || intersection / faceArea >= 0.08;
  }

  Future<String> _ensurePrimaryPhotoAllowed(
    String photoPath, {
    int sanitizePass = 0,
  }) async {
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

      dynamic resp;
      try {
        resp = await Supabase.instance.client.functions
            .invoke(
              'validate-primary-photo',
              body: {
                'photoPath': photoPath,
                // Capability flag: the server may sanitize the photo itself
                // (crop out the flagged text) and approve the cleaned copy in
                // the same call — no second AI round-trip.
                'clientSupportsServerSanitize': true,
              },
            )
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // TimeoutException (client gave up while the server retries its model
        // chain) and FunctionsHttpException (the functions client throws on
        // non-2xx, e.g. the 503 "Gemini unavailable" response) must both
        // surface as the localized photo-system error — never raw exception
        // text or a connectivity message.
        final locale = ref.read(localizationProvider);
        throw Exception(
          locale.getString('primaryPhotoVerificationErrorSystem'),
        );
      }

      if (resp.status != 200) {
        final locale = ref.read(localizationProvider);
        throw Exception(
          locale.getString('primaryPhotoVerificationErrorSystem'),
        );
      }

      dynamic data = resp.data;
      if (data is String && data.trim().isNotEmpty) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      // Server-side sanitize: the function cropped the flagged text out of
      // the photo itself and approved the cleaned copy — swap to its path.
      if (data is Map && data['serverSanitized'] == true && data['photoPath'] is String) {
        final sanitizedPath = data['photoPath'] as String;
        if (sanitizedPath.isNotEmpty && sanitizedPath != photoPath) {
          approved.add(sanitizedPath);
          await localDb.setApprovedPrimaryPhotos(userId, approved);
          // Keep wizard bookkeeping in sync with the swap (mirrors the
          // local sanitize path in _sanitizePrimaryPhoto): callers add the
          // original upload to _wizardUploadedPhotoPaths before validation,
          // so without this the sanitized copy is never draft-cleaned and
          // the stale original would be.
          if (_wizardUploadedPhotoPaths.remove(photoPath)) {
            _wizardUploadedPhotoPaths.add(sanitizedPath);
          }
          return sanitizedPath;
        }
      }

      final allow = data is Map && data['allow'] == true;
      final reasonCode = data is Map && data['reasonCode'] is String
          ? data['reasonCode'] as String
          : null;
      final action = data is Map && data['action'] is String
          ? (data['action'] as String)
          : null;

      if (action == 'SANITIZE' && !allow) {
        if (sanitizePass >= 1) {
          // The auto-crop/pixelate pipeline ran once and the validator still
          // flags text. Throw the structured rejection so the wizard can show
          // the uploaded photo with the remaining text regions highlighted.
          // The server's generic SANITIZE translationKey is dropped so the
          // StillText wording is the fixed baseline.
          final stillTextData = data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
          stillTextData['translationKey'] = null;
          throw await _buildPhotoModerationRejection(
            data: stillTextData,
            reasonCode: 'STILL_TEXT',
            fallbackKey: 'primaryPhotoVerificationErrorStillText',
            // The issue is the leftover text, not the face — mark only the
            // text regions.
            includeFaceBox: false,
            // The sanitized copy replaced the original upload in storage, so
            // the dialog must render THESE bytes.
            photoPath: photoPath,
          );
        }

        final faceBox = data is Map && data['faceBox'] is Map
            ? Map<String, dynamic>.from(data['faceBox'] as Map)
            : null;
        final textBoxes = data is Map && data['textBoxes'] is List
            ? (data['textBoxes'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
            : <Map<String, dynamic>>[];

        if (faceBox == null || faceBox.isEmpty) {
          final locale = ref.read(localizationProvider);
          throw Exception(
            locale.getString('primaryPhotoVerificationErrorGeneral'),
          );
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
          throw Exception(
            locale.getString('primaryPhotoVerificationErrorSystem'),
          );
        }

        return await _ensurePrimaryPhotoAllowed(
          sanitizedPath,
          sanitizePass: sanitizePass + 1,
        );
      }

      if (!allow) {
        String fallbackKey;

        switch (reasonCode) {
          case 'NO_PERSON':
            fallbackKey = 'primaryPhotoVerificationErrorNoPerson';
            break;
          case 'FACE_NOT_VISIBLE':
            fallbackKey = 'primaryPhotoVerificationErrorFaceNotVisible';
            break;
          case 'BAD_CONTENT':
            fallbackKey = 'primaryPhotoVerificationErrorBadContent';
            break;
          case 'MULTIPLE_PEOPLE':
            fallbackKey = 'primaryPhotoVerificationErrorMultipleFaces';
            break;
          case 'BODY_SHOT':
            fallbackKey = 'primaryPhotoVerificationErrorBodyNotAllowed';
            break;
          case 'VERIFIED_SELFIE_MISMATCH':
            fallbackKey = 'primaryPhotoVerificationErrorVerifiedMismatch';
            break;
          case 'VERIFIED_REFERENCE_EXPIRED':
            fallbackKey = 'primaryPhotoVerificationErrorReferenceExpired';
            break;
          case 'GENERAL_ERROR':
          default:
            fallbackKey = 'primaryPhotoVerificationErrorGeneral';
            break;
        }

        throw await _buildPhotoModerationRejection(
          data: data,
          reasonCode: reasonCode,
          fallbackKey: fallbackKey,
        );
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

  /// Runs the local primary-photo prescreen on the stored bytes of [photoPath].
  /// Used when a reorder/remove promotes a secondary photo to primary: the
  /// promoted photo must satisfy the same face-only prescreen as a freshly
  /// captured primary selfie before Gemini re-validates it.
  ///
  /// Skips silently (Gemini remains the validator) when the path was already
  /// approved as primary, when bytes cannot be downloaded, or when local ML
  /// is unavailable (web/desktop). Throws a localized message on failure so
  /// callers can revert the promotion and surface the reason.
  Future<void> _prescreenPromotedPrimaryPhoto(String photoPath) async {
    try {
      final localDb = ref.read(localDbProvider);
      final approved = await localDb.loadApprovedPrimaryPhotos(userId);
      if (approved.contains(photoPath)) return;
    } catch (_) {}

    final Uint8List bytes;
    try {
      final signed = await StorageHelper.getSignedUrl(
        photoPath,
        ttlSeconds: 600,
      );
      if (signed == null || signed.isEmpty) return;
      final resp = await http
          .get(Uri.parse(signed))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return;
      bytes = resp.bodyBytes;
    } catch (_) {
      return;
    }
    if (bytes.isEmpty) return;

    PhotoPrescreenResult result;
    try {
      result = await ref
          .read(photoPrescreenServiceProvider)
          .prescreenPhoto(bytes, isPrimary: true);
    } catch (_) {
      return;
    }
    if (result.passed) return;

    final locale = ref.read(localizationProvider);
    throw Exception(
      locale.getString(prescreenFailureL10nKey(result.failureReason)),
    );
  }

  Future<String> _ensureSecondaryPhotoAllowed(String photoPath) async {
    dynamic resp;
    try {
      resp = await Supabase.instance.client.functions
          .invoke('validate-secondary-photo', body: {'photoPath': photoPath})
          .timeout(const Duration(seconds: 120));
    } catch (_) {
      // TimeoutException or FunctionsHttpException (thrown by the functions
      // client on non-2xx): show the photo-system error rather than raw
      // exception text or a connectivity message. Thrown as a translation key
      // (see ErrorLocalizationService).
      throw Exception('secondaryPhotoVerificationErrorSystem');
    }

    if (resp.status != 200) {
      throw Exception('secondaryPhotoVerificationErrorSystem');
    }

    dynamic data = resp.data;
    if (data is String && data.trim().isNotEmpty) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }

    final allow = data is Map && data['allow'] == true;
    if (!allow) {
      throw await _buildPhotoModerationRejection(
        data: data,
        reasonCode: data is Map && data['reasonCode'] is String
            ? data['reasonCode'] as String
            : null,
        fallbackKey: 'secondaryPhotoVerificationErrorGeneral',
      );
    }
    return photoPath;
  }

  Future<void> ensurePrimaryPhotoAllowedForWizard(String photoPath) async {
    final finalPath = await _ensurePrimaryPhotoAllowed(photoPath);
    if (finalPath == photoPath) return;
    // The server-sanitize flow replaced the upload with a cleaned copy:
    // track the new path for draft cleanup and drop stale caches.
    _wizardUploadedPhotoPaths.remove(photoPath);
    _wizardUploadedPhotoPaths.add(finalPath);
    StorageHelper.evict(photoPath);
    StorageHelper.evict(finalPath);
    final current = state.asData?.value;
    if (current == null) {
      // State is mid-reload (AsyncLoading): remember the swap and apply it
      // on the next data emission so the profile can't keep referencing the
      // object the sanitize flow just deleted.
      _pendingPhotoPathSwaps[photoPath] = finalPath;
      return;
    }
    final photos = List<String>.from(current.photos);
    // Match by normalized identity too: state may hold a URL form of the
    // same object, and an exact-only match previously bailed out here,
    // stranding the deleted original as the primary photo.
    final idx = _photoIndexMatching(photos, photoPath);
    if (idx < 0) {
      _pendingPhotoPathSwaps[photoPath] = finalPath;
      return;
    }
    photos[idx] = finalPath;
    state = AsyncData(current.copyWith(photos: photos));
    await saveWizardDraft();
  }

  /// Sanitize/validation swaps that completed while `state` was momentarily
  /// unavailable. Applied on the next data emission (see
  /// [_withPendingPhotoSwapsApplied]) so a reload racing a photo swap can't
  /// resurrect the deleted original path.
  final Map<String, String> _pendingPhotoPathSwaps = {};

  /// Index of [path] in [photos], matching on exact string first and then on
  /// the normalized cache identity (so object paths and their URL forms are
  /// recognized as the same photo).
  int _photoIndexMatching(List<String> photos, String path) {
    final exact = photos.indexOf(path);
    if (exact >= 0) return exact;
    final key = StorageHelper.cacheKeyForSource(path);
    if (key.isEmpty) return -1;
    for (var i = 0; i < photos.length; i++) {
      if (StorageHelper.cacheKeyForSource(photos[i]) == key) return i;
    }
    return -1;
  }

  UserProfile _withPendingPhotoSwapsApplied(UserProfile profile) {
    if (_pendingPhotoPathSwaps.isEmpty) return profile;
    final photos = List<String>.from(profile.photos);
    final applied = <String>[];
    for (final entry in _pendingPhotoPathSwaps.entries) {
      final idx = _photoIndexMatching(photos, entry.key);
      if (idx < 0) continue;
      final newIdx = _photoIndexMatching(photos, entry.value);
      if (newIdx >= 0 && newIdx != idx) {
        // The replacement is already present; just drop the stale original.
        photos.removeAt(idx);
      } else {
        photos[idx] = entry.value;
      }
      applied.add(entry.key);
    }
    for (final key in applied) {
      _pendingPhotoPathSwaps.remove(key);
    }
    if (applied.isEmpty) return profile;
    return profile.copyWith(photos: photos);
  }

  int _wizardCurrentPageIndex = 0;
  int get wizardCurrentPageIndex => _wizardCurrentPageIndex;

  /// Set by [clearWizardDraft] after a successful submit. The wizard's
  /// dispose()/PopScope/page-change handlers call [saveWizardDraft]
  /// unconditionally while unmounting, which would resurrect a draft
  /// (including _wizard_current_page_index) right after the clear — letting
  /// a completed wizard later reopen on the review step with empty content
  /// ("Not set"). Suppressed until the next [loadInitialProfile] starts a
  /// fresh wizard session.
  bool _wizardDraftSuppressed = false;

  void setWizardPageIndex(int index) {
    _wizardCurrentPageIndex = index;
  }

  Future<void> loadInitialProfile({bool applyWizardDraft = false}) async {
    _profileLoadCount++;
    // A new wizard session may write drafts again.
    _wizardDraftSuppressed = false;
    try {
      // Always reload fresh data to ensure we have the latest from server
      state = const AsyncLoading();
      final initialProfile = await ref.read(userProfileProvider(userId).future);
      if (initialProfile != null) {
        var p = initialProfile.copyWith();
        if (applyWizardDraft) {
          p = await _mergeWizardDraft(p);
        }
        p = _withPendingPhotoSwapsApplied(p);
        state = AsyncData(p);
        unawaited(_prewarmSignedUrls(p.photos));
      } else {
        final localDb = ref.read(localDbProvider);
        final syncResult = await ref
            .read(profileSyncProvider)
            .syncProfile(userId, source: 'profile-edit-initial-load');
        final cachedMap = await localDb.getLocalProfile(userId);
        var reloaded = cachedMap == null
            ? null
            : UserProfile.fromMap(cachedMap);
        reloaded ??= await ref.read(userProfileProvider(userId).future);
        if (reloaded == null) {
          throw syncResult.error ??
              StateError('profileSync:${syncResult.status.name}');
        }
        var p = reloaded.copyWith();
        if (applyWizardDraft) {
          p = await _mergeWizardDraft(p);
        }
        p = _withPendingPhotoSwapsApplied(p);
        if (ref.mounted) {
          state = AsyncData(p);
          unawaited(_prewarmSignedUrls(p.photos));
        }
      }
    } catch (e, st) {
      if (ref.mounted) {
        state = AsyncError(e, st);
      }
    } finally {
      _profileLoadCount--;
    }
  }

  Future<void> saveWizardDraft() async {
    // After a successful submit the draft must stay cleared: the wizard's
    // unmount paths fire draft saves that would otherwise resurrect the
    // cleared state (see [_wizardDraftSuppressed]).
    if (_wizardDraftSuppressed) return;
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    final localDb = ref.read(localDbProvider);
    final draftData = p.toMap();
    draftData['_wizard_uploaded_photo_paths'] = _wizardUploadedPhotoPaths
        .toList();
    draftData['_wizard_current_page_index'] = _wizardCurrentPageIndex;
    await localDb.saveProfileWizardDraft(userId, draftData);
  }

  Future<void> clearWizardDraft() async {
    // From here on, unmount-time draft saves (dispose/PopScope) are no-ops
    // until the next loadInitialProfile() starts a fresh wizard session.
    _wizardDraftSuppressed = true;
    final localDb = ref.read(localDbProvider);
    // The keep-set must never be derived from a null/loading state: a
    // concurrent loadInitialProfile() flips the provider to AsyncLoading,
    // and treating that as "the user has no photos" previously deleted
    // already-saved uploads from storage while user_profiles.photos still
    // referenced them (permanently broken photo tile on the next edit).
    // Fall back to the persisted local profile; if that is unavailable
    // too, skip storage deletion entirely — leaking an abandoned upload
    // is recoverable, deleting a saved photo is not.
    Set<String>? keep = state.asData?.value?.photos.toSet();
    if (keep == null) {
      try {
        final persisted = await localDb.getLocalProfile(userId);
        keep = persisted == null
            ? null
            : _toStringList(persisted['photos']).toSet();
      } catch (_) {
        keep = null;
      }
    }
    if (keep != null) {
      final keepSet = keep;
      final keepIds = keepSet
          .where((p) => p.isNotEmpty)
          .map(StorageHelper.cacheKeyForSource)
          .toSet();
      final toDelete = _wizardUploadedPhotoPaths
          .where(
            (p) =>
                p.isNotEmpty &&
                !keepSet.contains(p) &&
                !keepIds.contains(StorageHelper.cacheKeyForSource(p)),
          )
          .toList();
      for (final path in toDelete) {
        try {
          await _deleteStorageObject(path);
        } catch (_) {}
        StorageHelper.evict(path);
        _wizardUploadedPhotoPaths.remove(path);
      }
    }
    _wizardUploadedPhotoPaths.clear();
    _wizardCurrentPageIndex = 0;
    await localDb.clearProfileWizardDraft(userId);
  }

  Future<UserProfile> _mergeWizardDraft(UserProfile base) async {
    final localDb = ref.read(localDbProvider);
    final draft = await localDb.loadProfileWizardDraft(userId);
    if (draft == null) return base;
    final normalized = Map<String, dynamic>.from(draft);
    normalized['id'] = userId;
    _wizardUploadedPhotoPaths
      ..clear()
      ..addAll(_toStringList(draft['_wizard_uploaded_photo_paths']));

    if (draft['_wizard_current_page_index'] is int) {
      _wizardCurrentPageIndex = draft['_wizard_current_page_index'] as int;
    }

    final draftProfile = UserProfile.fromMap(normalized);

    String photoId(String src) => StorageHelper.cacheKeyForSource(src);

    final baseIds = base.photos
        .map(photoId)
        .where((s) => s.isNotEmpty)
        .toList();
    final draftIds = draftProfile.photos
        .map(photoId)
        .where((s) => s.isNotEmpty)
        .toList();

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

    final draftName = draftProfile.name.trim();
    final validDraftName = draftName.isNotEmpty && draftName != 'Unnamed';

    final draftBio = draftProfile.bio?.trim();
    final validDraftBio = draftBio != null && draftBio.isNotEmpty;

    final draftInsta = draftProfile.instagramUrl?.trim();
    final validDraftInsta = draftInsta != null && draftInsta.isNotEmpty;

    final draftLinkedin = draftProfile.linkedinUrl?.trim();
    final validDraftLinkedin =
        draftLinkedin != null && draftLinkedin.isNotEmpty;

    final draftFb = draftProfile.facebookUrl?.trim();
    final validDraftFb = draftFb != null && draftFb.isNotEmpty;

    final draftOcc = draftProfile.occupation?.trim();
    final validDraftOcc = draftOcc != null && draftOcc.isNotEmpty;

    final draftEdu = draftProfile.education?.trim();
    final validDraftEdu = draftEdu != null && draftEdu.isNotEmpty;

    final draftZodiac = draftProfile.zodiacSign?.trim();
    final validDraftZodiac = draftZodiac != null && draftZodiac.isNotEmpty;

    final draftGender = draftProfile.gender?.trim();
    final validDraftGender = draftGender != null && draftGender.isNotEmpty;

    final mergedLifestyle = <String, dynamic>{
      ...?base.lifestyle,
      ...?draftProfile.lifestyle,
    };
    final mergedFamily = <String, dynamic>{
      ...?base.family,
      ...?draftProfile.family,
    };
    final mergedReligion = <String, dynamic>{
      ...?base.religion,
      ...?draftProfile.religion,
    };

    final mergedActiveModes = draftProfile.activeModes.isNotEmpty
        ? draftProfile.activeModes
        : base.activeModes;

    // Preserve stashed selections for inactive intents so re-activating an
    // intent restores its previous sub-intents/interests as checked.
    // Display layers filter by activeModes.
    final merged = base.copyWith(
      name: validDraftName ? draftProfile.name : base.name,
      dateOfBirth: draftProfile.dateOfBirth ?? base.dateOfBirth,
      gender: validDraftGender ? draftProfile.gender : base.gender,
      preferredLanguage: draftProfile.preferredLanguage.isNotEmpty
          ? draftProfile.preferredLanguage
          : base.preferredLanguage,
      activeModes: mergedActiveModes,
      subIntents: draftProfile.subIntents.isNotEmpty
          ? {...base.subIntents, ...draftProfile.subIntents}
          : base.subIntents,
      personalInterests: draftProfile.personalInterests.isNotEmpty
          ? {...base.personalInterests, ...draftProfile.personalInterests}
          : base.personalInterests,
      businessInterests: draftProfile.businessInterests.isNotEmpty
          ? {...base.businessInterests, ...draftProfile.businessInterests}
          : base.businessInterests,
      languagesKnown: draftProfile.languagesKnown.isNotEmpty
          ? {...base.languagesKnown, ...draftProfile.languagesKnown}
          : base.languagesKnown,
      matchRadiusDefault: draftProfile.matchRadiusDefault,
      gpsIntervalDefault: draftProfile.gpsIntervalDefault,
      smartGpsThrottlingEnabled: draftProfile.smartGpsThrottlingEnabled,
      sharedEventMatchingEnabled: draftProfile.sharedEventMatchingEnabled,
      sharedMovementMatchingEnabled: draftProfile.sharedMovementMatchingEnabled,
      genderPreferences: draftProfile.genderPreferences.isNotEmpty
          ? {...base.genderPreferences, ...draftProfile.genderPreferences}
          : base.genderPreferences,
      agePreferences: draftProfile.agePreferences.isNotEmpty
          ? {...base.agePreferences, ...draftProfile.agePreferences}
          : base.agePreferences,
      bio: validDraftBio ? draftProfile.bio : base.bio,
      photos: mergedPhotos.isNotEmpty ? mergedPhotos : base.photos,
      instagramUrl: validDraftInsta
          ? draftProfile.instagramUrl
          : base.instagramUrl,
      linkedinUrl: validDraftLinkedin
          ? draftProfile.linkedinUrl
          : base.linkedinUrl,
      facebookUrl: validDraftFb ? draftProfile.facebookUrl : base.facebookUrl,
      height: draftProfile.height ?? base.height,
      heightUnit: draftProfile.heightUnit,
      occupation: validDraftOcc ? draftProfile.occupation : base.occupation,
      education: validDraftEdu ? draftProfile.education : base.education,
      zodiacSign: validDraftZodiac ? draftProfile.zodiacSign : base.zodiacSign,
      lifestyle: mergedLifestyle.isNotEmpty ? mergedLifestyle : base.lifestyle,
      family: mergedFamily.isNotEmpty ? mergedFamily : base.family,
      religion: mergedReligion.isNotEmpty ? mergedReligion : base.religion,
      lifestyleFilters: draftProfile.lifestyleFilters.isNotEmpty
          ? {...base.lifestyleFilters, ...draftProfile.lifestyleFilters}
          : base.lifestyleFilters,
      familyFilters: draftProfile.familyFilters.isNotEmpty
          ? {...base.familyFilters, ...draftProfile.familyFilters}
          : base.familyFilters,
      religionFilters: draftProfile.religionFilters.isNotEmpty
          ? {...base.religionFilters, ...draftProfile.religionFilters}
          : base.religionFilters,
      heightPreferences: draftProfile.heightPreferences.isNotEmpty
          ? {...base.heightPreferences, ...draftProfile.heightPreferences}
          : base.heightPreferences,
    );
    return merged;
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
    final before = state.value!;
    final unchanged =
        before.dateOfBirth != null &&
        before.dateOfBirth!.year == dob.year &&
        before.dateOfBirth!.month == dob.month &&
        before.dateOfBirth!.day == dob.day;
    if (unchanged) return;

    _applyBasicFieldEdit(
      before,
      nextProfile: before.copyWith(dateOfBirth: dob),
    );
  }

  void updateGender(String? gender) {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    final normalizedGender = gender?.trim();
    final normalizedBefore = before.gender?.trim();
    if (normalizedGender == normalizedBefore) return;

    _applyBasicFieldEdit(before, nextProfile: before.copyWith(gender: gender));
  }

  /// Deferred: basic field locking now happens at save time via the DB trigger.
  /// This method is kept as a no-op for compatibility.
  Future<void> commitUnlockedBasicFieldChange(String fieldKey) async {
    return;
  }

  bool _datesDiffer(DateTime? a, DateTime? b) {
    if (a == null && b == null) return false;
    if (a == null || b == null) return true;
    return a.year != b.year || a.month != b.month || a.day != b.day;
  }

  void _applyBasicFieldEdit(
    UserProfile before, {
    required UserProfile nextProfile,
  }) {
    state = AsyncData(nextProfile);
  }

  void updatePreferredLanguage(String lang) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(preferredLanguage: lang));
  }

  Future<void> updateRadius(int radius) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(matchRadiusDefault: radius);
    state = AsyncData(updatedProfile);
    _lastRadiusChangeAt = DateTime.now();

    // Save to local cache first
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());
    _markProfileLocalSave(userId);

    // Try to sync to backend before invalidating, so a refetch can't
    // pull the pre-update value and revert the local change.
    var synced = false;
    try {
      await supabase
          .from('users')
          .update({'match_radius_default': radius})
          .eq('id', userId);
      synced = true;
    } catch (e) {
      debugPrint('[ProfileEdit] radius server update failed, queued to outbox: $e');
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'match_radius_default': radius},
      });
      // Do not revert state, keep the local change
    }

    // Invalidate the userProfileProvider to ensure immediate update
    ref.invalidate(userProfileProvider(userId));
    // Radius is an input to the Nearby count. Refresh active dashboard/map
    // listeners immediately and warm the persisted snapshot even if neither
    // screen is currently mounted.
    ref.invalidate(dashboardStatsProvider);
    unawaited(warmDashboardStatsForUser(userId));
    // Note: Removed ref.invalidate(isVisibleProvider) to break circular dependency.
    // The visibility provider already listens to profileEditProvider changes via ref.listen,
    // so explicit invalidation here was unnecessary and caused a rebuild cycle.
    if (!synced) {
      // Keep the guard window fresh while the outbox is pending so a later
      // refetch of the stale server value doesn't revert the local radius.
      _lastRadiusChangeAt = DateTime.now();
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('flutter.gps_interval', seconds);
    } catch (_) {}

    // Directly notify VisibilityNotifier with the new GPS rate value
    // This bypasses the database read which might return cached/stale data
    try {
      final visibilityNotifier = ref.read(isVisibleProvider.notifier);
      await visibilityNotifier.updateLocationStreamInterval(
        newGpsRate: seconds,
      );
    } catch (e) {
      // Ignore
    }

    // Try to sync to backend
    try {
      await supabase
          .from('users')
          .update({'gps_interval_default': seconds})
          .eq('id', userId);
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
    final updatedProfile = state.value!.copyWith(
      smartGpsThrottlingEnabled: enabled,
    );
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('flutter.smart_throttling_enabled', enabled);
    } catch (_) {}

    // Directly notify VisibilityNotifier to update throttling setting immediately
    try {
      final visibilityNotifier = ref.read(isVisibleProvider.notifier);
      await visibilityNotifier.updateLocationStreamInterval();
    } catch (e) {
      // Ignore
    }

    // Try to sync to backend
    try {
      await supabase
          .from('users')
          .update({'smart_gps_throttling_enabled': enabled})
          .eq('id', userId);
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
    final updatedProfile = state.value!.copyWith(
      sharedEventMatchingEnabled: enabled,
    );
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Try to sync to backend
    try {
      await supabase
          .from('users')
          .update({'shared_event_matching_enabled': enabled})
          .eq('id', userId);
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
    final updatedProfile = state.value!.copyWith(
      sharedMovementMatchingEnabled: enabled,
    );
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Try to sync to backend
    try {
      await supabase
          .from('users')
          .update({'shared_movement_matching_enabled': enabled})
          .eq('id', userId);
    } catch (e) {
      // If offline or error, add to outbox for later sync
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'shared_movement_matching_enabled': enabled},
      });
      // Do not revert state, keep the local change
    }
  }

  Future<void> updateRetroMatching(bool enabled) async {
    if (!state.hasValue || state.value == null) return;
    final updatedProfile = state.value!.copyWith(retroMatchingEnabled: enabled);
    state = AsyncData(updatedProfile);

    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('flutter.retro_enabled', enabled);
    } catch (_) {}

    try {
      await supabase
          .from('users')
          .update({'retro_matching_enabled': enabled})
          .eq('id', userId);
      if (!enabled) {
        try {
          await supabase.rpc('delete_my_offline_trail');
        } catch (_) {}
        await localDb.clearOfflineTrail(userId);
      }
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'retro_matching_enabled': enabled},
      });
    }
  }

  Future<void> updateRetroRetention(int hours) async {
    final clamped = hours.clamp(2, 72);
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    final updatedProfile = before.copyWith(retroRetentionHours: clamped);
    state = AsyncData(updatedProfile);

    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('flutter.retro_retention_hours', clamped);
    } catch (_) {}
    // Lowering prunes the on-device copy immediately (can't be undone).
    if (clamped < before.retroRetentionHours) {
      try {
        await localDb.pruneOfflineTrail(userId, Duration(hours: clamped));
      } catch (_) {}
    }

    try {
      await supabase
          .from('users')
          .update({'retro_retention_hours': clamped})
          .eq('id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'retro_retention_hours': clamped},
      });
    }
  }

  Future<void> updateGenderAgePreferences(
    Map<String, List<String>> genderPreferences,
    Map<String, List<double>> agePreferences,
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
      normalizedAgePreferences[entry.key] = [
        minAge.toDouble(),
        maxAge.toDouble(),
      ];
    }
    final updatedProfile = state.value!.copyWith(
      genderPreferences: genderPreferences,
      agePreferences: normalizedAgePreferences,
    );
    state = AsyncData(updatedProfile);

    // Save to local cache
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updatedProfile.toMap());

    // Build intent_preferences and write to user_profiles
    final intentPrefs = {
      if (genderPreferences.isNotEmpty) 'gender_preferences': genderPreferences,
      if (normalizedAgePreferences.isNotEmpty)
        'age_preferences': normalizedAgePreferences,
      if (updatedProfile.lifestyleFilters.isNotEmpty)
        'lifestyle_filters': updatedProfile.lifestyleFilters,
      if (updatedProfile.familyFilters.isNotEmpty)
        'family_filters': updatedProfile.familyFilters,
      if (updatedProfile.religionFilters.isNotEmpty)
        'religion_filters': updatedProfile.religionFilters,
      if (updatedProfile.heightPreferences.isNotEmpty)
        'height_preferences': updatedProfile.heightPreferences,
    };

    try {
      await supabase
          .from('user_profiles')
          .update({
            'intent_preferences': intentPrefs.isNotEmpty ? intentPrefs : null,
          })
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {
          'intent_preferences': intentPrefs.isNotEmpty ? intentPrefs : null,
        },
      });
    }
  }

  Future<void> updateLifestyleFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(lifestyleFilters: filters);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    // Write merged intent_preferences to user_profiles
    final intentPrefs = _buildIntentPreferences(updated);
    try {
      await supabase
          .from('user_profiles')
          .update({'intent_preferences': intentPrefs})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'intent_preferences': intentPrefs},
      });
    }
  }

  Future<void> updateFamilyFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(familyFilters: filters);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    final intentPrefs = _buildIntentPreferences(updated);
    try {
      await supabase
          .from('user_profiles')
          .update({'intent_preferences': intentPrefs})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'intent_preferences': intentPrefs},
      });
    }
  }

  Future<void> updateReligionFilters(
    Map<String, Map<String, dynamic>> filters,
  ) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(religionFilters: filters);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    final intentPrefs = _buildIntentPreferences(updated);
    try {
      await supabase
          .from('user_profiles')
          .update({'intent_preferences': intentPrefs})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'intent_preferences': intentPrefs},
      });
    }
  }

  Future<void> updateHeightPreferences(
    Map<String, Map<String, dynamic>> prefs,
  ) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(heightPreferences: prefs);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    final intentPrefs = _buildIntentPreferences(updated);
    try {
      await supabase
          .from('user_profiles')
          .update({'intent_preferences': intentPrefs})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'intent_preferences': intentPrefs},
      });
    }
  }

  void updateActiveModes(List<String> modes) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(activeModes: modes));
  }

  void toggleIntent(String intentKey) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final normalized = _normalizeIntentKey(intentKey);
    final List<String> updatedModes = List<String>.from(current.activeModes);

    if (updatedModes.map(_normalizeIntentKey).contains(normalized)) {
      updatedModes.removeWhere((m) => _normalizeIntentKey(m) == normalized);

      // Keep the intent's selections persisted but hidden while it is inactive.
      // Display layers (profile screen, matched profile) filter by activeModes,
      // so orphans disappear in realtime, while re-activating the intent
      // instantly restores its previous sub-intents/interests as checked.
      state = AsyncData(current.copyWith(activeModes: updatedModes));
    } else {
      updatedModes.add(intentKey);
      // No need to copy interests — personalInterests/businessInterests are shared across intents.
      // Selections stashed while the intent was inactive are still present and
      // reappear as checked.
      state = AsyncData(current.copyWith(activeModes: updatedModes));
    }
  }

  void toggleSubIntent(
    String intentKey,
    String subIntentKey, {
    bool awaitPersist = false,
  }) {
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

  void toggleInterest(
    String categoryKey,
    String interestKey, {
    bool awaitPersist = false,
    bool isBusiness = false,
  }) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final source = isBusiness
        ? current.businessInterests
        : current.personalInterests;
    final newInterests = Map<String, List<String>>.from(source);
    var list = List<String>.from(newInterests[categoryKey] ?? const []);
    list = list.toSet().toList(); // deduplicate
    if (list.contains(interestKey)) {
      list.remove(interestKey);
      if (list.isEmpty) {
        newInterests.remove(categoryKey);
      } else {
        newInterests[categoryKey] = list;
      }
    } else {
      list.add(interestKey);
      newInterests[categoryKey] = list;
    }
    if (isBusiness) {
      state = AsyncData(current.copyWith(businessInterests: newInterests));
    } else {
      state = AsyncData(current.copyWith(personalInterests: newInterests));
    }
  }

  void clearInterestsForCategory(
    String categoryKey, {
    bool isBusiness = false,
  }) {
    if (!state.hasValue || state.value == null) return;
    final current = state.value!;
    final source = isBusiness
        ? current.businessInterests
        : current.personalInterests;
    final newInterests = Map<String, List<String>>.from(source);
    newInterests.remove(categoryKey);
    if (isBusiness) {
      state = AsyncData(current.copyWith(businessInterests: newInterests));
    } else {
      state = AsyncData(current.copyWith(personalInterests: newInterests));
    }
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

  // --- Social URL management ---
  void updateInstagramUrl(String? url) {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    state = AsyncData(p.copyWith(instagramUrl: url));
  }

  void updateLinkedinUrl(String? url) {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    state = AsyncData(p.copyWith(linkedinUrl: url));
  }

  void updateFacebookUrl(String? url) {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    state = AsyncData(p.copyWith(facebookUrl: url));
  }

  // --- Profile Details Draft ---
  void updateHeight(int? value) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(height: value));
  }

  void updateHeightUnit(String value) {
    if (!state.hasValue || state.value == null) return;
    final normalized = value == 'ft' ? 'ft' : 'cm';
    state = AsyncData(state.value!.copyWith(heightUnit: normalized));
  }

  void updateOccupation(String? value) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(occupation: value));
  }

  void updateEducation(String? value) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(education: value));
  }

  void updateZodiacSign(String? value) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(zodiacSign: value));
  }

  Future<void> updateLifestyle(Map<String, dynamic>? value) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(lifestyle: value);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    try {
      await supabase
          .from('user_profiles')
          .update({'lifestyle': value})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'lifestyle': value},
      });
    }
  }

  Future<void> updateFamily(Map<String, dynamic>? value) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(family: value);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    try {
      await supabase
          .from('user_profiles')
          .update({'family': value})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'family': value},
      });
    }
  }

  Future<void> updateReligion(Map<String, dynamic>? value) async {
    if (!state.hasValue || state.value == null) return;
    final updated = state.value!.copyWith(religion: value);
    state = AsyncData(updated);
    final localDb = ref.read(localDbProvider);
    await localDb.saveLocalProfile(userId, updated.toMap());
    try {
      await supabase
          .from('user_profiles')
          .update({'religion': value})
          .eq('user_id', userId);
    } catch (e) {
      await localDb.saveProfileUpdateToOutbox(userId, {
        'userId': userId,
        'updates': {'religion': value},
      });
    }
  }

  // --- Gender & Age Preferences Draft ---
  void updateGenderAgePreferencesDraft({
    required Map<String, List<String>> genderPreferences,
    required Map<String, List<double>> agePreferences,
  }) {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    final updated = p.copyWith(
      genderPreferences: genderPreferences,
      agePreferences: agePreferences,
    );
    state = AsyncData(updated);
    unawaited(_saveToLocalCache(updated));
  }

  Future<void> _saveToLocalCache(UserProfile profile) async {
    try {
      final localDb = ref.read(localDbProvider);
      await localDb.saveLocalProfile(userId, profile.toMap());
    } catch (_) {}
  }

  Map<String, dynamic> _buildIntentPreferences(UserProfile p) {
    final intentPrefs = <String, dynamic>{};
    if (p.genderPreferences.isNotEmpty) {
      intentPrefs['gender_preferences'] = p.genderPreferences;
    }
    if (p.agePreferences.isNotEmpty) {
      intentPrefs['age_preferences'] = p.agePreferences;
    }
    if (p.lifestyleFilters.isNotEmpty) {
      intentPrefs['lifestyle_filters'] = p.lifestyleFilters;
    }
    if (p.familyFilters.isNotEmpty) {
      intentPrefs['family_filters'] = p.familyFilters;
    }
    if (p.religionFilters.isNotEmpty) {
      intentPrefs['religion_filters'] = p.religionFilters;
    }
    if (p.heightPreferences.isNotEmpty) {
      intentPrefs['height_preferences'] = p.heightPreferences;
    }
    return intentPrefs;
  }

  void updateLifestyleFiltersDraft(Map<String, Map<String, dynamic>> filters) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(lifestyleFilters: filters));
  }

  void updateFamilyFiltersDraft(Map<String, Map<String, dynamic>> filters) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(familyFilters: filters));
  }

  void updateReligionFiltersDraft(Map<String, Map<String, dynamic>> filters) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(religionFilters: filters));
  }

  void updateHeightPreferencesDraft(Map<String, Map<String, dynamic>> prefs) {
    if (!state.hasValue || state.value == null) return;
    state = AsyncData(state.value!.copyWith(heightPreferences: prefs));
  }

  // --- Local Verification Update ---
  Future<void> applyLocalVerificationUpdate({
    required String verificationStatus,
    required bool isVerified,
    DateTime? verificationSubmittedAt,
    DateTime? verificationReviewedAt,
  }) async {
    if (!state.hasValue || state.value == null) return;
    final p = state.value!;
    final updated = p.copyWith(
      verificationStatus: verificationStatus,
      isVerified: isVerified,
      verificationSubmittedAt: verificationSubmittedAt,
      verificationReviewedAt: verificationReviewedAt,
    );
    state = AsyncData(updated);
    // Persist to local DB so the update is reflected immediately
    try {
      final localDb = ref.read(localDbProvider);
      await localDb.saveLocalProfile(userId, updated.toMap());
    } catch (_) {}
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
    final uploadedObjectPath = await uploader.uploadBytesToStorage(
      fileName,
      bytes,
      public: false,
    );
    if (uploadedObjectPath == null) {
      throw Exception('Photo upload failed.');
    }
    var uploadedPath = uploadedObjectPath;
    _wizardUploadedPhotoPaths.add(uploadedPath);

    if (before.photos.isEmpty) {
      try {
        uploadedPath = await _ensurePrimaryPhotoAllowed(uploadedPath);
      } catch (e) {
        unawaited(_cleanupWizardUploadedPhotosNotIn(before.photos.toSet()));
        rethrow;
      }
    } else {
      try {
        uploadedPath = await _ensureSecondaryPhotoAllowed(uploadedPath);
      } catch (e) {
        unawaited(_cleanupWizardUploadedPhotosNotIn(before.photos.toSet()));
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
    // A completed profile can never drop its last photo (wizard blocks it
    // in the UI; this backstop keeps the draft state legal too — a
    // zero-photo draft would surface again on the next wizard entry).
    if (before.isProfileComplete && before.photos.length <= 1) {
      throw Exception('At least 1 photo is required.');
    }

    final removedPath = before.photos[index];
    final newPhotos = List<String>.from(before.photos)..removeAt(index);
    final updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = newPhotos.isNotEmpty ? newPhotos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        await _prescreenPromotedPrimaryPhoto(newPrimary);
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

  Future<void> replacePhotoAtIndexDraft(
    int index, {
    Uint8List? bytes,
    String? url,
  }) async {
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
      final uploadedObjectPath = await uploader.uploadBytesToStorage(
        fileName,
        bytes,
        public: false,
      );
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
          unawaited(_cleanupWizardUploadedPhotosNotIn(before.photos.toSet()));
        }
        rethrow;
      }
    } else {
      try {
        newPath = await _ensureSecondaryPhotoAllowed(newPath);
      } catch (e) {
        if (shouldDeleteNewOnFailure) {
          unawaited(_cleanupWizardUploadedPhotosNotIn(before.photos.toSet()));
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
    if (oldIndex < 0 ||
        oldIndex >= photos.length ||
        newIndex < 0 ||
        newIndex >= photos.length) {
      return;
    }
    final item = photos.removeAt(oldIndex);
    photos.insert(newIndex, item);
    var updated = before.copyWith(photos: photos);
    state = AsyncData(updated);

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = photos.isNotEmpty ? photos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        await _prescreenPromotedPrimaryPhoto(newPrimary);
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

  Future<void> addPhotoFromBytes(
    Uint8List bytes, {
    bool awaitPersist = true,
  }) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (before.photos.length >= 5) {
      throw Exception('Maximum 5 photos allowed.');
    }

    final uploader = ref.read(profileEditRequestServiceProvider);
    final fileName = '$userId/${DateTime.now().millisecondsSinceEpoch}.jpg';

    // uploader returns the object path (e.g. "userId/163423432.jpg")
    final uploadedObjectPath = await uploader.uploadBytesToStorage(
      fileName,
      bytes,
      public: false,
    );
    if (uploadedObjectPath == null) {
      throw Exception('Photo upload failed.');
    }
    var uploadedPath = uploadedObjectPath;

    if (before.photos.isEmpty) {
      try {
        uploadedPath = await _ensurePrimaryPhotoAllowed(uploadedPath);
      } catch (e) {
        _deleteStorageObject(uploadedPath);
        rethrow;
      }
    } else {
      try {
        uploadedPath = await _ensureSecondaryPhotoAllowed(uploadedPath);
      } catch (e) {
        _deleteStorageObject(uploadedPath);
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
        await supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId);
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
      unawaited(
        supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId)
            .catchError((e) {
              unawaited(ref.read(profileSyncProvider).syncProfile(userId));
            }),
      );
    }
  }

  Future<void> removePhotoAt(int index, {bool awaitPersist = true}) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    if (index < 0 || index >= before.photos.length) return;
    // This path persists straight to the server, so it must never be able
    // to leave a completed profile without photos.
    if (before.isProfileComplete && before.photos.length <= 1) {
      throw Exception('At least 1 photo is required.');
    }

    final removedPath = before.photos[index];

    final newPhotos = List<String>.from(before.photos)..removeAt(index);
    var updated = before.copyWith(photos: newPhotos);
    state = AsyncData(updated);

    // If removal promotes a new primary photo, it must pass Gemini primary
    // validation like every other primary change (mirrors removePhotoAtDraft).
    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = newPhotos.isNotEmpty ? newPhotos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        await _prescreenPromotedPrimaryPhoto(newPrimary);
        final verifiedPrimary = await _ensurePrimaryPhotoAllowed(newPrimary);
        if (verifiedPrimary != newPrimary && newPhotos.isNotEmpty) {
          newPhotos[0] = verifiedPrimary;
          updated = before.copyWith(photos: newPhotos);
          state = AsyncData(updated);
        }
      } catch (e) {
        if (ref.mounted) {
          state = AsyncData(before);
        }
        rethrow;
      }
    }

    final localDb = ref.read(localDbProvider);

    if (awaitPersist) {
      try {
        await supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId);
        // Delete the storage object from Supabase storage
        await _deleteStorageObject(removedPath);
        // Ensure local cache reflects the removal immediately to avoid being reverted by sync
        await localDb.saveLocalProfile(userId, updated.toMap());
        await localDb.removeApprovedPrimaryPhoto(userId, removedPath);
        // Evict cache for removed objectPath if it's not a full URL
        if (!removedPath.startsWith('http://') &&
            !removedPath.startsWith('https://')) {
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
      unawaited(
        supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId)
            .catchError((e) {
              unawaited(ref.read(profileSyncProvider).syncProfile(userId));
            })
            .whenComplete(() async {
              // Delete the storage object from Supabase storage
              await _deleteStorageObject(removedPath);
              if (!removedPath.startsWith('http://') &&
                  !removedPath.startsWith('https://')) {
                StorageHelper.evict(removedPath);
              }
            }),
      );
    }
  }

  Future<void> replacePhotoAtIndex(
    int index, {
    Uint8List? bytes,
    String? url,
    bool awaitPersist = true,
  }) async {
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
      final uploadedObjectPath = await uploader.uploadBytesToStorage(
        fileName,
        bytes,
        public: false,
      );
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
          _deleteStorageObject(newPath);
        }
        newPath = verifiedPath;
        approved.remove(oldPath);
        approved.add(newPath);
        await localDb.setApprovedPrimaryPhotos(userId, approved);
      } catch (e) {
        if (shouldDeleteNewOnFailure) {
          _deleteStorageObject(newPath);
        }
        rethrow;
      }
    } else {
      try {
        newPath = await _ensureSecondaryPhotoAllowed(newPath);
      } catch (e) {
        if (shouldDeleteNewOnFailure) {
          _deleteStorageObject(newPath);
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
        await supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId);
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
      unawaited(
        supabase
            .from('user_profiles')
            .update({'photos': newPhotos})
            .eq('user_id', userId)
            .catchError((e) {
              unawaited(ref.read(profileSyncProvider).syncProfile(userId));
            })
            .whenComplete(() async {
              // Delete the old storage object from Supabase storage
              await _deleteStorageObject(oldPath);
              await localDb.removeApprovedPrimaryPhoto(userId, oldPath);
              if (!oldPath.startsWith('http://') &&
                  !oldPath.startsWith('https://')) {
                StorageHelper.evict(oldPath);
              }
              if (!newPath.startsWith('http://') &&
                  !newPath.startsWith('https://')) {
                StorageHelper.evict(newPath);
              }
            }),
      );
    }
  }

  Future<void> reorderPhotos(
    int oldIndex,
    int newIndex, {
    bool awaitPersist = true,
  }) async {
    if (!state.hasValue || state.value == null) return;
    final before = state.value!;
    final photos = List<String>.from(before.photos);
    if (oldIndex < 0 ||
        oldIndex >= photos.length ||
        newIndex < 0 ||
        newIndex >= photos.length) {
      return;
    }
    final item = photos.removeAt(oldIndex);
    photos.insert(newIndex, item);
    final updated = before.copyWith(photos: photos);
    state = AsyncData(updated);

    final localDb = ref.read(localDbProvider);

    final oldPrimary = before.photos.isNotEmpty ? before.photos.first : null;
    final newPrimary = photos.isNotEmpty ? photos.first : null;
    if (newPrimary != null && oldPrimary != newPrimary) {
      try {
        await _prescreenPromotedPrimaryPhoto(newPrimary);
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
        await supabase
            .from('user_profiles')
            .update({'photos': photos})
            .eq('user_id', userId);
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
      unawaited(
        supabase
            .from('user_profiles')
            .update({'photos': photos})
            .eq('user_id', userId)
            .catchError((e) {
              unawaited(ref.read(profileSyncProvider).syncProfile(userId));
            }),
      );
    }
  }

  Future<bool> saveProfile({
    bool showLoading = true,
    bool markComplete = true,
  }) async {
    var currentState = state.asData?.value;
    if (currentState == null) return false;
    final wasCompleteBefore = currentState.isProfileComplete;
    if (currentState.name.isEmpty || currentState.dateOfBirth == null) {
      state = AsyncError("Name and DOB required.", StackTrace.current);
      return false;
    }
    // Hard gate: every save/completion (first-time or edit) requires at
    // least one photo, and the primary photo must have passed the local
    // prescreen and been approved by the AI validation
    // (validate-primary-photo). Approved paths are cached in the local DB,
    // so an already-approved primary photo saves fine offline; an unapproved
    // one blocks the save both online (AI re-check) and offline (no cached
    // approval to trust).
    if (currentState.photos.isEmpty) {
      state = AsyncError("At least 1 photo is required.", StackTrace.current);
      return false;
    }
    try {
      final verifiedPrimary = await _ensurePrimaryPhotoAllowed(
        currentState.photos.first,
      );
      if (verifiedPrimary != currentState.photos.first) {
        // The AI mechanism sanitized the photo; persist the sanitized path
        // as the primary so the saved profile references the approved bytes.
        final photos = List<String>.from(currentState.photos);
        photos[0] = verifiedPrimary;
        currentState = currentState.copyWith(photos: photos);
        if (ref.mounted) state = AsyncData(currentState);
      }
    } catch (e) {
      state = AsyncError(
        e is Exception ? e : Exception("Primary photo verification failed."),
        StackTrace.current,
      );
      return false;
    }
    // Height is optional (only asked for Romantic intent); validate range if provided
    if (currentState.height != null &&
        (currentState.height! < 100 || currentState.height! > 250)) {
      state = AsyncError(
        "Height must be between 100 and 250 cm.",
        StackTrace.current,
      );
      return false;
    }
    // Occupation and Education are mandatory for Business/Networking intent
    final hasBusinessIntent = currentState.activeModes.any(
      (m) =>
          m
              .trim()
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
              .replaceAll(RegExp(r'_+'), '_')
              .replaceAll(RegExp(r'^_|_$'), '') ==
          'business_networking',
    );
    if (hasBusinessIntent) {
      if ((currentState.occupation ?? '').trim().isEmpty) {
        state = AsyncError(
          "Occupation is required for business networking profiles.",
          StackTrace.current,
        );
        return false;
      }
      if ((currentState.education ?? '').trim().isEmpty) {
        state = AsyncError(
          "Education is required for business networking profiles.",
          StackTrace.current,
        );
        return false;
      }
    }
    // Interests are split into two buckets: personal (shared by Romantic,
    // Friendship, Activity) and business (Business/Networking only). Each
    // bucket corresponding to a selected intent must contain at least one
    // non-empty interest. This mirrors the wizard per-page checks and blocks
    // direct provider/RPC bypass of the UI validation.
    String normalizeIntentKey(String m) => m
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final hasSocialIntentForInterests = currentState.activeModes.any(
      (m) => normalizeIntentKey(m) != 'business_networking',
    );
    final hasPersonalInterest = currentState.personalInterests.values.any(
      (v) => v.isNotEmpty,
    );
    final hasBusinessInterest = currentState.businessInterests.values.any(
      (v) => v.isNotEmpty,
    );
    if (hasSocialIntentForInterests && !hasPersonalInterest) {
      state = AsyncError(
        "At least one personal interest is required.",
        StackTrace.current,
      );
      return false;
    }
    if (hasBusinessIntent && !hasBusinessInterest) {
      state = AsyncError(
        "At least one business interest is required.",
        StackTrace.current,
      );
      return false;
    }
    // Preserve stashed selections for inactive intents on save so quick
    // re-activation restores them. Display layers filter by activeModes.
    if (showLoading) state = const AsyncLoading();
    try {
      // Explicitly relock basic fields that changed — this ensures fields are
      // locked immediately at save time regardless of DB trigger timing.
      final baseline = ref.read(userProfileProvider(userId)).asData?.value;
      if (baseline != null && baseline.isProfileComplete) {
        final updatedFields = List<String>.from(
          currentState.editableProfileFields,
        );
        bool anyRelocked = false;
        for (final entry in <MapEntry<String, bool>>[
          MapEntry('name', currentState.name != baseline.name),
          MapEntry(
            'date_of_birth',
            _datesDiffer(currentState.dateOfBirth, baseline.dateOfBirth),
          ),
          MapEntry(
            'gender',
            (currentState.gender ?? '') != (baseline.gender ?? ''),
          ),
        ]) {
          if (entry.value &&
              baseline.editableProfileFields.contains(entry.key) &&
              updatedFields.contains(entry.key)) {
            updatedFields.remove(entry.key);
            anyRelocked = true;
          }
        }
        if (anyRelocked) {
          currentState = currentState.copyWith(
            editableProfileFields: updatedFields,
          );
          state = AsyncData(currentState);
        }
      }

      final userUpdatePayload = currentState.toJsonForUserTableSave();
      // Remove null-valued keys to avoid sending nulls to the REST endpoint
      final filteredPayload = Map<String, dynamic>.fromEntries(
        userUpdatePayload.entries.where((e) => e.value != null),
      );

      // Mark profile as complete when saving
      if (markComplete) {
        filteredPayload['is_profile_complete'] = true;
      }

      // New users default to Visible + Background Matching ON at completion.
      // Written into the users-table payload itself (not just via
      // onProfileCompleted below) so the offline outbox path — which returns
      // before that call — still carries the defaults to the server on sync.
      final isFirstCompletion = markComplete && !wasCompleteBefore;
      if (isFirstCompletion) {
        filteredPayload['user_visibility_setting'] = true;
        filteredPayload['background_matching_mode'] = true;
      }

      // Build the user_profiles single-row upsert payload
      final profilePayload = currentState.toJsonForProfileTableSave();
      // Remove null-valued keys
      final filteredProfilePayload = Map<String, dynamic>.fromEntries(
        profilePayload.entries.where((e) => e.value != null),
      );

      // Update local state to reflect completion immediately (offline-first).
      var localProfile = currentState.copyWith(
        isProfileComplete: markComplete ? true : currentState.isProfileComplete,
      );

      // Persist to local DB first so user's progress is saved even if network
      // fails. This Hive write is what drives the ProfileScreen in realtime
      // (userProfileProvider watches the local DB stream).
      final localDb = ref.read(localDbProvider);
      try {
        await localDb.saveLocalProfile(userId, localProfile.toMap());
        _markProfileLocalSave(userId);
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
          'profilePayload': filteredProfilePayload,
          'timestamp': DateTime.now().toIso8601String(),
        });
        if (ref.mounted) {
          state = AsyncData(localProfile);
        }
        // Offline completion must still flip local visibility immediately:
        // state now holds isProfileComplete=true so onProfileCompleted() can
        // evaluate effective visibility correctly. The server write (including
        // user_visibility_setting=true above) lands via the outbox on sync.
        if (isFirstCompletion) {
          try {
            await localDb.saveVisibilityUpdateToOutbox(userId, true);
          } catch (_) {}
          try {
            unawaited(
              ref.read(isVisibleProvider.notifier).onProfileCompleted(),
            );
          } catch (_) {}
        }
        return true;
      }

      // Realtime ordering: upsert user_profiles BEFORE updating users.
      // The realtime users-table stream triggers a syncProfile on every
      // users change — if users were updated first, that sync could fetch
      // the still-old user_profiles row and overwrite the fresh local DB
      // (ProfileScreen flashing back to stale data). Profiles-first closes
      // that window: by the time the users event fires, the server already
      // has the new profile content.
      // Upsert the single user_profiles row
      try {
        await supabase
            .from('user_profiles')
            .upsert(filteredProfilePayload, onConflict: 'user_id');
      } on PostgrestException catch (e) {
        debugPrint('user_profiles upsert failed: ${e.message}');
        final problematicMsg = e.message.toLowerCase();
        if (problematicMsg.contains('pkey') ||
            problematicMsg.contains('primary key') ||
            problematicMsg.contains('no unique or exclusion constraint')) {
          try {
            await supabase.from('user_profiles').delete().eq('user_id', userId);
            await supabase.from('user_profiles').insert(filteredProfilePayload);
          } catch (inner) {
            debugPrint('Fallback replace of user_profiles failed: $inner');
            rethrow;
          }
        } else {
          rethrow;
        }
      }

      try {
        await supabase.from('users').update(filteredPayload).eq('id', userId);
      } catch (e) {
        debugPrint('Failed to update users record');
        debugPrint('Supabase update error: $e');
        // If we lost connectivity mid-save, queue it and return success.
        final nowOnline = ref.read(connectivityProvider).value ?? true;
        if (!nowOnline) {
          await localDb.saveProfileUpdateToOutbox(userId, {
            'type': 'full_profile_save',
            'userId': userId,
            'updates': filteredPayload,
            'profilePayload': filteredProfilePayload,
            'timestamp': DateTime.now().toIso8601String(),
          });
          if (ref.mounted) {
            state = AsyncData(localProfile);
          }
          if (isFirstCompletion) {
            try {
              await localDb.saveVisibilityUpdateToOutbox(userId, true);
            } catch (_) {}
            try {
              unawaited(
                ref.read(isVisibleProvider.notifier).onProfileCompleted(),
              );
            } catch (_) {}
          }
          return true;
        }
        rethrow;
      }

      try {
        final updatedRow = await supabase
            .from('users')
            .select('editable_profile_fields')
            .eq('id', userId)
            .maybeSingle();
        if (updatedRow != null) {
          final fields = _toStringList(updatedRow['editable_profile_fields']);
          localProfile = localProfile.copyWith(editableProfileFields: fields);
          await localDb.saveLocalProfile(userId, localProfile.toMap());
          _markProfileLocalSave(userId);
          ref.invalidate(userProfileProvider(userId));
          if (ref.mounted) {
            state = AsyncData(localProfile);
          }
        }
      } catch (_) {}

      // Check referral completion
      if (markComplete) {
        unawaited(ref.read(referralServiceProvider).completeReferral(userId));
      }

      if (ref.mounted) {
        state = AsyncData(localProfile);
      }
      // Re-save to local DB after all Supabase operations complete to ensure
      // any concurrent realtime-triggered sync that may have overwritten the
      // local cache with stale data is corrected. This fixes the bug where
      // deleted interests reappear on the profile screen after the wizard saves.
      // The Hive write + invalidate below is what pushes the update to the
      // ProfileScreen in realtime.
      try {
        await localDb.saveLocalProfile(userId, localProfile.toMap());
        _markProfileLocalSave(userId);
        ref.invalidate(userProfileProvider(userId));
      } catch (e) {
        print('Local DB save after Supabase ops failed: $e');
      }

      // The profile just became complete (onboarding finished). While it was
      // incomplete the user was held invisible so the background service
      // would not show the "MatchMe Active" notification or poll GPS — now
      // that they are in the matching pool, activate them (default visible).
      if (markComplete && !wasCompleteBefore) {
        try {
          unawaited(ref.read(isVisibleProvider.notifier).onProfileCompleted());
        } catch (_) {}
      }
      return true;
    } catch (e, st) {
      if (ref.mounted) {
        if (e is PostgrestException) {
          final msg = e.message.toLowerCase();
          if (msg.contains('basic_details_update_not_allowed')) {
            final locale = ref.read(localizationProvider);
            state = AsyncError(
              locale.getString('profileEditBasicDetailsLocked'),
              st,
            );
            return false;
          }
        }
        state = AsyncError(e, st);
      }
      return false;
    }
  }
}
