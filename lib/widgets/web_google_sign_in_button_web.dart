import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:matchme/services/web_calendar_service.dart';

class WebGoogleSignInButton extends ConsumerStatefulWidget {
  final Future<void> Function()? onSignIn;

  const WebGoogleSignInButton({super.key, this.onSignIn});

  @override
  ConsumerState<WebGoogleSignInButton> createState() =>
      _WebGoogleSignInButtonState();
}

class _WebGoogleSignInButtonState extends ConsumerState<WebGoogleSignInButton> {
  late final String _clientId;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    final envClientId = const String.fromEnvironment(
      'GOOGLE_CLIENT_ID',
      defaultValue: '',
    ).trim();
    final androidEnvClientId = const String.fromEnvironment(
      'GOOGLE_ANDROID_CLIENT_ID',
      defaultValue: '',
    ).trim();
    final dotEnvClientId = (dotenv.env['GOOGLE_CLIENT_ID'] ?? '').trim();
    final androidDotEnvClientId = (dotenv.env['GOOGLE_ANDROID_CLIENT_ID'] ?? '')
        .trim();

    final clientId = envClientId.isNotEmpty ? envClientId : dotEnvClientId;
    final androidClientId = androidEnvClientId.isNotEmpty
        ? androidEnvClientId
        : androidDotEnvClientId;

    _clientId = kIsWeb
        ? clientId
        : (androidClientId.isNotEmpty ? androidClientId : clientId);

    _initFuture = _clientId.isEmpty
        ? Future.value()
        : WebCalendarService.ensureGoogleSignInInitialized(clientId: _clientId);
  }

  @override
  Widget build(BuildContext context) {
    if (_clientId.isEmpty) return const SizedBox.shrink();
    final l10n = ref.watch(localizationProvider);

    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            width: 250,
            height: 40,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        return SizedBox(
          width: 250,
          height: 40,
          child: OutlinedButton.icon(
            onPressed: widget.onSignIn,
            icon: const Icon(Icons.login),
            label: Text(l10n.getString('authContinueWithGoogle')),
          ),
        );
      },
    );
  }
}
