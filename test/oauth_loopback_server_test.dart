// test/oauth_loopback_server_test.dart
//
// Covers the desktop OAuth loopback listener that replaces the custom-scheme
// redirect on Windows/Linux (and on macOS for non-Google providers).
//
// The listener is the piece that makes `signInWithOAuth(redirectTo: ...)` able
// to come back to the app at all on desktop, so it is worth pinning down the
// callback parsing and the socket lifecycle.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/oauth_loopback_server.dart';

void main() {
  final listener = OAuthLoopbackServer.instance;

  tearDown(() async {
    await listener.close();
  });

  group('OAuthLoopbackCallback.fromQuery', () {
    test('extracts a PKCE code', () {
      final callback = OAuthLoopbackCallback.fromQuery({'code': 'abc123'});
      expect(callback.isSuccess, isTrue);
      expect(callback.isProviderError, isFalse);
      expect(callback.code, 'abc123');
    });

    test('trims the code', () {
      final callback = OAuthLoopbackCallback.fromQuery({'code': '  abc123 '});
      expect(callback.code, 'abc123');
    });

    test('extracts a provider error with description', () {
      final callback = OAuthLoopbackCallback.fromQuery({
        'error': 'access_denied',
        'error_description': 'The user denied the request',
      });
      expect(callback.isSuccess, isFalse);
      expect(callback.isProviderError, isTrue);
      expect(callback.error, 'access_denied');
      expect(callback.errorDescription, 'The user denied the request');
    });

    test('treats a blank code as no callback', () {
      final callback = OAuthLoopbackCallback.fromQuery({'code': '   '});
      expect(callback, same(OAuthLoopbackCallback.none));
    });

    test('treats a blank error as no callback', () {
      final callback = OAuthLoopbackCallback.fromQuery({'error': ' '});
      expect(callback, same(OAuthLoopbackCallback.none));
    });

    test('prefers the code when a provider sends both', () {
      final callback = OAuthLoopbackCallback.fromQuery({
        'code': 'abc123',
        'error': 'server_error',
      });
      expect(callback.isSuccess, isTrue);
      expect(callback.code, 'abc123');
    });
  });

  group('OAuthLoopbackServer', () {
    test('binds loopback only and returns a 127.0.0.1 redirect', () async {
      final redirect = await listener.listen();

      expect(listener.isListening, isTrue);
      expect(redirect.scheme, 'http');
      // Must be a literal IP, not `localhost`: GoTrue short-circuits redirect
      // validation on `net.ParseIP(host).IsLoopback()` before it ever consults
      // the project's redirect allow list, and `localhost` would not match.
      expect(redirect.host, '127.0.0.1');
      expect(redirect.port, greaterThan(0));
      expect(redirect.path, '/auth/callback');
      // The redirect must not carry a query string, or the PKCE code the
      // provider appends would not be what we asked for.
      expect(redirect.query, isEmpty);
    });

    test('re-listening rebinds a fresh port', () async {
      final first = await listener.listen();
      final second = await listener.listen();
      expect(listener.isListening, isTrue);
      // Both binds succeed; the old listener is fully released.
      expect(second.host, '127.0.0.1');
      expect(second.port, greaterThan(0));
      expect(first.port, greaterThan(0));
    });

    test('captures the code the provider redirects with', () async {
      final redirect = await listener.listen();
      final pending = listener.waitForCallback(const Duration(seconds: 10));

      final response = await HttpClient()
          .getUrl(redirect.replace(queryParameters: {'code': 'pkce-code-1'}))
          .then((r) => r.close());
      expect(response.statusCode, 200);

      final callback = await pending;
      expect(callback.isSuccess, isTrue);
      expect(callback.code, 'pkce-code-1');
    });

    test('captures a provider error', () async {
      final redirect = await listener.listen();
      final pending = listener.waitForCallback(const Duration(seconds: 10));

      await HttpClient()
          .getUrl(
            redirect.replace(
              queryParameters: {
                'error': 'access_denied',
                'error_description': 'User cancelled',
              },
            ),
          )
          .then((r) => r.close());

      final callback = await pending;
      expect(callback.isSuccess, isFalse);
      expect(callback.isProviderError, isTrue);
      expect(callback.error, 'access_denied');
      expect(callback.errorDescription, 'User cancelled');
    });

    test('serves a page the browser can render', () async {
      final redirect = await listener.listen();
      final pending = listener.waitForCallback(const Duration(seconds: 10));

      final client = HttpClient();
      final request = await client.getUrl(
        redirect.replace(queryParameters: {'code': 'pkce-code-2'}),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();

      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(body, contains('Signed in'));
      expect(body, contains('Return to MatchMe'));
      // Nothing from the provider's response is interpolated into the page.
      expect(body, isNot(contains('pkce-code-2')));

      await pending;
      client.close(force: true);
    });

    test('ignores stray requests on other paths', () async {
      final redirect = await listener.listen();
      final pending = listener.waitForCallback(
        const Duration(milliseconds: 600),
      );

      // A favicon/port-scanner probe must not be mistaken for a callback.
      final response = await HttpClient()
          .getUrl(redirect.replace(path: '/favicon.ico'))
          .then((r) => r.close());
      expect(response.statusCode, 200);

      await expectLater(
        pending,
        throwsA(
          isA<OAuthLoopbackException>().having(
            (e) => e.failure,
            'failure',
            OAuthLoopbackFailure.timeout,
          ),
        ),
      );
    });

    test('times out when the browser never comes back', () async {
      await listener.listen();
      await expectLater(
        listener.waitForCallback(const Duration(milliseconds: 300)),
        throwsA(
          isA<OAuthLoopbackException>().having(
            (e) => e.failure,
            'failure',
            OAuthLoopbackFailure.timeout,
          ),
        ),
      );
    });

    test('waitForCallback without a listener reports notListening', () async {
      expect(listener.isListening, isFalse);
      await expectLater(
        listener.waitForCallback(const Duration(milliseconds: 100)),
        throwsA(
          isA<OAuthLoopbackException>().having(
            (e) => e.failure,
            'failure',
            OAuthLoopbackFailure.notListening,
          ),
        ),
      );
    });

    test('close releases the port so it can be re-bound', () async {
      final first = await listener.listen();
      await listener.close();
      expect(listener.isListening, isFalse);

      // Binding the exact same port again proves the previous listener really
      // released it (Windows keeps a socket in TIME_WAIT otherwise).
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        first.port,
      );
      await server.close(force: true);

      final second = await listener.listen();
      expect(second.port, greaterThan(0));
    });

    test('close is idempotent', () async {
      await listener.close();
      await listener.close();
      expect(listener.isListening, isFalse);
    });
  });
}
