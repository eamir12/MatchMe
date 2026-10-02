import 'package:matchme/utils/passkey_device_capability.dart';

import 'passkey_client_service_stub.dart'
    if (dart.library.io) 'passkey_client_service_native.dart'
    if (dart.library.html) 'passkey_client_service_web.dart'
    as impl;

class PasskeyClientService {
  static Future<bool> isAuthenticationSupported() =>
      impl.isAuthenticationSupported();

  static Future<bool> isRegistrationSupported() =>
      impl.isRegistrationSupported();

  /// Per-device availability flags, so the UI can explain *why* passkey
  /// sign-in is offered or unavailable rather than silently hiding it.
  static Future<PasskeyDeviceAvailability> getDeviceAvailability() =>
      impl.getDeviceAvailability();

  static Future<Map<String, dynamic>> getAuthenticationAssertion({
    required Map<String, dynamic> publicKeyOptions,
  }) {
    return impl.getAuthenticationAssertion(publicKeyOptions: publicKeyOptions);
  }

  static Future<Map<String, dynamic>> getRegistrationAttestation({
    required Map<String, dynamic> publicKeyOptions,
  }) {
    return impl.getRegistrationAttestation(publicKeyOptions: publicKeyOptions);
  }
}
