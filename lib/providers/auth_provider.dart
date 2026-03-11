// lib/providers/auth_provider.dart
// ...existing code...
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matchme/providers/locale_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthUiMessageNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setMessage(String? message) {
    state = message;
  }

  void clear() {
    state = null;
  }
}

final authUiMessageProvider =
    NotifierProvider<AuthUiMessageNotifier, String?>(() {
  return AuthUiMessageNotifier();
});

// This creates a stream that notifies the app when the auth state changes
final authStateProvider = StreamProvider<AuthState>((ref) {
  final controller = StreamController<AuthState>();
  final auth = Supabase.instance.client.auth;

  bool disposed = false;
  StreamSubscription<AuthState>? sub;
  bool validationInFlight = false;
  String? lastValidatedAccessToken;

  void bestEffortSignOut(Object error) {
    try {
      debugPrint('Auth error encountered: $error. Signing out...');
      auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

  bool shouldSignOutForError(Object error) {
    final msg = (error is AuthException) ? error.message : error.toString();
    final lower = msg.toLowerCase();
    return lower.contains('refresh_token_not_found') ||
        lower.contains('refresh token not found') ||
        lower.contains('invalid refresh token') ||
        lower.contains('refresh_token_already_used') ||
        lower.contains('already used') ||
        lower.contains('session') ||
        lower.contains('token') ||
        lower.contains('expired') ||
        lower.contains('logout') ||
        lower.contains('sign out') ||
        lower.contains('invalid');
  }

  bool isPkceCodeVerifierError(Object error) {
    final msg = (error is AuthException) ? error.message : error.toString();
    return msg.toLowerCase().contains('code verifier could not be found');
  }

  bool isLikelyInvalidSessionError(Object error) {
    final msg = (error is AuthException) ? error.message : error.toString();
    final lower = msg.toLowerCase();
    return lower.contains('invalid jwt') ||
        lower.contains('jwt expired') ||
        lower.contains('token is expired') ||
        lower.contains('invalid refresh token') ||
        lower.contains('refresh_token_not_found') ||
        lower.contains('refresh token not found') ||
        lower.contains('refresh_token_already_used') ||
        lower.contains('already used') ||
        lower.contains('unauthorized') ||
        lower.contains('not authorized');
  }

  void validateSessionBestEffort(AuthState authState) {
    if (validationInFlight) return;
    final session = authState.session;
    if (session == null) return;
    final token = session.accessToken.trim();
    if (token.isEmpty) return;
    if (kIsWeb) {
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final exp = session.expiresAt;
      if (exp != null && exp <= now) {
        bestEffortSignOut('Session expired');
        return;
      }
    }
    if (token == lastValidatedAccessToken) return;

    validationInFlight = true;
    () async {
      try {
        await auth.getUser();
        lastValidatedAccessToken = token;
      } catch (e) {
        if (disposed) return;
        if (isLikelyInvalidSessionError(e) || shouldSignOutForError(e)) {
          lastValidatedAccessToken = null;
          bestEffortSignOut(e);
        }
      } finally {
        validationInFlight = false;
      }
    }();
  }

  sub = auth.onAuthStateChange.listen(
    (authState) {
      if (disposed) return;
      if (authState.event == AuthChangeEvent.initialSession ||
          authState.event == AuthChangeEvent.signedIn ||
          authState.event == AuthChangeEvent.tokenRefreshed) {
        validateSessionBestEffort(authState);
      }
      controller.add(authState);
    },
    onError: (Object error, StackTrace stackTrace) {
      if (disposed) return;

      if (isPkceCodeVerifierError(error)) {
        try {
          final l10n = ref.read(localizationProvider);
          ref.read(authUiMessageProvider.notifier).setMessage(l10n.getString('authOAuthFailed'));
        } catch (_) {}
        return;
      }

      if (shouldSignOutForError(error)) {
        bestEffortSignOut(error);
        return;
      }

      controller.addError(error, stackTrace);
    },
  );

  ref.onDispose(() {
    disposed = true;
    sub?.cancel();
    controller.close();
  });

  return controller.stream;
});
