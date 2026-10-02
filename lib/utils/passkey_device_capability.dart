/// What the current device can do with a passkey ceremony.
enum PasskeyDeviceCapability {
  /// The platform has no WebAuthn support at all — nothing to offer.
  unsupported,

  /// WebAuthn works and a platform authenticator is ready (Windows Hello,
  /// Android screen lock, iOS Face ID / Touch ID).
  platformAuthenticatorReady,

  /// WebAuthn works but no platform authenticator is enrolled. A roaming
  /// authenticator (a USB security key) can still complete a ceremony here, so
  /// this is worth offering — with an explanation — rather than hiding.
  noPlatformAuthenticator,
}

/// Maps the two availability flags the passkeys plugins report onto a
/// capability the UI can explain.
PasskeyDeviceCapability resolvePasskeyDeviceCapability({
  required bool hasPasskeySupport,
  required bool hasPlatformAuthenticator,
}) {
  if (!hasPasskeySupport) return PasskeyDeviceCapability.unsupported;
  if (hasPlatformAuthenticator) {
    return PasskeyDeviceCapability.platformAuthenticatorReady;
  }
  return PasskeyDeviceCapability.noPlatformAuthenticator;
}

/// Raw per-device passkey availability flags, as reported by the passkeys
/// plugins. Shared by every platform implementation.
class PasskeyDeviceAvailability {
  const PasskeyDeviceAvailability({
    required this.hasPasskeySupport,
    required this.hasPlatformAuthenticator,
  });

  static const unavailable = PasskeyDeviceAvailability(
    hasPasskeySupport: false,
    hasPlatformAuthenticator: false,
  );

  final bool hasPasskeySupport;
  final bool hasPlatformAuthenticator;

  PasskeyDeviceCapability get capability => resolvePasskeyDeviceCapability(
    hasPasskeySupport: hasPasskeySupport,
    hasPlatformAuthenticator: hasPlatformAuthenticator,
  );
}
