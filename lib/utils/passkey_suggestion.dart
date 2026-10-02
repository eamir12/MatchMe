import 'package:matchme/utils/passkey_device_capability.dart';

export 'package:matchme/utils/passkey_device_capability.dart'
    show PasskeyDeviceCapability, resolvePasskeyDeviceCapability;

/// What the passkey card should say and offer for a given device capability.
class PasskeyCardPresentation {
  const PasskeyCardPresentation({
    required this.titleKey,
    required this.bodyKey,
    required this.showActionButton,
  });

  final String titleKey;
  final String bodyKey;

  /// False when the device cannot run the ceremony: the "use your passkey"
  /// action would only fail, and the copy must not point at a button that
  /// isn't there.
  final bool showActionButton;
}

/// Chooses the passkey card's copy and whether to offer the passkey action.
///
/// When no platform authenticator is enrolled the card explains the situation
/// *instead of* advertising sign-in: telling someone to "use the passkey button
/// below", or showing a button that cannot succeed, is worse than an honest
/// explanation.
PasskeyCardPresentation resolvePasskeyCardPresentation(
  PasskeyDeviceCapability capability,
) {
  switch (capability) {
    case PasskeyDeviceCapability.noPlatformAuthenticator:
      return const PasskeyCardPresentation(
        titleKey: 'authPasskeyNoAuthenticatorTitle',
        bodyKey: 'authPasskeyNoAuthenticatorBody',
        showActionButton: false,
      );
    case PasskeyDeviceCapability.platformAuthenticatorReady:
    case PasskeyDeviceCapability.unsupported:
      return const PasskeyCardPresentation(
        titleKey: 'authPasskeyInlineHintTitle',
        bodyKey: 'authPasskeyInlineHintBody',
        showActionButton: true,
      );
  }
}

/// Whether the login screen may advertise passkey sign-in.
///
/// Passkey support is a property of the *device*, not just the account: the
/// account can have a passkey on file while the device cannot complete the
/// ceremony. The device can also be WebAuthn-capable without a platform
/// authenticator enrolled (a fresh Windows 11 PC with no Windows Hello PIN) —
/// a roaming authenticator such as a USB security key can still work there, so
/// that case is worth offering rather than hiding.
bool shouldSuggestPasskey({
  required bool isSignUp,
  required bool hasPasskeyForEmail,
  required PasskeyDeviceCapability? capability,
  required String normalizedEmail,
  required String lastCheckedEmail,
}) {
  if (isSignUp || !hasPasskeyForEmail) return false;
  // Null while the probe is in flight: don't flash the card before we know.
  if (capability == null) return false;
  if (capability == PasskeyDeviceCapability.unsupported) return false;
  return normalizedEmail.isNotEmpty && normalizedEmail == lastCheckedEmail;
}
