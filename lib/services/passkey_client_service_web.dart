import 'dart:convert';
import 'dart:js_interop';

import 'package:matchme/utils/passkey_device_capability.dart';
import 'package:web/web.dart' as web;

import 'passkey_client_exception.dart';

/// Raw availability for the browser. The web path has no separate platform
/// authenticator concept, so `hasPlatformAuthenticator` mirrors support.
Future<PasskeyDeviceAvailability> getDeviceAvailability() async {
  if (_passkeysTemporarilyDisabledOnIos) {
    return PasskeyDeviceAvailability.unavailable;
  }
  if (web.window.isSecureContext != true) {
    return PasskeyDeviceAvailability.unavailable;
  }
  try {
    return PasskeyDeviceAvailability(
      hasPasskeySupport: _hasPasskeySupport().toDart,
      hasPlatformAuthenticator: _hasPasskeySupport().toDart,
    );
  } catch (_) {
    return PasskeyDeviceAvailability.unavailable;
  }
}

/// iOS passkeys are temporarily disabled in the browser too: every browser
/// on iOS is WebKit, and ceremonies fail there for the same reason they
/// fail in the native app — the relying party is not associated with a
/// domain. Until that domain setup exists, report the feature as
/// unavailable on iOS so the UI never offers it. Re-enable by removing
/// this gate once the AASA/origin configuration is in place.
///
/// Every non-Safari iOS browser still reports WebKit's UA tokens, and
/// iPadOS 13+ masquerades as desktop macOS — hence the `maxTouchPoints`
/// cross-check for that case.
bool get _passkeysTemporarilyDisabledOnIos {
  try {
    final userAgent = web.window.navigator.userAgent;
    if (userAgent.contains('iPhone') ||
        userAgent.contains('iPad') ||
        userAgent.contains('iPod')) {
      return true;
    }
    // iPadOS 13+ desktop-mode: identified as "Macintosh" but still touch.
    return userAgent.contains('Macintosh') &&
        web.window.navigator.maxTouchPoints > 1;
  } catch (_) {
    return false;
  }
}

@JS('PasskeyAuthenticator.init')
external void _passkeyAuthenticatorInit();

@JS('PasskeyAuthenticator.login')
external JSPromise<JSString> _authenticatorLogin(JSString options);

@JS('PasskeyAuthenticator.register')
external JSPromise<JSString> _authenticatorRegister(JSString options);

@JS('PasskeyAuthenticator.hasPasskeySupport')
external JSBoolean _hasPasskeySupport();

Future<bool> isAuthenticationSupported() async {
  if (_passkeysTemporarilyDisabledOnIos) {
    return false;
  }
  if (web.window.isSecureContext != true) {
    return false;
  }

  try {
    return _hasPasskeySupport().toDart;
  } catch (_) {
    return false;
  }
}

Future<bool> isRegistrationSupported() async {
  if (_passkeysTemporarilyDisabledOnIos) {
    return false;
  }
  if (web.window.isSecureContext != true) {
    return false;
  }

  try {
    return _hasPasskeySupport().toDart;
  } catch (_) {
    return false;
  }
}

