import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:matchme/services/app_config_service.dart';
import 'package:matchme/services/secure_storage_service.dart';
import 'package:matchme/services/passkey_client_service.dart';
import 'package:matchme/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void _log(String message) {
  print(message);
}

class PasskeyAuthException implements Exception {
  const PasskeyAuthException({
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

class PasskeyAuthenticationEndpoints {
  const PasskeyAuthenticationEndpoints({
    required this.startAuthentication,
    required this.finishAuthentication,
  });

  final Uri startAuthentication;
  final Uri finishAuthentication;
}

class PasskeyAvailabilityState {
  const PasskeyAvailabilityState({
    required this.isEnabled,
    required this.isPlatformSupported,
    required this.isRuntimeConfigured,
  });

  final bool isEnabled;
  final bool isPlatformSupported;
  final bool isRuntimeConfigured;

  bool get canUse => isEnabled && isPlatformSupported && isRuntimeConfigured;
}

const String _prefsKnownPasskeyEmailsKey = 'passkey_known_enabled_emails';
const int _maxKnownPasskeyEmails = 100;
Set<String>? _knownPasskeyEmailsCache;

class PasskeyStartAuthenticationResult {
  const PasskeyStartAuthenticationResult({
    required this.rawResponse,
    this.publicKeyOptions,
    this.requestId,
  });

  final Map<String, dynamic> rawResponse;
  final Map<String, dynamic>? publicKeyOptions;
  final String? requestId;

  bool get hasPublicKeyOptions =>
      publicKeyOptions != null &&
      publicKeyOptions!.isNotEmpty &&
      hasRegisteredCredentials;

  bool get hasRegisteredCredentials {
    final options = publicKeyOptions;
    if (options == null || options.isEmpty) {
      return false;
    }

    final allowCredentials =
        options['allowCredentials'] ?? options['allow_credentials'];
    if (allowCredentials is List) {
      return allowCredentials.isNotEmpty;
    }

    return false;
  }

  factory PasskeyStartAuthenticationResult.fromResponse(
    Map<String, dynamic> response,
  ) {
    final extractedPublicKeyOptions = PasskeyAuthService._extractNestedMap(
      response,
      const [
        ['publicKey'],
        ['public_key'],
        ['publicKeyCredentialRequestOptions'],
        ['public_key_credential_request_options'],
        ['options', 'publicKey'],
        ['options', 'public_key'],
        ['data', 'publicKey'],
        ['data', 'public_key'],
        ['data', 'options', 'publicKey'],
        ['data', 'options', 'public_key'],
      ],
    );
    final publicKeyOptions =
        extractedPublicKeyOptions ??
        (PasskeyAuthService._looksLikePublicKeyRequestOptions(response)
            ? response
            : null);
    final requestId = PasskeyAuthService._extractNestedString(response, const [
      ['requestId'],
      ['request_id'],
      ['data', 'requestId'],
      ['data', 'request_id'],
      ['options', 'requestId'],
      ['options', 'request_id'],
    ]);

    return PasskeyStartAuthenticationResult(
      rawResponse: response,
      publicKeyOptions: publicKeyOptions,
      requestId: requestId,
    );
  }
}

class PasskeyFinishAuthenticationResult {
  const PasskeyFinishAuthenticationResult({
    required this.rawResponse,
    this.sessionPayload,
    this.refreshToken,
  });

  final Map<String, dynamic> rawResponse;
  final Map<String, dynamic>? sessionPayload;
  final String? refreshToken;

  bool get hasSupabaseSessionPayload =>
      sessionPayload != null && sessionPayload!.isNotEmpty;

  bool get hasRefreshToken =>
      refreshToken != null && refreshToken!.trim().isNotEmpty;

  bool get canApplySupabaseSession =>
      hasSupabaseSessionPayload || hasRefreshToken;

  factory PasskeyFinishAuthenticationResult.fromResponse(
    Map<String, dynamic> response,
  ) {
    final extractedSessionPayload = PasskeyAuthService._extractNestedMap(
      response,
      const [
        ['session'],
        ['auth', 'session'],
        ['data', 'session'],
        ['result', 'session'],
        ['auth'],
        ['data', 'auth'],
        ['result', 'auth'],
      ],
    );
    final sessionPayload =
        PasskeyAuthService._normalizeSupabaseSessionPayload(
          extractedSessionPayload,
        ) ??
        (PasskeyAuthService._looksLikeSupabaseSessionPayload(response)
            ? PasskeyAuthService._normalizeSupabaseSessionPayload(response)
            : null);
    final extractedRefreshToken = PasskeyAuthService._extractNestedString(
      response,
      const [
        ['refresh_token'],
        ['refreshToken'],
        ['session', 'refresh_token'],
        ['session', 'refreshToken'],
        ['auth', 'refresh_token'],
        ['auth', 'refreshToken'],
        ['auth', 'session', 'refresh_token'],
        ['auth', 'session', 'refreshToken'],
        ['data', 'refresh_token'],
        ['data', 'refreshToken'],
        ['data', 'auth', 'refresh_token'],
        ['data', 'auth', 'refreshToken'],
        ['data', 'session', 'refresh_token'],
        ['data', 'session', 'refreshToken'],
        ['result', 'refresh_token'],
        ['result', 'refreshToken'],
        ['result', 'auth', 'refresh_token'],
        ['result', 'auth', 'refreshToken'],
      ],
    );
    final refreshToken =
        extractedRefreshToken ??
        PasskeyAuthService._extractNormalizedString(sessionPayload, const [
          'refresh_token',
          'refreshToken',
        ]);

    return PasskeyFinishAuthenticationResult(
      rawResponse: response,
      sessionPayload: sessionPayload,
      refreshToken: refreshToken,
    );
  }
}

class PasskeyRegistrationEndpoints {
  const PasskeyRegistrationEndpoints({
    required this.startRegistration,
    required this.finishRegistration,
  });

  final Uri startRegistration;
  final Uri finishRegistration;
}

class PasskeyStartRegistrationResult {
  const PasskeyStartRegistrationResult({
    required this.rawResponse,
    this.publicKeyOptions,
    this.requestId,
  });

  final Map<String, dynamic> rawResponse;
  final Map<String, dynamic>? publicKeyOptions;
  final String? requestId;

  bool get hasPublicKeyOptions =>
      publicKeyOptions != null && publicKeyOptions!.isNotEmpty;

  factory PasskeyStartRegistrationResult.fromResponse(
    Map<String, dynamic> response,
  ) {
    final extractedPublicKeyOptions = PasskeyAuthService._extractNestedMap(
      response,
      const [
        ['publicKey'],
        ['public_key'],
        ['publicKeyCredentialCreationOptions'],
        ['public_key_credential_creation_options'],
        ['options', 'publicKey'],
        ['options', 'public_key'],
        ['data', 'publicKey'],
        ['data', 'public_key'],
        ['data', 'options', 'publicKey'],
        ['data', 'options', 'public_key'],
      ],
    );
    final publicKeyOptions =
        extractedPublicKeyOptions ??
        (PasskeyAuthService._looksLikePublicKeyCreationOptions(response)
            ? response
            : null);
    final requestId = PasskeyAuthService._extractNestedString(response, const [
      ['requestId'],
      ['request_id'],
      ['data', 'requestId'],
      ['data', 'request_id'],
      ['options', 'requestId'],
      ['options', 'request_id'],
    ]);

    return PasskeyStartRegistrationResult(
      rawResponse: response,
      publicKeyOptions: publicKeyOptions,
      requestId: requestId,
    );
  }
}

class PasskeyFinishRegistrationResult {
  const PasskeyFinishRegistrationResult({
    required this.rawResponse,
    this.sessionPayload,
    this.refreshToken,
    this.credentialId,
  });

  final Map<String, dynamic> rawResponse;
  final Map<String, dynamic>? sessionPayload;
  final String? refreshToken;
  final String? credentialId;

  bool get hasSupabaseSessionPayload =>
      sessionPayload != null && sessionPayload!.isNotEmpty;

  bool get hasRefreshToken =>
      refreshToken != null && refreshToken!.trim().isNotEmpty;

  bool get canApplySupabaseSession =>
      hasSupabaseSessionPayload || hasRefreshToken;

  factory PasskeyFinishRegistrationResult.fromResponse(
    Map<String, dynamic> response,
  ) {
    final extractedSessionPayload = PasskeyAuthService._extractNestedMap(
      response,
      const [
        ['session'],
        ['auth', 'session'],
        ['data', 'session'],
        ['result', 'session'],
        ['auth'],
        ['data', 'auth'],
        ['result', 'auth'],
      ],
    );
    final sessionPayload =
        PasskeyAuthService._normalizeSupabaseSessionPayload(
          extractedSessionPayload,
        ) ??
        (PasskeyAuthService._looksLikeSupabaseSessionPayload(response)
            ? PasskeyAuthService._normalizeSupabaseSessionPayload(response)
            : null);
    final extractedRefreshToken = PasskeyAuthService._extractNestedString(
      response,
      const [
        ['refresh_token'],
        ['refreshToken'],
        ['session', 'refresh_token'],
        ['session', 'refreshToken'],
        ['auth', 'refresh_token'],
        ['auth', 'refreshToken'],
        ['auth', 'session', 'refresh_token'],
        ['auth', 'session', 'refreshToken'],
        ['data', 'refresh_token'],
        ['data', 'refreshToken'],
        ['data', 'auth', 'refresh_token'],
        ['data', 'auth', 'refreshToken'],
        ['data', 'session', 'refresh_token'],
        ['data', 'session', 'refreshToken'],
        ['result', 'refresh_token'],
        ['result', 'refreshToken'],
        ['result', 'auth', 'refresh_token'],
        ['result', 'auth', 'refreshToken'],
      ],
    );
    final refreshToken =
        extractedRefreshToken ??
        PasskeyAuthService._extractNormalizedString(sessionPayload, const [
          'refresh_token',
          'refreshToken',
        ]);
    final credentialId = PasskeyAuthService._extractNestedString(
      response,
      const [
        ['credential_id'],
        ['credentialId'],
        ['passkey_id'],
        ['passkeyId'],
        ['credential', 'id'],
        ['data', 'credential_id'],
        ['data', 'credentialId'],
        ['data', 'credential', 'id'],
        ['result', 'credential_id'],
        ['result', 'credentialId'],
        ['result', 'credential', 'id'],
      ],
    );

    return PasskeyFinishRegistrationResult(
      rawResponse: response,
      sessionPayload: sessionPayload,
      refreshToken: refreshToken,
      credentialId: credentialId,
    );
  }
}

class PasskeyAuthService {
  static Future<List<String>> _readPasskeyEmailsFromSecureStore() async {
    try {
      final encoded = await SecureStorageService.instance.read(
        _prefsKnownPasskeyEmailsKey,
      );
      if (encoded != null && encoded.isNotEmpty) {
        final decoded = jsonDecode(encoded);
        if (decoded is List) {
          return decoded
              .whereType<String>()
              .map(_normalizeEmailForCache)
              .where((v) => v.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}
    // Legacy plain SharedPreferences fallback.
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored =
          prefs.getStringList(_prefsKnownPasskeyEmailsKey) ?? const <String>[];
      final normalized = stored
          .map(_normalizeEmailForCache)
          .where((v) => v.isNotEmpty)
          .toList();
      return normalized;
    } catch (_) {}
    return const <String>[];
  }

  static Future<void> _writePasskeyEmailsToSecureStore(
    List<String> emails,
  ) async {
    try {
      await SecureStorageService.instance.write(
        _prefsKnownPasskeyEmailsKey,
        jsonEncode(emails),
      );
    } catch (_) {}
    // Remove legacy plain copy.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_prefsKnownPasskeyEmailsKey)) {
        await prefs.remove(_prefsKnownPasskeyEmailsKey);
      }
    } catch (_) {}
  }

  static Future<Set<String>> getKnownPasskeyEnabledEmails() async {
    final cached = _knownPasskeyEmailsCache;
    if (cached != null) {
      return Set<String>.from(cached);
    }

    final normalized = await _readPasskeyEmailsFromSecureStore();
    _knownPasskeyEmailsCache = normalized.toSet();
    return Set<String>.from(normalized);
  }

  static Set<String> getKnownPasskeyEnabledEmailsSnapshot() {
    return Set<String>.from(_knownPasskeyEmailsCache ?? const <String>{});
  }

  static Future<Set<String>> cachePasskeyAvailabilityForEmail(
    String email,
    bool hasPasskey,
  ) async {
    final normalizedEmail = _normalizeEmailForCache(email);
    final updated = await getKnownPasskeyEnabledEmails();
    if (normalizedEmail.isEmpty) {
      return updated;
    }

    if (hasPasskey) {
      updated.add(normalizedEmail);
    } else {
      updated.remove(normalizedEmail);
    }

    final persisted = updated.toList()..sort();
    if (persisted.length > _maxKnownPasskeyEmails) {
      persisted.removeRange(0, persisted.length - _maxKnownPasskeyEmails);
    }

    _knownPasskeyEmailsCache = persisted.toSet();
    await _writePasskeyEmailsToSecureStore(persisted);
    return Set<String>.from(_knownPasskeyEmailsCache!);
  }

  static String _normalizeEmailForCache(String email) {
    return email.trim().toLowerCase();
  }

  static const Duration _requestTimeout = Duration(seconds: 15);
  static const String _prefsSupabaseAnonKeyKey = 'runtime_supabase_anon_key';

  static Future<PasskeyAvailabilityState>
  loadAuthenticationAvailability() async {
    final isEnabled = await appConfigService.isPasskeysEnabled();
    if (!isEnabled) {
      return const PasskeyAvailabilityState(
        isEnabled: false,
        isPlatformSupported: false,
        isRuntimeConfigured: false,
      );
    }

    return PasskeyAvailabilityState(
      isEnabled: true,
      isPlatformSupported:
          await PasskeyClientService.isAuthenticationSupported(),
      isRuntimeConfigured: await appConfigService.isPasskeysRuntimeConfigured(),
    );
  }

  static Future<PasskeyAvailabilityState> loadRegistrationAvailability() async {
    final isEnabled = await appConfigService.isPasskeysEnabled();
    if (!isEnabled) {
      return const PasskeyAvailabilityState(
        isEnabled: false,
        isPlatformSupported: false,
        isRuntimeConfigured: false,
      );
    }

    return PasskeyAvailabilityState(
      isEnabled: true,
      isPlatformSupported: await PasskeyClientService.isRegistrationSupported(),
      isRuntimeConfigured: await appConfigService.isPasskeysRuntimeConfigured(),
    );
  }

  static String _detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      default:
        return 'unknown';
    }
  }

  static Future<PasskeyAuthenticationEndpoints>
  getAuthenticationEndpoints() async {
    final configService = AppConfigService();
    final runtimeConfig = await configService.getPasskeysRuntimeConfig();
    final isRuntimeConfigured = await configService
        .isPasskeysRuntimeConfigured();
    if (!isRuntimeConfigured || runtimeConfig.serverBaseUri == null) {
      throw const PasskeyAuthException(
        code: 'config_invalid',
        message: 'Passkey authentication is not configured correctly.',
      );
    }

    final startPath = await configService.getPasskeysStartAuthenticationPath();
    final finishPath = await configService
        .getPasskeysFinishAuthenticationPath();
    final serverBaseUri = runtimeConfig.serverBaseUri!;

    return PasskeyAuthenticationEndpoints(
      startAuthentication: serverBaseUri.resolve(startPath),
      finishAuthentication: serverBaseUri.resolve(finishPath),
    );
  }

  static Future<PasskeyRegistrationEndpoints> getRegistrationEndpoints() async {
    final configService = AppConfigService();
    final runtimeConfig = await configService.getPasskeysRuntimeConfig();
    final isRuntimeConfigured = await configService
        .isPasskeysRuntimeConfigured();
    if (!isRuntimeConfigured || runtimeConfig.serverBaseUri == null) {
      throw const PasskeyAuthException(
        code: 'config_invalid',
        message: 'Passkey authentication is not configured correctly.',
      );
    }

    final startPath = await configService.getPasskeysStartRegistrationPath();
    final finishPath = await configService.getPasskeysFinishRegistrationPath();
    final serverBaseUri = runtimeConfig.serverBaseUri!;

    return PasskeyRegistrationEndpoints(
      startRegistration: serverBaseUri.resolve(startPath),
      finishRegistration: serverBaseUri.resolve(finishPath),
    );
  }

  static Future<PasskeyStartAuthenticationResult> startAuthentication({
    required String email,
  }) async {
    _log('[Passkey] startAuthentication called with email: $email');

    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      _log('[Passkey] Email is empty');
      throw const PasskeyAuthException(
        code: 'bad_request',
        message: 'Passkey sign-in requires an email address.',
      );
    }

    _log('[Passkey] Getting authentication endpoints');
    final endpoints = await getAuthenticationEndpoints();
    _log(
      '[Passkey] Start authentication endpoint: ${endpoints.startAuthentication}',
    );

    _log('[Passkey] Calling _postJson with email: $normalizedEmail');
    final response = await _postJson(
      endpoints.startAuthentication,
      body: {
        'email': normalizedEmail,
        'login_hint': normalizedEmail,
        'platform': _detectPlatform(),
      },
    );

    _log('[Passkey] Got response from startAuthentication');
    final result = PasskeyStartAuthenticationResult.fromResponse(response);
    _log(
      '[Passkey] Result has public key options: ${result.hasPublicKeyOptions}',
    );
    _log('[Passkey] Result request ID: ${result.requestId}');
    await cachePasskeyAvailabilityForEmail(
      normalizedEmail,
      result.hasPublicKeyOptions,
    );

    return result;
  }

