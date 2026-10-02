import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class AuthenticatorAppLauncher {
  static const MethodChannel _channel = MethodChannel(
    'matchme/authenticator_launcher',
  );

  static const List<String> _fallbackUris = <String>[
    'googleauthenticator://',
    'microsoft-authenticator://',
    'msauthv2://',
    'authy://',
    'duomobile://',
    'lastpassauthenticator://',
    '2fas://',
  ];

  static Future<bool> open() async {
    if (kIsWeb) return false;

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final launched =
            await _channel.invokeMethod<bool>('launchAuthenticatorApp') ??
            false;
        if (launched) return true;
      } catch (_) {
        // Fall back to scheme-based launch attempts.
      }
    }

    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return _openViaKnownSchemes();
    }

    return false;
  }

  static Future<bool> _openViaKnownSchemes() async {
    for (final rawUri in _fallbackUris) {
      try {
        final launched = await launchUrl(
          Uri.parse(rawUri),
          mode: LaunchMode.externalApplication,
        );
        if (launched) return true;
      } catch (_) {
        // Try the next known app scheme.
      }
    }

    return false;
  }
}
