import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/otp_utils.dart';

class PasswordResetException implements Exception {
  const PasswordResetException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => message;
}

class PasswordResetService {
  /// Sends a password-reset OTP using Supabase's built-in **Reset password**
  /// email template (Dashboard -> Authentication -> Emails -> Reset password).
  ///
  /// No edge function / Resend is required. Just configure that template to
  /// use `{{ .Token }}` (6-digit OTP) instead of `{{ .ConfirmationURL }}` (link),
  /// as shown in your screenshot. Example body:
  ///   `<h2>Reset your password</h2><p>Your code: {{ .Token }}</p><p>Expires in 10 minutes.</p>`
  ///
  /// The edge function `password-reset-otp` is kept as an optional fallback
  /// (requires RESEND_API_KEY) but is NOT used by default.
  static Future<void> requestPasswordResetOtp({
    required String email,
    String? language,
  }) async {
    final normalizedEmail = OtpUtils.normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      throw const PasswordResetException(
        code: 'invalid_request',
        message: 'Email is required.',
      );
    }

    try {
      // Built-in Supabase OTP – uses the Reset password template from the
      // Dashboard. Works on FREE tier; no custom SMTP / edge function needed.
      // If you also want localized emails, add `data: { language }` to the
      // template via `{{ .Data.language }}`.
      await Supabase.instance.client.auth.resetPasswordForEmail(
        normalizedEmail,
      );
    } on AuthException catch (error) {
      throw PasswordResetException(
        code: _mapAuthErrorCode(error),
        message: error.message,
      );
    } catch (error) {
      throw PasswordResetException(
        code: 'request_failed',
        message: 'Failed to send password reset code: $error',
      );
    }
  }

  /// Stage 1: Verify the 6-digit recovery OTP. Establishes a recovery session.
  /// Must be called before [updatePassword]. Throws [PasswordResetException] on failure.
  static Future<void> verifyRecoveryOtp({
    required String email,
    required String code,
  }) async {
    final normalizedEmail = OtpUtils.normalizeEmail(email);
    final normalizedCode = OtpUtils.sanitizeCode(code);
    if (normalizedEmail.isEmpty || normalizedCode.isEmpty) {
      throw const PasswordResetException(
        code: 'invalid_request',
        message: 'Email and verification code are required.',
      );
    }
    try {
      await Supabase.instance.client.auth.verifyOTP(
        email: normalizedEmail,
        token: normalizedCode,
        type: OtpType.recovery,
      );
    } on AuthException catch (error) {
      throw PasswordResetException(
        code: _mapAuthErrorCode(error),
        message: error.message,
      );
    } catch (error) {
      throw PasswordResetException(
        code: 'verification_failed',
        message: 'Failed to verify code: $error',
      );
    }
  }

  /// Stage 2: Update password using the recovery session established by [verifyRecoveryOtp].
  static Future<void> updatePassword({required String newPassword}) async {
    final trimmedPassword = newPassword.trim();
    if (trimmedPassword.isEmpty) {
      throw const PasswordResetException(
        code: 'invalid_request',
        message: 'New password is required.',
      );
    }
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: trimmedPassword),
      );
    } on AuthException catch (error) {
      throw PasswordResetException(
        code: _mapAuthErrorCode(error),
        message: error.message,
      );
    } catch (error) {
      throw PasswordResetException(
        code: 'update_failed',
        message: 'Failed to update password: $error',
      );
    }
    // POLICY: do NOT auto-sign-out after a password update. The recovery
    // OTP already proved ownership, so the resulting session is valid and
    // the user stays logged in. Only auth.forced_sign_out_days or an
    // explicit UI logout may sign out.
  }

  /// Verifies the OTP and updates the user's password (combined for backwards compat).
  static Future<void> verifyOtpAndUpdatePassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await verifyRecoveryOtp(email: email, code: code);
    await updatePassword(newPassword: newPassword);
  }

  /// Resends the password-reset OTP (simply calls request again).
  static Future<void> resendPasswordResetOtp({
    required String email,
    String? language,
  }) async {
    return requestPasswordResetOtp(email: email, language: language);
  }

  static String _mapAuthErrorCode(AuthException error) {
    final rawCode = error.code?.trim().toLowerCase();
    if (rawCode != null && rawCode.isNotEmpty) {
      return rawCode;
    }
    final lower = error.message.toLowerCase();
    if (lower.contains('expired')) return 'otp_expired';
    if (lower.contains('invalid')) return 'invalid_otp';
    if (lower.contains('rate limit')) return 'rate_limited';
    if (lower.contains('not found') || lower.contains('no user')) {
      return 'user_not_found';
    }
    return 'auth_error';
  }
}
