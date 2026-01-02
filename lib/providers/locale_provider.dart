// lib/providers/locale_provider.dart
import 'dart:convert'; // For jsonEncode and jsonDecode
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:devicelocale/devicelocale.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/resume_diagnostics.dart';

part 'locale_provider.g.dart';

// --- 1. Language Model ---
class AppLanguage {
  final String code;
  final String displayName;
  final TextDirection direction;

  AppLanguage({
    required this.code,
    required this.displayName,
    this.direction = TextDirection.ltr,
  });
}

// --- 2. Localization State Model ---
class LocalizationState {
  final Locale currentLocale;
  final TextDirection textDirection;
  final Map<String, String> strings;
  final List<AppLanguage> supportedLanguages;
  final bool isLoading;
  final Set<String> dbKeys;

  LocalizationState({
    required this.currentLocale,
    required this.textDirection,
    required this.strings,
    required this.supportedLanguages,
    this.isLoading = false,
    this.dbKeys = const <String>{},
  });

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
    Map<String, String>? strings,
    List<AppLanguage>? supportedLanguages,
    bool? isLoading,
    Set<String>? dbKeys,
  }) {
    return LocalizationState(
      currentLocale: currentLocale ?? this.currentLocale,
      textDirection: textDirection ?? this.textDirection,
      strings: strings ?? this.strings,
      supportedLanguages: supportedLanguages ?? this.supportedLanguages,
      isLoading: isLoading ?? this.isLoading,
      dbKeys: dbKeys ?? this.dbKeys,
    );
  }

  // Helper to get a string, with a fallback
  // NOTE: Missing translation logs can be noisy when many widgets call getString frequently.
  // To avoid spamming logs and impacting performance, we only log each missing key once.
  static final Set<String> _missingTranslationWarned = <String>{};

  String getString(String key) {
    final translation = strings[key];
    if (translation != null) {
      // Diagnostics: if diagnostics enabled and this key was not provided by DB, log it
      try {
        // If the key is part of defaults and not in dbKeys, the app is using the default not DB value
        if (ResumeDiagnostics.enabled && _defaultTranslations.containsKey(key) && !dbKeys.contains(key)) {
          ResumeDiagnostics.logThrottled('DB missing translation for key: $key; using built-in default', category: 'missing_db_key.$key', minIntervalMs: 60000);
        }
      } catch (_) {}
      return translation;
    }

    // Fallback to default translations (prefer defaults over logging missing key)
    final defaultTranslation = _defaultTranslations[key];
    if (defaultTranslation != null) {
      return defaultTranslation;
    }

    // Only log the missing translation once per key to avoid spam
    if (!_missingTranslationWarned.contains(key)) {
      _missingTranslationWarned.add(key);
      debugPrint('Missing translation for key: $key, strings has ${strings.length} entries');
      if (key == 'chatIsTyping') {
        debugPrint('Available string keys: ${strings.keys.where((k) => k.contains('chat')).toList()}');
      }
      if (key == '0') {
        debugPrint('Stack trace for missing key "0": ${StackTrace.current}');
      }
    }

    return '$key...'; // Show '...' fallback
  }

  // Default translations for critical keys
  static const Map<String, String> _defaultTranslations = {
    'authStreamError': 'Auth Stream Error',
    'supabaseInitFailed': 'Supabase initialization failed',
    'configRequired': 'Configuration required',
    'supabaseConfigMissing': 'Supabase configuration missing',
    'supabaseUrlMissing': 'SUPABASE_URL is missing from .env or --dart-define',
    'supabaseAnonKeyMissing': 'SUPABASE_ANON_KEY is missing from .env or --dart-define',
    'appName': 'MatchMe',
    // Password reset screen translations
    'authSetNewPassword': 'Set New Password',
    'authSetNewPasswordMessage': 'Please enter your new password below.',
    'authNewPassword': 'New Password',
    'authConfirmPassword': 'Confirm Password',
    'authConfirmPasswordRequired': 'Please confirm your password',
    'authPasswordsDoNotMatch': 'Passwords do not match',
    'authResetPassword': 'Reset Password',
    'authPasswordResetSuccess': 'Password Reset Successful',
    'authPasswordResetSuccessMessage': 'Your password has been successfully reset. You can now log in with your new password.',
    'authReturnToLogin': 'Return to Login',
    'authPasswordRequired': 'Password is required',
    'authPasswordTooShort': 'Password must be at least 8 characters',
    'authPasswordWeak': 'Password must contain uppercase, lowercase, number and special character',
    'settingsSmartGpsThrottling': 'Smart GPS Throttling',
    'settingsSmartGpsThrottlingUpdated': 'Smart GPS Throttling updated',
    'settingsSmartGpsThrottlingUpdateFailed': 'Failed to update Smart GPS Throttling',
    'rangeFrom': 'from',
    'rangeTo': 'to',
    'settingsGettingPreciseLocation': 'Getting precise location...\nThis may take up to 10 seconds',
    'settingsRadius': 'Radius',
    'settingsAccuracyMeters': 'm accuracy',
    'settingsWebGpsAccuracy': 'Web GPS: 50-100m accuracy',
    'settingsMobileGpsAccuracy': 'Mobile GPS: 5-20m accuracy',
    'settingsConsiderIncreasingRadius': 'Consider increasing radius to',
    'settingsGpsRate': 'GPS Update Rate',
    'settingsGpsRateUnit': 'seconds',
    'settingsGpsRateUpdated': 'GPS rate updated',
    'settingsGpsRateUpdateFailed': 'Failed to update GPS rate',
    'profileBasicsLockedNoteTitle': 'For your safety',
    'profileBasicsLockedNoteBody': 'Changes to your name, birthday, and gender are restricted to protect your identity and account safety. To request a change, tap the lock icon and provide a short reason and any supporting documents.',
    'settingsTitle': 'Settings',
    'generalOffline': 'Offline',
    'generalErrorLoadingProfile': 'Error loading profile',
    'settingsAppDisplay': 'App Display',
    'settingsThemeMode': 'Theme',
    'settingsThemeModeSystem': 'System default',
    'settingsThemeModeLight': 'Light',
    'settingsThemeModeDark': 'Dark',
    'profileAppLanguage': 'App Language',
    'settingsMatching': 'Matching',
    'settingsRadiusUpdateFailed': 'Failed to update radius',
    'settingsInvisibilityRules': 'Invisibility Rules',
    'settingsInvisibilityRulesDesc': 'Control when you appear invisible to others',
    'settingsGenderAgePreferences': 'Gender and Age Preferences',
    'settingsGenderAgePreferencesDesc': 'Set gender and age preferences for each intent',
    'settingsEnforcementMode': 'Enforcement Mode',
    'settingsStrictLabel': 'Strict enforcement',
    'settingsFlexibleLabel': 'Flexible mode',
    'settingsStrictEnforcement': 'Strict: Only create matches that meet ALL selected gender & age preferences',
    'settingsPrioritizeEnforcement': 'Flexible: Prefer matches that meet your preferences but allow others',
    'settingsEnforcementHelpTitle': 'About Enforcement Mode',
    'settingsEnforcementHelpBody': 'Strict enforcement ensures that matches are only created when the other person meets all your selected gender and age preferences (this may significantly reduce the number of matches). \n\nFlexible mode prefers matches that meet your preferences but will still create matches that don\'t match every preference (higher match rate).',
    'settingsPreferredGenders': 'Preferred Genders',
    'settingsPreferredAgeRange': 'Preferred Age Range',
    'settingsNoIntentsSelected': 'No intents selected in profile',
    'settingsPreferencesSaved': 'Preferences saved successfully',
    'settingsPreferencesSaveFailed': 'Failed to save preferences',
    'generalYearsOld': 'years old',
    'generalError': 'Error',
    'generalRetry': 'Retry',
    'settingsChangePassword': 'Change Password',
    'settingsCurrentPassword': 'Current Password',
    'settingsNewPassword': 'New Password',
    'settingsConfirmNewPassword': 'Confirm Change Password',
    'settingsPasswordMismatch': 'Passwords do not match',
    'settingsPasswordChanged': 'Password changed successfully',
    'settingsPasswordChangeFailed': 'Failed to change password',
    'settingsDeleteAccount': 'Delete Account',
    'settingsDeleteAccountConfirm': 'Are you sure you want to delete your account? This action cannot be undone and will permanently remove all your data.',
    'settingsDeleteAccountFailed': 'Failed to delete account',
    'settingsAccountDeleted': 'Account deleted successfully',
    'settingsAccountAlreadyDeleted': 'Account already deleted - logged out successfully',
    'settingsAccountManagement': 'Account Management',
    'generalCancel': 'Cancel',
    'generalSave': 'Save',
    'homeWelcome': 'Welcome',
    'homeNearby': 'Nearby',
    'homeOnline': 'Online',
    'homeTier': 'Tier',
    'homeStatusVisible': 'Visible',
    'homeStatusInvisible': 'Invisible',
    'homeSeeAll': 'See All',
    // Match reason translations (fallbacks for Recent Matches)
    'Friendship': 'Friendship',
    'Relationship': 'Relationship',
    'Proximity': 'Proximity',
    'Shared Event': 'Shared Event',
    'Event': 'Event',
    'Moving Together': 'Moving Together',
    'intentCategoryRomantic': 'Romantic',
    'intentCategoryFriendship': 'Friendship',
    'intentCategoryBusinessNetworking': 'Business/Networking',
    'interestsCategorySocial': 'Social Interests',
    'interestsCategoryBusiness': 'Business Interests',
    'matchedOn': 'Matched on',
    'matchedAt': 'Matched at',
    'eventLabel': 'Event',
    'intentLabel': 'Intent',
    'matchReasonProximityText': 'Due to proximity',
    'sharedEventLabel': 'Shared Event',
    // Chat UI
    'chatReact': 'React',
    'sharedInterestsLabel': 'Shared Interests',
    'matchedByProximityLabel': 'Matched by proximity',
    'attendingSharedEvent': 'Attending a shared event',
    // Individual intent key translations
    'romantic': 'Romantic',
    'relationship': 'Relationship', 
    'friendship': 'Friendship',
    'friend': 'Friendship',
    'social': 'Social',
    'activity_partner': 'Activity Partner',
    'business_networking': 'Business Networking',
    'networking': 'Networking',
    'dating': 'Dating',
    // Gender translations
    'gender_male': 'Male',
    'gender_female': 'Female',
    'gender_non_binary': 'Non-binary',
    'gender_prefer_not_to_say': 'Prefer not to say',
    // Chat translation keys
    'chatTranslateOn': 'Translation enabled',
    'chatTranslateOff': 'Translation disabled',
    'chatTranslateToggle': 'Translate messages',
    'chatTranslateFailed': 'Translation failed',
    'generalClose': 'Close',
    'generalLoading': 'Loading…',
    'generalUnknown': 'Unknown',
    'generalOnShort': 'On',
    'generalOffShort': 'Off',
    'generalOnInvisibleShort': 'On (Invisible)',
    'generalLoadingDots': 'Loading…',
    'eventTapToOpenInBrowser': 'Tap to open in your browser',
    'profileWizardAddPhotoFromGallery': 'Choose from gallery',
    'profileWizardAddPhotoFromCamera': 'Take a photo',
    'profileEditShortBioHint': 'Short description about yourself',
    'profileWizardSelectLanguagesAndSkills': 'Select Languages & Skills',
    'profileWizardRemoveLanguageTooltip': 'Remove language',
    'profileWizardNewPhotosAdded': '{count} new photos added',
    'profileWizardPhotosRemoved': '{count} photos removed',
    'newMatchPlaceholderName': 'New match',
    'newMatchTitle': 'New match',
    'viewMatch': 'View match',
    'eventImportCanceled': 'Import canceled',
    'eventMatchingTestButton': 'Test Event Matching',
    'eventMatchingFunctionSuccess': 'Event matching function called successfully',
    'eventMatchingFunctionError': 'Error calling function: {error}',
    'unitMeters': 'm',
    'unitKilometers': 'km',
    'unitFeet': 'ft',
    'unitMiles': 'mi',
    'settingsUnits': 'Units',
    'settingsUnitsSystem': 'System default',
    'settingsUnitsMetric': 'Metric',
    'settingsUnitsImperial': 'Imperial',
    'settingsTimeFormat': 'Time format',
    'settingsTimeFormatSystem': 'System default',
    'settingsTimeFormat24': '24-hour',
    'settingsTimeFormat12': 'AM/PM',
    'timeAM': 'AM',
    'timePM': 'PM',
    'timeMorning': 'Morning',
    'timeAfternoon': 'Afternoon',
    'timeEvening': 'Evening',
    'timeNight': 'Night',
    'eventLocationLabel': 'Location',
    'eventDateLabel': 'Day and Date',
    'eventTimeLabel': 'Time',
    'chatIsTyping': '{name} is typing',
  };

  /// Public helper to get a built-in default translation for a key (used when the app must show text before localization is initialized)
  static String defaultTranslation(String key) {
    return _defaultTranslations[key] ?? '$key...';
  }
}


