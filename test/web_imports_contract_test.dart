// Locks in the inert, platform-neutral half of the browser bridge.
//
// This suite deliberately imports `web_imports.dart` rather than
// `web_imports_contract.dart`: on the VM the conditional export resolves to the
// stub, so these assertions run against exactly what a phone or desktop build
// gets. The web branch is held to the same contract by `flutter analyze`,
// which checks every `@override` in `web_imports_web.dart` against
// `web_imports_contract.dart` regardless of which branch consumers resolve to.
//
// These are behavioural assertions, not source scraping. A source-comparison
// test for this would have to re-implement a Dart parser, and a subtly wrong
// parser is worse than no test at all: it passes while checking nothing.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:matchme/web_imports.dart';

void main() {
  group('platform-neutral contract', () {
    test('exposes the document and window singletons', () {
      expect(document, isA<HtmlDocument>());
      expect(window, isA<Window>());
      expect(document, same(document));
      expect(window, same(window));
    });

    test('reports a permanently visible document', () {
      expect(document.hidden, isFalse);
      expect(document.visibilityState, 'visible');
    });

    test('reports a non-script-opened, top-level window', () {
      expect(window.opener, isNull);
    });

    test('inert location and history are safe to touch', () {
      expect(window.location.href, '');
      window.location.reload();
      window.history.replaceState('', 'https://example.test/');
      window.history.replaceState('', null);
    });

    test('event add/remove is a no-op, including for null and repeats', () {
      void listener(Object _) {}

      expect(() {
        document.addEventListener('visibilitychange', listener);
        document.addEventListener('visibilitychange', listener);
        document.removeEventListener('visibilitychange', listener);
        document.removeEventListener('visibilitychange', listener);

        window.addEventListener('pageshow', listener);
        window.removeEventListener('pageshow', listener);

        // The DOM shim must tolerate these too: a null listener is what
        // `addEventListener(type, maybeNull)` hands over.
        document.addEventListener('visibilitychange', null);
        document.removeEventListener('visibilitychange', null);
        window.addEventListener('pageshow', null);
        window.removeEventListener('pageshow', null);
      }, returnsNormally);
    });

    test('event defaults carry no data and do nothing', () {
      final event = Event();
      expect(event.type, '');
      expect(event.preventDefault, returnsNormally);
      expect(KeyboardEvent().key, '');
      expect(KeyboardEvent().type, '');
    });
  });

  group('geolocation', () {
    test('never invokes the success callback', () {
      var called = false;
      window.navigator.geolocation.getCurrentPosition(
        (_) => called = true,
        (_, _) => called = true,
        const WebGeolocationOptions(enableHighAccuracy: true, timeout: 1),
      );
      expect(called, isFalse);
    });

    test('watch returns an inert id and clearWatch accepts it', () {
      final id = window.navigator.geolocation.watchPosition((_) {});
      expect(id, -1);
      expect(
        () => window.navigator.geolocation.clearWatch(id),
        returnsNormally,
      );
    });
  });

  group('permissions', () {
    test('queryState resolves to the undetermined state', () async {
      expect(
        await window.navigator.permissions.queryState('geolocation'),
        'prompt',
      );
    });
  });

  group('beacons and haptics', () {
    test('navigator.sendBeacon reports failure', () {
      expect(
        window.navigator.sendBeacon('https://example.test/', Uint8List(0)),
        isFalse,
      );
      expect(
        sendAuthenticatedOfflineBeacon(
          'https://example.test/',
          '{"type":"ping"}',
          'access-token',
          'anon-key',
        ),
        isFalse,
      );
    });

    test('safeVibrate accepts every pattern shape without throwing', () {
      expect(() {
        safeVibrate(200);
        safeVibrate(<int>[200, 100, 200]);
        safeVibrate('unsupported-pattern');
        safeVibrate(<int>[]);
      }, returnsNormally);
    });
  });

  group('camera', () {
    test('resolves to null instead of throwing off the web', () async {
      expect(await pickImageBytesFromCamera(), isNull);
      expect(await pickImageBytesFromCamera(capture: 'environment'), isNull);
    });
  });
}