Map<String, dynamic>? _tryDecodeJsonMap(String serialized) {
  try {
    final decoded = jsonDecode(serialized);
    return switch (decoded) {
      Map<String, dynamic>() => decoded,
      Map() => decoded.map((key, value) => MapEntry(key.toString(), value)),
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

bool _looksLikeCredentialPayload(Map<String, dynamic> payload) {
  final response = payload['response'];
  return payload['id'] != null &&
      (payload['rawId'] != null || response is Map || response != null);
}

Map<String, dynamic> _wrapRegistrationRequest(
  Map<String, dynamic> publicKeyOptions,
) {
  if (publicKeyOptions['publicKey'] is Map) {
    return publicKeyOptions;
  }

  return <String, dynamic>{'publicKey': publicKeyOptions};
}

Map<String, dynamic> _wrapAuthenticationRequest(
  Map<String, dynamic> publicKeyOptions,
) {
  if (publicKeyOptions['publicKey'] is Map) {
    return publicKeyOptions;
  }

  return <String, dynamic>{'publicKey': publicKeyOptions};
}

Map<String, dynamic> _decodeCredentialPayload(String serialized) {
  final decoded = jsonDecode(serialized);
  final payload = switch (decoded) {
    Map<String, dynamic>() => decoded,
    Map() => decoded.map((key, value) => MapEntry(key.toString(), value)),
    _ => null,
  };

  if (payload != null && _looksLikeCredentialPayload(payload)) {
    return payload;
  }

  throw const PasskeyClientException(
    code: 'invalid_response',
    message: 'Passkey credential response was invalid.',
  );
}

String _normalizeErrorText(Object error) {
  final raw = error.toString();
  final decoded = _tryDecodeJsonMap(raw);
  if (decoded == null) {
    return raw;
  }

  final parts = <String>[
    decoded['code']?.toString() ?? '',
    decoded['message']?.toString() ?? '',
    decoded['details']?.toString() ?? '',
  ].where((part) => part.trim().isNotEmpty);

  return parts.join(' ');
}

PasskeyClientException? _mapAuthenticationError(Object error) {
  final lower = _normalizeErrorText(error).toLowerCase();
  if (lower.contains('notallowederror') ||
      lower.contains('aborterror') ||
      lower.contains('cancel')) {
    return const PasskeyClientException(
      code: 'cancelled',
      message: 'Passkey sign-in was cancelled.',
    );
  }
  if (lower.contains('typeerror')) {
    return const PasskeyClientException(
      code: 'invalid_options',
      message: 'Passkey request options could not be prepared.',
    );
  }
  if (lower.contains('notsupportederror')) {
    return const PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey sign-in is not supported in this browser.',
    );
  }
  if (lower.contains('securityerror')) {
    return const PasskeyClientException(
      code: 'security_error',
      message: 'Passkey sign-in is blocked for this site configuration.',
    );
  }
  if (lower.contains('invalidstateerror')) {
    return const PasskeyClientException(
      code: 'invalid_state',
      message: 'Passkey sign-in could not use the selected credential.',
    );
  }
  if (lower.contains('notreadableerror') || lower.contains('unknownerror')) {
    return const PasskeyClientException(
      code: 'authenticator_unavailable',
      message: 'Passkey sign-in could not access an authenticator.',
    );
  }
  return null;
}

Future<Map<String, dynamic>> getAuthenticationAssertion({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  if (!await isAuthenticationSupported()) {
    throw const PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey sign-in is not supported in this browser.',
    );
  }

  try {
    _passkeyAuthenticatorInit();
    final request = _wrapAuthenticationRequest(publicKeyOptions);
    final serialized = await _authenticatorLogin(
      jsonEncode(request).toJS,
    ).toDart;
    final decoded = _tryDecodeJsonMap(serialized.toDart);
    if (decoded == null) {
      throw const PasskeyClientException(
        code: 'invalid_response',
        message: 'Passkey credential response was invalid.',
      );
    }

    return _decodeCredentialPayload(jsonEncode(decoded));
  } catch (error) {
    if (error is PasskeyClientException) {
      rethrow;
    }
    final mappedError = _mapAuthenticationError(error);
    if (mappedError != null) {
      throw mappedError;
    }
    throw PasskeyClientException(
      code: 'request_failed',
      message: error.toString(),
    );
  }
}

Future<Map<String, dynamic>> getRegistrationAttestation({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  if (!await isRegistrationSupported()) {
    throw const PasskeyClientException(
      code: 'not_supported',
      message: 'Passkey registration is not supported in this browser.',
    );
  }

  try {
    _passkeyAuthenticatorInit();
    final request = _wrapRegistrationRequest(publicKeyOptions);
    final serialized = await _authenticatorRegister(
      jsonEncode(request).toJS,
    ).toDart;
    final decoded = _tryDecodeJsonMap(serialized.toDart);
    if (decoded == null) {
      throw const PasskeyClientException(
        code: 'invalid_response',
        message: 'Passkey credential response was invalid.',
      );
    }

    return _decodeCredentialPayload(jsonEncode(decoded));
  } catch (error) {
    if (error is PasskeyClientException) {
      rethrow;
    }
    final mappedError = _mapAuthenticationError(error);
    if (mappedError != null) {
      throw mappedError;
    }
    throw PasskeyClientException(
      code: 'request_failed',
      message: error.toString(),
    );
  }
}
