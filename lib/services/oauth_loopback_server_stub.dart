// lib/services/oauth_loopback_server_stub.dart
//
// Web has no dart:io, so there is no loopback listener. Web keeps using the
// browser-native flow: `signInWithOAuth` against `${Uri.base.origin}/auth/callback`
// with the popup/redirect handled in the page itself (see
// `_processWebOAuthCodeDuringBootstrap` in main.dart).
//
// This exists so call sites can hold a reference to `OAuthLoopbackServer`
// unconditionally instead of sprinkling `kIsWeb` checks through the auth flow.

import 'oauth_loopback_types.dart';

export 'oauth_loopback_types.dart';

class OAuthLoopbackServer {
  OAuthLoopbackServer._();

  static final OAuthLoopbackServer instance = OAuthLoopbackServer._();

  bool get isListening => false;

  Future<Uri> listen() async {
    throw const OAuthLoopbackException(OAuthLoopbackFailure.unsupported);
  }

  Future<OAuthLoopbackCallback> waitForCallback(Duration timeout) async {
    throw const OAuthLoopbackException(OAuthLoopbackFailure.unsupported);
  }

  Future<void> close() async {}
}
