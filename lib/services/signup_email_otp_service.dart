import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/utils/otp_utils.dart';

class SignupEmailOtpException implements Exception {
  const SignupEmailOtpException({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => message;
}

class SignupEmailOtpService {
  static Future<void> verifySignupCode({
    required String email,
    required String code,
  }) async {
    final normalizedEmail = OtpUtils.normalizeEmail(email);
    final normalizedCode = OtpUtils.sanitizeCode(code);

    if (normalizedEmail.isEmpty || normalizedCode.isEmpty) {
      throw const SignupEmailOtpException(
        code: 'invalid_request',
        message: 'Email and verification code are required.',
      );
    }

    try {
      await Supabase.instance.client.auth.verifyOTP(
        email: normalizedEmail,
        token: normalizedCode,
        type: OtpType.signup,
      );
    } on AuthException catch (error) {
      throw SignupEmailOtpException(
        code: _mapAuthErrorCode(error),
        message: error.message,
      );
    } catch (error) {
      throw SignupEmailOtpException(
        code: 'verification_failed',
        message: 'Failed to verify sign-up code: $error',
      );
    }
  }

  static Future<void> resendSignupCode({required String email}) async {
    final normalizedEmail = OtpUtils.normalizeEmail(email);
    if (normalizedEmail.isEmpty) {
      throw const SignupEmailOtpException(
        code: 'invalid_request',
        message: 'Email is required.',
      );
    }

    try {
      await Supabase.instance.client.auth.resend(
        email: normalizedEmail,
        type: OtpType.signup,
      );
    } on AuthException catch (error) {
      throw SignupEmailOtpException(
        code: _mapAuthErrorCode(error),
        message: error.message,
      );
    } catch (error) {
      throw SignupEmailOtpException(
        code: 'resend_failed',
        message: 'Failed to resend sign-up code: $error',
      );
    }
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
    return 'auth_error';
  }
}