  static Future<PasskeyStartRegistrationResult> startRegistration({
    String? email,
    String? userId,
    String? displayName,
  }) async {
    _log('[Passkey] startRegistration called');

    final currentUser = Supabase.instance.client.auth.currentUser;
    _log('[Passkey] Current user ID: ${currentUser?.id}');
    _log('[Passkey] Current user email: ${currentUser?.email}');

    final normalizedEmail = (email ?? currentUser?.email ?? '')
        .trim()
        .toLowerCase();
    final normalizedUserId = (userId ?? currentUser?.id ?? '').trim();
    final normalizedDisplayName =
        (displayName ??
                currentUser?.userMetadata?['display_name']?.toString() ??
                currentUser?.userMetadata?['full_name']?.toString() ??
                currentUser?.email ??
                '')
            .trim();

    _log('[Passkey] Normalized email: $normalizedEmail');
    _log('[Passkey] Normalized user ID: $normalizedUserId');
    _log('[Passkey] Normalized display name: $normalizedDisplayName');

    if (normalizedEmail.isEmpty && normalizedUserId.isEmpty) {
      _log('[Passkey] Missing user identifier');
      throw const PasskeyAuthException(
        code: 'bad_request',
        message: 'Passkey registration requires a user identifier.',
      );
    }

    _log('[Passkey] Getting registration endpoints');
    final endpoints = await getRegistrationEndpoints();
    _log(
      '[Passkey] Start registration endpoint: ${endpoints.startRegistration}',
    );

    _log('[Passkey] Calling _postJson for registration start');
    final response = await _postJson(
      endpoints.startRegistration,
      body: {
        if (normalizedEmail.isNotEmpty) 'email': normalizedEmail,
        if (normalizedEmail.isNotEmpty) 'login_hint': normalizedEmail,
        if (normalizedUserId.isNotEmpty) 'user_id': normalizedUserId,
        if (normalizedUserId.isNotEmpty) 'userId': normalizedUserId,
        if (normalizedDisplayName.isNotEmpty)
          'display_name': normalizedDisplayName,
        if (normalizedDisplayName.isNotEmpty)
          'displayName': normalizedDisplayName,
        'platform': _detectPlatform(),
      },
    );

    _log('[Passkey] Got response from startRegistration');
    final result = PasskeyStartRegistrationResult.fromResponse(response);
    _log(
      '[Passkey] Result has public key options: ${result.hasPublicKeyOptions}',
    );
    _log('[Passkey] Result request ID: ${result.requestId}');

    return result;
  }