// --- 3. The Notifier ---
@riverpod
class Localization extends _$Localization {
  // Keys that were provided by the DB in the most recent fetch
  Set<String> _lastFetchedDbKeys = <String>{};

  // Remember which DB keys we've warned about already to avoid log spam
  final Set<String> _missingDbKeysWarned = <String>{};

  @override
  LocalizationState build() {
    _init();
    return LocalizationState.loading();
  }

  Future<void> _init() async {
    final supported = await _fetchSupportedLanguages();
    final prefs = await SharedPreferences.getInstance();
    String? langCode = prefs.getString('user_language_code');
    
    if (langCode == null) {
      try {
        final Locale? deviceLocale = await Devicelocale.currentAsLocale;
        if (deviceLocale != null && supported.any((lang) => lang.code == deviceLocale.languageCode)) {
          langCode = deviceLocale.languageCode;
        } else {
          langCode = 'en';
        }
      } catch (e) {
        langCode = 'en';
      }
    }

    final Map<String, String> cachedStrings = await _loadTranslationsFromCache(langCode);
    final AppLanguage initialLang = supported.firstWhere((l) => l.code == langCode, orElse: () => supported.firstWhere((l) => l.code == 'en', orElse: () => AppLanguage(code: 'en', displayName: 'English')));

    if (cachedStrings.isNotEmpty) {
      state = LocalizationState(
        currentLocale: Locale(initialLang.code),
        textDirection: initialLang.direction,
        strings: cachedStrings,
        supportedLanguages: supported,
        isLoading: false,
      );
    } else {
      await setLocale(langCode, supported);
      return;
    }

    // Stale-While-Revalidate: Silently fetch updates
    try {
      final updatedStrings = await _fetchTranslationsFromDB(langCode);
      if (updatedStrings.isNotEmpty) {
        await _saveTranslationsToCache(langCode, updatedStrings);
        if (state.strings.toString() != updatedStrings.toString()) {
           state = state.copyWith(strings: updatedStrings, dbKeys: _lastFetchedDbKeys);
        }
      }
    } catch (e) {
      // Ignore translation fetch errors
    }
  }

