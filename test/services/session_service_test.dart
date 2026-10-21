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
      },
    );

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
