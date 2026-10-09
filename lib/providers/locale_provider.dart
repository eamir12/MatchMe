// lib/providers/locale_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/supabase_realtime_manager.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/translation_edit_marker.dart';
import 'package:matchme/utils/resume_diagnostics.dart';
import 'package:matchme/services/chat_key_service.dart';
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
    required TextDirection textDirection,
    required this.strings,
    required this.supportedLanguages,
    this.isLoading = false,
    this.dbKeys = const <String>{},
  }) : textDirection = _reconcileDirection(currentLocale, textDirection);

  /// Direction follows the language code, always.
  ///
  /// [textDirection] is honoured only when it agrees with the code. A Hebrew or
  /// Arabic locale can therefore never be paired with an LTR state — which
  /// would otherwise lay out the entire UI, chevrons included, backwards — and
  /// no call site has to remember to pass the right value.
  static TextDirection _reconcileDirection(
    Locale locale,
    TextDirection declared,
  ) {
    final fromCode = isRtlLanguageCode(locale.languageCode)
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
  final Set<String> _missingTranslationWarned = <String>{};
  static int _missingKeysLimit = 20;

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

    // Try direct lookup first
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
    final defaultTranslation = _defaultTranslations[key];
    if (defaultTranslation != null) {
      return _applyParams(defaultTranslation, params);
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
    'authCaptchaCancelled': 'Security check was cancelled.',
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
    'authOAuthCancelled': 'Sign-in cancelled',
    'authOAuthFailed': 'Authentication failed',
    'authOAuthInvalidState': 'An OAuth error occurred. Please try again.',
    'authOAuthProviderFailed':
        'There was a problem logging in using {provider}.',
    'authOAuthSuggestionPasskey': 'You can also try using a passkey.',
    'authOAuthSuggestionDifferentProvider':
        'You can also try a different login provider.',
    'authOAuthSuggestionPassword': 'You can also try username and password.',
    'authOr': 'or',
    'authPasskeyAvailable': 'Passkey sign-in available for this account',
    'authPasskeyBody':
        'Use the passkey saved on this device to sign in securely without a password.',
    'authPasskeyCancelled': 'Passkey authentication was cancelled',
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
    'billingCancelled': 'Cancelled',
    'billingCancelledOn': 'Cancelled on',
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
    'calendarSyncDeviceSummaryBody':
        '{accounts} accounts found · {events} events found · {selected} selected',
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
        'Google sign-in was cancelled. Please try again.',
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
    'durationDay': '{count} day',
    'durationDays': '{count} days',
    'durationHour': '{count} hour',
    'durationHours': '{count} hours',
    'durationLessThanMinute': 'Less than a minute',
    'durationLessThanOneMinute': 'less than 1 minute',
    'durationMinute': '{count} minute',
    'durationMinutes': '{count} minutes',
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
        'Only people you’ve matched with are shown—not the full attendee list.',
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
    'homeNearbyMapPinnedLocation':
        'Your location is currently pinned{label}.',
    'homeNearbyMapPinnedToLabel': 'to',
    'homeNoChats': 'No recent chats',
    'homeNoMatches': 'No recent matches',
    'homeOnline': 'Online',
    'homeRecentChats': 'Recent Chats',
    'homeRecentMatches': 'Recent Matches',
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
    'locationShareCountdownMinutes':
        'for another {minutes} minutes and {seconds} seconds',
    'locationShareCountdownHours':
        'for another {hours} hours and {minutes} minutes',
    'locationShareCountdownHoursSeconds':
        'for another {hours} hours, {minutes} minutes and {seconds} seconds',
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
    'mapApproxUsersHere': 'Approx users here: {count}',
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
    'mapShowingApproxUsers': 'Showing ~{count} online',
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
    'pinnedLocationLabelHint': 'Label (optional, e.g. Home)',
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
    'pinnedLocationRemainingDays': '{count}d',
    'pinnedLocationRemainingHours': '{count}h',
    'pinnedLocationRemainingMinutes': '{count}m',
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
        'You have {count} pending change{plural} waiting to sync. These will be sent to the server when your connection is restored.\\n\\nActions in MatchMe will be unavailable until these sync.',
    'offlinePendingChangesPlural': 's',
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
    'offlineSyncingChanges': 'Syncing {count} change{plural}',
    'offlineSyncingChangesPlural': 's',
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
    'onlineProvidersEvents': 'events',
    'onlineProvidersEventSingular': 'event',
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
    'onlineProvidersSummaryBody':
        '{accounts} accounts connected · {events} events found · {selected} selected',
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
    'profileBasicsHelper':
        'Tell us a bit about yourself so people can get to know you.',
    'profileBasicsLockedNoteBody':
        'Some profile details cannot be edited at this time',
    'profileBasicsLockedNoteTitle': 'Profile locked',
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
    'profileReligion': 'Religion',
    'profileWizardReligionTitle': 'Your Religion',
    'profileWizardReligionSubtitle':
        'Share your religious affiliation, or skip if you prefer not to say.',

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

    // Religious affiliation options
    'religionChristianity': 'Christianity',
    'religionIslam': 'Islam',
    'religionHinduism': 'Hinduism',
    'religionBuddhism': 'Buddhism',
    'religionJudaism': 'Judaism',
    'religionOther': 'Other',
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
    'profileVerifiedBadge': 'Verified',
    'profileVerifiedBadgeFemale': 'Verified',
    'profileVerifiedBadgeNeutral': 'Verified',
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
    'promoCodeExpiresInSingular': 'Expires in {days} day',
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
    'promoDiscountFreeDaysManyFormat': '{days} days Free',
    'promoDiscountFreeDaysOneFormat': '{days} day Free',
    'promoDiscountPercentageFormat': '{amount}% Off',
    'promoDiscountSpecialOffer': 'Special Offer',
    'promoDiscountTierUpgradeFormat': 'Upgrade to {tier}',
    'Proximity': 'Proximity',
    'pushNewMatchBody': 'You matched with {name}',
    'pushNewMatchTitle': 'New match!',
    'pushNewMessageBodyFallback': 'New message',
    'pushNewMessageTitleFallback': 'New message',
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
    'securityCenterPasskeyPrimaryOff':
        'Add a passkey for faster, more secure sign-in.',
    'securityCenterPasskeyPrimaryReady':
        'Passkeys are ready for faster, passwordless sign-in.',
    'securityCenterPasskeyPrimarySignedIn':
        'You signed in with a passkey on this device.',
    'securityCenterPasskeySecondaryProtected':
        'A passkey is already protecting this account.',
    'securityCenterPasskeySecondaryReady':
        'This device and server are ready for a new passkey.',
    'securityCenterPasskeySecondarySetupRequired':
        'Server configuration is still required before passkeys can be added.',
    'securityCenterPasskeySecondaryUnsupported':
        'This device does not support passkeys.',
    'securityCenterPasskeySessionOther':
        'You signed in with {method}. Add a passkey for future sign-ins.',
    'securityCenterPasskeySessionPasskey':
        'This session is already using a passkey.',
    'securityCenterPasskeySessionReady':
        'A passkey is ready for future sign-ins.',
    'securityCenterSettingsEntryBody':
        'Manage your authenticator, passkeys, and recovery options',
    'securityCenterStatusActive': 'Active',
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
    'settingsAccuracyMeters': 'Accuracy: ~{meters} meters',
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
    'settingsMfaTitle': 'Authenticator app',
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
    'settingsReligion': 'Religion',
    'settingsReligionAny': 'Any',
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
    'settingsRetroOneDay': '1 day',
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
    'listFilterOptionsSection': 'Options',
    'listFilterShowResults': 'Show {count} results',
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
    'verificationCaptureClose': 'Close',
    'verificationCaptureFailedToLoad': 'Failed to load MediaPipe: {error}',
    'verificationCaptureHandLeft': 'left',
    'verificationCaptureHandRight': 'right',
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
    'verificationCaptureStatusUseCorrectHand': 'Use your {hand} hand',
    'verificationCaptureWrapperFailedToLoad':
        'Verification capture failed to load: {error}',
    'verificationGestureClosedFistDescription':
        'Show a closed fist with your right hand next to your face.',
    'verificationGestureClosedFistLeftDescription':
        'Show a closed fist with your left hand next to your face.',
    'verificationGestureClosedFistLeftTitle':
        'Show a closed fist with your left hand',
    'verificationGestureClosedFistTitle': 'Show a closed fist',
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
        'Show an open palm with your right hand next to your face, with your fingers fully visible.',
    'verificationGestureOpenPalmLeftDescription':
        'Show an open palm with your left hand next to your face, with your fingers fully visible.',
    'verificationGestureOpenPalmLeftTitle':
        'Show an open palm with your left hand',
    'verificationGestureOpenPalmTitle': 'Show an open palm',
    'verificationGesturePeaceSignDescription':
        'Show a V-shaped peace sign with your right hand next to your face.',
    'verificationGesturePeaceSignLeftDescription':
        'Show a V-shaped peace sign with your left hand next to your face.',
    'verificationGesturePeaceSignLeftTitle':
        'Show a peace sign with your left hand',
    'verificationGesturePeaceSignTitle': 'Show a peace sign',
    'verificationGesturePointingUpDescription':
        'Point up with your right index finger next to your face.',
    'verificationGesturePointingUpLeftDescription':
        'Point up with your left index finger next to your face.',
    'verificationGesturePointingUpLeftTitle':
        'Point up with your left index finger',
    'verificationGesturePointingUpTitle': 'Point up with your index finger',
    'verificationGesturePointToCheekDescription':
        'Point to your cheek with your finger',
    'verificationGesturePointToCheekTitle': 'Point to your cheek',
    'verificationGestureRaiseRightHandDescription':
        'Raise your right hand clearly in the photo',
    'verificationGestureRaiseRightHandTitle': 'Raise your right hand',
    'verificationGestureThumbsDownDescription':
        'Show a clear thumbs-down with your right hand next to your face.',
    'verificationGestureThumbsDownLeftDescription':
        'Show a clear thumbs-down with your left hand next to your face.',
    'verificationGestureThumbsDownLeftTitle':
        'Show a thumbs-down with your left hand',
    'verificationGestureThumbsDownTitle': 'Show a thumbs-down',
    'verificationGestureThumbsUpDescription':
        'Show a clear thumbs-up with your right hand next to your face.',
    'verificationGestureThumbsUpLeftDescription':
        'Show a clear thumbs-up with your left hand next to your face.',
    'verificationGestureThumbsUpLeftTitle':
        'Show a thumbs-up with your left hand',
    'verificationGestureThumbsUpTitle': 'Show a thumbs-up',
    'verificationGestureTouchChinDescription': 'Touch your chin with your hand',
    'verificationGestureTouchChinTitle': 'Touch your chin',
    'verificationNoPending': 'No pending verifications',
    'verificationNotApproved':
        'Your verification was not approved. Please try again with a clearer photo.',
    'verificationPrivacyNotice':
        'Your verification photo is used for verification and fraud prevention, stays private, and is kept only as long as needed for review and community safety. After that, we keep only derived fraud-prevention signals.',
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
    'profileWizardInterestMin': '{intent} requires at least {min} interest',
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
    'profileHeightFeetInches': '{feet} feet {inches} inches',
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
    'matchExtensionDurationHours': '{count} hour',
    'matchExtensionDurationHoursPlural': '{count} hours',
    'matchExtensionDurationMinutes': '{count} minute',
    'matchExtensionDurationMinutesPlural': '{count} minutes',
    'matchExtensionDurationDays': '{count} day',
    'matchExtensionDurationDaysPlural': '{count} days',

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
        'Choose your religious background, then tap Next.',
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
    'settingsAppTourDesc': 'Watch the guided introduction to MatchMe again.',
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
        'You earned a Verified badge by completing the verification procedure from Settings… This badge shows on your profile and whenever others see you.',
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
        'Verification is launched from here… Complete a live selfie check to earn the Verified badge that appears on your profile and when others see you.',
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
    'onboardingDemoRadius': '2 km',
    'onboardingDemoDaySat': 'SAT',
    'onboardingDemoDaySun': 'SUN',
    'onboardingDemoTimeLeft': '23h',
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
        'A live selfie check is needed to unlock the verified badge.',
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

  /// Formats a count number with abbreviated units (e.g., 1.5k, 3M).
  String formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return n.toString();
  }
}

