import 'package:flutter/foundation.dart' show TargetPlatform;

import 'package:matchme/utils/passkey_device_capability.dart';

export 'package:matchme/utils/passkey_device_capability.dart'
    show PasskeyDeviceCapability, resolvePasskeyDeviceCapability;

/// What the passkey card should say and offer for a given device capability.
class PasskeyCardPresentation {
  const PasskeyCardPresentation({
    required this.titleKey,
    required this.bodyKey,
    required this.showActionButton,
    this.setupAction,
    this.setupButtonLabelKey,
    this.setupInstructionsTitleKey,
    this.setupInstructionsBodyKey,
  });

  final String titleKey;
  final String bodyKey;

  /// False when the device cannot run the ceremony: the "use your passkey"
  /// action would only fail, and the copy must not point at a button that
  /// isn't there.
  final bool showActionButton;
  final PasskeySetupAction? setupAction;
  final String? setupButtonLabelKey;
  final String? setupInstructionsTitleKey;
  final String? setupInstructionsBodyKey;
}

enum PasskeySetupAction {
  openAndroidSecuritySettings,
  openWindowsSignInOptions,
  showInstructions,
}

/// Chooses the passkey card's copy and whether to offer the passkey action.
///
/// When no platform authenticator is enrolled the card explains the situation
/// and provides device-specific setup help instead of advertising a passkey
/// action that cannot currently succeed.
PasskeyCardPresentation resolvePasskeyCardPresentation(
  PasskeyDeviceCapability capability, {
  required TargetPlatform platform,
}
) {
  switch (capability) {
    case PasskeyDeviceCapability.noPlatformAuthenticator:
      final configuration = switch (platform) {
        TargetPlatform.iOS => (
          title: 'authPasskeySetupIosTitle',
          body: 'authPasskeySetupIosBody',
          button: 'authPasskeySetupIosButton',
          action: PasskeySetupAction.showInstructions,
          instructionsTitle: 'authPasskeySetupIosInstructionsTitle',
          instructionsBody: 'authPasskeySetupIosInstructionsBody',
        ),
        TargetPlatform.android => (
          title: 'authPasskeySetupAndroidTitle',
          body: 'authPasskeySetupAndroidBody',
          button: 'authPasskeySetupAndroidButton',
          action: PasskeySetupAction.openAndroidSecuritySettings,
          instructionsTitle: 'authPasskeySetupAndroidInstructionsTitle',
          instructionsBody: 'authPasskeySetupAndroidInstructionsBody',
        ),
        TargetPlatform.windows => (
          title: 'authPasskeySetupWindowsTitle',
          body: 'authPasskeySetupWindowsBody',
          button: 'authPasskeySetupWindowsButton',
          action: PasskeySetupAction.openWindowsSignInOptions,
          instructionsTitle: 'authPasskeySetupWindowsInstructionsTitle',
          instructionsBody: 'authPasskeySetupWindowsInstructionsBody',
        ),
        TargetPlatform.macOS => (
          title: 'authPasskeySetupMacTitle',
          body: 'authPasskeySetupMacBody',
          button: 'authPasskeySetupMacButton',
          action: PasskeySetupAction.showInstructions,
          instructionsTitle: 'authPasskeySetupMacInstructionsTitle',
          instructionsBody: 'authPasskeySetupMacInstructionsBody',
        ),
        _ => (
          title: 'authPasskeySetupOtherTitle',
          body: 'authPasskeySetupOtherBody',
          button: 'authPasskeySetupOtherButton',
          action: PasskeySetupAction.showInstructions,
          instructionsTitle: 'authPasskeySetupOtherInstructionsTitle',
          instructionsBody: 'authPasskeySetupOtherInstructionsBody',
        ),
      };
      return PasskeyCardPresentation(
        titleKey: configuration.title,
        bodyKey: configuration.body,
        showActionButton: false,
        setupAction: configuration.action,
        setupButtonLabelKey: configuration.button,
        setupInstructionsTitleKey: configuration.instructionsTitle,
        setupInstructionsBodyKey: configuration.instructionsBody,
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
