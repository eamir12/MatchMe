import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/utils/offline_utils.dart';
import 'package:matchme/utils/otp_utils.dart';

class EmailChangeException implements Exception {
  const EmailChangeException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class EmailChangeResult {
  const EmailChangeResult({
    required this.success,
    required this.message,
    this.expiresAt,
  });

  final bool success;
  final String message;
  final DateTime? expiresAt;
}

class EmailChangeService {
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const Duration _codeValidityWindow = Duration(minutes: 10);
  static const String _pendingEmailPrefsKey = 'email_change_pending_new_email';
  static const String _pendingExpiryPrefsKey =
      'email_change_pending_expires_at';

  static Future<void> _secureDeletePendingEmail() async {
    try {
      await SecureStorageService.instance.delete(_pendingEmailPrefsKey);
      await SecureStorageService.instance.delete(_pendingExpiryPrefsKey);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_pendingEmailPrefsKey)) {
        await prefs.remove(_pendingEmailPrefsKey);
        await prefs.remove(_pendingExpiryPrefsKey);
      }
    } catch (_) {}
  }

  /// Drop any pending email-change request. Called on logout so the pending
  /// new address never survives the session that requested it.
  static Future<void> clearPendingEmailChange() => _secureDeletePendingEmail();

  static Future<void> _securePersistPendingEmail(
    String email,
    DateTime? expiry,
  ) async {
    try {
      await SecureStorageService.instance.write(_pendingEmailPrefsKey, email);
      if (expiry != null) {
        await SecureStorageService.instance.write(
          _pendingExpiryPrefsKey,
          expiry.toIso8601String(),
        );
      }
    } catch (_) {}
    // Remove legacy plain copies.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_pendingEmailPrefsKey)) {
        await prefs.remove(_pendingEmailPrefsKey);
        await prefs.remove(_pendingExpiryPrefsKey);
      }
    } catch (_) {}
  }

  static DateTime? _activeEmailCodeExpiresAt;
  static String? _pendingNewEmail;
  static String? _verifiedCode;
  static String? _verifiedEmail;
  static DateTime? _verifiedAt;

  static DateTime? get activeEmailCodeExpiresAt {
    final expiresAt = _activeEmailCodeExpiresAt;
    if (expiresAt == null) return null;
    if (DateTime.now().isAfter(expiresAt)) {
      _activeEmailCodeExpiresAt = null;
      return null;
    }
    return expiresAt;
  }

  static Future<bool> isEmailAvailable(String email) async {
    if (shouldSkipSupabaseCalls()) return false;

    final supabase = Supabase.instance.client;
    final auth = supabase.auth;
    final currentUser = auth.currentUser;

    if (currentUser == null) {
      return false;
    }

    try {
      final response = await supabase
          .rpc(
            'check_email_availability',
            params: {
              'p_email': email.trim().toLowerCase(),
              'p_exclude_user_id': currentUser.id,
            },
          )
          .timeout(const Duration(seconds: 5));

      if (response == null || (response is List && response.isEmpty)) {
        return false;
      }

      final data = response is List ? response[0] : response;
      return data['available'] as bool? ?? false;
    } catch (error) {
      print('Error checking email availability');
      return false;
    }
  }

  static Future<EmailChangeResult> requestEmailChangeCode({
    required String newEmail,
    String? language,
  }) async {
    final supabase = Supabase.instance.client;
    final auth = supabase.auth;
    final currentUser = auth.currentUser;

    if (currentUser == null) {
      throw EmailChangeException(
        code: 'not_authenticated',
        message: 'A signed-in user is required.',
      );
    }

    final normalizedNewEmail = OtpUtils.normalizeEmail(newEmail);
    if (normalizedNewEmail.isEmpty) {
      throw EmailChangeException(
        code: 'invalid_email',
        message: 'Email address cannot be empty.',
      );
    }

    final currentEmail = OtpUtils.normalizeEmail(currentUser.email ?? '');
    if (currentEmail == normalizedNewEmail) {
      throw EmailChangeException(
        code: 'same_email',
        message: 'New email must be different from current email.',
      );
    }

    if (shouldSkipSupabaseCalls()) {
      throw EmailChangeException(
        code: 'offline',
        message: 'Cannot change email while offline',
      );
    }

    try {
      // Reuse the currently active (unexpired) code when one exists so that
      // tapping "Resend" does NOT invalidate the code the user just received.
      // Previously every request generated a brand-new code, so the first
      // email's correct code was rejected as invalid after a resend.
      final active = await _fetchActiveCode(
        supabase: supabase,
        userId: currentUser.id,
        email: normalizedNewEmail,
      );

      String code;
      String expiresAtStr;
      if (active != null) {
        code = active.code;
        expiresAtStr = active.expiresAtIso;
      } else {
        // Call the RPC function directly to generate the code for the new email
        final response = await supabase
            .rpc(
              'generate_sensitive_action_email_code',
              params: {
                'p_user_id': currentUser.id,
                'p_email': normalizedNewEmail,
              },
            )
            .timeout(_requestTimeout);

        if (response == null || (response is List && response.isEmpty)) {
          throw EmailChangeException(
            code: 'generation_failed',
            message: 'Failed to generate verification code',
          );
        }

        final data = response is List ? response[0] : response;
        final generatedCode = data is Map ? data['code'] as String? : null;
        final generatedExpiry = data is Map
            ? data['expires_at'] as String?
            : null;

        if (generatedCode == null || generatedExpiry == null) {
          throw EmailChangeException(
            code: 'generation_failed',
            message: 'Failed to generate verification code',
          );
        }
        code = generatedCode;
        expiresAtStr = generatedExpiry;
      }

      // Send the email with the code
      try {
        await supabase.functions
            .invoke(
              'sensitive-action-email-code',
              body: {
                'action': 'send_code_email',
                'email': normalizedNewEmail,
                'code': code,
                'language': language ?? 'en',
              },
            )
            .timeout(_requestTimeout);
      } catch (emailError) {
        // Log but don't fail - code was generated successfully
        print('Warning: Failed to send email');
      }

      _pendingNewEmail = normalizedNewEmail;
      _markEmailCodeWindow(serverExpiresAtIso: expiresAtStr);
      await _persistPendingState();

      return EmailChangeResult(
        success: true,
        message: 'Verification code sent to new email',
        expiresAt: activeEmailCodeExpiresAt,
      );
    } catch (error) {
      if (error is EmailChangeException) {
        rethrow;
      }
      throw EmailChangeException(
        code: 'generation_error',
        message: 'Failed to send verification code: $error',
      );
    }
  }

  static Future<EmailChangeResult> verifyEmailChangeCode({
    required String code,
    String? newEmail,
  }) async {
    final supabase = Supabase.instance.client;
    final auth = supabase.auth;
    final currentUser = auth.currentUser;

    if (currentUser == null) {
      throw EmailChangeException(
        code: 'not_authenticated',
        message: 'A signed-in user is required.',
      );
    }

    final sanitizedCode = OtpUtils.sanitizeCode(code);
    if (sanitizedCode.isEmpty) {
      throw EmailChangeException(
        code: 'invalid_code',
        message: 'Verification code cannot be empty.',
      );
    }

    final pendingEmail = await _resolvePendingEmail(newEmail);
    if (pendingEmail == null) {
      throw EmailChangeException(
        code: 'no_pending_email',
        message: 'No pending email change found.',
      );
    }

    try {
      // Verify server-side via the SECURITY DEFINER RPC. The codes are
      // stored encrypted (encrypted_code column) and direct table access is
      // revoked for authenticated users, so querying
      // `sensitive_action_email_codes` directly always fails with a correct
      // code ("Invalid or expired"). The RPC decrypts, checks expiry with
      // the server clock (avoiding device clock skew), and marks the code
      // as used atomically.
      final response = await supabase
          .rpc(
            'verify_sensitive_action_email_code',
            params: {
              'p_user_id': currentUser.id,
              'p_email': pendingEmail,
              'p_code': sanitizedCode,
            },
          )
          .timeout(_requestTimeout);

      final row = _firstRpcRow(response);
      final success = row != null && row['success'] == true;
      final serverMessage = row != null && row['message'] is String
          ? (row['message'] as String)
          : '';
      if (!success) {
        throw EmailChangeException(
          code: _mapVerifyFailureCode(serverMessage),
          message: serverMessage.isNotEmpty
              ? serverMessage
              : 'Invalid or expired verification code',
        );
      }

      _verifiedCode = sanitizedCode;
      _verifiedEmail = pendingEmail;
      _verifiedAt = DateTime.now();

      return EmailChangeResult(
        success: true,
        message: 'Code verified successfully',
      );
    } catch (error) {
      if (error is EmailChangeException) {
        rethrow;
      }
      throw EmailChangeException(
        code: 'verification_error',
        message: 'Failed to verify code: $error',
      );
    }
  }

  static Future<EmailChangeResult> completeEmailChange({
    required String code,
    String? newEmail,
  }) async {
    final supabase = Supabase.instance.client;
    final auth = supabase.auth;
    final currentUser = auth.currentUser;

    if (currentUser == null) {
      throw EmailChangeException(
        code: 'not_authenticated',
        message: 'A signed-in user is required.',
      );
    }

    final sanitizedCode = OtpUtils.sanitizeCode(code);
    if (sanitizedCode.isEmpty) {
      throw EmailChangeException(
        code: 'invalid_code',
        message: 'Verification code cannot be empty.',
      );
    }

    final pendingEmail = await _resolvePendingEmail(newEmail);
    if (pendingEmail == null) {
      throw EmailChangeException(
        code: 'no_pending_email',
        message: 'No pending email change found.',
      );
    }

    try {
      // The code must have been verified via [verifyEmailChangeCode] first.
      // The verify RPC marks the code as used, so re-verifying here would
      // reject the same correct code. Instead, require a fresh in-memory
      // verification; otherwise verify now (covers callers that skip the
      // explicit verify step).
      if (!_hasFreshVerification(email: pendingEmail, code: sanitizedCode)) {
        await verifyEmailChangeCode(
          code: sanitizedCode,
          newEmail: pendingEmail,
        );
      }

      final oldEmail = currentUser.email;

      // Update the user's email in Supabase Auth
      await auth.updateUser(UserAttributes(email: pendingEmail));

      // Send notification email to old email address
      try {
        await supabase.functions
            .invoke(
              'sensitive-action-email-code',
              body: {
                'action': 'send_email_changed_notification',
                'old_email': oldEmail,
                'new_email': pendingEmail,
                'language': 'en', // Will be determined by user's app language
              },
            )
            .timeout(_requestTimeout);
      } catch (emailError) {
        // Log but don't fail - email change was successful
        print('Warning: Failed to send notification email');
      }

      await clearEmailCodeWindow();

      return EmailChangeResult(
        success: true,
        message: 'Email changed successfully',
      );
    } on AuthException catch (error) {
      throw EmailChangeException(
        code: error.statusCode ?? 'auth_error',
        message: error.message,
        statusCode: int.tryParse(error.statusCode ?? ''),
      );
    } catch (error) {
      if (error is EmailChangeException) {
        rethrow;
      }
      throw EmailChangeException(
        code: 'completion_error',
        message: 'Failed to complete email change: $error',
      );
    }
  }

  static void _markEmailCodeWindow({String? serverExpiresAtIso}) {
    // Prefer the server-reported expiry so device clock skew cannot falsely
    // mark a just-received correct code as expired (or vice versa).
    final serverExpiry = serverExpiresAtIso == null
        ? null
        : DateTime.tryParse(serverExpiresAtIso);
    _activeEmailCodeExpiresAt =
        serverExpiry ?? DateTime.now().add(_codeValidityWindow);
  }

  static Future<void> clearEmailCodeWindow() async {
    _activeEmailCodeExpiresAt = null;
    _pendingNewEmail = null;
    _verifiedCode = null;
    _verifiedEmail = null;
    _verifiedAt = null;
    await _secureDeletePendingEmail();
  }

  static Future<void> _persistPendingState() async {
    try {
      final pending = _pendingNewEmail;
      if (pending == null || pending.isEmpty) {
        await _secureDeletePendingEmail();
        return;
      }
      await _securePersistPendingEmail(pending, _activeEmailCodeExpiresAt);
    } catch (_) {}
  }

  /// Resolves the pending new email, surviving app restarts. Previously this
  /// lived only in a static field, so a correct code entered after the app
  /// was backgrounded/killed was rejected with "No pending email change".
  static Future<String?> _resolvePendingEmail(String? explicit) async {
    final normalizedExplicit = explicit == null
        ? null
        : OtpUtils.normalizeEmail(explicit);
    if (normalizedExplicit != null && normalizedExplicit.isNotEmpty) {
      _pendingNewEmail = normalizedExplicit;
      await _persistPendingState();
      return normalizedExplicit;
    }
    if (_pendingNewEmail != null && _pendingNewEmail!.isNotEmpty) {
      return _pendingNewEmail;
    }
    try {
      String? stored;
      try {
        stored = await SecureStorageService.instance.read(
          _pendingEmailPrefsKey,
        );
      } catch (_) {}
      // Legacy plain prefs fallback.
      if (stored == null || stored.isEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          stored = prefs.getString(_pendingEmailPrefsKey);
        } catch (_) {}
      }
      stored = stored?.trim();
      if (stored != null && stored.isNotEmpty) {
        _pendingNewEmail = OtpUtils.normalizeEmail(stored);
        String? expiryIso;
        try {
          expiryIso = await SecureStorageService.instance.read(
            _pendingExpiryPrefsKey,
          );
        } catch (_) {}
        if (expiryIso == null || expiryIso.isEmpty) {
          try {
            final prefs = await SharedPreferences.getInstance();
            expiryIso = prefs.getString(_pendingExpiryPrefsKey);
          } catch (_) {}
        }
        final expiry = expiryIso == null ? null : DateTime.tryParse(expiryIso);
        if (expiry != null) _activeEmailCodeExpiresAt = expiry;
        return _pendingNewEmail;
      }
    } catch (_) {}
    return null;
  }

  static bool _hasFreshVerification({
    required String email,
    required String code,
  }) {
    if (_verifiedEmail != email || _verifiedCode != code) return false;
    final at = _verifiedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= _codeValidityWindow;
  }

  static Map<String, dynamic>? _firstRpcRow(dynamic response) {
    if (response == null) return null;
    if (response is List) {
      if (response.isEmpty) return null;
      final first = response.first;
      return first is Map ? Map<String, dynamic>.from(first) : null;
    }
    if (response is Map) return Map<String, dynamic>.from(response);
    return null;
  }

  static String _mapVerifyFailureCode(String serverMessage) {
    final lower = serverMessage.toLowerCase();
    if (lower.contains('expired')) return 'code_expired';
    if (lower.contains('already used')) return 'code_already_used';
    return 'invalid_code';
  }

  static Future<_ActiveEmailCode?> _fetchActiveCode({
    required SupabaseClient supabase,
    required String userId,
    required String email,
  }) async {
    try {
      final response = await supabase
          .rpc(
            'get_active_sensitive_action_email_code',
            params: {'p_user_id': userId, 'p_email': email},
          )
          .timeout(_requestTimeout);
      final row = _firstRpcRow(response);
      if (row == null) return null;
      final code = row['code'] as String?;
      final expiresAt = row['expires_at'] as String?;
      if (code == null || code.isEmpty || expiresAt == null) return null;
      final expiry = DateTime.tryParse(expiresAt);
      if (expiry == null) return null;
      // Only reuse codes that are still valid server-side.
      if (!expiry.isAfter(DateTime.now().toUtc()) &&
          !expiry.isAfter(DateTime.now())) {
        return null;
      }
      return _ActiveEmailCode(code: code, expiresAtIso: expiresAt);
    } catch (_) {
      // RPC may not be granted on older backends – fall back to generating.
      return null;
    }
  }
}

class _ActiveEmailCode {
  const _ActiveEmailCode({required this.code, required this.expiresAtIso});

  final String code;
  final String expiresAtIso;
}