  static Future<PasskeyFinishAuthenticationResult> finishAuthentication({
    required Map<String, dynamic> assertion,
    required String email,
    String? requestId,
  }) async {
    _log('[Passkey] finishAuthentication called');
    _log('[Passkey] Assertion keys: ${assertion.keys.toList()}');
    _log('[Passkey] Email: $email');
    _log('[Passkey] Request ID: $requestId');

    if (assertion.isEmpty) {
      _log('[Passkey] Assertion is empty');
      throw const PasskeyAuthException(
        code: 'bad_request',
        message: 'Passkey sign-in requires an assertion payload.',
      );
    }

    _log('[Passkey] Getting authentication endpoints');
    final endpoints = await getAuthenticationEndpoints();
    _log(
      '[Passkey] Finish authentication endpoint: ${endpoints.finishAuthentication}',
    );

    final normalizedEmail = email.trim().toLowerCase();
    final normalizedRequestId = requestId?.trim();
    if (normalizedEmail.isEmpty) {
      throw const PasskeyAuthException(
        code: 'bad_request',
        message: 'Passkey sign-in requires an email address.',
      );
    }
    _log('[Passkey] Calling _postJson to finish authentication');
    final response = await _postJson(
      endpoints.finishAuthentication,
      body: {
        'assertion': assertion,
        'credential': assertion,
        'email': normalizedEmail,
        if (normalizedRequestId != null && normalizedRequestId.isNotEmpty)
          'request_id': normalizedRequestId,
        if (normalizedRequestId != null && normalizedRequestId.isNotEmpty)
          'requestId': normalizedRequestId,
        'platform': _detectPlatform(),
      },
    );

    _log('[Passkey] Got response from finishAuthentication');
    final result = PasskeyFinishAuthenticationResult.fromResponse(response);
    _log(
      '[Passkey] Result has session payload: ${result.hasSupabaseSessionPayload}',
    );
    _log('[Passkey] Result has refresh token: ${result.hasRefreshToken}');
    await cachePasskeyAvailabilityForEmail(normalizedEmail, true);

    return result;
  }

