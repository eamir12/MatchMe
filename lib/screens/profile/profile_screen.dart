// lib/screens/profile/profile_screen.dart
// Complete ProfileScreen updated to show ordered photo thumbnails (tap to preview full-screen),
// bio, languages, and all previous functionality preserved.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'dart:ui' as ui;
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/providers/unit_provider.dart';
import 'package:matchme/screens/profile/profile_wizard_screen.dart';
import 'package:matchme/screens/profile/verification_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/providers/new_options_provider.dart';
import 'package:matchme/providers/main_intents_provider.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:matchme/utils/string_extensions.dart';
import 'package:matchme/utils/zodiac.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:matchme/widgets/verified_badge.dart';
import 'package:matchme/widgets/new_user_badge.dart';
import 'package:matchme/providers/match_rating_provider.dart';
import 'package:matchme/services/match_rating_service.dart';
import 'package:matchme/widgets/ad_slot.dart';
import 'package:matchme/widgets/app_empty_state.dart';
import 'package:matchme/widgets/app_skeleton.dart';
import 'package:matchme/models/sponsored_ad.dart';
import 'package:matchme/widgets/photo_gallery_viewer.dart';

final supabase = Supabase.instance.client;

String _normalizeKey(String s) {
  final trimmed = s.trim().toLowerCase();
  final replaced = trimmed.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  final collapsed = replaced.replaceAll(RegExp(r'_+'), '_');
  return collapsed.replaceAll(RegExp(r'^_|_$'), '');
}

bool _isBusinessIntentKey(String s) =>
    _normalizeKey(s) == 'business_networking';

bool _hasBusinessIntent(UserProfile p) =>
    p.activeModes.any((m) => _isBusinessIntentKey(m));

bool _hasSocialIntent(UserProfile p) => p.activeModes.any(
  (m) => m != '0' && m.isNotEmpty && !_isBusinessIntentKey(m),
);

/// Interests actually belonging to the currently active intents. Business
/// interests require business/networking; personal interests require a social
/// intent. Orphans from a removed intent are hidden in realtime.
Map<String, List<String>> _effectivePersonalInterests(UserProfile p) =>
    _hasSocialIntent(p) ? p.personalInterests : <String, List<String>>{};

Map<String, List<String>> _effectiveBusinessInterests(UserProfile p) =>
    _hasBusinessIntent(p) ? p.businessInterests : <String, List<String>>{};

/// Lightweight value projection of the fields the ProfileScreen actually
/// displays. We compare via value equality so a fresh [UserProfile] object
/// with the same display-relevant data does NOT trigger another build of
/// this heavy screen (the underlying StreamProvider re-emits whenever the
/// local DB changes, including unrelated bookkeeping fields).
@immutable
class _ProfileView {
  final UserProfile? profile;
  const _ProfileView(this.profile);

  factory _ProfileView.from(UserProfile? p) => _ProfileView(p);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _ProfileView) return false;
    final a = profile;
    final b = other.profile;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a.id == b.id &&
        a.name == b.name &&
        a.gender == b.gender &&
        a.isVerified == b.isVerified &&
        a.verificationStatus == b.verificationStatus &&
        a.bio == b.bio &&
        a.preferredLanguage == b.preferredLanguage &&
        a.subscriptionTier == b.subscriptionTier &&
        a.credits == b.credits &&
        a.createdAt == b.createdAt &&
        a.dateOfBirth == b.dateOfBirth &&
        a.userTimezone == b.userTimezone &&
        a.linkedinUrl == b.linkedinUrl &&
        a.instagramUrl == b.instagramUrl &&
        a.facebookUrl == b.facebookUrl &&
        a.height == b.height &&
        a.heightUnit == b.heightUnit &&
        a.occupation == b.occupation &&
        a.education == b.education &&
        a.zodiacSign == b.zodiacSign &&
        _deepEq(a.lifestyle, b.lifestyle) &&
        _deepEq(a.family, b.family) &&
        _deepEq(a.religion, b.religion) &&
        _listEq(a.photos, b.photos) &&
        _listEq(a.activeModes, b.activeModes) &&
        _mapEq(a.subIntents, b.subIntents) &&
        _mapEq(a.personalInterests, b.personalInterests) &&
        _mapEq(a.businessInterests, b.businessInterests) &&
        _mapEq(a.languagesKnown, b.languagesKnown);
  }

  @override
  int get hashCode {
    final p = profile;
    if (p == null) return 0;
    return Object.hashAll([
      p.id,
      p.name,
      p.gender,
      p.isVerified,
      p.verificationStatus,
      p.bio,
      p.preferredLanguage,
      p.subscriptionTier,
      p.credits,
      p.createdAt,
      p.dateOfBirth,
      p.userTimezone,
      p.linkedinUrl,
      p.instagramUrl,
      p.facebookUrl,
      p.height,
      p.heightUnit,
      p.occupation,
      p.education,
      p.zodiacSign,
      p.lifestyle,
      p.family,
      p.religion,
      Object.hashAll(p.photos),
      Object.hashAll(p.activeModes),
      _mapHash(p.subIntents),
      _mapHash(p.personalInterests),
      _mapHash(p.businessInterests),
      _mapHash(p.languagesKnown),
    ]);
  }
}

bool _deepEq(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (a[key] != b[key]) return false;
  }
  return true;
}

bool _mapEq(Map<String, List<String>>? a, Map<String, List<String>>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!_listEq(a[key], b[key])) return false;
  }
  return true;
}

int _mapHash(Map<String, List<String>>? map) {
  if (map == null) return 0;
  var hash = 0;
  for (final entry in map.entries) {
    hash = Object.hash(hash, entry.key, Object.hashAll(entry.value));
  }
  return hash;
}

