import 'package:flutter/material.dart';
import 'package:matchme/providers/locale_provider.dart';

class AuthEntryPoint extends StatelessWidget {
  final bool isSignUp;
  final VoidCallback onToggle;
  final LocalizationState l10n;
  final VoidCallback? onPasskeyPressed;

  const AuthEntryPoint({
    required this.isSignUp,
    required this.onToggle,
    required this.l10n,
    this.onPasskeyPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (isSignUp) {
      return SizedBox.shrink();
    }

    return Column(
      children: [
        if (onPasskeyPressed != null)
          ElevatedButton.icon(
            onPressed: onPasskeyPressed,
            icon: const Icon(Icons.fingerprint),
            label: Text(l10n.getString('authContinueWithPasskey')),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
      ],
    );
  }
}