  static Future<PasskeyFinishRegistrationResult> finishRegistration({
    required Map<String, dynamic> attestation,
    String? requestId,
  }) async {
    _log('[Passkey] finishRegistration called');
    _log('[Passkey] Attestation keys: ${attestation.keys.toList()}');
    _log('[Passkey] Request ID: $requestId');

    if (attestation.isEmpty) {
      _log('[Passkey] Attestation is empty');
      throw const PasskeyAuthException(
        code: 'bad_request',
        message: 'Passkey registration requires an attestation payload.',
      );
    }

    _log('[Passkey] Getting registration endpoints');
    final endpoints = await getRegistrationEndpoints();
    _log(
      '[Passkey] Finish registration endpoint: ${endpoints.finishRegistration}',
    );

    final normalizedRequestId = requestId?.trim();
    _log('[Passkey] Calling _postJson to finish registration');
    final response = await _postJson(
      endpoints.finishRegistration,
      body: {
        'attestation': attestation,
        'credential': attestation,
        if (normalizedRequestId != null && normalizedRequestId.isNotEmpty)
          'request_id': normalizedRequestId,
        if (normalizedRequestId != null && normalizedRequestId.isNotEmpty)
          'requestId': normalizedRequestId,
        'platform': _detectPlatform(),
      },
    );

    _log('[Passkey] Got response from finishRegistration');
    final result = PasskeyFinishRegistrationResult.fromResponse(response);
    _log('[Passkey] Result credential ID: ${result.credentialId}');
    _log('[Passkey] Result has session: ${result.hasSupabaseSessionPayload}');
    final currentUserEmail = Supabase.instance.client.auth.currentUser?.email;
    if (currentUserEmail != null && currentUserEmail.trim().isNotEmpty) {
      await cachePasskeyAvailabilityForEmail(currentUserEmail, true);
    }

    return result;
  }

