import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/utils/passkey_suggestion.dart';

/// Shows the how-to dialog for setting up passkeys on this device.
///
/// Shared by the sign-in passkey card and the Security Center so both screens
/// offer identical platform-specific instructions and the same deep links into
/// system settings.
Future<void> showPasskeySetupInstructionsDialog(
  BuildContext context, {
  required LocalizationState l10n,
  required String titleKey,
  required String bodyKey,
  required PasskeySetupAction setupAction,
  String? settingsButtonLabelKey,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.getString(titleKey)),
      content: SingleChildScrollView(child: Text(l10n.getString(bodyKey))),
      actions: [
        if (settingsButtonLabelKey != null)
          TextButton(
            onPressed: () => _openPasskeySetupSettings(setupAction),
            child: Text(l10n.getString(settingsButtonLabelKey)),
          ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.getString('done')),
        ),
      ],
    ),
  );
}

Future<void> _openPasskeySetupSettings(PasskeySetupAction setupAction) async {
  switch (setupAction) {
    case PasskeySetupAction.openAndroidSecuritySettings:
      try {
        final opened = await const MethodChannel(
          'matchme/passkey_setup',
        ).invokeMethod<bool>('openSecuritySettings');
        if (opened != true) {
          debugPrint('[Passkey] Android security settings did not open.');
        }
      } on PlatformException catch (error) {
        debugPrint('[Passkey] Could not open Android security settings: $error');
      } on MissingPluginException catch (error) {
        debugPrint('[Passkey] Android settings bridge is unavailable: $error');
      }
    case PasskeySetupAction.openWindowsSignInOptions:
      try {
        final opened = await launchUrl(
          Uri.parse('ms-settings:signinoptions'),
          mode: LaunchMode.externalApplication,
        );
        if (!opened) {
          debugPrint('[Passkey] Windows sign-in settings did not open.');
        }
      } catch (error) {
        debugPrint('[Passkey] Could not open Windows sign-in settings: $error');
      }
    case PasskeySetupAction.showInstructions:
      return;
  }
}