  Future<List<AppLanguage>> _fetchSupportedLanguages() async {
    try {
      final response = await Supabase.instance.client
          .from('app_languages')
          .select('language_code, display_name, text_direction')
          .order('display_name', ascending: true);
          
      return response.map((item) {
        return AppLanguage(
          code: item['language_code'],
          displayName: item['display_name'],
          direction: (item['text_direction'] == 'RTL') ? TextDirection.rtl : TextDirection.ltr,
        );
      }).toList();
    } catch (e) {
      return [AppLanguage(code: 'en', displayName: 'English', direction: TextDirection.ltr)];
    }
  }

  // *** MODIFIED: This function now fetches from translations table only ***
  Future<Map<String, String>> _fetchTranslationsFromDB(String langCode) async {
    final allStrings = <String, String>{};

    // Fetch from 'translations' table only
    try {
      final responseTranslations = await Supabase.instance.client
          .from('translations')
          .select('key, value')
          .eq('locale', langCode);

      for (var item in responseTranslations) {
        allStrings[item['key']] = item['value'];
      }

      // Remember which keys came from the DB so we can detect and log missing DB translations
      _lastFetchedDbKeys = allStrings.keys.toSet();

      // Log missing keys compared to our built-in defaults so it's visible in logs
      if (_lastFetchedDbKeys.isEmpty) {
        debugPrint('No translations fetched from DB for locale: $langCode');
      } else {
        final defaultKeys = LocalizationState._defaultTranslations.keys.toSet();
        final missing = defaultKeys.difference(_lastFetchedDbKeys);
        final newlyMissing = missing.where((k) => !_missingDbKeysWarned.contains(k)).toList();
        if (newlyMissing.isNotEmpty) {
          _missingDbKeysWarned.addAll(newlyMissing);
          debugPrint('Missing DB translation keys for $langCode: (count=${newlyMissing.length}) ${newlyMissing.take(20).toList()}');
        } else {
          debugPrint('Fetched ${_lastFetchedDbKeys.length} translations from DB for $langCode');
        }
      }

    } catch (e) {
      // Ignore DB fetch errors
    }

    // Merge with code defaults to ensure every key has a fallback
    final merged = Map<String, String>.from(LocalizationState._defaultTranslations);
    merged.addAll(allStrings); // DB overrides defaults when present

    return merged;
  }