  static Future<AuthResponse> applySupabaseSession(
    PasskeyFinishAuthenticationResult result,
  ) async {
    _log('[Passkey] applySupabaseSession called');
    _log('[Passkey] Can apply session: ${result.canApplySupabaseSession}');
    _log('[Passkey] Has session payload: ${result.hasSupabaseSessionPayload}');
    _log('[Passkey] Has refresh token: ${result.hasRefreshToken}');

    if (!result.canApplySupabaseSession) {
      _log('[Passkey] Cannot apply session - missing session data');
      throw const PasskeyAuthException(
        code: 'session_missing',
        message:
            'Passkey response did not include a reusable Supabase session.',
      );
    }

    _log('[Passkey] Setting pending auth method to passkey');
    await SessionService.setPendingAuthMethod('passkey');

    try {
      if (result.hasSupabaseSessionPayload) {
        _log('[Passkey] Applying session payload');
        final normalizedSessionPayload =
            _normalizeSupabaseSessionPayload(result.sessionPayload!) ??
            result.sessionPayload!;
        final sessionJson = jsonEncode(normalizedSessionPayload);
        _log('[Passkey] Recovering session');
        await Supabase.instance.client.auth.recoverSession(sessionJson);
        _log('[Passkey] Refreshing session');
        final refreshResponse = await Supabase.instance.client.auth
            .refreshSession()
            .timeout(_requestTimeout);
        _log('[Passkey] Registering session as passkey');
        await _registerCurrentSessionAsPasskey();
        _log('[Passkey] Session applied successfully');
        return refreshResponse;
      }

      _log('[Passkey] Applying refresh token');
      final refreshToken = result.refreshToken!.trim();
      _log('[Passkey] Setting session with refresh token');
      final authResponse = await Supabase.instance.client.auth
          .setSession(refreshToken)
          .timeout(_requestTimeout);
      _log('[Passkey] Registering session as passkey');
      await _registerCurrentSessionAsPasskey();
      _log('[Passkey] Session applied successfully');
      return authResponse;
    } catch (error) {
      _log('[Passkey] Error applying session: $error');
      await SessionService.setPendingAuthMethod(null);
      throw PasskeyAuthException(
        code: 'session_apply_failed',
        message: error.toString(),
      );
    }
  }

