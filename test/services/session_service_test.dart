import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:matchme/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _refreshTokenKey = 'flutter.refresh_token';
const _userTokenKey = 'flutter.user_token';
const _userIdKey = 'flutter.user_id';
const _snapshotKey = 'persisted_supabase_session';
const _legacySdkTokenKey = 'sb-abc123-auth-token';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit sign-out wipe clears every recoverable auth credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      // Written through the same facade the app uses, so the assertions are
      // independent of the mock store's key-prefix handling.
      await prefs.setString(_refreshTokenKey, 'stale-refresh-token');
      await prefs.setString(_userTokenKey, 'stale-access-token');
      await prefs.setString(_userIdKey, 'user-1');
      await prefs.setString(_snapshotKey, '{"currentSession":{}}');
      await prefs.setString(_legacySdkTokenKey, '{"currentSession":{}}');

      await SessionService.clearPersistedSupabaseSessionSnapshot();

      expect(
        prefs.getString(_refreshTokenKey),
        isNull,
        reason: 'a leftover refresh token re-authenticates on the next launch',
      );
      expect(prefs.getString(_userTokenKey), isNull);
      expect(prefs.getString(_userIdKey), isNull);
      expect(prefs.getString(_snapshotKey), isNull);
      expect(prefs.getString(_legacySdkTokenKey), isNull);
    },
  );

  group('session platform key', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('each target maps to its own platform key', () {
      const expected = {
        TargetPlatform.android: 'android',
        TargetPlatform.iOS: 'ios',
        TargetPlatform.macOS: 'macos',
        TargetPlatform.windows: 'windows',
        TargetPlatform.linux: 'linux',
        TargetPlatform.fuchsia: 'unknown',
      };
      for (final entry in expected.entries) {
        debugDefaultTargetPlatformOverride = entry.key;
        expect(
          SessionService.detectPlatform(),
          entry.value,
          reason: '${entry.key} must not collapse into the wrong key',
        );
      }
    });

    test('windows never falls back to unknown', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(
        SessionService.detectPlatform(),
        'windows',
        reason: 'match push finds Windows WNS targets only on platform=windows',
      );
    });
  });

  group('session policy: what may sign the user out', () {
    test(
      'a refresh-token failure never proves the account was deleted',
      () {
        // The incident: the native background service had already spent the
        // rotating refresh token, so the app's own refresh came back with
        // "Invalid Refresh Token: Already Used". Treating that as "the
        // account is gone" hard-signed the user out on the login screen.
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: Invalid Refresh Token: Already Used, '
            'statusCode: 400, code: refresh_token_already_used)',
          ),
          isFalse,
        );
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: Invalid Refresh Token, '
            'statusCode: 400, code: refresh_token_not_found)',
          ),
          isFalse,
        );
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: Session not found, statusCode: 403)',
          ),
          isFalse,
        );
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthSessionMissingException(message: Auth session missing!, '
            'statusCode: 400)',
          ),
          isFalse,
        );
      },
    );

    test(
      'only the auth server saying "this user does not exist" counts',
      () {
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: User from sub claim in JWT does not '
            'exist, statusCode: 404, code: user_not_found)',
          ),
          isTrue,
        );
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: user not found, statusCode: 404)',
          ),
          isTrue,
        );
        // GoTrue answers a deleted auth user with HTTP 403 + user_not_found.
        // The old classifier excluded every 403 before checking the marker,
        // so a deletion could never be confirmed.
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: User from sub claim in JWT does not '
            'exist, statusCode: 403, code: user_not_found)',
          ),
          isTrue,
        );
        expect(
          SessionService.isAccountGoneAuthError(
            'AuthApiException(message: user not found, statusCode: 403)',
          ),
          isTrue,
        );
      },
    );

    test('expired or invalid claims are never proof of deletion', () {
      expect(
        SessionService.isAccountGoneAuthError(
          'AuthApiException(message: JWT expired, statusCode: 401, '
          'code: jwt_expired)',
        ),
        isFalse,
      );
      expect(
        SessionService.isAccountGoneAuthError(
          'AuthApiException(message: invalid claim: missing sub claim, '
          'statusCode: 401)',
        ),
        isFalse,
      );
    });

    test('a network failure is never proof of deletion', () {
      expect(
        SessionService.isAccountGoneAuthError(
          'SocketException: Connection failed (OS Error: Network is '
          'unreachable)',
        ),
        isFalse,
      );
      expect(
        SessionService.isAccountGoneAuthError(
          'TimeoutException after 0:00:08.000000: Future not completed',
        ),
        isFalse,
      );
    });
  });
}
