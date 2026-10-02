import 'dart:io';

import 'package:flutter/services.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/exceptions.dart' as passkeys;
import 'package:passkeys/types.dart';

import 'package:matchme/utils/passkey_device_capability.dart';

import 'passkey_client_exception.dart';

void _log(String message) {
  stderr.writeln(message);
  print(message);
}

final PasskeyAuthenticator _authenticator = PasskeyAuthenticator();

Future<bool> isAuthenticationSupported() => _isPasskeySupported();

Future<bool> isRegistrationSupported() => _isPasskeySupported();

/// Raw availability flags for this device, used by the UI to explain *why*
/// passkey sign-in is or isn't offered rather than just hiding it.
Future<PasskeyDeviceAvailability> getDeviceAvailability() async {
  try {
    if (Platform.isAndroid) {
      final a = await _authenticator.getAvailability().android();
      return PasskeyDeviceAvailability(
        hasPasskeySupport: a.hasPasskeySupport,
        hasPlatformAuthenticator:
            a.isUserVerifyingPlatformAuthenticatorAvailable ?? false,
      );
    }
    if (Platform.isIOS) {
      final a = await _authenticator.getAvailability().iOS();
      return PasskeyDeviceAvailability(
        hasPasskeySupport: a.hasPasskeySupport,
        hasPlatformAuthenticator: a.hasBiometrics,
      );
    }
    if (Platform.isWindows) {
      final a = await _authenticator.getAvailability().windows();
      final availability = PasskeyDeviceAvailability(
        hasPasskeySupport: a.hasPasskeySupport,
        hasPlatformAuthenticator:
            a.isUserVerifyingPlatformAuthenticatorAvailable,
      );
      _log(
        '[PasskeyClient] Windows passkey availability: '
        'hasPasskeySupport=${availability.hasPasskeySupport} '
        'platformAuthenticator=${availability.hasPlatformAuthenticator}',
      );
      return availability;
    }
  } on MissingPluginException {
    return PasskeyDeviceAvailability.unavailable;
  } on PlatformException {
    return PasskeyDeviceAvailability.unavailable;
  } catch (_) {}

  return PasskeyDeviceAvailability.unavailable;
}

Future<Map<String, dynamic>> getAuthenticationAssertion({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  if (!await isAuthenticationSupported()) {
    throw const PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey sign-in is not supported on this platform.',
    );
  }

  try {
    _log('[PasskeyClient] getAuthenticationAssertion called');
    _log(
      '[PasskeyClient] publicKeyOptions keys: ${publicKeyOptions.keys.toList()}',
    );
    final response = await _authenticateWithFallbacks(publicKeyOptions);
    _log('[PasskeyClient] Got response from authenticator');
    return response.toJson();
  } catch (error) {
    _log('[PasskeyClient] ERROR in getAuthenticationAssertion: $error');
    _log('[PasskeyClient] Error type: ${error.runtimeType}');
    throw _mapAuthenticatorError(error, operation: 'sign-in');
  }
}

Future<AuthenticateResponseType> _authenticateWithFallbacks(
  Map<String, dynamic> publicKeyOptions,
) async {
  try {
    return await _authenticate(publicKeyOptions);
  } catch (error) {
    if (!Platform.isAndroid ||
        error is! passkeys.NoCredentialsAvailableException) {
      rethrow;
    }

    final fallbackRpIds = _buildAndroidAuthenticationRpIdFallbacks(
      publicKeyOptions,
    );
    if (fallbackRpIds.length <= 1) {
      rethrow;
    }

    _log(
      '[PasskeyClient] No credentials found for the primary Android RP ID. '
      'Retrying with fallbacks: $fallbackRpIds',
    );

    Object lastError = error;
    for (final rpId in fallbackRpIds.skip(1)) {
      try {
        final fallbackOptions = Map<String, dynamic>.from(publicKeyOptions)
          ..['rpId'] = rpId;
        _log(
          '[PasskeyClient] Retrying authentication with fallback rpId: $rpId',
        );
        return await _authenticate(fallbackOptions);
      } catch (fallbackError) {
        lastError = fallbackError;
        _log(
          '[PasskeyClient] Fallback authentication failed for rpId $rpId: '
          '$fallbackError',
        );
        if (fallbackError is! passkeys.NoCredentialsAvailableException) {
          rethrow;
        }
      }
    }

    throw lastError;
  }
}

Future<AuthenticateResponseType> _authenticate(
  Map<String, dynamic> publicKeyOptions,
) async {
  _log('[PasskeyClient] Creating AuthenticateRequestType from JSON');
  final request = AuthenticateRequestType.fromJson(publicKeyOptions);
  _log('[PasskeyClient] AuthenticateRequestType created successfully');
  _log('[PasskeyClient] Calling authenticator.authenticate()');
  return _authenticator.authenticate(request);
}

List<String> _buildAndroidAuthenticationRpIdFallbacks(
  Map<String, dynamic> publicKeyOptions,
) {
  final primaryRpId =
      _readString(publicKeyOptions['rpId']) ??
      _readString(publicKeyOptions['rp_id']);
  final candidates = <String>[
    ?primaryRpId,
    'com.example.matchme',
    'android',
    'localhost',
  ];

  final deduped = <String>[];
  for (final candidate in candidates) {
    final normalizedCandidate = candidate.trim();
    if (normalizedCandidate.isEmpty || deduped.contains(normalizedCandidate)) {
      continue;
    }
    deduped.add(normalizedCandidate);
  }
  return deduped;
}

String? _readString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    return null;
  }
  return text;
}