bool _listEq<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// MatchMe4 - Profile Screen
/// Shows user's own profile with photos, bio, interests, etc.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  // Cache for resolved display labels to avoid repeated computations
  static final Map<String, String> _displayLabelCache = {};

  // Cache for new user badge check to avoid repeated computations
  bool? _isNewUserCached;

  String _formatHeight(LocalizationState l10n, int heightCm, bool useImperial) {
    if (!useImperial) {
      return '$heightCm ${_t(l10n, 'settingsHeightCm')}';
    }
    final totalInches = (heightCm / 2.54).round();
    final feet = totalInches ~/ 12;
    final inches = totalInches % 12;
    return _t(l10n, 'profileHeightFeetInches')
        .replaceAll('{feet}', feet.toString())
        .replaceAll('{inches}', inches.toString());
  }

  String? _resolveLookupTranslationKey(
    Map<String, String>? lookup,
    String rawKey,
  ) {
    if (lookup == null || rawKey.trim().isEmpty) return null;
    for (final candidate in _translationLookupCandidates(rawKey)) {
      final match = lookup[candidate];
      if (match != null && match.trim().isNotEmpty) {
        return match;
      }
    }
    return null;
  }

  Iterable<String> _translationLookupCandidates(String rawKey) sync* {
    final seen = <String>{};

    void emit(String value) {
      final normalized = _normalizeKey(value);
      if (normalized.isNotEmpty && seen.add(normalized)) {
        // no-op: seen.add above ensures uniqueness while preserving insertion order
      }
    }

    void emitTokenVariants(List<String> tokens) {
      if (tokens.isEmpty) return;
      emit(tokens.join('_'));
      for (var i = 1; i < tokens.length; i++) {
        emit(tokens.sublist(i).join('_'));
      }
    }

    List<String> singularizeTokens(List<String> tokens) {
      String singularize(String token) {
        if (token.endsWith('ies') && token.length > 3) {
          return '${token.substring(0, token.length - 3)}y';
        }
        if (token.endsWith('ing') && token.length > 5) {
          final stem = token.substring(0, token.length - 3);
          if (stem.endsWith('v')) return '${stem}e';
          return stem;
        }
        if (token.endsWith('s') && token.length > 3) {
          return token.substring(0, token.length - 1);
        }
        return token;
      }

      return tokens.map(singularize).toList(growable: false);
    }

    emit(rawKey);
    if (rawKey.contains('::')) {
      final parts = rawKey.split('::');
      if (parts.length >= 2) {
        emit(parts.last);
      }
    }

    final normalized = _normalizeKey(rawKey);
    final parts = normalized
        .split(RegExp(r'[_.]'))
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
    emitTokenVariants(parts);

    final tokensWithoutFillers = parts
        .where((token) => token != 'and' && token != 'with')
        .toList(growable: false);
    emitTokenVariants(tokensWithoutFillers);

    final singularTokens = singularizeTokens(parts);
    emitTokenVariants(singularTokens);

    final singularWithoutFillers = singularTokens
        .where((token) => token != 'and' && token != 'with')
        .toList(growable: false);
    emitTokenVariants(singularWithoutFillers);

    if (normalized == 'gym_buddies') {
      emit('gym');
      emit('fitness_gym');
      emit('interest.friendship.fitness.gym');
    } else if (normalized == 'hiking_trails') {
      emit('hiking');
      emit('outdoors_hiking');
      emit('interest.activity.outdoors.hiking');
      emit('interest.romantic.outdoors.hiking');
    } else if (normalized == 'traveling') {
      emit('travel');
      emit('interest.friendship.travel');
    } else if (normalized == 'dates') {
      emit('dating');
      emit('date');
    } else if (normalized == 'walks') {
      emit('walking');
      emit('walk');
    } else if (normalized == 'music_and_art') {
      emit('music_art');
      emit('arts_music');
      emit('art_music');
    } else if (normalized == 'study_and_learning') {
      emit('study_learning');
      emit('learning');
      emit('study');
    } else if (normalized == 'startup_founders') {
      emit('startups_founders');
      emit('founders');
      emit('interest.business.entrepreneurship.startups');
    } else if (normalized == 'skill_sharing') {
      emit('sharing_skills');
      emit('skills_sharing');
    }

    for (final value in seen) {
      yield value;
    }
  }

  Map<String, String> _buildTranslationLookup(Map<String, String> source) {
    final lookup = <String, String>{};
    for (final entry in source.entries) {
      final translationKey = entry.value.trim();
      if (translationKey.isEmpty) continue;
      for (final alias in _translationLookupCandidates(entry.key)) {
        lookup.putIfAbsent(alias, () => translationKey);
      }
      for (final alias in _translationLookupCandidates(translationKey)) {
        lookup.putIfAbsent(alias, () => translationKey);
      }
    }
    return lookup;
  }

  // Humanize a key as a last-resort fallback for display:
  String _humanizeKey(String key) {
    var s = key;
    s = s.replaceAll(
      RegExp(
        r'^(interest_category_|interest_|category_|subIntent|intent|profileEdit)',
      ),
      '',
    );
    s = s.replaceAll('_', ' ');
    s = s.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    final words = s
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final human = words
        .map((w) {
          if (w.length <= 1) return w.toUpperCase();
          return w[0].toUpperCase() + w.substring(1);
        })
        .join(' ');

    final result = human.isEmpty ? key : human;
    return result;
  }

  String _localizedLifestyleValue(
    LocalizationState l10n,
    String category,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: category, context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final prefix =
        'lifestyle${category[0].toUpperCase()}${category.substring(1)}';
    final key = '$prefix$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedReligionValue(LocalizationState l10n, String value) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'religion', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final key = 'religion$value';
    return _tryGetString(l10n, key) ?? _humanizeKey(value);
  }

  String _localizedEducationValue(LocalizationState l10n, String value) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((fieldKey: 'education', context: 'profile')),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value.trim()).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final direct = _tryGetString(l10n, value.trim());
    if (direct != null) return direct;
    return _humanizeKey(value);
  }

  String _localizedFamilyWantsChildrenValue(
    LocalizationState l10n,
    String value,
  ) {
    final opts =
        ref
            .watch(
              fieldOptionsProvider((
                fieldKey: 'wants_children',
                context: 'profile',
              )),
            )
            .asData
            ?.value ??
        [];
    final match = opts.where((o) => o.profileValue == value).firstOrNull;
    if (match != null && match.profileDisplayKey.isNotEmpty) {
      final localized = _tryGetString(l10n, match.profileDisplayKey);
      if (localized != null) return localized;
    }
    final direct = _tryGetString(l10n, value);
    if (direct != null) return direct;
    return _humanizeKey(value);
  }

  bool _looksLikeTranslationKey(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(normalized);
  }

  String? _tryGetString(LocalizationState l10n, String key) {
    if (!_looksLikeTranslationKey(key)) return null;
    if (!l10n.containsKey(key)) return null;
    try {
      final val = l10n.getString(key);
      if (val.trim().isEmpty || val == key || val.endsWith('...')) return null;
      return val;
    } catch (_) {
      return null;
    }
  }

  // Extract language code from localization provider currentLocale value
  String _extractLangCode(dynamic cur) {
    try {
      if (cur == null) return 'en';
      if (cur is Locale) return cur.languageCode;
      if (cur is String) return (cur.split(RegExp('[-_]')).first);
      return cur.toString().split(RegExp('[-_]')).first;
    } catch (_) {
      return 'en';
    }
  }

  // Format a DateTime using localization provider:
  String _formatDateWithL10n(DateTime date, LocalizationState l10n) {
    try {
      final cur = l10n.currentLocale;
      final langCode = _extractLangCode(cur).toLowerCase();

      if (langCode.startsWith('he')) {
        try {
          final df = DateFormat('EEEE, d MMMM y', 'he');
          return df.format(date);
        } catch (_) {}
      }

      final enMonthLower = DateFormat.MMMM('en_US').format(date).toLowerCase();
      final monthKey = 'month_$enMonthLower';
      final translatedMonth = _tryGetString(l10n, monthKey);
      if (translatedMonth != null) {
        return '$translatedMonth ${date.day}, ${date.year}';
      }

      try {
        final localeTag = cur.toLanguageTag();
        final df = localeTag.isNotEmpty
            ? DateFormat.yMMMMd(localeTag)
            : DateFormat.yMMMMd();
        return df.format(date);
      } catch (_) {}

      return DateFormat('MMMM d, yyyy').format(date);
    } catch (_) {
      return DateFormat('MMMM d, yyyy').format(date);
    }
  }

  // Calculate age from date of birth
  int _calculateAge(DateTime birthDate) {
    final now = DateTime.now();
    int age = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  // Get age label for localization (same as profile wizard)
  String _ageLabelFor(LocalizationState l10n) {
    return l10n.getString('profileYourAge');
  }

  String _normalizeGenderDisplayKey(String raw) {
    final normalized = raw.trim().toLowerCase().replaceAll('-', '_');
    if (normalized.isEmpty) return normalized;
    if (normalized.startsWith('gender_')) return normalized;
    if (normalized == 'male' ||
        normalized == 'female' ||
        normalized == 'non_binary' ||
        normalized == 'nonbinary') {
      return normalized == 'nonbinary'
          ? 'gender_non_binary'
          : 'gender_$normalized';
    }
    return raw.trim();
  }

  // Resolve display label for a key or composite key into a user-friendly string.
  String _resolveDisplayLabel(
    LocalizationState l10n,
    String keyOrDisplay, {
    Map<String, String>? interestKeyToDisplayKey,
    Map<String, String>? categoryKeyToDisplayKey,
    Map<String, String>? allIntentsMap, // For sub-intents
  }) {
    // Create cache key from inputs
    final cacheKey =
        '$keyOrDisplay|${l10n.currentLocale.languageCode}|${l10n.translationSource}|${l10n.strings.length}|${interestKeyToDisplayKey?.length ?? 0}|${categoryKeyToDisplayKey?.length ?? 0}|${allIntentsMap?.length ?? 0}';
    if (_displayLabelCache.containsKey(cacheKey)) {
      return _displayLabelCache[cacheKey]!;
    }

    // Special case for invalid key "0"
    if (keyOrDisplay == '0') {
      return l10n.getString('profileUnknownIntent');
    }

    if (keyOrDisplay.trim().isEmpty) {
      return '';
    }

    // NOTE: full-key lookups MUST come before the '::' split below.
    // Composite interest keys like "dancing::salsa" have their own dedicated
    // translation ("interest.dancing.salsa" -> "Salsa"). If we split first we
    // redundantly prefix the parent category ("Dancing — Salsa") even though
    // the category is already shown as the section header above the chips.
    // Only fall through to the "Parent — Child" split when no dedicated
    // translation exists for the full key (e.g. intents).
    final resolvedIntentTranslationKey = _resolveLookupTranslationKey(
      allIntentsMap,
      keyOrDisplay,
    );
    if (resolvedIntentTranslationKey != null) {
      final mapped = resolvedIntentTranslationKey;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      return _humanizeKey(keyOrDisplay);
    }

    // NOTE: interest must be checked BEFORE category (same order as the
    // profile wizard). Sub-interest keys like `it_consulting` produce a
    // suffix candidate `consulting` which exists in the category map as
    // `interest.consulting` ("Consulting"). Checking the category map first
    // hijacks the lookup and the exact interest match
    // (`it_consulting` -> `interest.consulting.it` = "IT Consulting") is
    // never reached.
    final resolvedInterestTranslationKey = _resolveLookupTranslationKey(
      interestKeyToDisplayKey,
      keyOrDisplay,
    );
    if (resolvedInterestTranslationKey != null) {
      final mapped = resolvedInterestTranslationKey;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      return _humanizeKey(keyOrDisplay);
    }

    final resolvedCategoryTranslationKey = _resolveLookupTranslationKey(
      categoryKeyToDisplayKey,
      keyOrDisplay,
    );
    if (resolvedCategoryTranslationKey != null) {
      final mapped = resolvedCategoryTranslationKey;
      final mappedLoc = _tryGetString(l10n, mapped);
      if (mappedLoc != null) {
        _displayLabelCache[cacheKey] = mappedLoc;
        return mappedLoc;
      }
      return _humanizeKey(keyOrDisplay);
    }

    // Fallback: split composite keys with no dedicated translation
    // (e.g. intents like "romantic::casual" -> "Romantic — Casual").
    // Interests with their own translation never reach here.
    if (keyOrDisplay.contains('::')) {
      final parts = keyOrDisplay.split('::');
      if (parts.length >= 2) {
        final left = parts[0];
        final right = parts.sublist(1).join('::'); // keep any extra separators

        final leftLocalized =
            _tryGetString(l10n, allIntentsMap?[left] ?? left) ??
            _humanizeKey(left);
        String? rightLocalized;

        if (interestKeyToDisplayKey != null) {
          final mapped = interestKeyToDisplayKey[right];
          if (mapped != null && mapped.isNotEmpty) {
            rightLocalized = _tryGetString(l10n, mapped) ?? _humanizeKey(right);
          }
        }
        if ((rightLocalized == null || rightLocalized.trim().isEmpty) &&
            categoryKeyToDisplayKey != null) {
          final mappedCat = categoryKeyToDisplayKey[right];
          if (mappedCat != null && mappedCat.isNotEmpty) {
            rightLocalized =
                _tryGetString(l10n, mappedCat) ?? _humanizeKey(right);
          }
        }

        rightLocalized = rightLocalized ?? _humanizeKey(right);
        final result = '$leftLocalized — $rightLocalized';
        _displayLabelCache[cacheKey] = result;
        return result;
      }
    }

    final direct = _tryGetString(l10n, keyOrDisplay);
    if (direct != null) {
      _displayLabelCache[cacheKey] = direct;
      return direct;
    }

    // Handle race condition: if maps are empty during initialization,
    // try common prefixes before falling back to humanization
    if (!keyOrDisplay.contains('.') && !keyOrDisplay.contains('::')) {
      const prefixes = ['interest.', 'intent.activity.', 'intent.'];
      for (final prefix in prefixes) {
        final attempt = _tryGetString(l10n, '$prefix$keyOrDisplay');
        if (attempt != null) {
          _displayLabelCache[cacheKey] = attempt;
          return attempt;
        }
      }
    }

    return _humanizeKey(keyOrDisplay);
  }

  // Open a full-screen preview of the profile photos supporting swiping and gesture navigation
  void _openPhotoPreview(
    BuildContext context,
    int initialIndex,
    List<String> photos,
    LocalizationState l10n,
  ) {
    showDialog(
      context: context,
      builder: (_) => PhotoGalleryViewer(
        photos: photos,
        initialIndex: initialIndex,
        l10n: l10n,
      ),
    );
  }

  Widget _buildVerificationStatusCard(
    BuildContext context,
    LocalizationState l10n,
    UserProfile profile,
  ) {
    final status = profile.verificationStatus.trim().toLowerCase();
    if (profile.isVerified || status == 'approved') {
      // Nothing to show for an approved verification. The verified badge
      // already carries the meaning, and the explanatory note has been
      // removed from the product.
      return const SizedBox.shrink();
    }

    final colors = Theme.of(context).colorScheme;
    final isPending = status == 'pending' || status == 'analyzing';
    final isRejected = status == 'rejected';
    final title = isPending
        ? l10n.getString('underReview')
        : isRejected
        ? l10n.getString('verificationRejected')
        : l10n.getString('notVerified');
    final description = isPending
        ? l10n.getString('underReviewDescription')
        : isRejected
        ? l10n.getString('verificationRejectedCanRetry')
        : l10n.getString('notVerifiedDescription');
    final icon = isPending
        ? Icons.hourglass_top
        : isRejected
        ? Icons.error_outline
        : Icons.verified_user_outlined;
    final color = isPending
        ? colors.tertiary
        : isRejected
        ? colors.error
        : colors.primary;
    final actionLabel = isPending
        ? l10n.getString('verificationReview')
        : isRejected
        ? l10n.getString('verificationRetryNow')
        : l10n.getString('verifyNow');

    return Semantics(
      container: true,
      label: '$title. $description',
      child: Card(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        elevation: 0,
        color: color.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: color.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const VerificationScreen(),
                          ),
                        ),
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: Text(actionLabel),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Realtime: watch the profile stream directly so wizard saves (which
    // write the local DB + invalidate this provider) rebuild this screen
    // immediately. Do NOT use ref.read here — it snapshots once and never
    // rebuilds, which is why wizard edits previously appeared stale until
    // a manual refresh.
    // The _ProfileView projection below gates only the *heavy* list body:
    // when the local DB re-emits a fresh UserProfile object with identical
    // display-relevant data, the inner content does not rebuild.
    final l10n = ref.watch(localizationProvider);
    final usesImperialUnits = ref
        .watch(unitSystemProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    final user = supabase.auth.currentUser;
    if (user == null) {
      return Scaffold(body: Center(child: Text(_t(l10n, 'generalError'))));
    }
    final userId = user.id;
    // Watched for its rebuild side-effect only — the value is not read here
    // any more since the stale-profile banner was removed. Keep the watch: it
    // is what makes wizard saves reflect on this screen in realtime.
    ref.watch(profileSyncStateProvider(userId));

    // Watch (not read) so every local-DB emission — including wizard saves
    // that happen while this route is underneath the wizard — rebuilds
    // immediately in realtime. See _ProfileView for the value-equal
    // projection used to skip no-op rebuilds of identical data.
    final profileAsyncValue = ref.watch(localUserProfileProvider(userId));
    // Subscribe to the value-equal projection as well: when the DB re-emits
    // a fresh object with identical display data, Riverpod short-circuits
    // this selector and avoids re-running the heavy body below.
    ref.watch(
      localUserProfileProvider(
        userId,
      ).select((async) => _ProfileView.from(async.asData?.value)),
    );

    final allIntentsAsync = ref.watch(allIntentsProvider);
    final mainIntents = ref.watch(mainIntentsProvider);
    // Use the new provider to get only relevant interests for the selected intents
    final allIntents = allIntentsAsync.asData?.value ?? [];
    final allInterests = ref.watch(allInterestsProvider).asData?.value ?? [];
    final intentDisplayMap = _buildTranslationLookup({
      for (final intent in allIntents) intent.key: intent.translationKey,
    });
    final interestDisplayMap = _buildTranslationLookup({
      for (final interest in allInterests)
        interest.key: interest.translationKey,
    });
    final categoryDisplayMap = _buildTranslationLookup({
      for (final category in allInterests.where(
        (i) => i.parentId == null || i.parentId == 0,
      ))
        category.key: category.translationKey,
    });
    return Scaffold(
      floatingActionButton: Builder(
        builder: (context) => FloatingActionButton.extended(
          heroTag: 'profile_edit_fab',
          onPressed: () async {
            final currentUser = supabase.auth.currentUser;
            if (currentUser == null) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(_t(l10n, 'generalError'))));
              return;
            }
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) =>
                    ProfileWizardScreen(user: currentUser, isEditing: true),
              ),
            );
            // Realtime guarantee: the wizard writes the local DB on save and
            // the stream above already rebuilt, but if the wizard was
            // dismissed without save (or a stream event was missed while the
            // route was offstage), force a refresh on return so this screen
            // can never show stale data.
            if (!mounted) return;
            ref.invalidate(localUserProfileProvider(userId));
            try {
              await ref
                  .read(profileSyncProvider)
                  .syncProfile(
                    userId,
                    source: 'profile-screen-return-from-wizard',
                  );
            } catch (_) {}
          },
          tooltip: _t(l10n, 'generalEdit'),
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(Icons.edit_outlined),
          label: Text(_t(l10n, 'generalEdit')),
        ),
      ),
      body: Builder(
        builder: (context) => profileAsyncValue.when(
          data: (profile) {
            if (profile == null) {
              return AppEmptyState(
                icon: Icons.person_off_outlined,
                title: l10n.getString('profileLoadErrorTitle'),
                message: l10n.getString('profileLoadErrorMessage'),
                actionLabel: l10n.getString('generalRetry'),
                onAction: () {
                  unawaited(
                    ref
                        .read(profileSyncProvider)
                        .syncProfile(
                          userId,
                          source: 'profile-screen-retry-empty',
                        ),
                  );
                },
              );
            }

            return RefreshIndicator(
              onRefresh: () async {
                await ref
                    .read(profileSyncProvider)
                    .syncProfile(
                      userId,
                      source: 'profile-screen-pull-to-refresh',
                    );
              },
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                children: [
                  // Photos: show thumbnails in order. If none, show placeholder.
                  if (profile.photos.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: SizedBox(
                        height: 140,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: profile.photos.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (ctx, i) {
                            final source = profile.photos[i];
                            final photoLabel = l10n.getString(
                              'profilePhotoPreviewLabel',
                              params: {'index': '${i + 1}'},
                            );
                            return Semantics(
                              button: true,
                              label: photoLabel,
                              child: Tooltip(
                                message: photoLabel,
                                child: GestureDetector(
                                  onTap: () => _openPhotoPreview(
                                    context,
                                    i,
                                    profile.photos,
                                    l10n,
                                  ),
                                  child: Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: SignedImage(
                                          source: source,
                                          width: 140,
                                          height: 140,
                                          fit: BoxFit.cover,
                                          placeholder: Container(
                                            width: 140,
                                            height: 140,
                                            color: Colors.grey.shade100,
                                          ),
                                          errorWidget: Container(
                                            width: 140,
                                            height: 140,
                                            color: Colors.grey.shade200,
                                            child: const Icon(
                                              Icons.broken_image,
                                              size: 36,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (i == 0)
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          bottom: 0,
                                          child: Container(
                                            color: Colors.black54,
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 2,
                                            ),
                                            child: Text(
                                              l10n.getString(
                                                'profileWizardPrimaryPhotoBadge',
                                              ),
                                              textAlign: TextAlign.center,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: SizedBox(
                        height: 140,
                        child: Center(child: Text(_t(l10n, 'profileNoPhotos'))),
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Name (always capitalized regardless of how the user typed it)
                  // Badges sit directly next to the name (same Wrap) so there is
                  // no far-edge gap, and the whole unit stays aligned to the
                  // start side in both RTL and LTR. The name value itself is
                  // bidi-isolated so a Latin name in a Hebrew UI (or vice versa)
                  // keeps correct order without pulling the alignment.
                  (() {
                    final displayName = profile.name.capitalizeName();
                    final badgeWidgets = <Widget>[];
                    if (profile.isVerified) {
                      // Use gender-specific translation key based on user's gender
                      final normalizedGender = profile.gender
                          ?.trim()
                          .toLowerCase();
                      final translationKey = normalizedGender == 'female'
                          ? 'profileVerifiedBadgeFemale'
                          : (normalizedGender == 'non_binary' ||
                                normalizedGender == 'nonbinary')
                          ? 'profileVerifiedBadgeNeutral'
                          : 'profileVerifiedBadge';
                      badgeWidgets.add(
                        VerifiedBadge(
                          size: 20,
                          showText: true,
                          text: _t(l10n, translationKey),
                        ),
                      );
                    }
                    // Check if user is new (under 1 week) - cache the result to avoid repeated computations
                    if (_isNewUserCached == null && profile.createdAt != null) {
                      final now = DateTime.now();
                      final difference = now.difference(profile.createdAt!);
                      _isNewUserCached = difference.inDays < 7;
                      if (kDebugMode) {
                        debugPrint(
                          '[ProfileScreen] Account age: ${difference.inDays} days, isNewUser: $_isNewUserCached',
                        );
                      }
                    }

                    if (_isNewUserCached == true) {
                      // Use gender-specific translation key based on user's gender
                      final normalizedGender = profile.gender
                          ?.trim()
                          .toLowerCase();
                      final translationKey = normalizedGender == 'female'
                          ? 'profileNewUserBadgeFemale'
                          : (normalizedGender == 'non_binary' ||
                                normalizedGender == 'nonbinary')
                          ? 'profileNewUserBadgeNeutral'
                          : 'profileNewUserBadge';
                      badgeWidgets.add(
                        NewUserBadge(
                          size: 20,
                          showText: true,
                          text: _t(l10n, translationKey),
                          gender: profile.gender,
                        ),
                      );
                    }
                    final uiDirection = Directionality.of(context);
                    final nameLabel = _t(l10n, 'profileName');
                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.grey.shade200),
                      ),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          textDirection: uiDirection,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.person_outline_rounded,
                              color: Colors.grey[600],
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Wrap(
                                textDirection: uiDirection,
                                alignment: WrapAlignment.start,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(text: '$nameLabel: '),
                                        // Isolate the user-entered name so mixed
                                        // RTL/LTR content orders correctly.
                                        TextSpan(
                                          text: '\u2066$displayName\u2069',
                                        ),
                                      ],
                                    ),
                                    // Paragraph follows the UI direction so the
                                    // row aligns like every other profile row
                                    // (right in RTL, left in LTR).
                                    textDirection: uiDirection,
                                    textAlign: TextAlign.start,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                  ...badgeWidgets,
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  })(),
                  _buildVerificationStatusCard(context, l10n, profile),
                  (() {
                    final displayName = profile.name.trim();
                    final parts = displayName
                        .split(RegExp(r'\s+'))
                        .where((p) => p.trim().isNotEmpty)
                        .toList(growable: false);
                    final hasLastName = parts.length >= 2;
                    if (!hasLastName) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 16,
                        end: 16,
                        top: 2,
                        bottom: 12,
                      ),
                      child: Text(
                        _t(l10n, 'profileLastNameNotDisplayed'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey.shade600,
                        ),
                      ),
                    );
                  })(),

                  // Birthday
                  _buildProfileItem(
                    context,
                    Icons.cake_outlined,
                    _t(l10n, 'profileBirthday'),
                    profile.dateOfBirth != null
                        ? _formatDateWithL10n(profile.dateOfBirth!, l10n)
                        : _t(l10n, 'profileNotSet'),
                  ),

                  // Age (displayed separately like in profile wizard)
                  if (profile.dateOfBirth != null) ...[
                    const SizedBox(height: 8),
                    _buildProfileItem(
                      context,
                      Icons.calendar_month_outlined,
                      _ageLabelFor(l10n),
                      '${_calculateAge(profile.dateOfBirth!)}',
                    ),
                  ],

                  // Zodiac Sign
                  if (profile.dateOfBirth != null &&
                      calculateZodiacSign(profile.dateOfBirth) != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildProfileItem(
                        context,
                        Icons.auto_awesome_outlined,
                        _t(l10n, 'profileZodiacSign'),
                        () {
                          final sign = calculateZodiacSign(
                            profile.dateOfBirth,
                          )!;
                          return '${zodiacIcon(sign)} ${_t(l10n, 'zodiac${sign.capitalize()}')}';
                        }(),
                      ),
                    ),

                  // Gender
                  Consumer(
                    builder: (ctx, ref, _) {
                      final genderOptionsAsync = ref.watch(
                        genderOptionsProvider,
                      );
                      return genderOptionsAsync.when(
                        data: (options) {
                          final genderKey = profile.gender ?? '';
                          String genderDisplay;
                          try {
                            final Map<String, String> found = options
                                .firstWhere(
                                  (o) =>
                                      (o['key'] ?? '').trim().toLowerCase() ==
                                      genderKey.trim().toLowerCase(),
                                  orElse: () => <String, String>{},
                                );

                            if (found.isNotEmpty) {
                              final displayKey = found['displayKey'] ?? '';
                              final translated =
                                  _tryGetString(
                                    l10n,
                                    _normalizeGenderDisplayKey(displayKey),
                                  ) ??
                                  _tryGetString(
                                    l10n,
                                    _normalizeGenderDisplayKey(genderKey),
                                  );

                              genderDisplay =
                                  translated ??
                                  (genderKey.trim().isEmpty
                                      ? _t(l10n, 'profileNotSet')
                                      : _humanizeKey(genderKey));
                            } else {
                              if (genderKey.trim().isEmpty) {
                                genderDisplay = _t(l10n, 'profileNotSet');
                              } else {
                                genderDisplay = _humanizeKey(genderKey);
                              }
                            }
                          } catch (e) {
                            if (genderKey.trim().isEmpty) {
                              genderDisplay = _t(l10n, 'profileNotSet');
                            } else {
                              genderDisplay = _humanizeKey(genderKey);
                            }
                          }
                          return _buildProfileItem(
                            ctx,
                            Icons.wc_outlined,
                            _t(l10n, 'profileGender'),
                            genderDisplay,
                          );
                        },
                        loading: () => _buildProfileItem(
                          ctx,
                          Icons.wc_outlined,
                          _t(l10n, 'profileGender'),
                          _t(l10n, 'generalLoading'),
                        ),
                        error: (e, s) => _buildProfileItem(
                          ctx,
                          Icons.wc_outlined,
                          _t(l10n, 'profileGender'),
                          _t(l10n, 'generalError'),
                        ),
                      );
                    },
                  ),

                  // Bio display (if present)
                  if ((profile.bio ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _t(l10n, 'profileAbout'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Card(
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.grey.shade200),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Text(
                                profile.bio ?? '',
                                textDirection:
                                    RegExp(
                                      r'[a-zA-Z]',
                                    ).hasMatch(profile.bio ?? '')
                                    ? ui.TextDirection.ltr
                                    : ui.TextDirection.rtl,
                                textAlign: (profile.bio ?? '').isRtl()
                                    ? TextAlign.right
                                    : TextAlign.left,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  // Occupation
                  if (profile.occupation != null &&
                      profile.occupation!.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildProfileItem(
                      context,
                      Icons.work_outline,
                      _t(l10n, 'profileOccupation'),
                      profile.occupation!,
                    ),
                  ],

                  // Education
                  if (profile.education != null &&
                      profile.education!.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildProfileItem(
                      context,
                      Icons.school_outlined,
                      _t(l10n, 'profileEducation'),
                      _localizedEducationValue(l10n, profile.education!),
                    ),
                  ],

                  // Height
                  if (profile.height != null) ...[
                    const SizedBox(height: 12),
                    _buildProfileItem(
                      context,
                      Icons.straighten,
                      _t(l10n, 'profileHeight'),
                      _formatHeight(l10n, profile.height!, usesImperialUnits),
                    ),
                  ],

                  // Lifestyle section
                  if (profile.lifestyle != null &&
                      (profile.lifestyle!['smoking'] != null ||
                          profile.lifestyle!['drinking'] != null ||
                          profile.lifestyle!['exercise'] != null ||
                          profile.lifestyle!['diet'] != null)) ...[
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        _t(l10n, 'profileLifestyle'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (profile.lifestyle!['smoking'] != null &&
                        (profile.lifestyle!['smoking'] as String)
                            .trim()
                            .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.smoke_free_outlined,
                          _t(l10n, 'profileLifestyleSmoking'),
                          _localizedLifestyleValue(
                            l10n,
                            'smoking',
                            profile.lifestyle!['smoking'] as String,
                          ),
                        ),
                      ),
                    if (profile.lifestyle!['drinking'] != null &&
                        (profile.lifestyle!['drinking'] as String)
                            .trim()
                            .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.local_bar_outlined,
                          _t(l10n, 'profileLifestyleDrinking'),
                          _localizedLifestyleValue(
                            l10n,
                            'drinking',
                            profile.lifestyle!['drinking'] as String,
                          ),
                        ),
                      ),
                    if (profile.lifestyle!['exercise'] != null &&
                        (profile.lifestyle!['exercise'] as String)
                            .trim()
                            .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.fitness_center_outlined,
                          _t(l10n, 'profileLifestyleExercise'),
                          _localizedLifestyleValue(
                            l10n,
                            'exercise',
                            profile.lifestyle!['exercise'] as String,
                          ),
                        ),
                      ),
                    if (profile.lifestyle!['diet'] != null &&
                        (profile.lifestyle!['diet'] as String)
                            .trim()
                            .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.restaurant_outlined,
                          _t(l10n, 'profileLifestyleDiet'),
                          _localizedLifestyleValue(
                            l10n,
                            'diet',
                            profile.lifestyle!['diet'] as String,
                          ),
                        ),
                      ),
                  ],

                  // Family section
                  if (profile.family != null &&
                      (profile.family!['has_children'] != null ||
                          (profile.family!['wants_children'] != null &&
                              (profile.family!['wants_children'] as String)
                                  .trim()
                                  .isNotEmpty))) ...[
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        _t(l10n, 'profileFamily'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (profile.family!['has_children'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.child_care_outlined,
                          _t(l10n, 'profileFamilyHasChildren'),
                          (profile.family!['has_children'] == true)
                              ? _t(l10n, 'profileYes')
                              : _t(l10n, 'profileNo'),
                        ),
                      ),
                    if (profile.family!['wants_children'] != null &&
                        (profile.family!['wants_children'] as String)
                            .trim()
                            .isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _buildProfileItem(
                          context,
                          Icons.child_friendly_outlined,
                          _t(l10n, 'profileFamilyWantsChildren'),
                          _localizedFamilyWantsChildrenValue(
                            l10n,
                            profile.family!['wants_children'] as String,
                          ),
                        ),
                      ),
                  ],

                  // Religion section
                  if (profile.religion != null &&
                      (profile.religion!['religion'] != null &&
                          (profile.religion!['religion'] as String)
                              .trim()
                              .isNotEmpty)) ...[
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        _t(l10n, 'profileReligion'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _buildProfileItem(
                        context,
                        Icons.self_improvement_outlined,
                        _t(l10n, 'settingsReligion'),
                        _localizedReligionValue(
                          l10n,
                          profile.religion!['religion'] as String,
                        ),
                      ),
                    ),
                  ],

                  const Divider(height: 30),

                  // Social Links
                  if (_hasAnySocialLinks(profile))
                    _buildSocialLinksSection(context, l10n, profile),

                  // Intents
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.getString('profileEditIntentsTitle'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        if (profile.activeModes.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Text(
                              l10n.getString('profileWizardNoIntents'),
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ),
                        allIntentsAsync.when(
                          data: (allIntents) {
                            final Map<String, String>
                            mainIntentNormalizedLookup = {};
                            for (var opt in mainIntents) {
                              mainIntentNormalizedLookup[_normalizeKey(
                                    opt.key,
                                  )] =
                                  opt.translationKey;
                            }

                            final validMainModes = profile.activeModes.where((
                              modeKey,
                            ) {
                              final nm = _normalizeKey(modeKey);
                              return modeKey != '0' &&
                                  modeKey.isNotEmpty &&
                                  mainIntentNormalizedLookup.containsKey(nm);
                            }).toList();

                            final intentOrder = [
                              'romantic',
                              'friendship',
                              'activity_partner',
                              'business_networking',
                            ];
                            final sortedValidModes = validMainModes
                              ..sort((a, b) {
                                final aNorm = _normalizeKey(a);
                                final bNorm = _normalizeKey(b);
                                final aIndex = intentOrder.indexOf(aNorm);
                                final bIndex = intentOrder.indexOf(bNorm);
                                if (aIndex == -1) return 1;
                                if (bIndex == -1) return -1;
                                return aIndex.compareTo(bIndex);
                              });

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: sortedValidModes.map((modeKey) {
                                final norm = _normalizeKey(modeKey);
                                final displayKey =
                                    mainIntentNormalizedLookup[norm] ?? modeKey;
                                final chipLabel = _resolveDisplayLabel(
                                  l10n,
                                  displayKey,
                                );

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Chip(
                                        label: Text(chipLabel),
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer,
                                      ),
                                      if (profile
                                              .subIntents[modeKey]
                                              ?.isNotEmpty ??
                                          false)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 16.0,
                                            top: 4.0,
                                          ),
                                          child: Wrap(
                                            spacing: 6.0,
                                            runSpacing: 0.0,
                                            children: () {
                                              final subIntentSortMap =
                                                  <String, int>{};
                                              for (final intent in allIntents) {
                                                subIntentSortMap[_normalizeKey(
                                                      intent.key,
                                                    )] =
                                                    intent.sortOrder;
                                              }
                                              final sortedSubKeys =
                                                  profile.subIntents[modeKey]!
                                                      .where(
                                                        (subKey) =>
                                                            subKey != '0' &&
                                                            subKey.isNotEmpty,
                                                      )
                                                      .toList()
                                                    ..sort((a, b) {
                                                      final aFullKey =
                                                          _normalizeKey(
                                                            a.contains('::')
                                                                ? a
                                                                : '$modeKey::$a',
                                                          );
                                                      final bFullKey =
                                                          _normalizeKey(
                                                            b.contains('::')
                                                                ? b
                                                                : '$modeKey::$b',
                                                          );
                                                      final aOrder =
                                                          subIntentSortMap[aFullKey] ??
                                                          9999;
                                                      final bOrder =
                                                          subIntentSortMap[bFullKey] ??
                                                          9999;
                                                      return aOrder.compareTo(
                                                        bOrder,
                                                      );
                                                    });
                                              return sortedSubKeys.map((
                                                subKey,
                                              ) {
                                                final subDisplayKey =
                                                    subKey.contains('::')
                                                    ? subKey.split('::').last
                                                    : subKey;
                                                final translationKey =
                                                    _resolveLookupTranslationKey(
                                                      intentDisplayMap,
                                                      subDisplayKey,
                                                    );
                                                final subLabel =
                                                    (translationKey != null
                                                        ? _tryGetString(
                                                            l10n,
                                                            translationKey,
                                                          )
                                                        : null) ??
                                                    _tryGetString(
                                                      l10n,
                                                      subKey,
                                                    ) ??
                                                    _tryGetString(
                                                      l10n,
                                                      subDisplayKey,
                                                    ) ??
                                                    _humanizeKey(subDisplayKey);
                                                return Chip(
                                                  label: Text(
                                                    subLabel,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                  backgroundColor:
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                );
                                              }).toList();
                                            }(),
                                          ),
                                        ),
                                    ],
                                  ), // end column
                                );
                              }).toList(),
                            );
                          },
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (e, s) => Text(
                            _t(l10n, 'generalError'),
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 30),

                  // Interests
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.getString('profileInterests'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        if ((_effectivePersonalInterests(profile).isEmpty) &&
                            (_effectiveBusinessInterests(profile).isEmpty))
                          Padding(
                            padding: const EdgeInsets.only(left: 8.0),
                            child: Text(
                              _t(l10n, 'profileNoInterests'),
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ),

                        (() {
                          // Build category → sub-interests maps directly from the buckets.
                          // Buckets are gated by active intents: business interests only
                          // belong to business/networking, personal interests only to
                          // social intents. Orphaned data from a removed intent is
                          // hidden so it disappears in realtime after the wizard save.
                          final Map<String, Set<String>> personalByCategory =
                              {};
                          for (final entry in _effectivePersonalInterests(
                            profile,
                          ).entries) {
                            final subKeys = entry.value
                                .where(
                                  (k) =>
                                      k != entry.key &&
                                      k != '0' &&
                                      k.isNotEmpty,
                                )
                                .toSet();
                            if (subKeys.isNotEmpty ||
                                entry.value.contains(entry.key)) {
                              personalByCategory[entry.key] = subKeys.isNotEmpty
                                  ? subKeys
                                  : {entry.key};
                            } else {
                              personalByCategory.putIfAbsent(
                                entry.key,
                                () => {},
                              );
                            }
                          }

                          final Map<String, Set<String>> businessByCategory =
                              {};
                          for (final entry in _effectiveBusinessInterests(
                            profile,
                          ).entries) {
                            final subKeys = entry.value
                                .where(
                                  (k) =>
                                      k != entry.key &&
                                      k != '0' &&
                                      k.isNotEmpty,
                                )
                                .toSet();
                            if (subKeys.isNotEmpty ||
                                entry.value.contains(entry.key)) {
                              businessByCategory[entry.key] = subKeys.isNotEmpty
                                  ? subKeys
                                  : {entry.key};
                            } else {
                              businessByCategory.putIfAbsent(
                                entry.key,
                                () => {},
                              );
                            }
                          }

                          Widget buildCategorySection(
                            String categoryKey,
                            Set<String> subKeys,
                            Color? chipColor,
                          ) {
                            final categoryDisplayName = _resolveDisplayLabel(
                              l10n,
                              categoryKey,
                              interestKeyToDisplayKey: interestDisplayMap,
                              categoryKeyToDisplayKey: categoryDisplayMap,
                            );

                            final allSubKeys =
                                subKeys
                                    .where((k) => k != categoryKey)
                                    .toList(growable: false)
                                  ..sort((a, b) {
                                    final aName = _resolveDisplayLabel(
                                      l10n,
                                      a,
                                      interestKeyToDisplayKey:
                                          interestDisplayMap,
                                      categoryKeyToDisplayKey:
                                          categoryDisplayMap,
                                    ).toLowerCase();
                                    final bName = _resolveDisplayLabel(
                                      l10n,
                                      b,
                                      interestKeyToDisplayKey:
                                          interestDisplayMap,
                                      categoryKeyToDisplayKey:
                                          categoryDisplayMap,
                                    ).toLowerCase();
                                    return aName.compareTo(bName);
                                  });

                            final isPrimaryOnly =
                                allSubKeys.isEmpty ||
                                (allSubKeys.length == 1 &&
                                    allSubKeys.first == categoryKey);

                            return Padding(
                              padding: const EdgeInsets.only(
                                left: 8.0,
                                bottom: 12.0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (!isPrimaryOnly) ...[
                                    Text(
                                      categoryDisplayName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 12.0,
                                      ),
                                      child: Wrap(
                                        spacing: 6.0,
                                        runSpacing: 4.0,
                                        children: allSubKeys.map((interestKey) {
                                          final displayName =
                                              _resolveDisplayLabel(
                                                l10n,
                                                interestKey,
                                                interestKeyToDisplayKey:
                                                    interestDisplayMap,
                                                categoryKeyToDisplayKey:
                                                    categoryDisplayMap,
                                              );
                                          return Chip(
                                            label: Text(
                                              displayName,
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 2,
                                            ),
                                            backgroundColor: chipColor,
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ] else
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 4.0,
                                      ),
                                      child: Text(
                                        categoryDisplayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }

                          final List<Widget> sections = [];

                          if (personalByCategory.isNotEmpty) {
                            sections.add(
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.favorite_outline,
                                      size: 20,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      l10n.getString(
                                        'profilePersonalInterests',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                            final personalEntries =
                                personalByCategory.entries.toList()
                                  ..sort((a, b) => a.key.compareTo(b.key));
                            for (final entry in personalEntries) {
                              sections.add(
                                buildCategorySection(
                                  entry.key,
                                  entry.value,
                                  Theme.of(context)
                                      .colorScheme
                                      .tertiaryContainer
                                      .withValues(alpha: 0.5),
                                ),
                              );
                            }
                          }

                          if (businessByCategory.isNotEmpty) {
                            sections.add(
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.business_center_outlined,
                                      size: 20,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      l10n.getString(
                                        'profileBusinessInterests',
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                            final businessEntries =
                                businessByCategory.entries.toList()
                                  ..sort((a, b) => a.key.compareTo(b.key));
                            for (final entry in businessEntries) {
                              sections.add(
                                buildCategorySection(
                                  entry.key,
                                  entry.value,
                                  Theme.of(context)
                                      .colorScheme
                                      .secondaryContainer
                                      .withValues(alpha: 0.5),
                                ),
                              );
                            }
                          }

                          if (sections.isEmpty) {
                            return Padding(
                              padding: const EdgeInsets.only(left: 8.0),
                              child: Text(
                                l10n.getString('profileNoInterests'),
                                style: const TextStyle(color: Colors.grey),
                              ),
                            );
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: sections,
                          );
                        })(),
                      ],
                    ),
                  ),

                  const Divider(height: 30),

                  // Languages Known
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.getString('profileLanguagesKnown'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Consumer(
                          builder: (ctx, ref, _) {
                            final languageOptionsAsync = ref.watch(
                              languageOptionsProvider,
                            );
                            return languageOptionsAsync.when(
                              data: (allLanguages) {
                                final Map<String, String> allLangsMap = {
                                  for (var v in allLanguages)
                                    v['code']!: l10n.getString(
                                      'lang_${v['code']}',
                                    ),
                                };
                                if (profile.languagesKnown.isEmpty) {
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Text(
                                      l10n.getString('profileNotSet'),
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                  );
                                }
                                final filteredEntries =
                                    <MapEntry<String, List<String>>>[];
                                final langs =
                                    profile.languagesKnown['languages'] ?? [];
                                for (final lang in langs) {
                                  if (lang == 'languages') continue;
                                  final skills =
                                      profile.languagesKnown[lang] ?? [];
                                  filteredEntries.add(MapEntry(lang, skills));
                                }
                                if (filteredEntries.isEmpty) {
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 8.0),
                                    child: Text(
                                      l10n.getString('profileNotSet'),
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                  );
                                }
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: filteredEntries.map((entry) {
                                    final langCode = entry.key;
                                    final langName =
                                        allLangsMap[langCode] ??
                                        l10n.getString('lang_$langCode');
                                    final skills = entry.value;
                                    // Format skills with capitalization
                                    final skillsText = skills
                                        .map((skillKey) {
                                          final skillName = l10n.getString(
                                            skillKey,
                                          );
                                          return skillName;
                                        })
                                        .join(', ');

                                    return Card(
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: BorderSide(
                                          color: Colors.grey.shade200,
                                        ),
                                      ),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 12,
                                        ),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.language_outlined,
                                              color: Colors.grey[600],
                                              size: 20,
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Text(
                                                '$langName: $skillsText',
                                                style: Theme.of(
                                                  ctx,
                                                ).textTheme.bodyMedium,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                              loading: () => const CircularProgressIndicator(),
                              error: (e, s) => Text(
                                _t(l10n, 'generalError'),
                                style: const TextStyle(color: Colors.red),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  Consumer(
                    builder: (ctx, ref, _) {
                      final ratingSummaryAsync = ref.watch(
                        userRatingSummaryProvider(userId),
                      );
                      final ratingQuestionsAsync = ref.watch(
                        ratingQuestionsProvider,
                      );
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0),
                        child: ratingSummaryAsync.when(
                          data: (summary) {
                            if (summary.overallAvg == null) {
                              return const SizedBox.shrink();
                            }
                            return ratingQuestionsAsync.when(
                              data: (questions) {
                                final firstFive = questions.take(5).toList();
                                final questionAverages = <double?>[
                                  summary.q1Avg,
                                  summary.q2Avg,
                                  summary.q3Avg,
                                  summary.q4Avg,
                                  summary.q5Avg,
                                ];

                                Future<void> showQuestion(
                                  String headerKey,
                                  String questionKey,
                                ) async {
                                  final header = l10n.getString(headerKey);
                                  final question = l10n.getString(questionKey);
                                  await showDialog<void>(
                                    context: ctx,
                                    builder: (dlgCtx) => AlertDialog(
                                      title: Text(header),
                                      content: Text(question),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.of(dlgCtx).pop(),
                                          child: Text(
                                            l10n.getString('generalCancel'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Divider(height: 30),
                                    Text(
                                      l10n.getString('ratingSectionTitle'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    Card(
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(16.0),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            for (
                                              var i = 0;
                                              i < firstFive.length &&
                                                  i < questionAverages.length;
                                              i++
                                            )
                                              if (questionAverages[i] != null)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        bottom: 2.0,
                                                      ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        child: Row(
                                                          children: [
                                                            Flexible(
                                                              child: Text(
                                                                l10n.getString(
                                                                  _headerKeyForQuestion(
                                                                    firstFive[i],
                                                                  ),
                                                                ),
                                                                style: Theme.of(
                                                                  context,
                                                                ).textTheme.bodyMedium,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                              ),
                                                            ),
                                                            IconButton(
                                                              visualDensity:
                                                                  VisualDensity
                                                                      .compact,
                                                              padding:
                                                                  EdgeInsets
                                                                      .zero,
                                                              icon: const Icon(
                                                                Icons
                                                                    .info_outline,
                                                                size: 18,
                                                              ),
                                                              onPressed: () =>
                                                                  showQuestion(
                                                                    _headerKeyForQuestion(
                                                                      firstFive[i],
                                                                    ),
                                                                    firstFive[i]
                                                                        .translationKey,
                                                                  ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      Text(
                                                        _formatScore(
                                                          questionAverages[i]!,
                                                          decimals: 1,
                                                        ),
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodyMedium
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                            const Divider(height: 18),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    l10n.getString(
                                                      'ratingOverall',
                                                    ),
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                  ),
                                                ),
                                                Text(
                                                  _formatScore(
                                                    summary.overallAvg!,
                                                    decimals: 2,
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodyMedium
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                              loading: () => const SizedBox.shrink(),
                              error: (e, s) => const SizedBox.shrink(),
                            );
                          },
                          loading: () => const SizedBox.shrink(),
                          error: (e, s) => const SizedBox.shrink(),
                        ),
                      );
                    },
                  ),

                  // Ad slot at bottom of profile
                  const AdSlot(placement: AdPlacement.profileInline),
                  const SizedBox(height: 60),
                ],
              ),
            );
          },
          loading: () => SafeArea(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: AppSkeletonList(
                itemCount: 5,
                itemHeight: 72,
                semanticLabel: l10n.getString('generalLoading'),
              ),
            ),
          ),
          error: (err, stack) => AppEmptyState(
            icon: Icons.person_off_outlined,
            title: l10n.getString('profileLoadErrorTitle'),
            message: l10n.getString('profileLoadErrorMessage'),
            actionLabel: l10n.getString('generalRetry'),
            onAction: () {
              unawaited(
                ref
                    .read(profileSyncProvider)
                    .syncProfile(userId, source: 'profile-screen-retry-error'),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildProfileItem(
    BuildContext context,
    IconData icon,
    String label,
    String value, {
    ui.TextDirection? textDirection,
    Widget? trailing,
  }) {
    return Semantics(
      container: true,
      label: '$label: $value',
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.grey[600], size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$label: $value',
                  textDirection: textDirection,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ),
    );
  }

  String _formatScore(double value, {int decimals = 1}) {
    final s = value.toStringAsFixed(decimals);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _headerKeyForQuestion(RatingQuestion q) {
    switch (q.id) {
      case 'communication':
        return 'ratingHeaderCommunication';
      case 'reliability':
        return 'ratingHeaderReliability';
      case 'respect':
        return 'ratingHeaderRespect';
      case 'safety':
        return 'ratingHeaderSafety';
      case 'profile_accuracy':
        return 'ratingHeaderAccuracy';
      default:
        return q.translationKey;
    }
  }

  String _t(LocalizationState l10n, String key) => l10n.getString(key);

  bool _hasAnySocialLinks(UserProfile profile) {
    return (profile.instagramUrl?.isNotEmpty == true) ||
        (profile.linkedinUrl?.isNotEmpty == true) ||
        (profile.facebookUrl?.isNotEmpty == true);
  }

  Widget _buildSocialLinksSection(
    BuildContext context,
    LocalizationState l10n,
    UserProfile profile,
  ) {
    final List<Widget> links = [];
    final hasBusinessIntent = profile.activeModes.any(
      (m) => _normalizeKey(m) == 'business_networking',
    );

    if (profile.instagramUrl?.isNotEmpty == true) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.camera_alt_outlined,
          Colors.pink,
          l10n.getString('profileInstagramUrl'),
          profile.instagramUrl!,
        ),
      );
    }

    if (profile.facebookUrl?.isNotEmpty == true) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.group,
          Colors.blue,
          l10n.getString('profileFacebookUrl'),
          profile.facebookUrl!,
        ),
      );
    }

    if (profile.linkedinUrl?.isNotEmpty == true && hasBusinessIntent) {
      links.add(
        _buildSocialLinkTile(
          context,
          Icons.business_center_outlined,
          Colors.blue,
          l10n.getString('profileLinkedinUrl'),
          profile.linkedinUrl!,
        ),
      );
    }

    if (links.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.getString('profileSocialLinks'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          ...links,
        ],
      ),
    );
  }

  Widget _buildSocialLinkTile(
    BuildContext context,
    IconData icon,
    Color iconColor,
    String label,
    String url,
  ) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: iconColor.withValues(alpha: 0.1),
          child: Icon(icon, color: iconColor),
        ),
        title: Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          url,
          style: TextStyle(color: Colors.blue.shade700, fontSize: 13),
          textDirection: ui.TextDirection.ltr,
        ),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => _openUrl(url),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null || (scheme != 'http' && scheme != 'https')) {
      _showSocialLinkOpenFailed();
      return;
    }

    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!launched) {
      try {
        launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
      } catch (_) {}
    }
    if (!launched) _showSocialLinkOpenFailed();
  }

  void _showSocialLinkOpenFailed() {
    if (!mounted) return;
    final l10n = ref.read(localizationProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.getString('profileSocialLinkOpenFailed')),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }
}