// --- 3. The Notifier ---
@Riverpod(keepAlive: true)
class Localization extends _$Localization {
  // Keys that were provided by the DB in the most recent fetch
  Set<String> _lastFetchedDbKeys = <String>{};

  // Remember which DB keys we've warned about already to avoid log spam
  final Set<String> _missingDbKeysWarned = <String>{};
  RealtimeChannel? _languageRealtimeChannel;
  String? _languageRealtimeUserId;
  StreamSubscription<AuthState>? _authStateSubscription;
  bool _localeChangeInFlight = false;
  String? _localeChangeTarget;

  // Guards against overlapping smart retranslations when the language
  // changes before the previous retranslation completes.
  bool _retranslationInProgress = false;

  // Dedup key for _updateLanguageInDatabase. Bootstrap fires it from both
  // _loadStringsAndUpdateState (after first fetch) AND from the auth
  // listener (syncLanguageAfterLogin). Without this guard each cold start
  // updates the DB twice and runs smart retranslation twice.
  String? _lastSyncedLanguageInDb;
  String? _lastSyncedLanguageUserId;

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
            }
            _ensureLanguageRealtimeSubscription();
            if (authEvent != AuthChangeEvent.signedIn) {
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
    final userId = _languageRealtimeUserId;
    _languageRealtimeChannel = null;
    _languageRealtimeUserId = null;
    if (userId != null) {
      SupabaseRealtimeManager.instance.unregister('user_language_$userId');
    }
  }

  void _ensureLanguageRealtimeSubscription() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      _clearLanguageRealtimeSubscription();
      return;
    }
    if (_languageRealtimeChannel != null && _languageRealtimeUserId == userId) {
      return;
    }
    _clearLanguageRealtimeSubscription();

    final channelName = 'user_language_$userId';
    SupabaseRealtimeManager.instance.register(channelName, () {
      _languageRealtimeChannel = Supabase.instance.client
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'users',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: userId,
            ),
            callback: (payload) {
              final newRecord = payload.newRecord;
              final remoteLanguage = newRecord['preferred_language'] as String?;
              if (remoteLanguage == null || remoteLanguage.isEmpty) return;
              if (remoteLanguage == state.currentLocale.languageCode) return;
              if (_localeChangeInFlight &&
                  _localeChangeTarget == remoteLanguage) {
                return;
              }
              unawaited(setLocale(remoteLanguage, null, false));
            },
          )
          .subscribe((status, err) {
            if (status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut ||
                status == RealtimeSubscribeStatus.closed) {
              if (err != null && isExpectedOfflineFailure(err)) {
                // Proactively pause to suppress errors from other
                // channels and avoid the race with the connectivity
                // provider's own pauseAll() call.
                SupabaseRealtimeManager.instance.pauseAll();
                return;
              }
              if (SupabaseRealtimeManager.instance.isPaused) return;
              unawaited(_syncLanguageFromRemote());
            }
          });
      _languageRealtimeUserId = userId;
      return _languageRealtimeChannel!;
    });
  }

  Future<void> _syncLanguageFromRemote() async {
    if (!offlineCacheManager.isSupabaseAvailable) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final response = await Supabase.instance.client
          .from('users')
          .select('preferred_language')
          .eq('id', userId)
          .maybeSingle();
      final remoteLanguage = response?['preferred_language'] as String?;
      if (remoteLanguage == null || remoteLanguage.isEmpty) return;
      if (remoteLanguage == state.currentLocale.languageCode) return;
      await setLocale(remoteLanguage, null, false);
    } catch (_) {}
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
    } else {
      supported = await _fetchSupportedLanguages().timeout(
        const Duration(seconds: 5),
        onTimeout: () => _defaultSupportedLanguages(),
      );
    }

    final prefs = await SharedPreferences.getInstance();
    String? langCode = prefs.getString('user_language_code');

    if (langCode == null) {
      // Cold start with empty prefs: prefer the user's saved language from
      // the DB over the device locale. Without this, on devices where the
      // system language differs from the user's account preference
      // (e.g. device=`he`, account=`en`), every launch races:
      //   1. _init sets UI to the device locale
      //   2. syncLanguageAfterLogin (~750ms later) overwrites DB with
      //      the device locale
      //   3. _syncLanguageFromRemote re-reads DB and flips back to the
      //      account preference
      // Net effect: 2x DB writes + 2x smart-retranslation passes.
      if (!isOffline) {
        final initUserId = Supabase.instance.client.auth.currentUser?.id;
        if (initUserId != null) {
          try {
            final remote = await Supabase.instance.client
                .from('users')
                .select('preferred_language')
                .eq('id', initUserId)
                .maybeSingle()
                .timeout(const Duration(seconds: 5));
            if (!ref.mounted) return;
            final remoteLang = remote?['preferred_language'] as String?;
            if (remoteLang != null &&
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
    final cachedStrings = await _loadTranslationsFromCache(initialLang.code);
    if (cachedStrings.isNotEmpty) {
      if (!ref.mounted) return;

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
      _syncNativeBackgroundNotificationStrings(cachedStrings);

      // Refresh cache from DB in the background (only when online).
      if (offlineCacheManager.isSupabaseAvailable) {
        unawaited(_refreshTranslationCache(initialLang.code));
      }
    } else {
      // No cache — fetch from DB (will fall back to defaults on failure).
      try {
        final strings = await _fetchTranslationsFromDB(initialLang.code);

        await _saveTranslationsToCache(initialLang.code, strings);

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
        _syncNativeBackgroundNotificationStrings(strings);
      } catch (e) {
        if (!ref.mounted) return;
        state = state.copyWith(supportedLanguages: supported, isLoading: false);
        debugPrint('[L10N] Using default translations (DB and cache failed)');
        _syncNativeBackgroundNotificationStrings(state.strings);
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

  /// Background-refresh translation cache from DB (only call when online).
  Future<void> _refreshTranslationCache(String langCode) async {
    try {
      final strings = await _fetchTranslationsFromDB(langCode);
      await _saveTranslationsToCache(langCode, strings);
    } catch (_) {}
  }

  /// Public method: force-refresh translations from the DB for the current
  /// locale and update the in-memory state so the UI reflects admin changes
  /// without switching locales.
  Future<void> refreshTranslations() async {
    final currentLang = state.currentLocale.languageCode;
    if (!offlineCacheManager.isSupabaseAvailable) return;
    final strings = await _fetchTranslationsFromDB(currentLang);
    await _saveTranslationsToCache(currentLang, strings);
    if (!ref.mounted) return;
    state = state.copyWith(strings: strings, dbKeys: _lastFetchedDbKeys);
    _syncNativeBackgroundNotificationStrings(strings);
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

  Future<Map<String, String>> _fetchTranslationsFromDB(String langCode) async {
    // Skip DB call when offline to avoid 50s auth timeout.
    if (!offlineCacheManager.isSupabaseAvailable) {
      debugPrint('[L10N] Skipping DB fetch for $langCode (offline)');
      return <String, String>{};
    }

    final allStrings = <String, String>{};
    final fetchStart = DateTime.now();

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

    return merged;
  }

  Future<Map<String, String>> _loadTranslationsFromCache(
    String langCode,
  ) async {
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

  void _syncNativeBackgroundNotificationStrings(Map<String, String> strings) {
    // Persist the "MatchMe Active" foreground notification title/text in the
    // user's current display language so the Android service can show it
    // localized even after process death / reboot. Best-effort, never throw.
    try {
      final title =
          strings['bgNotificationTitle'] ??
          LocalizationState._defaultTranslations['bgNotificationTitle'] ??
          'MatchMe Active';
      final text =
          strings['bgNotificationText'] ??
          LocalizationState._defaultTranslations['bgNotificationText'] ??
          'You are visible and background matching is enabled.';
      unawaited(
        BackgroundService.setNativeBackgroundNotificationStrings(
          title: title,
          text: text,
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
      final cachedStrings = await _loadTranslationsFromCache(lang.code);
      Map<String, String> strings;

      if (cachedStrings.isNotEmpty) {
        // Use cached translations - they're faster and avoid DB round-trip
        strings = cachedStrings;
        debugPrint(
          '[L10N] Using cached translations for $langCode (${strings.length} strings)',
        );

        // If online and this is not English, refresh the cache in the
        // background so any corrupted cache (e.g. English defaults saved
        // during a previous offline session) gets overwritten.
        if (langCode != 'en' && offlineCacheManager.isSupabaseAvailable) {
          unawaited(_refreshTranslationCache(langCode));
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

      // Update UI immediately — don't block on DB sync.
      state = state.copyWith(
        currentLocale: Locale(lang.code),
        textDirection: lang.direction,
        strings: strings,
        supportedLanguages: supportedLanguages,
        isLoading: false,
        dbKeys: _lastFetchedDbKeys,
      );
      _syncNativeBackgroundNotificationStrings(strings);

      // Sync preferred_language to the database in the background.
      // This can block for 50+ seconds when offline (auth timeout), so
      // never await it here.
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (syncToDatabase && currentUserId != null) {
        unawaited(_updateLanguageInDatabase(lang.code));
      } else if (syncToDatabase) {
        debugPrint(
          '[L10N] Skipping DB language update: user not authenticated (login screen)',
        );
      }
    } finally {
      if (_localeChangeTarget == langCode) {
        _localeChangeInFlight = false;
        _localeChangeTarget = null;
      }
    }
  }

  /// Updates the user's preferred language in the database and all their chat translation settings
  Future<void> _updateLanguageInDatabase(String langCode) async {
    // Skip entirely when offline to avoid noisy SocketException logs.
    if (!offlineCacheManager.isSupabaseAvailable) return;
    // A dead/rotated refresh token means every authenticated call fails.
    // Don't even start — the pre-check + 2 UPDATEs + retranslation scan
    // would just add fuel to a 429 rate-limit spiral.
    if (Supabase.instance.client.auth.currentSession == null) return;

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        return;
      }

      // Skip if we already pushed this exact language for this user during
      // the current session. Multiple callers (locale init,
      // syncLanguageAfterLogin, home pull-to-refresh) otherwise duplicate
      // the same UPDATE + smart-retranslation pass on cold start.
      if (_lastSyncedLanguageInDb == langCode &&
          _lastSyncedLanguageUserId == userId) {
        debugPrint(
          '[L10N] Skipping DB update: language already synced this session',
        );
        return;
      }

      // Cold-start short-circuit: if the DB already stores the language the
      // UI is about to use, do nothing. Without this, every launch re-runs
      // the UPDATE + smart-retranslation pass even when nothing changed,
      // which on the moto g54 5G added a noticeable 1+ second after the
      // first frame was already rendered.
      if (!ref.mounted) return;
      try {
        final existing = await Supabase.instance.client
            .from('users')
            .select('preferred_language')
            .eq('id', userId)
            .maybeSingle();
        if (!ref.mounted) return;
        final stored =
            (existing == null
                    ? null
                    : existing['preferred_language'] as String?)
                ?.trim();
        if (stored != null && stored.isNotEmpty && stored == langCode) {
          debugPrint(
            '[L10N] Skipping DB update: language already stored (no change)',
          );
          _lastSyncedLanguageInDb = langCode;
          _lastSyncedLanguageUserId = userId;
          // NOTE: Do NOT set _lastRetranslatedLanguage here. That flag is only set
          // after _retranslateAllMessages() actually completes. Setting it here
          // would cause a subsequent call to _retranslateAllMessages() with the same
          // language to skip due to the dedup guard, even though retranslation never
          // actually happened. This bug manifests on the 3rd+ language switch when
          // the user switches to a previously-used language that's already in the DB.
          return;
        }
      } catch (e) {
        // When the pre-check itself is rejected (dead session, 429 rate
        // limit, RLS 42501), the UPDATE below is guaranteed to fail too —
        // abort now and back off instead of doubling the request storm.
        if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
          _lastLanguageSyncFailureAt = DateTime.now();
          debugPrint(
            '[L10N] Skipping DB update: pre-check failed with auth/rate-limit, backing off: $e',
          );
          return;
        }
        debugPrint(
          '[L10N] Could not pre-check stored language, proceeding with update: $e',
        );
      }

      debugPrint('[L10N] Updating preferred_language to $langCode');

      try {
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
      } catch (e) {
        // Auth/rate-limit/RLS rejection: back off, don't run retranslation.
        if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
          _lastLanguageSyncFailureAt = DateTime.now();
          debugPrint(
            '[L10N] Skipping DB update: write rejected with auth/rate-limit, backing off: $e',
          );
          return;
        }
        rethrow;
      }

      _lastSyncedLanguageInDb = langCode;
      _lastSyncedLanguageUserId = userId;

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
    } catch (e) {
      if (isAuthRateLimitFailure(e) || isExpectedOfflineFailure(e)) {
        _lastLanguageSyncFailureAt = DateTime.now();
      }
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
                final clientDetected = normalizeLanguageCode(
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

  /// Sync current language preference to the database.
  /// Safe to call on any auth event (initialSession or signedIn) — the name
  /// intentionally avoids "afterLogin" since it also fires on session restore.
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
    final currentLangCode = state.currentLocale.languageCode;
    final now = DateTime.now();
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
    // Cooldown for repeat calls with an unchanged language (auth event
    // flaps, duplicate initialSession, pull-to-refresh, login screen).
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
    debugPrint(
      '[L10N] syncLanguageAfterLogin: currentLangCode=$currentLangCode',
    );

    // Update database with current language preference
    final future = _updateLanguageInDatabase(currentLangCode);
    _languageSyncInFlight = future;
    try {
      await future;
    } finally {
      _languageSyncInFlight = null;
    }
  }
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

    return Supabase.instance.client
        .from('translations')
        .stream(primaryKey: const ['locale', 'key'])
        .eq('locale', currentLangCode)
        .map((rows) {
          developer.log(
            'Translations changed for $currentLangCode, refreshing',
            name: 'TranslationsRealtime',
          );
          ref.read(localizationProvider.notifier).refreshTranslations();
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
