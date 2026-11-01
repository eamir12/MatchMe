import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/providers/profile_provider.dart';
import 'package:matchme/services/secure_local_storage.dart';
import 'package:matchme/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _latchKey = 'flutter.dead_session_latch';
const _failedKey = 'flutter.auth_permanently_failed';
const _userId = 'ffc20046-a777-463b-922a-547151aa1455';

String _jwt(Map<String, dynamic> payload) {
  String encode(Map<String, dynamic> value) => base64Url
      .encode(utf8.encode(jsonEncode(value)))
      .replaceAll('=', '');
  return '${encode({'alg': 'HS256', 'typ': 'JWT'})}.${encode(payload)}.sig';
}

int? _adopt({
  int? seededExpiresAt = 1000,
  String seededUserId = _userId,
  String seededAccessToken = 'seeded-access',
  String seededRefreshToken = 'seeded-refresh',
  String? nativeAccessToken,
  String nativeRefreshToken = 'native-refresh',
}) {
  return SessionService.nativePairAdoptionExpiry(
    seededExpiresAt: seededExpiresAt,
    seededUserId: seededUserId,
    seededAccessToken: seededAccessToken,
    seededRefreshToken: seededRefreshToken,
    nativeAccessToken:
        nativeAccessToken ??
        _jwt({'sub': seededUserId, 'exp': 2000, 'iat': 1400}),
    nativeRefreshToken: nativeRefreshToken,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('native token adoption ordering (2026-10-30 incident)', () {
    test('a newer native pair wins even when its access token expired', () {
      // The background service rotated the token while the app was closed.
      // Its access token (exp=2000) is already in the past relative to the
      // wall clock, but it is still strictly newer than the seeded 1000 —
      // rejecting it made the app replay the stale persisted token.
      expect(_adopt(seededExpiresAt: 1000), 2000);
    });

    test('an equally old or older native pair never wins', () {
      expect(_adopt(seededExpiresAt: 2000), isNull);
      expect(_adopt(seededExpiresAt: 2500), isNull);
    });

    test('a pair for a different user is never adopted', () {
      expect(
        _adopt(
          nativeAccessToken: _jwt({'sub': 'someone-else', 'exp': 2000}),
        ),
        isNull,
      );
    });

    test('the pair must actually change both tokens', () {
      final sameAccessToken = _jwt({'sub': _userId, 'exp': 2000});
      expect(
        _adopt(
          seededAccessToken: sameAccessToken,
          nativeAccessToken: sameAccessToken,
        ),
        isNull,
        reason: 'same access token means the same generation',
      );
      expect(_adopt(nativeRefreshToken: 'seeded-refresh'), isNull);
      expect(_adopt(nativeRefreshToken: '  '), isNull);
      expect(_adopt(nativeAccessToken: '  '), isNull);
    });

    test('an access token without exp is never adopted', () {
      expect(
        _adopt(nativeAccessToken: _jwt({'sub': _userId})),
        isNull,
      );
    });
  });

  group('dead-session latch stops the renewal loop', () {
    tearDown(() async {
      await SessionService.clearDeadSessionState();
      SessionService.cancelStaleSessionRenewal();
    });

    test('markDeadSession latches the gate and persists the failure flag',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await SessionService.markDeadSession();

      expect(SessionService.deadSessionDetected.value, isTrue);
      expect(prefs.getBool(_latchKey), isTrue);
      expect(
        prefs.getBool(_failedKey),
        isTrue,
        reason: 'renewal paths read this flag before spending a token',
      );
      expect(SessionService.staleSessionRenewalScheduled, isFalse);
    });

    test('a dead family can never re-arm the stale-renewal bundle', () async {
      SharedPreferences.setMockInitialValues({});
      await SessionService.markDeadSession();

      SessionService.scheduleStaleSessionRenewalIfNeeded();

      expect(
        SessionService.staleSessionRenewalScheduled,
        isFalse,
        reason: 'a revoked family has no copy left to renew',
      );
    });

    test('safeRefreshSession refuses to spend a token while the gate is armed',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SessionService.markDeadSession();

      expect(
        await SessionService.safeRefreshSession(),
        isFalse,
        reason: 'every call site must bail before touching the token endpoint',
      );
    });

    test('probeRefreshTokenHealth never replays a token while the gate is armed',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SessionService.markDeadSession();

      expect(
        await SessionService.probeRefreshTokenHealth(),
        RefreshTokenHealth.dead,
        reason: 'each probe copy would be a fresh abuse-attempt log entry',
      );
    });

    test('restoreDeadSessionLatch re-arms the gate from launch', () async {
      // The mock store strips one `flutter.` prefix on load, while the app
      // reads its keys with that prefix already included (matching the
      // native store layout). Seed the doubled key so the cache resolves to
      // 'flutter.dead_session_latch' exactly like a real relaunch.
      SharedPreferences.setMockInitialValues({
        'flutter.flutter.dead_session_latch': true,
      });
      final prefs = await SharedPreferences.getInstance();

      await SessionService.restoreDeadSessionLatch();

      expect(SessionService.deadSessionDetected.value, isTrue);
      expect(prefs.getBool(_failedKey), isTrue);
      expect(SessionService.staleSessionRenewalScheduled, isFalse);
    });

    test('clearDeadSessionState retracts the latch and the failure flag',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SessionService.markDeadSession();
      final prefs = await SharedPreferences.getInstance();

      await SessionService.clearDeadSessionState();

      expect(SessionService.deadSessionDetected.value, isFalse);
      expect(prefs.getBool(_latchKey), isNull);
      expect(prefs.getBool(_failedKey), isFalse);
    });
  });

  group('deadSessionLatchProvider mirrors the gate', () {
    tearDown(() async {
      await SessionService.clearDeadSessionState();
    });

    test('exposes the current latch value synchronously and on every flip',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SessionService.clearDeadSessionState();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <bool>[];
      final sub = container.listen(
        deadSessionLatchProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      addTearDown(sub.close);

      expect(
        container.read(deadSessionLatchProvider),
        isFalse,
        reason: 'a synchronous read must never see a loading placeholder — '
            'that second build re-created the users stream on every launch',
      );

      await SessionService.markDeadSession();
      expect(container.read(deadSessionLatchProvider), isTrue);

      await SessionService.clearDeadSessionState();
      expect(
        container.read(deadSessionLatchProvider),
        isFalse,
        reason: 'the users-table stream must rebuild and re-subscribe on the '
            'new sign-in, not stay on the latched Stream.value(null) forever',
      );
      expect(seen, containsAllInOrder([false, true, false]));
    });
  });

  group('SecureLocalStorage read-through', () {
    test('bareSessionJson unwraps the app snapshot shape', () {
      final access = _jwt({'sub': _userId, 'exp': 2000});
      final wrapped = jsonEncode({
        'currentSession': {
          'access_token': access,
          'refresh_token': 'rt',
          'user': {'id': _userId},
        },
        'expiresAt': 2000,
      });

      final bare = bareSessionJson(wrapped);
      expect(bare, isNotNull);
      expect(jsonDecode(bare!)['access_token'], access);
      expect(jsonDecode(bare)['currentSession'], isNull);
    });

    test('bareSessionJson keeps an already-bare SDK payload', () {
      final access = _jwt({'sub': _userId, 'exp': 2000});
      final bare = bareSessionJson(
        jsonEncode({'access_token': access, 'refresh_token': 'rt'}),
      );
      expect(jsonDecode(bare!)['refresh_token'], 'rt');
    });

    test('sessionAccessExpiry reads exp through either shape', () {
      final access = _jwt({'sub': _userId, 'exp': 2000});
      final bare = jsonEncode({'access_token': access});
      final wrapped = jsonEncode({
        'currentSession': {'access_token': access},
      });
      expect(sessionAccessExpiry(bare), 2000);
      expect(sessionAccessExpiry(wrapped), 2000);
      expect(sessionAccessExpiry('not json'), isNull);
      expect(sessionAccessExpiry(null), isNull);
    });
  });
}
