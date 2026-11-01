// lib/providers/locale_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// intl also declares a TextDirection, which would shadow dart:ui's.
import 'package:intl/intl.dart' hide TextDirection;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/my_user_realtime_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/chat_notification_copy.dart';
import 'package:matchme/utils/plural_rules.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/chat_key_service.dart';
import 'package:matchme/services/language_choice_store.dart';
import 'package:matchme/services/local_db_service.dart';
import 'package:matchme/services/offline_cache_manager.dart';
import 'package:matchme/services/translation_service.dart';
import 'package:matchme/services/public_reference_data_service.dart';
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/background_service.dart';

part 'locale_provider.g.dart';

// --- 1. Language Model ---
/// Language codes written right-to-left.
///
/// Direction is derived from the code rather than trusted from
/// `app_languages.text_direction`. That column is seeded outside the migration
/// history, and `AppLanguage.direction` silently defaults to LTR — so a null or
/// 'LTR' value for Hebrew renders the entire UI, chevrons included, the wrong
/// way round. A code is a fact; a hand-entered column is not.
const Set<String> kRtlLanguageCodes = {
  'he', // Hebrew
  'iw', // Hebrew, legacy ISO code
  'yi', // Yiddish
  'ar', // Arabic
  'fa', // Persian
  'ur', // Urdu
  'ps', // Pashto
  'sd', // Sindhi
  'dv', // Divehi
  'ku', // Kurdish
  'ckb', // Central Kurdish
  'arc', // Aramaic
  'nqo', // N'Ko
};

/// True when [code] is a right-to-left language.
bool isRtlLanguageCode(String? code) {
  if (code == null) return false;
  var normalised = code.trim().toLowerCase().replaceAll('_', '-');
  if (normalised.isEmpty) return false;
  // Strip the region/script suffix: he-IL, ar-EG and sr-Latn all reduce to
  // their base code. sr-Latn is the notable case — Serbian in Latin script is
  // left-to-right.
  normalised = normalised.split('-').first;
  if (normalised == 'sr') return false;
  return kRtlLanguageCodes.contains(normalised);
}

/// Legacy/alternate platform language codes mapped to the modern ISO 639-1
/// code the app ships. Java (and some Android/Windows builds) still report
/// Hebrew as `iw`, Indonesian as `in`, Yiddish as `ji` and Javanese as `jw`.
const Map<String, String> kLegacyLanguageCodeAliases = {
  'iw': 'he',
  'in': 'id',
  'ji': 'yi',
  'jw': 'jv',
};

/// The initial UI language for a device: the device's own language when the
/// app ships it, otherwise English.
///
/// On a fresh install this is the only "choice" the user has made, so it must
/// win — but only when the language is actually supported. Platform codes are
/// normalised first (legacy `iw`, region suffixes like `he-IL`, case), so a
/// Hebrew device does not look unsupported and silently start in English.
///
/// This never consults stored preferences or the account: callers resolve
/// saved/explicit choices before falling back here.
String resolveDeviceLanguageCode(
  Iterable<String> supportedCodes,
  Locale? deviceLocale,
) {
  final raw = deviceLocale?.languageCode.trim().toLowerCase().replaceAll(
    '_',
    '-',
  );
  final base = (raw == null || raw.isEmpty) ? '' : raw.split('-').first;
  final code = kLegacyLanguageCodeAliases[base] ?? base;
  if (code.isNotEmpty &&
      supportedCodes.any((c) => c.trim().toLowerCase() == code)) {
    return code;
  }
  return 'en';
}

class AppLanguage {
  final String code;
  final String displayName;
  final TextDirection direction;

  AppLanguage({
    required this.code,
    required this.displayName,
    TextDirection? direction,
  }) : direction = direction ?? _directionFor(code);

  static TextDirection _directionFor(String code) =>
      isRtlLanguageCode(code) ? TextDirection.rtl : TextDirection.ltr;
}

/// Normalises a language code for comparisons: trimmed and lower-cased.
String normalizeContentLanguageCode(String? code) {
  final trimmed = (code ?? '').trim().toLowerCase();
  if (trimmed.isEmpty) return 'en';
  final base = trimmed.split('-').first.split('_').first;
  return base.isEmpty ? 'en' : base;
}

/// The language the loaded strings are actually in.
///
/// The loaded map is always "the bundled English defaults + the rows the
/// server returned for the chosen locale". When those rows are missing — the
/// device is offline, the fetch timed out, or the locale has no rows yet —
/// every visible string is the English fallback, so the UI has to lay out
/// left-to-right even though the member picked Hebrew. Laying English text
/// out right-to-left (or Hebrew text out left-to-right) is the "impossible"
/// state this mechanism exists to prevent.
String resolveContentLanguageCode({
  required String localeCode,
  required bool hasLocalizedRows,
}) {
  if (!hasLocalizedRows) return 'en';
  return normalizeContentLanguageCode(localeCode);
}

/// The key of the marker that records which language a cached translation
/// blob is really in.
String translationContentMarkerKey(String langCode) =>
    'translations_${langCode}_content';

/// How long a verified translation stamp is trusted when the stamp check
/// cannot run. Past this, the next start does a full download.
const _translationStampTtl = Duration(hours: 24);

/// The key of the cached `translations.updated_at` maximum for [langCode].
String translationStampKey(String langCode) =>
    'translations_${langCode}_stamp';

/// The key of the last successful stamp check or full fetch, in epoch
/// milliseconds.
String translationStampCheckedAtKey(String langCode) =>
    'translations_${langCode}_stamp_checked_at';

/// True when a cached string map holds translated rows rather than only the
/// bundled English defaults.
///
/// A cache written while the server was unreachable contains nothing but the
/// English fallbacks; a genuinely translated cache has at least one value
/// that differs from them. This is how a legacy cache (one written before
/// the content marker existed) is told apart from a translated one.
bool cachedStringsHoldLocalizedRows(Map<String, String> strings) {
  final defaults = LocalizationState._defaultTranslations;
  for (final entry in strings.entries) {
    final fallback = defaults[entry.key];
    if (fallback != null && fallback != entry.value) return true;
  }
  return false;
}

/// The language a cached translation blob is actually in.
///
/// The cache stores an explicit content marker next to the strings
/// (`translations_<locale>_content`). Legacy caches have no marker, so the
/// values are compared with the bundled English defaults to find out whether
/// the blob holds translated rows at all.
String resolveCachedContentLanguage({
  required String langCode,
  required Map<String, String> strings,
  String? marker,
}) {
  if (marker != null && marker.trim().isNotEmpty) {
    return normalizeContentLanguageCode(marker);
  }
  return resolveContentLanguageCode(
    localeCode: langCode,
    hasLocalizedRows: cachedStringsHoldLocalizedRows(strings),
  );
}

// --- 2. Localization State Model ---
class LocalizationState {
  /// The language the member picked (or that the device resolved to).
  final Locale currentLocale;
  final TextDirection textDirection;

  /// The language the loaded [strings] are actually in.
  ///
  /// Normally identical to [currentLocale]. It differs when the server copy of
  /// the chosen language could not be loaded and the app fell back to the
  /// bundled English defaults — in that case the direction follows the
  /// content (LTR), so English text is never laid out as if it were Hebrew.
  final String contentLanguageCode;

  final Map<String, String> strings;
  final List<AppLanguage> supportedLanguages;
  final bool isLoading;
  final Set<String> dbKeys;

  LocalizationState({
    required this.currentLocale,
    required TextDirection textDirection,
    required this.strings,
    required this.supportedLanguages,
    String? contentLanguageCode,
    this.isLoading = false,
    this.dbKeys = const <String>{},
  }) : contentLanguageCode = normalizeContentLanguageCode(
         contentLanguageCode ?? currentLocale.languageCode,
       ),
       textDirection = _reconcileDirection(
         normalizeContentLanguageCode(
           contentLanguageCode ?? currentLocale.languageCode,
         ),
         textDirection,
       );

  /// Direction follows the language of the CONTENT, always.
  ///
  /// [textDirection] is honoured only when it agrees with the content
  /// language. A Hebrew or Arabic locale can therefore never be paired with
  /// an LTR state — which would otherwise lay out the entire UI, chevrons
  /// included, backwards — and, symmetrically, English fallback text under a
  /// Hebrew locale is never laid out right-to-left.
  static TextDirection _reconcileDirection(
    String contentLanguageCode,
    TextDirection declared,
  ) {
    final fromCode = isRtlLanguageCode(contentLanguageCode)
        ? TextDirection.rtl
        : TextDirection.ltr;
    return declared == fromCode ? declared : fromCode;
  }

  factory LocalizationState.loading() {
    return LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: {},
      supportedLanguages: [],
      isLoading: true,
      dbKeys: const <String>{},
    );
  }

  LocalizationState copyWith({
    Locale? currentLocale,
    TextDirection? textDirection,
    String? contentLanguageCode,
    Map<String, String>? strings,
    List<AppLanguage>? supportedLanguages,
    bool? isLoading,
    Set<String>? dbKeys,
  }) {
    return LocalizationState(
      currentLocale: currentLocale ?? this.currentLocale,
      textDirection: textDirection ?? this.textDirection,
      contentLanguageCode: contentLanguageCode ?? this.contentLanguageCode,
      strings: strings ?? this.strings,
      supportedLanguages: supportedLanguages ?? this.supportedLanguages,
      isLoading: isLoading ?? this.isLoading,
      dbKeys: dbKeys ?? this.dbKeys,
    );
  }

  // Helper to get a string, with a fallback
  // NOTE: Missing translation logs can be noisy when many widgets call getString frequently.
  // To avoid spamming logs and impacting performance, we only log each missing key once.
  final Set<String> _missingTranslationWarned = <String>{};
  static int _missingKeysLimit = 20;

  /// The parameter that carries the quantity of a countable noun unless the
  /// caller says otherwise.
  static const String kDefaultPluralParam = 'count';

  /// Returns the translation stored under [key].
  ///
  /// [params] are substituted into `{name}` placeholders.
  ///
  /// When [params] carries a number for the plural parameter ([pluralParam],
  /// `count` by default) the lookup prefers a plural specific variant of
  /// [key] — `<key>_one`, `<key>_two`, … — over the base key, so that
  /// "1 minute left" and "2 minutes left" can use different templates. The
  /// variant is only used when a translation for it exists in the content
  /// language; otherwise the base key is used unchanged.
  String getString(
    String key, {
    String? gender,
    Map<String, String>? params,
    String? pluralParam,
  }) {
    final paramName = pluralParam ?? kDefaultPluralParam;
    final raw = params?[paramName];
    return _getString(
      key,
      gender: gender,
      params: params,
      pluralCount: raw == null ? null : num.tryParse(raw.trim()),
    );
  }

  String _getString(
    String key, {
    String? gender,
    Map<String, String>? params,
    num? pluralCount,
  }) {
    // The plural variant of the key ("<key>_one" for a single item). Falls
    // back to [key] when the quantity does not select a different form or
    // when the content language has no translation for that form.
    final pluralKey = _resolvePluralKey(key, pluralCount);

    // If gender provided, try gender-specific variant first. The DB uses suffixes like
    // '<key>_male', '<key>_female', '<key>_non_binary'. Accept either 'male'/'female'/'non_binary'
    // or 'gender_male' style values for convenience.

    // Try gendered key if possible
    if (gender != null && gender.trim().isNotEmpty) {
      final suffix = _normalizeGenderSuffix(gender);
      if (suffix.isNotEmpty) {
        final genderedKeys = <String>[
          '${pluralKey}_$suffix',
          if (pluralKey != key) '${key}_$suffix',
        ];
        for (final gKey in genderedKeys) {
          final gTranslation = strings[gKey] ?? _defaultTranslations[gKey];
          if (gTranslation != null) return _applyParams(gTranslation, params);
        }
      }
    }

    // Try direct lookup first
    final translation = strings[pluralKey];
    if (translation != null) {
      // Diagnostics: if diagnostics enabled and this key was not provided by DB, log it
      try {
        // If the key is part of defaults and not in dbKeys, the app is using the default not DB value
        if (ResumeDiagnostics.enabled &&
            _defaultTranslations.containsKey(pluralKey) &&
            !dbKeys.contains(pluralKey)) {
          ResumeDiagnostics.logThrottled(
            'DB missing translation for key: $pluralKey; using built-in default',
            category: 'missing_db_key.$pluralKey',
            minIntervalMs: 60000,
          );
        }
      } catch (_) {}
      return _applyParams(translation, params);
    }

    // Try with common prefixes to handle race condition where interestDisplayMapProvider
    // hasn't loaded yet. This allows UI to work even when interest/activity metadata
    // providers are still initializing.
    if (!key.contains('.') && !key.contains('::')) {
      // Only try prefixes if key doesn't already have a namespace
      const prefixes = ['interest.', 'intent.activity.', 'intent.'];
      for (final prefix in prefixes) {
        final prefixedKey = '$prefix$key';
        final prefixedTranslation = strings[prefixedKey];
        if (prefixedTranslation != null) {
          return _applyParams(prefixedTranslation, params);
        }
      }
    }

    // Fallback to default translations (prefer defaults over logging missing key)
    final defaultTranslation = _defaultTranslations[pluralKey];
    if (defaultTranslation != null) {
      return _applyParams(defaultTranslation, params);
    }

    // The base key may still hold a translated value even when the plural
    // variant does not (a non-English locale that never got the `_one` row).
    final baseTranslation = strings[key];
    if (baseTranslation != null) {
      return _applyParams(baseTranslation, params);
    }

    final baseDefault = _defaultTranslations[key];
    if (baseDefault != null) {
      return _applyParams(baseDefault, params);
    }

    // Only log the missing translation once per key to avoid spam
    if (!_missingTranslationWarned.contains(key) &&
        _missingTranslationWarned.length < _missingKeysLimit) {
      _missingTranslationWarned.add(key);
      debugPrint(
        'Missing translation for key: $key, strings has ${strings.length} entries',
      );
      if (key == 'chatIsTyping') {
        debugPrint(
          'Available string keys: ${strings.keys.where((k) => k.contains('chat')).toList()}',
        );
      }
      if (key == '0') {
        debugPrint('Stack trace for missing key "0": ${StackTrace.current}');
      }
    }

    // NO-TRUNCATION POLICY: never synthesize an ellipsis fallback.
    // A missing key renders as [key] in full so layout tests catch it
    // instead of users seeing a cut-off "key...".
    return '[$key]';
  }

  /// Returns the translation for [key] with the plural form that matches
  /// [count] in the content language.
  ///
  /// [countParam] names the placeholder the number is written into
  /// (`count` by default) and is also the parameter that selects the plural
  /// form.
  ///
  /// [displayValue] replaces the number written into the template when it
  /// differs from [count] — the compact formatter renders "1.5k" for 1500
  /// while the plural form still follows the real quantity.
  ///
  /// ```dart
  /// l10n.getPluralString('matchExpiryTitle', 1); // "1 minute left"
  /// l10n.getPluralString('matchExpiryTitle', 5); // "5 minutes left"
  /// ```
  String getPluralString(
    String key,
    num count, {
    Map<String, String>? params,
    String? countParam,
    String? displayValue,
  }) {
    final paramName = countParam ?? kDefaultPluralParam;
    final merged = <String, String>{
      ...?params,
      paramName: displayValue ?? count.toString(),
    };
    return _getString(key, params: merged, pluralCount: count);
  }

  /// The chat notification card copy, as a function of the unread count.
  ///
  /// [maskedName] is embedded here rather than by the renderer, because the
  /// name sits inside the sentence and its position depends on the language
  /// ("3 messages from John S." / "3 הודעות מאת יוסי כ.").
  ///
  /// The plural form is picked from [count], so the noun agrees with the real
  /// quantity: Hebrew grows a dual for two, Spanish a singular for one.
  ChatCopyForms chatCardForms({required String maskedName}) {
    // FSI/PDI around the name, exactly as the server does before it fills the
    // template: an RTL name inside an English sentence must not drag the whole
    // title right-to-left, and vice versa.
    final isolatedName = maskedName.isEmpty
        ? maskedName
        : '\u2068$maskedName\u2069';
    return ChatCopyForms(
      title: (count) => getPluralString(
        'pushMessagesTitle',
        count,
        params: {'name': isolatedName},
      ),
      openToReadBody: (count) => getPluralString('pushOpenToReadBody', count),
    );
  }

  /// Picks the key that carries the right plural form for [key].
  ///
  /// The base key holds the "other" (plural) form; the singular and — for
  /// Hebrew — the dual form live under `<key>_one` and `<key>_two`. When the
  /// content language has no translation for the selected form the base key
  /// is returned, so a partially translated locale still renders a sentence.
  String _resolvePluralKey(String key, num? count) {
    if (count == null) return key;

    final category = pluralCategoryFor(
      languageCode: contentLanguageCode,
      count: count,
    );
    // "other" is the base key itself.
    if (category == PluralCategory.other) return key;

    final pluralKey = '${key}_${category.keySuffix}';
    if (_hasContentTranslation(pluralKey)) return pluralKey;
    return key;
  }

  /// True when [key] holds a translation for the content language.
  ///
  /// The string map holds the bundled English defaults merged with the rows
  /// the server returned, so a key the server did not send still resolves —
  /// to English. For a non-English content language that English value must
  /// not be used, otherwise a Hebrew UI would show the English singular
  /// ("1 minute") next to a Hebrew plural ("2 דקות").
  bool _hasContentTranslation(String key) {
    if (contentLanguageCode == 'en') {
      // English content: the bundled defaults are the right values.
      return strings.containsKey(key) || _defaultTranslations.containsKey(key);
    }
    final value = strings[key];
    if (value == null) return false;
    if (dbKeys.contains(key)) return true;
    // Fallback for states built without the DB key set: a value that differs
    // from the bundled English default is a translated one.
    final fallback = _defaultTranslations[key];
    return fallback != null && fallback != value;
  }

  /// Checks if a key exists in any available source (strings, defaults, or
  /// prefix-expanded) without logging. Useful for probe lookups in resolve
  /// functions during initialization race conditions.
  bool containsKey(String key) {
    if (strings.containsKey(key)) return true;
    if (_defaultTranslations.containsKey(key)) return true;
    if (!key.contains('.') && !key.contains('::')) {
      const prefixes = ['interest.', 'intent.activity.', 'intent.'];
      for (final prefix in prefixes) {
        if (strings.containsKey('$prefix$key')) return true;
        if (_defaultTranslations.containsKey('$prefix$key')) return true;
      }
    }
    return false;
  }

  // Normalize gender input into the suffix used in translation keys.
  static String _normalizeGenderSuffix(String raw) {
    var g = raw.toLowerCase().trim();
    if (g.startsWith('gender_')) g = g.substring('gender_'.length);
    g = g.replaceAll('-', '_');
    if (g == 'nonbinary' || g == 'non binary') g = 'non_binary';
    return g;
  }

  // Simple parameter substitution: replaces {key} tokens with provided values
  static String _applyParams(String s, Map<String, String>? params) {
    if (params == null || params.isEmpty) return s;
    var out = s;
    params.forEach((k, v) {
      out = out.replaceAll('{$k}', v);
    });
    return out;
  }

  // Default translations for critical keys
  static const Map<String, String> _defaultTranslations = {
    'actionApprove': 'Approve',
    'actionRefresh': 'Refresh',
    'actionReject': 'Reject',
    'adConsentAccept': 'Accept',
    'adConsentCompactDescription':
        'We use cookies to personalize ads and analyze traffic.',
    'adConsentDescription':
        'We use cookies and similar technologies to personalize ads and analyze traffic. You can control your preferences below.',
    'adConsentPrivacyLink': 'Learn more about our privacy policy',
    'adConsentTitle': 'Ad Preferences',
    'webAdTryPremium': 'Try Premium',
    'webAdUnlockFeatures': 'Unlock all features',
    'webAdLearnMore': 'Learn more',
    'activity_partner': 'Activity partner',
    'activity_partner::hiking': 'Hiking',
    'activity_partner::travel_partner': 'Travel Partner',
    'activity_partner::workout': 'Workout partner',
    'addEventTitle': 'Add event',
    'addEventHowTitle': 'How do you want to add it?',
    'addEventIntroBody':
        'Add events you’re going to so you can meet others who’ll be there too. Choose one of the three easy ways below — MatchMe fills in the details for you.',
    'ads_demo_family_safety_partner_card_body':
        'Discover safe community events and activity ideas for all ages.',
    'ads_demo_family_safety_partner_card_cta': 'Learn more',
    'ads_demo_family_safety_partner_card_headline':
        'Family-friendly local events',
    'ads_demo_family_safety_partner_card_sponsor': 'MatchMe Family Safety Demo',
    'ads_test_1776895829181_body': 'This is a test body.',
    'ads_test_1776895829181_cta': '',
    'ads_test_1776895829181_headline': 'Test headline',
    'ads_test_1776895829181_sponsor': '',
    'ads_test_1777449306261_body': 'test body',
    'ads_test_1777449306261_cta': 'test',
    'ads_test_1777449306261_headline': 'This is a test headline!',
    'ads_test_1777449306262_sponsor': 'test',
    'adsLearnMore': 'Learn more',
    'adsOpenLinkFailed': 'We could not open the sponsor link right now.',
    'adsReportAction': 'Report ad',
    'adsReportFailed':
        'We could not submit your ad report right now. Please try again.',
    'adsReportSubmitted': 'Thanks for the report.',
    'adsSponsoredBy': 'Sponsored by {sponsor}',
    'adsSponsoredLabel': 'Sponsored',
    'adsWhyAmISeeingThisBody':
        'This sponsored card is shown only to free-tier users. MatchMe limits ad frequency and only allows approved family-safe campaigns.',
    'adsWhyAmISeeingThisTitle': 'Why am I seeing this?',
    'aiAnalysisPrefix': 'AI Analysis',
    'aiDetectedMismatch':
        'AI detected that the verification photo does not match your profile photo.',
    'analyzingPhotos': 'Analyzing Photos',
    'analyzingPhotosDescription':
        'AI is comparing your photos for verification...',
    'and': 'and',
    'andInvisible': 'and Invisible',
    'andInvisible_female': 'and invisible',
    'andInvisible_male': 'and invisible',
    'andInvisible_non_binary': 'and invisible',
    'appName': 'MatchMe',
    'appTagline': 'Connecting people, naturally!',
    'approvalRequiredBioEditBlocked':
        'Cannot edit bio while offline or unavailable',
    'approvalRequiredBioOfflineReason':
        'Your bio requires AI moderation and verification, which needs a stable connection to Supabase.',
    'approvalRequiredEditBlocked': 'This field requires Supabase connection',
    'approvalRequiredEditRequestEditBlocked':
        'Cannot edit this field while offline or unavailable',
    'approvalRequiredEditRequestOfflineReason':
        'This field change requires admin review and needs a stable connection to Supabase.',
    'approvalRequiredGenericOfflineReason':
        'This field change requires Supabase admin approval and needs a stable connection.',
    'approvalRequiredLearnMore': 'Learn More',
    'approvalRequiredOkButton': 'Understood',
    'approvalRequiredPhotoEditBlocked':
        'Cannot edit primary photo while offline or unavailable',
    'approvalRequiredPhotoOfflineReason':
        'Your primary photo requires face detection validation, which needs a stable connection to Supabase.',
    'art_music': 'Music & Art',
    'arts_music': 'Music & Art',
    'at': 'at',
    'attendees': 'Attendees',
    'attendingSharedEvent': 'Attending a shared event',
    'authAlreadyHaveAccountPrompt': 'Already have an account? Tap Log In.',
    'authCaptchaCancelled': 'Security check was canceled.',
    'authCaptchaComplete': 'Security check complete.',
    'authCaptchaEmptyToken': 'Security check returned an empty token.',
    'authCaptchaExpiredRetry': 'Security check expired. Please retry.',
    'authCaptchaFailedRetry': 'Security check failed. Please retry.',
    'authCaptchaFailedWithError': 'Security check failed: {error}',
    'authCaptchaLoginBody':
        'Complete this security check to continue after multiple password attempts.',
    'authCaptchaMissingConfig':
        'CAPTCHA is not configured for this app yet. Add TURNSTILE_SITE_KEY in the app and TURNSTILE_SECRET_KEY in Supabase Edge secrets.',
    'authCaptchaPreparing': 'Preparing security check...',
    'authCaptchaPrompt': 'Complete the security check to continue.',
    'authCaptchaRequiredAfterFailures':
        'After 3 failed password attempts, a security check is required before you can try again.',
    'authCaptchaSignUpBody':
        'Complete this quick security check before creating your account.',
    'authCaptchaTimedOutRetry': 'Security check timed out. Please retry.',
    'authCaptchaTitle': 'Security Check',
    'authCaptchaVerificationFailed':
        'Security check could not be verified. Please try again.',
    'authCheckEmail': 'Check your email',
    'authCodeExpired':
        'The verification code has expired. Please request a new one.',
    'authConfirmPassword': 'Confirm password',
    'authConfirmPasswordRequired': 'Password confirmation is required',
    'authContinueWithApple': 'Continue with Apple',
    'authContinueWithFacebook': 'Continue with Facebook',
    'authContinueWithGoogle': 'Continue with Google',
    'authContinueWithMicrosoft': 'Continue with Microsoft',
    'authContinueWithPasskey': 'Continue with Passkey',
    'authDisposableEmailBlocked':
        'Please use a regular personal email address. Temporary or disposable email addresses are not supported.',
    'authEmail': 'Email',
    'authEmailAlreadyRegistered': 'An account with this email already exists.',
    'authEmailInvalid': 'Enter a valid email address.',
    'authEmailNotConfirmed': 'Please confirm your email before logging in.',
    'authEmailRejected':
        'We couldn\'t use that email address for registration. Please try a different email.',
    'authEmailRequired': 'Email is required',
    'authForgotPassword': 'Forgot password?',
    'authHidePassword': 'Hide password',
    'authIncorrectPassword': 'Incorrect password.',
    'authInvalidCode':
        'The verification code you entered is invalid. Please try again.',
    'authInvalidCredentials': 'Invalid email or password.',
    'authInvalidCredentialsTryOAuth':
        'Invalid credentials. Try signing in with a connected provider.',
    'authInvalidTOTP': 'The code you entered is invalid. Please try again.',
    'authLogin': 'Log In',
    'authLoginFailed': 'Login failed. Please try again.',
    'authLoginServiceError':
        'Login is temporarily unavailable. Please try again in a moment.',
    'authLogout': 'Log Out',
    'authLogoutCleanupFailed':
        'Your data could not be cleared safely. You are still signed in; please try again.',
    'authLogoutConfirmTitle': 'Log out?',
    'authLogoutConfirmBody':
        'You’ll need to sign in again to access your account.',
    'authMfaBody':
        'Enter the 6-digit code from your authenticator app to finish signing in.',
    'authMfaLoadFailed':
        'We couldn’t load your multi-factor sign-in step. Please try again.',
    'authMfaLoading': 'Checking your security settings...',
    'authMFANotEnabled':
        '2-Factor authentication is not configured for your account.',
    'authMFARequired':
        'Enter your verification code from your authenticator app to continue.',
    'authMfaTitle': 'Verify your sign-in',
    'authNetworkError':
        'Unable to reach the server. Check your connection and try again.',
    'authNetworkIssue':
        'We couldn’t reach MatchMe right now. Please check your internet connection and try again.',
    'authNewHerePrompt': 'New here? Tap Sign Up to create your account first.',
    'authNewPassword': 'New password',
    'authNotAuthenticated': 'Not authenticated',
    'authOAuthAccessDenied':
        'OAuth access was denied. Please try again or choose a different sign-in method.',
    'authOAuthAccountExists': 'An account already exists with this email',
    'authOAuthCancelled': 'Sign-in canceled',
    'authOAuthFailed': 'Authentication failed',
    'authOAuthInvalidState': 'An OAuth error occurred. Please try again.',
    'authOAuthProviderFailed':
        'There was a problem logging in using {provider}.',
    'authOAuthSuggestionPasskey': 'You can also try using a passkey.',
    'authOAuthSuggestionDifferentProvider':
        'You can also try a different login provider.',
    'authOAuthSuggestionPassword': 'You can also try username and password.',
    'authOr': 'or',
    'authOAuthProviderUnavailable':
        'This sign-in method is currently unavailable. Please use another option.',
    'authPasskeyAvailable': 'Passkey sign-in available for this account',
    'authPasskeyBody':
        'Use the passkey saved on this device to sign in securely without a password.',
    'authPasskeyCancelled': 'Passkey authentication was canceled',
    'authPasskeyEnterEmail': 'Enter your email to continue with a passkey.',
    'authPasskeyEnterValidEmail':
        'Enter a valid email to continue with a passkey.',
    'authPasskeyInlineHintBody':
        'You can skip the password field and use the passkey button below.',
    'authPasskeyInlineHintTitle': 'Already using passkeys for this email?',
    'authPasskeySetupAndroidBody':
        'Passkeys on Android need a screen lock such as a PIN, pattern, password, fingerprint, or face unlock. Set one up in your device security settings, then try again.',
    'authPasskeySetupAndroidButton': 'Open screen lock settings',
    'authPasskeySetupAndroidInstructionsBody':
        'Open Settings, then Security & privacy (the name can vary by device) and set up a screen lock. Passkeys may also require Google Password Manager to be enabled.',
    'authPasskeySetupAndroidInstructionsTitle':
        'Set up a screen lock for passkeys',
    'authPasskeySetupAndroidTitle': 'Set up passkeys on this Android device',
    'authPasskeySetupAndroidLoginTitle':
        'Passkeys aren’t set up on this Android device',
    'authPasskeySetupIosBody':
        'Passkeys on iPhone use your device passcode and iCloud Passwords & Keychain. Turn on these features in Settings, then try again.',
    'authPasskeySetupIosButton': 'View iPhone setup steps',
    'authPasskeySetupIosInstructionsBody':
        '1. In Settings, set a passcode under Face ID & Passcode or Touch ID & Passcode.\n\n2. Tap your name, then iCloud > Passwords & Keychain, and turn on Sync this iPhone.\n\nMenu names can vary slightly by iOS version. After setup, return here and try the passkey again.',
    'authPasskeySetupIosInstructionsTitle': 'Set up passkeys on iPhone',
    'authPasskeySetupIosTitle': 'Set up passkeys on this iPhone',
    'authPasskeySetupIosLoginTitle': 'Passkeys aren’t set up on this iPhone',
    'authPasskeySetupMacBody':
        'Passkeys on Mac use Touch ID or your Mac login password and may sync through iCloud Passwords & Keychain. Use the setup steps for your Mac.',
    'authPasskeySetupMacButton': 'View Mac setup steps',
    'authPasskeySetupMacInstructionsBody':
        'In System Settings, check Touch ID or your login password, then open your Apple Account > iCloud > Passwords & Keychain and enable syncing. Menu names vary by macOS version.',
    'authPasskeySetupMacInstructionsTitle': 'Set up passkeys on Mac',
    'authPasskeySetupMacTitle': 'Set up passkeys on this Mac',
    'authPasskeySetupOtherBody':
        'This device does not currently report a ready platform authenticator. Check the device or browser security settings for passkey, screen-lock, or biometric setup.',
    'authPasskeySetupOtherButton': 'View setup steps',
    'authPasskeySetupOtherInstructionsBody':
        'Passkey setup depends on your device and browser. Enable a device screen lock or biometric unlock, and make sure a passkey provider is available. You can also use a passkey saved on another device.',
    'authPasskeySetupOtherInstructionsTitle': 'Set up passkeys on this device',
    'authPasskeySetupOtherTitle': 'Set up passkeys on this device',
    'authPasskeySetupMoreInfoButton': 'More information',
    'authPasskeySetupPasswordAlternative':
        'You can sign in with your username and password instead.',
    'authPasskeySetupWebInstructionsBody':
        'Passkey availability in a browser depends on your browser, device, and saved passkey provider. Check that your browser supports passkeys and that a passkey is available in your password manager. You can also sign in with your username and password.',
    'authPasskeySetupWebInstructionsTitle': 'About passkeys in this browser',
    'authPasskeySetupWebLoginTitle': 'Passkeys aren’t set up in this browser',
    'authPasskeySetupWindowsBody':
        'Passkeys on Windows use Windows Hello. Set up a PIN, fingerprint, or face sign-in in Windows Settings, then try again.',
    'authPasskeySetupWindowsButton': 'Open Windows Hello settings',
    'authPasskeySetupWindowsInstructionsBody':
        'Open Settings > Accounts > Sign-in options, then set up a Windows Hello PIN, fingerprint, or face sign-in. Return here and try the passkey again.',
    'authPasskeySetupWindowsInstructionsTitle':
        'Set up Windows Hello for passkeys',
    'authPasskeySetupWindowsTitle': 'Set up passkeys on this PC',
    'authPasskeySetupWindowsLoginTitle':
        'Passkeys aren’t set up on this Windows PC',
    'authPasskeyNoPasswordNeeded': 'No password needed on supported devices.',
    'authPasskeyNotAvailable':
        'This account does not have a passkey registered',
    'authPasskeyNotConfigured':
        'Passkey authentication is not configured for this server',
    'authPasskeyNotFound': 'No passkey found for this email address',
    'authPasskeyNotSupported':
        'Passkey authentication is not supported on this device',
    'authPasskeyReadyForEmail':
        'Use the passkey saved for {email} on this device.',
    'authPasskeySecurityError':
        'A security error occurred during passkey authentication',
    'authPasskeySessionMissing':
        'Passkey authentication succeeded but session data is missing',
    'authPasskeySetupRequired':
        'Passkeys are enabled, but the relying party ID and server URL still need to be configured before people can use them.',
    'authPasskeySignInFailed': 'Failed to sign in with passkey',
    'authPasskeySignInSuccess': 'Passkey sign-in successful',
    'authPasskeyUnavailable':
        'Passkey sign-in is not available in this app build yet. It still needs the app-side WebAuthn flow and server verification setup.',
    'authPasskeyUnsupported':
        'Passkeys are not available on this platform yet. Use email, password, or another sign-in method instead.',
    'authPassword': 'Password',
    'authPasswordHide': 'Hide password',
    'authPasswordLockedUntilEmailApproved':
        'Enter an approved email address to continue.',
    'authPasswordRequired': 'Password is required',
    'authPasswordRequirementsTitle': 'Your password must include:',
    'authPasswordResetSuccess': 'Password reset successful',
    'authPasswordResetSuccessMessage': 'Your password has been updated',
    'authPasswordRuleLowercase': 'At least 1 lowercase letter',
    'authPasswordRuleMinLength': 'At least 8 characters',
    'authPasswordRuleNumber': 'At least 1 number',
    'authPasswordRuleSpecial': r'At least 1 special character: @$!%*?&',
    'authPasswordRuleUppercase': 'At least 1 uppercase letter',
    'authPasswordsDoNotMatch': 'Passwords do not match',
    'authPasswordShow': 'Show password',
    'authPasswordTooShort': 'Password is too short',
    'authPasswordWeak': 'Password is too weak',
    'authRateLimitExceeded':
        'Too many requests. Please wait a moment and try again.',
    'authRefreshTokenExpired':
        'Your session has expired. Please sign in again.',
    'authRefreshTokenInvalid':
        'Your session is no longer valid. Please sign in again.',
    'authRefreshTokenNotFound':
        'Your session could not be renewed. Please sign in again.',
    'authResetPassword': 'Reset password',
    'authResetPasswordFailed': 'Failed to send password reset email',
    'authResetPasswordMessage':
        'Enter your email and we’ll send you a 6-digit verification code.',
    'authResetPasswordSent': 'Verification code sent to {email}',
    'authResetPasswordTitle': 'Reset password',
    'authResetPasswordOtpTitle': 'Check your email',
    'authResetPasswordOtpBody':
        'Enter the 6-digit code we sent to {email} and choose a new password.',
    'authResetPasswordOtpSent': 'Verification code sent to {email}',
    'authReturnToLogin': 'Return to login',
    'authSecurityCheckTryAgain':
        'We couldn’t complete the security check right now. Please try again.',
    'authSelectLanguage': 'Select Language',
    'authSendResetPassword': 'Send verification code',
    'authServerError': 'A server error occurred. Please try again later.',
    'authSessionExpired': 'Your session has expired. Please sign in again.',
    'authSessionInvalid': 'Your session is invalid. Please sign in again.',
    'authSetNewPassword': 'Set new password',
    'authSetNewPasswordMessage': 'Please set a new password to continue',
    'authShowPassword': 'Show Password',
    'authSigningIn': 'Signing in...',
    'authSignInWithPasskey': 'Sign In with Passkey',
    'authSignOut': 'Sign Out',
    'authSignUp': 'Sign up',
    'authSignUpBlocked':
        'We could not create this account. If you think this is a mistake, please contact support.',
    'authSignupCodeBackToLogin': 'Back',
    'authSignupCodeBody':
        'Enter the 6-digit code we sent to {email} to finish creating your account.',
    'authSignupCodeEnterPrompt': 'Enter the 6-digit code from your email',
    'authSignupCodeExpired':
        'That verification code has expired. Request a new one.',
    'authSignupCodeHint': '6-digit code',
    'authSignupCodeInvalid': 'That verification code is not valid.',
    'authSignupCodeLabel': 'Verification code',
    'authSignupCodeRateLimited':
        'A code was sent recently. Please wait a moment before trying again.',
    'authSignupCodeResend': 'Resend code',
    'authSignupCodeResendFailed': 'We could not resend the verification code.',
    'authSignupCodeResent': 'A new verification code was sent to {email}.',
    'authSignupCodeTitle': 'Verify your email',
    'authSignupCodeVerify': 'Verify email',
    'authSignupCodeVerifyFailed':
        'We could not verify that code. Please try again.',
    'authStreamError': 'Auth Stream Error',
    'authToggleToSignIn': 'Already have an account? Sign in',
    'authToggleToSignUp': 'Don’t have an account? Sign up',
    'authUnableToLogInRightNow':
        'We couldn’t log you in right now. Please try again in a moment.',
    'authUnableToSignUpRightNow':
        'We couldn’t create your account right now. Please try again in a moment.',
    'authUnauthorized': 'You are not authorized to perform this action.',
    'authUnexpectedError': 'An unexpected error occurred. Please try again.',
    'authUsePasskeyNow': 'Use passkey now',
    'authUserNotFound':
        'This account does not exist. Please sign up or try again.',
    'autoRejected': 'Auto-rejected',
    'backToEvents': 'Back to Events',
    'batteryOptimizationMessage':
        'Battery optimization may limit background features.',
    'batteryOptimizationTitle': 'Battery optimization enabled',
    'bgNotificationText': 'You are visible and background matching is enabled.',
    'bgNotificationTitle': 'MatchMe Active',
    'billingActivatedOn': 'Activated on',
    'billingActive': 'Active',
    'billingAmount': 'Amount',
    'billingCancellationReason': 'Cancellation reason',
    'billingCancelled': 'Canceled',
    'billingCancelledOn': 'Canceled on',
    'billingCompleted': 'Completed',
    'billingCurrentPlan': 'Current Plan',
    'billingEmptyActive': 'No active subscriptions.',
    'billingEmptyCompleted': 'No completed subscriptions yet.',
    'billingEmptyScheduled': 'No scheduled subscriptions.',
    'billingExpiresOn': 'Expires on',
    'billingFree': 'Free',
    'billingHistory': 'Billing History',
    'billingHistoryEmpty': 'No billing history yet.',
    'billingManagePlan': 'Manage Plan',
    'billingMethodsUsed': '{count} methods used',
    'billingNoActivePlan': 'No active plan',
    'billingPaymentMethod': 'Payment method',
    'billingPaymentMethodPromoCode': 'Promo Code',
    'billingPaymentMethodManual': 'Manual',
    'billingPaymentMethods': 'Payment Methods Used',
    'billingPaymentMethodsEmpty':
        'No payment method details are available yet.',
    'billingPlanStatus': 'Plan status',
    'billingPromoBadge': 'Promo',
    'billingPromoCode': 'Promo code',
    'billingProvider': 'Provider',
    'billingProvidersUsed': 'Providers used',
    'billingPurchasedOn': 'Purchased on',
    'billingScheduled': 'Scheduled',
    'billingSettingsDescription':
        'View your plan, payment methods, and billing history.',
    'billingStartsOn': 'Starts on',
    'billingTabActive': 'Active',
    'billingTabCompleted': 'Completed',
    'billingTabScheduled': 'Scheduled',
    'billingTimeLeft': 'Time left',
    'billingTitle': 'Billing',
    'billingTotalTransactions': '{count} transactions',
    'billingTransactionId': 'Transaction ID',
    'billingUnknownMethod': 'Not available',
    'billingUnknownProvider': 'Unknown',
    'background_matching_off_warning':
        'Turning off Background Matching Mode means your location will only update while the app is open and active. You won\'t appear on the nearby map or receive match notifications when the app is closed or in the background. Are you sure you want to turn this off?',
    'blockButton': 'Block',
    'blockConfirm':
        'Blocking removes this account from your matches and chats. This does not submit a report.',
    'blockFailed': 'Could not block this account',
    'blockSuccess': 'Account blocked',
    'blockTitleWithName': 'Block {name}',
    'board_games': 'Board Games',
    'bootstrapUnknownError': 'Unknown bootstrap error',
    'business_networking': 'Business networking',
    'business_networking::cofounder': 'Co-founder',
    'business_networking::events': 'Networking Events',
    'business_networking::hiring': 'Hiring',
    'business_networking::mentorship': 'Mentorship',
    'business_networking::skill_exchange': 'Skill exchange',
    'calendarSyncAccountAccessed': 'Account accessed',
    'calendarSyncAccountsAccessed': 'Accounts accessed',
    'calendarSyncAddAccount': 'Add Account',
    'calendarSyncAddAccountHint':
        'Add an account to import calendar events from Google, Outlook, or Apple.',
    'calendarSyncAppleOnlineImportTitle': 'Apple Online Events Import',
    'calendarSyncApplePublicFetchFailed':
        'Failed to fetch events from the Apple public calendar URL.',
    'calendarSyncApplePublicHelpLinkLabel':
        'How to get my Apple public calendar link',
    'calendarSyncApplePublicHelpLinkOpenFailed':
        'Unable to open Apple help page right now.',
    'calendarSyncApplePublicNoCalendars':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_female':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_male':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_non_binary':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicUrlHelp':
        'Paste your public Apple calendar link to import events in read-only mode.',
    'calendarSyncApplePublicUrlHint': 'webcal://p01-calendarws.icloud.com/...',
    'calendarSyncApplePublicUrlInvalid':
        'Invalid Apple public calendar URL. Use a webcal:// or https:// link.',
    'calendarSyncApplePublicUrlLabel': 'Apple public calendar URL',
    'calendarSyncApplePublicUrlRequired':
        'Please paste your Apple public calendar URL.',
    'calendarSyncAppleWebNotSupported':
        'Apple Calendar import on web is not available yet. Use iOS, macOS, or another device with Apple calendars enabled.',
    'calendarSyncCannotImportBadge': 'Can\'t import',
    'calendarSyncCannotImportPrivateBadge': 'Private',
    'calendarSyncCannotImportPrivateHint':
        'This event is marked private or “free” in your calendar, so it can’t be shared publicly.',
    'calendarSyncImportBlockedPrivate':
        'Can’t import: this event is marked private in your calendar, so it can’t be shared with other users.',
    'calendarSyncCannotImportPersonalBadge': 'Looks personal',
    'calendarSyncCannotImportPersonalHint':
        'This looks like a personal appointment rather than a public event others can join.',
    'calendarSyncImportBlockedPersonal':
        'Can’t import: this looks like a personal event rather than a public one other users can join.',
    'importBlockSheetTitlePrivate': 'This event is marked private',
    'importBlockSheetBodyPrivate':
        'Your calendar marks this event as private or “free”. MatchMe events are shared with your matches, so private calendar entries can’t be imported.',
    'importBlockSheetTitlePersonal': 'This looks like a personal event',
    'importBlockSheetBodyPersonal':
        '“{title}” looks like a personal appointment rather than a public event. MatchMe events are visible to your matches, so personal items can’t be imported.',
    'importBlockSheetTitleContext': 'Nothing public to share',
    'importBlockSheetBodyContext':
        'This event has neither a public link nor a physical location, so there’s nothing here for other users to attend.',
    'importBlockSheetWhatImportableTitle': 'What can I import?',
    'importBlockSheetWhatImportableBody':
        'Public events other users can join — concerts, meetups, exhibitions, public classes, parties — as long as they have a venue or a link.',
    'importBlockSheetFeedbackButton': 'This event is actually public',
    'importBlockSheetFeedbackThanks':
        'Thanks — we’ll take a look at this decision.',
    'importBlockSheetFeedbackAlreadyUsed':
        'You’ve already sent feedback. Thanks for helping us improve!',
    'eventAddLooksPrivateTitle': 'This looks personal',
    'eventAddLooksPrivateBody':
        '“{title}” looks like a personal appointment rather than a public event. MatchMe events are visible to your matches — consider sharing only events others can join.',
    'eventAddLooksPrivateConfirmButton': 'Add anyway',
    'calendarSyncChangeCalendars': 'Change Calendars',
    'calendarSyncConnectApple': 'Connect Apple Calendar',
    'calendarSyncConnectDevice': 'Connect Device Calendar',
    'calendarSyncConnectedAccounts': 'Connected Accounts',
    'calendarSyncConnectGoogle': 'Connect Google Calendar',
    'calendarSyncConnectMessage': 'Connect your calendar to sync events',
    'calendarSyncConnectOutlook': 'Connect Outlook Calendar',
    'calendarSyncDeselectAll': 'Deselect all',
    'calendarSyncDeviceSummaryAccounts': '{count} accounts found',
    'calendarSyncDeviceSummaryEvents': '{count} events found',
    'calendarSyncDeviceSummarySelected': '{count} selected',
    'calendarSyncDeviceSummaryTitle': 'Device calendars',
    'calendarSyncDeviceUnknownAccount': 'Unknown account',
    'calendarSyncDuplicateBadge': 'Duplicate',
    'calendarSyncDuplicateEventsFound': '{count} duplicates found',
    'calendarSyncDuplicateSelectedWillSkip':
        '{count} selected events will be skipped because they already exist.',
    'calendarSyncEventImportFailed': 'Could not import {title}: {reason}',
    'calendarSyncEventImportFailedMore': 'And {more} more.',
    'calendarSyncFailedLoadCalendars': 'Failed to load calendars.',
    'calendarSyncFailedLoadEvents': 'Failed to load events.',
    'calendarSyncFailedSyncEvents': 'Failed to sync events.',
    'calendarSyncFilterImportableOnly': 'Show importable only',
    'calendarSyncGoogleAuthRequired': 'Google Sign-In Required',
    'calendarSyncGoogleAuthRequiredMessage':
        'To access your Google calendars, you need to sign in with your Google account.',
    'calendarSyncGoogleAuthTimeout':
        'Google authentication timed out. Check your internet connection and try again.',
    'calendarSyncGoogleConfigError':
        'Google Sign-In is not configured correctly for this app build. Please contact support.',
    'calendarSyncGooglePermissionDenied':
        'This Google account has not granted calendar access to the app. Please approve the requested permissions and try again.',
    'calendarSyncGoogleSignIn': 'Please sign in to Google to continue.',
    'calendarSyncGoogleSignInCancelled':
        'Google sign-in was canceled. Please try again.',
    'calendarSyncImportRequiresLocationOrLink':
        'This event does not have either an event link or a physical location and therefore cannot be imported.',
    'calendarSyncListAnd': 'and',
    'calendarSyncLoadCalendars': 'Load Calendars',
    'calendarSyncLoadOutlookCalendars': 'Load Outlook Calendars',
    'calendarSyncMissingLocationOrLinkHint':
        'This event is missing both a physical location and an event link, so it cannot be imported.',
    'calendarSyncNetworkError':
        'Network error. Please check your internet connection.',
    'calendarSyncNext': 'Next',
    'calendarSyncNoAccounts': 'No accounts connected',
    'calendarSyncNoCalendarsApple':
        'No Apple calendars found on this device. Make sure iCloud Calendar is enabled in your device account settings.',
    'calendarSyncNoCalendarsDevice':
        'No device calendars were found on this device.',
    'calendarSyncNoCalendarsFound': 'No calendars found',
    'calendarSyncNoCalendarsGoogle':
        'No Google calendars found on this device.',
    'calendarSyncNoCalendarsGoogle_female': 'No Google calendars were found.',
    'calendarSyncNoCalendarsGoogle_male': 'No Google calendars were found.',
    'calendarSyncNoCalendarsGoogle_non_binary':
        'No Google calendars were found.',
    'calendarSyncNoCalendarsOutlook': 'No Outlook calendars found.',
    'calendarSyncNoCalendarsOutlook_female':
        'Unable to retrieve Outlook calendars. Please ensure calendar permissions are enabled and try again.',
    'calendarSyncNoCalendarsOutlook_male':
        'Unable to retrieve Outlook calendars. Please ensure calendar permissions are enabled and try again.',
    'calendarSyncNoCalendarsOutlook_non_binary':
        'Unable to retrieve Outlook calendars. Please ensure calendar permissions are enabled and try again.',
    'calendarSyncNoDate': 'No date',
    'calendarSyncNoEvents': 'No events found',
    'calendarSyncNoEventsHint':
        'Select calendars from your accounts to import events.',
    'calendarSyncNoEventsMatchFilters': 'No events match the current filters.',
    'calendarSyncNoEventsToSync': 'No events selected to sync.',
    'calendarSyncNoOutlookOnDevice':
        'No Outlook calendars found on this device.',
    'calendarSyncNoOutlookOnDevice_female':
        'Outlook is not installed on your device',
    'calendarSyncNoOutlookOnDevice_male':
        'Outlook is not installed on your device',
    'calendarSyncNoOutlookOnDevice_non_binary':
        'Outlook is not installed on your device',
    'calendarSyncOpenEventFailed':
        'Could not open this event in your device calendar.',
    'calendarSyncOpenOutlookGuidance':
        'Open Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh',
    'calendarSyncOpenOutlookGuidance_female':
        'Open the Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh.',
    'calendarSyncOpenOutlookGuidance_male':
        'Open the Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh.',
    'calendarSyncOpenOutlookGuidance_non_binary':
        'Open the Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh.',
    'calendarSyncOpenOutlookSettings': 'Open Outlook App',
    'calendarSyncOutlookAuthTimeout':
        'Outlook authentication timed out. Check your internet connection and try again.',
    'calendarSyncOutlookDetected':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_female':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_male':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_non_binary':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookEventsFailed':
        'Failed to fetch Outlook events. Please try again later.',
    'calendarSyncOutlookExpired':
        'Your Outlook session has expired. Please sign in again.',
    'calendarSyncOutlookFailed':
        'Failed to fetch Outlook calendars. Please try again later.',
    'calendarSyncOutlookNotConfigured':
        'Outlook is not configured. Please contact support or configure OUTLOOK_TENANT_ID, OUTLOOK_CLIENT_ID, and OUTLOOK_REDIRECT_URI in settings.',
    'calendarSyncOutlookNotInstalled':
        'Outlook is not installed on this device. You can still connect via Outlook Web to import your calendars.',
    'calendarSyncOutlookPermissionDenied':
        'This Microsoft account has not granted calendar access to the app. Please approve the requested permissions and try again.',
    'calendarSyncOutlookSignIn': 'Please sign in to Outlook to continue.',
    'calendarSyncOutlookUseWeb': 'Connect Outlook via Web',
    'calendarSyncOutlookWebNote':
        'If Outlook is not synced locally, sign in with your Outlook credentials and we will pull your calendars directly.',
    'calendarSyncOutlookWebOnly':
        'Outlook calendar sync is currently only available on the web version.',
    'calendarSyncPermissionActionClose': 'Close',
    'calendarSyncPermissionActionImportOnline': 'Import from Online Providers',
    'calendarSyncPermissionActionOpenAppSettings': 'Open App Settings',
    'calendarSyncPermissionBlocked':
        'Calendar permission is blocked by your device settings.',
    'calendarSyncPermissionBlockedSettingsGuide':
        'Calendar permission is currently blocked. Tap Open App Settings and enable Calendar permission for MatchMe.',
    'calendarSyncPermissionBlockedSettingsGuideAndroid':
        'Calendar permission is currently blocked on Android. Tap Open App Settings, then Permissions → Calendar, and choose Allow.',
    'calendarSyncPermissionBlockedSettingsGuideIos':
        'Calendar permission is currently blocked on iOS. Tap Open App Settings, then Calendars, and enable access for MatchMe.',
    'calendarSyncPermissionDenied':
        'Calendar access is required. Please grant permission in your device settings.',
    'calendarSyncDeviceNotSupported':
        'Importing from your device calendar is only available on the mobile app. Use Google, Outlook or Apple Calendar instead.',
    'calendarSyncPermissionFailed':
        'Failed to request calendar permissions. Please try again.',
    'calendarSyncPermissionSettingsGuide':
        'To import from your device calendar, tap Open App Settings and enable Calendar permission for MatchMe.',
    'calendarSyncPermissionTitle': 'Calendar permission required',
    'calendarSyncPreferredBadge': 'Preferred',
    'calendarSyncProviderApple': 'Apple',
    'calendarSyncProviderGoogle': 'Google',
    'calendarSyncProviderOutlook': 'Outlook',
    'calendarSyncProviderTitle': 'Choose calendar provider',
    'calendarSyncRetry': 'Retry',
    'calendarSyncSelectAll': 'Select all',
    'calendarSyncSelectCalendars': 'Select calendars',
    'calendarSyncSelectProvider': 'Select Provider',
    'calendarSyncSkipReasonMissingDate': 'missing a start date',
    'calendarSyncSourceDevice': 'Device calendar',
    'calendarSyncSourceOnline': 'Online calendar',
    'calendarSyncSourceTitle': 'Choose import source',
    'calendarSyncSourceWebOnly':
        'Web uses online calendar sign-in. Choose a provider and connect.',
    'calendarSyncSwitchAccount': 'Switch Google Account',
    'calendarSyncSwitchAccountMessage':
        'Choose a different Google account to import calendars from. Your MatchMe session will stay signed in.',
    'calendarSyncSwitchToGoogle': 'Switch to Google Calendar',
    'calendarSyncSwitchToOutlook': 'Switch to Outlook Calendar',
    'calendarSyncSyncedEventsSuccess': 'Successfully imported {count} events.',
    'calendarSyncSyncedEventsSuccessWithSkipped':
        'Successfully imported {count} events. Skipped {skipped}.',
    'calendarSyncSyncSelected': 'Sync Selected',
    'calendarSyncTimeout': 'Request timed out. Please try again.',
    'calendarSyncTitle': 'Sync Calendar',
    'calendarSyncUnexpectedError':
        'An unexpected error occurred. Please try again.',
    'calendarSyncUnknownEventTitle': 'Unknown event',
    'calendarSyncWaitForSync':
        'Note: After enabling sync, it may take 30-60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_female':
        'Note: After enabling sync, it may take 30–60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_male':
        'Note: After enabling sync, it may take 30–60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_non_binary':
        'Note: After enabling sync, it may take 30–60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'cameraCaptureFailed': 'Error capturing image: {error}',
    'cameraCapturePhoto': 'Capture Photo',
    'cameraInitFailed': 'Error initializing camera: {error}',
    'cameraNoCamerasAvailable': 'No cameras available',
    'cameraNotAvailable': 'Camera not available. Please try again.',
    'cameraRearTitle': 'Rear Camera',
    'cameraSelfieTitle': 'Selfie Camera',
    'cameraTitle': 'Camera',
    'cameraVerificationInstruction':
        'Position your face inside the oval and then tap the "Take Photo" button.',
    'primarySelfieCaptureInstruction':
        'Face the camera — fit your face inside the oval',
    'primarySelfieCaptureDescription':
        'Only you in the frame. Keep your face clearly visible with good lighting.',
    'primarySelfieCaptureLoading': 'Loading camera & face detection...',
    'cancel': 'Cancel',
    'casual': 'Casual',
    'chat': 'Chat',
    'chatButton': 'Chat',
    'chatSendMessage': 'Send message',
    'chatEmojiPicker': 'Emoji picker',
    'chatCancelReply': 'Cancel reply',
    'chatMessageActionsHint': 'Long press for message actions',
    'chatMessageStatusQueued': 'Message queued',
    'chatMessageStatusSent': 'Sent',
    'chatMessageStatusDelivered': 'Delivered',
    'chatMessageStatusRead': 'Read',
    'chatDayToday': 'Today',
    'chatDayYesterday': 'Yesterday',
    'chatDeleteConfirm': 'Are you sure you want to delete this message?',
    'chatEdited': 'Edited',
    'chatEditingMessage': 'Editing message…',
    'chatEditMessage': 'Edit message',
    'chatIsTyping': 'is typing…',
    'chatIsTyping_female': 'is typing…',
    'chatIsTyping_male': 'is typing…',
    'chatIsTyping_non_binary': 'is typing…',
    'chatLoadingMessages': 'Loading messages…',
    'chatMatchedWithOnDate': 'You matched with {name} on {date}',
    'chatMessageSendFailed': 'Failed to send/edit message',
    'chatOptionCopy': 'Copy message',
    'chatOptionDelete': 'Delete message',
    'chatOptionEdit': 'Edit message',
    'chatOptionReact': 'React',
    'chatOptionReply': 'Reply',
    'chatReact': 'React',
    'chatReactors': 'Reactions',
    'chatReactorsHeader': '{emoji} — {count}',
    'chatReactorsTapToRemove': 'Tap to remove',
    'chatSayHello': 'Say hello 👋',
    'chatSayHello_female': 'Say hello 👋',
    'chatSayHello_male': 'Say hello 👋',
    'chatSayHello_non_binary': 'Say hello 👋',
    'chatJumpToLatest': 'Back to latest messages',
    'chatSearchClose': 'Close search',
    'chatSearchHint': 'Search in conversation',
    'chatSearchMatchedInTranslation': 'Matched in translation',
    'chatSearchNext': 'Next result',
    'chatSearchNoResults': 'No messages found',
    'chatSearchPrevious': 'Previous result',
    'chatSearchResultCount': '{current} of {total}',
    'chatSearchTooltip': 'Search in conversation',
    'chatSendFailed': 'Failed to send message',
    'chatsScreenTitle': 'Chats',
    'chatsBrowseMatches': 'Browse Matches',
    'chatsClearFilters': 'Clear filters',
    'chatsNoUnreadResults': 'No unread conversations',
    'chatsNoUnreadResultsMessage':
        'You’re all caught up. Try another filter or browse Matches.',
    'chatsResultsCount': '{count} conversations',
    'chatsUnreadMessages': '{count} unread messages',
    'chatsUnreadOnly': 'Unread only',
    'chatsUnreadOnlyWithCount': 'Unread only ({count})',
    'chatsNoConversationsMessage':
        'Start a conversation from a match when you’re ready.',
    'chatsLoadErrorMessage': 'We couldn’t load your conversations. Try again.',
    'chatsNoIntentResults': 'No conversations for this connection yet',
    'chatsNoIntentResultsMessage':
        'Try another connection filter or browse Matches.',
    'chatsNoSearchResults': 'No conversations match your search',
    'chatsNoSearchResultsMessage': 'Try a different name or message.',
    'chatsSearchHint': 'Search by name or message',
    'chatsSearchingMessages': 'Searching all messages on this device…',
    'chatsSearchInTranslated': 'Matched in a translation',
    'chatsSearchLabel': 'Search conversations',
    'chatsStartConversation': 'Start a conversation',
    'chatsStartConversation_female': 'Start the conversation',
    'chatsStartConversation_male': 'Start the conversation',
    'chatsStartConversation_non_binary': 'Start the conversation',
    'chatTranslateAutoDisabled': 'Auto-translation is disabled for this chat',
    'chatTranslateFailed': 'Translation failed',
    'chatTranslateOff': 'Translation off',
    'chatTranslateOn': 'Translation on',
    'chatTranslateOnWithTarget': 'Translations turned on (to {language})',
    'chatTranslateToggle': 'Translate messages',
    'chatTranslating': 'Translating…',
    'chatTypeMessage': 'Type a message',
    'chatYouAreChattingWith': 'You are chatting with',
    'chatYouAreChattingWith_female': 'You are chatting with',
    'chatYouAreChattingWith_male': 'You are chatting with',
    'chatYouAreChattingWith_non_binary': 'You are chatting with',
    'clearSelfiePhoto': 'Clear selfie photo',
    'clearSelfiePhotoDescription': 'Take a clear, well-lit photo of yourself',
    'coffee': 'Coffee',
    'coffee_meetups': 'Coffee Meetups',
    'cofounder': 'Co-founder',
    'commonBulletSeparator': ' • ',
    'commonCancel': 'Cancel',
    'commonErrorWithDetails': 'Error: {error}',
    'commonPleaseLogIn': 'Please log in',
    'commonProfileNotFound': 'Profile not found',
    'configRequired': 'Configuration required',
    'confirmDelete': 'Are you sure you want to delete this?',
    'confirmDeleteInvisibilityRule':
        'Are you sure you want to delete this invisibility rule?',
    'confirmYourPhoto': 'Confirm your photo',
    'continueImporting': 'Continue importing?',
    'couldNotExtractEventDetailsFromTicket':
        'Could not extract event details from the ticket',
    'couldNotFetchDetailsFromLink': 'Could not fetch details from the link',
    'currencyAllSection': 'All currencies',
    'currencyNoResults': 'No currencies match your search.',
    'currencyPickerTitle': 'Choose currency',
    'currencyRecentSection': 'Recent',
    'currencySearchHint': 'Search currency code',
    'currencySuggestedByRegion':
        'Suggested from your region. You can change it anytime.',
    'currencyTopSection': 'Top currencies',
    'dancing': 'Dancing',
    'dataExtractedFromLink': 'Event data extracted from link',
    'date': 'Date',
    'dates': 'Dates',
    'dating': 'Dating',
    'dayFriday': 'Friday',
    'dayMonday': 'Monday',
    'daySaturday': 'Saturday',
    'daySunday': 'Sunday',
    'dayThursday': 'Thursday',
    'dayTuesday': 'Tuesday',
    'dayWednesday': 'Wednesday',
    'dinner': 'Dinner',
    'done': 'Done',
    'durationDays': '{count} days',
    'durationHours': '{count} hours',
    'durationLessThanMinute': 'Less than a minute',
    'durationLessThanOneMinute': 'less than 1 minute',
    'durationMinutes': '{count} minutes',
    'durationSeconds': '{count} seconds',
    'editEventTitle': 'Edit Event',
    'editPhoto': 'Edit photo',
    'emailChangeSuccess': 'Email changed successfully!',
    'enable': 'Enable',
    'errorCouldNotOpenMaps': 'Could not open Google Maps',
    'errorSwitchingAccount':
        'Failed to switch Google account. Please try again.',
    'errorTakingPhoto': 'Error taking photo',
    'Event': 'Event',
    'eventAdd': 'Add event',
    'eventAttendeeCountIncludingYou': '{count} attending, including you',
    'eventAttendeeCount': '{count} attending',
    'eventLeave': 'Leave event',
    'eventLeaveConfirmBody':
        'This removes only your MatchMe attendance and event matches. Other attendees keep the event.',
    'eventLeaveConfirmBodyWithName':
        'Leave "{eventName}"? This removes only your MatchMe attendance and event matches. Other attendees keep the event.',
    'eventLeaveConfirmTitle': 'Leave this event?',
    'eventLeaveFailed':
        'Could not leave this event. You are still listed as attending.',
    'eventLeft': 'You left the event',
    'eventMatchedAttendeesCount': '{count} of your matches attending',
    'eventMatchedAttendeesOnly':
        'Only your event matches are shown—not the full attendee list.',
    'eventRsvpAttending': 'You’re listed as attending on MatchMe',
    'eventPublicDisclosureTitle': 'Public event details',
    'eventPublicDisclosureBody':
        'If Shared Event Matching is on, the public event name, date, venue, and link you enter can be used to find people attending the same event. Don’t add private details.',
    'eventPublicDisclosureConfirmTitle': 'Save this public event?',
    'eventPublicDisclosureConfirmBody':
        'These event details will be available for shared-event matching. Continue only if this is a public event you want others to discover.',
    'eventLoadErrorTitle': 'We couldn’t load your events',
    'eventLoadErrorMessage': 'Check your connection and try again.',
    'eventMoreActions': 'More actions',
    'eventAddFailedAuth':
        'Could not import this event because you are no longer signed in.',
    'eventAddFailedDatabase':
        'Could not import this event because the database rejected the save request.',
    'eventAddFailedDuplicate':
        'Could not import this event because it is already in your events.',
    'eventAddFailedInvalidData':
        'Could not import this event because some event details were not accepted.',
    'eventAddFailedMissingDependency':
        'Could not import this event because a required related record was missing.',
    'eventAddFailedNetwork':
        'Could not import this event because the network request failed.',
    'eventAddFailedPastEvent':
        'Could not import this event because its start time is in the past.',
    'eventAddFailedPermission':
        'Could not import this event because the database denied permission to save it.',
    'eventAddFailedUnknown':
        'Could not import this event because of an unknown import error.',
    'eventAddRejectedContainsPII':
        'it contains personal information (email or phone number)',
    'eventAddRejectedCouldNotVerifyPublic':
        'Could not import this event because we could not verify that it is public and joinable by other users.',
    'eventAddRejectedMissingTitle': 'missing a title',
    'eventAddRejectedNotJoinable':
        'it doesn’t include a public venue or public event link',
    'eventAddRejectedNotPublicEvent':
        'it doesn’t look like a public event others can join',
    'eventAddRejectedPersonalOrPrivate':
        'it looks like a personal or private calendar item',
    'eventAddRejectedPrivateEvent':
        'Could not import this event because it appears to be private or personal.',
    'eventCannotBeInPast': 'The event cannot be in the past',
    'eventCreateFirst': 'Create your first event to get started',
    'eventDateInPast': 'The event date is in the past',
    'eventDateInPastNotImported':
        'Event occurred in the past and was not imported.',
    'eventDateLabel': 'Date',
    'eventDetails': 'Event details',
    'eventDetailsNotAvailable': 'Event details not available',
    'eventExtractionInvalidFormat':
        'Unable to extract event details. Please try uploading a clearer image or a different public event source.',
    'eventExtractionMissingRequiredData':
        'Could not find the event title or date. Please provide a public event page, ticket, or flyer with clear event information.',
    'eventExtractionNotEventContent':
        'We can only import public events that other people can join. Please share a public event page, ticket, or flyer (no personal calendar items or personal details).',
    'eventImportCanceled': 'Event import canceled',
    'eventInputModeLink': 'Link',
    'eventInputModeLinkDesc': 'Have a website or online invitation',
    'eventInputModeLinkTitle': 'Paste a link',
    'eventInputModeManual': 'Manual',
    'eventInputModeManualDesc': 'Type the event information yourself',
    'eventInputModeManualTitle': 'Enter details manually',
    'eventInputModeTicket': 'Ticket',
    'eventInputModeTicketDesc': 'Use a photo or PDF of your ticket',
    'eventInputModeTicketTitle': 'Upload a ticket',
    'eventLabel': 'Event',
    'eventLinkHint': 'Paste the event link here',
    'eventLinkMicrocopy': 'We will try to extract event details automatically',
    'eventLinkFetchButton': 'Get event details',
    'eventLinkHelpText':
        'MatchMe reads the page and fills in the details for you. You can review and edit everything before saving.',
    'eventLinkOptionalLabel': 'Event Link (Optional)',
    'eventLocationLabel': 'Location',
    'eventMatchesTitle': '{eventName} Matches',
    'eventMatchingFunctionError': 'Event matching failed',
    'eventMatchingFunctionSuccess': 'Event matching completed successfully',
    'eventMatchingLabel': 'Event matching',
    'eventMatchingTestButton': 'Test matching',
    'eventMatchingTooltip':
        'Match with people who are attending the same events as you',
    'eventNameLabel': 'Event Name',
    'eventNameRequired': 'Event name is required',
    'eventNoActiveEvents': 'No active events',
    'eventNotesHint': 'Add optional notes about the event',
    'eventNotesLabel': 'Notes',
    'eventNoTitle': 'Untitled event',
    'events': 'Events',
    'eventSavedSuccessfully': 'Event saved successfully',
    'eventSaveFailedWithReason': 'Could not save this event: {reason}',
    'eventsImportApple': 'Import from Apple',
    'eventsImportDeviceCalendar': 'Import from Device Calendar',
    'eventsImportGoogle': 'Import from Google',
    'eventsImportOnlineProviders': 'Import from Online Providers',
    'eventsImportOutlook': 'Import from Outlook',
    'eventsNoUpcomingFound': 'No upcoming events found',
    'eventsScreenTitle': 'Events',
    'eventsSyncFromCalendar': 'Sync from Outlook/Gmail',
    'eventStarted': 'Event started at:',
    'eventStarts': 'Event starts',
    'eventTapToOpenInBrowser': 'Tap to open in browser',
    'eventTicketMicrocopy': 'Upload a ticket or screenshot to extract details',
    'eventTicketUploadButton': 'Upload your ticket',
    'eventTicketUploadHelpText':
        'Tap to choose a photo or PDF. MatchMe reads the details for you.',
    'eventTimeLabel': 'Time',
    'eventVenueLabel': 'Venue',
    'eventVenueNotSpecified': 'Venue not specified',
    'eventViewDetails': 'View event details',
    'eventLinkOpenFailed': 'Could not open the event link. Please try again.',
    'eventOpenInMaps': 'Open in Maps',
    'externalAdsAcceptButton': 'Continue',
    'externalAdsAddAdUnit': 'Add Ad Unit',
    'externalAdsAddNetwork': 'Add Network',
    'externalAdsAdFormat': 'Ad Format',
    'externalAdsAdminDescription': 'Manage external ad networks and revenue',
    'externalAdsAdminTitle': 'External Ad Networks',
    'externalAdsAdUnitId': 'Ad Unit ID',
    'externalAdsAdUnitList': 'Ad Units',
    'externalAdsAllTime': 'All Time',
    'externalAdsAtLeastOneOption':
        'At least one consent option must be selected',
    'externalAdsClicks': 'Clicks',
    'externalAdsConsentBody':
        'We use ads to keep MatchMe free. You can choose whether to see personalized ads based on your interests or general ads.',
    'externalAdsConsentTitle': 'Personalized Ads',
    'externalAdsCPC': 'CPC (Cost Per Click)',
    'externalAdsCPM': 'CPM (Cost Per Mille)',
    'externalAdsCTR': 'CTR (Click-Through Rate)',
    'externalAdsDateRange': 'Date Range',
    'externalAdsImpressions': 'Impressions',
    'externalAdsLoadFailed': 'Failed to load preferences',
    'externalAdsNetworkEnabled': 'Enabled',
    'externalAdsNetworkList': 'Ad Networks',
    'externalAdsNetworkName': 'Network Name',
    'externalAdsNetworkPriority': 'Priority',
    'externalAdsNetworkProvider': 'Provider',
    'externalAdsNonPersonalizedDescription':
        'General ads not based on your interests',
    'externalAdsNonPersonalizedOption':
        'General ads (not based on my interests)',
    'externalAdsNonPersonalizedToggle': 'Allow general ads',
    'externalAdsOptOutAll': 'Opt Out',
    'externalAdsOptOutAllConfirmation':
        'You will not see any ads if you opt out. You can change this later.',
    'externalAdsOptOutAllFailed': 'Failed to opt out',
    'externalAdsOptOutAllSuccess': 'You have opted out of all ads',
    'externalAdsOptOutAllTitle': 'Opt Out of All Ads',
    'externalAdsOptOutWarning': 'You must allow at least one type of ad',
    'externalAdsPersonalizedDescription': 'Ads based on your interests',
    'externalAdsPersonalizedOption': 'Personalized ads (based on my interests)',
    'externalAdsPersonalizedToggle': 'Allow personalized ads',
    'externalAdsPlacement': 'Placement',
    'externalAdsPlatform': 'Platform',
    'externalAdsPreferencesSaved': 'Ad preferences saved',
    'externalAdsPrivacyLink': 'Privacy Policy',
    'externalAdsRevenueByNetwork': 'Revenue by Network',
    'externalAdsRevenueByPlacement': 'Revenue by Placement',
    'externalAdsRevenueByPlatform': 'Revenue by Platform',
    'externalAdsRevenueTitle': 'Revenue Analytics',
    'externalAdsSaved': 'Ad preferences saved',
    'externalAdsSaveFailed': 'Failed to save preferences',
    'externalAdsSettingsDescription': 'Control how ads are shown to you',
    'externalAdsSettingsTitle': 'Ad Preferences',
    'externalAdsCouldNotOpenPrivacy': 'Could not open privacy policy',
    'externalAdsThisMonth': 'This Month',
    'externalAdsThisWeek': 'This Week',
    'externalAdsToday': 'Today',
    'externalAdsTotalRevenue': 'Total Revenue',
    'extractDataButton': 'Extract Data',
    'failedToApproveVerification': 'Failed to approve verification',
    'failedToLoadPendingVerifications': 'Failed to load pending verifications',
    'failedToRejectVerification': 'Failed to reject verification',
    'failedToResetVerification': 'Failed to reset verification',
    'failedToSaveEvent': 'Failed to save event',
    'failedToSubmitVerification': 'Failed to submit verification',
    'fitness': 'Fitness',
    'fitness_gym': 'Gym',
    'food_and_drink': 'Food & Drink',
    'founders': 'Founders',
    'friend': 'Friend',
    'friendship': 'Friendship',
    'Friendship': 'Friendship',
    'friendship::chat': 'Chat',
    'friendship::group_activities': 'Group Activities',
    'friendship::hangouts': 'Hangouts',
    'friendship::travel_buddy': 'Travel Buddy',
    'gender_female': 'Female',
    'gender_male': 'Male',
    'gender_non_binary': 'Non-binary',
    'generalAdd': 'Add',
    'generalAgeYearsOld': '{age} years old',
    'generalAny': 'Any',
    'generalApply': 'Apply',
    'generalBack': 'Back',
    'generalCancel': 'Cancel',
    'generalClear': 'Clear',
    'generalClose': 'Close',
    'generalContinue': 'Continue',
    'generalDelete': 'Delete',
    'generalDetails': 'Details',
    'generalDisabled': 'Disabled',
    'generalEdit': 'Edit',
    'generalEnabled': 'Enabled',
    'generalError': 'Something went wrong',
    'generalErrorLoadingProfile': 'Error loading profile',
    'generalFieldRequired': 'This field is required',
    'generalFilters': 'Filters',
    'generalLabelValue': '{label}: {value}',
    'generalLoading': 'Loading…',
    'generalLoadingDots': 'Loading...',
    'generalLoadMore': 'Load more',
    'generalNameAge': '{name}, {age}',
    'generalNext': 'Next',
    'generalOffline': 'You are offline',
    'generalOffShort': 'Off',
    'generalOk': 'OK',
    'generalOnInvisibleShort': 'Invisible',
    'generalOnShort': 'On',
    'generalQuotedText': '"{text}"',
    'generalRefresh': 'Refresh',
    'generalAll': 'All',
    'generalRetry': 'Retry',
    'chatMessagesLoadFailed': "We couldn't load these messages.",
    'matchesSearchLabel': 'Search matches',
    'matchesSearchHint': 'Name, interest or event',
    'eventsSearchLabel': 'Search events',
    'eventsSearchHint': 'Event, venue or description',
    'eventsNoSearchResults': 'No events found',
    'eventsNoSearchResultsMessage':
        'No event matches that search. Try a different word, or clear the search.',
    'matchTypeFilterProximity': 'Nearby',
    'matchTypeFilterEvent': 'Event',
    'legalDocumentUnavailable': 'This document could not be loaded.',
    'legalTryAgain': 'Try again',
    'legalTitleTerms': 'Terms of Service',
    'legalTitlePrivacy': 'Privacy Policy',
    'legalEnglishFallbackNotice':
        'This document is not yet available in your language, so it is shown in English.',
    'settingsLegalTerms': 'Terms of Service',
    'settingsLegalTermsDesc': 'The rules for using MatchMe',
    'settingsLegalPrivacy': 'Privacy Policy',
    'settingsLegalPrivacyDesc': 'What we collect, and how long we keep it',
    'generalSave': 'Save',
    'generalSaved': 'Saved',
    'generalDiscard': 'Discard',
    'generalUnknown': 'Unknown',
    'generalUser': 'User',
    'generalVerify': 'Verify',
    'generalYearsOld': 'years old',
    'getVerifiedToBuildTrust': 'Get verified to build trust',
    'goodAfternoon': 'Good afternoon',
    'goodAfternoon_female': 'Good afternoon',
    'goodAfternoon_male': 'Good afternoon',
    'goodAfternoon_non_binary': 'Good afternoon',
    'goodEvening': 'Good evening',
    'goodEvening_female': 'Good evening',
    'goodEvening_male': 'Good evening',
    'goodEvening_non_binary': 'Good evening',
    'goodLighting': 'Good lighting',
    'goodLightingDescription': 'Ensure your face is clearly visible',
    'goodMorning': 'Good morning',
    'goodMorning_female': 'Good morning',
    'goodMorning_male': 'Good morning',
    'goodMorning_non_binary': 'Good morning',
    'goodNight': 'Good night',
    'goodNight_female': 'Good night',
    'goodNight_male': 'Good night',
    'goodNight_non_binary': 'Good night',
    'gpsThrottleDeactivatedBattery':
        'Battery restored — GPS updates returned to normal interval.',
    'gpsThrottleDeactivatedMoving':
        'Movement detected — GPS updates returned to normal interval.',
    'gpsThrottledLowBattery':
        'Low battery — GPS updates reduced to once every {interval} seconds to save battery. This will resume when your device is charging or battery is above {threshold}%.',
    'gpsThrottledStationary':
        'Not moving — GPS updates reduced to once every {interval} seconds to save battery. This will resume when you start moving.',
    'group_activities': 'Group activities',
    'gym': 'Gym',
    'gym_buddies': 'Gym Buddies',
    'hangouts': 'Hangouts',
    'highSimilarity': 'High similarity',
    'hiking': 'Hiking',
    'hiking_trails': 'Hiking Trails',
    'hiring': 'Hiring',
    'homeAllCaughtUp':
        'You’re all caught up — MatchMe is working in the background.',
    'homeChat': 'Chat',
    'homeNearby': 'Nearby',
    'homeNearbyMap': 'Nearby Map',
    'homeNearbyMapDesc': 'See who is around you within your match radius.',
    'homeNearbyMapRadius': 'Your currently selected radius: {radius}',
    'homeNearbyMapPinAction': 'Pin current location',
    'homeNearbyMapPinnedLocation': 'Your location is currently pinned{label}.',
    'homeNearbyMapPinnedToLabel': 'to',
    'homeNoChats': 'No recent chats',
    'homeNoMatches': 'No recent matches',
    'homeOnline': 'Online',
    'homeRecentChats': 'Recent Chats',
    'homeRecentChatsCount': 'Showing top {count} Conversations',
    'homeRecentChatsCountOf': 'Showing top {shown} of {total} Conversations',
    'homeRecentMatches': 'Recent Matches',
    'homeRecentMatchesCount': 'Showing top {count} Matches',
    'homeRecentMatchesCountOf': 'Showing top {shown} of {total} Matches',
    'homeRecoveryStaleMessage':
        'We couldn’t refresh your home. Showing the last saved data.',
    'homeRecoveryStaleTitle': 'Home may be out of date',
    'homeSeeAll': 'See all',
    'homeStatusInvisible': 'Invisible',
    'homeStatusVisible': 'Visible',
    'homeTier': 'Tier',
    'homeTitle': 'Home',
    'homeWelcome': 'Welcome',
    'inputMethod': 'Input method',
    'intent.activity_partner': 'Activity Partner',
    'intent.activity.gaming': 'Gaming partner',
    'intent.activity.hiking': 'Hiking',
    'intent.activity.sports': 'Sports',
    'intent.activity.travel_partner': 'Travel partner',
    'intent.activity.workout': 'Workout / Gym',
    'intent.business_networking': 'Business / Networking',
    'intent.business.cofounder': 'Co-founder / Startup',
    'intent.business.events': 'Events / Meetups',
    'intent.business.hiring': 'Hiring / Recruiting',
    'intent.business.mentorship': 'Mentorship',
    'intent.business.skill_exchange': 'Skill exchange',
    'intent.friendship': 'Friendship',
    'intent.friendship.chat': 'Chat & Meet',
    'intent.friendship.group_activities': 'Group activities',
    'intent.friendship.hangouts': 'Hangouts',
    'intent.friendship.study_buddy': 'Study buddy',
    'intent.friendship.travel_buddy': 'Travel buddy',
    'intent.romantic': 'Romantic',
    'intent.romantic.casual': 'Casual',
    'intent.romantic.fwb': 'Friends with benefits',
    'intent.romantic.long_term': 'Long-term',
    'intent.romantic.open': 'Open relationships',
    'intent.romantic.polyamory': 'Polyamorous',
    'intent.romantic.short_term': 'Short-term',
    'intent.activity.art': 'Art',
    'intent.activity.board_games': 'Board Games',
    'intent.activity.book_club': 'Book Club',
    'intent.activity.coffee': 'Coffee',
    'intent.activity.concerts': 'Concerts',
    'intent.activity.dining_out': 'Dining Out',
    'intent.activity.gym': 'Gym',
    'intent.activity.karaoke': 'Karaoke',
    'intent.activity.language_exchange': 'Language Exchange',
    'intent.activity.movies': 'Movies',
    'intent.activity.music': 'Music',
    'intent.activity.outdoors': 'Outdoors',
    'intent.activity.pets': 'Pets',
    'intent.activity.shopping': 'Shopping',
    'intent.activity.volunteering': 'Volunteering',
    'intent.activity.walking': 'Walking',
    'intent.friendship.casual': 'Casual Friendship',
    'intent.friendship.deep_connection': 'Deep Connection',
    'intent.friendship.expats': 'Expat Community',
    'intent.friendship.lgbtqia': 'LGBTQIA+ Friends',
    'intent.friendship.neighbors': 'Neighbors',
    'intent.friendship.new_in_town': 'New in Town',
    'intent.friendship.seniors': 'Seniors',
    'intent.friendship.single_parents': 'Single Parents',
    'intent.friendship.spiritual': 'Spiritual Connection',
    'intent.friendship.student_life': 'Student Life',
    'intentCategoryBusinessNetworking': 'Business networking',
    'intentCategoryFriendship': 'Friendship',
    'intentCategoryRomantic': 'Romantic',
    'intentLabel': 'Intent',
    'interest_category.business_events': 'Events & Meetups',
    'interest_category.dates': 'Date ideas',
    'interest_category.fitness': 'Fitness',
    'interest_category.food_and_drink': 'Food & Drink',
    'interest_category.gaming': 'Gaming',
    'interest_category.group_activities': 'Group activities',
    'interest_category.hangouts': 'Hangouts',
    'interest_category.mentorship': 'Mentorship',
    'interest_category.music_and_art': 'Music & Art',
    'interest_category.outdoors': 'Outdoors',
    'interest_category.skill_sharing': 'Skill sharing',
    'interest_category.study_and_learning': 'Study & Learning',
    'interest_category.arts_and_crafts': 'Arts & Crafts',
    'interest_category.consulting': 'Consulting',
    'interest_category.entrepreneurship': 'Entrepreneurship',
    'interest_category.music': 'Music',
    'interest_category.pets_and_animals': 'Pets & Animals',
    'interest_category.sports': 'Sports',
    'interest_category.technology': 'Technology',
    'interest_category.travel': 'Travel',
    'interest_category.wellness': 'Wellness',
    'interest.activity_partner': 'Activity Partner',
    'interest.activity.arts': 'Arts',
    'interest.activity.arts.crafts': 'Crafts',
    'interest.activity.arts.painting': 'Painting',
    'interest.activity.arts.photography': 'Photography',
    'interest.activity.cooking': 'Cooking',
    'interest.cooking.baking': 'Baking',
    'interest.activity.cooking.grilling': 'Grilling',
    'interest.activity.cooking.vegan': 'Vegan Cooking',
    'interest.cooking.grilling': 'Grilling',
    'interest.cooking.vegan': 'Vegan Cooking',
    'interest.cooking.international_cuisine': 'International Cuisine',
    'interest.activity.dance': 'Dance',
    'interest.activity.dance.ballroom': 'Ballroom Dance',
    'interest.activity.dance.hiphop': 'Hip-hop',
    'interest.activity.dance.salsa': 'Salsa',
    'interest.activity.fitness': 'Fitness',
    'interest.activity.fitness.crossfit': 'Crossfit',
    'interest.activity.fitness.gym': 'Gym',
    'interest.activity.fitness.yoga': 'Yoga',
    'interest.activity.gaming': 'Gaming',
    'interest.activity.gaming.arcade': 'Arcade Games',
    'interest.activity.gaming.board': 'Board Games',
    'interest.activity.gaming.esports': 'Esports',
    'interest.activity.language': 'Language Exchange',
    'interest.activity.language.exchange': 'Language Exchange',
    'interest.activity.language.learning': 'Language Learning',
    'interest.activity.language.sign': 'Sign Language',
    'interest.activity.outdoors': 'Outdoors',
    'interest.activity.outdoors.camping': 'Camping',
    'interest.activity.outdoors.cycling': 'Cycling',
    'interest.activity.outdoors.hiking': 'Hiking',
    'interest.activity.sports': 'Sports',
    'interest.activity.sports.basketball': 'Basketball',
    'interest.activity.sports.martial': 'Martial Arts',
    'interest.activity.sports.soccer': 'Soccer',
    'interest.activity.travel': 'Travel',
    'interest.activity.travel.adventure': 'Adventure Travel',
    'interest.activity.travel.cultural': 'Cultural Travel',
    'interest.activity.travel.roadtrips': 'Road Trips',
    'interest.activity.volunteering': 'Volunteering',
    'interest.activity.volunteering.animals': 'Animal Rescue',
    'interest.activity.volunteering.community': 'Community Service',
    'interest.activity.volunteering.environment': 'Environmental Protection',
    'interest.art_galleries': 'Art galleries',
    'interest.board_games': 'Board games',
    'interest.business': 'Business',
    'interest.business.education': 'Education',
    'interest.business.education.edtech': 'EdTech',
    'interest.business.education.international': 'International Education',
    'interest.business.education.training': 'Training',
    'interest.business.entrepreneurship': 'Entrepreneurship',
    'interest.business.entrepreneurship.investing': 'Investing',
    'interest.business.entrepreneurship.social': 'Social Entrepreneurship',
    'interest.business.entrepreneurship.startups': 'Startups',
    'interest.business.finance': 'Finance',
    'interest.business.finance.accounting': 'Accounting',
    'interest.business.finance.cryptocurrency': 'Cryptocurrency',
    'interest.business.finance.investing': 'Investing',
    'interest.business.healthcare': 'Healthcare',
    'interest.business.healthcare.international': 'International Healthcare',
    'interest.business.healthcare.policy': 'Healthcare Policy',
    'interest.business.healthcare.tech': 'Healthcare Technology',
    'interest.business.law': 'Law',
    'interest.business.law.corporate': 'Corporate Law',
    'interest.business.law.international': 'International Law',
    'interest.business.law.ip': 'Intellectual Property',
    'interest.business.marketing': 'Marketing',
    'interest.business.marketing.branding': 'Branding',
    'interest.business.marketing.digital': 'Digital Marketing',
    'interest.business.marketing.international': 'International Marketing',
    'interest.business.networking': 'Networking',
    'interest.business.networking.events': 'Networking Events',
    'interest.business.networking.international': 'International Networking',
    'interest.business.networking.online': 'Online Networking',
    'interest.business.sustainability': 'Sustainability',
    'interest.business.sustainability.green': 'Green Business',
    'interest.business.sustainability.international':
        'International Sustainability',
    'interest.business.sustainability.social': 'Social Sustainability',
    'interest.business.technology': 'Technology',
    'interest.business.technology.ai': 'AI Technology',
    'interest.business.technology.cyber': 'Cybersecurity',
    'interest.business.technology.web': 'Web Development',
    'interest.business.volunteering': 'Volunteering',
    'interest.business.volunteering.community': 'Community Service',
    'interest.business.volunteering.international':
        'International Volunteering',
    'interest.business.volunteering.mentoring': 'Mentoring',
    'interest.category.business_functions': 'Business functions',
    'interest.category.business_goals': 'Business goals',
    'interest.category.business_industry': 'Industries',
    'interest.category.business_topics': 'Business topics',
    'interest.co_op_gaming': 'Co-op gaming',
    'interest.cocktails': 'Cocktails / Bars',
    'interest.coffee': 'Coffee meetups',
    'interest.coffee_meetups': 'Coffee meetups',
    'interest.dancing': 'Dancing',
    'interest.dancing.line': 'Line dancing',
    'interest.dancing.line_dancing': 'Line dancing',
    'interest.dancing.salsa': 'Salsa',
    'interest.dancing.tango': 'Tango',
    'interest.dinner': 'Dinner',
    'interest.eating_out': 'Eating Out',
    'interest.finance': 'Finance',
    'interest.friendship': 'Friendship',
    'interest.friendship.arts': 'Arts',
    'interest.friendship.arts.crafts': 'Crafts',
    'interest.friendship.arts.music': 'Music',
    'interest.friendship.arts.photography': 'Photography',
    'interest.friendship.books': 'Books',
    'interest.friendship.books.club': 'Book Clubs',
    'interest.friendship.books.fiction': 'Fiction',
    'interest.friendship.books.nonfiction': 'Non-Fiction',
    'interest.friendship.fitness': 'Fitness',
    'interest.friendship.fitness.gym': 'Gym',
    'interest.friendship.fitness.running': 'Running',
    'interest.friendship.fitness.team': 'Team Sports',
    'interest.friendship.food': 'Food',
    'interest.friendship.food.baking': 'Baking',
    'interest.friendship.food.cooking': 'Cooking',
    'interest.friendship.food.tasting': 'Food Tasting',
    'interest.friendship.gaming': 'Gaming',
    'interest.friendship.gaming.board': 'Board Games',
    'interest.friendship.gaming.rpg': 'RPGs',
    'interest.friendship.gaming.video': 'Video Games',
    'interest.friendship.language': 'Language Exchange',
    'interest.friendship.language.exchange': 'Language Exchange',
    'interest.friendship.language.learning': 'Language Learning',
    'interest.friendship.language.sign': 'Sign Language',
    'interest.friendship.movies': 'Movies',
    'interest.friendship.movies.cinema': 'Cinema',
    'interest.friendship.movies.festivals': 'Film Festivals',
    'interest.friendship.movies.marathon': 'Movie Marathons',
    'interest.friendship.pets': 'Pets',
    'interest.friendship.pets.cats': 'Cats',
    'interest.friendship.pets.dogs': 'Dogs',
    'interest.friendship.pets.exotic': 'Exotic Pets',
    'interest.friendship.travel': 'Travel',
    'interest.friendship.travel.backpacking': 'Backpacking',
    'interest.friendship.travel.cultural': 'Cultural Travel',
    'interest.friendship.travel.roadtrips': 'Road Trips',
    'interest.friendship.volunteering': 'Volunteering',
    'interest.friendship.volunteering.community': 'Community Service',
    'interest.friendship.volunteering.education': 'Educational Volunteering',
    'interest.friendship.volunteering.environment': 'Environmental Protection',
    'interest.function.engineering': 'Engineering & development',
    'interest.function.hr': 'HR & people operations',
    'interest.function.product': 'Product management',
    'interest.function.sales': 'Sales & business development',
    'interest.goal.clients': 'Find clients',
    'interest.goal.find_cofounder': 'Find a co-founder',
    'interest.goal.investors': 'Meet investors',
    'interest.goal.mentor': 'Find a mentor',
    'interest.gym_buddies': 'Gym buddies',
    'interest.hiking_trails': 'Hiking trails',
    'interest.industry.education': 'Education & training',
    'interest.industry.finance': 'Finance',
    'interest.industry.healthcare': 'Healthcare',
    'interest.industry.marketing': 'Marketing & advertising',
    'interest.industry.technology': 'Technology',
    'interest.job_openings': 'Job openings',
    'interest.language_exchange': 'Language exchange',
    'interest.live_music': 'Live music',
    'interest.marketing': 'Marketing',
    'interest.movies': 'Movies',
    'interest.pickup_sports': 'Pickup sports',
    'interest.romantic': 'Romantic',
    'interest.romantic.animals': 'Animals',
    'interest.romantic.animals.horseback': 'Horseback Riding',
    'interest.romantic.animals.pets': 'Pets',
    'interest.romantic.animals.wildlife': 'Wildlife',
    'interest.romantic.arts': 'Arts',
    'interest.romantic.arts.museums': 'Museums',
    'interest.romantic.arts.painting': 'Painting',
    'interest.romantic.arts.theater': 'Theater',
    'interest.romantic.culture': 'Culture',
    'interest.romantic.culture.cuisine': 'Cuisine',
    'interest.romantic.culture.festivals': 'Festivals',
    'interest.romantic.culture.traditions': 'Traditions',
    'interest.romantic.dining': 'Dining',
    'interest.romantic.dining.casual': 'Casual Dining',
    'interest.romantic.dining.fine': 'Fine Dining',
    'interest.romantic.dining.international': 'International Cuisine',
    'interest.romantic.music': 'Music',
    'interest.romantic.music.concerts': 'Concerts',
    'interest.romantic.music.dancing': 'Dancing',
    'interest.romantic.music.jazz': 'Jazz',
    'interest.romantic.outdoors': 'Outdoors',
    'interest.romantic.outdoors.hiking': 'Hiking',
    'interest.romantic.outdoors.picnic': 'Picnics',
    'interest.romantic.outdoors.stargazing': 'Stargazing',
    'interest.romantic.sports': 'Sports',
    'interest.romantic.sports.dance': 'Dance',
    'interest.romantic.sports.tennis': 'Tennis',
    'interest.romantic.sports.yoga': 'Yoga',
    'interest.romantic.travel': 'Travel',
    'interest.romantic.travel.beach': 'Beach Getaways',
    'interest.romantic.travel.city': 'City Breaks',
    'interest.romantic.travel.mountains': 'Mountain Retreats',
    'interest.romantic.volunteering': 'Volunteering',
    'interest.romantic.volunteering.animals': 'Animal Rescue',
    'interest.romantic.volunteering.community': 'Community Service',
    'interest.romantic.volunteering.environment': 'Environmental Protection',
    'interest.romantic.wellness': 'Wellness',
    'interest.romantic.wellness.meditation': 'Meditation',
    'interest.romantic.wellness.retreats': 'Retreats',
    'interest.romantic.wellness.spa': 'Spa',
    'interest.singing': 'Singing',
    'interest.skill_swap': 'Skill swap',
    'interest.startup_founders': 'Startup founders',
    'interest.startups': 'Startups',
    'interest.study_groups': 'Study groups',
    'interest.topic.career_change': 'Career change',
    'interest.topic.leadership': 'Leadership',
    'interest.topic.remote_work': 'Remote work',
    'interest.topic.startups': 'Startups & entrepreneurship',
    'interest.traveling': 'Traveling',
    'interest.vc': 'Venture Capital',
    'interest.venture_capital': 'Venture Capital',
    'interest.walks': 'Walks / Strolls',
    'interest.adventure_travel': 'Adventure Travel',
    'interest.angel_investing': 'Angel Investing',
    'interest.backpacking': 'Backpacking',
    'interest.biotech': 'Biotech',
    'interest.brand_strategy': 'Brand Strategy',
    'interest.brunch': 'Brunch',
    'interest.career_coaching': 'Career Coaching',
    'interest.choir': 'Choir',
    'interest.cleantech': 'Cleantech',
    'interest.coding_bootcamps': 'Coding Bootcamps',
    'interest.consulting': 'Consulting',
    'interest.content_creation': 'Content Creation',
    'interest.cooking': 'Cooking',
    'interest.crossfit': 'Crossfit',
    'interest.cultural_tourism': 'Cultural Tourism',
    'interest.dancing.ballroom': 'Ballroom',
    'interest.dancing.bachata': 'Bachata',
    'interest.dancing.contemporary': 'Contemporary',
    'interest.dancing.hip_hop': 'Hip-Hop',
    'interest.dancing.swing': 'Swing',
    'interest.digital_marketing': 'Digital Marketing',
    'interest.ecommerce': 'E-Commerce',
    'interest.entrepreneurship': 'Entrepreneurship',
    'interest.ethnic_cuisine': 'Ethnic Cuisine',
    'interest.financial_advisory': 'Financial Advisory',
    'interest.fine_dining': 'Fine Dining',
    'interest.fintech': 'Fintech',
    'interest.food_trucks': 'Food Trucks',
    'interest.founder_groups': 'Founder Groups',
    'interest.growth_equity': 'Growth Equity',
    'interest.growth_hacking': 'Growth Hacking',
    'interest.hiking': 'Hiking',
    'interest.investing': 'Investing',
    'interest.jewelry_making': 'Jewelry Making',
    'interest.karaoke': 'Karaoke',
    'interest.management_consulting': 'Management Consulting',
    'interest.open_mic': 'Open Mic',
    'interest.open_source': 'Open Source',
    'interest.painting': 'Painting',
    'interest.personal_finance': 'Personal Finance',
    'interest.photography': 'Photography',
    'interest.pitch_nights': 'Pitch Nights',
    'interest.reading': 'Reading',
    'interest.road_trips': 'Road Trips',
    'interest.saas': 'SaaS',
    'interest.seed_stage': 'Seed Stage',
    'interest.startup_events': 'Startup Events',
    'interest.stock_trading': 'Stock Trading',
    'interest.tech_meetups': 'Tech Meetups',
    'interest.technology': 'Technology',
    'interest.volunteering': 'Volunteering',
    'interest.volunteering.animals': 'Animal Rescue',
    'interest.yoga': 'Yoga',
    'interest.yoga.ashtanga': 'Ashtanga',
    // Bare-key fallbacks for interests where the DB's translation_key
    // equals the raw key (e.g. 'saas') instead of the prefixed form
    // (e.g. 'interest.saas'). This covers stale cached interest data.
    'saas': 'SaaS',
    'fintech': 'Fintech',
    'arts_and_crafts': 'Arts & Crafts',
    'ashtanga': 'Ashtanga',
    'bachata': 'Bachata',
    'baking': 'Baking',
    'consulting': 'Consulting',
    'cooking': 'Cooking',
    'crossfit': 'Crossfit',
    'entrepreneurship': 'Entrepreneurship',
    'entrepreneurship_cat': 'Entrepreneurship',
    'founder_groups': 'Founder Groups',
    'gaming': 'Gaming',
    'jewelry_making': 'Jewelry Making',
    'technology': 'Technology',
    'technology_cat': 'Technology',
    'tech_meetups': 'Tech Meetups',
    'coding_bootcamps': 'Coding Bootcamps',
    'knitting': 'Knitting',
    'yoga': 'Yoga',
    'amusement_park': 'Amusement Park',
    'ballroom': 'Ballroom',
    'bootstrapping': 'Bootstrapping',
    'business_events': 'Business Events',
    'conferences': 'Conferences',
    'interestsCategoryBusiness': 'Business',
    'interestsCategorySocial': 'Social',
    'invisibleDueTo': 'Invisible due to ',
    'invisibleDueTo_female': 'Invisible due to',
    'invisibleDueTo_male': 'Invisible due to',
    'invisibleDueTo_non_binary': 'Invisible due to',
    'inviteFriendsCheckConnection':
        'Please check your internet connection or try again later.',
    'inviteFriendsCopied': 'Code copied to clipboard',
    'inviteFriendsCredits': 'Your Credits: {0}',
    'inviteFriendsDescription':
        'Share your link. Friends will be guided to download the app.',
    'inviteFriendsError': 'Could not generate referral code.',
    'inviteFriendsGetBenefitsSubtitle': 'Get 10 credits for every friend',
    'inviteFriendsGetBenefitsTitle': 'Invite friends and get benefits',
    'inviteFriendsRetry': 'Retry',
    'inviteFriendsShareBtn': 'Share Link',
    'inviteFriendsShareMessage':
        'Join me on MatchMe! Use my code {code} to get free credits! {link}',
    'inviteFriendsSubtitle': 'Give Rewards, Get Rewards',
    'inviteFriendsTitle': 'Invite Friends',
    'lang_en': 'English',
    'lang_es': 'Spanish',
    'lang_he': 'Hebrew',
    'locationShareStart': 'Share Your Location',
    'locationShareView': 'View Live Location',
    'locationShareStop': 'Stop Sharing',
    'locationSharePause': 'Pause',
    'locationShareResume': 'Resume',
    'locationShareCenter': 'Center Map',
    'locationShareActive': 'You are sharing your location',
    'locationShareReceiving': '{name} is sharing their location with you',
    'locationShareOtherSharing': '{name} is sharing their location',
    'locationShareExpired': 'Location sharing has ended',
    'locationShareWaiting': 'Waiting for location...',
    'locationShareDurationTitle': 'Share for how long?',
    'locationShareChangeDurationTitle': 'Change sharing duration',
    'locationShareSaveDuration': 'Save duration',
    'locationShareRecipientNotice':
        'You’re sharing your live location with {name}.',
    'locationSharePrivacyNotice':
        'Only share when you’re ready. The other person can see your live location for the selected duration, and you can stop sharing at any time.',
    'locationShareIndefiniteTitle': 'Share until turned off?',
    'locationShareIndefiniteMessage':
        'You’re choosing to share your live location with {name} until you turn it off. You can stop sharing at any time.',
    'locationShareUntilOff': 'Until turned off',
    'locationShareMinutes': '{count} minutes',
    'locationShareHours': '{count} hours',
    'locationShareOffline': 'You must be online to share your location',
    'locationShareOtherOffline': '{name} is currently offline',
    'locationShareOtherStopped': '{name} stopped sharing their location',
    'locationShareOtherPaused': '{name} paused their location sharing',
    'locationShareTimerRemaining': 'Expires in {time}',
    'locationShareNoLocation': 'Waiting for location...',
    'locationShareMapTitle': 'Live Location',
    'locationShareStale': 'Stale',
    'locationShareYou': 'You',
    'locationShareBannerTitle': 'Live Location Active',
    'locationShareBannerSubtitle': 'Tap to view on map',
    'locationShareBannerWaiting': 'Waiting for location...',
    'locationShareBannerView': 'View',
    'locationShareBannerYouAreSharing': 'You are sharing your location',
    'locationShareBannerSharingWith': 'Sharing with {name}',
    'locationShareBannerLocating': 'Getting your location...',
    'locationShareStarted': 'Live location sharing started',
    'locationShareDurationUpdated': 'Duration updated',
    'locationShareChangeDuration': 'Change Duration',
    'locationShareMutualActive': 'Mutual location sharing active',
    'locationShareTapToView': 'Tap to view on map',
    'locationShareButtonMutualActive': 'Mutual Sharing Active',
    'locationShareButtonSharing': 'Sharing Location',
    'settingsNotificationsLocationSharing': 'Location Sharing',
    'languageShort_en': 'EN',
    'languageShort_es': 'ES',
    'languageShort_he': 'HE',
    'later': 'Later',
    'learning': 'Learning',
    'line_dancing': 'Line dancing',
    'live_music': 'Live Music',
    'long_term': 'Long-term',
    'lowSimilarity': 'Low similarity',
    'manualInput': 'Manual input',
    'mapApproxUsersHere': 'About {count} users here',
    'mapZoomIn': 'Zoom in',
    'mapZoomOut': 'Zoom out',
    'nearbyLocationLoading': 'Finding your location…',
    'nearbyProfileErrorMessage':
        'We couldn’t load your matching radius. Try again.',
    'nearbyLocationUnavailableTitle': 'We couldn’t find your location',
    'nearbyLocationUnavailableMessage':
        'Allow location access or try again. The Nearby Map uses an approximate location, never your exact position.',
    'nearbyLocationOfflineMessage': 'Reconnect to load the Nearby Map.',
    'mapLegendOnlineInRadius': 'Online in your radius',
    'mapLegendOnlineCountries': 'Online by country',
    'mapLegendYou': 'You',
    'mapLegendOnlineUsersApprox': 'Nearby users',
    'mapShowingApproxUsers': 'Showing about {count} users',
    'matchChatStartExpiryWarningBody': 'You have {time} left to start a chat.',
    'matchChatStartExpiryWarningBodyWithName':
        'You have {time} left to start a chat with {name}.',
    'matchChatStartExpiryWarningTitle': '{time} left',
    'matchedAt': 'Matched on',
    'matchedByProximityLabel': 'Proximity',
    'matchedByCoMotionLabel': 'Shared movement',
    'matchReasonMovingTogether': 'Moving together',
    'matchedOn': 'Matched on',
    'matches': 'Matches',
    'matchesScreenTitle': 'Matches',
    'matchesClearFilters': 'Clear filters',
    'matchesNoIntentResults': 'No matches for this connection type',
    'matchesNoIntentResultsMessage':
        'Try another connection type or clear the filter to see all matches.',
    'matchesResultsCount': '{count} Matches',
    'matchesResultsCountOf': '{shown} of {total} Matches',
    'matchExpiryBody':
        'You have {count} minutes left to start a chat with {otherUserName}.',
    'matchExpiryTitle': '{count} minutes left',
    'matchingOn': 'Matching on',
    'pinnedLocationActiveUntil': 'Pinned{label} until {date}',
    'pinnedLocationBanner': '📍 Matching from pinned spot{label} — GPS paused',
    'pinnedLocationDur14d': '14 days',
    'pinnedLocationDur3d': '3 days',
    'pinnedLocationDur24h': '24 hours',
    'pinnedLocationDur7d': '7 days',
    'pinnedLocationDuration': 'Pin for',
    'pinnedLocationExtensionDuration': 'Add time',
    'pinnedLocationExpired': 'Pinned location expired — live GPS resumed.',
    'pinnedLocationExtend': 'Add time',
    'pinnedLocationExtended': 'Pinned time extended until {date}.',
    'pinnedLocationLabelHint': 'Label (optional, for example: Home)',
    'pinnedLocationMaxDurationReached':
        'The maximum total pinned time is 14 days.',
    'pinnedLocationManage': 'Manage',
    'pinnedLocationNoPosition':
        'No recent position to pin yet. Turn location on briefly, then try again.',
    'pinNoObservedLocation':
        'No recent GPS position on the server to pin. Open the map with location on, then try again.',
    'pinLocationTooOld':
        'Your last known position is too old to pin. Turn location on briefly to update it, then try again.',
    'pinnedLocationPinAction': 'Pin current location',
    'pinnedLocationPinned': 'Location pinned until {date}.',
    'pinnedLocationRemaining': '{duration} left',
    'pinnedLocationSectionDesc':
        'Keep matching near home while you travel. GPS pauses and matches use your pinned spot until it expires.',
    'pinnedLocationSectionTitle': 'Home base (pinned location)',
    'pinnedLocationUnpin': 'Unpin now',
    'pinnedLocationUnpinned': 'Pin removed — live GPS resumed.',
    'pinnedPartnerBadge': 'Pinned location',
    'matchMatchedAtValue': '{date}, at {time}',
    'matchProfileBio': 'About',
    'matchProfileBusinessInterests': 'Business Interests',
    'matchProfileLookingFor': 'Looking for',
    'matchProfileSharedIntent': 'Shared Intentions',
    'matchProfileSharedInterests': 'Shared Interests',
    'matchProfileSocialInterests': 'Social Interests',
    'matchReasonEvent': 'You matched because of a shared event',
    'matchReasonProximityText': 'You are or were located near each other.',
    'mediumSimilarity': 'Medium similarity',
    'mentorship': 'Mentorship',
    'month_april': 'April',
    'month_august': 'August',
    'month_december': 'December',
    'month_february': 'February',
    'month_january': 'January',
    'month_july': 'July',
    'month_june': 'June',
    'month_march': 'March',
    'month_may': 'May',
    'month_november': 'November',
    'month_october': 'October',
    'month_september': 'September',
    'movies': 'Movies',
    'Moving Together': 'Moving together',
    'music_and_art': 'Music & Art',
    'music_art': 'Music & Art',
    'navChats': 'Chats',
    'navEvents': 'Events',
    'navHome': 'Home',
    'navMatches': 'Matches',
    'navProfile': 'Profile',
    'networkErrorConnectionFailed':
        'Could not connect to the server. Please check your internet connection and try again.',
    'networkErrorGeneric':
        'A network error occurred. Please check your connection and try again.',
    'networkErrorNoInternet':
        'No internet connection. Please check your network and try again.',
    'networkErrorSSLCertificate':
        'A security error occurred. Please try again or contact support if the problem persists.',
    'networkErrorTimeout':
        'The request timed out. Please check your internet connection and try again.',
    'networking': 'Networking',
    'newMatchNotificationBody': 'You have a new match.',
    'newMatchNotificationTitle': 'New match',
    'newMatchNotificationTitleWithName': 'New match with {name}!',
    'newMatchPlaceholderName': 'New match',
    'newMatchTitle': 'New Match!',
    'newMatchTitle_female': 'You have a new match',
    'newMatchTitle_male': 'You have a new match',
    'newMatchTitle_non_binary': 'You have a new match',
    'matchExtendedBannerTitle': 'Match extended!',
    'matchExtendedBannerTitle_female': 'Match extended!',
    'matchExtendedBannerTitle_male': 'Match extended!',
    'matchExtendedBannerTitle_non_binary': 'Match extended!',
    'matchExtendedBannerBody': 'Say hi before this match runs out.',
    'matchExtendedPushTitle': '{name} gave you more time',
    'matchExtendedPushBody': 'Say hi before this match runs out.',
    'noFiltersOrEdits': 'No filters or edits',
    'noFiltersOrEditsDescription':
        'Use your real appearance without modifications',
    'noMatchesFoundForThisEvent': 'No matches were found for this event',
    'notesOptional': 'Notes (optional)',
    'notVerified': 'Not Verified',
    'notVerifiedDescription': 'Get verified to build trust with other users.',
    'noUsersWithMatchingIntentsFoundForThisEvent':
        'No users with matching interests were found for this event',
    'offlineAddInvisibilityRuleBody':
        'Your rule has been saved locally and will be added when you\'re back online.',
    'offlineAddInvisibilityRuleTitle':
        'Cannot add invisibility rule while offline',
    'offlineBlockUserBody':
        'Your block has been saved locally and will be processed when you\'re back online.',
    'offlineBlockUserTitle': 'Cannot block user while offline',
    'offlineCannotCompleteRequest': 'Cannot Complete Request',
    'offlineCreateEventBody':
        'Your event has been saved locally and will be created when you\'re back online.',
    'offlineCreateEventTitle': 'Cannot create event while offline',
    'offlineDeleteEventBody':
        'Your deletion request has been saved locally and will update when you\'re back online.',
    'offlineDeleteEventTitle': 'Cannot delete event while offline',
    'offlineDeleteMessageBody':
        'Your deletion request has been saved locally and will update when you\'re back online.',
    'offlineDeleteMessageTitle': 'Cannot delete message while offline',
    'offlineDeleteReactionBody':
        'Your reaction removal has been saved locally and will update when you\'re back online.',
    'offlineDeleteReactionTitle': 'Cannot remove reaction while offline',
    'offlineEditMessageBody':
        'Your message edit has been saved locally and will update when you\'re back online.',
    'offlineEditMessageTitle': 'Cannot edit message while offline',
    'offlineFeatureRequiresConnection':
        'This feature requires an internet connection.',
    'offlineFeatureRequiresConnectionDetailed':
        '{feature} requires an internet connection. MatchMe is currently offline.',
    'offlineFeatureUnavailable': 'Feature Unavailable',
    'offlineIndicatorTitle': 'MatchMe is offline - showing cached data',
    'offlineStatusSyncing': 'Syncing with server...',
    'offlineJoinEventBody':
        'Your event join request has been saved locally and will be processed when you\'re back online.',
    'offlineJoinEventTitle': 'Cannot join event while offline',
    'offlineLanguageUnavailableMessage':
        'To use this language, the app needs to download its translation texts. Please restore your internet connection and try again.',
    'offlineLanguageUnavailableTitle': 'Language Not Downloaded',
    'offlineLeaveEventBody':
        'Your event leave request has been saved locally and will be processed when you\'re back online.',
    'offlineLeaveEventTitle': 'Cannot leave event while offline',
    'offlineOkButton': 'OK',
    'offlinePendingChanges': 'Pending Changes',
    'offlinePendingChangesDescription':
        'You have {count} pending changes waiting to sync. These will be sent to the server when your connection is restored.\\n\\nActions in MatchMe will be unavailable until these sync.',
    'offlineReactToMessageBody':
        'Your reaction has been saved locally and will be added when you\'re back online.',
    'offlineMessageQueuedToast':
        'You\'re offline — message will be sent when you\'re back online',
    'offlineReactToMessageTitle': 'Cannot add reaction while offline',
    'offlineRemoveInvisibilityRuleBody':
        'Your rule removal has been saved locally and will be processed when you\'re back online.',
    'offlineRemoveInvisibilityRuleTitle':
        'Cannot remove invisibility rule while offline',
    'offlineReportUserBody':
        'Your report has been saved locally and will be submitted when you\'re back online.',
    'offlineReportUserTitle': 'Cannot report user while offline',
    'offlineSendAnywayButton': 'Send Anyway',
    'offlineSendMessageBody':
        'Your message has been saved locally and will send when you\'re back online.',
    'offlineSendMessageTitle': 'Cannot send message while offline',
    'offlineSensitiveActionsRequireInternet':
        'These features require an active internet connection.',
    'offlineSnackbarMessage': 'MatchMe is offline - using cached data',
    'offlineSyncingChanges': 'Syncing {count} changes',
    'offlineMutationId': 'Identifier: {id}',
    'offlineMutationRetries': 'Retries: {count}',
    'offlineMutationError': 'Error: {error}',
    'offlineToggleSharedEventBody':
        'Your preference change has been saved locally and will update when you\'re back online.',
    'offlineToggleSharedEventTitle':
        'Cannot change shared event setting while offline',
    'offlineToggleSharedMovementBody':
        'Your preference change has been saved locally and will update when you\'re back online.',
    'offlineToggleSharedMovementTitle':
        'Cannot change shared movement setting while offline',
    'offlineUnblockUserBody':
        'Your unblock request has been saved locally and will be processed when you\'re back online.',
    'offlineUnblockUserTitle': 'Cannot unblock user while offline',
    'offlineUpdateEventBody':
        'Your event changes have been saved locally and will update when you\'re back online.',
    'offlineUpdateEventTitle': 'Cannot update event while offline',
    'offlineUpdateGeneralBody':
        'Your changes have been saved locally and will update when you\'re back online.',
    'offlineUpdateGeneralTitle': 'Cannot make changes while offline',
    'offlineUpdateLocationBody':
        'Your location update has been saved locally and will be sent when you\'re back online.',
    'offlineUpdateLocationTitle': 'Cannot update location while offline',
    'offlineUpdateNotificationsBody':
        'Your notification preferences have been saved locally and will update when you\'re back online.',
    'offlineUpdateNotificationsTitle':
        'Cannot update notification settings while offline',
    'offlineUpdateProfileBody':
        'Your profile changes have been saved locally and will update when you\'re back online.',
    'offlineUpdateProfileTitle': 'Cannot update profile while offline',
    'offlineUpdateVisibilityBody':
        'Your visibility change has been saved locally and will update when you\'re back online.',
    'offlineUpdateVisibilityTitle': 'Cannot update visibility while offline',
    'offlineViewDetails': 'Details',
    'offlineViewPendingDetails': 'View Details',
    'onlineMapTotalOnline': 'Online: {count}',
    'onlineProvidersAccountAdded': '{account} is ready to import.',
    'onlineProvidersAccountAlreadyAdded': 'This account is already connected.',
    'onlineProvidersAccountLine': '{account}: {count} {eventWord}',
    'onlineProvidersAccountPickerHelp':
        'Choose an available account or add another one.',
    'onlineProvidersAccountRefreshFailed':
        'Could not refresh {account}. Please try again.',
    'onlineProvidersAccountStats': '{events} events · {calendars} calendars',
    'onlineProvidersAddAccount': 'Add Account',
    'onlineProvidersAddAccountHint':
        'Tap Add Account to connect Google, Outlook, or Apple calendars.',
    'onlineProvidersAllAccounts': 'All accounts',
    'onlineProvidersAppleUrlTitle': 'Paste Apple calendar URL',
    'onlineProvidersAvailableAccount': 'Available account',
    'onlineProvidersChooseGoogleAccount': 'Choose a Google account',
    'onlineProvidersChooseOutlookAccount': 'Choose an Outlook account',
    'onlineProvidersEventCount': '{count} events',
    'onlineProvidersImportSelected': 'Import Selected ({count})',
    'onlineProvidersNoAccounts': 'No accounts connected',
    'onlineProvidersNoEvents': 'No events found',
    'onlineProvidersNoEventsForFilter':
        'No events are available for this account.',
    'onlineProvidersReconnectRequired':
        'Reconnect this account to continue importing events.',
    'onlineProvidersRemoveAccount': 'Remove Account',
    'onlineProvidersRemoveAccountConfirm':
        'Are you sure you want to remove {account}?',
    'onlineProvidersSelectionSummary': '{selected} of {available} selected',
    'onlineProvidersSummaryAccounts': '{count} accounts connected',
    'onlineProvidersSummaryEvents': '{count} events found',
    'onlineProvidersSummarySelected': '{count} selected',
    'onlineProvidersSummaryTitle': 'Online calendars',
    'onlineProvidersUseAnotherAccount': 'Use another {provider} account',
    'outdoors': 'Outdoors',
    'outdoors_hiking': 'Hiking',
    'pasteEventUrl': 'Paste Event URL',
    'pasteLink': 'Paste link',
    'pastEventDetected': 'Past event detected',
    'paymentFailed': 'Payment failed: {error}',
    'paymentPromoRedemptionWarning':
        'Warning: Promo code redemption failed: {error}',
    'paymentTotal': 'Total',
    'paywallBestValue': 'Best Value',
    'paywallCurrencyEstimateFallback':
        'Converted prices are estimated from cached exchange rates.',
    'paywallFeatureAdvancedFilters': 'Advanced filters',
    'paywallFeatureNoAds': 'No ads',
    'paywallFeatureSeeWhoLikesYou': 'See who likes you',
    'paywallFeaturesTitle': 'Unlock Premium Features',
    'paywallFeatureUnlimitedLikes': 'Unlimited likes',
    'paywallPeriodAnnual': 'Annual',
    'paywallPeriodDaily': 'Daily',
    'paywallPeriodLifetime': 'Lifetime',
    'paywallPeriodMonthly': 'Monthly',
    'paywallPeriodWeekly': 'Weekly',
    'paywallOfflineTitle': 'Subscription details unavailable',
    'paywallOfflineBody':
        'You\'re offline and we don\'t have a recent copy of the subscription tiers cached on this device. Please connect to the internet to view subscription options.',
    'paywallPopular': 'Most Popular',
    'paywallPreferredCurrencyLabel': 'Preferred currency',
    'paywallPrivacy': 'Privacy',
    'paywallPurchaseFailed': 'Purchase failed. Please try again.',
    'paywallPurchaseSuccess':
        'Subscription active! Thank you for your support.',
    'paywallRestore': 'Restore purchases',
    'paywallRestoreFailed': 'Failed to restore purchases.',
    'paywallRestoreNoActive': 'No active subscriptions found to restore.',
    'paywallRestoreSuccess': 'Purchases restored successfully.',
    'paywallSavePercent': 'Save {percent}%',
    'paywallSubscribe': 'Subscribe',
    'paywallTerms': 'Terms',
    'paywallTermsAndPrivacy':
        'By subscribing you agree to our Terms and Privacy Policy',
    'paywallTitle': 'MatchMe Premium',
    'paywallWebError': 'Complete checkout on the web to continue.',
    'pendingManualReview': 'Pending manual review',
    'photoErrorAspectRatioInvalid':
        'Image aspect ratio not supported. Aspect ratio must be between 0.33 and 3.0.',
    'photoErrorDuplicatePhoto':
        'This photo has already been added to your profile.',
    'photoErrorFileTooLarge': 'File is too large. Maximum size is 10MB.',
    'photoErrorFileTooSmall': 'File is too small. Minimum size is 10KB.',
    'photoErrorFaceNotVisible':
        'Face is not clearly visible. Please use a clearer photo.',
    'photoErrorFaceTooSmall':
        'Face is too small in the photo. Please use a photo where your face is clearly visible.',
    'photoErrorGeneral':
        'Photo validation failed. Please try a different photo.',
    'photoErrorImageCorrupted': 'Image file is corrupted or invalid.',
    'photoErrorImageTooBlurry':
        'Image is too blurry. Please use a sharper photo.',
    'photoErrorImageTooBright':
        'Image is too bright. Please use a photo with better lighting.',
    'photoErrorImageTooDark': 'Image is too dark. Please use a brighter photo.',
    'photoErrorInvalidFormat':
        'Invalid image format. Please use JPEG, PNG, or WEBP.',
    'photoErrorMultipleFaces':
        'Primary photo must show only you (no group photos).',
    'photoErrorMultiplePeople':
        'Only you can be in the selfie. Retake it with just yourself in the frame.',
    'photoErrorPersonCheckUnavailable':
        'This device can\'t check who is in the photo. Add outfit details or a note instead.',
    'photoErrorNoFaceOrBody':
        'Photo must show at least your face or body clearly.',
    'photoErrorNoFaceDetected':
        'No face found. Your first photo must be a clear selfie showing only your face.',
    'photoErrorBodyShotNotAllowed':
        'The first photo must be a face-only selfie. Body shots are not allowed.',
    'photoErrorTextDetected':
        'Please retake the photo without any cards, signs, or visible text.',
    'photoErrorTextOverFace':
        'A card or text is covering part of your face. Please retake the photo without covering your face.',
    'photoErrorObjectOverFace':
        'Something is covering part of your face. Please retake the photo with your face fully visible.',
    'photoErrorDocumentDetected':
        'ID cards and documents are not allowed in photos. Please retake the photo without them.',
    'photoErrorEyesClosed':
        'Your eyes appear closed. Please retake the photo with your eyes open.',
    'photoErrorResolutionTooLow':
        'Image resolution too low. Minimum resolution is 200x200 for secondary photos and 400x400 for primary photos.',
    'photoPrescreenAdjustPhoto': 'Adjust photo',
    'photoPrescreenChooseAnother': 'Choose another photo',
    'photoPrescreenFailedTitle': 'Photo needs a small fix',
    'photoPrescreenOverlayCaption':
        'Outlined region: highlighted by the checker. Large outline: your face.',
    'photoPrescreenDetailsLabel': 'Technical details',
    'photoPrescreenDetailBrightness': 'Brightness',
    'photoPrescreenDetailSharpness': 'Sharpness',
    'photoPrescreenDetailFaceConfidence': 'Face detection',
    'photoPrescreenDetailHeadTilt': 'Head tilt',
    'photoPrescreenDetailFaces': 'Faces detected',
    'photoPrescreenDetailBodies': 'Bodies detected',
    'photoPrescreenDetailMinimum': 'minimum',
    'photoPrescreenDetailAnalyzer': 'Analyzer',
    'permActionNotNow': 'Not now',
    'permActionOpenSettings': 'Open settings',
    'permBatteryBody':
        'Disable battery optimization to allow reliable background activity.',
    'permBatteryTitle': 'Battery optimization',
    'permLocationAlwaysBody':
        'Allow location access at all times to enable full functionality.',
    'permLocationAlwaysTitle': 'Allow location access',
    'permLocationWhileInUseBody':
        'Allow location access while using the app to enable nearby features.',
    'permNotificationsBody':
        'Turn on notifications to stay updated with messages and activity.',
    'permNotificationsTitle': 'Enable notifications',
    'pleaseEnterValidUrl': 'Please enter a valid URL',
    'pleaseWait': 'Please wait…',
    'polyamorous': 'Polyamorous',
    'primaryPhotoVerificationErrorBadContent':
        'Photo contains restricted content.',
    'primaryPhotoVerificationErrorBodyNotAllowed':
        'The first photo must be a face-only selfie.',
    'primaryPhotoVerificationErrorDocument':
        'ID cards and documents are not allowed in photos. Please retake it without them.',
    'primaryPhotoVerificationErrorFaceNotVisible':
        'Face not clearly visible. Please check lighting.',
    'primaryPhotoVerificationErrorGeneral':
        'Please use a clear face-only selfie for your first photo.',
    'primaryPhotoVerificationErrorMultipleFaces':
        'Only one face is allowed in the first photo.',
    'primaryPhotoVerificationErrorNoPerson':
        'No person found. Please show your face clearly.',
    'primaryPhotoVerificationErrorReferenceExpired':
        'Please re-verify your profile before changing your primary photo.',
    'primaryPhotoVerificationErrorSystem':
        'Unable to verify your photo right now. Please try again.',
    'primaryPhotoVerificationErrorStillText':
        'We couldn’t remove the text from this photo automatically. Please retake it without any cards or text.',
    'primaryPhotoVerificationErrorVerifiedMismatch':
        'Your primary photo must match your verified identity.',
    'processingError': 'Something went wrong while processing your request',
    'profileAbout': 'About',
    'profileAgeLabel': 'Age',
    'profileZodiacSign': 'Zodiac Sign',
    'zodiacAries': 'Aries',
    'zodiacTaurus': 'Taurus',
    'zodiacGemini': 'Gemini',
    'zodiacCancer': 'Cancer',
    'zodiacLeo': 'Leo',
    'zodiacVirgo': 'Virgo',
    'zodiacLibra': 'Libra',
    'zodiacScorpio': 'Scorpio',
    'zodiacSagittarius': 'Sagittarius',
    'zodiacCapricorn': 'Capricorn',
    'zodiacAquarius': 'Aquarius',
    'zodiacPisces': 'Pisces',
    'profileAgeRequirementNote':
        'You must be at least 18 years old to use MatchMe.',
    'profileAppLanguage': 'App language',
    'profileBadgesShownToOthers': 'Shown to others',
    'profileBasicsHelper':
        'Tell us a bit about yourself so people can get to know you.',
    'profileBasicsLockedNoteBody':
        'Some profile details cannot be edited at this time',
    'profileBasicsLockedNoteTitle': 'Profile locked',
    'profileBasicsOneTimeBannerTitle':
        'Name, birthday & gender can be set only once',
    'profileBasicsOneTimeBannerBody':
        "Once you confirm these details, they can't be changed later.",
    'profileBasicsOneTimeDialogTitle': 'One-time details',
    'profileBasicsOneTimeDialogBody':
        "You can enter your name, birthday and gender once. After you confirm, they can't be changed later without approval from our team.",
    'profileBasicsOneTimeDialogOk': 'I understand',
    'profileBasicsOneTimeConfirmTitle': 'Confirm your details?',
    'profileBasicsOneTimeConfirmBody':
        "Your name, birthday and gender will be saved exactly as entered. Once you confirm, they can't be changed later without approval from our team.",
    'profileBasicsOneTimeConfirmCta': 'Confirm',
    'profileBio': 'Bio',
    'happyBirthday': 'Happy Birthday',
    'profileBirthday': 'Birthday',
    'birthdayPickerInstruction':
        'Spin each wheel to choose your birthday. Pick the month, then the day, then the year.',
    'birthdayWheelMonth': 'Month',
    'birthdayWheelDay': 'Day',
    'birthdayWheelYear': 'Year',
    'profileFieldOptional': 'optional',
    'profileWizardRequiredLegend':
        'Fields marked * are required and must be filled in to continue.',
    'profileWizardAllOptionalHint':
        'Everything on this page is optional — you can skip it now and complete it later.',
    'profileWizardSkipConfirmTitle': 'Skip this step?',
    'profileWizardSkipConfirmBody':
        "You haven't filled in anything on this page. All of it is optional — you can complete it later in your profile. Would you like to skip it for now?",
    'profileWizardSkipConfirmMatchingWarning':
        'Some of the fields on this page are used in match filters. If you skip them, you may be excluded from potential matches that filter on them.',
    'profileWizardSkipConfirmFillNow': 'Fill in now',
    'profileWizardSkipConfirmSkip': 'Skip for now',
    'profileWizardPhotosRequiredNote':
        'At least one photo is required to continue.',
    'profileBusinessInterests': 'Business Interests',
    'profileEditAdminDecisionApproved': 'Approved',
    'profileEditAdminDecisionApprovedOnceHint': 'You can edit this once now.',
    'profileEditAdminDecisionNoReason': 'No reason provided.',
    'profileEditAdminDecisionReasonPrefix': 'Reason: {reason}',
    'profileEditAdminDecisionRejected': 'Rejected',
    'profileEditAttachDocs': 'Attach supporting documents (optional)',
    'profileEditAttachmentInvalidType':
        'Unsupported file type. Allowed: {types}.',
    'profileEditAttachmentTooLarge':
        'File is too large. Maximum size is {maxMb} megabytes.',
    'profileEditAttachmentUploadFailed':
        'Upload failed for "{file}". Please try again.',
    'profileEditBasicDetailsLocked':
        'These details are locked. Please request approval to edit them.',
    'profileEditBasics': 'Basics',
    'profileEditBioDuplicate':
        'This bio is already being used by another profile. Please write your own bio.',
    'profileEditBioInappropriate': 'Your bio contains inappropriate language.',
    'profileEditBioModerationUnavailable':
        'Unable to verify your bio right now. Please try again.',
    'profileEditBioRejected': 'Your bio was not approved.',
    'profileEditDobRequired': 'Date of birth is required',
    'profileEditMustBe18': 'You must be at least 18 years old to use MatchMe.',
    'profileEditFieldLabelDateOfBirth': 'date of birth',
    'profileEditFieldLabelGender': 'gender',
    'profileEditFieldLabelName': 'name',
    'profileEditFullNameRequired': 'Enter both your first and last name.',
    'profileEditFileBytesMissing':
        'Could not read the selected file. Please pick another file.',
    'profileEditGenderRequired': 'Gender is required',
    'profileEditGoalsSubtitle': 'What are you looking for on MatchMe?',
    'profileEditGoalsTitle': 'Goals',
    'profileEditIntentsSubtitle': 'What are you looking for on MatchMe?',
    'profileEditIntentsTitle': 'Intentions',
    'profileEditLockedTooltip': 'Locked',
    'profileEditNoFiles': 'No files uploaded',
    'profileEditNoInterests': 'No interests selected',
    'profileEditRequestAlreadyPendingBody':
        'You already submitted a request for this field. Please wait for an admin decision.',
    'profileEditRequestAlreadyPendingTitle': 'Request already submitted',
    'profileEditRequestApprovedNotifBody':
        'An admin approved your profile edit request for {fields}.',
    'profileEditRequestApprovedNotifTitle': 'Profile edit request approved',
    'profileEditRequestChangingLabel': 'Requesting a change:',
    'profileEditRequestHelper': 'Tell us why you need to unlock your profile.',
    'profileEditRequestReasonHint': 'Reason for request',
    'profileEditRequestRejectedNotifBody':
        'An admin rejected your profile edit request for {fields}.',
    'profileEditRequestRejectedNotifTitle': 'Profile edit request rejected',
    'profileEditRequestReviewerNoteLine': 'Admin note: {note}',
    'profileEditRequestSubmit': 'Submit Request',
    'profileEditRequestSubmitted': 'Request submitted successfully.',
    'profileEditRequestSubmittedBody':
        'An admin will review your request soon.',
    'profileEditRequestSubmittedTitle': 'Request submitted',
    'profileEditRequestUnlockDesc':
        'Your profile is currently locked. Submit a request to unlock it for editing.',
    'profileEditRequestUnlockTitle': 'Request Profile Unlock',
    'profileEditReviewTitle': 'Review your profile',
    'profileEditSaveFailed': 'Failed to save changes. Please try again.',
    'profileEditSelectIntent': 'Select at least one intention',
    'profileEditShortBio': 'Short Bio',
    'profileEditShortBioHint': 'Write a short bio about yourself',
    'profileEditHeight': 'Height',
    'profileEditHeightHint': 'Height in centimeters (for example, 170)',
    'profileEditHeightRequired': 'Height is required',
    'profileEditHeightInvalid':
        'Height must be between 100 and 250 centimeters',
    'profileEditHeightInvalidFeet':
        'Height must be between 3 feet 4 inches and 8 feet 2 inches',
    'profileEditOccupation': 'Occupation',
    'profileEditOccupationHint': 'What do you do?',
    'profileEditOccupationRequired':
        'Occupation is required for business networking profiles',
    'profileEditEducation': 'Education',
    'profileEditEducationHint': 'Highest education level',
    'profileEditEducationRequired':
        'Education is required for business networking profiles',
    'profileWizardHeightOptionalNote':
        'Height is optional. If you skip it, you will only match with people who did not set any height restriction.',
    'profileWizardLifestyleTitle': 'Your Lifestyle',
    'profileWizardLifestyleSubtitle': 'Help others get to know you better.',
    'profileLifestyleSmoking': 'Smoking',
    'profileLifestyleDrinking': 'Drinking',
    'profileLifestyleExercise': 'Exercise',
    'profileLifestyleDiet': 'Diet',
    'profileWizardFamilyTitle': 'Family & Children',
    'profileWizardFamilySubtitle':
        'Let others know about your family situation.',
    'profileFamilyHasChildren': 'Do you have children?',
    'profileFamilyWantsChildren': 'Would you like to have children?',
    'profileHeight': 'Height',
    'profileOccupation': 'Occupation',
    'profileEducation': 'Education',
    'profileLifestyle': 'Lifestyle',
    'profileFamily': 'Family',
    'profileReligion': 'Religion or belief',
    'profileDenomination': 'Denomination or branch',
    'profileReligiousPractice': 'Religious practice',
    'profileWizardReligionTitle': 'Religion or Belief',
    'profileWizardReligionSubtitle':
        'Share your religion or belief, denomination, and practice. All fields are optional.',
    'profileWizardDenominationQuestion': 'Which denomination or branch?',
    'profileWizardPracticeQuestion':
        'How often do you engage in religious or spiritual practices?',

    // Lifestyle option values
    'lifestyleSmokingNever': 'Never',
    'lifestyleSmokingSometimes': 'Sometimes',
    'lifestyleSmokingRegularly': 'Regularly',
    'lifestyleDrinkingNever': 'Never',
    'lifestyleDrinkingSocially': 'Socially',
    'lifestyleDrinkingRegularly': 'Regularly',
    'lifestyleExerciseNever': 'Never',
    'lifestyleExerciseSometimes': 'Sometimes',
    'lifestyleExerciseRegularly': 'Regularly',
    'lifestyleExerciseDaily': 'Daily',
    'lifestyleDietAnything': 'Anything',
    'lifestyleDietVegetarian': 'Vegetarian',
    'lifestyleDietVegan': 'Vegan',
    'lifestyleDietHalal': 'Halal',
    'lifestyleDietKosher': 'Kosher',

    // Family option values
    'familyPreferNotToSay': 'Prefer not to say',
    'familyOpenToIt': 'Open to it',
    'familyNotSure': 'Not sure',

    // Religion or belief options
    'religionChristianity': 'Christianity',
    'religionIslam': 'Islam',
    'religionHinduism': 'Hinduism',
    'religionBuddhism': 'Buddhism',
    'religionJudaism': 'Judaism',
    'religionSikhism': 'Sikhism',
    'religionJainism': 'Jainism',
    'religionZoroastrianism': 'Zoroastrianism',
    'religionBahai': 'Bahá\'í',
    'religionShinto': 'Shinto',
    'religionTaoism': 'Taoism',
    'religionIndigenousFolk': 'Indigenous or folk religion',
    'religionPaganEarth': 'Pagan or Earth-based spirituality',
    'religionSpiritualNotReligious': 'Spiritual but not religious',
    'religionAtheist': 'Atheist',
    'religionAgnostic': 'Agnostic',
    'religionHumanist': 'Humanist',
    'religionNoReligion': 'No religion',
    'religionOther': 'Other',

    // Denominations and branches
    'denominationChristianityCatholic': 'Catholic',
    'denominationChristianityProtestant': 'Protestant',
    'denominationChristianityAnglican': 'Anglican or Episcopal',
    'denominationChristianityBaptist': 'Baptist',
    'denominationChristianityLutheran': 'Lutheran',
    'denominationChristianityMethodist': 'Methodist',
    'denominationChristianityPresbyterianReformed': 'Presbyterian or Reformed',
    'denominationChristianityPentecostalCharismatic':
        'Pentecostal or Charismatic',
    'denominationChristianityEvangelical': 'Evangelical',
    'denominationChristianityEasternOrthodox': 'Eastern Orthodox',
    'denominationChristianityOrientalOrthodox': 'Oriental Orthodox',
    'denominationChristianityLatterDaySaints': 'Latter-day Saints',
    'denominationChristianityJehovahsWitnesses': 'Jehovah\'s Witnesses',
    'denominationChristianityOther': 'Other Christian',
    'denominationIslamSunni': 'Sunni',
    'denominationIslamShia': 'Shia',
    'denominationIslamIbadi': 'Ibadi',
    'denominationIslamAhmadiyya': 'Ahmadiyya',
    'denominationIslamSufi': 'Sufi',
    'denominationIslamOther': 'Other Muslim',
    'denominationJudaismOrthodox': 'Orthodox',
    'denominationJudaismConservative': 'Conservative or Masorti',
    'denominationJudaismReform': 'Reform',
    'denominationJudaismReconstructionist': 'Reconstructionist',
    'denominationJudaismHasidic': 'Hasidic',
    'denominationJudaismSecularCultural': 'Secular or cultural Jewish',
    'denominationJudaismOther': 'Other Jewish',
    'denominationHinduismVaishnavism': 'Vaishnavism',
    'denominationHinduismShaivism': 'Shaivism',
    'denominationHinduismShaktism': 'Shaktism',
    'denominationHinduismSmartism': 'Smartism',
    'denominationHinduismOther': 'Other Hindu',
    'denominationBuddhismTheravada': 'Theravada',
    'denominationBuddhismMahayana': 'Mahayana',
    'denominationBuddhismZen': 'Zen',
    'denominationBuddhismVajrayana': 'Vajrayana or Tibetan',
    'denominationBuddhismPureLand': 'Pure Land',
    'denominationBuddhismNichiren': 'Nichiren',
    'denominationBuddhismOther': 'Other Buddhist',
    'denominationSikhismKhalsa': 'Khalsa',
    'denominationSikhismNanakpanthi': 'Nanakpanthi',
    'denominationSikhismOther': 'Other Sikh',
    'denominationJainismDigambara': 'Digambara',
    'denominationJainismSvetambara': 'Śvētāmbara',
    'denominationJainismOther': 'Other Jain',
    'denominationZoroastrianismOrthodox': 'Orthodox',
    'denominationZoroastrianismReformist': 'Reformist',
    'denominationZoroastrianismOther': 'Other Zoroastrian',
    'denominationShintoShrine': 'Shrine Shinto',
    'denominationShintoSect': 'Sect Shinto',
    'denominationShintoOther': 'Other Shinto',
    'denominationTaoismQuanzhen': 'Quanzhen',
    'denominationTaoismZhengyi': 'Zhengyi',
    'denominationTaoismOther': 'Other Taoist',
    'denominationPaganEarthWiccan': 'Wiccan',
    'denominationPaganEarthDruid': 'Druid',
    'denominationPaganEarthHeathen': 'Heathen',
    'denominationPaganEarthOther': 'Other pagan or Earth-based',

    // Religion option explanations
    'religionOptionHelp': 'What do these mean?',
    'religionChristianityDescription':
        'A monotheistic faith centered on Jesus Christ and his teachings, with many traditions and denominations.',
    'religionIslamDescription':
        'A monotheistic faith founded on the Qur\'an and the teachings of the Prophet Muhammad.',
    'religionHinduismDescription':
        'A diverse family of Indian religious and philosophical traditions, including many gods, scriptures, and practices.',
    'religionBuddhismDescription':
        'A tradition based on the Buddha\'s teachings on suffering, ethics, meditation, and liberation.',
    'religionJudaismDescription':
        'The monotheistic faith and cultural tradition of the Jewish people, rooted in the Torah and Jewish law.',
    'religionSikhismDescription':
        'A monotheistic faith founded by Guru Nanak, emphasizing devotion, equality, service, and the Guru Granth Sahib.',
    'religionJainismDescription':
        'An ancient Indian tradition emphasizing non-violence, truthfulness, asceticism, and liberation of the soul.',
    'religionZoroastrianismDescription':
        'An ancient Persian faith centered on Ahura Mazda, good thoughts, good words, and good deeds.',
    'religionBahaiDescription':
        'A faith teaching the unity of God, the unity of religion, and the unity of humanity.',
    'religionShintoDescription':
        'A traditional Japanese spiritual path focused on kami, nature, purity, and community rituals.',
    'religionTaoismDescription':
        'A Chinese tradition centered on living in harmony with the Tao, or the natural way of the universe.',
    'religionIndigenousFolkDescription':
        'Local or ancestral traditions tied to a particular culture, land, or community.',
    'religionPaganEarthDescription':
        'Spiritual paths that honor nature, cycles, and earth-centered practices, often outside mainstream religions.',
    'religionSpiritualNotReligiousDescription':
        'A personal spiritual life that is not tied to an organized religion.',
    'religionAtheistDescription':
        'A person who does not believe in God or gods.',
    'religionAgnosticDescription':
        'A person who holds that the existence of God or gods is unknown or unknowable.',
    'religionHumanistDescription':
        'A non-religious worldview centered on human reason, ethics, and well-being without relying on the supernatural.',
    'religionNoReligionDescription':
        'No religious affiliation or organized religion, without specifying a belief about God.',
    'religionOtherDescription':
        'A religion, belief, or spiritual path not listed here.',

    // Denomination option explanations
    'denominationChristianityCatholicDescription':
        'The largest Christian tradition, led by the Pope and emphasizing sacraments, tradition, and apostolic succession.',
    'denominationChristianityProtestantDescription':
        'A broad branch of Christianity that emerged from the Reformation, emphasizing Scripture and faith.',
    'denominationChristianityAnglicanDescription':
        'A Christian tradition rooted in the Church of England, combining Protestant and Catholic elements.',
    'denominationChristianityBaptistDescription':
        'A Protestant tradition emphasizing believer\'s baptism, congregational governance, and personal faith.',
    'denominationChristianityLutheranDescription':
        'A Protestant tradition rooted in Martin Luther\'s teachings, emphasizing grace and justification by faith.',
    'denominationChristianityMethodistDescription':
        'A Protestant tradition rooted in John Wesley\'s teachings, emphasizing personal holiness and social service.',
    'denominationChristianityPresbyterianReformedDescription':
        'Protestant traditions shaped by Calvinist theology, emphasizing God\'s sovereignty and representative church government.',
    'denominationChristianityPentecostalCharismaticDescription':
        'Christian movements emphasizing the Holy Spirit, spiritual gifts, and lively worship.',
    'denominationChristianityEvangelicalDescription':
        'A Christian movement emphasizing personal conversion, biblical authority, and sharing the faith.',
    'denominationChristianityEasternOrthodoxDescription':
        'A family of Orthodox churches rooted in early Christianity, with rich liturgy and tradition.',
    'denominationChristianityOrientalOrthodoxDescription':
        'Ancient Orthodox churches that recognize the first three ecumenical councils but not the later ones.',
    'denominationChristianityLatterDaySaintsDescription':
        'The Church of Jesus Christ of Latter-day Saints, founded by Joseph Smith and centered on the Book of Mormon.',
    'denominationChristianityJehovahsWitnessesDescription':
        'A Christian movement known for door-to-door witnessing and belief in God\'s Kingdom.',
    'denominationChristianityOtherDescription':
        'A Christian tradition or denomination not listed here.',
    'denominationIslamSunniDescription':
        'The largest branch of Islam, following the Qur\'an and the Sunnah and emphasizing community consensus.',
    'denominationIslamShiaDescription':
        'A major branch of Islam that emphasizes the leadership of Ali and his descendants.',
    'denominationIslamIbadiDescription':
        'A distinct branch of Islam found mainly in Oman, with its own legal and theological tradition.',
    'denominationIslamAhmadiyyaDescription':
        'A Muslim movement founded in the nineteenth century, not recognized as Muslim by many other Muslims.',
    'denominationIslamSufiDescription':
        'A mystical dimension of Islam focused on inner purification and closeness to God.',
    'denominationIslamOtherDescription':
        'A Muslim tradition or school not listed here.',
    'denominationJudaismOrthodoxDescription':
        'A Jewish tradition that strictly observes Jewish law and tradition.',
    'denominationJudaismConservativeDescription':
        'A Jewish movement that balances tradition and modern life while observing Jewish law.',
    'denominationJudaismReformDescription':
        'A Jewish movement that emphasizes ethical principles and adapts tradition to modern life.',
    'denominationJudaismReconstructionistDescription':
        'A Jewish movement that sees Judaism as an evolving civilization shaped by community.',
    'denominationJudaismHasidicDescription':
        'A Jewish movement known for joyful worship, mysticism, and close-knit communities.',
    'denominationJudaismSecularCulturalDescription':
        'Jewish identity based on culture, heritage, or community rather than religious observance.',
    'denominationJudaismOtherDescription':
        'A Jewish tradition or movement not listed here.',
    'denominationHinduismVaishnavismDescription':
        'A Hindu tradition centered on devotion to Vishnu and his avatars, especially Krishna and Rama.',
    'denominationHinduismShaivismDescription':
        'A Hindu tradition centered on devotion to Shiva as the supreme deity.',
    'denominationHinduismShaktismDescription':
        'A Hindu tradition centered on the divine feminine, especially the goddess Shakti.',
    'denominationHinduismSmartismDescription':
        'A Hindu tradition that worships several major deities as forms of one supreme reality.',
    'denominationHinduismOtherDescription':
        'A Hindu tradition or school not listed here.',
    'denominationBuddhismTheravadaDescription':
        'The oldest surviving Buddhist tradition, emphasizing the Pali scriptures and monastic practice.',
    'denominationBuddhismMahayanaDescription':
        'A major Buddhist branch emphasizing compassion, the bodhisattva path, and universal liberation.',
    'denominationBuddhismZenDescription':
        'A Mahayana tradition focused on meditation, direct experience, and simplicity.',
    'denominationBuddhismVajrayanaDescription':
        'A Buddhist tradition emphasizing tantric practice, ritual, and guidance from teachers.',
    'denominationBuddhismPureLandDescription':
        'A Mahayana tradition centered on faith in Amitabha Buddha and rebirth in the Pure Land.',
    'denominationBuddhismNichirenDescription':
        'A Japanese Buddhist tradition centered on the Lotus Sutra and chanting Nam-myoho-renge-kyo.',
    'denominationBuddhismOtherDescription':
        'A Buddhist tradition or school not listed here.',
    'denominationSikhismKhalsaDescription':
        'The initiated Sikh community established by Guru Gobind Singh, with a distinctive disciplined identity.',
    'denominationSikhismNanakpanthiDescription':
        'Sikhs who follow the teachings of Guru Nanak and often emphasize a more universal spiritual path.',
    'denominationSikhismOtherDescription':
        'A Sikh tradition or group not listed here.',
    'denominationJainismDigambaraDescription':
        'A Jain tradition whose monks traditionally practice nudity and emphasize strict asceticism.',
    'denominationJainismSvetambaraDescription':
        'A Jain tradition whose monks wear white robes and emphasize scholarship and ritual.',
    'denominationJainismOtherDescription':
        'A Jain tradition or group not listed here.',
    'denominationZoroastrianismOrthodoxDescription':
        'A Zoroastrian approach that preserves traditional rituals, calendar, and priestly authority.',
    'denominationZoroastrianismReformistDescription':
        'A Zoroastrian approach that adapts some traditions to modern life and emphasizes ethical practice.',
    'denominationZoroastrianismOtherDescription':
        'A Zoroastrian tradition or group not listed here.',
    'denominationShintoShrineDescription':
        'The traditional public form of Shinto centered on local shrines, festivals, and kami worship.',
    'denominationShintoSectDescription':
        'Independent Shinto movements and schools with their own teachings and practices.',
    'denominationShintoOtherDescription':
        'A Shinto tradition or group not listed here.',
    'denominationTaoismQuanzhenDescription':
        'A major Taoist school emphasizing monastic life, meditation, and inner alchemy.',
    'denominationTaoismZhengyiDescription':
        'A major Taoist school of hereditary priests, ritual, and community practice.',
    'denominationTaoismOtherDescription':
        'A Taoist tradition or school not listed here.',
    'denominationPaganEarthWiccanDescription':
        'A modern pagan tradition centered on nature, seasonal cycles, and ritual magic.',
    'denominationPaganEarthDruidDescription':
        'A modern or historical pagan path honoring nature, wisdom, and Celtic traditions.',
    'denominationPaganEarthHeathenDescription':
        'A modern pagan tradition rooted in Norse or Germanic gods, culture, and community.',
    'denominationPaganEarthOtherDescription':
        'A pagan or Earth-based path not listed here.',

    // Practice frequency
    'practiceDaily': 'Daily or almost daily',
    'practiceWeekly': 'Weekly',
    'practiceMonthly': 'Monthly',
    'practiceFewTimesAYear': 'A few times a year',
    'practiceRarelyOrNever': 'Rarely or never',
    'profileYes': 'Yes',
    'profileNo': 'No',
    'profileHasChildren': 'Has children',
    'profileNoChildren': 'No children',
    'profileEditStatusUnderReview': 'Under review',
    'profileEditTitle': 'Edit Profile',
    'profileFirstName': 'First name',
    'profileGender': 'Gender',
    'profileIntents': 'Intents',
    'profileInterests': 'Interests',
    'profileInstagramUrl': 'Instagram Profile (URL)',
    'profileInstagramUrlHint': 'https://instagram.com/yourusername',
    'profileLinkedinUrl': 'LinkedIn Profile (URL)',
    'profileLinkedinUrlHint': 'https://linkedin.com/in/yourprofile',
    'profileFacebookUrl': 'Facebook Profile (URL)',
    'profileFacebookUrlHint': 'https://facebook.com/yourusername',
    'profileSocialLinks': 'Social Links',
    'profileSocialLinkOpenFailed':
        'Could not open this link. Check your connection and try again.',
    'profileSocialLinksSubtitle':
        'Add links to your profiles. This step is optional.',
    'profileInterestsHelper':
        'Select a few interests to help improve your matches.',
    'profileLanguages': 'Languages Known',
    'profileLanguageSkills': 'Language skills',
    'profileLanguageSkillsLine': '{language} — {skills}',
    'profileLanguageSkillsRequired':
        'Please select at least one language skill.',
    'profileLanguagesKnown': 'Languages Known',
    'profileLastName': 'Last name',
    'profileLastNameNotDisplayed':
        'Your last name is never shown to other users.',
    'profileName': 'Name',
    'profileNewUserBadge': 'New here!',
    'profileNewUserBadgeFemale': 'New here!',
    'profileNewUserBadgeNeutral': 'New here!',
    'profileNoInterests': 'No interests selected',
    'profileNoLanguages': 'No languages selected',
    'profileNoPhotos': 'No photos added yet',
    'profileNotSet': 'Not set',
    'profilePersonalInterests': 'Personal Interests',
    'profilePhotos': 'Photos',
    'profilePhotoPreviewLabel': 'Photo {index}',
    'profileLoadErrorTitle': 'We couldn’t load your profile',
    'profileLoadErrorMessage': 'Check your connection and try again.',
    'profileSyncStaleTitle': 'Profile data may be out of date',
    'profileSyncStaleMessage':
        'We couldn’t refresh your profile. Showing the last saved version.',
    'profileSelectAtLeastOneSkill': 'Select at least one skill',
    'profileShowOriginalButton': 'Show original',
    'profileTitle': 'Profile',
    'profileTranslateButton': 'Translate',
    'profileUnknownIntent': 'Unknown Intent',
    'profileVerification': 'Profile Verification',
    'profileVerified': 'Your profile is verified',
    'profileVerifiedBadge': 'Primary Photo Verified',
    'profileVerifiedBadgeFemale': 'Primary Photo Verified',
    'profileVerifiedBadgeNeutral': 'Primary Photo Verified',
    'profileWizardAddPhotoFromCamera': 'Take photo with camera',
    'profileWizardAddPhotoFromGallery': 'Add photo from gallery',
    'profileWizardAddPhotoTooltip': 'Add a photo',
    'profileWizardEditPhotoAction': 'Edit photo',
    'profileWizardRemovePhotoAction': 'Remove photo',
    'profileWizardMovePhotoEarlier': 'Move photo earlier',
    'profileWizardMovePhotoLater': 'Move photo later',
    'profileWizardCompleteSubtitle': 'You are all set and ready to connect',
    'profileWizardCompleteTitle': 'Profile completed!',
    'profileWizardDetailsSubtitle': 'Add the basics to help others find you.',
    'profileWizardDetailsTitle': 'Your Details',
    'profileWizardFrom': 'From',
    'profileWizardGenderAgePreferencesSubtitle':
        'Configure your matching preferences for each of your selected intentions.',
    'profileWizardGenderPreferenceRequired':
        'Please select at least one preferred gender for {intent}.',
    'profileWizardErrorLoadingIntents': 'Error loading intents',
    'profileWizardErrorLoadingInterests': 'Error loading interests',
    'profileWizardReferenceDataErrorMessage':
        'We couldn’t load the profile options. Try again.',
    'profileWizardRecoveryMessage':
        'Your progress is still here. Check your connection and try again.',
    'profileWizardLogoutBody':
        'You can log out now and continue your profile setup later from where you left off.',
    'profileWizardLogoutTitle': 'Log out and finish later?',
    'profileWizardNewPhotosAdded': 'New photos added',
    'profileWizardNoIntents': 'Please select at least one intent',
    'profileWizardNoPhotos': 'No photos added yet',
    'profileWizardPhotoNoFaceDetected':
        'No face was detected in the photo. Please try a clearer photo.',
    'profileWizardPhotoOrderChanged': 'Photo order updated',
    'profileWizardPhotoOrderDesc':
        'Your primary photo is now your first photo.',
    'profileWizardPhotoReorderFailed': 'Failed to reorder photos',
    'profileWizardPhotosAdded': 'Photos added',
    'profileWizardPhotosRemoved': 'Photos removed',
    'profileWizardPhotosTip':
        'Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.',
    'profileWizardPhotosTitle': 'Add Photos',
    'profileWizardPhotoUploadFailed': 'We couldn\'t add that photo right now.',
    'profileWizardPhotoUploadFailedWithReason':
        'We couldn\'t add that photo. {reason}',
    'profileWizardPhotoPreparing': 'Preparing your photo…',
    'photoIssueDocument': 'ID card / document',
    'photoIssueFace': 'Face',
    'photoIssueMeme': 'Meme',
    'photoIssueScreenshot': 'Screenshot',
    'photoIssueText': 'Text overlay',
    'photoIssueWatermark': 'Watermark',
    'photoRejectedTitle': 'Photo not approved',
    'photoRejectedTryAgain': 'Try again',
    'photoRejectedPrimaryKept': 'Your current primary photo was kept.',
    'profileWizardPhotoUploading': 'Uploading and verifying your photo…',
    'profileWizardCompletingProfile': 'Setting up your profile…',
    'profileWizardPrimaryPhotoBadge': 'Primary Photo',
    'profileWizardPrimaryPhotoFaceOnlyBody':
        'Your first photo must be a clear solo face photo of you. Additional photos must show a real person and cannot be screenshots, memes, prominent text, watermarks, or explicit content.',
    'profileWizardPrimaryPhotoFaceOnlyTitle': 'Photo rules',
    'profileWizardRemoveLanguageTooltip': 'Remove language',
    'profileWizardSelectLanguagesAndSkills': 'Select languages and skills',
    'profileWizardTo': 'To',
    'profileWizardUploadPhotoRequired': 'Please upload at least one photo',
    'profileWizardLastPhotoRequired':
        'Your profile must keep at least one photo. Add a new photo before removing this one.',
    'profileYourAge': 'Your age',
    'promoCodeAlreadyUsed': 'You have already used this code',
    'promoCodeApplied': 'Promo Code Applied',
    'promoCodeApplyBtn': 'Apply',
    'promoCodeButtonExpired': 'Code Expired',
    'promoCodeCurrentDiscount': 'Current Discount',
    'promoCodeDescription':
        'Apply a promotional or discount code to get a special offer',
    'promoCodeEmpty': 'Please enter a promo code',
    'promoCodeExpired': 'This promo code has expired',
    'promoCodeExpiresIn': 'Expires in {days} days',
    'promoCodeExpiresInHours': 'Expires in {hours} hours',
    'promoCodeExpiresToday': 'Expires today',
    'promoCodeGlobalLimitReached':
        'This promo code has reached its usage limit',
    'promoCodeInvalid': 'Invalid or expired promo code',
    'promoCodeInvalidFallback': 'Invalid promo code',
    'promoCodeLabel': 'Promo Code',
    'promoCodeLimitReached':
        'You have already used this promo code the maximum number of times',
    'promoCodeNoExpiry': 'No expiry',
    'promoCodeNotApplicable':
        'This promo code is not applicable for your selected tier',
    'promoCodeNotApplicableForTier':
        'This promo code is not applicable for the {tier} tier',
    'promoCodeNotYetValid': 'This promo code is not yet valid',
    'promoCodePlaceholder': 'Enter promo code',
    'promoCodeRegularPrice': 'Regular Price',
    'promoCodeRemove': 'Remove',
    'promoCodeRemoveQuestion': 'Remove this promo code?',
    'promoCodeSavings': 'You save',
    'promoCodeSection': 'Promo Code',
    'promoCodeStatusExpired': 'Expired',
    'promoCodeUnlimitedUses': 'Unlimited uses',
    'promoCodeUseCount': '{used} of {max} uses remaining',
    'promoCodeValid': 'Promo code applied successfully!',
    'promoCodeValidation': 'Validating code...',
    'promoCodeValidationError': 'Error validating code: {error}',
    'promoCodeYouPay': 'You Pay',
    'promoDiscountFixedFormat': '{amount} Off',
    'promoDiscountFreeDaysFormat': '{days} days Free',
    'promoDiscountPercentageFormat': '{amount}% Off',
    'promoDiscountSpecialOffer': 'Special Offer',
    'promoDiscountTierUpgradeFormat': 'Upgrade to {tier}',
    'Proximity': 'Proximity',
    'pushMessagesTitle': '{count} messages from {name}',
    'pushNewMatchBody': 'You matched with {name}',
    'pushNewMatchTitle': 'New match!',
    'pushNewMessageBodyFallback': 'New message',
    'pushNewMessageTitleFallback': 'New message',
    'pushOpenToReadBody': '{count} unread - open to read',
    'quickReview': 'Quick review',
    'quickReviewDescription': 'Verification typically takes 1-2 business days',
    'rangeFrom': 'From',
    'rangeTo': 'To',
    'rating_q1': 'Profile Accuracy',
    'rating_q2': 'Punctuality',
    'rating_q3': 'Conversation',
    'rating_q4': 'Respect & Manners',
    'rating_q5': 'Safety',
    'ratingHeaderAccuracy': 'Profile Accuracy',
    'ratingHeaderCommunication': 'Communication',
    'ratingHeaderReliability': 'Reliability',
    'ratingHeaderRespect': 'Respect and Consideration',
    'ratingHeaderSafety': 'Safety and Comfort',
    'ratingNotEnoughData': 'Not enough ratings yet',
    'ratingOverall': 'Final rating',
    'ratingPromptBody': 'Did you meet {name} in real life?',
    'ratingPromptContent': 'Did you meet {name} in real life?',
    'ratingPromptLater': 'Later',
    'ratingPromptNo': 'No',
    'ratingPromptTitle': 'Rate your match',
    'ratingPromptYes': 'Yes',
    'ratingQ1Communication':
        'How well did this person communicate before and during the meetup?',
    'ratingQ2Reliability':
        'How reliable was this person (showed up as planned / on time)?',
    'ratingQ3Respect':
        'How respectful and considerate was this person during the meetup?',
    'ratingQ4Safety':
        'How safe and comfortable did you feel meeting this person?',
    'ratingQ5Accuracy':
        'How accurately did this person’s profile represent them in real life?',
    'ratingQuestionMeeting': 'How was your meeting with {name}?',
    'ratingRatedBy': 'Rated by {count} users',
    'ratingScorecardTitle': 'Community Rating',
    'ratingScreenTitle': 'Rate {name}',
    'ratingSectionTitle': 'Ratings:',
    'ratingSubmit': 'Submit',
    'ratingSubmitButton': 'Submit Rating',
    'ratingSubtitle':
        'Your feedback helps keep our community safe and high quality.',
    'ratingSuccess': 'Thank you for your feedback!',
    'ratingThanks': 'Thanks for your feedback',
    'ratingTitle': 'Rate Match',
    'ratingVerifiedCount': '{count} verified ratings',
    'read': 'Read',
    'refresh': 'Refresh',
    'rejected': 'Rejected',
    'relationship': 'Relationship',
    'Relationship': 'Relationship',
    'remove': 'Remove',
    'replyingToLabel': 'Replying to',
    'chatReplyYou': 'You',
    'chatSafetyActions': 'Safety actions',
    'chatReplyOriginalUnavailable': 'Original message unavailable',
    'replyToContent': 'Reply content',
    'replyToMessageId': 'Reply to message',
    'replyToSenderId': 'Reply to sender',
    'reportFailed': 'Could not submit report',
    'reportReason': 'What happened?',
    'reportReasonRequired': 'Tell us what happened',
    'reportSubmit': 'Submit report',
    'reportSuccess': 'Report submitted',
    'reportTitle': 'Report user',
    'reportTitleWithName': 'Report {name}',
    'retake': 'Retake',
    'retakePhoto': 'Retake Photo',
    'retry': 'Retry',
    'retryExtractionButton': 'Retry Extraction',
    'romantic': 'Romantic',
    'romantic::casual': 'Casual',
    'romantic::long_term': 'Long-term relationship',
    'romantic::open_relationships': 'Open relationships',
    'romantic::short_term': 'Short-term relationship',
    'salsa': 'Salsa',
    'saveEvent': 'Save event',
    'saveEventButton': 'Save Event',
    'secondaryPhotoVerificationErrorBadContent':
        'Photo contains restricted content.',
    'secondaryPhotoVerificationErrorDocument':
        'ID cards and documents are not allowed in photos. Please use a photo without them.',
    'secondaryPhotoVerificationErrorGeneral':
        'Please use a clear photo of a real person.',
    'secondaryPhotoVerificationErrorNoFaceOrBody':
        'Please use a photo that clearly shows at least a face or a body.',
    'secondaryPhotoVerificationErrorSystem':
        'Unable to verify this photo right now. Please try again.',
    'secondaryPhotoVerificationErrorTextScreenshotOrWatermark':
        'Choose a real photo of yourself with no screenshots, memes, large text, or watermarks.',
    'securityActiveSessions': 'Active Sessions',
    'securityActiveSessionsDescription':
        'View and manage your logged-in devices',
    'securityCenterAuthenticatorCtaCreateCodes': 'Create recovery codes',
    'securityCenterAuthenticatorCtaEnable': 'Enable authenticator',
    'securityCenterAuthenticatorCtaRefreshCodes': 'Refresh recovery codes',
    'securityCenterAuthenticatorCtaTurnOff': 'Turn off authenticator',
    'securityCenterAuthenticatorCtaVerify': 'Verify now',
    'securityCenterAuthenticatorEmailFallback':
        'Email fallback available at {email}',
    'securityCenterAuthenticatorPrimaryOff':
        'Add an authenticator app to protect sensitive account changes.',
    'securityCenterAuthenticatorPrimaryOn':
        'Authenticator protection is on. Sensitive changes ask for verification when needed.',
    'securityCenterAuthenticatorPrimaryVerified':
        'Authenticator protection is on. Sensitive changes ask for verification when needed.',
    'securityCenterAuthenticatorSecondaryOff':
        'Recovery options appear after you enable the authenticator.',
    'securityCenterAuthenticatorSecondaryRecoveryMissing':
        'Create recovery codes so you can recover access if needed.',
    'securityCenterAuthenticatorSecondaryRecoveryReady':
        'Recovery codes are ready if you lose access to your authenticator.',
    'securityCenterBadgeAuthenticatorOff': 'Authenticator off',
    'securityCenterBadgeAuthenticatorOn': 'Authenticator on',
    'securityCenterBadgePasskeyOff': 'No passkey',
    'securityCenterBadgePasskeyOn': 'Passkey added',
    'securityCenterBadgeSessionOther': 'Standard session',
    'securityCenterBadgeSessionPasskey': 'Passkey session',
    'securityCenterCardAuthenticatorEyebrow': 'Authenticator app',
    'securityCenterCardPasskeyEyebrow': 'Passkeys',
    'securityCenterEmailVerificationBody':
        'Use email verification as an alternative authentication method for sensitive actions',
    'securityCenterEmailVerificationSecondary':
        'Verification codes will be sent to {email}',
    'securityCenterHeroBodySetup':
        'Add an authenticator app or passkey to better protect sensitive actions and future sign-ins.',
    'securityCenterHeroBodyStrong':
        'Your account uses both an authenticator and passkey coverage for stronger protection.',
    'securityCenterHeroTitleSetup': 'Strengthen your sign-in protection',
    'securityCenterHeroTitleStrong': 'Strong protection is on',
    'securityCenterLoadFailedBody':
        'The latest authenticator or passkey status could not be loaded right now.',
    'securityCenterLoadFailedHint':
        'Check your connection and try refreshing again.',
    'securityCenterLoadFailedTitle': 'Security details unavailable',
    'securityCenterMetricBackupCodes': 'Recovery codes',
    'securityCenterMetricDevice': 'Device',
    'securityCenterMetricDeviceSupported': 'Supported',
    'securityCenterMetricDeviceUnsupported': 'Unsupported',
    'securityCenterMetricSensitiveActions': 'Sensitive actions',
    'securityCenterMetricSensitiveActionsPending': 'Needs verification',
    'securityCenterMetricSensitiveActionsVerified': 'Ready',
    'securityCenterMetricServer': 'Server',
    'securityCenterMetricServerReady': 'Ready',
    'securityCenterMetricServerSetup': 'Setup required',
    'securityCenterMetricSession': 'Session',
    'securityCenterMetricSessionStandard': 'Standard',
    'securityCenterMetricSessionVerified': 'Verified',
    'securityCenterMetricSignInMethod': 'Sign-in method',
    'securityCenterOfflineNotice':
        'You are offline. Security details may be outdated until the connection returns.',
    'securityCenterPasskeyCtaAddAnother': 'Add another passkey',
    'securityCenterPasskeyCtaCreate': 'Create passkey',
    'securityCenterPasskeyCtaRemoveAll': 'Remove all passkeys',
    'securityCenterPasskeyPrimaryAccountReady':
        'Your account has a passkey for faster, passwordless sign-in.',
    'securityCenterPasskeyPrimaryOff':
        'Add a passkey for faster, more secure sign-in.',
    'securityCenterPasskeyPrimaryReady':
        'Passkeys are ready for faster, passwordless sign-in.',
    'securityCenterPasskeyPrimarySignedIn':
        'You signed in with a passkey on this device.',
    'securityCenterPasskeySecondaryAppNotAvailable':
        'Passkey sign-in isn\'t available in this app on this platform yet.',
    'securityCenterPasskeySecondaryProtected':
        'A passkey is already protecting this account.',
    'securityCenterPasskeySecondaryReady':
        'Create a passkey on this device to sign in without a password.',
    'securityCenterPasskeySecondarySetupRequired':
        'Server configuration is still required before passkeys can be added.',
    'securityCenterPasskeySecondaryUnsupported':
        'This device does not support passkeys.',
    'securityCenterPasskeySessionAccountReady':
        'Your account has a passkey for use on supported devices.',
    'securityCenterPasskeySessionOther':
        'You signed in with {method}. Add a passkey for future sign-ins.',
    'securityCenterPasskeySessionPasskey':
        'This session is already using a passkey.',
    'securityCenterPasskeySessionReady':
        'A passkey is ready for future sign-ins.',
    'securityCenterSettingsEntryBody':
        'Manage your authenticator, passkeys, and recovery options',
    'securityCenterStatusActive': 'Active',
    'securityCenterStatusAdded': 'Added',
    'securityCenterStatusAttention': 'Attention',
    'securityCenterStatusAvailable': 'Available',
    'securityCenterStatusReady': 'Ready',
    'securityCenterStatusRecommended': 'Recommended',
    'securityCenterTitle': 'Security Center',
    'securityContextHelpWhatIsPasskey':
        'A passkey is a secure alternative to passwords using your device\'s biometric or PIN',
    'securityContextHelpWhy2FA':
        '2-factor authentication adds an extra verification step to protect your account',
    'securityContextHelpWhyMultiplePasskeys':
        'Multiple passkeys let you sign in from different devices without storing passwords',
    'securityCurrentDevice': 'Current device',
    'securityCurrentSessionTitle': 'Your Current Session',
    'securityDeviceInfo': 'Device information',
    'securityHowYouSignedIn': 'How you signed in:',
    'securityLevelBasic': 'Basic Security',
    'securityLevelHigh': 'High Security',
    'securityLevelMaximum': 'Maximum Security',
    'securityMethodConnected': 'Connected',
    'securityMethodLastChanged': 'Last changed:',
    'securityMethodNotConnected': 'Not connected',
    'securityPasswordDescription':
        'Reset your password to strengthen your account security',
    'securityPasswordLastChanged': 'Last changed: {date}',
    'securityPasswordNeverChanged': 'Never changed',
    'securityPasswordSection': 'Password',
    'securityRevokeAllSessions': 'Sign out everywhere',
    'securityRevokeOtherSessions': 'Sign out from other devices',
    'securitySessionStarted': 'Session started:',
    'securityShowAllDevices': 'Show all devices',
    'securitySignInHubDescription':
        'Manage your account security and sign-in methods',
    'securitySignInHubTitle': 'Security & Sign-In',
    'securitySignInMethodsDescription': 'Manage how you log in to your account',
    'securitySignInMethodsTitle': 'Sign-In Methods',
    'securityStatusSummaryEnable2FA':
        'Enable 2-factor authentication for additional protection',
    'securityStatusSummarySecure': 'Your account is secure',
    'securityStatusSummarySetupPasskey':
        'Set up a passkey for faster, more secure sign-in',
    'securityStatusSummaryWarning': 'Your account could be more secure',
    'securityTwoFactorDescription':
        'Optional extra verification step for sensitive actions',
    'securityTwoFactorTitle': '2-Factor Authentication',
    'selectTicketPdfImage': 'Select ticket PDF or image',
    'sensitiveActionEmailBody': 'Use this 6-digit code to continue: {code}',
    'sensitiveActionEmailFooter':
        'This code expires in 10 minutes. If you did not request it, you can ignore this email.',
    'sensitiveActionEmailHeading': 'Verify your sensitive action',
    'sensitiveActionEmailSubject': 'Your MatchMe security code',
    'settingsAccountAlreadyDeleted': 'Account already deleted',
    'settingsAccountDeleted': 'Account deleted successfully',
    'settingsAccountManagement': 'Account management',
    'settingsAccountManagementDesc':
        'Change your password, update your email, or delete your account.',
    'settingsAccuracyMeters': 'Accuracy: about {meters} meters',
    'settingsActiveRules': 'Active Rules',
    'settingsAddNewRule': 'Add New Rule',
    'settingsAppDisplay': 'App display',
    'settingsAppDisplayDesc':
        'Adjust language, currency, units, time format, and theme.',
    'settingsAgeRequirementsEnforcement': 'Age requirements enforcement',
    'settingsAuthMethodApple': 'Apple',
    'settingsAuthMethodEmailOtp': 'Email code',
    'settingsAuthMethodFacebook': 'Facebook',
    'settingsAuthMethodGoogle': 'Google',
    'settingsAuthMethodMicrosoft': 'Microsoft',
    'settingsAuthMethodPasskey': 'Passkey',
    'settingsAuthMethodPassword': 'Password',
    'settingsAuthMethodSmsOtp': 'SMS code',
    'settingsAuthMethodUnknown': 'Unknown',
    'settingsChangeEmailCancel': 'Cancel',
    'settingsChangeEmailCode': 'Verification Code',
    'settingsChangeEmailCodeExpired':
        'Verification code has expired. Please request a new one.',
    'settingsChangeEmailCodeExpires': 'Code expires in',
    'settingsChangeEmailCodeResent':
        'Verification code resent to your new email.',
    'settingsChangeEmailCodeSent':
        'Verification code sent to your new email address.',
    'settingsChangeEmailCurrentEmail': 'Current Email',
    'settingsChangeEmailDescription':
        'You\'ll need to verify your identity with MFA and confirm your new email address.',
    'settingsChangeEmailEmailInUse': 'This email address is already in use',
    'settingsChangeEmailError':
        'Failed to change email address. Please try again.',
    'settingsChangeEmailInvalidCode':
        'Invalid verification code. Please try again.',
    'settingsChangeEmailInvalidEmail': 'Please enter a valid email address.',
    'settingsChangeEmailMfaRequired':
        'MFA verification required to change email.',
    'settingsChangeEmailNewEmail': 'New Email Address',
    'settingsChangeEmailNewEmailHint': 'Enter your new email address',
    'settingsChangeEmailResendCode': 'Resend Code',
    'settingsChangeEmailSameEmail':
        'New email must be different from current email.',
    'settingsChangeEmailSendCode': 'Send Verification Code',
    'settingsChangeEmailStep1Description':
        'We need to verify you with MFA before changing your email.',
    'settingsChangeEmailStep1Title': 'Step 1: Verify Your Identity',
    'settingsChangeEmailStep2Description':
        'We\'ve sent a verification code to your new email address. Enter it below to confirm.',
    'settingsChangeEmailStep2Title': 'Step 2: Confirm New Email',
    'settingsChangeEmailSuccess': 'Email address changed successfully!',
    'settingsChangeEmailTitle': 'Change Email Address',
    'settingsChangeEmailVerificationCode': 'Verification Code',
    'settingsChangeEmailVerificationCodeHint': 'Enter the 6-digit code',
    'settingsChangeEmailVerify': 'Verify and Change Email',
    'settingsChangeEmailVerifyCode': 'Verify Code',
    'settingsChangeEmailVerifyCodeDescription':
        'We\'ve sent a verification code to your new email address. Enter it below to confirm the change.',
    'settingsChangeEmailVerifyCodeTitle': 'Verify Your New Email',
    'settingsChangePassword': 'Change Password',
    'settingsConfirmNewPassword': 'Confirm New Password',
    'settingsConsiderIncreasingRadius':
        'Consider increasing the radius for better results',
    'settingsCurrencyPreference': 'Currency',
    'settingsCurrencyPreferenceDesc':
        'Used for subscription prices and supported checkout flows.',
    'settingsCurrentPassword': 'Current Password',
    'settingsCurrentSignInMethodDescription':
        'This shows how your current session was authenticated.',
    'settingsCurrentSignInMethodTitle': 'Current Sign-In Method',
    'settingsDateRangeRules': 'Date range rules',
    'settingsDateTimePrefix': 'Date and time range',
    'settingsDateTimeRange': 'Date & time range',
    'settingsDateTimeRangeDesc':
        'Set visibility for a specific date and time range',
    'settingsDateTimeRangeRuleAdded': 'Date and time visibility rule added',
    'settingsDateTimeRangeRules': 'Date & time range rules',
    'settingsDayOfWeekRuleAdded': 'Day-of-week visibility rule added',
    'settingsDayOfWeekRules': 'Day of week rules',
    'settingsDays': 'Days',
    'settingsDaysTimePrefix': 'Day and time range',
    'settingsDayTimeRange': 'Day & time range',
    'settingsDayTimeRangeDesc': 'Set visibility for specific days and times',
    'settingsDayTimeRangeRuleAdded': 'Day and time visibility rule added',
    'settingsDayTimeRangeRules': 'Day & time range rules',
    'settingsDeleteAccount': 'Delete Account',
    'settingsDeleteAccountConfirm':
        'Are you sure you want to delete your account? This action cannot be undone.',
    'settingsDeleteAccountFailed': 'Failed to delete account',
    'settingsEditDateTimeRange': 'Edit date and time range',
    'settingsEditDateTimeRangeDesc':
        'Update when this visibility rule should be active based on date and time.',
    'settingsEditDayTimeRange': 'Edit day and time range',
    'settingsEditDayTimeRangeDesc':
        'Update on which days and at what times this visibility rule should be active.',
    'settingsEditLocationRule': 'Edit location rule',
    'settingsEmailVerification': 'Email Verification',
    'settingsEnd': 'End',
    'settingsEndTime': 'End time',
    'settingsEnforcementDetailsTooltip': 'Enforcement details',
    'settingsEnforcementHelpBody':
        'Controls how strictly preferences are applied',
    'settingsEnforcementHelpTitle': 'Enforcement mode',
    'settingsEnforcementMode': 'Enforcement mode',
    'settingsEnforcementFlexibleLabel': 'Show matches outside preferences too',
    'settingsEnforcementStrictLabel': 'Only show matches within preferences',
    'settingsEnforcementFlexibleShort': 'Allow exceptions',
    'settingsEnforcementStrictShort': 'Strict only',
    'settingsEnforcementTooltip':
        'When enabled, you will only see people who match your exact preferences. When disabled, we may show you people slightly outside your range to help you make more connections.',
    'settingsEnforcementTooltipShort':
        'Strict only: Only shows matches within your exact preferences. Allow exceptions: Shows matches outside preferences when no better options are available.',
    'settingsEnforcementImpactFlexible': 'This expands your potential matches',
    'settingsEnforcementImpactStrict': 'This may reduce your match pool',
    'settingsFlexibleLabel': 'Flexible',
    'settingsGenderAgePreferences': 'Gender & Age Preferences',
    'settingsGenderAgePreferencesDesc':
        'Choose which genders and age ranges you want to match with.',
    'settingsGenderAgePreferencesIntro':
        'Set who you would like to see for each of your relationship goals. You can have different preferences for different intents.',
    'settingsGenderRequirementsEnforcement': 'Gender requirements enforcement',
    'settingsGettingPreciseLocation': 'Trying to get your precise location…',
    'settingsGoPremium': 'Go Premium',
    'settingsGpsRate': 'Location update frequency',
    'settingsGpsRateOption': '{rate} {unit}',
    'settingsGpsRateUnit': 'seconds',
    'settingsGpsRateUpdated': 'Location update frequency saved',
    'settingsGpsRateUpdateFailed': 'Failed to update GPS refresh rate',
    'settingsHighAccuracyMode': 'Background Matching Mode',
    'settingsHighAccuracyModeDesc':
        'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.',
    'settingsHighAccuracyModeDesc_android':
        'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.\n• Requires a persistent notification so the system keeps the app running.',
    'settingsHighAccuracyModeDesc_ios':
        'Keep matching even after closing the app. Your location updates periodically in the background so you stay visible to potential matches.\n• Requires background location permission (Allow Always). If iOS fully stops the app, updates resume automatically when you move again.',
    'settingsHighAccuracyModeDesc_web':
        'Background matching is not supported on web. Matching only works while the app is open.',
    'settingsBackgroundMatchingTurnOff': 'Turn Off',
    'settingsBackgroundStatusOnTitle': 'Background Matching is on',
    'settingsBackgroundStatusOnDescription':
        'MatchMe can keep looking for matches while the app is closed.',
    'settingsBackgroundStatusOffTitle': 'Background Matching is off',
    'settingsBackgroundStatusOffDescription':
        'Closed-app matching is limited while Background Matching is off.',
    'settingsBackgroundStatusPermissionTitle': 'Permission needed',
    'settingsBackgroundStatusPermissionDescription':
        'Allow location access in system settings to keep matching in the background.',
    'settingsBackgroundStatusCheckingTitle': 'Checking Background Matching',
    'settingsBackgroundStatusCheckingDescription':
        'Confirming your background location permission…',
    'settingsBackgroundStatusWebTitle': 'Unavailable on web',
    'settingsBackgroundStatusWebDescription':
        'Background Matching works on mobile; on web, matching only works while the app is open.',
    'settingsInvisibilityRules': 'Invisibility rules',
    'settingsInvisibilityRulesDesc':
        'Manage when you appear Invisible based on location, schedule, or custom rules.',
    'settingsInvisibilityRulesTitle': 'Your invisibility rules',
    'settingsLocationName': 'Location name',
    'settingsLocationNameHint': 'For example: Home, Office, Gym',
    'settingsLocationPrefix': 'Location rules',
    'settingsLocationRadiusDesc': 'Visibility radius around this location',
    'settingsLocationRuleAdded': 'Location-based visibility rule added',
    'settingsLocationRules': 'Location rules',
    'settingsLocationRulesDesc': 'Control visibility based on location',
    'settingsLocationRuleUpdated': 'Location rule updated',
    'settingsLocationSuccess': 'Location rule saved successfully',
    'settingsManageSubscription': 'Manage',
    'settingsMatching': 'Matching',
    'settingsProfileUnavailableTitle': 'Profile settings unavailable',
    'settingsProfileUnavailableMessage':
        'We couldn’t load your profile settings. Try again to continue.',
    'settingsLoadErrorTitle': 'We couldn’t load Settings',
    'settingsLoadErrorMessage':
        'Check your connection and try again. Other cached settings may still be available.',
    'settingsMatchingDesc':
        'Configure match radius, GPS settings, and sharing preferences.',
    'settingsMfaChallengeBody': 'Enter your 6-digit authentication code',
    'settingsMfaChallengeFailed': 'Verification failed. Please try again.',
    'settingsMfaChallengeInvalid': 'Invalid code. Please try again.',
    'settingsMfaChallengeNotVerified': 'Verification failed',
    'settingsMfaChallengeTitle': 'Verify with 2FA',
    'settingsMfaCode': 'Authentication code',
    'settingsMfaCodeInvalid': 'Invalid code. Please try again.',
    'settingsMfaCopied': 'Code copied to clipboard',
    'settingsMfaCopySecret': 'Copy secret',
    'settingsMfaCurrentSessionNotVerified': 'Current session not verified',
    'settingsMfaCurrentSessionVerified': 'Current session verified',
    'settingsMfaDescription':
        'Protect sensitive account actions with one-time codes from your authenticator app.',
    'settingsMfaDisable': 'Disable',
    'settingsMfaDisableConfirm':
        'Disable multi-factor authentication for your account? Sensitive actions will only require your password.',
    'settingsMfaDisabled': 'Disabled',
    'settingsMfaDisableFailed': 'Failed to disable authenticator app',
    'settingsMfaDisableSuccess': 'Authenticator app disabled',
    'settingsMfaEmailCode': 'Email code',
    'settingsMfaEmailCodeBody': 'Enter the code we sent to {email}',
    'settingsMfaEmailCodeEnter': 'Please enter a valid 6-digit code',
    'settingsMfaEmailCodeResend': 'Resend Email',
    'settingsMfaEmailCodeResendIn': 'Resend in {seconds} seconds',
    'settingsMfaEmailCodeSend': 'Email me a code',
    'settingsMfaEmailCodeSendBody': 'Enter the code sent to your email',
    'settingsMfaEmailCodeSendFailed': 'Failed to send verification email',
    'settingsMfaEmailCodeSent': 'Code sent to {email}',
    'settingsMfaEmailCodeVerifyFailed': 'Invalid or expired code',
    'settingsMfaEmailFallbackAvailable': 'Email backup available: {email}',
    'settingsMfaEnable': 'Enable',
    'settingsMfaEnabled': 'Enabled',
    'settingsMfaEnrollmentFailed': 'Failed to start authenticator app setup',
    'settingsMfaEnrollmentSuccess': 'Authenticator app enabled',
    'settingsMfaEnterCode': 'Enter a valid 6-digit code',
    'settingsMfaInitializing': 'Setting up authenticator app...',
    'settingsMfaManualEntryBody':
        'If scanning is not available, choose manual setup in your authenticator app and paste this key.',
    'settingsMfaManualEntryTitle': 'Or enter the setup key manually',
    'settingsMfaNotEnabled': '2-Factor authentication is not enabled',
    'settingsMfaOpenAuthenticator': 'Open Authenticator App',
    'settingsMfaOpenAuthenticatorBody':
        'Open your authenticator app to add this account',
    'settingsMfaOpenAuthenticatorFailed':
        'Could not open an authenticator app. Use the QR code or setup key below instead.',
    'settingsMfaQrBody':
        'Best when your authenticator app is on another device.',
    'settingsMfaQrTitle': 'Scan QR code',
    'settingsMfaRecoveryCode': 'Recovery code',
    'settingsMfaRecoveryCodeBody':
        'Enter one of your saved recovery codes to continue. Each recovery code can only be used once.',
    'settingsMfaRecoveryCodeEnter': 'Enter a valid recovery code',
    'settingsMfaRecoveryCodeInvalid': 'Invalid recovery code',
    'settingsMfaRecoveryCodesAndEmailDescription':
        'Recovery codes are one-time backup codes. If you cannot access them, you can also request a one-time code by email at {email}.',
    'settingsMfaRecoveryCodesAndEmailUsageHint':
        'If you lose access to your authenticator app, start a protected action and choose "Use recovery code instead" or "Use email code instead" in the verification dialog.',
    'settingsMfaRecoveryCodesCopied': 'Recovery codes copied',
    'settingsMfaRecoveryCodesCopy': 'Copy codes',
    'settingsMfaRecoveryCodesCount': '{count} recovery codes ready',
    'settingsMfaRecoveryCodesDescription':
        'Recovery codes are one-time backup codes you can use if you lose access to your authenticator app.',
    'settingsMfaRecoveryCodesDialogBody':
        'Store these recovery codes somewhere safe. Each code can be used once if your authenticator app is unavailable.',
    'settingsMfaRecoveryCodesDialogRegeneratedBody':
        'Your previous recovery codes no longer work. Save this new set somewhere safe before you continue.',
    'settingsMfaRecoveryCodesDialogTitle': 'Save your recovery codes',
    'settingsMfaRecoveryCodesGenerate': 'Generate recovery codes',
    'settingsMfaRecoveryCodesGenerated': 'Recovery codes generated',
    'settingsMfaRecoveryCodesGenerateFailed':
        'Failed to generate recovery codes',
    'settingsMfaRecoveryCodesMissing': 'No recovery codes saved',
    'settingsMfaRecoveryCodesRegenerate': 'Regenerate recovery codes',
    'settingsMfaRecoveryCodesRegenerateConfirm':
        'Generate a new set of recovery codes? Any previous recovery codes will stop working immediately.',
    'settingsMfaRecoveryCodesRegenerated': 'Recovery codes regenerated',
    'settingsMfaRecoveryCodesUsageHint':
        'If you lose access to your authenticator app, start a protected action and choose "Use recovery code instead" in the verification dialog.',
    'settingsMfaRecoveryCodeTitle': 'Recovery Codes',
    'settingsMfaSecret': 'Secret key',
    'settingsMfaSecretMissing': 'Failed to retrieve authenticator secret',
    'settingsMfaSetupBody':
        'Open your authenticator app, scan the QR code or enter the setup key, then enter the 6-digit code it generates.',
    'settingsMfaSetupInstruction':
        'Scan the QR code with your authenticator app, or enter the code manually',
    'settingsMfaSetupTitle': 'Set up authenticator app',
    'settingsMfaTitle': 'Two-factor authentication',
    'settingsMfaUpdate': 'Update 2FA',
    'settingsMfaUseAuthenticatorCode': 'Use authenticator code instead',
    'settingsMfaUseEmailCode': 'Use email code instead',
    'settingsMfaUseRecoveryCode': 'Use recovery code instead',
    'settingsMfaVerificationFailed': 'Invalid verification code',
    'settingsMfaVerificationSuccess': 'Verification successful',
    'settingsMfaVerify': 'Verify now',
    'settingsMfaVerifySensitiveAction': 'Verify your identity',
    'settingsMfaVerifySensitiveActionBody':
        'Enter the 6-digit code from your authenticator app to continue.',
    'settingsMobileGpsAccuracy': 'Mobile GPS accuracy',
    'settingsNewPassword': 'New Password',
    'settingsNoDateRangeRules': 'No date range rules configured',
    'settingsNoDayOfWeekRules': 'No day of week rules configured',
    'settingsNoIntentsSelected': 'At least one intent must be selected',
    'settingsNoLocationRules': 'No location rules configured',
    'settingsNotificationPreferences': 'Notification Preferences',
    'settingsNotifications': 'Notifications',
    'settingsNotificationsAdmin': 'Admin Announcements',
    'settingsNotificationsAdminDesc':
        'Receive important announcements from the app',
    'settingsNotificationsAdminInApp': 'Admin in-app',
    'settingsNotificationsAdminInAppDesc':
        'Show admin announcements inside the app',
    'settingsNotificationsAdminSound': 'Admin sound',
    'settingsNotificationsAdminSoundDesc': 'Play sound for admin announcements',
    'settingsNotificationsAdminVibration': 'Admin vibration',
    'settingsNotificationsAdminVibrationDesc':
        'Vibrate for admin announcements',
    'settingsNotificationsAdvanced': 'Advanced',
    'settingsNotificationsChatInApp': 'Chat in-app',
    'settingsNotificationsChatInAppDesc':
        'Show chat notifications inside the app',
    'settingsNotificationsChatMessages': 'Chat Messages',
    'settingsNotificationsChatMessagesDesc':
        'Get notified when you receive new messages',
    'settingsNotificationsChatSound': 'Chat sound',
    'settingsNotificationsChatSoundDesc': 'Play sound for chat notifications',
    'settingsNotificationsChatVibration': 'Chat vibration',
    'settingsNotificationsChatVibrationDesc': 'Vibrate for chat notifications',
    'settingsNotificationsDesc':
        'Manage how and when you receive notifications',
    'settingsNotificationsInApp': 'In-App Notifications',
    'settingsNotificationsInAppDesc': 'Show notifications within the app',
    'settingsNotificationsInfo':
        'You can manage system notification permissions in your device settings.',
    'settingsNotificationsMatchExpiry': 'Match Expiry Alerts',
    'settingsNotificationsMatchExpiryDesc':
        'Get notified when matches are about to expire',
    'settingsNotificationsMatchExtended': 'Match Extended',
    'settingsNotificationsMatchExtendedDesc':
        'Get notified when someone gives you more time to say hi',
    'settingsNotificationsMatchInApp': 'Match in-app',
    'settingsNotificationsMatchInAppDesc':
        'Show match notifications inside the app',
    'settingsNotificationsMatchSound': 'Match sound',
    'settingsNotificationsMatchSoundDesc': 'Play sound for match notifications',
    'settingsNotificationsMatchVibration': 'Match vibration',
    'settingsNotificationsMatchVibrationDesc':
        'Vibrate for match notifications',
    'settingsNotificationsMatrixTitle': 'Notification methods',
    'settingsNotificationsMatrixType': 'Type',
    'settingsNotificationsMeetupTools': 'Meet-up alerts',
    'settingsNotificationsMeetupToolsDesc':
        'Waves, beacons, Spot me cards and meeting-point updates from your matches',
    'settingsNotificationsMethodBrowser': 'Browser',
    'settingsNotificationsMethodBrowserDesc':
        'A browser notification (Chrome/Safari), even when the tab is not focused.',
    'settingsNotificationsMethodInApp': 'In App',
    'settingsNotificationsMethodInAppDesc':
        'A banner inside MatchMe while you are using the app.',
    'settingsNotificationsMethodPush': 'Push',
    'settingsNotificationsMethodPushDesc':
        'A system notification on your phone, even when the app is closed.',
    'settingsNotificationsMethodSoundDesc':
        'Plays a sound when a notification appears.',
    'settingsNotificationsMethodVibrationDesc':
        'Vibrates your device when a notification appears.',
    'settingsNotificationsMuteAll': 'Mute all notifications',
    'settingsNotificationsMuteAllDesc':
        'Temporarily or permanently silence all notifications',
    'settingsNotificationsMuteAllOff': 'Off',
    'settingsNotificationsMutedForever': 'Muted forever',
    'settingsNotificationsMutedInfo':
        'Notifications are currently muted. Turn off "Mute all" to edit other settings.',
    'settingsNotificationsMutedUntilValue': 'Muted until {value}',
    'settingsNotificationsMuteForever': 'Mute forever',
    'settingsNotificationsMutePickTime': 'Pick time',
    'settingsNotificationsMuteQuick1h': '1 hour',
    'settingsNotificationsMuteQuick24h': '24 hours',
    'settingsNotificationsMuteQuick8h': '8 hours',
    'settingsNotificationsMuteUntil': 'Mute until…',
    'settingsNotificationsNewMatches': 'New matches',
    'settingsNotificationsPause15m': 'Pause for 15 minutes',
    'settingsNotificationsPause30m': 'Pause for 30 minutes',
    'settingsNotificationsPause5m': 'Pause for 5 minutes',
    'settingsNotificationsSettingsDesc': 'Control notification preferences',
    'settingsNotificationsSound': 'Sound',
    'settingsNotificationsSoundDesc': 'Play sound for notifications',
    'settingsNotificationsTitle': 'Notification Preferences',
    'settingsNotificationsPreviewTitle': 'Show message previews on this device',
    'settingsNotificationsPreviewDesc':
        'Decrypt and show message content in notifications on this device only',
    'settingsNotificationsVibration': 'Vibration',
    'settingsNotificationsVibrationDesc': 'Vibrate for notifications',
    'settingsNotificationTypes': 'Notification Types',
    'settingsNoTimeRangeRules': 'No time range rules configured',
    'settingsPasskeyAdd': 'Add Passkey',
    'settingsPasskeyAddAnother': 'Add Another Passkey',
    'settingsPasskeyAdded': 'Passkey added successfully',
    'settingsPasskeyAddedForFutureSignIn':
        'Passkey added. You can use it the next time you sign in.',
    'settingsPasskeyAddFailed':
        'Could not add a passkey right now. Please try again.',
    'settingsPasskeyAlreadyRegistered':
        'This passkey is already registered on your device. You can manage your passkeys in settings.',
    'settingsPasskeyCurrentSessionOther':
        'You are signed in with {method}. Add a passkey to make future sign-ins faster and more secure.',
    'settingsPasskeyCurrentSessionPasskey':
        'You are already signed in with a passkey on this session.',
    'settingsPasskeyDescription':
        'Add a passkey to this account so you can sign in faster and more securely on supported devices.',
    'settingsPasskeyEnrollFailed': 'Failed to add passkey',
    'settingsPasskeyEnrollSuccess': 'Passkey added successfully',
    'settingsPasskeyReady': 'Ready to add on this device.',
    'settingsPasskeyRemove': 'Remove Passkey',
    'settingsPasskeyRemoveConfirm':
        'Remove all passkeys from your account? You\'ll need to use another sign-in method.',
    'settingsPasskeyRemoved': 'All passkeys removed successfully',
    'settingsPasskeyRemoveDialogCancel': 'Keep Passkey',
    'settingsPasskeyRemoveDialogConfirm': 'Remove All Passkeys',
    'settingsPasskeyRemoveDialogMessage':
        'This will remove all registered passkeys. You\'ll need to sign in with your password or another authentication method.',
    'settingsPasskeyRemoveDialogTitle': 'Remove Passkey?',
    'settingsPasskeyRemoveDialogWarning': 'This action cannot be undone.',
    'settingsPasskeyRemoveFailed': 'Failed to remove passkey',
    'settingsPasskeyRemoveSuccess': 'Passkey removed successfully',
    'settingsPasskeyRevoke': 'Delete all passkeys',
    'settingsPasskeyRevokeConfirm':
        'Are you sure you want to delete all your passkeys? You will need to use another sign-in method.',
    'settingsPasskeyRevoked': 'All passkeys deleted successfully',
    'settingsPasskeyRevokeFailed':
        'Failed to delete passkeys. Please try again.',
    'settingsPasskeyStatusAddedThisSession': 'Added in this session',
    'settingsPasskeyStatusCurrentSession': 'Current session: {method}',
    'settingsPasskeyStatusReady': 'Ready on this device',
    'settingsPasskeyStatusSetupRequired': 'Needs server setup',
    'settingsPasskeyStatusUnsupported': 'Not supported on this device',
    'settingsPasskeyTitle': 'Passkey',
    'settingsPasswordChanged': 'Password changed successfully',
    'settingsPasswordChangeFailed': 'Failed to change password',
    'settingsPasswordChangeSuccess': 'Password changed successfully',
    'settingsPasswordMismatch': 'Passwords do not match',
    'settingsPasswordReauthBody': 'Enter your new password',
    'settingsPasswordReauthSentGeneric': 'Verification code sent',
    'settingsPreferencesSaved': 'Preferences saved successfully',
    'settingsPreferencesSaveFailed': 'Failed to save preferences',
    'settingsPreferredAgeRange': 'Preferred age range',
    'settingsPreferredGenders': 'Preferred genders',
    'settingsMatchPreferences': 'Match Preferences',
    'settingsMatchPreferencesDesc':
        'Customize your matching preferences for each relationship goal.',
    'settingsMatchPreferencesIntro':
        'Customize who you see for each relationship goal beyond gender and age.',
    'settingsCopyFromProfile': 'Copy from my profile',
    'settingsCopyFromProfileHint':
        'Use your own profile values as filters for this intent.',
    'settingsUnsavedChangesTitle': 'Unsaved Changes',
    'settingsUnsavedChangesMessage':
        'You have unsaved changes. What would you like to do?',
    'settingsLifestyleFilters': 'Lifestyle Filters',
    'settingsSmoking': 'Smoking',
    'settingsSmokingAny': 'Any',
    'settingsSmokingNever': 'Non-smoker',
    'settingsSmokingOk': 'Smoker OK',
    'settingsDrinking': 'Drinking',
    'settingsDrinkingAny': 'Any',
    'settingsDrinkingNever': 'Non-drinker',
    'settingsDrinkingOk': 'Drinker OK',
    'settingsDiet': 'Diet',
    'settingsDietAny': 'Any',
    'settingsDietVegetarian': 'Vegetarian',
    'settingsDietVegan': 'Vegan',
    'settingsDietHalal': 'Halal',
    'settingsDietKosher': 'Kosher',
    'settingsExercise': 'Exercise',
    'settingsExerciseAny': 'Any',
    'settingsExerciseActive': 'Active',
    'settingsExerciseNotActive': 'Not active',
    'settingsFamilyFilters': 'Family Filters',
    'settingsHasChildren': 'Has Children',
    'settingsHasChildrenAny': 'Any',
    'settingsHasChildrenYes': 'Has kids',
    'settingsHasChildrenNo': 'No kids',
    'settingsWantsChildren': 'Wants Children',
    'settingsWantsChildrenAny': 'Any',
    'settingsWantsChildrenYes': 'Wants',
    'settingsWantsChildrenNo': 'Doesn\'t want',
    'settingsWantsChildrenOpen': 'Open',
    'settingsHeightRange': 'Height Range',
    'settingsHeightCm': 'centimeters',
    'settingsBeliefs': 'Beliefs',
    'settingsReligion': 'Religion or belief',
    'settingsReligionAny': 'Any',
    'settingsDenomination': 'Denomination or branch',
    'settingsPractice': 'Religious practice',
    'settingsSameReligionOnly': 'Same religion only',
    'settingsPremiumActive': 'Premium Active',
    'settingsPremiumThanks': 'Thanks for your support!',
    'settingsPrioritizeEnforcement': 'Prioritize preferences',
    'settingsRadius': 'Radius',
    'settingsRadiusUpdateFailed': 'Failed to update search radius',
    'settingsRuleExpired': 'This rule has expired',
    'settingsSectionAccount': 'Account',
    'settingsSectionGeneral': 'General',
    'settingsSectionMatching': 'Matching & discovery',
    'settingsSectionPremium': 'Premium',
    'settingsSelectDate': 'Select Date',
    'settingsSelectEndDate': 'Select end date',
    'settingsSelectStartDate': 'Select start date',
    'settingsSensitiveActionRequiresMfaSetup':
        'Set up an authenticator app or a passkey before changing this security setting.',
    'settingsSharedEventMatching': 'Shared event matching',
    'settingsSharedEventMatchingSubtitle':
        'Get matched with people attending the same events as you.',
    'settingsSharedEventMatchingUpdateFailed':
        'Failed to update shared event matching',
    'settingsSharedEventMatchingUpdated':
        'Shared event matching preference updated',
    'settingsSharedMovementMatching': 'Shared movement matching',
    'settingsSharedMovementMatchingSubtitle':
        'When you and another person are detected moving together (similar direction and speed), matching may temporarily look slightly beyond your radius. It returns to normal once the shared movement ends.',
    'settingsSharedMovementMatchingUpdated':
        'Shared movement matching preference updated',
    'settingsRetroMatching': 'Find people you were near without internet',
    'settingsRetroMatchingDesc':
        'If you lose internet — for example in a tunnel, on the subway, or in a crowded place — MatchMe can still remember where you were, and look for people you were near once you are back online.',
    'settingsRetroMatchingUpdated': 'Preference updated',
    'settingsRetroMatchingUpdateFailed': 'Failed to update preference',
    'settingsRetroRetention': 'How long should we remember where you were?',
    'settingsRetroRetentionDesc':
        'Shorter time keeps less about you, but you may miss people who come back later. Longer time finds more people, but remembers where you were for longer.',
    'settingsRetroRetentionExample':
        'Example: Choose 1 day, and we can still find someone from yesterday who only came back today. After that time, this information is deleted automatically.',
    'settingsRetroRetentionUpdated': 'Time updated',
    'settingsRetroDeleteNow': 'Delete my saved places now',
    'settingsRetroDeleteNowConfirm':
        'This permanently deletes your saved places from this device and the server. You will not be able to recover them.',
    'settingsRetroDeleteNowDone': 'Saved places deleted',
    'settingsRetroPending': 'Saved places on this device: {count}',
    'settingsRetroHours': '{count} hours',
    'settingsRetroDays': '{count} days',
    'retroBanner':
        'You were near each other without internet. This match was found after you were back online.',
    'settingsSmartGpsThrottling': 'Smart GPS Throttling',
    'settingsSmartGpsThrottlingDesc':
        'Automatically reduces update frequency to save battery.',
    'settingsSmartGpsThrottlingDesc_android':
        'Automatically reduces update frequency to save battery when:\n• Device is stationary\n• Battery is below 15%',
    'settingsSmartGpsThrottlingDesc_ios':
        'iOS manages power automatically. This setting is disabled.',
    'settingsSmartGpsThrottlingDesc_web':
        'Smart throttling is not available on Web.',
    'settingsSmartGpsThrottlingUpdated': 'Smart GPS throttling setting updated',
    'settingsSmartGpsThrottlingUpdateFailed':
        'Failed to update smart GPS throttling',
    'settingsStart': 'Start',
    'settingsStartTime': 'Start time',
    'settingsStrictEnforcement': 'Strict enforcement',
    'settingsStrictLabel': 'Strict',
    'settingsAmoledMode': 'Pure black (AMOLED)',
    'settingsAmoledModeDescription':
        'Use true black surfaces in dark mode to save battery on OLED screens',
    'settingsThemeMode': 'Theme',
    'settingsThemeModeDark': 'Dark',
    'settingsThemeModeLight': 'Light',
    'settingsThemeModeSystem': 'System default',
    'settingsTimeFormat': 'Time format',
    'settingsTimeFormat12': '12-hour',
    'settingsTimeFormat24': '24-hour',
    'settingsTimeFormatSystem': 'System default',
    'settingsTimeRange': 'Time Range',
    'settingsTimeRangeRules': 'Time range rules',
    'settingsTimesDefaultAllDay': 'All day',
    'settingsTitle': 'Settings',
    'settingsSearch': 'Search settings',
    'settingsSearchHint': 'Find a setting',
    'settingsSearchNoResults': 'No matching settings',
    'settingsTo': 'to',
    'settingsUnits': 'Units',
    'settingsUnitsImperial': 'Imperial',
    'settingsUnitsMetric': 'Metric',
    'settingsUnitsSystem': 'System default',
    'settingsUnlockExclusive': 'Unlock exclusive features',
    'settingsUseCurrentLocation': 'Use current location',
    'settingsWebGpsAccuracy': 'Browser location accuracy',
    'Shared Event': 'Shared Event',
    'sharedEvent': 'Shared event',
    'sharedEventLabel': 'Shared event',
    'sharedInterestsLabel': 'Shared interests',
    'sharedInterestsCount': 'Shared interests: {count}',
    'sharing_skills': 'Skill Sharing',
    'short_term': 'Short-term',
    'showPastEvents': 'Show past events',
    'signIn': 'Sign In',
    'similarityPercentage': '% Similarity',
    'sortByLabel': 'Sort by',
    'sortNewest': 'Newest',
    'sortSharedInterests': 'Shared interests',
    'sortTopRated': 'Top rated',
    'sortExpiringSoon': 'Expiring soon', 'listFiltersTitle': 'Filters',
    'listFilterInterestSection': 'What they are looking for',
    'listFilterGenderSection': 'Gender',
    'listFilterOptionsSection': 'Options',
    'listFilterShowResults': 'Show {count} results',
    'listFilterActiveCount': '{count} active',
    'listSortSection': 'Sort by',
    'sortUnreadFirst': 'Unread first',
    'sortNameAsc': 'Name A–Z',
    'listFilterResultCount': '{count} conversations',
    'listFilterResultCountOf': '{shown} of {total} conversations',
    'matchTypeFilterLabel': 'How you met',
    'matchTypeFilterAllBlurb': 'Everyone',
    'matchTypeFilterProximityBlurb': 'Met nearby',
    'matchTypeFilterEventBlurb': 'Same event',
    'sortOptionNewest': 'Newest',
    'sortOptionMostShared': 'Most shared',
    'sortOptionTopRated': 'Top rated',
    'sortOptionExpiringSoon': 'Ending soon',
    'singing': 'Singing',
    'skill_sharing': 'Skill Sharing',
    'skill_swap': 'Skill Swap',
    'skills_sharing': 'Skill Sharing',
    'social': 'Social',
    'speak': 'Speak',
    'startDate': 'Start date',
    'startTime': 'Start time',
    'startup_founders': 'Startup Founders',
    'startups': 'Startups',
    'startups_founders': 'Startup Founders',
    'study': 'Study',
    'study_and_learning': 'Study & Learning',
    'study_learning': 'Study & Learning',
    'subintent.business.career': 'Career growth & opportunities',
    'subintent.business.clients': 'Find clients & customers',
    'subintent.business.collaboration': 'Collaboration & partnerships',
    'subintent.business.mentorship': 'Mentorship & advice',
    'submitForReview': 'Submit for Review',
    'submitVerificationPhoto': 'Submit Verification Photo',
    'subscriptionTimeLeft': 'Time left',
    'subscriptionTimeLeftActive':
        'Time left in {tier}: {duration} - currently active',
    'subscriptionTimeLeftPending': 'Time left in {tier}: {duration}',
    'subscriptionPlan': 'Subscription Plan',
    'subscriptionCurrent': 'CURRENT',
    'subscriptionUpNext': 'UP NEXT',
    'subscriptionLater': 'LATER',
    'subscriptionTotalRemaining': '{duration} total remaining',
    'supabaseAnonKeyLabel': 'SUPABASE_ANON_KEY',
    'supabaseAnonKeyMissing': 'Supabase anonymous key is missing',
    'supabaseConfigMissing': 'Supabase configuration missing',
    'supabaseInitFailed': 'Failed to initialize the service',
    'supabaseInitFailedBody': 'Please try again.',
    'supabaseUrlLabel': 'SUPABASE_URL',
    'supabaseUrlMissing': 'Supabase URL is missing',
    'supabaseWebQueryExample':
        'http://localhost:5000/?SUPABASE_URL=...&SUPABASE_ANON_KEY=...',
    'supabaseWebQueryTip':
        'Web tip: you can set keys via URL query params and reload:',
    'switchAccount': 'Switch Account',
    'systemLookup': 'Automatic lookup',
    'systemNotificationDismiss': 'Dismiss',
    'systemNotificationOpen': 'Open',
    'takePhoto': 'Take Photo',
    'takingPhotoIn': 'Taking photo in',
    'tango': 'Tango',
    'tapToTakeVerificationPhoto': 'Tap to take a verification photo',
    'thisFeatureComingSoon': 'This feature is coming soon',
    'ticketProcessedSuccessfully': 'Ticket processed successfully',
    'tierBadgeBestValue': 'Best Value',
    'tierBadgePopular': 'Most Popular',
    'tierFree': 'Free',
    'tierGold': 'Gold',
    'tierGoldFeatures':
        '["See who likes you", "Unlimited Likes", "Rewind", "5 Super Likes", "1 Boost a month"]',
    'tierGoldSubtitle': 'See who likes you',
    'tierGoldTitle': 'MatchMe Gold',
    'tierPlatinum': 'Platinum',
    'tierPlatinumFeatures':
        '["Priority Likes", "Message before matching", "See who likes you", "Unlimited Likes"]',
    'tierPlatinumSubtitle': 'Prioritized likes',
    'tierPlatinumTitle': 'MatchMe Platinum',
    'tierPlus': 'Plus',
    'tierPlusFeatures':
        '["Unlimited Likes", "Rewind last swipe", "5 Super Likes a day"]',
    'tierPlusSubtitle': 'Stand out from the crowd',
    'tierPlusTitle': 'MatchMe Plus',
    'timeAfternoon': 'Afternoon',
    'timeAM': 'AM',
    'timeEvening': 'Evening',
    'timeMorning': 'Morning',
    'timeNight': 'Night',
    'timePM': 'PM',
    'translationCoverageWarningBody':
        'Supabase is missing {count} UI text entries for {locale}. The app is showing English fallbacks for those keys.',
    'translationCoverageWarningTitle':
        'Missing translations in selected UI language',
    'travel': 'Travel',
    'travel_buddy': 'Travel buddy',
    'traveling': 'Traveling',
    'underReview': 'Under Review',
    'underReviewDescription':
        'Your verification photo is being reviewed by our team.',
    'understand': 'Understand',
    'unitFeet': 'feet',
    'unitKilometers': 'Kilometers',
    'unitMeters': 'meters',
    'unitMiles': 'Miles',
    // A distance carries its unit in one string so the unit can take the
    // right plural form ("1 foot", not "1 feet").
    'distanceInFeet': '{count} feet',
    'distanceInKilometers': '{count} kilometers',
    'distanceInMeters': '{count} meters',
    'distanceInMiles': '{count} Miles',
    'unmatch': 'Unmatch',
    'unmatchConfirm': 'Are you sure you want to unmatch?',
    'unmatchSuccess': 'You have successfully unmatched.',
    'updateEvent': 'Update Event',
    'uploadTicket': 'Upload ticket',
    'usePhoto': 'Use Photo',
    'venture_capital': 'Venture Capital',
    'venueLocationOptional': 'Venue / location (optional)',
    'verification': 'Verification',
    'verificationAiAnalysisPrefix': 'AI Analysis',
    'verificationApprovedAutomatically': 'Verification approved automatically',
    'verificationApprovedSuccessfully': 'Verification approved successfully',
    'verificationAutoRejected': 'Auto-rejected',
    'verificationCaptureCameraOrModelError': 'Camera or model error: {error}',
    'verificationCaptureCameraPermissionDenied':
        'Camera permission is required to continue.',
    'verificationCaptureChecklistFaceVisible': 'Face visible',
    'verificationCaptureChecklistGestureRecognized': 'Gesture recognized',
    'verificationCaptureChecklistHandPositioned': 'Hand in position',
    'verificationCaptureChecklistLighting': 'Good lighting',
    'verificationCaptureClose': 'Close',
    'verificationCaptureFailedToLoad': 'Failed to load MediaPipe: {error}',
    'verificationCaptureHandLeft': 'left',
    'verificationCaptureHandRight': 'right',
    'verificationCaptureHandLeftBadge': 'Left hand',
    'verificationCaptureHandRightBadge': 'Right hand',
    'verificationCaptureInstruction':
        'Hold your face in the guide and show the requested gesture.',
    'verificationCaptureLoading': 'Loading camera & gesture recognition...',
    'verificationCaptureStatusAlignFace': 'Center your face inside the guide',
    'verificationCaptureStatusCapturingBestFrame': 'Capturing best frame...',
    'verificationCaptureStatusGestureDetected': 'Ready! Hold still for capture',
    'verificationCaptureStatusHoldSteady': 'Great, hold steady...',
    'verificationCaptureStatusPositionHand':
        'Place your hand in the gesture area and show the gesture',
    'verificationCaptureStatusShowFace': 'Make sure your face is visible',
    'verificationCaptureStatusShowGesture': 'Show the required gesture',
    'verificationCaptureStatusTooDark':
        'It’s too dark here — move to a brighter spot',
    'verificationCaptureStatusUseCorrectHand':
        'Wrong hand — use your {hand} hand',
    'verificationCaptureRetry': 'Retry',
    'verificationCaptureWrapperFailedToLoad':
        'Verification capture failed to load: {error}',
    'verificationComparisonMismatchHeader': "What didn't match",
    'verificationComparisonNoBoxes':
        'The AI found differences between your photos but could not mark their exact locations.',
    'verificationComparisonPhotoUnavailable':
        'For privacy, verification photos are deleted 7 days after review. Your verification photo is no longer available.',
    'verificationComparisonProfilePhotoLabel': 'Profile photo',
    'verificationComparisonTitle': 'Photo comparison',
    'verificationComparisonVerificationPhotoLabel': 'Verification photo',
    'verificationGestureClosedFistDescription':
        'Curl the four fingers of your right hand down into your palm and wrap your thumb across the front of them. Keep your wrist straight, your knuckles facing the camera, and hold the fist beside your face.',
    'verificationGestureClosedFistLeftDescription':
        'Curl the four fingers of your left hand down into your palm and wrap your thumb across the front of them. Keep your wrist straight, your knuckles facing the camera, and hold the fist beside your face.',
    'verificationGestureClosedFistLeftTitle':
        'Show a closed fist with your left hand',
    'verificationGestureClosedFistTitle':
        'Show a closed fist with your right hand',
    'verificationGestureCoverMouthDescription':
        'Cover your mouth with your hand while taking the photo',
    'verificationGestureCoverMouthTitle': 'Cover your mouth',
    'verificationGestureHandOnHeadDescription':
        'Place one hand on top of your head',
    'verificationGestureHandOnHeadTitle': 'Place your hand on your head',
    'verificationGestureILoveYouDescription':
        'Show the I love you hand sign with your right hand next to your face.',
    'verificationGestureILoveYouTitle': 'Show the I love you sign',
    'verificationGestureOpenPalmDescription':
        'Hold your right hand up with your palm facing the camera and all five fingers spread apart, pointing upward. Keep every finger straight and fully visible, and hold your hand beside your face.',
    'verificationGestureOpenPalmLeftDescription':
        'Hold your left hand up with your palm facing the camera and all five fingers spread apart, pointing upward. Keep every finger straight and fully visible, and hold your hand beside your face.',
    'verificationGestureOpenPalmLeftTitle':
        'Show an open palm with your left hand',
    'verificationGestureOpenPalmTitle':
        'Show an open palm with your right hand',
    'verificationGesturePeaceSignDescription':
        'Extend the index and middle fingers of your right hand upward in a V shape and press them apart. Curl your ring finger and pinky down into your palm, hold them with your thumb, and keep your palm facing the camera beside your face.',
    'verificationGesturePeaceSignLeftDescription':
        'Extend the index and middle fingers of your left hand upward in a V shape and press them apart. Curl your ring finger and pinky down into your palm, hold them with your thumb, and keep your palm facing the camera beside your face.',
    'verificationGesturePeaceSignLeftTitle':
        'Show a peace sign with your left hand',
    'verificationGesturePeaceSignTitle':
        'Show a peace sign with your right hand',
    'verificationGesturePointingUpDescription':
        'Extend only the index finger of your right hand straight upward and make a fist with the other three fingers, held down with your thumb. Keep your palm facing the camera and your hand beside your face.',
    'verificationGesturePointingUpLeftDescription':
        'Extend only the index finger of your left hand straight upward and make a fist with the other three fingers, held down with your thumb. Keep your palm facing the camera and your hand beside your face.',
    'verificationGesturePointingUpLeftTitle':
        'Point up with your left index finger',
    'verificationGesturePointingUpTitle':
        'Point up with your right index finger',
    'verificationGesturePointToCheekDescription':
        'Point to your cheek with your finger',
    'verificationGesturePointToCheekTitle': 'Point to your cheek',
    'verificationGestureRaiseRightHandDescription':
        'Raise your right hand clearly in the photo',
    'verificationGestureRaiseRightHandTitle': 'Raise your right hand',
    'verificationGestureThumbsDownDescription':
        'Make a fist with your right hand and point your thumb straight down toward the floor. Keep the other fingers curled, your knuckles facing the camera, and hold your hand beside your face.',
    'verificationGestureThumbsDownLeftDescription':
        'Make a fist with your left hand and point your thumb straight down toward the floor. Keep the other fingers curled, your knuckles facing the camera, and hold your hand beside your face.',
    'verificationGestureThumbsDownLeftTitle':
        'Show a thumbs-down with your left hand',
    'verificationGestureThumbsDownTitle':
        'Show a thumbs-down with your right hand',
    'verificationGestureThumbsUpDescription':
        'Make a fist with your right hand and point your thumb straight up toward the ceiling. Keep the other fingers curled, your palm facing sideways, and hold your hand beside your face.',
    'verificationGestureThumbsUpLeftDescription':
        'Make a fist with your left hand and point your thumb straight up toward the ceiling. Keep the other fingers curled, your palm facing sideways, and hold your hand beside your face.',
    'verificationGestureThumbsUpLeftTitle':
        'Show a thumbs-up with your left hand',
    'verificationGestureThumbsUpTitle': 'Show a thumbs-up with your right hand',
    'verificationGestureTouchChinDescription': 'Touch your chin with your hand',
    'verificationGestureTouchChinTitle': 'Touch your chin',
    'verificationNoPending': 'No pending verifications',
    'verificationNotApproved':
        'Your verification was not approved. Please try again with a clearer photo.',
    'verificationPrivacyNotice':
        'Your verification photo is used for verification and fraud prevention, stays private, and is kept only as long as needed for review and community safety. After that, we keep only derived fraud-prevention signals.',
    'verificationPromptBodyRejected':
        'Your photo verification was not approved. Try again with a clearer photo and the requested hand gesture.',
    'verificationPromptBodyUnverified':
        'Verifying your photo keeps MatchMe real and safe. Take a quick selfie with a hand gesture — it only takes a minute.',
    'verificationPromptLater': 'Later',
    'verificationPromptTitle': 'Photo verification',
    'verificationRejected': 'Verification Rejected',
    'verificationRejectedCanRetry':
        'Verification was rejected. You can try again.',
    'verificationRejectedMessage': 'Verification rejected',
    'requestManualReview': 'Request Manual Review',
    'requestManualReviewHint':
        'Think the AI got it wrong? You can request our team to review your photo manually.',
    'manualReviewRequestedSuccess':
        'Your verification photo has been submitted for manual review.',
    'manualReviewRequestConfirmTitle': 'Request Human Review?',
    'manualReviewRequestConfirmMessage':
        'Our team will manually review your photo. While under review, you won\'t be able to submit new verification photos until the review is complete.',
    'manualReviewRequestButton': 'Submit for Review',
    'verificationRequirements': 'Verification Requirements',
    'verificationRetryNow': 'Try verification again',
    'verificationRetryReady': 'You can now submit a new verification photo.',
    'verificationReview': 'Verification Review',
    'verificationSimilarityPercentage': '% Similarity',
    'verificationSubmittedPrefix': 'Submitted',
    'verificationSubmittedSuccess':
        'Verification photo submitted successfully! We will review it shortly.',
    'verificationTakePhotoHint':
        'Review the requirements, then tap {button} at the bottom of the screen to start.',
    'verificationUnderReview': 'Verification under review',
    'verificationUnknownUser': 'Unknown user',
    'verified': 'Verified',
    'verifiedDescription': 'Your profile has been verified successfully!',
    'verifyNow': 'Verify Now',
    'viewEventMatches': 'View event matches',
    'viewMatch': 'View Match',
    'walk': 'Walk',
    'walking': 'Walking',
    'walks': 'Walks',
    'whenIsTheEvent': 'When is the event?',
    'you': 'You',
    'you_female': 'You',
    'you_male': 'You',
    'you_non_binary': 'You',
    'youAreCurrentlyOnline': 'You are currently Online',
    'youAreCurrentlyOnline_female': 'You are currently online',
    'youAreCurrentlyOnline_male': 'You are currently online',
    'youAreCurrentlyOnline_non_binary': 'You are currently online',
    'youAreCurrentlyOnlineAnd': 'You are currently Online and {reason}',
    'youAreCurrentlyOnlineAnd_female': 'You are currently online and {reason}',
    'youAreCurrentlyOnlineAnd_male': 'You are currently online and {reason}',
    'youAreCurrentlyOnlineAnd_non_binary':
        'You are currently online and {reason}',
    'youAreCurrentlyOnlineAndVisible': 'You are currently Online and Visible',
    'onlineToggleExplained':
        'When you go offline, other members cannot see you or match with you. Tap to come back online anytime.',
    'onlineStatusOnline': 'Online',
    'onlineStatusOffline': 'Offline',
    'youAreCurrentlyOnlineAndVisible_female':
        'You are currently online and visible',
    'youAreCurrentlyOnlineAndVisible_male':
        'You are currently online and visible',
    'youAreCurrentlyOnlineAndVisible_non_binary':
        'You are currently online and visible',
    'youAreInvisibleDueTo': 'You are invisible due to ',
    'youAreInvisibleDueTo_female': 'You are invisible due to',
    'youAreInvisibleDueTo_male': 'You are invisible due to',
    'youAreInvisibleDueTo_non_binary': 'You are invisible due to',
    'youAreOffline': 'You are offline',
    'youAreOffline_female': 'You are offline',
    'youAreOffline_male': 'You are offline',
    'youAreOffline_non_binary': 'You are offline',
    'youMatchedBecause': 'You matched because of:',
    'youMatchedBecause_female': 'You matched because',
    'youMatchedBecause_male': 'You matched because',
    'youMatchedBecause_non_binary': 'You matched because',
    'profileWizardSubIntentMin': '{intent} requires at least {min} sub-intent',
    'profileWizardSubIntentMax': '{intent} allows at most {max} sub-intents',
    'profileWizardInterestMin': '{intent} requires at least {min} interests',
    'profileWizardInterestMaxPerCategory':
        'Maximum {max} sub-interests per category',
    'profileWizardInterestMaxCategoriesSocial':
        'You can select up to {limit} social interests.',
    'profileWizardInterestMaxCategoriesBusiness':
        'You can select up to {limit} business/networking interests.',
    'profileWizardCategorySubInterestExceeded':
        'Category "{category}" exceeds maximum {max} sub-interests',
    'profileSelectAtLeastOneInterest': 'Please select at least one interest',
    'profileSelectSubIntentsMinMax': 'Select {min} to {max} sub-intents',
    'profileCounterSelected': '{count} / {max} selected',

    // ad_settings_screen keys
    'adSettingsAtLeastOneConsent':
        'At least one consent option must be selected',
    'adSettingsLoadFailed': 'Failed to load preferences',
    'adSettingsNonPersonalizedDesc': 'General ads not based on your interests',
    'adSettingsNotAuthenticated': 'Not authenticated',
    'adSettingsPersonalizedDesc': 'Ads based on your interests',
    'adSettingsSaveFailed': 'Failed to save preferences',
    'adSettingsSaved': 'Ad preferences saved',

    // auth_screen keys
    'authClearSession': 'Clear Session',

    // banner_ad_widget keys
    'adErrorGeneric': 'Error {code}: {message}',
    'adErrorInternal': 'Internal error: {message}',
    'adErrorInvalidRequest': 'Invalid request: {message}',
    'adErrorNetwork': 'Network error - check connection: {message}',
    'adErrorNoFill':
        'No fill - AdMob has no ad to serve (normal in test/development)',

    // calendar service keys
    'calendarNoTitle': 'No Title',

    // chat_screen keys
    'blockNeedsOnline': 'You need to be online to block a user',
    'reportNeedsOnline': 'You need to be online to report a user',

    // match_box keys
    'recentMatches': 'Recent Matches',

    // photo_gallery_viewer keys
    'failedToLoadImage': 'Failed to load image',

    // profile_wizard_screen keys
    'profileWizardFacebookHint': 'yourusername',
    'profileWizardInstagramHint': 'yourusername',
    'profileWizardLinkedinHint': 'yourprofile',
    'profileWizardRemove': 'Remove',
    'profileWizardSearchInterestsHint': 'Search interests and sub-interests...',
    'profileWizardSearchNoResults': 'No interests match your search',
    'profileWizardRemovePhotoBody':
        'Are you sure you want to remove this photo?',
    'profileWizardRemovePhotoTitle': 'Remove photo?',

    // web notification service keys
    'webNotificationNewMatchBody': 'New match! Tap to start chatting',
    'webNotificationNewMatchTitle': '💕 New match with {userName}',

    // web notification stub keys
    'notAvailableOnPlatform': 'Not available on this platform',

    // web placeholder ad keys
    'webArticleAdPlaceholder': 'Article Ad',
    'webDisplayAdPlaceholder': 'Web Display Ad',
    'webInFeedAdPlaceholder': 'In-Feed Ad',
    'webAdSpecialOffer': 'Special Offer',
    'webAdGetOffer': 'Get Offer',
    'webAdPremiumOffer': '50% Off Premium',

    // profile_wizard_screen bio validation keys
    'profileEditBioTooLong': 'Your bio is too long.',
    'profileEditBioContainsLink':
        'Your bio contains a link, which is not allowed.',
    'profileEditBioContainsEmail':
        'Your bio contains an email address, which is not allowed.',
    'profileEditBioContainsPhone':
        'Your bio contains a phone number, which is not allowed.',
    'profileEditBioContainsContact':
        'Your bio contains contact info, which is not allowed.',
    'profileEditBioSpamOrPromotion': 'Your bio looks like spam or promotion.',

    // height unit suffix
    'profileHeightCm': 'centimeters',

    // height unit labels and composite formats (full words, not abbreviations)
    'profileHeightUnitCm': 'centimeters',
    'profileHeightUnitFeet': 'feet',
    'profileHeightUnitInches': 'inches',
    'profileHeightFeet': 'Feet',
    'profileHeightInches': 'Inches',
    'profileHeightFeetInches': '{feet} {inches}',
    'profileHeightFeetValue': '{count} feet',
    'profileHeightInchesValue': '{count} inches',
    'profileHeightInCm': '{cm} centimeters',

    // education level labels
    'educationHighSchool': 'High School',
    'educationAssociate': 'Associate Degree',
    'educationBachelor': "Bachelor's Degree",
    'educationMaster': "Master's Degree",
    'educationPhd': 'Doctorate (PhD)',
    'educationOther': 'Other',

    // match_profile_screen fallback strings
    'matchProfileNoBio': 'No bio provided.',
    'matchProfileNoLanguages': 'No languages listed',

    // match chat-start extension feature (fallbacks mirror Supabase translations)
    'matchExtendButton': 'Extend',
    'matchExtendConfirmTitle': 'Extend match time?',
    'matchExtendConfirmBody':
        'Add {duration} more time before this match expires? You can only extend once per match.',
    'matchExtendConfirmBodyBoth':
        'Add {duration} more time before this match expires? Both you and {name} can extend once, for the same amount.',
    'matchExtendCancel': 'Cancel',
    'matchExtendConfirm': 'Extend',
    'matchExtendSuccess':
        'Match extended by {duration}. New time left: {remaining}.',
    'matchExtendSuccessTitle': 'Match extended',
    'matchExtendAlreadyExtended': 'You have already extended this match.',
    'matchExtendOtherExtended': '{name} has already extended this match.',
    'matchExtendBothExtended': 'Both of you have extended this match.',
    'matchExtendChatStarted':
        'A chat has already started, so this match will no longer expire.',
    'matchExtendExpired': 'This match has already expired.',
    'matchExtendError': 'Could not extend the match. Please try again.',
    'matchExtendMaxReached': 'This match cannot be extended further.',
    'matchExtendTimeLeftExtended': 'Extended time left: {time}',
    'matchExtendLabel': 'Extend time',
    'matchExtendHint': 'Add more time before the match expires',
    'matchExtendedBadge': 'Extended',
    'matchExtendedByYou': 'Extended by you',
    'matchExtendedByOther': 'Extended by {name}',
    'matchExtensionDurationHours': '{count} hours',
    'matchExtensionDurationMinutes': '{count} minutes',
    'matchExtensionDurationDays': '{count} days',

    // profile completeness (owner-facing %) — English fallbacks for keys also
    // shipped in migration 20262117000001_add_profile_completeness_translations.sql
    'profileCompletionTitle': 'Profile completeness',
    'profileCompletionPercent': '{percent}% complete',
    'profileCompletionAlmostThere': 'Almost there!',
    'profileCompletionFullTitle': 'Profile complete',
    'profileCompletionFullMessage': 'Your profile is 100% complete. Nice work!',
    'profileCompletionSubtitle': 'Complete profiles get more matches',
    'profileCompletionNextSteps': 'Next steps',
    'profileCompletionImprove': 'Complete now',
    'profileCompletionMoreItems': '+{count} more',
    'profileCompletionItemPhotos': 'Add 3 or more photos',
    'profileCompletionItemBio': 'Write a short bio',
    'profileCompletionItemPersonalInterests': 'Add personal interests',
    'profileCompletionItemBusinessInterests': 'Add business interests',
    'profileCompletionItemLifestyle': 'Add your lifestyle',
    'profileCompletionItemFamily': 'Add family details',
    'profileCompletionItemReligion': 'Add religion details',
    'profileCompletionItemOccupation': 'Add your occupation',
    'profileCompletionItemEducation': 'Add your education',
    'profileCompletionItemHeight': 'Add your height',
    'profileCompletionItemSocial': 'Link a social profile',
    'profileCompletionItemLanguages': 'Add at least 2 languages',
    'profileCompletionBadge': 'Profile Complete',
    'profileCompletionBadgeTooltip': 'This profile is 100% complete',
    'profileCompletionBannerTitle': 'Complete your profile',
    'profileCompletionBannerMessage':
        '{percent}% complete — finish the rest to stand out and get more matches.',
    'profileCompletionDismiss': 'Dismiss',

    // rematch indicator (3 times total)
    'rematchIndicator': 'This is the {count} time you matched!',
    'rematchIndicator2': 'This is the 2nd time you matched!',
    'rematchIndicator3': 'This is the 3rd time you matched!',
    'rematchBanner2': 'Rematch! This is your 2nd time matching with {name}',
    'rematchBanner3': 'Rematch! This is your 3rd time matching with {name}',
    'rematchBanner': 'Rematch! This is your {count} time matching with {name}',
    'matchExpiryHint':
        'Time left to send a message before match disappears: {duration}',
    'matchLocationTitle': 'Match location',
    'matchLocationOccurrence': 'Location #{count}',
    // NOTE: Hebrew DB value is 'מיקום {count}#' ("מיקום 1#") so "#" renders to
    // the right of the digits in RTL. Do not "fix" it back to "#{count}".
    // Singular header used when there is only one location (no number).
    'matchLocationSingle': 'Location',
    'matchMiniMapTitle': 'Where and when you matched',
    'matchMiniMapDescProximity': 'You were nearby each other here',
    'matchNoLocation': 'Location not available for this match',
    'matchFirstMatchedOn': 'First matched on:',
    'matchSecondMatchedOn': 'Second matched on:',
    'matchThirdMatchedOn': 'Third matched on:',

    // --- Voice guidance (spoken coaching in profile wizard + verification) ---
    'voiceGuidanceMuteTooltip': 'Mute voice guidance',
    'voiceGuidanceUnmuteTooltip': 'Turn voice guidance on',
    'voiceGuidanceEnabledConfirmation': 'Voice guidance is now on.',
    'voiceGuidanceSettingsLabel': 'Voice guidance',
    'voiceGuidanceSettingsDescription':
        'Spoken step-by-step help while you complete your profile and verify your photos.',
    'voiceGuidanceWizardWelcome':
        'Welcome! I will guide you through setting up your profile… On each page, tap Next when you are done.',
    'voiceGuidanceStepIntents':
        'First, choose why you are here. Select at least one option, then tap Next.',
    'voiceGuidanceStepSubIntents':
        'Now choose what fits your goal within {intent}. Pick at least one, then tap Next.',
    'voiceGuidanceStepAboutYou':
        'This page is about you. Enter your name, gender and date of birth. You must be at least eighteen years old.',
    'voiceGuidanceStepDetails':
        'Tell people about yourself. Write a short bio, pick the languages you know, and enter your height.',
    'voiceGuidanceStepPhotos':
        'Time to add your photos… Tap Add photo to take a selfie, or choose one from your gallery. Your first photo is your main photo.',
    'voiceGuidanceStepInterests':
        'Choose your interests. Pick at least one to continue, then tap Next.',
    'voiceGuidanceStepLifestyle':
        'Choose your lifestyle options, then tap Next.',
    'voiceGuidanceStepFamily': 'Share your family plans, then tap Next.',
    'voiceGuidanceStepReligion':
        'Choose your religion or belief, denomination if relevant, and how often you practice. All fields are optional. Then tap Next.',
    'voiceGuidanceStepMatchPrefs':
        'Set what you are looking for in a match, then tap Next.',
    'voiceGuidanceStepSocial':
        'Last step. Add social links if you like, then tap Save to finish.',
    'voiceGuidancePhotoAdded': 'Photo added.',
    'voiceGuidancePhotoPrimaryAdded':
        'Great… Your main photo was added. It is the first thing people see about you.',
    'voiceGuidancePhotoRemoved': 'Photo removed.',
    'voiceGuidancePhotosMaxReached':
        'You already have the maximum of five photos.',
    'voiceGuidancePhotoRequiredHint':
        'You need at least one photo to continue… Tap Add photo to take a selfie, or choose one from your gallery.',
    'voiceGuidancePrimaryPhotoOk': 'Your main photo looks great.',
    'voiceGuidanceVerificationIntro':
        'Welcome to photo verification… Your face must be clearly visible, in good lighting, with no filters or edits… I will guide you.',
    'voiceGuidanceVerificationTakePhotoHint':
        'When you are ready, tap {button} at the bottom of the screen to start.',
    'voiceGuidanceVerificationGesture': '{gesture}. {description}',
    'voiceGuidanceVerificationCaptured':
        'Photo captured… If it looks good, tap Submit for review.',
    'voiceGuidanceVerificationSubmitting': 'Uploading your photo for review.',

    // --- Onboarding introduction tour (interactive app walkthrough) ---
    // Narration lines are shared verbatim between the spoken audio (TTS) and
    // the subtitle bar, so they are written to be heard as well as read.
    'onboardingTourTitle': 'Discover MatchMe',
    'onboardingSkip': 'Exit',
    'onboardingStepOf': 'Step {current} of {total}',
    'onboardingGetStarted': 'Get Started',
    'onboardingPauseTooltip': 'Pause the tour',
    'onboardingPlayTooltip': 'Play the tour',
    'onboardingMuteTooltip': 'Mute audio',
    'onboardingUnmuteTooltip': 'Unmute audio',
    'onboardingReplayAudioTooltip': 'Replay this narration',
    'onboardingTagline': 'Meet people who match your world',
    'onboardingWelcomeStepProfile': 'Create your profile',
    'onboardingWelcomeStepDiscover': 'Discover nearby',
    'onboardingWelcomeStepChat': 'Chat & meet',
    'settingsAppTour': 'App tour',
    'settingsAppTourDesc': 'Replay the guided intro or a specific section.',
    'onboardingTourBasics': 'The basics',
    'onboardingTourBasicsDesc': 'A quick overview of how MatchMe works.',
    'onboardingTourSections': 'Section tours',
    'onboardingSectionPromptBody':
        'New here? Watch a 30-second guided tour of this screen.',
    'onboardingSectionPromptStart': 'Show me',
    'onboardingSectionPromptDismiss': 'No thanks',
    'onboardingChapterWelcome': 'Welcome to MatchMe',
    'onboardingChapterHome': 'Your home screen',
    'onboardingChapterNearby': 'Discover people nearby',
    'onboardingChapterWorldMap': 'Online around the world',
    'onboardingChapterMatches': 'Your matches',
    'onboardingChapterChats': 'Chat safely',
    'onboardingChapterEvents': 'Join events',
    'onboardingChapterProfile': 'Your profile',
    'onboardingChapterSettings': 'Settings',
    'onboardingChapterFinish': "You're all set!",
    'onboardingBeatWelcome1':
        'Welcome to MatchMe… You do not swipe or browse profiles. MatchMe looks for people nearby who share your interests and intentions, then lets you decide what to do next.',
    'onboardingBeatWelcome2':
        'Finish your profile, choose what you are here for, and set your matching controls. MatchMe can keep working in the background while you live your life.',
    'onboardingBeatHome1':
        'This is your home screen. It shows whether you are visible and lets you manage matching without making you hunt through menus. The switch controls visibility; it does not close your account.',
    'onboardingBeatHome2':
        'The cards up top show nearby people and online activity. Tap a card to open it.',
    'onboardingBeatHome3':
        'Below, your most recent matches and chats are waiting, so you can pick up right where you left off.',
    'onboardingBeatHome4':
        'These chips narrow what you see here… choose the kinds of connections you want.',
    'onboardingBeatNearby1':
        'This map shows an approximate count of visible people inside your matching radius. Nobody sees your exact location.',
    'onboardingBeatNearby2':
        'Each dot is an online and visible member inside your match circle… The blue marker in the middle is you.',
    'onboardingBeatNearby3':
        'Nobody sees your exact location… Others only see an approximate distance within the circle, and only when you are visible.',
    'onboardingBeatNearby4':
        'The world map counts online members by country… so you can see where the community is most active right now.',
    'onboardingBeatWorldMap1':
        'This is the online world map, opened from your home screen… The pill up top shows how many members are online, and each label counts them by country, so you can see where the community is most active.',
    'onboardingBeatWorldMap2':
        'Each label counts the online members in that country… so you can see where the community is most active.',
    'onboardingBeatMatches1':
        'Every time you and another member want the same kind of connection, they appear here as a match… The heart shows how many interests you share.',
    'onboardingBeatMatches2':
        'Matches last 24 hours by default… The countdown timer on each card shows how long you have to say hello. Either of you can tap Extend for extra time… and once you start chatting, the match never expires.',
    'onboardingBeatMatches3':
        'Sort your matches, and tap a card to view the full profile before starting a chat.',
    'onboardingBeatMatches4':
        'Use these intent filters — the same ones from your profile — to narrow matches to friends, dating, or both. These same filters also apply in Chats.',
    'onboardingBeatChats1':
        'All your conversations live here… Unread chats are highlighted, so you can jump straight back in.',
    'onboardingBeatChats2':
        'Messages are encrypted and stored securely, with an encrypted copy on your device… They can even be translated automatically, so language is never a barrier. You can block or report anyone, and share your live location with one match at a time.',
    'onboardingBeatEvents1':
        'Shared events are an alternative to being in the same radius right now… You will be in the same place in the future, when the event happens. Import from your calendar, upload a PDF ticket, paste an event link, or create one manually.',
    'onboardingBeatEvents2':
        'Bring your plans with you… Import events from Google, Outlook, Apple or device calendar into MatchMe, then meet members going too.',
    'onboardingBeatProfile1':
        'This is how others see you… AI-generated photos following the app photo rules, your age and bio, and your interests. A complete profile gets far more attention.',
    'onboardingBeatProfile2':
        'You earned a Primary Photo Verified badge by completing the verification procedure from Settings… This badge shows on your profile and whenever others see you.',
    'onboardingBeatProfile3':
        'Tap edit any time to update your photos or details through the same wizard you already know.',
    'onboardingBeatSettings1':
        'Open settings with the gear icon at the top of the screen.',
    'onboardingBeatSettings2':
        'Under Matching, you control the search distance and the matching modes. Tap to see all matching controls in one place. Three matching modes shape your experience… Shared Event Matching finds people at the same event, Retro Matching finds people you crossed paths with offline, and Background Matching keeps searching while you are away.',
    'onboardingBeatSettings3':
        'Under Match Preferences, you set the age range, gender preference, and lifestyle filters… These directly determine who can match with you.',
    'onboardingBeatSettings4':
        'Under Invisibility Rules, you choose when you are automatically invisible… at work, at home, or on a schedule.',
    'onboardingBeatSettings5':
        'Verification is launched from here… Complete a live selfie check to earn the Primary Photo Verified badge that appears on your profile and when others see you.',
    'onboardingBeatSettingsTour':
        'Start with the app tour… replay this guided walkthrough any time you want a refresher.',
    'onboardingBeatSettingsDisplay':
        'Under App display, you change the language, the theme, and voice guidance… This tour speaks in your language too.',
    'onboardingBeatSettingsNotifs':
        'Under Notifications, you choose what reaches you… new matches, messages, and announcements, each with its own push, sound, and vibration.',
    'onboardingBeatSettingsPaywall':
        'Under Premium, you compare the Free, Plus, Gold, and Platinum tiers… and unlock extra features.',
    'onboardingBeatSettingsBilling':
        'Under Billing, you manage payment methods and redeem promo codes…',
    'onboardingBeatSettingsInvite':
        'Under Invite friends, you share your referral link… and earn rewards for you both.',
    'onboardingBeatSettingsSecurity':
        'Under Security, you sign in with passkeys and protect your account with an authenticator app and recovery codes.',
    'onboardingBeatSettingsAccount':
        'Under Account, you change your password or email… or delete your account entirely. Sensitive actions first confirm it is really you.',
    'onboardingBeatFinish1':
        'That is the idea… MatchMe works quietly in the background. When someone matches, you can view their profile, message briefly, or meet in person. You can close the app and come back when you are ready.',
    'onboardingDemoGreeting': 'Hi there, Alex!',
    'onboardingDemoIntentFriends': 'Friends',
    'onboardingDemoIntentDating': 'Dating',
    'onboardingDemoRadius': '2 kilometers',
    'onboardingDemoDaySat': 'Saturday',
    'onboardingDemoDaySun': 'Sunday',
    'onboardingDemoTimeLeft': '23 hours',
    'demoName1': 'Maya, 28',
    'demoName2': 'Daniel, 31',
    'demoName3': 'Sofia, 26',
    'demoAge1': '28',
    'demoGender1': 'Woman',
    'demoBio': 'Hiking, live music and good coffee.',
    'demoInterest1': 'Hiking',
    'demoInterest2': 'Live music',
    'demoInterest3': 'Travel',
    'demoChatMessage1': 'Hi Maya! Loved your hiking photos.',
    'demoChatMessage2': 'Thank you! Are you free this weekend?',
    'demoChatMessage3': 'Definitely… coffee on Saturday?',
    'demoLastMessage1': 'Sounds like a plan!',
    'onboardingDemoMessageHint': 'Write a message…',
    'onboardingDemoJoin': 'Join',
    'demoEventTitle': 'Sunset beach volleyball',
    'demoEventMeta': 'Central Beach · Saturday 17:00',
    'demoEventTitle2': 'Rooftop jazz night',
    'demoEventMeta2': 'Old Town · Friday 20:00',
    'onboardingBeatProfileVerifyLabel': 'Verification in progress…',
    'onboardingBeatProfileVerifyHint':
        'A live selfie check is needed to unlock the Primary Photo Verified badge.',

    // --- Plural forms -----------------------------------------------------
    // The base key of a countable string holds the plural form; the singular
    // lives under `<key>_one` and Hebrew's dual under `<key>_two`. `getString`
    // picks the right one from the quantity it is handed, so "1 minute" and
    // "2 minutes" read correctly in every language.
    // See lib/utils/plural_rules.dart for the rules.
    'billingMethodsUsed_one': '{count} method used',
    'billingTotalTransactions_one': '{count} transaction',
    'calendarSyncDeviceSummaryAccounts_one': '{count} account found',
    'calendarSyncDeviceSummaryEvents_one': '{count} event found',
    'calendarSyncDuplicateEventsFound_one': '{count} duplicate found',
    'calendarSyncDuplicateSelectedWillSkip_one':
        '{count} selected event will be skipped because it already exists.',
    'calendarSyncSyncedEventsSuccess_one':
        'Successfully imported {count} event.',
    'calendarSyncSyncedEventsSuccessWithSkipped_one':
        'Successfully imported {count} event. Skipped {skipped}.',
    'chatsArchivedCount_one': '{count} chat archived',
    'chatsResultsCount_one': '{count} conversation',
    'chatsUnarchivedCount_one': '{count} chat unarchived',
    'chatsUnreadMessages_one': '{count} unread message',
    'inboxDeleteSelectedConfirm_one':
        'Delete {count} selected notification? This cannot be undone.',
    'inboxSelectedCount_one': '{count} selected',
    'inboxUnreadCount_one': '{count} unread',
    'durationDays_one': '{count} day',
    'durationHours_one': '{count} hour',
    'durationMinutes_one': '{count} minute',
    'durationSeconds_one': '{count} second',
    'generalAgeYearsOld_one': '{age} year old',
    'gpsThrottledLowBattery_one':
        'Low battery — GPS updates reduced to once every {interval} second to save battery. This will resume when your device is charging or battery is above {threshold}%.',
    'gpsThrottledStationary_one':
        'Not moving — GPS updates reduced to once every {interval} second to save battery. This will resume when you start moving.',
    'homeRecentChatsCount_one': 'Showing top {count} Conversation',
    'homeRecentChatsCountOf_one': 'Showing top {shown} of {total} Conversation',
    'homeRecentMatchesCount_one': 'Showing top {count} Match',
    'homeRecentMatchesCountOf_one': 'Showing top {shown} of {total} Match',
    'listFilterResultCount_one': '{count} conversation',
    'listFilterResultCountOf_one': '{shown} of {total} conversation',
    'listFilterShowResults_one': 'Show {count} result',
    'locationShareHours_one': '{count} hour',
    'locationShareMinutes_one': '{count} minute',
    'mapApproxUsersHere_one': 'About {count} user here',
    'mapShowingApproxUsers_one': 'Showing about {count} user',
    'matchExpiryBody_one':
        'You have {count} minute left to start a chat with {otherUserName}.',
    'matchExpiryTitle_one': '{count} minute left',
    'matchExtensionDurationDays_one': '{count} day',
    'matchExtensionDurationHours_one': '{count} hour',
    'matchExtensionDurationMinutes_one': '{count} minute',
    'matchesResultsCount_one': '{count} Match',
    'matchesResultsCountOf_one': '{shown} of {total} Match',
    'offlinePendingChangesDescription_one':
        'You have {count} pending change waiting to sync. These will be sent to the server when your connection is restored.\\n\\nActions in MatchMe will be unavailable until these sync.',
    'offlineSyncingChanges_one': 'Syncing {count} change',
    'onlineProvidersEventCount_one': '{count} event',
    'onlineProvidersSummaryAccounts_one': '{count} account connected',
    'onlineProvidersSummaryEvents_one': '{count} event found',
    'promoCodeExpiresIn_one': 'Expires in {days} day',
    'promoCodeExpiresInHours_one': 'Expires in {hours} hour',
    'promoDiscountFreeDaysFormat_one': '{days} day Free',
    'profileHeightFeetValue_one': '{count} foot',
    'profileHeightInchesValue_one': '{count} inch',
    'profileWizardCategorySubInterestExceeded_one':
        'Category "{category}" exceeds maximum {max} sub-interest',
    'profileWizardInterestMaxCategoriesBusiness_one':
        'You can select up to {limit} business/networking interest.',
    'profileWizardInterestMaxCategoriesSocial_one':
        'You can select up to {limit} social interest.',
    'profileWizardInterestMaxPerCategory_one':
        'Maximum {max} sub-interest per category',
    'profileWizardInterestMin_one': '{intent} requires at least {min} interest',
    'profileWizardSubIntentMax_one': '{intent} allows at most {max} sub-intent',
    'profileWizardSubIntentMin_one':
        '{intent} requires at least {min} sub-intent',
    'profileSelectSubIntentsMinMax_one': 'Select {min} to {max} sub-intent',
    'pushMessagesTitle_one': '{count} message from {name}',
    'pushOpenToReadBody_one': '1 unread - open to read',
    'ratingRatedBy_one': 'Rated by {count} user',
    'ratingVerifiedCount_one': '{count} verified rating',
    'rematchBanner_one':
        'Rematch! This is your first time matching with {name}',
    'rematchIndicator_one': 'This is the first time you matched!',
    'settingsAccuracyMeters_one': 'Accuracy: about {meters} meter',
    'settingsMfaEmailCodeResendIn_one': 'Resend in {seconds} second',
    'settingsMfaRecoveryCodesCount_one': '{count} recovery code ready',
    'settingsRetroDays_one': '{count} day',
    'settingsRetroHours_one': '{count} hour',
    'translationCoverageWarningBody_one':
        'Supabase is missing {count} UI text entry for {locale}. The app is showing English fallbacks for that key.',
    'distanceInFeet_one': '{count} foot',
    'distanceInKilometers_one': '{count} kilometer',
    'distanceInMeters_one': '{count} meter',
    'distanceInMiles_one': '{count} Mile',

    // --- Counters that only ever existed in the database -------------------
    // Bundled so the count reads correctly before the first fetch lands.
    'chatsArchivedCount': '{count} chats archived',
    'chatsUnarchivedCount': '{count} chats unarchived',
    'inboxDeleteSelectedConfirm':
        'Delete {count} selected notifications? This cannot be undone.',
    'inboxSelectedCount': '{count} selected',
    'inboxUnreadCount': '{count} unread',
    'inboxTypeMeetupSignal': 'Gesture',
    'inboxTypeMeetupBeacon': 'Beacon',
    'inboxTypeMeetupSpot': 'Spot me',
    'inboxTypeMeetupProposal': 'Meeting point proposal',
    'inboxTypeMeetupPlaceChange': 'New meeting point',
    'inboxOpenMeetup': 'Open Meet up',

    // --- Localized duration parts ------------------------------------------
    // A countdown that names several units ("1 hour, 5 minutes and 3 seconds")
    // cannot be pluralized in one template: every unit has its own quantity.
    // The parts are translated separately and joined with these connectors.
    'durationListAnd': '{first} and {second}',
    'durationListCommaAnd': '{first}, {second} and {third}',
    'locationShareCountdownRemaining': 'for another {duration}',

    // --- In-person meet-up ------------------------------------------------
    'meetupTitle': 'Meet up',
    'meetupIntroBody':
        'Choose a public place to meet. We use your current location once to look up nearby public places; your location is not saved.',
    'meetupPrivacyNote':
        'Your exact location is not saved or shared with the other person. Only the public meeting point is shared.',
    'meetupSafetyNote': 'Meet in a public, well-lit place.',
    'meetupSuggestPlaces': 'Suggest meeting points',
    'meetupFindingPlaces': 'Finding public places near you…',
    'meetupNoPlacesFound':
        'No suitable public places found nearby. Try again or move a little.',
    'meetupLandmarkLookupFailed':
        'We could not look up nearby places right now. Try again in a moment.',
    'meetupRetry': 'Try again',
    'meetupOffline': 'Meet-up needs a connection.',
    'meetupLocationUnavailable':
        'We could not get your location. Check location services and try again.',
    'meetupSendOptions': 'Send meeting points',
    'meetupSending': 'Sending…',
    'meetupSuggestionRoundTitle': 'Choose where to meet',
    'meetupSuggestionRoundBody':
        'These public places are close to you. Send up to three options.',
    'meetupCounterRoundTitle': 'Suggest other places',
    'meetupCounterRoundBody':
        'These public places are close to you. They can pick one, or end the meet-up.',
    'meetupWaitingForOther': 'Waiting for {name} to choose',
    'meetupChooseThisPlace': 'Meet here',
    'meetupSuggestOtherPlaces': 'Suggest other places',
    'meetupCounterSent': 'Your suggestions were sent',
    'meetupCounterLimit': 'Only one counter-suggestion is allowed.',
    'meetupInviteExpired': 'This meet-up invite expired.',
    'meetupActiveTitle': 'Meet-up active',
    'meetupActivityHintProposal': 'Choose a place together',
    'meetupActivityHintProposalMine': 'They have been notified',
    'meetupActivityHintPlaceChangeMine': 'You can withdraw it any time',
    'meetupActivityHintLive': 'Open the map to see where they are',
    'meetupActivityHintLiveMine': 'You can stop sharing at any time',
    'meetupActivityHintSpotMine': 'They can see it until it expires',
    'meetupActivityHintWaveMine': 'They can wave back',
    'meetupActivityHintActive': 'Open the meet-up for the tools',
    'meetupActivityYourWave': 'You waved',
    'meetupActivityOneMoreTool': '1 more meet-up tool is active',
    'meetupActivityMoreTools': '{count} more meet-up tools are active',
    'meetupChosenPlace': 'Meeting point',
    'meetupOpenInMaps': 'Open in maps',
    'meetupDistanceAway': '{distance} away',
    'meetupWalkDuration': '{duration} on foot',
    'meetupTimeLeft': '{time} left',
    'meetupBeacon': 'Beacon',
    'meetupBeaconHint': 'Show a bright shape so they can spot you',
    'meetupBeaconActiveTitle': 'Beacon on',
    'meetupBeaconActiveBody':
        'Hold up your screen. {name} is looking for this shape.',
    'meetupBeaconIncomingTitle': '{name} is showing a beacon',
    'meetupBeaconIncomingBody': 'Look for this shape on their screen.',
    'meetupBeaconHide': 'Hide beacon',
    'meetupBeaconEndsIn': 'Turns off in {duration}',
    'meetupSpotMe': 'Spot me',
    'meetupSpotMeHint': 'Take a selfie or share what you are wearing',
    'meetupSpotMeTitle': 'Spot me card',
    'meetupSpotMePhotoSelf': 'Photo of me',
    'meetupSpotMePhotoPlace': 'Photo of the meeting point',
    'meetupSpotMeNoPhoto': 'No photo',
    'meetupSpotMePickPhoto': 'Add a photo (optional)',
    'meetupSpotMeOutfit': 'What you are wearing (optional)',
    'meetupSpotMeNote': 'A short clue (optional)',
    'meetupSpotMeNoteHint': 'For example: I am by the north entrance',
    'meetupSpotMeShare': 'Share card',
    'meetupSpotMeSharing': 'Sharing…',
    'meetupSpotMeLimit':
        'You shared the maximum number of cards for this meet-up.',
    'meetupSpotMeRateLimited': 'Wait a moment before sharing another card.',
    'meetupSpotMeContentRequired': 'Add a photo or outfit details to share.',
    'meetupSpotMeIncomingTitle': '{name} shared a spot card',
    'meetupSpotMeIncomingBody': 'Open to see their Spot me card.',
    'meetupSpotMeHide': 'Hide',
    'meetupSpotMeDelete': 'Delete',
    'meetupSpotMeReport': 'Report',
    'meetupSpotMeHidden': 'Spot card hidden',
    'meetupSpotMeReported': 'Report sent',
    'meetupSpotMeReportConfirm': 'Report this spot card?',
    'meetupSpotMeExpired': 'Expired',
    'meetupSpotMeFromYou': 'Your spot card',
    'meetupSpotMeNoDetails': 'No extra details',
    'meetupSpotMeNew': 'New',
    'meetupSpotMeWearing': 'What they’re wearing',
    'meetupSpotMeNoOutfit': 'No outfit details shared',
    'meetupSpotMeNoPhotoShared': 'No photo shared',
    'meetupSpotMeViewPhoto': 'View photo',
    'meetupSpotMeJustNow': 'just now',
    'meetupSpotMeAgo': '{duration} ago',
    'meetupOutfitShirt': 'Shirt',
    'meetupOutfitPants': 'Pants',
    'meetupOutfitShoes': 'Shoes',
    'meetupOutfitColor': 'Color',
    'meetupOutfitLongSleeve': 'Long sleeve',
    'meetupOutfitShortSleeve': 'Short sleeve',
    'meetupOutfitJacket': 'Jacket',
    'meetupOutfitDress': 'Dress',
    'meetupOutfitShorts': 'Shorts',
    'meetupOutfitTrousers': 'Dress pants',
    'meetupOutfitSkirt': 'Skirt',
    'meetupOutfitSneakers': 'Sneakers',
    'meetupOutfitBoots': 'Boots',
    'meetupOutfitSandals': 'Sandals',
    'meetupOutfitOther': 'Other',
    'meetupWave': 'Wave',
    'meetupWaveHint': 'Send a gesture so they can spot you',
    'meetupWaveSent': 'Wave sent',
    'meetupWaveIncomingTitle': '{name} waved at you',
    'meetupWaveIncomingBody': 'Raise your hand so they can see you.',
    'meetupWaveBack': 'Wave back',
    'meetupWaveRateLimited': 'Wait a moment before waving again.',
    'meetupEnd': 'End meet-up',
    'meetupFound': 'I found them',
    'meetupEndConfirmTitle': 'End this meet-up?',
    'meetupEndFoundConfirmBody':
        'This ends the meet-up for both of you and removes the beacon and spot cards.',
    'meetupEndCancelConfirmBody':
        'This cancels the meet-up for both of you and removes the beacon and spot cards.',
    'meetupEndCancel': 'Cancel meet-up',
    'meetupCancelInvite': 'Cancel invite',
    'meetupEndedFound': 'Meet-up ended — they found you.',
    'meetupEndedByYou': 'You ended the meet-up.',
    'meetupEndedCancelled': 'Meet-up canceled.',
    'meetupEndedExpired': 'Meet-up expired.',
    'meetupEndedOther': '{name} ended the meet-up.',
    'meetupStartAgain': 'Start again',
    'meetupEventZonesTitle': 'Choose a zone at the venue',
    'meetupEventZonesBody':
        'Pick a place inside or just outside the venue. No coordinates are needed.',
    'meetupEventZoneMainEntrance': 'Main entrance',
    'meetupEventZoneBoxOffice': 'Box office / ticket desk',
    'meetupEventZoneBar': 'Bar area',
    'meetupEventZoneCloakroom': 'Cloakroom',
    'meetupEventZoneSeating': 'Seating area',
    'meetupEventZoneCustom': 'Other zone',
    'meetupEventZoneCustomHint': 'For example: Zone C bar',
    'meetupEventZone': 'Meeting zone',
    'meetupCategoryPark': 'Park',
    'meetupCategorySquare': 'Square',
    'meetupCategoryLandmark': 'Landmark',
    'meetupCategorySupermarket': 'Supermarket entrance',
    'meetupCategoryMall': 'Mall entrance',
    'meetupCategoryFuel': 'Fuel station forecourt',
    'meetupCategoryTransit': 'Transit entrance',
    'meetupCategoryPharmacy': 'Pharmacy entrance',
    'meetupCategoryAttraction': 'Tourist spot',
    'meetupCategoryLibrary': 'Public building',
    'meetupCategoryOther': 'Public place',
    'meetupBannerProposedByOther': '{name} suggested a meeting point',
    'meetupBannerProposedByYou': 'Waiting for {name} to choose a meeting point',
    'meetupBannerActive': 'Meet-up active — {place}',
    'meetupBannerActiveEvent': 'Meet-up active — {zone}',
    'meetupBannerWave': '{name} waved at you',
    'meetupBannerBeacon': '{name} is showing a beacon',
    'meetupOpen': 'Open',
    'meetupActionFailed': 'Something went wrong. Try again.',
    'meetupProposalSent': 'Meeting points sent',
    'meetupAccepted': 'Meeting point confirmed',
    'meetupEndedToast': 'Meet-up ended',
    'meetupPlace': 'Meeting point',
    'meetupYou': 'You',
    'meetupSignalExpired': 'This signal expired.',
    'meetupCounterWaiting': 'Waiting for {name} to choose your suggestion',
    'meetupProposalWaiting': 'Waiting for {name}',
    'meetupBeaconTapHint':
        'You can signal, show a beacon, or share a Spot me card before and after you choose a meeting point.',
    'meetupAlreadyActive': 'A meet-up is already active with this person.',
    'meetupBeaconRateLimited': 'Wait a moment before showing the beacon again.',
    'meetupBeaconExpired': 'This beacon expired.',
    'meetupSpotMeShared': 'Spot card shared',
    'meetupClose': 'Close',

    // Tools work for any open meet-up (proposed or active).
    'meetupSignal': 'Signal',
    'meetupSignalHint':
        'Wave, raise both hands, jump, or open your arms so they can spot you.',
    'meetupGestureSheetTitle': 'Choose a gesture',
    'meetupGestureSheetBody': 'They will see the gesture you choose.',
    'meetupGestureWave': 'Wave',
    'meetupGestureHandsUp': 'Both hands up',
    'meetupGestureJumping': 'Jumping',
    'meetupGestureArmsWide': 'Arms wide',
    'meetupGestureSent': '{gesture} sent',
    'meetupGestureIncomingTitle': '{name} is signaling: {gesture}',
    'meetupGestureIncomingBody':
        'Look for this gesture so you can spot each other.',
    'meetupSignalBack': 'Signal back',
    'meetupBannerGesture': '{name} is signaling: {gesture}',
    // The sender's own copy of a live signal: what was sent and for how long
    // the other device can still see it.
    'meetupSignalOutgoingKicker': 'You sent {name} a signal',
    'meetupSignalOutgoingVisible': 'Still visible {time}',
    'meetupSignalOutgoingPill': 'Sent',

    // Custom meeting places (name only, no coordinates stored).
    'meetupCustomPlace': 'Enter a place',
    'meetupCustomPlaceTitle': 'Name a meeting place',
    'meetupCustomPlaceBody':
        'Use a place the suggestions missed. Only the name is shared; no coordinates are saved.',
    'meetupCustomPlaceLabel': 'Place name',
    'meetupCustomPlaceHint': 'For example: Outside the corner bakery',
    'meetupCustomPlaceAdd': 'Use this place',
    'meetupCustomPlaceInvalid': 'Enter a place name.',
    'meetupCategoryCustom': 'Custom place',

    // Changing the meeting point while the meet-up is active.
    'meetupChangePlace': 'Change meeting point',
    'meetupChangePlaceTitle': 'Suggest a new meeting point',
    'meetupChangePlaceBody':
        'The current meeting point stays until they accept.',
    'meetupChangePlaceSent': 'Change request sent',
    'meetupChangePlacePropose': 'Suggest this place',
    'meetupChangePlaceWaiting':
        'Waiting for {name} to respond to your new meeting point',
    'meetupChangePlaceIncomingTitle': '{name} suggested a new meeting point',
    'meetupChangePlaceIncomingBody':
        'The current meeting point stays until you decide.',
    'meetupChangePlaceAccept': 'Use new place',
    'meetupChangePlaceKeep': 'Keep current place',
    'meetupChangePlaceWithdraw': 'Withdraw request',
    'meetupChangePlaceDeclined': 'Current meeting point kept',
    'meetupChangePlaceAccepted': 'Meeting point updated',
    'meetupChangePlaceWithdrawn': 'Change request withdrawn',
    'meetupChangePlacePendingLabel': 'Proposed new place',
    'meetupChangePlaceNewPlace': 'New place: {place}',
    'meetupChangePlaceUnavailable':
        'The meeting point cannot be changed for this meet-up.',
    'meetupChangePlacePendingError': 'A change request is already pending.',
    'meetupChangePlaceNoPending': 'No change request is pending.',

    // Editing your own pending proposal while the other side is deciding.
    'meetupChangeProposal': 'Change meeting points',
    'meetupChangeProposalSend': 'Update meeting points',
    'meetupProposalUpdated': 'Meeting points updated',
    'meetupRefreshPlaces': 'Find places near me',
    'meetupProposalChanged': 'The proposed places were updated. Choose again.',

    // Spot me selfie capture.
    'meetupSpotMeSelfie': 'Take a selfie',
    'meetupSpotMeRetake': 'Retake selfie',
    'meetupSpotMeChecking': 'Checking selfie…',
    'meetupSpotMeSelfieHint':
        'Use your front camera and make sure you\'re the only person in the photo. Only the photo is shared.',
    'meetupSpotMeCameraUnavailable':
        'Camera is not available here. Add outfit details or a note instead.',
    'meetupSpotMeCameraDenied':
        'Camera access is needed for a selfie. You can add outfit details or a note instead.',
    'meetupSpotMeCaptureFailed':
        'Could not take the selfie. Try again, or add details instead.',
    'meetupOutfitColorUnspecified': 'Not specified',
    'meetupColorBlack': 'Black',
    'meetupColorWhite': 'White',
    'meetupColorGray': 'Gray',
    'meetupColorBeige': 'Beige',
    'meetupColorBrown': 'Brown',
    'meetupColorNavy': 'Navy',
    'meetupColorBlue': 'Blue',
    'meetupColorLightBlue': 'Light blue',
    'meetupColorGreen': 'Green',
    'meetupColorOlive': 'Olive',
    'meetupColorRed': 'Red',
    'meetupColorBurgundy': 'Burgundy',
    'meetupColorPink': 'Pink',
    'meetupColorYellow': 'Yellow',
    'meetupColorOrange': 'Orange',
    'meetupColorPurple': 'Purple',
    'meetupColorGold': 'Gold',
    'meetupColorSilver': 'Silver',
    'meetupColorMulticolor': 'Multicolor',
    'meetupOsmAttribution': '© OpenStreetMap contributors',
    'meetupGoogleAttribution': 'Google Maps',
    'meetupShowOtherPlaces': 'Show other places',

    // Consolidated meet-up hub: every in-person option in one place.
    'meetupHubTitle': 'Meet up',
    'meetupHubIntroTitle': 'Meet up with {name}',
    'meetupHubIntroBody':
        'Choose what helps right now. Nothing is shared until you choose it.',
    'meetupHubNothingYet': 'Nothing set yet',
    'meetupHubHowItWorks': 'How it works',
    'meetupHubExplainYouDo': 'You do',
    'meetupHubExplainNotNow': 'Not now',
    'meetupHubPlanBody':
        'Suggest public places nearby and agree on one together.',
    'meetupHubPlanFacts':
        'Your location is used once to find places · Not saved',
    'meetupHubPlanAction': 'Suggest places',
    'meetupHubPlanOpen': 'Open meet-up',
    'meetupHubPlanAgreed': 'Meeting point agreed: {place}',
    'meetupHubPlanProposedByMe': 'Waiting for {name} to choose',
    'meetupHubPlanProposedByOther': '{name} suggested a meeting point',
    'meetupHubExplainPlanDo': 'Suggest places and pick one together',
    'meetupHubLiveBody':
        '{name} sees your dot on a map. You see theirs if they share back.',
    'meetupHubLiveFacts': 'Uses your location · Stops on its own',
    'meetupHubLiveStart': 'Start sharing',
    'meetupHubLiveView': 'View map',
    'meetupHubLiveManage': 'Manage',
    'meetupHubLiveMutual': 'You are both sharing location',
    'meetupHubLiveOtherSharing': '{name} is sharing location',
    'meetupHubLiveSharing': 'You are sharing location',
    'meetupHubLiveSharingFor': 'You are sharing location {time}',
    'meetupHubLiveUntilOff': 'until you stop',
    'meetupHubLiveIdle': 'Not sharing',
    'meetupHubExplainLiveDo': 'Tap "Start sharing" and choose how long',
    'meetupHubCloseSection': 'When you are close',
    'meetupHubCloseBody': 'Quick ways to catch their eye — no map needed.',
    'meetupHubSignalTitle': 'Signal',
    'meetupHubSignalBody':
        'Wave, raise both hands, jump, or open your arms to catch their eye.',
    'meetupHubSignalFacts': 'They see your gesture · No location',
    'meetupHubSignalAction': 'Send a signal',
    'meetupHubSignalAgain': 'Send again',
    'meetupHubExplainSignalDo': 'Pick a gesture to show what you are doing',
    'meetupHubBeaconTitle': 'Beacon',
    'meetupHubBeaconBody':
        'Hold up your phone with a bright shape they can look for.',
    'meetupHubBeaconFacts': 'They see a shape on your screen · No location',
    'meetupHubBeaconAction': 'Show beacon',
    'meetupHubBeaconOpen': 'Open beacon',
    'meetupHubExplainBeaconDo': 'Hold your phone up, screen facing them',
    'meetupHubSpotTitle': 'Spot me',
    'meetupHubSpotBody':
        'Send a selfie and what you are wearing so they recognize you.',
    'meetupHubSpotFacts': 'Private to this match · No location',
    'meetupHubSpotAction': 'Send a Spot me',
    'meetupHubExplainSpotDo': 'Take a selfie, add what you wear, share',
    'meetupHubCompare': 'Compare these options',
    'meetupHubCompareTitle': 'How these work',
    'meetupHubCompareBody':
        'Signal, Beacon and Spot me never use your location. Live location is the only option that tracks your GPS.',
    'meetupHubCompareHelps': 'Best for',
    'meetupHubCompareSee': 'They see',
    'meetupHubCompareLasts': 'How it ends',
    'meetupHubCompareLocation': 'Location',
    'meetupHubCompareClose': 'Got it',
    'meetupHubPlanName': 'Meeting point',
    'meetupHubLiveName': 'Live location',
    'meetupHubComparePlanHelps': 'Agreeing where to meet',
    'meetupHubComparePlanSee': 'The public meeting point',
    'meetupHubComparePlanLasts': 'You end it',
    'meetupHubComparePlanLocation': 'Used once to find places',
    'meetupHubCompareLiveHelps': 'Being followed on a map',
    'meetupHubCompareLiveSee': 'Your moving dot',
    'meetupHubCompareLiveLasts': 'Stops at the time you chose',
    'meetupHubCompareLiveLocation': 'Uses your GPS',
    'meetupHubCompareSignalHelps': 'Catching their eye',
    'meetupHubCompareSignalSee': 'Your gesture',
    'meetupHubCompareSignalLasts': 'Turns off on its own',
    'meetupHubCompareSignalLocation': 'No location',
    'meetupHubCompareBeaconHelps': 'Being seen in a crowd',
    'meetupHubCompareBeaconSee': 'A bright shape',
    'meetupHubCompareBeaconLasts': 'Turns off on its own, or you hide it',
    'meetupHubCompareBeaconLocation': 'No location',
    'meetupHubCompareSpotHelps': 'Being recognized',
    'meetupHubCompareSpotSee': 'Your photo, outfit and note',
    'meetupHubCompareSpotLasts': 'Goes away on its own, or you hide it',
    'meetupHubCompareSpotLocation': 'No location',
    'meetupHubFooter':
        'These tools work only with {name}. You can use them in any order.',

    // Separator between the counters of a summary line.
    'sessionExpiredTitle': 'Your session has expired',
    'sessionExpiredBody':
        'Sign in again to keep using MatchMe. Your matches, chats and photos are safe.',
    'sessionExpiredSignInAgain': 'Sign in again',
    'summarySeparator': ' · ',
  };

  /// Public helper to get a built-in default translation for a key (used when the app must show text before localization is initialized)
  static String defaultTranslation(String key) {
    // NO-TRUNCATION POLICY: bracket fallback, never "key...".
    return _defaultTranslations[key] ?? '[$key]';
  }

  /// Indicates the source of the currently loaded translations.
  /// Used for cache invalidation (e.g., profile display labels).
  String get translationSource {
    if (isLoading) return 'loading';
    if (dbKeys.isNotEmpty) return 'db';
    if (strings.isNotEmpty) return 'fallback';
    return 'empty';
  }

  /// Formats a count as a full number with the locale's group separator
  /// ("12,480" in English, "12.480" in Spanish) — never "12k" or "3M".
  String formatCount(int n) {
    return NumberFormat.decimalPattern(currentLocale.toLanguageTag()).format(n);
  }
}

/// Snapshot of the persisted localization cache, read once during bootstrap
/// (before Supabase is up) so the first [Localization.build] can paint the
/// app with real strings and a non-empty language list on frame one.
class _WarmLaunchLocalization {
  final String langCode;

  /// The language the cached strings are actually in — see
  /// [LocalizationState.contentLanguageCode].
  final String contentLanguageCode;

  final Map<String, String> strings;
  final List<AppLanguage> supportedLanguages;

  const _WarmLaunchLocalization({
    required this.langCode,
    required this.contentLanguageCode,
    required this.strings,
    required this.supportedLanguages,
  });
}

// --- 3. The Notifier ---
@Riverpod(keepAlive: true)
class Localization extends _$Localization {
  /// One-shot warm-launch preload filled by [preloadForWarmLaunch] during
  /// bootstrap and consumed by the first [build]. Without it, the online
  /// initial state is `isLoading: true, supportedLanguages: []`, which trips
  /// the router's localization gate and holds the pulsating loader for the
  /// ~0.6-0.8s _initImpl needs to re-read the exact same SharedPreferences
  /// keys — on every online warm relaunch.
  static _WarmLaunchLocalization? _warmLaunchPreload;

  /// Decoded translations from [preloadForWarmLaunch], kept so `_init()`'s
  /// cache load doesn't re-read prefs and re-jsonDecode the same multi-MB
  /// blob during the first-frames window (a several-hundred-ms main-isolate
  /// hog that delays the first Home data paint). Consumed on first read.
  static Map<String, Map<String, String>>? _predecodedTranslations;

  /// Reads the persisted supported-languages list and cached translations
  /// straight from SharedPreferences. Touches no Supabase state, so it is
  /// safe to run in parallel with (or before) Supabase.initialize. Best-effort:
  /// any failure leaves the preload null and build() takes the normal path.
  static Future<void> preloadForWarmLaunch() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final langJson = prefs.getString('cached_supported_languages');
      if (langJson == null || langJson.isEmpty || langJson == '[]') {
        return; // genuine first run — nothing persisted to warm from
      }
      final List<AppLanguage> supported;
      try {
        final List<dynamic> jsonList = jsonDecode(langJson);
        supported = jsonList.map((item) {
          return AppLanguage(
            code: item['code'] as String? ?? '',
            displayName: item['displayName'] as String? ?? '',
            direction: (item['direction'] as String? ?? 'LTR') == 'RTL'
                ? TextDirection.rtl
                : TextDirection.ltr,
          );
        }).toList();
      } catch (_) {
        return;
      }
      if (supported.isEmpty) return;

      var langCode = prefs.getString('user_language_code');
      if (langCode == null ||
          langCode.isEmpty ||
          !supported.any((l) => l.code == langCode)) {
        // Mirror _initImpl's non-DB fallback: the device's language when the
        // app ships it, otherwise 'en'.
        langCode = resolveDeviceLanguageCode(
          supported.map((l) => l.code),
          WidgetsBinding.instance.platformDispatcher.locale,
        );
      }

      final strJson = prefs.getString('translations_$langCode');
      if (strJson == null || strJson.isEmpty) return;
      final Map<String, String> strings;
      try {
        final raw = jsonDecode(strJson) as Map<dynamic, dynamic>;
        final map = <String, String>{};
        raw.forEach((key, value) {
          final keyStr = key.toString();
          if (keyStr.startsWith('ads_test_')) return;
          map[keyStr] = value.toString();
        });
        if (map.isEmpty) return;
        strings = map;
      } catch (_) {
        return;
      }

      _warmLaunchPreload = _WarmLaunchLocalization(
        langCode: langCode,
        contentLanguageCode: resolveCachedContentLanguage(
          langCode: langCode,
          strings: strings,
          marker: prefs.getString(translationContentMarkerKey(langCode)),
        ),
        strings: strings,
        supportedLanguages: supported,
      );
      (_predecodedTranslations ??= {})[langCode] = strings;
    } catch (_) {
      // Best-effort: build() falls back to the normal loading path.
    }
  }

  // Keys that were provided by the DB in the most recent fetch
  Set<String> _lastFetchedDbKeys = <String>{};

  // Remember which DB keys we've warned about already to avoid log spam
  final Set<String> _missingDbKeysWarned = <String>{};
  StreamSubscription<MyUserUpdate>? _myUserSubscription;
  StreamSubscription<void>? _languageResyncSubscription;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _localeChangeInFlight = false;
  String? _localeChangeTarget;

  final LanguageChoiceStore _languageChoices = LanguageChoiceStore();

  // Bumped whenever setLocale applies a new locale. _initImpl captures the
  // value before its first await and must not repaint a locale that a
  // concurrent remote/local change already applied.
  int _localeGeneration = 0;

  // Guards against overlapping smart retranslations when the language
  // changes before the previous retranslation completes.
  bool _retranslationInProgress = false;

  // Dedup key for _updateLanguageInDatabase. Bootstrap fires it from both
  // _loadStringsAndUpdateState (after first fetch) AND from the auth
  // listener (syncLanguageAfterLogin). Without this guard each cold start
  // updates the DB twice and runs smart retranslation twice.
  // _lastSyncedLanguageExplicit records how far the last push went: a seed
  // must not dedup away a later explicit push of the same code (that push
  // is what flips users.preferred_language_explicit to true).
  String? _lastSyncedLanguageInDb;
  String? _lastSyncedLanguageUserId;
  bool _lastSyncedLanguageExplicit = false;

  // Storm guards for syncLanguageAfterLogin. Auth events (initialSession,
  // signedIn, tokenRefreshed) + pull-to-refresh + login screen can all fire
  // within the same second; each sync costs 2 writes + N reads. Without
  // coalescing, a dead/rotated refresh token turns every call into a
  // guaranteed failure and the retries DDoS Supabase into 429
  // (over_request_rate_limit), which then breaks every other provider.
  Future<void>? _languageSyncInFlight;
  DateTime? _lastLanguageSyncAttemptAt;
  String? _lastLanguageSyncAttemptLang;
  DateTime? _lastLanguageSyncFailureAt;
  static const Duration _languageSyncCooldown = Duration(seconds: 60);
  static const Duration _languageSyncFailureBackoff = Duration(minutes: 5);

  // Per-user record of the last language we *retranslated* for. Cold-start
  // cold start, where the user's preferred language is already what the DB
  // holds, was triggering a full 1.3s retranslate pass on every launch.
  // Gating on this — combined with the in-progress lock — makes the
  // retranslation effectively no-op when the language hasn't changed.
  String? _lastRetranslatedLanguage;
  String? _lastRetranslatedUserId;

  // Completes when _init has finished seeding the initial locale. Callers
  // (notably auth_provider.syncLanguageForAuthenticatedSession) can await
  // `whenInitialized` so they only push to the DB once the UI is in its
  // correct cold-start locale — otherwise the device-locale fallback races
  // the saved DB preference and we end up running the smart retranslation
  // pass twice on every launch.
  Completer<void>? _initCompleter;

  Future<void> get whenInitialized async {
    final completer = _initCompleter;
    if (completer == null || completer.isCompleted) return;
    return completer.future;
  }

  @override
  LocalizationState build() {
    _initCompleter = Completer<void>();
    ref.onDispose(() {
      _clearLanguageRealtimeSubscription();
      _myUserSubscription?.cancel();
      _myUserSubscription = null;
      _languageResyncSubscription?.cancel();
      _languageResyncSubscription = null;
      _authStateSubscription?.cancel();
      _authStateSubscription = null;
    });
    _authStateSubscription?.cancel();
    _authStateSubscription = Supabase.instance.client.auth.onAuthStateChange
        .listen(
          (event) {
            final authEvent = event.event;
            if (authEvent == AuthChangeEvent.signedOut) {
              _clearLanguageRealtimeSubscription();
              _lastSyncedLanguageInDb = null;
              _lastSyncedLanguageUserId = null;
              _lastRetranslatedLanguage = null;
              _lastRetranslatedUserId = null;
              // The next sign-in must be able to push immediately; these
              // guards belong to the previous session, not the device.
              _lastLanguageSyncAttemptAt = null;
              _lastLanguageSyncAttemptLang = null;
              _lastLanguageSyncFailureAt = null;
              _languageSyncInFlight = null;
            }
            _ensureLanguageRealtimeSubscription();
            if (authEvent == AuthChangeEvent.signedIn) {
              // A pending login-screen pick must reach the server before any
              // other device can pull the account's previous language.
              unawaited(
                syncLanguageAfterLogin().catchError((
                  Object error,
                  StackTrace stackTrace,
                ) {
                  debugPrint('[L10N] Sign-in language sync failed: $error');
                }),
              );
            } else {
              unawaited(_syncLanguageFromRemote());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('[LOCALE] Auth stream error: $error');
          },
        );
    _ensureLanguageRealtimeSubscription();
    unawaited(_syncLanguageFromRemote());
    _init();

    // One-shot warm-launch preload (filled by bootstrap): paint real cached
    // strings + language list on the very first frame so the router's
    // localization gate never trips. _init() above still runs to refresh
    // from DB in the background and to complete whenInitialized.
    final warmPreload = _warmLaunchPreload;
    if (warmPreload != null) {
      _warmLaunchPreload = null;
      final initialLang = warmPreload.supportedLanguages.firstWhere(
        (l) => l.code == warmPreload.langCode,
        orElse: () => warmPreload.supportedLanguages.first,
      );
      debugPrint(
        '[L10N] Warm-launch preload: ${initialLang.code} '
        '(${warmPreload.strings.length} strings, '
        '${warmPreload.supportedLanguages.length} languages)',
      );
      return LocalizationState(
        currentLocale: Locale(initialLang.code),
        textDirection: initialLang.direction,
        contentLanguageCode: warmPreload.contentLanguageCode,
        strings: warmPreload.strings,
        supportedLanguages: warmPreload.supportedLanguages,
        isLoading: false,
      );
    }

    // When offline, provide supported languages immediately to prevent loader flash.
    // The _init() will still run and update locale from SharedPreferences.
    // We use defaults here to avoid empty supportedLanguages causing loader in MatchMeApp.
    final isOffline = !offlineCacheManager.isSupabaseAvailable;
    final initialSupported = isOffline
        ? _defaultSupportedLanguages()
        : const <AppLanguage>[];
    final initialIsLoading = isOffline ? false : true;

    return LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: Map<String, String>.from(LocalizationState._defaultTranslations),
      supportedLanguages: initialSupported,
      isLoading: initialIsLoading,
    );
  }

  void _clearLanguageRealtimeSubscription() {
    // The subscription is owned by MyUserRealtimeService; nothing to tear
    // down here. The service drops the channel itself on sign-out.
  }

  /// Subscribes to the shared "my own user row" realtime channel.
  void _ensureLanguageRealtimeSubscription() {
    _myUserSubscription?.cancel();
    _myUserSubscription = MyUserRealtimeService.instance.updates.listen(
      (update) => unawaited(
        _onMyUserLanguageUpdate(update).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint('[L10N] Realtime language update failed: $error');
        }),
      ),
    );
    _languageResyncSubscription = MyUserRealtimeService.instance.resyncRequests
        .listen((_) {
          // Reconnected after missed events: flush any pending choice and
          // re-pull the account value.
          unawaited(
            syncLanguageAfterLogin().catchError((
              Object error,
              StackTrace stackTrace,
            ) {
              debugPrint('[L10N] Language resync failed: $error');
            }),
          );
        });
  }

  Future<void> _onMyUserLanguageUpdate(MyUserUpdate update) async {
    if (!update.changed('preferred_language') &&
        !update.changed('preferred_language_explicit')) {
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    // An unsynced local pick is newer than anything already on the server.
    // Apply it and retry the push instead of letting the old row win.
    final pending = await _pickPendingLanguage(userId);
    if (pending != null) {
      if (pending != state.currentLocale.languageCode) {
        await setLocale(pending, null, false);
      }
      unawaited(
        syncLanguageAfterLogin().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint('[L10N] Pending language retry failed: $error');
        }),
      );
      return;
    }

    // A trimmed UPDATE payload may omit unchanged columns, including the
    // explicit flag. Pull the authoritative row rather than guessing.
    if (!update.row.containsKey('preferred_language_explicit')) {
      await _syncLanguageFromRemote();
      return;
    }

    final remoteLanguage = update.row['preferred_language'] as String?;
    // Only an explicit in-app choice may move this device's UI.
    // Seeds (the column default or a device-derived value another
    // session wrote) must never override the device language.
    final remoteExplicit =
        update.row['preferred_language_explicit'] as bool? ?? false;
    if (!remoteExplicit) return;
    if (remoteLanguage == null || remoteLanguage.isEmpty) return;
    if (remoteLanguage == state.currentLocale.languageCode) return;
    if (_localeChangeInFlight && _localeChangeTarget == remoteLanguage) {
      return;
    }
    await setLocale(remoteLanguage, null, false);
  }

  /// Applies the account's explicit language, or replays an unsynced pick.
  ///
  /// Never seeds a value: callers that may write a non-explicit row go through
  /// [syncLanguageAfterLogin].
  Future<void> _syncLanguageFromRemote() async {
    if (!offlineCacheManager.isSupabaseAvailable) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final pending = await _pickPendingLanguage(userId);
      if (pending != null) {
        if (pending != state.currentLocale.languageCode) {
          await setLocale(pending, null, false);
        }
        if (!ref.mounted) return;
        // Every pull trigger is also a retry point for an offline pick.
        await syncLanguageAfterLogin();
        return;
      }

      final remote = await _fetchRemoteLanguagePreference(userId);
      if (!ref.mounted || remote == null) return;
      if (Supabase.instance.client.auth.currentUser?.id != userId) return;
      if (!remote.explicit) return;
      final remoteLanguage = remote.language;
      if (remoteLanguage == null || remoteLanguage.isEmpty) return;
      if (remoteLanguage == state.currentLocale.languageCode) return;
      if (!_supportsLanguage(remoteLanguage)) return;
      await setLocale(remoteLanguage, null, false);
    } catch (_) {}
  }

  Future<({String? language, bool explicit})?> _fetchRemoteLanguagePreference(
    String userId,
  ) async {
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('preferred_language, preferred_language_explicit')
          .eq('id', userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));
      if (Supabase.instance.client.auth.currentUser?.id != userId) return null;
      return (
        language: response?['preferred_language'] as String?,
        explicit: response?['preferred_language_explicit'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  bool _supportsLanguage(String languageCode) {
    final supported = state.supportedLanguages;
    if (supported.isEmpty) return true;
    return supported.any((language) => language.code == languageCode);
  }

  /// Reads the newest unconfirmed choice for [userId].
  ///
  /// A login-screen pick is newer than any pick saved before sign-out. Invalid
  /// codes (a language an admin removed) are discarded rather than replayed
  /// forever.
  Future<String?> _pickPendingLanguage(String userId) async {
    final loginPick = await _languageChoices.readLoginPick();
    final userPick = await _languageChoices.readUserPick(userId);

    var validLoginPick = loginPick;
    if (validLoginPick != null && !_supportsLanguage(validLoginPick)) {
      await _languageChoices.clearLoginPick(ifMatches: validLoginPick);
      validLoginPick = null;
    }
    var validUserPick = userPick;
    if (validUserPick != null && !_supportsLanguage(validUserPick)) {
      await _languageChoices.clearUserPick(userId, ifMatches: validUserPick);
      validUserPick = null;
    }

    if (validLoginPick != null) {
      // The login-screen pick was made after any signed-in pick that was still
      // waiting to sync, so it wins.
      if (validUserPick != null && validUserPick != validLoginPick) {
        await _languageChoices.clearUserPick(userId);
      }
      return validLoginPick;
    }
    return validUserPick;
  }

  Future<void> _init() async {
    try {
      await _initImpl();
    } finally {
      final completer = _initCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  Future<void> _initImpl() async {
    // A remote pull or a setLocale can apply a newer locale while this init is
    // awaiting I/O. Capturing the generation here stops the final state write
    // below from repainting the language this session already moved away from.
    final initGeneration = _localeGeneration;

    // Load missing keys display limit from config
    try {
      LocalizationState._missingKeysLimit = await appConfigService.getInt(
        'performance.missing_keys_display_limit',
        defaultValue: 20,
      );
    } catch (e) {
      // keep default
    }

    // Skip network-dependent init when offline to avoid hanging startup
    // for 10-30 seconds on TCP timeouts (WiFi with no internet).
    final isOffline = !offlineCacheManager.isSupabaseAvailable;

    List<AppLanguage> supported;
    if (isOffline) {
      supported = await _loadSupportedLanguagesFromCache();
    } else if (await _hasPersistedSupportedLanguages()) {
      // CACHE-FIRST startup (warm relaunch): a previous launch already
      // persisted the real supported-languages list (see
      // _cacheSupportedLanguages), so render it immediately instead of
      // blocking the whole app on a network round-trip. The router's
      // localization gate (`isLoading && supportedLanguages.isEmpty`) therefore
      // clears on the first frame rather than after _fetchSupportedLanguages
      // returns — this is what kept the loader on screen for ~1.3s. Refresh
      // from the server in the background so admin changes still land for the
      // next launch.
      supported = await _loadSupportedLanguagesFromCache();
      unawaited(_fetchSupportedLanguages());
    } else {
      // Genuine first run (no persisted list yet): render the built-in
      // default list (en/es/he) instantly and fetch the real list from the
      // server in the background. Blocking here kept the whole app behind
      // the router's localization gate for up to 5s on first launch.
      supported = _defaultSupportedLanguages();
      unawaited(_fetchSupportedLanguages());
    }

    final prefs = await SharedPreferences.getInstance();
    // The previous marker was device-wide and permanently "explicit"; pending
    // choices are now stored per login/user instead.
    await _languageChoices.removeLegacyPickedFlag();
    String? langCode = prefs.getString('user_language_code');
    if (langCode != null && !supported.any((l) => l.code == langCode)) {
      // A persisted code the app no longer ships: treat it as no saved choice.
      langCode = null;
    }

    if (langCode == null) {
      // Cold start with no saved choice on this device. The initial language
      // must follow the device's UI language — unless the account holds a
      // language the user actually picked in-app
      // (users.preferred_language_explicit). The column default ('en') and
      // the device-derived seeds are deliberately NOT consulted: they are not
      // choices, and treating them as one is what used to pin the UI to
      // English on a Spanish/Hebrew device. Seeds always mirror the UI
      // language anyway, so honoring only explicit values cannot race:
      //   1. _init resolves the device language,
      //   2. syncLanguageAfterLogin re-seeds the (non-explicit) row with it,
      //   3. _syncLanguageFromRemote sees a non-explicit row and leaves the
      //      device language alone.
      if (!isOffline) {
        final initUserId = Supabase.instance.client.auth.currentUser?.id;
        if (initUserId != null) {
          try {
            final remote = await Supabase.instance.client
                .from('users')
                .select('preferred_language, preferred_language_explicit')
                .eq('id', initUserId)
                .maybeSingle()
                .timeout(const Duration(seconds: 5));
            if (!ref.mounted) return;
            final remoteLang = remote?['preferred_language'] as String?;
            final remoteExplicit =
                remote?['preferred_language_explicit'] as bool? ?? false;
            if (remoteExplicit &&
                remoteLang != null &&
                remoteLang.isNotEmpty &&
                supported.any((l) => l.code == remoteLang)) {
              langCode = remoteLang;
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                '[L10N] DB preferred_language read failed in _init, falling back: $e',
              );
            }
          }
        }
      }
      if (langCode == null) {
        try {
          langCode = resolveDeviceLanguageCode(
            supported.map((lang) => lang.code),
            WidgetsBinding.instance.platformDispatcher.locale,
          );
        } catch (e) {
          langCode = 'en';
        }
      }
    }

    final AppLanguage initialLang = supported.firstWhere(
      (l) => l.code == langCode,
      orElse: () => supported.firstWhere(
        (l) => l.code == 'en',
        orElse: () => AppLanguage(code: 'en', displayName: 'English'),
      ),
    );

    // Prefer cache over DB to avoid slow timeouts when offline and to
    // prevent _initImpl from racing with setLocale (which would revert the
    // user's language choice after _initImpl completes).
    final cached = await _loadTranslationsFromCache(initialLang.code);
    if (cached.strings.isNotEmpty) {
      if (!ref.mounted) return;
      if (_localeGeneration != initGeneration) return;

      state = LocalizationState(
        currentLocale: Locale(initialLang.code),
        textDirection: initialLang.direction,
        contentLanguageCode: cached.contentLanguageCode,
        strings: cached.strings,
        supportedLanguages: supported,
        isLoading: false,
      );
      debugPrint(
        '[L10N] Translations loaded from cache for $langCode '
        '(${cached.strings.length} strings, content=${cached.contentLanguageCode})',
      );
      _syncNativeBackgroundNotificationStrings(cached.strings);

      // Refresh cache from DB in the background (only when online). The
      // stamp gate keeps this to 51 B unless the translations changed; a
      // cached English fallback still forces the repair download.
      if (offlineCacheManager.isSupabaseAvailable) {
        unawaited(
          _refreshTranslationCacheIfStale(
            initialLang.code,
            force:
                normalizeContentLanguageCode(cached.contentLanguageCode) !=
                normalizeContentLanguageCode(initialLang.code),
          ),
        );
      }
    } else {
      // No cache (genuine first run, or a language never opened before).
      // The bundled defaults are English-only, so painting them under a
      // Spanish/Hebrew device locale showed an English UI until a background
      // fetch landed — or forever when it failed. The router's localization
      // gate is already up while _init runs, so fetching the initial
      // language's strings here costs no extra loader: first paint lands in
      // the device's language. Anything slower than the timeout falls back to
      // the defaults plus the background load, exactly as before.
      //
      // The fallback is English, so the content language is English too and
      // the UI lays out left-to-right until the real translations arrive.
      // Laying the English fallback out right-to-left (Hebrew locale) is the
      // impossible state this must never ship.
      var strings = Map<String, String>.from(
        LocalizationState._defaultTranslations,
      );
      var contentLanguage = 'en';
      var loadedFromDb = false;
      if (initialLang.code != 'en' && offlineCacheManager.isSupabaseAvailable) {
        try {
          final stamp = await _fetchTranslationsStamp(initialLang.code);
          final fetched = await _fetchTranslationsFromDB(
            initialLang.code,
          ).timeout(const Duration(seconds: 6));
          if (fetched.hasLocalizedRows) {
            strings = fetched.strings;
            contentLanguage = resolveContentLanguageCode(
              localeCode: initialLang.code,
              hasLocalizedRows: true,
            );
            await _saveTranslationsToCache(
              initialLang.code,
              fetched.strings,
              contentLanguageCode: contentLanguage,
              stamp: stamp,
            );
            loadedFromDb = true;
          }
        } catch (e) {
          debugPrint(
            '[L10N] Initial translation fetch for $langCode failed, using bundled defaults: $e',
          );
        }
      }
      if (!ref.mounted) return;
      if (_localeGeneration != initGeneration) return;
      state = LocalizationState(
        currentLocale: Locale(initialLang.code),
        textDirection: initialLang.direction,
        contentLanguageCode: contentLanguage,
        strings: strings,
        supportedLanguages: supported,
        isLoading: false,
      );
      debugPrint(
        loadedFromDb
            ? '[L10N] First run: loaded DB translations for $langCode (${strings.length} strings)'
            : '[L10N] First run: using bundled default translations for $langCode, fetching DB set in background',
      );
      _syncNativeBackgroundNotificationStrings(strings);
      if (!loadedFromDb && offlineCacheManager.isSupabaseAvailable) {
        unawaited(_loadTranslationsInBackground(initialLang.code));
      }
    }
  }

  Future<List<AppLanguage>> _fetchSupportedLanguages() async {
    if (!offlineCacheManager.isSupabaseAvailable) {
      return _loadSupportedLanguagesFromCache();
    }
    try {
      final response = await PublicReferenceDataService.instance
          .fetchSupportedLanguages()
          .timeout(const Duration(seconds: 5));

      final languages = response.map((item) {
        final code = item['language_code'] as String? ?? '';
        // Direction comes from the code, not the payload. See
        // isRtlLanguageCode: a wrong or missing text_direction in
        // app_languages would otherwise flip the whole UI.
        return AppLanguage(
          code: code,
          displayName: item['display_name'] as String? ?? '',
        );
      }).toList();

      await _cacheSupportedLanguages(languages);
      return languages;
    } catch (e) {
      final cached = await _loadSupportedLanguagesFromCache();
      if (cached.isNotEmpty) return cached;
      return _defaultSupportedLanguages();
    }
  }

  Future<void> _cacheSupportedLanguages(List<AppLanguage> languages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = languages
          .map(
            (lang) => {
              'code': lang.code,
              'displayName': lang.displayName,
              'direction': lang.direction == TextDirection.rtl ? 'RTL' : 'LTR',
            },
          )
          .toList();
      await prefs.setString('cached_supported_languages', jsonEncode(jsonList));
    } catch (_) {}
  }

  /// True when a real supported-languages list has been persisted by a previous
  /// launch (via [_cacheSupportedLanguages]), as opposed to the built-in default
  /// fallback that [_loadSupportedLanguagesFromCache] returns when nothing is
  /// stored yet. Lets warm relaunches render immediately instead of blocking on
  /// a network round-trip; a genuine first run also renders instantly (built-in
  /// defaults) and only refreshes the list from the server in the background.
  Future<bool> _hasPersistedSupportedLanguages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('cached_supported_languages');
      return jsonStr != null && jsonStr.isNotEmpty && jsonStr != '[]';
    } catch (_) {
      return false;
    }
  }

  Future<List<AppLanguage>> _loadSupportedLanguagesFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('cached_supported_languages');
      if (jsonStr == null || jsonStr.isEmpty) {
        return _defaultSupportedLanguages();
      }
      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList.map((item) {
        return AppLanguage(
          code: item['code'] as String? ?? '',
          displayName: item['displayName'] as String? ?? '',
          direction: (item['direction'] as String? ?? 'LTR') == 'RTL'
              ? TextDirection.rtl
              : TextDirection.ltr,
        );
      }).toList();
    } catch (_) {
      return _defaultSupportedLanguages();
    }
  }

  /// The server's current translation version for [langCode], or null when
  /// the check cannot run. One 51 B row replaces a whole-table download.
  Future<String?> _fetchTranslationsStamp(String langCode) async {
    try {
      final row = await Supabase.instance.client
          .from('translations')
          .select('updated_at')
          .eq('locale', langCode)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle()
          .timeout(const Duration(seconds: 2));
      return row?['updated_at']?.toString();
    } catch (e) {
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        debugPrint('[L10N] Translation stamp check failed for $langCode: $e');
      }
      return null;
    }
  }

  /// Refreshes the cached translations only when the server stamp moved.
  ///
  /// A cached English fallback ([force]) must still be repaired immediately;
  /// every other start pays 51 B instead of downloading the whole table.
  /// When the stamp check keeps failing for 24 h, the full download is the
  /// fallback: the cache may be arbitrarily old by then.
  Future<void> _refreshTranslationCacheIfStale(
    String langCode, {
    bool force = false,
  }) async {
    if (!force) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedStamp = prefs.getString(translationStampKey(langCode));
        if (cachedStamp != null) {
          final stamp = await _fetchTranslationsStamp(langCode);
          if (stamp != null) {
            await prefs.setInt(
              translationStampCheckedAtKey(langCode),
              DateTime.now().millisecondsSinceEpoch,
            );
            if (stamp == cachedStamp) return;
            await _refreshTranslationCache(langCode, knownStamp: stamp);
            return;
          }
          final checkedAtMs = prefs.getInt(
            translationStampCheckedAtKey(langCode),
          );
          final checkedAt = checkedAtMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(checkedAtMs);
          if (checkedAt != null &&
              DateTime.now().difference(checkedAt) < _translationStampTtl) {
            // Cannot verify right now: keep the cached strings. The TTL
            // guarantees a full download eventually.
            return;
          }
        }
      } catch (e) {
        debugPrint('[L10N] Translation stamp gate failed for $langCode: $e');
      }
    }
    await _refreshTranslationCache(langCode);
  }

  /// Background-refresh translation cache from DB (only call when online).
  ///
  /// The cache is only written when the server actually returned rows for the
  /// locale: saving the English fallback under a Hebrew cache key would make
  /// the next launch paint English text in an RTL layout, and it would stick
  /// there until the next successful fetch.
  ///
  /// The fresh strings are applied to the live state as well, so a member
  /// whose cached copy was an English fallback sees the real translations
  /// without having to restart the app.
  Future<void> _refreshTranslationCache(
    String langCode, {
    String? knownStamp,
  }) async {
    try {
      final stamp = knownStamp ?? await _fetchTranslationsStamp(langCode);
      final fetched = await _fetchTranslationsFromDB(langCode);
      if (!fetched.hasLocalizedRows) return;
      final contentLanguage = resolveContentLanguageCode(
        localeCode: langCode,
        hasLocalizedRows: true,
      );
      await _saveTranslationsToCache(
        langCode,
        fetched.strings,
        contentLanguageCode: contentLanguage,
        stamp: stamp,
      );
      if (!ref.mounted) return;
      if (state.currentLocale.languageCode != langCode) return;
      state = state.copyWith(
        strings: fetched.strings,
        dbKeys: _lastFetchedDbKeys,
        contentLanguageCode: contentLanguage,
      );
      _syncNativeBackgroundNotificationStrings(fetched.strings);
    } catch (_) {}
  }

  /// First-run background load: fetch the full translation set for
  /// [langCode] from the DB, persist it to the local cache, and update the
  /// in-memory state so the UI converges from the bundled defaults to the
  /// server set without a reload.
  Future<void> _loadTranslationsInBackground(String langCode) async {
    try {
      final stamp = await _fetchTranslationsStamp(langCode);
      final fetched = await _fetchTranslationsFromDB(langCode);
      final contentLanguage = resolveContentLanguageCode(
        localeCode: langCode,
        hasLocalizedRows: fetched.hasLocalizedRows,
      );
      if (fetched.hasLocalizedRows) {
        await _saveTranslationsToCache(
          langCode,
          fetched.strings,
          contentLanguageCode: contentLanguage,
          stamp: stamp,
        );
      }
      if (!ref.mounted) return;
      // The user may have switched locale while the fetch was in flight; in
      // that case the setLocale path owns the state update for the new code.
      if (state.currentLocale.languageCode != langCode) return;
      state = state.copyWith(
        strings: fetched.strings,
        dbKeys: _lastFetchedDbKeys,
        contentLanguageCode: contentLanguage,
      );
      _syncNativeBackgroundNotificationStrings(fetched.strings);
      debugPrint(
        '[L10N] Background DB translations applied for $langCode '
        '(${fetched.strings.length} strings, content=$contentLanguage)',
      );
    } catch (e) {
      debugPrint('[L10N] Background DB translation load failed: $e');
    }
  }

  /// Public method: force-refresh translations from the DB for the current
  /// locale and update the in-memory state so the UI reflects admin changes
  /// without switching locales.
  Future<void> refreshTranslations() async {
    final currentLang = state.currentLocale.languageCode;
    if (!offlineCacheManager.isSupabaseAvailable) return;
    final stamp = await _fetchTranslationsStamp(currentLang);
    final fetched = await _fetchTranslationsFromDB(currentLang);
    final contentLanguage = resolveContentLanguageCode(
      localeCode: currentLang,
      hasLocalizedRows: fetched.hasLocalizedRows,
    );
    if (fetched.hasLocalizedRows) {
      await _saveTranslationsToCache(
        currentLang,
        fetched.strings,
        contentLanguageCode: contentLanguage,
        stamp: stamp,
      );
    }
    if (!ref.mounted) return;
    // The locale may have changed while the fetch was in flight; setLocale
    // owns the state update in that case, and painting these older strings
    // would leave the new locale showing the previous language.
    if (state.currentLocale.languageCode != currentLang) return;
    state = state.copyWith(
      strings: fetched.strings,
      dbKeys: _lastFetchedDbKeys,
      contentLanguageCode: contentLanguage,
    );
    _syncNativeBackgroundNotificationStrings(fetched.strings);
  }

  List<AppLanguage> _defaultSupportedLanguages() {
    return [
      AppLanguage(
        code: 'en',
        displayName: 'English',
        direction: TextDirection.ltr,
      ),
      AppLanguage(
        code: 'es',
        displayName: 'Español',
        direction: TextDirection.ltr,
      ),
      AppLanguage(
        code: 'he',
        displayName: 'עברית',
        direction: TextDirection.rtl,
      ),
    ];
  }

  /// Fetches the translation rows for [langCode] and merges them over the
  /// bundled English defaults.
  ///
  /// [hasLocalizedRows] tells the caller whether the server actually returned
  /// rows for the locale. When it is false every value in [strings] is the
  /// English fallback, so the UI must lay out left-to-right — and the cache
  /// must not be written under this locale's key.
  Future<({Map<String, String> strings, bool hasLocalizedRows})>
  _fetchTranslationsFromDB(String langCode) async {
    // Skip DB call when offline to avoid 50s auth timeout.
    if (!offlineCacheManager.isSupabaseAvailable) {
      debugPrint('[L10N] Skipping DB fetch for $langCode (offline)');
      return (strings: <String, String>{}, hasLocalizedRows: false);
    }

    final allStrings = <String, String>{};
    final fetchStart = DateTime.now();
    // Reset before the fetch: a failed fetch must never leave the previous
    // locale's DB keys behind, they would make a failed fetch look successful.
    _lastFetchedDbKeys = <String>{};

    // Fetch from 'translations' table only
    try {
      final responseTranslations = await Supabase.instance.client
          .from('translations')
          .select('key, value')
          .eq('locale', langCode);

      for (var item in responseTranslations) {
        final key = item['key'] as String?;
        if (key == null) continue;
        // Strip ad-hoc test fixtures (e.g. `ads_test_1777449306261_body`) so
        // they never reach the user-facing string table nor the missing-keys
        // warning log. Production ad keys do not match this prefix.
        if (key.startsWith('ads_test_')) continue;
        allStrings[key] = item['value'];
      }

      // Remember which keys came from the DB so we can detect and log missing DB translations
      _lastFetchedDbKeys = allStrings.keys.toSet();

      // Log missing keys compared to our built-in defaults so it's visible in logs
      if (_lastFetchedDbKeys.isEmpty) {
        debugPrint(
          'No translations fetched from DB for locale: $langCode (elapsed=${DateTime.now().difference(fetchStart).inMilliseconds}ms)',
        );
      } else {
        final defaultKeys = LocalizationState._defaultTranslations.keys.toSet();
        // Drop ad-hoc test ad fixtures (e.g. `ads_test_1777449306261_body`)
        // from the missing-keys check. They live in the source-code defaults
        // as historical leftovers, but they are never localised in the DB
        // nor displayed in production; reporting them as missing on every
        // cold start is pure log noise.
        final productionDefaultKeys = defaultKeys
            .where((k) => !k.startsWith('ads_test_'))
            .toSet();
        final missing = productionDefaultKeys.difference(_lastFetchedDbKeys);
        final newlyMissing = missing
            .where((k) => !_missingDbKeysWarned.contains(k))
            .toList();
        if (newlyMissing.isNotEmpty) {
          _missingDbKeysWarned.addAll(newlyMissing);
          debugPrint(
            'Missing DB translation keys for $langCode: (count=${newlyMissing.length}) ${newlyMissing.take(20).toList()} (elapsed=${DateTime.now().difference(fetchStart).inMilliseconds}ms)',
          );
        }
        // Note: Fetch success is logged by the caller (setLocale or _init)
      }
    } catch (e) {
      // Suppress auth/RLS failures (dead refresh token, 42501) — cache
      // fallback below covers the UI, no need to spam release logs.
      if (!isAuthRateLimitFailure(e) && !isExpectedOfflineFailure(e)) {
        debugPrint(
          'Translation DB fetch failed for $langCode: $e (elapsed=${DateTime.now().difference(fetchStart).inMilliseconds}ms)',
        );
      }
    }

    // Merge with code defaults to ensure every key has a fallback
    final merged = Map<String, String>.from(
      LocalizationState._defaultTranslations,
    );
    merged.addAll(allStrings); // DB overrides defaults when present

    return (strings: merged, hasLocalizedRows: allStrings.isNotEmpty);
  }

  /// Reads the cached translations for [langCode] together with the language
  /// they are actually in.
  ///
  /// The content language is read from the marker written next to the cache.
  /// Legacy caches have no marker: their values are compared with the bundled
  /// English defaults to find out whether they hold translated rows at all.
  Future<({Map<String, String> strings, String contentLanguageCode})>
  _loadTranslationsFromCache(String langCode) async {
    // Fast path: the warm-launch bootstrap already decoded this language's
    // blob. Reuse it instead of re-reading SharedPreferences and re-decoding
    // several megabytes of JSON while the first Home frames are painting.
    final predecoded = _predecodedTranslations?.remove(langCode);
    if (predecoded != null && predecoded.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final dbJson = prefs.getString('translations_${langCode}_dbkeys');
        if (dbJson != null) {
          try {
            final List<dynamic> keys = jsonDecode(dbJson);
            _lastFetchedDbKeys = keys
                .map((e) => e.toString())
                .where((k) => !k.startsWith('ads_test_'))
                .toSet();
          } catch (e) {
            // ignore parse errors
          }
        } else {
          _lastFetchedDbKeys = predecoded.keys.toSet();
        }
        final content = resolveCachedContentLanguage(
          langCode: langCode,
          strings: predecoded,
          marker: prefs.getString(translationContentMarkerKey(langCode)),
        );
        return (
          strings: Map<String, String>.from(predecoded),
          contentLanguageCode: content,
        );
      } catch (e) {
        // ignore prefs errors — strings themselves are already in hand
        return (
          strings: Map<String, String>.from(predecoded),
          contentLanguageCode: resolveCachedContentLanguage(
            langCode: langCode,
            strings: predecoded,
          ),
        );
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('translations_$langCode');
      if (jsonString != null) {
        final map = <String, String>{};
        final raw = jsonDecode(jsonString) as Map<dynamic, dynamic>;
        raw.forEach((key, value) {
          final keyStr = key.toString();
          // Drop any cached test-ad keys (see _fetchTranslationsFromDB for rationale).
          if (keyStr.startsWith('ads_test_')) return;
          map[keyStr] = value.toString();
        });
        // also try to load saved DB keys for accurate logging
        final dbJson = prefs.getString('translations_${langCode}_dbkeys');
        if (dbJson != null) {
          try {
            final List<dynamic> keys = jsonDecode(dbJson);
            _lastFetchedDbKeys = keys
                .map((e) => e.toString())
                .where((k) => !k.startsWith('ads_test_'))
                .toSet();
          } catch (e) {
            // ignore parse errors
          }
        } else {
          _lastFetchedDbKeys = map.keys.toSet();
        }
        final content = resolveCachedContentLanguage(
          langCode: langCode,
          strings: map,
          marker: prefs.getString(translationContentMarkerKey(langCode)),
        );
        return (strings: map, contentLanguageCode: content);
      }
    } catch (e) {
      // Ignore cache read errors
    }
    return (strings: <String, String>{}, contentLanguageCode: 'en');
  }

  /// Persists the translation strings for [langCode] together with the
  /// language they are really in.
  ///
  /// The cache is only written when [contentLanguageCode] matches the locale:
  /// saving the English fallback under a Hebrew cache key would make the next
  /// launch paint English text in an RTL layout, and the damage would stick
  /// there until a successful fetch overwrote it.
  Future<void> _saveTranslationsToCache(
    String langCode,
    Map<String, String> strings, {
    required String contentLanguageCode,
    String? stamp,
  }) async {
    if (normalizeContentLanguageCode(contentLanguageCode) !=
        normalizeContentLanguageCode(langCode)) {
      debugPrint(
        '[L10N] Refusing to cache $langCode strings that are actually '
        '${normalizeContentLanguageCode(contentLanguageCode)} — the cache would '
        'render them in the wrong direction',
      );
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(strings);
      await prefs.setString('translations_$langCode', jsonString);
      // Save the DB-provided keys as well so we can detect missing DB translations when loading from cache
      try {
        final dbJson = jsonEncode(_lastFetchedDbKeys.toList());
        await prefs.setString('translations_${langCode}_dbkeys', dbJson);
      } catch (e) {
        // ignore
      }
      // Record which language the cached blob is really in, so the next
      // launch can lay it out correctly even when the blob is a fallback.
      try {
        await prefs.setString(
          translationContentMarkerKey(langCode),
          contentLanguageCode,
        );
      } catch (e) {
        // ignore
      }
      // Pair the blob with the version it came from. The stamp was read
      // before the download, so a change in between can only make the next
      // start refresh again, never skip an update.
      if (stamp != null) {
        try {
          await prefs.setString(translationStampKey(langCode), stamp);
          await prefs.setInt(
            translationStampCheckedAtKey(langCode),
            DateTime.now().millisecondsSinceEpoch,
          );
        } catch (e) {
          // ignore
        }
      }
    } catch (e) {
      // Ignore cache save errors
    }
  }

  void _syncNativeBackgroundNotificationStrings(Map<String, String> strings) {
    // Persist the "MatchMe Active" foreground notification title/text in the
    // user's current display language so the Android service can show it
    // localized even after process death / reboot. Also syncs the chat-card
    // copy the service needs when it has to build a card itself.
    // Best-effort, never throw.
    try {
      final title =
          strings['bgNotificationTitle'] ??
          LocalizationState._defaultTranslations['bgNotificationTitle'] ??
          'MatchMe Active';
      final text =
          strings['bgNotificationText'] ??
          LocalizationState._defaultTranslations['bgNotificationText'] ??
          'You are visible and background matching is enabled.';
      // The service picks a slot by the unread count alone, so the plural form
      // for each count has to be resolved here, in the content language.
      // `{count}` / `{name}` stay as tokens: the service fills the real number
      // and name when the card is built.
      String nativeForm(String key, int count) =>
          state.getPluralString(key, count, displayValue: '{count}');
      Map<String, String> nativeForms(String key) => {
        'one': nativeForm(key, 1),
        'two': nativeForm(key, 2),
        'other': nativeForm(key, 5),
      };
      unawaited(
        BackgroundService.setNativeBackgroundNotificationStrings(
          title: title,
          text: text,
          chatCopy: {
            'messagesTitle': nativeForms('pushMessagesTitle'),
            'openToReadBody': nativeForms('pushOpenToReadBody'),
          },
        ),
      );
    } catch (_) {}
  }

  Future<void> setLocale(
    String langCode, [
    List<AppLanguage>? supported,
    bool syncToDatabase = true,
  ]) async {
    if (_localeChangeInFlight && _localeChangeTarget == langCode) return;
    _localeChangeInFlight = true;
    _localeChangeTarget = langCode;
    state = state.copyWith(isLoading: true);
    try {
      final supportedLanguages = supported ?? state.supportedLanguages;
      if (supportedLanguages.isEmpty && supported == null) {
        final fetchedLanguages = await _fetchSupportedLanguages();
        return await setLocale(langCode, fetchedLanguages, syncToDatabase);
      }

      final AppLanguage lang = supportedLanguages.firstWhere(
        (l) => l.code == langCode,
        orElse: () => supportedLanguages.firstWhere((l) => l.code == 'en'),
      );

      // First check cache - if we already have translations for this language, use them
      final cached = await _loadTranslationsFromCache(lang.code);
      Map<String, String> strings;
      // The language the strings are really in. A cached blob can hold the
      // English fallback (written while the server was unreachable), in which
      // case the UI has to lay out left-to-right.
      String contentLanguage;

      if (cached.strings.isNotEmpty) {
        // Use cached translations - they're faster and avoid DB round-trip
        strings = cached.strings;
        contentLanguage = cached.contentLanguageCode;
        debugPrint(
          '[L10N] Using cached translations for $langCode '
          '(${strings.length} strings, content=$contentLanguage)',
        );

        // If online and this is not English, refresh the cache in the
        // background so any corrupted cache (e.g. English defaults saved
        // during a previous offline session) gets overwritten — and applied
        // right away, so the member is not stuck on the English fallback.
        if (langCode != 'en' && offlineCacheManager.isSupabaseAvailable) {
          unawaited(
            _refreshTranslationCacheIfStale(
              langCode,
              force:
                  normalizeContentLanguageCode(contentLanguage) !=
                  normalizeContentLanguageCode(langCode),
            ),
          );
        }
      } else {
        // No cache - fetch from DB (skipped when offline to avoid
        // corrupting the cache with English fallback text).
        final isOnline = offlineCacheManager.isSupabaseAvailable;
        if (!isOnline) {
          debugPrint(
            '[L10N] Cannot switch to $langCode: offline and no cached translations',
          );
          state = state.copyWith(isLoading: false);
          return;
        }
        final stamp = await _fetchTranslationsStamp(lang.code);
        final fetched = await _fetchTranslationsFromDB(lang.code);
        strings = fetched.strings;
        contentLanguage = resolveContentLanguageCode(
          localeCode: lang.code,
          hasLocalizedRows: fetched.hasLocalizedRows,
        );
        // Save to cache for future use (only real translations are cached).
        if (fetched.hasLocalizedRows) {
          await _saveTranslationsToCache(
            lang.code,
            strings,
            contentLanguageCode: contentLanguage,
            stamp: stamp,
          );
        }
        debugPrint(
          '[L10N] Fetched translations from DB for $langCode '
          '(${strings.length} strings, content=$contentLanguage)',
        );
      }

      // Respect provider lifecycle: if disposed while awaiting, bail out safely.
      if (!ref.mounted) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_language_code', lang.code);

      // Record the choice until the server row confirms it. The login-screen
      // pick is device-level because there is no account yet; a signed-in pick
      // is scoped to that account so it cannot leak into another session. A
      // signed-in pick also supersedes a leftover login-screen pick.
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (syncToDatabase) {
        if (currentUserId != null) {
          await _languageChoices.writeUserPick(currentUserId, lang.code);
        } else {
          await _languageChoices.writeLoginPick(lang.code);
        }
      }
      if (!ref.mounted) return;

      // Update UI immediately — don't block on DB sync.
      _localeGeneration++;
      state = state.copyWith(
        currentLocale: Locale(lang.code),
        textDirection: lang.direction,
        contentLanguageCode: contentLanguage,
        strings: strings,
        supportedLanguages: supportedLanguages,
        isLoading: false,
        dbKeys: _lastFetchedDbKeys,
      );
      _syncNativeBackgroundNotificationStrings(strings);

      // Sync preferred_language to the database in the background.
      // This can block for 50+ seconds when offline (auth timeout), so
      // never await it here. A failed/offline push keeps the pending marker
      // for the next sync trigger.
      if (syncToDatabase && currentUserId != null) {
        // This path only runs for in-app pickers (syncToDatabase=true), so
        // the row is being marked as an explicit choice.
        unawaited(_updateLanguageInDatabase(lang.code, explicit: true));
      } else if (syncToDatabase) {
        debugPrint(
          '[L10N] Login-screen pick stored; will be pushed as explicit after sign-in',
        );
      }
    } finally {
      if (_localeChangeTarget == langCode) {
        _localeChangeInFlight = false;
        _localeChangeTarget = null;
      }
    }
  }

  /// Updates the user's preferred language in the database and all their chat translation settings.
  ///
  /// [explicit] is true only for in-app language picks. Seeds (the startup
  /// device-language resolution, syncLanguageAfterLogin on a device where the
  /// user never picked) still write the value so notifications and broadcasts
  /// target the right locale, but they must never mark the row explicit and
  /// must never overwrite a value the user did pick.
  ///
  /// Returns true when the server row is confirmed to hold the requested
  /// value/flag; a false return keeps the pending-choice marker so the next
  /// sync trigger retries.
  Future<bool> _updateLanguageInDatabase(
    String langCode, {
    required bool explicit,
  }) async {
    // Skip entirely when offline to avoid noisy SocketException logs.
    if (!offlineCacheManager.isSupabaseAvailable) return false;
    // A dead/rotated refresh token means every authenticated call fails.
    // Don't even start — the pre-check + 2 UPDATEs + retranslation scan
    // would just add fuel to a 429 rate-limit spiral.
    if (Supabase.instance.client.auth.currentSession == null) return false;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        return false;
      }

      // Skip if we already pushed this exact language for this user during
      // the current session. Multiple callers (locale init,
      // syncLanguageAfterLogin, home pull-to-refresh) otherwise duplicate
      // the same UPDATE + smart-retranslation pass on cold start. An explicit
      // push is never deduped away by an earlier seed of the same code —
      // that push is what records the choice itself.
      if (_lastSyncedLanguageInDb == langCode &&
          _lastSyncedLanguageUserId == userId &&
          (!explicit || _lastSyncedLanguageExplicit)) {
        debugPrint(
          '[L10N] Skipping DB update: language already synced this session',
        );
        if (explicit) {
          await _languageChoices.clearConfirmed(userId, langCode);
        }
        return true;
      }

      // Cold-start short-circuit: if the DB already stores the language the
      // UI is about to use, do nothing. Without this, every launch re-runs
      // the UPDATE + smart-retranslation pass even when nothing changed,
      // which on the moto g54 5G added a noticeable 1+ second after the
      // first frame was already rendered.
      if (!ref.mounted) return false;
      String? stored;
      var storedExplicit = false;
      try {
        final existing = await Supabase.instance.client
            .from('users')
            .select('preferred_language, preferred_language_explicit')
            .eq('id', userId)
            .maybeSingle();
        if (!ref.mounted) return false;
        stored =
            (existing == null
                    ? null
                    : existing['preferred_language'] as String?)
                ?.trim();
        storedExplicit = existing == null
            ? false
            : (existing['preferred_language_explicit'] as bool? ?? false);
      } catch (e) {
        // When the pre-check itself is rejected (dead session, 429 rate
        // limit, RLS 42501), the UPDATE below is guaranteed to fail too —
        // abort now and back off instead of doubling the request storm.
        if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
          _lastLanguageSyncFailureAt = DateTime.now();
          debugPrint(
            '[L10N] Skipping DB update: pre-check failed with auth/rate-limit, backing off: $e',
          );
          return false;
        }
        debugPrint(
          '[L10N] Could not pre-check stored language, proceeding with update: $e',
        );
      }

      final valueChanged = stored != langCode;
      final flagNeedsSet = explicit && !storedExplicit;

      if (!valueChanged && !flagNeedsSet) {
        debugPrint(
          '[L10N] Skipping DB update: language already stored (no change)',
        );
        _lastSyncedLanguageInDb = langCode;
        _lastSyncedLanguageUserId = userId;
        _lastSyncedLanguageExplicit = storedExplicit;
        if (explicit) {
          // The row already holds the choice; the local marker is confirmed.
          await _languageChoices.clearConfirmed(userId, langCode);
        }
        // NOTE: Do NOT set _lastRetranslatedLanguage here. That flag is only set
        // after _retranslateAllMessages() actually completes. Setting it here
        // would cause a subsequent call to _retranslateAllMessages() with the same
        // language to skip due to the dedup guard, even though retranslation never
        // actually happened. This bug manifests on the 3rd+ language switch when
        // the user switches to a previously-used language that's already in the DB.
        return true;
      }

      if (!valueChanged) {
        // Same value, but never recorded as an explicit choice: the user just
        // confirmed the language that was only a device-derived seed. Record
        // the choice so it survives fresh installs and syncs to other
        // devices. Value unchanged -> no chats/retranslation pass.
        try {
          await Supabase.instance.client
              .from('users')
              .update({'preferred_language_explicit': true})
              .eq('id', userId);
        } catch (e) {
          if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
            _lastLanguageSyncFailureAt = DateTime.now();
          }
          debugPrint('[L10N] Could not mark stored language as explicit: $e');
          return false;
        }
        _lastSyncedLanguageInDb = langCode;
        _lastSyncedLanguageUserId = userId;
        _lastSyncedLanguageExplicit = true;
        await _languageChoices.clearConfirmed(userId, langCode);
        debugPrint('[L10N] Marked $langCode as an explicit language choice');
        return true;
      }

      if (!explicit && storedExplicit) {
        // A device-derived seed must never overwrite an explicit choice.
        debugPrint(
          '[L10N] Skipping DB update: stored language was explicitly chosen by the user',
        );
        return false;
      }

      debugPrint(
        '[L10N] Updating preferred_language to $langCode (explicit: $explicit)',
      );

      try {
        // Update users.preferred_language; explicit picks also record that
        // this is a real choice (seeds leave the flag untouched/false).
        await Supabase.instance.client
            .from('users')
            .update({
              'preferred_language': langCode,
              if (explicit) 'preferred_language_explicit': true,
            })
            .eq('id', userId);

        // Update translation_language for all user's chats
        await Supabase.instance.client
            .from('chats')
            .update({'translation_language': langCode})
            .eq('user_id', userId);
      } catch (e) {
        // Auth/rate-limit/RLS rejection: back off, don't run retranslation.
        if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
          _lastLanguageSyncFailureAt = DateTime.now();
          debugPrint(
            '[L10N] Skipping DB update: write rejected with auth/rate-limit, backing off: $e',
          );
          return false;
        }
        rethrow;
      }

      _lastSyncedLanguageInDb = langCode;
      _lastSyncedLanguageUserId = userId;
      _lastSyncedLanguageExplicit = explicit;
      if (explicit) {
        await _languageChoices.clearConfirmed(userId, langCode);
      }

      debugPrint('[L10N] Successfully updated language in database');
      debugPrint('[L10N] Synced language preference to database: $langCode');

      // Reset any TranslationProxy cooldown before retranslating — a previous
      // burst of per-bubble proxy calls may have triggered a 5-minute lockout.
      // The language switch is an intentional user action that should always
      // be able to translate, so we clear the lockout here.
      TranslationProxy.reset();

      // Retranslate all existing messages to the new language
      await _retranslateAllMessages(userId, langCode);
      // Full success — lift any earlier failure backoff.
      _lastLanguageSyncFailureAt = null;
      return true;
    } catch (e) {
      if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
        _lastLanguageSyncFailureAt = DateTime.now();
      }
      debugPrint('[L10N] Error updating language in database: $e');
      // Don't throw - language update is not critical for UI to continue
      return false;
    }
  }

  /// Retranslates the LAST incoming message for each chat when UI language changes
  /// Uses Case A/B/C logic to determine if translation is needed:
  /// - Case A: newUI != detected_source AND newUI != translated_target -> Call translate-proxy
  /// - Case B: newUI == detected_source -> Show original (no AI call)
  /// - Case C: newUI == translated_target -> Reuse existing (no AI call)
  Future<void> _retranslateAllMessages(String userId, String langCode) async {
    if (_retranslationInProgress) {
      debugPrint(
        '[L10N] Retranslation already in progress, skipping redundant call for $langCode',
      );
      return;
    }
    // Skip the entire pass when the active language for this user is the
    // one we already retranslated to. Cold start fires this path every time
    // a user has a saved preferred language; without this guard we'd run a
    // 1.3s DB scan + AI calls on every launch.
    if (_lastRetranslatedLanguage == langCode &&
        _lastRetranslatedUserId == userId) {
      debugPrint(
        '[L10N] Retranslation skipped: language already applied this session',
      );
      return;
    }
    _retranslationInProgress = true;
    try {
      debugPrint(
        '[L10N] Starting smart retranslation of last messages to $langCode',
      );
      final localDb = await LocalDbService.instance;

      // Get all the user's chats with translation enabled
      final chatsResponse = await Supabase.instance.client
          .from('chats')
          .select('match_id, translation_enabled, translation_language')
          .eq('user_id', userId)
          .eq('translation_enabled', true);

      // Verify each match exists and user is authorized
      final List<dynamic> validChats = [];
      for (final chatRow in (chatsResponse as List<dynamic>)) {
        final matchId = chatRow['match_id'] as String;
        try {
          final matchResponse = await Supabase.instance.client
              .from('matches')
              .select('id, user1_id, user2_id')
              .eq('id', matchId)
              .maybeSingle();

          if (matchResponse == null) {
            debugPrint(
              '[L10N] CRITICAL: Chat has match_id $matchId but match does not exist in matches table. Skipping.',
            );
            continue;
          }

          final user1Id = matchResponse['user1_id'] as String?;
          final user2Id = matchResponse['user2_id'] as String?;

          if (userId != user1Id && userId != user2Id) {
            debugPrint(
              '[L10N] CRITICAL: User $userId is not a participant in match $matchId (user1=$user1Id, user2=$user2Id). Skipping.',
            );
            continue;
          }

          validChats.add(chatRow);
        } catch (e) {
          debugPrint('[L10N] Error validating match $matchId: $e');
          continue;
        }
      }

      final chats = validChats;

      if (chats.isEmpty) {
        debugPrint('[L10N] No valid translation-enabled chats found');
        return;
      }

      debugPrint(
        '[L10N] Found ${chats.length} valid translation-enabled chats, checking last messages',
      );

      int translatedCount = 0;
      int skippedCaseB = 0; // source matches UI
      int skippedCaseC = 0; // already has translation

      // For each chat, only check and translate the LAST incoming message
      // BUT ONLY if it is also the absolute last message in the chat (most recent overall)
      // This is important for the message preview in Recent Chats which needs to reflect
      // the language change immediately. If it's not the absolute last message, skip and
      // let it be translated when the user enters the chat.
      for (final chat in chats) {
        final matchId = chat['match_id'] as String;

        try {
          // First, get the absolute last message in the chat (regardless of sender)
          final absoluteLastResponse = await Supabase.instance.client
              .from('chat_messages')
              .select('id, sender_id')
              .eq('match_id', matchId)
              .order('created_at', ascending: false)
              .limit(1);

          if (absoluteLastResponse.isEmpty) {
            continue; // No messages in this chat
          }

          final absoluteLastMessageId = absoluteLastResponse[0]['id'] as String;
          final absoluteLastSenderId =
              absoluteLastResponse[0]['sender_id'] as String?;

          debugPrint(
            '[L10N] Chat $matchId: absolute last message id=$absoluteLastMessageId, sender=$absoluteLastSenderId',
          );

          // Get the last incoming message (not from current user)
          final messagesResponse = await Supabase.instance.client
              .from('chat_messages')
              .select(
                'id, sender_id, detected_source_language, translated_target_language, '
                'encryption_scheme, sender_key_id, recipient_key_id, wrapped_keys, recipient_id, '
                'content_translated_encrypted, content_translated_nonce',
              )
              .eq('match_id', matchId)
              .neq('sender_id', userId) // Only incoming messages
              .order('created_at', ascending: false)
              .limit(1);

          if (messagesResponse.isEmpty) {
            debugPrint(
              '[L10N] Chat $matchId: no incoming messages found, skipping',
            );
            continue; // No incoming messages in this chat
          }

          final lastMessage = messagesResponse[0];
          final lastMessageId = lastMessage['id'] as String;

          debugPrint(
            '[L10N] Chat $matchId: last incoming message id=$lastMessageId',
          );

          // Only translate if the last incoming message IS ALSO the absolute last message.
          // This ensures the chat-list preview reflects the new language immediately.
          // If there are outgoing messages after the last incoming, we don't translate
          // in the smart phase - the user will see translations when they open the chat.
          final isAlsoAbsoluteLast = lastMessageId == absoluteLastMessageId;

          debugPrint(
            '[L10N] Chat $matchId: absolute_last=$absoluteLastMessageId vs last_incoming=$lastMessageId, isAlsoAbsoluteLast=$isAlsoAbsoluteLast',
          );

          if (!isAlsoAbsoluteLast) {
            debugPrint(
              '[L10N] Last incoming msg is not absolute last - skipping smart retranslation for this chat',
            );
            // Don't translate in smart phase, but DO clear cached translations
            // so translationFamilyProvider is forced into Case A when user opens the chat.
            try {
              final allMessages = await localDb.getMessages(matchId);
              final userId2 = userId; // captured for closure
              final incomingIds = allMessages
                  .where((m) => m['sender_id']?.toString() != userId2)
                  .map((m) => m['id']?.toString())
                  .whereType<String>()
                  .toList();
              if (incomingIds.isNotEmpty) {
                await localDb.clearCachedTranslationsForMessages(
                  matchId,
                  incomingIds,
                );
              }
            } catch (_) {}
            debugPrint(
              '[L10N] Skipped chat $matchId - not translating, continuing to next chat',
            );
            continue;
          }

          debugPrint(
            '[L10N] Last incoming msg IS absolute last - proceeding with smart retranslation',
          );

          String? detectedSource =
              lastMessage['detected_source_language'] as String?;
          final translatedTarget =
              lastMessage['translated_target_language'] as String?;
          final existingEncrypted =
              lastMessage['content_translated_encrypted'] as String?;
          final existingNonce =
              lastMessage['content_translated_nonce'] as String?;
          final encryptionScheme = lastMessage['encryption_scheme'] as String?;
          // Content version of the message behind the preview. A cached
          // translation is only reusable while this still matches the version
          // it was made for, because an edit keeps the message id.
          final lastMessageEditedAt = normalizeEditMarker(
            lastMessage['edited_at'],
          );

          // Validate server's detected source language
          // If invalid (e.g. "st", "ts", null), fall back to client-side detection
          if (!isValidLanguageCode(detectedSource)) {
            try {
              final messages = await localDb.getMessages(matchId);
              final rawMessage = messages.firstWhere(
                (m) => (m['id']?.toString() ?? '') == lastMessageId,
                orElse: () => <String, dynamic>{},
              );
              final originalContent = rawMessage['content_original'] as String?;
              if (originalContent != null &&
                  originalContent.isNotEmpty &&
                  originalContent != 'null') {
                final translationService = ref.read(translationServiceProvider);
                final clientDetected = normalizeContentLanguageCode(
                  await translationService.identifyLanguage(originalContent),
                );
                if (isValidLanguageCode(clientDetected) &&
                    clientDetected != 'und') {
                  detectedSource = clientDetected;
                  debugPrint(
                    '[L10N] Chat $matchId: server source invalid ($detectedSource), '
                    'client detected=$clientDetected',
                  );
                }
              }
            } catch (_) {}
          }

          // Normalize language codes for comparison
          final uiLang = langCode.toLowerCase();
          final sourceLang = detectedSource?.toLowerCase();
          final targetLang = translatedTarget?.toLowerCase();

          debugPrint(
            '[L10N] Chat $matchId: last message source=$sourceLang, target=$targetLang, ui=$uiLang',
          );

          // Case B: UI language matches source language -> Show original, don't translate
          if (sourceLang != null && sourceLang == uiLang) {
            debugPrint(
              '[L10N] Case B: Source matches UI ($sourceLang), showing original',
            );
            await localDb.updateChatLastMessageTranslation(
              userId,
              matchId,
              lastMessageId,
              null,
            );
            // Clear any stale message-level cache for the old UI language so
            // translationFamilyProvider hits Case B (show original) immediately
            // on chat open instead of trying to decrypt/reuse old data.
            try {
              await localDb.clearCachedTranslationsForMessages(matchId, [
                lastMessageId,
              ]);
            } catch (_) {}
            skippedCaseB++;
            continue;
          }

          // Case C: UI language matches existing translation target -> Reuse translation
          // The server stores the translation payload in the encrypted columns.
          final hasEncryptedForTarget =
              encryptionScheme == 'v1' &&
              existingEncrypted != null &&
              existingEncrypted.isNotEmpty &&
              existingEncrypted != 'null' &&
              existingNonce != null &&
              existingNonce.isNotEmpty;

          if (targetLang != null &&
              targetLang == uiLang &&
              hasEncryptedForTarget) {
            // Reusing the stored translation is only safe while it was made
            // for the message's current content: the translation AAD binds the
            // target language but not the original text, so a pre-edit blob
            // decrypts cleanly. Compare the server-side version marker recorded
            // at translation time against the row's `edited_at`.
            final storedTranslationIsCurrent = translationEditMarkersMatch(
              normalizeEditMarker(lastMessage['translated_source_edited_at']),
              lastMessageEditedAt,
            );

            if (!storedTranslationIsCurrent) {
              // The message was edited after this translation was stored. Drop
              // both caches and fall through to Case A, which regenerates it
              // once. Clearing the chat-list preview here matters: an edit
              // keeps the message id, so without this the Recent Chats row
              // would keep rendering the pre-edit text indefinitely.
              debugPrint(
                '[L10N] Stored translation for chat $matchId predates the last edit; retranslating',
              );
              await localDb.updateChatLastMessageTranslation(
                userId,
                matchId,
                lastMessageId,
                null,
              );
              try {
                await localDb.clearCachedTranslationsForMessages(matchId, [
                  lastMessageId,
                ]);
              } catch (_) {}
            } else {
              debugPrint(
                '[L10N] Case C: Already translated to $targetLang, reusing',
              );
              // Encrypted translation exists — decrypt to update Recent Chats
              // preview so the user sees it immediately without re-translating.
              String? decrypted;
              try {
                final privateKey = await ChatKeyService.instance
                    .loadPrivateKeyBytes(userId);
                if (privateKey != null) {
                  final senderId = lastMessage['sender_id'] as String?;
                  final senderKeyId = lastMessage['sender_key_id'] as String?;
                  final recipientKeyId =
                      lastMessage['recipient_key_id'] as String?;
                  final wrappedKeys =
                      lastMessage['wrapped_keys'] as Map<String, dynamic>?;
                  final recipientId = lastMessage['recipient_id'] as String?;
                  if (senderId != null &&
                      senderKeyId != null &&
                      recipientKeyId != null &&
                      wrappedKeys != null) {
                    decrypted = await ChatKeyService.instance
                        .decryptMessageTranslatedContent(
                          currentUserId: userId,
                          currentUserPrivateKey: privateKey,
                          messageId: lastMessageId,
                          matchId: matchId,
                          senderId: senderId,
                          senderKeyId: senderKeyId,
                          recipientKeyId: recipientKeyId,
                          contentTranslatedEncryptedBase64: existingEncrypted,
                          contentTranslatedNonceBase64: existingNonce,
                          wrappedKeys: wrappedKeys,
                          detectedSourceLanguage: detectedSource ?? 'und',
                          targetLanguage: langCode,
                          recipientId: recipientId?.isNotEmpty == true
                              ? recipientId
                              : null,
                        );
                  }
                }
              } catch (e) {
                debugPrint(
                  '[L10N] Case C decrypt failed for chat $matchId: $e',
                );
              }
              if (decrypted != null && decrypted.isNotEmpty) {
                await localDb.updateChatLastMessageTranslation(
                  userId,
                  matchId,
                  lastMessageId,
                  decrypted,
                  targetLanguage: langCode,
                  editedAt: lastMessageEditedAt,
                );
                // Mirror the translation into the message-level cache so
                // entering the chat hits Case C immediately without another
                // DeepL call. Preview-only writes leave localDb stale, which
                // would otherwise re-include this id in the next batch.
                try {
                  await localDb.mergeMessages(matchId, [
                    {
                      'id': lastMessageId,
                      'content_translated': decrypted,
                      'translated_target_language': langCode,
                    },
                  ]);
                } catch (_) {}
              }
              skippedCaseC++;
              continue;
            }
          }

          // Case A: Need to translate (UI != source AND UI != existing target)
          // Call translate-proxy for this single message
          debugPrint('[L10N] Case A: Need to translate to $uiLang');

          // Use message_ids to force translation of this specific message,
          // bypassing the retranslate_all query which skips messages with
          // existing content_translated_encrypted (even if undecryptable).
          try {
            await TranslationProxy.invoke(
              body: {
                'match_id': matchId,
                'target_language': langCode,
                'message_ids': [lastMessageId],
                'exclude_sender_id': userId,
              },
            );
          } catch (e) {
            // If translation fails due to authorization (orphaned match),
            // just skip the preview decryption. The actual translation will
            // happen when the user opens the chat via translationFamilyProvider.
            if (e.toString().contains('403') ||
                e.toString().contains('not authorized') ||
                e.toString().contains('Not authorized')) {
              debugPrint(
                '[L10N] CRITICAL: Match $matchId appears in user $userId\'s chats table but user is not authorized in matches table. '
                'This indicates data corruption or a schema issue. Error: ${e.toString()}',
              );
              continue; // Skip to next chat - don't process this invalid match
            }
            rethrow; // Re-throw other errors for higher-level handling
          }

          final refreshed = await Supabase.instance.client
              .from('chat_messages')
              .select(
                'translated_target_language, content_translated_encrypted, content_translated_nonce, encryption_scheme, sender_id, sender_key_id, recipient_key_id, wrapped_keys, recipient_id, edited_at, translated_source_edited_at',
              )
              .eq('id', lastMessageId)
              .maybeSingle();
          final refreshedTarget =
              refreshed?['translated_target_language'] as String?;
          final refreshedEncrypted =
              refreshed?['content_translated_encrypted'] as String?;
          final refreshedNonce =
              refreshed?['content_translated_nonce'] as String?;
          final refreshedEncScheme = refreshed?['encryption_scheme'] as String?;
          final refreshedSenderId = refreshed?['sender_id'] as String?;
          final refreshedSenderKeyId = refreshed?['sender_key_id'] as String?;
          final refreshedRecipientKeyId =
              refreshed?['recipient_key_id'] as String?;
          final refreshedWrappedKeys =
              refreshed?['wrapped_keys'] as Map<String, dynamic>?;
          final refreshedRecipientId = refreshed?['recipient_id'] as String?;

          final isEncrypted = refreshedEncScheme == 'v1';
          final hasEncryptedResult =
              isEncrypted &&
              refreshedEncrypted != null &&
              refreshedEncrypted.isNotEmpty &&
              refreshedNonce != null &&
              refreshedNonce.isNotEmpty;
          // Only cache a translation the server vouches was made for the
          // message's current content. Without this a translation stored before
          // an edit still decrypts and would be written straight into the
          // Recent Chats preview as if it described the new text.
          final refreshedEditedAt = normalizeEditMarker(
            refreshed?['edited_at'],
          );
          final refreshedTranslationIsCurrent = translationEditMarkersMatch(
            normalizeEditMarker(refreshed?['translated_source_edited_at']),
            refreshedEditedAt,
          );

          if (hasEncryptedResult &&
              refreshedTarget != null &&
              refreshedTarget.toLowerCase() == uiLang &&
              refreshedTranslationIsCurrent) {
            // Try to decrypt the encrypted translation for the Recent Chats
            // preview so the user sees the new language immediately without
            // having to open the chat first.
            String? decryptedForPreview;
            try {
              final privateKey = await ChatKeyService.instance
                  .loadPrivateKeyBytes(userId);
              if (privateKey != null &&
                  refreshedSenderId != null &&
                  refreshedSenderKeyId != null &&
                  refreshedRecipientKeyId != null &&
                  refreshedWrappedKeys != null &&
                  refreshedRecipientId != null) {
                decryptedForPreview = await ChatKeyService.instance
                    .decryptMessageTranslatedContent(
                      currentUserId: userId,
                      currentUserPrivateKey: privateKey,
                      messageId: lastMessageId,
                      matchId: matchId,
                      senderId: refreshedSenderId,
                      senderKeyId: refreshedSenderKeyId,
                      recipientKeyId: refreshedRecipientKeyId,
                      contentTranslatedEncryptedBase64: refreshedEncrypted,
                      contentTranslatedNonceBase64: refreshedNonce,
                      wrappedKeys: refreshedWrappedKeys,
                      detectedSourceLanguage:
                          lastMessage['detected_source_language'] as String? ??
                          'und',
                      targetLanguage: langCode,
                      recipientId: refreshedRecipientId.isNotEmpty
                          ? refreshedRecipientId
                          : null,
                    );
              }
            } catch (e) {
              debugPrint('[L10N] Failed to decrypt translation preview: $e');
            }
            if (decryptedForPreview != null && decryptedForPreview.isNotEmpty) {
              await localDb.updateChatLastMessageTranslation(
                userId,
                matchId,
                lastMessageId,
                decryptedForPreview,
                targetLanguage: langCode,
                editedAt: refreshedEditedAt,
              );
              // Cache at message level as well: entering the chat must reuse
              // this translation via Case C instead of sending this id to
              // DeepL again in the on-open batch.
              try {
                await localDb.mergeMessages(matchId, [
                  {
                    'id': lastMessageId,
                    'content_translated': decryptedForPreview,
                    'translated_target_language': langCode,
                  },
                ]);
              } catch (_) {}
              debugPrint(
                '[L10N] Updated Recent Chats preview with decrypted translation',
              );
            } else {
              debugPrint(
                '[L10N] Encrypted translation created (will decrypt on chat open)',
              );
            }
            translatedCount++;
          }
        } catch (e) {
          debugPrint('[L10N] Error processing chat: $e');
          // Continue with other chats
        }
      }

      debugPrint(
        '[L10N] Smart retranslation complete: $translatedCount translated, $skippedCaseB (show original), $skippedCaseC (reuse)',
      );
      // Only mark as done once the pass actually completed without erroring
      // out. Combined with the early-return guard above, this prevents the
      // same 1.3s DB scan + AI call chain from re-firing on every cold start
      // when the user's preferred language hasn't changed.
      _lastRetranslatedLanguage = langCode;
      _lastRetranslatedUserId = userId;
    } catch (e) {
      debugPrint('[L10N] Error in smart retranslation: $e');
      // Don't throw - retranslation is not critical
    } finally {
      _retranslationInProgress = false;
    }
  }

  /// Reconciles this session's language with the account and the server.
  ///
  /// Safe to call on any auth event (initialSession or signedIn) — the name
  /// intentionally avoids "afterLogin" since it also fires on session restore.
  ///
  /// Priority:
  ///   1. a pending login-screen or unsynced in-app pick (the newest intent),
  ///   2. the account's explicit language (so all devices agree),
  ///   3. this device's resolved language, seeded without marking it explicit.
  Future<void> syncLanguageAfterLogin() async {
    // Coalesce concurrent callers onto a single in-flight sync instead of
    // firing N parallel DB storms.
    final inFlight = _languageSyncInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
      return;
    }
    // Wait for _init to seed the cold-start locale (which now reads the
    // user's saved DB preference). Without this, callers scheduled by the
    // auth stream can fire before _init finishes and end up pushing the
    // wrong locale to the DB.
    await whenInitialized;
    if (!ref.mounted) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    final now = DateTime.now();

    // An unconfirmed choice is the newest intent and must not be suppressed
    // by the failure backoff / cooldown that protects ordinary seeding.
    final pending = await _pickPendingLanguage(userId);
    if (pending != null) {
      _lastLanguageSyncFailureAt = null;
      _lastLanguageSyncAttemptAt = now;
      _lastLanguageSyncAttemptLang = pending;
      if (pending != state.currentLocale.languageCode) {
        await setLocale(pending, null, false);
        if (!ref.mounted) return;
      }
      debugPrint('[L10N] Pushing pending language choice: $pending');
      await _pushLanguage(userId, pending, explicit: true);
      return;
    }

    // No local pending choice: the account row decides. Only an explicit
    // account choice overrides this device's language; a seed leaves it alone
    // (the device language was already resolved in _initImpl).
    final remote = await _fetchRemoteLanguagePreference(userId);
    if (!ref.mounted) return;
    if (Supabase.instance.client.auth.currentUser?.id != userId) return;
    if (remote != null && remote.explicit) {
      final remoteLanguage = remote.language;
      if (remoteLanguage != null &&
          remoteLanguage.isNotEmpty &&
          remoteLanguage != state.currentLocale.languageCode &&
          _supportsLanguage(remoteLanguage)) {
        await setLocale(remoteLanguage, null, false);
      }
      return;
    }

    // Failure backoff: a dead refresh token / 429 / RLS denial will fail
    // every retry — don't hammer Supabase, just use cache until it lifts.
    if (_lastLanguageSyncFailureAt != null &&
        now.difference(_lastLanguageSyncFailureAt!) <
            _languageSyncFailureBackoff) {
      debugPrint(
        '[L10N] syncLanguageAfterLogin: skipped (recent failure backoff)',
      );
      return;
    }
    // Cooldown for repeat seeds with an unchanged language (auth event flaps,
    // duplicate initialSession, pull-to-refresh).
    final currentLangCode = state.currentLocale.languageCode;
    if (_lastLanguageSyncAttemptAt != null &&
        _lastLanguageSyncAttemptLang == currentLangCode &&
        now.difference(_lastLanguageSyncAttemptAt!) < _languageSyncCooldown) {
      debugPrint(
        '[L10N] syncLanguageAfterLogin: skipped (cooldown, unchanged)',
      );
      return;
    }
    _lastLanguageSyncAttemptAt = now;
    _lastLanguageSyncAttemptLang = currentLangCode;
    debugPrint('[L10N] Seeding account language: $currentLangCode');

    // The account never chose a language: write the resolved UI language so
    // notifications/broadcasts target the right locale, but never mark the
    // row explicit and never overwrite a value the user did pick.
    await _pushLanguage(userId, currentLangCode, explicit: false);
  }

  Future<void> _pushLanguage(
    String userId,
    String langCode, {
    required bool explicit,
  }) async {
    if (!ref.mounted) return;
    final future = _updateLanguageInDatabase(langCode, explicit: explicit);
    _languageSyncInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_languageSyncInFlight, future)) {
        _languageSyncInFlight = null;
      }
    }
  }

  /// Re-pulls the account language after the app resumes or connectivity
  /// returns, and retries any pending choice.
  Future<void> refreshLanguageFromRemote() => _syncLanguageFromRemote();
}

// --- REALTIME PROVIDER ---
/// Watches the translations table for the current locale and refreshes the
/// in-memory translation state when the admin changes any string via the
/// admin panel, without requiring a locale switch or app restart.
final translationsRealtimeProvider = StreamProvider<List<Map<String, dynamic>>>(
  (ref) {
    if (Supabase.instance.client.auth.currentSession == null) {
      return const Stream.empty();
    }
    if (!offlineCacheManager.isSupabaseAvailable || shouldSkipSupabaseCalls()) {
      return const Stream.empty();
    }

    final currentLangCode = ref.watch(
      localizationProvider.select((s) => s.currentLocale.languageCode),
    );

    // A single migration can touch hundreds of rows at once. Without this
    // every row would trigger its own full fetch of the locale; the refreshes
    // are coalesced into one instead.
    Timer? refreshTimer;
    ref.onDispose(() => refreshTimer?.cancel());

    return Supabase.instance.client
        .from('translations')
        .stream(primaryKey: const ['locale', 'key'])
        .eq('locale', currentLangCode)
        .map((rows) {
          developer.log(
            'Translations changed for $currentLangCode, refreshing',
            name: 'TranslationsRealtime',
          );
          refreshTimer?.cancel();
          refreshTimer = Timer(const Duration(milliseconds: 500), () {
            if (!ref.mounted) return;
            ref.read(localizationProvider.notifier).refreshTranslations();
          });
          return rows;
        })
        .handleError((e) {
          developer.log(
            'translationsRealtimeProvider error: $e',
            name: 'TranslationsRealtime',
          );
        });
  },
);

// --- 4. The Main Provider ---
// Generated by @riverpod
