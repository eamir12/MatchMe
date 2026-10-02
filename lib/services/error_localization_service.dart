// Error localization service for mapping exceptions to user-friendly translation keys.
//
// This service converts various exception types to appropriate translation keys that
// are localized in the Supabase translations table (English, Spanish, Hebrew).
//
// All errors shown to users should go through this service to ensure they are:
// 1. User-friendly (not technical)
// 2. Properly localized
// 3. Consistent across the app

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/email_change_service.dart';
import 'package:matchme/services/password_reset_service.dart';
import 'package:matchme/services/signup_email_otp_service.dart';
import 'package:matchme/services/sensitive_action_reauth_service.dart';

class ErrorLocalizationService {
  /// Map any exception to a localization key.
  /// Returns a translation key that should be retrieved via localizationProvider.getString(key)
  static String getErrorTranslationKey(dynamic error, {bool isSignUp = false}) {
    // Network/Connectivity errors
    if (_isNetworkError(error)) {
      return _mapNetworkError(error);
    }

    // Password reset / signup OTP / sensitive-action exceptions – map by code/message
    if (error is PasswordResetException) {
      return _mapPasswordResetException(error);
    }
    if (error is SignupEmailOtpException) {
      return _mapSignupOtpException(error);
    }
    if (error is SensitiveActionReauthException) {
      return _mapSensitiveActionReauthException(error);
    }
    if (error is EmailChangeException) {
      return _mapEmailChangeException(error);
    }

    // Supabase AuthException
    if (error is AuthException) {
      return _mapAuthException(error, isSignUp: isSignUp);
    }

    // Passkey errors (these have their own exception types)
    if (error is Exception) {
      final msgLower = error.toString().toLowerCase();
      if (msgLower.contains('passkey')) {
        return _mapPasskeyError(error);
      }
    }

    // Photo verification errors (thrown as translation keys from profile_provider)
    if (error is Exception) {
      final msg = error.toString();
      const prefix = 'Exception: secondaryPhotoVerificationError';
      if (msg.startsWith(prefix)) {
        return msg.substring('Exception: '.length);
      }
    }

    // Generic exception fallback
    return 'authUnexpectedError';
  }

  static String getMapErrorTranslationKey(dynamic error) {
    final key = getErrorTranslationKey(error);
    return key.startsWith('networkError') ? key : 'generalError';
  }