  static Future<PasskeyFinishAuthenticationResult>
  finishAuthenticationAndApplySession({
    required Map<String, dynamic> assertion,
    required String email,
    String? requestId,
  }) async {
    final result = await finishAuthentication(
      assertion: assertion,
      email: email,
      requestId: requestId,
    );
    await applySupabaseSession(result);
    return result;
  }

  static Future<PasskeyFinishRegistrationResult>
  finishRegistrationAndApplySession({
    required Map<String, dynamic> attestation,
    String? requestId,
  }) async {
    _log('[Passkey] finishRegistrationAndApplySession called');
    _log('[Passkey] Attestation keys: ${attestation.keys.toList()}');
    _log('[Passkey] Request ID: $requestId');

    _log('[Passkey] Calling finishRegistration');
    final result = await finishRegistration(
      attestation: attestation,
      requestId: requestId,
    );

    _log('[Passkey] finishRegistration complete');
    _log('[Passkey] Can apply session: ${result.canApplySupabaseSession}');
    _log('[Passkey] Credential ID: ${result.credentialId}');

    if (result.canApplySupabaseSession) {
      _log('[Passkey] Applying Supabase session');
      await applySupabaseSession(
        PasskeyFinishAuthenticationResult(
          rawResponse: result.rawResponse,
          sessionPayload: result.sessionPayload,
          refreshToken: result.refreshToken,
        ),
      );
      _log('[Passkey] Session applied successfully');
    } else {
      _log('[Passkey] No session to apply');
    }
    return result;
  }