  Future<Map<String, String>> _loadTranslationsFromCache(String langCode) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final jsonString = prefs.getString('translations_$langCode');
        if (jsonString != null) {
          final map = Map<String, String>.from(jsonDecode(jsonString));
          // also try to load saved DB keys for accurate logging
          final dbJson = prefs.getString('translations_${langCode}_dbkeys');
          if (dbJson != null) {
            try {
              final List<dynamic> keys = jsonDecode(dbJson);
              _lastFetchedDbKeys = keys.map((e) => e.toString()).toSet();
            } catch (e) {
              // ignore parse errors
            }
          }
          return map;
        }
      } catch (e) {
        // Ignore cache read errors
      }
      return {};
  }

  Future<void> _saveTranslationsToCache(String langCode, Map<String, String> strings) async {
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
      } catch (e) {
        // Ignore cache save errors
      }
  }

  Future<void> setLocale(String langCode, [List<AppLanguage>? supported]) async {
    state = state.copyWith(isLoading: true);
    
    final supportedLanguages = supported ?? state.supportedLanguages;
    if (supportedLanguages.isEmpty && supported == null) {
       final fetchedLanguages = await _fetchSupportedLanguages();
       return setLocale(langCode, fetchedLanguages);
    }
    
    final AppLanguage lang = supportedLanguages.firstWhere(
      (l) => l.code == langCode,
      orElse: () => supportedLanguages.firstWhere((l) => l.code == 'en'),
    );

    final strings = await _fetchTranslationsFromDB(lang.code);
    await _saveTranslationsToCache(lang.code, strings);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_language_code', lang.code);
    
    state = state.copyWith(
      currentLocale: Locale(lang.code),
      textDirection: lang.direction,
      strings: strings,
      supportedLanguages: supportedLanguages,
      isLoading: false,
      dbKeys: _lastFetchedDbKeys,
    );
  }
}

// --- 4. The Main Provider ---
// Generated by @riverpod
