import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matchme/services/offline_image_cache.dart';
import 'package:matchme/services/storage_helper.dart';
import 'package:matchme/widgets/signed_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _currentUserId = 'signed-image-viewer';
const _loadingKey = Key('signed-image-loading');
const _errorKey = Key('signed-image-error');

// 1x1 transparent PNG.
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

String _accessToken() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Map<String, dynamic> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode({'sub': _currentUserId, 'iat': now, 'exp': now + 3600})}.sig';
}

Widget _harness(String source) {
  return MaterialApp(
    home: Scaffold(
      body: SignedImage(
        source: source,
        ttlSeconds: 3600,
        width: 56,
        height: 56,
        placeholder: const Icon(Icons.person, key: _loadingKey),
        errorWidget: const Icon(Icons.broken_image, key: _errorKey),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      publishableKey: 'test-publishable-key',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/user')) {
          return http.Response(
            jsonEncode({
              'id': _currentUserId,
              'aud': 'authenticated',
              'role': 'authenticated',
              'email': 'test@example.com',
              'app_metadata': <String, dynamic>{},
              'user_metadata': <String, dynamic>{},
              'created_at': '2026-01-01T00:00:00Z',
            }),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        // Signing fails the way it does while the session is not usable.
        // The image layer must treat that as transient and retry; for the
        // private profile-photos bucket there is no public URL to fall back
        // to (Supabase answers 400 for those by design).
        return http.Response(
          jsonEncode({
            'statusCode': '400',
            'error': 'Bad Request',
            'message': 'bad request',
          }),
          400,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
      debug: false,
    );
    await Supabase.instance.client.auth.setSession(
      'test-refresh-token',
      accessToken: _accessToken(),
    );
  });

  setUp(() {
    // The encrypted box keeps a cold cache for every key. (The real box does
    // real file I/O that never completes under fake async.)
    OfflineImageCache.debugReadOverride = (_) async => null;
  });

  tearDown(() {
    OfflineImageCache.debugReadOverride = null;
    // Resuming the app starts Supabase's auto-refresh periodic timer; stop it
    // so the test binding does not report a pending timer.
    Supabase.instance.client.auth.stopAutoRefresh();
  });

  testWidgets('a failed avatar load retries instead of failing permanently', (
    tester,
  ) async {
    final logs = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      await tester.pumpWidget(_harness('retry-user/photo.jpg'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The first attempt has failed, but the budget is not spent: the tile
      // keeps its placeholder up and retries in the background. Showing the
      // error icon here is what left avatars faceless for a whole session.
      expect(find.byKey(_errorKey), findsNothing);
      expect(find.byKey(_loadingKey), findsOneWidget);

      var pumps = 0;
      while (find.byKey(_errorKey).evaluate().isEmpty && pumps < 30) {
        await tester.pump(const Duration(seconds: 20));
        await tester.pump();
        pumps++;
      }

      expect(
        find.byKey(_errorKey),
        findsOneWidget,
        reason: 'the retry budget must be finite so a dead image stops trying',
      );
      expect(
        logs.where((line) => line.contains('[IMG] gave up on')).length,
        1,
        reason: 'a terminal image failure must be traceable in the log',
      );
      expect(
        logs.any((line) => line.contains('retry-user/photo.jpg')),
        isTrue,
        reason: 'the log names the object path (never the signed token)',
      );
    } finally {
      debugPrint = originalDebugPrint;
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed avatar load recovers when the app resumes', (
    tester,
  ) async {
    const source = 'resume-user/photo.jpg';
    await tester.pumpWidget(_harness(source));
    await tester.pump();
    // Let the first attempt fail and the 500ms backoff attempt run, so the
    // tile is sitting between retries when the app is resumed.
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(_loadingKey), findsOneWidget);
    expect(find.byKey(_errorKey), findsNothing);

    // The photo becomes available while the tile is waiting (e.g. the
    // re-login that follows an OAuth round trip warmed the byte cache).
    final cacheKey = StorageHelper.cacheKeyForSource(source);
    OfflineImageCache.debugReadOverride = (key) async =>
        key == cacheKey ? _onePixelPng : null;
    await tester.pump();

    // Coming back from the auth sheet is a resume: the pending tile must
    // re-attempt immediately instead of waiting out the backoff.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(_loadingKey), findsNothing);
    expect(find.byKey(_errorKey), findsNothing);

    // Supabase starts its token auto-refresh when the app resumes; the
    // binding rejects a still-pending timer at the end of the body.
    Supabase.instance.client.auth.stopAutoRefresh();

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
