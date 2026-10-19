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
    this.moreInfoButtonKey,
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
  final String? moreInfoButtonKey;
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

/// Device-setup copy and actions for explaining how to enable passkeys on a
/// platform whose authenticator (Face ID, screen lock, Windows Hello) isn't
/// ready yet. Used by both the sign-in card and the Security Center so the
/// two screens cannot drift apart.
class PasskeySetupInstructions {
  const PasskeySetupInstructions({
    required this.setupBodyKey,
    required this.instructionsTitleKey,
    required this.instructionsBodyKey,
    required this.settingsButtonLabelKey,
    required this.setupAction,
  });

  /// Concise card line telling the user what to enable on this device.
  final String setupBodyKey;
  final String instructionsTitleKey;
  final String instructionsBodyKey;
  final String? settingsButtonLabelKey;
  final PasskeySetupAction setupAction;
}

class _PasskeySetupCopy {
  const _PasskeySetupCopy({
    required this.loginTitleKey,
    required this.setupBodyKey,
    required this.instructionsTitleKey,
    required this.instructionsBodyKey,
    required this.settingsButtonLabelKey,
    required this.setupAction,
  });

  final String loginTitleKey;
  final String setupBodyKey;
  final String instructionsTitleKey;
  final String instructionsBodyKey;
  final String? settingsButtonLabelKey;
  final PasskeySetupAction setupAction;
}

_PasskeySetupCopy _resolveSetupCopy({
  required TargetPlatform platform,
  required bool isWeb,
}) {
  if (isWeb) {
    return const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupWebLoginTitle',
      setupBodyKey: 'authPasskeySetupWebInstructionsBody',
      instructionsTitleKey: 'authPasskeySetupWebInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupWebInstructionsBody',
      settingsButtonLabelKey: null,
      setupAction: PasskeySetupAction.showInstructions,
    );
  }
  return switch (platform) {
    TargetPlatform.iOS => const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupIosLoginTitle',
      setupBodyKey: 'authPasskeySetupIosBody',
      instructionsTitleKey: 'authPasskeySetupIosInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupIosInstructionsBody',
      settingsButtonLabelKey: null,
      setupAction: PasskeySetupAction.showInstructions,
    ),
    TargetPlatform.android => const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupAndroidLoginTitle',
      setupBodyKey: 'authPasskeySetupAndroidBody',
      instructionsTitleKey: 'authPasskeySetupAndroidInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupAndroidInstructionsBody',
      settingsButtonLabelKey: 'authPasskeySetupAndroidButton',
      setupAction: PasskeySetupAction.openAndroidSecuritySettings,
    ),
    TargetPlatform.windows => const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupWindowsLoginTitle',
      setupBodyKey: 'authPasskeySetupWindowsBody',
      instructionsTitleKey: 'authPasskeySetupWindowsInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupWindowsInstructionsBody',
      settingsButtonLabelKey: 'authPasskeySetupWindowsButton',
      setupAction: PasskeySetupAction.openWindowsSignInOptions,
    ),
    TargetPlatform.macOS => const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupMacTitle',
      setupBodyKey: 'authPasskeySetupMacBody',
      instructionsTitleKey: 'authPasskeySetupMacInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupMacInstructionsBody',
      settingsButtonLabelKey: null,
      setupAction: PasskeySetupAction.showInstructions,
    ),
    _ => const _PasskeySetupCopy(
      loginTitleKey: 'authPasskeySetupOtherTitle',
      setupBodyKey: 'authPasskeySetupOtherBody',
      instructionsTitleKey: 'authPasskeySetupOtherInstructionsTitle',
      instructionsBodyKey: 'authPasskeySetupOtherInstructionsBody',
      settingsButtonLabelKey: null,
      setupAction: PasskeySetupAction.showInstructions,
    ),
  };
}

/// Device-setup instructions for the current platform. Cards use
/// [PasskeySetupInstructions.setupBodyKey] as their explanatory line and the
/// remaining keys to open a how-to dialog.
PasskeySetupInstructions resolvePasskeySetupInstructions({
  required TargetPlatform platform,
  bool isWeb = false,
}) {
  final copy = _resolveSetupCopy(platform: platform, isWeb: isWeb);
  return PasskeySetupInstructions(
    setupBodyKey: copy.setupBodyKey,
    instructionsTitleKey: copy.instructionsTitleKey,
    instructionsBodyKey: copy.instructionsBodyKey,
    settingsButtonLabelKey: copy.settingsButtonLabelKey,
    setupAction: copy.setupAction,
  );
}

/// Chooses the passkey card's copy and whether to offer the passkey action.
///
/// When no platform authenticator is enrolled the card explains the situation
/// and provides device-specific setup help instead of advertising a passkey
/// action that cannot currently succeed.
PasskeyCardPresentation resolvePasskeyCardPresentation(
  PasskeyDeviceCapability capability, {
  required TargetPlatform platform,
  bool isWeb = false,
}) {
  switch (capability) {
    case PasskeyDeviceCapability.noPlatformAuthenticator:
      final copy = _resolveSetupCopy(platform: platform, isWeb: isWeb);
      return PasskeyCardPresentation(
        titleKey: copy.loginTitleKey,
        bodyKey: 'authPasskeySetupPasswordAlternative',
        showActionButton: false,
        moreInfoButtonKey: 'authPasskeySetupMoreInfoButton',
        setupAction: copy.setupAction,
        setupButtonLabelKey: copy.settingsButtonLabelKey,
        setupInstructionsTitleKey: copy.instructionsTitleKey,
        setupInstructionsBodyKey: copy.instructionsBodyKey,
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
