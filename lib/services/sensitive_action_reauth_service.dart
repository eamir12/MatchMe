// ignore_for_file: unused_element
import 'dart:async';

import 'package:matchme/utils/otp_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SensitiveActionReauthException implements Exception {
  const SensitiveActionReauthException({
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

class SensitiveActionEmailCodeRequestResult {
  const SensitiveActionEmailCodeRequestResult({
    required this.expiresAt,
    required this.sentFreshly,
  });

  final DateTime expiresAt;
  final bool sentFreshly;
}

class SensitiveActionReauthService {
  static const Duration _requestTimeout = Duration(seconds: 10);
  static const Duration _codeEntryWindow = Duration(minutes: 10);

  /// Minimum time between two explicit **Resend** taps.
  ///
  /// Every fresh send invalidates previously sent codes, so entering the
  /// code from an older email always fails – even when that code was just
  /// received. The cooldown stops impatient taps from orphaning the code
  /// sitting in the user's inbox. (Explicit resends reuse the still-valid
  /// code server-side whenever possible.)
  static const Duration resendCooldown = Duration(seconds: 60);

  static DateTime? _activeEmailCodeExpiresAt;
  static DateTime? _lastEmailCodeSentAt;

  /// Identifies which account the outstanding-code window belongs to
  /// (`"<userId>|<email>"`). The auto-send skip must only apply to the same
  /// account – after an account switch a stale window must never suppress a
  /// fresh send (the outstanding code would belong to the previous user).
  static String? _windowOwnerKey;

  /// When the most recent reauthentication email was successfully requested,
  /// or null if none was sent (yet). App-scoped (static) so reopening the
  /// verification dialog does not trigger a second send that would
  /// invalidate the outstanding code.
  static DateTime? get lastEmailCodeSentAt => _lastEmailCodeSentAt;

  static DateTime? get activeEmailCodeExpiresAt {
    final expiresAt = _activeEmailCodeExpiresAt;
    if (expiresAt == null) return null;
    if (DateTime.now().isAfter(expiresAt)) {
      _activeEmailCodeExpiresAt = null;
      return null;
    }
    return expiresAt;
  }

  static Future<SensitiveActionEmailCodeRequestResult> requestEmailCode({
    bool forceResend = false,
    String? language,
  }) async {
    // Codes go through the `sensitive-action-email-code` edge function (see
    // [sendEmailCode] for why native `reauthenticate()` is not used).
    await sendEmailCode(language: language, forceResend: forceResend);
    // sendEmailCode() already recorded the send window (with owner); just
    // read back the expiry it established.
    final expiresAt = activeEmailCodeExpiresAt ?? _markEmailCodeWindow();
    return SensitiveActionEmailCodeRequestResult(
      expiresAt: expiresAt,
      sentFreshly: true,
    );
  }

  /// Whether an outstanding (recently sent, same-account) email code exists,
  /// so callers can skip a redundant send that would invalidate the code
  /// sitting in the user's inbox.
  static bool hasOutstandingCodeFor({String? userId, String? email}) {
    if (activeEmailCodeExpiresAt == null) return false;
    if (userId == null && email == null) return true;
    final owner = _windowOwnerKey;
    if (owner == null) return true;
    final normalizedEmail = email?.trim().toLowerCase();
    final userMatch =
        userId != null && userId.isNotEmpty && owner.startsWith('$userId|');
    final emailMatch =
        normalizedEmail != null &&
        normalizedEmail.isNotEmpty &&
        owner.endsWith('|$normalizedEmail');
    return userMatch || emailMatch;
  }

  /// Sends the sensitive-action email code via the
  /// `sensitive-action-email-code` edge function (custom 6-digit code stored
  /// in `sensitive_action_email_codes`, verified by the
  /// `verify_sensitive_action_email_code` RPC).
  ///
  /// WHY NOT Supabase native `reauthenticate()`: GoTrue has no standalone
  /// endpoint that verifies a reauthentication nonce. `POST /verify` with
  /// `type: 'reauthentication'` unconditionally returns
  /// `403 "Token has expired or is invalid"` (verify.go has no such type, so
  /// the token is never compared), and `PUT /user` with only `nonce`
  /// succeeds without checking anything. Native reauth codes could be
  /// delivered but never verified – every correct code was rejected.
  static Future<void> sendEmailCode({
    String? language,
    bool forceResend = false,
  }) async {
    final auth = Supabase.instance.client.auth;

    final currentUser = auth.currentUser;
    if (currentUser == null) {
      throw const SensitiveActionReauthException(
        code: 'not_authenticated',
        message: 'A signed-in user is required to send email code.',
      );
    }

    final email = OtpUtils.normalizeEmail(currentUser.email ?? '');
    if (email.isEmpty) {
      throw const SensitiveActionReauthException(
        code: 'missing_email',
        message: 'The current user does not have a confirmed email address.',
      );
    }

    final normalizedLanguage = (language ?? 'en').trim().isEmpty
        ? 'en'
        : language!.trim();
    // Explicit Resend reuses the still-valid code when one exists (the edge
    // `resend` action only mints a new code when the old one is stale), so
    // the code already in the inbox keeps working. First sends generate.
    final action = forceResend ? 'resend' : 'generate';
    final result = await _invokeEmailCodeFn(
      action: action,
      body: {'action': action, 'email': email, 'language': normalizedLanguage},
      timeoutMessage: 'Email code request timed out.',
    );
    _markEmailCodeWindow(
      serverExpiresAtIso: result['expiresAt'] as String?,
      ownerKey: _ownerKey(currentUser.id, email),
    );
  }

  /// Verifies the 6-digit email code sent by [sendEmailCode] via the
  /// `sensitive-action-email-code` edge function (`verify` action →
  /// `verify_sensitive_action_email_code` RPC, SECURITY DEFINER: decrypts the
  /// stored code, checks expiry with the server clock, single-use).
  ///
  /// Deliberately NOT GoTrue `POST /verify` with `type: 'reauthentication'`:
  /// the server has no such verify case and answers every attempt – right or
  /// wrong code – with `403 "Token has expired or is invalid"`. Likewise
  /// `updateUser(data: <unchanged>, nonce: <code>)` is not a verifier:
  /// GoTrue only checks `nonce` when a password change requires it, so a
  /// metadata-only update accepts ANY code. Never verify either way.
  static Future<void> verifyEmailCode({
    required String email,
    required String token,
  }) async {
    final normalizedEmail = OtpUtils.normalizeEmail(email);
    final normalizedToken = OtpUtils.sanitizeCode(token);
    if (normalizedEmail.isEmpty || normalizedToken.isEmpty) {
      throw const SensitiveActionReauthException(
        code: 'invalid_request',
        message: 'Email reauthentication requires both email and token.',
      );
    }

    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      throw const SensitiveActionReauthException(
        code: 'not_authenticated',
        message: 'A signed-in user is required for email reauthentication.',
      );
    }

    final currentEmail = OtpUtils.normalizeEmail(currentUser.email ?? '');
    if (currentEmail.isEmpty) {
      throw const SensitiveActionReauthException(
        code: 'missing_email',
        message: 'The current user does not have a confirmed email address.',
      );
    }
    if (currentEmail != normalizedEmail) {
      throw const SensitiveActionReauthException(
        code: 'email_mismatch',
        message:
            'The provided reauthentication email does not match the current user.',
      );
    }

    await _invokeEmailCodeFn(
      action: 'verify',
      body: {
        'action': 'verify',
        'email': normalizedEmail,
        'code': normalizedToken,
      },
      timeoutMessage: 'Reauthentication request timed out.',
    );

    clearEmailCodeWindow();
  }

  /// Invokes the `sensitive-action-email-code` edge function and returns its
  /// result map. A `{success: false}` response (wrong/expired code, send
  /// failure, …) becomes a typed [SensitiveActionReauthException] – never a
  /// silent success. Transport failures (401 etc.) get one retry after a
  /// best-effort session refresh.
  ///
  /// NOTE: functions_client throws [FunctionException] for non-2xx edge
  /// responses (e.g. the edge `400 {success:false,message:"Invalid code"}`),
  /// so both the return path and the throw path are normalized into
  /// [_EdgeOutcome] below.
  static Future<Map<String, dynamic>> _invokeEmailCodeFn({
    required String action,
    required Map<String, dynamic> body,
    required String timeoutMessage,
  }) async {
    final supabase = Supabase.instance.client;
    try {
      var outcome = await _callEdgeFn(supabase, body);
      if (outcome.result['success'] == true) return outcome.result;
      if (_looksUnauthorized(outcome.status, outcome.result) &&
          await _refreshSessionBestEffort()) {
        outcome = await _callEdgeFn(supabase, body);
        if (outcome.result['success'] == true) return outcome.result;
      }
      throw _edgeRejection(
        action: action,
        status: outcome.status,
        result: outcome.result,
      );
    } on SensitiveActionReauthException {
      rethrow;
    } on TimeoutException {
      throw SensitiveActionReauthException(
        code: 'timeout',
        message: timeoutMessage,
      );
    } catch (error) {
      throw SensitiveActionReauthException(
        code: action == 'verify' ? 'verification_failed' : 'send_failed',
        message: error.toString(),
      );
    }
  }

  static Future<_EdgeOutcome> _callEdgeFn(
    SupabaseClient supabase,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await supabase.functions
          .invoke('sensitive-action-email-code', body: body)
          .timeout(_requestTimeout);
      return _EdgeOutcome(
        status: response.status,
        result: _edgeResultData(response.data),
      );
    } on FunctionException catch (error) {
      final details = error.details;
      final Map<String, dynamic> result;
      if (details is Map<String, dynamic>) {
        result = details;
      } else if (details is Map) {
        result = Map<String, dynamic>.from(details);
      } else {
        result = <String, dynamic>{
          if (error.reasonPhrase?.trim().isNotEmpty == true)
            'message': error.reasonPhrase!.trim()
          else
            'message': error.toString(),
        };
      }
      return _EdgeOutcome(status: error.status, result: result);
    }
  }

  static Map<String, dynamic> _edgeResultData(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  static bool _looksUnauthorized(int? status, Map<String, dynamic> result) {
    if (status == 401 || status == 403) {
      final message = (result['message'] as String?)?.toLowerCase() ?? '';
      if (message.contains('unauthor')) return true;
      // A bare 401/403 with no usable body: treat as auth failure so the
      // caller retries once with a refreshed session before giving up.
      if (status == 401) return true;
    }
    return false;
  }

  /// Maps an edge `{success: false}` response to a stable error code.
  /// Wrong/expired codes surface as `invalid_code`/`otp_expired` so callers
  /// show the "code incorrect/expired" message; infrastructure failures keep
  /// their own codes and must never look like a mistyped code.
  static SensitiveActionReauthException _edgeRejection({
    required String action,
    required int? status,
    required Map<String, dynamic> result,
  }) {
    final rawMessage = result['message'];
    final message = rawMessage is String && rawMessage.trim().isNotEmpty
        ? rawMessage.trim()
        : (action == 'verify'
              ? 'Invalid or expired verification code.'
              : 'Failed to send verification email.');
    // No HTTP response at all (status 0) or a 5xx/relay failure is an
    // infrastructure problem – it must never look like a mistyped code.
    if (status == 0 || (status != null && status >= 500)) {
      return SensitiveActionReauthException(
        code: action == 'verify' ? 'verification_failed' : 'send_failed',
        message: message,
        statusCode: status,
      );
    }
    final lower = message.toLowerCase();
    if (lower.contains('unauthor')) {
      return SensitiveActionReauthException(
        code: 'not_authenticated',
        message: message,
        statusCode: status,
      );
    }
    if (lower.contains('rate limit') ||
        lower.contains('too many requests') ||
        lower.contains('over_email_send_rate_limit') ||
        lower.contains('over_request_rate_limit')) {
      return SensitiveActionReauthException(
        code: 'rate_limited',
        message: message,
        statusCode: status,
      );
    }
    if (action == 'verify') {
      if (lower.contains('expired')) {
        return SensitiveActionReauthException(
          code: 'otp_expired',
          message: message,
          statusCode: status,
        );
      }
      if (lower.contains('internal') ||
          lower.contains('failed to verify') ||
          lower.contains('database')) {
        return SensitiveActionReauthException(
          code: 'verification_failed',
          message: message,
          statusCode: status,
        );
      }
      return SensitiveActionReauthException(
        code: 'invalid_code',
        message: message,
        statusCode: status,
      );
    }
    return SensitiveActionReauthException(
      code: 'send_failed',
      message: message,
      statusCode: status,
    );
  }

  /// Best-effort session refresh before giving up on an auth failure.
  /// Returns true when a refresh token existed and the refresh succeeded.
  static Future<bool> _refreshSessionBestEffort() async {
    try {
      final auth = Supabase.instance.client.auth;
      final refreshToken = auth.currentSession?.refreshToken?.trim();
      if (refreshToken == null || refreshToken.isEmpty) return false;
      await auth.refreshSession().timeout(_requestTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void clearEmailCodeWindow() {
    _activeEmailCodeExpiresAt = null;
  }

  /// Clears all email-code send state (used on sign-out so a new user never
  /// reuses the previous account's "outstanding code" signal).
  static void clearAllEmailCodeState() {
    _activeEmailCodeExpiresAt = null;
    _lastEmailCodeSentAt = null;
    _windowOwnerKey = null;
  }

  static String _ownerKey(String userId, String email) =>
      '${userId.trim()}|${email.trim().toLowerCase()}';

  static DateTime _markEmailCodeWindow({
    String? ownerKey,
    String? serverExpiresAtIso,
  }) {
    final now = DateTime.now();
    // Prefer the server-reported expiry so device clock skew cannot falsely
    // mark a just-received correct code as expired (or vice versa).
    final serverExpiry = serverExpiresAtIso == null
        ? null
        : DateTime.tryParse(serverExpiresAtIso);
    final expiresAt = serverExpiry ?? now.add(_codeEntryWindow);
    _activeEmailCodeExpiresAt = expiresAt;
    _lastEmailCodeSentAt = now;
    if (ownerKey != null && ownerKey.isNotEmpty) {
      _windowOwnerKey = ownerKey;
    }
    return expiresAt;
  }
}

/// Normalized outcome of one edge-function call: functions_client returns
/// [FunctionResponse] on 2xx but throws [FunctionException] on non-2xx, so
/// both shapes are folded into status + result map.
class _EdgeOutcome {
  const _EdgeOutcome({required this.status, required this.result});

  final int? status;
  final Map<String, dynamic> result;
}