  /// Check if the error is a network/connectivity related error
  static bool _isNetworkError(dynamic error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('clientexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('network is unreachable') ||
        msg.contains('connection refused') ||
        msg.contains('connection reset') ||
        msg.contains('software caused connection abort') ||
        msg.contains('timed out') ||
        msg.contains('timeout') ||
        msg.contains('eof exception') ||
        msg.contains('handshake exception') ||
        msg.contains('certificate verification failed') ||
        msg.contains('netconnection error') ||
        msg.contains('platformexception') && msg.contains('network');
  }

  /// Map network errors to localization keys
  static String _mapNetworkError(dynamic error) {
    final msg = error.toString().toLowerCase();

    if (msg.contains('timed out') || msg.contains('timeout')) {
      return 'networkErrorTimeout';
    }

    if (msg.contains('failed host lookup') ||
        msg.contains('no address associated with hostname')) {
      return 'networkErrorNoInternet';
    }

    if (msg.contains('connection refused') ||
        msg.contains('connection reset') ||
        msg.contains('connection aborted')) {
      return 'networkErrorConnectionFailed';
    }

    if (msg.contains('certificate verification failed') ||
        msg.contains('handshake exception')) {
      return 'networkErrorSSLCertificate';
    }

    if (msg.contains('network is unreachable') || msg.contains('no internet')) {
      return 'networkErrorNoInternet';
    }

    // Generic network error
    return 'networkErrorGeneric';
  }

  /// Map AuthException to localization keys
  static String _mapAuthException(AuthException e, {bool isSignUp = false}) {
    final msg = e.message.toLowerCase();

    // Network errors wrapped in AuthException
    if (_isNetworkError(e.message)) {
      return _mapNetworkError(e.message);
    }

    // Password-related errors
    if (msg.contains('invalid login credentials') ||
        msg.contains('invalid credentials') ||
        (msg.contains('invalid') && msg.contains('credentials'))) {
      return 'authIncorrectPassword';
    }

    if (msg.contains('password') && msg.contains('weak')) {
      return 'authPasswordWeak';
    }

    // Email-related errors
    if (msg.contains('user already registered') ||
        msg.contains('user with this email already registered')) {
      return 'authEmailAlreadyRegistered';
    }

    if (msg.contains('invalid email')) {
      return 'authEmailInvalid';
    }

    // OTP/Code errors
    if (msg.contains('invalid otp') || msg.contains('invalid code')) {
      return 'authInvalidCode';
    }

    if (msg.contains('otp expired') || msg.contains('code expired')) {
      return 'authCodeExpired';
    }

    if (msg.contains('otp disabled') || msg.contains('mfa disabled')) {
      return 'authMFANotEnabled';
    }

    // Session/Token errors
    if (msg.contains('invalid jwt') ||
        msg.contains('jwt malformed') ||
        msg.contains('jwt signature does not match')) {
      return 'authSessionInvalid';
    }

    if (msg.contains('jwt expired') || msg.contains('token is expired')) {
      return 'authSessionExpired';
    }

    if (msg.contains('refresh_token_not_found') ||
        msg.contains('refresh token not found')) {
      return 'authRefreshTokenNotFound';
    }

    if (msg.contains('invalid refresh token') ||
        msg.contains('refresh_token_invalid')) {
      return 'authRefreshTokenInvalid';
    }

    if (msg.contains('refresh_token_already_used') ||
        msg.contains('refresh token has expired')) {
      return 'authRefreshTokenExpired';
    }

    if (msg.contains('unauthorized') && !msg.contains('oauth')) {
      return 'authUnauthorized';
    }

    // MFA/TOTP errors
    if (msg.contains('mfa') && msg.contains('required')) {
      return 'authMFARequired';
    }

    if (msg.contains('totp') && msg.contains('invalid')) {
      return 'authInvalidTOTP';
    }

    // OAuth errors
    if (msg.contains('oauth')) {
      if (msg.contains('invalid state')) {
        return 'authOAuthInvalidState';
      }
      if (msg.contains('access denied') || msg.contains('user denied')) {
        return 'authOAuthAccessDenied';
      }
      if (msg.contains('already exists')) {
        return 'authOAuthAccountExists';
      }
      return 'authOAuthFailed';
    }

    // Rate limiting
    if (msg.contains('rate limit') || msg.contains('too many requests')) {
      return 'authRateLimitExceeded';
    }

    // Server errors
    if (msg.contains('internal server error') ||
        msg.contains('500') ||
        msg.contains('503')) {
      return 'authServerError';
    }

    // User disabled/deleted
    if (msg.contains('user_not_found') ||
        msg.contains('user not found') ||
        msg.contains('user_disabled') ||
        msg.contains('user has been deleted')) {
      return 'authUserNotFound';
    }

    // Code verifier errors (from PKCE flow)
    if (msg.contains('code verifier')) {
      return 'authSessionInvalid';
    }

    return 'authUnexpectedError';
  }

  static String _mapPasswordResetException(PasswordResetException e) {
    final code = e.code.toLowerCase();
    final msg = e.message.toLowerCase();
    if (code.contains('otp_expired') || msg.contains('expired')) {
      return 'authCodeExpired';
    }
    if (code.contains('invalid_otp') ||
        code.contains('invalid') ||
        msg.contains('invalid')) {
      return 'authInvalidCode';
    }
    if (code.contains('rate_limited') || msg.contains('rate limit')) {
      return 'authRateLimitExceeded';
    }
    if (code.contains('user_not_found') || msg.contains('user not found')) {
      return 'authUserNotFound';
    }
    if (code.contains('invalid_email') || msg.contains('invalid email')) {
      return 'authEmailInvalid';
    }
    if (msg.contains('network') || msg.contains('socket')) {
      return _mapNetworkError(msg);
    }
    // Fall back to generic auth mapping using the message
    return _mapAuthException(AuthException(msg), isSignUp: false);
  }

  static String _mapSignupOtpException(SignupEmailOtpException e) {
    final code = e.code.toLowerCase();
    final msg = e.message.toLowerCase();
    if (code.contains('otp_expired') || msg.contains('expired')) {
      return 'authCodeExpired';
    }
    if (code.contains('invalid_otp') ||
        code.contains('invalid') ||
        msg.contains('invalid')) {
      return 'authInvalidCode';
    }
    if (code.contains('rate_limited') || msg.contains('rate limit')) {
      return 'authRateLimitExceeded';
    }
    return _mapAuthException(AuthException(msg), isSignUp: true);
  }

  static String _mapSensitiveActionReauthException(
    SensitiveActionReauthException e,
  ) {
    final code = e.code.toLowerCase();
    final msg = e.message.toLowerCase();
    if (code.contains('rate_limited') ||
        code == 'over_email_send_rate_limit' ||
        code == 'over_request_rate_limit' ||
        msg.contains('rate limit') ||
        msg.contains('too many requests')) {
      return 'authRateLimitExceeded';
    }
    if (code.contains('otp_expired') ||
        code.contains('expired') ||
        msg.contains('expired')) {
      return 'authCodeExpired';
    }
    if (code.contains('invalid_code') ||
        code.contains('invalid') ||
        msg.contains('invalid')) {
      return 'authInvalidCode';
    }
    if (code.contains('timeout') || msg.contains('timed out')) {
      return 'networkErrorTimeout';
    }
    if (code.contains('not_authenticated') || code.contains('missing_email')) {
      return 'authNotAuthenticated';
    }
    if (msg.contains('network') || msg.contains('socket')) {
      return _mapNetworkError(msg);
    }
    return _mapAuthException(AuthException(e.message), isSignUp: false);
  }

  static String _mapEmailChangeException(EmailChangeException e) {
    final code = e.code.toLowerCase();
    final msg = e.message.toLowerCase();
    if (code.contains('code_expired') ||
        code.contains('otp_expired') ||
        msg.contains('expired')) {
      return 'authCodeExpired';
    }
    if (code.contains('invalid_code') ||
        code.contains('code_already_used') ||
        code.contains('invalid') ||
        msg.contains('invalid') ||
        msg.contains('already been used')) {
      return 'authInvalidCode';
    }
    if (code.contains('rate_limited') || msg.contains('rate limit')) {
      return 'authRateLimitExceeded';
    }
    if (code.contains('timeout') || msg.contains('timed out')) {
      return 'networkErrorTimeout';
    }
    if (code.contains('offline') ||
        msg.contains('offline') ||
        msg.contains('network') ||
        msg.contains('socket')) {
      return _mapNetworkError(msg);
    }
    if (code.contains('not_authenticated')) return 'authNotAuthenticated';
    return _mapAuthException(AuthException(e.message), isSignUp: false);
  }

  /// Map passkey-related errors
  static String _mapPasskeyError(dynamic error) {
    final msg = error.toString().toLowerCase();

    if (msg.contains('not supported') || msg.contains('not available')) {
      return 'authPasskeyNotSupported';
    }

    if (msg.contains('passkey not found') || msg.contains('no account')) {
      return 'authPasskeyNotFound';
    }

    if (msg.contains('cancelled') || msg.contains('user_cancelled')) {
      return 'authPasskeyCancelled';
    }

    if (msg.contains('security') && msg.contains('error')) {
      return 'authPasskeySecurityError';
    }

    if (msg.contains('attestation') || msg.contains('assertion')) {
      return 'authPasskeySecurityError';
    }

    return 'authPasskeySignInFailed';
  }

  /// Get a user-friendly error message from an exception.
  /// This method combines error mapping with localization retrieval.
  ///
  /// Usage:
  /// ```dart
  /// try {
  ///   await supabase.auth.signInWithPassword(...);
  /// } catch (e) {
  ///   final errorKey = ErrorLocalizationService.getErrorTranslationKey(e);
  ///   final errorMessage = l10n.getString(errorKey);
  ///   showError(errorMessage);
  /// }
  /// ```
  static String mapErrorToTranslationKey(
    dynamic error, {
    bool isSignUp = false,
    String fallbackKey = 'authUnexpectedError',
  }) {
    try {
      return getErrorTranslationKey(error, isSignUp: isSignUp);
    } catch (e) {
      return fallbackKey;
    }
  }
}
