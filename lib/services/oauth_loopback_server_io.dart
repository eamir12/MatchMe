// lib/services/oauth_loopback_server_io.dart
//
// Loopback OAuth callback listener for platforms that have dart:io
// (Android, iOS, Windows, macOS, Linux).
//
// Desktop apps cannot use a custom URL scheme to get the OAuth redirect back:
// Windows and Linux have no protocol-handler registration in this project, and
// macOS declares no CFBundleURLSchemes, so a `com.example.matchme://` redirect
// dead-ends in the browser. RFC 8252 section 7.3 ("Loopback Interface
// Redirection") is the standard desktop answer: the provider redirects to a
// loopback HTTP listener the app itself owns, and the app finishes the exchange.
//
// Supabase accepts `http://127.0.0.1:<port>/...` as a `redirect_to` without any
// entry in the project's redirect allow list, because GoTrue short-circuits on
// `net.ParseIP(host).IsLoopback()`. That is why this uses a literal 127.0.0.1
// and not `localhost` - `localhost` is not an IP and *would* require a
// `http://localhost:*/**` glob, which is both more config for the operator and
// exposed to the userinfo-confusion hole in that glob's `*`.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'oauth_loopback_types.dart';

// Re-exported so `oauth_loopback_server.dart` surfaces the shared types no matter
// which implementation the conditional export selects.
export 'oauth_loopback_types.dart';

/// Owns a short-lived `http://127.0.0.1:<port>` server that catches the OAuth
/// redirect the provider sends at the end of a desktop sign-in.
class OAuthLoopbackServer {
  OAuthLoopbackServer._();

  static final OAuthLoopbackServer instance = OAuthLoopbackServer._();

  /// Path the redirect must point at.
  static const String callbackPath = '/auth/callback';

  /// How long to let the browser finish writing its response before forcing
  /// the listener's connections closed.
  static const Duration _responseFlushGrace = Duration(milliseconds: 500);

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Completer<OAuthLoopbackCallback>? _pending;

  bool get isListening => _server != null;

  /// Binds an ephemeral loopback port and returns the URL to pass to
  /// `signInWithOAuth(redirectTo: ...)`.
  ///
  /// Any previous listener is torn down first, so a retry after a failed or
  /// abandoned attempt always gets a fresh port.
  Future<Uri> listen() async {
    await close();

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } catch (error) {
      debugPrint('🔴 [OAuthLoopback] could not bind loopback port: $error');
      throw const OAuthLoopbackException(OAuthLoopbackFailure.bindFailed);
    }

    final pending = Completer<OAuthLoopbackCallback>();
    _server = server;
    _pending = pending;

    // Held so `close()` can cancel it; the stream has no consumer we need to
    // await, and a failed request must not tear the listener down.
    _subscription = server.listen(
      (HttpRequest request) => _handleRequest(request, pending),
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('⚠️ [OAuthLoopback] listener error: $error');
      },
      cancelOnError: false,
    );

    final redirect = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: callbackPath,
    );
    debugPrint('🔗 [OAuthLoopback] listening on $redirect');
    return redirect;
  }

  /// Completes once the browser hits the loopback URL, or fails with
  /// [OAuthLoopbackException] if nothing usable arrives within [timeout].
  ///
  /// Declared `async` so every failure - including "not listening" - surfaces as
  /// a failed future rather than a synchronous throw, which keeps the error
  /// handling uniform for callers.
  Future<OAuthLoopbackCallback> waitForCallback(Duration timeout) async {
    final pending = _pending;
    if (pending == null) {
      throw const OAuthLoopbackException(OAuthLoopbackFailure.notListening);
    }
    return pending.future.timeout(
      timeout,
      onTimeout: () =>
          throw const OAuthLoopbackException(OAuthLoopbackFailure.timeout),
    );
  }

  /// Stops listening. Safe to call when nothing is listening.
  Future<void> close() async {
    final server = _server;
    final subscription = _subscription;
    _server = null;
    _subscription = null;
    _pending = null;
    await subscription?.cancel();
    if (server == null) return;
    try {
      await server.close(force: true);
    } catch (error) {
      debugPrint('⚠️ [OAuthLoopback] error while closing listener: $error');
    }
  }

  Future<void> _handleRequest(
    HttpRequest request,
    Completer<OAuthLoopbackCallback> pending,
  ) async {
    final callback = OAuthLoopbackCallback.fromQuery(
      request.uri.queryParameters,
    );
    final isCallback = callback.isSuccess || callback.isProviderError;
    await _respond(request, succeeded: callback.isSuccess);

    // Anything else on the socket (favicon, port scanner, user typo) is answered
    // and ignored.
    if (!isCallback) return;

    debugPrint(
      '🔗 [OAuthLoopback] callback received '
      '(success=${callback.isSuccess}, error=${callback.error})',
    );
    if (!pending.isCompleted) {
      pending.complete(callback);
    }
    unawaited(Future<void>.delayed(_responseFlushGrace, close));
  }

  /// Writes the result page and waits for it to be handed to the socket, so the
  /// listener can be torn down without truncating what the browser is reading.
  Future<void> _respond(HttpRequest request, {required bool succeeded}) async {
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..write(_resultPage(succeeded: succeeded));
    try {
      await response.close();
    } catch (error) {
      // The browser can navigate away mid-write. Harmless: the code has already
      // been captured, and the user is about to return to the app regardless.
      debugPrint('⚠️ [OAuthLoopback] response close failed: $error');
    }
  }
}

/// Minimal "you can close this tab" page.
///
/// Deliberately static text: nothing from the provider's response is
/// interpolated, so there is no escaping surface.
String _resultPage({required bool succeeded}) {
  final heading = succeeded ? 'Signed in' : 'Sign-in not completed';
  final body = succeeded
      ? 'Return to MatchMe to continue.'
      : 'No account was connected. Return to MatchMe and try again.';

  return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MatchMe</title>
<style>
  :root { color-scheme: light dark; }
  body {
    margin: 0; min-height: 100vh;
    display: flex; align-items: center; justify-content: center;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f6f7fb; color: #1c1f2a;
  }
  .card { text-align: center; padding: 40px 32px; max-width: 420px; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { margin: 0; font-size: 15px; line-height: 1.5; color: #5b6072; }
  button {
    margin-top: 20px; padding: 9px 18px; font: inherit; font-size: 14px;
    color: inherit; background: transparent; cursor: pointer;
    border: 1px solid currentColor; border-radius: 8px; opacity: 0.75;
  }
  button:hover { opacity: 1; }
  @media (prefers-color-scheme: dark) {
    body { background: #12141c; color: #eef0f6; }
    p { color: #a2a8bd; }
  }
</style>
</head>
<body>
  <div class="card">
    <h1>$heading</h1>
    <p>$body</p>
    <button id="close" type="button">Close this tab</button>
  </div>
  <script>
    // The OAuth tab is opened by the *browser* (we hand the URL to the OS), so
    // window.close() is refused by every major engine - see the WHATWG spec:
    // it only succeeds for script-opened contexts. Try anyway (it does work for
    // a few browser/OS combinations), and if the tab is still open after a
    // moment, quietly drop the button rather than offering a dead control.
    (function () {
      var button = document.getElementById('close');
      function tryClose() {
        try { window.close(); } catch (e) { /* ignored */ }
        setTimeout(function () {
          if (!window.closed && button && button.parentNode) {
            button.parentNode.removeChild(button);
          }
        }, 250);
      }
      button.addEventListener('click', tryClose);
      setTimeout(tryClose, 1200);
    })();
  </script>
</body>
</html>''';
}