  static Future<Map<String, dynamic>> _postJson(
    Uri uri, {
    required Map<String, dynamic> body,
  }) async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final apiKey = await _resolveSupabaseApiKey();
      final requestHeaders = <String, String>{
        'Content-Type': 'application/json',
      };
      if (session?.accessToken case final token?) {
        requestHeaders['Authorization'] = 'Bearer $token';
      } else if (apiKey != null && apiKey.trim().isNotEmpty) {
        requestHeaders['Authorization'] = 'Bearer ${apiKey.trim()}';
      }
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        requestHeaders['apikey'] = apiKey.trim();
      }

      _log('[Passkey] Has current session: ${session != null}');
      _log(
        '[Passkey] Sending auth header: '
        '${requestHeaders.containsKey('Authorization')}',
      );
      _log(
        '[Passkey] Sending apikey header: ${requestHeaders.containsKey('apikey')}',
      );

      final response = await http
          .post(uri, headers: requestHeaders, body: jsonEncode(body))
          .timeout(_requestTimeout);

      _log('[Passkey] HTTP status: ${response.statusCode}');
      _log('[Passkey] HTTP body: ${response.body}');

      final decoded = _decodeJsonMap(response.body);

      // Check for HTTP errors
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorCode = _extractErrorCode(decoded) ?? 'request_failed';
        final errorMessage =
            _extractErrorMessage(decoded) ??
            'Passkey request failed with status ${response.statusCode}';
        _log(
          '[Passkey] HTTP error: ${response.statusCode} $errorCode $errorMessage',
        );
        throw PasskeyAuthException(
          code: errorCode,
          message: errorMessage,
          statusCode: response.statusCode,
        );
      }

      _log('[Passkey] Decoded: $decoded');

      if (decoded == null) {
        throw const PasskeyAuthException(
          code: 'invalid_response',
          message: 'Passkey server returned an invalid response.',
        );
      }

      return decoded;
    } on TimeoutException {
      _log('[Passkey] Timeout error');
      throw const PasskeyAuthException(
        code: 'timeout',
        message: 'Passkey request timed out.',
      );
    } on PasskeyAuthException catch (error) {
      _log('[Passkey] PasskeyAuthException: $error');
      rethrow;
    } catch (error) {
      _log('[Passkey] Network error: $error');
      throw PasskeyAuthException(
        code: 'network_error',
        message: error.toString(),
      );
    }
  }

  static Future<String?> _resolveSupabaseApiKey() async {
    final clientApiKey = Supabase.instance.client.headers['apikey']?.trim();
    if (clientApiKey != null && clientApiKey.isNotEmpty) {
      return clientApiKey;
    }

    const envApiKey = String.fromEnvironment('SUPABASE_ANON_KEY');
    final normalizedEnvApiKey = _stripOptionalQuotes(envApiKey);
    if (normalizedEnvApiKey.isNotEmpty) {
      return normalizedEnvApiKey;
    }

    final dotenvApiKey = _stripOptionalQuotes(
      dotenv.env['SUPABASE_ANON_KEY'] ?? '',
    );
    if (dotenvApiKey.isNotEmpty) {
      return dotenvApiKey;
    }

    final prefs = await SharedPreferences.getInstance();
    final storedApiKey = prefs.getString(_prefsSupabaseAnonKeyKey)?.trim();
    if (storedApiKey != null && storedApiKey.isNotEmpty) {
      return storedApiKey;
    }

    return null;
  }

  static String _stripOptionalQuotes(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2) {
      final first = trimmed[0];
      final last = trimmed[trimmed.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    return trimmed;
  }

  static Map<String, dynamic>? _decodeJsonMap(String rawBody) {
    final trimmed = rawBody.trim();
    if (trimmed.isEmpty) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  static String? _extractErrorCode(Map<String, dynamic>? source) {
    if (source == null || source.isEmpty) return null;

    return _extractNestedString(source, const [
          ['code'],
          ['error_code'],
          ['errorCode'],
          ['error', 'code'],
          ['error', 'error_code'],
          ['error', 'errorCode'],
          ['data', 'code'],
          ['data', 'error_code'],
          ['data', 'errorCode'],
          ['data', 'error', 'code'],
          ['data', 'error', 'error_code'],
          ['data', 'error', 'errorCode'],
          ['result', 'code'],
          ['result', 'error_code'],
          ['result', 'errorCode'],
          ['result', 'error', 'code'],
          ['result', 'error', 'error_code'],
          ['result', 'error', 'errorCode'],
          ['meta', 'code'],
          ['meta', 'error_code'],
          ['meta', 'errorCode'],
        ]) ??
        _extractFirstErrorListValue(source, const [
          'code',
          'error_code',
          'errorCode',
        ]);
  }

  static String? _extractErrorMessage(Map<String, dynamic>? source) {
    if (source == null || source.isEmpty) return null;

    return _extractNestedString(source, const [
          ['message'],
          ['error_description'],
          ['errorDescription'],
          ['error'],
          ['detail'],
          ['details'],
          ['error', 'message'],
          ['error', 'description'],
          ['error', 'detail'],
          ['data', 'message'],
          ['data', 'error_description'],
          ['data', 'errorDescription'],
          ['data', 'error'],
          ['data', 'detail'],
          ['data', 'details'],
          ['data', 'error', 'message'],
          ['data', 'error', 'description'],
          ['data', 'error', 'detail'],
          ['result', 'message'],
          ['result', 'error_description'],
          ['result', 'errorDescription'],
          ['result', 'error'],
          ['result', 'detail'],
          ['result', 'details'],
          ['result', 'error', 'message'],
          ['result', 'error', 'description'],
          ['result', 'error', 'detail'],
        ]) ??
        _extractFirstErrorListValue(source, const [
          'message',
          'description',
          'detail',
        ]);
  }

  static String? _extractFirstErrorListValue(
    Map<String, dynamic> source,
    List<String> candidateKeys,
  ) {
    final rawErrors = source['errors'];
    if (rawErrors is! List) return null;
    for (final entry in rawErrors) {
      if (entry is Map<String, dynamic>) {
        final value = _extractNormalizedString(entry, candidateKeys);
        if (value != null) return value;
        continue;
      }
      if (entry is Map) {
        final mapped = entry.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final value = _extractNormalizedString(mapped, candidateKeys);
        if (value != null) return value;
        continue;
      }
      final text = entry?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  static Future<void> _registerCurrentSessionAsPasskey() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      await SessionService.registerSession(
        user.id,
        platform: _detectPlatform(),
        authMethod: 'passkey',
      );
    } catch (_) {}
  }

  static Map<String, dynamic>? _extractNestedMap(
    Map<String, dynamic> source,
    List<List<String>> candidatePaths,
  ) {
    for (final path in candidatePaths) {
      dynamic current = source;
      var matched = true;
      for (final segment in path) {
        if (current is Map && current.containsKey(segment)) {
          current = current[segment];
        } else {
          matched = false;
          break;
        }
      }
      if (!matched) continue;
      if (current is Map<String, dynamic>) return current;
      if (current is Map) {
        return current.map((key, value) => MapEntry(key.toString(), value));
      }
    }
    return null;
  }

  static String? _extractNestedString(
    Map<String, dynamic> source,
    List<List<String>> candidatePaths,
  ) {
    for (final path in candidatePaths) {
      dynamic current = source;
      var matched = true;
      for (final segment in path) {
        if (current is Map && current.containsKey(segment)) {
          current = current[segment];
        } else {
          matched = false;
          break;
        }
      }
      if (!matched || current == null) continue;
      final text = current.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static String? _extractNormalizedString(
    Map<String, dynamic>? source,
    List<String> candidateKeys,
  ) {
    if (source == null) return null;
    for (final key in candidateKeys) {
      final value = source[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static Map<String, dynamic>? _normalizeSupabaseSessionPayload(
    Map<String, dynamic>? source,
  ) {
    if (source == null || source.isEmpty) return null;

    final accessToken = _extractNormalizedString(source, const [
      'access_token',
      'accessToken',
    ]);
    final refreshToken = _extractNormalizedString(source, const [
      'refresh_token',
      'refreshToken',
    ]);
    final tokenType = _extractNormalizedString(source, const [
      'token_type',
      'tokenType',
    ]);
    final providerToken = _extractNormalizedString(source, const [
      'provider_token',
      'providerToken',
    ]);
    final providerRefreshToken = _extractNormalizedString(source, const [
      'provider_refresh_token',
      'providerRefreshToken',
    ]);
    final user = _extractNestedMap(source, const [
      ['user'],
    ]);

    final normalized = <String, dynamic>{
      ...?accessToken == null ? null : {'access_token': accessToken},
      ...?refreshToken == null ? null : {'refresh_token': refreshToken},
      ...?tokenType == null ? null : {'token_type': tokenType},
      ...?providerToken == null ? null : {'provider_token': providerToken},
      ...?providerRefreshToken == null
          ? null
          : {'provider_refresh_token': providerRefreshToken},
      ...?user == null ? null : {'user': user},
    };

    final expiresIn = _extractEpochLikeInt(source, const [
      'expires_in',
      'expiresIn',
    ]);
    if (expiresIn != null) {
      normalized['expires_in'] = expiresIn;
    }

    final expiresAt = _extractEpochLikeInt(source, const [
      'expires_at',
      'expiresAt',
    ]);
    if (expiresAt != null) {
      normalized['expires_at'] = expiresAt;
    }

    return _looksLikeSupabaseSessionPayload(normalized) ? normalized : null;
  }

  static int? _extractEpochLikeInt(
    Map<String, dynamic> source,
    List<String> candidateKeys,
  ) {
    for (final key in candidateKeys) {
      final value = source[key];
      if (value == null) continue;
      if (value is int) return value;
      if (value is num) return value.toInt();
      final text = value.toString().trim();
      if (text.isEmpty) continue;
      final parsedInt = int.tryParse(text);
      if (parsedInt != null) return parsedInt;
      final parsedDateTime = DateTime.tryParse(text);
      if (parsedDateTime != null) {
        return parsedDateTime.millisecondsSinceEpoch ~/ 1000;
      }
    }
    return null;
  }

  static bool _looksLikePublicKeyRequestOptions(Map<String, dynamic> source) {
    return source['challenge'] != null ||
        source['allowCredentials'] != null ||
        source['allow_credentials'] != null ||
        source['rpId'] != null ||
        source['rp_id'] != null ||
        source['userVerification'] != null ||
        source['user_verification'] != null;
  }

  static bool _looksLikePublicKeyCreationOptions(Map<String, dynamic> source) {
    return source['challenge'] != null ||
        source['rp'] != null ||
        source['user'] != null ||
        source['pubKeyCredParams'] != null ||
        source['pub_key_cred_params'] != null ||
        source['authenticatorSelection'] != null ||
        source['authenticator_selection'] != null;
  }

  static bool _looksLikeSupabaseSessionPayload(Map<String, dynamic> source) {
    return source['access_token'] != null ||
        source['accessToken'] != null ||
        source['refresh_token'] != null ||
        source['refreshToken'] != null ||
        source['expires_at'] != null ||
        source['expiresAt'] != null ||
        source['expires_in'] != null ||
        source['expiresIn'] != null ||
        source['token_type'] != null ||
        source['tokenType'] != null;
  }

  /// Remove/revoke all passkeys for the current user
  ///
  /// This is a security-sensitive operation that removes all registered passkeys.
  /// The user should be warned before calling this.
  static Future<void> revokeAllPasskeys() async {
    _log('[Passkey] Starting passkey revocation');

    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;

      if (userId == null) {
        throw PasskeyAuthException(
          code: 'not_authenticated',
          message: 'User is not authenticated',
        );
      }

      // Call the RPC to revoke all passkeys for this user
      // This RPC should:
      // 1. Delete all webauthn credentials for the user
      // 2. Log the revocation event
      // 3. Return success/failure
      _log('[Passkey] Calling revoke_all_passkeys RPC for user: $userId');

      await client.rpc('revoke_all_passkeys', params: {'p_user_id': userId});

      _log('[Passkey] Successfully revoked all passkeys');
    } catch (e) {
      _log('[Passkey] Error revoking passkeys: $e');
      if (e is PasskeyAuthException) {
        rethrow;
      }
      throw PasskeyAuthException(
        code: 'revocation_failed',
        message: 'Failed to revoke passkeys: $e',
      );
    }
  }

  /// Check if current authenticated user has any passkeys registered
  /// Returns true if user has at least one passkey, false otherwise
  static Future<bool> currentUserHasRegisteredPasskeys() async {
    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) return false;

    try {
      final response = await Supabase.instance.client
          .from('passkey_credentials')
          .select('id')
          .eq('user_id', currentUser.id)
          .limit(1)
          .maybeSingle();

      return response != null;
    } catch (e) {
      _log('[Passkey] Error checking passkey existence: $e');
      // Fall back to cached email check if direct query fails
      final email = currentUser.email;
      if (email != null) {
        final knownEmails = await getKnownPasskeyEnabledEmails();
        return knownEmails.contains(_normalizeEmailForCache(email));
      }
      return false;
    }
  }
}
