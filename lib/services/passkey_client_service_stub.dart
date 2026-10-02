import 'package:matchme/utils/passkey_device_capability.dart';

import 'passkey_client_exception.dart';

Future<bool> isAuthenticationSupported() async => false;

Future<bool> isRegistrationSupported() async => false;

Future<PasskeyDeviceAvailability> getDeviceAvailability() async =>
    PasskeyDeviceAvailability.unavailable;

Future<Map<String, dynamic>> getAuthenticationAssertion({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  throw const PasskeyClientException(
    code: 'not_supported',
    message: 'Passkey sign-in is not supported on this platform.',
  );
}

Future<Map<String, dynamic>> getRegistrationAttestation({
  required Map<String, dynamic> publicKeyOptions,
}) async {
  throw const PasskeyClientException(
    code: 'not_supported',
    message: 'Passkey registration is not supported on this platform.',
  );
}