Future<Map<String, dynamic>> getRegistrationAttestation({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  if (!await isRegistrationSupported()) {
    throw const PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey registration is not supported on this platform.',
    );
  }

  try {
    _log('[PasskeyClient] getRegistrationAttestation called');
    _log(
      '[PasskeyClient] publicKeyOptions keys: ${publicKeyOptions.keys.toList()}',
    );
    _log('[PasskeyClient] publicKeyOptions: $publicKeyOptions');
    final normalizedPublicKeyOptions = _normalizeRegistrationOptions(
      publicKeyOptions,
    );
    _log(
      '[PasskeyClient] normalizedPublicKeyOptions: '
      '$normalizedPublicKeyOptions',
    );
    _log('[PasskeyClient] Creating RegisterRequestType from JSON');
    final request = RegisterRequestType.fromJson(normalizedPublicKeyOptions);
    _log('[PasskeyClient] RegisterRequestType created successfully');
    _log('[PasskeyClient] Calling authenticator.register()');
    final response = await _authenticator.register(request);
    _log('[PasskeyClient] Got response from authenticator');
    _log('[PasskeyClient] Response: $response');
    return response.toJson();
  } catch (error) {
    _log('[PasskeyClient] ERROR in getRegistrationAttestation: $error');
    _log('[PasskeyClient] Error type: ${error.runtimeType}');
    _log('[PasskeyClient] Error toString: ${error.toString()}');
    if (error is Exception) {
      _log('[PasskeyClient] Error stacktrace: ${StackTrace.current}');
    }
    throw _mapAuthenticatorError(error, operation: 'registration');
  }
}

Map<String, dynamic> _normalizeRegistrationOptions(
  Map<String, dynamic> publicKeyOptions,
) {
  final normalized = Map<String, dynamic>.from(publicKeyOptions);
  final selection = normalized['authenticatorSelection'];
  if (selection is Map) {
    final normalizedSelection = Map<String, dynamic>.from(
      selection.map((key, value) => MapEntry(key.toString(), value)),
    );
    final residentKey = normalizedSelection['residentKey']
        ?.toString()
        .trim()
        .toLowerCase();
    normalizedSelection['requireResidentKey'] ??= residentKey == 'required';
    normalized['authenticatorSelection'] = normalizedSelection;
  }
  return normalized;
}

Future<bool> _isPasskeySupported() async {
  try {
    if (Platform.isAndroid) {
      final availability = await _authenticator.getAvailability().android();
      return availability.hasPasskeySupport &&
          (availability.isUserVerifyingPlatformAuthenticatorAvailable ?? false);
    }

    if (Platform.isIOS) {
      final availability = await _authenticator.getAvailability().iOS();
      return availability.hasPasskeySupport && availability.hasBiometrics;
    }

    // Windows: `passkeys_windows` bridges WebAuthn, and Windows 11 ships a
    // TPM-backed platform authenticator (Windows Hello). Windows 10 usually
    // has none unless a roaming authenticator (e.g. a USB security key) is
    // attached, which is why the authenticator-availability flag — not just
    // `hasPasskeySupport` — decides.
    if (Platform.isWindows) {
      final availability = await _authenticator.getAvailability().windows();
      final supported =
          availability.hasPasskeySupport &&
          availability.isUserVerifyingPlatformAuthenticatorAvailable;
      _log(
        '[PasskeyClient] Windows passkey support: '
        'hasPasskeySupport=${availability.hasPasskeySupport} '
        'authenticatorAvailable='
        '${availability.isUserVerifyingPlatformAuthenticatorAvailable} '
        '-> $supported',
      );
      return supported;
    }
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  } catch (_) {
    return false;
  }

  return false;
}

PasskeyClientException _mapAuthenticatorError(
  Object error, {
  required String operation,
}) {
  if (error is PasskeyClientException) {
    return error;
  }

  if (error is passkeys.PasskeyAuthCancelledException) {
    return PasskeyClientException(
      code: 'cancelled',
      message: 'Passkey $operation was cancelled.',
    );
  }

  if (error is passkeys.DomainNotAssociatedException) {
    return PasskeyClientException(
      code: 'security_error',
      message:
          'Passkey $operation is blocked until the app domain association is configured.',
    );
  }

  if (error is passkeys.DeviceNotSupportedException) {
    return PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey $operation is not supported on this device.',
    );
  }

  if (error is passkeys.MissingGoogleSignInException ||
      error is passkeys.SyncAccountNotAvailableException ||
      error is passkeys.NoCredentialsAvailableException ||
      error is passkeys.NoCreateOptionException) {
    return PasskeyClientException(
      code: 'authenticator_unavailable',
      message: 'Passkey $operation is not available right now.',
    );
  }

  if (error is passkeys.ExcludeCredentialsCanNotBeRegisteredException ||
      error is passkeys.MalformedBase64Url ||
      error is FormatException) {
    return PasskeyClientException(
      code: 'invalid_options',
      message: 'Passkey $operation options could not be prepared.',
    );
  }

  // Handle Android-specific InvalidStateError for duplicate passkey registration
  if (error is PlatformException &&
      error.code.contains('INVALID_STATE_ERROR') &&
      (error.message?.contains('excluded credentials') ?? false)) {
    return PasskeyClientException(
      code: 'passkey_already_registered',
      message:
          'You have already registered this passkey. You can register a new passkey or manage it in settings.',
    );
  }

  if (error is passkeys.TimeoutException ||
      error is passkeys.UnhandledAuthenticatorException ||
      error is PlatformException) {
    return PasskeyClientException(
      code: 'authenticator_unavailable',
      message: 'Passkey $operation could not be completed.',
    );
  }

  return PasskeyClientException(
    code: 'request_failed',
    message: error.toString(),
  );
}
