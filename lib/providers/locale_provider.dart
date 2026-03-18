// lib/providers/locale_provider.dart
import 'dart:convert'; // For jsonEncode and jsonDecode
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/local_db_service.dart';

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

  String getString(String key, {String? gender, Map<String, String>? params}) {
    // If gender provided, try gender-specific variant first. The DB uses suffixes like
    // '<key>_male', '<key>_female', '<key>_non_binary'. Accept either 'male'/'female'/'non_binary'
    // or 'gender_male' style values for convenience.

    // Try gendered key if possible
    if (gender != null && gender.trim().isNotEmpty) {
      final suffix = _normalizeGenderSuffix(gender);
      if (suffix.isNotEmpty) {
        final gKey = '${key}_$suffix';
        final gTranslation = strings[gKey] ?? _defaultTranslations[gKey];
        if (gTranslation != null) return _applyParams(gTranslation, params);
      }
    }

    // Fall back to normal behavior
    final translation = strings[key];
    if (translation != null) {
      // Diagnostics: if diagnostics enabled and this key was not provided by DB, log it
      try {
        // If the key is part of defaults and not in dbKeys, the app is using the default not DB value
        if (ResumeDiagnostics.enabled &&
            _defaultTranslations.containsKey(key) &&
            !dbKeys.contains(key)) {
          ResumeDiagnostics.logThrottled(
            'DB missing translation for key: $key; using built-in default',
            category: 'missing_db_key.$key',
            minIntervalMs: 60000,
          );
        }
      } catch (_) {}
      return _applyParams(translation, params);
    }

    // Fallback to default translations (prefer defaults over logging missing key)
    final defaultTranslation = _defaultTranslations[key];
    if (defaultTranslation != null) {
      return _applyParams(defaultTranslation, params);
    }

    // Only log the missing translation once per key to avoid spam
    if (!_missingTranslationWarned.contains(key)) {
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

    return '$key...'; // Show '...' fallback
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
    'authStreamError': 'Auth Stream Error',
    'supabaseInitFailed': 'Supabase initialization failed',
    'configRequired': 'Configuration required',
    'supabaseConfigMissing': 'Supabase configuration missing',
    'supabaseUrlMissing': 'SUPABASE_URL is missing from .env or --dart-define',
    'supabaseAnonKeyMissing':
        'SUPABASE_ANON_KEY is missing from .env or --dart-define',
    'appName': 'MatchMe',
    'navEvents': 'Events',
    'eventsSyncFromCalendar': 'Sync from Outlook/Gmail',

    'bgNotificationTitle': 'New Match',
    'bgNotificationText': 'You have a new match!',
    // Auth screen keys
    'authOr': 'or',
    'authContinueWithGoogle': 'Continue with Google',
    'authContinueWithMicrosoft': 'Continue with Microsoft',
    'authContinueWithApple': 'Continue with Apple',
    'authContinueWithFacebook': 'Continue with Facebook',

    // --- Auth screen keys ---
    'authSelectLanguage': 'Select Language',
    'authLogin': 'Log In',
    'authEmail': 'Email',
    'authPassword': 'Password',
    'authShowPassword': 'Show Password',
    'authToggleToSignUp': 'Sign Up',
    'authToggleToSignIn': 'Log In',
    'authForgotPassword': 'Forgot Password?',
    'authSignUp': 'Sign Up',
    'authEmailRequired': 'Email is required',
    'authEmailInvalid': 'Invalid email address',
    'authUnexpectedError': 'Unexpected error',
    'authInvalidCredentials': 'Invalid email or password',
    'authInvalidCredentialsTryOAuth':
        'Please check your credentials or sign in with Google, Microsoft, Apple, or Facebook.',
    'authResetPasswordTitle': 'Reset Password',
    'authResetPasswordMessage':
        'Enter your email to receive a password reset link',
    'authResetPasswordSent': 'Password reset email sent',
    'authResetPasswordFailed': 'Failed to send reset email',

    // --- Permissions (fallbacks; prefer DB translations) ---
    'permLocationAlwaysTitle': 'Location permission required',
    'permLocationAlwaysBody':
        'To keep MatchMe working after a device restart (messages, matches, and location updates), set Location permission to "Allow all the time".\n\nAndroid: Settings → Apps → MatchMe → Permissions → Location → Allow all the time.',
    'permLocationWhileInUseBody':
        'MatchMe needs Location permission to work. Please enable Location permission, then set it to "Allow all the time" for full background functionality.',
    'permNotificationsTitle': 'Enable notifications',
    'permNotificationsBody':
        'MatchMe needs notification permission so you can receive new message and match alerts reliably.',
    'permBatteryTitle': 'Allow background activity',
    'permBatteryBody':
        'To stay always-on like WhatsApp, please allow MatchMe to run in the background and exclude it from battery optimizations.',
    'permActionOpenSettings': 'Open settings',
    'permActionNotNow': 'Not now',
    'calendarSyncPermissionTitle': 'Calendar permission required',
    'calendarSyncPermissionActionOpenAppSettings': 'Open App Settings',
    'calendarSyncPermissionActionImportOnline':
        'Import from Online Providers',
    'calendarSyncPermissionActionClose': 'Close',
    'calendarSyncPermissionSettingsGuide':
        'To import from your device calendar, tap Open App Settings and enable Calendar permission for MatchMe.',
    'calendarSyncPermissionBlockedSettingsGuide':
        'Calendar permission is currently blocked. Tap Open App Settings and enable Calendar permission for MatchMe.',
    'calendarSyncPermissionBlockedSettingsGuideAndroid':
        'Calendar permission is currently blocked on Android. Tap Open App Settings, then Permissions → Calendar, and choose Allow.',
    'calendarSyncPermissionBlockedSettingsGuideIos':
        'Calendar permission is currently blocked on iOS. Tap Open App Settings, then Calendars, and enable access for MatchMe.',
    // Password reset screen translations
    'authSetNewPassword': 'Set New Password',
    'authSetNewPasswordMessage': 'Please enter your new password below.',
    'authNewPassword': 'New Password',
    'authConfirmPassword': 'Confirm Password',
    'authConfirmPasswordRequired': 'Please confirm your password',
    'authPasswordsDoNotMatch': 'Passwords do not match',
    'authResetPassword': 'Reset Password',
    'authPasswordResetSuccess': 'Password Reset Successful',
    'authPasswordResetSuccessMessage':
        'Your password has been successfully reset. You can now log in with your new password.',
    'authReturnToLogin': 'Return to Login',
    'authPasswordRequired': 'Password is required',
    'authPasswordTooShort': 'Password must be at least 8 characters',
    'authPasswordWeak':
        'Password must contain uppercase, lowercase, number and special character',

    // --- Add Event Screen ---
    'addEventTitle': 'Add Event',
    'editEventTitle': 'Edit Event',
    'eventInputModeLink': 'Paste Link',
    'eventInputModeTicket': 'Upload Ticket',
    'eventInputModeManual': 'Manual Entry',
    'eventLinkHint': 'Paste event URL here',
    'eventLinkMicrocopy':
        'We\'ll automatically extract the event name, venue, and date from the link.',
    'eventTicketMicrocopy':
        'Upload a screenshot or PDF of your ticket to automatically extract event details.',
    'extractDataButton': 'Extract Details',
    'retryExtractionButton': 'Retry Extraction',
    'eventNameLabel': 'Event Name',
    'eventVenueLabel': 'Venue',
    'eventDateLabel': 'Date',
    'eventTimeLabel': 'Time',
    'eventNotesLabel': 'Notes (Optional)',
    'eventNotesHint': 'Add any extra details here...',
    'saveEventButton': 'Save Event',
    'pleaseEnterValidUrl': 'Please enter a valid URL starting with http',
    'processingError': 'Error processing input',
    'dataExtractedFromLink': 'Details extracted from link',
    'couldNotFetchDetailsFromLink':
        'Could not extract details from link. You can try again or enter manually.',
    'eventDateInPastNotImported':
        'Event date is in the past and was not imported.',
    'ticketProcessedSuccessfully': 'Ticket processed successfully',
    'couldNotExtractEventDetailsFromTicket':
        'Could not extract details from ticket. You can try again or enter manually.',
    'settingsSmartGpsThrottling': 'Smart GPS Throttling',
    'settingsSmartGpsThrottlingDesc':
        'When enabled, Smart GPS reduces GPS updates when you are stationary, and reduces updates to once every 60 seconds when your battery is 15% or lower until charging.',
    'settingsSmartGpsThrottlingUpdated': 'Smart GPS Throttling updated',
    'settingsSmartGpsThrottlingUpdateFailed':
        'Failed to update Smart GPS Throttling',
    'gpsThrottledLowBattery':
        'Low battery — GPS updates reduced to once every 60 seconds to save battery. This will resume when your device is charging or battery is above 15%.',
    'rangeFrom': 'from',
    'rangeTo': 'to',
    'settingsGettingPreciseLocation':
        'Getting precise location...\nThis may take up to 10 seconds',
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
    'profileBasicsLockedNoteBody':
        'Changes to your name, birthday, and gender are restricted to protect your identity and account safety. To request a change, tap the lock icon and provide a short reason and any supporting documents.',
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
    'settingsInvisibilityRulesDesc':
        'Control when you appear invisible to others',
    'backToEvents': 'Back to events',
    'settingsGenderAgePreferences': 'Gender and Age Preferences',
    'settingsGenderAgePreferencesDesc':
        'Set gender and age preferences for each intent',
    'settingsEnforcementMode': 'Enforcement Mode',
    'settingsStrictLabel': 'Strict enforcement',
    'settingsFlexibleLabel': 'Flexible mode',
    'settingsStrictEnforcement':
        'Strict: Only create matches that meet ALL selected gender & age preferences',
    'settingsPrioritizeEnforcement':
        'Flexible: Prefer matches that meet your preferences but allow others',
    'settingsEnforcementHelpTitle': 'About Enforcement Mode',
    'settingsEnforcementHelpBody':
        'Strict enforcement ensures that matches are only created when the other person meets all your selected gender and age preferences (this may significantly reduce the number of matches). \n\nFlexible mode prefers matches that meet your preferences but will still create matches that don\'t match every preference (higher match rate).',
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
    'settingsDeleteAccountConfirm':
        'Are you sure you want to delete your account? This action cannot be undone and will permanently remove all your data.',
    'settingsDeleteAccountFailed': 'Failed to delete account',
    'settingsAccountDeleted': 'Account deleted successfully',
    'settingsAccountAlreadyDeleted':
        'Account already deleted - logged out successfully',
    'settingsAccountManagement': 'Account Management',
    'generalCancel': 'Cancel',
    'generalSave': 'Save',
    // Chat message options (fallbacks; prefer DB-provided translations)
    'chatOptionReact': 'React',
    'chatOptionEdit': 'Edit',
    'chatOptionDelete': 'Delete',
    'chatOptionCopy': 'Copy',
    'chatOptionReply': 'Reply',
    'chatTranslateAutoDisabled':
        'Translations turned off (UI matches translation language)',
    'chatYouAreChattingWith': 'You are chatting with',
    'replyingToLabel': 'Replying to',
    'chatEditingMessage': 'Editing message',
    'chatLoadingMessages': 'Loading messages...',
    'chatDeleteConfirm': 'Delete message?',
    'homeWelcome': 'Welcome',
    'homeNearby': 'Nearby',
    'homeOnline': 'Online',
    'homeTier': 'Tier',
    'invisibleDueTo': 'Invisible due to ',
    'invisibleDueTo_male': 'Invisible due to ',
    'invisibleDueTo_female': 'Invisible due to ',
    'invisibleDueTo_non_binary': 'Invisible due to ',
    'andInvisible': 'and Invisible',
    'andInvisible_male': 'and Invisible',
    'andInvisible_female': 'and Invisible',
    'andInvisible_non_binary': 'and Invisible',
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
    'chatSendFailed': 'Failed to send/edit message',
    'actionRefresh': 'Refresh',
    'verificationReview': 'Verification Review',
    'verificationNoPending': 'No pending verifications',
    'verificationUnknownUser': 'Unknown User',
    'verificationSubmittedPrefix': 'Submitted: ',
    'verificationAiAnalysisPrefix': 'AI Analysis: ',
    'verificationAutoRejected': 'Auto-rejected by AI',
    'actionReject': 'Reject',
    'actionApprove': 'Approve',
    'errorCouldNotOpenMaps': 'Could not open Google Maps',
    'failedToLoadPendingVerifications': 'Failed to load pending verifications',
    'adminAuthenticationRequired': 'Admin authentication required',
    'verificationApprovedSuccessfully': 'Verification approved successfully',
    'failedToApproveVerification': 'Failed to approve verification',
    'verificationRejectedMessage': 'Verification rejected',
    'failedToRejectVerification': 'Failed to reject verification',
    'verificationSimilarityPercentage': '{percentage}%',
    'interestsCategoryBusiness': 'Business Interests',
    'matchedOn': 'Matched on',
    'matchedAt': 'Matched at',
    // Connector word used between date and time in matched-at displays (e.g. "January 3, 2026, at 21:53")
    'at': 'at',
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
    'eventMatchingFunctionSuccess':
        'Event matching function called successfully',
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

    // Calendar Sync Messages
    'calendarSyncNoCalendarsFound': 'No calendars found',
    'calendarSyncRetry': 'Retry',
    'eventsNoUpcomingFound': 'No upcoming events found',
    'calendarSyncSwitchToGoogle': 'Switch to Google',
    'calendarSyncSwitchToOutlook': 'Switch to Outlook',
    'calendarSyncProviderTitle': 'Choose calendar provider',
    'calendarSyncSourceTitle': 'Choose import source',
    'calendarSyncProviderGoogle': 'Google',
    'calendarSyncProviderOutlook': 'Outlook',
    'calendarSyncProviderApple': 'Apple',
    'calendarSyncPreferredBadge': 'Preferred',
    'calendarSyncSourceDevice': 'Device calendar',
    'calendarSyncSourceOnline': 'Online calendar',
    'calendarSyncSourceWebOnly':
        'Web uses online calendar sign-in. Choose a provider and connect.',
    'calendarSyncOutlookNotConfigured':
        'Outlook is not configured. Please contact support or configure OUTLOOK_TENANT_ID, OUTLOOK_CLIENT_ID, and OUTLOOK_REDIRECT_URI in settings.',
    'calendarSyncOutlookSignIn': 'Please sign in to Outlook to continue.',
    'calendarSyncPermissionDenied':
        'Calendar access is required. Please grant permission in your device settings.',
    'calendarSyncPermissionFailed':
        'Failed to request calendar permissions. Please try again.',
    'calendarSyncPermissionBlocked':
        'Calendar permission is blocked by your device settings.',
    'calendarSyncGoogleAuthRequired': 'Google Sign-In Required',
    'calendarSyncGoogleAuthRequiredMessage':
        'To access your Google calendars, you need to sign in with your Google account.',
    'calendarSyncGoogleSignInCancelled':
        'Sign-in was cancelled. Please try again.',
    'calendarSyncGoogleConfigError':
        'Google Sign-In is not configured correctly for this app build. Please contact support.',
    'signIn': 'Sign In',
    'calendarSyncOutlookWebOnly':
        'Outlook calendar sync is currently only available on the web version.',
    'calendarSyncOutlookExpired':
        'Your Outlook session has expired. Please sign in again.',
    'calendarSyncOutlookFailed':
        'Failed to fetch Outlook calendars. Please try again later.',
    'calendarSyncNetworkError':
        'Network error. Please check your internet connection.',
    'calendarSyncTimeout': 'Request timed out. Please try again.',
    'calendarSyncUnexpectedError':
        'An unexpected error occurred. Please try again.',
    'calendarSyncOutlookEventsFailed':
        'Failed to fetch Outlook events. Please try again later.',
    'calendarSyncNoOutlookOnDevice':
        'No Outlook calendars found on this device.\n\nTo sync Outlook calendars:\n\nAndroid:\n1. Settings → Accounts → Add Account\n2. Select Microsoft Exchange or Outlook\n3. Sign in and enable Calendar sync\n\niOS:\n1. Settings → Calendar → Accounts → Add Account\n2. Select Outlook.com\n3. Sign in and enable Calendars\n\nWindows/Mac:\nOutlook calendars should sync automatically if Outlook is installed.\n\nAlternatively, use the web version for direct OAuth access.',
    'calendarSyncNoOutlookOnDevice_male':
        'No Outlook calendars found on this device.\n\nTo sync Outlook calendars:\n\nAndroid:\n1. Settings → Accounts → Add Account\n2. Select Microsoft Exchange or Outlook\n3. Sign in and enable Calendar sync\n\niOS:\n1. Settings → Calendar → Accounts → Add Account\n2. Select Outlook.com\n3. Sign in and enable Calendars\n\nWindows/Mac:\nOutlook calendars should sync automatically if Outlook is installed.\n\nAlternatively, use the web version for direct OAuth access.',
    'calendarSyncNoOutlookOnDevice_female':
        'No Outlook calendars found on this device.\n\nTo sync Outlook calendars:\n\nAndroid:\n1. Settings → Accounts → Add Account\n2. Select Microsoft Exchange or Outlook\n3. Sign in and enable Calendar sync\n\niOS:\n1. Settings → Calendar → Accounts → Add Account\n2. Select Outlook.com\n3. Sign in and enable Calendars\n\nWindows/Mac:\nOutlook calendars should sync automatically if Outlook is installed.\n\nAlternatively, use the web version for direct OAuth access.',
    'calendarSyncNoOutlookOnDevice_non_binary':
        'No Outlook calendars found on this device.\n\nTo sync Outlook calendars:\n\nAndroid:\n1. Settings → Accounts → Add Account\n2. Select Microsoft Exchange or Outlook\n3. Sign in and enable Calendar sync\n\niOS:\n1. Settings → Calendar → Accounts → Add Account\n2. Select Outlook.com\n3. Sign in and enable Calendars\n\nWindows/Mac:\nOutlook calendars should sync automatically if Outlook is installed.\n\nAlternatively, use the web version for direct OAuth access.',
    'calendarSyncOutlookDetected':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_male':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_female':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOutlookDetected_non_binary':
        'Outlook app is installed but calendar sync is disabled',
    'calendarSyncOpenOutlookGuidance':
        'Open Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh',
    'calendarSyncOpenOutlookGuidance_male':
        'Open Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh',
    'calendarSyncOpenOutlookGuidance_female':
        'Open Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh',
    'calendarSyncOpenOutlookGuidance_non_binary':
        'Open Outlook app, go to Settings → Calendar → Sync calendars, then return here and refresh',
    'calendarSyncWaitForSync':
        'Note: After enabling sync, it may take 30-60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_male':
        'Note: After enabling sync, it may take 30-60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_female':
        'Note: After enabling sync, it may take 30-60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncWaitForSync_non_binary':
        'Note: After enabling sync, it may take 30-60 seconds for calendars to appear. Wait a moment before clicking Retry.',
    'calendarSyncNoCalendarsGoogle':
        'No Google calendars found on this device.',
    'calendarSyncNoCalendarsGoogle_male':
        'No Google calendars found on this device.',
    'calendarSyncNoCalendarsGoogle_female':
        'No Google calendars found on this device.',
    'calendarSyncNoCalendarsGoogle_non_binary':
        'No Google calendars found on this device.',
    'calendarSyncNoCalendarsOutlook': 'No Outlook calendars found.',
    'calendarSyncNoCalendarsOutlook_male': 'No Outlook calendars found.',
    'calendarSyncNoCalendarsOutlook_female': 'No Outlook calendars found.',
    'calendarSyncNoCalendarsOutlook_non_binary': 'No Outlook calendars found.',
    'calendarSyncOpenOutlookSettings': 'Open Outlook App',
    'calendarSyncOutlookNotInstalled':
        'Outlook is not installed on this device. You can still connect via Outlook Web to import your calendars.',
    'calendarSyncOutlookUseWeb': 'Connect Outlook via Web',
    'calendarSyncOutlookWebNote':
        'If Outlook is not synced locally, sign in with your Outlook credentials and we will pull your calendars directly.',
    'calendarSyncConnectMessage': 'Connect your calendar to sync events',
    'calendarSyncConnectGoogle': 'Connect Google Calendar',
    'calendarSyncConnectOutlook': 'Connect Outlook Calendar',
    'calendarSyncConnectApple': 'Connect Apple Calendar',
    'calendarSyncConnectDevice': 'Connect Device Calendar',
    'calendarSyncDeviceUnknownAccount': 'Unknown account',
    'calendarSyncNoCalendarsDevice':
        'No device calendars were found on this device.',
    'calendarSyncNoCalendarsApple':
        'No Apple calendars found on this device. Make sure iCloud Calendar is enabled in your device account settings.',
    'calendarSyncAppleWebNotSupported':
        'Apple Calendar import on web is not available yet. Use iOS, macOS, or another device with Apple calendars enabled.',
    'calendarSyncAppleOnlineImportTitle': 'Apple Online Events Import',
    'calendarSyncApplePublicUrlLabel': 'Apple public calendar URL',
    'calendarSyncApplePublicUrlHint': 'webcal://p01-calendarws.icloud.com/...',
    'calendarSyncApplePublicUrlHelp':
        'Paste your public Apple calendar link to import events in read-only mode.',
    'calendarSyncApplePublicHelpLinkLabel':
        'How to get my Apple public calendar link',
    'calendarSyncApplePublicHelpLinkOpenFailed':
        'Unable to open Apple help page right now.',
    'calendarSyncApplePublicUrlRequired':
        'Please paste your Apple public calendar URL.',
    'calendarSyncApplePublicUrlInvalid':
        'Invalid Apple public calendar URL. Use a webcal:// or https:// link.',
    'calendarSyncApplePublicFetchFailed':
        'Failed to fetch events from the Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_male':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_female':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncApplePublicNoCalendars_non_binary':
        'No events were found for this Apple public calendar URL.',
    'calendarSyncLoadOutlookCalendars': 'Load Outlook Calendars',
    'calendarSyncLoadCalendars': 'Load Calendars',
    'calendarSyncNext': 'Next',
    'calendarSyncSyncSelected': 'Sync Selected',
    'calendarSyncTitle': 'Sync Calendar',
    'calendarSyncChangeCalendars': 'Change Calendars',
    'eventsImportOnlineProviders': 'Import from Online Providers',
    'eventsImportGoogle': 'Import from Google',
    'eventsImportOutlook': 'Import from Outlook',
    'eventsImportApple': 'Import from Apple',
    'eventsImportDeviceCalendar': 'Import from Device Calendar',
    'timeNight': 'Night',
    'eventLocationLabel': 'Location',
    'showPastEvents': 'Show past events',
    'eventCannotBeInPast': 'Event start time cannot be in the past',
    'generalContinue': 'Continue',
    'chatIsTyping': '{name} is typing',
    'batteryOptimizationTitle': 'Always On Mode',
    'batteryOptimizationMessage':
        'To ensure you never miss a match or message, please disable battery optimization for MatchMe.',
    'later': 'Later',
    'enable': 'Enable',
    'profileVerification': 'Get Verified',
    'getVerifiedToBuildTrust':
        'Verify your profile to build trust and get more matches.',
    'verifyNow': 'Verify Now',
    'cameraVerificationInstruction':
        'Position your face inside the oval and then tap the "Take Photo" button.',

    // --- Verification Screen ---
    'verification': 'Verification',
    'cameraNotAvailable': 'Camera not available. Please try again.',
    'errorTakingPhoto': 'Error taking photo',
    'verificationSubmittedSuccess':
        'Verification photo submitted successfully! We will review it shortly.',
    'failedToSubmitVerification': 'Failed to submit verification',
    'analyzingPhotos': 'Analyzing Photos',
    'analyzingPhotosDescription':
        'AI is comparing your photos for verification...',
    'verified': 'Verified',
    'verifiedDescription': 'Your profile has been verified successfully!',
    'verificationApprovedAutomatically': 'Verification approved automatically',
    'underReview': 'Under Review',
    'underReviewDescription':
        'Your verification photo is being reviewed by our team.',
    'pendingManualReview': 'Pending manual review',
    'verificationRejected': 'Verification Rejected',
    'aiAnalysisPrefix': 'AI Analysis',
    'aiDetectedMismatch':
        'AI detected that the verification photo does not match your profile photo.',
    'verificationNotApproved':
        'Your verification was not approved. Please try again with a clearer photo.',
    'autoRejected': 'Auto-rejected',
    'rejected': 'Rejected',
    'notVerified': 'Not Verified',
    'notVerifiedDescription': 'Get verified to build trust with other users.',
    'highSimilarity': 'High similarity',
    'mediumSimilarity': 'Medium similarity',
    'lowSimilarity': 'Low similarity',
    'similarityPercentage': '% Similarity',
    'verificationRequirements': 'Verification Requirements',
    'clearSelfiePhoto': 'Clear selfie photo',
    'clearSelfiePhotoDescription': 'Take a clear, well-lit photo of yourself',
    'goodLighting': 'Good lighting',
    'goodLightingDescription': 'Ensure your face is clearly visible',
    'noFiltersOrEdits': 'No filters or edits',
    'noFiltersOrEditsDescription':
        'Use your real appearance without modifications',
    'submitVerificationPhoto': 'Submit Verification Photo',
    'tapToTakeVerificationPhoto': 'Tap to take a verification photo',
    'takePhoto': 'Take Photo',
    'retakePhoto': 'Retake Photo',
    'submitForReview': 'Submit for Review',
    'verificationRetryNow': 'Try verification again',
    'verificationRetryReady': 'You can now submit a new verification photo.',
    'failedToResetVerification': 'Failed to reset verification',
    'verificationRejectedCanRetry':
        'Verification was rejected. Tap to try again.',

    // --- Gesture-based verification ---
    'verificationGestureRaiseRightHandTitle': 'Raise your right hand',
    'verificationGestureRaiseRightHandDescription':
        'Raise your right hand next to your face so your hand is clearly visible.',
    'verificationGesturePeaceSignTitle': 'Show a peace sign',
    'verificationGesturePeaceSignDescription':
        'Show a V-shaped peace sign with your right hand next to your face.',
    'verificationGestureTouchChinTitle': 'Touch your chin',
    'verificationGestureTouchChinDescription':
        'Touch your chin with your right hand so both your hand and chin are visible.',
    'verificationGestureHandOnHeadTitle': 'Place your hand on your head',
    'verificationGestureHandOnHeadDescription':
        'Place one hand flat on top of your head so your hand is clearly visible.',
    'verificationGestureThumbsUpTitle': 'Show a thumbs-up',
    'verificationGestureThumbsUpDescription':
        'Show a clear thumbs-up with your right hand next to your face.',
    'verificationGesturePointToCheekTitle': 'Point to your cheek',
    'verificationGesturePointToCheekDescription':
        'Point to one of your cheeks with your right hand so both your hand and cheek are visible.',
    'verificationGestureCoverMouthTitle': 'Cover your mouth with your hand',
    'verificationGestureCoverMouthDescription':
        'Cover your mouth with your right hand while keeping the rest of your face visible.',

    // --- Camera Preview Widget ---
    'confirmYourPhoto': 'Confirm your photo',
    'retake': 'Retake',
    'usePhoto': 'Use Photo',
    'takingPhotoIn': 'Taking photo in',
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
    // Return loading state initially - translations will be loaded async
    // BUT: Ensure we at least have default translations while loading
    return LocalizationState(
      currentLocale: const Locale('en'),
      textDirection: TextDirection.ltr,
      strings: Map<String, String>.from(LocalizationState._defaultTranslations),
      supportedLanguages: const [],
      isLoading: true,
    );
  }

  Future<void> _init() async {
    final supported = await _fetchSupportedLanguages();
    final prefs = await SharedPreferences.getInstance();
    String? langCode = prefs.getString('user_language_code');

    if (langCode == null) {
      try {
        final Locale deviceLocale =
            WidgetsBinding.instance.platformDispatcher.locale;
        langCode =
            supported.any((lang) => lang.code == deviceLocale.languageCode)
            ? deviceLocale.languageCode
            : 'en';
      } catch (e) {
        langCode = 'en';
      }
    }

    final AppLanguage initialLang = supported.firstWhere(
      (l) => l.code == langCode,
      orElse: () => supported.firstWhere(
        (l) => l.code == 'en',
        orElse: () => AppLanguage(code: 'en', displayName: 'English'),
      ),
    );

    // CRITICAL: Fetch from DB FIRST before setting state with non-loading
    // This ensures translations are loaded BEFORE showing the screen
    try {
      final strings = await _fetchTranslationsFromDB(initialLang.code);

      // Save to cache for future sessions
      await _saveTranslationsToCache(initialLang.code, strings);

      // Only update state if provider is still mounted
      if (!ref.mounted) return;

      state = LocalizationState(
        currentLocale: Locale(initialLang.code),
        textDirection: initialLang.direction,
        strings: strings,
        supportedLanguages: supported,
        isLoading: false,
      );
      debugPrint(
        '[L10N] Translations loaded from DB for $langCode (${strings.length} strings)',
      );
    } catch (e) {
      // If DB fetch fails, try cached strings
      final cachedStrings = await _loadTranslationsFromCache(initialLang.code);
      if (!ref.mounted) return;

      if (cachedStrings.isNotEmpty) {
        state = LocalizationState(
          currentLocale: Locale(initialLang.code),
          textDirection: initialLang.direction,
          strings: cachedStrings,
          supportedLanguages: supported,
          isLoading: false,
        );
        debugPrint(
          '[L10N] Translations loaded from cache for $langCode (${cachedStrings.length} strings)',
        );
      } else {
        // Use defaults - this should rarely happen if DB is working
        if (!ref.mounted) return;
        state = state.copyWith(supportedLanguages: supported, isLoading: false);
        debugPrint('[L10N] Using default translations (DB and cache failed)');
      }
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
          direction: (item['text_direction'] == 'RTL')
              ? TextDirection.rtl
              : TextDirection.ltr,
        );
      }).toList();
    } catch (e) {
      return [
        AppLanguage(
          code: 'en',
          displayName: 'English',
          direction: TextDirection.ltr,
        ),
      ];
    }
  }

  // *** MODIFIED: This function now fetches from translations table only ***
  Future<Map<String, String>> _fetchTranslationsFromDB(String langCode) async {
    final allStrings = <String, String>{};
    final fetchStart = DateTime.now();

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
        debugPrint(
          'No translations fetched from DB for locale: $langCode (elapsed=${DateTime.now().difference(fetchStart).inMilliseconds}ms)',
        );
      } else {
        final defaultKeys = LocalizationState._defaultTranslations.keys.toSet();
        final missing = defaultKeys.difference(_lastFetchedDbKeys);
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
      debugPrint(
        'Translation DB fetch failed for $langCode: $e (elapsed=${DateTime.now().difference(fetchStart).inMilliseconds}ms)',
      );
    }

    // Merge with code defaults to ensure every key has a fallback
    final merged = Map<String, String>.from(
      LocalizationState._defaultTranslations,
    );
    merged.addAll(allStrings); // DB overrides defaults when present

    return merged;
  }

  Future<Map<String, String>> _loadTranslationsFromCache(
    String langCode,
  ) async {
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

  Future<void> _saveTranslationsToCache(
    String langCode,
    Map<String, String> strings,
  ) async {
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

  Future<void> setLocale(
    String langCode, [
    List<AppLanguage>? supported,
  ]) async {
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

    // First check cache - if we already have translations for this language, use them
    final cachedStrings = await _loadTranslationsFromCache(lang.code);
    Map<String, String> strings;

    if (cachedStrings.isNotEmpty) {
      // Use cached translations - they're faster and avoid DB round-trip
      strings = cachedStrings;
      debugPrint(
        '[L10N] Using cached translations for $langCode (${strings.length} strings)',
      );
    } else {
      // No cache - fetch from DB
      strings = await _fetchTranslationsFromDB(lang.code);
      // Save to cache for future use
      await _saveTranslationsToCache(lang.code, strings);
      debugPrint(
        '[L10N] Fetched translations from DB for $langCode (${strings.length} strings)',
      );
    }

    // Respect provider lifecycle: if disposed while awaiting, bail out safely.
    if (!ref.mounted) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_language_code', lang.code);
    if (!ref.mounted) return;

    // Update users.preferred_language and chats.translation_language in database
    // Only attempt DB update if user is authenticated (skip on login screen)
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId != null) {
      await _updateLanguageInDatabase(lang.code);
    } else {
      debugPrint(
        '[L10N] Skipping DB language update: user not authenticated (login screen)',
      );
    }
    if (!ref.mounted) return;

    state = state.copyWith(
      currentLocale: Locale(lang.code),
      textDirection: lang.direction,
      strings: strings,
      supportedLanguages: supportedLanguages,
      isLoading: false,
      dbKeys: _lastFetchedDbKeys,
    );
  }

  /// Updates the user's preferred language in the database and all their chat translation settings
  Future<void> _updateLanguageInDatabase(String langCode) async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        debugPrint(
          '[L10N] Cannot update language in DB: user not authenticated',
        );
        return;
      }

      debugPrint(
        '[L10N] Updating preferred_language to $langCode for user $userId',
      );

      // Update users.preferred_language
      await Supabase.instance.client
          .from('users')
          .update({'preferred_language': langCode})
          .eq('id', userId);

      // Update translation_language for all user's chats
      await Supabase.instance.client
          .from('chats')
          .update({'translation_language': langCode})
          .eq('user_id', userId);

      debugPrint('[L10N] Successfully updated language in database');

      // Retranslate all existing messages to the new language
      await _retranslateAllMessages(userId, langCode);
    } catch (e) {
      debugPrint('[L10N] Error updating language in database: $e');
      // Don't throw - language update is not critical for UI to continue
    }
  }

  /// Retranslates the LAST incoming message for each chat when UI language changes
  /// Uses Case A/B/C logic to determine if translation is needed:
  /// - Case A: newUI != detected_source AND newUI != translated_target -> Call translate-proxy
  /// - Case B: newUI == detected_source -> Show original (no AI call)
  /// - Case C: newUI == translated_target -> Reuse existing (no AI call)
  Future<void> _retranslateAllMessages(String userId, String langCode) async {
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

      final chats = chatsResponse as List<dynamic>;

      if (chats.isEmpty) {
        debugPrint('[L10N] No translation-enabled chats found');
        return;
      }

      debugPrint(
        '[L10N] Found ${chats.length} translation-enabled chats, checking last messages',
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

          // Get the last incoming message (not from current user)
          final messagesResponse = await Supabase.instance.client
              .from('chat_messages')
              .select(
                'id, content_original, sender_id, detected_source_language, translated_target_language, content_translated',
              )
              .eq('match_id', matchId)
              .neq('sender_id', userId) // Only incoming messages
              .order('created_at', ascending: false)
              .limit(1);

          if (messagesResponse.isEmpty) {
            continue; // No incoming messages in this chat
          }

          final lastMessage = messagesResponse[0];
          final lastMessageId = lastMessage['id'] as String;

          // NEW RULE: Only translate immediately if this is also the absolute last message
          // If the last incoming message is NOT the absolute last message in the chat,
          // skip it - it will be translated when the user enters the chat
          final isAlsoAbsoluteLast = lastMessageId == absoluteLastMessageId;

          debugPrint(
            '[L10N] Chat $matchId: last incoming message id=$lastMessageId, absolute last id=$absoluteLastMessageId, isAlsoAbsoluteLast=$isAlsoAbsoluteLast',
          );

          if (!isAlsoAbsoluteLast) {
            debugPrint(
              '[L10N] Skipping: last incoming message is not the absolute last message in chat $matchId - will translate when user enters chat',
            );
            continue;
          }
          final detectedSource =
              lastMessage['detected_source_language'] as String?;
          final translatedTarget =
              lastMessage['translated_target_language'] as String?;
          final existingTranslation =
              lastMessage['content_translated'] as String?;

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
            skippedCaseB++;
            continue;
          }

          // Case C: UI language matches existing translation target -> Reuse translation
          if (targetLang != null &&
              targetLang == uiLang &&
              existingTranslation != null &&
              existingTranslation.isNotEmpty &&
              existingTranslation != 'null') {
            debugPrint(
              '[L10N] Case C: Already translated to $targetLang, reusing',
            );
            await localDb.updateChatLastMessageTranslation(
              userId,
              matchId,
              lastMessageId,
              existingTranslation,
            );
            skippedCaseC++;
            continue;
          }

          // Case A: Need to translate (UI != source AND UI != existing target)
          // Call translate-proxy for this single message
          debugPrint('[L10N] Case A: Need to translate to $uiLang');

          await Supabase.instance.client.functions.invoke(
            'translate-proxy',
            body: {
              'match_id': matchId,
              'target_language': langCode,
              'retranslate_all': true,
              'exclude_sender_id': userId,
            },
          );

          final refreshed = await Supabase.instance.client
              .from('chat_messages')
              .select('content_translated, translated_target_language')
              .eq('id', lastMessageId)
              .maybeSingle();
          final translatedText = refreshed?['content_translated'] as String?;
          final refreshedTarget =
              refreshed?['translated_target_language'] as String?;

          if (translatedText != null &&
              translatedText.isNotEmpty &&
              translatedText != 'null' &&
              refreshedTarget != null &&
              refreshedTarget.toLowerCase() == uiLang) {
            await localDb.updateChatLastMessageTranslation(
              userId,
              matchId,
              lastMessageId,
              translatedText,
            );
            debugPrint('[L10N] Updated local cache for chat $matchId');
            translatedCount++;
            debugPrint('[L10N] Translated last message for chat $matchId');
          }
        } catch (e) {
          debugPrint('[L10N] Error processing chat $matchId: $e');
          // Continue with other chats
        }
      }

      debugPrint(
        '[L10N] Smart retranslation complete: $translatedCount translated, $skippedCaseB (show original), $skippedCaseC (reuse)',
      );
    } catch (e) {
      debugPrint('[L10N] Error in smart retranslation: $e');
      // Don't throw - retranslation is not critical
    }
  }

  /// Public method to sync language to database after login
  /// Call this after the user successfully logs in to ensure their language preference
  /// (which may have been set on the login screen) is synced to the database
  Future<void> syncLanguageAfterLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLangCode = prefs.getString('user_language_code');
    final currentLangCode = state.currentLocale.languageCode;
    final langCode = savedLangCode ?? currentLangCode;

    debugPrint(
      '[L10N] syncLanguageAfterLogin: savedLangCode=$savedLangCode, currentLangCode=$currentLangCode, using=$langCode',
    );

    // Update database with current language preference
    await _updateLanguageInDatabase(langCode);

    debugPrint(
      '[L10N] Synced language preference to database after login: $langCode',
    );
  }
}

// --- 4. The Main Provider ---
// Generated by @riverpod
